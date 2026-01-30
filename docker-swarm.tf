# ============================================================================
# Docker Swarm Cluster Infrastructure
# ============================================================================
# Architecture: Single Swarm with 6 nodes
#   - 3 Application Nodes (docker-app-1/2/3) - Swarm Managers
#   - 3 Infrastructure Nodes (docker-infra-1/2/3) - SeaweedFS + Patroni
#
# Storage: All VMs on ZFS Tank pool for snapshots and performance
# Network: Dual VLAN (4 = Cluster, 12 = Storage)
#
# Ansible will later:
#   - Initialize Docker Swarm cluster
#   - Deploy SeaweedFS on infra nodes (placement constraints)
#   - Deploy Patroni PostgreSQL cluster on infra nodes
#   - Configure overlay networks
# ============================================================================

# ============================================================================
# Cloud-Init Snippets
# ============================================================================

# Application Nodes Cloud-Init
resource "proxmox_virtual_environment_file" "cloud_init_app" {
  for_each = var.app_nodes

  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value.node

  source_raw {
    data = templatefile("${path.module}/terraform/docker-swarm/cloud-init-docker.yml", {
      vm_hostname = "${var.app_node_prefix}-${each.key}"
    })
    file_name = "cloud-init-${var.app_node_prefix}-${each.key}.yml"
  }
}

# Infrastructure Nodes Cloud-Init
resource "proxmox_virtual_environment_file" "cloud_init_infra" {
  for_each = var.infra_nodes

  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value.node

  source_raw {
    data = templatefile("${path.module}/terraform/docker-swarm/cloud-init-docker.yml", {
      vm_hostname = "${var.infra_node_prefix}-${each.key}"
    })
    file_name = "cloud-init-${var.infra_node_prefix}-${each.key}.yml"
  }
}

# ============================================================================
# Application Nodes (Docker Swarm Managers for Applications)
# ============================================================================

resource "proxmox_virtual_environment_vm" "app_nodes" {
  for_each = var.app_nodes

  name      = "${var.app_node_prefix}-${each.key}"
  node_name = each.value.node
  vm_id     = each.value.vm_id

  tags = ["docker", "swarm", "app"]

  clone {
    vm_id     = var.template_id
    node_name = "pve03"
    full      = true
  }

  cpu {
    cores = var.app_node_cores
    type  = "host"
  }

  memory {
    dedicated = var.app_node_memory
  }

  boot_order = ["scsi0"]

  # Single disk on ZFS Tank
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.app_node_disk_size
  }

  # Network Interface 1: VLAN 4 (Cluster Network - PRIMARY)
  network_device {
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = true
  }

  # Network Interface 2: VLAN 12 (Storage Network)
  network_device {
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id_storage
    firewall = true
  }

  initialization {
    # IP Config for VLAN 4 (eth0 - PRIMARY with gateway)
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }

    # IP Config for VLAN 12 (eth1 - Storage, no gateway)
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan12}/24"
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_app[each.key].id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  # Clean SSH known_hosts after VM creation
  provisioner "local-exec" {
    command = "ssh-keygen -R ${each.value.ip_vlan4} 2>/dev/null || true"
  }
}

# ============================================================================
# Infrastructure Nodes (SeaweedFS + Patroni Cluster)
# ============================================================================

resource "proxmox_virtual_environment_vm" "infra_nodes" {
  for_each = var.infra_nodes

  name      = "${var.infra_node_prefix}-${each.key}"
  node_name = each.value.node
  vm_id     = each.value.vm_id

  tags = ["docker", "swarm", "infra", "storage", "database"]

  clone {
    vm_id     = var.template_id
    node_name = "pve03"
    full      = true
  }

  cpu {
    cores = var.infra_node_cores
    type  = "host"
  }

  memory {
    dedicated = var.infra_node_memory
  }

  boot_order = ["scsi0"]

  # Boot disk (uses node-specific storage or default)
  disk {
    datastore_id = coalesce(each.value.storage_pool, var.storage_pool)
    interface    = "scsi0"
    size         = var.infra_node_boot_disk_size
  }

  # Data disk for SeaweedFS + Patroni (per-node size and storage)
  disk {
    datastore_id = coalesce(each.value.storage_pool, var.storage_pool)
    interface    = "scsi1"
    size         = each.value.data_disk_size
  }

  # Network Interface 1: VLAN 4 (Cluster Network - PRIMARY)
  network_device {
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = true
  }

  # Network Interface 2: VLAN 12 (Storage Network)
  network_device {
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id_storage
    firewall = true
  }

  initialization {
    # IP Config for VLAN 4 (eth0 - PRIMARY with gateway)
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }

    # IP Config for VLAN 12 (eth1 - Storage, no gateway)
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan12}/24"
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_infra[each.key].id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  # Clean SSH known_hosts after VM creation
  provisioner "local-exec" {
    command = "ssh-keygen -R ${each.value.ip_vlan4} 2>/dev/null || true"
  }
}
