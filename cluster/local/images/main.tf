resource "docker_image" "openobserve_sync" {
  name = "registry.cloud.test/platform/openobserve-sync:default"
  build {
    context    = abspath("${path.root}/../images/openobserve-sync")
    dockerfile = abspath("${path.root}/../images/openobserve-sync/Dockerfile")
  }
  keep_locally = true
  triggers = {
    dockerfile = filesha1(abspath("${path.root}/../images/openobserve-sync/Dockerfile"))
  }
}

resource "docker_registry_image" "openobserve_sync" {
  name                 = docker_image.openobserve_sync.name
  keep_remotely        = true
  insecure_skip_verify = true
  auth_config {
    address  = "https://${var.registry_hostname}"
    username = var.registry_username
    password = var.registry_password
  }
}
