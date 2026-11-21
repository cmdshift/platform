---
name: platform-workflow
description: End-to-end workflow for changing platform manifests — pre-reconcile checks (yaml_lint, helm_verify), bucket-sync convergence (sync_wait), root reconcile via flux_wait, post-change verification, and the docs-maintenance gate before commit/PR. Use before reconciling ANY manifest change.
---

# Making a manifest change

The standard loop for every change to `manifests/` (bases + clusters). Flux v2 deploys everything; there is no manual `kubectl apply`.

## 0. Before editing

- **Branch check**: never work on `main`. Verify `git branch --show-current` shows a feature branch (`feat/<topic>` / `fix/<topic>`); create one before the first edit if not. The commit/PR steps assume it (see the `making-a-commit` skill).
- Check for **rationale** before overriding "odd" config — deliberate decisions are documented in the group README and at the value (why some kustomizations have `prune: false`, why `mirror.sh` passes `--remove`). If a choice looks wrong, find the rationale first.
- Any comment you write, edit, or delete follows the **Comments section of the `writing-yaml` skill** (the rules: default no comment, delete-test; max 3 lines; `# remove/true in the cloud` markers for Talos-in-Docker deviations; no `cmdshift/platform#N` refs in comments — refs and explanations live in the nearest README; update-or-delete comments for values you touch).

## 1. Pre-reconcile checks

```
yaml_lint            # parse-check all YAML; prints every bad file, exit 1 if any
kustomization_audit  # registration guard: every yaml in a kustomize dir must be referenced in that dir's kustomization.yaml
helm_verify          # renders every group overlay's HelmReleases with the values flux ships; FAILs on 0 (focused: helm_verify manifests/clusters/local/<group>)
cr_validate          # server-side dry-run of CRs against on-cluster CRD schemas
dryrun_check         # kustomize build + per-object server-side dry-run of a changed group
```

`kustomization_audit` is the registration check next to `yaml_lint`'s parse check: an unregistered yaml in a kustomize dir silently never deploys (the landmine hit three times — cmdshift/platform#183 twice, cmdshift/platform#186's talos-backup VPA orphan). Values files (generator inputs) and the terraform-applied root `local.kustomization.yaml` are excepted automatically.

`dryrun_check <path>` is the whole-group gate: `kubectl apply` on a multi-doc build stops at the first failure, but the controller's dry-run failure message reads group-wide — dryrun_check reports EVERY failing object individually (catches CM last-applied-annotation oversize (~256KB, cmdshift/platform#171), kyverno denials, strict-decode errors pre-reconcile). It also resolves `${VAR}` tokens (flux `postBuild.substitute`) and FAILs any survivor — tokenized groups (CNPs, talos-backup) must gate through it, not raw `cr_validate` (the cilium FQDN regex rejects literal `${...}`).

`helm_verify` catches nil-pointer template errors, but schema-less charts do **not** reject values-key typos — cross-check surprise diffs against the chart's `values.yaml`. `cr_validate` is mandatory for any new/changed CR (TracingPolicy, ExternalSecret, CEL health checks…): kustomize-controller dry-runs the whole group before applying, so one undeclared field blocks every file in the directory and repeats at `retryInterval` forever. **But `cr_validate` proves nothing for schema-less CRDs** (`x-kubernetes-preserve-unknown-fields`): a wrong spec field validates clean and the operator silently drops it — check field names against the chart values the operator maps onto, and verify the rendered result (e.g. `kubectl get sts -o jsonpath='{.spec.template.metadata.labels}'`, cmdshift/platform#155).

## 2. Converge the bucket, then reconcile

```
sync_wait          # wait until edited manifests actually landed in the flux bucket
flux_wait          # reconcile root kustomization local --with-source + bounded poll
```

