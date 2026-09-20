locals {
  ports = {
    k8s  = 6443
    apid = 50000
  }

  # host-side API identity: the ctrl container publishes k8s/apid on the host
  # loopback; the cluster endpoint itself is the ctrl node IP (nodes reach it
  # L2-direct on the private network)
  local_api_ip    = "127.0.0.1"
  ctrl_ip         = cidrhost(var.net.ctrl_cidr, 1)
  public_endpoint = "https://${local.ctrl_ip}:${local.ports.k8s}"

  # reviewed audit policy (cmdshift/platform#90); 1.13/1.14 mechanics in files/audit-policy.yaml
  audit_policy_body = file("${path.module}/files/audit-policy.yaml")

  # platform root CA baked into the machine config for --oidc-ca-file
  # (cmdshift/platform#131); read at apply time from the `just certs` output
  platform_root_ca = trimspace(file("${path.root}/.tmp/tls/root_ca.crt"))

  cluster_machine_patch = templatefile("${path.module}/templates/cluster.tftpl.yaml", {
    public_endpoint = local.public_endpoint
    local_api_ip    = local.local_api_ip
    ctrl_ip         = local.ctrl_ip
    ctrl_cidr       = var.net.ctrl_cidr
    audit_policy    = local.audit_policy_body
  })

  base_machine_patch = templatefile("${path.module}/templates/base.tftpl.yaml", {
    local_api_ip   = local.local_api_ip
    ctrl_ip        = local.ctrl_ip
    ctrl_cidr      = var.net.ctrl_cidr
    work_cidr      = var.net.work_cidr
    dns_private_ip = var.dns.private_ip
  })

  ctrl_machine_patch = templatefile("${path.module}/templates/ctrl.tftpl.yaml", {
    platform_root_ca = local.platform_root_ca
  })

  work_machine_patch = templatefile("${path.module}/templates/work.tftpl.yaml", {

  })

  registry_mirror_config_patch = templatefile("${path.module}/templates/registry-mirror-config.tftpl.yaml", {
    registry_hostname = var.registry.hostname
  })

  user_volume_config_patch = file("${path.module}/files/user-volume-config.yaml")

  mounts = {
    tmpfs = ["/run", "/system", "/tmp"]
    # volume mounts: k8s overlay dirs, node state (/var, /system/state), then cilium
    volume = concat(
      ["/etc/cni", "/etc/kubernetes", "/usr/libexec/kubernetes", "/opt"],
      ["/var", "/system/state"],
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
