---
name: adopt-chart
description: Adopting or upgrading a helm chart — the 1MB release-secret cap check (measure, don't estimate), CRD split strategies, hook-job sizing, image-registry mapping against the pull-through cache, and patching rules for what values can't express. Use before adding a new chart or bumping a version.
---

# Adopting a chart

## 0. Import the chart repo locally

```
helm repo add <name> <url> && helm repo update
```

Name it the same as the HelmRepository CR it will get in `sources/`. Then: `helm search repo <name>/ --versions` to pin an exact version (never floating), `helm show values` to read the real values surface, `helm template` for local renders.

Charts pinned in TWO places must bump in **lockstep** — the bootstrap helm_release values in `cluster/local/bootstrap/main.tf` and the flux HelmRelease in `manifests/bases/` carry independent `version` pins (cilium is the live example, bootstrap ↔ `bases/networking/cilium.helm-release.yaml`): flux adoption converges the live release to the HelmRelease's pin, so bumping only one side silently moves the live release to whichever pin lags.

Gotcha: `helm_verify` printing `FAIL: <name> — helm repo add/update … failed` means the index fetch failed — it no longer swallows those (`|| true` used to leave a stale/empty index that produced phantom "version not in index" verdicts); re-run before digging deeper. `version X not in <repo> index` after a successful fetch means the pin is genuinely wrong/missing — without this check `helm template --version` silently rendered the *closest* index version and passed. A `v`-prefixed pin (`version: "v1.2.3"`) is fine — both sides are normalized. Index fetches are on-miss only (probe → one scoped `helm repo update` → verdict), so a "not in index" verdict is trustworthy.

Periodic re-inventory of ALL pinned dependencies (not just the chart you're adopting) is a separate sweep: [runbooks/local/dependency-inventory.md](../../../runbooks/local/dependency-inventory.md).

## 1. The 1MB release-secret cap

Helm persists the release manifest in the `sh.helm.release.*` Secret, capped at **1MB** (`data: Too long: may not be more than 1048576 bytes`). Check the rendered size **before** creating the HelmRelease:

```
helm template <release> <chart> -f .agents/temp/values.yaml | wc -c
```

**Measure, don't estimate** — a gzipped-size estimate (~420KB) predicted safety for a chart whose install then failed hard; helm-controller's secret storage doesn't behave like `gzip | base64`.

If too big, pick a strategy:
- **separate CRD chart** (`prometheus-operator-crds` pattern — cleanest when upstream ships one)
- **upstream moves CRDs to helm's `crds/` dir** — install-only, never stored in the release secret; wire with `install.crds: Create` / `upgrade.crds: CreateReplace` on the HelmRelease (the vpa release's shape, cmdshift/platform#62)
- **vendor rendered CRDs** into `manifests/bases/crds/` + `crd.enable: false` — works, but adds a manual regen step on every bump
- **raw manifests via kustomization** (bundle.yaml) — no secret involved; the thanos-operator's answer (predecessor, cmdshift/platform#128)

Charts whose CRDs render from `templates/` (no `crds/` dir) are a variant of the first two: stop the render with the chart's own skip knob and land the CRDs via a child kustomization — the first operator-adoption trap below.

## 2. Admission compliance

- **hook jobs are kyverno-checked**: `helm template <chart> | yq 'select(.kind == "Job")'` — size every hook (requests, limits, security contexts) before the first install
- **a hook Job can render NO resources and offer no values knob for them** (emqx-operator's `emqx-operator-pre-upgrade`): fix with HelmRelease `postRenderers` kustomize SMP on the named container, verifying the post-rendered output locally — an SMP that silently matches nothing reproduces the exact admission denial. Security contexts may still flow via values even when resources don't (emqx merges its top-level `podSecurityContext`/`containerSecurityContext` into hook pods). `upgrade.preUpgradeCheck: false` can skip such hooks outright
- **hook-job admission denial during UNINSTALL wedges the release** (k8s-monitoring's `waitForAlloyRemoval` hooks, cmdshift/platform#149): the pre-delete/add-finalizer hooks failed `require-resource-limits`, uninstall remediation itself failed, and the HR hung in `uninstalling` state ("Could not determine release state"). Recovery: suspend HR → delete `sh.helm.release.v1.<release>.*` secrets → resume → fresh install; a leftover deployed release needs a direct `helm uninstall`. Size uninstall hooks too — install-time greps of `helm template` cover the hooks only if you remember they also run on delete
- **git templates ≠ released chart** (emqx main-2.3 ships two hook Jobs, the released 2.3.2 chart one combined): render the pinned version from the repo index, not a git checkout
- **image pinning**: floating tags violate policy/convention — prefer per-commit tags (`main-YYYY-MM-DD-<sha>`) or digests
- prefer chart **values** for security contexts and resources over patches when the chart exposes them

## 3. Patching what values can't express

- strategic-merge patches on Deployments merge `containers` **by name** — a wrong name silently *adds* a container; verify the container name first
- `ClusterRole.rules` is atomic: strategic merge **replaces** it — append with JSON6902 (`op: add, path: /rules/-`)
- house example: a kustomization SMP on an operator's manager container (the thanos-operator pattern, cmdshift/platform#128 — the operator is since removed, see its runbook; the emqx-operator pre-upgrade Job SMP below is the live example)

## 4. Verify before pushing

`helm_verify [path] [release]` renders the release with the **exact** values flux will ship — `valuesFrom` refs resolved from the configMapGenerator entries, chart fetched from the source CRs; the single-release form is for ad-hoc values debugging. For schema-less charts it catches template errors, not key typos (see §0) — cross-check surprise diffs against the chart's `values.yaml`. When you need to eyeball the full rendered manifest (hook jobs, securityContext placement), `helm template` by hand — with the real values. And run `cr_validate` on any CR the chart/CRDs introduce before pushing; for field-level detail verify new-to-you API fields against the **on-cluster CRD schema** (undeclared fields fail the root dry-run and wedge the whole chain).

## Image-registry traps (pull-through cache)

- **A chart whose default image registry isn't a mapped upstream hard-fails at pull** (kyverno's `reg.kyverno.io` was the live case): the wildcard node mirror + `skipFallback: true` gives every registry not in the angos upstream map a hard image-pull failure — no silent direct-pull fallback. Override to a mapped upstream carrying identical content (`global.image.registry: ghcr.io` — reg.kyverno.io is a vanity proxy of ghcr, same token realm; rationale comment in `manifests/bases/policies/kyverno-values.yaml`). Upstream-map mechanics: [runbooks/local/cluster-rebuild.md](../../../runbooks/local/cluster-rebuild.md).
- **Chart `flags` maps are schema-less — unknown keys are silently dropped** (goldilocks: `--vpa-object-mode` was removed upstream while the values key would have kept flowing): verify flag names against the image's `--help` before wiring — `docker run --rm --entrypoint /goldilocks us-docker.pkg.dev/fairwinds-ops/oss/goldilocks:<tag> controller --help`.

## Feature-validation + operator-CR traps (k8s-monitoring, cmdshift/platform#149)

- **A chart that template-validates its main feature can't be reduced to an installer** (k8s-monitoring v4.5.2 required ≥1 enabled collector via `collectors.validate.atLeastOneEnabled` — no bypass, not even `collectors: {}`): check for hard validations in the chart's `templates/*validations*`/`_helpers.tpl` before planning a "chart only for the CRDs/operator" deployment. If the values can't disable the feature, the chart can't be stripped to scaffolding — adopt the standalone pieces instead (that's what the alloy-operator + Alloy CRs are).
- **A chart-generated CR with a nameless config reference lets the controller default the name** (k8s-monitoring's Alloy CR: `alloy.configMap: {create: false}` without `name` → operator mounted `<cr-name>-config`, silently picking up a STALE CM from an old generator). Fix pattern: always set the reference's `name` explicitly — `configMap: {create: false, name: <fullname>}` matching the chart's own generated CM name.
- **Discovery labelMatchers shared with chart-wide labels over-match** (k8s-monitoring hostMetrics: `labelMatchers` on `app.kubernetes.io/instance` matched the release label shared by ALL chart-deployed pods, and the pod-role discovery has no port-name filter — operator + ksm pods were scraped as node-exporter). Match on the specific `app.kubernetes.io/name`, and check what other objects carry the label before trusting a discovery selector.
- **An operator adopting a release name already used by a flux HelmRelease fights the old release storage** ("upgrade failed; rollback required" over immutable StatefulSet fields) — fresh name or purge `sh.helm.release.v1.<name>.*` + HR first. Full story: [runbooks/local/incidents.md](../../../runbooks/local/incidents.md).

## Worked examples

thanos-operator (removed locally, cmdshift/platform#128 — kept as precedent): helm chart attempt → install failed at the 1MB cap (~2.5MB of embedded CRDs) → vendored CRDs (regen burden) → repo's `bundle.yaml` via kustomization with three patches. Worked-example detail: [runbooks/local/adopting-a-chart.md](../../../runbooks/local/adopting-a-chart.md).

trivy-operator: chart 0.36.0 adopted clean (CRDs ship in `crds/`, no hook jobs, 23KB release) but three values keys were **silently ignored** (schema-less chart): `operator.resources` (wants top-level `resources`), `scanJobsConcurrentLimit`/`scanJobTTL` (want `operator.`, not `trivyOperator.`) — caught by inspecting the render, not by helm template. Values now live in a plain values file + configMapGenerator → `valuesFrom` (cmdshift/platform#31 pattern, helm_verify resolves it); operator-generated scan jobs needed the admission shaping trap above. Rationale in `security/trivy-values.yaml` + `security/README.md`.

## Operator-adoption traps (datastores group, cmdshift/platform#49)

- **Chart renders > 1MB because CRDs ship in `templates/`** (cloudnative-pg, emqx-operator): disable the chart's CRD rendering with its own knob (`crds.create: false` for cnpg, `skipCRDs: true` for emqx — each template gates on its own value) + a child Kustomization (crds group, `prune: false`) building the upstream repo's `config/crd` at a pinned tag — upstream-tracked beats vendoring (no regen burden, bump = tag ref kept in lockstep with the chart version; emqx tags have no `v` prefix). **flux's `install.crds: Skip` does not help here** — it only governs a chart's `crds/` directory, not CRDs rendered from `templates/`. Verify the build is load-restrictor-safe (no `../` refs) and diff it against the chart's CRDs — deltas can be deliberate (emqx's wholesale `config/crd` build carries `v2beta1` compat versions from upstream's own patch) (runbooks/local/adopting-a-chart.md).
- **Chartless operators with kustomize overlays** (pattern kept; the rabbitmq ×2 example was removed for the nats stack, cmdshift/platform#52): upstream `config/default` uses `../` refs that flux's kustomize load-restrictor blocks from a GitRepository, and the manager images ship `:latest`. Vendor the **rendered** `kubectl kustomize config/default` output (tag checkout) into the group dir; pin images with a kustomize `images:` transformer and patch resources in the group `kustomization.yaml`. Watch for objects the namespace transformer won't fix: Namespace objects (drop or patch), cert-manager `inject-ca-from` annotations and Certificate `dnsNames` (both bake `<ns>` in at render time — patch explicitly). The Bitnami OCI charts are not an alternative for anything — the free `bitnamicharts` catalog is frozen, and OCI has no index to search anyway (Docker Hub gates `tags/list`; exact-version probes or Artifact Hub are the enumeration paths).

- **Versioned image tags may live only on one registry, with different prefixes** (rabbitmq was the live example): its `:latest` was on ghcr AND docker hub, but versioned tags were ghcr-only and **without the `v` prefix** (`2.22.5`, not `v2.22.5`); docker hub's `rabbitmqoperator` repos lagged releases. `ErrImagePull ... not found` on a freshly pinned tag = check the registry's real tag list before touching anything else.

- **Clean charts whose images ship no USER directive** (nats stack, cmdshift/platform#52): `runAsNonRoot` fails the kubelet check unless `runAsUser` is set explicitly — check `docker inspect <img> --format '{{.Config.User}}'` before wiring security contexts, and check the chart's own values for `securityContext`/`containerSecurityContext` knobs (nack has them; the nats chart needs `podTemplate.merge`/`container.merge`).
- **Charts that `lookup` their own CRDs at render time** (kubeblocks): helm-controller renders without API discovery, so a chart whose templates `lookup` an API it doesn't ship fails install unless the CRDs are established first — by a separate crds chart (`prometheus-operator-crds` pattern), vendored CRDs in the `crds` group, or a `crds/` dir (helm install-only, the valkey-operator's shape).
- **Hardcoded admission-incompliant initContainers** (kubeblocks `tools` init: resources present, securityContext absent, no values knob): fix with HelmRelease `postRenderers` (kustomize SMP on the named initContainer). Verify the post-rendered output locally first — an SMP that silently matches nothing reproduces the exact admission denial.
- **KubeBlocks — aborted, not adopted** (cmdshift/platform#49): multi-engine operator (2 Deployments + 28 CRDs + inert Addon CRs + a dataprotection controller) rejected as not single-purpose enough; replaced by the valkey-operator. The abort left the 28 CRDs on-cluster (crds group is prune:false) — deleted manually like the kubescape removal. When rejecting an operator, sweep CRDs + operator-created CRs by hand; helm uninstall does not remove CRDs.
- **Even clean removals leave things behind** (nats/nack, cmdshift/platform#64): helm uninstall keeps `crds/`-dir CRDs (install-only — 6 `jetstream.nats.io` CRDs deleted by hand) and StatefulSet-uninstall leaves PVCs Bound (the nats JetStream PVC). Sweep both by hand; the rabbitmq vendored-render removal is the contrast — one prune reconcile cleaned everything. Procedure: the runbook's "Removing a chart".

## Full detail

[runbooks/local/adopting-a-chart.md](../../../runbooks/local/adopting-a-chart.md)
