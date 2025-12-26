terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.80.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Configure Proxmox provider
provider "proxmox" {
  endpoint = var.proxmox.endpoint
  insecure = var.proxmox.insecure

  api_token = try(var.proxmox.api_token, null)
  username  = try(var.proxmox.username, null)
  password  = try(var.proxmox.password, null)

  ssh {
    agent    = var.proxmox.ssh_username == null && var.proxmox.ssh_password == null
    username = try(var.proxmox.ssh_username, null)
    password = try(var.proxmox.ssh_password, null)
  }
}
