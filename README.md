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

Configure `dnsmasq` to resolve `.test` and `.cloud.test` to separate loopback addresses.

```conf
# /path/to/dnsmasq.d/test.conf

address=/.test/127.0.0.1
address=/.cloud.test/127.0.10.1
```

## Initialize the Local Environment

```shell
just init
```
