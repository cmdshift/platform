locals {
  external_name = replace(var.external_hostname, ".", "-")
  internal_name = replace(var.internal_hostname, ".", "-")
  cluster_name  = replace(var.internal_hostname, ".", "-")
}

locals {
  network_cidr = "10.0.0.0/8"
  cmd_cidr     = "10.0.8.0/24"
  ctrl_cidr    = "10.0.16.0/24"
  work_cidr    = "10.0.32.0/24"
  local_cidr   = "10.0.64.0/24"
  cloud_cidr   = "10.0.128.0/24"
  pod_cidr     = "10.244.0.0/16"
  service_cidr = "10.96.0.0/12"
}

locals {
  storage_buckets = {
    flux = "flux"
  }
}

locals {
  local_ca_cert = "${path.root}/.tmp/tls.crt"
  local_ca_key  = "${path.root}/.tmp/tls.key"
  local_ca_pem  = "${path.root}/.tmp/tls.pem"
}