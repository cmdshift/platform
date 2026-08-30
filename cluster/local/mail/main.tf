resource "docker_image" "mailpit" {
  name          = data.docker_registry_image.mailpit.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.mailpit.sha256_digest]
}

resource "docker_container" "secrets" {
  name         = var.name
  image        = docker_image.mailpit.name
  network_mode = "bridge"
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
  }
}
