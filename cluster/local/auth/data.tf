data "docker_registry_image" "rauthy" {
  name = "ghcr.io/sebadob/rauthy:0.36.2"
}

locals {
  # hiqlite cluster secrets: >= 16 chars, raft/api should differ
  cluster_secret_raft = "rauthy-raft-local-secret"
  cluster_secret_api  = "rauthy-api-local-secret2"
  encryption_key_id   = "localtest"
  encryption_key      = "xS/gD1gX12MoAAJ/Qlhs44Sy/TCknA1Eac6PilcL2zc="
  bootstrap_password  = "secret"
}
