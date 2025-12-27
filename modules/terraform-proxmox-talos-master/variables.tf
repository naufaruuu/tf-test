variable "cluster_config" {
  description = "Cluster configuration from secrets module"
  type = object({
    name       = string
    endpoint   = string
    kubernetes = string
    interfaces = map(object({
      routes = list(object({
        network = string
        gateway = string
      }))
    }))
    root_disk = string
    kernel_logging = optional(object({
      enabled = bool
      url     = string
    }), { enabled = false, url = "" })
    service_logging = optional(object({
      enabled = bool
      url     = string
    }), { enabled = false, url = "" })
    hostDNS = optional(object({
      enabled              = bool
      forwardKubeDNSToHost = optional(bool, false)
    }), { enabled = false, forwardKubeDNSToHost = false })
  })
}

variable "talos_secrets" {
  description = "Talos secrets from secrets module"
  type = object({
    client_configuration             = any
    controlplane_machine_configuration = string
  })
  sensitive = true
}

variable "master_config" {
  description = "Master node configuration"
  type = object({
    iso                            = string
    image                          = string
    kernel_modules                 = list(string)
    sysctls                        = optional(map(string), {})
    kubelet_extraArgs              = optional(map(string), {})
    allowSchedulingOnControlPlanes = optional(bool, false)
  })
}

variable "master_vms" {
  description = "Master VM configurations grouped by host_node"
  type = map(map(object({
    ip              = string
    cpu             = number
    cpu_affinity    = string # Required, must be unique per VM (e.g., "0-1", "2-3")
    numa            = optional(bool, false)
    ram_dedicated   = number
    disk_size       = number
    bandwidth_limit = number
    datastore_id    = string
  })))
}

variable "network" {
  description = "Network configuration"
  type = object({
    gateway = string
    cidr    = number
    dns     = optional(list(string), ["1.1.1.1"])
    mtu     = optional(number, 1500)
  })
}

variable "proxmox" {
  description = "Proxmox connection configuration"
  type = object({
    endpoint  = string
    insecure  = bool
    api_token = optional(string)
    username  = optional(string)
    password  = optional(string)
  })
}

variable "master_ips" {
  description = "Static list of master IPs for talosconfig endpoints"
  type        = list(string)
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file (for node cleanup on destroy)"
  type        = string
  default     = ""
}

variable "talosconfig_path" {
  description = "Path to talosconfig file (for etcd cleanup on destroy)"
  type        = string
  default     = ""
}
