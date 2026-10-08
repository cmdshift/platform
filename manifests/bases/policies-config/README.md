# policies-config

Config objects for the admission-policy engine — the PolicyException registry, the 13 kyverno ValidatingPolicies (Deny mode), the first GeneratingPolicy, and the explicit kube-system PDBs. The `policies` operator itself lives in [policies/](../policies/README.md); admission requirements live there too, and the workload checklist in [runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md).

This kustomization **prunes** (test-bed posture, cmdshift/platform#84): deleting or renaming an exception/policy/PDB file here GCs the object from the cluster on the next reconcile — deletions are reviewed in PRs, and kyverno background scans act as the tripwire (a GC'd PolicyException re-fails its pods' validation, so `policy_report` failures go non-zero within one scan cycle).

## Contents

- `*.validating-policy.yaml` — the 13 ValidatingPolicies, all Deny mode (requests/limits, pinned tags, runAsNonRoot, seccomp, caps dropped, host namespaces/paths/ports, privilege escalation, proc mount, graceful termination, shell entrypoint). Requirements: [policies/README.md](../policies/README.md).
- `*.policy-exception.yaml` — the PolicyException registry: hostNetwork kyverno, privileged velero node-agents + data-mover pods, cilium + hubble-relay, openobserve-collector host access (host-path/nonroot/caps for the filelog+hostmetrics agent DaemonSet, cmdshift/platform#171 — replaces the retired alloy/node-exporter host-log exceptions), local-path helper pod (also excepted from `deny-shell-entrypoint` — the provisioner hardcodes `/bin/sh /script/setup`, cmdshift/platform#60), trivy scan jobs (label-scoped to `managed-by: trivy-operator` in `scanning`, not a name prefix — scan Job/pod names are hash-suffixed), tetragon agent, kube-system system components. Scoped by namespace + name prefix; matching must use `startsWith`, not `==` (see [policies/README.md](../policies/README.md)). History: the node-exporter exception once matched a second prefix, `kube-prometheus-stack-prometheus-node-exporter` (kps-vendored DS, cmdshift/platform#69) — narrowing mid-transition stopped the vendored DS from matching and the kps upgrade failed admission (helm rollbacks too, since a rollback re-applies the old release's manifest against now-unchanged policies). Stripped in cmdshift/platform#146 after kube-prometheus-stack itself was removed — only widen a prefix during an active dual-release window, don't keep dead prefixes for hypothetical ordering races.
- `policies.resource-quota.yaml` — the `policies` namespace's own compute quota, plus the `resourceFiltersInclude` entry for `[*/*,policies,*]` so kyverno's own namespace stays in scope of its policy engine where the default filters would have excluded it.
- `auto-pod-disruption-budget-multi-replica.generating-policy.yaml` — the repo's first kyverno **GeneratingPolicy** (CEL API, `policies.kyverno.io/v1`): generates a `PodDisruptionBudget` (maxUnavailable: 1) for every apps/v1 Deployment/StatefulSet with replicas > 1 in flux-managed namespaces (cmdshift/platform#84).
- `coredns.pod-disruption-budget.yaml`, `cilium-operator.pod-disruption-budget.yaml` — explicit PDBs for kube-system workloads the generate policy can't reach (below).

## The generate-vs-explicit PDB split (cmdshift/platform#84)

Every multi-replica workload must have a PDB. The baseline rule:

- **Flux-managed namespaces**: the `auto-pod-disruption-budget-multi-replica` GeneratingPolicy owns it — no PDB manifest needed. Trigger: any apps/v1 Deployment/StatefulSet with replicas > 1; `evaluation.generateExisting` covers pre-existing workloads and `synchronize` drift-heals / cleans up on trigger deletion. Escape hatch for charts shipping their own PDB: label the workload `pdb.kyverno.io/skip: "true"` — overlapping PDBs over-restrict evictions (the most restrictive wins).
- **kube-system**: explicit PDB manifests here — the GeneratingPolicy can never see kube-system workloads (next section). coredns (`selector: k8s-app=kube-dns`) and cilium-operator (`selector: io.cilium/app=operator`), both maxUnavailable: 1. coredns has a second reason for explicitness: it is talos-bootstrap-owned, not flux-managed, so a generate path couldn't own it anyway.

**maxUnavailable: 1, not minAvailable** — maxUnavailable caps concurrent voluntary evictions at 1 regardless of replica count; minAvailable: 1 would let a 3-replica database lose 2 at once. The policy's real payoff is future multi-replica databases (cloudnative-pg is deployed in `datastores/`).

## Landmine: CEL policies never see kube-system (cmdshift/platform#84)

Kyverno builds a fine-grained webhook per CEL policy (e.g. `gpol.validate.kyverno.svc-ignore-finegrained-<policy-name>` in validatingwebhookconfigurations) and that webhook's `namespaceSelector` **inherits `config.webhooks.namespaceSelector`** from the kyverno helm values (`clusters/local/policies/kyverno-values.yaml`), which NotIn-excludes kube-system/kube-public/kube-node-lease/flux-system/policies. A GeneratingPolicy (or any CEL-policy generation) targeting kube-system therefore **silently does nothing** — the background-controller just never enqueues UpdateRequests for those triggers; no error, no event, anywhere. Workloads in kube-system need explicit manifests.

## Exception + policy rationale table (migrated from file-header comments)

| exception / policy | what it allows / does | why it exists | ref |
|---|---|---|---|
| `allow-trivy-scan-jobs` | label-scoped (operator's `managed-by` label, not a name prefix — scan Job/pod names are hash-suffixed, no stable prefix), namespace `scanning` | trivy-operator scan Jobs exec `/bin/sh -c` wrappers around the trivy binary by design (the operator generates the command; no values knob) — the deny-shell-entrypoint backstop would deny every scan; trivy moved out of security/ so tetragon bootstraps early | #60 |
| `allow-velero-security-contexts` | velero/node-agent pods by name + data-mover pods (arbitrary name prefix, always the `velero.io/pod-volume-*` label) | node-agent needs privileges for node snapshots; data movers covered by require-graceful-termination — velero hardcodes `TerminationGracePeriodSeconds: 0`, no upstream knob | #111 |
| `allow-tetragon-security-contexts` | name-prefix match (`tetragon-`) on privileged/host-ns/hostPath agent pods | agent DaemonSet runs privileged with host namespaces/hostPaths — eBPF sensors need the BPF syscall, tracefs, host /proc and /sys/fs/bpf; prefix covers generated pods (tetragon-xxxxx); operator Deployment compliant as-is; the agent terminates in 1s by design (fast node shutdown, no state to drain) | #80 |
| `allow-cilium-system-components` | cilium agent/envoy/hubble-relay graceful termination | agents terminate in 1s by design (fast node shutdown, no state to drain); startsWith required for hubble-relay — autogen pods carry RS-hash suffixes | #100 |
| `allow-openobserve-collector-host-access` | collector agent hostPath/caps | hostmetrics receiver needs host fs access; revisit the caps refs after first on-cluster run | #171 |
| `allow-local-path-helper-pod` (clusters/local) | local-path helper pods exec `/bin/sh /script/setup` | the provisioner hardcodes the command (v0.0.37 provisioner.go) — deny-shell-entrypoint must be excepted or every PVC create/delete is admission-denied; also the accepted collateral for the storage exec-deny-list (the helper carries the instance label) | #60 |
| `deny-shell-entrypoint` (ValidatingPolicy) | admission-time shell/interpreter ban across flux-managed namespaces (phase-4 wave 1 set, lockstep with the exec-deny-list-* TracingPolicies) | admission backstop for the tetragon exec deny-list: container-init execs escape pod-scoped enforcement. Binary list is verbatim the tetragon deny-list's — **keep the two in lockstep**; the o2-sync Job is safe (its image ENTRYPOINT is the sync script — no shell command) | #56, #58, #60 |
| `require-graceful-termination` (ValidatingPolicy) | floor 5s grace period, not 0 | sub-5s is instant-kill in practice; the 1s system agents (cilium, cilium-envoy, hubble-relay, tetragon) are PolicyExcepted | #89 |

**Admission re-pick-up bump**: a CEL expression edit can leave admission evaluating the stale expression after the generator applied it — bump the exception's annotation to force re-pick-up (pattern used by allow-privileged-system-worloads, cmdshift/platform#31; allow-velero carried a matching bump; the engine-lag note also lives on allow-openobserve-collector-host-access).

### kyverno-values decision table (`clusters/local/policies/kyverno-values.yaml`)

| value | why | ref |
|---|---|---|
| `global.image.registry: ghcr.io` | chart default reg.kyverno.io is a vanity proxy of ghcr (token realm ghcr.io/token) — the caching proxy's pull-through to it fails silently (angos_pull_through_total miss, 404 served) while ghcr.io works; same content | #93 |
| `features.logging` format json | JSON logging: platform convention (nests under features here) | — |
| `backgroundScanInterval: 1h` | investigate: was 5m, reports-controller CPU ramped to 5+ cores | #17 |
| admission-controller memory 208Mi / reports-controller 160→240Mi, 20m CPU req | audits: steady 120Mi (peak×1.2); 7d peak 101m CPU during scan churn, limit keeps burst room (#66); memory sawtooth peaks ~178Mi during the hourly background scan, request 160Mi covers the scan-driven baseline | #66 |

`policies.resource-quota.yaml` sizing (audit 2026-09): kyverno's four controllers — 75m CPU / 744Mi req, 3700m/1424Mi limits, 4 pods (cmdshift/platform#93). CPU limits quota is generous (hostNetwork controllers burst during webhook storms).
