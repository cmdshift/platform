locals {
  local_name   = replace(var.local_hostname, ".", "-")
  cloud_name   = replace(var.cloud_hostname, ".", "-")
  cluster_name = replace(var.local_hostname, ".", "-")

  network_cidr = "10.0.0.0/8"
  cmd_cidr     = "10.0.8.0/24"
  ctrl_cidr    = "10.0.16.0/24"
  work_cidr    = "10.0.32.0/24"
  local_cidr   = "10.0.64.0/24"
  cloud_cidr   = "10.0.128.0/24"

  ctrl_nodes = {
    for n in range(var.ctrl_nodes) :
    cidrhost(local.ctrl_cidr, n + 1) => {
      name = join("-", ["ctrl", local.local_name])
    }
  }
  work_nodes = {
    for n in range(var.work_nodes) :
    cidrhost(local.work_cidr, n + 1) => {
      name = join("-", ["work", local.local_name])
    }
  }
}
