resource "kubernetes_namespace_v1" "flux_system" {
  depends_on = [
    kubernetes_namespace_v1.flux_system
  ]
  metadata {
    name = "flux-system"
  }
}

# separate secret:
# adding to extra objects
# causes deletion during pivot
resource "kubernetes_secret_v1" "bucket_credentials" {
  metadata {
    name      = "bucket-credentials"
    namespace = "flux-system"
  }
  data = {
    accesskey = local.sync_bucket.access_key
    secretkey = local.sync_bucket.secret_key
  }
  type = "opaque"
  depends_on = [
    kubernetes_namespace_v1.flux_system
  ]
}

# separate secret:
# adding to extra objects
# causes deletion during pivot
resource "kubernetes_secret_v1" "flux_ca" {
  depends_on = [
    kubernetes_namespace_v1.flux_system
  ]
  metadata {
    name      = "flux-ca"
    namespace = "flux-system"
  }
  data = {
    "ca.crt" = local.cloud_trust_bundle
  }
  type = "opaque"
}

resource "helm_release" "flux" {
  depends_on = [
    kubernetes_namespace_v1.flux_system
  ]
  name          = "flux"
  repository    = "https://fluxcd-community.github.io/helm-charts"
  chart         = "flux2"
  version       = var.flux_chart_version
  namespace     = "flux-system"
  wait          = true
  wait_for_jobs = true
  values = [
    yamlencode({
      imageAutomationController = {
        create = false
      }
      imageReflectionController = {
        create = false
      }
      notificationController = {
        create = false
      }
      extraObjects = [
        {
          apiVersion = "source.toolkit.fluxcd.io/v1"
          kind       = "Bucket"
          metadata = {
            name      = "main"
            namespace = "flux-system"
            annotations = {
              "helm.sh/hook" = "post-install"
            }
          }
          spec = {
            interval   = "5s"
            endpoint   = local.sync_bucket.endpoint
            bucketName = local.sync_bucket.name
            secretRef = {
              name = "bucket-credentials"
            }
            certSecretRef = {
              name = "flux-ca"
            }
          }
        },
        {
          apiVersion = "kustomize.toolkit.fluxcd.io/v1"
          kind       = "Kustomization"
          metadata = {
            name      = "local"
            namespace = "flux-system"
            annotations = {
              "helm.sh/hook" = "post-install"
            }
          }
          spec = {
            interval = "5s"
            sourceRef = {
              kind = "Bucket"
              name = "main"
            }
            path    = "./manifests/local"
            prune   = true
            timeout = "1m"
          }
        }
      ]
    })
  ]
}

resource "kubernetes_namespace_v1" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_secret_v1" "cert_manager_ca" {
  metadata {
    name      = "intermediate-ca"
    namespace = "cert-manager"
  }
  data = {
    "tls.crt" = local.intermediate_ca.crt
    "tls.key" = local.intermediate_ca.key
  }
  depends_on = [
    kubernetes_namespace_v1.cert_manager
  ]
}
