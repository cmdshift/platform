# AGENTS.md

Platform manifests for a Talos-in-Docker local test cluster (terraform in `cluster/local`, ignore for manifest work). Flux v2 deploys everything in `manifests/local/`.

Out-of-cluster companions (terraform/docker, `*.cloud.test`): rustfs S3 (`s3.cloud.test`, container `storage-cloud-test`), secrets server (`secrets.cloud.test`, container `secrets-cloud-test`, served over haproxy), the sync container (`sync-cloud-test`) that mirrors manifests into the flux bucket, and mailpit — alerts (ruler → alertmanager) land at **http://mail.cloud.test**.

## How changes propagate

Local file → docker sync container (`rc mirror --overwrite --remove` + inotify) → S3 bucket `flux` on **rustfs** (out-of-cluster, terraform/docker `storage` container, endpoint `s3.cloud.test`) → flux `Bucket` source (`main`, 1m interval) → `Kustomization/local` (root) → child kustomizations in dependency order.

- Child kustomization intervals are **drift-heal only** — propagation is event-driven (artifact change + `dependsOn` requeue at 5s), so the 10m child intervals cost nothing in latency. `retryInterval` is 5s everywhere
- macOS bind mounts occasionally drop inotify delete events — if a manifest deletion doesn't propagate (check with `rustfs ls main/flux --recursive`), `docker restart sync-cloud-test` forces a full `--remove` re-mirror. Full wedge triage (sync/bucket/root decision tree): [runbooks/local/pipeline-wedged.md](runbooks/local/pipeline-wedged.md)

## Making changes: workflow

**Before reconciling:**
1. Lint: `yaml_lint`
2. Verify values paths with `helm_verify` (renders every HelmRelease's values via `helm template`; schema-less charts don't reject key typos — see tools/bin/README.md)
3. **Check for rationale comments before overriding "odd" config** — deliberate decisions are documented inline (why the thanos-operator uses `bundle.yaml` instead of its helm chart, why some kustomizations have `prune: false`, why `mirror.sh` passes `--remove`). If a choice looks wrong, look for the comment explaining it first. And when you make a non-obvious decision yourself, **leave one** — future you will have forgotten it

**Reconcile and wait:**
- **Reconcile from the root any time you change a file**: `flux_wait` — reconcile + bounded progress poll in one; exit 0 green, exit 1 timeout with the pending list + diagnose hint. (Reconcile-only, no wait: `flux reconcile kustomization local --with-source`.)
- Where no wait script exists (`flux_wait`, `velero_wait`), poll with bounded `until` loops that **echo progress each iteration**, not blind sleeps or silent loops that look hung. Test exit codes / existence (`until ! kubectl get <thing> >/dev/null 2>&1; do ...`), not output parsing — kubectl prints "No resources found" to stdout, so `wc -l` checks never match
- **Estimate the reconcile duration first, then cap the poll at ~2× that** (a root reconcile settles in ~2-3m). When the cap is hit, stop polling and diagnose — a stuck loop means a real problem, not slowness. Triage ladder (diagnose commands + common causes): [runbooks/local/reconciliation-stuck.md](runbooks/local/reconciliation-stuck.md)

