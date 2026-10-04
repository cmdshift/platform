locals {
  registry_map = {
    docker = {
      name   = "docker.io"
      remote = "https://registry-1.docker.io"
    }
    gcr = {
      name   = "gcr.io"
      remote = "https://gcr.io"
    }
    ecr = {
      name   = "public.ecr.aws"
      remote = "https://public.ecr.aws"
    }
    ghcr = {
      name   = "ghcr.io"
      remote = "https://ghcr.io"
    }
    k8s = {
      name   = "registry.k8s.io"
      remote = "https://registry.k8s.io"
    }
    quay = {
      name   = "quay.io"
      remote = "https://quay.io"
    }
    mcr = {
      name   = "mcr.microsoft.com"
      remote = "https://mcr.microsoft.com"
    }
    gar = {
      name   = "us-docker.pkg.dev"
      remote = "https://us-docker.pkg.dev"
    }
    kyverno = {
      name   = "reg.kyverno.io"
      remote = "https://reg.kyverno.io"
    }
  }

  registry_volume_name = "platform-registry-data"

  # push identity for locally-built images (cmdshift/platform#171) — the
  # argon2id hash is of the plaintext in images/main.tf's registry_auth
  # (local-only lab credential, same trust tier as secrets/locals.tf)
  push_identity = {
    username = "push-user"
    # argon2id of "push-password-2026" — regenerate via `angos argon` (reads
    # stdin) if the plaintext changes
    password_hash = "$argon2id$v=19$m=19456,t=2,p=1$Tm2MgZgyzecS10ZE9krO/g$lz0BI6XsYxARaGYfWy3dg3gslZtAyPiylTUkN6B2Y/U"
  }
}
