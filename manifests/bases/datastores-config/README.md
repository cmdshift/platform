# datastores-config

Local-config overlay for the [datastores](../datastores/README.md) group: the namespace ResourceQuota (sized to the namespace audit, 2× request-sum headroom — cmdshift/platform#93).

## ResourceQuota

`ResourceQuota/compute` (namespace `datastores`): the rollout-overlap clause is checked against **all four quota faces, not just memory** — the 2026-11 re-audit (cmdshift/platform#186) found the strimzi wedge still latent on `limits.cpu` after the #186 memory repair: operator limits sum 3500m (cnpg 1000 + opensearch 1000 + strimzi 1000 + valkey 500) plus a strimzi surge pod's 1000m exceeded the old 4 cap, so `limits.cpu: 5`. Requests side: operators' request sum 520Mi, surge pod 256Mi requests / 384Mi limits → 800Mi/1200Mi holds (VPA-shaped sum 480Mi + strimzi target 309Mi surge = 789Mi, tighter but still inside). A quota-exceeded ReplicaSet does not self-heal when the quota is raised — annotate the stuck RS (cmdshift/platform#155). Quota gets re-checked when the first Kafka CR lands (brokers + entity operator + PVCs).

