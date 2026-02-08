# ============================================================================
# Dedicated etcd LXC Containers (etcd-4, etcd-5)
# ============================================================================
# Purpose: Expand the 3-node Docker Swarm etcd cluster to 5 nodes
# Container Type: LXC (unprivileged — no Docker/VXLAN needed)
# Service: Native etcd via systemd (immune to Docker Swarm rollbacks)
# Network: Dual-NIC — VLAN 4 (Management/SSH) + VLAN 12 (etcd Cluster)
#
# Why dedicated LXC instead of Docker Swarm?
#   A Docker Swarm rollback reset etcd restart policies from condition:any
#   to condition:on-failure with MaxAttempts:3. etcd exited cleanly (code 0)
#   so on-failure never restarted it. Native systemd Restart=always is immune.
#
# Cluster topology after deployment:
#   etcd-1: docker-infra-1 / 192.168.12.40 (Docker Swarm)
#   etcd-2: docker-infra-2 / 192.168.12.41 (Docker Swarm)
#   etcd-3: docker-infra-3 / 192.168.12.42 (Docker Swarm)
#   etcd-4: pve02 LXC      / 192.168.12.53 (native systemd) ← NEW
#   etcd-5: pve03 LXC      / 192.168.12.54 (native systemd) ← NEW
#
# Quorum: 3 of 5 (tolerates 2 failures)
# ============================================================================

# ============================================================================
# LXC Container Template (one per target Proxmox node)
# ============================================================================

resource "proxmox_virtual_environment_download_file" "ubuntu_lxc_template_etcd" {
  for_each = var.etcd_nodes

  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = each.value.node

  url       = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  file_name = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"

  overwrite_unmanaged = false
}

# ============================================================================
# etcd LXC Containers
# ============================================================================

resource "proxmox_virtual_environment_container" "etcd_nodes" {
  for_each = var.etcd_nodes

  node_name = each.value.node
  vm_id     = each.value.vm_id

  description = "Dedicated etcd node (etcd-${each.key}) for Patroni PostgreSQL HA cluster"
  tags        = ["etcd", "patroni", "infrastructure"]

  # =========================================================================
  # Container Resources
  # =========================================================================

  cpu {
    cores = var.etcd_node_cores
  }

  memory {
    dedicated = var.etcd_node_memory
    swap      = 0
  }

  # =========================================================================
  # Storage
  # =========================================================================

  disk {
    datastore_id = coalesce(each.value.storage_pool, "local-lvm")
    size         = var.etcd_node_disk_size
  }

  # =========================================================================
  # Network Configuration - Dual NIC
  # =========================================================================

  # eth0: VLAN 4 (Management / SSH access)
  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = false
  }

  # eth1: VLAN 12 (etcd cluster traffic — peer + client)
  network_interface {
    name     = "eth1"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id_storage
    firewall = false
  }

  # =========================================================================
  # Operating System Template
  # =========================================================================

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.ubuntu_lxc_template_etcd[each.key].id
    type             = "ubuntu"
  }

  # =========================================================================
  # Container Features — No Docker needed
  # =========================================================================
  # etcd runs as a native binary, no nesting or keyctl required

  features {
    nesting = false
  }

  # =========================================================================
  # Unprivileged Container (etcd doesn't need kernel-level access)
  # =========================================================================

  unprivileged = true

  # =========================================================================
  # Initialization
  # =========================================================================

  initialization {
    hostname = "etcd-${each.key}"

    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }

    # eth1: VLAN 12 (etcd cluster) — no gateway (routed via eth0)
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan12}/24"
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
  # Startup Configuration — Boot before Docker Swarm nodes
  # =========================================================================

  start_on_boot = true

  startup {
    order      = "1"
    up_delay   = "30"
    down_delay = "15"
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
    command = "ssh-keygen -R ${each.value.ip_vlan4} 2>/dev/null || true"
  }

  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_lxc_template_etcd
  ]
}

# ============================================================================
# etcd Installation via remote-exec
# ============================================================================
# LXC containers don't support cloud-init user_data_file_id like VMs,
# so we use null_resource + remote-exec to install etcd after container boot.

resource "null_resource" "etcd_setup" {
  for_each = var.etcd_nodes

  triggers = {
    container_id = proxmox_virtual_environment_container.etcd_nodes[each.key].id
    etcd_version = var.etcd_version
  }

  connection {
    type        = "ssh"
    host        = each.value.ip_vlan4
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "3m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/terraform/etcd/setup-etcd.sh.tpl", {
      etcd_version          = var.etcd_version
      etcd_name             = "etcd-${each.key}"
      listen_ip             = each.value.ip_vlan12
      initial_cluster       = join(",", concat(
        [for k, v in var.infra_nodes : "etcd-${k}=http://${v.ip_vlan12}:2380"],
        [for k, v in var.etcd_nodes : "etcd-${k}=http://${v.ip_vlan12}:2380"]
      ))
      cluster_token         = var.etcd_cluster_token
      initial_cluster_state = var.etcd_initial_cluster_state
    })
    destination = "/tmp/setup-etcd.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-etcd.sh",
      "/tmp/setup-etcd.sh",
      "rm -f /tmp/setup-etcd.sh"
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.etcd_nodes
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "etcd_nodes" {
  description = "Dedicated etcd LXC container details"
  value = {
    for key, node in proxmox_virtual_environment_container.etcd_nodes : "etcd-${key}" => {
      vm_id      = node.vm_id
      hostname   = "etcd-${key}"
      ip_mgmt    = var.etcd_nodes[key].ip_vlan4
      ip_cluster = var.etcd_nodes[key].ip_vlan12
      proxmox    = var.etcd_nodes[key].node
      cpu        = "${var.etcd_node_cores} core"
      memory     = "${var.etcd_node_memory} MB"
      disk       = "${var.etcd_node_disk_size} GB"
    }
  }
}

output "etcd_cluster_members" {
  description = "Complete 5-node etcd cluster overview (Docker Swarm + dedicated LXC)"
  value = merge(
    {
      for key, config in var.infra_nodes : "etcd-${key}" => {
        type       = "Docker Swarm service"
        ip_cluster = config.ip_vlan12
        host       = "${var.infra_node_prefix}-${key}"
        client_url = "http://${config.ip_vlan12}:2379"
        peer_url   = "http://${config.ip_vlan12}:2380"
      }
    },
    {
      for key, config in var.etcd_nodes : "etcd-${key}" => {
        type       = "Dedicated LXC (systemd)"
        ip_cluster = config.ip_vlan12
        host       = "etcd-${key}"
        client_url = "http://${config.ip_vlan12}:2379"
        peer_url   = "http://${config.ip_vlan12}:2380"
      }
    }
  )
}
