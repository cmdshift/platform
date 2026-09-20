---
name: resource-sizing
description: Setting or auditing container resources. The sizing convention (lean requests, generous CPU limits, memory request ≈ P99×1.2 / limit 1.5×), the audit tools (memory_audit, cpu_audit, request_audit, vpa_recs), and trend-vs-snapshot interpretation. Use whenever sizing, bumping, or auditing resources.
---

# Resource sizing

## The convention

- **Requests lean** (10-50m CPU) — they're the scheduling side, not a performance knob.
- **CPU limits generous for bursts** (200m-2000m) — throttling is the silent killer. For a single suspect: `prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'`.
- **Memory: request ≈ P99 × 1.2, limit = 1.5 × request.** Deliberate deviations get a rationale comment (`code-comments` skill rules — no dates, keep the evidence numbers) — velero runs 2× because kopia repo-maintenance spikes OOM-killed it at 1.5×.
- **Flux delivery controllers** (source/helm) have their own floor — 1000m CPU / 512Mi-1Gi — or they wedge the whole pipeline.
- Evidence-based, not defaults: size from audits, not vibes.
- **Quota interplay**: every workload namespace has a `ResourceQuota/compute` capping namespace-sum requests/limits/pods (cmdshift/platform#93) — any request/limit bump or new replica consumes quota; a bump that exceeds it wedges the rollout with `exceeded quota` (StartError/FailedCreate, not a helm error). Bumps and quota headroom move in the same change. Exception-exempt containers (PolicyException, no resources) still fail the quota — quota ignores kyverno exceptions; their only defaults source is a namespace LimitRange (cmdshift/platform#111, recipe: adding-a-workload runbook §7).

## The audits — pick by question

| Tool | Question |
|---|---|
| `memory_audit [pct]` | is anything near its **limit**? (usage-vs-limits; footer counts limit-less containers — expected 3: control-plane statics, cmdshift/platform#70) |
| `cpu_audit [pct]` | same for CPU + the silent-killer check: top-10 by % of CFS periods throttled (>5% worth a look) |
| `request_audit [pct]` | are **requests** honest for scheduling? (≥100% of memory request = first evicted under node pressure) |
| `vpa_recs [ns]` | what does **VPA** recommend for this workload? (the recommendation side — P99-shaped candidate requests from the Off-mode VPAs goldilocks maintains) |

A VPA recommendation is a **candidate request, not a drop-in** — cross-check it against the usage audits and the convention above (request ≈ P99 × 1.2, limit = 1.5 × request) before editing manifests. The VPAs are Off mode and maintained automatically by goldilocks for every non-system workload (see `manifests/local/observability/README.md`) — no per-workload step.

- **Seasoning gate**: a fresh rebuild resets recommender history, so `vpa_recs` pulled <48h after one are polluted by the early-cluster ramp (alloy came back +530% CPU that never materialized — the 7d peak stayed single-digit; most deltas collapsed to ±10% noise, cmdshift/platform#66). Pull recommendations only after the cluster has seasoned, and cross-check every delta against 7d max/P99 trend queries before editing.
- **Reject over-conservative recs at tiny sizes**: below ~20Mi the recommender's output can exceed the observed P99 (loki-gateway's 22Mi rec vs a 7d P99 of 13Mi under a 16Mi request) — the trend query wins (cmdshift/platform#66).

## Interpretation

- **Trend, not snapshot.** A fresh cluster's first ~3h is always a ramp (head chunks, WAL, warmup) — judge after that.
- **Shapes:** a steady climb = leak or cardinality growth; a **sawtooth returning to baseline = periodic burst** (needs limit headroom over the peak, not a leak hunt).
- For prometheus's own memory: check series count first (`prometheus_query -c 'prometheus_tsdb_head_series'`, `topk(10, count by (job)({__name__=~".+"}))`) — if memory tracks series, the fix is `MetricRelabelings`, not a bump.

## Decide and record

- Rationale comment at the value in the manifest (`code-comments` skill rules, cmdshift/platform#43); trend-driven cases get a tracking issue with the data (cmdshift/platform#20 is the template).
- The `ContainerOOMKilled` alert guards the ceiling meanwhile — alerts at http://mail.cloud.test.

## Full detail

[runbooks/local/memory-sizing-audit.md](../../../runbooks/local/memory-sizing-audit.md)
