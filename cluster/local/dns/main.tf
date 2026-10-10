resource "docker_image" "coredns" {
  name          = data.docker_registry_image.coredns.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.coredns.sha256_digest]
}

resource "docker_container" "dns" {
  name     = var.name
  hostname = var.hostname
  image    = docker_image.coredns.name
  command = [
    "-conf",
    "/etc/coredns/Corefile"
  ]
  networks_advanced {
    name = var.net.bridge_network_id
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
    aliases = [
      var.hostname
    ]
  }
  memory      = 256
  memory_swap = 256
  upload {
    file = "/etc/coredns/Corefile"
    content = templatefile("${path.module}/templates/Corefile.tftpl", {
      load_ip_address = var.net.load_ip_address
      cmd_hostname    = var.cmd_hostname
      local_hostname  = var.local_hostname
      cloud_hostname  = var.cloud_hostname
    })
  }
}
