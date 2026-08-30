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
    seaweedfs_s3_config = {
      "s3.json" = jsonencode({
        identities = [
          {
            name = "thanos"
            credentials = [
              {
                accessKey = "thanos-username"
                secretKey = "thanos-password"
              }
            ]
            actions = [
              "Read:thanos",
              "Write:thanos",
              "List:thanos",
              "Delete:thanos"
            ]
          },
          {
            name = "loki"
            credentials = [
              {
                accessKey = "loki-username"
                secretKey = "loki-password"
              }
            ]
            actions = [
              "Read:loki",
              "Write:loki",
              "List:loki",
              "Delete:loki",
              "Read:loki-rules",
              "Write:loki-rules",
              "List:loki-rules",
              "Delete:loki-rules"
            ]
          },
          {
            name = "velero"
            credentials = [
              {
                accessKey = "velero-username"
                secretKey = "velero-password"
              }
            ]
            actions = [
              "Read:velero",
              "Write:velero",
              "List:velero",
              "Delete:velero"
            ]
          }
        ]
      })
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
          endpoint   = "main-s3.objects.svc:8333"
          access_key = "thanos-username"
          secret_key = "thanos-password"
          insecure   = true
        }
      })
    }
  }

  logging = {
    loki_s3_credentials = {
      LOKI_S3_ACCESS_KEY_ID     = "loki-username"
      LOKI_S3_SECRET_ACCESS_KEY = "loki-password"
    }
  }

  backups = {
    velero_s3_credentials = {
      seaweedfs = <<-EOF
        [default]
        aws_access_key_id=velero-username
        aws_secret_access_key=velero-password
      EOF
    }
  }
}
