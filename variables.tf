# Terraform Variables for Docker Swarm Cluster
# Architecture: Single Swarm with 3 App Nodes + 3 Infra Nodes
# All VMs on ZFS Tank storage with dual VLAN networking

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
# APPLICATION NODES (Docker Swarm - Application Workloads)
# ============================================================================
# These nodes run application containers: web apps, APIs, etc.
# All 3 are Swarm Managers for HA

variable "app_node_prefix" {
  description = "Prefix for application node names"
  type        = string
  default     = "docker-app"
}

variable "app_node_cores" {
  description = "CPU cores for app nodes"
  type        = number
  default     = 4
}

variable "app_node_memory" {
  description = "Memory for app nodes in MB"
  type        = number
  default     = 8192
}

variable "app_node_disk_size" {
  description = "Disk size for app nodes in GB"
  type        = number
  default     = 50
}

variable "app_nodes" {
  description = "Application node configuration"
  type = map(object({
    node    = string
    vm_id   = number
    ip_vlan4  = string
    ip_vlan12 = string
  }))
  default = {
    "1" = {
      node      = "pve01"
      vm_id     = 4100
      ip_vlan4  = "192.168.4.30"
      ip_vlan12 = "192.168.12.30"
    }
    "2" = {
      node      = "pve02"
      vm_id     = 4101
      ip_vlan4  = "192.168.4.31"
      ip_vlan12 = "192.168.12.31"
    }
    "3" = {
      node      = "pve03"
      vm_id     = 4102
      ip_vlan4  = "192.168.4.32"
      ip_vlan12 = "192.168.12.32"
    }
  }
}

# ============================================================================
# INFRASTRUCTURE NODES (Docker Swarm - SeaweedFS + Patroni)
# ============================================================================
# These nodes run infrastructure services:
# - SeaweedFS distributed storage cluster
# - PostgreSQL Patroni HA cluster
# Placement constraints ensure these only run on infra nodes
#
# NOTE: Only 2 infra nodes (pve01, pve03) due to storage constraints on pve02
# SeaweedFS/Patroni 3rd instance can run on app node if needed

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
# SWARMPIT LXC CONTAINER (Docker Swarm Management UI)
# ============================================================================
# Swarmpit provides web UI for Docker Swarm management
# Runs as Docker Swarm worker with CouchDB + InfluxDB
# CouchDB Memory Requirements: 4GB minimum for view building spikes

variable "swarmpit_node" {
  description = "Proxmox node for Swarmpit container"
  type        = string
  default     = "pve01"
}

variable "swarmpit_vmid" {
  description = "VM ID for Swarmpit LXC container"
  type        = number
  default     = 4300
}

variable "swarmpit_hostname" {
  description = "Hostname for Swarmpit container"
  type        = string
  default     = "swarmpit-mgmt"
}

variable "swarmpit_ip" {
  description = "IP address for Swarmpit container (VLAN 4)"
  type        = string
  default     = "192.168.4.50"
}

variable "swarmpit_cores" {
  description = "CPU cores for Swarmpit container"
  type        = number
  default     = 4  # 2 for Swarm/Docker, 2 for CouchDB
}

variable "swarmpit_memory" {
  description = "Memory in MB for Swarmpit container"
  type        = number
  default     = 6144  # 6GB: 4GB CouchDB + 2GB Swarmpit/InfluxDB
}

variable "swarmpit_disk_size" {
  description = "Disk size in GB for Swarmpit container"
  type        = number
  default     = 30  # CouchDB data + InfluxDB metrics
}
