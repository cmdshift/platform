# certificates-config

Local-config overlay for the [certificates](../certificates/README.md) group: the selfsigned ClusterIssuer + the namespace ResourceQuota (sized to the namespace audit, 2× request-sum headroom — cmdshift/platform#93).
