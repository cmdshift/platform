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
  entrypoint = ["httpd", "-vv", "-f", "-h", "/www"]
  upload {
    file       = "/www/cgi-bin/index.cgi"
    executable = true
    content    = file("${path.module}/scripts/index.cgi")
  }
  upload {
    file = "/www/secrets/_/bucket-credentials"
    content = jsonencode({
      accesskey = local.s3.access_key
      secretkey = local.s3.secret_key
    })
  }
  upload {
    file = "/www/secrets/_/cloud-trust-bundle"
    content = jsonencode({
      "ca.crt" = local.cloud_trust_bundle
    })
  }
  upload {
    file = "/www/secrets/cert-manager/intermediate-ca"
    content = jsonencode({
      "tls.crt" = local.intermediate_ca.crt
      "tls.key" = local.intermediate_ca.key
    })
  }
}
