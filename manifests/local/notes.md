# Local cluster notes (Talos-in-Docker)

Inventory of settings in this tree that are deliberately local-only — the counterpart of `manifests/cloud/notes.md`, which records what to change for the cloud cluster. In-repo markers (`# true in the cloud`, `# remove in the cloud`) flag these at the value; this file is the list with rationale. Step-by-step procedures live in `runbooks/local/` (and as agent skills in `.agents/skills/`); this file is the decision log.

## Cilium — `networking/cilium.helm-release.yaml`

- `kubeProxyReplacement: false` — kube-proxy stays; the cloud runs `true` (marked in-repo)
- `k8sServiceHost: localhost` / `k8sServicePort: 7445` — cilium must reach the API server before pod networking/in-cluster DNS exists; port 7445 is the per-node docker haproxy fronting the control plane (`cluster/local/nodes/main.tf`)
- `cgroup.autoMount.enabled: false` + `hostRoot` — running-inside-a-container quirk
- `gatewayAPI.hostNetwork: true` on `k8s-role/work` nodes — publishes LB ports on the docker host
- `l2announcements` — relies on the docker bridge network being one L2 segment

## Kyverno — `policies/kyverno.helm-release.yaml`, `namespaces/kyverno.namespace.yaml`

- `hostNetwork: true` on all 4 controllers (marked `# remove in the cloud`) — docker host ports; also the cause of the rollout-deadlock landmine (`tools/bin/kyverno_unblock`)
- PSS `privileged` labels on the kyverno namespace (marked `# remove in the cloud`)

## Velero — `backups/velero.helm-release.yaml`

- nodeAgent `privileged: true` — local-only ("remove in the cloud" comments in the file); node snapshots against docker volumes

## PolicyExceptions — `policies-config/`

Scoped exceptions covering Talos-in-docker workloads (hostNetwork kyverno, privileged velero/cilium, alloy host-logs, local-path helper pod, node-exporter). Each needs a keep/drop decision for the cloud — don't blanket-copy the directory.

## Hardening baseline + accepted deviations (NSA audit 2026-09-05; kubescape removed 2026-09-06)

Posture was driven by a kubescape NSA scan (baseline 80 → **92.3, zero failing controls** at removal; C-0069/C-0070 `notEvaluated` was the lean ceiling). The kubescape operator + `nsa_scan` were removed 2026-09-06 — too heavy for what they delivered; single-purpose hardening tools are the replacement (section below). The hardening settings it drove stay in the manifests as `# NSA hardening:` comments. This section is the deviations ledger those tools audit against — keep it current when adding workloads. Every deviation maps to a kyverno PolicyException or an upstream/CRD limitation:

