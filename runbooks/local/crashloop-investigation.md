# CrashLoopBackOff investigation

## 1. What killed the container?

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

If admission denied the pod: its template violates a policy (missing requests/limits, `runAsNonRoot`, seccomp, capabilities, `:latest`). Fix the workload if it's ours. If a controller/operator generates non-compliant pods and offers no config knobs (e.g. the thanos-operator's config-reloader sidecar), add a **scoped PolicyException** — `policies-config/*.policy-exception.yaml`, namespace + name-prefix matching, with a rationale comment.

## 3. Memory: limit too low, or a leak?

Usage vs limits across the cluster (Mi/Gi handled — `1Gi` silently parses as `1` in naive scripts):

```
memory_audit 50
```

Is it growing or stable? (snapshot proves nothing — query the trend):

```
prometheus_query -c -r 6h 'container_memory_working_set_bytes{namespace="<ns>",container="<name>"}'
```

For prometheus specifically, also check series count and cardinality by job (`prometheus_tsdb_head_series`, `topk(10, count by (job)({__name__=~".+"}))` via `prometheus_query`) — memory growth usually tracks series growth.

The `ContainerOOMKilled` alert (ruler → alertmanager → mailpit) catches ceiling hits that go unnoticed in logs. **Alerts are readable at http://mail.cloud.test.**

## 4. Fix and verify

Size per the convention in AGENTS.md (request ≈ P99 × 1.2, limit = 1.5 × request); deliberate deviations (velero runs 2× for kopia repo-maintenance spikes) get a rationale comment in the manifest. Bump, reconcile from the root, then confirm stability across **at least one full failure cycle** — velero's cycle was ~14 min, so a few minutes of uptime proved nothing. For trend-driven cases (prometheus), watch the next day's trend rather than the immediate snapshot.

## Worked example

velero, 2026-09-05: CrashLoopBackOff, 20 restarts, OOMKilled exit 137, logs end silently right after `Start to prepare repo` (kopia repo preparation). Limit was 132Mi — too small for repo prep. The 3am fs-backup failed as collateral (server kept dying mid-run). Fix: 88Mi/132Mi → 256Mi/512Mi, verified by `Prepare repo complete` in startup logs plus zero restarts past one full crash cycle.
