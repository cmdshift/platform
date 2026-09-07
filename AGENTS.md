# AGENTS.md

Platform manifests for a Talos-in-Docker local test cluster (terraform in `cluster/local`, ignore for manifest work). Flux v2 deploys everything in `manifests/local/`.

Out-of-cluster companions (terraform/docker, `*.cloud.test`): rustfs S3 (`s3.cloud.test`, container `storage-cloud-test`), secrets server (`secrets.cloud.test`, container `secrets-cloud-test`, served over haproxy), the sync container (`sync-cloud-test`) that mirrors manifests into the flux bucket, and mailpit — alerts (ruler → alertmanager) land at **http://mail.cloud.test**.

## Skills (load on demand, don't re-derive)

Procedures are agent skills in `.agents/skills/<name>/SKILL.md`, loaded via the `skill` tool. Load the matching skill instead of improvising a workflow:

| Skill | Load when |
|---|---|
| `platform-workflow` | about to change any manifest — the standard loop |
| `reconcile-stuck` | a kustomization won't go Ready / `flux_wait` timed out |
| `pipeline-wedged` | manifest edits not reaching the cluster |
| `helmrelease-stuck` | a HelmRelease is failing or stuck |
| `crashloop-investigation` | pods crashlooping / OOMKilled |
| `resource-sizing` | setting or auditing container resources |
| `add-workload` | deploying anything new |
| `adopt-chart` | adopting or bumping a helm chart |
| `rustfs-ops` | touching S3, buckets, or objects |
| `velero-ops` | backups and restores |
| `cilium-test` | full-cluster connectivity validation |
| `cluster-rebuild` | fresh bootstrap from terraform |
| `observability` | metrics, logs, tetragon events (tetra), or alert delivery |

The standard loop (`platform-workflow`): rationale-comment check → `yaml_lint` → `helm_verify` → `sync_wait` → `flux_wait` (reconcile from the root) → final checks (`kubectl get helmreleases -A` green, `policy_report` failures 0). Posture scanning (kubescape) was removed 2026-09-06 — single-purpose hardening tools are its replacement; see `manifests/local/notes.md`.

Every skill links out to its human-readable runbook in `runbooks/local/` (full detail, worked examples) — read the runbook when the skill's summary isn't enough.

## Docs maintenance (required before commit/PR)

Documentation is part of the change — a change isn't ready to commit or PR until the docs it made stale are updated in the same branch. Sweep all four surfaces:

- **`manifests/local/notes.md`** (+ `manifests/cloud/notes.md`) — new local-only settings + rationale, session learnings, accepted findings, cloud deltas
- **runbooks** (`runbooks/local/`) — procedures that changed, new gotchas, worked examples from live incidents
- **skills** (`.agents/skills/*/SKILL.md`) — sync any skill whose trigger, steps, or trap list changed (skills are thin dispatchers; detail may live in the runbook, but the trap list must stay current)
- **tools/bin/README.md** — new or changed helper scripts: args, defaults, exit codes, gotchas

Bar to clear: if this session hit a landmine, cost a debugging round, or produced a decision with rationale, it's documentation — write it down where the next operator (or agent) will find it.

## How changes propagate

Local file → docker sync container (`rc mirror --overwrite --remove` + inotify) → S3 bucket `flux` on **rustfs** (out-of-cluster, terraform/docker `storage` container, endpoint `s3.cloud.test`) → flux `Bucket` source (`main`, 5m interval) → `Kustomization/local` (root) → child kustomizations in dependency order.

