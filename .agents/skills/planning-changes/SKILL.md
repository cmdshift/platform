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

## 4. Write the root plan, then expand each section into a detail plan

- **Root plan first** (`.agents/temp/plans/<issue-or-topic>.md`): the source issue, the decisions made in conversation with the human (attributed, so a subagent doesn't relitigate them), and the work split into numbered **sections**. The root plan stays a **table of contents + one-paragraph summary per section** with rough `- [ ]` checklists — full detail lives only in the section detail plans, so re-reading the root plan to dispatch the next batch never means re-reading a giant document. Scratch lives in `.agents/temp/` — plans are agent scratch, not repo docs.
- **Chunk sections by logical boundary, not size** — one resource, one chart, one migration per section. Sections that look independent often have hidden dependencies (e.g. "add the migration" depends on "define the schema"): order sections by dependency and expand/dispatch in topological order — never parallel-expand sections whose inputs depend on each other.
- **One detail plan per section**, written by the `planner` subagent (see `.opencode/agents/planner.md`) into a separate, well-named file next to the root plan — e.g. `.agents/temp/plans/183-section-2-move-helm-values.md`. A detail plan is a **long, detailed checkbox checklist** for a given section: granular `- [ ]` items (one edit/command/verification each, exact files and commands), expected states, verification steps, and traps — written for a **coding/change-edit agent** that has no access to this conversation. Include the context it needs (issue ref, decisions, conventions) because the subagent starts with fresh context. Each item's expected state must be artifact-shaped (file content, command outcome, on-cluster state) so the verifier can confirm it without git.
- **Execution goes through the `executor` subagent** (see `.opencode/agents/executor.md`): hand it one detail plan file at a time; it ticks each checkbox as the step completes and verifies, leaving an accurate resume point if interrupted. It time-boxes its own troubleshooting (5 minutes, then a `## Blockers` entry) and escalates surprises so you can re-invoke the planner with current state — the plan doc stays the single source of truth.
- **Verify each executed section** with the `verifier` subagent (see `.opencode/agents/verifier.md`): dispatch it with the detail plan path; it checks every ticked item against the files on disk and cluster state (read-only, no git) and returns PASS/FAIL per item. Run it between sections and again before proposing a commit — errors caught between sections don't compound.
- Confirm the root plan's section split with the human before dispatching planners. Single-file fixes don't need the plan ritual — go.
- **All git operations stay with the primary agent** — subagents (planner, executor, verifier) never branch, add, commit, push, or stash (denied at the agent level). The primary agent creates the feature branch before dispatching an executor and owns any commit/push after the human approves.
