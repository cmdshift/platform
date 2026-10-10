output "public_endpoint" {
  value = local.public_endpoint
}

output "ctrl" {
  value = [
    for ip, node in docker_container.ctrl : {
      name = node.name
      ipv4 = ip
    }
  ]
}

output "work" {
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

output "kubeconfig" {
  value = talos_cluster_kubeconfig.main.kubeconfig_raw
}

output "kubeconfig_oidc" {
  value = templatefile("${path.module}/templates/kubeconfig-oidc.tftpl.yaml", {
    local_api_endpoint = local.public_endpoint
    ca_data            = talos_cluster_kubeconfig.main.kubernetes_client_configuration.ca_certificate
    issuer_url         = var.oidc_issuer_url
    client_id          = "kubernetes"
  })
}

output "k8s_client_config" {
  value = talos_cluster_kubeconfig.main.kubernetes_client_configuration
}

output "talosconfig" {
  value = replace(data.talos_client_configuration.main.talos_config, var.cmd.private_ip, var.cmd.hostname)
}
