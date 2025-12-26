# =============================================================================
# LXC Containers (Nginx Load Balancer)
# =============================================================================
module "nginx_lb" {
  source = "../modules/terraform-proxmox-lxc"

  lxc_containers = {
    "ayumu" = {
      "nginx_master_lb" = {
        ip              = local.master_endpoint
        cpu             = 0.5
        ram_dedicated   = 0.5
        disk_size       = 3
        bandwidth_limit = 0
        datastore_id    = "teamgroup-ssd"
        template        = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
        password        = "aaaaa"
        nginx_master_lb = true
      }
    }
  }

  nginx_lb_config = {
    master_ips = local.master_ips
  }

  network = local.network
  proxmox = local.proxmox
}

# =============================================================================
# LXC Outputs
# =============================================================================
output "nginx_lb_ips" {
  description = "Nginx load balancer IPs"
  value       = module.nginx_lb.container_ips
}

output "nginx_lb_ids" {
  description = "Nginx load balancer container IDs"
  value       = module.nginx_lb.container_ids
}
