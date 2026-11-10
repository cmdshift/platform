# datastores-config

Local-config overlay for the [datastores](../datastores/README.md) group: the namespace ResourceQuota (sized to the namespace audit, 2× request-sum headroom — cmdshift/platform#93).

## ResourceQuota

`ResourceQuota/compute` (namespace `datastores`): requests.memory 800Mi / limits.memory 1200Mi sit above the three operators' sums (requests ~400Mi, limits ~590Mi) **plus one strimzi rollout overlap** (a RollingUpdate surge pod adds 256Mi requests / 384Mi limits — the original 500Mi/750Mi sizing from the #93 audit predated strimzi (cmdshift/platform#166) and wedged every upgrade: the surge pod was denied by quota, the Deployment stayed `InProgress`, and retries exhausted into Stalled/RetriesExceeded, repaired via cmdshift/platform#186). A quota-exceeded ReplicaSet does not self-heal when the quota is raised — annotate the stuck RS (cmdshift/platform#155). Quota gets re-checked when the first Kafka CR lands (brokers + entity operator + PVCs).

