# observability

OpenObserve is the observability stack (cmdshift/platform#171 — replaces the LGTM stack: mimir/loki/tempo/grafana + seaweedfs, which existed only to serve them; the `objects/` group went with it). The group keeps: **openobserve** (`openobserve-standalone` chart 1.0.1 — single node, SQLite metadata on local-path PVC, parquet data in rustfs S3), **two collector HelmReleases** from the plain `otel/opentelemetry-collector` chart 0.175.0 (agent DaemonSet + gateway Deployment — see below why two), and the sizing stack (metrics-server, vpa — both install into kube-system but their HelmReleases/values live here by domain). kube-state-metrics remains a standalone release (the agent collector's `clusterMetrics` preset bundles its own ksm; the gateway scrapes the standalone one). Alertmanager was removed (cmdshift/platform#182) — O2 native alerts deliver via O2's built-in SMTP directly to the mailpit companion.

Grafana is back (cmdshift/platform#196) as an operator-managed query UI **alongside** O2's own (cmdshift/platform#171 dropped it; the operator route + O2 plugin + Prometheus datasource made the return cheap) — gated by the `grafana-auth-proxy` cookie-gate ([access/README.md](../access/README.md)), identity is grafana's own login (admin creds from `secret/main-grafana-credentials`; the old auth.proxy header-passthrough stays retired — the phantom-user trap). Datasources: `openobserve-metrics` (native `prometheus` type at O2's `/api/default/prometheus`) and `openobserve-logs` (the **unsigned O2 plugin**, shipped in-tree via the `grafana-plugin-zo-gp` ConfigMap). Dashboards/alerts are still out of scope for grafana — the alerting story remains cmdshift/platform#206; the o2-sync Job (which GitOps-synced O2 dashboards, alert destinations, and alerts) was **removed on 2026-10-29** — OSS O2 has no CRDs/CLI/Terraform for them, and the Job had no successor; O2-native dashboards/alerts created in the O2 UI are **ephemeral** — any pod-churn PVC delete wipes them with no GitOps recovery.

**Store decision (cmdshift/platform#186, resolving #171's store gap)**: O2 is the queryable metrics AND log store — its Prometheus-compat API (`/api/default/prometheus/api/v1/...`, Basic auth, org hardcoded `default`, no `X-Scope-OrgID`) backs `prometheus_query` and `cpu_audit`'s throttle check, and its `_search` SQL API (same auth/org) backs `log_query` (cmdshift/platform#203 — replaced the retired `loki_query`). Tooling caveats: the OTel receiver translates standard target labels (`job` → `service_name`, `instance` → `service_instance_id`) while metric-defined labels survive; range-query history is sparse/blocky over long windows; all container logs land in the single `k8s_logs` stream (event fields INSIDE `body`, k8s identity as flat columns). Auth is the `O2_AUTH_BASIC` key of `secret/openobserve-credentials` — derived in the secrets-server payload from the root credential (no inlined tokens anywhere; [credentials](#credentials-secret-driven)).

Namespace layout rationale (cmdshift/platform#120): the former metrics/monitoring/logging groups merged into `observability` + `observability-config`.

## Architecture

```
workload logs/filelogs + host/kubelet/node metrics ─ agent DaemonSet ─┐
OTLP (traces, app metrics) ─────────────────────────── gateway Dep ───┤
prometheus scrape families (hand-expressed) ────────── gateway Dep ───┼→ openobserve :5080
                                                                        │   (SQLite meta on local-path,
thin detectors (stream+threshold) ──────────────────────────────────────┘    parquet in rustfs)
     │ O2 native alerts → O2 built-in SMTP (ZO_SMTP_* env) → :25 passthrough
   mailpit
```

- **`openobserve`** — `openobserve-standalone` 1.0.1, `fullnameOverride: openobserve`, PVC 5Gi local-path holds SQLite + WAL + query cache only (`ZO_LOCAL_MODE_STORAGE: s3` → rustfs `http://s3.cloud.test`, bucket `openobserve`, region `local`, path-style). Credentials via ExternalSecrets (`openobserve-credentials` root user + derived `O2_AUTH_BASIC` header, `openobserve-s3-credentials` S3 quartet) feeding `extraEnv` — the chart renders `auth.existingRootUserSecret` and empty `ZO_S3_*` placeholders; explicit env beats envFrom. An `emptyDir` at `/tmp` rides `extraVolumes` — O2 writes temp files there and the pod ships `readOnlyRootFilesystem: true` (cmdshift/platform#209: restart/recreate crashed without it).
- **`openobserve-collector` (agent, daemonset)** — filelog (pod logs), hostmetrics, kubeletstats, kubernetesAttributes, clusterMetrics presets; pushes to `http://openobserve.observability.svc:5080/api/default/` via `otlphttp`; all ingest ports closed (it receives nothing).
- **`openobserve-collector-gateway` (deployment)** — OTLP ingest 4317/4318 (traces + app metrics; the old tempo intake shape) + hand-expressed `prometheus` scrape_configs ported 1:1 from the deleted `alloy-telemetry.config.alloy` (job names are load-bearing — the o2 community dashboards/alerts select on them).
- **NOT the o2 `openobserve-collector` chart 0.5.0** — it requires the opentelemetry-operator, and there was no CRD-free path through it; the human rejected an operator for this. The plain `otel/opentelemetry-collector` chart has `mode` + `config` **release-global**, so one HelmRelease per mode: agent (daemonset) + gateway (deployment) are two releases in one file (`openobserve-collector.helm-release.yaml`).

## O2 chart landmines

- **The standalone chart's config CM is a HARDCODED KEY ALLOWLIST** — unknown `config.*` values are silently dropped (no error anywhere). Env-only flags must ride `extraEnv` (cmdshift/platform#171). The allowlist contains **ZERO SMTP keys** — all five `ZO_SMTP_*` settings (ENABLED/HOST/PORT/FROM_EMAIL/ENCRYPTION) ride `extraEnv` (cmdshift/platform#182); a `config:` attempt is silently dropped.
- **Alert delivery is O2 built-in SMTP, no alertmanager** (cmdshift/platform#182): the alertmanager HelmRelease/values were deleted; O2 emails destinations directly through the `ZO_SMTP_*` env to the mailpit companion (`ZO_SMTP_ENCRYPTION: ""` is the documented plain-SMTP mode — port 25, local relay). `ZO_SKIP_SSRF_CHECKS` was removed with it — no in-cluster webhook destinations remain; re-add it only if a destination ever points in-cluster again.
- **O2 email destination schema (chart 1.0.1)**: `{"name", "type": "email", "emails": [recipients], "template" (optional)}` — there are **NO per-destination SMTP fields**; transport is the global `ZO_SMTP_*` env. Recipients must be org members; the root user is implicitly a member, and the O2 root user is `admin@cloud.test` (one admin identity across rauthy + O2 — set in `cluster/local/secrets/locals.tf`).
- **The `POST /api/{org}/<stream>/_json` endpoint is LOGS-ONLY** (cmdshift/platform#182, cost multiple debugging rounds): seeding a *metrics* stream name through it materializes a phantom LOGS stream under the same name, which the v2 alerts API (binding on the alert's `stream_type`) still reports as `Stream not found` (404). Metrics streams must be seeded via `POST /api/{org}/ingest/metrics/_json` with body `[{"__name__":"<stream_name>","__type__":"gauge","value":0,"_timestamp":...}]` — `__name__` carries the stream name, `__type__` locks on the first record. Streams auto-create on first ingest of the correct type; a future sync mechanism (cmdshift/platform#206) must seed before alert creation, existence-gated via `GET streams?type=<type>` (metrics seed value 0 so no alert condition can fire on the seed). The mechanics are preserved here because the removed o2-sync Job's script encoded them and any #206 successor will need them again.
- **`ZO_COMPACT_DATA_RETENTION_DAYS` defaults to 3650** — a silent disk-full waiting to happen. Set `"10"` (cmdshift/platform#186, bumped from 3d: the vpa_recs/resource-sizing calibration wants ≥10d of trend history; disk gate checked first — the rustfs docker volume's host disk had 168GB free of 230GB). **Retention lives inside the compactor module** (`src/service/compact/retention.rs`) — compaction OFF silently disables data retention entirely (cmdshift/platform#182: `ZO_COMPACT_ENABLED` must stay true or retention is dead).
- **Image registry: point at the real home, never a façade** — `o2cr.ai` is a 302 redirect façade to `public.ecr.aws/zinclabs/openobserve`; docker CLI follows cross-registry redirects but **angos does not** (cache-miss returns `not found`; no redirect-following/host-override knob exists in angos v1.12.2 — checked docs+source). Values use `public.ecr.aws/zinclabs/openobserve` (the already-mapped `ecr` upstream); there is deliberately **no o2cr.ai stanza in `registry_map`** (`cluster/local/registry/locals.tf`). Applies to any future image whose host is a redirect façade.
- Chart pin: `openobserve-standalone` 1.0.1 — SQLite metadata migration chains break across minor bumps; test on a fork of the PVC before bumping (cmdshift/platform#171).
- **FSTree sizing** (cmdshift/platform#182): `ZO_MEMORY_CACHE_MAX_SIZE`/`ZO_MEMORY_CACHE_DATAFUSION_MAX_SIZE` are 1536/1536 and the disk cache (`ZO_DISK_CACHE_*`) is the relief valve — 1Gi of the 5Gi PVC, leaving the rest for SQLite + WAL. Memory caches compete with ingest for the same limit.
- **Pod annotations**: `backup.velero.io/backup-volumes-excludes: data` — the data PVC holds disposable SQLite metadata + WAL/parquet staging (data lives in rustfs; config is **ephemeral** until #206 restores a sync mechanism — see the o2-sync removal note above); backing it up live fails ~90% through with an empty data-path error and burns ~7GB of kopia churn per backup (cmdshift/platform#171).
- **Resources** (cmdshift/platform#182): request 500m CPU / 5Gi mem, limit 4 CPU / 7Gi mem. Lean request because the quota charges requests (the old 2-core request ate 2/3 of the 3-cpu budget) and O2 reads host cores anyway; the 4-core limit is the burst cap.

### openobserve-collector-agent (values decision table)

| value | why | ref |
|---|---|---|
| `mode: daemonset`, plain `otel/opentelemetry-collector` chart 0.175.0 | `mode` + `config` are release-global in the otel chart — one HelmRelease per mode; NOT the o2 `openobserve-collector` chart 0.5.0 (needs the opentelemetry-operator, rejected) | #171 |
| `presets.clusterMetrics` | k8s_cluster receiver → node conditions (`k8s_node_condition_ready` et al — the node_not_ready alert reads it); daemonset mode leader-elects so the 3 replicas don't duplicate | #171 |
| `clusterRole.rules` nodes/stats+proxy+metrics | kubeletstats with extra_metadata_labels needs nodes/proxy + nodes/pods beyond the preset's nodes/stats — utilization metrics only scrape on the /pods summary endpoint (403 without) | #171 |
| `securityContext.runAsUser: 0` + host access | allow-node-exporter-style host access (PolicyException `allow-openobserve-collector-host-access` covers admission); the daemonset mounts /var/log + /var/lib/docker/containers via the logsCollection preset | #171 |
| all ingest `ports` disabled | agent receives nothing — it pushes to openobserve; chart default jaeger/zipkin/otlp/prometheus receivers nulled for the same reason | #171 |
| `rewriteDeprecatedComponentNames: false` | without it the config uses modern names (filelog/k8sattributes/otlphttp) verbatim — pinned to the explicit names | #171 |
| computed utilization metrics opt-in (hostmetrics cpu/mem, kubeletstats `k8s.pod.*_utilization`) | stock presets ship them off; the o2 community dashboards/alerts read them | #171 |
| `kubeletstats.extra_metadata_labels` + `metric_groups` | metric_groups required for the summary API path the utilization metrics derive from (o2 chart ships node/pod/container/volume) | #171 |
| Basic-auth header via `${env:O2_AUTH_BASIC}` on `otlphttp` exporters | the header is NOT inlined in values (cmdshift/platform#209): `extraEnvs` injects `O2_AUTH_BASIC` from `secret/openobserve-credentials`, and the collector config expands `${env:…}` at startup — the chart's own defaults use the same interpolation (`${env:MY_POD_IP}`), so the #171 "chart exposes no env passthrough" claim was wrong. A credential change now only needs a collector rollout restart (ESO refreshes the secret automatically); no values re-encoding, no CM-digest dance | #209 |
| exporter `debug: null` | dropped the chart's default debug exporter (noise) | #171 |

### openobserve-collector-gateway (values decision table)

| value | why | ref |
|---|---|---|
| `mode: deployment`, OTLP 4317/4318 with hostPorts | OTLP ingest (traces + app metrics — the old tempo intake shape) + hand-expressed prometheus scrape families ported 1:1 from the deleted `alloy-telemetry.config.alloy`; job names are load-bearing for the ported alert rules + dashboards | #171 |
| `clusterRole.rules` services/endpoints/endpointslices/pods/nodes/namespaces | the prometheus receiver's kubernetes_sd needs discovery RBAC — the preset role only covers k8sattributes (pods); without it every scrape job resolves zero targets | #171 |
| `clusterRole.rules` nodes/metrics+proxy+stats + `nonResourceURLs: [/metrics]` | kubelet/cadvisor scrapes authorize via SAR on nodes/{subresource}; the apiserver /metrics job is a nonResourceURL | #171 |
| keep-rules select on `namespace;labels;port-name` | exactly as the old alloy keep-rules did (instance = release name is load-bearing); control-plane jobs keep the upstream chart wiring (scheme https, SA bearer token, port remap) | #171 |
| cadvisor job on the gateway | the agent already scrapes kubeletstats — cadvisor stays here (gateway) for the container_fs_* families the old config kept | #171 |
| cadvisor keep regex also passes the `container_cpu_cfs_*` families | `cpu_audit`'s throttle check reads `container_cpu_cfs_throttled_periods_total`; the fs-only keep dropped it. The cpu families ride the SAME regex (sequential keep rules are AND — a second keep rule could never see a series the first dropped) | #186 |
| gateway limits 1 CPU / 1536Mi | memory_limiter preset is 80% of the limit — keep headroom above WAL spikes | #171 |
| flux-controllers job selects on `__meta_kubernetes_pod_label_app` | flux pod templates carry only `app: <name>` (app.kubernetes.io labels live on the Deployment, not the pod); metrics port named `http-prom`; job name fed the o2-alerts-library fluxcd pack on gotk_resource_info (alerts removed with o2-sync — cmdshift/platform#206) | #182 |

### metrics-server / kube-state-metrics / vpa (values decision tables)

| value | why | ref |
|---|---|---|
| metrics-server `--logging-format=json` | JSON logging: platform convention (pre-OpenObserve ref removed) | #171 |
| metrics-server `runAsGroup: 1000` | `# NSA hardening:` explicit container-level uid+gid (chart SC is container-level; runAsNonRoot alone isn't enough) | NSA baseline |
| kube-state-metrics container uid/gid 65534 | `# NSA hardening:` explicit non-root uid/gid (image declares USER "nobody"); request 96Mi = 12h median 69Mi / max 79Mi × 1.2, limit 1.5× | NSA baseline |
| vpa `updater`/`admissionController` disabled | recommendation mode only — VPA never mutates pods or injects webhooks, so manifests stay authoritative and recommendations are pure evidence | #62 |
| vpa recommender floors 2m CPU / 10MB | chart defaults clamp recommendations UP to 15m CPU / 100Mi — lowered so this cluster's small pods get honest numbers; recommender 48Mi request (12h max 37Mi — old 128Mi was 3.4× peak), 200m limit (16% of CFS periods throttled — bursty recommend loops) | #62 |
| vpa `install.crds: Create` / `upgrade.crds: CreateReplace` | the CRDs ship in the chart's `crds/` dir — install-only, never in the release secret (1MB cap) | #62 |
| metrics-server/vpa HelmReleases live in the observability group, values CMs in kube-system | both install into kube-system (cluster plumbing); grouped by domain, not namespace | — |

## Sizing: the memtable/intervals evidence (cmdshift/platform#171)

First config burned **~830m sustained CPU** — bursty zstd dump/merge across all cores + 60s compaction cycles. Full decision tables live in the values files' README rows above; the historical evidence:

- **Memtable 768MB + 4Gi limit**: the default derives 25% of container mem_total (256MB at 1Gi) and ~1400 streams overflowed it on the first scrape cycle (`MemoryTableOverflowError` 503s); 256MB still overflowed at ~150/min. 768 + the 4Gi limit holds the working set with the thread caps.
- **Thread caps 2** (dump/move/merge) + **halved intervals** (retention 30s, file-push 60s, compact-interval 150s): doubling the frequency means smaller units of zstd/merge work — bursts cool between them instead of one core pinned for long stretches.
- **Query caches capped** (memory-cache 512, datafusion 256 — they compete with ingest for the same limit); **disk cache OFF** (duplicates rustfs reads, burns CPU on GC).
- Result: **~200m avg, 0 overflows, 100% 200s**. (The current shape supersedes these numbers — see the cmdshift/platform#182 bullet below; the sizing evidence lives in the values decision tables.)
- **Compaction is ON** (cmdshift/platform#182): an earlier "tuning" left `ZO_COMPACT_ENABLED` false, which silently disabled data retention entirely (retention lives inside the compactor module). Current shape: compact enabled, interval 600s, batch 50, fast-mode false, retention 10d (#186 — disk-gated bump from 3d, see the landmine above), `ZO_MAX_FILE_SIZE_ON_DISK: "16"`. The interval rides 600s (the values file's setting — the #182 "60s" wording here was stale against the live config); the #171 60s-cycle burn history is what argues against going BELOW it — the work set is now bounded by 10d retention; post-change openobserve sits ~120m CPU, well under the 2-core limit.

## Grafana (operator): wiring + landmines (cmdshift/platform#196)

- **File layout follows the #149 rule**: operator HelmRelease in `observability/`; `Grafana`, `GrafanaDatasource`, and the `main-grafana-credentials` ExternalSecret live in `observability-config/` (the grafana-operator chart ships its CRDs, so the CRs need the group that dependsOn the release).
- **The O2 plugin can't be fetched at runtime** — its upstream tarball is unversioned (`zo_gp/zo_gp.tar.gz`, pinned at sha256 `85e75427…`, published 2025-12-10) and a runtime fetch is impossible anyway: `curl`/`wget` are on the `deny-shell-entrypoint` binary list and the tetragon `exec-deny-list-observability-grafana` sibling kills them at runtime. The tarball therefore rides **in-tree as the `grafana-plugin-zo-gp` ConfigMap** (85KB binaryData, generator in `clusters/local/observability-config/`), and the init chain is two bare-exec steps (`mkdir -p`, then `tar -xzf`) — no shell, no net tool. `tar -C` needs the target dir to pre-exist; that's why the mkdir step exists.
- **Plugin update procedure**: replace `clusters/local/observability-config/zo_gp.tar.gz` (re-verify the tarball's `plugin.json` first), then **roll the grafana deployment** — the CM is `disableNameSuffixHash` (stable name referenced inside the `Grafana` CR; a hash suffix wouldn't be rewritten by kustomize there), so a content change does NOT trigger a roll (the CM-digest trap family). The init containers re-extract on every pod start, so a single rollout restart picks up the new tarball.
- **The plugin is unsigned and declares `grafanaDependency: "^9.3.8"`** while the operator deploys grafana 13.2.4 — observed behavior (2026-11-11): registered, enabled, queries work; no version gate fires. Grafana logs a benign "Permitting unsigned plugin" warning. Re-check both on any grafana/plugin bump.
- **Datasource health-check trap**: the logs datasource's `/health` API returns `500 plugin.unavailable` — the O2 plugin is frontend-only (no backend binary), so the health endpoint is not a failure signal. Verify the logs path through grafana's datasource proxy (`POST /api/datasources/proxy/uid/<logs-uid>/api/default/_search…`) or Explore.
- **`GrafanaDatasource.valuesFrom` mechanics** (cost two debugging rounds): the target node must already contain **placeholder text** that the operator string-replaces — set `basicAuthUser: $ZO_ROOT_USER_EMAIL` in the datasource model and let `valuesFrom` swap it from `secret/openobserve-credentials`; and `targetPath` is a JSONPath **relative to the datasource object** (`secureJsonData.basicAuthPassword`, not `datasource.secureJsonData…`). Placeholders are deliberately **unbraced** (`$KEY`, the operator's documented second form) because dryrun_check flags braced `${VAR}` survivors as unresolved flux tokens.
- **`NO MATCHING INSTANCES: true` is a latency state, not an error**: datasources can't match until the `Grafana` CR reaches `complete/success` AND their resync ticks (default 10m) — check the Grafana CR status before debugging the selector.
- **Admission constraints baked in**: the operator's generated grafana pod gets resources via the CR's container override, init containers carry their own (require-resource-limits), and everything passes `deny-shell-entrypoint`/`disallow-capabilities-strict`/NSA contexts. The grafana exec deny-list sibling (`exec-deny-list-observability-grafana`, restored with #196) selects the operator-generated `app: grafana` label.
- **Sizing**: lean starts carried from the previous grafana run (grafana 10m/320Mi req, 200m/480Mi lim; operator 48Mi — 7d peak 37Mi). Re-audit with `memory_audit`/`vpa_recs` after a day; both VPAs are Off mode.

## SQLite-on-local-path corruption: the MANDATORY pod-churn procedure

**Never force-delete the openobserve pod or live-patch it.** Four occurrences, same trigger every time (cmdshift/platform#171; upstream openobserve/openobserve#14590): an ungraceful pod replacement (helm upgrade → new checksum → SIGKILL) kills SQLite mid-write; every restart replays the dirty WAL and fails `stream cache failed: disk I/O error (6410)` at ~2s after start. A debug-pod dd test proved the volume writes 250MB/s — corruption is WAL state, **not the disk**. For ANY openobserve pod churn (upgrade that replaces the pod, recovery, config change forcing a restart):

```sh
flux suspend helmrelease openobserve
kubectl -n observability scale sts openobserve --replicas=0
kubectl -n observability delete pod openobserve-0        # graceful, not --force
kubectl -n observability delete pvc data-openobserve-0   # wipes the dirty WAL
kubectl -n observability scale sts openobserve --replicas=1
flux resume helmrelease openobserve
```

Metadata (users/dashboards/alerts) is disposable **when it can be re-created** — it lived in Git via the o2-sync Job until that was removed (2026-10-29, cmdshift/platform#206). Until a successor lands, a PVC delete wipes dashboards/alerts with **no recovery** — data itself survives in rustfs. If the O2 UI has accumulated dashboards worth keeping, export them from the UI before any pod churn.

## Credentials: secret-driven (cmdshift/platform#209)

The O2 root credential lives in exactly one place — the secrets-server payload `observability/openobserve-credentials` (`cluster/local/secrets/locals.tf`). Three derived keys share it:

- `ZO_ROOT_USER_EMAIL` / `ZO_ROOT_USER_PASSWORD` — the O2 root user (chart's `auth.existingRootUserSecret`).
- `O2_AUTH_BASIC` — `Basic + base64(email:password)`, **computed in terraform from the same locals** (never hand-typed; a credential change re-derives it on the next apply).

The `openobserve-credentials` ExternalSecret uses `dataFrom: extract`, so new payload keys appear in the k8s secret automatically (1m refresh) — no manifest change needed. Consumers:

- **Collectors** (agent + gateway): `extraEnvs` injects `O2_AUTH_BASIC` from the secret; the otlphttp exporter headers expand `${env:O2_AUTH_BASIC}` at collector startup. A credential change needs only a collector rollout restart — no values re-encoding, no CM-digest dance (the old inlined-header 401 trap is dead).
- **`prometheus_query` / `log_query`**: read the same key live from `secret/openobserve-credentials` (cache + 401-refetch-once).

## o2-sync: removed (2026-10-29, cmdshift/platform#206)

The o2-sync Job (`observability-config/o2-sync/`) synced dashboards, alert destinations, and alerts into O2 via REST — the ONLY GitOps path for them (OSS O2 has no CRDs/CLI/Terraform). It was removed with commit `5bb7c5a` ("remove o2-sync and apply advised settings for o2 cpu usage"), which also took the entire O2 alert set with it (19 detectors incl. the watchdog heartbeat + the o2-alerts-library flux pack) and left the `o2_sync` docker image dead (deleted with its terraform module in cmdshift/platform#209). The alerting story — restore a sync successor vs consciously retire — is #206's decision; the API landmines the Job's script encoded are preserved in the O2 chart landmines section above (logs-only `_json` seeding + v2 API path shapes) so a successor doesn't re-pay that debugging.

- The v2 alerts API path is `/api/v2/{org}/alerts` — **v2 nests BEFORE the org segment** (`/api/{org}/v2/alerts` 404s); list endpoints return `{"list":[…]}` wrappers.
- **Email destination schema**: one `email`-type destination, recipient `admin@cloud.test` (the O2 root user — implicitly an org member, which destination recipients must be).
- **CM last-applied cap** (~256KB, below) was discovered by a 420KB dashboard JSON failing the group dry-run — still applies to any future dashboard-carrying CM.

## otel collector: RBAC + opt-in metrics

- **kubeletstats with utilization metrics** needs `nodes/stats` + `nodes/proxy` + `nodes/pods` — without the proxy/pods pair the summary scrape 403s (`resource=nodes, subresource(s)=[pods proxy]`); the utilization metrics only derive from the `/pods` summary endpoint. The chart's `clusterRole.rules` **APPENDS to the preset rules** — add, don't replace.
- **apiserver `/metrics` scrape** needs `nonResourceURLs: [/metrics]` get (non-resource SAR — the kubelet-style rules don't cover it).
- **kubernetes_sd discovery** (the gateway's prometheus receiver) needs services/endpoints/endpointslices/pods/nodes/namespaces list+watch — the preset role only covers k8sattributes' pods; without it every scrape job resolves zero targets while the pod stays healthy.
- **Computed utilization metrics are OPT-IN** — stock presets ship them off: `system.cpu.utilization`/`system.memory.utilization` (hostmetrics receiver `metrics:` blocks), `k8s.pod.*_utilization` (kubeletstats `metrics:` block). The o2 community dashboards/alerts read them. `k8s_node_condition_ready` comes from the `k8s_cluster` receiver (clusterMetrics preset, **leader-elected in daemonset mode** so the replicas don't duplicate).

## valuesFrom staleness: the CM-digest trap

A values-ConfigMap-only change does **not** re-trigger helm-controller — the HR reconciles clean while `status.lastAttemptedConfigDigest` stays frozen at the old digest (the CM updated underneath it). Hit 4+ times during tuning. Verify:

```sh
kubectl get hr openobserve -o jsonpath='{.status.lastAttemptedConfigDigest}'
```

If it's stale after reconcile + requestedAt annotate (kubectl only — `flux annotate` doesn't exist; use `--overwrite` since the annotation carries a prior value), the fix is the suspend → `helm uninstall` → resume dance (or a full group bounce). When the pending rollout must not SIGKILL SQLite mid-write (openobserve itself), suspend FIRST, then annotate — the request is queued and processed on resume (cmdshift/platform#209 ran this successfully). `flux_triage` shows attempted-vs-applied revision lag to recognize the state; `helm_wait` for the per-release verdict. (The general ordering rule — `flux_wait` before `helm_wait` on values-only changes — lives in the `platform-workflow` skill.)

## ConfigMap size caps: two different limits

- **~256KB last-applied annotation cap (kustomize-controller)**: its client-side-apply dry-run embeds object content in `last-applied-configuration` — **not** the 1MiB CM data limit. A 420KB dashboard JSON alone failed the whole group's dry-run with a confusing Job error (cmdshift/platform#171). **Keep every generated CM well under ~250KB**.
- 1MiB CM data limit and the 1MB helm release-secret cap ([adopt-chart skill](../../../.agents/skills/adopt-chart/SKILL.md)) are separate checks — a CM can pass both and still fail the annotation cap.

## Alert patterns (O2 native detectors) — dormant, restore via cmdshift/platform#206

The alert set is **empty** since the o2-sync removal — O2 → SMTP → mailpit delivery is still wired (`ZO_SMTP_*` env) but nothing sends. When #206 restores detectors (or a successor), keep the evidence-based semantics the removed JSONs encoded:

- **Any alert built on a gauge that materializes only after a first success needs an absent()/zero-guard arm** — `velero_backup_last_successful_timestamp` is absent before the first Completed backup (cmdshift/platform#111).
- **PartiallyFailed lives in the partial-failure counter, not the failure counter** — a rule watching only the failure counter is blind to exactly the failed-volume-data state it exists for.
- **One-shot counter spikes don't page**: sustained-condition windows (`for:` equivalents, `min_over_time` guards) absorb rebuild-time bursts (the tetragon bootstrap-kill flap, cmdshift/platform#60).
- Keep a **`watchdog` always-firing heartbeat** — its silence in mailpit is the one signal that survives a broken detector stack (cmdshift/platform#206).

## Flux alerts: REMOVED with o2-sync (cmdshift/platform#182 → #206)

The `o2-alerts-library` fluxcd pack (3 of 4 adopted: `flux_helmrelease_failure`, `flux_kustomization_failure`, `flux_source_issue`, all on scraped `gotk_resource_info`) was synced into O2 by the o2-sync Job — its removal took the flux detectors too. **No O2 alert exists today**; #206 decides the successor. The mechanics below are the rediscovery cost if the pack returns:

- **The `flux-controllers` gateway scrape job selects on `__meta_kubernetes_pod_label_app` regex alternation** — flux pod templates carry only `app: <controller-name>` (the `app.kubernetes.io/*` labels live on the Deployment, not the pod template), so pod-role SD can't use the standard label set. The metrics port is **named `http-prom`** (8080 is the http port). Verified live at the time: `gotk_resource_info` rows carried `service_name="flux-controllers"` for all four controllers.
- `flux_image_issue` was **PARKED** even while the pack lived — image automation controllers run `create: false` in this cluster, so its stream can never exist.
- The pack is CC-BY-4.0 (awesome-prometheus-alerts): keep the source block verbatim in each JSON, and replace the broken upstream Go-template descriptions with operator guidance.

## quotas / limit-range / VPA

- `observability-config/logging.limit-range.yaml` sets Container defaults in `observability` — it exists for the **quota-vs-exception gap** (ResourceQuota admission is not skipped by kyverno PolicyExceptions; LimitRange is the only defaults source for exception-exempt containers). Mechanics: [runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md).
- Two quotas: `compute` (32 pods) + the former `logging` quota renamed `logging-compute` (36 pods) — two `ResourceQuota/compute` objects in one namespace would both charge every pod (cmdshift/platform#120). A quota-exceeded ReplicaSet does NOT self-heal when the quota is raised — annotate the stuck RS (cmdshift/platform#155).
- All VPAs are **Off mode** — recommendations only, never mutation (cmdshift/platform#62). The chart runs the recommender only; `install.crds: Create` / `upgrade.crds: CreateReplace` because the CRDs ship in the chart's `crds/` dir (1MB cap a non-issue). Never run `helm test` on the vpa release — the chart renders three resource-less hook pods with no values knob; kyverno would deny them. Off-mode VPAs are hand-maintained (goldilocks removed) and coverage is **complete for every workload controller outside kube-system/flux-system** (cmdshift/platform#186 — the `vpa_recs` gap footer counts 0): a new workload gets one in its group manifest, `<controller>.vertical-pod-autoscaler.yaml` in the group's `-config` dir. kube-system/flux-system stay excluded **by design** — chart-pinned system plumbing, so the calibration table has no cilium/coredns rows there (cloud implication in [clusters/cloud/notes.md](../clusters/cloud/notes.md)).

Cloud: the manifests port as-is with the deltas in [clusters/cloud/notes.md](../clusters/cloud/notes.md) — S3 endpoint/TLS differs, the lowered VPA recommendation floors carry over.
