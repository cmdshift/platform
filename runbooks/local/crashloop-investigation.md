# CrashLoopBackOff investigation

## 1. What killed the container?

`pod_status [-n ns]` (tools/bin) gives the triage table up front — phase, restarts, and the last exit code/reason per container. Then:

```
kubectl -n <ns> describe pod <pod> | grep -A3 "Last State"
```

- **OOMKilled / exit 137** — memory limit. Go to §3
- **Error / exit 1** — read the previous container's logs:
  ```
  kubectl -n <ns> logs <pod> --previous --tail=50
  ```
- **container never starts** — check events for `admission webhook ... denied the request: Policy <name> failed` (§2)

A silent exit with nothing in the logs is almost always an OOMKill — the process gets SIGKILLed before it can log anything.

## 2. Kyverno or workload?

If admission denied the pod: its template violates a policy (missing requests/limits, `runAsNonRoot`, seccomp, capabilities, `:latest`). Fix the workload if it's ours. If a controller/operator generates non-compliant pods and offers no config knobs (e.g. the thanos-operator's config-reloader sidecar in its day), add a **scoped PolicyException** — `policies-config/*.policy-exception.yaml`, namespace + name-prefix matching, with the rationale recorded in the group README (comment rules: the `writing-yaml` skill, Comments section); a LimitRange can be the better fix for resource-less exempt containers (cmdshift/platform#111).

## 3. Memory: limit too low, or a leak?

Usage vs limits across the cluster (Mi/Gi handled — `1Gi` silently parses as `1` in naive scripts):

```
memory_audit 50
```

Snapshot proves nothing — judge the trend. **And for an OOMKill specifically, a below-limit snapshot does not clear the limit either**: transient bursts kill between snapshots (seaweed volume server died at a 240Mi limit while `kubectl top` showed 183Mi) — pull the range query and judge headroom against the burst peak, not the last observed value ([memory-sizing-audit.md](memory-sizing-audit.md) §4; seaweed burst traps: [../../manifests/bases/objects/README.md](../../manifests/bases/objects/README.md)).

```
prometheus_query 'max_over_time(k8s_pod_memory_working_set{k8s_namespace_name="<ns>"}[6h])'   # O2 shape: kubeletstats family, NOT container_memory_working_set_bytes (tools/bin/README.md → prometheus_query)
```

For prometheus specifically, also check series count and cardinality by job (`prometheus_tsdb_head_series`, `topk(10, count by (job)({__name__=~".+"}))` via `prometheus_query`) — memory growth usually tracks series growth.

The `ContainerOOMKilled` alert (O2 → SMTP → mailpit) catches ceiling hits that go unnoticed in logs. **Alerts are readable at http://mail.cloud.test (`mailpit`).**

## 4. Fix and verify

Size per the convention (AGENTS.md → Do list: request ≈ P99 × 1.2, limit = 1.5 × request); deliberate deviations (velero: request ≈ P99×1.2 covering the observed kopia burst, with the 512Mi limit holding the spike-absorption role, cmdshift/platform#219) record their rationale in the group README's sizing decision (comment rules: the `writing-yaml` skill, Comments section, cmdshift/platform#43). Bump, reconcile from the root, then confirm stability across **at least one full failure cycle** — velero's cycle was ~14 min, so a few minutes of uptime proved nothing. For trend-driven cases (prometheus), watch the next day's trend rather than the immediate snapshot.

## Worked example

velero, 2026-09-05: CrashLoopBackOff, 20 restarts, OOMKilled exit 137, logs end silently right after `Start to prepare repo` (kopia repo preparation). Limit was 132Mi — too small for repo prep. The 3am fs-backup failed as collateral (server kept dying mid-run). Fix: 88Mi/132Mi → 256Mi/512Mi, verified by `Prepare repo complete` in startup logs plus zero restarts past one full crash cycle.

---

*Agent entry point: the `crashloop-investigation` skill in `.agents/skills/crashloop-investigation/`.*
