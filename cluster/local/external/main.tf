resource "docker_image" "haproxy" {
  name          = data.docker_registry_image.haproxy.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.haproxy.sha256_digest]
}

resource "docker_container" "cloud" {
  name     = var.name
  image    = docker_image.haproxy.name
  hostname = var.hostname
  networks_advanced {
    name = var.net.bridge_network_id
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
    aliases = flatten([
      for name, backend in var.services : [
        for _, server in backend : server.hostname
      ]
    ])
  }
  ports {
    internal = 80
    external = 80
    ip       = "127.0.10.1"
  }
  ports {
    internal = 443
    external = 443
    ip       = "127.0.10.1"
  }
  upload {
    file = "/usr/local/etc/haproxy/haproxy.cfg"
    content = templatefile("${path.module}/templates/haproxy.tftpl.cfg", {

    })
  }
  upload {
    file = "/usr/local/etc/haproxy/hosts.map"
    content = templatefile("${path.module}/templates/hosts.tftpl.map", {
      hosts = flatten([
        for service, hosts in var.services : [
          for host in hosts : {
            name       = host.hostname
            private_ip = host.private_ip
          }
        ]
      ])
    })
  }
  upload {
    file = "/usr/local/etc/haproxy/ports.map"
    content = templatefile("${path.module}/templates/ports.tftpl.map", {
      hosts = flatten([
        for service, hosts in var.services : [
          for host in hosts : {
            name = host.hostname
            port = host.port
          }
        ]
      ])
    })
  }
}
