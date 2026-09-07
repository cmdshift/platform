---
name: cilium-test
description: Running the full-cluster Cilium connectivity test via cilium_test — temp admission scaffolding (kyverno PolicyException, privileged PSS labels, allow-all CNPs) applied and removed automatically. Use when validating cluster networking or datapath connectivity.
---

# Cilium connectivity test

## Run it

```
cilium_test          # ~5 min with the default suite filter
```

`tools/bin/cilium_test` applies temporary scaffolding, runs the test with a background loop that scaffolds namespaces as they appear mid-run (the ccnp suites create `cilium-test-ccnp*` partway through), and removes everything on exit.

## Why scaffolding is needed (three layers)

Fresh `cilium-test*` namespaces hit all three admission/policy layers. All fixes are **imperative and temporary on purpose** — nothing is committed to `manifests/`:

1. **kyverno** (Deny mode) — test pods ship without requests/limits/seccomp/`runAsNonRoot`; the `host-netns` DaemonSet is hostNetwork. Deployments rejected outright.
2. **PodSecurity** — unlabeled namespaces default to `enforce: baseline`; test pods add `NET_RAW` → `FailedCreate` until the namespace is labeled `privileged`.
3. **Cilium egress default-deny CCNP** — every test pod's egress is dropped; each namespace needs an allow-all CNP.

Failure signatures if a layer changes: creation denied (kyverno), `FailedCreate` PSS violations (PSS), hubble `Policy denied DROPPED` on client→echo flows (default-deny).

## Wrapper defaults (and why)

- `--flow-validation=disabled` — this cluster runs kube-proxy, so service ClusterIPs are DNAT'd before cilium sees them; the resulting `DNS request ... not found` / `SYN ... dst=<service-ip> not found` spam is the *matcher* failing, not the datapath.
- **connectivity suites only** — policy suites (`deny-all`, `*-l7`, `to-fqdns`, ...) deploy their own deny policies whose expectations union with the required allow-all scaffold and can only fail here. Pass explicit `--test ...` to run anything else.
- `check-log-errors` excluded — its only matches are benign on talos-in-docker (missing `CONFIG_INET_DIAG_DESTROY`, `bpf-lb-sock` warning with `kubeProxyReplacement: false`).

## Gotchas

- A failed run leaves artifacts — the next run fails with `serviceaccounts "echo-same-node" already exists`. Clean up before re-running.
- The CLI's `--namespace-labels` doesn't cover mid-run `cilium-test-ccnp*` namespaces — the loop is the reliable mechanism.
- Pods unready anyway? Check admission events first, then hubble:
  ```
  kubectl -n cilium-test-1 get events --sort-by=.lastTimestamp | tail
  kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
  hubble observe --namespace cilium-test-1 --verdict DROPPED
  ```
- Ignore `Warning: would violate PodSecurity "restricted:latest"` lines — warn/audit noise, not a block.

## Full detail

[runbooks/local/cilium-connectivity-test.md](../../../runbooks/local/cilium-connectivity-test.md)
