# Incident post-mortems

Worked incident narratives for this cluster: symptom → triage path → root cause → fix → tells for next time. Timeless landmines distilled from these live in the skills and group READMEs; the date-driven story lives here (and in [CHANGELOG.md](../../CHANGELOG.md)).

Incidents documented in their owning runbooks (kept there for context):

- **Bootstrap hang** (stale Docker port publisher) → [cluster-rebuild.md](cluster-rebuild.md)
- **Trivy cold-start race** on fresh rebuild → [cluster-rebuild.md](cluster-rebuild.md)
- **kps PSS-label clobber via SSA field-manager collision** (mechanism) → [namespace-migration.md](namespace-migration.md)
- **velero OOM during kopia repo prep** → [crashloop-investigation.md](crashloop-investigation.md)
- **prometheus memory growth / kyverno reports sawtooth** (trend-vs-snapshot templates) → [memory-sizing-audit.md](memory-sizing-audit.md)

---

## Audit policy field wedged the apiserver (cmdshift/platform#90)

**Symptom**: after templating a kube-apiserver audit Policy into the ctrl machine config, the ctrl node dropped out of the cluster — pods on it unschedulable, API blipping.

**Root cause**: the Policy rule field `responseStages` does not exist in the Kubernetes audit Policy schema. Talos's RenderConfigsStaticPodController failed strict decoding: `error generating configuration "auditpolicy.yaml" for "kube-apiserver": error unmarshaling audit policy configuration: strict decoding error: unknown field "rules[0].responseStages"` — the kube-apiserver static pod went down on the ctrl node.

**Fix**: remove the invalid field from the policy file, `terraform apply` (the `talos_machine_configuration_apply` resource re-lands the config), and restart the ctrl container. **Talos-in-Docker container mode does NOT support `talosctl reboot`** (`FailedPrecondition: method is not supported in container mode`) — node-level convergence after an apiserver-render failure is `docker restart <ctrl-container>` (~30s to Ready; k8s API drops briefly).

**Kyverno re-pick-up lag collateral** (known shape, re-hit): during the churn the thanos-operator's STS update was denied by kyverno → ThanosRuler `main` went Ready=False ("failed to create or update 1 resources"). A reconcile + annotation bump on the PolicyException cleared it — no manifest change needed there. Related DaemonSet gotcha: a DS at `desired=5 current=4` with no PodScheduled-pending pod means the DS controller hasn't created the 5th pod yet; an annotation nudge (`platform.nudge`) forces the controller loop — but the annotate itself goes through kyverno admission, which was also mid-lag. Once stable, the nudge landed the pod.

**Tells for next time**:

- Anything templated into a static-pod render path gets validated by Talos's **strict decoder** — verify every field against the real Kubernetes audit Policy schema before it touches the machine config; one unknown field takes down the control plane, not just the feature.
- After an apiserver-render fix, the recovery is machine-config apply + `docker restart` of the ctrl container (container mode has no `talosctl reboot`).
- A downstream controller failing "create or update" mid-cluster-churn is often kyverno admission lag, not a real spec error — bump the PolicyException annotation and reconcile before rewriting anything.

## Gateway-API ingress born dead (cmdshift/platform#70)

**Symptom**: the `cilium` GatewayClass and the `local-test` Gateway both sat "Waiting for controller" indefinitely; agent logs carried zero GatewayClass activity; the internal haproxy answered 503. Found during the #54 rebuild (2026-09-09) but pre-existing — nothing in that change touched cilium values, the Gateway, or the LB.

**Root cause**: the bootstrap pinned `kubeProxyReplacement=false` — cilium's Gateway API controller requires KPR and refuses the GatewayClass, logging exactly `Gateway API support requires kube-proxy-replacement enabled`. The KPR=false flip (+ Talos `proxy.disabled=false`) had landed as an unexplained drive-by in c4a6077 (2026-08-31, the kyverno-policies commit — the same commit that introduced the Gateway manifest): no CHANGELOG entry, no issue, and it inverted the docs-recommended 2026-08-26 pairing (KPR=true + proxy.disabled=true). The Gateway path was never green — it was born into the dead window.

**Fix chain** (each step gated on the previous):

