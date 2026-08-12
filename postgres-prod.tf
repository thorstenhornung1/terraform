# ============================================================================
# Standalone PostgreSQL 16 VM — Patroni-Ablösung (Single-VM + Proxmox-HA)
# ============================================================================
# Ersetzt den 3-Node-Patroni-Cluster durch eine einzelne PG-VM auf tank (ZFS,
# lokale NVMe-fsync-Latenz) + pvesr-Replikation + Proxmox-HA.
# Storage-Entscheidung (Research 2026-06-14): NICHT Ceph RBD (fsync übers geteilte
# 1GbE = Performance-Killer). Plan: docs/POSTGRES-SINGLE-VM-HA-MIGRATION-PLAN.md
#
# Netzwerk: VLAN 4 (App-Zugriff, Gateway) + VLAN 12 (Storage/pvesr-Replikation)
# HA-Failover wird erst scharfgeschaltet, wenn der Patroni-Abbau RAM auf
# pve01/pve03 freimacht (ha-manager + pvesr → separater Schritt, nicht hier).
# ============================================================================

resource "proxmox_virtual_environment_file" "cloud_init_postgres_prod" {
  content_type = "snippets"
  # Diskstation-NFS (SHARED) statt local (per-node): Das Snippet MUSS auf ALLEN
  # Nodes sichtbar sein, sonst scheitert der PVE-HA-Failover-Start auf einem
  # anderen Node mit "volume 'local:snippets/cloud-init-postgres-prod.yml' does
  # not exist" (realer Ausfall im Node-Kill-Test 2026-06-28: postgres-prod kam
  # auf pve03 nicht hoch -> DB ~16 min down). CLAUDE.md erlaubt Diskstation-NFS
  # AUSDRUECKLICH nur fuer Cloud-Init-Snippets (shared, alle Nodes mounten es).
  datastore_id = "Diskstation-NFS"
  node_name    = var.postgres_prod.node

  source_raw {
    data = templatefile("${path.module}/terraform/postgres-prod/cloud-init-postgres.yml", {
      vm_hostname = "postgres-prod"
    })
    file_name = "cloud-init-postgres-prod.yml"
  }
}

resource "proxmox_virtual_environment_vm" "postgres_prod" {
  name      = "postgres-prod"
  node_name = var.postgres_prod.node
  vm_id     = var.postgres_prod.vm_id

  tags = ["postgres", "database", "ha"]

  clone {
    vm_id     = var.template_id
    node_name = "pve01"
    full      = true
    # KEIN datastore_id hier: Template liegt auf Diskstation-NFS (shared); ein
    # Cross-Node-Clone (pve01→pve02) auf lokales tank ist von Proxmox verboten
    # ("can't clone to non-shared storage"). Clone geht daher auf NFS (shared),
    # disk.datastore_id=tank unten verschiebt scsi0 danach auf tank (post-clone move).
  }

  cpu {
    cores = var.postgres_prod.cores
    type  = "host"
  }

  memory {
    dedicated = var.postgres_prod.memory
  }

  boot_order = ["scsi0"]

  disk {
    datastore_id = var.postgres_prod.storage_pool
    interface    = "scsi0"
    size         = var.postgres_prod.disk_size
  }

  # VLAN 4 — Cluster/Access (PRIMARY, mit Gateway)
  network_device {
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = true
  }

  # VLAN 12 — Storage/pvesr-Replikation (kein Gateway)
  network_device {
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id_storage
    firewall = true
  }

  initialization {
    # cloudinit-Disk auf tank (NICHT local-lvm — pve02s Thin-Pool ist ~90% voll).
    datastore_id = var.postgres_prod.storage_pool

    ip_config {
      ipv4 {
        address = "${var.postgres_prod.ip_vlan4}/24"
        gateway = var.network_gateway
      }
    }
    ip_config {
      ipv4 {
        address = "${var.postgres_prod.ip_vlan12}/24"
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

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_postgres_prod.id
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  provisioner "local-exec" {
    command = "ssh-keygen -R ${var.postgres_prod.ip_vlan4} 2>/dev/null || true"
  }

  # ==========================================================================
  # 2026-08-12: SCHUTZ GEGEN UNGEWOLLTES REPLACE — HIER BESONDERS KRITISCH
  # ==========================================================================
  # Diese VM traegt NEUN produktive App-Datenbanken. `terraform plan` meldete
  # am 2026-08-12 "proxmox_virtual_environment_vm.postgres_prod must be
  # replaced" — destroy+create, also Totalverlust.
  #
  # Scharf geworden ist die Ladung durch eine voellig harmlose Aenderung: die
  # AGE-Ergaenzung an terraform/postgres-prod/cloud-init-postgres.yml fuer
  # LightRAG (Commits f2da0b5 und 9868ecd). Die Kaskade:
  #
  #   cloud-init-postgres.yml bearbeitet
  #     -> proxmox_virtual_environment_file...data aendert sich
  #       -> Datei-Ressource wird ersetzt -> NEUE Datei-ID
  #         -> initialization.user_data_file_id aendert sich
  #           -> ForceNew -> die Datenbank-VM wird zerstoert und neu gebaut
  #
  # Cloud-Init laeuft nur beim ERSTEN Boot; jede spaetere Aenderung ist fuer die
  # laufende VM folgenlos. user_account ist write-only (Proxmox gibt es nie
  # zurueck), erzeugt also bei JEDEM Plan erneut Replace-Druck.
  #
  # KONSEQUENZ: Terraform verwaltet diese beiden Attribute nicht mehr. Eine
  # bewusste Neuerstellung geht weiterhin ueber `-replace=` — aber NUR mit
  # vorherigem Proxmox-Snapshot UND geprueftem Datenbank-Dump.
  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
      initialization[0].user_account,
    ]
  }
}
