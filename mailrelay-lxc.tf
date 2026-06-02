# ============================================================================
# Homelab Mail-Relay — LXC (Variante C: Postfix-Null-Client → smtp-oauth-relay
#                          → Microsoft Graph sendMail)
# ============================================================================
# Zweck: Zentraler Mail-Versand fürs Homelab. Apps liefern UNAUTHENTIFIZIERT
#        ins LAN ein (SMTP :587/:25, keine Auth — Schutz nur per mynetworks);
#        ein Postfix-Null-Client (boky/postfix) queued und reicht per SASL +
#        STARTTLS an einen co-lokalen smtp-oauth-relay weiter, der app-only
#        OAuth2 (Client Credentials) macht und via Graph sendMail an Microsoft
#        365 zustellt. Absender immer homelab@hornung-bn.de (lizenzfreie
#        Shared Mailbox). Das EINZIGE Secret (Entra Client Secret) liegt nur
#        auf diesem Host (chmod 600, file-mount in den Container).
#
# Unmittelbarer Consumer: Proxmox VE Backup-Fehler (voller vzdump-Fehlertext —
#        der Telegram-Webhook ist wg. 4096-Zeichen-Limit nur Kurz-Alert).
#        Weitere Apps (Grafana, Paperless, Authentik, HA …) später ohne
#        Auth/TLS auf 192.168.4.71 umhängen.
#
# Container: LXC, UNPRIVILEGED + nesting-only (Docker-in-LXC). keyctl/fuse
#        scheiden aus: per API-Token erlaubt Proxmox NUR das nesting-Flag
#        (HTTP 403 sonst) — identisch zu gha-runner.tf. KEIN VLAN-12/Ceph.
# Platzierung: pve01 / tank (ZFS). Bewusst NICHT im Swarm — Mail-Versand
#        (inkl. Backup-Alerts) bleibt von der Swarm-Gesundheit entkoppelt
#        (swarm_os-Wartung rebootet sonst die Alert-Pipeline selbst).
# Provisioning: null_resource + remote-exec (LXC kann kein cloud-init
#        user_data) — Standard-Pattern wie gha-runner.tf / etcd-cluster.tf.
#
# Das Client Secret kommt aus terraform.tfvars (var.mailrelay_client_secret,
# sensitive — gitignored via *.tfvars; exakt das Muster von gha_runner_pat)
# und wird beim Provisioning nach /opt/mailrelay/secrets/relay_client_secret
# (chmod 600) injiziert. M365/Entra-Prereqs (Shared Mailbox, App-Reg, Secret,
# Mail.Send + Admin-Consent, ApplicationAccessPolicy) sind VOR apply manuell
# zu erledigen — siehe output "mailrelay_next_steps".
# ============================================================================

variable "mailrelay" {
  description = "Homelab Mail-Relay LXC (relay.hornung-bn.de)"
  type = object({
    node         = string
    vm_id        = number
    ip           = string
    hostname     = string
    cores        = number
    memory       = number # MB
    disk_size    = number # GB
    storage_pool = optional(string)
  })
  default = {
    node         = "pve01"
    vm_id        = 4505           # frei nach frigate(4502)/tailscale(4503-4504)
    ip           = "192.168.4.71" # frei: höchste belegte VLAN-4-IP ist .70 (frigate)
    hostname     = "relay"
    cores        = 1
    memory       = 512 # postfix + winziger Relay sind genügsam
    disk_size    = 8   # nur Mail-Queue (wie dns/etcd-LXC)
    storage_pool = "tank"
  }
}

# Entra App Client Secret (smtp-relay sendMail App) — das EINZIGE Secret.
# Kein Default = Pflicht: ohne Wert bricht plan/apply mit klarer Meldung ab
# statt einen toten Relay zu bauen. Aus terraform.tfvars (gitignored via
# *.tfvars, NICHT in Git/State-Remote) — exakt das Muster von gha_runner_pat.
# Provisioning schreibt den Wert nach /opt/mailrelay/secrets/relay_client_secret
# (chmod 600, ohne trailing newline).
variable "mailrelay_client_secret" {
  description = "Entra App Client Secret (smtp-relay@) — in terraform.tfvars setzen"
  type        = string
  sensitive   = true
}

