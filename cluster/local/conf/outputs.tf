output "cloud_name" {
  value = local.cloud_name
}

output "local_name" {
  value = local.local_name
}

output "cluster_name" {
  value = local.cluster_name
}

output "versions" {
  value = {
    talos  = var.talos_version
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

output "storage" {
  value = {
    private_ip        = cidrhost(local.cloud_cidr, 3)
    name              = join("-", ["storage", local.cloud_name])
    access_key_id     = var.storage_access_key_id
    secret_access_key = var.storage_secret_access_key
    volume_name       = join("-", ["storage", local.cloud_name])
    buckets = [
      local.storage_buckets.flux
    ]
    services = {
      s3 = {
        hostname = join(".", ["s3", var.cloud_hostname])
        port     = 9000
      }
      ui = {
        hostname = join(".", ["minio", var.cloud_hostname])
        port     = 9001
      }
    }
  }
}