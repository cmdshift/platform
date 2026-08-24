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
    local.cilium_machine_patch,
    local.registry_mirror_config_patch,
    local.registry_tls_config_patch
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
    local.registry_tls_config_patch
  ]
}

data "helm_template" "cilium" {
  name         = "cilium"
  namespace    = "kube-system"
  repository   = "https://helm.cilium.io"
  chart        = "cilium"
  version      = "1.20.1"
  kube_version = var.cluster.k8s_version
  set = [
    {
      name  = "cgroup.autoMount.enabled"
      value = "false"
    },
    {
      name  = "cgroup.hostRoot"
      value = "/sys/fs/cgroup"
    },
    {
      name  = "ipam.mode"
      value = "kubernetes"
    },
    {
      name  = "k8sServiceHost"
      value = "localhost"
    },
    {
      name  = "k8sServicePort"
      value = "7445"
    },
    {
      name  = "kubeProxyReplacement"
      value = "true"
    },
    {
      name  = "l2announcements.enabled"
      value = "true"
    }
  ]

  values = [
    yamlencode({
      securityContext = {
        capabilities = {
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }
    })
  ]
}
