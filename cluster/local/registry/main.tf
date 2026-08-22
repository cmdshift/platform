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
    command = "docker volume create ${local.registry_volume_name}"
  }
}

resource "docker_container" "registry" {
  name         = var.name
  image        = docker_image.angos.name
  network_mode = "bridge"
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
  upload {
    file    = "/etc/angos/config.toml"
    content = templatefile("${path.module}/templates/config.tftpl.toml", {
      registries = local.registry_map
    })
  }
  command = ["-c", "/etc/angos/config.toml", "server"]
}
