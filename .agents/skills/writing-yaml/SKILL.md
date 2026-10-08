---
name: writing-yaml
description: Writing or editing YAML manifests in this repo — manifest file naming (the kind-suffix table), valuesFrom pattern, kustomization registration, comment rules, and the yaml_lint → cr_validate → dry-run verification gates. Load when writing or editing any .yaml manifest or helm values file.
---

# Writing YAML (manifests)

Scope: `manifests/**` (bases + clusters overlays). Never write outside the repo — agent scratch goes in `.agents/temp/`; plans go in `.agents/temp/plans/`. The cluster state is git-managed; these rules keep the diff reviewable and the drift zero.

## 1. Everything in files — no live patches

Never fix drift with `kubectl edit` / `talosctl patch` / `docker exec` mutations (the one documented exception: root `Kustomization/local` / `Bucket/main` during a pipeline wedge — the `pipeline-wedged` skill). Change the manifest and reconcile. If a fix needs a rebuild, note the pending state in `CHANGELOG.md` or the tracking issue.

## 2. Manifest conventions

- **File naming**: `<name>.<kind>.yaml` inside groups (`velero.helm-release.yaml`, `mimir.statefulset.yaml`, `mail.alertmanager-config.yaml`), `<action>.<kind>.yaml` for policies (`disallow-privileged.validating-policy.yaml`, `allow-velero-security-contexts.policy-exception.yaml`), plain `<name>-values.yaml` for helm values files. Follow the dir's existing pattern — don't invent spellings.

  The suffix is the exact Kubernetes kind, kebab-cased, as the last dot-segment. Kind→suffix table (cmdshift/platform#183):

  | Kind | Suffix | Example |
  |------|--------|---------|
  | HelmRelease / helm values | `helm-release` / `<release>-values.yaml` (no kind segment) | `velero.helm-release.yaml`, `velero-values.yaml` |
  | HelmRepository / GitRepository | `helm-repository` / `git-repository` | `cilium.helm-repository.yaml` |
  | ConfigMap | `config-map` | `node-agent-config.config-map.yaml` |
  | VerticalPodAutoscaler | `vertical-pod-autoscaler` (never `vpa`) | `talos-backup.vertical-pod-autoscaler.yaml` |
  | CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy | `cilium-network-policy` / `cilium-clusterwide-network-policy` | `default-deny.cilium-clusterwide-network-policy.yaml` |
  | ExternalSecret / ClusterSecretStore | `external-secret` / `cluster-secret-store` | `bucket-credentials.external-secret.yaml` |
  | ValidatingPolicy / GeneratingPolicy / PolicyException / TracingPolicy | `validating-policy` / `generating-policy` / `policy-exception` / `tracing-policy` | `disallow-privileged.validating-policy.yaml` |
  | ResourceQuota / LimitRange | `<namespace-or-scope>.resource-quota` / `.limit-range` | `policies.resource-quota.yaml`, `logging.limit-range.yaml` |
  | everything else | exact kebab-cased kind (`namespace`, `cronjob`, `job`, `service-account`, `role-binding`, `schedule`, `storage-class`, `gateway`, `httproute`, `referencegrant`, `cluster-issuer`, `backup-storage-location`, `pod-disruption-budget`, `cluster-compliance-report`, `bucket`, `kustomization`) | `talos-backup.cronjob.yaml` |

  Rules: (a) suffix = the exact kind, kebab-cased — abbreviations (`vpa`, `cm`, `sa`, `rb`, `ds`) are banned; (b) shape is `<name>.<kind>.yaml`, and every manifest file carries a kind segment except `<release>-values.yaml` and `kustomization.yaml` (which is load-bearing for kustomize and never renamed); (c) singleton config objects (ResourceQuota/LimitRange) take their scope as the name.
- **Every new file joins the group's inner `kustomization.yaml` resources list** (auto-discovered dirs excepted — but see the `kubectl kustomize` landmine: explicit-list dirs silently drop unlisted files from dry-runs while flux still applies them).
- **valuesFrom pattern** (cmdshift/platform#31): helm values live in a plain `<release>-values.yaml`, joined to the HelmRelease via `configMapGenerator` + `valuesFrom` (fixed name, `disableNameSuffixHash: true`). `helm_verify` resolves these refs — keep the generator name in sync.
- **YAML style**: match the surrounding files (2-space indent, quoted strings where the value is ambiguous).

## 3. Comments — minimize

Comments are a maintenance cost: stale ones actively lie. **Default is no comment — treat writing one as the exception that needs justification** (full rules + worked examples: [runbooks/local/code-comments.md](../../../runbooks/local/code-comments.md)):

1. **Don't add comments by default.** Delete-test: *if this comment were removed, would any future reader lose information they couldn't reconstruct from the value, the chart docs, or the git history?* Narration, restated config, section banners: never.
2. **Max 3 lines.** The story lives in the **group `README.md`** (`bases/<group>/README.md` — one home per group regardless of where values sit) with at most a short pointer at the value.
3. **Do comment environment-specific values** — anything that exists only because this cluster runs Talos-in-Docker. Exact marker vocabulary `# remove in the cloud` / `# true in the cloud` at the value; a new marker obligates a `manifests/clusters/cloud/notes.md` entry. Never repurpose the markers for ordinary rationale.
4. **Do reference issues that document bugs** (cmdshift/platform#N, fully qualified — commit SHAs stay SHAs): chart bugs, upstream landmines, workarounds. **Don't reference feature/update issues** — git history carries what landed.
5. **Evidence numbers justify sizing values at the value** (the `resource-sizing` skill): observed number + derivation, nothing more.
6. **Stale comments are worse than none** — changing a value means updating or deleting its comment in the same change.

## 4. Verification gates

Run, in order, before pushing anything through the reconciliation pipeline (the `platform-workflow` skill owns the full loop):

1. `yaml_lint` — every touched file, always.
2. `cr_validate` — CRD-backed objects against the on-cluster schema (undeclared fields fail the root dry-run and wedge the whole dependency chain).
3. `--dry-run` (`kubectl apply --dry-run=server` / `helm_verify` / `dryrun_check`) on new or updated YAML before the sync container picks it up.
