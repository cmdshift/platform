terraform {
  required_providers {
    docker-push = {
      source                = "kreuzwerker/docker"
      configuration_aliases = [docker-push.push]
    }
  }
}
