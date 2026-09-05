# Memory sizing audit

Proactive, cluster-wide. For investigating a single crashing container see [crashloop-investigation.md](crashloop-investigation.md) §3 — same tools, incident framing.

## 1. Nodes first

```
kubectl top nodes
```

Low node utilization (<50%) means nothing is on fire — the risks are per-container limits, not capacity.

## 2. Usage vs limits, cluster-wide

```
memory_audit 50        # threshold pct; tools/bin, Mi/Gi normalized
```

The script normalizes Mi/Gi — `1Gi` silently parses as `1` in naive scripts (this cost an hour once).

## 3. Containers without limits

Folded into `memory_audit`'s footer. Expected on this cluster: **9** — eight control-plane statics (apiserver, scheduler, controller-manager, kube-proxy ×5) plus the thanos-ruler config-reloader (PolicyException'd, ~18Mi). Anything else is a finding.

## 4. Trend, not snapshot

```
prometheus_query -v -r 6h 'container_memory_working_set_bytes{namespace="<ns>",container="<name>"}'
```

A fresh cluster's first ~3h is always a ramp (head chunks, WAL, warmup) — judge trends after that. Anything >60% of limit and climbing is a candidate.

## 5. For prometheus itself: cardinality, not just memory

```
prometheus_query -v 'prometheus_tsdb_head_series'                          # absolute + trend
prometheus_query -v 'topk(10, count by (job)({__name__=~".+"}))'           # which job owns the series
```

Reference finding (platform#20): the apiserver job alone was 52k of 111k head series on this CRD-heavy cluster. If memory tracks series growth, the fix is `MetricRelabelings` (e.g. pruning `apiserver_request_duration_seconds` buckets), not another memory bump.

## 6. Decide and record

- size per the convention in AGENTS.md (request ≈ P99 × 1.2, limit = 1.5 × request); deliberate deviations get a rationale comment in the manifest (velero runs 2× for kopia spikes)
- flux delivery controllers (source/helm/kustomize) have their own floor — see the sizing section in AGENTS.md; starving them wedges the whole pipeline
- trend-driven cases: open a tracking issue with the data (platform#20 is the template) — the `ContainerOOMKilled` alert guards the ceiling meanwhile (read alerts at http://mail.cloud.test)
