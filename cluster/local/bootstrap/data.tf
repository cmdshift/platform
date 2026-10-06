data "http" "kube_apiserver" {
  url                = "${local.k8s_client_config.host}/version"
  ca_cert_pem        = base64decode(local.k8s_client_config.ca_certificate)
  request_timeout_ms = 3000
  retry {
    attempts     = 60
    min_delay_ms = 1000
    max_delay_ms = 1000
  }
}

data "terraform_remote_state" "main" {
  backend = "local"
  config = {
    path = "${path.root}/../terraform.tfstate"
  }
}
