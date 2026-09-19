# RustFS Operator wants a minimum of 8 bytes for accesskey and secretkey, hence "-user"

locals {
  flux_system = {
    bucket_credentials = {
      accesskey = "flux-user"
      secretkey = "password"
    }
  }

  # ns refactor cmdshift/platform#31: locals/upload paths mirror the cluster namespaces
  certificates = {
    intermediate_ca = {
      "tls.crt" = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.crt"))
      "tls.key" = trimspace(file("${path.root}/.tmp/tls/intermediate_ca.key"))
    }
  }

  objects = {
    # Seeded S3 credentials for the S3Identity/S3Credentials CR path
    # (cmdshift/platform#125): S3Credentials adopts pre-populated Secrets
    # as-is, so the static values keep matching the workload consumers.
    thanos_s3_credentials = {
      accessKey = "thanos-username"
      secretKey = "thanos-password"
    }

    loki_s3_credentials = {
      accessKey = "loki-username"
      secretKey = "loki-password"
    }

    tempo_s3_credentials = {
      accessKey = "tempo-username"
      secretKey = "tempo-password"
    }
  }

  observability = {
    main_grafana_credentials = {
      GF_SECURITY_ADMIN_USER     = "root"
      GF_SECURITY_ADMIN_PASSWORD = "secret"
    }

    thanos_objstore = {
      "objstore.yaml" = yamlencode({
        type = "s3"
        config = {
          bucket     = "thanos"
          endpoint   = "main-s3.objects.svc:8333"
          access_key = "thanos-username"
          secret_key = "thanos-password"
          insecure   = true
        }
      })
    }

    loki_s3_credentials = {
      LOKI_S3_ACCESS_KEY_ID     = "loki-username"
      LOKI_S3_SECRET_ACCESS_KEY = "loki-password"
    }

    tempo_s3_credentials = {
      TEMPO_S3_ACCESS_KEY_ID     = "tempo-username"
      TEMPO_S3_SECRET_ACCESS_KEY = "tempo-password"
    }
  }

  backups = {
    velero_s3_credentials = {
      default = <<-EOF
        [default]
        aws_access_key_id=backups-user
        aws_secret_access_key=password
      EOF
    }
  }
}
