locals {
  network_cidr      = var.network.cidr
  primary_interface = keys(var.cluster_config.interfaces)[0]
  iso_id            = "local:iso/${var.worker_config.iso}"

  # Flatten nested VM maps: host_node -> vm_name -> config
  worker_vms_flat = merge([
    for host_node, vms in var.worker_vms : {
      for vm_name, config in vms : vm_name => merge(config, { host_node = host_node })
    }
  ]...)

  # Flatten additional disks: vm_name/disk_name -> disk config with vm context
  additional_disks_flat = merge([
    for vm_name, vm_config in local.worker_vms_flat : {
      for disk_name, disk_config in try(vm_config.additional_disks, {}) : "${vm_name}/${disk_name}" => merge(disk_config, {
        vm_name   = vm_name
        disk_name = disk_name
      })
    }
  ]...)

  # Compute effective config per VM: global → workload → VM (highest priority)
  effective_config = {
    for vm_name, vm_config in local.worker_vms_flat : vm_name => {
      kernel_modules = concat(
        var.worker_config.kernel_modules,
        coalesce(try(var.worker_config_workload[vm_config.workload].kernel_modules, null), []),
        coalesce(vm_config.kernel_modules, [])
      )
      sysctls = merge(
        var.worker_config.sysctls,
        coalesce(try(var.worker_config_workload[vm_config.workload].sysctls, null), {}),
        coalesce(vm_config.sysctls, {})
      )
      kubelet_extraArgs = merge(
        var.worker_config.kubelet_extraArgs,
        coalesce(try(var.worker_config_workload[vm_config.workload].kubelet_extraArgs, null), {}),
        coalesce(vm_config.kubelet_extraArgs, {})
      )
      kubelet_extraConfig = merge(
        var.worker_config.kubelet_extraConfig,
        coalesce(try(var.worker_config_workload[vm_config.workload].kubelet_extraConfig, null), {}),
        coalesce(vm_config.kubelet_extraConfig, {})
      )
    }
  }
}

# Cleanup helper - runs before VM destroy
resource "null_resource" "worker_cleanup" {
  for_each = local.worker_vms_flat

  triggers = {
    node_name       = each.key
    kubeconfig_path = var.kubeconfig_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning up worker node ${self.triggers.node_name} before destroy..."
      NODE_NAME="${self.triggers.node_name}"
      KUBECONFIG_PATH="${self.triggers.kubeconfig_path}"

      # Try to drain and delete from Kubernetes
      if [ -n "$KUBECONFIG_PATH" ] && [ -f "$KUBECONFIG_PATH" ]; then
        echo "Draining node $NODE_NAME..."
        kubectl --kubeconfig "$KUBECONFIG_PATH" drain "$NODE_NAME" \
          --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>/dev/null || true

        echo "Deleting node $NODE_NAME from Kubernetes..."
        kubectl --kubeconfig "$KUBECONFIG_PATH" delete node "$NODE_NAME" --timeout=30s 2>/dev/null || true
      else
        echo "Kubeconfig not found at $KUBECONFIG_PATH, skipping cleanup"
      fi

      echo "Cleanup complete for $NODE_NAME"
    EOT
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}

# Create Worker VMs with cloud-init for static IP
resource "proxmox_virtual_environment_vm" "worker" {
  for_each = local.worker_vms_flat

  name        = each.key
  description = "Talos Kubernetes Worker - ${var.cluster_config.name}"
  tags        = ["talos", "worker", var.cluster_config.name, try(each.value.workload, "")]
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
    serial       = "ROOT"
  }

  # Additional disks for this VM (scsi1, scsi2, etc. based on sorted key order)
  dynamic "disk" {
    for_each = { for idx, key in sort(keys(try(each.value.additional_disks, {}))) : key => {
      config    = each.value.additional_disks[key]
      interface = "scsi${idx + 1}"
    }}
    content {
      datastore_id = disk.value.config.datastore_id
      interface    = disk.value.interface
      size         = disk.value.config.size
      iothread     = true
      ssd          = true
      discard      = "on"
      serial       = upper(disk.key)
    }
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
  depends_on = [null_resource.worker_cleanup]
}

# Apply configuration to worker nodes using static IPs
resource "talos_machine_configuration_apply" "worker" {
  for_each = local.worker_vms_flat

  client_configuration        = var.talos_secrets.client_configuration
  machine_configuration_input = var.talos_secrets.worker_machine_configuration

  node     = each.value.ip  # Use static IP directly - nocloud sets IP on boot
  endpoint = each.value.ip

  config_patches = concat(
    # Main machine configuration patch
    [
      yamlencode({
        machine = merge(
          {
            nodeLabels = merge(
              {
                "node.kubernetes.io/cluster"      = var.cluster_config.name
                "node.kubernetes.io/ip"           = each.value.ip
                "node.kubernetes.io/cpu"          = tostring(each.value.cpu)
                "node.kubernetes.io/memory"       = tostring(each.value.ram_dedicated)
                "node.kubernetes.io/proxmox-host" = each.value.host_node
              },
              each.value.workload != null ? {
                "workload" = each.value.workload
              } : {}
            )
            network = {
              hostname    = each.key
              nameservers = var.network.dns
              interfaces = [{
                interface = local.primary_interface
                mtu       = var.network.mtu
                addresses = ["${each.value.ip}/${local.network_cidr}"]
                routes    = var.cluster_config.interfaces[local.primary_interface].routes
              }]
            }
            kubelet = merge(
              {
                image = "ghcr.io/siderolabs/kubelet:${var.cluster_config.kubernetes}"
              },
              # Merge kubelet extraArgs: effective_config (base + workload + vm) + workload taint
              length(local.effective_config[each.key].kubelet_extraArgs) > 0 || each.value.workload != null ? {
                extraArgs = merge(
                  local.effective_config[each.key].kubelet_extraArgs,
                  each.value.workload != null ? {
                    register-with-taints = "workload=${each.value.workload}:NoSchedule"
                  } : {}
                )
              } : {},
              # Merge kubelet extraConfig: effective_config (base + workload + vm)
              length(local.effective_config[each.key].kubelet_extraConfig) > 0 ? {
                extraConfig = local.effective_config[each.key].kubelet_extraConfig
              } : {},
              # Add extraMounts for additional disks (Talos mounts UserVolumes to /var/mnt/<name>)
              length(try(each.value.additional_disks, {})) > 0 ? {
                extraMounts = [
                  for disk_name, disk_config in each.value.additional_disks : {
                    destination = "/var/mnt/${disk_name}"
                    type        = "bind"
                    source      = "/var/mnt/${disk_name}"
                    options     = ["bind", "rshared", "rw"]
                  }
                ]
              } : {}
            )
            install = {
              disk  = var.cluster_config.root_disk
              image = var.worker_config.image
            }
            kernel = {
              modules = [for mod in local.effective_config[each.key].kernel_modules : { name = mod }]
            }
            sysctls = local.effective_config[each.key].sysctls
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
      })
    ],
    # UserVolumeConfig patches for each additional disk
    [
      for disk_name, disk_config in try(each.value.additional_disks, {}) : yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UserVolumeConfig"
        name       = disk_name
        provisioning = {
          diskSelector = {
            match = "'/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_${upper(disk_name)}' in disk.symlinks"
          }
          minSize = "1GB"
          grow    = true
        }
        filesystem = {
          type = disk_config.filesystem
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

  depends_on = [proxmox_virtual_environment_vm.worker]
}
