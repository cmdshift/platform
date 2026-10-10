data "docker_registry_image" "busybox" {
  name = "index.docker.io/library/busybox:1.38.0"
}

data "local_sensitive_file" "intermediate_ca_crt" {
  filename = var.intermediate_ca_crt_path
}

data "local_sensitive_file" "intermediate_ca_key" {
  filename = var.intermediate_ca_key_path
}
