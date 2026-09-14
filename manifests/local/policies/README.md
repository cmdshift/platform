# policies

Kyverno (admission policy engine) + `policies-config/` (the PolicyException registry). Kyverno runs in the `policies` namespace per the namespace convention and reads PolicyExceptions from there (`features.policyExceptions.namespace: policies`).

## Deliberately local-only settings

- **`hostNetwork: true` on all 4 controllers** (`# remove in the cloud`) — docker host ports; also the cause of the rollout-deadlock landmine below.
- **PSS `privileged` labels on the `policies` namespace** (`# remove in the cloud`).
- **`backgroundScanInterval: 1h`** — 5m caused a reports-controller CPU ramp (cmdshift/platform#17).

## Admission policy

All 12 ValidatingPolicies run in **Deny** mode; requirements and the workload checklist live in [AGENTS.md](../../AGENTS.md) and [runbooks/local/adding-a-workload.md](../../runbooks/local/adding-a-workload.md). Policies autogen to controllers but **not ReplicaSets** (avoids old-RS noise); old PolicyReports for unmatched resources are never retracted — delete stale report objects directly if needed (hit live when `require-graceful-termination` landed: the pre-existing hubble-relay pod report kept failing until deleted, cmdshift/platform#89; again during the cmdshift/platform#66 sizing pass: a kube-system report with empty subjects for a pod already gone).

**Exception matching must use name prefixes (`startsWith`), not exact names (`==`)** — background scans evaluate autogen pod-level rules against hash-suffixed pod names, so an exact-name exception matches the Deployment/RS but never its pods; the background scan then re-creates a failing report on every rollout (the hubble-relay case, fixed in cmdshift/platform#100 — audit confirmed the rest of the registry was already prefix-scoped or namespace-scoped).

`require-graceful-termination` floors `terminationGracePeriodSeconds` at 5 (unset = 30s default = compliant); the 1s-terminating system agents are excepted below. preStop hooks are deliberately a convention (effectiveness can't be validated — see the adding-a-workload runbook §2b), not a policy.

`deny-shell-entrypoint` is the admission-time backstop for the tetragon exec deny-list (container-init execs escape tetragon's pod-scoped enforcement — security/README.md): its binary list is **verbatim the tetragon deny-list's and the two layers must move in lockstep** — a binary added to one enforcement layer and not the other is either a silent gap (tetragon killed it, admission passed) or a wedge (admission denies pods the runtime layer was fine with).

## PolicyException registry (`policies-config/`)

Scoped by namespace + name prefix; each needs a keep/drop decision for the cloud — don't blanket-copy the directory. Covers: hostNetwork kyverno, privileged velero node-agents + data-mover pods, cilium + hubble-relay (incl. their 1s termination grace), node-exporter, alloy host-logs, local-path helper pod, thanos-ruler config-reloader sidecar, tetragon agent (security namespace), kube-system system components.

## Kyverno landmines (all cost debugging rounds)

- **Rollout deadlock on hostNetwork ports**: new-generation pods stay Pending while every node hosts an old-generation hostNetwork pod. `kyverno_unblock` deletes the stale-generation **ReplicaSets** — pod deletion is whack-a-mole (the stale RS respawns and the deployment controller re-scales it). If the old release still lives in a former namespace, delete its **deployments** instead (cross-ns edition, hit live in the namespace refactor).
- **`admissionController.container.resources` is nested** (unlike background/cleanup/reports).
- **`config.webhooks` is a map** — a list is silently dropped by the helm merge.
- **PolicyException CEL updates can lag in the admission engine** even after the generator logs them — bump the object (annotation via manifest) to force re-pick-up.
- **`features.logging.format: json`** is the JSON-logging knob — it nests under `features:`; top-level `logging:` and `config.logging:` both render `text` silently.
- Helm hook jobs are admission-checked too; the `kyverno-scale-to-zero` uninstall hook can wedge an HR deletion (finalizer story in the `helmrelease-stuck` skill).
