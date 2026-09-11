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
  # loopback-only: the API server and apid are reachable from the host through
  # these published ports (127.0.0.1), not from the LAN
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
    ipv4_address = each.key
  }
  env = [
    "PLATFORM=container",
    "USERDATA=${base64encode(data.talos_machine_configuration.ctrl.machine_configuration)}"
  ]
  # observed peak 4.1Gi; kubelet advertises the VM's full meminfo regardless,
  # so the limit only bounds actual consumption (whole-node OOM on breach)
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

# Converges running nodes to the generated machine config (talosctl
# apply-config) — the iteration path for template changes. USERDATA on the
# containers is first-boot only; once a node has a config applied it persists
# in the /system/state volume, so template changes propagate here without
# recreating containers (cmdshift/platform#73).
resource "talos_machine_configuration_apply" "ctrl" {
  for_each = docker_container.ctrl

  client_configuration        = talos_machine_secrets.main.client_configuration
  machine_configuration_input = data.talos_machine_configuration.ctrl.machine_configuration
  node                        = [for n in each.value.networks_advanced : n.ipv4_address if n.name == var.net.private_network_id][0]
  endpoint                    = local.local_api_ip
  apply_mode                  = "auto"
  # the provider silently retries transport errors within the create timeout —
  # 2m covers a fresh node's apid coming up while keeping a down node a fast,
  # visible failure instead of the 10m default
  timeouts = {
    create = "2m"
  }
}

resource "talos_machine_configuration_apply" "work" {
  for_each = docker_container.work

  client_configuration        = talos_machine_secrets.main.client_configuration
  machine_configuration_input = data.talos_machine_configuration.work.machine_configuration
  node                        = [for n in each.value.networks_advanced : n.ipv4_address if n.name == var.net.private_network_id][0]
  endpoint                    = local.local_api_ip
  apply_mode                  = "auto"
  # applies route through the ctrl node's apid (no host ports on workers), so
  # the ctrl applies must have run first
  depends_on = [talos_machine_configuration_apply.ctrl]
  timeouts = {
    create = "2m"
  }
}

resource "talos_machine_bootstrap" "main" {
  depends_on = [
    talos_machine_configuration_apply.ctrl
  ]
  client_configuration = talos_machine_secrets.main.client_configuration
  node                 = local.boot_node
  endpoint             = local.local_api_ip
  # The provider's default 10m create timeout silently retries every transport
  # error; the healthy path is sub-second, so fail fast and surface the real
  # error (stale Docker port binding — see runbooks/local/cluster-rebuild.md).
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
  endpoint             = local.local_api_ip
  timeouts = {
    create = "10s"
  }
}
