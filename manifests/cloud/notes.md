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

## Kubescape operator (local: manifests/local/security/)

The local cluster runs the kubescape operator lean (config scanning + continuous scanning + risk acceptance only) — see `manifests/local/notes.md`. Cloud changes:

- `kubescape.downloadArtifacts: true` ("remove in the cloud" marker on the local `false`) + a `security` CNP with egress to the artifact hosts (github.com / objects.githubusercontent.com, 443) — local keeps the baked-in policy set so the one-shot rebuild has no external egress dependency.
- Consider `capabilities.nodeScan: enable` in the cloud: the kubelet controls C-0069/C-0070 are `notEvaluated` without the node-agent, capping the NSA score at ~92 locally. Real nodes make them evaluable — but budget for the node-agent's admission story (privileged hostPath DaemonSet → PolicyException + PSS) and eBPF-on-real-kernel verification.
- `capabilities.admissionController` stays **disabled** in the cloud too — kyverno owns admission there as well.
- `security-config/` holds ALL kubescape SecurityExceptions (migrated from `policies-config/`, which keeps only kyverno PolicyExceptions). Copy it wholesale, then re-review the kube-system entries: the Talos statics/kube-proxy/coredns rationales carry over (still Talos-rendered), but re-run `nsa_scan` first — the cloud cilium runs non-hostNetwork and the findings set will differ.
- `nsa_scan`'s empty `--exceptions` file stays: the ARMO-portal systemExceptions preempt in-cluster CRs on overlap regardless of cluster.
