# ============================================================================
# Swarmpit LXC Container Configuration
# ============================================================================
# Purpose: Swarmpit Docker Swarm Management UI with CouchDB
# Container Type: LXC (privileged for Docker nesting)
# Storage: ZFS Tank for snapshots
# Network: VLAN 4 (Cluster Network)
#
# IMPORTANT: This container will be added to the existing Docker Swarm
# as a Worker node. Swarmpit services run here but don't affect Swarm quorum.
# ============================================================================

# ============================================================================
# LXC Container Template (Downloaded from Proxmox)
# ============================================================================

resource "proxmox_virtual_environment_download_file" "ubuntu_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.swarmpit_node

  url       = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  file_name = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

  overwrite_unmanaged = false
}

# ============================================================================
# Cloud-Init Snippet for Swarmpit Container
# ============================================================================

resource "proxmox_virtual_environment_file" "cloud_init_swarmpit" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.swarmpit_node

  source_raw {
    data = templatefile("${path.module}/terraform/swarmpit/cloud-init-swarmpit.yml", {
      vm_hostname     = var.swarmpit_hostname
      dns_servers     = join(" ", var.dns_servers)
      swarm_manager_ip = var.app_nodes["1"].ip_vlan4  # First app node is Swarm manager
    })
    file_name = "cloud-init-swarmpit.yml"
  }
}

# ============================================================================
# Swarmpit LXC Container
# ============================================================================

resource "proxmox_virtual_environment_container" "swarmpit" {
  node_name = var.swarmpit_node
  vm_id     = var.swarmpit_vmid

  description = "Swarmpit Docker Swarm Management UI with CouchDB"
  tags        = ["docker", "swarm", "swarmpit", "management"]

  # =========================================================================
  # Container Resources (CRITICAL for CouchDB!)
  # =========================================================================
  # CouchDB requires: 4GB RAM (hard), 2GB (soft) for view building spikes
  # Swarmpit + InfluxDB: 1-2GB additional
  # Total recommended: 6GB RAM minimum

  cpu {
    cores = var.swarmpit_cores
  }

  memory {
    dedicated = var.swarmpit_memory
    swap      = 0  # CouchDB performs poorly with swap
  }

  # =========================================================================
  # Storage - ZFS Tank for Snapshots
  # =========================================================================

  disk {
    datastore_id = var.storage_pool
    size         = var.swarmpit_disk_size
  }

  # =========================================================================
  # Network Configuration - VLAN 4 (Cluster Network)
  # =========================================================================

  network_interface {
    name       = "eth0"
    bridge     = "vmbr0"
    vlan_id    = var.vlan_id
    firewall   = false
  }

  # =========================================================================
  # Operating System Template
  # =========================================================================

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.ubuntu_lxc_template.id
    type             = "ubuntu"
  }

  # =========================================================================
  # Container Features - Docker Support (CRITICAL!)
  # =========================================================================
  # nesting=1 is REQUIRED for running Docker inside LXC
  # keyctl needed for Docker volume management

  features {
    nesting = true
    keyctl  = true
  }

  # =========================================================================
  # Privileged Container (Required for Docker Swarm!)
  # =========================================================================
  # Docker Swarm overlay networks require VXLAN which only works
  # in privileged containers. Unprivileged LXC lacks kernel access.

  unprivileged = false

  # =========================================================================
  # Initialization
  # =========================================================================

  initialization {
    hostname = var.swarmpit_hostname

    ip_config {
      ipv4 {
        address = "${var.swarmpit_ip}/24"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      keys     = [file(var.ssh_public_key_path)]
      password = var.vm_password
    }
  }

  # =========================================================================
  # Startup Configuration
  # =========================================================================

  start_on_boot = true

  startup {
    order      = "3"
    up_delay   = "60"
    down_delay = "30"
  }

  # =========================================================================
  # Console
  # =========================================================================

  console {
    type = "console"
  }

  # =========================================================================
  # Post-Creation: Clean SSH known_hosts
  # =========================================================================

  provisioner "local-exec" {
    command = "ssh-keygen -R ${var.swarmpit_ip} 2>/dev/null || true"
  }

  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_lxc_template
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "swarmpit_container" {
  description = "Swarmpit LXC container details"
  value = {
    vm_id     = proxmox_virtual_environment_container.swarmpit.vm_id
    hostname  = var.swarmpit_hostname
    ip        = var.swarmpit_ip
    node      = var.swarmpit_node
    cpu       = "${var.swarmpit_cores} cores"
    memory    = "${var.swarmpit_memory} MB"
    disk      = "${var.swarmpit_disk_size} GB"
    swarmpit_ui = "http://${var.swarmpit_ip}:888"
  }
}

output "swarmpit_ansible_host" {
  description = "Ansible inventory entry for Swarmpit"
  value = {
    hostname = var.swarmpit_hostname
    ip       = var.swarmpit_ip
    user     = "root"
  }
}
