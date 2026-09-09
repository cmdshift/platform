# logging

Alloy (log collection DaemonSet) + Loki (S3 to seaweed) + `loki-rules.yaml` (ruler rules delivered via alloy) — alert path: thanos-ruler/loki rules → alertmanager → mailpit.

## The alloy pipeline (`config.alloy`)

- **k8s properties are stream labels**: `discovery.relabel` promotes `__meta_kubernetes_{namespace,pod_name,pod_container_name,node_name}` to `namespace`/`pod`/`container`/`node` — same cardinality as `instance` (`ns/pod:container`, kept for dashboards), so `{namespace="monitoring", pod=~"grafana-.*"}` selects natively.
- **Every line in Loki is JSON**: JSON lines pass through; logfmt lines convert; plain-text falls back to `{"msg": raw}`. `stage.decolorize` strips ANSI codes first (preventive — escapes would otherwise end up embedded in JSON string values). There is no generic format-to-JSON stage in alloy (pack is the only wrapper and it double-encodes), so conversion happens at the source where a knob exists.
- **`stage.pack` was removed on purpose**: `loki.source.kubernetes` only emits `instance`/`job`/`service_name`, so the pack carried no metadata and just wrapped every line as `{"_entry":"<original>"}` with apps' JSON nested-and-escaped inside. Lines are app-native now; expected `alloy_components` set: `discovery.kubernetes.pods` + `loki.source.kubernetes.pods` + `loki.write.endpoint` (no `loki.process`).
- **The `alloy.configMap` values block is load-bearing** — omitting it makes the chart **silently install its example config** (pods healthy, no push, zero errors; the kustomize-generated `alloy-config` CM sits unreferenced). Fingerprint + triage: [runbooks/local/incidents.md](../../runbooks/local/incidents.md) (cmdshift/platform#27).

## Log-format sweep (source-side JSON conversion)

Method that worked: **binary `--help` via kubectl exec is authoritative** — chart-values greps miss nested/renamed keys.

| App | Knob | Where |
|---|---|---|
| loki | `global.extraArgs += -log.format=json` | `loki-values.yaml` |
| prometheus / prometheus-operator | `prometheusSpec.logFormat` / `prometheusOperator.logFormat` | kps values |
| alertmanager (CR) | `spec.logFormat: json` | monitoring-config |
| thanos ×4 | `additionalArgs: [--log.format=json]` | monitoring-config CRs |
| velero | `configuration.logFormat: json` | velero values |
| grafana | `GF_LOG_CONSOLE_FORMAT=json` env (webhook rejects `spec.config.log.console`) | monitoring-config CR |
| kyverno | `features.logging.format: json` (**nests under `features:`** — top-level and `config.logging` render text silently) | kyverno values |
| grafana-operator | `logging.encoder: json` (`--zap-encoder`) | grafana-operator values |
| seaweedfs-operator | `--zap-encoder=json` via HelmRelease **postRenderers** (no args knob; container is `seaweedfs-operator`, not `manager`) | objects |
| metrics-server | `args += --logging-format=json` | metrics-server values |
| flux, trivy-operator, external-secrets, thanos sidecar, tetragon | already JSON | — |
| cilium, cert-manager, local-path, seaweed weed, kubelet-csr-approver | **no knob exists** (verified via `--help`) — the pipeline's normalize stage converts | — |

## Loki decisions

- **Retention**: `limits_config.retention_period: 30d`, compactor `retention_enabled` + `delete_request_store: s3`. Loki 3.x timing knobs shortened locally for observable feedback (`delete_request_cancel_period` 24h→15m, `retention_delete_delay` 2h→5m — marked `# true in the cloud`; **keep upstream defaults in the cloud**).
- **Delete path runs through seaweed** (`main-s3.objects.svc:8333`): s3.json grants explicit `Delete:` on the loki buckets; the delete-request store round-trips sigv4 through seaweed. Open observable: a real S3 `DeleteObject` round-trip = `loki_compactor_deleted_lines_total` appearing in Prometheus.
- Tetragon rule/alert queries benefit from the same stream labels: `{namespace="security", pod=~"tetragon-.*"}`.

## Operational landmines

- **Ingestion triage**: the components API (`alloy_components`) is the source of truth for what config alloy is running. Red herring: `loki_distributor_lines_received_total` is absent from loki-0 `/metrics` even when healthy (kafka/async counters materialize on first use) — live-traffic counters are `loki_distributor_bytes_received_total{tenant=...}`, `loki_ingester_memory_chunks`, `loki_write_sent_bytes_total` (alloy side). jq trap: `query_range` entries live in `.data.result`, not `.data.streams`.
- **River comments are `//`, not `#`** — a `#`-commented config crashloops the pods at load (`illegal character`); the rolling update keeps old pods serving, so no ingestion gap.
- **ConfigMap content edits may not reach pod volume mounts** (observed 5+ min stale after an in-place CM update) — `kubectl -n logging rollout restart daemonset/alloy`.
- **Seaweed volume exhaustion** shows up as loki flush failures (`S3: PutObject ... 500`, master: `Not enough data nodes found!`) — sizing and the read-only-volume mechanism in [objects/README.md](../objects/README.md); post-mortem in [runbooks/local/incidents.md](../../runbooks/local/incidents.md).
