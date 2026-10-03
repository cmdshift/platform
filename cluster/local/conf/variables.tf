variable "k8s_version" {
  type    = string
  default = "1.36.4"
}

variable "talos_version" {
  type    = string
  default = "1.13.9"
}

variable "external_hostname" {
  type    = string
  default = "cloud.test"
}

variable "internal_hostname" {
  type    = string
  default = "local.test"
}

variable "ctrl_nodes" {
  type    = number
  default = 1 # single-node etcd (cmdshift/platform#173) — HA etcd's install-burst and loss-simulation complexity isn't worth the RAM/CPU on a testbed
}

variable "work_nodes" {
  type    = number
  default = 2 # cilium gatewayAPI binds hostNetwork ports on work nodes — too few starve those placements
}
