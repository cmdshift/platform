# crds

Upstream CRD kustomizations (cloudnative-pg, emqx-operator, gateway-api) installed ahead of the operators that use them.

## Rules

- **Never prune**: deleting a CRD destroys every CR of that kind cluster-wide — CRD removal must be deliberate and coordinated, never git-driven. Each child kustomization carries the same `prune: false`-class posture; upstream CRD churn between releases would otherwise delete every CR of the kind (Gateway/HTTPRoute, Cluster/Backup, Emqx/Rebalance).
- The GitRepository tags for `cloudnative-pg-crds` / `emqx-operator-crds` must move **in lockstep with the matching chart version** — the CRDs must match the operator's API surface.
