# networking

Cilium as the CNI + the cluster's network policy objects (`networking-config/`).

## Cilium is flux-adopted — values are manifest edits

The live release is the flux **HelmRelease** `kube-system/cilium` (helm storage version v2 — adopted in place over terraform's bootstrap release, which was v1): cilium value changes are manifest edits + `helm_wait` — never rebuilds (cmdshift/platform#70). Exception: with `kubeProxyReplacement: true` a values-only upgrade is not enough by itself — see the operator-restart gotcha below.

## kube-proxy is gone (cmdshift/platform#70)

`kubeProxyReplacement: true` here + Talos `proxy.disabled: true` in the node machine config (`cluster/local/nodes/templates/cluster.tftpl.yaml`). KPR is a cilium Gateway API controller prerequisite (the operator refuses the GatewayClass without it — `Gateway API support requires kube-proxy-replacement enabled`); nothing else on this cluster depended on kube-proxy DNAT (no NodePort services existed). Talos stops *rendering* kube-proxy but never deletes the already-applied DaemonSet (the ManifestApplyController applies, never prunes) — if it ever needs removing again, that's a one-time `kubectl -n kube-system delete ds kube-proxy`. **Ordering hazard**: never remove kube-proxy before KPR=true is live — the ClusterIP DNAT gap makes coredns (a ClusterIP service) unreachable and flux reconciles nothing. Verified post-cutover: `cilium-dbg status` → `KubeProxyReplacement: True [Direct Routing]`, DNS through ClusterIP fine. Masquerading is still IPTables (`bpf.masquerade` not enabled — possible future tuning, deliberately not done).

## Cilium — deliberately local-only settings

The cloud deltas are spelled out in [manifests/cloud/notes.md](../../cloud/notes.md) (the old in-repo `# remove in the cloud` / `# true in the cloud` markers are gone — the KPR/proxy.disabled deltas they marked resolved in cmdshift/platform#70; this list is the remaining inventory):

- **`version: 1.20.2`** — back on stable (cmdshift/platform#41): the pre-release pin was a kernel-7.2 workaround (`FnSetRetval` probe crash, cilium/cilium#48016) and 1.20.2 ships the fix (`b73ca6e8` — `bpf_core_enum_value_exists()` for HAVE_SET_RETVAL) plus the `policy: fix host identity check` commit. Still pinned in BOTH places — the bootstrap helm_release in `cluster/local/bootstrap/main.tf` AND this HelmRelease — and the two must move in **lockstep**: flux adoption converges the live release to the HelmRelease's pin, so a stale bootstrap pin silently downgrades on the next reconcile.
- **`hubble.ui.httpRoute.enabled: false`** — the chart nil-pointers when the key is absent (verified on 1.21-pre installs; kept explicit on 1.20.x, harmless). Set in both this values file and the bootstrap values.
- **`k8sServiceHost: localhost` / `k8sServicePort: 7445`** — cilium must reach the API server before pod networking/in-cluster DNS exists; 7445 is the per-node docker haproxy fronting the control plane (`cluster/local/nodes/main.tf`). A bootstrap chicken-and-egg that doesn't exist on real VMs.
- **`cgroup.autoMount.enabled: false` + `hostRoot`** — running-inside-a-container quirk.
- **`gatewayAPI.hostNetwork: true`** on `k8s-role/work` nodes — publishes LB ports on the docker host. Cloud: normal listeners fronted by a cloud LB.
- **`l2announcements`** — relies on the docker bridge being one L2 segment.

Keep as-is (validate under real traffic in the cloud): `ipam.mode: kubernetes`. `kubeProxyReplacement` is no longer a delta — true everywhere since cmdshift/platform#70.

## Encryption: wireguard (ztunnel removed, cmdshift/platform#41)

`encryption.type: wireguard` — ztunnel (`encryption.type: ztunnel`, cmdshift/platform#87) shipped only in the 1.21-pre line, so the 1.20.2 downgrade required removing it: the ztunnel values block, the HelmRelease `postRenderers` (cert-manager secret remap onto `/etc/ztunnel` filenames), the two ztunnel Certificates in `certificates-config/` (with the Certificate healthCheckExpr), and the `ztunnel-cilium` match in the cilium PolicyException all went in the same change. `networking.dependsOn certificates-config` remains (issuer still needed for other certs) but its ztunnel rationale comment is gone. The ztunnel CA-rotation runbook is retained as history; if ztunnel returns (cilium 1.21 GA), resurrect from git history — the certs are PKCS#8 + CA:FALSE-sensitive, don't re-derive from memory. Cloud notes carry the wireguard decision.

## Network policy model

- Cluster-wide **egress** default-deny CCNP (`networking-config/default-deny.cilium-clusterwide-network-policy.yaml`), kube-system exempt; every namespace gets a CNP in `networking-config/` carved out for its needs. New workloads: copy the closest house pattern (`kube-apiserver` egress, intra-ns, `toFQDNs` for `*.cloud.test` companions) — checklist in the `add-workload` skill.
- **`*.cloud.test` resolves via the container port publisher** (dockerd publishes the ports natively on Linux hosts). If host curls to companions time out but cluster traffic works, restart `cloud-test` (see cluster-rebuild runbook) — a stale-binding symptom (first root-caused on the historical macOS/Docker Desktop host's VM publisher; the host is no longer supported).

## Gotchas

- **A values-only helm upgrade does not restart cilium-operator** (cost a debugging round, cmdshift/platform#70): it updates the `cilium-config` ConfigMap and rolls the agent DaemonSets (`rollOutCiliumPods`), but the operator Deployment's pod template is unchanged — the process keeps OLD startup flags (the GatewayClass stayed unclaimed on a stale `--kube-proxy-replacement='false'`) until `kubectl -n kube-system rollout restart deploy/cilium-operator` (mounted-config reload). After any values change that gates an operator startup flag, restart the operator.
- Agents report `Degraded(1)` on the health module — it probes `/var/run/cilium/health.sock`, which doesn't exist because chart `health.enabled` defaults false (never enabled in any values file). Cosmetic.
- **The agent/operator metrics Services only render while `serviceMonitor.enabled` is true** (cost a debugging round, cmdshift/platform#146): the chart's `prometheus.metricsService` gate ANDs with the SM block, so stripping the SM values silently deleted the `cilium-agent`/`cilium-operator` headless services too — alloy's discovery lost both jobs (0 targets) with pods healthy. Fix: keep `prometheus.metricsService: true` + `operator.prometheus.metricsService: true` alongside `enabled: true`. The obsolete `trustCRDsExist` note is gone with the SM values (no SM → no CRD-render gate).
- Cilium has no agent log-format flag (verified via `--help`) — the alloy pipeline normalizes its logfmt lines to JSON.
- `cilium_test` (connectivity test with temp admission scaffolding): [runbooks/local/cilium-connectivity-test.md](../../../runbooks/local/cilium-connectivity-test.md).
- **Helm upgrade timeout on `DaemonSet/ztunnel-cilium status: 'InProgress'`** — historical ztunnel note (ztunnel removed in cmdshift/platform#41): ztunnel pods never went Ready when the local agent's gRPC server wasn't up (CA material missing or wrong encoding). Pattern generalizes: a chart DaemonSet stuck InProgress under helm remediation usually means a dependency on an in-cluster service that isn't up yet.
- **Agent memory 512Mi/768Mi (cmdshift/platform#41)** — OOM live on the busiest node (368Mi steady after the auth-proxy Gateway routes landed); alert fires via `ContainerOOMKilled` → mailpit. Old 448/672 numbers predate the Gateway L7 load.
