# =============================================================================
# Talos Secrets (shared between master and worker)
# =============================================================================
module "talos_secrets" {
  source = "../modules/terraform-talos-secrets"

  cluster_config = {
    talos_version    = local.cluster_config.talos_version
    kubernetes       = local.cluster_config.kubernetes
    name             = local.cluster_config.name
    endpoint         = local.cluster_config.endpoint
    podSubnets       = local.cluster_config.podSubnets
    serviceSubnets   = local.cluster_config.serviceSubnets
    proxy_disabled   = local.cluster_config.proxy_disabled
    flannel_disabled = local.cluster_config.flannel_disabled
  }

  master_ips = local.master_ips
}

# =============================================================================
# Talos Master Nodes
# =============================================================================
module "talos_master" {
  source = "../modules/terraform-proxmox-talos-master"

  cluster_config = {
    name            = local.cluster_config.name
    endpoint        = local.cluster_config.endpoint
    kubernetes      = local.cluster_config.kubernetes
    interfaces      = local.cluster_config.interfaces
    root_disk       = local.cluster_config.root_disk
    kernel_logging  = local.cluster_config.kernel_logging
    service_logging = local.cluster_config.service_logging
  }

  talos_secrets = {
    client_configuration               = module.talos_secrets.client_configuration
    controlplane_machine_configuration = module.talos_secrets.controlplane_machine_configuration
  }

  master_config = {
    iso                            = "nocloud-amd64.iso"
    allowSchedulingOnControlPlanes = true
    image                          = "factory.talos.dev/nocloud-installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.11.6"
    kernel_modules                 = [],
    sysctls                        = {},
    kubelet_extraArgs              = {}
  }

  master_vms = {
    "PROXMOX" = {
      "master-0" = {
        ip              = local.master_ips[0]
        cpu             = 2
        numa            = true
        cpu_affinity    = "0-1"
        ram_dedicated   = 4096
        disk_size       = 20
        bandwidth_limit = 0
        datastore_id    = "local-lvm"
      }
      "master-1" = {
        ip              = local.master_ips[1]
        cpu             = 2
        numa            = true
        cpu_affinity    = "2-3"
        ram_dedicated   = 4096
        disk_size       = 20
        bandwidth_limit = 0
        datastore_id    = "local-lvm"
      }
      "master-2" = {
        ip              = local.master_ips[2]
        cpu             = 2
        numa            = true
        cpu_affinity    = "4-5"
        ram_dedicated   = 4096
        disk_size       = 20
        bandwidth_limit = 0
        datastore_id    = "local-lvm"
      }
    }
  }

  network    = local.network
  proxmox    = local.proxmox
  master_ips = local.master_ips

  kubeconfig_path  = "${path.module}/kubeconfig.yaml"
  talosconfig_path = "${path.module}/talosconfig.yaml"
}

# =============================================================================
# Master Outputs
# =============================================================================
output "kubeconfig" {
  description = "Kubernetes configuration for kubectl access"
  value       = module.talos_master.kubeconfig
  sensitive   = true
}

output "talosconfig" {
  description = "Talos configuration for talosctl access"
  value       = module.talos_master.talosconfig
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.talos_master.cluster_endpoint
}

output "master_ips" {
  description = "Master node IP addresses"
  value       = module.talos_master.master_ips
}

output "master_vm_ids" {
  description = "Master node VM IDs"
  value       = module.talos_master.master_vm_ids
}
