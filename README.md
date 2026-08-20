## Required Binaries

- `just`
- `mkcert`
- `terraform` (`brew tap hashicorp/tap`)
- `packer` (`brew tap hashicorp/tap`)
- `dnsmasq`
- `doppler`

## Trusted Local Certificate

Use the `mkcert` CLI to create and install a custom CA.

```shell
mkcert -install
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

## Initialize the Local Environment

```shell
just init
```
