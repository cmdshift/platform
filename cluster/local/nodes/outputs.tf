output "public_endpoint" {
  value = local.public_endpoint
}

output "servers" {
  value = concat(
    [
      for ip, node in docker_container.ctrl : {
        name = node.name
        ipv4 = ip
      }
    ],
    [
      for ip, node in docker_container.work : {
        name = node.name
        ipv4 = ip
      }
    ]
  )
}

output "boot_node" {
  value = local.boot_node
}

output "kubeconfig" {
  value = talos_cluster_kubeconfig.main.kubeconfig_raw
}

output "talosconfig" {
  value = replace(data.talos_client_configuration.main.talos_config, var.cmd.private_ip, var.cmd.hostname)
}
