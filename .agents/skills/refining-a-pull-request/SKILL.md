---
name: refining-a-pull-request
description: Keeping an open PR coherent while review iterates — syncing the PR description when new commits drift from it, and triaging reviewer comments into change-request plans (plan and respond, but don't apply without local human directive). Load when new commits land on an open PR or review feedback arrives.
---

# Refining a pull request

A PR is a living object: the branch keeps moving after the description is written, and reviewers add comments on top. Two failure modes — a description that lies about the diff, and feedback that gets read but never triaged.

## 1. Description drift (commits vs description)

Every push to the PR branch re-runs this check against the diff (`git diff origin/main...HEAD`) and the body (`gh pr view --json body`):

- New or amended commits that **conflict with the description** — changed scope, added/removed docs surfaces, a verification claim that no longer holds, a dropped or renamed decision — mean **update the description in the same push cycle** (`gh pr edit --body/-t`).
- Update in place: rewrite the affected bullets rather than appending a changelog to the body — the description always describes the PR as it stands now, not its history (the dated story belongs in `CHANGELOG.md`, not the body).
- Title follows the primary commit's summary (see `opening-a-pull-request`); re-check it when the lead commit changes.
- Only sync the parts that actually drifted; a clean diff against the description needs no edit.

## 2. Reviewer comments (change requests)

For each review comment, triage before acting:

- **Well-founded change request** → start a **plan** (todo list: surface touched, sequencing per `planning-changes`, docs impact), and **respond to the comment** (`gh pr comment` or a reply on the review thread) acknowledging it and stating the planned approach — so the reviewer sees the request landed.
- **Do not apply the changes on the PR branch without local human directive.** The rule is the same family as commit-by-permission (`making-a-commit` §0): plan and reply, then stop. The human decides when (or whether) the feedback becomes commits.
- **Not well-founded** (misreads the diff, conflicts with a documented decision) → respond with the reasoning and the pointer (rationale comment, README, runbook, `cmdshift/platform#N`) — don't silently ignore it, and don't change the code to match a wrong suggestion.
- **Question, not a request** → answer it in the thread; no plan needed.
- Out-of-scope-but-valid findings → the `file-issue` skill, then link the new issue in the reply.

## 3. After the changes land (with directive)

Apply per the plan, reconcile green (`platform-workflow`), commit per `making-a-commit`, push — then re-run §1 (description drift) and reply on the threads the changes close, so the reviewer can re-review.
