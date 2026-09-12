---
name: add-workload
description: Checklist for deploying any new workload to the cluster — kyverno Deny-mode admission requirements, sizing, security context, helm hook jobs, CiliumNetworkPolicy patterns, secrets-server wiring, file placement, and PolicyException policy. Use before adding any pod/job/deployment.
---

# Adding a workload

All kyverno ValidatingPolicies run in **Deny** mode — non-compliant pods/jobs are rejected at admission. Everything below is enforced, not advisory.

## 1. Sizing

All containers + initContainers need cpu/memory **requests and limits**. Lean requests, generous CPU limits, memory = evidence not vibes → load the `resource-sizing` skill if unsure (its audits: `memory_audit` / `cpu_audit` / `request_audit` / `vpa_recs`). Part of the evidence is automatic: goldilocks maintains Off-mode VPAs for every non-system workload, so recommendations already exist — no per-workload step.

## 2. Security context

- pinned image tag — **never** `:latest` or floating (`main`)
- `runAsNonRoot: true` (pod or container level)
- `seccompProfile: RuntimeDefault`
- capabilities dropped `ALL`

## 2b. Graceful shutdown

- `terminationGracePeriodSeconds >= 5` is **enforced** by `require-graceful-termination` (Deny mode; unset passes — the 30s default). Set it deliberately for anything serving traffic: ≈ max in-flight request duration + shutdown overhead, not the default.
- `preStop` hooks are a **convention, not policy** — kyverno can validate presence only, not effectiveness; a presence-only Deny rule invites cargo-cult hooks. Add a `preStop: sleep <grace-readiness-lag>` hook when the app has no in-pod graceful-drain of its own (or rely on the app's own SIGTERM handling when it has one).
- System agents that deliberately terminate in 1s (cilium, cilium-envoy, hubble-relay, tetragon) are PolicyExcepted — don't copy their values.

## 3. Helm hook jobs

Admission-checked too — render and size them before the first install:

```
helm template <chart> | yq 'select(.kind == "Job")'
```

Known-proofed: cert-manager `startupapicheck.resources` (all-lowercase key!), velero `upgradeJobResources`, kube-prometheus-stack `prometheusOperator.admissionWebhooks.patch.resources`. The no-knob case: emqx-operator's pre-upgrade Job renders zero resources with no values knob — fixed with HelmRelease postRenderers SMP on its `cleanup` container (cmdshift/platform#64).

**Operator-GENERATED pods are admission-checked as well** (trivy-operator scan jobs are the live example): an operator that spawns jobs/pods with no resources, no securityContext, or a root-declaring image gets them denied at admission — and the failure is often *silent* (scans just never run). Prefer chart values that shape generated pods (`trivyOperator.scanJobPodTemplatePodSecurityContext` etc.); note `runAsUser` must be set explicitly when the image declares `USER root` **or ships no USER directive at all** (every NATS-stack image) — `runAsNonRoot` alone fails the kubelet image-USER check. Reserve PolicyExceptions for what values can't express (tetragon agent).

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

Controllers generating non-compliant pods with no config knobs get a **PolicyException** in `policies-config/` — scoped by namespace + name prefix, with a rationale comment (AGENTS.md comment rules). Don't reach for exceptions for workloads you control — fix the workload.

## 8. Verify

```
yaml_lint
flux_wait
```

Then: helmreleases green (`helm_wait -c <ns> <name>` per release), `policy_report` failures 0 (skips = exceptions; `--clean` for stale reports). If the workload exposes metrics: ServiceMonitor (+ trust-CRDs flag where the chart needs it), then verify scraping landed with `prometheus_query 'up{namespace="<ns>"}'`; if it logs and should ship to Loki, confirm with `loki_query '{namespace="<ns>"}'` (`-c` for a compact series list); if it should alert: rules in `monitoring-config/thanos-rules.yaml` → alerts land at http://mail.cloud.test (`mailpit`).

## Full detail

[runbooks/local/adding-a-workload.md](../../../runbooks/local/adding-a-workload.md)
