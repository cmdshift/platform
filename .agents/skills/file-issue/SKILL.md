---
name: file-issue
description: Dispatch a background subagent to file a GitHub issue on cmdshift/platform when a follow-up, refactor idea, or recurring failure surfaces mid-session (rebuild races, rot traps, decomposition ideas, tooling gaps) — without blocking the main work. Load when the user says "file an issue" or when a finding deserves tracking but is out of scope for the current change.
---

# File issue (background)

Filing issues shouldn't block the session: hand the finding to a background subagent, keep working, report the issue number when it lands.

## 1. Collect the finding (main session, minutes)

Facts only, one bullet each:

- what was observed (error strings, timings, which resource/tool) and whether it self-healed
- what the follow-up is (refactor, decomposition, hardening, tooling) and why now
- evidence pointers: file paths, commands, live output snippets, `cmdshift/platform#N` refs
- proposed acceptance criteria if obvious — otherwise let the subagent draft them from the evidence

An empty finding means no dispatch. If the issue is a docs fix, dispatch `docs-sweep` instead.

## 2. Dispatch the subagent

Task tool, subagent_type `general`, background (do not wait — continue other work). Prompt skeleton (fill the brackets, pass the finding verbatim):

```
File ONE GitHub issue in this repo (cmdshift/platform) from the finding below. gh is
authenticated; the repo is the cwd's origin. This is issue-creation only — no code,
manifest, or cluster changes.

Finding:
<verbatim bullets>

Procedure:
1. Search first: `gh issue list --state open --search <keywords>` — if a live issue
   already covers it, STOP and report the existing number instead of filing a duplicate.
2. Ground the issue in the evidence (grep the named files, read the referenced manifests)
   so the body quotes real paths/commands, not guesses. Do not invent versions or
   error strings — only what the finding (or your verification) shows.
3. `gh issue create --title <title> --body-file -` with a body structured as:
   - **What** — observed behavior with evidence (error strings, live output)
   - **Why** — the cost or risk, and why it's tracked rather than fixed in passing
   - **Proposal** — candidate direction(s) with honest availability notes where relevant
   - **Acceptance** — concrete, checkable criteria
   - refs as cmdshift/platform#N (fully qualified, never bare #N)
4. Verify the issue exists: `gh issue view <number> --json number,title,url`.

Report back: issue URL + title (or the existing duplicate), plus any evidence you
could not verify from the finding.
```

## 3. Gate

The subagent files a real issue — when it reports, relay the number/URL to the user and reference it (`cmdshift/platform#N`) from the CHANGELOG entry of the change that surfaced it.
