locals {
  s3 = {
    access_key = "rustfsadmin"
    secret_key = "rustfsadmin"
  }

  intermediate_ca = {
    crt = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.crt"))
    key = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.key"))
  }
}
