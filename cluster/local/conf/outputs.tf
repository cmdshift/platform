output "k8s_version" {
  value = var.k8s_version
}

output "talos_version" {
  value = var.talos_version
}

output "local_name" {
  value = local.local_name
}

output "cloud_name" {
  value = local.cloud_name
}

output "cluster_name" {
  value = local.cluster_name
}

output "local_hostname" {
  value = replace(local.local_name, "-", ".")
}

output "cloud_hostname" {
  value = replace(local.cloud_name, "-", ".")
}

output "net" {
  value = {
    network_cidr = local.network_cidr
    cmd_cidr     = local.cmd_cidr
    ctrl_cidr    = local.ctrl_cidr
    work_cidr    = local.work_cidr
    local_cidr   = local.local_cidr
    cloud_cidr   = local.cloud_cidr
  }
}

output "load" {
  value = {
    name       = local.cloud_name
    hostname   = var.local_hostname
    private_ip = cidrhost(local.local_cidr, 1)
  }
}

output "cmd" {
  value = {
    hostname   = join(".", ["cmd", replace(local.local_name, "-", ".")])
    private_ip = cidrhost(local.local_cidr, 1)
  }
}

output "dns" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 1)
    name       = join("-", ["dns", local.cloud_name])
    hostname   = join(".", ["dns", var.cloud_hostname])
  }
}

output "secrets" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 2)
    name       = join("-", ["secrets", local.cloud_name])
    services = {
      main = {
        hostname   = join(".", ["secrets", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 2)
        port       = 80
      }
    }
  }
}

output "storage" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 3)
    name       = join("-", ["storage", local.cloud_name])
    buckets = [
      "flux",
      "backups",
      "openobserve"
    ]
    services = {
      s3 = {
        hostname   = join(".", ["s3", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 3)
        port       = 9000
      }
      ui = {
        hostname   = join(".", ["storage", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 3)
        port       = 9001
      }
    }
  }
}

output "registry" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 4)
    name       = join("-", ["registry", local.cloud_name])
    services = {
      main = {
        hostname   = join(".", ["registry", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 4)
        port       = 8000
      }
    }
  }
}

output "mail" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 5)
    name       = join("-", ["mail", local.cloud_name])
    services = {
      smtp = {
        hostname   = join(".", ["smtp", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 5)
        port       = 1025
      }
      web = {
        hostname   = join(".", ["mail", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 5)
        port       = 8025
      }
    }
  }
}

output "auth" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 6)
    name       = join("-", ["auth", local.cloud_name])
    services = {
      main = {
        hostname   = join(".", ["auth", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 6)
        port       = 8080
      }
    }
  }
}

output "scanner" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 7)
    name       = join("-", ["scanner", local.cloud_name])
    services = {
      main = {
        hostname   = join(".", ["scanner", var.cloud_hostname])
        private_ip = cidrhost(local.cloud_cidr, 7)
        port       = 8766
      }
    }
  }
}

output "sync" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 8)
    name       = join("-", ["sync", local.cloud_name])
    bucket     = "flux"
  }
}

output "nodes" {
  value = {
    ctrl = local.ctrl_nodes
    work = local.work_nodes
  }
}
