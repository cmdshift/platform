---
name: skill-improvement
description: Modifying existing agent skills — keeping the thin-dispatcher shape, the frontmatter trigger language, the trap list current, and the AGENTS.md dispatch table in sync. Load when a skill's steps, triggers, or trap list need updating, or when session learnings contradict one.
---

# Improving skills

Skills live in `.agents/skills/<name>/SKILL.md` with `name`/`description` frontmatter. They're the load-on-demand layer over AGENTS.md's dispatch table; detail may live in the paired runbook, but the skill must stay self-sufficient for its trigger.

## 1. What a change to a skill must keep true

- **Frontmatter `description` is the trigger surface** — it's what gets matched ("Load when…"). New triggers, scope changes, or renamed procedures update the description first; the body second.
- **Thin-dispatcher shape**: the skill carries the decision procedure and trap list; worked examples and full narratives live in the runbook (`runbooks/local/`) — link, don't duplicate. If content in a skill duplicates a runbook section, one of them owns it and the other links.
- **The trap list must stay current** — this is the hard rule from AGENTS.md ("skills are thin dispatchers; detail may live in the runbook, but the trap list must stay current"). A landmine that cost a debugging round gets added to the owning skill's trap list in the same change, with its `cmdshift/platform#N` ref.
- **No dates, no "as of"** — timeless rules only; the dated story goes in `CHANGELOG.md` (the `docs-sweep` skill's writing rules apply verbatim to skills).

## 2. Sync points (a skill edit isn't done until these match)

- **AGENTS.md dispatch table** — new skill → new row (name + load-when); renamed/re-scoped skill → row updated. The table is the entry point agents read first; a skill missing from it is undiscoverable.
- **Paired runbook** — if the skill links `runbooks/local/<topic>.md`, the procedure change lands in both in the same edit.
- **Cross-references in other skills** — skills link each other (`platform-workflow` → `reconcile-stuck`, `making-a-commit` → `opening-a-pull-request`); a rename or scope change sweeps those links.

## 3. Procedure

1. Read the target skill fully + its runbook before editing; match structure and tone (numbered steps, fenced command blocks, `## Full detail` linker at the bottom when a runbook exists).
2. Make the edit — add steps in place, don't append unstructured paragraphs.
3. Update the sync points above.
4. Verify: frontmatter still parses (name matches the directory), links resolve relative to the skill dir (`../../../runbooks/...` from `.agents/skills/<name>/`).
5. CHANGELOG entry for the change that motivated it (ref `cmdshift/platform#N`).

## 4. Adding vs editing

A recurring procedure that fits no existing skill → propose a new one (frontmatter + dispatch-table row together — a new skill without its AGENTS.md row doesn't exist). A near-duplicate of an existing one → extend the existing skill instead; skill sprawl is the failure mode (see the convention's origin: every rule here exists because a violation was hit live, cmdshift/platform#43 lineage).
