locals {
  k8s_client_config = data.terraform_remote_state.main.outputs.bootstrap.k8s_client_config
  flux_bucket       = data.terraform_remote_state.main.outputs.bootstrap.flux_bucket
}
