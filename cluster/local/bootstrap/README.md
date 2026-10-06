# bootstrap

The second terraform root (`just bootstrap apply`): it installs the two things that must exist before flux can take over — cilium and flux itself — plus the fresh-install twins of the Bucket + root Kustomization that the pipeline's own `flux-config` group force-adopts on its first reconcile. Cluster (re)builds are a two-root sequence: `just cluster apply` (nodes, companions, kubeconfig) → `just bootstrap apply`. Readiness is self-gated: the apply blocks on a kube-apiserver readiness poll (`data.http.kube_apiserver` — nodes Ready ≠ API serving; the first 401 response means it's up), so no manual wait between the two applies.

## One-way by design

Every resource carries `lifecycle { prevent_destroy = true }`. Bootstrapping a cluster is a one-way operation — destroying the bootstrap state would orphan the live flux/cilium releases that the reconciled tree now owns. `just bootstrap destroy` always fails by intent; a rebuild destroys the cluster root underneath and re-applies bootstrap onto the fresh cluster.

## Cilium

The helm release here is the **minimal boot twin** of the full HelmRelease that flux later adopts from `manifests/bases/networking/`: the bootstrap boots with no L7 consumers (no envoy DaemonSet), and hubble relay/UI stay **disabled** — they are enabled by cilium's flux-managed install, which converges on the first reconcile and takes ownership of the live release. The `cilium_chart_version` variable must match the HelmRelease chart pin or adoption drifts the live release.

## Flux "installing itself"

1. The `flux2` helm release installs the controllers into `flux-system`, with `wait_for_jobs` so the post-install hooks complete before terraform exits.
2. The release's `extraObjects` (helm `post-install` hooks) create the **Bucket** source (`main`, pointing at the rustfs flux bucket with the bucket credentials secret) and the **root Kustomization** (`local`, path `./manifests/clusters/local`) — the objects flux needs to start reconciling, created by flux's own installer.
3. The root Kustomization reconciles `manifests/clusters/local`, whose `flux-config` group declares the same Bucket + root Kustomization — the first reconcile force-adopts the helm-created twins (kustomize-controller takes over their spec), and the bootstrap objects become redundant-but-harmless twins. **Never delete the on-cluster Bucket/Kustomization** — the tree reconciles from them.

The twin's `path` (`./manifests/clusters/local`) must match the root Kustomization CR's `spec.path` in `manifests/clusters/local/flux-config/` — they move together on any tree restructure.

## Inputs

- `flux_chart_version` — the flux2 chart pin.
- `cilium_chart_version` — the cilium chart pin; keep in lockstep with the networking HelmRelease.

State input: `data.terraform_remote_state.main` reads the cluster root's `bootstrap` output (kube client config + flux bucket credentials) from the sibling `terraform.tfstate`.
