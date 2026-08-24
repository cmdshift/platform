output "k8s_version" {
  value = var.k8s_version
}

output "talos_version" {
  value = var.talos_version
}

output "external_name" {
  value = local.external_name
}

output "internal_name" {
  value = local.internal_name
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
  }
}

output "external" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 1)
    name       = local.external_name
    hostname   = var.external_hostname
  }
}

output "dns" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 2)
    name       = join("-", ["dns", local.external_name])
    hostname   = join(".", ["dns", var.external_hostname])
  }
}

output "secrets" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 3)
    name       = join("-", ["secrets", local.external_name])
    services = {
      main = {
        hostname = join(".", ["secrets", var.external_hostname])
        port     = 80
      }
    }
  }
}

output "storage" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 4)
    name       = join("-", ["storage", local.external_name])
    buckets = [
      local.storage_buckets.flux
    ]
    services = {
      s3 = {
        hostname = join(".", ["s3", var.external_hostname])
        port     = 9000
      }
      ui = {
        hostname = join(".", ["storage", var.external_hostname])
        port     = 9001
      }
    }
  }
}

output "registry" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 5)
    name       = join("-", ["registry", local.external_name])
    services = {
      main = {
        hostname = join(".", ["registry", var.external_hostname])
        port     = 8000
      }
    }
  }
}

output "sync" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 6)
    name       = join("-", ["sync", local.external_name])
    bucket     = local.storage_buckets.flux
  }
}

output "nodes" {
  value = {
    cmd = {
      private_ip = cidrhost(local.cmd_cidr, 1)
      hostname   = join(".", ["cmd", var.internal_hostname])
    }
    ctrl = local.ctrl_nodes
    work = local.work_nodes
  }
}

output "internal" {
  value = {
    private_ip = cidrhost(local.local_cidr, 1)
    name       = local.internal_name
    hostname   = var.internal_hostname
  }
}