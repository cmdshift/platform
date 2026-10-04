terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

# angos push identity — must match registry/locals.tf push_identity (the
# argon2id hash there is of this plaintext). Provider-level because the
# kreuzwerker provider errors on push without an auth entry for the registry
# host, and we won't write ~/.docker/config.json (cmdshift/platform#171)
provider "docker" {
  registry_auth {
    address  = "registry.cloud.test"
    username = "push-user"
    password = "push-password-2026"
  }
}
