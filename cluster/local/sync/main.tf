resource "docker_image" "sync" {
  name = var.name
  build {
    context = path.module
  }
  triggers = {
    dockerfile_sha = sha256(file("${path.module}/Dockerfile"))
  }
  keep_locally = true
}

resource "docker_container" "sync" {
  name  = var.name
  image = docker_image.sync.name
  env = [
    "AWS_ACCESS_KEY_ID=${var.s3.access_key_id}",
    "AWS_SECRET_ACCESS_KEY=${var.s3.secret_access_key}",
    "RUSTFS_BUCKET=${var.s3.bucket}",
    "RUSTFS_ENDPOINT=${var.s3.endpoint}"
  ]
  network_mode = "bridge"
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
  }
  upload {
    file       = "/tmp/mirror.sh"
    content    = file("${path.module}/scripts/mirror.sh")
    executable = true
  }
  volumes {
    read_only      = true
    host_path      = abspath("${path.root}/../../manifests")
    container_path = "/tmp/manifests"
  }
  entrypoint = ["/tmp/mirror.sh"]
}