## Required Binaries

- `just`
- `talosctl`
- `kubectl`
- `flux` (`brew tap fluxcd/tap`)
- `k9s`
- `direnv`
- `step`
- `terraform` (`brew tap hashicorp/tap`)
- `packer` (`brew tap hashicorp/tap`)
- `dnsmasq` (or other host management)
- `doppler`

## Ensure that `direnv` is working.

Install the `direnv` editor extension and allow the `platform` repository root.

Run the `env` command to confirm that `.envrc` variables have loaded into your editor shell.

## Trusted Local Certificate

Use the `step` CLI to create and install a custom CA.

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

## Cloud Service Emulation

On macOS, enable additional loopback address `127.0.10.1` to support `cloud.test` domains.

```shell
sudo ifconfig lo0 alias 127.0.10.1 up
```

To verify the address is active, use `ifconfig lo0` and confirm that 127.0.10.1 appears in the output.

Configure `dnsmasq` to resolve `.test` and `.cloud.test` to separate loopback addresses.

```conf
# /path/to/dnsmasq.d/test.conf

address=/.test/127.0.0.1
address=/.cloud.test/127.0.10.1

# include fallback servers so your normal DNS works
server=1.1.1.1 # cloudflare
server=8.8.8.8 # google
# additional servers
```

On macOS, `dnsmasq` needs to be started as root.

```shell
sudo brew services start dnsmasq
```

On macOS, we need to point our DNS resolution to `localhost` to start running lookups through `dnsmasq`.

- Open System Preferences
- Network
- Choose your active internet connection (WiFi)
- Click Details...
- Select DNS
- Add 127.0.0.1 to the DNS servers and remove the others

**WARNING**: macOS updates have been known to reset Network settings.

## Initialize the Local Environment

```shell
just init
```

## Build the Cluster

```shell
just cluster apply
```

## Bootstrap Gitops Sync

```shell
just bootstrap apply
```

## Inspect the Cluster

```shell
k9s
```

## Known Issues

### Local Talos Machine Bootstrap

There may be a race condition with node bootup and HAProxy readiness. If cluster creation hangs at `machine_bootstrap` for more than a couple of seconds, destroy and try again. Report if you run into a hanging machine bootstrap locally.
