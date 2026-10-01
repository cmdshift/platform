variable "host_os" {
  type = string
}

variable "libvirt_uri" {
  type = string
}

variable "pool_path" {
  type = string
}

variable "image_arch" {
  type = string
}

variable "domain_type" {
  type = string
}

variable "machine_arch" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "uefi_loader" {
  type = string
}

variable "uefi_nvram_template" {
  type = string
}

variable "ctrl_nodes" {
  type = number
}

variable "work_nodes" {
  type = number
}

variable "ctrl_memory" {
  type = number
}

variable "work_memory" {
  type = number
}

variable "infra_memory" {
  type = number
}

variable "ctrl_vcpus" {
  type = number
}

variable "work_vcpus" {
  type = number
}

variable "infra_vcpus" {
  type = number
}

variable "talos_version" {
  type    = string
  default = "1.14.2"
}

variable "talos_schematic_id" {
  type    = string
  default = "792e9a5d808e95300237c15474b2adbb79873a4709261e13e22ea5d04ee112df"
}

variable "ctrl_disk_gigabytes" {
  type    = number
  default = 16
}

variable "work_disk_gigabytes" {
  type    = number
  default = 32
}

variable "infra_disk_gigabytes" {
  type    = number
  default = 32
}
