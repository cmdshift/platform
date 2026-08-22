resource "docker_image" "talos" {
  name          = data.docker_registry_image.talos.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.talos.sha256_digest]
}

resource "talos_machine_secrets" "main" {
  talos_version = "v${var.cluster.talos_version}"
}

resource "random_id" "ctrl" {
  for_each    = var.ctrl
  byte_length = 2
}

resource "docker_container" "ctrl" {
  for_each     = var.ctrl
  name         = join("-", compact([each.value.name, random_id.ctrl[each.key].hex]))
  hostname     = join("-", compact([each.value.name, random_id.ctrl[each.key].hex]))
  image        = docker_image.talos.name
  networks_advanced {
    name = var.net.bridge_network_id
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = each.key
  }
  env = [
    "PLATFORM=container",
    "USERDATA=${base64encode(data.talos_machine_configuration.ctrl.machine_configuration)}"
  ]
  privileged = true
  dynamic "mounts" {
    for_each = local.mounts.tmpfs
    content {
      target = mounts.value
      type   = "tmpfs"
    }
  }
  dynamic "mounts" {
    for_each = local.mounts.volume
    content {
      target = mounts.value
      type   = "volume"
    }
  }
  lifecycle {
    ignore_changes = [
      env
    ]
  }
}

resource "docker_image" "haproxy" {
  name          = data.docker_registry_image.haproxy.name
  keep_locally  = true
  pull_triggers = [data.docker_registry_image.haproxy.sha256_digest]
}

resource "docker_container" "cmd" {
  name         = replace(var.cmd.hostname, ".", "-")
  hostname     = var.cmd.hostname
  image        = docker_image.haproxy.name
  networks_advanced {
    name = var.net.bridge_network_id
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = var.cmd.private_ip
    aliases = [
      var.cmd.hostname
    ]
  }
  ports {
    internal = local.ports.k8s
    external = local.ports.k8s
  }
  ports {
    internal = local.ports.apid
    external = local.ports.apid
  }
  upload {
    file = "/usr/local/etc/haproxy/haproxy.cfg"
    content = templatefile("${path.module}/templates/haproxy.tftpl.cfg", {
      nodes = [
        for node in docker_container.ctrl : {
          name = node.name
          ipv4 = [
            for n in node.networks_advanced : n.ipv4_address if n.name == var.net.private_network_id
          ][0]
        }
      ]
    })
  }
}

resource "random_id" "work" {
  for_each    = var.work
  byte_length = 2
}

resource "docker_container" "work" {
  for_each     = var.work
  name         = join("-", compact([each.value.name, random_id.work[each.key].hex]))
  hostname     = join("-", compact([each.value.name, random_id.work[each.key].hex]))
  image        = docker_image.talos.name
  networks_advanced {
    name = var.net.bridge_network_id
  }
  networks_advanced {
    name         = var.net.private_network_id
    ipv4_address = each.key
  }
  env = [
    "PLATFORM=container",
    "USERDATA=${base64encode(data.talos_machine_configuration.work.machine_configuration)}"
  ]
  privileged = true
  dynamic "mounts" {
    for_each = local.mounts.tmpfs
    content {
      target = mounts.value
      type   = "tmpfs"
    }
  }
  dynamic "mounts" {
    for_each = local.mounts.volume
    content {
      target = mounts.value
      type   = "volume"
    }
  }
  lifecycle {
    ignore_changes = [
      env
    ]
  }
}

resource "talos_machine_bootstrap" "main" {
  depends_on = [
    docker_container.cmd,
    docker_container.ctrl
  ]
  client_configuration = talos_machine_secrets.main.client_configuration
  node                 = local.boot_node
  endpoint             = docker_container.cmd.hostname
}

resource "talos_cluster_kubeconfig" "main" {
  depends_on = [
    talos_machine_bootstrap.main
  ]
  client_configuration = talos_machine_secrets.main.client_configuration
  node                 = local.boot_node
  endpoint             = var.cmd.hostname
}