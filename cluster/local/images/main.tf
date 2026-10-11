resource "docker_registry_image" "o2_sync" {
  provider = docker-push.push
  name     = "${var.registry_hostname}/platform/o2-sync:default"
  build {
    context = "${path.module}/../../../images/o2-sync"
  }
  keep_remotely        = true
  insecure_skip_verify = true
  triggers = {
    dockerfile_sha = filesha256("${path.module}/../../../images/o2-sync/Dockerfile")
  }
}
