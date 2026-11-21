---
name: resource-sizing
description: Setting or auditing container resources. The sizing convention (lean requests, generous CPU limits, memory request ≈ P99×1.2 / limit 1.5×), the audit tools (memory_audit, cpu_audit, request_audit, vpa_recs), and trend-vs-snapshot interpretation. Use whenever sizing, bumping, or auditing resources.
---

# Resource sizing

## The convention

- **Requests lean** (10-50m CPU) — they're the scheduling side, not a performance knob.
- **CPU limits generous for bursts** (200m-2000m) — throttling is the silent killer. For a single suspect: `prometheus_query 'container_cpu_cfs_throttled_periods_total{namespace="…",container="…"}'`.
- **Memory: request ≈ P99 × 1.2, limit = 1.5 × request.** Deliberate deviations record their rationale in the group README's sizing decision (`writing-yaml` skill Comments rules — no dates, keep the evidence numbers, `cmdshift/platform#N` ref) — velero is the shaped deviation: request ≈ P99×1.2 covering the observed 387Mi burst (448Mi, cmdshift/platform#219) while the limit STAYS 512Mi holding the spike-absorption role — kopia maintenance OOM-killed it at 1.5×, and the cmdshift/platform#20 evidence belongs to the limit, not a request multiple.
- **Flux delivery controllers** (source/helm) have their own floor — 1000m CPU / 512Mi-1Gi — or they wedge the whole pipeline.
- Evidence-based, not defaults: size from audits, not vibes. Worked example (cmdshift/platform#171, openobserve): ~830m sustained CPU wasn't a limit problem — it was bursty zstd dump/merge across all cores plus 60s compaction. The fix shrank the unit of work (thread caps 2, halved intervals: retention 30s / push 60s / compact 150s) + capped competing caches (memtable 768MB, memory-cache 512, datafusion 256, disk cache off) → ~200m avg. **Tune the workload's internal concurrency/cadence knobs before sizing the container around a burn.** Conversely, a memory limit sized below the workload's own internal cache budget (a chart default deriving % of mem_total) turns the OOM killer into the eviction policy — see the loki chunks-cache memcached precedent.
- **Hook jobs are pods too** (cmdshift/platform#149): helm hook jobs go through kyverno admission — a chart hook without resources wedges install AND uninstall (the k8s-monitoring `waitForAlloyRemoval` hooks hung an HR in `uninstalling` until their resources were set). Size install AND uninstall hooks when adopting a chart; sizing-a-chart-hook is `adopt-chart`'s §2, not a values-audit case (hooks are short-lived, so convention minimums suffice — no P99 evidence possible).
- **Quota interplay**: every workload namespace has a `ResourceQuota/compute` capping namespace-sum requests/limits/pods (cmdshift/platform#93) — any request/limit bump or new replica consumes quota; a bump that exceeds it wedges the rollout with `exceeded quota` (StartError/FailedCreate, not a helm error). Bumps and quota headroom move in the same change. Exception-exempt containers (PolicyException, no resources) still fail the quota — quota ignores kyverno exceptions; their only defaults source is a namespace LimitRange (cmdshift/platform#111, recipe: adding-a-workload runbook §7). **Surge clause (all four faces)**: quota headroom must admit a rollout surge pod of the namespace's largest Deployment on requests AND limits, cpu AND memory — a quota face can be individually exhausted by the overlap even when memory fits (the strimzi wedge hit memory once, then `limits.cpu` after the memory repair; evidence in `bases/datastores-config/README.md`, cmdshift/platform#186). A quota-exceeded ReplicaSet does not self-heal when the quota is raised — annotate the stuck RS (cmdshift/platform#155).

## The audits — pick by question

| Tool | Question |
|---|---|
| `memory_audit [pct]` | is anything near its **limit**? (usage-vs-limits; footer counts limit-less containers — expected 3: control-plane statics, cmdshift/platform#70) |
| `cpu_audit [pct]` | same for CPU + the silent-killer check: top-10 by % of CFS periods throttled (>5% worth a look) |
| `request_audit [pct]` | are **requests** honest for scheduling? (≥100% of memory request = first evicted under node pressure) |
| `vpa_recs [ns]` | what does **VPA** recommend for this workload? (the recommendation side — P99-shaped candidate requests from the Off-mode VPAs) |

A VPA recommendation is a **candidate request, not a drop-in** — cross-check it against the usage audits and the convention above (request ≈ P99 × 1.2, limit = 1.5 × request) before editing manifests. The VPAs are Off mode and hand-maintained per workload (goldilocks the auto-creator was removed; new workloads get a VPA in their group manifest — see `manifests/bases/observability/README.md`).

**Store decision (cmdshift/platform#186, resolving #171)**: O2 **is** the
metrics store — `prometheus_query` speaks PromQL to O2's Prometheus-compat
API and `cpu_audit`'s throttle check works again. Two O2 query caveats:
metric-defined labels (`pod`, `namespace`, `container`) survive, but the
standard target labels are OTel-translated (`job` → `service_name`,
`instance` → `service_instance_id`) — group by the surviving names. Range
queries are honest, not buggy: gap clusters in 7d trend output are
**environment outages** (host sleep or a dead store companion — cmdshift/
platform#202, root-caused live 2026-11-19), so read gap clusters as outage
windows — check the host sleep log (`pmset -g log`) and companion uptimes
(`docker ps`) before diagnosing the store — and never a query fault; instant
queries (what the audits use) scan a narrow recent window and look clean
through anything. Scrape-path inventory (cmdshift/platform#219): the
gateway's cadvisor scrape keeps only `container_fs_*` +
`container_cpu_cfs_*` families — there are NO cadvisor `container_memory_*`
series in O2; memory gauges come from the kubeletstats receiver as
`k8s_pod_memory_working_set`/`k8s_pod_memory_rss` with OTel labels
(`k8s_namespace_name`/`k8s_pod_name`/`k8s_node_name`/`service_name`), not
the prometheus `container_memory_working_set_bytes` family and not
`job`/`instance`. Some series carry no `k8s_container_name` at all (the
velero server series) — sanity-filter against `kubectl top` before trusting
a selector. Range mode under-samples short bursts (~30 points over 7d) —
for burst evidence, run instant `max_over_time`/`quantile_over_time` evals
over `[7d]` selectors with a `kubectl top` cross-check.

- **Seasoning gate**: a fresh rebuild resets recommender history, so `vpa_recs` pulled <48h after one are polluted by the early-cluster ramp (alloy came back +530% CPU that never materialized — the 7d peak stayed single-digit; most deltas collapsed to ±10% noise, cmdshift/platform#66). Pull recommendations only after the cluster has seasoned, and cross-check every delta against 7d max/P99 trend queries before editing. The gate extends to outages (cmdshift/platform#219): operators crashlooping through an apiserver outage reshape the recommender's recent samples (cloudnative-pg's fresh target drifted 75→105Mi, +40%, purely on outage-window crashlooping) — distrust fresh targets whose window overlaps an outage and prefer the unaffected 7d P99 trend.
- **Reject over-conservative recs at tiny sizes**: below ~20Mi the recommender's output can exceed the observed P99 (loki-gateway's 22Mi rec vs a 7d P99 of 13Mi under a 16Mi request) — the trend query wins (cmdshift/platform#66).

## Interpretation

- **Trend, not snapshot.** A fresh cluster's first ~3h is always a ramp (head chunks, WAL, warmup) — judge after that.
- **Shapes:** a steady climb = leak or cardinality growth; a **sawtooth returning to baseline = periodic burst** (needs limit headroom over the peak, not a leak hunt).
- **A below-limit snapshot does not clear a limit** — transient bursts kill between snapshots (seaweed volume server OOMKilled at 240Mi while `kubectl top` read 183Mi); judge burst headroom from the range-query peak (memory-sizing-audit §4, seaweed traps in `manifests/bases/objects/README.md`).
- For prometheus's own memory: check series count first (`prometheus_query -c 'prometheus_tsdb_head_series'`, `topk(10, count by (job)({__name__=~".+"}))`) — if memory tracks series, the fix is `MetricRelabelings`, not a bump.

## Decide and record

- Sizing rationale lives in the group README's decision table (`writing-yaml` skill Comments rules — evidence numbers + derivation + `cmdshift/platform#N` ref, never at the value); trend-driven cases get a tracking issue with the data (cmdshift/platform#20 is the template).
- The `ContainerOOMKilled` alert guards the ceiling meanwhile — alerts at http://mail.cloud.test.

## Full detail

[runbooks/local/memory-sizing-audit.md](../../../runbooks/local/memory-sizing-audit.md)
