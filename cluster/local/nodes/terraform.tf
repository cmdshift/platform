terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
    helm = {
      source = "hashicorp/helm"
    }
    random = {
      source = "hashicorp/random"
    }
    talos = {
      source = "siderolabs/talos"
    }
  }
}