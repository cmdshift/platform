data "docker_registry_image" "coredns" {
  name = "index.docker.io/coredns/coredns:${var.coredns_version}"
}

data "docker_registry_image" "talos" {
  name = "ghcr.io/siderolabs/talos:${var.talos_version}"
}

data "docker_registry_image" "haproxy" {
  name = "ghcr.io/haproxytech/haproxy-docker-alpine:${var.haproxy_version}"
}
