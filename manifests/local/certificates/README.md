# certificates

cert-manager + kubelet-csr-approver, plus `certificates-config/` (ClusterIssuer).

## Decisions and gotchas

- **cert-manager values keys are all-lowercase** (`startupapicheck`) — camelCase fails the chart schema and blocks the whole dependency chain.
- **Explicit container-level uid/gid** set per the hardening baseline (the chart only sets pod-level non-root; see [README at manifests/local](../README.md)).
- Webhook-cert consumers elsewhere depend on this group: the rabbitmq operators' `inject-ca-from` annotations and Certificate `dnsNames` bake the namespace at render time (patched in [datastores](../datastores/README.md)) — that's why `datastores` dependsOn `certificates`.
- kubelet-csr-approver lives in `kube-system` (cluster plumbing, per the namespace convention).
