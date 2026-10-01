locals {
  libvirt_network_count = {
    linux = 1
    macos = 0
  }

  nvram_names = concat(
    [for i in range(var.ctrl_nodes) : "ctrl-${i}"],
    [for i in range(var.work_nodes) : "work-${i}"],
    ["infra"]
  )
}
