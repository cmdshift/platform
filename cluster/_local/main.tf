resource "libvirt_pool" "main" {
  name = "main"
  type = "dir"
  target = {
    path = abspath("${path.root}/.temp/pool")
  }
}

resource "libvirt_network" "main" {
  count     = local.libvirt_network_count[var.platform]
  name      = "main"
  autostart = false
  forward = {
    mode = "nat"
  }
  ips = [
    {
      address = "10.0.0.1"
      dhcp = {
        hosts = [
          { name = "infra", ip = "10.0.8.1" },
          { name = "ctrl-0", ip = "10.0.16.1" },
          { name = "ctrl-1", ip = "10.0.16.2" },
          { name = "ctrl-2", ip = "10.0.16.3" },
          { name = "work-0", ip = "10.0.32.1" },
          { name = "work-1", ip = "10.0.32.2" }
        ]
      }
    }
  ]
}

resource "libvirt_volume" "talos_image" {
  name = "talos-${var.talos_version}-${var.image_arch}"
  pool = libvirt_pool.main.name
  target = {
    format = {
      type = "qcow2"
    }
  }
  create = {
    content = {
      url = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/metal-${var.image_arch}.qcow2"
    }
  }
}

resource "libvirt_volume" "debian_image" {
  name = "debian-12-${var.image_arch}"
  pool = libvirt_pool.main.name
  target = {
    format = {
      type = "qcow2"
    }
  }
  create = {
    content = {
      url = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-${var.image_arch}.qcow2"
    }
  }
}

resource "libvirt_volume" "ctrl_disk" {
  count = var.ctrl_nodes
  name  = "ctrl-${count.index}.qcow2"
  pool  = libvirt_pool.main.name
  target = {
    format = {
      type = "qcow2"
    }
  }
  capacity      = var.ctrl_disk_gigabytes
  capacity_unit = "GiB"
  backing_store = {
    path = libvirt_volume.talos_image.path
  }
}

resource "libvirt_volume" "work_disk" {
  count = var.work_nodes
  name  = "work-${count.index}.qcow2"
  pool  = libvirt_pool.main.name
  target = {
    format = {
      type = "qcow2"
    }
  }
  capacity      = var.work_disk_gigabytes
  capacity_unit = "GiB"
  backing_store = {
    path = libvirt_volume.talos_image.path
  }
}

resource "libvirt_volume" "infra_disk" {
  name = "infra.qcow2"
  pool = libvirt_pool.main.name
  target = {
    format = {
      type = "qcow2"
    }
  }
  capacity      = var.infra_disk_gigabytes
  capacity_unit = "GiB"
  backing_store = {
    path = libvirt_volume.debian_image.path
  }
}

resource "tls_private_key" "infra" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "infra_ssh_key" {
  filename        = "${path.root}/.temp/ssh/id_ed25519"
  file_permission = "0600"
  content         = tls_private_key.infra.private_key_openssh
}

resource "libvirt_cloudinit_disk" "infra" {
  name      = "infra-cloud-config"
  user_data = <<-EOT
    #cloud-config
    hostname: infra
    users:
      - name: root
        ssh_authorized_keys:
          - ${tls_private_key.infra.public_key_openssh}
    runcmd:
      - apt-get update
      - DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
      - systemctl enable --now docker
  EOT
  meta_data = <<-EOT
    instance-id: infra
    local-hostname: infra
  EOT
}

resource "null_resource" "nvram" {
  provisioner "local-exec" {
    command = "scripts/init_nvram.bash ${var.uefi_nvram_template} ${path.root}/.temp/storage ${join(" ", local.nvram_names)}"
  }
}

resource "libvirt_domain" "ctrl" {
  count = var.ctrl_nodes
  depends_on = [
    null_resource.nvram
  ]
  name        = "ctrl-${count.index}"
  running     = true
  memory      = var.ctrl_memory_megabytes
  memory_unit = "MiB"
  vcpu        = var.ctrl_vcpus
  type        = "hvf"
  cpu = {
    mode = "host-passthrough"
  }
  features = {
    gic = {
      version = "3"
    }
  }
  qemu_commandline = {
    args = [
      { value = "-netdev" },
      { value = "vmnet-shared,id=net0" },
      { value = "-device" },
      { value = "virtio-net-device,netdev=net0" }
    ]
  }
  os = {
    type         = "hvm"
    type_arch    = "aarch64"
    type_machine = "virt"
    loader       = var.uefi_loader
    nv_ram = {
      nv_ram   = abspath("${path.root}/.temp/storage/ctrl-${count.index}_VARS.fd")
      template = var.uefi_nvram_template
      format   = "raw"
    }
  }
  devices = {
    disks = [
      {
        driver = {
          type = "qcow2"
        }
        source = {
          file = {
            file = libvirt_volume.ctrl_disk[count.index].id
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      }
    ]
  }
}

resource "libvirt_domain" "work" {
  count = var.work_nodes
  depends_on = [
    null_resource.nvram
  ]
  name        = "work-${count.index}"
  running     = true
  memory      = var.work_memory_megabytes
  memory_unit = "MiB"
  vcpu        = var.work_vcpus
  type        = var.domain_type
  cpu = {
    mode = "host-passthrough"
  }
  features = {
    gic = {
      version = "3"
    }
  }
  qemu_commandline = {
    for args in toset(range(local.libvirt_network_count[var.platform])) : args => [
      { value = "-netdev" },
      { value = "vmnet-shared,id=net0" },
      { value = "-device" },
      { value = "virtio-net-device,netdev=net0" }
    ]
  }
  os = {
    type         = "hvm"
    type_arch    = "aarch64"
    type_machine = "virt"
    loader       = var.uefi_loader
    nv_ram = {
      nv_ram   = abspath("${path.root}/.temp/storage/work-${count.index}_VARS.fd")
      template = var.uefi_nvram_template
      format   = "raw"
    }
  }
  devices = {
    disks = [
      {
        driver = {
          type = "qcow2"
        }
        source = {
          file = {
            file = libvirt_volume.work_disk[count.index].id
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      }
    ]
    interfaces = [
      for _ in range(local.libvirt_network_count[var.platform]) : {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = libvirt_network.main[0].name
          }
        }
      }
    ]
  }
}
