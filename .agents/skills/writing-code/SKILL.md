---
name: writing-code
description: Coding standards for the platform repo — manifest file naming, the valuesFrom pattern, fully-qualified issue refs, no-live-patches, evidence-based sizing, comment rules, and YAML/HCL verification gates. Load when writing or editing any manifest, terraform template, or tools/bin script.
---

# Writing code (this repo)

Scope: `manifests/local/**`, `cluster/local/**` (terraform + templates), `tools/bin/*`. The cluster state is git-managed; these rules keep the diff reviewable and the drift zero.

## 1. Everything in files — no live patches

Never fix drift with `kubectl edit` / `talosctl patch` / `docker exec` mutations (the one documented exception: root `Kustomization/local` / `Bucket/main` during a pipeline wedge). Change the manifest or terraform template and reconcile. If a fix needs a rebuild, note the pending state in `CHANGELOG.md` or the tracking issue.

## 2. Manifest conventions

- **File naming**: `<name>.<kind>.yaml` inside groups (`velero.helm-release.yaml`, `mimir.statefulset.yaml`, `mail.alertmanager-config.yaml`), `<action>.<kind>.yaml` for policies (`disallow-privileged.validating-policy.yaml`, `allow-velero-security-contexts.policy-exception.yaml`), plain `<name>-values.yaml` for helm values files. Follow the dir's existing pattern — don't invent spellings.
- **Every new file joins the group's inner `kustomization.yaml` resources list** (auto-discovered dirs excepted — but see the `kubectl kustomize` landmine: explicit-list dirs silently drop unlisted files from dry-runs while flux still applies them).
- **valuesFrom pattern** (cmdshift/platform#31): helm values live in a plain `<release>-values.yaml`, joined to the HelmRelease via `configMapGenerator` + `valuesFrom` (fixed name, `disableNameSuffixHash: true`). `helm_verify` resolves these refs — keep the generator name in sync.
- **YAML style**: match the surrounding files (2-space indent, quoted strings where the value is ambiguous). `yaml_lint` before reconciling, always.

## 3. Comments — minimize

Comments are a maintenance cost: stale ones actively lie, and every comment is a second source of truth to keep in sync. **Default is no comment — treat writing one as the exception that needs justification**, not the baseline.

1. **Don't add comments by default.** Before writing one, apply the delete-test: *if this comment were removed, would any future reader lose information they couldn't reconstruct from the value, the chart docs, or the git history?* Narration (`# set the replica count`), restated config, section banners, chart-default restatements: never.
2. **Max 3 lines.** The story lives in the **nearest group `README.md`** — write it there and leave at most a short pointer at the value (`# why: observability/README.md`). Even a compliant ≤3-line comment is worse than the same story in a README when the detail is procedural or narrative.
3. **Prefer the README from the start.** A surprising value gets a one-line comment (`# reg.kyverno.io pull-through 404s silently — cmdshift/platform#71`) only when the why fits in one line; anything longer or mechanism-heavy goes straight to the README with no comment at all.
4. **Do comment environment-specific values** — anything that exists only because this cluster runs Talos-in-Docker (Docker VM vs real Talos/VM) and won't work otherwise. These get the exact marker vocabulary `# remove in the cloud` / `# true in the cloud` at the value — the grep-surface for cloud migration; a new marker obligates the matching `manifests/cloud/notes.md` entry. Never repurpose the markers for ordinary rationale.
5. **Do reference issues that document bugs** (cmdshift/platform#N, fully qualified, never bare `#N` — commit SHAs stay SHAs): chart bugs, upstream landmines, workarounds. **Don't reference feature/update issues** — git history carries what landed.
6. **Evidence numbers justify sizing values at the value** (the `resource-sizing` skill): a sizing comment carries the observed number and the derivation (`peak x 1.2`), nothing more — the incident story belongs in the README/runbook.
7. **Stale comments are worse than none** — changing a value means updating or deleting its comment in the same change. When rewriting a file, comment you *touch* follows these rules; don't leave a rotting block behind because "it was already there".

Worked examples, marker vocabulary table, sweep checklist: [runbooks/local/code-comments.md](../../../runbooks/local/code-comments.md).

## 4. Writing YAML

Run, in order, before pushing anything through the reconciliation pipeline:

1. `yaml_lint` — every touched file, always.
2. `cr_validate` — CRD-backed objects against the on-cluster schema (undeclared fields fail the root dry-run and wedge the whole dependency chain).
3. `--dry-run` (`kubectl apply --dry-run=server` / `helm_verify`) on new or updated YAML before the sync container picks it up.

## 5. Writing HCL (terraform)

1. `terraform fmt` — keep `cluster/local/**` formatted; run before finishing any `.tf`/`.tftpl` edit.
2. `terraform plan` — check for errors and unintended changes before apply. Plan drift on resources you didn't touch is usually provider churn (the `terraform-churn` skill owns interpretation).

## 6. Sizing and security

- Resources are **evidence-based** (the `resource-sizing` skill): requests lean (10-50m CPU), CPU limits generous, memory request ≈ P99×1.2 / limit 1.5×. Numbers come from `memory_audit`/`cpu_audit`/`vpa_recs`, not defaults — and the evidence rides with the value as a short rationale comment (≤3 lines; longer stories go to the group README, rule 2 above).
- Admission is **Deny-mode kyverno**: every container needs requests+limits, pinned tags, runAsNonRoot, seccomp, caps dropped. New workload → the `add-workload` checklist before writing the manifest, not after admission rejects it.

## 7. Scripts (`tools/bin/`)

When a task needs more than a round or two of throwaway plumbing, promote it to a script (the proven pattern — `policy_report`/`cpu_audit` started as inline jq). Scripts handle their own plumbing (port-forwards, bounded polls, unit normalization); `tools/bin/README.md` gets the args/defaults/exit-codes/gotchas entry in the same change.
