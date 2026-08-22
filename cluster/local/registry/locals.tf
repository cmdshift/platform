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
    k8s = {
      name   = "registry.k8s.io"
      remote = "https://registry.k8s.io"
    }
    ghcr = {
      name   = "ghcr.io"
      remote = "https://ghcr.io"
    }
    quay = {
      name   = "quay.io"
      remote = "https://quay.io"
    }
    mcr = {
      name   = "mcr.microsoft.com"
      remote = "https://mcr.microsoft.com"
    }
  }

  registry_volume_name = "platform-registry-data"
}
