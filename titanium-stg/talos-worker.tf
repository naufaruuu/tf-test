# =============================================================================
# Talos Worker Nodes
# =============================================================================
module "talos_worker" {
  source = "../modules/terraform-proxmox-talos-worker"

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
    client_configuration         = module.talos_secrets.client_configuration
    worker_machine_configuration = module.talos_secrets.worker_machine_configuration
  }

  worker_config = {
    iso            = "talos-nocloud-1.11.6.iso"
    image          = "factory.talos.dev/nocloud-installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.11.6"
    kernel_modules = [
      "nbd", 
      "iscsi_tcp", 
      "configfs", 
      "nf_conntrack"
    ]
    sysctls        = {
      "net.netfilter.nf_conntrack_max" = "524288"
    }
    kubelet_extraArgs = {
      max-pods: "250"
      image-gc-high-threshold: "85"
      image-gc-low-threshold: "80"
      cpu-manager-policy: "static"
      cpu-manager-policy-options: "distribute-cpus-across-numa=true"
      topology-manager-policy: "best-effort"
      topology-manager-scope: "pod"
      eviction-hard: "memory.available<500Mi,nodefs.available<10%"
      feature-gates: "CPUManagerPolicyBetaOptions=true"
    }
    kubelet_extraConfig = {
      #memoryManagerPolicy: "Static"
    }
  }

  worker_config_workload = {
    "tier-0" = {
      kernel_modules = []
      sysctls        = {}
      kubelet_extraArgs = {
        kube-reserved: "cpu=600m,memory=1Gi"
        system-reserved: "cpu=500m,memory=1Gi"
      }
      kubelet_extraConfig = {}
    }
    "tier-naufal" = {
      kernel_modules = []
      sysctls        = {}
      kubelet_extraArgs = {
        reserved-cpus: "1"
        kube-reserved: "memory=1Gi"
        system-reserved: "memory=1Gi"
      }
      kubelet_extraConfig = {}
    }
  }

  worker_vms = {}

  network    = local.network
  proxmox    = local.proxmox

  kubeconfig_path = "${path.module}/kubeconfig.yaml"

  depends_on = [module.talos_master]
}

# =============================================================================
# Worker Outputs
# =============================================================================
output "worker_ips" {
  description = "Worker node IP addresses"
  value       = module.talos_worker.worker_ips
}

output "worker_vm_ids" {
  description = "Worker node VM IDs"
  value       = module.talos_worker.worker_vm_ids
}
