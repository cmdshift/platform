---
name: crashloop-investigation
description: A pod is crashlooping, OOMKilled, or exiting silently. Identify the killer (OOM vs error vs admission denial), distinguish memory-limit vs leak with audits and prometheus trends, fix per the sizing convention, and verify across a full failure cycle. Use for any CrashLoopBackOff.
---

# CrashLoopBackOff investigation

## 1. What killed the container?

Start with `pod_status [-n ns]` — phase, restarts, and last exit code/reason per container.

- **OOMKilled / exit 137** — memory limit. Go to §3
- **Error / exit 1** — read the previous container's logs: `kubectl -n <ns> logs <pod> --previous --tail=50`
- **container never starts** — check events for `admission webhook ... denied the request: Policy <name> failed` (§2)

A silent exit with nothing in the logs is almost always an OOMKill — the process is SIGKILLed before it can log anything.

## 2. Kyverno or workload?

If admission denied the pod, its template violates a policy (requests/limits, `runAsNonRoot`, seccomp, capabilities, `:latest`). Fix the workload if it's ours. If a controller/operator generates non-compliant pods with no config knobs (e.g. the thanos-operator's config-reloader sidecar), add a **scoped PolicyException** in `policies-config/*.policy-exception.yaml` — namespace + name-prefix matching, with a rationale comment.

## 3. Memory: limit too low, or a leak?

```
memory_audit 50                                                  # usage vs limits, cluster-wide
prometheus_query -c -r 6h 'container_memory_working_set_bytes{namespace="<ns>",container="<name>"}'
```

Snapshot proves nothing — judge the trend. For prometheus itself, check cardinality too (`prometheus_tsdb_head_series`, `topk(10, count by (job)({__name__=~".+"}))`) — memory growth usually tracks series growth.

The `ContainerOOMKilled` alert (ruler → alertmanager) catches ceiling hits invisible in logs; alerts land at http://mail.cloud.test (`mailpit`).

## 4. Fix and verify

Size per convention (request ≈ P99 × 1.2, limit = 1.5 × request; deliberate deviations get a rationale comment — velero runs 2× for kopia repo-maintenance spikes). Bump, reconcile from the root, then confirm stability across **at least one full failure cycle** — velero's cycle was ~14 min, so a few minutes of uptime proved nothing.

## Worked example

velero, 2026-09-05: 20 restarts, OOMKilled exit 137, logs ended silently right after `Start to prepare repo` (kopia). 88Mi/132Mi → 256Mi/512Mi, verified by `Prepare repo complete` plus zero restarts past one full cycle.

## Full detail

[runbooks/local/crashloop-investigation.md](../../../runbooks/local/crashloop-investigation.md)
