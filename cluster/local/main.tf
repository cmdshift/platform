module "conf" {
  source = "./conf"
}

module "net" {
  source       = "./net"
  network_cidr = module.conf.net.network_cidr
  cluster = {
    name = module.conf.local_name
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