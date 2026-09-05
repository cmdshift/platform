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

Usage vs limits across the cluster (mind Mi/Gi normalization — `1Gi` silently parses as `1`):

```
kubectl top pods -A --containers --no-headers | awk '{print $1"/"$2"/"$3, $5}' | sort > /tmp/usage.txt
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p | .spec.containers[]? | select(.resources.limits.memory != null) | "\($ns)/\($p)/\(.name) \(.resources.limits.memory | sub("Mi$";""))"' > /tmp/limits.txt
join <(sort /tmp/limits.txt) <(sort /tmp/usage.txt) | awk '{u=$3; l=$2; gsub(/Mi$/,"",u); if (l ~ /Gi$/) {gsub(/Gi$/,"",l); l*=1024} else gsub(/Mi$/,"",l); r=u/l; if (r>=0.5) printf "%-72s %6.0fMi / %6.0fMi %3.0f%%\n", $1, u, l, r*100}' | sort -k4 -rn
```

Is it growing or stable? (snapshot proves nothing — query the trend):

```
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
curl -sG --data-urlencode 'query=container_memory_working_set_bytes{namespace="<ns>",container="<name>"}' \
  --data-urlencode "start=$(date -v-6H +%s)" --data-urlencode "end=$(date +%s)" --data-urlencode "step=1800" \
  http://localhost:9090/api/v1/query_range | jq -r '.data.result[0].values[] | "\(.[0]) \(.[1] | tonumber / 1048576 | floor)Mi"'
```

For prometheus specifically, also check series count and cardinality by job (`prometheus_tsdb_head_series`, `topk(10, count by (job)({__name__=~".+"}))`) — memory growth usually tracks series growth.

The `ContainerOOMKilled` alert (ruler → alertmanager → mailpit) catches ceiling hits that go unnoticed in logs. **Alerts are readable at http://mail.cloud.test.**

## 4. Fix and verify

Size per the convention in AGENTS.md (request ≈ P99 × 1.2, limit = 1.5 × request); deliberate deviations (velero runs 2× for kopia repo-maintenance spikes) get a rationale comment in the manifest. Bump, reconcile from the root, then confirm stability across **at least one full failure cycle** — velero's cycle was ~14 min, so a few minutes of uptime proved nothing. For trend-driven cases (prometheus), watch the next day's trend rather than the immediate snapshot.

## Worked example

velero, 2026-09-05: CrashLoopBackOff, 20 restarts, OOMKilled exit 137, logs end silently right after `Start to prepare repo` (kopia repo preparation). Limit was 132Mi — too small for repo prep. The 3am fs-backup failed as collateral (server kept dying mid-run). Fix: 88Mi/132Mi → 256Mi/512Mi, verified by `Prepare repo complete` in startup logs plus zero restarts past one full crash cycle.
