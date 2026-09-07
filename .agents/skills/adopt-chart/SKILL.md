---
name: adopt-chart
description: Adopting or upgrading a helm chart — the 1MB release-secret cap check (measure, don't estimate), CRD split strategies, hook-job sizing, and patching rules for what values can't express. Use before adding a new chart or bumping a version.
---

# Adopting a chart

## 0. Import the chart repo locally

```
helm repo add <name> <url> && helm repo update
```

Name it the same as the HelmRepository CR it will get in `sources/`. Then: `helm search repo <name>/ --versions` to pin an exact version (never floating), `helm show values` to read the real values surface, `helm template` for local renders.

Gotcha: `helm_verify` printing `FAIL: <name> — repo <name> not found` usually means its `helm repo add` swallowed a transient network hiccup — re-run before digging deeper.

## 1. The 1MB release-secret cap

Helm persists the release manifest in the `sh.helm.release.*` Secret, capped at **1MB** (`data: Too long: may not be more than 1048576 bytes`). Check the rendered size **before** creating the HelmRelease:

```
helm template <release> <chart> -f /tmp/values.yaml | wc -c
```

**Measure, don't estimate** — a gzipped-size estimate (~420KB) predicted safety for a chart whose install then failed hard; helm-controller's secret storage doesn't behave like `gzip | base64`.

If too big, pick a strategy:
- **separate CRD chart** (`prometheus-operator-crds` pattern — cleanest when upstream ships one)
- **upstream moves CRDs to helm's `crds/` dir** — install-only, never stored in the release secret; file an issue/PR
- **vendor rendered CRDs** into `manifests/local/crds/` + `crd.enable: false` — works, but adds a manual regen step on every bump
- **raw manifests via kustomization** (bundle.yaml) — no secret involved; the thanos-operator's answer

## 2. Admission compliance

- **hook jobs are kyverno-checked**: `helm template <chart> | yq 'select(.kind == "Job")'` — size every hook (requests, limits, security contexts) before the first install
- **image pinning**: floating tags violate policy/convention — prefer per-commit tags (`main-YYYY-MM-DD-<sha>`) or digests
- prefer chart **values** for security contexts and resources over patches when the chart exposes them

## 3. Patching what values can't express

- strategic-merge patches on Deployments merge `containers` **by name** — a wrong name silently *adds* a container; verify the container name first
- `ClusterRole.rules` is atomic: strategic merge **replaces** it — append with JSON6902 (`op: add, path: /rules/-`)
- house example: `manifests/local/monitoring/thanos-operator.kustomization.yaml` (seccomp + image pin via SMP, events RBAC via JSON6902)

## 4. Verify before pushing

Render with the **exact** release values extracted from the HelmRelease yaml:

```
helm template <release> <chart> --namespace <ns> -f /tmp/release-values.yaml
```

`helm template` rejects unknown values keys only for charts shipping `values.schema.json` — for schema-less charts this catches template errors, not key typos. And verify any new-to-you API fields against the **on-cluster CRD schema** before pushing (undeclared fields fail the root dry-run and wedge the whole chain).

## Worked example

thanos-operator (2026-09-05): helm chart attempt → install failed at the 1MB cap (~2.5MB of embedded CRDs) → vendored CRDs (regen burden) → repo's `bundle.yaml` via kustomization with three patches. Rationale in `monitoring/thanos-operator.kustomization.yaml`.

## Full detail

[runbooks/local/adopting-a-chart.md](../../../runbooks/local/adopting-a-chart.md)
