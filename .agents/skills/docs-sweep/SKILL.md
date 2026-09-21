---
name: docs-sweep
description: Dispatch a background subagent to sweep the docs surfaces (CHANGELOG, group READMEs, runbooks, skills, tools/bin README, cloud notes) with the session's learnings while the main work continues. Load when a landmine was hit, a debugging round was spent, a decision with rationale was made, or before commit/PR — documentation is part of the change.
---

# Docs sweep (background)

Docs maintenance is a commit/PR gate (AGENTS.md → Do list), but it shouldn't block the session: collect the learnings, dispatch a subagent, keep working (reconciles, waits, other tasks), review the diff when it lands.

## 1. Collect the learnings inventory (main session, minutes)

One bullet per learning, facts only — what was hit, what cost a debugging round, what was decided and why, the file/value it applies to, and a `cmdshift/platform#N` ref if one exists. An empty inventory means no dispatch — not every change produces docs.

## 2. Dispatch the subagent

Task tool, subagent_type `general`, background (do not wait — continue other work). Prompt skeleton (fill the brackets, pass the inventory verbatim):

```
You are doing DOCS-ONLY work in this repo (no code, no manifests, no cluster commands
that mutate anything). Write or update documentation from the learnings inventory below.

Inventory:
<verbatim bullets>

Surfaces — pick by what the learnings touch (details + examples: AGENTS.md → Docs map):
- CHANGELOG.md — dated narrative (what/when/why, incident stories); append a
  reverse-chron entry, ref cmdshift/platform#N
- manifests/bases/<group>/README.md (+ manifests/README.md for cross-cutting
  conventions and the hardening-deviations baseline) — group-level decisions the
  change touched
- runbooks/local/ (incl. incidents.md) — procedures that changed, new gotchas,
  incident post-mortems
- .agents/skills/*/SKILL.md — sync any skill whose trigger, steps, or trap list
  changed (skills are thin dispatchers; the trap list must stay current)
- tools/bin/README.md — new or changed helper scripts: args, defaults, exit
  codes, gotchas
- manifests/cloud/notes.md — what the cloud cluster must do differently

Writing rules (AGENTS.md → Docs map):
- Timeless rules go in skills/READMEs/runbooks — no dates, no "as of" language;
  provenance is a cmdshift/platform#N ref. The dated story goes in the CHANGELOG only.
- Keep evidence numbers (observed usage, error strings, versions) with the value
  they justify.
- Reference issues as cmdshift/platform#N (fully qualified), never a bare #N.
- Update existing sections in place; don't duplicate content that already has an
  owner — link it.
- Read each target file before editing; match its structure and tone.

Verify before reporting: `git diff --stat` on the doc files you touched; re-read
each edit for factual consistency with the inventory. Do NOT commit.

Report back: per-surface list of what changed and why, plus anything in the
inventory you could not place (so the main session can decide).
```

## 3. Gate

The subagent edits land in the working tree — review them (`git diff` on the doc files) when it reports, resolve its "could not place" items, and fold the sweep into the commit proposal. A change is not ready to commit or PR until the docs it made stale are in the same branch.
