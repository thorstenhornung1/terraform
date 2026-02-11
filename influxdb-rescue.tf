# ============================================================================
# Dedicated InfluxDB VM for air_rescue_tracker + Home Assistant
# ============================================================================
# Standalone InfluxDB 2.7 on pve03 with ZFS Tank storage.
# Stores rescue-helicopter telemetry (infinite retention) and
# Home Assistant metrics (1yr retention).
#
# Network: Dual VLAN (4 = Cluster/Access, 12 = Storage/Replication)
# Access: rescue-tracker (Swarm), Grafana (Swarm), Home Assistant (192.168.2.5)
# ============================================================================

# ============================================================================
# Cloud-Init Snippet
# ============================================================================

resource "proxmox_virtual_environment_file" "cloud_init_influxdb_rescue" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.influxdb_rescue.node

  source_raw {
    data = templatefile("${path.module}/terraform/influxdb-rescue/cloud-init-influxdb.yml", {
      vm_hostname = "influxdb-rescue"
      ghcr_user   = var.ghcr_user
      ghcr_pat    = var.ghcr_pat
    })
    file_name = "cloud-init-influxdb-rescue.yml"
  }
}

# ============================================================================
# InfluxDB VM
# ============================================================================

resource "proxmox_virtual_environment_vm" "influxdb_rescue" {
  name      = "influxdb-rescue"
  node_name = var.influxdb_rescue.node
  vm_id     = var.influxdb_rescue.vm_id

  tags = ["docker", "influxdb", "rescue"]

  clone {
    vm_id     = var.template_id
    node_name = "pve01"
    full      = true
  }

  cpu {
    cores = var.influxdb_rescue.cores
    type  = "host"
  }

  memory {
    dedicated = var.influxdb_rescue.memory
  }

  boot_order = ["scsi0"]

  disk {
    datastore_id = var.influxdb_rescue.storage_pool
    interface    = "scsi0"
    size         = var.influxdb_rescue.disk_size
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
        address = "${var.influxdb_rescue.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }

    # IP Config for VLAN 12 (eth1 - Storage, no gateway)
    ip_config {
      ipv4 {
        address = "${var.influxdb_rescue.ip_vlan12}/24"
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_influxdb_rescue.id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  # Clean SSH known_hosts after VM creation
  provisioner "local-exec" {
    command = "ssh-keygen -R ${var.influxdb_rescue.ip_vlan4} 2>/dev/null || true"
  }
}
