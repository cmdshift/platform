terraform {
  required_providers {
    local = {
      source = "hashicorp/local"
    }
    random = {
      source = "hashicorp/random"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "docker" {
  alias = "push"
  registry_auth {
    address  = "http://${module.conf.registry.services.main.hostname}"
    username = module.registry.push_identity.username
    password = module.registry.push_identity.password
  }
}