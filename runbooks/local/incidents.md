# Incident post-mortems

Worked incident narratives for this cluster: symptom → triage path → root cause → fix → tells for next time. Timeless landmines distilled from these live in the skills and group READMEs; the date-driven story lives here (and in [CHANGELOG.md](../../CHANGELOG.md)).

Incidents documented in their owning runbooks (kept there for context):

- **Bootstrap hang** (stale Docker port publisher) → [cluster-rebuild.md](cluster-rebuild.md)
- **Trivy cold-start race** on fresh rebuild → [cluster-rebuild.md](cluster-rebuild.md)
- **kps PSS-label clobber via SSA field-manager collision** (mechanism) → [namespace-migration.md](namespace-migration.md)
- **velero OOM during kopia repo prep** → [crashloop-investigation.md](crashloop-investigation.md)
- **prometheus memory growth / kyverno reports sawtooth** (trend-vs-snapshot templates) → [memory-sizing-audit.md](memory-sizing-audit.md)

---

## Loki zero-ingestion (cmdshift/platform#27)

**Symptom**: since the rebuild Loki ingested nothing — `loki_ingester_chunks_created_total 0`, 24h-empty queries — with clean logs everywhere. Pods healthy, no errors anywhere.

**Root cause**: commit `ddd4f83` overwrote the `alloy.configMap` values block in `alloy.helm-release.yaml` with the tmp-volume `mounts.extra` block instead of adding alongside it. The grafana/alloy chart then **silently installs its example config** (pods healthy, no push, zero errors), while the kustomize-generated `alloy-config` ConfigMap with the real config sat unreferenced in the namespace. Fix: restore the `configMap` block (now with a rationale comment — it is load-bearing).

**Triage tells, in discovery order**:

- **The components API is the source of truth for "what config is alloy running"** (`alloy_components`, new helper): the example config shows `discovery.kubernetes.{nodes,services,endpoints,endpointslices,ingresses}` (absent from `config.alloy`) and zero `loki.*` components; alloy's only loki metric reads `loki_experimental_features_in_use_total 0`.
- **Red herring**: `loki_distributor_lines_received_total` (and `_bytes_`, `loki_ingester_streams_created_total`) are absent from loki-0 `/metrics` even when healthy — this Loki's kafka/async write-path counters only materialize on first use. Live-traffic counters: `loki_distributor_bytes_received_total{tenant=...}`, `loki_ingester_memory_chunks`, `loki_write_sent_bytes_total` (alloy side).
- **jq trap**: `query_range` responses put entries in `.data.result`, not `.data.streams` — reading `.data.streams | length` always prints 0.

## Seaweed all-volumes-read-only → loki flush failures

**Symptom**: loki-0 logging ~80/min `failed to flush ... S3: PutObject ... 500 InternalError` for 4h+ (ingester retries buffered the chunks — no data lost, memory stable at 404Mi).

**Triage path**: Loki's S3 endpoint is seaweed, not rustfs (`main-s3.objects.svc:8333`). The s3 gateway logged the real error: `No writable volumes and no free volumes left`; the filer's metadata log failed with the same assign error; the master logged `create 7 volume, created 0: Not enough data nodes found!`

**Root cause**: the volume server has a default max volume count (7 slots on one disk dir), loki chunks + thanos blocks filled them in ~12h, and volumes hitting `volumeSizeLimitMB: 1024` go read-only — with no free slot the master can't grow replacements, so every write path 500s at once. Compounding: the volume server was CPU-throttled at 93% of CFS periods (vacuum/compaction churn) and only recovered when the liveness probe restarted the container (fresh process re-registered, master re-read post-vacuum sizes, writes resumed — flush errors 0 within a minute).

**Fix**: volume-server CPU limit 500m→1000m (`objects-config/main.seaweed.yaml`) — same hottest-path logic as the s3 gateway's 1000m. Post-bump: throttling 0, flush errors 0.

**Open follow-up**: no alert fired during the 4h+ of failed flushes — a ruler alert on loki flush failures (or seaweed writable-volume exhaustion) is a gap. Watch the 10Gi seaweed PVC: retention/vacuum is the only lever (`allowVolumeExpansion: false` is deliberate).

## kps uninstall-remediation (PSS labels pruned)

**Symptom** (fresh rebuild): kube-prometheus-stack install failed 4× (timeout waiting for the node-exporter DaemonSet) → uninstall remediation each time → Stalled. `policy_report` showed 0 failures and kyverno saw nothing.

