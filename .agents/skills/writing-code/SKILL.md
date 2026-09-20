---
name: writing-code
description: Coding standards for the platform repo — manifest file naming, the valuesFrom pattern, fully-qualified issue refs, no-live-patches, evidence-based sizing, and the code-comments rules. Load when writing or editing any manifest, terraform template, or tools/bin script.
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

## 3. Comments and refs

- Comments follow the `code-comments` skill (load it): default **no comment**; comments only for surprising choices, edge cases/landmines, and evidence at the value. Stale comments are updated-or-deleted in the same change.
- **Issue/PR refs are fully qualified**: `cmdshift/platform#N`, never bare `#N` — in manifests, terraform, docs, and skills. Commit SHAs stay SHAs.
- **No dates in timeless files** — dated narrative goes in `CHANGELOG.md` only.

## 4. Sizing and security

- Resources are **evidence-based** (the `resource-sizing` skill): requests lean (10-50m CPU), CPU limits generous, memory request ≈ P99×1.2 / limit 1.5×. Numbers come from `memory_audit`/`cpu_audit`/`vpa_recs`, not defaults — and the evidence rides with the value as a rationale comment.
- Admission is **Deny-mode kyverno**: every container needs requests+limits, pinned tags, runAsNonRoot, seccomp, caps dropped. New workload → the `add-workload` checklist before writing the manifest, not after admission rejects it.
- Talos-in-Docker deviations get the exact marker vocabulary (`# remove/true in the cloud`) — grep-surface for cloud migration; adding one requires the matching `manifests/cloud/notes.md` entry.

## 5. Scripts (`tools/bin/`)

When a task needs more than a round or two of throwaway plumbing, promote it to a script (the proven pattern — `policy_report`/`cpu_audit` started as inline jq). Scripts handle their own plumbing (port-forwards, bounded polls, unit normalization); `tools/bin/README.md` gets the args/defaults/exit-codes/gotchas entry in the same change.
