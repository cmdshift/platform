output "intermediate_ca_key_path" {
  value = abspath(local_sensitive_file.intermediate_key.filename)
}

output "intermediate_ca_crt_path" {
  value = abspath(local_sensitive_file.intermediate_crt.filename)
}

output "cloud_pem_path" {
  value = abspath(local_sensitive_file.cloud_pem.filename)
}
