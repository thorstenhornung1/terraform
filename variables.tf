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
  description = "DNS servers (Technitium DNS cluster)"
  type        = list(string)
  default     = ["192.168.4.2", "192.168.4.3", "192.168.4.4"]
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

# ============================================================================
# DEDICATED ETCD LXC CONTAINERS (etcd-4, etcd-5)
# ============================================================================
# Native etcd on systemd — immune to Docker Swarm rollback-induced restart
# policy regressions. Combined with the 3 Docker Swarm etcd instances this
# forms a 5-node etcd cluster (quorum=3, tolerates 2 failures).

variable "etcd_nodes" {
  description = "Dedicated etcd LXC container configuration"
  type = map(object({
    node         = string
    vm_id        = number
    ip_vlan4     = string
    ip_vlan12    = string
    storage_pool = optional(string)  # Override storage pool (default: local-lvm)
  }))
  default = {
    "4" = {
      node         = "pve02"
      vm_id        = 4301
      ip_vlan4     = "192.168.4.53"
      ip_vlan12    = "192.168.12.53"
      storage_pool = "tank"  # local-lvm thin pool full on pve02
    }
    "5" = {
      node         = "pve03"
      vm_id        = 4302
      ip_vlan4     = "192.168.4.54"
      ip_vlan12    = "192.168.12.54"
    }
  }
}

variable "etcd_node_cores" {
  description = "CPU cores for dedicated etcd LXC containers"
  type        = number
  default     = 1
}

variable "etcd_node_memory" {
  description = "Memory in MB for dedicated etcd LXC containers"
  type        = number
  default     = 512
}

variable "etcd_node_disk_size" {
  description = "Disk size in GB for dedicated etcd LXC containers"
  type        = number
  default     = 8
}

variable "etcd_version" {
  description = "etcd version for dedicated LXC containers"
  type        = string
  default     = "v3.5.15"
}

variable "etcd_cluster_token" {
  description = "etcd cluster token (must match Docker Swarm etcd services)"
  type        = string
  default     = "patroni-etcd-cluster"
}

variable "etcd_initial_cluster_state" {
  description = "Initial cluster state for new etcd members (existing = join running cluster)"
  type        = string
  default     = "existing"
}

# ============================================================================
# DEDICATED INFLUXDB VM (air_rescue_tracker + Home Assistant)
# ============================================================================
# Standalone InfluxDB 2.7 instance on pve03 with ZFS Tank storage.
# Stores rescue-helicopter telemetry (2.3GB, infinite retention) and
# Home Assistant metrics (1.7GB, 1yr retention).
# Accessed by: rescue-tracker (Swarm), Grafana (Swarm), Home Assistant (192.168.2.5)

# ============================================================================
# TECHNITIUM DNS CLUSTER (3-Node LXC)
# ============================================================================
# Authoritative + recursive DNS cluster on Debian 12 LXC containers.
# Replaces/augments existing Pi-hole DNS with full-featured DNS server.
# Cluster mode: dns1 = primary, dns2/dns3 = secondary (join to primary).
# All nodes on VLAN 4 — no storage VLAN needed.

variable "dns_nodes" {
  description = "Technitium DNS cluster LXC container configuration"
  type = map(object({
    node         = string
    vm_id        = number
    ip           = string
    storage_pool = optional(string)  # Override storage pool (default: var.storage_pool / tank)
  }))
  default = {
    "1" = {
      node  = "pve01"
      vm_id = 4100
      ip    = "192.168.4.2"
    }
    "2" = {
      node  = "pve02"
      vm_id = 4101
      ip    = "192.168.4.3"
      storage_pool = "tank"  # local-lvm thin pool full on pve02
    }
    "3" = {
      node  = "pve03"
      vm_id = 4102
      ip    = "192.168.4.4"
    }
  }
}

variable "dns_node_cores" {
  description = "CPU cores for DNS LXC containers"
  type        = number
  default     = 1
}

variable "dns_node_memory" {
  description = "Memory in MB for DNS LXC containers"
  type        = number
  default     = 512
}

variable "dns_node_disk_size" {
  description = "Disk size in GB for DNS LXC containers"
  type        = number
  default     = 8
}

# ============================================================================
# DEDICATED INFLUXDB VM (air_rescue_tracker + Home Assistant)
# ============================================================================
# Standalone InfluxDB 2.7 instance on pve03 with ZFS Tank storage.
# Stores rescue-helicopter telemetry (2.3GB, infinite retention) and
# Home Assistant metrics (1.7GB, 1yr retention).
# Accessed by: rescue-tracker (Swarm), Grafana (Swarm), Home Assistant (192.168.2.5)

