# secrets-config

Local-config overlay for the [secrets](../secrets/README.md) group: the namespace ResourceQuota (sized to the namespace audit, 2× request-sum headroom — cmdshift/platform#93; re-audit 2026-11: usage 192Mi/500Mi, VPA-shaped sum 183Mi, P99s ≤64Mi, surge fit clean — values unchanged, cmdshift/platform#186) plus the live `ClusterSecretStore` in `clusters/local/secrets-config/` (`:80` required — the provider forces HTTPS otherwise; `remoteRef.key` is URL encoded — janky provider).
