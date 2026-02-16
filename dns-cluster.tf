# ============================================================================
# Technitium DNS Cluster — 3-Node LXC Deployment
# ============================================================================
# Purpose: Authoritative + recursive DNS cluster for the entire infrastructure
# Container Type: LXC (unprivileged — no Docker/VXLAN needed)
# Service: Technitium DNS Server (native systemd)
# Network: Single-NIC — VLAN 4 (Management/DNS)
#
# Cluster topology:
#   dns1: pve01 / 192.168.4.2  (Primary — initialize cluster here)
#   dns2: pve02 / 192.168.4.3  (Secondary — join cluster)
#   dns3: pve03 / 192.168.4.4  (Secondary — join cluster)
#
# Ports:
#   53      TCP/UDP  DNS queries
#   5380    HTTP     WebUI (unencrypted)
#   53443   HTTPS    WebUI (TLS)
#
# Provisioning includes:
#   - APT proxy (apt-cacher.hornung-bn.de)
#   - LDAP/SSSD authentication
#   - rsyslog → Loki forwarding
#   - Technitium DNS installation
#
# After Terraform apply:
#   1. Open https://192.168.4.2:53443 — set admin password
#   2. Initialize cluster on dns1
#   3. Join dns2 and dns3 to the cluster
#   4. Update DHCP to use 192.168.4.2/3/4 as DNS servers
# ============================================================================

# ============================================================================
# DNS LXC Containers
# ============================================================================
# Ubuntu 24.04 template already exists on all Proxmox nodes (downloaded by
# etcd-cluster.tf and swarmpit.tf). Referenced directly by storage path to
# avoid duplicate download_file resources — the bpg provider errors on
# unmanaged existing files.

resource "proxmox_virtual_environment_container" "dns_nodes" {
  for_each = var.dns_nodes

  node_name = each.value.node
  vm_id     = each.value.vm_id

  description = "Technitium DNS Server (dns${each.key}) — Cluster member"
  tags        = ["dns", "technitium", "infrastructure"]

  # =========================================================================
  # Container Resources — Lean profile
  # =========================================================================
  # Technitium DNS + .NET runtime uses ~200MB RAM at idle.
  # 1 core is sufficient for DNS workloads in this environment.

  cpu {
    cores = var.dns_node_cores
  }

  memory {
    dedicated = var.dns_node_memory
    swap      = 0
  }

  # =========================================================================
  # Storage — ZFS Tank for snapshots and data integrity
  # =========================================================================

  disk {
    datastore_id = coalesce(each.value.storage_pool, var.storage_pool)
    size         = var.dns_node_disk_size
  }

  # =========================================================================
  # Network Configuration — Single NIC on VLAN 4
  # =========================================================================
  # DNS servers only need VLAN 4 (cluster/management network).
  # No VLAN 12 (storage) needed — DNS has no replication traffic that
  # requires a separate network.

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = false
  }

  # =========================================================================
  # Operating System Template — Ubuntu 24.04
  # =========================================================================
  # Template already present on all nodes via etcd/swarm-control downloads.

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type             = "ubuntu"
  }

  # =========================================================================
  # Container Features — No Docker needed
  # =========================================================================
  # Technitium runs as a native .NET application, no nesting required.

  features {
    nesting = false
  }

  # =========================================================================
  # Unprivileged Container (DNS doesn't need kernel-level access)
  # =========================================================================

  unprivileged = true

  # =========================================================================
  # Initialization
  # =========================================================================

  initialization {
    hostname = "dns${each.key}"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
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
  # Startup Configuration — Boot early (DNS is foundational)
  # =========================================================================
  # DNS should start before everything else that depends on name resolution.
  # order=1 with short delay — DNS is lightweight and starts fast.

  start_on_boot = true

  startup {
    order      = "1"
    up_delay   = "15"
    down_delay = "10"
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
    command = "ssh-keygen -R ${each.value.ip} 2>/dev/null || true"
  }

  # =========================================================================
  # Lifecycle — Prevent replacement after import
  # =========================================================================
  # user_account and template_file_id are write-only attributes that cannot
  # be read back from the Proxmox API. After terraform import, these are
  # missing from state, causing Terraform to plan a replacement.
  # ignore_changes prevents this — both are only relevant at creation time.

  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
      operating_system[0].template_file_id,
    ]
  }
}

# ============================================================================
# Technitium DNS Installation via remote-exec
# ============================================================================
# LXC containers don't support cloud-init user_data_file_id like VMs,
# so we use null_resource + remote-exec to provision after container boot.
#
# The setup script installs:
#   1. APT proxy configuration
#   2. SSSD/LDAP for user authentication
#   3. rsyslog forwarding to Loki
#   4. Technitium DNS Server (with ASP.NET runtime)

resource "null_resource" "dns_setup" {
  for_each = var.dns_nodes

  triggers = {
    container_id = proxmox_virtual_environment_container.dns_nodes[each.key].id
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/terraform/dns/setup-dns.sh.tpl", {
      hostname = "dns${each.key}"
      ip       = each.value.ip
    })
    destination = "/tmp/setup-dns.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-dns.sh",
      "/tmp/setup-dns.sh",
      "rm -f /tmp/setup-dns.sh"
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.dns_nodes
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "dns_nodes" {
  description = "Technitium DNS cluster node details"
  value = {
    for key, node in proxmox_virtual_environment_container.dns_nodes : "dns${key}" => {
      vm_id    = node.vm_id
      hostname = "dns${key}"
      ip       = var.dns_nodes[key].ip
      proxmox  = var.dns_nodes[key].node
      cpu      = "${var.dns_node_cores} core"
      memory   = "${var.dns_node_memory} MB"
      disk     = "${var.dns_node_disk_size} GB"
      webui    = "https://${var.dns_nodes[key].ip}:53443"
    }
  }
}

output "dns_cluster_info" {
  description = "Technitium DNS cluster setup instructions"
  value = {
    primary_webui    = "https://${var.dns_nodes["1"].ip}:53443"
    cluster_domain   = "dns.internal.home.arpa"
    dns_servers      = [for k, v in var.dns_nodes : v.ip]
    dhcp_config      = "Set DNS servers to: ${join(", ", [for k, v in var.dns_nodes : v.ip])}"
    rolling_update   = "Order: dns2 → dns3 → dns1 (primary last)"
  }
}
