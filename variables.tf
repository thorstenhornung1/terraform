# Terraform Variables for Docker Swarm Cluster
# Architecture: Single Swarm with 3 Infra Nodes (Managers) + 1 Management LXC
# Infra nodes on ZFS Tank / local-lvm with dual VLAN networking

# ============================================================================
# PROXMOX CONFIGURATION
# ============================================================================

variable "proxmox_api_url" {
  description = "Proxmox API endpoint"
  type        = string
  default     = "https://pve01.hornung-bn.de:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token"
  type        = string
  default     = "root@pam!terraform=d3555d52-2615-4173-a470-39e432221a96"
  sensitive   = true
}

# ============================================================================
# NETWORK CONFIGURATION
# ============================================================================

variable "vlan_id" {
  description = "VLAN ID for cluster network (management/applications)"
  type        = number
  default     = 4
}

variable "vlan_id_storage" {
  description = "VLAN ID for storage network (SeaweedFS, Patroni replication)"
  type        = number
  default     = 12
}

variable "network_gateway" {
  description = "Gateway for VLAN 4 cluster network"
  type        = string
  default     = "192.168.4.1"
}

variable "network_gateway_storage" {
  description = "Gateway for VLAN 12 storage network"
  type        = string
  default     = "192.168.12.1"
}

variable "dns_servers" {
  description = "DNS servers (Pi-hole cluster)"
  type        = list(string)
  default     = ["192.168.2.4", "192.168.4.5", "192.168.4.6"]
}

# ============================================================================
# GITHUB CONTAINER REGISTRY (GHCR)
# ============================================================================
# PAT for pulling custom images (e.g., patroni-postgres:16) from GHCR.
# Applied to all Docker nodes via cloud-init so new VMs authenticate on first boot.
# Generate at: https://github.com/settings/tokens?type=beta
#   → Repository: swarm-stacks → Permissions: Packages (Read)

variable "ghcr_user" {
  description = "GitHub username for GHCR authentication"
  type        = string
  default     = "thorstenhornung1"
}

variable "ghcr_pat" {
  description = "GitHub PAT with read:packages scope for GHCR image pulls"
  type        = string
  sensitive   = true
}

# ============================================================================
# VM TEMPLATE & CLOUD-INIT
# ============================================================================

variable "template_id" {
  description = "Ubuntu template VM ID on pve01"
  type        = number
  default     = 9000
}

variable "vm_username" {
  description = "Default VM username for Ansible"
  type        = string
  default     = "ansible"
}

variable "vm_password" {
  description = "Default VM password"
  type        = string
  default     = "ansible123"
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "/Users/thorstenhornung/.ssh/id_ed25519.pub"
}

# ============================================================================
# STORAGE CONFIGURATION
# ============================================================================

variable "storage_pool" {
  description = "Proxmox storage pool for VM disks (ZFS Tank)"
  type        = string
  default     = "tank"
}

# ============================================================================
# INFRASTRUCTURE NODES (Docker Swarm Managers + Patroni PostgreSQL)
# ============================================================================
# These nodes are Swarm Managers and run:
# - Patroni PostgreSQL HA cluster (etcd + postgres)
# - Traefik reverse proxy (via app=true label)
# - HAProxy for PostgreSQL routing
# - Application workloads

variable "infra_node_prefix" {
  description = "Prefix for infrastructure node names"
  type        = string
  default     = "docker-infra"
}

variable "infra_node_cores" {
  description = "CPU cores for infra nodes"
  type        = number
  default     = 4
}

variable "infra_node_memory" {
  description = "Memory for infra nodes in MB"
  type        = number
  default     = 8192
}

variable "infra_node_boot_disk_size" {
  description = "Boot disk size for infra nodes in GB"
  type        = number
  default     = 30
}

variable "infra_nodes" {
  description = "Infrastructure node configuration (per-node data disk sizes and storage)"
  type = map(object({
    node           = string
    vm_id          = number
    ip_vlan4       = string
    ip_vlan12      = string
    data_disk_size = number
    storage_pool   = optional(string)  # Override storage pool (default: var.storage_pool)
  }))
  default = {
    "1" = {
      node           = "pve01"
      vm_id          = 4200
      ip_vlan4       = "192.168.4.40"
      ip_vlan12      = "192.168.12.40"
      data_disk_size = 50   # Limited by tank space on pve01
    }
    "2" = {
      node           = "pve02"
      vm_id          = 4201
      ip_vlan4       = "192.168.4.41"
      ip_vlan12      = "192.168.12.41"
      data_disk_size = 100  # Medium size on pve02
      storage_pool   = "local-lvm"  # ZFS tank on pve02 is full
    }
    "3" = {
      node           = "pve03"
      vm_id          = 4202
      ip_vlan4       = "192.168.4.42"
      ip_vlan12      = "192.168.12.42"
      data_disk_size = 200  # Full size on pve03 (1.2TB available)
    }
  }
}

# ============================================================================
# SWARM-CONTROL LXC CONTAINER (Bootstrap/Recovery Management Node)
# ============================================================================
# Independent management node for Portainer (bootstrap/recovery tool)
# Survives infra node failures for cluster recovery
# Runs as Docker Swarm worker

variable "swarm_control_node" {
  description = "Proxmox node for swarm-control container"
  type        = string
  default     = "pve01"
}

variable "swarm_control_vmid" {
  description = "VM ID for swarm-control LXC container"
  type        = number
  default     = 4300
}

variable "swarm_control_hostname" {
  description = "Hostname for swarm-control container"
  type        = string
  default     = "swarm-control"
}

variable "swarm_control_ip" {
  description = "IP address for swarm-control container (VLAN 4)"
  type        = string
  default     = "192.168.4.50"
}

variable "swarm_control_cores" {
  description = "CPU cores for swarm-control container"
  type        = number
  default     = 4
}

variable "swarm_control_memory" {
  description = "Memory in MB for swarm-control container"
  type        = number
  default     = 6144  # 6GB: Portainer + Swarmpit services
}

variable "swarm_control_disk_size" {
  description = "Disk size in GB for swarm-control container"
  type        = number
  default     = 30
}
