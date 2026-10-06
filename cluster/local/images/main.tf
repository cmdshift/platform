resource "docker_image" "o2_sync" {
  provider = docker-push.push
  name     = "${var.registry_hostname}/platform/o2-sync:default"
  build {
    context = "${path.module}/../../../images/o2-sync"
  }
  triggers = {
    dockerfile_sha = filesha256("${path.module}/../../../images/o2-sync/Dockerfile")
  }
  keep_locally = true
}

resource "docker_registry_image" "o2_sync" {
  provider      = docker-push.push
  name          = docker_image.o2_sync.name
  keep_remotely = true
  triggers = {
    digest = docker_image.o2_sync.repo_digest
  }
}
