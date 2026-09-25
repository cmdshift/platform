data "docker_registry_image" "talos" {
  name = "ghcr.io/siderolabs/talos:v${var.cluster.talos_version}"
}

data "docker_registry_image" "haproxy" {
  name = "ghcr.io/haproxytech/haproxy-docker-alpine:3.2.22"
}

data "talos_client_configuration" "main" {
  cluster_name         = var.cluster.name
  client_configuration = talos_machine_secrets.main.client_configuration
  endpoints = [
    var.cmd.hostname
  ]
  nodes = flatten([
    for node in docker_container.ctrl :
    [
      for n in node.networks_advanced : n.ipv4_address if n.name == var.net.private_network_id
    ]
  ])
}

data "talos_machine_configuration" "ctrl" {
  machine_type       = "controlplane"
  cluster_name       = var.cluster.name
  kubernetes_version = var.cluster.k8s_version
  cluster_endpoint   = local.public_endpoint
  machine_secrets    = talos_machine_secrets.main.machine_secrets
  config_patches = [
    local.cluster_machine_patch,
    local.base_machine_patch,
    local.ctrl_machine_patch,
    local.registry_mirror_config_patch,
    local.user_volume_config_patch
  ]
}

data "talos_machine_configuration" "work" {
  machine_type       = "worker"
  cluster_name       = var.cluster.name
  kubernetes_version = var.cluster.k8s_version
  cluster_endpoint   = local.public_endpoint
  machine_secrets    = talos_machine_secrets.main.machine_secrets
  config_patches = [
    local.base_machine_patch,
    local.work_machine_patch,
    local.registry_mirror_config_patch,
    local.user_volume_config_patch
  ]
}
