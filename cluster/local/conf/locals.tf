locals {
  external_name = replace(var.external_hostname, ".", "-")
  internal_name = replace(var.internal_hostname, ".", "-")
  cluster_name  = replace(var.internal_hostname, ".", "-")
}

locals {
  network_cidr = "10.0.0.0/8"
  ctrl_cidr    = "10.0.16.0/24"
  work_cidr    = "10.0.32.0/24"
  local_cidr   = "10.0.64.0/24"
  cloud_cidr   = "10.0.128.0/24"
}

locals {
  # single fixed control plane node — 3-node etcd saturates the Docker VM
  # during the install burst (host CPU/IOPS ceiling); 1 node has no quorum
  # trade-off that matters here, so there is no LB and no node count knob
  # (cmdshift/platform#54)
  ctrl_nodes = {
    (cidrhost(local.ctrl_cidr, 1)) = {
      name = join("-", ["ctrl", local.internal_name])
    }
  }
  work_nodes = {
    for n in range(var.work_nodes) :
    cidrhost(local.work_cidr, n + 1) => {
      name = join("-", ["work", local.internal_name])
    }
  }
}
