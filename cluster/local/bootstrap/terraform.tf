terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.k8s_client_config.host
    client_certificate     = base64decode(local.k8s_client_config.client_certificate)
    client_key             = base64decode(local.k8s_client_config.client_key)
    cluster_ca_certificate = base64decode(local.k8s_client_config.ca_certificate)
  }
}

provider "kubernetes" {
  host                   = local.k8s_client_config.host
  client_certificate     = base64decode(local.k8s_client_config.client_certificate)
  client_key             = base64decode(local.k8s_client_config.client_key)
  cluster_ca_certificate = base64decode(local.k8s_client_config.ca_certificate)
}