- **thanos CR-managed pods (query/compact/store/ruler)** — the `monitoring.thanos.io` CRDs expose no `automountServiceAccountToken` and no per-container securityContext, so SA-token automount and roFS stay open for them. Disabling automount via SA manifests was tried and **the operator recreates the SAs on every reconcile**, reverting the field — don't fight it. Pod-level runAsNonRoot + seccomp ARE set (the only knobs the CRD exposes).
- **thanos-ruler config-reloader** — operator-injected, no resource/securityContext knobs (existing PolicyException, ~18Mi).
- **seaweed `main-master`** — no roFS: the CR has no persistence knob for master and it writes its wal/segment files to `/data` on the container's root fs. filer/volume/s3 got roFS; filer and s3 keep a writable `/tmp` emptyDir (filer's gRPC socket, s3 temp files live there).
- **velero deployment** — the chart only exposes `securityContext` at POD level and renders it into its CRD-upgrade hook jobs too, where `allowPrivilegeEscalation` is not a legal pod field (SSA rejects it, helm upgrade fails — hit live). Its pod-level `runAsUser: 0` default is deliberate (the node-agent needs root), so container-level roFS / caps dropping is not reachable via values; only the aws-plugin initContainer is container-hardened.
- **loki / alloy keep their SA tokens**: loki's rules sidecar watches ConfigMaps via the API, alloy's `discovery.kubernetes` uses in-cluster config. Alloy also still runs as root (image declares no USER — covered by its PolicyException for the host-log mounts).
- **kubernetes/Talos defaults** — the `system:*` discovery/basic-user ClusterRoleBindings and `cluster-admin → system:masters` (the Talos admin credential group) are stock bootstrap, not manifest-owned. Talos-rendered statics (apiserver/controller-manager/scheduler, kube-proxy, coredns) likewise.
- **ConfigMap regex false positives** — findings on config keys (cilium-config, kyverno/logging CMs) are verified non-credentials (policy strings look like secrets but aren't).
- **metrics-server** — the fix-first success: its `securityContext` value is container-level; `runAsGroup: 1000` in `metrics/` cleared the finding with no exception needed.

Hardening learnings worth keeping:

- **Explicit container-level `runAsGroup` is the common gap**: several charts set pod-level non-root or uid-only (gid implicit 0). Where the chart allowed it, explicit uid/gid is now set (cert-manager/eso/flux/lpp/ksm/grafana-op/seaweedfs-op — kills the implicit-gid-0 hole too); charts/CRDs that can't express it are covered by the deviations above.
- **flux2 chart securityContext REPLACES, not merges**: its templates hardcode container-sc defaults behind an if/else, so setting any value (e.g. just `runAsGroup`) silently drops APE/caps/roFS — spell out the full map (hit live; note in flux.helm-release.yaml).
- **thanos ruler non-root retrofit** needed `runAsUser: 65534` (numeric) at pod level, not just `runAsNonRoot: true`: the config-reloader image declares `USER "nobody"`, which kubelet can't verify against a bare `runAsNonRoot`. The PVC then needed a one-time `chown 65534` (helper pod pattern, same as seaweedfs) — the wal was root-owned from pre-hardening runs.

## Request audit (2026-09-06) — memory requests rebalanced

Limits had been evidence-bumped repeatedly; requests were still at their original pass and lagged steady-state usage (`tools/bin/request_audit` — the usage-vs-requests sibling of `memory_audit`, added this session). CPU requests were verified fine (all ≤0.70 of request at P99 — lean-on-purpose, limits carry bursts; don't "fix" them).

- **Tier 1 bumped** (steady usage ≥60% of request at the 35-min post-rebuild ramp floor): seaweedfs-operator 50→120 (new `resources:` values — chart default was running at 114%), cilium-agent 256→288 (worst-node), source-controller 160→224, kyverno admission 200→208, velero node-agent 80→88, seaweedfs-admin 96→104, thanos-operator manager 64→80 (kustomize patch on the bundle), cert-manager-controller 80→96 + limit 120→144 (only limit change — 1.3× floor).
- **The kyverno bump re-landmined as predicted**: admission rollout deadlocked on hostNetwork ports — `kyverno_unblock` fixed it in one call.
- **Tier 2 recheck at 24h uptime** via `request_audit 80` (bootstrap-phase P99s overstate — first-scrape/init spikes decayed within the hour): cilium-operator (90% post-rollout), helm-controller (92%), thanos-store (105%), alertmanager + alloy config-reloaders (100-109%), grafana, alertmanager, kube-state-metrics, local-path-provisioner, hubble-relay, metrics-server, kyverno reports/cleanup, cainjector, cert-manager-webhook.
- **kube-apiserver static runs ~1.8Gi against a 512Mi request** (361%) — talos-managed, not fixable in this tree; the ctrl node's request totals understate by that gap. Only container above its request post-audit.

## Storage: `allowVolumeExpansion: false` on purpose (2026-09-06)

local-path-provisioner has **no volume-expansion support** — verified in the v0.0.37 source (only `create`/`delete` ActionTypes exist, zero resize/expand code), and non-CSI external provisioners can't expand regardless. The classes previously advertised `allowVolumeExpansion: true`, which the API accepts but nothing can ever act on: a PVC resize (e.g. a CNPG instance grow when `spec.storage.size` changes) would hang forever. Resize path locally = recreate the PVC at the larger size (velero FSB restore for data). The cloud's CSI StorageClasses expand natively — set `true` there (see `manifests/cloud/notes.md`).

## Prometheus fires to the CR-managed Alertmanager (2026-09-06)

The chart's `alertmanager` component is disabled (Alertmanager is CR-managed in `monitoring-config/`), which left the Prometheus CR's `spec.alerting` **null** — the entire kubernetes-mixin rule set (`kubernetes-storage` PV-filling, `kubernetes-apps` StatefulSet-mismatch, node alerts) was evaluated but never delivered; only thanos-ruler alerts reached mailpit. Fixed via `prometheusSpec.alertingEndpoints` → `alertmanager-operated.monitoring:9093` (same endpoint as `main.thanos-ruler.yaml`). The values key and the CR field were both verified before reconcile (`helm_verify` render + on-cluster CRD schema: `spec.alerting.alertmanagers[].{name,namespace,port,scheme}`).

## Prometheus scrapes everything (2026-09-06)

`prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false` → `serviceMonitorSelector: {}` — the chart default required a `release: kube-prometheus-stack` label that only the stack's own SMs carried, leaving kyverno ×4, thanos ×4, thanos-operator, and velero ServiceMonitors unscraped. Two chart gotchas hit live: `serviceMonitorSelector: {}` directly **doesn't work** (the template treats an empty map as falsy and falls back to the release label — only the `NilUsesHelmValues: false` path renders `{}`), and cilium's `validate.yaml` gate refuses to render SMs without `prometheus.serviceMonitor.trustCRDsExist: true` (helm-controller renders without API discovery; safe here — prometheus-operator-crds ships the CRDs). New SMs enabled: cilium-agent/operator, hubble-relay, alloy, loki (note the per-chart key shapes: alloy `serviceMonitor` is top-level, loki's lives under `monitoring:`, cilium needs the metrics `enabled: true` too — all SM keys verified by rendering via `helm_verify` before reconcile).

## kube-proxy metrics: fixed in terraform, verified after rebuild (2026-09-06)

kube-proxy 1.33+ defaults `--metrics-bind-address` to `127.0.0.1:10249` — nothing listens on the node interface, so Prometheus's targets sat at `connection refused` (not a CNP block: that times out silently; this RSTs). Fixed at the source in `cluster/local/nodes/templates/cluster.tftpl.yaml` (`cluster.proxy.extraArgs.metrics-bind-address: 0.0.0.0:10249`, same pattern as controllerManager/scheduler) — **applied by the 2026-09-06 rebuild**, not live-patched (house rule: everything in files, no `talosctl patch` drift). The monitoring CNP's `10249` egress rule (`networking-config/`) is load-bearing for this. Verified post-rebuild (cmdshift/platform#23): kube-proxy statics carry the flag, all 5 `up{job="kube-proxy"}` targets = 1, no `TargetDown`/`KubeProxyInstanceUnreachable` firing or delivered to mailpit.

## PVC volume stats arrived with the local PV conversion (2026-09-06)

`kubelet_volume_stats_*` (PVC capacity/usage — what dashboards and capacity alerts build on) only exists for volumes kubelet can stat, and **hostPath PVs are skipped** — a kubelet limitation, not a Talos one, though easy to misattribute on a Talos cluster where local-path is the provisioner. Before the 2026-09-05 conversion every PVC was hostPath-backed, so these series were silently absent. The StorageClasses' `defaultVolumeType: local` (added for velero FSB) plus the rebuild's fresh PVs made all 8 PVs `local`, and all 8 PVCs now report stats. Cloud note: if the cloud cluster ever provisions hostPath-style volumes, PVC metrics vanish the same way — dashboards/alerts on `kubelet_volume_stats_*` go quietly empty, no error anywhere.

## Loki retention + seaweed delete-path proof (2026-09-06)

Loki retention configured: `limits_config.retention_period: 30d`, `compactor.retention_enabled + delete_request_store: s3` (verified live in `/config`). Three Loki 3.x timing knobs were surprises — **`delete_request_cancel_period` defaults to 24h** (delete requests sit `received` for a day before processing), `apply_retention_interval: 15m` (processing/retention sweep cadence), `retention_delete_delay: 2h` (mark-to-physical-delete window). Both shortened locally (15m / 5m) for observable feedback — keep the defaults in the cloud.

**Seaweed delete-path evidence** (the buckets live in-cluster on seaweed, `main-s3.objects.svc:8333`): s3.json identities grant explicit `Delete:loki`, `Delete:loki-rules`, `Delete:thanos` (secret `objects/seaweedfs-s3-config`); the delete-request store round-tripped through seaweed (compactor wrote the request and read it back — same sigv4 path as DeleteObject) and processed it with zero S3 errors. **Open observable:** an actual S3 `DeleteObject` round-trip — Loki's TSDB mark/deletion internals hadn't produced a marks file yet at session end (retention worker logs `no marks file found` every minute). Confirmation = `loki_compactor_deleted_lines_total` series appearing in Prometheus (check passively; the processed request should drive it on a later sweep). Thanos compactor's 7d block deletion uses the same server + granted identity — first exercise comes when blocks age out.

## Kubescape removed (2026-09-06)

The kubescape operator (namespace `kubescape`, release in `security/`, SecurityExceptions in `security-config/`) was removed — too heavy for what it delivered (3 Deployments + a scheduler CronJob scanning for drift the manifests already pin); single-purpose hardening tools are the replacement. Removal mechanics, for the record: exceptions + namespace + CRDs deleted **manually** — everything kubescape lived under `prune: false` (security-config, crds, namespaces) by design, and helm uninstall leaves the chart's 4 extra CRDs behind (helm never removes CRDs). Post-check: 25/25 kustomizations, 15/15 helmreleases, `policy_report` failures 0. The deviations ledger it fed survives in the section above; the cloud cluster gets the same tombstone in `manifests/cloud/notes.md` (don't resurrect it there).

**Kernel-limitation intel for the replacement tools** (from the kubescape node-agent's death, kept because it generalizes — attempted + reverted 2026-09-06): the Docker Desktop linuxkit 7.0.12 kernel hosting these Talos containers ships `CONFIG_FANOTIFY_ACCESS_PERMISSIONS=n` (`docker run alpine zcat /proc/config.gz`) — fanotify **permission events** fail `EINVAL`, which killed the node-agent's container watcher at startup on every node (with `RUNTIME_PATH` set correctly; Talos keeps runc at `/usr/bin/runc`, visible only via the `/host` mount). The watcher init is unconditional, so no partial-enable workaround exists. Cilium works because eBPF needs the BPF syscall + bpf fs — a different kernel feature. Before adopting any tool that needs LSM hooks (KubeArmor), fanotify permission events, or similar, check the linuxkit kernel config first; also budget its admission story (privileged DaemonSet → PolicyException + PSS labels).

Sync-container learnings from the same session (generic, kept): the sync container's inotify drops **edits** too, not just deletes (hit twice in one session, once producing helm upgrade/rollback churn against a stale artifact) — `rustfs cat <key> | grep <marker>` before `flux_wait` for edit-heavy sessions, and `docker restart sync-cloud-test` forces a full `--remove` re-mirror when the artifact hash won't move.

## Loosened flux polling for interactive determinism (2026-09-06)

Bucket `main` 1m → **5m**, root + child kustomizations 10m → **1h** (thanos-operator already 24h). Rationale: the intervals never gate change propagation (event-driven — artifact change requeues dependents at `retryInterval: 5s`), so the manual flow (`sync_wait` + `flux_wait --with-source`) is unaffected; what loosening buys is that background reconciles stop interleaving with interactive work — the 1m bucket poll could publish a half-mirrored artifact mid-edit (sync lag is documented) and the whole chain would start applying it. Drift-heal at 1h remains the enforcement of everything-in-files. Full manual (suspend) was rejected: a suspended tree reconciles nothing on rebuild, breaking the one-shot requirement. The bootstrap twins run 1m/10m until flux-config adopts and converges them — keeps fresh rebuilds fast. Cloud: keep the tighter 10m/1m there (multiple operators make frequent drift-heal worthwhile); see `manifests/cloud/notes.md`.

## Out-of-cluster companions (`*.cloud.test`)

rustfs S3, secrets server, haproxy, mailpit, sync container — terraform/docker in `cluster/local/external`; none of this exists in the cloud, so the CNP `toFQDNs` rules (`networking-config/*.cilium-network-policy.yaml`), the Bucket endpoint (`flux-config/main.bucket.yaml`), the ClusterSecretStore URL, alertmanager's mailpit smarthost, and velero's BSL `s3Url` all resolve differently there.
