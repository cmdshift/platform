output "external_name" {
  value = local.external_name
}

output "internal_name" {
  value = local.internal_name
}

output "cluster_name" {
  value = local.cluster_name
}

output "ca" {
  value = {
    cert = local.local_ca_cert
    key  = local.local_ca_key
    pem  = local.local_ca_pem
  }
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

output "storage" {
  value = {
    private_ip        = cidrhost(local.cloud_cidr, 3)
    name              = join("-", ["storage", local.external_name])
    access_key_id     = var.storage_access_key_id
    secret_access_key = var.storage_secret_access_key
    volume_name       = join("-", ["storage", local.external_name])
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

output "flux" {
  value = {
    private_ip = cidrhost(local.cloud_cidr, 4)
    name       = join("-", ["flux", local.external_name])
    bucket     = local.storage_buckets.flux
  }
}

output "internal" {
  value = {
    private_ip = cidrhost(local.local_cidr, 1)
    name       = local.internal_name
    hostname   = var.internal_hostname
  }
}