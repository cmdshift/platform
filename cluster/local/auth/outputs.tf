output "oidc_issuer_url" {
  value = "https://${replace(var.name, "-", ".")}/auth/v1/"
}
