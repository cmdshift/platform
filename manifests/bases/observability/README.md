# observability

OpenObserve is the observability stack (cmdshift/platform#171 — replaces the LGTM stack: mimir/loki/tempo/grafana + seaweedfs, which existed only to serve them; the `objects/` group went with it). The group keeps: **openobserve** (`openobserve-standalone` chart 1.0.1 — single node, SQLite metadata on local-path PVC, parquet data in rustfs S3), **two collector HelmReleases** from the plain `otel/opentelemetry-collector` chart 0.175.0 (agent DaemonSet + gateway Deployment — see below why two), the chart-managed **Alertmanager** (delivery only — O2 native alerts are thin detectors that webhook AM `/api/v2/alerts`; the mail routing/template work from the mimir-ruler era carries over unchanged), and the sizing stack (metrics-server, vpa — both install into kube-system but their HelmReleases/values live here by domain). kube-state-metrics remains a standalone release (the agent collector's `clusterMetrics` preset bundles its own ksm; the gateway scrapes the standalone one).

Grafana is dropped — O2's built-in UI serves dashboards, gated by the `openobserve-auth-proxy` cookie-gate ([access/README.md](../access/README.md)). Dashboards, alert destinations, and alerts are GitOps-synced into O2 by the **o2-sync Job** in `observability-config/` (OSS O2 has no CRDs/CLI for them; [o2-sync pattern](#the-o2-sync-job-observability-config)).

Namespace layout rationale (cmdshift/platform#120): the former metrics/monitoring/logging groups merged into `observability` + `observability-config`.

## Architecture

```
workload logs/filelogs + host/kubelet/node metrics ─ agent DaemonSet ─┐
OTLP (traces, app metrics) ─────────────────────────── gateway Dep ───┤
prometheus scrape families (hand-expressed) ────────── gateway Dep ───┼→ openobserve :5080
                                                                        │   (SQLite meta on local-path,
alertmanager ← O2 alerts webhook /api/v2/alerts ←─────── thin detectors ┘    parquet in rustfs)
     ↓ email
   mailpit
```

- **`openobserve`** — `openobserve-standalone` 1.0.1, `fullnameOverride: openobserve`, PVC 5Gi local-path holds SQLite + WAL + query cache only (`ZO_LOCAL_MODE_STORAGE: s3` → rustfs `http://s3.cloud.test`, bucket `openobserve`, region `local`, path-style). Credentials via ExternalSecrets (`openobserve-credentials` root user, `openobserve-s3-credentials` S3 quartet) feeding `extraEnv` — the chart renders `auth.existingRootUserSecret` and empty `ZO_S3_*` placeholders; explicit env beats envFrom.
- **`openobserve-collector` (agent, daemonset)** — filelog (pod logs), hostmetrics, kubeletstats, kubernetesAttributes, clusterMetrics presets; pushes to `http://openobserve.observability.svc:5080/api/default/` via `otlphttp`; all ingest ports closed (it receives nothing).
- **`openobserve-collector-gateway` (deployment)** — OTLP ingest 4317/4318 (traces + app metrics; the old tempo intake shape) + hand-expressed `prometheus` scrape_configs ported 1:1 from the deleted `alloy-telemetry.config.alloy` (job names are load-bearing — the o2 community dashboards/alerts select on them).
- **NOT the o2 `openobserve-collector` chart 0.5.0** — it requires the opentelemetry-operator, and there was no CRD-free path through it; the human rejected an operator for this. The plain `otel/opentelemetry-collector` chart has `mode` + `config` **release-global**, so one HelmRelease per mode: agent (daemonset) + gateway (deployment) are two releases in one file (`openobserve-collector.helm-release.yaml`).
- Stream names in `o2-alerts-library` alerts assume the O2 collector chart's exact receiver config — if you change receiver/metric wiring, re-check the alert stream names in `observability-config/o2-sync/alerts/`.

## O2 chart landmines

- **The standalone chart's config CM is a HARDCODED KEY ALLOWLIST** — unknown `config.*` values are silently dropped (no error anywhere). Env-only flags like `ZO_SKIP_SSRF_CHECKS` must ride `extraEnv` (cmdshift/platform#171).
- **`ZO_SKIP_SSRF_CHECKS: "true"` is REQUIRED** for alert destinations pointing at in-cluster services — O2's SSRF guard blocks private IPs, and the alertmanager destination (`http://alertmanager.observability.svc:9093/api/v2/alerts`) is exactly that. Trusted environment; the deviation is commented at the value.
- **`ZO_COMPACT_DATA_RETENTION_DAYS` defaults to 3650** — a silent disk-full waiting to happen. Set `"7"` (data lives in rustfs; the PVC only buffers).
- **Image registry: point at the real home, never a façade** — `o2cr.ai` is a 302 redirect façade to `public.ecr.aws/zinclabs/openobserve`; docker CLI follows cross-registry redirects but **angos does not** (cache-miss returns `not found`; no redirect-following/host-override knob exists in angos v1.12.2 — checked docs+source). Values use `public.ecr.aws/zinclabs/openobserve` (the already-mapped `ecr` upstream); there is deliberately **no o2cr.ai stanza in `registry_map`** (`cluster/local/registry/locals.tf`). Applies to any future image whose host is a redirect façade.
- Chart pin: SQLite metadata migration chains break across minor bumps — test on a fork of the PVC before bumping (comment at the pin).

## Sizing: the memtable/intervals evidence (cmdshift/platform#171)

First config burned **~830m sustained CPU** — bursty zstd dump/merge across all cores + 60s compaction cycles. Final shape (evidence comments live at each value in `openobserve-values.yaml`):

- **Memtable 768MB + 4Gi limit**: the default derives 25% of container mem_total (256MB at 1Gi) and ~1400 streams overflowed it on the first scrape cycle (`MemoryTableOverflowError` 503s); 256MB still overflowed at ~150/min. 768 + the 4Gi limit holds the working set with the thread caps.
- **Thread caps 2** (dump/move/merge) + **halved intervals** (retention 30s, file-push 60s, compact-interval 150s): doubling the frequency means smaller units of zstd/merge work — bursts cool between them instead of one core pinned for long stretches.
- **Query caches capped** (memory-cache 512, datafusion 256 — they compete with ingest for the same limit); **disk cache OFF** (duplicates rustfs reads, burns CPU on GC).
- Result: **~200m avg, 0 overflows, 100% 200s**. The 2-core CPU limit is the deliberate heat ceiling (cgroup throttle), sized under the observability quota.

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

## Alertmanager: delivery only (cmdshift/platform#141 shape, unchanged)

The `prometheus-community/alertmanager` chart (1.43.3, app v0.34.1) stays as the alert delivery path: O2 native alerts are thin detectors (stream + PromQL + threshold) whose destination webhooks AM's `/api/v2/alerts`; the mail routing, receivers, and the email template with link annotations are unchanged from the mimir-ruler era. Chart traps that still apply:

- **Raw Alertmanager YAML, not the CR spelling**: route keys snake_case (`group_by` — camelCase fails the am config parse), sub-route matchers STRINGS (`slo="true"`); the chart's values.schema enforces the string form (`helm_verify` catches it).
- **A failed install keeps the bad release**: helm-controller retries the same broken config; the values fix only lands after `helm uninstall`.
- **Custom annotations never reach the inbox by default**: receivers' `text`/`html` must call `email.default.*` templates and a values `templates:` map renders them INTO the same ConfigMap mounted at `/etc/alertmanager`. Validate with `amtool check-config` (in `quay.io/prometheus/alertmanager:v0.34.1`), end-to-end via a smoke alert + `mailpit -s`/`-b`.

## Alert patterns that carry over (now evaluated as O2 detectors)

The alert semantics ported from the mimir ruler keep their evidence-based rules — the o2-sync JSONs in `observability-config/o2-sync/alerts/` encode the same shapes:

- **Any alert built on a gauge that materializes only after a first success needs an absent()/zero-guard arm** — `velero_backup_last_successful_timestamp` is absent before the first Completed backup (cmdshift/platform#111).
- **PartiallyFailed lives in the partial-failure counter, not the failure counter** — a rule watching only the failure counter is blind to exactly the failed-volume-data state it exists for.
- **One-shot counter spikes don't page**: sustained-condition windows (`for:` equivalents, `min_over_time` guards) absorb rebuild-time bursts (the tetragon bootstrap-kill flap, cmdshift/platform#60).

## quotas / limit-range / VPA

- `observability-config/limit-range.yaml` sets Container defaults in `observability` — it exists for the **quota-vs-exception gap** (ResourceQuota admission is not skipped by kyverno PolicyExceptions; LimitRange is the only defaults source for exception-exempt containers). Mechanics: [runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md).
- Two quotas: `compute` (32 pods) + the former `logging` quota renamed `logging-compute` (36 pods) — two `ResourceQuota/compute` objects in one namespace would both charge every pod (cmdshift/platform#120). A quota-exceeded ReplicaSet does NOT self-heal when the quota is raised — annotate the stuck RS (cmdshift/platform#155).
- All VPAs are **Off mode** — recommendations only, never mutation (cmdshift/platform#62). The chart runs the recommender only; `install.crds: Create` / `upgrade.crds: CreateReplace` because the CRDs ship in the chart's `crds/` dir (1MB cap a non-issue). Never run `helm test` on the vpa release — the chart renders three resource-less hook pods with no values knob; kyverno would deny them. Off-mode VPAs are hand-maintained (goldilocks removed): a new workload gets one in its group manifest.

Cloud: the manifests port as-is with the deltas in [clusters/cloud/notes.md](../clusters/cloud/notes.md) — S3 endpoint/TLS differs, the lowered VPA recommendation floors carry over.
