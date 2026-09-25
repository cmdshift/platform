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
  memory      = 64
  memory_swap = 64
  entrypoint  = ["httpd", "-vvv", "-f", "-h", "/www"]
  upload {
    file    = "/www/certificates/intermediate-ca"
    content = jsonencode(local.certificates.intermediate_ca)
  }
  upload {
    file    = "/www/flux-system/bucket-credentials"
    content = jsonencode(local.flux_system.bucket_credentials)
  }
  upload {
    file    = "/www/objects/loki-s3-credentials"
    content = jsonencode(local.objects.loki_s3_credentials)
  }
  upload {
    file    = "/www/objects/tempo-s3-credentials"
    content = jsonencode(local.objects.tempo_s3_credentials)
  }
  upload {
    file    = "/www/objects/mimir-s3-credentials"
    content = jsonencode(local.objects.mimir_s3_credentials)
  }
  upload {
    file    = "/www/observability/main-grafana-credentials"
    content = jsonencode(local.observability.main_grafana_credentials)
  }
  upload {
    file    = "/www/observability/loki-s3-credentials"
    content = jsonencode(local.observability.loki_s3_credentials)
  }
  upload {
    file    = "/www/observability/tempo-s3-credentials"
    content = jsonencode(local.observability.tempo_s3_credentials)
  }
  upload {
    file    = "/www/observability/mimir-s3-credentials"
    content = jsonencode(local.observability.mimir_s3_credentials)
  }
  upload {
    file    = "/www/backups/velero-s3-credentials"
    content = jsonencode(local.backups.velero_s3_credentials)
  }
  upload {
    file    = "/www/access/oauth2-proxy-credentials"
    content = jsonencode(local.access.oauth2_proxy_credentials)
  }
  upload {
    file    = "/www/access/platform-root-ca"
    content = jsonencode(local.access.platform_root_ca)
  }
}
