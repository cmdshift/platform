---
name: platform-workflow
description: End-to-end workflow for changing platform manifests — pre-reconcile checks (yaml_lint, helm_verify), bucket-sync convergence (sync_wait), root reconcile via flux_wait, post-change verification, and the docs-maintenance gate before commit/PR. Use before reconciling ANY manifest change.
---

# Making a manifest change

The standard loop for every change to `manifests/local/`. Flux v2 deploys everything; there is no manual `kubectl apply`.

## 0. Before editing

- **Branch check**: never work on `main`. Verify `git branch --show-current` shows a feature branch (`feat/<topic>` / `fix/<topic>`); create one before the first edit if not. The commit/PR steps assume it (see the `making-a-commit` skill).
- Check for **rationale comments** before overriding "odd" config — deliberate decisions are documented inline at the value (why some kustomizations have `prune: false`, why `mirror.sh` passes `--remove`). If a choice looks wrong, find the comment first.
- Any comment you write, edit, or delete follows the **Comments section of the `writing-code` skill** (the rules: default no comment, delete-test; max 3 lines; `# remove/true in the cloud` markers for Talos-in-Docker deviations; `cmdshift/platform#N` bug refs only, never feature refs; update-or-delete comments for values you touch).

## 1. Pre-reconcile checks

```
yaml_lint          # parse-check all YAML; prints every bad file, exit 1 if any
helm_verify        # renders every HelmRelease's values via helm template
cr_validate        # server-side dry-run of CRs against on-cluster CRD schemas
```

`helm_verify` catches nil-pointer template errors, but schema-less charts do **not** reject values-key typos — cross-check surprise diffs against the chart's `values.yaml`. `cr_validate` is mandatory for any new/changed CR (TracingPolicy, AlertmanagerConfig,CEL health checks…): kustomize-controller dry-runs the whole group before applying, so one undeclared field blocks every file in the directory and repeats at `retryInterval` forever. Kustomize dry-run caveat: dirs without a `kustomization.yaml` (e.g. `crds/`) fail standalone `kustomize build`/`kubectl kustomize` but build fine in flux (implicit kustomization auto-generated listing all YAMLs) — validate those with `flux build kustomization <name> --path <dir>`, not the CLI.

## 2. Converge the bucket, then reconcile

```
sync_wait          # wait until edited manifests actually landed in the flux bucket
flux_wait          # reconcile root kustomization local --with-source + bounded poll
```

The sync mirror is a ≤5s poll (cmdshift/platform#55) and the Bucket source pulls on its own schedule, so reconciling without `sync_wait` can still run against an artifact older than the edit — `sync_wait` keeps that window closed.

- `flux_wait` exit 0 = all green; exit 1 = a failing group (fast-fail: `Ready=False` with a real error is a failed attempt, not slowness — the loop exits on the first one with its message. **Dependency-waiting is not failure**: `dependency '...' is not ready` / `revision is not up to date` are the normal tree-cascade states and stay pending) or timeout with the pending list + diagnose hint → load the `reconcile-stuck` skill. `flux_wait -c` / `helm_wait -c <ns> <name>` give instant no-reconcile verdicts when you just want current state.
- **valuesFrom releases (cmdshift/platform#31 pattern)**: a values-only change (ConfigMap edit, HelmRelease spec untouched) does not re-trigger helm-controller. Ordering matters: `flux_wait` FIRST (the group kustomization rebuilds the generated `ConfigMap/<release>-values`), THEN `helm_wait <ns> <name>` per changed release. `helm_wait` without the preceding `flux_wait` re-renders against the OLD ConfigMap — the HR goes Ready and the values never land (the tell is `request_audit` still showing old requests after a "green" rollout). `helm_wait` also exits fast with the HR failure message when the release is terminally broken (retries exhausted → reconciles replay the cached failure instead of re-attempting). CR-managed workloads pick up CR edits on the operator's own reconcile — force with `flux reconcile kustomization <group>-config --with-source`.
- Edits never reaching the cluster at all → load the `pipeline-wedged` skill.
- Observed timing: a single-group change settles in ~5 polls (~1m); a full-tree reconcile in ~2-3m; a fresh rebuild ~10m. Default cap 42 covers the rebuild worst case — for interactive changes run `flux_wait 15`: a kustomization still pending at ~8 polls is almost always **failing, not slow** — `describe` it instead of waiting out the cap.

## 3. Final checks

```
kubectl get helmreleases -A      # every release True (per-release check: helm_wait -c <ns> <name>)
policy_report                    # failures: 0 expected (skips = PolicyExceptions); lists stale reports for gone resources
```

Posture scanning (kubescape) was removed — single-purpose hardening tools are its replacement (see `manifests/local/README.md` for the accepted-deviations baseline those tools will audit against).

## Hard rule: no live patches

Never fix drift with `kubectl edit` / `talosctl patch` / `docker exec` mutations — change the manifest (or terraform template) and reconcile. The one documented exception is editing the root `Kustomization/local` / `Bucket/main` themselves during a pipeline wedge (see the `pipeline-wedged` skill). If a fix needs a rebuild, note the pending state in `CHANGELOG.md` or the tracking issue.

## 4. Docs maintenance before commit/PR

Docs are part of the change — a change isn't ready to commit or PR until the docs it made stale are updated in the same branch. Sweep the surfaces:

- `CHANGELOG.md` — dated learnings, incident narratives, follow-ups (append an entry; ref `cmdshift/platform#N`)
- `manifests/local/<group>/README.md` — group-level decisions the change touched (keep current)
- `runbooks/local/` — changed procedures, new gotchas, incident post-mortems
- `.agents/skills/*/SKILL.md` — sync any skill whose trigger/steps/traps changed (this one included)
- `tools/bin/README.md` — new/changed helper scripts: args, defaults, exit codes

Rule of thumb: if this session hit a landmine or learned something the hard way, it's documentation — write it down where the next operator (or agent) will find it.

## 5. Stop at green — the human commits

Commit/push by **permission** — commit-by-permission is a hard rule, and a pre-review go-ahead doesn't authorize the commit (the `making-a-commit` skill carries the full signing/permission rules). When reconcile is green and docs are swept, summarize the change and propose a commit — then **stop; wait for the human's explicit approval before running `git commit`/`git push`**; the human reviews the diff and approves history. The commit step follows the `making-a-commit` skill (conventional format, signing rule); the PR step follows `opening-a-pull-request`.

## Full detail

- [runbooks/local/reconciliation-stuck.md](../../../runbooks/local/reconciliation-stuck.md) — when reconcile stalls
- [runbooks/local/pipeline-wedged.md](../../../runbooks/local/pipeline-wedged.md) — when edits don't reach the cluster
- [tools/bin/README.md](../../../tools/bin/README.md) — every helper script
