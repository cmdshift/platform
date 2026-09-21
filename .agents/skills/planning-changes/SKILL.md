---
name: planning-changes
description: How to plan a change before touching manifests — map the issue to owning surfaces (group vs -config), check rationale comments first, sequence dependency groups, anticipate docs surfaces, and start on the right branch. Load when starting any non-trivial change or after pulling an issue.
---

# Planning changes

Planning happens before editing — a change to `manifests/` reconciles through the whole flux tree, so the cost of a wrong surface is a wedged dependency chain, not a failed file.

## 0. Branch first

Never work on `main`. Create a branch before the first edit: `feat/<topic>` or `fix/<topic>` (enforced convention; merge history is the precedent). If `gh issue view` says work is planned, the branch exists before any manifest changes.

## 1. Map the issue to surfaces

- **Which group owns it?** Every workload lives in one of the group dirs (`networking/`, `observability/`, `backups/`, …); the group's README carries its decisions. Cluster-protection and cross-cutting objects (PolicyExceptions, quotas, PDBs, limit ranges) live in the `-config/` dir of the group that depends on them — `policies-config/` owns cluster-protection, `<group>-config/` owns that group's CR-managed specs and quota objects.
- **Read the group README + manifests first.** Check for **rationale comments** before deciding existing config is wrong — deliberate decisions are documented inline at the value (e.g. why `mirror.sh` passes `--remove`). If a choice looks odd, find the comment before planning to "fix" it.
- **Sweep the CHANGELOG + skills for prior art.** If the landmine was hit before, it's written down (skills' trap lists, `CHANGELOG.md`, `manifests/README.md`). Re-deriving it is wasted rounds.

## 2. Sequence the dependency order

- Operators group (`<group>/`) reconciles before its config group (`<group>-config/`); the root kustomization wires `dependsOn`. A CR whose CRDs ship in a later group wedges the tree — check `sources/` + `crds/` first when adopting anything new (the `adopt-chart` skill owns that checklist).
- New kustomizations need: inner `kustomization.yaml`, root `<group>.yaml` Kustomization CR, a root list entry, and `dependsOn` on the right parents. Use an existing `-config/` group as the template.
- Distinguish **operator workloads** (helm values) from **CR-managed workloads** (grafana, the OTel collector, alertmanager, seaweed — resources/security contexts go in the CR specs, not helm values; mimir is a plain StatefulSet — [manifests/bases/observability/README.md](../../../manifests/bases/observability/README.md) and [manifests/bases/objects/README.md](../../../manifests/bases/objects/README.md) carry the split).

## 3. Anticipate the full loop

- New workload → the `add-workload` skill checklist (admission is Deny-mode; hook jobs included). Chart bump → `adopt-chart`. Resources → `resource-sizing`.
- **Docs are part of the plan**: if the change will make a decision, hit a landmine, or alter a procedure, the docs surfaces (CHANGELOG, group README, runbook, skill trap lists) will need updating — plan for it, don't discover it at commit time (`docs-sweep` skill).
- Follow-ups that don't belong in this change get filed, not forgotten (`file-issue` skill).

## 4. State the plan before executing

For multi-file or multi-group changes, lay out the surface list and sequence in a todo list (and confirm with the human when scope is ambiguous). Single-file fixes don't need a plan ritual — go.