- Child kustomization intervals are **drift-heal only** (1h; the thanos-operator's is 24h) — propagation is event-driven (artifact change + `dependsOn` requeue at 5s), so loosened intervals cost nothing in latency. Loosened from 10m/1m (2026-09-06) for interactive determinism: the 1m bucket poll could publish a half-mirrored artifact mid-edit and set the whole chain applying it. The manual flow (`sync_wait` + `flux_wait --with-source`) forces an immediate pull; the bootstrap twin's 1m intervals keep the one-shot rebuild fast until flux-config adopts. **Do not suspend** kustomizations — a suspended tree reconciles nothing on rebuild, breaking the one-shot requirement. `retryInterval` is 5s everywhere
- macOS bind mounts occasionally drop inotify events (deletes, sometimes edits) — if a change doesn't propagate (check with `rustfs ls main/flux --recursive`), `docker restart sync-cloud-test` forces a full `--remove` re-mirror. Full wedge triage: the `pipeline-wedged` skill

## Admission policy (read this before adding any workload)

All 11 kyverno ValidatingPolicies are in **Deny** mode — non-compliant pods/jobs are rejected at admission:

- All containers + initContainers need cpu/memory **requests and limits**; pinned image tags (no `:latest`), `runAsNonRoot`, seccompProfile `RuntimeDefault`, capabilities dropped `ALL`
- Policies autogen to controllers, but **not ReplicaSets** (removed to avoid old-RS noise). Old PolicyReports for unmatched resources are never retracted — delete stale report objects directly if needed
- **PolicyExceptions** (`manifests/local/policies-config/*.policy-exception.yaml`) cover deliberate Talos-in-Docker settings (hostNetwork kyverno, privileged velero node-agents, cilium, node-exporter, kube-system system components, alloy host-logs, local-path helper pod, thanos-ruler config-reloader sidecar). They're scoped by namespace + name prefix — don't try to "fix" these workloads
- **Helm hook jobs are admission-checked too** — render and size them when adopting a chart (known-proofed list in the `add-workload` skill)

Full checklist: the `add-workload` skill → [runbooks/local/adding-a-workload.md](runbooks/local/adding-a-workload.md).

## Resource sizing conventions

Evidence-based, not defaults: requests lean (10-50m CPU), **CPU limits generous for bursts** (200m-2000m). Throttling is the silent killer — `cpu_audit` ranks the throttled containers; for a single suspect, `prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'`. Memory: request ≈ P99 × 1.2, limit = 1.5 × request (velero is 2× deliberately — kopia repo-maintenance spikes OOM-killed it at 1.5×; rationale comment in `backups/velero.helm-release.yaml`). Burst-heavy delivery components (flux source/helm-controllers) need 1000m CPU / 512Mi-1Gi or they wedge the whole pipeline. Audit procedure: the `resource-sizing` skill.

## Storage: local-path and non-root workloads

local-path-provisioner creates **world-writable (0777)** dirs (`mkdir -m 0777`), so non-root workloads can write PVCs — but only on **fresh deploy**. Retrofitting root-owned data needs a one-time chown. `main.seaweed.yaml` documents this; seaweedfs runs as 65534. The helper pod image is pinned via `helperImage.tag` (must not be `:latest` — admission denies it, silently breaking all PVC provisioning).

## CR-managed workloads (not helm values)

grafana (`Grafana` CR), thanos ×3, alertmanager (`Alertmanager` CR) → `monitoring-config/`; seaweed cluster + `seaweedfs-admin` (plain Deployment) → `objects-config/`. Resources/security contexts go in the CR specs (`resourceRequirements`, `securityContext`, per-component `podSecurityContext`/`containerSecurityContext`).

## tools/bin

Helper scripts for the repeated plumbing (direnv adds `tools/bin` to PATH; invoke as `tools/bin/<name>` otherwise). **Check here before formulating any kubectl/jq/prometheus/docker command by hand** — audits (`memory_audit`/`cpu_audit`/`request_audit`/`policy_report`), observability queries (`prometheus_query`/`loki_query`/`mailpit`), and waits (`flux_wait`/`velero_wait`) already exist and handle the plumbing you'd get wrong inline: port-forward lifecycle, Mi/Gi/m normalization, bounded polling. When a task needs more than a round or two of throwaway plumbing anyway, promote it to a new script here instead of re-deriving it next time (the proven pattern: `policy_report`/`cpu_audit`/`kyverno_unblock` all started as inline jq — see cmdshift/platform#21).

Full reference — what each does, arguments, defaults, exit codes, gotchas: [tools/bin/README.md](tools/bin/README.md). One-line map: `yaml_lint` (manifest lint), `helm_verify` (HelmRelease values render check), `cr_validate` (server-side dry-run of CRs against on-cluster CRD schemas + admission — run before `sync_wait` on any CR change), `sync_wait` (bucket-sync convergence before reconciling), `flux_wait` (reconcile root + bounded poll), `memory_audit`/`cpu_audit` (usage-vs-**limits**), `request_audit` (usage-vs-**requests**, the scheduling side), `pod_status` (pod table with restarts/exit codes, crashloop triage), `policy_report` (admission results), `kyverno_unblock` (hostNetwork rollout deadlock), `prometheus_query`/`loki_query`/`mailpit` (observability), `velero_wait` (backup/restore poll), `rustfs` (rc CLI in the storage container), `cilium_test` (connectivity test + temp scaffolding).

## Hygiene

- **No live patches — everything in files**: never fix drift with `kubectl edit`/`talosctl patch`/`docker exec` mutations (flux root `local`/`main` bucket edits during a wedge are the documented exception). Change the manifest or terraform template and reconcile; if the fix needs a rebuild, note the pending state in `manifests/local/notes.md`.
- **local-vs-cloud notes**: `manifests/local/notes.md` (inventory of deliberately local-only settings + rationale) and `manifests/cloud/notes.md` (what to do differently in the cloud cluster). When you add or change a setting that's local-only, or learn something the cloud cluster must do differently, record it in the matching file. In-repo markers (`# remove in the cloud`, `# true in the cloud`) stay the source of truth at the value itself; the notes carry the "why" and the cloud-side action.
- **Rationale comments**: when you make a non-obvious decision (sizing after observed P99, a deliberate `prune: false`, a workaround for a landmine), leave the inline comment at the value — then link the notes/runbook/issue if there's more context.

## Landmines

### Charts

- **kyverno**: `admissionController.container.resources` is nested (unlike background/cleanup/reports); `config.webhooks` is a **map** (a list is silently dropped by helm merge); `backgroundScanInterval: 1h` (5m caused a reports-controller CPU ramp — cmdshift/platform#17); controllers use hostNetwork → rollouts deadlock on host ports (`kyverno_unblock` deletes the old pods)
- **cert-manager**: values keys all-lowercase (`startupapicheck`), camelCase fails chart schema and blocks the whole dependency chain
- **seaweedfs-operator**: setting `spec.admin` on the Seaweed CR *enables* a new component — only set component sections intentionally
- **velero**: node-agents are privileged by design ("remove in the cloud" comments mark local-only settings). FSB skips hostPath PVs — the StorageClasses carry `defaultVolumeType: local` so **new** PVCs get `local` PVs and are volume-data protected (all 8 PVs converted with the 2026-09-05 rebuild). The temporary data mover pods (velero 1.15+ hosting-pod design) need the velero PolicyException + the `node-agent-config` configmap — the configmap **ships with the release in `backups/`**, not `backups-config/`: velero exits at startup if the flag's configmap is missing (the circular-wedge story is in the runbook). Delete backups with `velero backup delete`, never `kubectl delete backup` — backup-sync resurrects the Backup CR from storage within minutes. Operations: the `velero-ops` skill
- **thanos-operator**: deployed from its repo's `bundle.yaml` via kustomization, not its helm chart — the chart embeds ~2.5MB of CRDs in the release manifest, blowing helm's 1MB release-secret cap (rationale comment in `monitoring/thanos-operator.kustomization.yaml`; strategy ladder in `adopt-chart`). The operator's status conditions are unreliable (`ReconcileFailed=True` is sticky from bootstrap status-races) — verify health via workloads and logs, not conditions. **Ruler alerting depends on the query seeing the prometheus head** — the sidecar endpoint is wired manually via `additionalArgs` in `main.thanos-query.yaml` (label-based discovery can't see the chart-managed discovery service); if ruler rules silently never fire, check `prometheus_query --query 'count(kube_pod_container_status_restarts_total)'` against the query svc — empty means the head path is broken again. Alert delivery lands in mailpit (http://mail.cloud.test)
- **AlertmanagerConfig** (`monitoring.coreos.com/v1alpha1`): child-route `matchers` are **structured Matcher objects** (`{name, value}`), not PromQL strings — strings fail the validating webhook with an opaque "invalid". Receiver names that look like YAML nulls (`name: null`) must be quoted (`name: "null"`) or the CRD rejects the object before the webhook even sees it. Both hit live in `monitoring-config/mail.alertmanager-config.yaml`

### Flux APIs

- **Kustomizations**: `wait: true` **ignores** `spec.healthChecks` — gate custom resources on real operator status with `spec.healthCheckExprs` (CEL; in use on the `*-config` kustomizations); copy battle-tested expressions from https://fluxcd.io/flux/cheatsheets/cel-healthchecks/ (ClusterIssuer, ClusterSecretStore, etc. — only the apiVersion **group** is matched, `kind` optional for group-wide entries). Verify new API fields against the **on-cluster CRD schema** before pushing (`kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'`) — undeclared fields fail the root dry-run ("field not declared in schema") and wedge the whole dependency chain (`healthyWhen` did exactly this). When unsure of a flux/CRD API shape, fetch the upstream docs or CRD (webfetch) instead of guessing
- the root `local` Kustomization and `Bucket` source are managed by the `flux-config` kustomization (`manifests/local/flux-config/`, `force: true` adopts them from the terraform bootstrap's helm-hook objects on every fresh install). They're duplicated in `cluster/local/bootstrap` `extraObjects` — close enough, not identical (the bootstrap twin is minimal; flux-config converges both objects to its spec on first reconcile). A bad edit to either (path, sourceRef, endpoint) wedges the pipeline: everything keeps running but nothing applies. Fix forward with `kubectl -n flux-system edit kustomization local` (or `edit bucket main`) — **never delete** them (the root has `deletionPolicy: Orphan`, but its absence stops all reconciliation)

### Tooling

- **helm**: release manifests are persisted in the `sh.helm.release.*` Secret, which caps at **1MB** — charts embedding large CRDs fail at install with `data: Too long: may not be more than 1048576 bytes`. Prometheus CRDs avoid the limit by shipping as the separate `prometheus-operator-crds` chart. Strategy ladder: the `adopt-chart` skill
- **rustfs** (`rc` CLI — use the `rustfs` wrapper, a passthrough in the `storage-cloud-test` container with the admin alias preset): `rc rm --recursive` silently removes nothing — use `rc object remove` per key or `rc mirror --remove`; `rc ls` needs `--recursive`. Bucket changes (the `buckets` list in `cluster/local/conf/outputs.tf`) recreate the container and wipe its data. Quirks + provisioning model: the `rustfs-ops` skill
