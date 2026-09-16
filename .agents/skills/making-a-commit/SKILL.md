---
name: making-a-commit
description: Conventional commits for this repo — scope-prefixed summaries, cmdshift/platform#N refs in the body, natural splits, docs in the same change, and commit/push by explicit human permission. Load when a change is green and ready to commit.
---

# Making a commit

## 0. Gate: commit by permission only

The agent's job ends at a green reconcile + docs swept. Then **propose** the commit (message + natural split) and **ask the human before running `git commit`/`git push`** — the human reviews the diff and approves history. Never commit proactively, never push without approval.

## 1. Pre-commit gates

- Reconcile is green (`kubectl get helmreleases -A` all True, `policy_report` failures 0).
- Docs swept: the surfaces this change made stale (CHANGELOG, group README, runbook, skill trap lists, `tools/bin/README.md`) are updated **in the same change** — docs are part of the change, not a follow-up.
- `git status` is clean of unintended files (`.tmp/` scratch, kubeconfigs must never land — they live under `cluster/local/.tmp/`, gitignored).
- `git diff` reviewed: stage only intended files.

## 2. Message format

Conventional-commit style, as the history shows:

```
<scope>: <summary> (<cmdshift/platform#N>)
```

- **Scope** = the owning group or area: `policies:`, `monitoring:`, `backups:`, `networking:`, `docs:`, `feat:`/`fix:` for cross-cutting changes (both shapes are precedented — match what the change most belongs to).
- **Summary** = imperative, lowercase, no trailing period; carries the *what* in one line (e.g. `policies: auto-generate PDBs for multi-replica workloads (cmdshift/platform#84)`).
- **Refs are fully qualified**: `cmdshift/platform#N`, never bare `#N`.
- Body (when needed): the *why* + the landmines hit, in short bullets — the dated narrative lives in CHANGELOG, so the body stays lean.

## 3. Natural splits

One logical change per commit; docs and code for the same change usually land together, but a docs-only sweep of unrelated rot can be its own `docs:` commit. Multi-group batched passes (like the sizing sweep) stay one commit — splitting by group there would leave history unreconstructable. Look at the last ~10 commits before deviating from the house pattern.

## 4. Commit signing

If the developer normally signs commits (the gpg.format setting in `git config`), commits **must be signed** — do not strip, bypass, or fall back to unsigned commits. If signing fails (gpg agent timeout, passphrase prompt, `gpg failed to sign the data`), **stop and hand it back to the human** — do not troubleshoot gpg, restart agents, cache passphrases, or work around it (no `-c commit.gpgsign=false`, no env-var cache tricks). Signing setup is the developer's local environment, not the repo's, and a failed sign usually just needs the human's touch/id unlock. **If the human isn't present, just stop and wait** — an unsigned commit is not an alternative, and neither is a retry loop.

## 5. Branch discipline

Commits land on the feature branch (`feat/<topic>` / `fix/<topic>`), never directly on `main`. Push only after the human approves; the PR step is the `opening-a-pull-request` skill.
