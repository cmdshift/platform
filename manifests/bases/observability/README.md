# observability

grafana-operator, loki, **alloy-logging** (logs/audit) + **alloy-telemetry** (the sole metrics scraper and OTLP trace receiver since cmdshift/platform#146), **tempo**, **mimir** (raw metrics store, cmdshift/platform#128), a chart-managed Alertmanager, and the sizing stack (metrics-server, vpa, goldilocks — all three install into kube-system but their HelmReleases/values live here by domain) + `observability-config/` (alert routing, dashboards, quotas, the alloy-telemetry RBAC). kube-prometheus-stack was removed in cmdshift/platform#141, and cmdshift/platform#146 completed the arc: the opentelemetry-operator + collector CR and prometheus-operator-crds are GONE — no SM/PodMonitor CRDs exist, every scrape target is hand-expressed in `alloy-telemetry.config.alloy`. The former collector sections remain below as history/precedent. Namespace layout rationale (cmdshift/platform#120): the former `metrics`/`monitoring`/`logging` groups collapsed into one — the `logging → dependsOn: monitoring` edge existed only because `loki.grafana-datasource.yaml` needed the grafana-operator CRDs, and the merge dissolves it.

## Prometheus removed → collector → alloy: the scrape-path history

The path was: kps (removed #141) → OTel collector + target allocator reading ServiceMonitor CRs (#141) → **alloy hand-expressing every target (#146, Option B — SM CRDs deleted, no discovery layer left)**. The #141 trap list is kept for the chart-decomposition precedent (the same classes of trap apply to any operator-generated scraper):

- **`.spec.mode` is immutable** (operator webhook): deployment→statefulset is delete-and-recreate, and TA only supports statefulset pools. The rejection message names the OLD mode — don't read it as "statefulset rejected".
- **TA pod inherits nothing from the collector spec**: securityContext/resources had to be set explicitly or kyverno Deny-mode rejected the operator-generated Deployment. The TA SA needed its own ClusterRoleBinding plus CRD-watcher informer RBAC.
- **kubelet auth is SAR-based for SA tokens**: `nodes/metrics` (+`nodes/proxy`/`stats`/`log`) get verbs are required — `kubectl auth can-i get nodes/metrics --as=...` is the direct probe. The apiserver `/metrics` is a non-resource URL: `nonResourceURLs: ["/metrics"]` get in the ClusterRole (carried into `alloy-telemetry.rbac.yaml`).
- **prw exporter semantics**: the collector treated 429 as PERMANENT (drops the batch) — mimir `limits.ingestion_rate`/`ingestion_burst_size` absorb the whole-cluster snapshot (40000/400000). Alloy's remote_write has queueing semantics; the mimir headroom stays.

## Mimir: the raw metrics store (cmdshift/platform#128)

Thanos (operator + Query/Ruler/Store/Compact CRs) was replaced by a hand-rolled monolithic Mimir StatefulSet — no chart, plain manifests in this dir: `mimir.statefulset.yaml` (image `grafana/mimir:3.2.0`, `-target=all`, replicas 1, 10Gi local-path volumeClaimTemplate), `mimir.config.yaml` (mounted CM), `mimir.service.yaml` (ClusterIP `mimir:8080` + headless for memberlist self-join), `runtime.yaml` (empty `{}` CM), `mimir-s3-credentials.external-secret.yaml`. Blocks go to seaweed (new `mimir` IAM quartet in `objects-config/`).

- **No downsampling** (grafana/mimir#1834, maintainer-confirmed): the thanos 5m/1h tiers have no equivalent — retention is flat raw-only, `-compactor.blocks-retention-period=168h`.
- **The retention flag is CLI-only in 3.2.0**: `-compactor.blocks-retention-period` has no yaml equivalent — the docs list `compactor_blocks_retention_period` (flat) and the chart shape nests it, but the Go struct rejects both (`field not found in type mimir.Config` / `compactor.Config`). Always an arg on the StatefulSet.
- **Config gotchas** (all hit live): `blocks_storage.s3.bucket_name` (not `bucket`); `compactor.data_dir` must not overlap `blocks_storage.tsdb.dir` (validation rejects `/data` for both — `/data/compactor` is scratch only); the `runtime_config` file must exist at startup (empty `{}` runtime CM); the prometheus query API serves under the **`/prometheus` prefix** and every query needs `X-Scope-OrgID: self-monitoring`; `alertmanager_url` is `http://alertmanager.observability.svc:9093` (chart service, cmdshift/platform#141).
- **Ruler is the local-backend kind**: `ruler_storage.backend: local` scans `<dir>/<tenant>/*.yaml`, so rule ConfigMap keys are remapped via subPath `items` into `self-monitoring/` (ConfigMap keys can't contain `/`). Rules live in this group (`mimir-rules.yaml`, `slo.rules.yaml`) — kustomize can't reference files above the group dir (flux's `LoadRestrictionsNone` builds `../` fine, but plain `kubectl kustomize` on a group dir fails; keep files local). The thanos-operator's one-data-key-per-rule-CM rule is obsolete — mimir's local backend reads the whole mount.
- **Sizing**: 1280Mi req / 1920Mi lim after the cmdshift/platform#141 dual-push OOM (was 768Mi/1Gi, OOMKilled at the parity window) — ingester WAL is the memory spike case, cmdshift/platform#83 playbook. Runs as 65532, roFS, seccomp RuntimeDefault, caps ALL dropped, TGP 90.

## OpenTelemetry collector (removed in cmdshift/platform#146; scraper #141-#146)

Deleted with the Option B cutover: `opentelemetry-operator.helm-release.yaml`, the `OpenTelemetryCollector` CR, its rbac, and the `prometheus-operator-crds` release (SM/PodMonitor CRDs included — the collector was their only consumer). Kept as precedent:

- **v1beta1 `spec.config` is a structured object** — v1alpha1 took a string; the schema rejects the string form (`cr_validate` catches it).
- **`collectorImage` must be `opentelemetry-collector-contrib`** — the chart's default `opentelemetry-collector-k8s` image lacks the prometheusremotewrite exporter (`unknown type` at startup).
- **k8sattributes RBAC**: a Role/RoleBinding (even RoleBinding→ClusterRole) did not take effect in the recreated-SA case — a dedicated ClusterRole+ClusterRoleBinding works. Don't burn time on the namespace-scoped path (cmdshift/platform#128).
- **The `name_validation_scheme: "utf8"` mimir flag stays** — dot-containing metric/label names (any component exporting them) 400-reject a whole push under the legacy scheme.

## alloy-telemetry discovery (alloy-telemetry.config.alloy, cmdshift/platform#146)

- **Multi-replica families scrape via the `endpoints` role, not `service`**: a service-role target is the ClusterIP — one address load-balanced across the DS/sts replicas, so per-node series (node-exporter, cilium-agent) silently collapse to one pod's. Endpoints role expands to one target per backing pod.
- **At endpoints role the port-name meta label is `__meta_kubernetes_endpoint_port_name`**, NOT `__meta_kubernetes_service_port_name` — reusing a service-role rule verbatim silently drops every target (the keep regex matches nothing; pods stay healthy). The label rename is the whole migration cost when flipping a family to endpoints role.
- **Config edits need an sts rollout restart to reach the pod** — see the alloy pipeline section for the fingerprint (hit live on the endpoints flip: new config shipped, old targets kept until restart).

## Tempo (traces) (cmdshift/platform#83)

- **Chart values traps**: the tempo chart's `persistence` is a **top-level** values key — nesting it under `tempo:` silently renders no volumeClaimTemplates (`helm template` catches it). The S3 config key is `forcepathstyle` (not `s3ForcePathStyle`), and env expansion needs `-config.expand-env=true` — set via `tempo.extraArgs: {config.expand-env: "true"}` (the chart renders the extraArgs map as `-key=value`).
- **Credentials flow** (same pattern as loki): secrets server `/www/observability/tempo-s3-credentials` → ExternalSecret `tempo-s3-credentials` → `extraEnvFrom` secretRef → `${TEMPO_S3_ACCESS_KEY_ID}`/`${TEMPO_S3_SECRET_ACCESS_KEY}` in values. Blockstorage backend is seaweed via a Bucket CR (`objects-config/tempo.s3-bucket.yaml`).
- **Beyla was removed (2026-09-18)** — the eBPF probes panicked the host kernel (7.2, the same constraint class as the cilium `1.21.0-pre.2` pin). The release, values, `allow-beyla-ebpf` PolicyException, and the beyla quota share are gone; the "Recent traces" dashboard panel and the tempo datasource stay (tempo is retained, traceless until instrumentation returns — any re-adoption must first verify host-kernel compatibility). Full post-mortem: [runbooks/local/incidents.md](../../../runbooks/local/incidents.md). Historical landmines from the adoption that still apply to any future eBPF workload: `contextPropagation.enabled: true` (chart default) forces `hostNetwork: true` → kyverno disallow-host-ports denial — privileged eBPF pods must mount tracefs in-namespace, and the observability CNP only allows host egress 10250/9100.
- **Sizing evidence**: tempo lean start validated 268-367Mi steady (768Mi request / 1Gi limit), CPU 150m→1000m.
- **Grafana wiring**: `observability-config/tempo.grafana-datasource.yaml` (`GrafanaDatasource` CR, type `tempo`, url `http://tempo.observability.svc:3200`); the `platform-deployment` dashboard has a `tempo_ds` datasource variable + a "Recent traces" traces panel (id 7, filters on `k8s.namespace.name=$namespace`).

## Decomposition: complete (cmdshift/platform#141, SMs hand-expressed in #146)

kps was fully removed in cmdshift/platform#141 (operator + Prometheus CR + generated SMs); #146 then deleted the SM/PodMonitor CRDs entirely — every chart's `serviceMonitor`/`prometheus.monitor` values block is stripped (alloy-telemetry hand-expresses the targets). The cmdshift/platform#69 partial-split mechanics below remain as precedent for chart migrations: node-exporter → standalone `prometheus-node-exporter@4.57.0`, kube-state-metrics → standalone `kube-state-metrics@8.5.0`.

- **Scrape-label mechanics (post-SM: selector logic moved into alloy)**: the kubernetes-mixin node rules select `job="node-exporter"`. The node-exporter values keep `podLabels.jobLabel: node-exporter` — alloy's `targets_node_exporter` discovery maps the target `job` from that pod label.
- **Chart metrics gates are NOT uniform** (hit live in #146): the cilium chart only renders the agent/operator metrics Services while `serviceMonitor.enabled` is true (`prometheus.metricsService` ANDs with the SM block) — stripping SM values alone deleted the services and zeroed both jobs; `metricsService: true` restores them. Check each chart's values shape before assuming `enabled: true` alone yields a service.
- Transition landmines (full story: [policies-config/README.md](../policies-config/README.md)): the node-exporter PolicyException must match **both** DS name prefixes before the kps upgrade lands (narrowing it first wedged the old release and every rollback), and the standalone DS's hostPort 9100 conflicts with the vendored DS's until the kps upgrade deletes the vendored one — the new pods sit Pending on `didn't have free ports` during the overlap.

## Alertmanager: chart-managed (cmdshift/platform#141)

The kps-operator-managed `Alertmanager` CR (and the `mail` AlertmanagerConfig child route) died with the operator; replaced by the `prometheus-community/alertmanager` chart (1.43.3, app v0.34.1), fullname `alertmanager`:

- **Config is raw Alertmanager YAML, not the CR spelling**: route keys are snake_case (`group_by`, `group_wait`, `repeat_interval` — camelCase fails the am config parse at startup, "field groupBy not found"), and sub-route matchers are STRINGS (`slo="true"`) — the AlertmanagerConfig CR used structured `{name, value}` objects. The chart's values.schema enforces the string form (`helm_verify` catches it).
- **A failed install keeps the bad release**: helm-controller's install remediation retries the same broken config; the values fix only lands after `helm uninstall` (or `flux suspend/resume` does not help). Symptom: the pod crashloops with the OLD error after the values were already corrected.
- The mail routing (root route + `slo="true"` child) lives inline in `alertmanager-values.yaml` `config:`; `alertmanager-operated` → `alertmanager` service name repointed in `mimir.config.yaml`, `loki-values.yaml`, and `flux-system.provider.yaml`.
- Hardening carries over: runAs 65534, roFS, caps ALL, seccomp RuntimeDefault, `automountServiceAccountToken: false` (am config reloads watch mounted files, never the API).

## What's CR-managed vs helm values

- **grafana (`Grafana` CR), the OpenTelemetryCollector (`OpenTelemetryCollector` CR)** → `observability-config/`. Resources/securityContext go in the CR specs (`resourceRequirements`, `securityContext`, per-component `podSecurityContext`/`containerSecurityContext`). Mimir is a plain StatefulSet (no chart, no operator); the Alertmanager is chart values (`alertmanager-values.yaml`). The former kps-era `serviceMonitorSelectorNilUsesHelmValues` and `alertingEndpoints` mechanics died with the Prometheus CR (cmdshift/platform#141); SM selection now happens in `targetAllocator.prometheusCR`.

## thanos-operator (removed 2026-09, cmdshift/platform#128)

The thanos-operator section is gone with the LGTM migration — Query/Ruler/Store/Compact are replaced by the monolithic mimir (above). Historical mechanics remain useful as precedent: the operator ran from its repo's `bundle.yaml` via Kustomization because its helm chart embedded ~2.5MB of CRDs and blew helm's 1MB release-secret cap (strategy ladder: [runbooks/local/adopting-a-chart.md](../../../runbooks/local/adopting-a-chart.md)), and its single recoverable `Ready` condition was the pattern `healthCheckExprs` gates were verified against. The leftover thanos CRDs needed a manual `kubectl delete crd` (the `crds` kustomization prunes with `prune: false`).

## Ruler alerting (mimir ruler)

- **SLO rule template**: `slo.rules.yaml` is the copy-for-the-first-real-service shape (cmdshift/platform#85) — recording rules `slo:<service>:<sli>:rate<window>` (windows 5m/30m/1h/6h), multiwindow multi-burn alert pairs (fast 5m+1h > 14.4× budget → critical, slow 30m+6h > 6× → warning; no `for:` — the pair `and` sustains it), 99.9% budget → thresholds 0.0144/0.006. **Underscores everywhere in the names**: classic Prometheus metric names cannot contain `-` — `slo:cilium-datapath:...` passes `promtool check rules` (check-lint doesn't validate the record-name charset) but every query of the series fails with a parse error.
- **SLO alert routing**: alerts carry `slo: "true"`, matched by the child route in `alertmanager-values.yaml` (config inline since cmdshift/platform#141 — the AlertmanagerConfig CR died with the operator; groupBy [alertname], groupInterval 1m, repeatInterval 1h, same email receiver).
- **Rule-file verification**: download promtool host-side (the mimir/prometheus images are distroless — no shell, no tar) and run `check rules` / `test rules`. Gotchas for the test series: a counter that jumps then goes FLAT yields rate 0 again (sustain the increment), and `a+bxN` produces N+1 points. Live-validate expressions with `prometheus_query --query` (mimir) before pushing; unit tests are throwaway.
- Alert delivery: mimir ruler → alertmanager (chart) → mailpit (**http://mail.cloud.test**). Raw-config child-route matchers are STRINGS (`slo="true"`) — the AlertmanagerConfig-CR `{name, value}` object form was valid only while the CR existed (hit live both ways, cmdshift/platform#85 and cmdshift/platform#141).
- **One-shot counter spikes don't page**: `TetragonEnforcementKill` (defined in `mimir-rules.yaml`) carries `for: 5m` — a cluster rebuild's bootstrap generates 3-5 runc pre-exec fork kills in the deny-list namespaces, which used to fire a critical alert that self-resolved minutes later (cmdshift/platform#60). Corollary: a counter that materializes at series start (like `tetragon_policy_events_total`) reads 0 under `increase(...[24h])` after the burst — post-hoc alert forensics go through `tetra getevents -o json`, not the metric's history. Attribution details: [security/README.md](../security/README.md).
- **Velero backup-alert rules** (`mimir-rules.yaml`, `backup-alerts` group, cmdshift/platform#111) — two counter/gauge semantics that cost live outages:
  - **PartiallyFailed lives in `velero_backup_partial_failure_total`, not `..._failure_total`** — a schedule backup with failed PodVolumeBackups lands `PartiallyFailed`, so a rule watching only `velero_backup_failure_total` is blind to exactly the failed-volume-data state it exists for. `VeleroBackupFailed` ORs both counters (critical, no `for:` — fires within one evaluation, ~1m).
  - **`velero_backup_last_successful_timestamp` materializes only after a first Completed backup** — velero computes the gauge from Backup CR completion timestamps; before any success the series is absent, `time() - gauge` matches nothing, and a stale-backup alert built on it can never fire in the never-succeeded state. **Timeless rule: any alert built on a gauge that materializes only after a first success needs an `absent()` arm.** `VeleroBackupStale` has it (+ `for: 1h`).
  - `VeleroRepoMaintenanceFailed` (`velero_repo_maintenance_failure_total`, 2h window, warning, `for: 15m`) watches kopia maintenance failures — an admission-blocked maintenance fleet increments the counter and is caught in ~2h instead of at the next manual look.
- kube-proxy is gone from the cluster (cilium KPR=true + Talos `proxy.disabled`, cmdshift/platform#70). The old terraform `metrics-bind-address` arg (cmdshift/platform#23) and the monitoring CNP's 10249 egress rule are deleted with it.
- The kubernetes-mixin defaultRules died with the kps Prometheus CR (cmdshift/platform#141) — the essential subset (Watchdog heartbeat, KubeNodeNotReady, KubeDeploymentReplicasMismatch, KubeJobFailed) was ported into `mimir-rules.yaml` (`kubernetes-mixin` group) and is evaluated by the mimir ruler; the remaining ~40 mixin groups were dropped deliberately (small single-node cluster, duplicate coverage from the custom alerts). ksm v2 trap on the port: `kube_job_status_stage` does not exist — `KubeJobFailed` uses `kube_job_status_failed > 0`.

## Quota defaults: LimitRange/compute-defaults

`observability-config/limit-range.yaml` sets Container defaults (limits 200m/64Mi, requests 10m/24Mi) in the `observability` namespace. It exists for the **quota-vs-exception gap**: ResourceQuota admission is not skipped by kyverno PolicyExceptions, so an exception-exempt container (no resources, no config knob) still fails the `compute` quota's must-specify-limits check — LimitRange is the only defaults source for exception-exempt containers. It was introduced for the thanos-operator's config-reloader sidecar (cmdshift/platform#111, ~18Mi/10m audit); the operator is gone since the LGTM migration (cmdshift/platform#128), but the LimitRange stays — any future exception-exempt container in `observability` depends on it. Full mechanics: [runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md).

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

alertmanager `extraArgs.log.format: json`, mimir `server.log_format: json` in `mimir.config.yaml`, grafana `GF_LOG_CONSOLE_FORMAT=json` env (**the operator's webhook rejects `spec.config.log.console`**, and grafana 13 ignores `[log] format` — the knob is `[log.console]`, override via env). Full sweep table below.

## Log-format sweep (source-side JSON conversion)

Method that worked: **binary `--help` via kubectl exec is authoritative** — chart-values greps miss nested/renamed keys.

| App | Knob | Where |
|---|---|---|
| loki | `global.extraArgs += -log.format=json` | `loki-values.yaml` |
| alertmanager (chart) | `extraArgs.log\.format: json` | `alertmanager-values.yaml` |
| mimir | `server.log_format: json` | `observability/mimir.config.yaml` |
| velero | `configuration.logFormat: json` | velero values |
| grafana | `GF_LOG_CONSOLE_FORMAT=json` env (webhook rejects `spec.config.log.console`) | observability-config CR |
| kyverno | `features.logging.format: json` (**nests under `features:`** — top-level and `config.logging` render text silently) | kyverno values |
| grafana-operator | `logging.encoder: json` (`--zap-encoder`) | grafana-operator values |
| seaweedfs-operator | `--zap-encoder=json` via HelmRelease **postRenderers** (no args knob; container is `seaweedfs-operator`, not `manager`) | objects |
| metrics-server | `args += --logging-format=json` | metrics-server values |
| flux, trivy-operator, external-secrets, tetragon, alloy | already JSON | — |
| cilium, cert-manager, local-path, seaweed weed, kubelet-csr-approver | **no knob exists** (verified via `--help`) — the pipeline's normalize stage converts | — |

## The alloy pipeline (`config.alloy`)

- **k8s properties are stream labels**: `discovery.relabel` promotes `__meta_kubernetes_{namespace,pod_name,pod_container_name,node_name}` to `namespace`/`pod`/`container`/`node` — same cardinality as `instance` (`ns/pod:container`, kept for dashboards), so `{namespace="observability", pod=~"grafana-.*"}` selects natively.
- **Every line in Loki is JSON**: JSON lines pass through; logfmt lines convert; plain-text falls back to `{"msg": raw}`. `stage.decolorize` strips ANSI codes first (preventive — escapes would otherwise end up embedded in JSON string values). There is no generic format-to-JSON stage in alloy (pack is the only wrapper and it double-encodes), so conversion happens at the source where a knob exists.
- **`stage.pack` was removed on purpose**: `loki.source.kubernetes` only emits `instance`/`job`/`service_name`, so the pack carried no metadata and just wrapped every line as `{"_entry":"<original>"}` with apps' JSON nested-and-escaped inside. Lines are app-native now; expected `alloy_components` set: `discovery.kubernetes.pods` + `loki.source.kubernetes.pods` + `loki.write.endpoint` (no `loki.process`).
- **The `alloy.configMap` values block is load-bearing** — omitting it makes the chart **silently install its example config** (pods healthy, no push, zero errors; the kustomize-generated `alloy-config` CM sits unreferenced). Fingerprint + triage: [runbooks/local/incidents.md](../../../runbooks/local/incidents.md) (cmdshift/platform#27).
- **A config-CM content change does not restart the alloy pods** (hit live on `alloy-telemetry`, 2026-09-24): the sts mounts the CM but the rendered pod spec is unchanged, so helm-controller rolls nothing — the pod kept scraping with the old config. After an edit, `kubectl -n observability rollout restart statefulset/alloy-telemetry` (the sts mount is read fresh at pod start).

## Audit log pipeline (cmdshift/platform#90)

The ctrl node's kube-apiserver writes node-local audit logs (the reviewed 9-rule policy; policy body + Talos 1.13/1.14 placement story in `cluster/local/nodes/files/audit-policy.yaml` and the machine-config docs). Alloy scrapes them on ctrl into Loki with `job="audit"`:

- **"Who deleted that PVC at 3am"** = `loki_query '{job="audit"}'` — audit streams ride the existing 30d `limits_config.retention_period`, no separate tenant.
- **Volume control lives in the audit policy, not Loki**: with the reviewed policy alone ingestion jumped from the ~4.5KB/s baseline to ~2MB/s, dominated by `coordination.k8s.io/leases` heartbeats (74 of the first 100 events). A `none` rule for leases + tokenreviews cut it ~97% to ~60KB/s. Rule ordering matters: the machine-heartbeat `none` rule must sit BEFORE the Metadata catch-all (rules are first-match-wins).
- **Ctrl-taint scheduling**: alloy tolerates `node-role.kubernetes.io/control-plane:NoSchedule` — until this change the DS was 4/5 by design (workers only). The audit dir is 0700 `65534:nogroup` with 0600 files, and alloy's host-log mounts run root without capabilities — root alone gets `Permission denied`; the container-level `DAC_READ_SEARCH` capability is what makes the read possible, with the mount read-only and `readOnlyRootFilesystem: true` preserved (alloy runs as root because the image declares no USER — the alloy PolicyException covers the run-as-nonroot deviation). The third ctrl-only requirement (Talos API image-pull namespace allowance) is PolicyException-side — see [runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md) for the ctrl-scheduling pattern.
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
- **Seaweed volume exhaustion** shows up as loki flush failures (`S3: PutObject ... 500`, master: `Not enough data nodes found!`) — sizing and the read-only-volume mechanism in [objects/README.md](../objects/README.md); post-mortem in [runbooks/local/incidents.md](../../../runbooks/local/incidents.md).

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
