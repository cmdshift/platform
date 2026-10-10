data "docker_registry_image" "haproxy" {
  name = "ghcr.io/haproxytech/haproxy-docker-alpine:3.2.22"
}

data "local_sensitive_file" "cloud_pem" {
  filename = var.cloud_pem_path
}
