resource "docker_image" "auth" {
  name          = data.docker_registry_image.keycloak.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.keycloak.sha256_digest]
}

resource "docker_container" "auth" {
  name  = var.name
  image = docker_image.auth.name
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.net.private_ip
    aliases      = ["auth.cloud.test"]
  }
  # start-dev: H2 in the container layer — disposable companion, realm
  # re-imports on recreate (cmdshift/platform#131; the cnpg-backed alternative
  # was rejected: a companion depending on the in-cluster DB inverts the
  # bootstrap order)
  command = ["start-dev", "--import-realm"]
  env = [
    "KC_BOOTSTRAP_ADMIN_USERNAME=admin",
    "KC_BOOTSTRAP_ADMIN_PASSWORD=secret",
    # TLS terminates at the external haproxy (cmdshift/platform#130) — the
    # hostname must render https into discovery/issuer URLs or OIDC clients
    # reject the metadata
    "KC_HOSTNAME=https://auth.cloud.test",
    "KC_PROXY_HEADERS=xforwarded",
  ]
  # start-then-audit: OOM-killed at 1280Mi mid-import, then again at 2Gi
  # (JVM MaxRAMPercentage=70 + 256Mi metaspace + H2 import churn); 3Gi held
  # through import + settle (cmdshift/platform#131). Heaviest companion by
  # far — the ARCHITECTURE.md budget carries the delta.
  memory      = 3072
  memory_swap = 3072
  upload {
    file    = "/opt/keycloak/data/import/realm.json"
    content = file("${path.module}/files/realm.json")
  }
}
