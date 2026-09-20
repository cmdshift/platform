---
name: opening-a-pull-request
description: PR mechanics for this repo — pre-PR verification gates, title/body conventions, closing or referencing the target issue with cmdshift/platform#N, and the docs-in-same-branch requirement. Load when the change is committed and ready for review.
---

# Opening a pull request

## 0. Gates before the PR

- All commits on the feature branch; the pre-commit gates (reconcile green, docs swept, clean status) were checked per the `making-a-commit` skill — the PR adds nothing new except the docs-in-same-branch bar: a change isn't PR-ready until the docs it invalidated are in it (AGENTS.md → Do list).
- Final verification on-cluster: `kubectl get helmreleases -A` all True, `policy_report` failures 0. State the results in the PR body — reviewers shouldn't re-derive them.

## 1. Title and body

- **Title** = the primary commit's summary, same convention: `<scope>: <summary> (cmdshift/platform#N)`.
- **Body**:
  - *What + why* — a short paragraph; the landmines hit belong here (or a pointer into CHANGELOG) so the reviewer sees the debugging that produced the diff.
  - **Issue linkage**: `Closes cmdshift/platform#N` when the PR fully resolves the issue (auto-closes on merge); `Refs cmdshift/platform#N` for partial work or context. Never a bare `#N`.
  - *Verification*: the checks run and their results (reconcile green, policy_report, drill outputs).
  - *Docs touched*: list the surfaces updated (CHANGELOG, READMEs, runbooks, skills) so the reviewer can confirm the sweep.

## 2. Mechanics

```
gh pr create --repo cmdshift/platform --base main --head <branch> --title "..." --body "..."
```

- Squash-merge is the house pattern (history shows `Merge pull request #N from cmdshift/<branch>` with clean scoped commits); the PR title becomes the history entry — make it carry the issue ref.
- The human reviews and merges; the agent's job ends at the proposed PR — ask before creating it, same as commits.

## 3. After merge

Watch the merge's effect on the cluster (a `main` merge is what the sync container mirrors; the post-merge reconcile is normally a no-op re-confirm since the feature branch was already reconciled). Follow-ups surfaced in review that won't land now get filed via the `file-issue` skill. While the PR is still **open** — new commits or review feedback — the `refining-a-pull-request` skill owns the loop (description-drift sync, change-request triage).
