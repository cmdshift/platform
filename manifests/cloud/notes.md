# Cloud cluster notes (self-managed Talos)

Things to do differently from the local Talos-in-Docker cluster when standing up a cloud cluster. The inventory of deliberately local-only settings lives in `manifests/local/notes.md`.

## Storage: local-path reclaim policy + volume binding (from cmdshift/platform#12)

Both `reclaimPolicy` and `volumeBindingMode` are **StorageClass-level** settings — there is no per-PVC override in general use:

- `volumeBindingMode: WaitForFirstConsumer` — non-negotiable in a multi-node cloud cluster: volumes must bind after pod scheduling so they land on the node the pod runs on. (We already default this locally, so it carries over as-is.)
- `reclaimPolicy` — the PV snapshots the class's policy at provision time. Changing the class later only affects newly provisioned PVs; existing PVs keep `Delete` (or `Retain`) until patched individually.
  - Selective overrides: a separate `local-path-retain` class for data that can't be regenerated, or patch the PV's `persistentVolumeReclaimPolicy` directly. A PVC-level `spec.persistentVolumeReclaimPolicy` field exists upstream (KEP-3939, alpha in 1.32, feature-gated) — verify its status in our k8s version before relying on it.
  - Keep `Delete` as the class default in the cloud too: `Retain` everywhere trades accidental-deletion safety for a steady accumulation of `Released` PVs nobody cleans up. Protect the few volumes that matter, not all of them.

Bigger caveat first: local-path is node-local with no replication — a lost node is a lost volume. In the cloud it's only appropriate for rebuildable state (caches, scratch); durable data belongs on replicated storage or off-cluster S3 (the velero → rustfs pattern we already use locally). Decide the real storage story before spending time tuning local-path policy.

**Velero + local-path volume data — solved locally with a one-annotation fix** (drill 2026-09-05, runbooks/local/velero-backups.md): velero FSB skips hostPath PVs, and local-path-provisioner defaults to hostPath — but its `defaultVolumeType: local` StorageClass annotation makes it emit `local` PVs, which velero FSB backs up natively (no CSI plugin needed). The local StorageClasses carry the annotation; the cloud cluster needs the same on its StorageClasses if it keeps local-path. Velero's temporary data mover pods need resources (`node-agent-config` configmap) and a PolicyException scoped by the `velero.io/pod-volume-*` labels.

**Volume expansion**: the local classes set `allowVolumeExpansion: false` because local-path-provisioner has no expansion code at all (a `true` value just wedges any PVC resize forever — evidence in `manifests/local/notes.md`). Any real CSI StorageClass in the cloud (EBS, Ceph, …) expands natively — set `allowVolumeExpansion: true` there, and size local-path-hosted stateful workloads for the recreate-with-bigger-PVC path if any stay on local-path.

## Cilium (local: manifests/local/networking/cilium.helm-release.yaml)

What must change vs the local helm release:

- `kubeProxyReplacement: false` → **`true`** (explicitly marked in-repo: "true in the cloud") — BPF-based service routing instead of kube-proxy; on real Talos VMs the chart default (probe-based auto) is fine, but pin it.
- `k8sServiceHost: localhost` / `k8sServicePort: 7445` → the real control-plane endpoint (Talos cluster/API VIP or a proper LB). The local values point at the per-node docker haproxy (`cluster/local/nodes/main.tf`) and exist because cilium must reach the API before pod networking exists — a bootstrap chicken-and-egg that doesn't apply on real VMs.
- `cgroup.autoMount.enabled: false` + `hostRoot` → drop; that's a Talos-in-docker container quirk. Use chart defaults on real nodes.
- `gatewayAPI.hostNetwork: true` (+ `k8s-role/work` node match) → normal non-hostNetwork gateway API listeners fronted by a cloud LB. The local form exists to publish LB ports on the docker host.
- `l2announcements` → only if the cloud VMs share an L2 segment; otherwise replace with the LB story above.

Keep as-is (validate under real traffic): wireguard encryption, `ipam.mode: kubernetes`, resource sizing (re-audit — local sizing was tuned for idle test loads, not real traffic).

## Kubescape (removed locally 2026-09-06)
The kubescape operator and all its SecurityExceptions were removed from `manifests/local/` (too heavy for what it delivered; single-purpose hardening tools are the replacement — see `manifests/local/notes.md`). Do **not** reintroduce it in the cloud: the hardening settings it drove (explicit non-root uid/gid, roFS, caps drop, SA-token off) stay in the manifests as NSA-guidance comments, and the accepted-deviations baseline lives in `manifests/local/notes.md` for the replacement tools to audit against.
- Flux polling: the local cluster loosened the bucket to 5m and kustomization drift-heal to 1h for interactive determinism (single operator, frequent manual `sync_wait` + `flux_wait`). Keep the tighter 1m/10m in the cloud — with multiple operators, frequent drift-heal is the enforcement of everything-in-files.

## Tetragon (local: `manifests/local/security/`, adopted 2026-09-07)

Chart 1.7.1 from the same `cilium` HelmRepository as Cilium — no extra source. Carries over as-is: the release values, the PSS-`privileged` `security` namespace, and the `allow-tetragon-security-contexts` PolicyException scoped to the namespace + `tetragon` prefix (the agent DaemonSet is privileged with host paths `/proc`, `/sys/fs/bpf`, `/sys/kernel/tracing` by design; same shapes exist for cilium/node-exporter today).

