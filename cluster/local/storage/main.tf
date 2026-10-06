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

resource "null_resource" "storage_volume" {
  triggers = {
    volume_name = local.storage_volume_name
  }
  provisioner "local-exec" {
    command = <<-EOT
      docker volume create ${local.storage_volume_name} && \
      docker run --rm -v ${local.storage_volume_name}:/data busybox:1.37.0 chown -R 10001:10001 /data
    EOT
  }
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
  volumes {
    container_path = "/data"
    volume_name    = null_resource.storage_volume.triggers.volume_name
  }
  memory      = 1024
  memory_swap = 1024
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
