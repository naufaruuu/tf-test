# Generate Talos machine secrets
resource "talos_machine_secrets" "cluster" {
  talos_version = substr(var.cluster_config.talos_version, 1, -1)
}

# Build certSANs list
locals {
  cert_sans = concat(
    [var.cluster_config.endpoint],
    var.master_ips
  )
}

# Generate controlplane machine configuration
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_config.name
  cluster_endpoint   = "https://${var.cluster_config.endpoint}:6443"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = substr(var.cluster_config.talos_version, 1, -1)
  kubernetes_version = var.cluster_config.kubernetes

  docs     = false
  examples = false

  config_patches = [
    yamlencode({
      machine = {
        certSANs = local.cert_sans  # For Talos API certificate (port 50000)
      }
      cluster = {
        apiServer = {
          image    = "registry.k8s.io/kube-apiserver:${var.cluster_config.kubernetes}"
          certSANs = local.cert_sans  # For Kubernetes API certificate (port 6443)
        }
        controllerManager = {
          image = "registry.k8s.io/kube-controller-manager:${var.cluster_config.kubernetes}"
        }
        scheduler = {
          image = "registry.k8s.io/kube-scheduler:${var.cluster_config.kubernetes}"
        }
        network = {
          cni = {
            name = var.cluster_config.flannel_disabled ? "none" : "flannel"
          }
          podSubnets     = [var.cluster_config.podSubnets]
          serviceSubnets = [var.cluster_config.serviceSubnets]
        }
        proxy = {
          disabled = var.cluster_config.proxy_disabled
          image    = var.cluster_config.proxy_disabled ? null : "registry.k8s.io/kube-proxy:${var.cluster_config.kubernetes}"
        }
      }
    })
  ]
}

# Generate worker machine configuration
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_config.name
  cluster_endpoint   = "https://${var.cluster_config.endpoint}:6443"
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = substr(var.cluster_config.talos_version, 1, -1)
  kubernetes_version = var.cluster_config.kubernetes

  docs     = false
  examples = false

  config_patches = [
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = var.cluster_config.flannel_disabled ? "none" : "flannel"
          }
          podSubnets     = [var.cluster_config.podSubnets]
          serviceSubnets = [var.cluster_config.serviceSubnets]
        }
        proxy = {
          disabled = var.cluster_config.proxy_disabled
          image    = var.cluster_config.proxy_disabled ? null : "registry.k8s.io/kube-proxy:${var.cluster_config.kubernetes}"
        }
      }
    })
  ]
}