# Entra Tenant-ID + App (Client) ID — keine Secrets (GUIDs), aber
# deployment-spezifisch. Kein Default → in terraform.tfvars setzen.
variable "mailrelay_tenant_id" {
  description = "Entra Tenant (Directory) ID — in terraform.tfvars setzen"
  type        = string
}

variable "mailrelay_client_id" {
  description = "Entra App (Client) ID der sendMail-App — in terraform.tfvars setzen"
  type        = string
}

# CIDRs, die unauthentifiziert einliefern dürfen (POSTFIX_mynetworks).
# Postfix läuft network_mode:host (s. setup-Skript) → sieht die ECHTEN
# Quell-IPs (kein Docker-NAT) → exakte Liste statt Bridge-Subnetz:
#   192.168.4.0/24     = VLAN 4 (alle Apps/Swarm/LXCs; deckt auch pve03→.4.16)
#   192.168.2.10/11/12 = die 3 PVE-Mgmt-IPs (pve01/02 routen über .2.x zum Relay)
#   192.168.2.7        = PBS (verifiziert: src 192.168.2.7)
#   127.0.0.0/8        = loopback (lokaler swaks-Test)
variable "mailrelay_trusted_networks" {
  description = "CIDRs für unauthentifizierte Einlieferung (POSTFIX_mynetworks) — VLAN4 + 3 PVEs + PBS"
  type        = string
  default     = "127.0.0.0/8,192.168.4.0/24,192.168.2.7/32,192.168.2.10/32,192.168.2.11/32,192.168.2.12/32"
}

# ============================================================================
# LXC Template
# ============================================================================

resource "proxmox_virtual_environment_download_file" "ubuntu_lxc_template_mailrelay" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.mailrelay.node

  url = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  # Eigener file_name: pve01 hält dasselbe Ubuntu-Template (dns/swarm-control)
  # bereits unter dem kanonischen Namen. Zwei download_file-Ressourcen auf
  # dieselbe Datei/Node kollidieren (bpg: "refusing to override existing
  # file"). Eigener Name = separater Cache-Eintrag, keine Kollision.
  file_name = "ubuntu-24.04-standard_24.04-2_amd64-mailrelay.tar.zst"

  overwrite_unmanaged = false
}

# ============================================================================
# Mail-Relay LXC Container
# ============================================================================

resource "proxmox_virtual_environment_container" "mailrelay" {
  node_name = var.mailrelay.node
  vm_id     = var.mailrelay.vm_id

  description = "Homelab Mail-Relay (Postfix null-client -> smtp-oauth-relay -> MS Graph)"
  tags        = ["mail", "relay", "smtp", "docker"]

  cpu {
    cores = var.mailrelay.cores
  }

  memory {
    dedicated = var.mailrelay.memory
    swap      = 0
  }

  disk {
    datastore_id = coalesce(var.mailrelay.storage_pool, "local-lvm")
    size         = var.mailrelay.disk_size
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = var.vlan_id
    # Firewall an: erlaubt, :25/:587 später per PVE-Firewall auf Trusted-VLANs
    # einzugrenzen (mynetworks vertraut der Docker-Bridge → Port-ACL als
    # zweite Schicht). Greift nur bei aktiver PVE-Cluster/Node-Firewall.
    firewall = true
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.ubuntu_lxc_template_mailrelay.id
    type             = "ubuntu"
  }

  # Nur nesting (API-Token erlaubt kein keyctl/fuse, HTTP 403 — s. gha-runner.tf).
  # nesting genügt für Docker-in-unprivileged-LXC.
  features {
    nesting = true
  }

  unprivileged = true

  initialization {
    hostname = var.mailrelay.hostname

    ip_config {
      ipv4 {
        address = "${var.mailrelay.ip}/24"
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

  start_on_boot = true

  startup {
    order      = "5" # nach etcd/swarm/swarm-control/gha-runner
    up_delay   = "30"
    down_delay = "30"
  }

  console {
    type = "console"
  }

  provisioner "local-exec" {
    command = "ssh-keygen -R ${var.mailrelay.ip} 2>/dev/null || true"
  }

  # Re-apply-Stabilität: diese Felder driften provider-seitig und würden sonst
  # spurious Replacement triggern (identisch frigate-lxc.tf).
  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
      features,
      console,
      unprivileged,
      description,
    ]
  }

  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_lxc_template_mailrelay
  ]
}

