# logging

Alloy (log collection DaemonSet) + Loki (S3 to seaweed) + `loki-rules.yaml` (ruler rules delivered via alloy) — alert path: thanos-ruler/loki rules → alertmanager → mailpit. The namespace's `ResourceQuota/compute` lives in `logging-config/` (a dedicated config group since the group previously had no `-config/` split; cmdshift/platform#93).

## The alloy pipeline (`config.alloy`)

- **k8s properties are stream labels**: `discovery.relabel` promotes `__meta_kubernetes_{namespace,pod_name,pod_container_name,node_name}` to `namespace`/`pod`/`container`/`node` — same cardinality as `instance` (`ns/pod:container`, kept for dashboards), so `{namespace="monitoring", pod=~"grafana-.*"}` selects natively.
- **Every line in Loki is JSON**: JSON lines pass through; logfmt lines convert; plain-text falls back to `{"msg": raw}`. `stage.decolorize` strips ANSI codes first (preventive — escapes would otherwise end up embedded in JSON string values). There is no generic format-to-JSON stage in alloy (pack is the only wrapper and it double-encodes), so conversion happens at the source where a knob exists.
- **`stage.pack` was removed on purpose**: `loki.source.kubernetes` only emits `instance`/`job`/`service_name`, so the pack carried no metadata and just wrapped every line as `{"_entry":"<original>"}` with apps' JSON nested-and-escaped inside. Lines are app-native now; expected `alloy_components` set: `discovery.kubernetes.pods` + `loki.source.kubernetes.pods` + `loki.write.endpoint` (no `loki.process`).
- **The `alloy.configMap` values block is load-bearing** — omitting it makes the chart **silently install its example config** (pods healthy, no push, zero errors; the kustomize-generated `alloy-config` CM sits unreferenced). Fingerprint + triage: [runbooks/local/incidents.md](../../runbooks/local/incidents.md) (cmdshift/platform#27).

## Audit log pipeline (cmdshift/platform#90)

The ctrl node's kube-apiserver writes node-local audit logs (the reviewed 9-rule policy; policy body + Talos 1.13/1.14 placement story in `cluster/local/nodes/files/audit-policy.yaml` and the machine-config docs). Alloy scrapes them on ctrl into Loki with `job="audit"`:

- **"Who deleted that PVC at 3am"** = `loki_query '{job="audit"}'` — audit streams ride the existing 30d `limits_config.retention_period`, no separate tenant.
- **Volume control lives in the audit policy, not Loki**: with the reviewed policy alone ingestion jumped from the ~4.5KB/s baseline to ~2MB/s, dominated by `coordination.k8s.io/leases` heartbeats (74 of the first 100 events). A `none` rule for leases + tokenreviews cut it ~97% to ~60KB/s. Rule ordering matters: the machine-heartbeat `none` rule must sit BEFORE the Metadata catch-all (rules are first-match-wins).
- **Ctrl-taint scheduling**: alloy tolerates `node-role.kubernetes.io/control-plane:NoSchedule` — until this change the DS was 4/5 by design (workers only). The other two ctrl-only requirements (Talos API image-pull namespace allowance, `DAC_READ_SEARCH` on the audit dir) are PodSpec/PolicyException-side, not config-side — see [runbooks/local/adding-a-workload.md](../../runbooks/local/adding-a-workload.md) for the ctrl-scheduling pattern.
- **River gotchas hit on the audit stages**: map literals need a trailing comma after EVERY attribute (`{ __path__ = "...", job = "audit", node = sys.env("..."), }`); `env()` is deprecated/removed in alloy v1.19.x — `sys.env()` is the replacement (validation error otherwise).

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
