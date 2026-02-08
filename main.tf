# Docker Swarm Infrastructure - Terraform Configuration
# Single Swarm Cluster: 3 App Nodes + 3 Infra Nodes
# Storage: ZFS Tank pool on all Proxmox hosts
# Networks: VLAN 4 (Cluster) + VLAN 12 (Storage)

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = var.proxmox_api_token
  insecure  = true

  # IMPORTANT: Proxmox API Configuration
  # - Use terraform apply -parallelism=2 to prevent HTTP 596 timeouts
  # - DO NOT use timeout blocks - not supported by provider

  ssh {
    agent    = true
    username = "root"
    node {
      name    = "pve01"
      address = "pve01.hornung-bn.de"
    }
    node {
      name    = "pve02"
      address = "192.168.2.11"
    }
    node {
      name    = "pve03"
      address = "192.168.2.12"
    }
  }
}
