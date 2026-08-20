variable "cluster" {
  type = object({
    name          = string
    k8s_version   = string
    talos_version = string
  })
}

variable "net" {
  type = object({
    bridge_network_id  = string
    private_network_id = string
    ctrl_cidr          = string
    work_cidr          = string
  })
}

variable "dns" {
  type = object({
    private_ip = string
  })
}

variable "cmd" {
  type = object({
    hostname   = string
    private_ip = string
  })
}

variable "ctrl" {
  type = map(object({
    name = string
  }))
}

variable "work" {
  type = map(object({
    name = string
  }))
}
