# Local cluster notes (Talos-in-Docker)

Inventory of settings in this tree that are deliberately local-only — the counterpart of `manifests/cloud/notes.md`, which records what to change for the cloud cluster. In-repo markers (`# true in the cloud`, `# remove in the cloud`) flag these at the value; this file is the list with rationale.

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

## Kubescape NSA audit (2026-09-05) — accepted findings

Scan via `tools/bin/nsa_scan`. Baseline moved 80 → **84.8**, with **zero findings outside kube-system** — every app-namespace acceptance ships as a `SecurityException`/`ClusterSecurityException` resource (`policies-config/*.security-exception.yaml`, applied by flux; kubescape reads them at scan time). The remaining findings are kube-system system components (Talos statics, CNI, coredns, kube-proxy — not manifest-owned) plus kubernetes' own default `system:*` RBAC bindings. Details:

- **thanos CR-managed pods (query/compact/store/ruler)** — the `monitoring.thanos.io` CRDs expose no `automountServiceAccountToken` and no per-container securityContext, so C-0034 (automount) and C-0017 (roFS) stay open for them. Disabling automount via SA manifests was tried and **the operator recreates the SAs on every reconcile**, reverting the field — don't fight it.
- **thanos-ruler config-reloader** — operator-injected, no resource/securityContext knobs (existing PolicyException, ~18Mi).
- **seaweed `main-master`** — no roFS (C-0017): the CR has no persistence knob for master and it writes its wal/segment files to `/data` on the container's root fs. filer/volume/s3 got roFS; filer and s3 keep a writable `/tmp` emptyDir (filer's gRPC socket, s3 temp files live there).
- **velero deployment** — the chart only exposes `securityContext` at POD level and renders it into its CRD-upgrade hook jobs too, where `allowPrivilegeEscalation` is not a legal pod field (SSA rejects it, helm upgrade fails — hit live). Its pod-level `runAsUser: 0` default is deliberate (the node-agent needs root), so container-level readOnlyRootFilesystem / caps dropping is not reachable via values; only the aws-plugin initContainer is container-hardened.
- **flux/kyverno/external-secrets/grafana-operator/thanos CRs** — kubescape's C-0013 rule requires explicit **container-level `runAsGroup`** (and ignores pod-level); charts/CRDs that can't express it are exceptioned. Where the chart allowed it, explicit uid/gid is now set (cert-manager/eso/flux/lpp/ksm/grafana-op/seaweedfs-op — kills the implicit-gid-0 hole too).
- **loki / alloy keep their SA tokens** (C-0034 accepted): loki's rules sidecar watches ConfigMaps via the API, alloy's `discovery.kubernetes` uses in-cluster config. Alloy also still runs as root (image declares no USER — covered by its PolicyException for the host-log mounts).

Audit-session learnings worth keeping:

- **thanos ruler non-root retrofit** needed `runAsUser: 65534` (numeric) at pod level, not just `runAsNonRoot: true`: the config-reloader image declares `USER "nobody"`, which kubelet can't verify against a bare `runAsNonRoot`. The PVC then needed a one-time `chown 65534` (helper pod pattern, same as seaweedfs) — the wal was root-owned from pre-hardening runs.
- **kyverno hostNetwork rollouts**: `kyverno_unblock` now deletes all old-generation pods in a single kubectl call — piecemeal deletion loses the race (the deployment controller recreates old-gen pods that re-grab freed ports; observed twice live).
- **kubescape C-0013** is really "explicit container-level runAsNonRoot **and runAsGroup**" — pod-level (or uid alone) doesn't satisfy it; the `fixPath` in the JSON output names the missing field.
- **flux2 chart securityContext REPLACES, not merges**: its templates hardcode container-sc defaults behind an if/else, so setting any value (e.g. just `runAsGroup`) silently drops APE/caps/roFS — spell out the full map (hit live; note in flux.helm-release.yaml).
- **kubescape CLI `--exceptions` silently no-ops on 4.0.13** (malformed or nonexistent files aren't even an error) — use the in-cluster `SecurityException` CRDs, which the CLI reads automatically and which fit the GitOps model. The CRDs are vendored in `crds/`.
- **kubescape score is severity-weighted over scanned resources**: excluding kube-system can LOWER the score (strips passing weight). `nsa_scan full` is the headline; `nsa_scan apps` is the prod-style app-namespace view despite its lower number.

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

## Out-of-cluster companions (`*.cloud.test`)

rustfs S3, secrets server, haproxy, mailpit, sync container — terraform/docker in `cluster/local/external`; none of this exists in the cloud, so the CNP `toFQDNs` rules (`networking-config/*.cilium-network-policy.yaml`), the Bucket endpoint (`flux-config/main.bucket.yaml`), the ClusterSecretStore URL, alertmanager's mailpit smarthost, and velero's BSL `s3Url` all resolve differently there.
