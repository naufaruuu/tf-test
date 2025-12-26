terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.73.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.9.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

provider "proxmox" {
  endpoint = local.proxmox.endpoint
  insecure = local.proxmox.insecure

  username = local.proxmox.username
  password = local.proxmox.password

  ssh {
    agent    = false
    username = split("@", local.proxmox.username)[0] # "root" from "root@pam"
    password = local.proxmox.password
  }
}
