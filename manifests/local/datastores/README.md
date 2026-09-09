# datastores

Datastore operators — **operators only, nothing instantiated yet**; `datastores-config` with `healthCheckExprs` gets created when the first CR lands. All images run through the caching registry. Adoption decision tree and traps: [runbooks/local/adopting-a-chart.md](../../runbooks/local/adopting-a-chart.md).

## The operators

| Operator | Channel | Notes |
|---|---|---|
| cloudnative-pg 0.29.0 (app 1.30.0) | Helm chart, `cloudnative-pg` HelmRepository | Rendered 1.27MB with CRDs > the 1MB release-secret cap → `crds.create: false`; the 11 CRDs install via the **`cnpg-crds` child kustomization** (crds group) built from upstream `config/crd` at the tag pinned in `cloudnative-pg-crds.git-repository.yaml` — no vendored file, no regen burden; bump that tag in lockstep with the chart's appVersion. Webhook certs self-rotated by the operator (no cert-manager need). Provisional resources — audit after burn-in |
| valkey-operator 0.6.0 | Helm chart, `valkey` HelmRepository | Cleanest chart adopted so far: CRDs in `crds/`, admission-clean by default, house-convention resources. Only values: `metrics.serviceMonitor.enabled` — nests under `metrics.` (a top-level `serviceMonitor:` is silently ignored; caught by the missing SM after a green install) |
| nats 2.14.6 | Helm chart, `nats` HelmRepository (`nats-io/k8s`) | Queue server. Single replica, JetStream fileStore 2Gi on the default local-path SC. Every chart image ships **no USER directive** — `runAsNonRoot` needs an explicit `runAsUser` (65534; local-path PVCs are 0777 so the fileStore is writable). `natsBox` disabled: debug-only, and its bootstrap is non-idempotent across restarts at runAsNonRoot (`[ -s context ]` misses symlinks → `ln` aborts → CrashLoop). promExporter + PodMonitor on — visible to prometheus only after `podMonitorSelectorNilUsesHelmValues: false` in kube-prometheus-stack |
| nack 0.35.0 | Helm chart, same `nats` HelmRepository | JetStream controller (Stream/Consumer/KeyValue/ObjectStore CRs). CRDs ship in the chart's `crds/` dir — install-only, chart bumps don't upgrade them (same trade as valkey-operator). HelmRelease `dependsOn` nats; connects via `jetstream.nats.url: nats://nats.datastores.svc:4222` |

The rabbitmq cluster + messaging-topology operators (cmdshift/platform#49) were removed for the NATS stack (cmdshift/platform#52) — removal was clean because their vendored renders carried the CRDs under this kustomization's `prune: true` (deployments, webhooks, certs, CRDs pruned in one reconcile). Full story in the CHANGELOG.

## Group wiring

`datastores.yaml` dependsOn `namespaces, sources, crds` (the vendored CNPG CRDs live there), `networking`. CNP in `networking-config/datastores.cilium-network-policy.yaml` (egress kube-apiserver + intra-ns) — covers nats/nack; ingress isn't default-denied, so future cross-namespace queue clients connect without a CNP change.

## KubeBlocks — aborted, not adopted (cmdshift/platform#49)

Adopted as the "KubeBlocks Redis" line of the issue, then rejected: a multi-engine operator (2 Deployments, 28 CRDs, 9 inert Addon CRs, a dataprotection controller) is the opposite of single-purpose. Replaced by valkey-operator. Abort mechanics worth knowing for any future rejection (full story in the adopting-a-chart runbook): the chart `lookup`s its Addon CRD at render time and ships no CRDs anywhere (helm-controller renders without API discovery → install fails until CRDs exist); the `tools` initContainer hardcodes no securityContext (postRenderers SMP, verify locally — a silently-unmatched patch reproduces the identical admission denial); cleanup is manual (partial-apply leftovers + the CRDs — the crds group is prune:false; helm never removes CRDs); deleting the release's storage secrets mid-recovery wedges remediation (`missing target release for rollback` — the `helmrelease-stuck` skill).
