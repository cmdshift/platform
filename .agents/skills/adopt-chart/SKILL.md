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

Gotcha: `helm_verify` printing `FAIL: <name> — helm repo add/update … failed` means the index fetch failed — it no longer swallows those (`|| true` used to leave a stale/empty index that produced phantom "version not in index" verdicts); re-run before digging deeper. `version X not in <repo> index` after a successful fetch means the pin is genuinely wrong/missing — without this check `helm template --version` silently rendered the *closest* index version and passed. A `v`-prefixed pin (`version: "v1.2.3"`) is fine — both sides are normalized. Index fetches are on-miss only (probe → one scoped `helm repo update` → verdict), so a "not in index" verdict is trustworthy.

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

## Worked examples

thanos-operator (2026-09-05): helm chart attempt → install failed at the 1MB cap (~2.5MB of embedded CRDs) → vendored CRDs (regen burden) → repo's `bundle.yaml` via kustomization with three patches. Rationale in `monitoring/thanos-operator.kustomization.yaml`.

trivy-operator (2026-09-07): chart 0.36.0 adopted clean (CRDs ship in `crds/`, no hook jobs, 23KB release) but three values keys were **silently ignored** (schema-less chart): `operator.resources` (wants top-level `resources`), `scanJobsConcurrentLimit`/`scanJobTTL` (want `operator.`, not `trivyOperator.`) — caught by inspecting the render, not by helm template. Values now live in a plain values file + configMapGenerator → `valuesFrom` (cmdshift/platform#31 pattern, helm_verify resolves it); operator-generated scan jobs needed the admission shaping trap above. Rationale in `security/trivy-values.yaml` + `manifests/local/notes.md`.

## Operator-adoption traps (datastores group, issue #49)

- **Chart renders > 1MB because CRDs ship in `templates/`** (cloudnative-pg): `crds.create: false` + a child Kustomization (crds group, `prune: false`) building the upstream repo's `config/crd` at a pinned tag — upstream-tracked beats vendoring (no regen burden, bump = tag ref). Verify the build is load-restrictor-safe (no `../` refs) and semantically identical to the chart's CRDs before switching (runbooks/local/adopting-a-chart.md).

- **Chartless operators with kustomize overlays** (rabbitmq ×2): upstream `config/default` uses `../` refs that flux's kustomize load-restrictor blocks from a GitRepository, and the manager images ship `:latest`. Vendor the **rendered** `kubectl kustomize config/default` output (tag checkout) into the group dir; pin images with a kustomize `images:` transformer and patch resources in the group `kustomization.yaml`. Watch for objects the namespace transformer won't fix: Namespace objects (drop or patch), cert-manager `inject-ca-from` annotations and Certificate `dnsNames` (both bake `<ns>` in at render time — patch explicitly). The Bitnami OCI charts are not an alternative — the free `bitnamicharts` catalog is frozen (rco chart ships operator 2.16.1 vs upstream 2.22.5; the mto chart is absent entirely), and OCI has no index to search anyway (Docker Hub gates `tags/list`; exact-version probes or Artifact Hub are the enumeration paths).
- **Versioned image tags may live only on one registry, with different prefixes**: rabbitmq's `:latest` is on ghcr AND docker hub, but versioned tags are ghcr-only and **without the `v` prefix** (`2.22.5`, not `v2.22.5`); docker hub's `rabbitmqoperator` repos lag releases. `ErrImagePull ... not found` on a freshly pinned tag = check the registry's real tag list before touching anything else.
- **Charts that `lookup` their own CRDs at render time** (kubeblocks): helm-controller renders without API discovery, so a chart whose templates `lookup` an API it doesn't ship fails install unless the CRDs are established first — by a separate crds chart (`prometheus-operator-crds` pattern), vendored CRDs in the `crds` group, or a `crds/` dir (helm install-only, the valkey-operator's shape).
- **Hardcoded admission-incompliant initContainers** (kubeblocks `tools` init: resources present, securityContext absent, no values knob): fix with HelmRelease `postRenderers` (kustomize SMP on the named initContainer). Verify the post-rendered output locally first — an SMP that silently matches nothing reproduces the exact admission denial.
- **KubeBlocks — aborted, not adopted** (issue #49): multi-engine operator (2 Deployments + 28 CRDs + inert Addon CRs + a dataprotection controller) rejected as not single-purpose enough; replaced by the valkey-operator. The abort left the 28 CRDs on-cluster (crds group is prune:false) — deleted manually like the kubescape removal. When rejecting an operator, sweep CRDs + operator-created CRs by hand; helm uninstall does not remove CRDs.

## Full detail

[runbooks/local/adopting-a-chart.md](../../../runbooks/local/adopting-a-chart.md)
