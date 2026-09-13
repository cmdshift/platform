# bump in lockstep with the scanner -trivy pin in scanner/data.tf (cmdshift/platform#102)
data "docker_registry_image" "angos" {
  name = "ghcr.io/project-angos/angos:1.8.0"
}
