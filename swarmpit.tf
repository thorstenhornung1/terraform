# ============================================================================
# Swarm-Control LXC Container Configuration
# ============================================================================
# Purpose: Bootstrap/Recovery management node with Portainer
# Container Type: LXC (privileged for Docker nesting)
# Storage: ZFS Tank for snapshots
# Network: VLAN 4 (Cluster Network)
#
# IMPORTANT: This container is the independent recovery tool for the Swarm.
# Portainer runs here and survives infra node failures.
# ============================================================================

# ============================================================================
# LXC Container Template (Downloaded from Proxmox)
# ============================================================================

resource "proxmox_virtual_environment_download_file" "ubuntu_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.swarm_control_node

  url       = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  file_name = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

  overwrite_unmanaged = false
}

# ============================================================================
# Cloud-Init Snippet for Swarm-Control Container
# ============================================================================

resource "proxmox_virtual_environment_file" "cloud_init_swarm_control" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.swarm_control_node

  source_raw {
    data = templatefile("${path.module}/terraform/swarmpit/cloud-init-swarmpit.yml", {
      vm_hostname      = var.swarm_control_hostname
      dns_servers      = join(" ", var.dns_servers)
      swarm_manager_ip = var.infra_nodes["1"].ip_vlan4  # First infra node is Swarm manager
      ghcr_user        = var.ghcr_user
      ghcr_pat         = var.ghcr_pat
    })
    file_name = "cloud-init-swarm-control.yml"
  }
}

# ============================================================================
# Swarm-Control LXC Container
# ============================================================================

resource "proxmox_virtual_environment_container" "swarm_control" {
  node_name = var.swarm_control_node
  vm_id     = var.swarm_control_vmid

  description = "Swarm-Control: Bootstrap/Recovery management node with Portainer"
  tags        = ["docker", "swarm", "management", "portainer"]

  # =========================================================================
  # Container Resources
  # =========================================================================

  cpu {
    cores = var.swarm_control_cores
  }

  memory {
    dedicated = var.swarm_control_memory
    swap      = 0
  }

  # =========================================================================
  # Storage - ZFS Tank for Snapshots
  # =========================================================================

  disk {
    datastore_id = var.storage_pool
    size         = var.swarm_control_disk_size
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
    hostname = var.swarm_control_hostname

    ip_config {
      ipv4 {
        address = "${var.swarm_control_ip}/24"
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
    command = "ssh-keygen -R ${var.swarm_control_ip} 2>/dev/null || true"
  }

  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_lxc_template
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "swarm_control_container" {
  description = "Swarm-Control LXC container details"
  value = {
    vm_id     = proxmox_virtual_environment_container.swarm_control.vm_id
    hostname  = var.swarm_control_hostname
    ip        = var.swarm_control_ip
    node      = var.swarm_control_node
    cpu       = "${var.swarm_control_cores} cores"
    memory    = "${var.swarm_control_memory} MB"
    disk      = "${var.swarm_control_disk_size} GB"
    portainer = "https://${var.swarm_control_ip}:9443"
  }
}

output "swarm_control_ansible_host" {
  description = "Ansible inventory entry for swarm-control"
  value = {
    hostname = var.swarm_control_hostname
    ip       = var.swarm_control_ip
    user     = "root"
  }
}
