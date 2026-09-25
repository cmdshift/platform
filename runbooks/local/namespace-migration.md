# Namespace migration (cmdshift/platform#31)

How the 2026-09-07 namespace refactor landed, the conventions it locked in, and the traps it hit — the playbook for any future move (including the cloud cluster).

## The convention

**Operators install into a namespace named after their kustomization group.** One namespace per ops domain; cluster admins own the operators; user workloads (web/workers/crons) land in `default` later. `kube-system` and `flux-system` stay put (cluster plumbing + the pipeline itself), as do cilium/metrics-server/kubelet-csr-approver inside kube-system.

| Group kustomization | Namespace | Operators |
|---|---|---|
| `certificates` | `certificates` | cert-manager |
| `secrets` | `secrets` | external-secrets + ClusterSecretStore |
| `policies` | `policies` | kyverno + all PolicyException objects |
| `storage` | `storage` | local-path-provisioner |
| `objects` | `objects` | seaweedfs-operator (+ seaweed cluster/admin) |
| `observability` | `observability` | grafana-operator, alertmanager (chart), opentelemetry-operator + otel-collector (target allocator, the sole scraper), prometheus-operator-crds (CRDs-only — SM discovery needs the CRDs), loki, alloy, mimir (plain StatefulSet), metrics-server, vpa (the last two install into kube-system but their HelmReleases live in the observability group by domain) |
| `backups` | `backups` | velero |
| `security` | `security` | tetragon, trivy-operator |

Secrets-server upload paths (`cluster/local/secrets/main.tf`) mirror the namespaces (`/www/<namespace>/<key>`) — when a namespace is born or renamed, the terraform path and the ExternalSecret's `key` move together.

## Rules that made the migration work

1. **Explicit `metadata.namespace` on every HelmRelease** — the HR's namespace *is* the release target namespace. Don't rely on kustomize `namespace:` transformers (they clobber explicit fields and are one silent move away from installing a release into the wrong ns).
2. **PolicyExceptions live in kyverno's namespace** (`features.policyExceptions.namespace`). Moving kyverno = moving all 11 exception objects.
3. **Zero-gap exception moves need manual sequencing now that policies-config prunes** (cmdshift/platform#84): a rename/move GCs the old-ns copies as soon as the new build applies — so to keep the old kyverno matched until the values flip, apply the exceptions **before** the kyverno release move, in separate reconciles, and expect the old-ns copies to disappear on the first post-flip reconcile. If a gap ever bites: PolicyExceptions are git-recoverable (revert + reconcile), and the tripwire is `policy_report` failures going non-zero within one background-scan cycle.
4. **CNP + PSS labels move with the namespace**: a new namespace is born under the cluster-wide `default-deny` CCNP — its CNP (from `networking-config/`) must land before/at the same time as the first pods, and the `pod-security.kubernetes.io/enforce: privileged` label must be on the ns manifest if the operator needs it.

## Traps hit live (2026-09-07)

### Wave-ordering deadlock (cert-manager wave)

`networking.yaml` `dependsOn: certificates` + the certificates CNP living in `networking-config` = a cycle when the namespace is born **mid-migration**: cert-manager pods crashlooped (`dial tcp 10.96.0.1:443 i/o timeout`) because the CNP that allows apiserver egress couldn't apply until `certificates` went Ready. On a fresh bootstrap this never bites (CNPs and workloads land in one wave, so default-deny never precedes the per-ns CNPs) — but mid-migration the ns is born under default-deny. Fix: temporarily drop the `certificates` dependency from `networking.yaml`, reconcile so the CNP lands, restore the dependency. Same shape will bite any group whose CNP its own dependency chain blocks.

### kyverno exception propagation is not instantaneous (velero wave)

Editing a PolicyException's CEL + reconciling updates the object, and the **admission-policy-generator** logs the update — but the admission engine kept evaluating the previous expression (storage matched, backups denied with identical CEL). Forcing another object update (the `platform.cmdshift.io/ns-refactor` annotation bump) made the engine re-pick-up. If an exception "should match but doesn't", bump the object (annotation via manifest, not a live patch) before assuming the CEL is wrong.

### kyverno cross-namespace port deadlock (policies wave)

The classic hostNetwork deadlock, cross-namespace edition: new kyverno pods pended in `policies` while the **old deployments in `kyverno`** held the host ports. `kyverno_unblock` (now `-n policies`) deletes old-generation pods — but in the cross-ns case the right kill is **deleting the old deployments themselves** (pods alone get replaced by the still-running old deployment, which re-grabs the ports). One `kubectl -n kyverno delete deploy <4 controllers>` freed everything; new pods bound within ~30s.

### helm-controller terminal state replays, doesn't retry

After the denied install exhausted `remediation.retries: 3`, every subsequent `flux reconcile helmrelease` **replayed the cached failure** ("terminal error: exceeded maximum retries: cannot remediate failed release" in helm-controller logs) — it did not re-attempt the install even though admission had already been fixed. `flux suspend` + `flux resume` clears the counters and forces a fresh install. This is why `helm_wait` exists: it surfaces the terminal message immediately instead of blind-polling.

### Old kyverno HR resisted GC (finalizer + uninstall hook)

The old kyverno HelmRelease was the only one of six moved releases that flux GC didn't remove. Deleting it by hand wedged on the `finalizers.fluxcd.io` finalizer: the old release's uninstall ran its `kyverno-scale-to-zero` hook job, which retries forever against deployments that no longer exist (they were already deleted to free the ports). Fix: clear the finalizer (`kubectl patch hr kyverno -n kyverno --type=merge -p '{"metadata":{"finalizers":null}}'`). Safe here — the uninstall's remaining work was all namespace-scoped garbage that dies with the old namespace, chart CRDs are not uninstalled by helm-controller, and the cluster-scoped webhook configs were already recreated by the new release (kyverno's webhook-integrity controller also self-heals them). The emptied resource-mutating-webhook-cfg (0 webhooks) is kyverno's own dynamic management — there are no MutatingPolicies, so nothing is lost.

