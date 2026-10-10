module "conf" {
  source = "./conf"
}

module "certs" {
  source         = "./certs"
  cloud_hostname = module.conf.cloud_hostname
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
    private_ip         = module.conf.dns.private_ip
    load_ip_address    = module.conf.load.private_ip
    bridge_network_id  = module.net.bridge_network_id
    private_network_id = module.net.private_network_id
  }
  cmd_hostname   = module.conf.load.hostname
  load_hostname  = module.conf.load.hostname
  local_hostname = module.conf.local_hostname
  cloud_hostname = module.conf.cloud_hostname
}

module "secrets" {
  source = "./secrets"
  depends_on = [
    module.certs
  ]
  name = module.conf.secrets.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.secrets.private_ip
  }
  intermediate_ca_crt_path = module.certs.intermediate_ca_crt_path
  intermediate_ca_key_path = module.certs.intermediate_ca_key_path
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

module "scanner" {
  source = "./scanner"
  name   = module.conf.scanner.name
  net = {
    bridge_network_id  = module.net.bridge_network_id
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.scanner.private_ip
  }
  registry_url = "http://${module.conf.registry.services.main.hostname}"
}

module "registry" {
  source = "./registry"
  name   = module.conf.registry.name
  net = {
    private_ip         = module.conf.registry.private_ip
    private_network_id = module.net.private_network_id
    bridge_network_id  = module.net.bridge_network_id
  }
  scan = {
    url   = "http://${module.conf.scanner.services.main.hostname}"
    token = module.scanner.scan_token
  }
}

module "mail" {
  source = "./mail"
  name   = module.conf.mail.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.mail.private_ip
  }
}

module "auth" {
  source = "./auth"
  name   = module.conf.auth.name
  net = {
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.auth.private_ip
  }
  trusted_proxies = module.conf.net.cloud_cidr
}

module "images" {
  source            = "./images"
  providers         = { docker-push.push = docker.push }
  depends_on        = [module.registry, module.load]
  registry_hostname = module.conf.registry.services.main.hostname
}

module "nodes" {
  source = "./nodes"
  depends_on = [
    module.certs,
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
    hostname   = module.conf.cmd.hostname
    private_ip = module.conf.cmd.private_ip
  }
  ctrl            = module.conf.nodes.ctrl
  work            = module.conf.nodes.work
  oidc_issuer_url = module.auth.oidc_issuer_url
  registry = {
    hostname = module.conf.registry.services.main.hostname
  }
}

module "load" {
  source = "./load"
  depends_on = [
    module.certs
  ]
  name     = module.conf.load.name
  hostname = module.conf.load.hostname
  net = {
    bridge_network_id  = module.net.bridge_network_id
    private_network_id = module.net.private_network_id
    private_ip         = module.conf.load.private_ip
  }
  hosts = {
    "${module.conf.storage.name}"  = module.conf.storage.services
    "${module.conf.secrets.name}"  = module.conf.secrets.services
    "${module.conf.registry.name}" = module.conf.registry.services
    "${module.conf.mail.name}"     = module.conf.mail.services
    "${module.conf.scanner.name}"  = module.conf.scanner.services
    "${module.conf.auth.name}"     = module.conf.auth.services
  }
  ctrl           = module.nodes.ctrl
  work           = module.nodes.work
  cloud_pem_path = module.certs.cloud_pem_path
  local_hostname = module.conf.local_hostname
  cloud_hostname = module.conf.cloud_hostname
}

module "sync" {
  depends_on = [
    module.storage,
    module.load
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

resource "local_sensitive_file" "kubeconfig" {
  content  = module.nodes.kubeconfig
  filename = "${path.module}/.temp/kubeconfig"
}

resource "local_sensitive_file" "kubeconfig_oidc" {
  content  = module.nodes.kubeconfig_oidc
  filename = "${path.module}/.temp/kubeconfig-oidc"
}

resource "local_sensitive_file" "talosconfig" {
  content  = module.nodes.talosconfig
  filename = "${path.module}/.temp/talosconfig"
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
