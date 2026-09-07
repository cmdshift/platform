# Running `cilium connectivity test`

Full-cluster Cilium datapath validation: deploys client/echo test pods and exercises pod-to-pod (same + cross-node), services, DNS, NodePorts, host-netns paths, and wireguard encryption. ~5 min with the default suite filter (see Notes for what's excluded on this cluster and why).

## Easy path

```
cilium_test
```

`tools/bin/cilium_test` applies the scaffolding below, runs the test with a background loop that scaffolds namespaces as the CLI creates them mid-run (the ccnp suites create `cilium-test-ccnp*` namespaces partway through), and removes everything on exit.

## Why the test needs scaffolding (three layers)

Fresh `cilium-test*` namespaces hit all three admission/policy layers of this cluster. All three fixes are **imperative and temporary on purpose** — nothing is committed to `manifests/`, so the cluster's policy posture stays minimal. If a future layer changes (e.g. kyverno policies renamed), the failure looks like: pod/deployment creation denied (kyverno), pods stuck with `FailedCreate` PSS violations, or hubble shows `Policy denied DROPPED` on every client→echo flow (default-deny).

1. **kyverno** (11 ValidatingPolicies, Deny mode) — test pods ship without requests/limits, seccomp, `runAsNonRoot`; the `host-netns` DaemonSet is hostNetwork. `deploy` creation is rejected outright.
2. **PodSecurity** — the apiserver defaults unlabeled namespaces to `enforce: baseline` (Talos `admission-control-config.yaml`, only kube-system exempted). The test pods add `NET_RAW`, so pods sit in `FailedCreate` until the namespace is labeled privileged. This is the same reason namespaces like velero/local-path-storage carry explicit `privileged` labels in `manifests/local/namespaces/`.
3. **Cilium `default-deny` CCNP** (`networking-config/default-deny.cilium-clusterwide-network-policy.yaml`) — cluster-wide **egress** default-deny, kube-system exempt. Every test pod's egress is dropped (hubble: `Policy denied DROPPED` on each SYN); only DNS to kube-dns is allowed. Per-namespace CNPs carve out the workloads' needs — the test namespaces need their own.

## Manual procedure

### 1. Temporary kyverno PolicyException

```bash
kubectl -n kyverno apply -f - <<'EOF'
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: allow-cilium-connectivity-test
  namespace: kyverno
spec:
  policyRefs:
    - name: disallow-capabilities-strict
      kind: ValidatingPolicy
    - name: disallow-host-namespaces
      kind: ValidatingPolicy
    - name: disallow-privilege-escalation
      kind: ValidatingPolicy
    - name: require-resource-limits
      kind: ValidatingPolicy
    - name: require-run-as-nonroot
      kind: ValidatingPolicy
    - name: restrict-seccomp-strict
      kind: ValidatingPolicy
  matchConditions:
    - name: match-cilium-test-namespace
      expression: "object.metadata.namespace.startsWith('cilium-test')"
EOF
```

### 2. Run the test with the scaffolder loop

The loop must run while the test does — namespaces appear on the fly:

```bash
scaffold() {
  kubectl get namespaces -o name | grep -E '^namespace/cilium-test' | cut -d/ -f2 | while read -r ns; do
    # PSS: privileged label (baseline default would deny NET_RAW)
    kubectl label ns "$ns" --overwrite \
      pod-security.kubernetes.io/enforce=privileged \
      pod-security.kubernetes.io/warn=privileged \
      pod-security.kubernetes.io/audit=privileged >/dev/null
    # Cilium: allow-all CNP against the cluster-wide egress default-deny
    kubectl -n "$ns" apply -f - <<EOF >/dev/null
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-all
  namespace: $ns
spec:
  endpointSelector: {}
  ingress:
    - fromEntities: [all]
  egress:
    - toEntities: [all]
EOF
  done
}

# --flow-validation=disabled: kube-proxy DNATs service IPs before cilium sees
# them, so hubble can't match what the CLI searches for (see Notes)
cilium connectivity test --flow-validation=disabled &
TEST_PID=$!
while kill -0 "$TEST_PID" 2>/dev/null; do scaffold; sleep 2; done
wait $TEST_PID
```

### 3. Clean up (delete when done)

```bash
kubectl -n kyverno delete policyexception allow-cilium-connectivity-test
kubectl get ns -o name | grep -E '^namespace/cilium-test' | cut -d/ -f2 | xargs kubectl delete ns --wait=false
```

Deleting the namespaces removes the CNPs and PSS labels with them. `cilium connectivity test --cleanup` is the CLI's own alternative for step 3.

## Notes

- **Run with `--flow-validation=disabled`** (the wrapper adds it automatically). This cluster runs kube-proxy (`kubeProxyReplacement: false`), so service ClusterIPs are DNAT'd before packets reach cilium — hubble never sees the service IP the CLI's flow matcher searches for — and monitor aggregation hides DNS flows. The resulting `DNS request ... not found` / `SYN ... dst=<service-ip> not found` spam is the *matcher* failing, not the datapath; the curls themselves complete (full handshakes in the flow dumps below the errors).
- **The wrapper defaults to the connectivity suites only** (`no-policies`, `health`, `host-entity-*`, `pod-to-pod-*`, `node-to-node-encryption`, `no-unexpected-packet-drops`, ...). The policy suites (`deny-all`, `*-l7`, `tls-sni`, `to-fqdns`, `to-cidr-*`, the `ccnp` namespaces) deploy their own deny policies and verify enforcement — on this cluster they can only fail, because the allow-all scaffold (required by the cluster's egress default-deny CCNP) unions with their policies and defeats every deny expectation. The policy engine is exercised for real by the workload CNPs day-to-day. Pass an explicit `--test ...` to run anything else.
- **`check-log-errors` is excluded** because its only matches are benign on talos-in-docker: the docker-host kernel lacks `CONFIG_INET_DIAG_DESTROY` (socket-termination on backend deletion degrades gracefully), and the `bpf-lb-sock` warning is expected with `kubeProxyReplacement: false`. Both appear at bootstrap, once.
- A failed run leaves artifacts behind — the next run then fails with `serviceaccounts "echo-same-node" already exists`. Clean up (step 3) before re-running (the wrapper waits out deleting namespaces automatically).
- The CLI's `--namespace-labels` flag can pre-label the main test namespace, but it does not cover the mid-run `cilium-test-ccnp*` namespaces — the loop is the reliable mechanism.
- Ignore the `Warning: would violate PodSecurity "restricted:latest"` lines during deployment: that's warn/audit-level noise (namespace is privileged-labeled), not a block.
- If pods sit unready anyway, check admission first (`kubectl -n cilium-test-1 get events --sort-by=.lastTimestamp | tail`), then hubble for policy drops:
  ```
  kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
  hubble observe --namespace cilium-test-1 --verdict DROPPED
  ```

---

*Agent entry point: the `cilium-test` skill in `.agents/skills/cilium-test/`.*