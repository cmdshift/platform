output "public_endpoint" {
  value = local.public_endpoint
}

# workers only — the internal haproxy frontends the Gateway, whose hostNetwork
# listeners bind on k8s-role/work nodes; the ctrl would sit permanently
# check-down in the backends
output "servers" {
  value = [
    for ip, node in docker_container.work : {
      name = node.name
      ipv4 = ip
    }
  ]
}

output "boot_node" {
  value = local.boot_node
}

# The talos provider derives the embedded API address from the cluster
# endpoint (ctrl node IP — only routable inside the private network); host-side
# consumers (kubectl, the bootstrap terraform providers) must go through the
# loopback-published ports instead.
locals {
  local_api_endpoint = "https://${local.local_api_ip}:${local.ports.k8s}"
}

output "kubeconfig" {
  value = replace(talos_cluster_kubeconfig.main.kubeconfig_raw, local.public_endpoint, local.local_api_endpoint)
}

output "k8s_client_config" {
  value = merge(talos_cluster_kubeconfig.main.kubernetes_client_configuration, {
    host = local.local_api_endpoint
  })
}

output "talosconfig" {
  value = data.talos_client_configuration.main.talos_config
}
