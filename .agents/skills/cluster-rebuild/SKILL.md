---
name: cluster-rebuild
description: Fresh terraform bootstrap of the Talos-in-Docker cluster — the just commands, the ~10m one-shot convergence timeline, the post-rebuild verification table, and what data is wiped. Use when rebuilding the cluster or validating a fresh bootstrap.
---

# Cluster rebuild (fresh bootstrap)

Validated end-to-end: the whole platform converges in **one shot, no manual intervention** — bootstrap helm hooks create the pipeline's own Bucket + root Kustomization, and the flux tree takes it from there.

## Prerequisites

- `.tmp/tls` certs must exist (the `secrets` and `bootstrap` modules read them): `just certs` — skip if already present
- Nothing running that you care about — see data implications below

## Procedure

```
just cluster apply      # docker network, companions, talos nodes, kubeconfig (.tmp/kubeconfig)
just bootstrap apply    # cilium + flux helm releases + the Bucket/root hooks
```

**Destroy + recreate from scratch (operator recipe):**
1. `just bootstrap destroy` **always fails** — `lifecycle.prevent_destroy` guards the flux state (bucket_credentials, helm_release.flux, …), and the plan error ("Instance cannot be destroyed") IS that guard, not a problem to fix (on a cluster that's already down it fails earlier, at the readiness poll — same verdict). Skip it (or run it and ignore the failure); the cluster module is destroyed *underneath* the bootstrap state and `bootstrap apply` reinstalls flux onto the fresh cluster.
2. `just cluster destroy -auto-approve` (~1m, wipes rustfs + PVCs per data implications).
3. `just cluster apply -auto-approve` (~45s at 1 ctrl node; not health-gated — returns after the machine-config applies + bootstrap, and the bootstrap API gate in step 4 owns readiness; the former `talos_cluster_health` node-health gate was removed as redundant, cmdshift/platform#73). **If it hangs at `talos_machine_bootstrap`** (macOS/Docker Desktop hosts only — the stale-binding failure class is Docker-Desktop-specific and unobserved on Linux/Docker Engine hosts): root cause is a stale Docker Desktop port binding after container churn — host listener accepts but black-holes into the VM (not the node, not a race). Recovery: kill the apply, `docker restart $(docker ps -q --filter name=ctrl-local-test)` (node reboot, ~30s to Ready), re-run the apply — only bootstrap + kubeconfig remain and they land in seconds. The provider now fails fast (10s timeouts) instead of its old silent 10m retry. Verify with `curl -skf --max-time 3 https://127.0.0.1:6443/version` — 401 = binding alive; TLS `SSL_ERROR_SYSCALL` right after a restart = publisher alive, API still booting (~60s), NOT a stale binding (a stale binding is a silent hang with no TLS stage) — don't restart twice. Non-interactive shells MUST pass `-auto-approve` (the approval prompt EOFs otherwise).
4. `just bootstrap apply -auto-approve` (~90s incl. the API-up gate; 4 resources). The bootstrap module **gates itself on an apiserver readiness poll** (cmdshift/platform#72): the apply blocks in plan polling the kube API until it answers, then applies — no wait, no re-run (**nodes Ready ≠ API serving** is the poll's problem now, not the operator's; bootstrap apply stays idempotent regardless). A gate timeout ≈ genuinely broken — suspect the stale Docker port binding (step 3's recovery), not timing.
5. Everything reconciles eventually — the dependency chain below takes ~10m; the trivy cold-start race pod (below) is expected. First-converge blips that self-heal (ClusterIssuer, Seaweed volume 0/1, Alertmanager NoPodReady — the recurring one, cmdshift/platform#69) are catalogued in the runbook's verification section.
6. **If a node-level fix is ever needed post-apply** (e.g. an apiserver static-pod render failure wedged the ctrl node): container mode does NOT support `talosctl reboot` (`FailedPrecondition: method is not supported in container mode`) — `docker restart <ctrl-container>` is the convergence path (~30s to Ready; k8s API drops briefly). Post-mortem: [runbooks/local/incidents.md](../../../runbooks/local/incidents.md) (cmdshift/platform#90).

Expect **~10 minutes**, progressing through the dependency chain in order:

```
sources → crds → namespaces → certificates → networking (cilium: the long pole)
→ flux → flux-config (adopts the Bucket + root) → metrics → policies
→ storage → objects → monitoring → thanos-operator → monitoring-config
→ backups → logging → security → security-config
```

Watch with `flux_wait` (interactive cap ~15), or `flux_wait -c` for an instant no-reconcile verdict.

## Post-rebuild verification

| Check | Command | Expect |
|---|---|---|
| Kustomizations | `flux_wait -c` | exit 0, all Ready |
| HelmReleases | `kubectl get helmreleases -A` | all True; per-release: `helm_wait -c <ns> <name>` |
| Tetragon policies | `tetra --server-address localhost:54321 tracingpolicy list` (after `kubectl -n security port-forward ds/tetragon 54321:54321`) | 4 × enabled, monitor_only; FILTERID non-zero for privileges-raise + sensitive-host-paths |
| Policy load failures | `prometheus_query 'tetragon_tracingpolicy_loaded{state=~"error\|load_error"} > 0'` | empty (the gauge exports zero-valued states too — filter with `> 0`) |
| flux-config adoption | `kubectl -n flux-system get kustomization local -o json --show-managed-fields` | `kustomize-controller` owns the spec |
| Velero BSL | `kubectl -n backups get bsl default` | `Available` |
| Rustfs buckets | `rustfs ls main/` | `flux`, `backups` |
| Thanos ruler | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-ruler` | 1/1 Running (CR sets `replicas: 1`) |
| Host API path | `curl -skf --max-time 3 https://127.0.0.1:6443/version` | 401 = publisher alive |
| Ingress | `curl -s -o /dev/null -w '%{http_code}' http://local.test` | 404 = correct wiring with zero HTTPRoutes (`server: envoy` header proves the Gateway path); 503 = haproxy backends down |
| Trivy scan pod | `kubectl -n security get pods` | one `scan-vulnerabilityreport-*` pod in `Error` is EXPECTED (see below); all later scans `Completed`, VulnerabilityReports accumulating |
| PolicyReports | `policy_report` | 0 failures |

**Bootstrap race, self-healing:** on a fresh rebuild the ruler CR can fail its first sync (query service not up yet) → `Ready=False (ReconcileError)` on the CR. Since thanos-community/thanos-operator#636 the operator emits a single recoverable `Ready` condition — the next sync flips it `True`; no manual action, verify it converged (cmdshift/platform#22).

**Trivy cold-start race (expected, mostly self-healing):** the operator's Deployment goes ready ~16s before its first scan job, but the `trivy-server-0` StatefulSet (cache server, same release) starts ~75s later — the first job (the cluster-SBOM scan) dies with `dial tcp trivy-service:4954: connect: connection refused`. The operator deletes the failed job (30s retry delay) and all *workload* scans re-run fine; `dependsOn: networking` would NOT fix this — the race is between two resources of one helm release, and networking is Ready long before. The one artifact that does NOT self-heal: the `ClusterSbomReport` stays status-less (the operator treats its server-side cached SBOM as valid and won't re-scan until the report TTL/server cache expires). Nothing consumes that report locally — leave it, or delete it + restart the operator (note: a restart alone does NOT regenerate it).

## Data implications

A full destroy/apply wipes everything not in the local manifests:

- rustfs container data — buckets re-provision, `flux` re-populates via sync, **all other bucket contents gone (velero backups included)**
- local-path PVCs and everything on them (seaweed, grafana, loki, thanos ruler state)
- seaweed buckets and their data

If the rebuild stalls: load the `reconcile-stuck` skill (kustomization failures) or `pipeline-wedged` (manifests stop applying).

## Full detail

[runbooks/local/cluster-rebuild.md](../../../runbooks/local/cluster-rebuild.md)
