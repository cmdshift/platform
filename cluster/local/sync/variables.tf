variable "name" {
  type = string
}

variable "net" {
  type = object({
    private_ip         = string
    private_network_id = string
  })
}

variable "flux_s3" {
  type = object({
    endpoint   = string
    bucket     = string
    access_key = string
    secret_key = string
  })
}
