# scanning-config

Local-config overlay for the [scanning](../scanning/README.md) group: the namespace ResourceQuota + the vendored ClusterComplianceReports.

## Decision tables

| object | why | ref |
|---|---|---|
| `scanning.resource-quota.yaml` | trivy-operator + trivy-server + up to 3 concurrent scan jobs (`scanJobsConcurrentLimit`) — scan bursts peak ~768Mi each; headroom for one rollout overlap. Post-cmdshift/platform#219 arithmetic: steady request sum 512Mi (operator 448Mi + server 64Mi), limits 768Mi; worst case (operator surge + 3 scan Jobs) fits all four faces (worst limits.cpu 4000m = exactly the 4 face — pre-existing surge fit, operator CPU limit untouched); quota values unchanged (cmdshift/platform#219) | cmdshift/platform#93, cmdshift/platform#186, cmdshift/platform#219 |
| `k8s-{nsa-1.0,pss-baseline-0.1,pss-restricted-0.1}.cluster-compliance-report.yaml` | vendored from aqua/trivy-operator chart 0.36.0 — **re-vendor deliberately on chart bumps**; re-verified against chart 0.38.1 (cmdshift/platform#263): the only upstream spec-template delta is the `app.kubernetes.io/version` label (0.34.0 → 0.36.1), and the vendored files carry no chart labels → no content re-vendor; CIS excluded: node-collector hostPath mounts don't exist on Talos ([security/README.md](../security/README.md)) | cmdshift/platform#263 |
