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

variable "work_nodes" {
  type    = number
  default = 4 # cilium gatewayAPI and kyverno bind hostNetwork ports on work nodes — too few starve those placements
}
