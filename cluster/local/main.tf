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

module "storage" {
  source = "./storage"
  name   = module.conf.storage.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.storage.private_ip
  }
  services          = module.conf.storage.services
  access_key_id     = module.conf.storage.access_key_id
  secret_access_key = module.conf.storage.secret_access_key
  buckets           = module.conf.storage.buckets
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
  aliases = {
    "${module.conf.storage.name}" = module.conf.storage.services
  }
}

module "flux" {
  depends_on = [
    module.storage,
    module.external
  ]
  source = "./flux"
  name   = module.conf.flux.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.flux.private_ip
  }
  s3 = {
    bucket            = module.conf.flux.bucket
    endpoint          = module.storage.endpoint
    access_key_id     = module.conf.storage.access_key_id
    secret_access_key = module.conf.storage.secret_access_key
  }
}

module "nodes" {
  source = "./nodes"
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