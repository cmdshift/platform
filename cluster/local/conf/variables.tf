variable "cloud_hostname" {
  type    = string
  default = "cloud.test"
}

variable "local_hostname" {
  type    = string
  default = "local.test"
}

variable "coredns_version" {
  type    = string
  default = "1.14.6"
}

variable "talos_version" {
  type    = string
  default = "v1.12.11"
}

variable "haproxy_version" {
  type    = string
  default = "3.2.22"
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
