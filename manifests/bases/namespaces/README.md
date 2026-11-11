# namespaces

The flux-managed Namespace manifests (everything except `flux-system` — owned by the flux2 HelmRelease — and `kube-system` — cluster-owned).

## PSS labels

- `policies` is PSS `privileged` — kyverno's controllers need them (hostNetwork, privileged bits). The labels are **applied by the local overlay patch** (`clusters/local/namespaces/policies-pss-labels.patch.yaml`), not the base — a cloud cluster runs its own kyverno posture and inherits the label-free base (cmdshift/platform#191).
- `security` is PSS `privileged` — the tetragon agent DaemonSet is privileged by design (eBPF, hostNetwork, hostPath `/proc`, `/sys/fs/bpf`, `/sys/kernel/tracing`); the kyverno deviation is scoped by `allow-tetragon-security-contexts` in [security-config](../security-config/README.md).
- `scanning` is kept privileged to match the old security-namespace posture the scan jobs were deployed under: trivy scan pods run non-root 65534 via `scanJobPodTemplate*`, but the chart also renders admission-controller-mutating scaffolding that predates the hardening pass — revisit for `restricted` when the chart's job template is audited end-to-end; kyverno deviations scoped by `allow-trivy-scan-jobs`.
