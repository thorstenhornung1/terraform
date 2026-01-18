# ============================================================================
# SeaweedFS Storage Infrastructure
# ============================================================================
# Purpose: Single-node distributed object storage with S3 API
# Deployed on pve03 with VLAN 12 (dedicated storage network)
#
# Architecture:
#   - Minimal VM (4 vCPU, 8GB RAM, 20GB boot disk)
#   - 500GB data disk on Tank ZFS pool
#   - LevelDB metadata backend (embedded, no external database)
#   - Network: VLAN 12 (10.12.0.0/24)
#
# Services:
#   - Master (Port 9333): Volume ID coordination, leader election
#   - Volume (Port 8080): Actual data storage
#   - Filer (Port 8888): Filesystem abstraction
#   - S3 Gateway (Port 8333): AWS S3-compatible API
#
# Deployment Order:
#   1. Deploy seaweed3 VM (this file)
#   2. Verify all services are running
#   3. Test S3 API from K3s cluster
#   4. Configure applications to use S3 endpoints
# ============================================================================

# Cloud-Init Snippet for SeaweedFS
resource "proxmox_virtual_environment_file" "cloud_init_seaweedfs" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.seaweedfs_node

  source_raw {
    data = templatefile("${path.module}/terraform/seaweedfs/cloud-init-seaweedfs.yml", {
      vm_hostname  = var.seaweedfs_name
      seaweedfs_ip = var.seaweedfs_ip
    })
    file_name = "cloud-init-seaweedfs.yml"
  }
}

# SeaweedFS VM
resource "proxmox_virtual_environment_vm" "seaweedfs" {
  name      = var.seaweedfs_name
  node_name = var.seaweedfs_node
  vm_id     = var.seaweedfs_vm_id

  clone {
    vm_id     = var.template_id
    node_name = "pve01" # Template exists only on pve01
    full      = true
  }

  timeout_clone = 3600  # Increase to 60 minutes for large disk clone

  cpu {
    cores = var.seaweedfs_cores
    type  = "host"
  }

  memory {
    dedicated = var.seaweedfs_memory
  }

  boot_order = ["scsi0", "scsi1"]

  # Boot disk (20GB - minimal for OS + SeaweedFS binary)
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.seaweedfs_boot_disk_size
  }

  # Data disk (500GB on Tank ZFS pool)
  disk {
    datastore_id = var.seaweedfs_data_storage
    interface    = "scsi1"
    size         = var.seaweedfs_data_disk_size
  }

  # Network Interface 1: VLAN 12 (dedicated storage network - PRIMARY)
  network_device {
    bridge  = "vmbr0"
    vlan_id = var.seaweedfs_vlan_id
  }

  # Network Interface 2: VLAN 4 (K3s cluster network - VIRTUAL)
  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id
  }

  initialization {
    # IP Config for VLAN 12 (eth0 - PRIMARY with gateway)
    ip_config {
      ipv4 {
        address = "${var.seaweedfs_ip}/24"
        gateway = var.seaweedfs_gateway
      }
    }

    # IP Config for VLAN 4 (eth1 - VIRTUAL, no gateway)
    ip_config {
      ipv4 {
        address = "${var.seaweedfs_ip_vlan4}/24"
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.vm_username
      password = var.vm_password
      keys     = [file(var.ssh_public_key_path)]
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_seaweedfs.id
  }

  agent {
    enabled = true
  }

  tags = ["storage", "seaweedfs", "s3"]
}

# ============================================================================
# Outputs
# ============================================================================

output "seaweedfs_info" {
  description = "SeaweedFS deployment information"
  value = {
    name               = proxmox_virtual_environment_vm.seaweedfs.name
    vm_id              = proxmox_virtual_environment_vm.seaweedfs.vm_id
    node               = proxmox_virtual_environment_vm.seaweedfs.node_name
    ip_address_vlan12  = var.seaweedfs_ip
    ip_address_vlan4   = var.seaweedfs_ip_vlan4
    vlan_primary       = var.seaweedfs_vlan_id
    vlan_secondary     = var.vlan_id
    master_endpoint    = "http://${var.seaweedfs_ip}:9333"
    volume_endpoint    = "http://${var.seaweedfs_ip}:8080"
    filer_endpoint     = "http://${var.seaweedfs_ip}:8888"
    s3_endpoint        = "http://${var.seaweedfs_ip}:8333"
    s3_endpoint_vlan4  = "http://${var.seaweedfs_ip_vlan4}:8333"
    boot_disk_size     = var.seaweedfs_boot_disk_size
    data_disk_size     = var.seaweedfs_data_disk_size
    data_storage       = var.seaweedfs_data_storage
  }
}

output "seaweedfs_s3_config" {
  description = "S3 configuration for applications"
  value = {
    endpoint_vlan12  = "http://${var.seaweedfs_ip}:8333"
    endpoint_vlan4   = "http://${var.seaweedfs_ip_vlan4}:8333"
    region           = "us-east-1"
    force_path_style = true
    disable_ssl      = true
    note             = "Use endpoint_vlan4 for K3s cluster access, endpoint_vlan12 for storage network"
  }
}
