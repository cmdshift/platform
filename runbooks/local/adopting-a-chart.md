# Adopting a chart

Bringing a new helm chart in (or deciding how to deploy an upstream project at all). Worked example throughout: the thanos-operator, 2026-09-05.

## 1. Can it be a helm release?

Helm persists the release manifest in the `sh.helm.release.*` Secret, which caps at **1MB** (`data: Too long: may not be more than 1048576 bytes`). Check the rendered size **before** the HelmRelease exists:

```
helm template <release> <chart> -f /tmp/values.yaml | wc -c
```

**Measure, don't estimate** — a gzipped-size estimate (~420KB) predicted safety for a chart whose helm install then failed hard; helm-controller's secret storage doesn't behave like `gzip | base64`.

If the manifest is too big, pick a strategy:
- **separate CRD chart** (the `prometheus-operator-crds` pattern — cleanest when upstream ships one)
- **upstream moves CRDs to helm's `crds/` dir** — install-only, never stored in the release secret; file an issue/PR
- **vendor the rendered CRDs** into `manifests/local/crds/` + `crd.enable: false` on the release — works, but adds a manual regen-on-every-bump step (rejected for thanos for exactly that reason)
- **raw manifests via kustomization** (bundle.yaml, etc.) — no secret involved at all; the thanos-operator's final answer

## 2. Admission compliance

- **hook jobs are kyverno-checked**: `helm template <chart> | yq 'select(.kind == "Job")'` — size every hook (requests, limits, security contexts) before the first install
- **image pinning**: floating tags (`main`, `latest`) violate policy or convention — prefer per-commit tags (`quay.io/<org>/<repo>:main-YYYY-MM-DD-<sha>`) or digests
- prefer chart **values** for security contexts and resources over patches when the chart exposes them

## 3. Patching what values can't express

For the kustomization-over-raw-manifests path:
- strategic-merge patches on Deployments merge `containers` **by name** — a wrong name silently *adds* a container. Verify the container name first
- `ClusterRole.rules` is an atomic list: strategic merge **replaces** it — use a JSON6902 `op: add, path: /rules/-` to append instead
- house example: `manifests/local/monitoring/thanos-operator.kustomization.yaml` (seccomp + image pin via strategic merge, events RBAC via JSON6902)

## 4. Verify before pushing

```
# render with the EXACT release values (extract them from the HelmRelease yaml)
helm template <release> <chart> --namespace <ns> -f /tmp/release-values.yaml
# simulate post-render patches if using them: kubectl kustomize a dir of rendered.yaml + patches
```

And per the flux landmine in AGENTS.md: verify any new-to-you API fields against the **on-cluster CRD schema** before pushing.

## Worked example (thanos-operator)

helm chart attempt → install failed at the 1MB secret cap (its CRDs are ~2.5MB of the manifest) → vendored CRDs (worked, regen burden) → reverted to the repo's `bundle.yaml` via kustomization with three patches (seccomp, image pin, events RBAC). Full rationale comments live in `monitoring/thanos-operator.kustomization.yaml`; the helm-side lesson is the helm landmine in AGENTS.md.
