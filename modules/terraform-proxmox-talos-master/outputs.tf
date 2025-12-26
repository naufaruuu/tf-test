output "kubeconfig" {
  description = "Kubernetes configuration for kubectl access"
  value       = talos_cluster_kubeconfig.cluster.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos configuration for talosctl access"
  value       = data.talos_client_configuration.cluster.talos_config
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = "https://${var.cluster_config.endpoint}:6443"
}

output "master_ips" {
  description = "Master node IP addresses"
  value       = { for k, v in local.master_vms_flat : k => v.ip }
}

output "master_vm_ids" {
  description = "Master node VM IDs"
  value       = { for k, v in proxmox_virtual_environment_vm.master : k => v.vm_id }
}

output "client_configuration" {
  description = "Talos client configuration (for worker module)"
  value       = var.talos_secrets.client_configuration
  sensitive   = true
}

output "etcd_cluster_ready" {
  description = "Marker that etcd cluster is ready with all voters"
  value       = null_resource.wait_for_etcd_cluster.id
}
