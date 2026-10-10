# platform

A local Kubernetes platform testbed: Talos nodes running in Docker, provisioned with terraform (`cluster/local`), and deployed entirely by Flux v2 from the manifests in `manifests/local/`. Out-of-cluster companions (S3, secrets server, alert delivery) emulate the cloud services a production deployment would use. Supported hosts: **Linux with Docker Engine** (tested on Arch — the cluster runs natively on the host kernel) and **macOS** — [OrbStack](https://orbstack.dev) recommended (lower resource consumption and better stability than Docker Desktop, cmdshift/platform#192); Docker Desktop remains supported. Docker Desktop's port publisher adds a stale-binding failure class (see [Known Issues](#known-issues)).

## Prerequisites

### Required binaries

The tested binary list is installable in one shot via Homebrew (also available through most Linux package managers — on Linux, substitute `dnsmasq`/`docker` with the distro packages where the casks differ):

```shell
brew bundle --file=tools/Brewfile
```

The list (without `dnsmasq`, which is host-specific — see below):

- `cilium`
- `direnv`
- `dnsmasq` (or other local DNS management — see [Cloud service emulation](#cloud-service-emulation-the-test-domains))
- `docker` (tested with Docker Engine 29.7.2 — runs the cluster and companions)
- `doppler`
- `flux` (`brew tap fluxcd/tap`)
- `helm`
- `jq`
- `just`
- `k9s`
- `kubectl`
- `packer` (`brew tap hashicorp/tap`)
- `step`
- `talosctl`
- `terraform` (`brew tap hashicorp/tap`)
- `velero` (backup operations — see `runbooks/local/velero-backups.md`)
- `yq` (manifest lint — used by `tools/bin/yaml_lint`)

### direnv

Install the `direnv` editor extension and allow the `platform` repository root. Run `env` to confirm that `.envrc` variables have loaded into your shell — `tools/bin` should be on your `PATH`.

### Trusted local certificate

Provision the root CA on the host with the `step` CLI (`.envrc` sets `STEPPATH=cluster/local/.temp/tls`; the intermediate CA and `*.cloud.test` wildcard leaf are terraform-managed by `cluster/local/certs/` — cmdshift/platform#192):

```shell
step certificate create "platform" $STEPPATH/root_ca.crt $STEPPATH/root_ca.key \
  --profile root-ca \
  --not-after 8760h \
  --kty RSA \
  --size 4096 \
  --no-password \
  --insecure

step certificate install --all $STEPPATH/root_ca.crt
```

## Cloud service emulation: the `.test` domains

The companion services resolve under `*.cloud.test` (S3, secrets server, mailpit). The unified haproxy load balancer publishes `:80`/`:443`/`:6443`/`:50000` on host loopback `127.0.0.1`, and a local resolver maps `*.test` → `127.0.0.1` (host dnsmasq; inside the cluster, coredns maps the same names to the LB's private IP). On all supported platforms the whole `127/8` block is loopback-reachable; `ping -c1 127.0.10.1` is a harmless sanity check.

### macOS

Install `dnsmasq` via Homebrew (`brew install dnsmasq`) with this config at `$(brew --prefix)/etc/dnsmasq.conf`:

```conf
address=/.test/127.0.0.1

# include fallback servers so your normal DNS works
server=1.1.1.1 # cloudflare
server=8.8.8.8 # google
# additional servers
```

Start it and point the system resolver at it (macOS resolver picks up `/etc/resolver` automatically — no port-53 conflict dance like systemd-resolved):

```shell
brew services start dnsmasq
sudo mkdir -p /etc/resolver
printf 'nameserver 127.0.0.1\n' | sudo tee /etc/resolver/test
```

Verify: `dig +short s3.cloud.test` and `scutil --dns | grep 127.0.0.1` (dig queries dnsmasq directly; apps use the resolver entry).

### Linux

Tested on Arch (Docker Engine 29.7.2) — the cluster runs natively on the host kernel. Verify the loopback block with `ping -c1 127.0.10.1`.

Install `dnsmasq` with your package manager (`apt install dnsmasq`, `dnf install dnsmasq`, ...) with this config at `/etc/dnsmasq.d/test.conf`:

```conf
address=/.test/127.0.0.1

# include fallback servers so your normal DNS works
server=1.1.1.1 # cloudflare
server=8.8.8.8 # google
# additional servers
```

If `systemd-resolved` is running (default on Ubuntu), it holds port 53 — disable its stub listener first:

```shell
# /etc/systemd/resolved.conf: DNSStubListener=no
sudo systemctl restart systemd-resolved
```

Then point the system resolver at `dnsmasq` and start it:

```shell
printf 'nameserver 127.0.0.1\n' | sudo tee /etc/resolv.conf
sudo systemctl enable --now dnsmasq
```

Verify: `dig +short s3.cloud.test` should return `127.0.0.1`.

### Windows

Windows has no local DNS proxy built in; pick one:

**Quick path — hosts entries** for the known companion endpoints (`C:\Windows\System32\drivers\etc\hosts`, edited as administrator):

```
127.0.0.1 s3.cloud.test secrets.cloud.test mail.cloud.test
```

Caveat: the hosts file supports no wildcards — new `*.cloud.test` companions need new entries.

**Full path — Acrylic DNS Proxy**: install [Acrylic](https://mayakron.altervista.org/support/acrylic/Home.htm), append to `AcrylicHosts.txt`:

```
*.test        127.0.0.1
```

Restart the Acrylic service, then point your network adapter's DNS at `127.0.0.1`:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses 127.0.0.1
```

Verify: `Resolve-DnsName s3.cloud.test` should return `127.0.0.1` (if it fails, check the `*.test` entry is present). Acrylic forwards everything else to your normal DNS.

## Getting started

```shell
just init
```

Build the cluster (docker network, companions, Talos nodes, kubeconfig):

```shell
just cluster apply
```

Bootstrap the GitOps sync (cilium + flux + the pipeline's own Bucket/root objects):

```shell
just bootstrap apply
```

Expect roughly **10 minutes** of one-shot convergence — no manual intervention. Watch it with `kubectl -n flux-system get kustomizations`; the full verification checklist and topology map (`cluster/local/ARCHITECTURE.md`) are in `runbooks/local/cluster-rebuild.md`.

Inspect the cluster:

```shell
k9s
```

## Agentic DevOps

This repository is built to be operated by coding agents as much as by humans. The knowledge lives in four layers, thinnest first:

- **`AGENTS.md`** — always-loaded agent instructions: conventions (Do/Don't), the docs map, and the pre-commit docs-maintenance gate. Landmines live one layer down, in the README nearest the thing they describe. Start there regardless of species.
- **`.agents/skills/`** — on-demand agent skills in the open agent-skills format (`.agents/skills/<name>/SKILL.md`), loaded via the `skill` tool by agents such as OpenCode. One skill per procedure: the manifest-change loop (`platform-workflow`), incident triage (`reconcile-stuck`, `pipeline-wedged`, `helmrelease-stuck`, `crashloop-investigation`), and operations (`add-workload`, `adopt-chart`, `resource-sizing`, `velero-ops`, `rustfs-ops`, `cilium-test`, `cluster-rebuild`, `observability`).
- **`runbooks/local/`** — human-readable procedures with worked examples. Every skill links out to its matching runbook; read the runbook when you want the full story.
- **`tools/bin/`** — helper scripts for the repeated plumbing (reconcile waits, resource audits, admission reports, observability queries). On your `PATH` via `direnv`; full reference in `tools/bin/README.md`.

Same body of knowledge, two entry points: humans read the runbooks, agents load the skills.

## Known Issues

### Local Talos Machine Bootstrap hang

`talos_machine_bootstrap` can hang when the host port binding for the cluster endpoint (the unified `load` haproxy companion, ports 6443/50000 among others, host loopback only) goes stale after rapid container churn (destroy → recreate within ~a minute): the host listener still accepts connections but black-holes them. The provider fails fast (10s timeouts) rather than silently retrying for 10 minutes; the fix is `docker restart $(docker ps -q --filter name=cloud-test)` (an LB restart — the ctrl nodes keep running) followed by a re-apply. First root-caused on the historical macOS/Docker Desktop host (its VM port publisher was the black-hole; OrbStack is the recommended macOS host now); full root cause and diagnostics: [runbooks/local/cluster-rebuild.md](runbooks/local/cluster-rebuild.md).
