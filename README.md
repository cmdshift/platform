# platform

A local Kubernetes platform testbed: Talos nodes running in Docker, provisioned with terraform (`cluster/local`), and deployed entirely by Flux v2 from the manifests in `manifests/local/`. Out-of-cluster companions (S3, secrets server, alert delivery) emulate the cloud services a production deployment would use.

## Prerequisites

### Required binaries

- `cilium`
- `direnv`
- `dnsmasq` (or other local DNS management — see [Cloud service emulation](#cloud-service-emulation-the-test-domains))
- `docker` (Docker Desktop or equivalent — runs the cluster and companions)
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
- `yq` (manifest lint — see `AGENTS.md`)

### direnv

Install the `direnv` editor extension and allow the `platform` repository root. Run `env` to confirm that `.envrc` variables have loaded into your shell — `tools/bin` should be on your `PATH`.

### Trusted local certificate

Use the `step` CLI to create and install a custom CA:

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

The companion services resolve under `*.cloud.test` (S3, secrets server, mailpit). Two things make that work: a second loopback address (`127.0.10.1`), and a local resolver that maps `*.test` → `127.0.0.1` and `*.cloud.test` → `127.0.10.1`.

### macOS

Enable the additional loopback address:

```shell
sudo ifconfig lo0 alias 127.0.10.1 up
```

To verify the address is active, use `ifconfig lo0` and confirm that `127.0.10.1` appears in the output.

Configure `dnsmasq`:

```conf
# /opt/homebrew/etc/dnsmasq.d/test.conf   (Intel brew: /usr/local/etc/dnsmasq.d/test.conf)

address=/.test/127.0.0.1
address=/.cloud.test/127.0.10.1

# include fallback servers so your normal DNS works
server=1.1.1.1 # cloudflare
server=8.8.8.8 # google
# additional servers
```

On macOS, `dnsmasq` needs to be started as root:

```shell
sudo brew services start dnsmasq
```

Point macOS DNS resolution at `localhost`:

- Open System Preferences → Network
- Choose your active internet connection (WiFi)
- Click Details... → DNS
- Add `127.0.0.1` to the DNS servers and remove the others

Verify: `dscacheutil -q host -a name s3.cloud.test` should return `127.0.10.1`.

**WARNING**: macOS updates have been known to reset Network settings.

### Linux

No loopback alias needed — the entire `127.0.0.0/8` block routes to `lo` by default. Verify with `ping -c1 127.0.10.1`.

Install `dnsmasq` with your package manager (`apt install dnsmasq`, `dnf install dnsmasq`, ...) and use the same config as macOS at `/etc/dnsmasq.d/test.conf`.

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

Verify: `dig +short s3.cloud.test` should return `127.0.10.1`.

### Windows

No loopback alias needed — the whole `127/8` block is loopback-reachable natively.

Windows has no local DNS proxy built in; pick one:

**Quick path — hosts entries** for the known companion endpoints (`C:\Windows\System32\drivers\etc\hosts`, edited as administrator):

```
127.0.10.1 s3.cloud.test secrets.cloud.test mail.cloud.test
```

Caveat: the hosts file supports no wildcards — new `*.cloud.test` companions need new entries.

**Full path — Acrylic DNS Proxy**: install [Acrylic](https://mayakron.altervista.org/support/acrylic/Home.htm), append to `AcrylicHosts.txt`:

```
*.test        127.0.0.1
*.cloud.test  127.0.10.1
```

Restart the Acrylic service, then point your network adapter's DNS at `127.0.0.1`:

```powershell
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses 127.0.0.1
```

Verify: `Resolve-DnsName s3.cloud.test` should return `127.0.10.1` (if it returns `127.0.0.1`, check the more-specific `*.cloud.test` entry is present). Acrylic forwards everything else to your normal DNS.

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

Expect roughly **10 minutes** of one-shot convergence — no manual intervention. Watch it with `kubectl -n flux-system get kustomizations`; the full verification checklist (25 kustomizations, 15 HelmReleases, velero BSL, ...) is in `runbooks/local/cluster-rebuild.md`.

Inspect the cluster:

```shell
k9s
```

## Agentic DevOps

This repository is built to be operated by coding agents as much as by humans. The knowledge lives in four layers, thinnest first:

- **`AGENTS.md`** — always-loaded agent instructions: architecture, conventions, landmines, and the pre-commit docs-maintenance gate. Start there regardless of species.
- **`.agents/skills/`** — on-demand agent skills in the open agent-skills format (`.agents/skills/<name>/SKILL.md`), loaded via the `skill` tool by agents such as OpenCode. One skill per procedure: the manifest-change loop (`platform-workflow`), incident triage (`reconcile-stuck`, `pipeline-wedged`, `helmrelease-stuck`, `crashloop-investigation`), and operations (`add-workload`, `adopt-chart`, `resource-sizing`, `velero-ops`, `rustfs-ops`, `cilium-test`, `cluster-rebuild`, `observability`).
- **`runbooks/local/`** — human-readable procedures with worked examples. Every skill links out to its matching runbook; read the runbook when you want the full story.
- **`tools/bin/`** — helper scripts for the repeated plumbing (reconcile waits, resource audits, admission reports, observability queries). On your `PATH` via `direnv`; full reference in `tools/bin/README.md`.

Same body of knowledge, two entry points: humans read the runbooks, agents load the skills.

## Known Issues

### Local Talos Machine Bootstrap

There may be a race condition with node bootup and HAProxy readiness. If cluster creation hangs at `machine_bootstrap` for more than a couple of seconds, destroy and try again. Report if you run into a hanging machine bootstrap locally.