**Final checks:**
1. Green everywhere: `kubectl get helmreleases -A` (kustomizations are already covered by `flux_wait`'s exit code)
2. `policy_report` → failures: 0 expected (skips = exceptions); also lists stale reports for gone resources
3. `nsa_scan` (kubescape NSA) for compliance — baseline **92.3, zero failing controls** (kubelet controls C-0069/C-0070 are `notEvaluated` without the operator's node-agent — the lean ceiling; see `manifests/local/notes.md`). Accepted findings + reasons in `manifests/local/notes.md` and `security-config/*.security-exception.yaml`

## Admission policy (read this before adding any workload)

Full checklist for new workloads: [runbooks/local/adding-a-workload.md](runbooks/local/adding-a-workload.md).

All 11 kyverno ValidatingPolicies are in **Deny** mode — non-compliant pods/jobs are rejected at admission:

- All containers + initContainers need cpu/memory **requests and limits**
- Pinned image tags (no `:latest`), `runAsNonRoot`, seccompProfile `RuntimeDefault`, capabilities dropped `ALL`
- Policies autogen to controllers, but **not ReplicaSets** (removed to avoid old-RS noise). Old PolicyReports for unmatched resources are never retracted — delete stale report objects directly if needed
- **PolicyExceptions** (`manifests/local/policies-config/*.policy-exception.yaml`) cover deliberate Talos-in-Docker settings (hostNetwork kyverno, privileged velero node-agents, cilium, node-exporter, kube-system system components, alloy host-logs, local-path helper pod, thanos-ruler config-reloader sidecar). They're scoped by namespace + name prefix — don't try to "fix" these workloads
- **Helm hook jobs are admission-checked too**. Known-proofed: cert-manager `startupapicheck.resources` (all-lowercase key!), velero `upgradeJobResources`, kube-prometheus-stack `prometheusOperator.admissionWebhooks.patch.resources`, seaweedfs-operator uses cert-manager for webhook certs (no certgen jobs). When adopting/upgrading a chart, render its hook jobs (`helm template`, filter `kind: Job`) and size them

## Resource sizing conventions

Evidence-based, not defaults: requests lean (10-50m CPU), **CPU limits generous for bursts** (200m-2000m). Throttling is the silent killer — `cpu_audit` ranks the throttled containers; for a single suspect, `prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'` (port-forward lifecycle handled). Memory: request ≈ P99 × 1.2, limit = 1.5 × request (velero is 2× deliberately — kopia repo-maintenance spikes OOM-killed it at 1.5×; rationale comment in `backups/velero.helm-release.yaml`). Burst-heavy delivery components (flux source/helm-controllers) need 1000m CPU / 512Mi-1Gi or they wedge the whole pipeline.

## Storage: local-path and non-root workloads

local-path-provisioner creates **world-writable (0777)** dirs (`mkdir -m 0777`), so non-root workloads can write PVCs — but only on **fresh deploy**. Retrofitting root-owned data needs a one-time chown. `main.seaweed.yaml` documents this; seaweedfs runs as 65534. The helper pod image is pinned via `helperImage.tag` (must not be `:latest` — admission denies it, silently breaking all PVC provisioning).

## CR-managed workloads (not helm values)

grafana (`Grafana` CR), thanos ×3, alertmanager (`Alertmanager` CR) → `monitoring-config/`; seaweed cluster + `seaweedfs-admin` (plain Deployment) → `objects-config/`. Resources/security contexts go in the CR specs (`resourceRequirements`, `securityContext`, per-component `podSecurityContext`/`containerSecurityContext`).

## tools/bin

Helper scripts for the repeated plumbing (direnv adds `tools/bin` to PATH; invoke as `tools/bin/<name>` otherwise). **Check here before formulating any kubectl/jq/prometheus/docker command by hand** — audits (`memory_audit`/`cpu_audit`/`request_audit`/`policy_report`/`nsa_scan`), observability queries (`prometheus_query`/`loki_query`/`mailpit`), and waits (`flux_wait`/`velero_wait`) already exist and handle the plumbing you'd get wrong inline: port-forward lifecycle, Mi/Gi/m normalization, bounded polling. When a task needs more than a round or two of throwaway plumbing anyway, promote it to a new script here instead of re-deriving it next time (the proven pattern: `policy_report`/`cpu_audit`/`kyverno_unblock` all started as inline jq — see cmdshift/platform#21).

Full reference — what each does, arguments, defaults, exit codes, gotchas: [tools/bin/README.md](tools/bin/README.md). One-line map: `yaml_lint` (manifest lint), `helm_verify` (HelmRelease values render check), `flux_wait` (reconcile root + bounded poll), `memory_audit`/`cpu_audit` (usage-vs-**limits**), `request_audit` (usage-vs-**requests**, the scheduling side), `policy_report` (admission results), `nsa_scan` (kubescape NSA), `kyverno_unblock` (hostNetwork rollout deadlock), `prometheus_query`/`loki_query`/`mailpit` (observability), `velero_wait` (backup/restore poll), `rustfs` (rc CLI in the storage container), `cilium_test` (connectivity test + temp scaffolding).

## Hygiene

- **No live patches — everything in files**: never fix drift with `kubectl edit`/`talosctl patch`/`docker exec` mutations (flux root `local`/`main` bucket edits during a wedge are the documented exception). Change the manifest or terraform template and reconcile; if the fix needs a rebuild, note the pending state in `manifests/local/notes.md`.
- **local-vs-cloud notes**: `manifests/local/notes.md` (inventory of deliberately local-only settings + rationale) and `manifests/cloud/notes.md` (what to do differently in the cloud cluster). When you add or change a setting that's local-only, or learn something the cloud cluster must do differently, record it in the matching file. In-repo markers (`# remove in the cloud`, `# true in the cloud`) stay the source of truth at the value itself; the notes carry the "why" and the cloud-side action.
- **Rationale comments**: when you make a non-obvious decision (sizing after observed P99, a deliberate `prune: false`, a workaround for a landmine), leave the inline comment at the value — then link the notes/runbook/issue if there's more context.

## Landmines

### Charts

- **kyverno**: `admissionController.container.resources` is nested (unlike background/cleanup/reports); `config.webhooks` is a **map** (a list is silently dropped by helm merge); `backgroundScanInterval: 1h` (5m caused a reports-controller CPU ramp — cmdshift/platform#17); controllers use hostNetwork → rollouts deadlock on host ports (`kyverno_unblock` deletes the old pods)
- **cert-manager**: values keys all-lowercase (`startupapicheck`), camelCase fails chart schema and blocks the whole dependency chain
- **seaweedfs-operator**: setting `spec.admin` on the Seaweed CR *enables* a new component — only set component sections intentionally
- **velero**: node-agents are privileged by design ("remove in the cloud" comments mark local-only settings). Backs up to rustfs: bucket `backups` at `s3.cloud.test`, user `backups-user` via secrets-server payload `backups/velero-s3-credentials` (key `default`), egress via the velero CNP's `toFQDNs: s3.cloud.test` rule — seaweedfs is no longer involved. FSB skips hostPath PVs — the StorageClasses carry `defaultVolumeType: local` so **new** PVCs get `local` PVs and are volume-data protected; all 8 PVs converted with the 2026-09-05 rebuild (the one-shot rebuild includes shipping the `node-agent-config` configmap with the velero release). The temporary data mover pods (velero 1.15+ hosting-pod design) need the velero PolicyException + the `node-agent-config` configmap — the configmap **ships with the release in `backups/`**, not `backups-config/`: velero exits at startup if the flag's configmap is missing, and a fresh bootstrap wedged circularly (`backups` never Ready → `backups-config` can't apply the CM) before the move (runbook has the story). Delete backups with `velero backup delete`, never `kubectl delete backup` — kubectl leaves the S3 objects and backup-sync resurrects the Backup CR from storage within minutes. Operations: [runbooks/local/velero-backups.md](runbooks/local/velero-backups.md)
- **thanos-operator**: deployed from its repo's `bundle.yaml` via kustomization, not its helm chart — the chart embeds ~2.5MB of CRDs in the release manifest, blowing helm's 1MB release-secret cap (rationale comment in `monitoring/thanos-operator.kustomization.yaml`). The operator's status conditions are unreliable (`ReconcileFailed=True` is sticky from bootstrap status-races) — verify health via workloads and logs, not conditions. **Ruler alerting depends on the query seeing the prometheus head** — the sidecar endpoint is wired manually via `additionalArgs` in `main.thanos-query.yaml` (label-based discovery can't see the chart-managed discovery service); if ruler rules silently never fire, check `prometheus_query --query 'count(kube_pod_container_status_restarts_total)'` against the query svc — empty means the head path is broken again. Alert delivery lands in mailpit (http://mail.cloud.test)
- **AlertmanagerConfig** (`monitoring.coreos.com/v1alpha1`): child-route `matchers` are **structured Matcher objects** (`{name, value}`), not PromQL strings — strings fail the validating webhook with an opaque "invalid". Receiver names that look like YAML nulls (`name: null`) must be quoted (`name: "null"`) or the CRD rejects the object before the webhook even sees it. Both hit live in `monitoring-config/mail.alertmanager-config.yaml`

### Flux APIs

- **Kustomizations**: `wait: true` **ignores** `spec.healthChecks` — gate custom resources on real operator status with `spec.healthCheckExprs` (CEL; in use on the `*-config` kustomizations); copy battle-tested expressions from https://fluxcd.io/flux/cheatsheets/cel-healthchecks/ (ClusterIssuer, ClusterSecretStore, etc. — only the apiVersion **group** is matched, `kind` optional for group-wide entries). Verify new API fields against the **on-cluster CRD schema** before pushing (`kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'`) — undeclared fields fail the root dry-run ("field not declared in schema") and wedge the whole dependency chain (`healthyWhen` did exactly this). When unsure of a flux/CRD API shape, fetch the upstream docs or CRD (webfetch) instead of guessing
- the root `local` Kustomization and `Bucket` source are managed by the `flux-config` kustomization (`manifests/local/flux-config/`, `force: true` adopts them from the terraform bootstrap's helm-hook objects on every fresh install). They're duplicated in `cluster/local/bootstrap` `extraObjects` — close enough, not identical (the bootstrap twin is minimal; flux-config converges both objects to its spec on first reconcile). A bad edit to either (path, sourceRef, endpoint) wedges the pipeline: everything keeps running but nothing applies. Fix forward with `kubectl -n flux-system edit kustomization local` (or `edit bucket main`) — **never delete** them (the root has `deletionPolicy: Orphan`, but its absence stops all reconciliation)

### Tooling

- **helm**: release manifests are persisted in the `sh.helm.release.*` Secret, which caps at **1MB** — charts embedding large CRDs fail at install with `data: Too long: may not be more than 1048576 bytes`. Prometheus CRDs avoid the limit by shipping as the separate `prometheus-operator-crds` chart
- **rustfs** (`rc` CLI — use the `rustfs` wrapper, a passthrough in the `storage-cloud-test` container with the admin alias preset): `rc rm --recursive` silently removes nothing (exits 0, reports success) — use `rc object remove` per key or `rc mirror --remove`; `rc ls` needs `--recursive` to show objects under a prefix. Buckets/users/policies are auto-provisioned by the container entrypoint from the `buckets` list in `cluster/local/conf/outputs.tf` (user is `<bucket>-user`, password `password`) — bucket changes recreate the container and wipe its data, but the sync container re-mirrors the `flux` bucket from the local manifests. Procedures: [runbooks/local/rustfs-operations.md](runbooks/local/rustfs-operations.md)

## Runbooks

Procedures live in `runbooks/local/` (for agents and humans alike):

Incident response:
- [reconciliation-stuck.md](runbooks/local/reconciliation-stuck.md) — triage ladder for kustomizations that won't go Ready: diagnose commands + common causes
- [crashloop-investigation.md](runbooks/local/crashloop-investigation.md) — exit codes, OOM vs leak, usage-vs-limits audit, prometheus trend queries, sizing per convention
- [pipeline-wedged.md](runbooks/local/pipeline-wedged.md) — manifest edits not reaching the cluster: sync container / bucket source / root kustomization decision tree
- [helmrelease-stuck.md](runbooks/local/helmrelease-stuck.md) — admission check first, then the reconcile → suspend/resume → uninstall escalation ladder

Routine operations:
- [cluster-rebuild.md](runbooks/local/cluster-rebuild.md) — fresh bootstrap from terraform: procedure, expected timeline (~10m, one shot), verification list, data implications
- [velero-backups.md](runbooks/local/velero-backups.md) — nightly backup check, test backups, the deletion trap, BSL troubleshooting
- [rustfs-operations.md](runbooks/local/rustfs-operations.md) — rc CLI quirks, bucket/user provisioning, verifying bucket contents
- [cilium-connectivity-test.md](runbooks/local/cilium-connectivity-test.md) — full-cluster cilium validation: temp scaffolding for the three admission layers (kyverno exception, PSS labels, allow-all CNP vs the egress default-deny), run + cleanup; `tools/bin/cilium_test` automates it
- [adding-a-workload.md](runbooks/local/adding-a-workload.md) — the full checklist: sizing, security context, hook jobs, network policy, secrets, wiring

Changes with landmines:
- [adopting-a-chart.md](runbooks/local/adopting-a-chart.md) — the 1MB release-secret check, CRD split strategies, hook sizing, patching rules
- [memory-sizing-audit.md](runbooks/local/memory-sizing-audit.md) — proactive cluster-wide audit: usage-vs-limits join, prometheus cardinality, sizing decisions
