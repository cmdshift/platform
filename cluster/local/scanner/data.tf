data "docker_registry_image" "scanner" {
  # -trivy variants stopped at 1.9.2; plain image runs `scanner trivy` with the engine mounted in (scan-images.md step 3)
  name = "ghcr.io/project-angos/angos:1.12.5"
}

data "docker_registry_image" "trivy" {
  name = "aquasec/trivy:0.76.2"
}