variable "influxdb_rescue" {
  description = "Dedicated InfluxDB VM configuration"
  type = object({
    node         = string
    vm_id        = number
    ip_vlan4     = string
    ip_vlan12    = string
    cores        = number
    memory       = number
    disk_size    = number
    storage_pool = string
  })
  default = {
    node         = "pve03"
    vm_id        = 4400
    ip_vlan4     = "192.168.4.55"
    ip_vlan12    = "192.168.12.55"
    cores        = 2
    memory       = 4096
    disk_size    = 30
    storage_pool = "tank"
  }
}

# ============================================================================
# FRIGATE OPENVINO TEST LXC (pve03 — Intel iGPU)
# ============================================================================
# Dedicated test container to evaluate Intel iGPU (OpenVINO) for local
# object detection in Frigate 0.17. Replaces/supplements the remote
# Apple Silicon ZMQ detector (192.168.2.236:5555).
# Privileged LXC with /dev/dri passthrough for GPU compute access.
# NOT for production — start_on_boot = false.

variable "frigate_test" {
  description = "Frigate OpenVINO test LXC configuration"
  type = object({
    node         = string
    vm_id        = number
    ip           = string
    cores        = number
    memory       = number
    disk_size    = number
    storage_pool = string
  })
  default = {
    node         = "pve02"
    vm_id        = 4500
    ip           = "192.168.4.60"
    cores        = 4
    memory       = 4096
    disk_size    = 30
    storage_pool = "tank"
  }
}

# ============================================================================
# FRIGATE PRODUCTION LXC (pve03 — Intel iGPU + Ceph Storage)
# ============================================================================
# Dedicated production Frigate NVR on privileged LXC with Intel iGPU (OpenVINO)
# for local object detection. Replaces Docker Swarm frigate-beta stack.
#
# Storage architecture:
#   - CephFS: /config (yml+sh), /clips, /exports (3x replicated)
#   - Ceph RBD: /recordings (1 TB, replica 1), /db (10 GB, replica 3)
#   - Local tmpfs: frame processing cache
#
# Network: Dual-NIC — VLAN 4 (cluster) + VLAN 12 (Ceph storage)
# iGPU: Intel HD Graphics 630 via /dev/dri passthrough
# start_on_boot = true (production service)

variable "frigate_prod" {
  description = "Frigate production LXC with OpenVINO iGPU + Ceph storage (BETA — 192.168.4.61)"
  type = object({
    node         = string
    vm_id        = number
    ip_vlan4     = string
    ip_vlan12    = string
    cores        = number
    memory       = number
    disk_size    = number
    storage_pool = string
  })
  default = {
    node         = "pve03"
    vm_id        = 4501
    ip_vlan4     = "192.168.4.61"
    ip_vlan12    = "192.168.12.61"
    cores        = 4
    memory       = 8192
    disk_size    = 30
    storage_pool = "tank"
  }
}

# ============================================================================
# FRIGATE PRODUCTION LXC (pve03 — Intel iGPU + Ceph Storage) — NEW
# ============================================================================
# Clean production Frigate NVR replacing the beta instance on 192.168.4.61.
# Domain: frigate.hornung-bn.de (DNS already pointing to 192.168.4.70)
# Same architecture: privileged LXC, OpenVINO iGPU, CephFS + RBD storage.
# Deployed via GitHub Actions lxc-deploy pipeline.

variable "frigate" {
  description = "Frigate production LXC — frigate.hornung-bn.de (192.168.4.70)"
  type = object({
    node         = string
    vm_id        = number
    ip_vlan4     = string
    ip_vlan12    = string
    cores        = number
    memory       = number
    disk_size    = number
    storage_pool = string
  })
  default = {
    node         = "pve03"
    vm_id        = 4502
    ip_vlan4     = "192.168.4.70"
    ip_vlan12    = "192.168.12.70"
    cores        = 4
    memory       = 8192
    disk_size    = 30
    storage_pool = "tank"
  }
}

# ============================================================================
# CEPH STORAGE CREDENTIALS (for Frigate Production LXC)
# ============================================================================
# Separate Ceph client for frigate-prod — not reusing docker-swarm client.
# Values provided via terraform.tfvars (gitignored).

variable "ceph_frigate_key" {
  description = "CephX key for client.frigate-prod (base64)"
  type        = string
  sensitive   = true
}

variable "ceph_fsid" {
  description = "Ceph cluster FSID (from ceph fsid)"
  type        = string
}


