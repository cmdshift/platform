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
  network_mode = "bridge"
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
  upload {
    file = "/etc/coredns/Corefile"
    content = templatefile("${path.module}/templates/Corefile.tftpl", {
      external_hostname = var.net.external_hostname
      internal_hostname = var.net.internal_hostname
    })
  }
  upload {
    file = "/etc/coredns/zones/cloud.zone"
    content = templatefile("${path.module}/templates/cloud.tftpl.zone", {
      hostname            = var.hostname
      external_hostname   = var.net.external_hostname
      external_ip_address = var.net.external_ip_address
    })
  }
}