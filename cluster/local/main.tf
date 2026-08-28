module "conf" {
  source = "./conf"
}

module "net" {
  source       = "./net"
  network_cidr = module.conf.net.network_cidr
  cluster = {
    name = module.conf.cluster_name
  }
}

module "external" {
  source   = "./external"
  name     = module.conf.external.name
  hostname = module.conf.external.hostname
  net = {
    bridge_network_id  = module.net.bridge_network_id
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.external.private_ip
  }
  services = {
    "${module.conf.storage.name}"  = module.conf.storage.services
    "${module.conf.secrets.name}"  = module.conf.secrets.services
    "${module.conf.registry.name}" = module.conf.registry.services
  }
}

module "dns" {
  source   = "./dns"
  name     = module.conf.dns.name
  hostname = module.conf.dns.hostname
  net = {
    private_ip          = module.conf.dns.private_ip
    external_hostname   = module.conf.external.hostname
    external_ip_address = module.conf.external.private_ip
    internal_hostname   = module.conf.internal.hostname
    internal_ip_address = module.conf.internal.private_ip
    bridge_network_id   = module.net.bridge_network_id
    private_network_id  = module.net.private_network_id
  }
  cmd = {
    hostname   = module.conf.nodes.cmd.hostname
    private_ip = module.conf.nodes.cmd.private_ip
  }
}

module "secrets" {
  source = "./secrets"
  name   = module.conf.secrets.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.secrets.private_ip
  }
}

module "storage" {
  source = "./storage"
  name   = module.conf.storage.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.storage.private_ip
  }
  buckets    = module.conf.storage.buckets
  access_key = module.secrets.flux_system_bucket_credentials.accesskey
  secret_key = module.secrets.flux_system_bucket_credentials.secretkey
}

module "registry" {
  source = "./registry"
  name   = module.conf.registry.name
  net = {
    private_ip         = module.conf.registry.private_ip
    private_network_id = module.net.private_network_id
    bridge_network_id  = module.net.bridge_network_id
  }
}

module "sync" {
  depends_on = [
    module.storage,
    module.external
  ]
  source = "./sync"
  name   = module.conf.sync.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.sync.private_ip
  }
  flux_s3 = {
    bucket     = module.conf.sync.bucket
    endpoint   = module.conf.storage.services.s3.hostname
    access_key = module.secrets.flux_system_bucket_credentials.accesskey
    secret_key = module.secrets.flux_system_bucket_credentials.secretkey
  }
}

module "nodes" {
  source = "./nodes"
  depends_on = [
    module.registry
  ]
  cluster = {
    name          = module.conf.cluster_name
    k8s_version   = module.conf.k8s_version
    talos_version = module.conf.talos_version
  }
  net = {
    bridge_network_id  = module.net.bridge_network_id
    private_network_id = module.net.private_network_id
    ctrl_cidr          = module.conf.net.ctrl_cidr
    work_cidr          = module.conf.net.work_cidr
  }
  dns = {
    private_ip = module.dns.private_ip
  }
  cmd = {
    hostname   = module.conf.nodes.cmd.hostname
    private_ip = module.conf.nodes.cmd.private_ip
  }
  ctrl = module.conf.nodes.ctrl
  work = module.conf.nodes.work
  registry = {
    hostname  = module.conf.registry.services.main.hostname
    upstreams = module.registry.upstreams
  }
}

module "internal" {
  source   = "./internal"
  name     = module.conf.internal.name
  hostname = module.conf.internal.hostname
  net = {
    bridge_network_id  = module.net.bridge_network_id
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.internal.private_ip
  }
  servers = module.nodes.servers
}

resource "local_sensitive_file" "kubeconfig" {
  content  = module.nodes.kubeconfig
  filename = "${path.module}/.tmp/kubeconfig"
}

resource "local_sensitive_file" "talosconfig" {
  content  = module.nodes.talosconfig
  filename = "${path.module}/.tmp/talosconfig"
}

output "bootstrap" {
  sensitive = true
  value = {
    k8s_client_config = module.nodes.k8s_client_config
    flux_bucket = {
      name       = module.conf.sync.bucket
      endpoint   = module.conf.storage.services.s3.hostname
      access_key = module.secrets.flux_system_bucket_credentials.accesskey
      secret_key = module.secrets.flux_system_bucket_credentials.secretkey
    }
  }
}
