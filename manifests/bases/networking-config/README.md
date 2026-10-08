# networking-config

The cluster's CiliumNetworkPolicy/CCNP set (per-namespace CNPs + the default-deny CCNP and the ingress-proxy egress CCNP) + the local HTTPRoute. Chart landmines for cilium itself live in the [networking README](../networking/README.md).

## Decision tables

### default-deny + ingress proxying

| object | why | ref |
|---|---|---|
| `default-deny` CCNP: cluster-wide **egress** default-deny, kube-system exempt | every namespace gets a CNP carved out for its needs; new workloads copy the closest house pattern (`kube-apiserver` egress, intra-ns, `toFQDNs` for `*.cloud.test` companions) — `add-workload` skill checklist | — |
| `allow-ingress-proxy-egress` CCNP | cilium's own recommendation for Gateway/ingress under policy enforcement (docs: servicemesh/ingress-and-network-policy) — the reserved:ingress endpoint (per-node Envoy L7LB) checks its EGRESS policy on the matched-route→upstream step; without this rule the upstream dial is denied as 403 "Access denied" (src reserved:ingress → dst reserved:host, the ClusterIP frontend identity) while all L3/L4 packets forward (cilium/cilium#47617, #43519) | cilium/cilium#47617 |

### `access` CNP (the busiest — auth proxies)

| rule | why | ref |
|---|---|---|
| ingress: `fromEntities: [ingress, host]`, **no toPorts** | gateway→backend traffic arrives with the reserved:ingress identity — without an explicit ingress allow, cilium's L7 proxy denies it before it reaches the proxy pods (symptom: 403 "Access denied" from envoy, while direct pod:4180 curls 302 fine). No toPorts: the gateway L7LB evaluates its listener policy against the host/frontend identity — restricting to 4180 denied the frontend check itself (403 before any upstream dial) | #130 |
| egress hubble-ui :8081 | selectors mirror the actual pod labels (hubble-ui statefulset), not chart-invented ones; port enforced post-DNAT — service port 80 maps to targetPort 8081, so the policy must match the targetPort | — |
| egress openobserve-standalone :5080 | openobserve-auth-proxy → O2 UI/API upstream (cookie-gated dashboard) | #171 |
| egress `auth.cloud.test` :443 | Rauthy discovery + token endpoints — TLS through the companion haproxy (the :443 frontend, not the container's direct :8080) | #154 |
| egress `secrets.cloud.test` :80 | secrets server (external-secrets → plain :80; cluster consumers stay on :80) | #131 |

### per-namespace CNP carve-outs

| CNP | carve-out | why |
|---|---|---|
| `flux-system` | kube-apiserver, intra-ns, all-HTTPS egress | API server, inter-controller traffic, registries/S3/GitHub/Helm repos |
| `kube-system` | DNS, hubble, metrics-server | system plumbing (namespace is CCNP-exempt anyway; belt-and-braces) |
| `policies` | kube-apiserver/node/KubePrism → kyverno webhook 9443/443, intra-ns, metrics-port :8000 | webhook admission + the observability metrics collector scrapes kyverno's metrics-port |
| `security` (clusters/local) | kube-apiserver, host, kube-dns :53 with DNS rules | agent watches the k8s API (`tetragon.enableK8sAPI`); agent is hostNetwork — node-local paths resolve via the host entity; the agent uses `dnsPolicy Default` (node resolv.conf) so the CCNP's kube-dns allow isn't enough — keep explicit DNS egress. **No ingress section**: egress-only default-deny, metrics ports stay scrapeable (tetra gRPC is loopback-only, doesn't traverse Cilium) | 
| `scanning` (clusters/local) | kube-apiserver, `registry.cloud.test` :80, world :443, intra-ns :4954 | trivy-operator manages CRDs/leases; all image/DB pulls go through the angos caching registry (plain HTTP :80) — scan-job image refs via the chart's registry.mirror rewrite, DB via dbRegistry; world:443 stays as fallback for upstreams outside the map; trivy-operator → built-in trivy-server and scan jobs → server for the cached trivy-db on **:4954** (the chart's "4975" comment is stale, verified in the template) — this rule was LOST in the security→scanning split (`a0a41ce`) and vuln scanning silently never ran without it (#171). No ingress section (egress-only deny; metrics scrapeable) |
| `backups` (clusters/local) | `s3.cloud.test` :80, host, talos apid | S3 (rustfs via haproxy); node agent reads PVCs on the node (hostPath); talos-backup pulls the etcd snapshot from the ctrl nodes' Talos apid |
| `observability` (clusters/local) | kubelet 10250 / kube-controller-manager 10257 / kube-scheduler 10259, `s3.cloud.test` :80 | openobserve-collector agent scrapes kubelet + control-plane metrics; openobserve writes parquet data to rustfs (companion haproxy :80, velero pattern) |
| `secrets` (clusters/local) | kube-apiserver, webhook store | external-secrets operator basics |

### local-only object

`local-test-redirect.httproute.yaml`: HTTP→HTTPS redirect for `local.test` / `*.local.test`, attached to the two HTTP listeners only — the HTTPS listeners would 301 in a loop. No port: cilium renders the scheme-implied 443, the host-facing port.
