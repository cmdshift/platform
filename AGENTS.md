# AGENTS.md

Platform manifests for a Talos-in-Docker local test cluster (terraform in `cluster/local`, ignore for manifest work). Flux v2 deploys everything in `manifests/local/`.

## How changes propagate

Local file → docker sync container (`rc mirror --overwrite --remove` + inotify) → S3 bucket `flux` on **rustfs** (out-of-cluster, terraform/docker `storage` container, endpoint `s3.cloud.test`) → flux `Bucket` source (`main`, 1m interval) → `Kustomization/local` (root) → child kustomizations in dependency order.

- **Reconcile from the root any time you change a file**: `flux reconcile kustomization local --with-source`
- Poll for completion with bounded `until` loops that **echo progress each iteration**, not blind sleeps or silent loops that look hung. Test exit codes / existence (`until ! kubectl get <thing> >/dev/null 2>&1; do ...`), not output parsing — kubectl prints "No resources found" to stdout, so `wc -l` checks never match
- Verify values paths with `helm template` + the release's `values:` before reconciling

## Policy enforcement (read this before adding any workload)

All 11 kyverno ValidatingPolicies are in **Deny** mode — non-compliant pods/jobs are rejected at admission:

- All containers + initContainers need cpu/memory **requests and limits**
- Pinned image tags (no `:latest`), `runAsNonRoot`, seccompProfile `RuntimeDefault`, capabilities dropped `ALL`
- Policies autogen to controllers, but **not ReplicaSets** (removed to avoid old-RS noise). Old PolicyReports for unmatched resources are never retracted — delete stale report objects directly if needed
- **PolicyExceptions** (`manifests/local/policies-config/*.policy-exception.yaml`) cover deliberate Talos-in-Docker settings (hostNetwork kyverno, privileged velero node-agents, cilium, node-exporter, kube-system system components, alloy host-logs, local-path helper pod). They're scoped by namespace + name prefix — don't try to "fix" these workloads
- **Helm hook jobs are admission-checked too**. Known-proofed: cert-manager `startupapicheck.resources` (all-lowercase key!), velero `upgradeJobResources`, kube-prometheus-stack `prometheusOperator.admissionWebhooks.patch.resources`, seaweedfs-operator uses cert-manager for webhook certs (no certgen jobs). When adopting/upgrading a chart, render its hook jobs (`helm template`, filter `kind: Job`) and size them

## Resource sizing conventions

Evidence-based, not defaults: requests lean (10-50m CPU), **CPU limits generous for bursts** (200m-2000m). Throttling is the silent killer — check `container_cpu_cfs_throttled_periods_total` via Prometheus (port-forward `svc/kube-prometheus-stack-prometheus`, port 9090). Memory: request ≈ P99 × 1.2, limit = 1.5 × request. Burst-heavy delivery components (flux source/helm-controllers) need 1000m CPU / 512Mi-1Gi or they wedge the whole pipeline.

## Non-root + local-path

local-path-provisioner creates **world-writable (0777)** dirs (`mkdir -m 0777`), so non-root workloads can write PVCs — but only on **fresh deploy**. Retrofitting root-owned data needs a one-time chown. `main.seaweed.yaml` documents this; seaweedfs runs as 65534. The helper pod image is pinned via `helperImage.tag` (must not be `:latest` — admission denies it, silently breaking all PVC provisioning).

## Chart-specific landmines

- **kyverno**: `admissionController.container.resources` is nested (unlike background/cleanup/reports); `config.webhooks` is a **map** (a list is silently dropped by helm merge); `backgroundScanInterval: 1h` (5m caused a reports-controller CPU ramp — cmdshift/platform#17); controllers use hostNetwork → rollouts deadlock on host ports (delete old pods to unblock)
- **cert-manager**: values keys all-lowercase (`startupapicheck`), camelCase fails chart schema and blocks the whole dependency chain
- **seaweedfs-operator**: setting `spec.admin` on the Seaweed CR *enables* a new component — only set component sections intentionally
- **velero**: node-agents are privileged by design ("remove in the cloud" comments mark local-only settings). Backs up to rustfs: bucket `backups` at `s3.cloud.test`, user `backups-user` via secrets-server payload `backups/velero-s3-credentials` (key `default`), egress via the velero CNP's `toFQDNs: s3.cloud.test` rule — seaweedfs is no longer involved. Delete backups with `velero backup delete`, never `kubectl delete backup` — kubectl leaves the S3 objects and backup-sync resurrects the Backup CR from storage within minutes
- **rustfs** (`rc` CLI, run inside the `storage-cloud-test` container; admin alias: `rc alias set main http://localhost:9000 rustfsadmin rustfsadmin`): `rc rm --recursive` silently removes nothing (exits 0, reports success) — use `rc object remove` per key or `rc mirror --remove`; `rc ls` needs `--recursive` to show objects under a prefix. Buckets/users/policies are auto-provisioned by the container entrypoint from the `buckets` list in `cluster/local/conf/outputs.tf` (user is `<bucket>-user`, password `password`) — bucket changes recreate the container and wipe its data, but the sync container re-mirrors the `flux` bucket from the local manifests

## CR-managed workloads (not helm values)

grafana (`Grafana` CR), thanos ×3, alertmanager (`Alertmanager` CR) → `monitoring-config/`; seaweed cluster + `seaweedfs-admin` (plain Deployment) → `objects-config/`. Resources/security contexts go in the CR specs (`resourceRequirements`, `securityContext`, per-component `podSecurityContext`/`containerSecurityContext`).

## Ops runbook

Stuck HelmRelease escalation ladder:
1. `flux reconcile helmrelease <name> -n <ns>`
2. `flux suspend helmrelease ... && flux resume helmrelease ...` (clears Stalled + retry counters)
3. `kubectl get secrets -n <ns> -l owner=helm` → `helm uninstall <release> -n <ns>` (nuke; flux re-installs)

All 15 HelmReleases have `install/upgrade.remediation.retries: 3` and are version-pinned. Check webhook denials in `kubectl get events -n <ns> --sort-by=.lastTimestamp` — under Deny mode, blocked installs show as `admission webhook ... denied the request: Policy <name> failed`.

## Verification checklist

1. `ruby -ryaml -e 'Dir["manifests/local/**/*.yaml"].each { |f| YAML.safe_load(File.read(f), aliases: true) }'` (no python yaml available)
2. `helm template` renders with the release values
3. Root reconcile, wait for green: `kubectl -n flux-system get kustomizations` and `kubectl get helmreleases -A`
4. `kubectl get policyreports -A -o json | jq '[.items[] | .results[]? | select(.result=="fail")] | length'` → expect 0 (skips = exceptions)
5. `kubescape scan framework nsa` for compliance (baseline ~80)
