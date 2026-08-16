packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "~> 1"
    }
  }
}

variable "schematic_id" {
  type    = string
  default = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
}

variable "talos_version" {
  type    = string
  default = "v1.13.8"
}

locals {
  image_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/hcloud-amd64.raw.xz"
}

source "hcloud" "main" {
  rescue        = "linux64"
  image         = "debian-12"
  location      = "hil"
  server_type   = "cpx11"
  ssh_username  = "root"
  snapshot_name = "talos-${var.talos_version}"
  snapshot_labels = {
    os      = "talos"
    version = var.talos_version
  }
}

build {
  sources = ["source.hcloud.main"]

  provisioner "shell" {
    inline = [
      "apt-get update && apt-get install -y xz-utils",
      "curl -sL ${local.image_url} | xz -d -c | dd of=/dev/sda bs=4M status=progress && sync"
    ]
  }
}