**Root cause**: the `monitoring` namespace's PSS labels were gone — node-exporter needs `enforce=privileged` (hostNetwork/hostPID/hostPath/hostPort) and PSS baseline denied every pod at creation (`Error creating: ... violates PodSecurity "baseline:latest"`). That is **kubelet PSS admission, not kyverno** — kyverno never sees the pod. Mechanism: the thanos-operator bundle ships `Namespace: thanos-operator-system`, renamed onto `monitoring`; both the `namespaces` and `thanos-operator` kustomizations apply the same object as the same SSA field manager (`kustomize-controller`), and whichever reconciles last rewrites the label map, pruning the other's fields. Pre-rebuild this survived by luck (reconcile order); on a rebuild the order isn't guaranteed. Fix: the bundle's Namespace carries the PSS labels via a strategic-merge patch in `monitoring/thanos-operator.kustomization.yaml` — both appliers declare the identical load-bearing set, so order no longer matters (cosmetic label flip-flop may persist; harmless).

**Recovery sequence** (after the fix, for a Stalled kps): PSS labels land (via the monitoring group reconciling the updated Kustomization CR — note `flux reconcile kustomization monitoring --with-source` BLOCKS on the group's health wait while kps is down; the CR spec still applies event-driven) → node-exporter DS FailedCreate retries succeed → the release replays its terminal state (`RetriesExceeded`) → `flux suspend/resume helmrelease kube-prometheus-stack -n monitoring` forces a fresh install (the `helmrelease-stuck` ladder, step 2) → Ready.

**Triage fingerprint**: kps install timeout on node-exporter + `kubectl get events -n monitoring --field-selector reason=FailedCreate` showing PSS violations + `kubectl get ns monitoring --show-managed-fields -o json` showing a single `kustomize-controller` Apply entry whose label set is missing the PSS keys.

## etcd health flap during the first datastores reconcile (cmdshift/platform#49)

**Symptom**: kube-apiserver stopped answering for ~3-min waves — flux controllers lost leader election; kube-scheduler/kcm/cert-manager/cilium-operator crashed with connection errors. **No OOM kills, nodes healthy.**

**Root cause**: etcd had been flapping `Health check failed: context deadline exceeded` for an hour+; ctrl-node busiest-core CPU ran 94-98% from ~02:45 — before both the nightly backup (03:00) and the reconcile (03:44). Reading: overlapping load waves (hourly trivy scans, nightly velero backup, thanos compaction) on the shared Docker Desktop VM, with the reconcile's 24-CRD discovery stampede as the worst wave. All controllers self-recovered; the incident is the sizing argument for keeping single-purpose operators lean.

**Triage tell**: `talosctl services` on the ctrl node shows etcd health flaps — NOT restarts (check the event history; "LAST CHANGE" is the last flap, not a boot).

## Ruler store-path stale-IP window

**Symptom**: during trivy-alert verification the ruler logged `no query API server reachable` / store `dial tcp <pod-ip>:10901: i/o timeout` — even head-only rules failed.

**Root cause**: the query's SRV-resolved store endpoint held a stale pod IP after the store pod was recreated, and the query errors the WHOLE request when one store dials out. Self-healed when the query pod rolled.

**Triage order**: ruler logs → dial-test the store IP from the query pod (`wget http://<store-ip>:10902/-/ready`) → only then suspect network policy. It is not a CNP block. (Sibling of the "head path broken again" landmine in [monitoring/README.md](../../manifests/local/monitoring/README.md).)

## Alloy ConfigMap mount staleness (cmdshift/platform#39)

**Symptom**: after an in-place edit of the kustomize-generated `alloy-config` ConfigMap, the API object updated but all four pod volume mounts stayed stale 5+ min (first in-place CM update since the rebuild). The pods didn't crash — they were serving the old config.

**Fix**: `kubectl -n logging rollout restart daemonset/alloy` (same class as `docker restart sync-cloud-test`). Whether alloy hot-reloads is untested — the mount never refreshed to find out.

## Tetragon lsmhooks load failure (kernel BTF gap)

**Symptom**: an `lsmhooks:` TracingPolicy applied cleanly via flux but the agent reported load errors on every node: `lsm hook security_file_open not found in BTF`.

**Root cause**: `CONFIG_BPF_LSM=y` in `/proc/config.gz` looked like full BPF-LSM support, but the vmlinux BTF **lacks the `bpf_lsm_*` hook symbols**. Pre-flight that works: `talosctl -n <node> read /proc/kallsyms | grep -wE "[Tt] (<symbols>)"` before writing the policy, then `cr_validate` before `sync_wait`. Plain kprobes on the same symbols attach fine; `fmodret: true` is supported. Also discovered: `free_module` is inlined in this kernel build (absent from kallsyms) — dropped from the modules policy; `do_init_module` attaches as a local `t` symbol.
