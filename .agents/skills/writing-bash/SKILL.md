---
name: writing-bash
description: Writing or editing bash scripts in this repo — the tools/bin promotion pattern, the small-functions-with-named-entrypoint structure, repo-scope rules, and shell verification. Load when writing or editing any shell script or tools/bin helper.
---

# Writing bash (scripts)

Scope: `tools/bin/*` and any shell scripting this repo needs. Never write outside the repo — no `/tmp`, no `$HOME` scratch. Agent scratch goes in `.agents/temp/`; plans go in `.agents/temp/plans/`; transient script output only under `.agents/temp/` or `cluster/local/.tmp/` (the terraform/`.envrc`-owned dir). Helper args/defaults/exit codes live in [tools/bin/README.md](../../../tools/bin/README.md) — keep it current in the same change.

## 1. Structure — small functions, named entrypoint

- The script is a set of **small, single-purpose functions** — one concern per function, named for what it does. No monolithic scripts, no copy-pasted blocks.
- The **entrypoint sits at the bottom**, a function named the same as the file (e.g. `flux_wait` in `flux_wait`): argument parsing + the call sequence only. All logic lives in the functions above it.
- Fail loudly: `set -euo pipefail`, explicit exit codes (0 green / 1 actionable failure), error messages that say what to do next.

## 2. Script hygiene

- **Bounded waits, never blind polls** — no sleep loops; cap polls and print the pending state + diagnose hint on timeout (the existing helpers are the pattern).
- **No writes outside the repo** — scripts that cache or snapshot write under `.agents/temp/` or `cluster/local/.tmp/`, never `/tmp`.
- Don't re-export `KUBECONFIG` — direnv exports it; tools that ignore it get an explicit `--kubeconfig` flag.
- Prefer the repo's own helpers inside scripts (`kubectl`, `flux`, the `tools/bin` family) over re-deriving plumbing.

## 3. Promotion rule

When a task needs more than a round or two of throwaway plumbing, promote it to a `tools/bin/` script instead of re-deriving it inline (the proven pattern — `policy_report`/`cpu_audit` started as inline jq). The promotion includes its `tools/bin/README.md` entry (args, defaults, exit codes, gotchas) in the same change.

## 4. Verification

- `shellcheck tools/bin/<name>` — clean before finishing any script edit.
- Exercise the failure path once (bad args, unreachable target) — exit codes and messages are part of the interface.
- Comments follow the same minimize rules as manifests (the `writing-yaml` skill, Comments section): no narration; the why goes in `tools/bin/README.md` or the nearest README.
