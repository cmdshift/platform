# Adding a workload

The checklist for deploying anything new to this cluster. All kyverno ValidatingPolicies run in **Deny** mode — everything below is enforced at admission, not advisory.

## 1. Sizing (kyverno-checked, convention-checked)

All containers + initContainers need cpu/memory requests and limits. Size per the convention in AGENTS.md: lean requests, generous CPU limits for bursts, memory = evidence not vibes. If unsure of usage, size conservatively and revisit with the audit in [crashloop-investigation.md](crashloop-investigation.md).

## 2. Security context (kyverno-checked)

- pinned image tag — **never** `:latest` or floating (`main`)
- `runAsNonRoot: true` (pod or container level)
- `seccompProfile: RuntimeDefault`
- capabilities dropped `ALL`

## 3. Helm hook jobs (if using a chart)

Render and size them — they're admission-checked too:

```
helm template <chart> | yq 'select(.kind == "Job")'
```

Known-proofed: cert-manager `startupapicheck.resources` (all-lowercase key!), velero `upgradeJobResources`, kube-prometheus-stack `prometheusOperator.admissionWebhooks.patch.resources`. Full admission-policy context: AGENTS.md.

## 4. Network policy

The cluster runs default-deny egress (except kube-system); every workload needs a CiliumNetworkPolicy in `networking-config/`. House patterns (copy the closest match):

- `kube-apiserver` egress (almost everything)
- intra-namespace for peer traffic
- specific service: `toEndpoints` + `matchLabels: io.kubernetes.pod.namespace: <ns>` + port
- external companions: `toFQDNs: matchName: <host>.cloud.test` + port (e.g. the velero CNP's `s3.cloud.test:80` rule, external-secrets' `secrets.cloud.test:80`)

## 5. Secrets (if needed)

Credentials come from the secrets server: add the payload to `cluster/local/secrets/locals.tf` + an `upload` block in `main.tf`, then an ExternalSecret referencing `ClusterSecretStore/main` (see `backups-config/velero-s3-credentials.external-secret.yaml` for the shape). The ClusterSecretStore's `conditions` list must include your namespace.

## 6. Wiring

- **namespace**: plain manifest in `namespaces/` (prune is deliberately false there)
- **helm release**: in the relevant `<thing>/` dir; **CRs/config** in the matching `<thing>-config/` dir (grafana/thanos/alertmanager CRs go in `monitoring-config/`, not helm values)
- **custom resources**: if operator-managed, add `healthCheckExprs` to the owning kustomization (copy from the CEL cheatsheet — see the flux landmine in AGENTS.md)

## 7. When admission rejects something you can't fix

Controllers that generate non-compliant pods with no config knobs (e.g. the thanos-operator's config-reloader sidecar) get a **PolicyException** in `policies-config/`: scoped by namespace + name prefix, with a rationale comment. Don't reach for exceptions for workloads you control — fix the workload.

## 8. Verify

```
yaml_lint                                       # parse-check
flux_wait                                       # reconcile from the root + poll
```

Then the final checks: kustomizations + helmreleases green, then `policy_report` → failures 0, no stale reports. If the workload exposes metrics: ServiceMonitor (+ `service-monitor` feature where applicable); if it should alert: rules in `monitoring-config/thanos-rules.yaml` (delivered to http://mail.cloud.test).

---

*Agent entry point: the `add-workload` skill in `.agents/skills/add-workload/`.*
