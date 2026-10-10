resource "tls_private_key" "intermediate_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "intermediate_key" {
  content         = tls_private_key.intermediate_key.private_key_pem
  filename        = "${path.module}/../.temp/tls/intermediate_ca.key"
  file_permission = "0600"
}

resource "tls_cert_request" "intermediate_csr" {
  private_key_pem = tls_private_key.intermediate_key.private_key_pem
  subject {
    common_name  = "Platform"
    organization = "NA"
  }
}

resource "tls_locally_signed_cert" "intermediate_crt" {
  cert_request_pem      = tls_cert_request.intermediate_csr.cert_request_pem
  ca_cert_pem           = file("${path.module}/../.temp/tls/root_ca.crt")
  ca_private_key_pem    = file("${path.module}/../.temp/tls/root_ca.key")
  validity_period_hours = 87600
  is_ca_certificate     = true
  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

resource "local_sensitive_file" "intermediate_crt" {
  content         = tls_locally_signed_cert.intermediate_crt.cert_pem
  filename        = "${path.module}/../.temp/tls/intermediate_ca.crt"
  file_permission = "0600"
}

resource "tls_private_key" "cloud_key" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_cert_request" "cloud_csr" {
  private_key_pem = tls_private_key.cloud_key.private_key_pem
  subject {
    common_name = "*.${var.cloud_hostname}"
  }
  dns_names = ["*.${var.cloud_hostname}"]
}

resource "tls_locally_signed_cert" "cloud_crt" {
  cert_request_pem      = tls_cert_request.cloud_csr.cert_request_pem
  ca_cert_pem           = tls_locally_signed_cert.intermediate_crt.cert_pem
  ca_private_key_pem    = tls_private_key.intermediate_key.private_key_pem
  validity_period_hours = 8760
  is_ca_certificate     = false
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "local_sensitive_file" "cloud_pem" {
  content = join("", [
    tls_locally_signed_cert.cloud_crt.cert_pem,
    tls_locally_signed_cert.intermediate_crt.cert_pem,
    tls_private_key.cloud_key.private_key_pem,
  ])
  filename        = "${path.module}/../.temp/tls/cloud.pem"
  file_permission = "0600"
}
