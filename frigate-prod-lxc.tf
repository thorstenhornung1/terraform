# ============================================================================
# Frigate Production LXC — Intel iGPU (OpenVINO) + Ceph Storage
# ============================================================================
# Purpose: Production Frigate 0.17 NVR with local OpenVINO object detection
# Container Type: LXC (privileged — required for /dev/dri passthrough)
# Network: Dual-NIC — VLAN 4 (cluster) + VLAN 12 (Ceph storage)
#
# Architecture:
#   - Privileged LXC on pve03 with Intel HD Graphics 630 passthrough
#   - Docker CE + Docker Compose for Frigate + Traefik
#   - OpenVINO detector (device: AUTO) replaces remote ZMQ detector
#   - CephFS for config/clips/exports (3x replicated)
#   - Ceph RBD for recordings (1 TB, replica 1) + SQLite DB (10 GB, replica 3)
#   - Traefik reverse proxy for HTTPS (Let's Encrypt DNS-01)
#
# PRE-REQUISITES (Phase 0 + 1 — manual on Ceph/Proxmox nodes):
#   1. Create Ceph client: client.frigate-prod (see plan Phase 1.1)
#   2. Create Ceph pool: frigate-recordings (replica 1)
#   3. Create RBD images: frigate-recordings + frigate-db
#   4. Create CephFS dirs under /mnt/cephfs/swarm-state/stack-frigate-prod/
#
# Deployment:
#   terraform apply -target=proxmox_virtual_environment_container.frigate_prod
#   # Then wait for iGPU passthrough + setup to complete automatically
# ============================================================================

# ============================================================================
# LXC Container — Privileged for GPU Access
# ============================================================================

