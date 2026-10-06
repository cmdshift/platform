locals {
  cluster_secret_raft = "rauthy-raft-local-secret"
  cluster_secret_api  = "rauthy-api-local-secret2"
  encryption_key_id   = "platform"
  encryption_key      = random_bytes.encryption_key.base64
  bootstrap_password  = "secret"
}

resource "random_bytes" "encryption_key" {
  length = 32
}
