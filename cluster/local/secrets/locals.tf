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

    thanos_bucket_credentials = {
      accesskey = "username"
      secretkey = "password"
    }
  }

  monitoring = {
    main_grafana_credentials = {
      GF_SECURITY_ADMIN_USER     = "root"
      GF_SECURITY_ADMIN_PASSWORD = "secret"
    }

    thanos_objstore = {
      "objstore.yaml" = yamlencode({
        type = "s3"
        config = {
          bucket     = "thanos"
          endpoint   = "main-hl.objects.svc:9000"
          access_key = "username"
          secret_key = "password"
          insecure   = true
        }
      })
    }
  }
}
