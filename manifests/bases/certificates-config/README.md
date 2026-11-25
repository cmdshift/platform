# certificates-config

Local-config overlay for the [certificates](../certificates/README.md) group: the selfsigned ClusterIssuer + the namespace ResourceQuota (sized to the namespace audit, 2× request-sum headroom — cmdshift/platform#93; re-audit: usage 224Mi/500Mi, VPA-shaped sum 171Mi, P99s ≤73Mi, surge fit clean — values unchanged, cmdshift/platform#186).
