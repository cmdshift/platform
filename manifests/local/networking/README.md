# networking

Cilium as the CNI + the cluster's network policy objects (`networking-config/`).

## Cilium is flux-adopted — values are manifest edits

The live release is the flux **HelmRelease** `kube-system/cilium` (helm storage version v2 — adopted in place over terraform's bootstrap release, which was v1): cilium value changes are manifest edits + `helm_wait` — never rebuilds (cmdshift/platform#70). Exception: with `kubeProxyReplacement: true` a values-only upgrade is not enough by itself — see the operator-restart gotcha below.

## kube-proxy is gone (cmdshift/platform#70)

`kubeProxyReplacement: true` here + Talos `proxy.disabled: true` in the node machine config (`cluster/local/nodes/templates/cluster.tftpl.yaml`). KPR is a cilium Gateway API controller prerequisite (the operator refuses the GatewayClass without it — `Gateway API support requires kube-proxy-replacement enabled`); nothing else on this cluster depended on kube-proxy DNAT (no NodePort services existed). Talos stops *rendering* kube-proxy but never deletes the already-applied DaemonSet (the ManifestApplyController applies, never prunes) — if it ever needs removing again, that's a one-time `kubectl -n kube-system delete ds kube-proxy`. **Ordering hazard**: never remove kube-proxy before KPR=true is live — the ClusterIP DNAT gap makes coredns (a ClusterIP service) unreachable and flux reconciles nothing. Verified post-cutover: `cilium-dbg status` → `KubeProxyReplacement: True [Direct Routing]`, DNS through ClusterIP fine. Masquerading is still IPTables (`bpf.masquerade` not enabled — possible future tuning, deliberately not done).

## Cilium — deliberately local-only settings

The cloud deltas are spelled out in [manifests/cloud/notes.md](../../cloud/notes.md) (the old in-repo `# remove in the cloud` / `# true in the cloud` markers are gone — the KPR/proxy.disabled deltas they marked resolved in cmdshift/platform#70; this list is the remaining inventory):

- **`version: 1.21.0-pre.2`** — pre-release pin: cilium 1.20.x crashes at agent startup on the Linux host's kernel 7.2 (`failed to probe helper … FnSetRetval for program type CGroupSock` — the verifier rejects `bpf_set_retval#187: R1 is not a scalar`, cilium/cilium#48016). Pinned in BOTH places — the bootstrap helm_release in `cluster/local/bootstrap/main.tf` AND this HelmRelease — and the two must move in **lockstep** (mirrors the thanos-operator's commit↔image-tag rule): flux adoption converges the live release to the HelmRelease's pin, so a stale bootstrap pin silently downgrades on the next reconcile. Revisit when the fix ships in a 1.20.x patch. Cloud runs the latest stable 1.20.x — this pin is a local kernel-7.2 workaround ([manifests/cloud/notes.md](../../cloud/notes.md)).
- **`hubble.ui.httpRoute.enabled: false`** — chart 1.21-pre nil-pointers when the key is absent (install dies); the explicit `false` is the workaround, set in both this values file and the bootstrap values.
- **`k8sServiceHost: localhost` / `k8sServicePort: 7445`** — cilium must reach the API server before pod networking/in-cluster DNS exists; 7445 is the per-node docker haproxy fronting the control plane (`cluster/local/nodes/main.tf`). A bootstrap chicken-and-egg that doesn't exist on real VMs.
- **`cgroup.autoMount.enabled: false` + `hostRoot`** — running-inside-a-container quirk.
- **`gatewayAPI.hostNetwork: true`** on `k8s-role/work` nodes — publishes LB ports on the docker host. Cloud: normal listeners fronted by a cloud LB.
- **`l2announcements`** — relies on the docker bridge being one L2 segment.

Keep as-is (validate under real traffic in the cloud): wireguard encryption, `ipam.mode: kubernetes`. `kubeProxyReplacement` is no longer a delta — true everywhere since cmdshift/platform#70.

## Network policy model

- Cluster-wide **egress** default-deny CCNP (`networking-config/default-deny.cilium-clusterwide-network-policy.yaml`), kube-system exempt; every namespace gets a CNP in `networking-config/` carved out for its needs. New workloads: copy the closest house pattern (`kube-apiserver` egress, intra-ns, `toFQDNs` for `*.cloud.test` companions) — checklist in the `add-workload` skill.
- **`*.cloud.test` resolves via the container port publisher** (Docker Desktop's `com.docker.backend` VM forward on macOS hosts; native docker port publishing on Linux hosts — same published ports, no VM indirection). If host curls to companions time out but cluster traffic works, restart `cloud-test` (see cluster-rebuild runbook) — a macOS/Docker-Desktop stale-binding symptom, unobserved on Linux hosts.

## Gotchas

- **A values-only helm upgrade does not restart cilium-operator** (cost a debugging round, cmdshift/platform#70): it updates the `cilium-config` ConfigMap and rolls the agent DaemonSets (`rollOutCiliumPods`), but the operator Deployment's pod template is unchanged — the process keeps OLD startup flags (the GatewayClass stayed unclaimed on a stale `--kube-proxy-replacement='false'`) until `kubectl -n kube-system rollout restart deploy/cilium-operator` (mounted-config reload). After any values change that gates an operator startup flag, restart the operator.
- Agents report `Degraded(1)` on the health module — it probes `/var/run/cilium/health.sock`, which doesn't exist because chart `health.enabled` defaults false (never enabled in any values file). Cosmetic.
- Cilium's ServiceMonitor needs `prometheus.serviceMonitor.trustCRDsExist: true` — helm-controller renders without API discovery (details in [monitoring/README.md](../monitoring/README.md)).
- Cilium has no agent log-format flag (verified via `--help`) — the alloy pipeline normalizes its logfmt lines to JSON.
- `cilium_test` (connectivity test with temp admission scaffolding): [runbooks/local/cilium-connectivity-test.md](../../runbooks/local/cilium-connectivity-test.md).
