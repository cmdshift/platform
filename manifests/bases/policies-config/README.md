# policies-config

Config objects for the admission-policy engine — the PolicyException registry, the 13 kyverno ValidatingPolicies (Deny mode), the first GeneratingPolicy, and the explicit kube-system PDBs. The `policies` operator itself lives in [policies/](../policies/README.md); admission requirements live there too, and the workload checklist in [runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md).

This kustomization **prunes** (test-bed posture, cmdshift/platform#84): deleting or renaming an exception/policy/PDB file here GCs the object from the cluster on the next reconcile — deletions are reviewed in PRs, and kyverno background scans act as the tripwire (a GC'd PolicyException re-fails its pods' validation, so `policy_report` failures go non-zero within one scan cycle).

## Contents

- `*.validating-policy.yaml` — the 13 ValidatingPolicies, all Deny mode (requests/limits, pinned tags, runAsNonRoot, seccomp, caps dropped, host namespaces/paths/ports, privilege escalation, proc mount, graceful termination, shell entrypoint). Requirements: [policies/README.md](../policies/README.md).
- `*.policy-exception.yaml` — the PolicyException registry: hostNetwork kyverno, privileged velero node-agents + data-mover pods, cilium + hubble-relay, node-exporter, alloy host-logs, local-path helper pod, thanos-ruler config-reloader sidecar, tetragon agent, kube-system system components. Scoped by namespace + name prefix; matching must use `startsWith`, not `==` (see [policies/README.md](../policies/README.md)). History: the node-exporter exception once matched a second prefix, `kube-prometheus-stack-prometheus-node-exporter` (kps-vendored DS, cmdshift/platform#69) — narrowing mid-transition stopped the vendored DS from matching and the kps upgrade failed admission (helm rollbacks too, since a rollback re-applies the old release's manifest against now-unchanged policies). Stripped in cmdshift/platform#146 after kube-prometheus-stack itself was removed — only widen a prefix during an active dual-release window, don't keep dead prefixes for hypothetical ordering races.
- `resource-quota.yaml` — the `policies` namespace's own compute quota, plus the `resourceFiltersInclude` entry for `[*/*,policies,*]` so kyverno's own namespace stays in scope of its policy engine where the default filters would have excluded it.
- `auto-pod-disruption-budget-multi-replica.generating-policy.yaml` — the repo's first kyverno **GeneratingPolicy** (CEL API, `policies.kyverno.io/v1`): generates a `PodDisruptionBudget` (maxUnavailable: 1) for every apps/v1 Deployment/StatefulSet with replicas > 1 in flux-managed namespaces (cmdshift/platform#84).
- `coredns.pod-disruption-budget.yaml`, `cilium-operator.pod-disruption-budget.yaml` — explicit PDBs for kube-system workloads the generate policy can't reach (below).

## The generate-vs-explicit PDB split (cmdshift/platform#84)

Every multi-replica workload must have a PDB. The baseline rule:

- **Flux-managed namespaces**: the `auto-pod-disruption-budget-multi-replica` GeneratingPolicy owns it — no PDB manifest needed. Trigger: any apps/v1 Deployment/StatefulSet with replicas > 1; `evaluation.generateExisting` covers pre-existing workloads and `synchronize` drift-heals / cleans up on trigger deletion. Escape hatch for charts shipping their own PDB: label the workload `pdb.kyverno.io/skip: "true"` — overlapping PDBs over-restrict evictions (the most restrictive wins).
- **kube-system**: explicit PDB manifests here — the GeneratingPolicy can never see kube-system workloads (next section). coredns (`selector: k8s-app=kube-dns`) and cilium-operator (`selector: io.cilium/app=operator`), both maxUnavailable: 1. coredns has a second reason for explicitness: it is talos-bootstrap-owned, not flux-managed, so a generate path couldn't own it anyway.

**maxUnavailable: 1, not minAvailable** — maxUnavailable caps concurrent voluntary evictions at 1 regardless of replica count; minAvailable: 1 would let a 3-replica database lose 2 at once. The policy's real payoff is future multi-replica databases (cloudnative-pg is deployed in `datastores/`).

## Landmine: CEL policies never see kube-system (cmdshift/platform#84)

Kyverno builds a fine-grained webhook per CEL policy (e.g. `gpol.validate.kyverno.svc-ignore-finegrained-<policy-name>` in validatingwebhookconfigurations) and that webhook's `namespaceSelector` **inherits `config.webhooks.namespaceSelector`** from the kyverno helm values (`policies/kyverno-values.yaml`), which NotIn-excludes kube-system/kube-public/kube-node-lease/flux-system/policies. A GeneratingPolicy (or any CEL-policy generation) targeting kube-system therefore **silently does nothing** — the background-controller just never enqueues UpdateRequests for those triggers; no error, no event, anywhere. Workloads in kube-system need explicit manifests.
