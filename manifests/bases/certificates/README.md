# certificates

cert-manager + kubelet-csr-approver, plus `certificates-config/` (ClusterIssuer).

## Decisions and gotchas

- **cert-manager values keys are all-lowercase** (`startupapicheck`) — camelCase fails the chart schema and blocks the whole dependency chain.
- **Explicit container-level uid/gid** set per the hardening baseline (the chart only sets pod-level non-root; see the hardening baseline in [manifests/README.md](../../README.md)).
- Webhook-cert consumers elsewhere may depend on this group: the (removed, cmdshift/platform#52) rabbitmq operators' `inject-ca-from` annotations and Certificate `dnsNames` baked the namespace at render time — the trap to remember for any vendored cert-manager wiring. `datastores` dependedOn `certificates` only for those; it has no current consumer.
- kubelet-csr-approver lives in `kube-system` (cluster plumbing, per the namespace convention).
- **`certificates-config/` owns the ztunnel mesh CA** (cmdshift/platform#87): ClusterIssuer `selfsigned` + two Certificates in `kube-system` (`ztunnel-bootstrap` → `cilium-ztunnel-secrets`, `ztunnel-ca` → `cilium-ztunnel-ca`). This is the one place a Certificate's secret lands outside this group's namespaces — deliberate: the secret must exist before cilium reconciles ztunnel mode, hence `networking` `dependsOn: certificates-config` + the Certificate Ready `healthCheckExprs` entry. Landmines (PKCS#8 mandatory, CA:FALSE bootstrap, trigger-ignores-spec-changes, rotation): [runbooks/local/ztunnel-ca-rotation.md](../../../runbooks/local/ztunnel-ca-rotation.md). The `intermediate-ca` issuer remains gateway-API-only — the ztunnel CA is deliberately NOT chained to it (a yearly intermediate expiry dragging the 10y mesh CA, plus the intermediate-renewal split-brain, buys nothing: `ca_server.go` never sends the root over the wire).
