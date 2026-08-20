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
}

variable "work_nodes" {
  type    = number
  default = 1
}

variable "storage_access_key_id" {
  type    = string
  default = "rustfsadmin"
}

variable "storage_secret_access_key" {
  type    = string
  default = "rustfsadmin"
}
