# Local cluster notes (Talos-in-Docker)

Inventory of settings in this tree that are deliberately local-only — the counterpart of `manifests/cloud/notes.md`, which records what to change for the cloud cluster. In-repo markers (`# true in the cloud`, `# remove in the cloud`) flag these at the value; this file is the list with rationale.

## Cilium — `networking/cilium.helm-release.yaml`

- `kubeProxyReplacement: false` — kube-proxy stays; the cloud runs `true` (marked in-repo)
- `k8sServiceHost: localhost` / `k8sServicePort: 7445` — cilium must reach the API server before pod networking/in-cluster DNS exists; port 7445 is the per-node docker haproxy fronting the control plane (`cluster/local/nodes/main.tf`)
- `cgroup.autoMount.enabled: false` + `hostRoot` — running-inside-a-container quirk
- `gatewayAPI.hostNetwork: true` on `k8s-role/work` nodes — publishes LB ports on the docker host
- `l2announcements` — relies on the docker bridge network being one L2 segment

## Kyverno — `policies/kyverno.helm-release.yaml`, `namespaces/kyverno.namespace.yaml`

- `hostNetwork: true` on all 4 controllers (marked `# remove in the cloud`) — docker host ports; also the cause of the rollout-deadlock landmine (`tools/bin/kyverno_unblock`)
- PSS `privileged` labels on the kyverno namespace (marked `# remove in the cloud`)

## Velero — `backups/velero.helm-release.yaml`

- nodeAgent `privileged: true` — local-only ("remove in the cloud" comments in the file); node snapshots against docker volumes

## PolicyExceptions — `policies-config/`

Scoped exceptions covering Talos-in-docker workloads (hostNetwork kyverno, privileged velero/cilium, alloy host-logs, local-path helper pod, node-exporter). Each needs a keep/drop decision for the cloud — don't blanket-copy the directory.

## Kubescape NSA audit (2026-09-05) — accepted findings

Scan via `tools/bin/nsa_scan`. Baseline moved 80 → **84.8**, with **zero findings outside kube-system** — every app-namespace acceptance ships as a `SecurityException`/`ClusterSecurityException` resource (`policies-config/*.security-exception.yaml`, applied by flux; kubescape reads them at scan time). The remaining findings are kube-system system components (Talos statics, CNI, coredns, kube-proxy — not manifest-owned) plus kubernetes' own default `system:*` RBAC bindings. Details:

- **thanos CR-managed pods (query/compact/store/ruler)** — the `monitoring.thanos.io` CRDs expose no `automountServiceAccountToken` and no per-container securityContext, so C-0034 (automount) and C-0017 (roFS) stay open for them. Disabling automount via SA manifests was tried and **the operator recreates the SAs on every reconcile**, reverting the field — don't fight it.
- **thanos-ruler config-reloader** — operator-injected, no resource/securityContext knobs (existing PolicyException, ~18Mi).
- **seaweed `main-master`** — no roFS (C-0017): the CR has no persistence knob for master and it writes its wal/segment files to `/data` on the container's root fs. filer/volume/s3 got roFS; filer and s3 keep a writable `/tmp` emptyDir (filer's gRPC socket, s3 temp files live there).
- **velero deployment** — the chart only exposes `securityContext` at POD level and renders it into its CRD-upgrade hook jobs too, where `allowPrivilegeEscalation` is not a legal pod field (SSA rejects it, helm upgrade fails — hit live). Its pod-level `runAsUser: 0` default is deliberate (the node-agent needs root), so container-level readOnlyRootFilesystem / caps dropping is not reachable via values; only the aws-plugin initContainer is container-hardened.
- **flux/kyverno/external-secrets/grafana-operator/thanos CRs** — kubescape's C-0013 rule requires explicit **container-level `runAsGroup`** (and ignores pod-level); charts/CRDs that can't express it are exceptioned. Where the chart allowed it, explicit uid/gid is now set (cert-manager/eso/flux/lpp/ksm/grafana-op/seaweedfs-op — kills the implicit-gid-0 hole too).
- **loki / alloy keep their SA tokens** (C-0034 accepted): loki's rules sidecar watches ConfigMaps via the API, alloy's `discovery.kubernetes` uses in-cluster config. Alloy also still runs as root (image declares no USER — covered by its PolicyException for the host-log mounts).

Audit-session learnings worth keeping:

- **thanos ruler non-root retrofit** needed `runAsUser: 65534` (numeric) at pod level, not just `runAsNonRoot: true`: the config-reloader image declares `USER "nobody"`, which kubelet can't verify against a bare `runAsNonRoot`. The PVC then needed a one-time `chown 65534` (helper pod pattern, same as seaweedfs) — the wal was root-owned from pre-hardening runs.
- **kyverno hostNetwork rollouts**: `kyverno_unblock` now deletes all old-generation pods in a single kubectl call — piecemeal deletion loses the race (the deployment controller recreates old-gen pods that re-grab freed ports; observed twice live).
- **kubescape C-0013** is really "explicit container-level runAsNonRoot **and runAsGroup**" — pod-level (or uid alone) doesn't satisfy it; the `fixPath` in the JSON output names the missing field.
- **flux2 chart securityContext REPLACES, not merges**: its templates hardcode container-sc defaults behind an if/else, so setting any value (e.g. just `runAsGroup`) silently drops APE/caps/roFS — spell out the full map (hit live; note in flux.helm-release.yaml).
- **kubescape CLI `--exceptions` silently no-ops on 4.0.13** (malformed or nonexistent files aren't even an error) — use the in-cluster `SecurityException` CRDs, which the CLI reads automatically and which fit the GitOps model. The CRDs are vendored in `crds/`.
- **kubescape score is severity-weighted over scanned resources**: excluding kube-system can LOWER the score (strips passing weight). `nsa_scan full` is the headline; `nsa_scan apps` is the prod-style app-namespace view despite its lower number.

## Out-of-cluster companions (`*.cloud.test`)

rustfs S3, secrets server, haproxy, mailpit, sync container — terraform/docker in `cluster/local/external`; none of this exists in the cloud, so the CNP `toFQDNs` rules (`networking-config/*.cilium-network-policy.yaml`), the Bucket endpoint (`flux-config/main.bucket.yaml`), the ClusterSecretStore URL, alertmanager's mailpit smarthost, and velero's BSL `s3Url` all resolve differently there.
