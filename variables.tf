# Terraform Variables for K3s Cluster Deployment
# This file makes the infrastructure configuration flexible and maintainable

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
# CLUSTER CONFIGURATION
# ============================================================================

variable "k3s_version" {
  description = "K3s version to install"
  type        = string
  default     = "v1.34.2+k3s1"
}

variable "cluster_name" {
  description = "K3s cluster name prefix"
  type        = string
  default     = "k3s"
}

# ============================================================================
# VM STORAGE CONFIGURATION
# ============================================================================

# Master Nodes
variable "master_disk_size" {
  description = "Disk size for K3s master nodes in GB"
  type        = number
  default     = 25
}

variable "master_memory" {
  description = "Memory for K3s master nodes in MB"
  type        = number
  default     = 4096
}

variable "master_cores" {
  description = "CPU cores for K3s master nodes"
  type        = number
  default     = 2
}

# Worker Nodes Storage
# NOTE: Longhorn will be installed on workers and requires 20-30% overhead
# for replication and snapshots. Plan storage accordingly!
variable "worker_disk_sizes" {
  description = "Disk sizes for K3s worker nodes in GB"
  type        = map(number)
  default = {
    worker-1 = 80  # pve01 (limited by 2 masters on same host)
    worker-2 = 110 # pve02 (larger, only 1 worker)
    worker-3 = 110 # pve03 (larger, only 1 worker)
  }
}

variable "worker_memory" {
  description = "Memory for K3s worker nodes in MB"
  type        = number
  default     = 8192
}

variable "worker_cores" {
  description = "CPU cores for K3s worker nodes"
  type        = number
  default     = 2
}

# ============================================================================
# STORAGE BACKEND CONFIGURATION  
# ============================================================================

variable "storage_backend" {
  description = "Proxmox storage backend per host"
  type        = map(string)
  default = {
    pve01 = "local-lvm"
    pve02 = "local-lvm"
    pve03 = "local-lvm"
  }
}

# ============================================================================
# NETWORK CONFIGURATION
# ============================================================================

variable "vlan_id" {
  description = "VLAN ID for K3s cluster"
  type        = number
  default     = 4
}

variable "network_gateway" {
  description = "Network gateway"
  type        = string
  default     = "192.168.4.1"
}

variable "dns_servers" {
  description = "DNS servers (Pi-hole cluster for local DNS resolution)"
  type        = list(string)
  default     = ["192.168.2.4", "192.168.4.5", "192.168.4.6"] # Primary Pi-hole + VLAN 4 Pi-hole cluster
}

variable "master_ips" {
  description = "IP addresses for masters"
  type        = map(string)
  default = {
    master-1 = "192.168.4.10"
    master-2 = "192.168.4.11"
    master-3 = "192.168.4.12"
  }
}

variable "worker_ips" {
  description = "IP addresses for workers (VLAN 4)"
  type        = map(string)
  default = {
    worker-1 = "192.168.4.13"
    worker-2 = "192.168.4.14"
    worker-3 = "192.168.4.15"
  }
}

variable "master_ips_vlan12" {
  description = "IP addresses for masters (VLAN 12 - Storage Network)"
  type        = map(string)
  default = {
    master-1 = "192.168.12.10"
    master-2 = "192.168.12.11"
    master-3 = "192.168.12.12"
  }
}

variable "worker_ips_vlan12" {
  description = "IP addresses for workers (VLAN 12 - Storage Network)"
  type        = map(string)
  default = {
    worker-1 = "192.168.12.13"
    worker-2 = "192.168.12.14"
    worker-3 = "192.168.12.15"
  }
}

variable "vlan_id_storage" {
  description = "VLAN ID for storage network"
  type        = number
  default     = 12
}

variable "network_gateway_vlan12" {
  description = "Network gateway for VLAN 12"
  type        = string
  default     = "192.168.12.1"
}

# ============================================================================
# VM DISTRIBUTION (Temporary until pve02 tank repaired)
# ============================================================================

