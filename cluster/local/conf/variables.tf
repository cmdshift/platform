variable "k8s_version" {
  type    = string
  default = "1.36.4"
}

variable "talos_version" {
  type    = string
  default = "1.13.9"
}

variable "external_hostname" {
  type    = string
  default = "cloud.test"
}

variable "internal_hostname" {
  type    = string
  default = "local.test"
}

variable "ctrl_nodes" {
  type    = number
  default = 1 # 3-node etcd saturates the Docker VM during the install burst (host CPU/IOPS ceiling); 1 node has no quorum trade-off that matters here
}

variable "work_nodes" {
  type    = number
  default = 4 # leave set to 4 for now. cilium/kyverno forces host network
}
