output "public_endpoint" {
  value = local.public_endpoint
}

# workers only — the internal haproxy frontends the Gateway, whose hostNetwork listeners
# bind on work nodes; the ctrl would sit permanently check-down in the backends
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

output "kubeconfig" {
  value = talos_cluster_kubeconfig.main.kubeconfig_raw
}

# OIDC-login twin of the admin kubeconfig (cmdshift/platform#131): kubelogin exec plugin
# against the auth companion (install: runbooks/local/cluster-rebuild.md). Authorization is
# the `access/` group's bindings keyed on the `groups` claim (cmdshift/platform#91).
output "kubeconfig_oidc" {
  value = templatefile("${path.module}/templates/kubeconfig-oidc.tftpl.yaml", {
    local_api_endpoint = local.public_endpoint
    ca_data            = talos_cluster_kubeconfig.main.kubernetes_client_configuration.ca_certificate
    issuer_url         = "https://auth.cloud.test/auth/v1/"
    client_id          = "kubernetes"
  })
}

output "k8s_client_config" {
  value = talos_cluster_kubeconfig.main.kubernetes_client_configuration
}

output "talosconfig" {
  value = replace(data.talos_client_configuration.main.talos_config, var.cmd.private_ip, var.cmd.hostname)
}
