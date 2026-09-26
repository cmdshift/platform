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
    # Seeded S3 credentials for the S3Identity/S3Credentials CR path (cmdshift/platform#125):
    # S3Credentials adopts pre-populated Secrets as-is, so the static values keep
    # matching the workload consumers.
    loki_s3_credentials = {
      accessKey = "loki-username"
      secretKey = "loki-password"
    }

    tempo_s3_credentials = {
      accessKey = "tempo-username"
      secretKey = "tempo-password"
    }

    mimir_s3_credentials = {
      accessKey = "mimir-username"
      secretKey = "mimir-password"
    }
  }

  observability = {
    main_grafana_credentials = {
      GF_SECURITY_ADMIN_USER     = "root"
      GF_SECURITY_ADMIN_PASSWORD = "secret"
    }

    loki_s3_credentials = {
      LOKI_S3_ACCESS_KEY_ID     = "loki-username"
      LOKI_S3_SECRET_ACCESS_KEY = "loki-password"
    }

    tempo_s3_credentials = {
      TEMPO_S3_ACCESS_KEY_ID     = "tempo-username"
      TEMPO_S3_SECRET_ACCESS_KEY = "tempo-password"
    }

    mimir_s3_credentials = {
      MIMIR_S3_ACCESS_KEY_ID     = "mimir-username"
      MIMIR_S3_SECRET_ACCESS_KEY = "mimir-password"
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

    # env-style keys — talos-backup reads AWS_* via the Go SDK env chain
    talos_backup_s3_credentials = {
      AWS_ACCESS_KEY_ID     = "backups-user"
      AWS_SECRET_ACCESS_KEY = "password"
    }

    # private key lives only in tfstate + this payload is public half — decryption
    # procedure in runbooks/local/etcd-backups.md
    talos_backup_age_public_key = {
      AGE_RECIPIENT_PUBLIC_KEY = age_secret_key.etcd_backup.public_key
    }
  }

  # oauth2-proxy admin-ingress secrets (cmdshift/platform#41) — shared by all
  # three proxies; the cookie secret must match for the .local.test SSO cookie
  # to validate across apps. client-secret mirrors clients.json's oauth2-proxy
  # client (rauthy: >= 64 chars, token-endpoint validation [a-zA-Z0-9] only,
  # cmdshift/platform#154); root_ca is the platform root (TLS trust for auth.cloud.test).
  access = {
    # single payload = single server path: the webhook provider serves whole
    # JSON docs (no property projection), so the ExternalSecret's dataFrom
    # extract maps the keys directly
    oauth2_proxy_credentials = {
      client-id     = "oauth2-proxy"
      client-secret = "LXMLrmq38BZxuBMTINMYVXj97Kt6n0fM44jSOfV7iOmuJZUEpsIId5E7NcBoCqfV"
      cookie-secret = "Zk1MRldtSnhkV2RMY0hOc1pHbHVZWFJzWVhKcGJtZT0="
    }

    platform_root_ca = {
      "ca.crt" = trimspace(file("${path.root}/.tmp/tls/root_ca.crt"))
    }
  }
}
