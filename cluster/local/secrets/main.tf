resource "docker_image" "busybox" {
  name          = data.docker_registry_image.busybox.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.busybox.sha256_digest]
}

resource "docker_container" "secrets" {
  name         = var.name
  image        = docker_image.busybox.name
  network_mode = "bridge"
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
  }
  entrypoint = ["httpd", "-vvv", "-f", "-h", "/www"]
  upload {
    file    = "/www/flux-system/bucket-credentials"
    content = jsonencode(local.flux_system.bucket_credentials)
  }
  upload {
    file    = "/www/cert-manager/intermediate-ca"
    content = jsonencode(local.cert_manager.intermediate_ca)
  }
  upload {
    file    = "/www/objects/bucket-credentials"
    content = jsonencode(local.flux_system.bucket_credentials)
  }
  upload {
    file    = "/www/monitoring/main-grafana-credentials"
    content = jsonencode(local.monitoring.main_grafana_credentials)
  }
}
