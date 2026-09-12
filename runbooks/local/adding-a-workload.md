# Adding a workload

The checklist for deploying anything new to this cluster. All kyverno ValidatingPolicies run in **Deny** mode — everything below is enforced at admission, not advisory.

## 1. Sizing (kyverno-checked, convention-checked)

All containers + initContainers need cpu/memory requests and limits. Size per the convention in AGENTS.md: lean requests, generous CPU limits for bursts, memory = evidence not vibes. If unsure of usage, size conservatively and revisit with the audits (`memory_audit` / `cpu_audit` / `request_audit` — procedure in [memory-sizing-audit.md](memory-sizing-audit.md)).

## 2. Security context (kyverno-checked)

- pinned image tag — **never** `:latest` or floating (`main`)
- `runAsNonRoot: true` (pod or container level)
- `seccompProfile: RuntimeDefault`
- capabilities dropped `ALL`

## 2b. Graceful shutdown (tgps kyverno-checked; preStop convention)

`require-graceful-termination` (Deny mode) rejects pods whose `terminationGracePeriodSeconds` is set below 5 — unset passes (the kubelet's 30s default counts as compliant). Worked example of the rejection: `kubectl run x --overrides '{"spec":{"terminationGracePeriodSeconds":0,...}}'` → `Policy require-graceful-termination failed`.

Conventions:

- For anything serving traffic, **set tgps deliberately**: ≈ max in-flight request duration + shutdown overhead. Don't drift on the 30s default for apps that need longer (alertmanager uses 120s, prometheus 600s — evidence-shaped values).
- **`preStop` hooks are convention, not policy.** Kyverno can validate presence only, never hook *effectiveness* — a presence-only Deny rule invites hooks that exist but do nothing. Add `preStop: sleep <grace-readiness-lag>` only when the app has no in-pod graceful drain of its own; when it handles SIGTERM properly, no hook is the better shape.
- The 1s-terminating system agents (cilium, cilium-envoy, hubble-relay, tetragon) are PolicyExcepted in `policies-config/` — deliberate, don't copy their values.

## 3. Helm hook jobs (if using a chart)

Render and size them — they're admission-checked too:

```
helm template <chart> | yq 'select(.kind == "Job")'
```

Known-proofed: cert-manager `startupapicheck.resources` (all-lowercase key!), velero `upgradeJobResources`, kube-prometheus-stack `prometheusOperator.admissionWebhooks.patch.resources`. The no-knob case: emqx-operator's pre-upgrade Job renders zero resources with no values knob — fixed with HelmRelease postRenderers SMP on its `cleanup` container (cmdshift/platform#64). Full admission-policy context: AGENTS.md.

## 4. Network policy

The cluster runs default-deny egress (except kube-system); every workload needs a CiliumNetworkPolicy in `networking-config/`. House patterns (copy the closest match):

- `kube-apiserver` egress (almost everything)
- intra-namespace for peer traffic
- specific service: `toEndpoints` + `matchLabels: io.kubernetes.pod.namespace: <ns>` + port
- external companions: `toFQDNs: matchName: <host>.cloud.test` + port (e.g. the backups CNP's `s3.cloud.test:80` rule, secrets' `secrets.cloud.test:80`)

## 5. Secrets (if needed)

Credentials come from the secrets server: add the payload to `cluster/local/secrets/locals.tf` + an `upload` block in `main.tf`, then an ExternalSecret referencing `ClusterSecretStore/main` (see `backups-config/velero-s3-credentials.external-secret.yaml` for the shape). The ClusterSecretStore's `conditions` list must include your namespace.

## 6. Wiring

- **namespace**: plain manifest in `namespaces/` **and register it in `namespaces/kustomization.yaml`** — the list is explicit, so an unregistered `*.namespace.yaml` is silently not applied and everything depending on the namespace hangs on `namespaces "<name>" not found` (cost a debugging round with tetragon, 2026-09-07). Prune is deliberately false there
- **helm release**: in the relevant `<thing>/` dir; **CRs/config** in the matching `<thing>-config/` dir (grafana/thanos/alertmanager CRs go in `monitoring-config/`, not helm values)
- **custom resources**: if operator-managed, add `healthCheckExprs` to the owning kustomization (copy from the CEL cheatsheet — see the flux landmine in AGENTS.md)
- **scheduling on the ctrl node** (alloy was the first, cmdshift/platform#90): pods newly scheduled on ctrl need, beyond the usual checks — a toleration for `node-role.kubernetes.io/control-plane:NoSchedule` (nothing runs there by default); if the pod pulls images, its **namespace must be in `kubernetesTalosAPIAccess.allowedKubernetesNamespaces`** in `cluster/local/nodes/templates/ctrl.tftpl.yaml` — in container mode kubelet verifies image pulls through the Talos API on ctrl, and non-allowed namespaces fail pulls with `failed to verify image "..." with talos: rpc error: code = PermissionDenied desc = not authorized` (a machine-config change: template edit + `terraform apply`, not a manifest). Host-path reads of root-owned dirs need a capability beyond the dropped-ALL baseline — `DAC_READ_SEARCH` for the 0600-node-local audit logs — which means the workload's PolicyException gains `disallow-capabilities-strict` in its policyRefs

## 7. When admission rejects something you can't fix

Controllers that generate non-compliant pods with no config knobs (e.g. the thanos-operator's config-reloader sidecar) get a **PolicyException** in `policies-config/`: scoped by namespace + name prefix, with a rationale comment (AGENTS.md comment rules). Don't reach for exceptions for workloads you control — fix the workload.

## 8. Verify

```
yaml_lint                                       # parse-check
helm_verify                                     # values render check (HelmReleases)
cr_validate <file-or-dir>                       # server-side dry-run of new/changed CRs
flux_wait                                       # reconcile from the root + poll
```

Then the final checks: helmreleases green (`helm_wait -c <ns> <name>` per release), `policy_report` → failures 0, no stale reports. If the workload exposes metrics: ServiceMonitor (+ `service-monitor` feature where applicable), verified with `prometheus_query 'up{namespace="<ns>"}'`; if it should alert: rules in `monitoring-config/thanos-rules.yaml`, delivery confirmed with `mailpit` (http://mail.cloud.test).

---

*Agent entry point: the `add-workload` skill in `.agents/skills/add-workload/`.*
