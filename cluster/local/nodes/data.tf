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
    local.cilium_machine_patch
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
    local.work_machine_patch
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
      name  = "ipam.mode"
      value = "kubernetes"
    },
    {
      name  = "kubeProxyReplacement"
      value = "true"
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
      name  = "cgroup.autoMount.enabled"
      value = "false"
    },
    {
      name  = "cgroup.hostRoot"
      value = "/sys/fs/cgroup"
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

data "http" "kubernetes_endpoint" {
  depends_on = [
    talos_machine_bootstrap.main
  ]
  method      = "GET"
  url         = local.public_endpoint
  ca_cert_pem = base64decode(talos_machine_secrets.main.machine_secrets.certs.k8s.cert)
  retry {
    attempts     = 30
    min_delay_ms = 5000
  }
  lifecycle {
    postcondition {
      condition     = self.status_code == 401
      error_message = "unexpected status code"
    }
  }
}
