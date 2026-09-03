# Helm Release Resource Requests & Limits - Verification Notes

## Overview
Added commented-out resource request and limit structures to all 9 helm-release YAML files in the manifests directory. This document provides verification results against official Helm chart repositories.

## Verification Summary

### ✅ VERIFIED - Correct Placement

1. **alloy.helm-release.yaml**
   - Resources placed under `alloy:` section
   - ✅ Matches grafana/alloy official chart pattern
   - Reference: https://github.com/grafana/alloy/blob/main/operations/helm/charts/alloy/values.yaml (line 137)

2. **cilium.helm-release.yaml**
   - Resources placed at top-level `values:` section
   - ✅ Matches cilium/cilium official chart pattern
   - Reference: https://github.com/cilium/cilium/blob/main/install/kubernetes/cilium/values.yaml#L337-L343
   - Note: Cilium also defines `initResources` for init containers

3. **kyverno.helm-release.yaml**
   - Resources placed in each controller section: `admissionController`, `backgroundController`, `cleanupController`, `reportsController`
   - ✅ Matches kyverno/kyverno official chart pattern
   - Reference: https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml#L1569-L1676
   - Each controller has independent resource configuration

4. **metrics-server.helm-release.yaml**
   - Resources placed at top-level `values:` section
   - ✅ Matches kubernetes-sigs/metrics-server official pattern
   - Reference: https://github.com/kubernetes-sigs/metrics-server/blob/main/charts/metrics-server/values.yaml

5. **kube-prometheus-stack.helm-release.yaml**
   - Resources placed in component sections: `alertmanager`, `prometheus`, `grafana`
   - ✅ Matches prometheus-community/helm-charts official pattern
   - Each component has independent resource configuration

### ⚠️ NEEDS VERIFICATION - Limited Documentation

6. **flux.helm-release.yaml**
   - Resources placed under `kustomizeController.container:`
   - ⚠️ Flux2 official chart is minimal; placement appears reasonable but unconfirmed
   - Recommendation: Verify against fluxcd/flux2 official chart documentation

7. **kubelet-csr-approver.helm-release.yaml**
   - Resources placed at top-level `values:` section
   - ⚠️ Repository access limited; couldn't verify official chart
   - Recommendation: Verify against kubelet-csr-approver/kubelet-csr-approver repository

8. **velero.helm-release.yaml**
   - Resources placed under component sections: `initContainers`, `nodeAgent`
   - ⚠️ Repository access limited; placement follows standard Helm pattern
   - Recommendation: Verify against vmware-tanzu/velero official chart

9. **local-path-provisioner.helm-release.yaml**
   - Resources placed at top-level `values:` section
   - ⚠️ Repository access limited; placement follows standard Helm pattern
   - Recommendation: Verify against rancher/local-path-provisioner official chart

## YAML Structure Format

All resources follow the standard Kubernetes format with commented-out placeholders:

```yaml
resources:
  requests:
    cpu: ""
    memory: ""
  limits:
    cpu: ""
    memory: ""
```

## Next Steps

1. **Populate resource values** based on your cluster's observed resource consumption
   - Start with realistic requests (typically 80% of typical usage)
   - Set limits to 150-200% of typical usage
   - Use `kubectl top pods` to monitor actual consumption

2. **Verify unconfirmed charts** (items 6-9) against their official documentation

3. **Test in staging** before deploying to production

4. **Monitor metrics** after enabling resources to validate thresholds

## Related Documentation

- Kubernetes Resource Management: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Helm Values Best Practices: https://helm.sh/docs/chart_best_practices/values/
