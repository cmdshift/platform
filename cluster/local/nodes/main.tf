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
  for_each = var.ctrl
  name     = join("-", compact([each.value.name, random_id.ctrl[each.key].hex]))
  hostname = join("-", compact([each.value.name, random_id.ctrl[each.key].hex]))
  image    = docker_image.talos.name
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
  # observed peak 4.1Gi; kubelet advertises the VM's full meminfo regardless — the
  # limit only bounds actual consumption (whole-node OOM on breach)
  memory      = 6144
  memory_swap = 6144
  privileged  = true
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
  depends_on = [
    docker_container.ctrl
  ]
  name     = replace(var.cmd.hostname, ".", "-")
  hostname = var.cmd.hostname
  image    = docker_image.haproxy.name
  ports {
    internal = local.ports.k8s
    external = local.ports.k8s
    ip       = "127.0.0.1"
  }
  ports {
    internal = local.ports.apid
    external = local.ports.apid
    ip       = "127.0.0.1"
  }
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
  memory      = 256
  memory_swap = 256
  upload {
    file = "/usr/local/etc/haproxy/haproxy.cfg"
    content = templatefile("${path.module}/templates/haproxy.tftpl.cfg", {
      node_count = length(docker_container.ctrl)
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
  for_each = var.work
  name     = join("-", compact([each.value.name, random_id.work[each.key].hex]))
  hostname = join("-", compact([each.value.name, random_id.work[each.key].hex]))
  image    = docker_image.talos.name
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
  # observed peak 3.0Gi; same limit-vs-scheduler caveat as ctrl
  memory      = 4096
  memory_swap = 4096
  privileged  = true
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
  endpoint             = var.cmd.hostname
  # the default 10m create timeout silently retries every transport error; the healthy
  # path is sub-second, so fail fast (stale Docker port binding — runbooks/local/cluster-rebuild.md)
  timeouts = {
    create = "10s"
  }
}

resource "talos_cluster_kubeconfig" "main" {
  depends_on = [
    talos_machine_bootstrap.main
  ]
  client_configuration = talos_machine_secrets.main.client_configuration
  node                 = local.boot_node
  endpoint             = var.cmd.hostname
  timeouts = {
    create = "10s"
  }
}
