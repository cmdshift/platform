resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = "1.20.1"
  namespace        = "kube-system"
  create_namespace = false
  values = [
    yamlencode({
      cgroup = {
        autoMount = {
          enabled = false
        }
        hostRoot = "/sys/fs/cgroup"
      }
      encryption = {
        enabled = true
        type    = "wireguard"
      }
      gatewayAPI = {
        enabled = true
        hostNetwork = {
          enabled = true
          nodes = {
            matchLabels = {
              "k8s-role/work" = ""
            }
          }
        }
      }
      hubble = {
        relay = {
          enabled = true
        }
        ui = {
          enabled = true
        }
      }
      ipam = {
        mode = "kubernetes"
      }
      k8sServiceHost       = "localhost"
      k8sServicePort       = 7445
      kubeProxyReplacement = false # true in the cloud
      l2announcements = {
        enabled = true
      }
      rollOutCiliumPods = true
      securityContext = {
        capabilities = {
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }
    })
  ]
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

resource "kubernetes_namespace_v1" "flux_system" {
  metadata {
    name = "flux-system"
  }
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "bucket_credentials" {
  metadata {
    name      = "bucket-credentials"
    namespace = "flux-system"
    labels = {
      "external-secrets.io/type" = "webhook"
    }
  }
  data = {
    accesskey = local.flux_bucket.access_key
    secretkey = local.flux_bucket.secret_key
  }
  type = "Opaque"
  depends_on = [
    kubernetes_namespace_v1.flux_system
  ]
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}

resource "helm_release" "flux" {
  depends_on = [
    kubernetes_namespace_v1.flux_system,
    helm_release.cilium
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
      kustomizeController = {
        container = {
          additionalArgs = [
            "--requeue-dependency=5s"
          ]
        }
      }
      # The Bucket + root Kustomization below are duplicated in
      # manifests/local/flux-config/ — close enough, not identical (that copy
      # carries deletionPolicy, retryInterval, timeout, 10m interval). These
      # hooks are load-bearing for fresh installs only (CRDs must exist before
      # the Bucket CR can be applied); after first reconcile the flux-config
      # kustomization force-adopts both objects and converges them to its spec.
      # With ignore_changes = all below, this block never runs against an
      # existing cluster.
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
            interval   = "1m"
            endpoint   = local.flux_bucket.endpoint
            bucketName = local.flux_bucket.name
            secretRef = {
              name = "bucket-credentials"
            }
            insecure = true
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
            interval = "1m"
            sourceRef = {
              kind = "Bucket"
              name = "main"
            }
            path  = "./manifests/local"
            prune = true
          }
        }
      ]
    })
  ]
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }
}