1. `kubeProxyReplacement: true` in the cilium values (+ bootstrap parity) — **and this alone was not enough**: a values-only helm upgrade updates the `cilium-config` ConfigMap and rolls the agent DaemonSets (`rollOutCiliumPods`), but the cilium-operator Deployment's pod template is unchanged, so the operator process kept the old `--kube-proxy-replacement='false'` startup flag and the GatewayClass stayed unclaimed until `kubectl -n kube-system rollout restart deploy/cilium-operator` (mounted-config reload). The tell: the values can be right while the process is stale — check the operator's actual startup args before assuming a values change landed.
2. Talos `proxy.disabled: true` — Talos stops *rendering* kube-proxy but never deletes the already-applied DaemonSet (the ManifestApplyController applies, never prunes), so convergence needed a one-time `kubectl -n kube-system delete ds kube-proxy`. The machine config applied live with no reboot (cluster.proxy changes are live-appliable).

**Ordering hazard (dodged)**: kube-proxy must not disappear before cilium KPR=true is live — the ClusterIP DNAT gap would make coredns (a ClusterIP service) unreachable and flux could reconcile nothing: a deadlock. Sequence used: values flip → agents healthy → machine config.

**Secondary find during verification**: `curl https://local.test` failed with `tlsv1 alert protocol version` — the internal haproxy's `web_tls` frontend/backend inherited `mode http` from `defaults main` and parsed the TLS ClientHello as HTTP, mangling the handshake. Fixed to `mode tcp` passthrough (the Gateway terminates TLS) + `timeout server 10m` (the defaults' 10s client/server timeout would cut idle TLS connections). :80 was unaffected (plain HTTP through to envoy).

**Tells for next time**:

- "Waiting for controller" on a GatewayClass → grep the cilium-operator logs for the prerequisite message first, then check the operator process's actual startup flags (`kubectl -n kube-system get deploy cilium-operator -o yaml`), not just the values.
- A DaemonSet the platform "removed" (Talos stops rendering it) keeps running — removed rendered manifests need a one-time manual delete; rendered-manifest apply never prunes.
- Any kube-proxy ↔ cilium-KPR ordering-sensitive change: cut cilium over first, remove kube-proxy second.

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

