---
name: add-workload
description: Checklist for deploying any new workload to the cluster — kyverno Deny-mode admission requirements, sizing, security context, helm hook jobs, CiliumNetworkPolicy patterns, secrets-server wiring, file placement, and PolicyException policy. Use before adding any pod/job/deployment.
---

# Adding a workload

All kyverno ValidatingPolicies run in **Deny** mode — non-compliant pods/jobs are rejected at admission. Everything below is enforced, not advisory.

## 1. Sizing

All containers + initContainers need cpu/memory **requests and limits**. Lean requests, generous CPU limits, memory = evidence not vibes → load the `resource-sizing` skill if unsure.

## 2. Security context

- pinned image tag — **never** `:latest` or floating (`main`)
- `runAsNonRoot: true` (pod or container level)
- `seccompProfile: RuntimeDefault`
- capabilities dropped `ALL`

## 3. Helm hook jobs

Admission-checked too — render and size them before the first install:

```
helm template <chart> | yq 'select(.kind == "Job")'
```

Known-proofed: cert-manager `startupapicheck.resources` (all-lowercase key!), velero `upgradeJobResources`, kube-prometheus-stack `prometheusOperator.admissionWebhooks.patch.resources`.

## 4. Network policy

The cluster runs default-deny egress (except kube-system) — every workload needs a CiliumNetworkPolicy in `networking-config/`. Copy the closest house pattern:

- `kube-apiserver` egress (almost everything needs it)
- intra-namespace for peer traffic
- specific service: `toEndpoints` + `matchLabels: io.kubernetes.pod.namespace: <ns>` + port
- external companions: `toFQDNs: matchName: <host>.cloud.test` + port (e.g. velero's `s3.cloud.test`, external-secrets' `secrets.cloud.test`)

## 5. Secrets

Credentials come from the secrets server: payload in `cluster/local/secrets/locals.tf` + an `upload` block in `main.tf`, then an ExternalSecret referencing `ClusterSecretStore/main` (shape: `backups-config/velero-s3-credentials.external-secret.yaml`). The store's `conditions` list must include your namespace.

## 6. Wiring

- **namespace**: plain manifest in `namespaces/` **and register it in `namespaces/kustomization.yaml`** (explicit resources list — an unregistered file is silently not applied and dependents hang on `namespaces "<name>" not found`); prune is deliberately false there
- **helm release**: `<thing>/`; **CRs/config**: the matching `<thing>-config/`
- **CR-managed workloads** (grafana, thanos ×3, alertmanager, seaweed): resources + securityContext go in the **CR spec** (`resourceRequirements`, `securityContext`), not helm values
- **operator-managed CRs**: add `healthCheckExprs` (CEL) to the owning kustomization — `wait: true` ignores `healthChecks`; copy expressions from https://fluxcd.io/flux/cheatsheets/cel-healthchecks/ and verify fields against the on-cluster CRD schema

## 7. When admission rejects something you can't fix

Controllers generating non-compliant pods with no config knobs get a **PolicyException** in `policies-config/` — scoped by namespace + name prefix, with a rationale comment. Don't reach for exceptions for workloads you control — fix the workload.

## 8. Verify

```
yaml_lint
flux_wait
```

Then: helmreleases green, `policy_report` failures 0 (skips = exceptions; `--clean` for stale reports). If the workload exposes metrics: ServiceMonitor (+ trust-CRDs flag where the chart needs it); if it should alert: rules in `monitoring-config/thanos-rules.yaml` → alerts land at http://mail.cloud.test.

## Full detail

[runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md)
