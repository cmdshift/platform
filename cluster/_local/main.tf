resource "libvirt_pool" "main" {
  name = "main"
  type = "dir"
  target = {
    path = var.pool_path
  }
}

resource "libvirt_network" "main" {
  count     = local.libvirt_network_count[var.host_os]
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
