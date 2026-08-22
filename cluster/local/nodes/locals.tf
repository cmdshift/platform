locals {
  ports = {
    k8s    = 6443
    apid   = 50000
    trustd = 50001
  }

  public_endpoint  = "https://${var.cmd.hostname}:${local.ports.k8s}"
  private_endpoint = "https://${var.cmd.private_ip}:${local.ports.k8s}"

  cluster_machine_patch = templatefile("${path.module}/templates/cluster.tftpl.yaml", {
    public_endpoint = local.public_endpoint
    cmd_hostname    = var.cmd.hostname
    cmd_private_ip  = var.cmd.private_ip
    ctrl_cidr       = var.net.ctrl_cidr
  })

  base_machine_patch = templatefile("${path.module}/templates/base.tftpl.yaml", {
    cmd_hostname   = var.cmd.hostname
    cmd_private_ip = var.cmd.private_ip
    ctrl_cidr      = var.net.ctrl_cidr
    work_cidr      = var.net.work_cidr
    dns_private_ip = var.dns.private_ip
  })

  ctrl_machine_patch = templatefile("${path.module}/templates/ctrl.tftpl.yaml", {

  })

  work_machine_patch = templatefile("${path.module}/templates/work.tftpl.yaml", {

  })

  registry_mirror_config_patch = templatefile("${path.module}/templates/registry-mirror-config.tftpl.yaml", {
    registry_hostname = var.registry.hostname
    upstreams         = var.registry.upstreams
  })

  registry_tls_config_patch = templatefile("${path.module}/templates/registry-tls-config.tftpl.yaml", {
    registry_hostname = var.registry.hostname
    ca_bundle_content = "\n${file("${path.root}/.tmp/tls/cloud.bundle")}"
  })

  cilium_machine_patch = yamlencode({
    cluster = {
      inlineManifests = [
        {
          name     = "helm-cilium"
          contents = data.helm_template.cilium.manifest
        }
      ]
    }
  })

  mounts = {
    tmpfs = ["/run", "/system", "/tmp"]
    volume = concat(
      ["/etc/cni", "/etc/kubernetes", "/usr/libexec/kubernetes", "/opt"], # overlays
      ["/var", "/system/state"],                                          # ephemeral
      ["/run/cilium"],
      ["/sys/fs/bpf"]
    )
  }

  boot_node = flatten([
    for node in values(docker_container.ctrl) : [
      for n in node.networks_advanced : n.ipv4_address if n.name == var.net.private_network_id
    ]
  ])[0]
}
