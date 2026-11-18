# scanning-config

Local-config overlay for the [scanning](../scanning/README.md) group: the namespace ResourceQuota + the vendored ClusterComplianceReports.

## Decision tables

| object | why | ref |
|---|---|---|
| `scanning.resource-quota.yaml` | trivy-operator + trivy-server + up to 3 concurrent scan jobs (`scanJobsConcurrentLimit`) — scan bursts peak ~768Mi each; headroom for one rollout overlap. 2026-11 re-audit: usage 736Mi/4Gi, VPA-shaped sum 483Mi, surge fit clean on all four faces — values unchanged (cmdshift/platform#186) | cmdshift/platform#93, cmdshift/platform#186 |
| `k8s-{nsa-1.0,pss-baseline-0.1,pss-restricted-0.1}.cluster-compliance-report.yaml` | vendored from aqua/trivy-operator chart 0.36.0 — **re-vendor deliberately on chart bumps**; CIS excluded: node-collector hostPath mounts don't exist on Talos ([security/README.md](../security/README.md)) | — |
