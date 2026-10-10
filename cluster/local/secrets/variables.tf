variable "name" {
  type = string
}

variable "net" {
  type = object({
    private_ip         = string
    private_network_id = string
  })
}

variable "intermediate_ca_crt_path" {
  type = string
}

variable "intermediate_ca_key_path" {
  type = string
}
