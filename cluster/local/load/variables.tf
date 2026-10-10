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

variable "hosts" {
  type = map(map(object({
    hostname   = string
    private_ip = string
    port       = number
  })))
}

variable "ctrl" {
  type = list(object({
    name = string
    ipv4 = string
  }))
}

variable "work" {
  type = list(object({
    name = string
    ipv4 = string
  }))
}

variable "cloud_pem_path" {
  type = string
}

variable "local_hostname" {
  type = string
}

variable "cloud_hostname" {
  type = string
}