### kustomize patches cannot change `metadata.namespace`

Strategic-merge patches treat `metadata.namespace` in the patch body as **selector data, not a merged field** — a SM patch silently leaves the resource in its original namespace (verified against the rendered thanos bundle). Every namespace relocation must be a JSON6902 `replace /metadata/namespace` patch (the thanos-operator bundle used per-resource JSON6902 patches; its two ClusterRoleBindings also needed `subjects[0].namespace` moved or the operator lost RBAC — kept as precedent, the operator is gone since cmdshift/platform#128).

### Stale-inventory health-check loop (thanos-operator wave)

When a kustomization moves *all* its resources to another namespace in one apply with `wait: true`, the health check can race the inventory update: it waits on the old namespace's objects (already GC'd) → `NotFound` → timeout → reconcile fails → inventory never refreshes → every 5s retry re-waits on deleted objects forever. Break the loop with `wait: false` for one reconcile (let inventory + Ready reset), then restore `wait: true`. Watch for the secondary trap: a duplicate YAML key left by the edit fails the *parent* kustomization's build (`mapping key "wait" already defined`).

### Dry-run admission checks are only half the truth

`kubectl apply --dry-run=server` exercises the same webhooks — but pair it with the HR's real failure message before concluding anything: during the velero wave, dry-runs passed while the HR kept failing because the failures were **replays** of a terminal state, not fresh denials. `helm_wait` reads both sides (reconcile result + HR message).

## Migration wave order that worked

storage → objects → observability (thanos bundle) → certificates (+ terraform secrets-server path) → secrets (store conditions swap) → backups → policies (sub-waves: exceptions-first, then release+values, then CNP) → delete old namespaces → docs. Secrets-server paths renamed in the same wave as their ExternalSecret (single terraform apply, container recreates, ES keeps last-synced values through the gap).

### A bundle Namespace renamed onto a managed namespace gets its labels pruned (thanos-operator wave — operator since removed, cmdshift/platform#128; SSA mechanism stands)

The thanos-operator `bundle.yaml` ships `Namespace: thanos-operator-system`; cmdshift/platform#31 renamed it to the monitoring namespace (today `observability`, cmdshift/platform#120) via JSON6902. Two flux kustomizations (`namespaces` and `thanos-operator`) then apply the **same Namespace as the same SSA field manager** (`kustomize-controller`) — SSA treats an Apply from a manager as authoritative for the fields it owns, so whichever kustomization reconciles last rewrites the label map and **prunes the other's labels**. On the 2026-09-07 rebuild `thanos-operator` went last: the `pod-security.kubernetes.io/enforce: privileged` label vanished and the kps node-exporter DaemonSet was denied by PSS at pod creation (`violates PodSecurity "baseline:latest"` — kubelet admission, invisible to kyverno and to `policy_report`), failing the kps install into uninstall-remediation/Stalled.

Fix (in `observability/thanos-operator.kustomization.yaml`): a strategic-merge patch puts the same PSS labels on the bundle's Namespace so both appliers declare the identical load-bearing set — order no longer matters. General rule: **when a kustomization renames a bundle Namespace onto one the `namespaces` group owns, mirror the namespace's load-bearing labels into that kustomization's patch** (or pick a different bundle namespace entirely).

Triage fingerprint: kps install timeout on node-exporter + `FailedCreate` events citing PSS + `kubectl get ns <ns> --show-managed-fields -o json` showing a single `kustomize-controller` Apply entry whose label set is missing the PSS keys.

## Traps from the observability collapse (cmdshift/platform#120)

### Implicit kustomization generation for dirs without a `kustomization.yaml`

Kustomize-controller **auto-generates an implicit kustomization listing all YAMLs** for a build path with no `kustomization.yaml` — historically the `crds/` dir was built this way on purpose (verified via `flux build kustomization crds --path manifests/local/crds` + the live cluster's crds inventory: it applied the nested Kustomization CRs and the HelmRelease); the multi-cluster restructure gave every dir an explicit `kustomization.yaml`, so the flux-only implicit behavior no longer applies to any current dir. Consequence when a dir *does* lack an explicit kustomization: a local dry-run with the standalone `kustomize` CLI (or `kubectl kustomize`) on it **fails**, while flux builds it fine — don't conclude the build is broken from a CLI failure. Triage: `flux build kustomization <name> --path <dir>` (validates with the same engine flux uses), or `kubectl -n flux-system describe kustomization <name>` for the live build state. (Sibling of the cmdshift/platform#93 trap in the opposite direction: `kubectl kustomize` on dirs WITH an explicit kustomization silently skips unlisted files — either way, flux is ground truth.)

### Merged ResourceQuotas need a rename, not a stack

When two namespaces' quotas fold into one (namespace collapse), the two `ResourceQuota/compute` objects can't both keep the name `compute` in the merged namespace: two quotas named `compute` would **both charge every pod** (quota admission charges against every matching quota), and kustomize would refuse the duplicate resource id anyway. Rename one on merge — the former `logging` quota became `logging-compute` in `observability-config/logging-resource-quota.yaml` (cmdshift/platform#120).
