resource "docker_image" "haproxy" {
  name          = data.docker_registry_image.haproxy.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.haproxy.sha256_digest]
}

resource "docker_container" "load" {
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
      for name, backend in var.hosts : [
        for _, server in backend : server.hostname
      ]
    ])
  }
  ports {
    internal = local.ports.http
    external = local.ports.http
    ip       = "127.0.0.1"
  }
  ports {
    internal = local.ports.https
    external = local.ports.https
    ip       = "127.0.0.1"
  }
  ports {
    internal = local.ports.k8s
    external = local.ports.k8s
    ip       = "127.0.0.1"
  }
  ports {
    internal = local.ports.apid
    external = local.ports.apid
    ip       = "127.0.0.1"
  }
  memory      = 512
  memory_swap = 512
  upload {
    file    = "/usr/local/etc/haproxy/cloud.pem"
    content = data.local_sensitive_file.cloud_pem.content
  }
  upload {
    file = "/usr/local/etc/haproxy/haproxy.cfg"
    content = templatefile("${path.module}/templates/haproxy.tftpl.cfg", {
      local_hostname = var.local_hostname
      cloud_hostname = var.cloud_hostname
      internal_ip    = var.net.private_ip
      smtp = flatten([
        for container_name, services in var.hosts : [
          for name, service in services : {
            name       = container_name
            private_ip = service.private_ip
          }
          if can(regex("^smtp", name))
        ]
      ])
      ctrl = var.ctrl
      work = var.work
    })
  }
  upload {
    file = "/usr/local/etc/haproxy/hosts.map"
    content = templatefile("${path.module}/templates/hosts.tftpl.map", {
      hosts = flatten([
        for _, services in var.hosts : [
          for name, service in services : {
            name       = service.hostname
            private_ip = service.private_ip
          }
          if !can(regex("^smtp", name))
        ]
      ])
    })
  }
  upload {
    file = "/usr/local/etc/haproxy/ports.map"
    content = templatefile("${path.module}/templates/ports.tftpl.map", {
      hosts = flatten([
        for _, services in var.hosts : [
          for name, service in services : {
            name = service.hostname
            port = service.port
          }
          if !can(regex("^smtp", name))
        ]
      ])
    })
  }
}
