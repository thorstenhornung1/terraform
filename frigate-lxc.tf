# ============================================================================
# Frigate Production LXC — Intel iGPU (OpenVINO) + Ceph Storage
# ============================================================================
# Purpose: Production Frigate 0.17 NVR at frigate.hornung-bn.de
# Container Type: LXC (privileged — required for /dev/dri passthrough)
# Network: Dual-NIC — VLAN 4 (cluster) + VLAN 12 (Ceph storage)
#
# Architecture:
#   - Privileged LXC on pve03 with Intel HD Graphics 630 passthrough
#   - Docker CE + Docker Compose for Frigate + Traefik
#   - OpenVINO detector (device: AUTO) for local object detection
#   - CephFS for config/clips/exports (3x replicated)
#   - Ceph RBD for SQLite DB (10 GB, replica 3 on swarm-volumes pool)
#   - Local ZFS (tank/frigate-recordings) for video recordings (no replication)
#   - Traefik reverse proxy for HTTPS (Let's Encrypt HTTP-01)
#
# Storage layout:
#   /config               → CephFS (pipeline deploys config.yml + entrypoint.sh)
#   /db                   → Ceph RBD (replica 3, local ext4 — POSIX locking for SQLite)
#   /media/frigate/clips  → CephFS (3x replicated snapshots)
#   /media/frigate/exports→ CephFS (3x replicated exports)
#   /media/frigate/recordings → ZFS tank/frigate-recordings (local on pve03)
#   /tmp/cache            → tmpfs (256 MB RAM)
#
# ZFS Recordings Replication:
#   Primary: tank/frigate-recordings on pve03 (full size)
#   Replicas: tank/frigate-recordings on pve01 + pve02 (smaller, via zfs send/recv)
#   Purpose: Backup access, NOT HA failover (iGPU only on pve03)
#
# PRE-REQUISITES (manual on Ceph/Proxmox nodes):
#   1. Ceph client: client.frigate-prod (shared with frigate-prod beta)
#   2. ZFS dataset: tank/frigate-recordings on pve03 (already exists)
#      + ZFS replication to pve01/pve02 (smaller quotas)
#   3. RBD image: frigate-prod-db (swarm-volumes pool, replica 3)
#   4. Host-side RBD map + mount unit for DB on pve03
#   5. LXC bind-mounts (mp0: ZFS recordings, mp1: RBD DB) in 4502.conf
#   6. CephFS dirs under /mnt/cephfs/swarm-state/stack-frigate/
#
# Deployment:
#   terraform apply -target=proxmox_virtual_environment_container.frigate
#   # Then: Ceph storage setup → pipeline deploy
# ============================================================================

# ============================================================================
# LXC Container — Privileged for GPU Access
# ============================================================================

