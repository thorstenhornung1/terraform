# K3s Cluster Infrastructure - Variable-based Configuration
# Staging Branch: Optimized for 3-host deployment with configurable worker sizes
# Storage: Longhorn-ready with 20-30% overhead calculation

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
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

# ============================================================================
# Cloud-Init Snippets
# ============================================================================

# Master Cloud-Init Files
resource "proxmox_virtual_environment_file" "cloud_init_masters" {
  for_each = var.master_ips

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.vm_distribution[each.key]

  source_raw {
    data = templatefile("${path.module}/terraform/k3s-cluster/cloud-init-k3s-complete.yml", {
      vm_hostname = "${var.cluster_name}-${each.key}"
    })
    file_name = "cloud-init-k3s-${each.key}.yml"
  }
}

# Worker Cloud-Init Files
resource "proxmox_virtual_environment_file" "cloud_init_workers" {
  for_each = var.worker_ips

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.vm_distribution[each.key]

  source_raw {
    data = templatefile("${path.module}/terraform/k3s-cluster/cloud-init-k3s-complete.yml", {
      vm_hostname = "${var.cluster_name}-${each.key}"
    })
    file_name = "cloud-init-k3s-${each.key}.yml"
  }
}

# ============================================================================
# K3s Master Nodes
# ============================================================================

resource "proxmox_virtual_environment_vm" "k3s_masters" {
  for_each = var.master_ips

  name      = "${var.cluster_name}-${each.key}"
  node_name = var.vm_distribution[each.key]
  vm_id     = var.vm_ids[each.key]

  clone {
    vm_id     = var.template_id
    node_name = "pve01" # Template exists only on pve01
    full      = true
  }

  cpu {
    cores = var.master_cores
    type  = "host"
  }

  memory {
    dedicated = var.master_memory
  }

  boot_order = ["scsi0"]

  disk {
    datastore_id = var.storage_backend[var.vm_distribution[each.key]]
    interface    = "scsi0"
    size         = var.master_disk_size
  }

  # Network Interface 1: VLAN 4 (K3s Cluster Network - PRIMARY)
  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id
  }

  # Network Interface 2: VLAN 12 (Storage Network)
  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id_storage
  }

  initialization {
    # IP Config for VLAN 4 (eth0 - PRIMARY with gateway)
    ip_config {
      ipv4 {
        address = "${each.value}/24"
        gateway = var.network_gateway
      }
    }

    # IP Config for VLAN 12 (eth1 - Storage, no gateway)
    ip_config {
      ipv4 {
        address = "${var.master_ips_vlan12[each.key]}/24"
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_masters[each.key].id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  # CI/CD: Clean SSH known_hosts after VM creation
  provisioner "local-exec" {
    command = "ssh-keygen -R ${each.value} 2>/dev/null || true"
  }
}

# ============================================================================
# K3s Worker Nodes (with variable disk sizes for Longhorn)
# ============================================================================

resource "proxmox_virtual_environment_vm" "k3s_workers" {
  for_each = var.worker_ips

  name      = "${var.cluster_name}-${each.key}"
  node_name = var.vm_distribution[each.key]
  vm_id     = var.vm_ids[each.key]

  clone {
    vm_id     = var.template_id
    node_name = "pve01" # Template exists only on pve01
    full      = true
  }

  cpu {
    cores = var.worker_cores
    type  = "host"
  }

  memory {
    dedicated = var.worker_memory
  }

  boot_order = ["scsi0"]

  disk {
    datastore_id = var.storage_backend[var.vm_distribution[each.key]]
    interface    = "scsi0"
    size         = var.worker_disk_sizes[each.key] # Variable worker sizes!
  }

  # Network Interface 1: VLAN 4 (K3s Cluster Network - PRIMARY)
  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id
  }

  # Network Interface 2: VLAN 12 (Storage Network)
  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id_storage
  }

  initialization {
    # IP Config for VLAN 4 (eth0 - PRIMARY with gateway)
    ip_config {
      ipv4 {
        address = "${each.value}/24"
        gateway = var.network_gateway
      }
    }

    # IP Config for VLAN 12 (eth1 - Storage, no gateway)
    ip_config {
      ipv4 {
        address = "${var.worker_ips_vlan12[each.key]}/24"
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_workers[each.key].id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  # CI/CD: Clean SSH known_hosts after VM creation
  provisioner "local-exec" {
    command = "ssh-keygen -R ${each.value} 2>/dev/null || true"
  }
}

# ============================================================================
# Outputs
# ============================================================================

output "cluster_summary" {
  value = {
    masters = {
      for k, v in proxmox_virtual_environment_vm.k3s_masters : k => {
        name = v.name
        node = v.node_name
        ip   = var.master_ips[k]
        disk = "${var.master_disk_size}GB"
      }
    }
    workers = {
      for k, v in proxmox_virtual_environment_vm.k3s_workers : k => {
        name            = v.name
        node            = v.node_name
        ip              = var.worker_ips[k]
        disk            = "${var.worker_disk_sizes[k]}GB"
        longhorn_usable = "${floor(var.worker_disk_sizes[k] * 0.7)}GB (70% of ${var.worker_disk_sizes[k]}GB)"
      }
    }
    storage_summary = {
      total_worker_storage = "${sum([for k, v in var.worker_disk_sizes : v])}GB provisioned"
      longhorn_total       = "${floor(sum([for k, v in var.worker_disk_sizes : v]) * 0.7)}GB usable"
      longhorn_replicated  = "${floor(sum([for k, v in var.worker_disk_sizes : v]) * 0.7 / 3)}GB effective (3x replication)"
    }
  }
  description = "K3s Cluster deployment summary with Longhorn storage calculations"
}
