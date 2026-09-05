# Memory sizing audit

Proactive, cluster-wide. For investigating a single crashing container see [crashloop-investigation.md](crashloop-investigation.md) §3 — same tools, incident framing.

## 1. Nodes first

```
kubectl top nodes
```

Low node utilization (<50%) means nothing is on fire — the risks are per-container limits, not capacity.

## 2. Usage vs limits, cluster-wide

```
kubectl top pods -A --containers --no-headers | awk '{print $1"/"$2"/"$3, $5}' | sort > /tmp/usage.txt
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p | .spec.containers[]? | select(.resources.limits.memory != null) | "\($ns)/\($p)/\(.name) \(.resources.limits.memory | sub("Mi$";""))"' > /tmp/limits.txt
join <(sort /tmp/limits.txt) <(sort /tmp/usage.txt) | awk '{u=$3; l=$2; gsub(/Mi$/,"",u); if (l ~ /Gi$/) {gsub(/Gi$/,"",l); l*=1024} else gsub(/Mi$/,"",l); r=u/l; if (r>=0.5) printf "%-72s %6.0fMi / %6.0fMi %3.0f%%\n", $1, u, l, r*100}' | sort -k4 -rn
```

Mind the Mi/Gi normalization — `1Gi` silently parses as `1` in naive scripts (this cost an hour once).

## 3. Containers without limits

```
kubectl get pods -A -o json | jq -r '[.items[] | .spec.containers[]? | select((.resources.limits.memory // null) == null) | .name] | length'
```

Expected on this cluster: **9** — eight control-plane statics (apiserver, scheduler, controller-manager, kube-proxy ×5) plus the thanos-ruler config-reloader (PolicyException'd, ~18Mi). Anything else is a finding.

## 4. Trend, not snapshot

```
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
curl -sG --data-urlencode 'query=container_memory_working_set_bytes{namespace="<ns>",container="<name>"}' \
  --data-urlencode "start=$(date -v-6H +%s)" --data-urlencode "end=$(date +%s)" --data-urlencode "step=1800" \
  http://localhost:9090/api/v1/query_range | jq -r '.data.result[0].values[] | "\(.[0]) \(.[1] | tonumber / 1048576 | floor)Mi"'
```

A fresh cluster's first ~3h is always a ramp (head chunks, WAL, warmup) — judge trends after that. Anything >60% of limit and climbing is a candidate.

## 5. For prometheus itself: cardinality, not just memory

```
prometheus_tsdb_head_series                       # absolute + trend
topk(10, count by (job)({__name__=~".+"}))        # which job owns the series
```

Reference finding (platform#20): the apiserver job alone was 52k of 111k head series on this CRD-heavy cluster. If memory tracks series growth, the fix is `MetricRelabelings` (e.g. pruning `apiserver_request_duration_seconds` buckets), not another memory bump.

## 6. Decide and record

- size per the convention in AGENTS.md (request ≈ P99 × 1.2, limit = 1.5 × request); deliberate deviations get a rationale comment in the manifest (velero runs 2× for kopia spikes)
- flux delivery controllers (source/helm/kustomize) have their own floor — see the sizing section in AGENTS.md; starving them wedges the whole pipeline
- trend-driven cases: open a tracking issue with the data (platform#20 is the template) — the `ContainerOOMKilled` alert guards the ceiling meanwhile (read alerts at http://mail.cloud.test)
