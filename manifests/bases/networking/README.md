# networking

Cilium as the CNI + the cluster's network policy objects (`networking-config/`).

## Cilium is flux-adopted — values are manifest edits

The live release is the flux **HelmRelease** `kube-system/cilium` (helm storage version v2 — adopted in place over terraform's bootstrap release, which was v1): cilium value changes are manifest edits + `helm_wait` — never rebuilds (cmdshift/platform#70). Exception: with `kubeProxyReplacement: true` a values-only upgrade is not enough by itself — see the operator-restart gotcha below.

## kube-proxy is gone (cmdshift/platform#70)

`kubeProxyReplacement: true` here + Talos `proxy.disabled: true` in the node machine config (`cluster/local/nodes/templates/cluster.tftpl.yaml`). KPR is a cilium Gateway API controller prerequisite (the operator refuses the GatewayClass without it — `Gateway API support requires kube-proxy-replacement enabled`); nothing else on this cluster depended on kube-proxy DNAT (no NodePort services existed). Talos stops *rendering* kube-proxy but never deletes the already-applied DaemonSet (the ManifestApplyController applies, never prunes) — if it ever needs removing again, that's a one-time `kubectl -n kube-system delete ds kube-proxy`. **Ordering hazard**: never remove kube-proxy before KPR=true is live — the ClusterIP DNAT gap makes coredns (a ClusterIP service) unreachable and flux reconciles nothing. Verified post-cutover: `cilium-dbg status` → `KubeProxyReplacement: True [Direct Routing]`, DNS through ClusterIP fine. Masquerading is still IPTables (`bpf.masquerade` not enabled — possible future tuning, deliberately not done).

## Cilium — deliberately local-only settings

The cloud deltas are spelled out in [manifests/cloud/notes.md](../../cloud/notes.md) (the old in-repo `# remove in the cloud` / `# true in the cloud` markers are gone — the KPR/proxy.disabled deltas they marked resolved in cmdshift/platform#70; this list is the remaining inventory):

- **`version: 1.21.0-pre.2`** — pre-release pin: cilium 1.20.x crashes at agent startup on the Linux host's kernel 7.2 (`failed to probe helper … FnSetRetval for program type CGroupSock` — the verifier rejects `bpf_set_retval#187: R1 is not a scalar`, cilium/cilium#48016). Pinned in BOTH places — the bootstrap helm_release in `cluster/local/bootstrap/main.tf` AND this HelmRelease — and the two must move in **lockstep**: flux adoption converges the live release to the HelmRelease's pin, so a stale bootstrap pin silently downgrades on the next reconcile. Revisit when the fix ships in a 1.20.x patch. Cloud runs the latest stable 1.20.x — this pin is a local kernel-7.2 workaround ([manifests/cloud/notes.md](../../cloud/notes.md)).
- **`hubble.ui.httpRoute.enabled: false`** — chart 1.21-pre nil-pointers when the key is absent (install dies); the explicit `false` is the workaround, set in both this values file and the bootstrap values.
- **`k8sServiceHost: localhost` / `k8sServicePort: 7445`** — cilium must reach the API server before pod networking/in-cluster DNS exists; 7445 is the per-node docker haproxy fronting the control plane (`cluster/local/nodes/main.tf`). A bootstrap chicken-and-egg that doesn't exist on real VMs.
- **`cgroup.autoMount.enabled: false` + `hostRoot`** — running-inside-a-container quirk.
- **`gatewayAPI.hostNetwork: true`** on `k8s-role/work` nodes — publishes LB ports on the docker host. Cloud: normal listeners fronted by a cloud LB.
- **`l2announcements`** — relies on the docker bridge being one L2 segment.

Keep as-is (validate under real traffic in the cloud): `ipam.mode: kubernetes`. `kubeProxyReplacement` is no longer a delta — true everywhere since cmdshift/platform#70.

## Encryption: ztunnel (cmdshift/platform#87)

`encryption.type: ztunnel` replaced wireguard — Istio's ambient-mode per-node L4 proxy integrated as a cilium encryption type (beta upstream; the "ZTunnel Integration" milestone is open in 1.21). Pod-to-pod TCP gets transparent mTLS: enrolled pods' netns gets iptables HBONE redirect to the local ztunnel DaemonSet, which holds a SPIFFE workload cert (`spiffe://cluster.local/ns/<ns>/sa/<sa>`) and terminates mTLS to the remote node's ztunnel. The cilium agent hosts the xDS + internal CA gRPC server on `localhost:15012` (hostNetwork) per node.

- **CA material is cert-manager's, not the chart's** — two self-signed Certificates in `certificates-config/` (`ztunnel-bootstrap` → secret `cilium-ztunnel-secrets`, the CA:FALSE end-entity securing the agent↔ztunnel gRPC; `ztunnel-ca` → secret `cilium-ztunnel-ca`, the mesh root signing workload certs). The HelmRelease `postRenderers` remap cert-manager's `tls.crt`/`tls.key` onto the four filenames `ca_server.go` reads from `/etc/ztunnel` — a patch coupled to the chart's DaemonSet template shapes, **re-verify on every chart bump**. PKCS#8 encoding is mandatory (the CA server rejects PKCS#1, cert-manager's default); the bootstrap cert must be CA:FALSE (rustls rejects `CaUsedAsEndEntity`). Full landmine list + rotation procedure: [runbooks/local/ztunnel-ca-rotation.md](../../../runbooks/local/ztunnel-ca-rotation.md).
- **Bootstrap twin is unencrypted** (`cluster/local/bootstrap/main.tf`, `encryption.enabled = false`): the secret can only exist after cert-manager runs, and cert-manager only exists post-flux — the HelmRelease flips encryption on at first reconcile. Empirically fine: the twins already drift (values converge via adoption), and the live flip wireguard→ztunnel completed through helm remediation retries. A rebuild boots plain CNI → flux upgrades to ztunnel within the one-shot timeline.
- **Enrollment registry** — `io.cilium/mtls-enabled: "true"` namespace label; **currently empty** (the demo namespace was ad-hoc, not committed — see below). Enrolled↔non-enrolled traffic is UNSUPPORTED upstream (both endpoints must be enrolled), TCP only (UDP/DNS never redirected), and L4 CNP port-matching degrades (traffic is encrypted before it leaves the pod — only the HBONE port 15008 is visible to policy). Do not enroll namespaces carrying port-scoped L4 CNPs without re-validating them.
- **Verification was ad-hoc, not committed** (cmdshift/platform#87): an ephemeral demo namespace (labeled + deleted post-verification) proved the datapath — allowed flow 200 over HBONE (ztunnel `config_dump`: SPIFFE workload cert + pods `protocol: HBONE`), non-enrolled-identity SYN dropped, `cilium_test` green. To re-verify: create a namespace with the enrollment label + two admission-compliant pods, a CNP carrying BOTH halves (client egress + server ingress — the cluster-wide default-deny also denies enrolled egress; an ingress-only rule drops the SYN on the client side), and curl through. curl gotchas: `--retry` counts retries of FAILED attempts (no success-loop flag exists) and kubelet's restart backoff compounds even on exit-0 — `--limit-rate 1` on a small page is the shell-free long-lived-client trick.

## Network policy model

- Cluster-wide **egress** default-deny CCNP (`networking-config/default-deny.cilium-clusterwide-network-policy.yaml`), kube-system exempt; every namespace gets a CNP in `networking-config/` carved out for its needs. New workloads: copy the closest house pattern (`kube-apiserver` egress, intra-ns, `toFQDNs` for `*.cloud.test` companions) — checklist in the `add-workload` skill.
- **`*.cloud.test` resolves via the container port publisher** (dockerd publishes the ports natively on Linux hosts). If host curls to companions time out but cluster traffic works, restart `cloud-test` (see cluster-rebuild runbook) — a stale-binding symptom (first root-caused on the historical macOS/Docker Desktop host's VM publisher; the host is no longer supported).

## Gotchas

- **A values-only helm upgrade does not restart cilium-operator** (cost a debugging round, cmdshift/platform#70): it updates the `cilium-config` ConfigMap and rolls the agent DaemonSets (`rollOutCiliumPods`), but the operator Deployment's pod template is unchanged — the process keeps OLD startup flags (the GatewayClass stayed unclaimed on a stale `--kube-proxy-replacement='false'`) until `kubectl -n kube-system rollout restart deploy/cilium-operator` (mounted-config reload). After any values change that gates an operator startup flag, restart the operator.
- Agents report `Degraded(1)` on the health module — it probes `/var/run/cilium/health.sock`, which doesn't exist because chart `health.enabled` defaults false (never enabled in any values file). Cosmetic.
- Cilium's ServiceMonitor needs `prometheus.serviceMonitor.trustCRDsExist: true` — helm-controller renders without API discovery (details in [observability/README.md](../observability/README.md)).
- Cilium has no agent log-format flag (verified via `--help`) — the alloy pipeline normalizes its logfmt lines to JSON.
- `cilium_test` (connectivity test with temp admission scaffolding): [runbooks/local/cilium-connectivity-test.md](../../../runbooks/local/cilium-connectivity-test.md).
- **Helm upgrade timeout on `DaemonSet/ztunnel-cilium status: 'InProgress'`** — ztunnel pods never go Ready when the local agent's gRPC server isn't up (CA material missing or wrong encoding — see the rotation runbook); helm-controller burns `remediation.retries` and rolls back. Check `kubectl logs -n kube-system ds/cilium | grep "ztunnel gRPC"` first.
