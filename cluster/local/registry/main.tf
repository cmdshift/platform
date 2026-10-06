resource "random_password" "push_password" {
  length  = 32
  special = false
}

resource "password_argon2" "push_password" {
  password   = random_password.push_password.result
  memory     = 19456
  iterations = 2
  thread     = 1
}

resource "docker_image" "angos" {
  name          = data.docker_registry_image.angos.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.angos.sha256_digest]
}

resource "null_resource" "registry_volume" {
  triggers = {
    volume_name = local.registry_volume_name
  }
  provisioner "local-exec" {
    command = <<-EOT
      docker volume create ${local.registry_volume_name} && \
      docker run --rm -v ${local.registry_volume_name}:/data busybox:1.37.0 chown -R 65534:65534 /data
    EOT
  }
}

resource "docker_container" "registry" {
  name  = var.name
  image = docker_image.angos.name
  networks_advanced {
    name = var.net.bridge_network_id
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
  }
  volumes {
    container_path = "/data"
    volume_name    = null_resource.registry_volume.triggers.volume_name
  }
  memory      = 256
  memory_swap = 256
  upload {
    file = "/etc/angos/config.toml"
    content = templatefile("${path.module}/templates/config.tftpl.toml", {
      registries = local.registry_map
      scan       = var.scan
      push = {
        username      = local.push_username
        password_hash = password_argon2.push_password.hash
      }
    })
  }
  command = ["-c", "/etc/angos/config.toml", "server"]
}
