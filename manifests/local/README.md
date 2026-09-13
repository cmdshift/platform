# manifests/local

Flux-managed manifest tree for the local Talos-in-Docker cluster. There is no `kubectl apply` — everything here is mirrored into the `flux` bucket on rustfs by the sync container and reconciled by the root `Kustomization/local` (deployed by the terraform bootstrap, adopted and owned by the `flux-config` group). Pipeline mechanics and wedge recovery: [runbooks/local/pipeline-wedged.md](../../runbooks/local/pipeline-wedged.md).

Change history and dated learnings live in [CHANGELOG.md](../../CHANGELOG.md); per-group decisions in each group's `README.md`; procedures in `runbooks/local/`; landmine dispatchers in `.agents/skills/`.

## Groups and dependency order

Each `<group>.yaml` is a flux Kustomization CR; the directory of the same name is its build path. `X` installs the operator/release, `X-config` applies that group's config objects (CRs, StorageClasses, exceptions, CNPs, rules) and gates them on real operator status via `healthCheckExprs`.

```
namespaces → sources → crds → secrets → secrets-config → certificates → certificates-config
→ networking → networking-config → flux → flux-config → metrics → policies → policies-config
→ storage → storage-config → objects → objects-config → datastores → monitoring → monitoring-config
→ backups → backups-config → logging → security → security-config
```

Groups without a README are self-explanatory: `crds/` (vendored/child-kustomization CRDs, `prune: false`), `sources/` (HelmRepository/GitRepository pins), `namespaces/` (namespace manifests — **explicit resources list in `kustomization.yaml`; an unregistered `*.namespace.yaml` is silently inert**).

Group READMEs: [networking](networking/README.md) · [metrics](metrics/README.md) · [policies](policies/README.md) · [secrets](secrets/README.md) · [certificates](certificates/README.md) · [storage](storage/README.md) · [objects](objects/README.md) · [datastores](datastores/README.md) · [monitoring](monitoring/README.md) · [backups](backups/README.md) · [logging](logging/README.md) · [security](security/README.md) · [flux](flux/README.md)

## Conventions

