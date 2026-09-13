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

variable "registry_url" {
  type = string
}

variable "token" {
  type      = string
  sensitive = true
}
