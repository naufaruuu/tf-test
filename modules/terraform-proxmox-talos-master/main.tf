locals {
  network_cidr      = var.network.cidr
  primary_interface = keys(var.cluster_config.interfaces)[0]
  iso_id            = "local:iso/${var.master_config.iso}"

  # Flatten nested VM maps: host_node -> vm_name -> config
  master_vms_flat = merge([
    for host_node, vms in var.master_vms : {
      for vm_name, config in vms : vm_name => merge(config, { host_node = host_node })
    }
  ]...)

  # Convert to ordered list for sequential operations
  master_vms_list = [
    for k in sort(keys(local.master_vms_flat)) : merge(local.master_vms_flat[k], { name = k })
  ]

  # Helper to generate config patches
  config_patches = {
    for k, v in local.master_vms_flat : k => concat(
      # Main machine configuration patch
      [
        yamlencode({
          machine = merge(
            {
              network = {
                hostname    = k
                nameservers = var.network.dns
                interfaces = [{
                  interface = local.primary_interface
                  mtu       = var.network.mtu
                  addresses = ["${v.ip}/${local.network_cidr}"]
                  routes    = var.cluster_config.interfaces[local.primary_interface].routes
                }]
              }
              kubelet = merge(
                {
                  image = "ghcr.io/siderolabs/kubelet:${var.cluster_config.kubernetes}"
                },
                length(var.master_config.kubelet_extraArgs) > 0 ? {
                  extraArgs = var.master_config.kubelet_extraArgs
                } : {}
              )
              install = {
                disk  = var.cluster_config.root_disk
                image = var.master_config.image
              }
              kernel = {
                modules = [for mod in var.master_config.kernel_modules : { name = mod }]
              }
              sysctls = var.master_config.sysctls
            },
            # Service logging (machine.logging.destinations)
            var.cluster_config.service_logging.enabled ? {
              logging = {
                destinations = [{
                  endpoint = var.cluster_config.service_logging.url
                  format   = "json_lines"
                }]
              }
            } : {},
            # Host DNS feature
            var.cluster_config.hostDNS.enabled ? {
              features = {
                hostDNS = {
                  enabled              = true
                  forwardKubeDNSToHost = var.cluster_config.hostDNS.forwardKubeDNSToHost
                }
              }
            } : {}
          )
          cluster = {
            allowSchedulingOnControlPlanes = var.master_config.allowSchedulingOnControlPlanes
          }
        })
      ],
      # Kernel logging (KmsgLogConfig)
      var.cluster_config.kernel_logging.enabled ? [
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KmsgLogConfig"
          name       = "kernel-logs"
          url        = var.cluster_config.kernel_logging.url
        })
      ] : []
    )
  }
}

# Cleanup helper - runs before VM destroy
resource "null_resource" "master_cleanup" {
  for_each = local.master_vms_flat

  triggers = {
    node_name        = each.key
    kubeconfig_path  = var.kubeconfig_path
    talosconfig_path = var.talosconfig_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning up master node ${self.triggers.node_name} before destroy..."
      NODE_NAME="${self.triggers.node_name}"
      KUBECONFIG_PATH="${self.triggers.kubeconfig_path}"
      TALOSCONFIG_PATH="${self.triggers.talosconfig_path}"

      # Try to drain and delete from Kubernetes
      if [ -n "$KUBECONFIG_PATH" ] && [ -f "$KUBECONFIG_PATH" ]; then
        echo "Draining node $NODE_NAME..."
        kubectl --kubeconfig "$KUBECONFIG_PATH" drain "$NODE_NAME" \
          --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>/dev/null || true

        echo "Deleting node $NODE_NAME from Kubernetes..."
        kubectl --kubeconfig "$KUBECONFIG_PATH" delete node "$NODE_NAME" --timeout=30s 2>/dev/null || true
      else
        echo "Kubeconfig not found at $KUBECONFIG_PATH, skipping K8s cleanup"
      fi

      # Try to remove from etcd (requires talosconfig and a healthy node)
      if [ -n "$TALOSCONFIG_PATH" ] && [ -f "$TALOSCONFIG_PATH" ]; then
        echo "Attempting to remove $NODE_NAME from etcd..."
        # Get member ID by hostname
        MEMBER_ID=$(talosctl --talosconfig "$TALOSCONFIG_PATH" etcd members 2>/dev/null | grep "$NODE_NAME" | awk '{print $2}' || true)
        if [ -n "$MEMBER_ID" ] && [ "$MEMBER_ID" != "" ]; then
          talosctl --talosconfig "$TALOSCONFIG_PATH" etcd remove-member "$MEMBER_ID" 2>/dev/null || true
        fi
      else
        echo "Talosconfig not found at $TALOSCONFIG_PATH, skipping etcd cleanup"
      fi

      echo "Cleanup complete for $NODE_NAME"
    EOT
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}

# Create Master VMs with cloud-init for static IP (all in parallel)
resource "proxmox_virtual_environment_vm" "master" {
  for_each = local.master_vms_flat

  name        = each.key
  description = "Talos Kubernetes Master - ${var.cluster_config.name}"
  tags        = ["talos", "master", var.cluster_config.name]
  node_name   = each.value.host_node

  agent {
    enabled = true
    timeout = "5m"
  }

  cpu {
    cores    = each.value.cpu
    type     = "host"
    affinity = each.value.cpu_affinity
    numa     = each.value.numa
  }

  memory {
    dedicated = each.value.ram_dedicated
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = each.value.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_size
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  cdrom {
    file_id   = local.iso_id
    interface = "ide3"
  }

  network_device {
    bridge     = "vmbr0"
    model      = "virtio"
    rate_limit = each.value.bandwidth_limit > 0 ? each.value.bandwidth_limit : null
  }

  operating_system {
    type = "l26"
  }

  vga {
    type   = "virtio"
    memory = 16
  }

  # Cloud-init for nocloud - sets static IP on boot
  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.network_cidr}"
        gateway = var.network.gateway
      }
    }
    dns {
      servers = var.network.dns
    }
  }

  boot_order = ["scsi0", "ide3"]
  on_boot    = true

  lifecycle {
    ignore_changes = [cdrom, initialization]
  }

  # Cleanup runs before VM destroy via null_resource dependency
  depends_on = [null_resource.master_cleanup]
}

