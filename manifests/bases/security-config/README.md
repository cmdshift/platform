# security-config

TracingPolicies + the namespace ResourceQuota for the [security](../security/README.md) group. The deep trap narratives (flip mechanics, probe ritual, kill-event visibility, kernel intel) live in the [security README](../security/README.md) — this README carries the per-policy scope table that used to be header comments on each file.

## ResourceQuota

`ResourceQuota/compute` (namespace `security`): limits.cpu 12 sits above the tetragon daemons' 8-CPU limits sum so one rollout overlap doesn't block (daemon bursts dominate; cmdshift/platform#93). trivy moved to `scanning/` — this quota is tetragon-only now.

## TracingPolicy table (policy | namespace target | scoping label | why it exists)

| policy | target | scoping label (selector ANDs — sibling policies for disjoint sets) | why |
|---|---|---|---|
| `exec-inventory` | cluster-wide, all pods (`matchLabels: {}`) | none — the unfiltered stream is the point | phase 3 (#60): exec inventory, no binary filter — the evidence base for phase-4 deny-list widening (allowlist-by-absence); monitor_only; enforcement is per-namespace in the exec-deny-list-* policies |
| `kernel-modules` | cluster-wide | — | stage-2 flip 1, **enforce** (#28): Override(EACCES) on auto-load requests (every Go runtime probes missing modules), Sigkill on real loads; burn-in: 327 events/~6h, all benign |
| `sensitive-host-paths` | cluster-wide, pod-ns filtered | — | file-integrity **enforcement** on `/var/lib/etcd` + `/run/containerd/containerd.sock` (#60 phase 5); 7-day monitor burn-in was EMPTY (paths touched only by host-ns processes) — arms a policy that cannot fire from flux-managed workloads; defense-in-depth. Override(EACCES), not Sigkill (would kill interpreters mid-open) |
| `privileges-raise` | cluster-wide, pod-ns filtered | — | pod-side privilege-escalation attempts (setuid/setgid/capset/userns), adapted from the tetragon policylibrary; monitor_only; needs `enableProcessCred`; **policy-level podSelector required** — the per-hook Pid NotIn host_ns filter let runc through live |
| `bpf-activity` | cluster-wide | — | audit of BPF subsystem interactions (program loads, perf_event, bpffs, map creation); monitor_only; expected actors cilium + tetragon only; `security_bpf_map_alloc` needs `ignore.callNotFound` (renamed in Linux 6.9 — verified in kallsyms) |
| `exec-deny-list-flux-system` | flux-system | pod `app` label (add future flux controllers to the list or they're out of scope) | stage-2 flip 2, **enforce** (#28) — the anchor policy for the sibling deny-lists |
| `exec-deny-list-policies` | policies | chart's release instance label (unique cluster-wide) | stage-2 flip 2 sibling (#28) |
| `exec-deny-list-secrets` | secrets | chart's release instance label | stage-2 flip 2 sibling (#28) |
| `exec-deny-list-access` | access (oauth2-proxy) | chart's release instance label | phase-4 wave 1 (#60) |
| `exec-deny-list-certificates` | certificates (cert-manager) | chart's release instance label | phase-4 wave 1 (#60) |
| `exec-deny-list-datastores` | datastores (cnpg, emqx, valkey operators) | charts' release instance labels | phase-4 wave 1 (#60) |
| `exec-deny-list-security` | security (tetragon agent + operator) | chart's release instance labels | phase-4 wave 1 (#60); trivy moved to scanning/ |
| `exec-deny-list-observability` | observability (openobserve) | release instance label — future release workloads must be added to the values list | phase-4 wave 1 (#60) |
| `exec-deny-list-backups` | backups (velero controller + node-agent DS) | release instance label | phase-4 wave 1 (#60); split from its siblings because k8s LabelSelectors AND their terms — a pod can't match "velero OR kopia-job OR talos-backup" in one selector |
| `exec-deny-list-backups-jobs` | backups, kopia repo-maintenance Jobs | `velero.io/repo-name` only (no instance label — velero generates them) | phase-4 wave 1 (#60); separate policy for the AND-terms reason above |
| `exec-deny-list-backups-talos` | backups, talos-backup cronjob | standalone label set | phase-4 wave 1 (#60); separate policy for the AND-terms reason above |
| `exec-deny-list-scanning` | scanning (trivy-operator, trivy-server) | charts' release instance labels | phase-4 wave 1 (#60); trivy moved out of security/ so tetragon bootstraps early (rebuild ordering). Scan Jobs exec `/bin/sh -c` legitimately but carry only `managed-by=trivy-operator` (no instance label), so they're out of scope here — the kyverno backstop carries the matching PolicyException |
| `exec-deny-list-storage` | storage (local-path-provisioner) | chart's release instance label | phase-4 wave 1 (#60). The on-demand helper pods exec `/bin/sh /script/setup` legitimately and carry the same instance label (inherited from the helperPod template) — the selector can't scope them out, so `allow-local-path-helper-pod` covers the admission layer and the helper's shell exec is accepted collateral here ([storage/README.md](../storage/README.md)); unscoped execs (debug shells) are still killed |

Enforcement/monitor status and flip history: [security README](../security/README.md). `kube-system` and `objects` are excluded from the deny-list set (host-ns statics; seaweed's hardcoded `/bin/sh -ec` entrypoint — the CRD has no command override).
