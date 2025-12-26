# Flatten nested container maps: host_node -> container_name -> config
locals {
  lxc_containers_flat = merge([
    for host_node, containers in var.lxc_containers : {
      for container_name, config in containers : container_name => merge(config, { host_node = host_node })
    }
  ]...)

  # Filter containers with nginx_master_lb = true
  nginx_lb_containers = {
    for name, config in local.lxc_containers_flat : name => config if config.nginx_master_lb == true
  }
}

# LXC Container resources
resource "proxmox_virtual_environment_container" "lxc" {
  for_each = local.lxc_containers_flat

  node_name = each.value.host_node
  vm_id     = each.value.vm_id # Auto-assigned by Proxmox if null

  description   = "LXC container: ${each.key}"
  tags          = ["lxc", each.key]
  unprivileged  = each.value.unprivileged
  start_on_boot = each.value.start_on_boot
  started       = true

  initialization {
    hostname = replace(each.key, "_", "-")

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network.cidr}"
        gateway = coalesce(each.value.gateway, var.network.gateway)
      }
    }

    dns {
      servers = each.value.dns != null ? [each.value.dns] : var.network.dns
    }

    user_account {
      password = each.value.password
    }
  }

  cpu {
    cores = ceil(each.value.cpu)
  }

  memory {
    dedicated = ceil(each.value.ram_dedicated * 1024)
  }

  disk {
    datastore_id = each.value.datastore_id
    size         = each.value.disk_size
  }

  network_interface {
    name       = "eth0"
    bridge     = "vmbr0"
    rate_limit = each.value.bandwidth_limit > 0 ? each.value.bandwidth_limit : null
  }

  operating_system {
    template_file_id = "local:vztmpl/${each.value.template}"
    type             = "ubuntu"
  }

  features {
    nesting = true
  }
}

# Configure nginx as K8s API load balancer for containers with nginx_master_lb = true
resource "null_resource" "nginx_lb_setup" {
  for_each = var.nginx_lb_config != null ? local.nginx_lb_containers : {}

  triggers = {
    container_id = proxmox_virtual_environment_container.lxc[each.key].vm_id
    master_ips   = join(",", var.nginx_lb_config.master_ips)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      # Wait for container to be ready
      sleep 10

      PROXMOX_HOST="${trimsuffix(trimprefix(var.proxmox.endpoint, "https://"), ":8006")}"
      PROXMOX_USER="${var.proxmox.ssh_username}"
      PROXMOX_PASS="${var.proxmox.ssh_password}"
      CONTAINER_ID="${proxmox_virtual_environment_container.lxc[each.key].vm_id}"

      # Use pct exec via Proxmox host to configure nginx
      sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no "$PROXMOX_USER@$PROXMOX_HOST" << ENDSSH
pct exec $CONTAINER_ID -- bash -c 'apt-get update && apt-get install -y nginx libnginx-mod-stream'

pct exec $CONTAINER_ID -- bash -c 'cat > /etc/nginx/nginx.conf << "EOF"
load_module /usr/lib/nginx/modules/ngx_stream_module.so;

user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
    worker_connections 768;
}

stream {
    log_format basic \\\$remote_addr [\\\$time_local] \\\$protocol \\\$status \\\$bytes_sent \\\$bytes_received \\\$session_time;

    access_log /var/log/nginx/k8s-access.log basic;
    error_log  /var/log/nginx/k8s-error.log;

    upstream k8s_api {
        least_conn;
${join("\n", [for ip in var.nginx_lb_config.master_ips : "        server ${ip}:6443 max_fails=3 fail_timeout=30s;"])}
    }

    server {
        listen 6443;
        proxy_pass k8s_api;
        proxy_timeout 10m;
        proxy_connect_timeout 5s;
    }

    upstream talos_api {
        least_conn;
${join("\n", [for ip in var.nginx_lb_config.master_ips : "        server ${ip}:50000 max_fails=3 fail_timeout=30s;"])}
    }

    server {
        listen 50000;
        proxy_pass talos_api;
        proxy_timeout 10m;
        proxy_connect_timeout 5s;
    }
}
EOF'

pct exec $CONTAINER_ID -- bash -c 'nginx -t && systemctl restart nginx && systemctl enable nginx'
echo "Nginx configured as K8s API load balancer: ${each.key}"
ENDSSH
    EOT
  }

  depends_on = [
    proxmox_virtual_environment_container.lxc
  ]
}

# Output container IPs
output "container_ips" {
  description = "Map of container names to IPs"
  value = {
    for k, v in local.lxc_containers_flat : k => v.ip
  }
}

output "container_ids" {
  description = "Map of container names to VM IDs"
  value = {
    for k, v in proxmox_virtual_environment_container.lxc : k => v.vm_id
  }
}
