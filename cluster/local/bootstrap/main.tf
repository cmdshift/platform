resource "helm_release" "cilium" {
  depends_on = [
    data.http.kube_apiserver
  ]
  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  # pre-release: 1.20.x crashes at startup on kernel 7.2 hosts — the FnSetRetval
  # probe fails verification (cilium/cilium#48016); revisit when 1.20.2 ships
  version          = "1.21.0-pre.2"
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
        # unencrypted twin: ztunnel mode needs cilium-ztunnel-secrets, which
        # only cert-manager (flux, post-bootstrap) can issue — the flux
        # HelmRelease flips encryption to ztunnel on first reconcile
        # (cmdshift/platform#87)
        enabled = false
      }
      # no standalone envoy DaemonSet in the twin: the bootstrap boots with
      # no L7 consumers (gateway-api is flux's problem, and gateway-api proxy
      # mode runs in the agent) — flux converges the rest on first reconcile
      # (cmdshift/platform#87)
      envoy = {
        enabled = false
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
          # chart 1.21-pre nil-pointers when hubble.ui.httpRoute is absent
          httpRoute = {
            enabled = false
          }
        }
      }
      ipam = {
        mode = "kubernetes"
      }
      k8sServiceHost       = "localhost"
      k8sServicePort       = 7445
      # gateway-api controller prerequisite (cmdshift/platform#70)
      kubeProxyReplacement = true
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
  depends_on = [
    data.http.kube_apiserver
  ]
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
      # Fresh-install bootstrap twins of the Bucket + root Kustomization owned
      # by manifests/local/flux-config/ (that copy carries deletionPolicy,
      # retryInterval, timeout, 10m interval): the hooks are load-bearing only
      # until its first reconcile force-adopts both objects — with
      # ignore_changes = all below, this block never runs against an existing
      # cluster. Never delete the on-cluster objects (flux/README.md).
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
