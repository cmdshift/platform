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

Folded into `memory_audit`'s footer. Expected on this cluster: **3** — three control-plane statics (apiserver, scheduler, controller-manager). Anything else is a finding.

## 4. Trend, not snapshot

```
prometheus_query 'max_over_time(k8s_pod_memory_working_set{k8s_namespace_name="<ns>"}[6h])'   # instant eval — no -r (see tools README: -r under-samples bursts)
prometheus_query 'max_over_time(container_memory_working_set{k8s_namespace_name="<ns>"}[6h])'  # per-container P99 (adds k8s_container_name)
```

The store behind this is O2 (cmdshift/platform#186 — the cmdshift/platform#171 orphaning is
resolved). O2 query caveats: the memory gauges are the kubeletstats families
`k8s_pod_memory_working_set` / `k8s_pod_memory_rss` (pod level) and
`container_memory_working_set` (container level, with `k8s_container_name`
except on the velero server series — sanity-filter with `kubectl top`) with
OTel labels
(`k8s_namespace_name`, `k8s_pod_name`, `k8s_node_name`), NOT the prometheus
`container_memory_working_set_bytes` family — the gateway's cadvisor scrape
keeps only the fs/cfs families (cmdshift/platform#219 inventory; full shape:
`tools/bin/README.md` → `prometheus_query`); and range queries are honest,
not buggy — gap clusters in trend output are **environment outages** (host
sleep or a dead store companion, cmdshift/platform#202, root-caused
2026-11-19): check the host sleep log (`pmset -g log`) and companion uptimes
(`docker ps`) before diagnosing the store. Instant queries (what the audits
use) scan a narrow recent window and look clean through anything.

A fresh cluster's first ~3h is always a ramp (head chunks, WAL, warmup) — judge trends after that. Anything >60% of limit and climbing is a candidate. Distinguish shapes before acting: a steady climb is a leak or cardinality growth (cmdshift/platform#20), a **sawtooth that returns to baseline is a periodic burst** (kyverno reports-controller's hourly scan, cmdshift/platform#21) — that needs limit headroom over the peak, not a leak hunt.

**A "usage below limit" snapshot is NOT evidence the limit is safe.** Transient bursts kill between snapshots: the (since-removed) seaweed volume server was OOMKilled at its 240Mi limit while `kubectl top` read 183Mi at death — only the range query showed the spike (post-mortem story in [CHANGELOG.md](../../CHANGELOG.md), 2026-09-25). For any container with a burst-shaped workload (flush paths, vacuum/compaction, periodic scans), judge headroom as limit ÷ range-query peak, not limit ÷ current usage.

## 5. Cardinality, not just memory

```
prometheus_query -c 'count by (service_name) (<metric>)'   # which source owns a metric's series (O2: job → service_name; name-less selectors are rejected)
```

Reference finding (cmdshift/platform#20): the apiserver job alone was 52k of 111k head series on this CRD-heavy cluster. If memory tracks series growth, the fix is scrape-config metric pruning (e.g. dropping high-cardinality buckets), not another memory bump. (No prometheus runs, so there is no `prometheus_tsdb_head_series`; and O2 rejects name-less selectors — `{__name__=~".+"}` → `metric name is required` — so cardinality is counted per metric, never across all series at once.)

## 6. Decide and record

- size per the convention (AGENTS.md → Do list: request ≈ P99 × 1.2, limit = 1.5 × request); deliberate deviations record their rationale in the group README's sizing decision (comment rules: the `writing-yaml` skill, Comments section, cmdshift/platform#43 — velero: request ≈ P99×1.2 covering the observed kopia burst, with the 512Mi limit holding the spike-absorption role, cmdshift/platform#219)
- the CPU sibling of this audit is `cpu_audit` (throttled-periods top-N + usage-vs-limits table)
- the scheduling-side sibling is `request_audit` (usage-vs-**requests** for memory + CPU — containers over 100% of their memory request are first in line for eviction under node pressure, and their scheduling reservation lies)
- the recommendation-side sibling is `vpa_recs` (VPA targets vs current requests; Off-mode VPAs are hand-maintained per workload — goldilocks the auto-creator was removed — `manifests/bases/observability/README.md`). A recommendation is a P99-shaped candidate request, **not a drop-in**: cross-check against the usage audits and the convention above before editing manifests. Two `vpa_recs` traps (cmdshift/platform#66): a fresh rebuild resets recommender history, so recommendations pulled <48h after one are inflated by the early-cluster ramp — pull only after seasoning and cross-check deltas against 7d max/P99 trends; and at tiny sizes the recommender can overshoot the observed P99 (the since-removed loki-gateway: 22Mi rec vs 13Mi P99 under a 16Mi request) — reject with the trend evidence
- flux delivery controllers (source/helm/kustomize) have their own floor — see the sizing section in [manifests/bases/flux/README.md](../../manifests/bases/flux/README.md); starving them wedges the whole pipeline
- trend-driven cases: open a tracking issue with the data (cmdshift/platform#20 is the template) — the `ContainerOOMKilled` alert guards the ceiling meanwhile (read alerts at http://mail.cloud.test)

## 7. Landing the changes: valuesFrom ordering (hit 2026-09-07)

Resource bumps are values-only changes → the HelmRelease spec is untouched → helm-controller never re-triggers. The two-step dance, **in this order**:

1. `sync_wait` + `flux_wait` — the *group* kustomization rebuilds the generated `ConfigMap/<release>-values` (the CMs do not exist until this runs).
2. `helm_wait <ns> <release>` for each changed release — re-triggers helm against the *fresh* CM.

Run `helm_wait` **without** `flux_wait` first and the upgrade re-renders against the OLD ConfigMap data — the HR goes Ready, reports success, and the new values never land (hit twice in the 2026-09-07 audit; the tell is `request_audit` still showing the old requests after a "successful" rollout). CR-managed workloads (operator CRs, e.g. a future datastores `Cluster`/`Kafka`) don't need step 2 — the operator picks up the CR edit on its own reconcile; a `flux reconcile kustomization <group>-config --with-source` forces it. Plain-manifest workloads (e.g. the `openobserve-sync` Job) are owned by their group kustomization — `flux_wait`, then `flux reconcile kustomization <group> --with-source` if a nudge is needed.

Also: `request_audit`'s read of pod resources reflects the **old** pods until each rollout finishes — daemonsets/statefulsets roll one pod at a time; re-run the audit after the roll completes, not during it.

---

*Agent entry point: the `resource-sizing` skill in `.agents/skills/resource-sizing/`.*
