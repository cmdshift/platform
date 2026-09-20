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

Folded into `memory_audit`'s footer. Expected on this cluster: **3** — three control-plane statics (apiserver, scheduler, controller-manager). The thanos-ruler config-reloader used to make it 4 but left with the LGTM migration (cmdshift/platform#128); kube-proxy ×5 used to make it 9 but left with the cilium KPR cutover (cmdshift/platform#70). Anything else is a finding.

## 4. Trend, not snapshot

```
prometheus_query -c -r 6h 'container_memory_working_set_bytes{namespace="<ns>",container="<name>"}'
```

A fresh cluster's first ~3h is always a ramp (head chunks, WAL, warmup) — judge trends after that. Anything >60% of limit and climbing is a candidate. Distinguish shapes before acting: a steady climb is a leak or cardinality growth (platform#20), a **sawtooth that returns to baseline is a periodic burst** (kyverno reports-controller's hourly scan, platform#21) — that needs limit headroom over the peak, not a leak hunt.

## 5. For prometheus itself: cardinality, not just memory

```
prometheus_query -c 'prometheus_tsdb_head_series'                          # absolute + trend
prometheus_query -c 'topk(10, count by (job)({__name__=~".+"}))'           # which job owns the series
```

Reference finding (platform#20): the apiserver job alone was 52k of 111k head series on this CRD-heavy cluster. If memory tracks series growth, the fix is `MetricRelabelings` (e.g. pruning `apiserver_request_duration_seconds` buckets), not another memory bump.

## 6. Decide and record

- size per the convention (AGENTS.md → Do list: request ≈ P99 × 1.2, limit = 1.5 × request); deliberate deviations get a rationale comment in the manifest (comment rules: the `code-comments` skill, cmdshift/platform#43 — velero runs 2× for kopia spikes)
- the CPU sibling of this audit is `cpu_audit` (throttled-periods top-N + usage-vs-limits table)
- the scheduling-side sibling is `request_audit` (usage-vs-**requests** for memory + CPU — containers over 100% of their memory request are first in line for eviction under node pressure, and their scheduling reservation lies)
- the recommendation-side sibling is `vpa_recs` (VPA targets vs current requests; goldilocks maintains Off-mode VPAs automatically for every non-system workload — `manifests/local/observability/README.md`). A recommendation is a P99-shaped candidate request, **not a drop-in**: cross-check against the usage audits and the convention above before editing manifests. Two `vpa_recs` traps (cmdshift/platform#66): a fresh rebuild resets recommender history, so recommendations pulled <48h after one are inflated by the early-cluster ramp — pull only after seasoning and cross-check deltas against 7d max/P99 trends; and at tiny sizes the recommender can overshoot the observed P99 (loki-gateway: 22Mi rec vs 13Mi P99 under a 16Mi request) — reject with the trend evidence
- flux delivery controllers (source/helm/kustomize) have their own floor — see the sizing section in [manifests/local/flux/README.md](../../manifests/local/flux/README.md); starving them wedges the whole pipeline
- trend-driven cases: open a tracking issue with the data (platform#20 is the template) — the `ContainerOOMKilled` alert guards the ceiling meanwhile (read alerts at http://mail.cloud.test)

## 7. Landing the changes: valuesFrom ordering (hit 2026-09-07)

Resource bumps are values-only changes → the HelmRelease spec is untouched → helm-controller never re-triggers. The two-step dance, **in this order**:

1. `sync_wait` + `flux_wait` — the *group* kustomization rebuilds the generated `ConfigMap/<release>-values` (the CMs do not exist until this runs).
2. `helm_wait <ns> <release>` for each changed release — re-triggers helm against the *fresh* CM.

Run `helm_wait` **without** `flux_wait` first and the upgrade re-renders against the OLD ConfigMap data — the HR goes Ready, reports success, and the new values never land (hit twice in the 2026-09-07 audit; the tell is `request_audit` still showing the old requests after a "successful" rollout). CR-managed workloads (Grafana/Alertmanager/the OTel collector CR) don't need step 2 — the operator picks up the CR edit on its own reconcile; a `flux reconcile kustomization <group>-config --with-source` forces it. Plain-manifest workloads (mimir's StatefulSet) are owned by the `observability` group kustomization — `flux_wait`, then `flux reconcile kustomization observability --with-source` if a nudge is needed.

Also: `request_audit`'s read of pod resources reflects the **old** pods until each rollout finishes — daemonsets/statefulsets roll one pod at a time; re-run the audit after the roll completes, not during it.

---

*Agent entry point: the `resource-sizing` skill in `.agents/skills/resource-sizing/`.*
