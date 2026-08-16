resource "docker_image" "storage" {
  name = "${var.name}"
  build {
    context = "${path.module}"
  }
}

resource "docker_volume" "data" {
  name = join("-", [var.name, "data"])
}

resource "docker_container" "storage" {
  name  = var.name
  image = docker_image.storage.name
  wait  = true
  env = [
    "RUSTFS_ACCESS_KEY=${var.access_key_id}",
    "RUSTFS_SECRET_KEY=${var.secret_access_key}",
    "RUSTFS_CONSOLE_ENABLE=true"
  ]
  volumes {
    container_path = "/data"
    volume_name    = docker_volume.data.name
  }
  upload {
    file       = "/tmp/healthcheck.sh"
    content    = file("${path.module}/scripts/healthcheck.sh")
    executable = true
  }
  network_mode = "bridge"
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
  }
  healthcheck {
    start_period = "3s"
    interval     = "5s"
    retries      = 5
    test = concat(
      [
        "CMD", "/tmp/healthcheck.sh",
        "http://localhost:${var.services.s3.port}",
        var.access_key_id,
        var.secret_access_key
      ],
      var.buckets
    )
  }
}
