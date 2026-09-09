# datastores

Datastore operators — **operators only, nothing instantiated yet**; `datastores-config` with `healthCheckExprs` gets created when the first CR lands. All four images run through the caching registry. Adoption decision tree and traps: [runbooks/local/adopting-a-chart.md](../../runbooks/local/adopting-a-chart.md).

## The four operators

| Operator | Channel | Notes |
|---|---|---|
| cloudnative-pg 0.29.0 (app 1.30.0) | Helm chart, `cloudnative-pg` HelmRepository | Rendered 1.27MB with CRDs > the 1MB release-secret cap → `crds.create: false`; the 11 CRDs install via the **`cnpg-crds` child kustomization** (crds group) built from upstream `config/crd` at the tag pinned in `cloudnative-pg-crds.git-repository.yaml` — no vendored file, no regen burden; bump that tag in lockstep with the chart's appVersion. Webhook certs self-rotated by the operator (no cert-manager need). Provisional resources — audit after burn-in |
| rabbitmq cluster-operator v2.22.5 | **Vendored render** of upstream `config/default` | No official chart; overlays use `../` refs flux can't build. Versioned images are **ghcr-only, no `v` prefix** (`2.22.5`) — docker hub's `rabbitmqoperator` repos lag at 2.19.x; the `:latest` the overlays ship is admission-denied. Namespace transformer + explicit patches: drop mto's stray Namespace, rewrite 4 `inject-ca-from` annotations + 3 Certificate `dnsNames` (they bake `rabbitmq-system` at render). Bitnami OCI charts checked and rejected: `rabbitmq-cluster-operator` tops out at chart 4.4.34 → operator 2.16.1 (frozen catalog since Broadcom's Secure-Images split), `messaging-topology-operator` absent entirely — vendored renders track upstream exactly |
| messaging-topology-operator v1.20.2 | Same vendored-render pattern | 13 CRDs in the vendored file; requires cert-manager; `--metrics-cert-path` secret wiring works as-rendered once the dnsNames are patched |
| valkey-operator 0.6.0 | Helm chart, `valkey` HelmRepository | Cleanest chart adopted so far: CRDs in `crds/`, admission-clean by default, house-convention resources. Only values: `metrics.serviceMonitor.enabled` — nests under `metrics.` (a top-level `serviceMonitor:` is silently ignored; caught by the missing SM after a green install) |

## Group wiring

`datastores.yaml` dependsOn `namespaces, sources, crds` (the vendored CNPG CRDs live there), `certificates` (rabbitmq webhook certs), `networking`. The rabbitmq vendored files include their CRDs under the group's `prune: true` — deleting the file deletes the CRDs + every CR of those kinds (repo-owned files, deliberate removal only). CNP in `networking-config/datastores.cilium-network-policy.yaml` (egress kube-apiserver + intra-ns).

## KubeBlocks — aborted, not adopted (cmdshift/platform#49)

Adopted as the "KubeBlocks Redis" line of the issue, then rejected: a multi-engine operator (2 Deployments, 28 CRDs, 9 inert Addon CRs, a dataprotection controller) is the opposite of single-purpose. Replaced by valkey-operator. Abort mechanics worth knowing for any future rejection (full story in the adopting-a-chart runbook): the chart `lookup`s its Addon CRD at render time and ships no CRDs anywhere (helm-controller renders without API discovery → install fails until CRDs exist); the `tools` initContainer hardcodes no securityContext (postRenderers SMP, verify locally — a silently-unmatched patch reproduces the identical admission denial); cleanup is manual (partial-apply leftovers + the CRDs — the crds group is prune:false; helm never removes CRDs); deleting the release's storage secrets mid-recovery wedges remediation (`missing target release for rollback` — the `helmrelease-stuck` skill).
