# datastores-config

Local-config overlay for the [datastores](../datastores/README.md) group: the namespace ResourceQuota (sized to the namespace audit with rollout-surge headroom — cmdshift/platform#93, re-sized for the cmdshift/platform#219 request alignment).

## ResourceQuota

`ResourceQuota/compute` (namespace `datastores`): the rollout-overlap clause is checked against **all four quota faces, not just memory** — the 2026-11 re-audit (cmdshift/platform#186) found the strimzi wedge still latent on `limits.cpu` after the #186 memory repair: operator limits sum 3500m (cnpg 1000 + opensearch 1000 + strimzi 1000 + valkey 500) plus a strimzi surge pod's 1000m exceeded the old 4 cap, so `limits.cpu: 5`. The cmdshift/platform#219 request alignment raised strimzi to 320Mi req / 480Mi limit (limits.cpu untouched): requests side 584Mi + 320Mi surge = 904Mi → `requests.memory: 1000Mi`; limits side 876Mi + 480Mi surge = 1356Mi → `limits.memory: 1400Mi` (headroom style per the cmdshift/platform#186 sizing). A quota-exceeded ReplicaSet does not self-heal when the quota is raised — annotate the stuck RS (cmdshift/platform#155). Quota gets re-checked when the first Kafka CR lands (brokers + entity operator + PVCs).