# ============================================================================
# Provisioning via remote-exec (LXC kann kein cloud-init user_data)
# ============================================================================

resource "null_resource" "mailrelay_setup" {
  triggers = {
    container_id     = proxmox_virtual_environment_container.mailrelay.id
    script_hash      = filemd5("${path.module}/terraform/mailrelay/setup-mailrelay.sh.tpl")
    trusted_networks = var.mailrelay_trusted_networks
    tenant_id        = var.mailrelay_tenant_id
    client_id        = var.mailrelay_client_id
    # client_secret bewusst NICHT als Trigger (stünde sonst im Plan-Diff im
    # Klartext). Secret-Rotation = re-apply mit geändertem script_hash ODER
    # manuell auf dem Host + 'docker compose up -d'.
  }

  connection {
    type        = "ssh"
    host        = var.mailrelay.ip
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/terraform/mailrelay/setup-mailrelay.sh.tpl", {
      tenant_id        = var.mailrelay_tenant_id
      client_id        = var.mailrelay_client_id
      client_secret    = var.mailrelay_client_secret
      trusted_networks = var.mailrelay_trusted_networks
      bind_addr        = var.mailrelay.ip
    })
    destination = "/tmp/setup-mailrelay.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-mailrelay.sh",
      "/tmp/setup-mailrelay.sh",
      "rm -f /tmp/setup-mailrelay.sh",
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.mailrelay
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "mailrelay" {
  description = "Homelab Mail-Relay LXC"
  value = {
    vm_id    = proxmox_virtual_environment_container.mailrelay.vm_id
    hostname = var.mailrelay.hostname
    ip       = var.mailrelay.ip
    node     = var.mailrelay.node
    smtp     = "${var.mailrelay.ip}:587 (auch :25), keine Auth, mynetworks-only"
    disk     = "${var.mailrelay.disk_size} GB (${coalesce(var.mailrelay.storage_pool, "local-lvm")})"
  }
}

output "mailrelay_next_steps" {
  description = "M365-Prereqs (VOR apply) + Verifikation + PVE-Anbindung"
  value = join("\n", [
    "VOR apply — Microsoft 365 / Entra (einmalig):",
    "  1. Shared Mailbox homelab@hornung-bn.de (lizenzfrei).",
    "  2. App-Registrierung (single tenant) -> Tenant-ID + Client-ID.",
    "  3. Client Secret -> Value -> terraform.tfvars:",
    "       mailrelay_tenant_id     = \"<tenant-guid>\"",
    "       mailrelay_client_id     = \"<client-guid>\"",
    "       mailrelay_client_secret = \"<secret-value>\"",
    "  4. Graph Application-Permission Mail.Send + Admin Consent.",
    "  5. New-ApplicationAccessPolicy (RestrictAccess) -> App nur als smtp-relay@.",
    "apply: Provisioning schreibt das Secret nach /opt/mailrelay/secrets/ (600)",
    "  und startet postfix + smtp-oauth-relay (mailrelay.service).",
    "Verifizieren (vom LAN, OHNE Auth):",
    "  swaks --server ${var.mailrelay.ip} --port 587 --from homelab@hornung-bn.de \\",
    "        --to thorsten@hornung-bn.de --h-Subject 'mailrelay test'",
    "  ssh root@${var.mailrelay.ip} 'cd /opt/mailrelay && docker compose logs smtp-oauth-relay'",
    "    -> Token-Abruf + Graph sendMail 202; 'docker compose exec postfix postqueue -p' leer.",
    "PVE-Anbindung (natives smtp-Target, keine Auth):",
    "  pvesh create /cluster/notifications/endpoints/smtp --name o365-relay \\",
    "    --server ${var.mailrelay.ip} --port 587 --mode insecure \\",
    "    --from-address homelab@hornung-bn.de --mailto thorsten@hornung-bn.de",
    "  pvesh set /cluster/notifications/matchers/default-matcher \\",
    "    --target telegram-backup --target o365-relay",
  ])
}
