output "worker_ips" {
  description = "Worker node IP addresses"
  value       = { for k, v in local.worker_vms_flat : k => v.ip }
}

output "worker_vm_ids" {
  description = "Worker node VM IDs"
  value       = { for k, v in proxmox_virtual_environment_vm.worker : k => v.vm_id }
}
