---
name: platform-workflow
description: End-to-end workflow for changing platform manifests — pre-reconcile checks (yaml_lint, helm_verify), bucket-sync convergence (sync_wait), root reconcile via flux_wait, post-change verification, and the docs-maintenance gate before commit/PR. Use before reconciling ANY manifest change.
---

# Making a manifest change

The standard loop for every change to `manifests/local/`. Flux v2 deploys everything; there is no manual `kubectl apply`.

## 0. Before editing

- Check for **rationale comments** before overriding "odd" config — deliberate decisions are documented inline at the value (why the thanos-operator uses `bundle.yaml`, why some kustomizations have `prune: false`, why `mirror.sh` passes `--remove`). If a choice looks wrong, find the comment first.
- Any non-obvious decision you make gets its own rationale comment, then a link to notes/runbook/issue if there is more context.

## 1. Pre-reconcile checks

```
yaml_lint          # parse-check all YAML; exits 1 on the first bad file
helm_verify        # renders every HelmRelease's values via helm template
```

`helm_verify` catches nil-pointer template errors, but schema-less charts do **not** reject values-key typos — cross-check surprise diffs against the chart's `values.yaml`.

## 2. Converge the bucket, then reconcile

```
sync_wait          # wait until edited manifests actually landed in the flux bucket
flux_wait          # reconcile root kustomization local --with-source + bounded poll
```

The sync container drops inotify events (edits included, not just deletes — hit twice 2026-09-06), so reconciling without `sync_wait` can apply a stale artifact. For edit-heavy sessions, spot-check with `rustfs cat <key> | grep <marker>`.

- `flux_wait` exit 0 = all green; exit 1 = timeout with the pending list + diagnose hint → load the `reconcile-stuck` skill.
- Edits never reaching the cluster at all → load the `pipeline-wedged` skill.
- Estimate the reconcile duration first (~2-3m for a root reconcile, ~10m for a fresh rebuild) and cap polling at ~2× that.

## 3. Final checks

```
kubectl get helmreleases -A      # every release True
policy_report                    # failures: 0 expected (skips = PolicyExceptions); lists stale reports for gone resources
```

Posture scanning (kubescape) was removed 2026-09-06 — single-purpose hardening tools are its replacement (see `manifests/local/notes.md` for the accepted-deviations baseline those tools will audit against).

## Hard rule: no live patches

Never fix drift with `kubectl edit` / `talosctl patch` / `docker exec` mutations — change the manifest (or terraform template) and reconcile. The one documented exception is editing the root `Kustomization/local` / `Bucket/main` themselves during a pipeline wedge (see the `pipeline-wedged` skill). If a fix needs a rebuild, note the pending state in `manifests/local/notes.md`.

## 4. Docs maintenance before commit/PR

Docs are part of the change — a change isn't ready to commit or PR until the docs it made stale are updated in the same branch. Sweep all four surfaces:

- `manifests/local/notes.md` (+ `manifests/cloud/notes.md`) — local-only settings + rationale, session learnings, cloud deltas
- `runbooks/local/` — changed procedures, new gotchas, worked examples
- `.agents/skills/*/SKILL.md` — sync any skill whose trigger/steps/traps changed (this one included)
- `tools/bin/README.md` — new/changed helper scripts: args, defaults, exit codes

Rule of thumb: if this session hit a landmine or learned something the hard way, it's documentation — write it down where the next operator (or agent) will find it.

## Full detail

- [runbooks/local/reconciliation-stuck.md](../../../runbooks/local/reconciliation-stuck.md) — when reconcile stalls
- [runbooks/local/pipeline-wedged.md](../../../runbooks/local/pipeline-wedged.md) — when edits don't reach the cluster
- [tools/bin/README.md](../../../tools/bin/README.md) — every helper script
