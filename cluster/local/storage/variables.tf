variable "name" {
  type = string
}

variable "net" {
  type = object({
    private_network_id = string
    private_ip         = string
  })
}

variable "access_key" {
  type = string
}

variable "secret_key" {
  type = string
}

variable "buckets" {
  type = list(string)
}
