resource "docker_image" "platform_api" {
  name = "registry.cloud.test/platform/api:default"
  build {
    context    = abspath("${path.root}/../images/api")
    dockerfile = abspath("${path.root}/../images/api/Dockerfile")
  }
  keep_locally = true
  triggers = {
    dockerfile = filesha1(abspath("${path.root}/../images/api/Dockerfile"))
  }
}

resource "docker_registry_image" "platform_api" {
  name                 = docker_image.platform_api.name
  keep_remotely        = true
  insecure_skip_verify = true
  auth_config {
    address  = "https://${var.registry_hostname}"
    username = var.registry_username
    password = var.registry_password
  }
}

resource "docker_image" "platform_job" {
  name = "registry.cloud.test/platform/job:default"
  build {
    context    = abspath("${path.root}/../images/job")
    dockerfile = abspath("${path.root}/../images/job/Dockerfile")
  }
  keep_locally = true
  triggers = {
    dockerfile = filesha1(abspath("${path.root}/../images/job/Dockerfile"))
  }
}

resource "docker_registry_image" "platform_job" {
  name                 = docker_image.platform_job.name
  keep_remotely        = true
  insecure_skip_verify = true
  auth_config {
    address  = "https://${var.registry_hostname}"
    username = var.registry_username
    password = var.registry_password
  }
}

resource "docker_image" "platform_worker" {
  name = "registry.cloud.test/platform/worker:default"
  build {
    context    = abspath("${path.root}/../images/worker")
    dockerfile = abspath("${path.root}/../images/worker/Dockerfile")
  }
  keep_locally = true
  triggers = {
    dockerfile = filesha1(abspath("${path.root}/../images/worker/Dockerfile"))
  }
}

resource "docker_registry_image" "platform_worker" {
  name                 = docker_image.platform_worker.name
  keep_remotely        = true
  insecure_skip_verify = true
  auth_config {
    address  = "https://${var.registry_hostname}"
    username = var.registry_username
    password = var.registry_password
  }
}

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