resource "proxmox_virtual_environment_container" "frigate_prod" {
  node_name = var.frigate_prod.node
  vm_id     = var.frigate_prod.vm_id

  description = "Frigate Production NVR — OpenVINO iGPU + Ceph Storage"
  tags        = ["frigate", "openvino", "production", "gpu"]

  # =========================================================================
  # Container Resources — Sized for OpenVINO + ffmpeg + SQLite + 10 cameras
  # =========================================================================

  cpu {
    cores = var.frigate_prod.cores
  }

  memory {
    dedicated = var.frigate_prod.memory
    swap      = 0
  }

  # =========================================================================
  # Storage — ZFS Tank for snapshots
  # =========================================================================

  disk {
    datastore_id = var.frigate_prod.storage_pool
    size         = var.frigate_prod.disk_size
  }

  # =========================================================================
  # Network — Dual-NIC: VLAN 4 (cluster) + VLAN 12 (Ceph storage)
  # =========================================================================

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = false
  }

  network_interface {
    name     = "eth1"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id_storage
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
  # Container Features — Docker Support (nesting + keyctl)
  # =========================================================================

  features {
    nesting = true
    keyctl  = true
  }

  # =========================================================================
  # Privileged Container (Required for /dev/dri GPU passthrough!)
  # =========================================================================

  unprivileged = false

  # =========================================================================
  # Initialization
  # =========================================================================

  initialization {
    hostname = "frigate-prod"

    ip_config {
      ipv4 {
        address = "${var.frigate_prod.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }

    # VLAN 12 — Ceph storage network (no gateway, point-to-point)
    ip_config {
      ipv4 {
        address = "${var.frigate_prod.ip_vlan12}/24"
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
  # Startup — Production service, auto-start after Ceph
  # =========================================================================

  start_on_boot = true

  startup {
    order = "3"
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
    command = "ssh-keygen -R ${var.frigate_prod.ip_vlan4} 2>/dev/null || true"
  }

  # =========================================================================
  # Lifecycle — Prevent replacement after import
  # =========================================================================

  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
      operating_system[0].template_file_id,
      features,       # Managed by pct create (API token can't modify privileged features)
      console,        # pct default is tty, Terraform wants console
      unprivileged,   # Set at creation time, read-only
      description,    # URL-encoded by Proxmox on import
    ]
  }
}

# ============================================================================
# iGPU Passthrough — Inject cgroup + mount entries into LXC config
# ============================================================================
# Device numbers:
#   226:0   = /dev/dri/card0 (display)
#   226:128 = /dev/dri/renderD128 (compute — used by OpenVINO)
#   29:0    = /dev/fb0 (framebuffer — some OpenVINO operations)

resource "null_resource" "frigate_prod_igpu_passthrough" {
  triggers = {
    container_id = proxmox_virtual_environment_container.frigate_prod.id
  }

  connection {
    type        = "ssh"
    host        = "192.168.2.12" # pve03 management IP
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '=== Configuring iGPU passthrough for LXC ${var.frigate_prod.vm_id} ==='",

      # Check if iGPU is available on the host
      "test -e /dev/dri/renderD128 || (echo 'ERROR: /dev/dri/renderD128 not found on pve03! Run: modprobe i915' && exit 1)",

      # Append cgroup + mount entries (only if not already present)
      "grep -q 'lxc.cgroup2.devices.allow: c 226:0' /etc/pve/lxc/${var.frigate_prod.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 226:0 rwm' >> /etc/pve/lxc/${var.frigate_prod.vm_id}.conf",
      "grep -q 'lxc.cgroup2.devices.allow: c 226:128' /etc/pve/lxc/${var.frigate_prod.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 226:128 rwm' >> /etc/pve/lxc/${var.frigate_prod.vm_id}.conf",
      "grep -q 'lxc.cgroup2.devices.allow: c 29:0' /etc/pve/lxc/${var.frigate_prod.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 29:0 rwm' >> /etc/pve/lxc/${var.frigate_prod.vm_id}.conf",
      "grep -q 'lxc.mount.entry: /dev/dri' /etc/pve/lxc/${var.frigate_prod.vm_id}.conf 2>/dev/null || echo 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir' >> /etc/pve/lxc/${var.frigate_prod.vm_id}.conf",

      # Restart container to apply mount entries
      "pct stop ${var.frigate_prod.vm_id} || true",
      "sleep 3",
      "pct start ${var.frigate_prod.vm_id}",
      "sleep 5",

      "echo '=== iGPU passthrough configured — /dev/dri visible inside LXC ==='"
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.frigate_prod
  ]
}

# ============================================================================
# Frigate Production Setup — Docker + Intel GPU + Ceph + Compose Stack
# ============================================================================

resource "null_resource" "frigate_prod_setup" {
  triggers = {
    container_id = proxmox_virtual_environment_container.frigate_prod.id
    passthrough  = null_resource.frigate_prod_igpu_passthrough.id
  }

  connection {
    type        = "ssh"
    host        = var.frigate_prod.ip_vlan4
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "10m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/terraform/frigate-prod/setup-frigate-prod.sh.tpl", {
      hostname           = "frigate-prod"
      ip_vlan4           = var.frigate_prod.ip_vlan4
      ip_vlan12          = var.frigate_prod.ip_vlan12
      ceph_mon_addresses = "192.168.12.10,192.168.12.12,192.168.12.11"
      ceph_client_name   = "frigate-prod"
      ceph_client_key    = var.ceph_frigate_key
      ceph_fsid          = var.ceph_fsid
    })
    destination = "/tmp/setup-frigate-prod.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-frigate-prod.sh",
      "/tmp/setup-frigate-prod.sh",
      "rm -f /tmp/setup-frigate-prod.sh"
    ]
  }

  depends_on = [
    null_resource.frigate_prod_igpu_passthrough
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "frigate_prod" {
  description = "Frigate production LXC details"
  value = {
    vm_id     = proxmox_virtual_environment_container.frigate_prod.vm_id
    hostname  = "frigate-prod"
    ip_vlan4  = var.frigate_prod.ip_vlan4
    ip_vlan12 = var.frigate_prod.ip_vlan12
    proxmox   = var.frigate_prod.node
    cpu       = "${var.frigate_prod.cores} cores"
    memory    = "${var.frigate_prod.memory} MB"
    disk      = "${var.frigate_prod.disk_size} GB"
    ssh       = "ssh root@${var.frigate_prod.ip_vlan4}"
    frigate   = "https://frigate.beta.hornung-bn.de"
  }
}
