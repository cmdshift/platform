resource "docker_image" "storage" {
  name = var.name
  build {
    context = path.module
  }
  triggers = {
    dockerfile_sha = sha256(file("${path.module}/Dockerfile"))
  }
  keep_locally = true
}

resource "docker_container" "storage" {
  name  = var.name
  image = docker_image.storage.name
  wait  = true
  env = [
    "RUSTFS_BUCKETS=${join(" ", var.buckets)}",
    "RUSTFS_CONSOLE_ENABLE=true"
  ]
  upload {
    file       = "/tmp/entrypoint.sh"
    executable = true
    content    = file("${path.module}/scripts/entrypoint.sh")
  }
  upload {
    file       = "/tmp/healthcheck.sh"
    executable = true
    content    = file("${path.module}/scripts/healthcheck.sh")
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
  }
  entrypoint = [
    "/tmp/entrypoint.sh"
  ]
  healthcheck {
    start_period = "3s"
    interval     = "5s"
    retries      = 5
    test = concat(
      [
        "CMD",
        "/tmp/healthcheck.sh",
      ],
      var.buckets
    )
  }
}