- **Namespace convention** — operators install into a namespace named after their kustomization group. Full mapping, migration rules, and traps: [runbooks/local/namespace-migration.md](../../runbooks/local/namespace-migration.md).
- **valuesFrom everywhere** (cmdshift/platform#31): every HelmRelease ships values via configMapGenerator → `valuesFrom` — values live in a plain `<release>-values.yaml` next to the HelmRelease, generated as `ConfigMap/<release>-values` by the dir's `kustomization.yaml` with **per-entry `disableNameSuffixHash: true`** (`valuesFrom` is not a kustomize-known name reference, so a content-hash suffix would desync the hand-written reference; helm-controller re-reconciles on CM data changes anyway). Rationale comments move with the values; only local-only landmine notes stay inline. `helm_verify` resolves `valuesFrom` refs locally and renders the exact file flux ships. Gotcha: a values-only change doesn't re-trigger helm-controller — order is `flux_wait` (rebuilds the CM) then `helm_wait` per release.
- **Registration is explicit**: every yaml in a dir must be listed in that dir's `kustomization.yaml` `resources:` (values files excepted — generator inputs). Unregistered files are silently not built and flux prunes them from the cluster. Same for the `namespaces/` list.
- **Explicit `metadata.namespace` on every HelmRelease** — the HR namespace is the release target; no kustomize `namespace:` transformers (they clobber explicit fields).
- **CR-managed workloads** (grafana, thanos ×3, alertmanager, seaweed cluster): resources and securityContext go in the CR spec (`resourceRequirements`, `securityContext`), not helm values.
- **Dependency rules**: a group naming `storageClassName: local-path` must `dependsOn: storage-config` (the SCs moved out of `storage`); CRs whose CRDs a release's operator creates live in a group that `dependsOn` that release, never the reverse; admission-critical PolicyExceptions go in the early `policies-config/` group.
- **Local-only markers**: `# remove in the cloud` and `# true in the cloud` flag deliberately local-only settings at the value; the cloud-side actions are collected in [manifests/cloud/notes.md](../cloud/notes.md).
- **Comment rules** (cmdshift/platform#43): default no comment; comments only for surprising choices, edge cases, and Talos-in-Docker deviations — full rules in the [`code-comments` skill](../../.agents/skills/code-comments/SKILL.md).

## Admission policy

All kyverno ValidatingPolicies run in **Deny** mode — see the admission-policy section of [AGENTS.md](../../AGENTS.md) for the requirements (requests/limits, pinned tags, runAsNonRoot, seccomp, caps dropped) and the checklist in [runbooks/local/adding-a-workload.md](../../runbooks/local/adding-a-workload.md). PolicyExceptions live in `policies-config/` (with kyverno, per the namespace convention) and cover deliberate Talos-in-Docker settings — don't try to "fix" those workloads.

## Hardening baseline: accepted deviations

The NSA-guidance hardening settings stay in the manifests; every deviation below is deliberate, maps to a kyverno PolicyException or an upstream/CRD limitation, and is the baseline the hardening tools (tetragon: runtime, trivy-operator: static, kube-bench: episodic CIS) audit against — keep it current when adding workloads:

- **thanos CR-managed pods (query/compact/store/ruler)** — the `monitoring.thanos.io` CRDs expose no `automountServiceAccountToken` and no per-container securityContext, so SA-token automount and roFS stay open. Disabling automount via SA manifests was tried and **the operator recreates the SAs on every reconcile** — don't fight it. Pod-level runAsNonRoot + seccomp ARE set (the only knobs the CRD exposes).
- **thanos-ruler config-reloader** — operator-injected, no resource/securityContext knobs (PolicyException, ~18Mi).
- **seaweed `main-master`** — no roFS: the CR has no persistence knob for master and it writes wal/segment files to `/data` on the container root fs. filer/volume/s3 got roFS; filer and s3 keep a writable `/tmp` emptyDir (filer's gRPC socket, s3 temp files).
- **velero deployment** — the chart only exposes pod-level `securityContext` and renders it into its CRD-upgrade hook jobs too, where `allowPrivilegeEscalation` is not a legal pod field (SSA rejects it, helm upgrade fails). Pod-level `runAsUser: 0` is deliberate (node-agent needs root); only the aws-plugin initContainer is container-hardened.
- **loki / alloy keep their SA tokens** — loki's rules sidecar watches ConfigMaps via the API, alloy's `discovery.kubernetes` uses in-cluster config. Alloy also runs as root (image declares no USER — covered by its PolicyException for the host-log mounts).
- **kubernetes/Talos defaults** — the `system:*` discovery/basic-user ClusterRoleBindings, `cluster-admin → system:masters`, and Talos-rendered statics are stock bootstrap, not manifest-owned.
- **ConfigMap regex false positives** — findings on config keys (cilium-config, kyverno/logging CMs) are verified non-credentials.
- **metrics-server** — the fix-first success: container-level `securityContext` with `runAsGroup: 1000` cleared the finding, no exception needed.

Learnings that generalize: explicit container-level `runAsGroup` is the common gap (charts set pod-level non-root or uid-only, leaving gid implicit 0 — set uid/gid explicitly wherever the chart allows); **the flux2 chart securityContext REPLACES, not merges** (templates hardcode container-sc defaults behind an if/else — spell out the full map or you silently drop APE/caps/roFS); the thanos ruler non-root retrofit needed numeric `runAsUser: 65534` (the config-reloader image declares `USER "nobody"`, which kubelet can't verify against a bare `runAsNonRoot`) plus a one-time PVC `chown` (helper-pod pattern).

## Out-of-cluster companions

rustfs S3, secrets server, haproxy, mailpit, sync container, caching registry — terraform/docker in `cluster/local/`, none exist in the cloud, so CNP `toFQDNs` rules, the Bucket endpoint, the ClusterSecretStore URL, alertmanager's smarthost, and the BSL `s3Url` all resolve differently there. Topology and landmines: [runbooks/local/cluster-rebuild.md](../../runbooks/local/cluster-rebuild.md).