Cloud deltas:
- **gRPC exposure**: the local cluster binds the tetra gRPC listener to node loopback (`tetragon.grpc.address: localhost:54321`) so `kubectl port-forward` + `tetra --server-address localhost:54321` works with zero node-IP exposure. That's acceptable in the cloud too for admin access through the API server, but if anything needs remote gRPC, enable `tetragon.grpc.tls` (chart supports cert-manager/cronJob methods + client-cert enforcement) — never plain TCP on a node IP.
- **Enforcement TracingPolicies**: observability-first locally; if enforcement policies ship in the cloud, stage them per-namespace (`TracingPolicyNamespaced`) and watch for workload breakage before cluster-wide `TracingPolicy`. Stage-1 observe policies (`security-config/*.tracing-policy.yaml`, all `monitor_only`) carry over as-is; enforcement flips are manifest edits (`spec.options.policy-mode`), never `tetra tp set-mode` (flux is the source of truth). Local kernel findings to re-verify on real nodes: the linuxkit kernel lacks `bpf_lsm_*` BTF symbols so LSM-hook policies are unavailable there (kprobes on the same hooks work) — a cloud Talos kernel likely HAS working BPF-LSM (check `kallsyms | grep bpf_lsm_`), meaning `lsmhooks:` policies are possible there but the local kprobe-based policies still apply unchanged.
- **Log delivery**: tetragon's export-stdout events land in Loki via the alloy pipeline (`loki_query '{instance=~"security/tetragon.*"}'`) — the local ingestion outage (cmdshift/platform#27) is fixed; see the Logging section below for the carry-over landmine.

## Logging (local: `manifests/local/logging/`, alloy+loki adopted 2026-08-30)

Carries over as-is: the alloy DaemonSet + `config.alloy` pipeline (kustomize `alloy-config` ConfigMap → `alloy.configMap` wiring), the loki release (S3 to seaweed `main-s3.objects.svc:8333`, buckets `loki`/`loki-rules`, gateway default tenant `self-monitoring`), and the tenant preset in `loki_query`/`config.alloy`.

Cloud deltas:
- **`alloy.configMap` wiring is load-bearing** — the grafana/alloy chart **silently installs its example config** (pods healthy, nothing pushed, zero errors) if the values block (`create: false` / `name: alloy-config` / `key: config.alloy`) is missing; locally this was the #27 ingestion outage (dropped by an edit that overwrote the block, cmdshift/platform#27). Verify the running config from day one with `alloy_components`: the expected set is `discovery.kubernetes.pods` + `discovery.relabel.k8s_labels` + `loki.source.kubernetes.pods` + `loki.write.endpoint` — `discovery.kubernetes.{nodes,services,endpoints,...}` appearing means the example config is live. (2026-09-07: the intermediate `loki.process.wrap`/`stage.pack` was removed — it wrapped every line in `{"_entry": ...}` while carrying no metadata; keep lines app-native. River comments are `//`, never `#`.)
- **Stream labels**: `namespace`, `pod`, `container`, `node` are promoted by the alloy relabel pipeline (2026-09-07 — the label-pipeline follow-up this note used to wait for LANDED locally; same cardinality as `instance`), plus `instance` (`ns/pod:container`), `job`, `service_name`, `detected_level`. Select natively on the k8s labels; **every line in Loki is JSON** — the alloy pipeline normalizes (JSON pass-through, logfmt→JSON fields, plain-text→`{"msg": raw}`) and the components with knobs log JSON at the source (loki `-log.format=json`, kps `logFormat`s, thanos CR `additionalArgs`, velero `configuration.logFormat`, grafana `GF_LOG_CONSOLE_FORMAT` env — the operator webhook rejects `spec.config.log.console`; kyverno `features.logging.format`; grafana-operator `logging.encoder`; metrics-server `--logging-format=json`; seaweedfs-operator via HelmRelease postRenderers — see `manifests/local/notes.md`). Cilium/cert-manager/local-path/weed have no knob — the pipeline handles them.
- **Seaweed volume-server CPU sizing matters** (2026-09-07 local incident): the volume server CPU-throttled at 93% of CFS periods during vacuum, wedged with all volumes read-only, and seaweed S3 500'd every write for hours (loki couldn't flush chunks; master: `Not enough data nodes found!`). Limit is now 1000m locally — size the cloud volume server (and s3 gateway) with the same generous-CPU convention, and watch the loki bucket's PVC growth: `allowVolumeExpansion: false` makes retention/vacuum the only lever.
- **Loki delete-path tuning is local-only**: `retention_delete_delay: 5m` and `delete_request_cancel_period: 15m` shorten the compactor feedback loop for a test cluster (`# true in the cloud` comments at the values) — keep the upstream defaults (2h / 24h) in the cloud.

## valuesFrom pattern (local rollout 2026-09-07, issue cmdshift/platform#31)

All local HelmReleases now ship values via configMapGenerator → `valuesFrom` (per-dir `kustomization.yaml`, per-entry `disableNameSuffixHash`, values in plain `<release>-values.yaml`). When refactoring `manifests/cloud/`, adopt the same layout — canonical why + conventions in `manifests/local/notes.md` → "valuesFrom everywhere". `helm_verify` already resolves `valuesFrom` refs on both clusters.

## thanos-operator status conditions (local upgrade 2026-09-07, issue cmdshift/platform#22)

Upstream thanos-community/thanos-operator#636 replaced the sticky `ReconcileSuccess`/`ReconcileFailed` pair with a single recoverable `Ready` condition. The cloud cluster inherits the fix automatically (the `GitRepository` pin in the shared `manifests/sources/thanos-operator.git-repository.yaml` — commit and quay image tag must be bumped in lockstep on any future bump). Gate the four thanos CR kinds via `healthCheckExprs` on `monitoring-config` the same way (see `manifests/local/notes.md`); the "trust workloads, not conditions" caveat in older runbooks is dead.