**Root cause**: the (now `observability`, cmdshift/platform#120) namespace's PSS labels were gone — node-exporter needs `enforce=privileged` (hostNetwork/hostPID/hostPath/hostPort) and PSS baseline denied every pod at creation (`Error creating: ... violates PodSecurity "baseline:latest"`). That is **kubelet PSS admission, not kyverno** — kyverno never sees the pod. Mechanism: the thanos-operator bundle ships `Namespace: thanos-operator-system`, renamed onto the monitoring namespace (today `observability`); both the `namespaces` and `thanos-operator` kustomizations apply the same object as the same SSA field manager (`kustomize-controller`), and whichever reconciles last rewrites the label map, pruning the other's fields. Pre-rebuild this survived by luck (reconcile order); on a rebuild the order isn't guaranteed. Fix: the bundle's Namespace carries the PSS labels via a strategic-merge patch in `observability/thanos-operator.kustomization.yaml` — both appliers declare the identical load-bearing set, so order no longer matters (cosmetic label flip-flop may persist; harmless).

**Recovery sequence** (after the fix, for a Stalled kps): PSS labels land (via the observability group reconciling the updated Kustomization CR — note `flux reconcile kustomization observability --with-source` BLOCKS on the group's health wait while kps is down; the CR spec still applies event-driven) → node-exporter DS FailedCreate retries succeed → the release replays its terminal state (`RetriesExceeded`) → `flux suspend/resume helmrelease kube-prometheus-stack -n observability` forces a fresh install (the `helmrelease-stuck` ladder, step 2) → Ready.

**Triage fingerprint**: kps install timeout on node-exporter + `kubectl get events -n observability --field-selector reason=FailedCreate` showing PSS violations + `kubectl get ns observability --show-managed-fields -o json` showing a single `kustomize-controller` Apply entry whose label set is missing the PSS keys.

## etcd health flap during the first datastores reconcile (cmdshift/platform#49)

**Symptom**: kube-apiserver stopped answering for ~3-min waves — flux controllers lost leader election; kube-scheduler/kcm/cert-manager/cilium-operator crashed with connection errors. **No OOM kills, nodes healthy.**

**Root cause**: etcd had been flapping `Health check failed: context deadline exceeded` for an hour+; ctrl-node busiest-core CPU ran 94-98% from ~02:45 — before both the nightly backup (03:00) and the reconcile (03:44). Reading: overlapping load waves (hourly trivy scans, nightly velero backup, thanos compaction) on the shared Docker Desktop VM, with the reconcile's 24-CRD discovery stampede as the worst wave. All controllers self-recovered; the incident is the sizing argument for keeping single-purpose operators lean.

**Triage tell**: `talosctl services` on the ctrl node shows etcd health flaps — NOT restarts (check the event history; "LAST CHANGE" is the last flap, not a boot).

## Ruler store-path stale-IP window

**Symptom**: during trivy-alert verification the ruler logged `no query API server reachable` / store `dial tcp <pod-ip>:10901: i/o timeout` — even head-only rules failed.

**Root cause**: the query's SRV-resolved store endpoint held a stale pod IP after the store pod was recreated, and the query errors the WHOLE request when one store dials out. Self-healed when the query pod rolled.

**Triage order**: ruler logs → dial-test the store IP from the query pod (`wget http://<store-ip>:10902/-/ready`) → only then suspect network policy. It is not a CNP block. (Sibling of the "head path broken again" landmine in [observability/README.md](../../manifests/local/observability/README.md).)

## Alloy ConfigMap mount staleness (cmdshift/platform#39)

**Symptom**: after an in-place edit of the kustomize-generated `alloy-config` ConfigMap, the API object updated but all four pod volume mounts stayed stale 5+ min (first in-place CM update since the rebuild). The pods didn't crash — they were serving the old config.

**Fix**: `kubectl -n observability rollout restart daemonset/alloy` (same class as `docker restart sync-cloud-test`). Whether alloy hot-reloads is untested — the mount never refreshed to find out.

## Beyla host kernel panic → removal (2026-09-18)

**Symptom**: within a day of the beyla adoption (cmdshift/platform#83, merged as PR #124) the host kernel panicked with beyla's eBPF probes attached. No exact panic text captured (cluster destroyed for a clean rebuild immediately after); symptom-level evidence only: the panic correlated with beyla's DaemonSet running probes on the work nodes.

**Root cause**: beyla 1.16.11's eBPF instrumentation is incompatible with the host kernel (7.2) — the same host-kernel constraint class that already forces the cilium `1.21.0-pre.2` pin (cilium/cilium#48016). Unlike cilium, beyla's panic mode is fatal to the host, not degraded functionality. The eBPF programs that load cleanly for tetragon (kprobes, and kallsyms-verified symbols) do not imply kprobe/tracepoint coverage for a different instrumenter's probe set — each eBPF workload must be verified against this kernel independently.

**Fix**: beyla removed entirely — HelmRelease + values, `beyla-values` configMapGenerator entries, and the `allow-beyla-ebpf` PolicyException deleted; observability quotas reclaimed beyla's share (pods 41→36, limits.memory 12Gi→9Gi; tempo's share kept, `requests.cpu: "1"` stays — tempo's 150m still exceeds the old 750m ceiling). Tempo is retained (traceless until instrumentation returns). Because the cluster was destroyed before the fix, the removal took effect at the next rebuild — zero in-cluster ordering concerns. Landmines learned during the one-day adoption (contextPropagation default forcing hostNetwork, in-namespace tracefs mounts, quota-ordering deadlock) are retained in [manifests/local/observability/README.md](../../manifests/local/observability/README.md) — they apply to any future eBPF/privileged-instrumentation workload.

**Tells for next time**:

- **Verify host-kernel compatibility BEFORE adopting any eBPF-probe workload** (beyla, future OBI/hubble versions, anything loading kprobes/tracepoints beyond tetragon's proven set). Tetragon loading is not evidence another instrumenter's probes are safe; cilium's pin and beyla's panic are the two data points.
- A workload that takes down the HOST (not just its pods) must be treated as a destroy-and-rebuild event: the cluster was destroyed and rebuilt rather than attempting in-place recovery — node-level panics in Talos-in-Docker have no supported convergence path (container mode has no `talosctl reboot`; see the audit-policy incident above for the limited `docker restart` recovery class).
- An eBPF workload surviving a deploy window (beyla ran fine for a day before the panic) is not proof of stability — probe paths fire on workload mix; treat the first 24-48h of any new eBPF workload as a burn-in window.

## Tetragon lsmhooks load failure (kernel BTF gap)

**Symptom**: an `lsmhooks:` TracingPolicy applied cleanly via flux but the agent reported load errors on every node: `lsm hook security_file_open not found in BTF`.

**Root cause**: `CONFIG_BPF_LSM=y` in `/proc/config.gz` looked like full BPF-LSM support, but the vmlinux BTF **lacks the `bpf_lsm_*` hook symbols**. Pre-flight that works: `talosctl -n <node> read /proc/kallsyms | grep -wE "[Tt] (<symbols>)"` before writing the policy, then `cr_validate` before `sync_wait`. Plain kprobes on the same symbols attach fine; `fmodret: true` is supported. Also discovered: `free_module` is inlined in this kernel build (absent from kallsyms) — dropped from the modules policy; `do_init_module` attaches as a local `t` symbol.
