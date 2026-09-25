resource "docker_image" "auth" {
  name          = data.docker_registry_image.rauthy.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.rauthy.sha256_digest]
}

resource "docker_container" "auth" {
  name  = var.name
  image = docker_image.auth.name
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
    aliases      = ["auth.cloud.test"]
  }
  # bootstrap JSONs are first-boot only — data lives in the container layer, so a
  # terraform recreate wipes hiqlite and re-seeds from files/bootstrap (cmdshift/platform#154;
  # the cnpg-backed alternative was rejected for keycloak: a companion depending on the
  # in-cluster DB inverts the bootstrap order)
  upload {
    file = "/app/config.toml"
    content = templatefile("${path.module}/templates/rauthy.tftpl.toml", {
      trusted_proxies          = var.trusted_proxies
      encryption_key_id        = local.encryption_key_id
      encryption_key           = local.encryption_key
      cluster_secret_raft      = local.cluster_secret_raft
      cluster_secret_api       = local.cluster_secret_api
      bootstrap_admin_password = local.bootstrap_password
    })
  }
  upload {
    file    = "/app/bootstrap/groups.json"
    content = file("${path.module}/files/bootstrap/groups.json")
  }
  upload {
    file    = "/app/bootstrap/users.json"
    content = file("${path.module}/files/bootstrap/users.json")
  }
  upload {
    file    = "/app/bootstrap/clients.json"
    content = file("${path.module}/files/bootstrap/clients.json")
  }
  # start-then-audit: Rust binary, single worker — keycloak needed 3Gi for the JVM
  # import churn (cmdshift/platform#131); audit rauthy's real peak before trusting this
  memory      = 256
  memory_swap = 256
}
