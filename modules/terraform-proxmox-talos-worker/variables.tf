variable "cluster_config" {
  description = "Cluster configuration"
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
  })
}

variable "talos_secrets" {
  description = "Talos secrets from secrets module"
  type = object({
    client_configuration           = any
    worker_machine_configuration   = string
  })
  sensitive = true
}

variable "worker_config" {
  description = "Worker node configuration (base config for all workers)"
  type = object({
    iso                = string
    image              = string
    kernel_modules     = list(string)
    sysctls            = optional(map(string), {})
    kubelet_extraArgs  = optional(map(string), {})
    kubelet_extraConfig = optional(map(any), {})
  })
}

variable "worker_config_workload" {
  description = "Per-workload overrides merged on top of worker_config"
  type = map(object({
    kernel_modules      = optional(list(string))
    sysctls             = optional(map(string))
    kubelet_extraArgs   = optional(map(string))
    kubelet_extraConfig = optional(map(any))
  }))
  default = {}
}

variable "worker_vms" {
  description = "Worker VM configurations grouped by host_node"
  type = map(map(object({
    ip              = string
    cpu             = number
    cpu_affinity    = string # Required, must be unique per VM (e.g., "0-1", "2-3")
    numa            = optional(bool, false)
    ram_dedicated   = number
    disk_size       = number
    bandwidth_limit = number
    datastore_id    = string
    workload        = optional(string)
    additional_disks = optional(map(object({
      size         = number
      datastore_id = string
      filesystem   = optional(string, "xfs")
    })), {})
    # Per-VM config overrides (highest priority)
    kernel_modules      = optional(list(string))
    sysctls             = optional(map(string))
    kubelet_extraArgs   = optional(map(string))
    kubelet_extraConfig = optional(map(any))
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

variable "depends_on_masters" {
  description = "Dependency on master module completion"
  type        = any
  default     = null
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file (for node cleanup on destroy)"
  type        = string
  default     = ""
}
