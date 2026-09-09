# networking

Cilium as the CNI + the cluster's network policy objects (`networking-config/`).

## Cilium — deliberately local-only settings

All marked `# remove in the cloud` / `# true in the cloud` in `cilium.helm-release.yaml` / `cilium-values.yaml`; the cloud deltas are spelled out in [manifests/cloud/notes.md](../../cloud/notes.md):

- **`kubeProxyReplacement: false`** — kube-proxy stays. The cloud runs `true` (BPF service routing).
- **`k8sServiceHost: localhost` / `k8sServicePort: 7445`** — cilium must reach the API server before pod networking/in-cluster DNS exists; 7445 is the per-node docker haproxy fronting the control plane (`cluster/local/nodes/main.tf`). A bootstrap chicken-and-egg that doesn't exist on real VMs.
- **`cgroup.autoMount.enabled: false` + `hostRoot`** — running-inside-a-container quirk.
- **`gatewayAPI.hostNetwork: true`** on `k8s-role/work` nodes — publishes LB ports on the docker host. Cloud: normal listeners fronted by a cloud LB.
- **`l2announcements`** — relies on the docker bridge being one L2 segment.

Keep as-is (validate under real traffic in the cloud): wireguard encryption, `ipam.mode: kubernetes`.

## Network policy model

- Cluster-wide **egress** default-deny CCNP (`networking-config/default-deny.cilium-clusterwide-network-policy.yaml`), kube-system exempt; every namespace gets a CNP in `networking-config/` carved out for its needs. New workloads: copy the closest house pattern (`kube-apiserver` egress, intra-ns, `toFQDNs` for `*.cloud.test` companions) — checklist in the `add-workload` skill.
- **`*.cloud.test` resolves via the Docker Desktop port publisher** — if host curls to companions time out but cluster traffic works, restart `cloud-test` (see cluster-rebuild runbook), not a CNP problem.
- The monitoring CNP's `10249` egress rule is load-bearing for kube-proxy metrics (bind address fixed at the talos template level — see CHANGELOG 2026-09-06, cmdshift/platform#23).

## Gotchas

- Cilium's ServiceMonitor needs `prometheus.serviceMonitor.trustCRDsExist: true` — helm-controller renders without API discovery (details in [monitoring/README.md](../monitoring/README.md)).
- Cilium has no agent log-format flag (verified via `--help`) — the alloy pipeline normalizes its logfmt lines to JSON.
- `cilium_test` (connectivity test with temp admission scaffolding): [runbooks/local/cilium-connectivity-test.md](../../runbooks/local/cilium-connectivity-test.md).
