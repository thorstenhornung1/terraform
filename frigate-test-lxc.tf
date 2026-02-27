# ============================================================================
# Frigate OpenVINO Test LXC — Intel iGPU on pve03
# ============================================================================
# Purpose: Evaluate Intel iGPU (OpenVINO) for local object detection
# Container Type: LXC (privileged — required for /dev/dri passthrough)
# Service: Docker + Frigate 0.17-rc3 with OpenVINO detector
# Network: Single-NIC — VLAN 4 (Cluster Network)
#
# Architecture:
#   - Privileged LXC on pve03 with Intel iGPU passthrough
#   - Docker CE for running Frigate container
#   - Intel GPU runtime (intel-opencl-icd) for OpenVINO compute
#   - /dev/dri bind-mounted from pve03 host
#
# PRE-REQUISITE: Verify iGPU on pve03 BEFORE terraform apply:
#   ssh root@192.168.2.12 "ls -la /dev/dri/ && lspci | grep -i vga"
#   If /dev/dri/renderD128 missing → modprobe i915
#
# This is a TEST container — start_on_boot = false
# Cleanup: terraform destroy -target=proxmox_virtual_environment_container.frigate_test
# ============================================================================

# ============================================================================
# LXC Container — Privileged for GPU Access
# ============================================================================

resource "proxmox_virtual_environment_container" "frigate_test" {
  node_name = var.frigate_test.node
  vm_id     = var.frigate_test.vm_id

  description = "Frigate OpenVINO Test — Intel iGPU object detection evaluation"
  tags        = ["frigate", "openvino", "test", "gpu"]

  # =========================================================================
  # Container Resources — Sized for Frigate + OpenVINO inference
  # =========================================================================

  cpu {
    cores = var.frigate_test.cores
  }

  memory {
    dedicated = var.frigate_test.memory
    swap      = 0
  }

  # =========================================================================
  # Storage — ZFS Tank for snapshots
  # =========================================================================

  disk {
    datastore_id = var.frigate_test.storage_pool
    size         = var.frigate_test.disk_size
  }

  # =========================================================================
  # Network — VLAN 4 (Cluster Network)
  # =========================================================================

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = false
  }

  # =========================================================================
  # Operating System Template — Ubuntu 24.04
  # =========================================================================
  # Template already present on pve03 (downloaded by etcd-cluster.tf).

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
    hostname = "frigate-test"

    ip_config {
      ipv4 {
        address = "${var.frigate_test.ip}/24"
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
  # Startup — Test container, NO auto-start
  # =========================================================================

  start_on_boot = false

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
    command = "ssh-keygen -R ${var.frigate_test.ip} 2>/dev/null || true"
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
# iGPU Passthrough — Inject cgroup + mount entries into LXC config
# ============================================================================
# The Terraform Proxmox provider doesn't support cgroup device allowlists
# or arbitrary mount entries natively. We SSH to the Proxmox host and
# append the required lines to /etc/pve/lxc/<vmid>.conf, then restart
# the container so the GPU device nodes become visible inside the LXC.
#
# Device numbers:
#   226:0   = /dev/dri/card0 (display)
#   226:128 = /dev/dri/renderD128 (compute — used by OpenVINO)

resource "null_resource" "frigate_test_igpu_passthrough" {
  triggers = {
    container_id = proxmox_virtual_environment_container.frigate_test.id
  }

  connection {
    type        = "ssh"
    host        = var.frigate_test.node == "pve01" ? "192.168.2.10" : var.frigate_test.node == "pve02" ? "192.168.2.11" : "192.168.2.12"
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '=== Configuring iGPU passthrough for LXC ${var.frigate_test.vm_id} ==='",

      # Check if iGPU is available on the host
      "test -e /dev/dri/renderD128 || (echo 'ERROR: /dev/dri/renderD128 not found on ${var.frigate_test.node}! Run: modprobe i915' && exit 1)",

      # Append cgroup + mount entries (only if not already present)
      "grep -q 'lxc.cgroup2.devices.allow: c 226:0' /etc/pve/lxc/${var.frigate_test.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 226:0 rwm' >> /etc/pve/lxc/${var.frigate_test.vm_id}.conf",
      "grep -q 'lxc.cgroup2.devices.allow: c 226:128' /etc/pve/lxc/${var.frigate_test.vm_id}.conf 2>/dev/null || echo 'lxc.cgroup2.devices.allow: c 226:128 rwm' >> /etc/pve/lxc/${var.frigate_test.vm_id}.conf",
      "grep -q 'lxc.mount.entry: /dev/dri' /etc/pve/lxc/${var.frigate_test.vm_id}.conf 2>/dev/null || echo 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir' >> /etc/pve/lxc/${var.frigate_test.vm_id}.conf",

      # Restart container to apply mount entries (pct stop + pct start, NOT reboot)
      "pct stop ${var.frigate_test.vm_id} || true",
      "sleep 3",
      "pct start ${var.frigate_test.vm_id}",
      "sleep 5",

      "echo '=== iGPU passthrough configured — /dev/dri should be visible inside LXC ==='"
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.frigate_test
  ]
}

# ============================================================================
# Frigate Test Setup — Docker + Intel GPU Runtime
# ============================================================================
# Runs after iGPU passthrough is configured and container is restarted.
# Installs: APT proxy, SSSD/LDAP, rsyslog → Loki, Docker CE, Intel GPU tools

resource "null_resource" "frigate_test_setup" {
  triggers = {
    container_id  = proxmox_virtual_environment_container.frigate_test.id
    passthrough   = null_resource.frigate_test_igpu_passthrough.id
  }

  connection {
    type        = "ssh"
    host        = var.frigate_test.ip
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/terraform/frigate-test/setup-frigate-test.sh.tpl", {
      hostname = "frigate-test"
      ip       = var.frigate_test.ip
    })
    destination = "/tmp/setup-frigate-test.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-frigate-test.sh",
      "/tmp/setup-frigate-test.sh",
      "rm -f /tmp/setup-frigate-test.sh"
    ]
  }

  depends_on = [
    null_resource.frigate_test_igpu_passthrough
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "frigate_test" {
  description = "Frigate OpenVINO test LXC details"
  value = {
    vm_id    = proxmox_virtual_environment_container.frigate_test.vm_id
    hostname = "frigate-test"
    ip       = var.frigate_test.ip
    proxmox  = var.frigate_test.node
    cpu      = "${var.frigate_test.cores} cores"
    memory   = "${var.frigate_test.memory} MB"
    disk     = "${var.frigate_test.disk_size} GB"
    ssh      = "ssh root@${var.frigate_test.ip}"
    frigate  = "http://${var.frigate_test.ip}:5001"
  }
}
