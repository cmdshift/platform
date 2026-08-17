module "conf" {
  source = "./conf"
}

module "net" {
  source       = "./net"
  network_cidr = module.conf.net.network_cidr
  cluster = {
    name = module.conf.internal_name
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