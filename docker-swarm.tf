# ============================================================================
# Docker Swarm Cluster Infrastructure
# ============================================================================
# Architecture: Single Swarm with 3 infra nodes + 1 management LXC
#   - 3 Infrastructure Nodes (docker-infra-1/2/3) - Swarm Managers + Patroni
#   - 1 Management LXC (swarm-control) - Portainer (bootstrap/recovery)
#
# Storage: ZFS Tank pool (pve01/pve03), local-lvm (pve02)
# Network: Dual VLAN (4 = Cluster, 12 = Storage/Replication)
# ============================================================================

# ============================================================================
# Cloud-Init Snippets
# ============================================================================

# Infrastructure Nodes Cloud-Init
resource "proxmox_virtual_environment_file" "cloud_init_infra" {
  for_each = var.infra_nodes

  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value.node

  source_raw {
    data = templatefile("${path.module}/terraform/docker-swarm/cloud-init-docker.yml", {
      vm_hostname = "${var.infra_node_prefix}-${each.key}"
      ghcr_user   = var.ghcr_user
      ghcr_pat    = var.ghcr_pat
    })
    file_name = "cloud-init-${var.infra_node_prefix}-${each.key}.yml"
  }
}

# ============================================================================
# Infrastructure Nodes (Swarm Managers + Patroni PostgreSQL)
# ============================================================================

resource "proxmox_virtual_environment_vm" "infra_nodes" {
  for_each = var.infra_nodes

  name      = "${var.infra_node_prefix}-${each.key}"
  node_name = each.value.node
  vm_id     = each.value.vm_id

  tags = ["docker", "swarm", "infra", "database"]

  clone {
    vm_id     = var.template_id
    node_name = "pve01"
    full      = true
  }

  cpu {
    cores = var.infra_node_cores
    type  = "host"
  }

  memory {
    dedicated = coalesce(each.value.memory, var.infra_node_memory)
    floating  = coalesce(each.value.balloon, 0) # >0 = Ballooning (min=floating, max=dedicated)
  }

  boot_order = ["scsi0"]

  # Boot disk (uses node-specific storage or default)
  disk {
    datastore_id = coalesce(each.value.storage_pool, var.storage_pool)
    interface    = "scsi0"
    size         = var.infra_node_boot_disk_size
  }

  # Data disk for Docker data-root (/srv/data/docker) — separate from OS root
  # so containers/volumes/images cannot fill /. SeaweedFS removed 2026-05-09;
  # Patroni runs as a Swarm service, not directly on this disk.
  disk {
    datastore_id = coalesce(each.value.storage_pool, var.storage_pool)
    interface    = "scsi1"
    size         = each.value.data_disk_size
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
        address = "${each.value.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }

    # IP Config for VLAN 12 (eth1 - Storage, no gateway)
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan12}/24"
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_infra[each.key].id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  # Clean SSH known_hosts after VM creation
  provisioner "local-exec" {
    command = "ssh-keygen -R ${each.value.ip_vlan4} 2>/dev/null || true"
  }

  # ==========================================================================
  # 2026-08-12: SCHUTZ GEGEN UNGEWOLLTES REPLACE
  # ==========================================================================
  # Ohne diesen Block meldete `terraform plan` am 2026-08-12:
  #   proxmox_virtual_environment_vm.infra_nodes["1"|"2"|"3"] must be replaced
  # also destroy+create aller drei Swarm-Nodes — ausgeloest durch eine voellig
  # harmlose Bearbeitung der Cloud-Init-Vorlage. Die Kaskade:
  #
  #   cloud-init-*.yml bearbeitet
  #     -> proxmox_virtual_environment_file...data aendert sich
  #       -> Datei-Ressource wird ersetzt -> NEUE Datei-ID
  #         -> initialization.user_data_file_id aendert sich
  #           -> und das ist ForceNew -> die VM wird zerstoert und neu gebaut
  #
  # Cloud-Init laeuft ausschliesslich beim ERSTEN Boot. Eine spaetere Aenderung
  # ist fuer die laufende VM folgenlos und darf sie niemals ersetzen.
  #
  # user_account ist zusaetzlich write-only: Proxmox liefert Keys und Passwort
  # nie zurueck, Terraform liest sie deshalb bei JEDEM Plan als "fehlt" und
  # erzwingt Replace — ein Dauerzustand, kein einmaliger Drift.
  #
  # KONSEQUENZ: Terraform verwaltet diese beiden Attribute nicht mehr. Soll die
  # Cloud-Init einer BESTEHENDEN VM wirklich neu angewandt werden, muss die VM
  # bewusst per `terraform taint` bzw. `-replace=` ersetzt werden — mit Snapshot
  # vorher (siehe Disaster-Recovery-Regel in .claude/CLAUDE.md).
  # `clone` beschreibt ausschliesslich, WIE die VM einst erzeugt wurde, und ist
  # fuer die laufende Instanz bedeutungslos. Im State fehlt der Block bei
  # infra_nodes["2"] und ["3"] (anders als bei ["1"]) — Terraform wollte ihn
  # deshalb nachtragen, und weil jedes clone-Attribut ForceNew ist, haette das
  # beide Nodes zerstoert.
  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
      initialization[0].user_account,
      clone,
    ]
  }
}
