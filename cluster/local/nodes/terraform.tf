terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
    random = {
      source = "hashicorp/random"
    }
    talos = {
      source = "siderolabs/talos"
    }
  }
}
