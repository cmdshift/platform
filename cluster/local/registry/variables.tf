variable "name" {
  type = string
}

variable "net" {
  type = object({
    bridge_network_id  = string
    private_network_id = string
    private_ip         = string
  })
}
