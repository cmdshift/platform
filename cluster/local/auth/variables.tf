variable "name" {
  type = string
}

variable "net" {
  type = object({
    private_ip         = string
    private_network_id = string
  })
}
