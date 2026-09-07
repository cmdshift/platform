---
name: resource-sizing
description: Setting or auditing container resources. The sizing convention (lean requests, generous CPU limits, memory request ≈ P99×1.2 / limit 1.5×), the three audit tools (memory_audit, cpu_audit, request_audit), and trend-vs-snapshot interpretation. Use whenever sizing, bumping, or auditing resources.
---

# Resource sizing

## The convention

- **Requests lean** (10-50m CPU) — they're the scheduling side, not a performance knob.
- **CPU limits generous for bursts** (200m-2000m) — throttling is the silent killer. For a single suspect: `prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'`.
- **Memory: request ≈ P99 × 1.2, limit = 1.5 × request.** Deliberate deviations get a rationale comment — velero runs 2× because kopia repo-maintenance spikes OOM-killed it at 1.5×.
- **Flux delivery controllers** (source/helm) have their own floor — 1000m CPU / 512Mi-1Gi — or they wedge the whole pipeline.
- Evidence-based, not defaults: size from audits, not vibes.

## The three audits — pick by question

| Tool | Question |
|---|---|
| `memory_audit [pct]` | is anything near its **limit**? (usage-vs-limits; footer counts limit-less containers — expected 9) |
| `cpu_audit [pct]` | same for CPU + the silent-killer check: top-10 by % of CFS periods throttled (>5% worth a look) |
| `request_audit [pct]` | are **requests** honest for scheduling? (≥100% of memory request = first evicted under node pressure) |

## Interpretation

- **Trend, not snapshot.** A fresh cluster's first ~3h is always a ramp (head chunks, WAL, warmup) — judge after that.
- **Shapes:** a steady climb = leak or cardinality growth; a **sawtooth returning to baseline = periodic burst** (needs limit headroom over the peak, not a leak hunt).
- For prometheus's own memory: check series count first (`prometheus_query -c 'prometheus_tsdb_head_series'`, `topk(10, count by (job)({__name__=~".+"}))`) — if memory tracks series, the fix is `MetricRelabelings`, not a bump.

## Decide and record

- Rationale comment at the value in the manifest; trend-driven cases get a tracking issue with the data (cmdshift/platform#20 is the template).
- The `ContainerOOMKilled` alert guards the ceiling meanwhile — alerts at http://mail.cloud.test.

## Full detail

[runbooks/local/memory-sizing-audit.md](../../../runbooks/local/memory-sizing-audit.md)
