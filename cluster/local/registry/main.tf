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
    # fresh volumes default to root:root and angos runs as 65534 since 1.8.0 —
    # the first write would fail EACCES (cmdshift/platform#102)
    command = "docker volume create ${local.registry_volume_name} && docker run --rm -v ${local.registry_volume_name}:/data busybox:1.37.0 chown -R 65534:65534 /data"
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
    })
  }
  command = ["-c", "/etc/angos/config.toml", "server"]
}
