# observability

kube-prometheus-stack (operator + Prometheus CR only — node-exporter and kube-state-metrics are standalone HelmReleases since cmdshift/platform#69), grafana-operator, thanos-operator (bundle), loki, alloy, **tempo**, and the sizing stack (metrics-server, vpa, goldilocks — all three install into kube-system but their HelmReleases/values live here by domain) + `observability-config/` (CR-managed components, thanos ruler rules, alert routing, dashboards, quotas). prometheus-operator-crds stays in `crds/` (its HelmRelease targets the `observability` namespace). Namespace layout rationale (cmdshift/platform#120): the former `metrics`/`monitoring`/`logging` groups collapsed into one — the `logging → dependsOn: monitoring` edge existed only because `loki.grafana-datasource.yaml` needed the grafana-operator CRDs, and the merge dissolves it.

## Tempo (traces) (cmdshift/platform#83)

- **Chart values traps**: the tempo chart's `persistence` is a **top-level** values key — nesting it under `tempo:` silently renders no volumeClaimTemplates (`helm template` catches it). The S3 config key is `forcepathstyle` (not `s3ForcePathStyle`), and env expansion needs `-config.expand-env=true` — set via `tempo.extraArgs: {config.expand-env: "true"}` (the chart renders the extraArgs map as `-key=value`).
- **Credentials flow** (same pattern as loki): secrets server `/www/observability/tempo-s3-credentials` → ExternalSecret `tempo-s3-credentials` → `extraEnvFrom` secretRef → `${TEMPO_S3_ACCESS_KEY_ID}`/`${TEMPO_S3_SECRET_ACCESS_KEY}` in values. Blockstorage backend is seaweed via a Bucket CR (`objects-config/tempo.s3-bucket.yaml`).
- **Beyla was removed (2026-09-18)** — the eBPF probes panicked the host kernel (7.2, the same constraint class as the cilium `1.21.0-pre.2` pin). The release, values, `allow-beyla-ebpf` PolicyException, and the beyla quota share are gone; the "Recent traces" dashboard panel and the tempo datasource stay (tempo is retained, traceless until instrumentation returns — any re-adoption must first verify host-kernel compatibility). Full post-mortem: [runbooks/local/incidents.md](../../runbooks/local/incidents.md). Historical landmines from the adoption that still apply to any future eBPF workload: `contextPropagation.enabled: true` (chart default) forces `hostNetwork: true` → kyverno disallow-host-ports denial — privileged eBPF pods must mount tracefs in-namespace, and the observability CNP only allows host egress 10250/9100.
- **Sizing evidence**: tempo lean start validated 268-367Mi steady (768Mi request / 1Gi limit), CPU 150m→1000m.
- **Grafana wiring**: `observability-config/tempo.grafana-datasource.yaml` (`GrafanaDatasource` CR, type `tempo`, url `http://tempo.observability.svc:3200`); the `platform-deployment` dashboard has a `tempo_ds` datasource variable + a "Recent traces" traces panel (id 7, filters on `k8s.namespace.name=$namespace`).

## Decomposition: partial split adopted (cmdshift/platform#69)

The original issue proposed moving the operator to a standalone prometheus-operator chart too. **Rejected**: that chart is deprecated (it became kube-prometheus-stack; a full decomposition would need raw operator manifests, thanos-operator bundle.yaml style), and splitting the remainder was judged not worth it — kps 91.2.1 stays for the operator + Prometheus CR + the control-plane ServiceMonitors (kubelet/apiserver/coredns/etc).

- node-exporter → standalone `prometheus-node-exporter@4.57.0` (same version kps vendors as subchart); kube-state-metrics → standalone `kube-state-metrics@8.5.0` (app 2.20.0, same as kps vendors; chart 8.4.2). kps values carry `kubeStateMetrics.enabled: false` / `nodeExporter.enabled: false` — the top-level keys are the **subchart-condition switches**; the legacy `kube-state-metrics:` / `prometheus-node-exporter:` values keys only configure the subcharts and never disable them.
- **Scrape-label mechanics that keep the split scrape-identical**: the kubernetes-mixin node rules select `job="node-exporter"`. kps sets `podLabels.jobLabel: node-exporter` on the vendored DS pods and `jobLabel: jobLabel` on its ServiceMonitor — target `job` comes from that pod label. The standalone node-exporter values replicate this exactly: `podLabels.jobLabel: node-exporter` + `prometheus.monitor.enabled: true` + `prometheus.monitor.jobLabel: jobLabel`. Key-shape trap: the standalone chart's SM block is `prometheus.monitor.*` — there is **no top-level `serviceMonitor.enabled`** in the 4.57.0 chart. ksm's SM needs no extra labels (its `app.kubernetes.io/name` jobLabel is the standalone default and matches kps behavior).
- Transition landmines (full story: [policies-config/README.md](../policies-config/README.md)): the node-exporter PolicyException must match **both** DS name prefixes before the kps upgrade lands (narrowing it first wedged the old release and every rollback), and the standalone DS's hostPort 9100 conflicts with the vendored DS's until the kps upgrade deletes the vendored one — the new pods sit Pending on `didn't have free ports` during the overlap.

## What's CR-managed vs helm values

- **grafana (`Grafana` CR), thanos query/compact/store/ruler (`Thanos*` CRs), alertmanager (`Alertmanager` CR)** → `observability-config/`. Resources/securityContext go in the CR specs (`resourceRequirements`, `securityContext`, per-component `podSecurityContext`/`containerSecurityContext`).
- The kps chart's alertmanager component is **disabled** (Alertmanager is CR-managed) — consequence: the Prometheus CR's `spec.alerting` must point at `alertmanager-operated.observability:9093` via `alertingEndpoints`, or the entire kubernetes-mixin rule set is evaluated but **never delivered** (only thanos-ruler alerts would reach mailpit). Same endpoint pattern as `main.thanos-ruler.yaml`.
- `prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false` is load-bearing — the chart default required a `release:` label only the stack's own SMs carried, leaving kyverno/thanos/velero SMs unscraped. Chart gotchas: `serviceMonitorSelector: {}` directly **doesn't work** (empty map is falsy → falls back to the release label), and cilium's `validate.yaml` gate refuses to render SMs without `prometheus.serviceMonitor.trustCRDsExist: true` (safe: prometheus-operator-crds ships the CRDs). Per-chart SM key shapes differ (alloy top-level, loki under `monitoring:`, cilium needs `metrics.enabled` too) — verify each by rendering with `helm_verify`.

## thanos-operator: bundle, not chart

Deployed from the repo's `bundle.yaml` via Kustomization — the helm chart embeds ~2.5MB of CRDs and blows helm's 1MB release-secret cap (strategy ladder: [runbooks/local/adopting-a-chart.md](../../runbooks/local/adopting-a-chart.md)). GitRepository commit and quay image tag (`main-YYYY-MM-DD-<shortsha>`) bump in lockstep.

- **Status conditions are the health signal** since thanos-community/thanos-operator#636: a single recoverable `Ready` condition (the old sticky `ReconcileSuccess`/`ReconcileFailed` pair could read True simultaneously). `observability-config.yaml` gates all four thanos CR kinds via `healthCheckExprs` on `Ready`. Semantics: empty conditions pass vacuously; a denied StatefulSet (missing resources) flips the CR to `Ready=False` within seconds — recipe for verifying operator condition behavior: scratch `ThanosStore` without `resourceRequirements` (needs `spec.shardingStrategy` too), watch denial → recovery.
- **Bundle Namespace label clobber**: the bundle ships `Namespace: thanos-operator-system`, renamed onto `observability`; both `namespaces` and `thanos-operator` apply it as the same SSA field manager, so the load-bearing PSS labels are mirrored into the kustomization's strategic-merge patch (otherwise whichever reconciles last prunes them — kps node-exporter then dies on PSS admission, invisible to kyverno). Full mechanism: [runbooks/local/namespace-migration.md](../../runbooks/local/namespace-migration.md).

## Ruler alerting (thanos-ruler)

- **One data key per rule ConfigMap — the thanos-operator skips ConfigMaps with more than one** (`skipping invalid config map`, `len(cfgmap.Data) != 1` gate in the ruler controller's `getRuleConfigMaps`): adding a second rule file to an existing rule configMapGenerator **silently unloads ALL ruler rules** — `numFiles:0` in thanos-ruler logs, no error anywhere, reconciles stay green. Rule: one configMapGenerator entry per rule file, each labeled `operator.thanos.io/rule-file: "true"` (see `observability-config/kustomization.yaml`, cmdshift/platform#85).
- **SLO rule template**: `observability-config/slo.rules.yaml` is the copy-for-the-first-real-service shape (cmdshift/platform#85) — recording rules `slo:<service>:<sli>:rate<window>` (windows 5m/30m/1h/6h), multiwindow multi-burn alert pairs (fast 5m+1h > 14.4× budget → critical, slow 30m+6h > 6× → warning; no `for:` — the pair `and` sustains it), 99.9% budget → thresholds 0.0144/0.006. **Underscores everywhere in the names**: classic Prometheus metric names cannot contain `-` — `slo:cilium-datapath:...` passes `promtool check rules` (check-lint doesn't validate the record-name charset) but every query of the series fails with a parse error.
- **SLO alert routing**: alerts carry `slo: "true"`, matched by the child route in `mail.alertmanager-config.yaml` (groupBy [alertname], groupInterval 1m, repeatInterval 1h, same email receiver). The prometheus-operator injects no namespace matcher on that AlertmanagerConfig (same namespace as the Alertmanager CR), so thanos-ruler alerts without a namespace label match fine.
- **Rule-file verification without a shell**: the prometheus pod is distroless (no shell, no tar, `kubectl cp` fails) — download promtool to /tmp and run `check rules` / `test rules` host-side. Gotchas for the test series: a counter that jumps then goes FLAT yields rate 0 again (sustain the increment), and `a+bxN` produces N+1 points. Live-validate expressions with `prometheus_query` before pushing; unit tests are throwaway.
- **Ruler alerting depends on the query seeing the prometheus head** — the sidecar endpoint is wired manually via `additionalArgs` in `main.thanos-query.yaml` (label-based discovery can't see the chart-managed discovery service). If ruler rules silently never fire, check `prometheus_query --query 'count(kube_pod_container_status_restarts_total)'` against the query svc — empty means the head path is broken again.
- **Store-path stale-IP window** (not a CNP block): a stale SRV-resolved store pod IP makes the query fail WHOLE requests (even head-only rules) until it re-resolves — ruler logs `no query API server reachable`; dial-test the store IP from the query pod (`wget http://<store-ip>:10902/-/ready`) before suspecting policy.
- Alert delivery: ruler → alertmanager (CR) → mailpit (**http://mail.cloud.test**). AlertmanagerConfig child-route `matchers` are structured `{name, value}` objects, not PromQL strings; receiver names that look like YAML nulls must be quoted — both hit live in `mail.alertmanager-config.yaml`.
- **One-shot counter spikes don't page**: `TetragonEnforcementKill` (defined in `observability-config/thanos-rules.yaml`) carries `for: 5m` — a cluster rebuild's bootstrap generates 3-5 runc pre-exec fork kills in the deny-list namespaces, which used to fire a critical alert that self-resolved minutes later (cmdshift/platform#60). Corollary: a counter that materializes at series start (like `tetragon_policy_events_total`) reads 0 under `increase(...[24h])` after the burst — post-hoc alert forensics go through `tetra getevents -o json`, not the metric's history. Attribution details: [security/README.md](../security/README.md).
- **Velero backup-alert rules** (`observability-config/thanos-rules.yaml`, `backup-alerts` group, cmdshift/platform#111) — two counter/gauge semantics that cost live outages:
  - **PartiallyFailed lives in `velero_backup_partial_failure_total`, not `..._failure_total`** — a schedule backup with failed PodVolumeBackups lands `PartiallyFailed`, so a rule watching only `velero_backup_failure_total` is blind to exactly the failed-volume-data state it exists for. `VeleroBackupFailed` ORs both counters (critical, no `for:` — fires within one evaluation, ~1m).
  - **`velero_backup_last_successful_timestamp` materializes only after a first Completed backup** — velero computes the gauge from Backup CR completion timestamps; before any success the series is absent, `time() - gauge` matches nothing, and a stale-backup alert built on it can never fire in the never-succeeded state. **Timeless rule: any alert built on a gauge that materializes only after a first success needs an `absent()` arm.** `VeleroBackupStale` has it (+ `for: 1h`).
  - `VeleroRepoMaintenanceFailed` (`velero_repo_maintenance_failure_total`, 2h window, warning, `for: 15m`) watches kopia maintenance failures — an admission-blocked maintenance fleet increments the counter and is caught in ~2h instead of at the next manual look.
- kube-proxy is gone from the cluster (cilium KPR=true + Talos `proxy.disabled`, cmdshift/platform#70) — kps runs `kubeProxy.enabled: false` (chart 89.2.1 single switch: drops the dead-target ServiceMonitor and the kube-proxy rule set). The old terraform `metrics-bind-address` arg (cmdshift/platform#23) and the monitoring CNP's 10249 egress rule are deleted with it.
- InfoInhibitor is disabled (`defaultRules.disabled.InfoInhibitor: true`) — the chart's built-in `inhibit_rules`, its only consumer, are not loaded by the CR-managed Alertmanager config (`alertmanagerConfiguration: mail`), so the meta-alert delivered pure spam to mailpit and muted nothing (cmdshift/platform#114). Watchdog stays enabled — it is the alerting-pipeline heartbeat. Rule: check what actually consumes a chart rule before accepting it.

## Quota defaults: LimitRange/compute-defaults

`observability-config/limit-range.yaml` sets Container defaults (limits 200m/64Mi, requests 10m/24Mi — sized from the config-reloader ~18Mi/10m audit) in the `observability` namespace. It exists for the **quota-vs-exception gap**: ResourceQuota admission is not skipped by kyverno PolicyExceptions, so the thanos-operator's config-reloader sidecar (no resources, no CRD knob, PolicyException-exempt) still fails the `compute` quota's must-specify-limits check — LimitRange is the only defaults source for exception-exempt containers. The operator injects the sidecar into every thanos pod, so any namespace hosting thanos CR-managed pods needs this. Full mechanics: [runbooks/local/adding-a-workload.md](../../runbooks/local/adding-a-workload.md) (cmdshift/platform#111).

Two `ResourceQuota/compute` objects in one namespace would both charge every pod (and kustomize refuses the duplicate id), so the former `logging` quota merged in renamed: `observability-config/logging-resource-quota.yaml`, name `logging-compute` (cmdshift/platform#120).

## Dashboards

`platform-deployment.grafana-dashboard.yaml` is the in-repo pattern: JSON in `platform-deployment.dashboard.json`, wired via configMapGenerator (`disableNameSuffixHash: true`) + `spec.configMapRef`; `url:` reserved for mirrored upstream dashboards. **The operator does not watch the ConfigMap** — JSON edits propagate on resync (`resyncPeriod: 5m` + `contentCacheDuration: "0s"`; the field is a string); metadata-only CR changes are filtered out, bump a `spec` field to force propagation. The log-filter strip is a markdown text panel whose preset links set `var-log_filter` via URL (Grafana pins variables to the toolbar; URL-param links are the only mid-canvas filter control).

**PromQL landmines against kube-state-metrics v2** (all verified live, all cost debugging rounds):

- `kube_pod_spec_volumes_persistent_volume_claim*s*_info` — v2.20 emits `persistentvolumeclaims` (no underscores); the v1 name is absent.
- `kube_replicaset_owner` has no `deployment` label — Deployment→pod mapping needs `label_replace` overwriting `owner_name` with the RS name to line up the join keys (quoted label args).
- **Chained vector joins silently return empty** — the second `on()` group must be parenthesized; `sum by` must keep the outer join key. No error anywhere; panels just render empty.
- **Grafana `label_values()` variable queries are selector-only** (`/api/v1/series match[]`) — joins fail with a parse error and dependent panels silently show nothing; chain hidden selector-only variables instead (order in `templating.list` matters). Panel queries are unaffected.
- The deployment variable uses a sentinel (`includeAll` + `allValue: "__none__"`) — Grafana auto-selects the first value of a query variable, so an empty `current` doesn't stay empty.
- Logs panel takes a full LogQL pipeline via a textbox (`{...} $log_query`); the html-mode preset strip needs `GF_PANELS_DISABLE_SANITIZE_HTML=true` (repo-authored content only).

## JSON logging knobs (observability components)

prometheus `prometheusSpec.logFormat: json`, prometheus-operator `logFormat: json`, alertmanager CR `spec.logFormat: json`, thanos CRs `additionalArgs: [--log.format=json]` (verified against on-cluster CRDs), grafana `GF_LOG_CONSOLE_FORMAT=json` env (**the operator's webhook rejects `spec.config.log.console`**, and grafana 13 ignores `[log] format` — the knob is `[log.console]`, override via env). Full sweep table below.

## Log-format sweep (source-side JSON conversion)

Method that worked: **binary `--help` via kubectl exec is authoritative** — chart-values greps miss nested/renamed keys.

| App | Knob | Where |
|---|---|---|
| loki | `global.extraArgs += -log.format=json` | `loki-values.yaml` |
| prometheus / prometheus-operator | `prometheusSpec.logFormat` / `prometheusOperator.logFormat` | kps values |
| alertmanager (CR) | `spec.logFormat: json` | observability-config |
| thanos ×4 | `additionalArgs: [--log.format=json]` | observability-config CRs |
| velero | `configuration.logFormat: json` | velero values |
| grafana | `GF_LOG_CONSOLE_FORMAT=json` env (webhook rejects `spec.config.log.console`) | observability-config CR |
| kyverno | `features.logging.format: json` (**nests under `features:`** — top-level and `config.logging` render text silently) | kyverno values |
| grafana-operator | `logging.encoder: json` (`--zap-encoder`) | grafana-operator values |
| seaweedfs-operator | `--zap-encoder=json` via HelmRelease **postRenderers** (no args knob; container is `seaweedfs-operator`, not `manager`) | objects |
| metrics-server | `args += --logging-format=json` | metrics-server values |
| flux, trivy-operator, external-secrets, thanos sidecar, tetragon | already JSON | — |
| cilium, cert-manager, local-path, seaweed weed, kubelet-csr-approver | **no knob exists** (verified via `--help`) — the pipeline's normalize stage converts | — |

## The alloy pipeline (`config.alloy`)

- **k8s properties are stream labels**: `discovery.relabel` promotes `__meta_kubernetes_{namespace,pod_name,pod_container_name,node_name}` to `namespace`/`pod`/`container`/`node` — same cardinality as `instance` (`ns/pod:container`, kept for dashboards), so `{namespace="observability", pod=~"grafana-.*"}` selects natively.
- **Every line in Loki is JSON**: JSON lines pass through; logfmt lines convert; plain-text falls back to `{"msg": raw}`. `stage.decolorize` strips ANSI codes first (preventive — escapes would otherwise end up embedded in JSON string values). There is no generic format-to-JSON stage in alloy (pack is the only wrapper and it double-encodes), so conversion happens at the source where a knob exists.
- **`stage.pack` was removed on purpose**: `loki.source.kubernetes` only emits `instance`/`job`/`service_name`, so the pack carried no metadata and just wrapped every line as `{"_entry":"<original>"}` with apps' JSON nested-and-escaped inside. Lines are app-native now; expected `alloy_components` set: `discovery.kubernetes.pods` + `loki.source.kubernetes.pods` + `loki.write.endpoint` (no `loki.process`).
- **The `alloy.configMap` values block is load-bearing** — omitting it makes the chart **silently install its example config** (pods healthy, no push, zero errors; the kustomize-generated `alloy-config` CM sits unreferenced). Fingerprint + triage: [runbooks/local/incidents.md](../../runbooks/local/incidents.md) (cmdshift/platform#27).

## Audit log pipeline (cmdshift/platform#90)

The ctrl node's kube-apiserver writes node-local audit logs (the reviewed 9-rule policy; policy body + Talos 1.13/1.14 placement story in `cluster/local/nodes/files/audit-policy.yaml` and the machine-config docs). Alloy scrapes them on ctrl into Loki with `job="audit"`:

- **"Who deleted that PVC at 3am"** = `loki_query '{job="audit"}'` — audit streams ride the existing 30d `limits_config.retention_period`, no separate tenant.
- **Volume control lives in the audit policy, not Loki**: with the reviewed policy alone ingestion jumped from the ~4.5KB/s baseline to ~2MB/s, dominated by `coordination.k8s.io/leases` heartbeats (74 of the first 100 events). A `none` rule for leases + tokenreviews cut it ~97% to ~60KB/s. Rule ordering matters: the machine-heartbeat `none` rule must sit BEFORE the Metadata catch-all (rules are first-match-wins).
- **Ctrl-taint scheduling**: alloy tolerates `node-role.kubernetes.io/control-plane:NoSchedule` — until this change the DS was 4/5 by design (workers only). The other two ctrl-only requirements (Talos API image-pull namespace allowance, `DAC_READ_SEARCH` on the audit dir) are PodSpec/PolicyException-side, not config-side — see [runbooks/local/adding-a-workload.md](../../runbooks/local/adding-a-workload.md) for the ctrl-scheduling pattern.
- **River gotchas hit on the audit stages**: map literals need a trailing comma after EVERY attribute (`{ __path__ = "...", job = "audit", node = sys.env("..."), }`); `env()` is deprecated/removed in alloy v1.19.x — `sys.env()` is the replacement (validation error otherwise).

## Loki decisions

- **Retention**: `limits_config.retention_period: 30d`, compactor `retention_enabled` + `delete_request_store: s3`. Loki 3.x timing knobs shortened locally for observable feedback (`delete_request_cancel_period` 24h→15m, `retention_delete_delay` 2h→5m — marked `# true in the cloud`; **keep upstream defaults in the cloud**).
- **Delete path runs through seaweed** (`main-s3.objects.svc:8333`): the loki S3Policy grants `s3:DeleteObject` on the loki buckets (`loki`, `loki-rules` — cmdshift/platform#125); the delete-request store round-trips sigv4 through seaweed. Open observable: a real S3 `DeleteObject` round-trip = `loki_compactor_deleted_lines_total` appearing in Prometheus.
- **Loki ruler rules** (`loki-rules.yaml`): delivered via the `loki-rule` configMapGenerator in `observability/kustomization.yaml` — the chart's kiwigrid sidecar (env `LABEL=loki_rule`) watches ConfigMaps labeled **`loki_rule: "true"` (underscore — must match the sidecar's LABEL env exactly; a `loki-rule` dash label matches nothing and the ruler silently runs zero rules, hit live cmdshift/platform#120)** and mounts them into `/etc/loki/rules`. The generator is load-bearing delivery config, not dead config.
- Tetragon rule/alert queries benefit from the same stream labels: `{namespace="security", pod=~"tetragon-.*"}`.
- Tenant `self-monitoring` is the default (alloy's `loki.write` tenant; the gateway's default too) — the queries in `loki_query` ride it.

## Operational landmines (loki + alloy)

- **Ingestion triage**: the components API (`alloy_components`) is the source of truth for what config alloy is running. Red herring: `loki_distributor_lines_received_total` is absent from loki-0 `/metrics` even when healthy (kafka/async counters materialize on first use) — live-traffic counters are `loki_distributor_bytes_received_total{tenant=...}`, `loki_ingester_memory_chunks`, `loki_write_sent_bytes_total` (alloy side). jq trap: `query_range` entries live in `.data.result`, not `.data.streams`.
- **River comments are `//`, not `#`** — a `#`-commented config crashloops the pods at load (`illegal character`); the rolling update keeps old pods serving, so no ingestion gap.
- **ConfigMap content edits may not reach pod volume mounts** (observed 5+ min stale after an in-place CM update) — `kubectl -n observability rollout restart daemonset/alloy`.
- **Seaweed volume exhaustion** shows up as loki flush failures (`S3: PutObject ... 500`, master: `Not enough data nodes found!`) — sizing and the read-only-volume mechanism in [objects/README.md](../objects/README.md); post-mortem in [runbooks/local/incidents.md](../../runbooks/local/incidents.md).

## VPA: recommendations only, never mutation

All VPAs are **Off mode**. The chart runs the recommender only (`updater` + `admissionController` disabled), so there is no mutating webhook and pods are never mutated — manifests stay authoritative and the recommendations are pure sizing evidence (cmdshift/platform#62). The HelmRelease sets `install.crds: Create` / `upgrade.crds: CreateReplace` because the chart ships its CRDs in the `crds/` dir (install-only, never in the release secret — the 1MB cap is a non-issue).

- **The recommender floors are lowered** to `pod-recommendation-min-cpu-millicores: "2"` / `pod-recommendation-min-memory-mb: "10"`: the defaults clamp every pod recommendation UP to 15m CPU / 100Mi — far above this cluster's 10-50m CPU / 32-96Mi workloads, so small pods would get dishonest numbers.
- **Never run `helm test` on the vpa release** — the chart renders three `helm test` Pods (hook-annotated, so they exist only if someone runs `helm test`) with no resources and no values knob; kyverno would deny them.

## goldilocks: automatic VPA maintenance

The controller creates and maintains an Off-mode VPA for every workload outside the system namespaces (`controller.flags`: `on-by-default: "true"` + `exclude-namespaces: "kube-system,flux-system"` — 48 VPAs on first pass). Read the recommendations with `vpa_recs` (the evidence side of sizing; `request_audit`/`memory_audit` are the usage side — [tools/bin/README.md](../../../tools/bin/README.md)). **A recommendation is a P99-shaped candidate request, not a drop-in** — cross-check against the usage audits and the sizing convention before editing manifests: the resource-sizing skill / [runbooks/local/memory-sizing-audit.md](../../../runbooks/local/memory-sizing-audit.md).

- **Chart `flags` maps are schema-less** — unknown keys are silently dropped. goldilocks' old `--vpa-object-mode` flag was removed upstream while the values key would have kept flowing; verify flag names against the image before wiring: `docker run --rm --entrypoint /goldilocks us-docker.pkg.dev/fairwinds-ops/oss/goldilocks:<tag> controller --help`.
- **The image home is us-docker.pkg.dev** (the `gar` entry in the caching proxy's upstream map) — images moved there at v4.15+; `quay.io/fairwinds/goldilocks` is stale (tops at v4.6.0).
- The dashboard is **server-rendered HTML** — namespace list at `/namespaces`, per-namespace pages at `/dashboard/<ns>`; there is no JSON API. Exposure is ad-hoc: `kubectl -n kube-system port-forward svc/goldilocks-dashboard 8080:80`.

Cloud: the manifests port as-is, including the lowered recommendation floors — [manifests/cloud/notes.md](../../cloud/notes.md).