resource "proxmox_virtual_environment_container" "frigate" {
  node_name = var.frigate.node
  vm_id     = var.frigate.vm_id

  description = "Frigate Production NVR — frigate.hornung-bn.de — OpenVINO iGPU + Ceph Storage"
  tags        = ["frigate", "openvino", "production", "gpu"]

  # =========================================================================
  # Container Resources — Sized for OpenVINO + ffmpeg + SQLite + 10 cameras
  # =========================================================================

  cpu {
    cores = var.frigate.cores
  }

  memory {
    dedicated = var.frigate.memory
    swap      = 0
  }

  # =========================================================================
  # Storage — ZFS Tank for snapshots
  # =========================================================================

  disk {
    datastore_id = var.frigate.storage_pool
    size         = var.frigate.disk_size
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
  # Container Features — Docker + ceph-fuse (nesting + keyctl + fuse)
  # =========================================================================

  features {
    nesting = true
    keyctl  = true
    fuse    = true
  }

  # =========================================================================
  # Privileged Container (Required for /dev/dri GPU passthrough!)
  # =========================================================================

  unprivileged = false

  # =========================================================================
  # Initialization
  # =========================================================================

  initialization {
    hostname = "frigate"

    ip_config {
      ipv4 {
        address = "${var.frigate.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }

    # VLAN 12 — Ceph storage network (no gateway, point-to-point)
    ip_config {
      ipv4 {
        address = "${var.frigate.ip_vlan12}/24"
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
    command = "ssh-keygen -R ${var.frigate.ip_vlan4} 2>/dev/null || true"
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

resource "null_resource" "frigate_igpu_passthrough" {
  triggers = {
    container_id = proxmox_virtual_environment_container.frigate.id
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
      "echo '=== Configuring iGPU passthrough for LXC ${var.frigate.vm_id} ==='",

      # Check if iGPU is available on the host
      "test -e /dev/dri/renderD128 || (echo 'ERROR: /dev/dri/renderD128 not found on pve03! Run: modprobe i915' && exit 1)",

      # Append cgroup + mount entries (only if not already present)
      "grep -q 'lxc.cgroup2.devices.allow: c 226:0' /etc/pve/lxc/${var.frigate.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 226:0 rwm' >> /etc/pve/lxc/${var.frigate.vm_id}.conf",
      "grep -q 'lxc.cgroup2.devices.allow: c 226:128' /etc/pve/lxc/${var.frigate.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 226:128 rwm' >> /etc/pve/lxc/${var.frigate.vm_id}.conf",
      "grep -q 'lxc.cgroup2.devices.allow: c 29:0' /etc/pve/lxc/${var.frigate.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 29:0 rwm' >> /etc/pve/lxc/${var.frigate.vm_id}.conf",
      "grep -q 'lxc.mount.entry: /dev/dri' /etc/pve/lxc/${var.frigate.vm_id}.conf 2>/dev/null || echo 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir' >> /etc/pve/lxc/${var.frigate.vm_id}.conf",

      # Restart container to apply mount entries
      "pct stop ${var.frigate.vm_id} || true",
      "sleep 3",
      "pct start ${var.frigate.vm_id}",
      "sleep 5",

      "echo '=== iGPU passthrough configured — /dev/dri visible inside LXC ==='"
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.frigate
  ]
}

# ============================================================================
# Frigate Setup — Docker + Intel GPU + Ceph + Compose Stack
# ============================================================================

resource "null_resource" "frigate_setup" {
  triggers = {
    container_id = proxmox_virtual_environment_container.frigate.id
    passthrough  = null_resource.frigate_igpu_passthrough.id
  }

  connection {
    type        = "ssh"
    host        = var.frigate.ip_vlan4
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "10m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/terraform/frigate/setup-frigate.sh.tpl", {
      hostname           = "frigate"
      ip_vlan4           = var.frigate.ip_vlan4
      ip_vlan12          = var.frigate.ip_vlan12
      ceph_mon_addresses = "192.168.12.10,192.168.12.12,192.168.12.11"
      ceph_client_name   = "frigate-prod"
      ceph_client_key    = var.ceph_frigate_key
      ceph_fsid          = var.ceph_fsid
    })
    destination = "/tmp/setup-frigate.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-frigate.sh",
      "/tmp/setup-frigate.sh",
      "rm -f /tmp/setup-frigate.sh"
    ]
  }

  depends_on = [
    null_resource.frigate_igpu_passthrough
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "frigate" {
  description = "Frigate production LXC details"
  value = {
    vm_id     = proxmox_virtual_environment_container.frigate.vm_id
    hostname  = "frigate"
    ip_vlan4  = var.frigate.ip_vlan4
    ip_vlan12 = var.frigate.ip_vlan12
    proxmox   = var.frigate.node
    cpu       = "${var.frigate.cores} cores"
    memory    = "${var.frigate.memory} MB"
    disk      = "${var.frigate.disk_size} GB"
    ssh       = "ssh root@${var.frigate.ip_vlan4}"
    frigate   = "https://frigate.hornung-bn.de"
  }
}
