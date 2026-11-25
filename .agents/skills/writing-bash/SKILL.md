---
name: writing-bash
description: Writing or editing bash scripts in this repo — the tools/bin promotion pattern, the small-functions-with-named-entrypoint structure, repo-scope rules, and shell verification. Load when writing or editing any shell script or tools/bin helper.
---

# Writing bash (scripts)

Scope: `tools/bin/*` and any shell scripting this repo needs. Never write outside the repo — no `/tmp`, no `$HOME` scratch. Agent scratch goes in `.agents/temp/` (`temp_prune` lists what's stale and deletes only with `--delete`); plans go in `.agents/temp/plans/`; transient script output only under `.agents/temp/` or `cluster/local/.temp/` (the terraform/`.envrc`-owned dir). A helper's usage, defaults, and exit codes live in its header comment block (what `--help` prints); its gotchas, exit-code semantics, and provenance live in [tools/bin/README.md](../../../tools/bin/README.md) — keep both current in the same change.

## 1. Structure — small functions, named entrypoint

- The script is a set of **small, single-purpose functions** — one concern per function, named for what it does. No monolithic scripts, no copy-pasted blocks.
- The **entrypoint sits at the bottom**, a function named the same as the file (e.g. `flux_wait` in `flux_wait`): argument parsing + the call sequence only. All logic lives in the functions above it.
- Fail loudly: `set -euo pipefail`, explicit exit codes (0 green / 1 actionable failure), error messages that say what to do next.
- **`-h`/`--help` answers from the header**: define `help()` (awk-prints the header comment block) and make a leading `-h`/`--help` the entrypoint's first check — exit 0 before any side effect (no port-forward, no cluster call, no mutating trap). Passthrough wrappers (`rustfs`, `cilium_test`) intercept only the first argument. The header is functional — usage lines, defaults, exit codes; issue refs, dates, and removed-component history go in `tools/bin/README.md`.

## 2. Script hygiene

- **Bounded waits, never blind polls** — no sleep loops; cap polls and print the pending state + diagnose hint on timeout (the existing helpers are the pattern).
- **No writes outside the repo** — scripts that cache or snapshot write under `.agents/temp/` or `cluster/local/.temp/`, never `/tmp`.
- Don't re-export `KUBECONFIG` — direnv exports it; tools that ignore it get an explicit `--kubeconfig` flag.
- Prefer the repo's own helpers inside scripts (`kubectl`, `flux`, the `tools/bin` family) over re-deriving plumbing.

## 3. Promotion rule

When a task needs more than a round or two of throwaway plumbing, promote it to a `tools/bin/` script instead of re-deriving it inline (the proven pattern — `policy_report`/`cpu_audit` started as inline jq). The promotion includes its header usage block and its `tools/bin/README.md` quick-reference row (plus a section for any gotchas) in the same change.

## 4. Verification

- `shellcheck tools/bin/<name>` — clean before finishing any script edit.
- Exercise the failure path once (bad args, unreachable target) — exit codes and messages are part of the interface.
- **HTTP-error paths need no companion outage** (cmdshift/platform#259): a tool that curls a companion (mailpit, OpenObserve) can have its non-200 / non-JSON paths exercised via a curl PATH shim — `PATH="$PWD/.agents/temp/cache/<issue>/shim-curl-<flavor>:$PATH" tools/bin/<tool>` — with three flavors: exit 7 (unreachable), prints non-JSON (bad answer), and passes `/healthz` through + answers everything else 500 (O2 error paths). The companion itself is never touched.
- `<name> -h` exits 0 and prints the header without touching the cluster (prove it behind a PATH shim of the cluster CLIs when unsure).
- `agent_lint` exits 0 — every script needs a `tools/bin/README.md` quick-reference row and a mention in a skill or AGENTS.md.
- Comments follow the same minimize rules as manifests (the `writing-yaml` skill, Comments section): no narration; the why goes in `tools/bin/README.md` or the nearest README.
