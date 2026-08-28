locals {
  s3 = {
    access_key = "rustfsadmin"
    secret_key = "rustfsadmin"
  }

  intermediate_ca = {
    crt = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.crt"))
    key = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.key"))
  }

  main_grafana_credentials = {
    GF_SECURITY_ADMIN_USER     = "root"
    GF_SECURITY_ADMIN_PASSWORD = "secret"
  }
}
