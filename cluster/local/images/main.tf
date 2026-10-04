resource "docker_image" "o2_sync" {
  name = var.name
  build {
    context = "${path.module}/../../../images/sync"
  }
  # plain alpine+curl+jq — the sync script is CM-mounted, so the image only
  # changes when the Dockerfile does
  triggers = {
    dockerfile_sha = filesha256("${path.module}/../../../images/sync/Dockerfile")
  }
  keep_locally = true
}

# angos accepts pushes (validated cmdshift/platform#171) — the pushed image
# lands in the registry volume and nodes pull it via the wildcard mirror.
# insecure_skip_verify: the local registry is plain HTTP (no TLS).
resource "docker_registry_image" "o2_sync" {
  name                 = var.name
  keep_remotely        = true
  insecure_skip_verify = true

  depends_on = [docker_image.o2_sync]

  triggers = {
    digest = docker_image.o2_sync.repo_digest
  }
}
