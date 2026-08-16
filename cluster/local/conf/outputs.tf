output "cloud_name" {
  value = local.cloud_name
}

output "local_name" {
  value = local.local_name
}

output "cluster_name" {
  value = local.cluster_name
}

output "net" {
  value = {
    network_cidr = local.network_cidr
    cmd_cidr     = local.cmd_cidr
    ctrl_cidr    = local.ctrl_cidr
    work_cidr    = local.work_cidr
    pod_cidr     = local.pod_cidr
    service_cidr = local.service_cidr
  }
}