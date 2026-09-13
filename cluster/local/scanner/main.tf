locals {
  scanner_volume_name = "platform-scanner-cache"
}

resource "docker_image" "scanner" {
  name          = data.docker_registry_image.scanner.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.scanner.sha256_digest]
}

resource "null_resource" "scanner_volume" {
  triggers = {
    volume_name = local.scanner_volume_name
  }
  provisioner "local-exec" {
    command = "docker volume create ${local.scanner_volume_name}"
  }
}

resource "docker_container" "scanner" {
  name  = var.name
  image = docker_image.scanner.name
  # trivy downloads its own DB from upstream over the bridge — the private-only
  # ipvlan path's DNS forwarder fails external lookups (cmdshift/platform#102)
  networks_advanced {
    name = var.net.bridge_network_id
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
  }
  volumes {
    container_path = "/cache"
    volume_name    = null_resource.scanner_volume.triggers.volume_name
  }
  # start-then-audit — trivy DB + scan working set (cmdshift/platform#102)
  memory      = 768
  memory_swap = 768
  upload {
    file = "/scanner.toml"
    content = templatefile("${path.module}/templates/scanner.tftpl.toml", {
      registry_url = var.registry_url
      token        = var.token
    })
  }
  command = ["-c", "/scanner.toml", "scanner", "trivy"]
}