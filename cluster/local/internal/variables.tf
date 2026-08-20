variable "name" {
  type = string
}

variable "hostname" {
  type = string
}

variable "net" {
  type = object({
    bridge_network_id  = string
    private_network_id = string
    private_ip         = string
  })
}

variable "nodes" {
  type = list(object({
    name = string
    ipv4 = string
  }))
}