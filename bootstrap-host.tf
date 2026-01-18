# ============================================================================
# Bootstrap Host Infrastructure
# ============================================================================
# Purpose: Standalone Docker host running Infisical for K3s cluster bootstrapping
# Deployed OUTSIDE K3s cluster to avoid circular dependency issues
#
# Architecture:
#   - Minimal VM (2 vCPU, 4GB RAM, 10GB disk on ZFS tank)
#   - Docker + Docker Compose
#   - Traefik reverse proxy with Let's Encrypt
#   - Infisical v0.46.0 with PostgreSQL 15 + Redis 7
#   - Domain: infisical.hornung-bn.de
#   - Storage: ZFS tank (HA requirement, snapshot capability)
#
# Why PostgreSQL?
#   - Production-grade database for reliability
#   - Better performance for complex queries
#   - Supports high availability and replication
#   - PostgreSQL pg_dump for consistent backups
#
# Deployment Order:
#   1. Deploy bootstrap-host (this file)
#   2. Configure Infisical secrets
#   3. Deploy K3s cluster (can reference Infisical for all secrets)
#   4. Deploy applications using External Secrets Operator
# ============================================================================

# Cloud-Init Snippet for Bootstrap Host
resource "proxmox_virtual_environment_file" "cloud_init_bootstrap" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.bootstrap_host_node

  source_raw {
    data = templatefile("${path.module}/terraform/bootstrap-host/cloud-init-docker-infisical.yml", {
      vm_hostname = var.bootstrap_host_name
    })
    file_name = "cloud-init-bootstrap-host.yml"
  }
}

# Bootstrap Host VM
resource "proxmox_virtual_environment_vm" "bootstrap_host" {
  name      = var.bootstrap_host_name
  node_name = var.bootstrap_host_node
  vm_id     = var.bootstrap_host_vm_id

  clone {
    vm_id     = var.template_id
    node_name = "pve01" # Template exists only on pve01
    full      = true
  }

  cpu {
    cores = var.bootstrap_host_cores
    type  = "host"
  }

  memory {
    dedicated = var.bootstrap_host_memory
  }

  boot_order = ["scsi0"]

  disk {
    datastore_id = var.bootstrap_host_storage # ZFS tank for HA, snapshots
    interface    = "scsi0"
    size         = var.bootstrap_host_disk_size
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${var.bootstrap_host_ip}/24"
        gateway = var.network_gateway
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_bootstrap.id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  # CI/CD: Clean SSH known_hosts after VM creation
  provisioner "local-exec" {
    command = "ssh-keygen -R ${var.bootstrap_host_ip} 2>/dev/null || true"
  }
}

# ============================================================================
# Outputs
# ============================================================================

output "bootstrap_host_summary" {
  value = {
    name     = proxmox_virtual_environment_vm.bootstrap_host.name
    node     = proxmox_virtual_environment_vm.bootstrap_host.node_name
    ip       = var.bootstrap_host_ip
    hostname = "${var.bootstrap_host_name}.hornung-bn.de"
    services = {
      infisical = "https://infisical.hornung-bn.de"
      traefik   = "https://traefik.hornung-bn.de"
    }
    specs = {
      cpu    = "${var.bootstrap_host_cores} cores"
      memory = "${var.bootstrap_host_memory}MB"
      disk   = "${var.bootstrap_host_disk_size}GB"
    }
    post_deployment_steps = [
      "1. SSH to ${var.bootstrap_host_ip}",
      "2. Generate secrets: openssl rand -hex 32",
      "3. Edit /opt/infisical/.env with generated values",
      "4. Start services: sudo systemctl start infisical.service",
      "5. Access Infisical: https://infisical.hornung-bn.de",
      "6. Create initial admin account",
      "7. Configure secrets for K3s cluster"
    ]
  }
  description = "Bootstrap Host deployment summary with post-deployment instructions"
}
