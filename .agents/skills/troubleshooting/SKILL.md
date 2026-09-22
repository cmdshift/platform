---
name: troubleshooting
description: Something broke, behaves unexpectedly, or a change isn't landing — start here before deep-diving. Check the README nearest the area being worked on first, then route to the specific skill (pipeline-wedged, reconcile-stuck, helmrelease-stuck, crashloop-investigation, observability).
---

# Troubleshooting: route before you dig

## 1. Check the nearest README first

Chart traps, per-group decisions, and pipeline mechanics live with the thing they describe — read the README nearest the area being worked on **before** diagnosing:

- `manifests/bases/<group>/README.md` — the group's chart landmines (kyverno, cilium/ztunnel, velero, mimir/alloy, seaweedfs, cert-manager, local-path, …)
- `manifests/bases/flux/README.md` — flux API traps, the pipeline's own objects, propagation mechanics
- `cluster/local/README.md` — terraform/docker traps (endpoint rewrite, bootstrap pins, port publishing)
- `manifests/README.md` — cross-cutting conventions + the hardening-deviations baseline

Most live landmines are already written down with their fingerprints — the README often answers the question without a diagnostic round.

## 2. Route to the specific skill

| Symptom | Skill |
|---|---|
| Manifest edits not reaching the cluster (workloads run, nothing applies) | `pipeline-wedged` |
| A flux Kustomization won't go Ready / `flux_wait` timed out | `reconcile-stuck` |
| A HelmRelease failing or stuck reconciling | `helmrelease-stuck` |
| Pods crashlooping / OOMKilled / exiting silently | `crashloop-investigation` |
| Need metrics, logs, or alert delivery evidence | `observability` |
| Terraform plan shows unexpected replacements on untouched resources | `terraform-churn` |

## 3. First diagnostics

```
pod_status                 # pod table with restarts/exit codes — crashloop triage
policy_report              # admission verdicts; failures > 0 = denials in play
flux_wait -c               # instant no-reconcile verdict on the tree
helm_wait -c <ns> <name>   # instant verdict on one HelmRelease
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

Observability evidence (`prometheus_query`, `loki_query`, `mailpit`, `tetra`): the `observability` skill.

**No invocation longer than 60 seconds** (AGENTS.md rule): local ops either make progress or fail fast. No sleep loops, no blind polling to a long timeout — estimate the wait, cap the poll at ~2× that, and diagnose early failures (StartError, admission denial, failed mounts at t=10s) instead of waiting out the timeout. Bounded wait helpers (`flux_wait`, `helm_wait`, `velero_wait`) exist in `tools/bin/` precisely so this rule doesn't get improvised around.

## 4. Write-back rule

A landmine that cost a debugging round gets written to the **nearest README** (with its `cmdshift/platform#N` ref) in the same session — that's where the next operator looks first (step 1). Skills keep their trap lists for their own trigger; the README carries the narrative. The `docs-sweep` skill dispatches the write-up if the session shouldn't block.
