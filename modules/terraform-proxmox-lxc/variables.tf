variable "proxmox" {
  description = "Proxmox connection configuration"
  type = object({
    endpoint      = string
    insecure      = optional(bool, true)
    api_token     = optional(string)
    username      = optional(string)
    password      = optional(string)
    ssh_username  = optional(string)
    ssh_password  = optional(string)
  })
}

variable "lxc_containers" {
  description = "Map of LXC containers grouped by host_node"
  type = map(map(object({
    vm_id           = optional(number) # Auto-assigned if not specified
    ip              = string
    cpu             = optional(number, 1)
    ram_dedicated   = optional(number, 1)  # in GB
    disk_size       = optional(number, 8)  # in GB
    bandwidth_limit = optional(number, 0)
    datastore_id    = string
    template        = string
    password        = string
    start_on_boot   = optional(bool, true)
    unprivileged    = optional(bool, true)
    gateway         = optional(string)
    dns             = optional(string)
    nginx_master_lb = optional(bool, false)  # If true, configure as K8s API load balancer
  })))
}

variable "network" {
  description = "Network configuration"
  type = object({
    gateway = string
    cidr    = number
    dns     = optional(list(string), ["1.1.1.1"])
  })
}

variable "nginx_lb_config" {
  description = "Nginx load balancer configuration - master IPs to load balance (required if any container has nginx_master_lb = true)"
  type = object({
    master_ips = list(string)  # List of K8s master IPs to load balance
  })
  default = null
}
