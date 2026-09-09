# certificates

cert-manager + kubelet-csr-approver, plus `certificates-config/` (ClusterIssuer).

## Decisions and gotchas

- **cert-manager values keys are all-lowercase** (`startupapicheck`) — camelCase fails the chart schema and blocks the whole dependency chain.
- **Explicit container-level uid/gid** set per the hardening baseline (the chart only sets pod-level non-root; see [README at manifests/local](../README.md)).
- Webhook-cert consumers elsewhere may depend on this group: the (removed, cmdshift/platform#52) rabbitmq operators' `inject-ca-from` annotations and Certificate `dnsNames` baked the namespace at render time — the trap to remember for any vendored cert-manager wiring. `datastores` dependedOn `certificates` only for those; it has no current consumer.
- kubelet-csr-approver lives in `kube-system` (cluster plumbing, per the namespace convention).
