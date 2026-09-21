# Adopting a chart

Bringing a new helm chart in (or deciding how to deploy an upstream project at all). Worked example throughout: the thanos-operator, 2026-09-05 (kept as precedent — the operator was removed with the LGTM migration, cmdshift/platform#128, but the decision ladder stands).

## 0. Import the chart repo into the local helm client

Add the upstream repo locally first — name it the same as the HelmRepository CR it will get in `sources/`:

```
helm repo add <name> <url> && helm repo update
```

- `helm search repo <name>/ --versions | head` — find the exact version to pin (releases pin versions, never floating tags)
- `helm show values <name>/<chart> --version <v>` — read the real values surface before writing release values
- `helm template <release> <name>/<chart>` — the section-1 size check and admission renders need the chart locally anyway

The tools (helm_verify) resolve sources from the cluster's source CRs into their own temp dir, so a local import isn't strictly required — but it turns every ad-hoc lookup above into one command. Diagnostic note: when helm_verify prints `FAIL: <name> — repo <name> not found`, its `helm repo add` silently swallowed a failure (`|| true`) — usually a transient network hiccup; re-run before digging deeper (velero, 2026-09-06).

## 1. Can it be a helm release?

Helm persists the release manifest in the `sh.helm.release.*` Secret, which caps at **1MB** (`data: Too long: may not be more than 1048576 bytes`). Check the rendered size **before** the HelmRelease exists:

```
helm template <release> <chart> -f /tmp/values.yaml | wc -c
```

**Measure, don't estimate** — a gzipped-size estimate (~420KB) predicted safety for a chart whose helm install then failed hard; helm-controller's secret storage doesn't behave like `gzip | base64`.

If the manifest is too big, pick a strategy:
- **separate CRD chart** (the `prometheus-operator-crds` pattern — cleanest when upstream ships one)
- **upstream moves CRDs to helm's `crds/` dir** — install-only, never stored in the release secret; file an issue/PR
- **vendor the rendered CRDs** into `manifests/bases/crds/` + `crd.enable: false` on the release — works, but adds a manual regen-on-every-bump step (rejected for thanos for exactly that reason)
- **raw manifests via kustomization** (bundle.yaml, etc.) — no secret involved at all; the thanos-operator's final answer

## 2. Admission compliance

- **hook jobs are kyverno-checked**: `helm template <chart> | yq 'select(.kind == "Job")'` — size every hook (requests, limits, security contexts) before the first install
- **image pinning**: floating tags (`main`, `latest`) violate policy or convention — prefer per-commit tags (`quay.io/<org>/<repo>:main-YYYY-MM-DD-<sha>`) or digests
- prefer chart **values** for security contexts and resources over patches when the chart exposes them

## 3. Patching what values can't express

For the kustomization-over-raw-manifests path:
- strategic-merge patches on Deployments merge `containers` **by name** — a wrong name silently *adds* a container. Verify the container name first
- `ClusterRole.rules` is an atomic list: strategic merge **replaces** it — use a JSON6902 `op: add, path: /rules/-` to append instead
- house example: the (removed) thanos-operator kustomization's three patches — seccomp + image pin via strategic merge, events RBAC via JSON6902 (shape preserved in git history and in the `adopt-chart` skill)

## 4. Verify before pushing

```
helm_verify [path] [release]      # renders the release with the EXACT values flux will ship
                                  # (resolves valuesFrom refs + chart from source CRs locally)
```

Use the single-release form (`helm_verify manifests/bases/<group> <release>`) for ad-hoc values debugging. When you need to eyeball the full rendered manifest (hook jobs, securityContext placement), render by hand — but render with the real values, not reconstructed ones:

```
helm template <release> <chart> --namespace <ns> -f /tmp/release-values.yaml
```

And verify any new-to-you API fields against the **on-cluster CRD schema** before pushing — undeclared fields fail the root dry-run and wedge the whole dependency chain:

```
kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'
```

## Worked example (thanos-operator — historical, operator removed cmdshift/platform#128)

helm chart attempt → install failed at the 1MB secret cap (its CRDs are ~2.5MB of the manifest) → vendored CRDs (worked, regen burden) → reverted to the repo's `bundle.yaml` via kustomization with three patches (seccomp, image pin, events RBAC). Full rationale in git history (`observability/thanos-operator.kustomization.yaml` was deleted with the teardown).

## Operator adoption (datastores group, cmdshift/platform#49)

Four operators, four different install channels — the decision tree in practice:

- **Clean chart** (valkey-operator 0.6.0): CRDs in `crds/` (helm install-only — no 1MB risk), no hook jobs, pod+container security contexts and house-convention resources all in the chart defaults. One values key (`metrics.serviceMonitor.enabled`) — nested under `metrics.`, silently ignored at top level (schema-less chart; caught because the ServiceMonitor didn't exist on-cluster after a green install).
- **Chart with oversized CRDs** (cloudnative-pg 0.29.0): rendered 1.27MB > the 1MB release-secret cap because the 11 CRDs live in `templates/crds/` (rendered into the release). Fix: `crds.create: false` + a **`cnpg-crds` child Kustomization** (crds group, `prune: false`) building upstream `config/crd` at a pinned tag via a new GitRepository — preferred over vendoring the ~1.2MB of CRDs into the repo (no regen burden; a version bump = the tag ref, kept in lockstep with the chart's appVersion). Before switching, verify the upstream kustomize build is load-restrictor-safe (no `../` refs out of `config/crd` — checked) and semantically identical to the chart's CRDs (verified via canonical JSON diff; the only delta was the chart-injected `helm.sh/resource-policy: keep` annotation, meaningless for flux-managed CRDs). The child Kustomization needs `dependsOn: sources`; no hard ordering vs the operator install (the chart doesn't render-lookup CRDs; its fail-closed webhooks only fire on CNPG CRs). Post-split release: 43KB.
- **Clean chart, no-USER images** (nats 2.14.6 + nack 0.35.0, cmdshift/platform#52): both charts from one repo (`nats-io/k8s`), no hook jobs, nack ships CRDs in `crds/` (install-only, valkey shape), tiny renders (9KB/3KB — no cap concern). Traps hit: every image in the stack (`nats`, config-reloader, prom-exporter, nats-box, jetstream-controller) ships **no USER directive** — `runAsNonRoot` fails the kubelet check without an explicit `runAsUser` (65534; local-path PVCs are 0777 so the JetStream fileStore is writable); nats-box's bootstrap is not idempotent across restarts (`[ -s context ]` misses symlinks → `ln` aborts the `-ec` script → CrashLoop) — disabled rather than carrying a command override for a debug-only pod; the chart's PodMonitor was invisible to prometheus until `podMonitorSelectorNilUsesHelmValues: false` joined its ServiceMonitor sibling in `kube-prometheus-stack-values.yaml`.
- **Chart with oversized CRDs in `templates/`, plus a hook Job with no resources** (emqx-operator 2.3.2, cmdshift/platform#64): the chart packages ~1.42MB of CRDs in `templates/crds.yaml` — a `.Files.Get` of a ~1.13MB file generated at package time from `config/crd/bases` (in the released chart only, not git). Same shape as the cloudnative-pg fix with one nuance: flux's `install.crds: Skip` only governs a chart's `crds/` directory — CRDs rendered from `templates/` are stopped only by the chart's own knob (`skipCRDs: true` here, template-gated). The CRDs land via the `emqx-operator-crds` child Kustomization (crds group, `prune: false`) building upstream `config/crd` at a GitRepository tag kept in lockstep with the chart version (emqx tags have no `v` prefix). The wholesale `config/crd` build applies upstream's `compat/v2beta1_patch.yaml`, so the on-cluster `emqxes.apps.emqx.io` CRD carries both `v2` and `v2beta1` — deliberate (fresh cluster, matches upstream's own kustomize output); conversion strategy is None in 2.3.x (webhook conversion was removed in the 2.2→2.3 cutover). The pre-upgrade hook Job (`emqx-operator-pre-upgrade`, container `cleanup`) renders no resources and has no values knob for hook resources — postRenderers SMP on the named container (kubeblocks `tools` pattern; verify the post-rendered output locally — kustomize build over the helm render); security contexts DO flow via values (the chart merges top-level `podSecurityContext`/`containerSecurityContext` into hook pods, runAsUser 65534 auto-added). Gotcha: git templates ≠ released chart — main-2.3 ships two hook Jobs, the released 2.3.2 chart one combined (`upgrade.preUpgradeCheck: false` skips it; kept enabled as a no-op safety net).
- **Chartless, kustomize-overlay operator** (**pattern kept, example removed** — rabbitmq cluster-operator + messaging-topology-operator were removed for the nats stack, cmdshift/platform#52): upstream `config/default` uses `../` base refs — flux's kustomize load-restrictor blocks building them from a GitRepository, and the repos ship no release YAMLs. Vendor the rendered `kubectl kustomize config/default` output (built from a tag checkout) into the group dir. Traps hit, all fixed by patches in the group `kustomization.yaml`:
  - the images transformer must pin real tags — **versioned tags may live on only one registry, with different prefixes** (rabbitmq's versioned tags were ghcr-only and without the `v` prefix; docker hub's `rabbitmqoperator` repos lagged). A `not found` pull error means check the registry's real tag list before touching anything else;
  - the namespace transformer doesn't rewrite: Namespace objects (mto ships one — `$patch: delete`), cert-manager `inject-ca-from` annotations (4 webhook configs), Certificate `dnsNames` (bake `<ns>.svc` at render time). Patch all three explicitly — verified locally with `kubectl kustomize` before pushing (zero `rabbitmq-system` refs in the build);
  - one upstream Certificate (`metrics-certs`) had placeholder dnsNames and no consumer — deleted rather than patched.
- **Rejected** (kubeblocks 1.0.2): multi-engine operator (2 Deployments, 28 CRDs, 9 inert Addon CRs, dataprotection controller) — not single-purpose enough for this repo. Aborted mid-install; three abort-specific landmines are worth knowing for any future rejection:
  - the chart `lookup`s its own Addon CRD at render time and ships no CRDs (no `crds/` dir, no crds chart upstream) — helm-controller renders without API discovery, so install fails unless the CRDs are established first;
  - the `tools` initContainer hardcodes no securityContext (resources only) with no values knob — postRenderers SMP fixes it, **but verify the patch locally**: an SMP that matches nothing reproduces the identical admission denial, and the failure message doesn't say which container;
  - abort cleanup: the failed install's partial apply leaves operator CRs (Addons, StorageProviders) behind even after uninstall remediation, and the `crds` group's prune:false leaves the CRDs — both need manual deletion. Deleting the storage secrets mid-recovery wedges remediation (`missing target release for rollback`) — see the `helmrelease-stuck` skill.

## Removing a chart

What helm uninstall leaves behind, learned across the datastore-operator removals:

- **CRDs survive every uninstall** — CRDs shipped in a chart's `crds/` dir are install-only and helm never removes them (the nats/nack removal left 6 `jetstream.nats.io` CRDs to `kubectl delete crd` by hand, cmdshift/platform#64); vendored-render CRDs under a `prune: true` group kustomization instead disappear with their files (the rabbitmq removal pruned deployments, webhooks, certificates, and CRDs in one reconcile). The `crds` group is `prune: false`, so its child-kustomization CRDs (gateway-api, cnpg, emqx) must also be removed by hand.
- **StatefulSet uninstall leaves PVCs Bound** — the nats JetStream PVC `nats-js-nats-0` (2Gi local-path) outlived its release; its PV drained to Released/Delete on its own once reclaimed.

---

*Agent entry point: the `adopt-chart` skill in `.agents/skills/adopt-chart/`.*
