# observability

OpenObserve is the observability stack (cmdshift/platform#171 — replaces the LGTM stack: mimir/loki/tempo/grafana + seaweedfs, which existed only to serve them; the `objects/` group went with it). The group keeps: **openobserve** (`openobserve-standalone` chart 1.0.1 — single node, SQLite metadata on local-path PVC, parquet data in rustfs S3), **two collector HelmReleases** from the plain `otel/opentelemetry-collector` chart 0.175.0 (agent DaemonSet + gateway Deployment — see below why two), and the sizing stack (metrics-server, vpa — both install into kube-system but their HelmReleases/values live here by domain). kube-state-metrics remains a standalone release (the agent collector's `clusterMetrics` preset bundles its own ksm; the gateway scrapes the standalone one). Alertmanager was removed (cmdshift/platform#182) — O2 native alerts deliver via O2's built-in SMTP directly to the mailpit companion.

Grafana is dropped — O2's built-in UI serves dashboards, gated by the `openobserve-auth-proxy` cookie-gate ([access/README.md](../access/README.md)). Dashboards, alert destinations, and alerts are GitOps-synced into O2 by the **o2-sync Job** in `observability-config/` (OSS O2 has no CRDs/CLI for them; [o2-sync pattern](#the-o2-sync-job-observability-config)).

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

- **`openobserve`** — `openobserve-standalone` 1.0.1, `fullnameOverride: openobserve`, PVC 5Gi local-path holds SQLite + WAL + query cache only (`ZO_LOCAL_MODE_STORAGE: s3` → rustfs `http://s3.cloud.test`, bucket `openobserve`, region `local`, path-style). Credentials via ExternalSecrets (`openobserve-credentials` root user, `openobserve-s3-credentials` S3 quartet) feeding `extraEnv` — the chart renders `auth.existingRootUserSecret` and empty `ZO_S3_*` placeholders; explicit env beats envFrom.
- **`openobserve-collector` (agent, daemonset)** — filelog (pod logs), hostmetrics, kubeletstats, kubernetesAttributes, clusterMetrics presets; pushes to `http://openobserve.observability.svc:5080/api/default/` via `otlphttp`; all ingest ports closed (it receives nothing).
- **`openobserve-collector-gateway` (deployment)** — OTLP ingest 4317/4318 (traces + app metrics; the old tempo intake shape) + hand-expressed `prometheus` scrape_configs ported 1:1 from the deleted `alloy-telemetry.config.alloy` (job names are load-bearing — the o2 community dashboards/alerts select on them).
- **NOT the o2 `openobserve-collector` chart 0.5.0** — it requires the opentelemetry-operator, and there was no CRD-free path through it; the human rejected an operator for this. The plain `otel/opentelemetry-collector` chart has `mode` + `config` **release-global**, so one HelmRelease per mode: agent (daemonset) + gateway (deployment) are two releases in one file (`openobserve-collector.helm-release.yaml`).
- Stream names in `o2-alerts-library` alerts assume the O2 collector chart's exact receiver config — if you change receiver/metric wiring, re-check the alert stream names in `observability-config/o2-sync/alerts/`.

## O2 chart landmines

- **The standalone chart's config CM is a HARDCODED KEY ALLOWLIST** — unknown `config.*` values are silently dropped (no error anywhere). Env-only flags must ride `extraEnv` (cmdshift/platform#171). The allowlist contains **ZERO SMTP keys** — all five `ZO_SMTP_*` settings (ENABLED/HOST/PORT/FROM_EMAIL/ENCRYPTION) ride `extraEnv` (cmdshift/platform#182); a `config:` attempt is silently dropped.
- **Alert delivery is O2 built-in SMTP, no alertmanager** (cmdshift/platform#182): the alertmanager HelmRelease/values were deleted; O2 emails destinations directly through the `ZO_SMTP_*` env to the mailpit companion (`ZO_SMTP_ENCRYPTION: ""` is the documented plain-SMTP mode — port 25, local relay). `ZO_SKIP_SSRF_CHECKS` was removed with it — no in-cluster webhook destinations remain; re-add it only if a destination ever points in-cluster again.
- **O2 email destination schema (chart 1.0.1)**: `{"name", "type": "email", "emails": [recipients], "template" (optional)}` — there are **NO per-destination SMTP fields**; transport is the global `ZO_SMTP_*` env. Recipients must be org members; the root user is implicitly a member, and the O2 root user is `admin@cloud.test` (one admin identity across rauthy + O2 — set in `cluster/local/secrets/locals.tf`).
- **The `POST /api/{org}/<stream>/_json` endpoint is LOGS-ONLY** (cmdshift/platform#182, cost multiple debugging rounds): seeding a *metrics* stream name through it materializes a phantom LOGS stream under the same name, which the v2 alerts API (binding on the alert's `stream_type`) still reports as `Stream not found` (404). Metrics streams must be seeded via `POST /api/{org}/ingest/metrics/_json` with body `[{"__name__":"<stream_name>","__type__":"gauge","value":0,"_timestamp":...}]` — `__name__` carries the stream name, `__type__` locks on the first record. Streams auto-create on first ingest of the correct type; the o2-sync Job seeds before alert creation (existence-gated via `GET streams?type=<type>`; metrics seed value 0 so no alert condition can fire on the seed).
- **`ZO_COMPACT_DATA_RETENTION_DAYS` defaults to 3650** — a silent disk-full waiting to happen. Set `"3"` (data lives in rustfs; the PVC only buffers). **Retention lives inside the compactor module** (`src/service/compact/retention.rs`) — compaction OFF silently disables data retention entirely (cmdshift/platform#182: `ZO_COMPACT_ENABLED` must stay true or retention is dead).
- **Image registry: point at the real home, never a façade** — `o2cr.ai` is a 302 redirect façade to `public.ecr.aws/zinclabs/openobserve`; docker CLI follows cross-registry redirects but **angos does not** (cache-miss returns `not found`; no redirect-following/host-override knob exists in angos v1.12.2 — checked docs+source). Values use `public.ecr.aws/zinclabs/openobserve` (the already-mapped `ecr` upstream); there is deliberately **no o2cr.ai stanza in `registry_map`** (`cluster/local/registry/locals.tf`). Applies to any future image whose host is a redirect façade.
- Chart pin: `openobserve-standalone` 1.0.1 — SQLite metadata migration chains break across minor bumps; test on a fork of the PVC before bumping (cmdshift/platform#171).
- **FSTree sizing** (cmdshift/platform#182): `ZO_MEMORY_CACHE_MAX_SIZE`/`ZO_MEMORY_CACHE_DATAFUSION_MAX_SIZE` are 1536/1536 and the disk cache (`ZO_DISK_CACHE_*`) is the relief valve — 1Gi of the 5Gi PVC, leaving the rest for SQLite + WAL. Memory caches compete with ingest for the same limit.
- **Pod annotations**: `backup.velero.io/backup-volumes-excludes: data` — the data PVC holds disposable SQLite metadata + WAL/parquet staging (config is GitOps-recovered via o2-sync, data lives in rustfs); backing it up live fails ~90% through with an empty data-path error and burns ~7GB of kopia churn per backup (cmdshift/platform#171).
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
| inlined Basic-auth header on `otlphttp/openobserve` | root user, same identity as the UI — chart exposes no env passthrough into presets; must be re-encoded whenever the secrets-server `openobserve-credentials` payload changes (401 trap below) | #171 |
| exporter `debug: null` | dropped the chart's default debug exporter (noise) | #171 |

### openobserve-collector-gateway (values decision table)

| value | why | ref |
|---|---|---|
| `mode: deployment`, OTLP 4317/4318 with hostPorts | OTLP ingest (traces + app metrics — the old tempo intake shape) + hand-expressed prometheus scrape families ported 1:1 from the deleted `alloy-telemetry.config.alloy`; job names are load-bearing for the ported alert rules + dashboards | #171 |
| `clusterRole.rules` services/endpoints/endpointslices/pods/nodes/namespaces | the prometheus receiver's kubernetes_sd needs discovery RBAC — the preset role only covers k8sattributes (pods); without it every scrape job resolves zero targets | #171 |
| `clusterRole.rules` nodes/metrics+proxy+stats + `nonResourceURLs: [/metrics]` | kubelet/cadvisor scrapes authorize via SAR on nodes/{subresource}; the apiserver /metrics job is a nonResourceURL | #171 |
| keep-rules select on `namespace;labels;port-name` | exactly as the old alloy keep-rules did (instance = release name is load-bearing); control-plane jobs keep the upstream chart wiring (scheme https, SA bearer token, port remap) | #171 |
| cadvisor job on the gateway | the agent already scrapes kubeletstats — cadvisor stays here (gateway) for the container_fs_* families the old config kept | #171 |
| gateway limits 1 CPU / 1536Mi | memory_limiter preset is 80% of the limit — keep headroom above WAL spikes | #171 |
| flux-controllers job selects on `__meta_kubernetes_pod_label_app` | flux pod templates carry only `app: <name>` (app.kubernetes.io labels live on the Deployment, not the pod); metrics port named `http-prom`; job name feeds the o2-alerts-library fluxcd pack on gotk_resource_info | #182 |

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
- **Compaction is ON** (cmdshift/platform#182): an earlier "tuning" left `ZO_COMPACT_ENABLED` false, which silently disabled data retention entirely (retention lives inside the compactor module). Current shape: compact enabled, interval 60s, batch 50, fast-mode false, retention 3d, `ZO_MAX_FILE_SIZE_ON_DISK: "16"`. The 60s interval is deliberately kept against the #171 60s-cycle burn history — the work set is now bounded by 3d retention; post-change openobserve sits ~120m CPU, well under the 2-core limit.

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

Metadata (users/dashboards/alerts) is **disposable by design** — all of it lives in Git via the o2-sync Job, which re-creates it idempotently on the next run. Data itself survives in rustfs.

## The o2-sync Job (`observability-config/o2-sync/`)

OSS O2 has no CRDs/CLI/Terraform for dashboards, alert destinations, or alerts — they are synced via REST by a Job in `observability-config/` (so it applies **after** the observability group is Ready; the `-config` group dependsOn it).

- **Re-run trigger is the configMapGenerator hash suffix**: the Job's pod template references hash-suffixed CMs, and `kustomize.toolkit.fluxcd.io/force: Enabled` makes flux delete+recreate the Job when the pod template changes — a completed Job is never re-run otherwise. Any dashboard/alert/script edit changes a CM name → Job recreated → sync re-runs.
- **Script is CM-mounted, image is plain alpine+curl+jq** (built+pushed by terraform module `cluster/local/images/`) — script edits don't need image builds.
- **API landmines** (all in `scripts/sync.sh` with refs): the v2 alerts API path is `/api/v2/{org}/alerts` — **v2 nests BEFORE the org segment** (`/api/{org}/v2/alerts` 404s); list endpoints return `{"list":[…]}` wrappers (jq walks either shape); POST-creation races concurrent Job-retry pods — the script re-fetches the list per file instead of snapshotting; alerts on not-yet-ingested streams fail `StreamNotFound` → bounded retry (`MAX_STREAM_RETRIES`).
- **Stream seeding step runs before alert creation** (cmdshift/platform#182): each alert's stream is existence-gated via `GET streams?type=<type>`; logs streams seed through `POST /api/{org}/<stream>/_json`, metrics streams through `POST /api/{org}/ingest/metrics/_json` (the `_json` endpoint is logs-only — see the landmine above). Metrics seed value is 0 so no alert condition can fire on the seed (a seed of 1 on the `up` stream would look like a real reading).
- **Email destination**: one `email`-type destination, recipient `admin@cloud.test` (the O2 root user — implicitly an org member, which destination recipients must be). Verified end-to-end: watchdog + genuine detections delivered to mailpit.
- **Trivy alert PARKED**: the `trivy_image_vulnerabilities` stream materializes only after the first VulnerabilityReport — none exist (vuln-scan investigation parked). The alert JSON is commented out of the generator; re-add it with the file.

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

If it's stale after reconcile + requestedAt annotate, the fix is the suspend → `helm uninstall` → resume dance (or a full group bounce). `flux_triage` shows attempted-vs-applied revision lag to recognize the state; `helm_wait` for the per-release verdict. (The general ordering rule — `flux_wait` before `helm_wait` on values-only changes — lives in the `platform-workflow` skill.)

## ConfigMap size caps: two different limits

- **~256KB last-applied annotation cap (kustomize-controller)**: its client-side-apply dry-run embeds object content in `last-applied-configuration` — **not** the 1MiB CM data limit. A 420KB dashboard JSON alone failed the whole group's dry-run with a confusing Job error (cmdshift/platform#171). **Keep every generated CM well under ~250KB**; `observability-config/o2-sync/kustomization.yaml` groups dashboards by domain into separate configMapGenerator entries for exactly this.
- 1MiB CM data limit and the 1MB helm release-secret cap ([adopt-chart skill](../../../.agents/skills/adopt-chart/SKILL.md)) are separate checks — a CM can pass both and still fail the annotation cap.

## Alert patterns (O2 native detectors)

Alert delivery is O2 → SMTP → mailpit; no alertmanager anywhere in the path. The detector semantics keep their evidence-based rules — the o2-sync JSONs in `observability-config/o2-sync/alerts/` encode the same shapes:

- **Any alert built on a gauge that materializes only after a first success needs an absent()/zero-guard arm** — `velero_backup_last_successful_timestamp` is absent before the first Completed backup (cmdshift/platform#111).
- **PartiallyFailed lives in the partial-failure counter, not the failure counter** — a rule watching only the failure counter is blind to exactly the failed-volume-data state it exists for.
- **One-shot counter spikes don't page**: sustained-condition windows (`for:` equivalents, `min_over_time` guards) absorb rebuild-time bursts (the tetragon bootstrap-kill flap, cmdshift/platform#60).

## Flux alerts: the o2-alerts-library pack (cmdshift/platform#182)

Flux alerting uses the `o2-alerts-library` fluxcd pack — **3 of 4 adopted**: `flux_helmrelease_failure`, `flux_kustomization_failure`, `flux_source_issue`, all on scraped `gotk_resource_info` metrics (the gateway's `flux-controllers` scrape job). `flux_image_issue` is **PARKED** — image automation controllers run `create: false` in this cluster, so its stream can never exist. The pack is CC-BY-4.0 (awesome-prometheus-alerts): the source block is kept verbatim in each JSON, and the broken upstream Go-template descriptions are replaced with operator guidance. This **replaced** the flux notification Provider+Alert objects (both deleted) — persistent not-ready metrics beat transient error events, and the flux event path no longer exists.

- **The `flux-controllers` gateway scrape job selects on `__meta_kubernetes_pod_label_app` regex alternation** — flux pod templates carry only `app: <controller-name>` (the `app.kubernetes.io/*` labels live on the Deployment, not the pod template), so pod-role SD can't use the standard label set. The metrics port is **named `http-prom`** (8080 is the http port). Verified live: `gotk_resource_info` rows carry `service_name="flux-controllers"` for all four controllers.
- **The collectors' otlphttp exporter carries an inlined base64 Basic-auth header** (agent + gateway): the collector chart exposes no env passthrough into presets, so the header is inlined in values — **it must be re-encoded whenever the secrets-server `openobserve-credentials` payload changes**. This mismatch caused 401 Unauthenticated on all O2 exports after the root-user rename (symptom: gateway `Exporting failed... 401`, dropped items, zero data landing).

## quotas / limit-range / VPA

- `observability-config/logging.limit-range.yaml` sets Container defaults in `observability` — it exists for the **quota-vs-exception gap** (ResourceQuota admission is not skipped by kyverno PolicyExceptions; LimitRange is the only defaults source for exception-exempt containers). Mechanics: [runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md).
- Two quotas: `compute` (32 pods) + the former `logging` quota renamed `logging-compute` (36 pods) — two `ResourceQuota/compute` objects in one namespace would both charge every pod (cmdshift/platform#120). A quota-exceeded ReplicaSet does NOT self-heal when the quota is raised — annotate the stuck RS (cmdshift/platform#155).
- All VPAs are **Off mode** — recommendations only, never mutation (cmdshift/platform#62). The chart runs the recommender only; `install.crds: Create` / `upgrade.crds: CreateReplace` because the CRDs ship in the chart's `crds/` dir (1MB cap a non-issue). Never run `helm test` on the vpa release — the chart renders three resource-less hook pods with no values knob; kyverno would deny them. Off-mode VPAs are hand-maintained (goldilocks removed): a new workload gets one in its group manifest.

Cloud: the manifests port as-is with the deltas in [clusters/cloud/notes.md](../clusters/cloud/notes.md) — S3 endpoint/TLS differs, the lowered VPA recommendation floors carry over.
