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

resource "docker_image" "trivy" {
  name          = data.docker_registry_image.trivy.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.trivy.sha256_digest]
}

resource "null_resource" "scanner_volume" {
  triggers = {
    volume_name = local.scanner_volume_name
  }
  provisioner "local-exec" {
    command = "docker volume create ${local.scanner_volume_name}"
  }
}

locals {
  scanner_engine_volume_name = "platform-scanner-engine"
}

# trivy is exec'd by `angos scanner trivy` from PATH; image mounts aren't expressible
# via kreuzwerker, so the engine binary is provisioned into a volume once per pin bump
resource "null_resource" "scanner_engine" {
  triggers = {
    volume_name  = local.scanner_engine_volume_name
    trivy_digest = data.docker_registry_image.trivy.sha256_digest
  }
  provisioner "local-exec" {
    command = <<-EOT
      docker volume create ${local.scanner_engine_volume_name} && \
      docker run --rm --entrypoint sh -v ${local.scanner_engine_volume_name}:/target ${docker_image.trivy.name} -c 'cp -a /usr/local/bin/. /target/ 2>/dev/null; cp -a /trivy /target/ 2>/dev/null; ls /target'
    EOT
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
    container_path = "/tmp"
    volume_name    = null_resource.scanner_volume.triggers.volume_name
  }
  memory      = 768
  memory_swap = 768
  env = [
    "PATH=/opt/scanner:/opt/scanner/usr/local/bin",
    "XDG_CACHE_HOME=/tmp",
  ]
  mounts {
    type   = "volume"
    source = null_resource.scanner_engine.triggers.volume_name
    target = "/opt/scanner"
  }
  upload {
    file = "/config.toml"
    content = templatefile("${path.module}/templates/config.tftpl.toml", {
      registry_url = var.registry_url
      token        = random_password.scan_token.result
    })
  }
  command = ["-c", "/config.toml", "scanner", "trivy"]
}
