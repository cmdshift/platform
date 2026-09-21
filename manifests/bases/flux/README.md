# flux

The flux v2 controllers themselves + `flux-config/` (the `Bucket/main` source and root `Kustomization/local` — the CR lives at `manifests/clusters/local/flux-config/local.kustomization.yaml`, `path: ./manifests/clusters/local`, mirrored by the bootstrap twin in `cluster/local/bootstrap/main.tf`).

## Source of truth chain

Local file → sync container (full `rc mirror --overwrite --remove` re-mirror every 5s) → `flux` bucket on rustfs → `Bucket/main` → root `Kustomization/local` → children in dependency order. Pipeline mechanics and wedge recovery: [runbooks/local/pipeline-wedged.md](../../../runbooks/local/pipeline-wedged.md).

## flux-config owns the pipeline's own objects

The root `local` Kustomization and `main` Bucket are managed by the `flux-config` kustomization (`force: true` adopts them from the terraform bootstrap's helm-hook objects on every fresh install). They're duplicated in `cluster/local/bootstrap` `extraObjects` — close enough, not identical (the bootstrap twin is minimal; flux-config converges both on first reconcile). **A bad edit to either wedges the pipeline silently** (everything keeps running, nothing applies) — fix forward with `kubectl -n flux-system edit kustomization local` / `edit bucket main`, **never delete them** (the root has `deletionPolicy: Orphan`, but its absence stops all reconciliation).

## Flux API traps

- **Kustomizations**: `wait: true` **ignores** `spec.healthChecks` — gate custom resources on real operator status with `spec.healthCheckExprs` (CEL; in use on the `*-config` kustomizations); copy battle-tested expressions from https://fluxcd.io/flux/cheatsheets/cel-healthchecks/ (ClusterIssuer, ClusterSecretStore, etc. — only the apiVersion **group** is matched, `kind` optional for group-wide entries). Two exprs landmines: **empty conditions pass vacuously** (`.all` over `[]` is true — a CR the operator hasn't reconciled yet reads Ready, so gate on the operator's single Ready condition knowing that), and **never wait on conditionless CRs** (TracingPolicy et al. have no status — the health check polls the full `timeout` per attempt, failing with `no matches for kind` while the CRD demonstrably exists; find the real loaded-signal elsewhere, e.g. `tetra tracingpolicy list` + an alert). A single transient failure mid-rollout is not a wedge — re-poll before diagnosing (a terminating old pod counts as unavailable via the CR status).
- **Verify new API fields against the on-cluster CRD schema before pushing** (`kubectl get crd <crd> -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.<field>}'`) — undeclared fields fail the root dry-run ("field not declared in schema") and wedge the whole dependency chain (`healthyWhen` did exactly this). When unsure of a flux/CRD API shape, fetch the upstream docs or CRD (webfetch) instead of guessing. Kustomize dry-run caveat: dirs without a `kustomization.yaml` (e.g. `crds/`) fail standalone `kustomize build`/`kubectl kustomize` but build fine in flux (implicit kustomization auto-generated listing all YAMLs) — validate those with `flux build kustomization <name> --path <dir>`, not the CLI.
- **The flux2 chart's `securityContext` values replace, not merge** — the chart's securityContext template swaps its whole defaults block when ANY `securityContext` value is set, so the full container context must be spelled out: providing only `runAsGroup` silently dropped `allowPrivilegeEscalation: false`, `capabilities.drop: ALL`, and `readOnlyRootFilesystem: true` from every controller (hit live on the NSA gid hardening; the pod was still admission-legal, just unhardened — caught by review, not admission). Applies to every controller section of `flux-values.yaml` (`helmController`, `kustomizeController`, `sourceController`, `notificationController` — see the repeated "values replace the chart's sc defaults" notes).

## Polling intervals (deliberately loose)

Bucket `main` 5m, root + child kustomizations 1h drift-heal (`retryInterval: 5s` everywhere). Propagation is **event-driven** — artifact change + `dependsOn` requeue at 5s — so the loosened intervals cost nothing in latency; what they buy is background reconciles not interleaving with interactive edits (the old 1m bucket poll could publish a half-mirrored artifact mid-edit and the whole chain would apply it). The bootstrap twins run 1m/10m until flux-config adopts and converges them — keeps fresh rebuilds fast. **Do not suspend kustomizations** — a suspended tree reconciles nothing on rebuild, breaking the one-shot requirement. Cloud keeps tighter 10m/1m (multiple operators make frequent drift-heal worthwhile).

## Sizing

Burst-heavy delivery components (source/helm-controllers) carry 1000m CPU / 512Mi-1Gi — starving them wedges the whole pipeline (evidence-bumped; see the resource-sizing skill).