The sync mirror is a ≤5s poll (cmdshift/platform#55) and the Bucket source pulls on its own schedule, so reconciling without `sync_wait` can still run against an artifact older than the edit — `sync_wait` keeps that window closed. **But sync_wait proves bucket parity, NOT artifact freshness** (cmdshift/platform#216): the source-controller artifact lags bucket objects until its next 5m poll, and groups reconcile happily against the previous artifact — `sync_wait` OK + `flux_wait` all-Ready can BOTH pass while the edit never applied (only symptom: unchanged live state). When a change must land now (or right after a just-mirrored edit), force the pull between the two: `flux reconcile source bucket main`.

- **The bucket sync runs on its own interval — it can land mid-recovery and undo temporary state.** While a release is wedged (kyverno-denied install, uninstall remediation loop) you often manipulate cluster state (secret cleanup, hook-job deletion) that the next bucket-driven reconcile will re-run against. If the interval is short, `sync_wait`-then-reconcile can race your cleanup. Set the root `Kustomization/local` `interval` long during heavy iterating (or annotation-reconcile per step instead of waiting for the timer) so you drive each reconcile explicitly.

- `flux_wait` exit 0 = all green; exit 1 = a failing group (fast-fail: `Ready=False` with a real error is a failed attempt, not slowness — the loop exits on the first one with its message. **Dependency-waiting is not failure**: `dependency '...' is not ready` / `revision is not up to date` are the normal tree-cascade states and stay pending) or timeout with the pending list + diagnose hint → load the `reconcile-stuck` skill. `flux_wait -c` / `helm_wait -c <ns> <name>` give instant no-reconcile verdicts when you just want current state.
- **valuesFrom releases (cmdshift/platform#31 pattern)**: a values-only change (ConfigMap edit, HelmRelease spec untouched) does not re-trigger helm-controller. Ordering matters: `flux_wait` FIRST (the group kustomization rebuilds the generated `ConfigMap/<release>-values`), THEN `helm_wait <ns> <name>` per changed release. `helm_wait` without the preceding `flux_wait` re-renders against the OLD ConfigMap — the HR goes Ready and the values never land (the tell is `request_audit` still showing old requests after a "green" rollout). Worse (cmdshift/platform#171): the values-ConfigMap digest can stay FROZEN even after reconcile + annotate — check `status.lastAttemptedConfigDigest`; when stale, the fix is suspend/`helm uninstall`/resume (the `helmrelease-stuck` skill's valuesFrom-staleness section). `helm_wait` also exits fast with the HR failure message when the release is terminally broken (retries exhausted → reconciles replay the cached failure instead of re-attempting). CR-managed workloads pick up CR edits on the operator's own reconcile — force with `flux reconcile kustomization <group>-config --with-source`.
- Edits never reaching the cluster at all → load the `pipeline-wedged` skill.
- Observed timing: a single-group change settles in ~5 polls (~1m); a full-tree reconcile in ~2-3m; a fresh rebuild ~10m. Default cap 42 covers the rebuild worst case — for interactive changes run `flux_wait 15`: a kustomization still pending at ~8 polls is almost always **failing, not slow** — `describe` it instead of waiting out the cap.

## 3. Final checks

```
kubectl get helmreleases -A      # every release True (per-release check: helm_wait -c <ns> <name>)
flux_triage                      # scoreboard: kustomization revision lag + HR verdicts (INTERVENE = act)
policy_report                    # failures: 0 expected (skips = PolicyExceptions); lists stale reports for gone resources
```

After any **scrape-path change** (openobserve-collector agent/gateway config, chart metrics toggles): `metrics_summary -t` — per-family up-target counts (grouped by `service_name`) + total in one call. Empty output = no series; a family missing or a per-replica count collapsed (cilium-agent/kubelet < node count) is the scrape regression tell. Don't hand-roll port-forward+curl — the tool rides `prometheus_query`'s shared O2 forward.

## Hard rule: no live patches

Never fix drift with `kubectl edit` / `talosctl patch` / `docker exec` mutations — change the manifest (or terraform template) and reconcile. The one documented exception is editing the root `Kustomization/local` / `Bucket/main` themselves during a pipeline wedge (see the `pipeline-wedged` skill). If a fix needs a rebuild, note the pending state in `CHANGELOG.md` or the tracking issue.

## 4. Docs maintenance before commit/PR

Docs are part of the change — a change isn't ready to commit or PR until the docs it made stale are updated in the same branch. Sweep the surfaces:

- `CHANGELOG.md` — dated learnings, incident narratives, follow-ups (append an entry; ref `cmdshift/platform#N`)
- `manifests/bases/<group>/README.md` — group-level decisions the change touched (keep current)
- `runbooks/local/` — changed procedures, new gotchas, incident post-mortems
- `.agents/skills/*/SKILL.md` — sync any skill whose trigger/steps/traps changed (this one included)
- `tools/bin/README.md` — new/changed helper scripts: quick-reference row + gotchas (usage, defaults, and exit codes live in the script header — `<name> --help`)

Rule of thumb: if this session hit a landmine or learned something the hard way, it's documentation — write it down where the next operator (or agent) will find it.

## 5. Stop at green — the human commits

Commit/push by **permission** — commit-by-permission is a hard rule, and a pre-review go-ahead doesn't authorize the commit (the `making-a-commit` skill carries the full signing/permission rules). When reconcile is green and docs are swept, summarize the change and propose a commit — then **stop; wait for the human's explicit approval before running `git commit`/`git push`**; the human reviews the diff and approves history. The commit step follows the `making-a-commit` skill (conventional format, signing rule); the PR step follows `opening-a-pull-request`.

## Full detail

- [runbooks/local/reconciliation-stuck.md](../../../runbooks/local/reconciliation-stuck.md) — when reconcile stalls
- [runbooks/local/pipeline-wedged.md](../../../runbooks/local/pipeline-wedged.md) — when edits don't reach the cluster
- [tools/bin/README.md](../../../tools/bin/README.md) — every helper script
