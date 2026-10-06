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
  default = 1

  validation {
    condition     = var.ctrl_nodes % 2 == 1
    error_message = "ctrl node count must be odd (etcd quorum)."
  }
}

variable "work_nodes" {
  type    = number
  default = 2
}
