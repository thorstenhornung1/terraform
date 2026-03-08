# ============================================================================
# Tailscale HA Subnet Router Cluster — 2-Node LXC Deployment
# ============================================================================
# Purpose: Persistent remote access via Tailscale subnet routing with
#          FRR BGP for high availability (route-based failover)
# Container Type: LXC (privileged — /dev/net/tun required for Tailscale)
# Services: Tailscale (subnet router) + FRR (BGP + BFD failover)
# Network: Single-NIC — VLAN 4 (Management)
#
# BGP topology (eBGP — each node has its own AS):
#   sowi10-1: pve01 / 192.168.4.56 (AS 64512, MED 0   — Primary)
#   sowi10-2: pve02 / 192.168.4.57 (AS 64513, MED 100 — Backup)
#   UniFi UDM-Pro: 192.168.4.1    (AS 65000 — BGP peer)
#
# Both nodes announce 100.64.0.0/10 (Tailscale CGNAT range).
# UniFi selects sowi10-1 (lower MED). BFD provides sub-second failover.
#
# Advertised subnets (via Tailscale):
#   192.168.4.0/24  — VLAN 4 (Cluster/Management)
#   192.168.12.0/24 — VLAN 12 (Storage)
#   192.168.2.0/24  — VLAN 2 (Proxmox Management)
#
# Secrets flow (NOT via terraform.tfvars):
#   1. User creates Docker Swarm secrets in Portainer
#   2. Bootstrap container writes secrets to CephFS
#   3. Terraform copies secrets from CephFS (via infra node) to LXC
#   4. Activate script reads secrets and starts services
#
# Provisioning includes:
#   - APT proxy (apt-cacher.hornung-bn.de)
#   - LDAP/SSSD authentication
#   - rsyslog → Loki forwarding
#   - Tailscale + FRR (BGP/BFD) installation
#
# After Terraform apply:
#   1. Create Swarm secret in Portainer (tailscale_auth_key)
#   2. Run bootstrap container to write secrets to CephFS
#   3. Run: terraform apply (creates LXC, installs, copies secrets, activates)
#   4. Configure BGP on UniFi UDM-Pro
#   5. Approve subnet routes in Tailscale Admin Console
# ============================================================================

# ============================================================================
# Tailscale LXC Containers
# ============================================================================
# Ubuntu 24.04 template already exists on all Proxmox nodes (downloaded by
# etcd-cluster.tf and swarmpit.tf). Referenced directly by storage path.

resource "proxmox_virtual_environment_container" "tailscale_nodes" {
  for_each = var.tailscale_nodes

  node_name = each.value.node
  vm_id     = each.value.vm_id

  description = "Tailscale HA Subnet Router (sowi10-${each.key}) — BGP/FRR failover (AS ${each.value.asn})"
  tags        = ["tailscale", "vpn", "infrastructure", "bgp", "frr"]

  # =========================================================================
  # Container Resources — Minimal profile
  # =========================================================================
  # Tailscale + FRR are lightweight. 1 core and 256MB are sufficient.

  cpu {
    cores = var.tailscale_node_cores
  }

  memory {
    dedicated = var.tailscale_node_memory
    swap      = 0
  }

  # =========================================================================
  # Storage — ZFS Tank for snapshots and data integrity
  # =========================================================================

  disk {
    datastore_id = coalesce(each.value.storage_pool, var.storage_pool)
    size         = var.tailscale_node_disk_size
  }

  # =========================================================================
  # Network Configuration — Single NIC on VLAN 4
  # =========================================================================
  # Tailscale only needs VLAN 4 (management). Subnet routing to VLAN 12/2
  # is handled at the IP level — Tailscale forwards packets, no direct
  # VLAN 12 NIC needed.

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = false
  }

  # =========================================================================
  # Operating System Template — Ubuntu 24.04
  # =========================================================================

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type             = "ubuntu"
  }

  # =========================================================================
  # Container Features — Nesting required for systemd 255+
  # =========================================================================
  # Ubuntu 24.04 ships systemd 255 which requires nesting=true in LXC
  # containers, otherwise systemd fails to start and networking stays down.

  features {
    nesting = true
  }

  # =========================================================================
  # Privileged Container (Required for /dev/net/tun)
  # =========================================================================
  # Tailscale needs /dev/net/tun. Additionally requires manual LXC config:
  #   lxc.cgroup2.devices.allow: c 10:200 rwm
  #   lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
  # These must be added to /etc/pve/lxc/<vmid>.conf on the Proxmox host
  # AFTER container creation (not manageable via Terraform provider).

  unprivileged = false

  # =========================================================================
  # Initialization
  # =========================================================================

  initialization {
    hostname = "sowi10-${each.key}"

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
  # Startup Configuration — After DNS, before Docker Swarm
  # =========================================================================

  start_on_boot = true

  startup {
    order      = "2"
    up_delay   = "20"
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

  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
      operating_system[0].template_file_id,
    ]
  }
}

