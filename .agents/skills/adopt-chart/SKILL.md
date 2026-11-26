---
name: adopt-chart
description: Adopting or upgrading a helm chart — the 1MB release-secret cap check (measure, don't estimate), CRD split strategies, hook-job sizing, image-registry mapping against the pull-through cache, and patching rules for what values can't express. Use before adding a new chart or bumping a version.
---

# Adopting a chart

Procedure + one rule per trap; per-chart stories and worked examples: [Full detail](#full-detail).

## 0. Import, pin, lockstep

```
helm repo add <name> <url> && helm repo update
```

Name it after its future `sources/` HelmRepository CR. `helm search repo <name>/ --versions` → pin an exact version (never floating); `helm show values` for the real values surface; `helm template` for local renders.

- **Two-place pins bump in lockstep** — bootstrap (`var.cilium_chart_version` in `cluster/local/bootstrap/`) ↔ `bases/networking/cilium.helm-release.yaml`: flux converges the live release to the HelmRelease pin, so a one-sided bump silently lands on whichever pin lags.
- **`helm_verify` index verdicts**: `FAIL: <name> — helm repo add/update … failed` = the fetch failed, re-run; `version X not in <repo> index` after a good fetch = the pin is genuinely wrong (plain `helm template --version` silently renders the closest version). `v`-prefixed pins are normalized.
- All-pins re-inventory: [dependency-inventory.md](../../../runbooks/local/dependency-inventory.md).

## 1. The 1MB release-secret cap

`sh.helm.release.*` Secrets cap at **1MB** (`data: Too long: may not be more than 1048576 bytes`). **Measure, don't estimate** (gzip estimates lie) before the HelmRelease exists:

```
helm template <release> <chart> -f .agents/temp/values.yaml | wc -c
```

Too big → pick a strategy:
- **separate CRD chart** (`prometheus-operator-crds` pattern)
- **CRDs in the chart's `crds/` dir** — never in the secret; set `install.crds: Create` / `upgrade.crds: CreateReplace` (flux defaults to create-only; cmdshift/platform#62)
- **CRDs rendered from `templates/`** → the chart's own skip knob + a `crds`-group child Kustomization (`prune: false`) building upstream `config/crd` at a tag in lockstep with the chart; `install.crds: Skip` does **not** help (it governs only `crds/`). Check the build has no `../` refs and diff it against the chart's CRDs (cmdshift/platform#49)
- **vendor rendered CRDs** into `manifests/bases/crds/` — a regen step on every bump
- **raw manifests via kustomization** (`bundle.yaml`) — no secret at all (cmdshift/platform#128)

**Generated ConfigMaps cap at ~256KB in the kustomize-controller dry-run** (`last-applied-configuration`, not the 1MiB data limit, cmdshift/platform#171) — split across configMapGenerator entries; `dryrun_check` names the failing object.

## 2. Admission compliance

- **Hook Jobs are kyverno-checked — install AND uninstall hooks**: `helm template <chart> | yq 'select(.kind == "Job")'`; size every hook before the first install. A denied pre-delete hook wedges the HR in `uninstalling` (the `helmrelease-stuck` skill, cmdshift/platform#149).
- **No values knob for a container's resources/securityContext**: HelmRelease `postRenderers` SMP on the named container — verify the post-rendered output locally; an SMP that matches nothing reproduces the exact denial. Security contexts may still flow via values when resources don't.
- **Images with no USER directive** fail `runAsNonRoot` without an explicit `runAsUser` — `docker inspect <img> --format '{{.Config.User}}'` first (cmdshift/platform#52).
- Render the pinned **released** chart from the index — git templates ≠ released chart.
- No floating image tags (per-commit tags or digests); prefer chart values over patches when exposed.

## 3. Patching what values can't express

- SMPs merge `containers` **by name** — a wrong name silently *adds* a container.
- `ClusterRole.rules` is atomic: SMP **replaces** it — append with JSON6902 (`op: add, path: /rules/-`).
- Chartless kustomize-overlay operators (vendored render, namespace-transformer gaps): the runbook's "Operator adoption" section.

## 4. Verify before pushing

`helm_verify [path] [release]` renders with the **exact** values flux ships. Schema-less charts **silently drop unknown values keys and `flags` entries** — inspect the render for what you set; check flag names against the image's `--help`. Hand `helm template` (real values) to eyeball hooks/securityContext placement. `cr_validate` new CRs; check new-to-you fields against the **on-cluster CRD schema** (undeclared fields wedge the root dry-run).

## Traps

- **Unmapped image registry = hard pull failure** (wildcard mirror + `skipFallback: true`): override to a mapped upstream with identical content (kyverno → `global.image.registry: ghcr.io`; rationale in `manifests/bases/policies-config/README.md`). Map: [cluster-rebuild.md](../../../runbooks/local/cluster-rebuild.md).
- **`not found` pull on a freshly pinned tag** — check the registry's real tag list: versioned tags may live on one registry only, with or without a `v` prefix.
- **Upstream tags can be silently re-pushed** — a release-notes SBOM digest can be the vulnerable build; trust the mirror-served digest + the on-cluster pod's `imageID`, never the SBOM (strimzi `1.3.1`; ritual in the [datastores README](../../../manifests/bases/datastores/README.md), cmdshift/platform#263).
- **A CVE fix riding a base-image rebuild has its fix boundary at the base bump date, not the version tag** — "controller ≥ vX" release-date reasoning doesn't survive rebuilds (kustomize-controller v1.9.6, trivy 0.76.1). Verify the published image's apk-db (`/lib/apk/db/installed`) — an SBOM can hide base-image packages (flux SBOMs are Go-only). Precedents: flux + scanning READMEs (cmdshift/platform#262).
- **Chart bumps preferred; an image-tag override is a temporary exception** — add one only with a named removal condition recorded at the value (convention in `manifests/README.md`, condition table in cmdshift/platform#263).
- **Charts that `lookup` their own CRDs at render** fail install until the CRDs exist (helm-controller renders without API discovery).
- **An operator-managed release reusing a HelmRelease's name fights the old storage** ("upgrade failed; rollback required") — fresh name or purge `sh.helm.release.v1.<name>.*` + the HR ([incidents.md](../../../runbooks/local/incidents.md)).
- **Uninstall leaves residue** (CRDs, operator CRs, PVCs): [Removing a chart](../../../runbooks/local/adopting-a-chart.md#removing-a-chart).
- **Rarer shapes**: feature-validated charts, nameless config refs, over-matching discovery labels (runbook "Operator-CR traps"); Bitnami as a source (runbook §0).

## Full detail

[runbooks/local/adopting-a-chart.md](../../../runbooks/local/adopting-a-chart.md)
