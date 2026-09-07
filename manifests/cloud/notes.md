# Cloud cluster notes (self-managed Talos)

Things to do differently from the local Talos-in-Docker cluster when standing up a cloud cluster. The inventory of deliberately local-only settings lives in `manifests/local/notes.md`.

## Storage: local-path reclaim policy + volume binding (from cmdshift/platform#12)

Both `reclaimPolicy` and `volumeBindingMode` are **StorageClass-level** settings — there is no per-PVC override in general use:

- `volumeBindingMode: WaitForFirstConsumer` — non-negotiable in a multi-node cloud cluster: volumes must bind after pod scheduling so they land on the node the pod runs on. (We already default this locally, so it carries over as-is.)
- `reclaimPolicy` — the PV snapshots the class's policy at provision time. Changing the class later only affects newly provisioned PVs; existing PVs keep `Delete` (or `Retain`) until patched individually.
  - Selective overrides: a separate `local-path-retain` class for data that can't be regenerated, or patch the PV's `persistentVolumeReclaimPolicy` directly. A PVC-level `spec.persistentVolumeReclaimPolicy` field exists upstream (KEP-3939, alpha in 1.32, feature-gated) — verify its status in our k8s version before relying on it.
  - Keep `Delete` as the class default in the cloud too: `Retain` everywhere trades accidental-deletion safety for a steady accumulation of `Released` PVs nobody cleans up. Protect the few volumes that matter, not all of them.

Bigger caveat first: local-path is node-local with no replication — a lost node is a lost volume. In the cloud it's only appropriate for rebuildable state (caches, scratch); durable data belongs on replicated storage or off-cluster S3 (the velero → rustfs pattern we already use locally). Decide the real storage story before spending time tuning local-path policy.

**Velero + local-path volume data — solved locally with a one-annotation fix** (drill 2026-09-05, runbooks/local/velero-backups.md): velero FSB skips hostPath PVs, and local-path-provisioner defaults to hostPath — but its `defaultVolumeType: local` StorageClass annotation makes it emit `local` PVs, which velero FSB backs up natively (no CSI plugin needed). The local StorageClasses carry the annotation; the cloud cluster needs the same on its StorageClasses if it keeps local-path. Velero's temporary data mover pods need resources (`node-agent-config` configmap) and a PolicyException scoped by the `velero.io/pod-volume-*` labels.

**Volume expansion**: the local classes set `allowVolumeExpansion: false` because local-path-provisioner has no expansion code at all (a `true` value just wedges any PVC resize forever — evidence in `manifests/local/notes.md`). Any real CSI StorageClass in the cloud (EBS, Ceph, …) expands natively — set `allowVolumeExpansion: true` there, and size local-path-hosted stateful workloads for the recreate-with-bigger-PVC path if any stay on local-path.

## Cilium (local: manifests/local/networking/cilium.helm-release.yaml)

What must change vs the local helm release:

- `kubeProxyReplacement: false` → **`true`** (explicitly marked in-repo: "true in the cloud") — BPF-based service routing instead of kube-proxy; on real Talos VMs the chart default (probe-based auto) is fine, but pin it.
- `k8sServiceHost: localhost` / `k8sServicePort: 7445` → the real control-plane endpoint (Talos cluster/API VIP or a proper LB). The local values point at the per-node docker haproxy (`cluster/local/nodes/main.tf`) and exist because cilium must reach the API before pod networking exists — a bootstrap chicken-and-egg that doesn't apply on real VMs.
- `cgroup.autoMount.enabled: false` + `hostRoot` → drop; that's a Talos-in-docker container quirk. Use chart defaults on real nodes.
- `gatewayAPI.hostNetwork: true` (+ `k8s-role/work` node match) → normal non-hostNetwork gateway API listeners fronted by a cloud LB. The local form exists to publish LB ports on the docker host.
- `l2announcements` → only if the cloud VMs share an L2 segment; otherwise replace with the LB story above.

Keep as-is (validate under real traffic): wireguard encryption, `ipam.mode: kubernetes`, resource sizing (re-audit — local sizing was tuned for idle test loads, not real traffic).

## Kubescape (removed locally 2026-09-06)
The kubescape operator and all its SecurityExceptions were removed from `manifests/local/` (too heavy for what it delivered; single-purpose hardening tools are the replacement — see `manifests/local/notes.md`). Do **not** reintroduce it in the cloud: the hardening settings it drove (explicit non-root uid/gid, roFS, caps drop, SA-token off) stay in the manifests as NSA-guidance comments, and the accepted-deviations baseline lives in `manifests/local/notes.md` for the replacement tools to audit against.
- Flux polling: the local cluster loosened the bucket to 5m and kustomization drift-heal to 1h for interactive determinism (single operator, frequent manual `sync_wait` + `flux_wait`). Keep the tighter 1m/10m in the cloud — with multiple operators, frequent drift-heal is the enforcement of everything-in-files.

## Tetragon (local: `manifests/local/security/`, adopted 2026-09-07)

Chart 1.7.1 from the same `cilium` HelmRepository as Cilium — no extra source. Carries over as-is: the release values, the PSS-`privileged` `security` namespace, and the `allow-tetragon-security-contexts` PolicyException scoped to the namespace + `tetragon` prefix (the agent DaemonSet is privileged with host paths `/proc`, `/sys/fs/bpf`, `/sys/kernel/tracing` by design; same shapes exist for cilium/node-exporter today).

Cloud deltas:
- **gRPC exposure**: the local cluster binds the tetra gRPC listener to node loopback (`tetragon.grpc.address: localhost:54321`) so `kubectl port-forward` + `tetra --server-address localhost:54321` works with zero node-IP exposure. That's acceptable in the cloud too for admin access through the API server, but if anything needs remote gRPC, enable `tetragon.grpc.tls` (chart supports cert-manager/cronJob methods + client-cert enforcement) — never plain TCP on a node IP.
- **Enforcement TracingPolicies**: observability-first locally; if enforcement policies ship in the cloud, stage them per-namespace (`TracingPolicyNamespaced`) and watch for workload breakage before cluster-wide `TracingPolicy`.
- **Enforcement TracingPolicies**: observability-first locally; if enforcement policies ship in the cloud, stage them per-namespace (`TracingPolicyNamespaced`) and watch for workload breakage before cluster-wide `TracingPolicy`. Stage-1 observe policies (`security-config/*.tracing-policy.yaml`, all `monitor_only`) carry over as-is; enforcement flips are manifest edits (`spec.options.policy-mode`), never `tetra tp set-mode` (flux is the source of truth). Local kernel findings to re-verify on real nodes: the linuxkit kernel lacks `bpf_lsm_*` BTF symbols so LSM-hook policies are unavailable there (kprobes on the same hooks work) — a cloud Talos kernel likely HAS working BPF-LSM (check `kallsyms | grep bpf_lsm_`), meaning `lsmhooks:` policies are possible there but the local kprobe-based policies still apply unchanged.
- Loki delivery of events relies on the alloy → Loki pipeline, which is currently broken locally (open issue in `manifests/local/notes.md`) — validate that path in the cloud from day one.
