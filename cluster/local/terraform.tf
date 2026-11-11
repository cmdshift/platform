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