# ============================================================================
# Phase 1: Base Setup (Tailscale + FRR installation)
# ============================================================================
# Installs all software and configures FRR with BGP + BFD.
# Does NOT start Tailscale or FRR — that happens in Phase 3 (activate).

resource "null_resource" "tailscale_setup" {
  for_each = var.tailscale_nodes

  triggers = {
    container_id = proxmox_virtual_environment_container.tailscale_nodes[each.key].id
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "5m"
  }

  # Render the activate script first (embedded into setup script)
  provisioner "file" {
    content = templatefile("${path.module}/terraform/tailscale/setup-tailscale.sh.tpl", {
      hostname      = "sowi10-${each.key}"
      ip            = each.value.ip
      asn           = each.value.asn
      bgp_med       = each.value.bgp_med
      bgp_peer_ip   = var.tailscale_bgp_peer_ip
      bgp_asn_unifi = var.tailscale_bgp_asn_unifi
      activate_script = templatefile("${path.module}/terraform/tailscale/activate-tailscale.sh.tpl", {
        hostname         = "sowi10-${each.key}"
        advertise_routes = var.tailscale_advertise_routes
      })
    })
    destination = "/tmp/setup-tailscale.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-tailscale.sh",
      "/tmp/setup-tailscale.sh",
      "rm -f /tmp/setup-tailscale.sh"
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.tailscale_nodes
  ]
}

# ============================================================================
# Phase 2: Copy Secrets from CephFS (via infra node SSH chain)
# ============================================================================
# Secrets are stored on CephFS by a Docker Swarm bootstrap container.
# This provisioner copies them from an infra node (which has CephFS mounted)
# to the Tailscale LXC container.
#
# Prerequisite: /mnt/cephfs/swarm-state/stack-tailscale/secrets.env must exist.
# See plan documentation for the bootstrap container one-shot command.

resource "null_resource" "tailscale_secrets" {
  for_each = var.tailscale_nodes

  triggers = {
    container_id = proxmox_virtual_environment_container.tailscale_nodes[each.key].id
  }

  # SSH chain: Local → Infra node (CephFS) → read secrets → SSH → Tailscale LXC
  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no -i ${replace(var.ssh_public_key_path, ".pub", "")} root@192.168.4.40 \
        "cat /mnt/cephfs/swarm-state/stack-tailscale/secrets.env" \
      | ssh -o StrictHostKeyChecking=no -i ${replace(var.ssh_public_key_path, ".pub", "")} root@${each.value.ip} \
        "mkdir -p /etc/tailscale && cat > /etc/tailscale/secrets.env && chmod 600 /etc/tailscale/secrets.env"
    EOT
  }

  depends_on = [
    null_resource.tailscale_setup
  ]
}

# ============================================================================
# Phase 3: Activate Tailscale + FRR
# ============================================================================
# Runs the activate script which reads secrets.env, starts FRR (BGP + BFD),
# and starts Tailscale with auth key and subnet routing.

resource "null_resource" "tailscale_activate" {
  for_each = var.tailscale_nodes

  triggers = {
    container_id = proxmox_virtual_environment_container.tailscale_nodes[each.key].id
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "/usr/local/bin/activate-tailscale.sh"
    ]
  }

  depends_on = [
    null_resource.tailscale_secrets
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "tailscale_nodes" {
  description = "Tailscale HA subnet router cluster node details"
  value = {
    for key, node in proxmox_virtual_environment_container.tailscale_nodes : "sowi10-${key}" => {
      vm_id    = node.vm_id
      hostname = "sowi10-${key}"
      ip       = var.tailscale_nodes[key].ip
      proxmox  = var.tailscale_nodes[key].node
      asn      = var.tailscale_nodes[key].asn
      bgp_med  = var.tailscale_nodes[key].bgp_med
      role     = var.tailscale_nodes[key].bgp_med == 0 ? "PRIMARY" : "BACKUP"
      cpu      = "${var.tailscale_node_cores} core"
      memory   = "${var.tailscale_node_memory} MB"
      disk     = "${var.tailscale_node_disk_size} GB"
    }
  }
}

output "tailscale_cluster_info" {
  description = "Tailscale HA cluster BGP configuration summary"
  value = {
    bgp_peer         = "${var.tailscale_bgp_peer_ip} (AS ${var.tailscale_bgp_asn_unifi})"
    node_asns        = { for k, v in var.tailscale_nodes : "sowi10-${k}" => "AS ${v.asn}" }
    announced        = "100.64.0.0/10"
    advertise_routes = var.tailscale_advertise_routes
    verify_bgp       = "ssh root@${var.tailscale_nodes["1"].ip} 'vtysh -c \"show ip bgp summary\"'"
    verify_routes    = "ssh root@${var.tailscale_nodes["1"].ip} 'vtysh -c \"show ip bgp\"'"
    verify_bfd       = "ssh root@${var.tailscale_nodes["1"].ip} 'vtysh -c \"show bfd peers\"'"
    approve_routes   = "https://login.tailscale.com/admin/machines"
  }
}