variable "vm_distribution" {
  description = "VM to host mapping"
  type        = map(string)
  default = {
    master-1 = "pve01"
    master-2 = "pve02" # Tank repaired - proper distribution
    master-3 = "pve03"
    worker-1 = "pve01"
    worker-2 = "pve02"
    worker-3 = "pve03"
  }
}

variable "vm_ids" {
  description = "VM IDs"
  type        = map(number)
  default = {
    master-1 = 4500
    master-2 = 4501
    master-3 = 4502
    worker-1 = 4510
    worker-2 = 4511
    worker-3 = 4512
  }
}

# ============================================================================
# CLOUD-INIT
# ============================================================================

variable "vm_username" {
  description = "VM username"
  type        = string
  default     = "ansible"
}

variable "vm_password" {
  description = "VM password"
  type        = string
  default     = "ansible123"
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "SSH public key path"
  type        = string
  default     = "/Users/thorstenhornung/.ssh/id_rsa.pub"
}

# ============================================================================
# TEMPLATE
# ============================================================================

variable "template_id" {
  description = "Template VM ID"
  type        = number
  default     = 9000
}

# ============================================================================
# BOOTSTRAP HOST CONFIGURATION
# ============================================================================

variable "bootstrap_host_name" {
  description = "Bootstrap host name"
  type        = string
  default     = "infisical-bootstrap"
}

variable "bootstrap_host_node" {
  description = "Proxmox node for bootstrap host"
  type        = string
  default     = "pve01"
}

variable "bootstrap_host_vm_id" {
  description = "VM ID for bootstrap host"
  type        = number
  default     = 4001
}

variable "bootstrap_host_ip" {
  description = "IP address for bootstrap host"
  type        = string
  default     = "192.168.4.20"
}

variable "bootstrap_host_cores" {
  description = "CPU cores for bootstrap host"
  type        = number
  default     = 2
}

variable "bootstrap_host_memory" {
  description = "Memory for bootstrap host in MB"
  type        = number
  default     = 4096
}

variable "bootstrap_host_disk_size" {
  description = "Disk size for bootstrap host in GB"
  type        = number
  default     = 10
}

variable "bootstrap_host_storage" {
  description = "Storage backend for bootstrap host (ZFS tank for HA)"
  type        = string
  default     = "tank"
}

# ============================================================================
# SEAWEEDFS STORAGE CONFIGURATION
# ============================================================================

variable "seaweedfs_name" {
  description = "SeaweedFS VM name"
  type        = string
  default     = "seaweed3"
}

variable "seaweedfs_node" {
  description = "Proxmox node for SeaweedFS"
  type        = string
  default     = "pve03"
}

variable "seaweedfs_vm_id" {
  description = "VM ID for SeaweedFS"
  type        = number
  default     = 5002
}

variable "seaweedfs_ip" {
  description = "IP address for SeaweedFS (VLAN 12)"
  type        = string
  default     = "192.168.12.50"
}

variable "seaweedfs_ip_vlan4" {
  description = "IP address for SeaweedFS (VLAN 4 - virtual, not primary)"
  type        = string
  default     = "192.168.4.50"
}

variable "seaweedfs_vlan_id" {
  description = "VLAN ID for SeaweedFS storage network"
  type        = number
  default     = 12
}

variable "seaweedfs_gateway" {
  description = "Gateway for VLAN 12 storage network"
  type        = string
  default     = "192.168.12.1"
}

variable "seaweedfs_cores" {
  description = "CPU cores for SeaweedFS"
  type        = number
  default     = 4
}

variable "seaweedfs_memory" {
  description = "Memory for SeaweedFS in MB"
  type        = number
  default     = 8192
}

variable "seaweedfs_boot_disk_size" {
  description = "Boot disk size for SeaweedFS in GB (OS + binary)"
  type        = number
  default     = 20
}

variable "seaweedfs_data_disk_size" {
  description = "Data disk size for SeaweedFS in GB (object storage)"
  type        = number
  default     = 500
}

variable "seaweedfs_data_storage" {
  description = "Storage backend for SeaweedFS data disk (Tank ZFS pool)"
  type        = string
  default     = "tank"
}
