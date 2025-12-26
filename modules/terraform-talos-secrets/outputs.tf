output "client_configuration" {
  description = "Talos client configuration"
  value       = talos_machine_secrets.cluster.client_configuration
  sensitive   = true
}

output "machine_secrets" {
  description = "Talos machine secrets"
  value       = talos_machine_secrets.cluster.machine_secrets
  sensitive   = true
}

output "controlplane_machine_configuration" {
  description = "Controlplane machine configuration"
  value       = data.talos_machine_configuration.controlplane.machine_configuration
  sensitive   = true
}

output "worker_machine_configuration" {
  description = "Worker machine configuration"
  value       = data.talos_machine_configuration.worker.machine_configuration
  sensitive   = true
}

output "cluster_name" {
  description = "Cluster name"
  value       = var.cluster_config.name
}

output "cluster_endpoint" {
  description = "Cluster endpoint"
  value       = var.cluster_config.endpoint
}

output "kubernetes_version" {
  description = "Kubernetes version"
  value       = var.cluster_config.kubernetes
}
