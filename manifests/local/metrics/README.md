# metrics

metrics-server (helm release) + the VPA sizing stack: vpa (recommender-only) and goldilocks, both from the `fairwinds` HelmRepository. All three install in kube-system alongside each other — no separate namespace.

## VPA: recommendations only, never mutation

All VPAs are **Off mode**. The chart runs the recommender only (`updater` + `admissionController` disabled), so there is no mutating webhook and pods are never mutated — manifests stay authoritative and the recommendations are pure sizing evidence (cmdshift/platform#62). The HelmRelease sets `install.crds: Create` / `upgrade.crds: CreateReplace` because the chart ships its CRDs in the `crds/` dir (install-only, never in the release secret — the 1MB cap is a non-issue).

- **The recommender floors are lowered** to `pod-recommendation-min-cpu-millicores: "2"` / `pod-recommendation-min-memory-mb: "10"`: the defaults clamp every pod recommendation UP to 15m CPU / 100Mi — far above this cluster's 10-50m CPU / 32-96Mi workloads, so small pods would get dishonest numbers.
- **Never run `helm test` on the vpa release** — the chart renders three `helm test` Pods (hook-annotated, so they exist only if someone runs `helm test`) with no resources and no values knob; kyverno would deny them.

## goldilocks: automatic VPA maintenance

The controller creates and maintains an Off-mode VPA for every workload outside the system namespaces (`controller.flags`: `on-by-default: "true"` + `exclude-namespaces: "kube-system,flux-system"` — 48 VPAs on first pass). Read the recommendations with `vpa_recs` (the evidence side of sizing; `request_audit`/`memory_audit` are the usage side — [tools/bin/README.md](../../../tools/bin/README.md)). **A recommendation is a P99-shaped candidate request, not a drop-in** — cross-check against the usage audits and the sizing convention before editing manifests: the resource-sizing skill / [runbooks/local/memory-sizing-audit.md](../../../runbooks/local/memory-sizing-audit.md).

- **Chart `flags` maps are schema-less** — unknown keys are silently dropped. goldilocks' old `--vpa-object-mode` flag was removed upstream while the values key would have kept flowing; verify flag names against the image before wiring: `docker run --rm --entrypoint /goldilocks us-docker.pkg.dev/fairwinds-ops/oss/goldilocks:<tag> controller --help`.
- **The image home is us-docker.pkg.dev** (the `gar` entry in the caching proxy's upstream map) — images moved there at v4.15+; `quay.io/fairwinds/goldilocks` is stale (tops at v4.6.0).
- The dashboard is **server-rendered HTML** — namespace list at `/namespaces`, per-namespace pages at `/dashboard/<ns>`; there is no JSON API. Exposure is ad-hoc: `kubectl -n kube-system port-forward svc/goldilocks-dashboard 8080:80`.

Cloud: the manifests port as-is, including the lowered recommendation floors — [manifests/cloud/notes.md](../../cloud/notes.md).
