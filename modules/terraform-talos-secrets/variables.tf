variable "cluster_config" {
  description = "Cluster configuration"
  type = object({
    talos_version    = string
    kubernetes       = string
    name             = string
    endpoint         = string
    podSubnets       = string
    serviceSubnets   = string
    proxy_disabled   = bool
    flannel_disabled = bool
  })

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.cluster_config.talos_version))
    error_message = "Talos version must be in format vX.Y.Z (e.g., v1.10.3)"
  }

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.cluster_config.kubernetes))
    error_message = "Kubernetes version must be in format vX.Y.Z (e.g., v1.33.7)"
  }

  validation {
    condition     = !can(regex("/", var.cluster_config.endpoint))
    error_message = "Endpoint must be an IP address without CIDR"
  }
}

variable "master_ips" {
  description = "List of master node IPs for certSANs"
  type        = list(string)
}
