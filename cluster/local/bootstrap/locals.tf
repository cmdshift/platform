locals {
  k8s_client_config  = data.terraform_remote_state.main.outputs.bootstrap.k8s_client_config
  sync_bucket        = data.terraform_remote_state.main.outputs.bootstrap.sync_bucket
  intermediate_ca    = data.terraform_remote_state.main.outputs.bootstrap.intermediate_ca
  cloud_trust_bundle = data.terraform_remote_state.main.outputs.bootstrap.cloud_trust_bundle
}
