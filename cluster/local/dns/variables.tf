variable "name" {
  type = string
}

variable "hostname" {
  type = string
}

variable "net" {
  type = object({
    private_ip          = string
    external_hostname   = string
    external_ip_address = string
    internal_hostname   = string
    internal_ip_address = string
    bridge_network_id   = string
    private_network_id  = string
  })
}

variable "cmd" {
  type = object({
    hostname   = string
    private_ip = string
  })
}
