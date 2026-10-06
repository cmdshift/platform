locals {
  flux_system = {
    bucket_credentials = {
      accesskey = "flux-user"
      secretkey = "password"
    }
  }

  certificates = {
    intermediate_ca = {
      "tls.crt" = trimspace(file("${path.module}/../.tmp/tls/intermediate_ca.crt"))
      "tls.key" = trimspace(file("${path.module}/../.tmp/tls/intermediate_ca.key"))
    }
  }

  observability = {
    openobserve_credentials = {
      ZO_ROOT_USER_EMAIL    = "root@cloud.test"
      ZO_ROOT_USER_PASSWORD = "Complexpass#123"
    }

    openobserve_s3_credentials = {
      ZO_S3_ACCESS_KEY = "openobserve-user"
      ZO_S3_SECRET_KEY = "password"
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

    talos_backup_s3_credentials = {
      AWS_ACCESS_KEY_ID     = "backups-user"
      AWS_SECRET_ACCESS_KEY = "password"
    }

    talos_backup_age_public_key = {
      AGE_RECIPIENT_PUBLIC_KEY = age_secret_key.etcd_backup.public_key
    }
  }

  access = {
    oauth2_proxy_credentials = {
      client-id     = "oauth2-proxy"
      client-secret = "LXMLrmq38BZxuBMTINMYVXj97Kt6n0fM44jSOfV7iOmuJZUEpsIId5E7NcBoCqfV"
      cookie-secret = "Zk1MRldtSnhkV2RMY0hOc1pHbHVZWFJzWVhKcGJtZT0="
    }

    platform_root_ca = {
      "ca.crt" = trimspace(file("${path.module}/../.tmp/tls/root_ca.crt"))
    }
  }
}
