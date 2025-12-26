# =============================================================================
# Shared Configuration
# =============================================================================
locals {
  proxmox = {
    endpoint     = "https://192.168.95.6:8006"
    insecure     = true
    username     = "root@pam"
    password     = "P@ssw0rd"
  }

  network = {
    gateway = "192.168.95.1"
    cidr    = 24
    dns     = ["1.1.1.1", "8.8.8.8"]
    mtu     = 1492
  }

  # K8s API load balancer endpoint
  master_endpoint = "192.168.95.220"
  master_ips      = ["192.168.95.210", "192.168.95.211", "192.168.95.212"]

  # Shared cluster configuration
  cluster_config = {
    talos_version    = "v1.12.0"
    kubernetes       = "v1.34.2"
    name             = "titanium-stg"
    endpoint         = local.master_endpoint
    podSubnets       = "10.100.0.0/16"
    serviceSubnets   = "10.200.0.0/16"
    root_disk        = "/dev/sda"
    proxy_disabled   = true
    flannel_disabled = true
    kernel_logging   = {
      enabled = true
      url     = "udp://127.0.0.1:6050"
    }
    service_logging  = {
      enabled = true
      url     = "udp://127.0.0.1:6051"
    } 
    interfaces = {
      "eth0" = {
        routes = [{
          network = "0.0.0.0/0"
          gateway = local.network.gateway
        }]
      }
    }
  }
}
