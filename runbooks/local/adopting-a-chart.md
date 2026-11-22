# Adopting a chart

Bringing a new helm chart in (or deciding how to deploy an upstream project at all). The narrative companion of the `adopt-chart` skill: the skill carries the procedure and one rule per trap, this runbook the worked examples. Several examples are removed components kept as precedent — thanos-operator (cmdshift/platform#128), emqx-operator, rabbitmq, nats/nack, kubeblocks, k8s-monitoring, goldilocks — the decision ladder and the traps stand.

## 0. Import the chart repo into the local helm client

Add the upstream repo locally first — name it the same as the HelmRepository CR it will get in `sources/`:

```
helm repo add <name> <url> && helm repo update
```

- `helm search repo <name>/ --versions | head` — find the exact version to pin (releases pin versions, never floating tags)
- `helm show values <name>/<chart> --version <v>` — read the real values surface before writing release values
- `helm template <release> <name>/<chart>` — the section-1 size check and admission renders need the chart locally anyway

The tools (helm_verify) resolve sources from the cluster's source CRs into their own temp dir, so a local import isn't strictly required — but it turns every ad-hoc lookup above into one command.

`helm_verify` index verdicts are trustworthy — index fetches are on-miss only (probe the local index → one scoped `helm repo update` → verdict):
- `FAIL: <name> — helm repo add/update … failed` — the index fetch itself failed (usually a transient network hiccup); re-run before digging deeper. These used to be swallowed (`|| true`), leaving a stale/empty index that produced phantom "version not in index" verdicts.
- `version X not in <repo> index` after a successful fetch — the pin is genuinely wrong or missing. Without this check `helm template --version` silently rendered the *closest* index version and passed.
- a `v`-prefixed pin (`version: "v1.2.3"`) is fine — both sides are normalized.

Charts pinned in two places bump in **lockstep** — cilium's bootstrap `var.cilium_chart_version` (`cluster/local/bootstrap/variables.tf`) and the flux HelmRelease (`manifests/bases/networking/cilium.helm-release.yaml`) carry independent pins: flux adoption converges the live release to the HelmRelease's pin, so bumping only one side silently moves the live release to whichever pin lags.

**Bitnami is not an alternative source** for anything — the free `bitnamicharts` catalog is frozen, and OCI repos have no index to search (Docker Hub gates `tags/list`; exact-version probes or Artifact Hub are the enumeration paths).

## 1. Can it be a helm release?

Helm persists the release manifest in the `sh.helm.release.*` Secret, which caps at **1MB** (`data: Too long: may not be more than 1048576 bytes`). Check the rendered size **before** the HelmRelease exists:

```
helm template <release> <chart> -f .agents/temp/values.yaml | wc -c
```

**Measure, don't estimate** — a gzipped-size estimate (~420KB) predicted safety for a chart whose helm install then failed hard; helm-controller's secret storage doesn't behave like `gzip | base64`.

If the manifest is too big, pick a strategy:
- **separate CRD chart** (the `prometheus-operator-crds` pattern — cleanest when upstream ships one)
- **upstream moves CRDs to helm's `crds/` dir** — install-only, never stored in the release secret; file an issue/PR. Charts that already ship `crds/` need the HelmRelease's `install.crds: Create` / `upgrade.crds: CreateReplace` (flux defaults to create-only — without it chart bumps skip CRD upgrades; the vpa release's shape, cmdshift/platform#62, also carried by valkey, strimzi and cilium)
- **vendor the rendered CRDs** into `manifests/bases/crds/` + `crd.enable: false` on the release — works, but adds a manual regen-on-every-bump step (rejected for thanos for exactly that reason)
- **raw manifests via kustomization** (bundle.yaml, etc.) — no secret involved at all; the thanos-operator's final answer

Charts whose CRDs render from `templates/` (no `crds/` dir) are a variant of the first two: stop the render with the chart's own skip knob and land the CRDs via a child kustomization — worked through for cloudnative-pg and emqx-operator under "Operator adoption" below.

**Generated ConfigMaps have their own cap — ~256KB, in the kustomize-controller dry-run** (cmdshift/platform#171): client-side-apply embeds object content in `last-applied-configuration`, so a 420KB dashboard JSON alone failed a whole group's dry-run with a confusing Job error — NOT the 1MiB CM data limit, a different check. Keep every generated CM (dashboards, rules, values bundles) well under ~250KB and split large content into multiple configMapGenerator entries; `dryrun_check` reports the failing object instead of kubectl's first-failure stop.

## 2. Admission compliance

- **hook jobs are kyverno-checked**: `helm template <chart> | yq 'select(.kind == "Job")'` — size every hook (requests, limits, security contexts) before the first install
- **image pinning**: floating tags (`main`, `latest`) violate policy or convention — prefer per-commit tags (`quay.io/<org>/<repo>:main-YYYY-MM-DD-<sha>`) or digests
- prefer chart **values** for security contexts and resources over patches when the chart exposes them
- **uninstall hooks are admission-checked too** — pre-delete/finalizer hook Jobs run on delete; an admission-denied one fails uninstall remediation and wedges the HR in `uninstalling` ("Could not determine release state"). Size them with the install hooks. Story + recovery: [incidents.md](incidents.md) "k8s-monitoring removal" (cmdshift/platform#149); ladder: the `helmrelease-stuck` skill
- **hook Jobs / containers with no resources and no values knob** — HelmRelease `postRenderers` kustomize SMP on the named container, verified against the post-rendered output locally (an SMP that silently matches nothing reproduces the exact admission denial). Security contexts may still flow via values even when resources don't; a chart toggle may skip the hook outright (`upgrade.preUpgradeCheck: false` for emqx). Worked examples under "Operator adoption": the emqx-operator pre-upgrade Job, the kubeblocks `tools` initContainer
- **render the released chart, not git** — git templates ≠ released chart (emqx main-2.3 ships two hook Jobs, the released 2.3.2 chart one combined); render the pinned version from the repo index
- **images without a USER directive** — `runAsNonRoot` fails the kubelet check unless `runAsUser` is set; `docker inspect <img> --format '{{.Config.User}}'` before wiring security contexts (the nats stack under "Operator adoption")

## 3. Patching what values can't express

For the kustomization-over-raw-manifests path:
- strategic-merge patches on Deployments merge `containers` **by name** — a wrong name silently *adds* a container. Verify the container name first
- `ClusterRole.rules` is an atomic list: strategic merge **replaces** it — use a JSON6902 `op: add, path: /rules/-` to append instead
- house example: the (removed) thanos-operator kustomization's three patches — seccomp + image pin via strategic merge, events RBAC via JSON6902 (shape preserved in git history)
- Helm-path equivalent: a HelmRelease `postRenderers` SMP on the named container (the emqx-operator pre-upgrade Job — emqx has since been swapped for strimzi, cmdshift/platform#166, whose chart has no hook Jobs and needs no SMP)

## 4. Verify before pushing

```
helm_verify [path] [release]      # renders the release with the EXACT values flux will ship
                                  # (resolves valuesFrom refs + chart from source CRs locally)
```

Use the single-release form against the group overlay (`helm_verify manifests/clusters/local/<group> <release>`) for ad-hoc values debugging: the tool builds that dir with `kubectl kustomize`, which follows the overlay's `resources:` into the base HelmRelease and generates the values ConfigMaps, so the render is what flux ships. A bare `helm_verify` runs every group overlay the same way (the full-tree pre-reconcile gate; each overlay is built on its own — cmdshift/platform#187), and `helm_verify '' <release>` finds the release in whichever overlay holds it. Pointing it at the base dir (`manifests/bases/<group>`) FAILs on unresolved `valuesFrom` (the values live in the overlay — cmdshift/platform#183). When you need to eyeball the full rendered manifest (hook jobs, securityContext placement), render by hand — but render with the real values, not reconstructed ones:

```
helm template <release> <chart> --namespace <ns> -f .agents/temp/release-values.yaml
```

And verify any new-to-you API fields against the **on-cluster CRD schema** before pushing — undeclared fields fail the root dry-run and wedge the whole dependency chain:

```
kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'
```

For schema-less charts `helm_verify` catches template errors, not key typos — unknown values keys are silently dropped, so cross-check surprise diffs (or objects missing after a green install) against the chart's `values.yaml`. Run `cr_validate` on any CR the chart/CRDs introduce.

## Values-surface and image traps

- **Unknown values keys are silently dropped** (trivy-operator): chart 0.36.0 adopted clean (CRDs in `crds/`, no hook Jobs, 23KB release) but three keys were ignored — `operator.resources` (wants top-level `resources`), `scanJobsConcurrentLimit`/`scanJobTTL` (want `operator.`, not `trivyOperator.`) — caught by inspecting the render, not by `helm template` passing. Values live in a plain values file + configMapGenerator → `valuesFrom` (the cmdshift/platform#31 pattern; `helm_verify` resolves it); the operator-generated scan Jobs needed admission shaping too. Current rationale: `manifests/clusters/local/scanning/trivy-values.yaml` + [scanning/README.md](../../manifests/bases/scanning/README.md).
- **Chart `flags` maps are schema-less too** (goldilocks, since removed): `--vpa-object-mode` was removed upstream while the values key would have kept flowing. Verify flag names against the image's `--help` before wiring — e.g. `docker run --rm --entrypoint /goldilocks us-docker.pkg.dev/fairwinds-ops/oss/goldilocks:<tag> controller --help`.
- **A default image registry outside the pull-through map hard-fails at pull** (kyverno's `reg.kyverno.io`): the wildcard node mirror + `skipFallback: true` gives every registry not in the angos upstream map a hard image-pull failure — no silent direct-pull fallback. Override to a mapped upstream carrying identical content (`global.image.registry: ghcr.io` — reg.kyverno.io is a vanity proxy of ghcr, same token realm; rationale table in [policies-config/README.md](../../manifests/bases/policies-config/README.md), moved there off the values file by cmdshift/platform#183). Upstream-map mechanics: [cluster-rebuild.md](cluster-rebuild.md) "Companions: the caching registry".
- **Versioned tags may live on one registry only, with different prefixes** — the rabbitmq example under "Operator adoption".

## Worked example (thanos-operator — historical, operator removed cmdshift/platform#128)

helm chart attempt → install failed at the 1MB secret cap (its CRDs are ~2.5MB of the manifest) → vendored CRDs (worked, regen burden) → reverted to the repo's `bundle.yaml` via kustomization with three patches (seccomp, image pin, events RBAC). Full rationale in git history (`observability/thanos-operator.kustomization.yaml` was deleted with the teardown).

## Operator adoption (datastores group, cmdshift/platform#49)

Four operators, four different install channels — the decision tree in practice:

- **Clean chart** (valkey-operator 0.6.0): CRDs in `crds/` (helm install-only — no 1MB risk), no hook jobs, pod+container security contexts and house-convention resources all in the chart defaults. One values key (`metrics.serviceMonitor.enabled`) — nested under `metrics.`, silently ignored at top level (schema-less chart; caught because the ServiceMonitor didn't exist on-cluster after a green install).
- **Chart with oversized CRDs** (cloudnative-pg 0.29.0): rendered 1.27MB > the 1MB release-secret cap because the 11 CRDs live in `templates/crds/` (rendered into the release). Fix: `crds.create: false` + a **`cnpg-crds` child Kustomization** (crds group, `prune: false`) building upstream `config/crd` at a pinned tag via a new GitRepository — preferred over vendoring the ~1.2MB of CRDs into the repo (no regen burden; a version bump = the tag ref, kept in lockstep with the chart's appVersion). Before switching, verify the upstream kustomize build is load-restrictor-safe (no `../` refs out of `config/crd` — checked) and semantically identical to the chart's CRDs (verified via canonical JSON diff; the only delta was the chart-injected `helm.sh/resource-policy: keep` annotation, meaningless for flux-managed CRDs). The child Kustomization needs `dependsOn: sources`; no hard ordering vs the operator install (the chart doesn't render-lookup CRDs; its fail-closed webhooks only fire on CNPG CRs). Post-split release: 43KB.
- **Clean chart, no-USER images** (nats 2.14.6 + nack 0.35.0, cmdshift/platform#52; since removed, cmdshift/platform#64): both charts from one repo (`nats-io/k8s`), no hook jobs, nack ships CRDs in `crds/` (install-only, valkey shape), tiny renders (9KB/3KB — no cap concern). Traps hit: every image in the stack (`nats`, config-reloader, prom-exporter, nats-box, jetstream-controller) ships **no USER directive** — `runAsNonRoot` fails the kubelet check without an explicit `runAsUser` (65534; local-path PVCs are 0777 so the JetStream fileStore is writable); nats-box's bootstrap is not idempotent across restarts (`[ -s context ]` misses symlinks → `ln` aborts the `-ec` script → CrashLoop) — disabled rather than carrying a command override for a debug-only pod; the chart's PodMonitor was invisible to prometheus until `podMonitorSelectorNilUsesHelmValues: false` joined its ServiceMonitor sibling in `kube-prometheus-stack-values.yaml`. Security-context knobs differ per chart even within one repo: nack exposes `securityContext`/`containerSecurityContext` values; the nats chart needs `podTemplate.merge`/`container.merge`.
- **Chart with oversized CRDs in `templates/`, plus a hook Job with no resources** (emqx-operator 2.3.2, cmdshift/platform#64; since swapped for strimzi, cmdshift/platform#166): the chart packages ~1.42MB of CRDs in `templates/crds.yaml` — a `.Files.Get` of a ~1.13MB file generated at package time from `config/crd/bases` (in the released chart only, not git). Same shape as the cloudnative-pg fix with one nuance: flux's `install.crds: Skip` only governs a chart's `crds/` directory — CRDs rendered from `templates/` are stopped only by the chart's own knob (`skipCRDs: true` here, template-gated). The CRDs land via the `emqx-operator-crds` child Kustomization (crds group, `prune: false`) building upstream `config/crd` at a GitRepository tag kept in lockstep with the chart version (emqx tags have no `v` prefix). The wholesale `config/crd` build applies upstream's `compat/v2beta1_patch.yaml`, so the on-cluster `emqxes.apps.emqx.io` CRD carries both `v2` and `v2beta1` — deliberate (fresh cluster, matches upstream's own kustomize output); conversion strategy is None in 2.3.x (webhook conversion was removed in the 2.2→2.3 cutover). The pre-upgrade hook Job (`emqx-operator-pre-upgrade`, container `cleanup`) renders no resources and has no values knob for hook resources — postRenderers SMP on the named container (kubeblocks `tools` pattern; verify the post-rendered output locally — kustomize build over the helm render); security contexts DO flow via values (the chart merges top-level `podSecurityContext`/`containerSecurityContext` into hook pods, runAsUser 65534 auto-added). Gotcha: git templates ≠ released chart — main-2.3 ships two hook Jobs, the released 2.3.2 chart one combined (`upgrade.preUpgradeCheck: false` skips it; kept enabled as a no-op safety net).
- **Chart with oversized CRDs that FIT once a deprecated API is disabled** (opensearch-operator 3.0.14, cmdshift/platform#199): chart defaults render 1.21MB (10 legacy `opensearch.opster.io` CRDs + 10 `opensearch.org` CRDs — install dies at the cap); `legacyAPI.enabled: false` on a fresh install drops the legacy half → 660KB in the release. When the child-kustomization escape hatch looks tempting, check what upstream's buildable dir actually carries first: `opensearch-operator/config/crd` ships all 20 CRDs **plus a full `servicemonitors.monitoring.coreos.com` CRD copy** (stale controller-gen) — applying it would plant a stale, unowned ServiceMonitor CRD (no `monitoring.coreos.com` CRDs are installed since cmdshift/platform#146; where a prometheus-operator owns one, it would downgrade that schema); vendoring org-only files = the regen burden rejected for thanos/CNPG. Standing obligations: re-measure the render on every bump (the org clusters CRD alone is 588KB and grows); the webhook is cert-manager-issued (chart does a live `lookup` that fails hard without the cert-manager API — the consuming group's Kustomization needs `dependsOn` on the certificates group); Restricted-PSS needs values the chart doesn't default (seccompProfile, caps drop ALL) while the image itself is distroless nonroot with a direct `/manager` entrypoint (exec-deny-list-safe, unlike strimzi).
- **Chartless, kustomize-overlay operator** (**pattern kept, example removed** — rabbitmq cluster-operator + messaging-topology-operator were removed for the nats stack, cmdshift/platform#52): upstream `config/default` uses `../` base refs — flux's kustomize load-restrictor blocks building them from a GitRepository, and the repos ship no release YAMLs. Vendor the rendered `kubectl kustomize config/default` output (built from a tag checkout) into the group dir. Traps hit, all fixed by patches in the group `kustomization.yaml`:
  - the images transformer must pin real tags — **versioned tags may live on only one registry, with different prefixes** (rabbitmq's versioned tags were ghcr-only and without the `v` prefix; docker hub's `rabbitmqoperator` repos lagged). A `not found` pull error means check the registry's real tag list before touching anything else;
  - the namespace transformer doesn't rewrite: Namespace objects (mto ships one — `$patch: delete`), cert-manager `inject-ca-from` annotations (4 webhook configs), Certificate `dnsNames` (bake `<ns>.svc` at render time). Patch all three explicitly — verified locally with `kubectl kustomize` before pushing (zero `rabbitmq-system` refs in the build);
  - one upstream Certificate (`metrics-certs`) had placeholder dnsNames and no consumer — deleted rather than patched.
- **Rejected** (kubeblocks 1.0.2): multi-engine operator (2 Deployments, 28 CRDs, 9 inert Addon CRs, dataprotection controller) — not single-purpose enough for this repo. Aborted mid-install; three abort-specific landmines are worth knowing for any future rejection:
  - the chart `lookup`s its own Addon CRD at render time and ships no CRDs (no `crds/` dir, no crds chart upstream) — helm-controller renders without API discovery, so install fails unless the CRDs are established first (a separate crds chart — the `prometheus-operator-crds` pattern — vendored CRDs in the `crds` group, or a `crds/` dir as valkey ships);
  - the `tools` initContainer hardcodes no securityContext (resources only) with no values knob — postRenderers SMP fixes it, **but verify the patch locally**: an SMP that matches nothing reproduces the identical admission denial, and the failure message doesn't say which container;
  - abort cleanup: the failed install's partial apply leaves operator CRs (Addons, StorageProviders) behind even after uninstall remediation, and the `crds` group's prune:false leaves the CRDs — both need manual deletion. Deleting the storage secrets mid-recovery wedges remediation (`missing target release for rollback`) — see the `helmrelease-stuck` skill.

## Operator-CR traps (k8s-monitoring — removed, cmdshift/platform#149)

The Alloy-CR migration (k8s-monitoring chart → alloy-operator + Alloy CRs; all since removed by the OpenObserve migration, cmdshift/platform#171) left four generic rules:

- **A chart that template-validates its main feature can't be reduced to an installer**: k8s-monitoring v4.5.2 required ≥1 enabled collector via `collectors.validate.atLeastOneEnabled` — no bypass, not even `collectors: {}`. Check `templates/*validations*` / `_helpers.tpl` for hard validations before planning a "chart only for the CRDs/operator" deployment; if values can't disable the feature, adopt the standalone pieces instead (what alloy-operator + Alloy CRs were).
- **Name every chart-generated config reference explicitly**: the chart's Alloy CR with `alloy.configMap: {create: false}` and no `name` let the operator default to `<cr-name>-config` — silently mounting a STALE CM from an old generator. Always set the reference's `name` (`configMap: {create: false, name: <fullname>}`, matching the chart's own generated CM name).
- **Discovery selectors on chart-wide labels over-match**: hostMetrics `labelMatchers` on `app.kubernetes.io/instance` matched the release label shared by ALL chart-deployed pods, and the pod-role discovery has no port-name filter — operator + ksm pods were scraped as node-exporter. Match the specific `app.kubernetes.io/name`, and check what else carries a label before trusting a discovery selector.
- **An operator-managed release reusing a flux HelmRelease's name fights the old release storage** ("upgrade failed; rollback required" over immutable StatefulSet fields) — fresh name, or purge `sh.helm.release.v1.<name>.*` + the HR first. Full story, plus the uninstall-hook wedge: [incidents.md](incidents.md) "k8s-monitoring removal".

## Removing a chart

What helm uninstall leaves behind, learned across the datastore-operator removals:

- **CRDs survive every uninstall** — CRDs shipped in a chart's `crds/` dir are install-only and helm never removes them (the nats/nack removal left 6 `jetstream.nats.io` CRDs to `kubectl delete crd` by hand, cmdshift/platform#64); vendored-render CRDs under a `prune: true` group kustomization instead disappear with their files (the rabbitmq removal pruned deployments, webhooks, certificates, and CRDs in one reconcile). The `crds` group is `prune: false`, but its child Kustomizations' CRDs are not immune either: **deleting a child Kustomization object cascades GC through its inventory even with `prune: false`** (the emqx removal in cmdshift/platform#166 lost the `emqx.io` CRDs to the object deletion — no hand sweep, and the reverse landmine for cnpg/gateway-api: never delete those children casually). Only removing the CRD files from the child's own resources list orphans the CRDs safely.
- **StatefulSet uninstall leaves PVCs Bound** — the nats JetStream PVC `nats-js-nats-0` (2Gi local-path) outlived its release; its PV drained to Released/Delete on its own once reclaimed.

---

*Agent entry point: the `adopt-chart` skill in `.agents/skills/adopt-chart/`.*
