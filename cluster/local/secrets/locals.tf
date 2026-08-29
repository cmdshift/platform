# RustFS Operator wants a minimum of 8 bytes for accesskey and secretkey, hence "-user"

locals {
  flux_system = {
    bucket_credentials = {
      accesskey = "flux-user"
      secretkey = "password"
    }
  }

  cert_manager = {
    intermediate_ca = {
      "tls.crt" = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.crt"))
      "tls.key" = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.key"))
    }
  }

  objects = {
    tenant_credentials = {
      accesskey = "objects-user"
      secretkey = "password"
    }
  }

  monitoring = {
    main_grafana_credentials = {
      GF_SECURITY_ADMIN_USER     = "root"
      GF_SECURITY_ADMIN_PASSWORD = "secret"
    }
  }
}
