terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.9.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.4.1"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

provider "local" {}

provider "tls" {}


