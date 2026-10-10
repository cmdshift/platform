variable "name" {
  type = string
}

variable "hostname" {
  type = string
}

variable "cmd_hostname" {
  type = string
}

variable "load_hostname" {
  type = string
}

variable "local_hostname" {
  type = string
}

variable "cloud_hostname" {
  type = string
}

variable "net" {
  type = object({
    private_ip         = string
    load_ip_address    = string
    bridge_network_id  = string
    private_network_id = string
  })
}
