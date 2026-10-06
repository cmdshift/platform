locals {
  scanner_volume_name = "platform-scanner-cache"
}

resource "random_password" "scan_token" {
  length  = 32
  special = false
}

output "scan_token" {
  value     = random_password.scan_token.result
  sensitive = true
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
  memory      = 768
  memory_swap = 768
  upload {
    file = "/config.toml"
    content = templatefile("${path.module}/templates/config.tftpl.toml", {
      registry_url = var.registry_url
      token        = random_password.scan_token.result
    })
  }
  command = ["-c", "/config.toml", "scanner", "trivy"]
}
