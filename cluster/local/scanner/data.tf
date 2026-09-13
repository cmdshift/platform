# bump in lockstep with the registry pin in registry/data.tf (cmdshift/platform#102)
data "docker_registry_image" "scanner" {
  name = "ghcr.io/project-angos/angos:1.8.0-trivy"
}