# Create Talos client configuration
data "talos_client_configuration" "cluster" {
  cluster_name         = var.cluster_config.name
  client_configuration = var.talos_secrets.client_configuration
  endpoints            = var.master_ips

  depends_on = [proxmox_virtual_environment_vm.master]
}

# Write talosconfig to temp file for health checks
resource "local_file" "talosconfig" {
  content         = data.talos_client_configuration.cluster.talos_config
  filename        = "${path.module}/.talosconfig.tmp"
  file_permission = "0600"
}

# ============================================================================
# PARALLEL CONFIG APPLY - Apply to all masters, then bootstrap, then wait for etcd
# ============================================================================

# Step 1: Apply config to ALL masters in parallel
resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.master_vms_flat

  client_configuration        = var.talos_secrets.client_configuration
  machine_configuration_input = var.talos_secrets.controlplane_machine_configuration

  node     = each.value.ip
  endpoint = each.value.ip

  config_patches = local.config_patches[each.key]

  depends_on = [proxmox_virtual_environment_vm.master]
}

# Step 2: Wait for master-0 apid to be responding (ready for bootstrap)
resource "null_resource" "wait_for_master_0" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for master-0 (${local.master_vms_list[0].ip}) apid to be ready..."
      for i in $(seq 1 90); do
        # Check if apid is responding by querying services
        if talosctl --talosconfig ${local_file.talosconfig.filename} -n ${local.master_vms_list[0].ip} -e ${local.master_vms_list[0].ip} services 2>/dev/null | grep -q "apid.*Running"; then
          echo "Master-0 apid is ready"
          exit 0
        fi
        echo "Attempt $i/90: waiting for apid..."
        sleep 5
      done
      echo "Timeout waiting for master-0 apid"
      exit 1
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [talos_machine_configuration_apply.controlplane, local_file.talosconfig]
}

# Step 3: Bootstrap on master-0
resource "talos_machine_bootstrap" "cluster" {
  client_configuration = var.talos_secrets.client_configuration
  node                 = local.master_vms_list[0].ip
  endpoint             = local.master_vms_list[0].ip

  depends_on = [null_resource.wait_for_master_0]
}

# Step 4: Wait for ALL masters to join etcd as voters
resource "null_resource" "wait_for_etcd_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for all ${length(local.master_vms_list)} masters to join etcd as voters..."
      EXPECTED_VOTERS=${length(local.master_vms_list)}

      for i in $(seq 1 120); do
        # Count voters (lines ending with "false" = not a learner)
        VOTER_COUNT=$(talosctl --talosconfig ${local_file.talosconfig.filename} -n ${local.master_vms_list[0].ip} -e ${local.master_vms_list[0].ip} etcd members 2>/dev/null | grep -c "false$" || echo "0")

        if [ "$VOTER_COUNT" = "$EXPECTED_VOTERS" ]; then
          echo "All $EXPECTED_VOTERS masters are now voters in etcd"
          talosctl --talosconfig ${local_file.talosconfig.filename} -n ${local.master_vms_list[0].ip} -e ${local.master_vms_list[0].ip} etcd members
          exit 0
        fi
        echo "Attempt $i/120: $VOTER_COUNT/$EXPECTED_VOTERS voters in etcd"
        sleep 5
      done
      echo "Timeout waiting for all masters to join etcd"
      exit 1
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [talos_machine_bootstrap.cluster]
}

# Retrieve kubeconfig after all masters are in etcd
resource "talos_cluster_kubeconfig" "cluster" {
  client_configuration = var.talos_secrets.client_configuration
  node                 = local.master_vms_list[0].ip
  endpoint             = local.master_vms_list[0].ip

  depends_on = [null_resource.wait_for_etcd_cluster]
}
