# ============================================================================
# Self-hosted GitHub Actions Runner — LXC (Issue swarm-stacks#45)
# ============================================================================
# Purpose: Ephemeral self-hosted runner für die 3 PRIVATEN Repos
#          (Reisekosten-Steuer, Reisekostenabrechnung, swarm-stacks).
#          Verbraucht 0 inkludierte GitHub-Actions-Minuten und löst die
#          AVX-512-Falle strukturell (Runner-i5 == Target-i5).
#
# Container: LXC, UNPRIVILEGED + nesting (Docker-in-LXC für
#            Image-Builds). Privileged scheidet aus: Feature-Flags auf
#            privilegierten LXCs erlaubt Proxmox nur mit root@pam, NICHT
#            per API-Token (dieses Setup nutzt api_token, HTTP 403) —
#            unprivileged ist ohnehin die stärkere Isolation. Bewusst
#            NICHT im Prod-Swarm (Security-Boundary: CI != Prod-Daemon).
# Platzierung: pve02 (Workhorse-RAM; NICHT pve03 — chronisch overcommittet).
# Storage: tank (ZFS) — local-lvm Thin-Pool auf pve02 ist voll
#          (identischer Workaround wie etcd-4, siehe variables.tf:255).
# Provisioning: null_resource + remote-exec (LXC unterstützt kein
#               cloud-init user_data — Standard-Pattern wie etcd-cluster.tf).
#
# SECURITY: Alle 3 Workflow-Repos sind PRIVAT (kein Fork-PR-RCE). Das public
#           `terraform`-Repo hat KEINE Workflows → bekommt NIE einen Runner.
#           Dauerregel: niemals `runs-on: self-hosted` in einem public Repo.
#
# Der Registrierungs-PAT kommt aus terraform.tfvars (var.gha_runner_pat,
# sensitive — gitignored via *.tfvars, NICHT in Git/State-Remote; exakt das
# Muster von ghcr_pat) und wird beim Provisioning nach /opt/gha-runner/.env
# (chmod 600) injiziert; die Runner starten automatisch. KEIN manueller
# Post-apply-Schritt mehr. Nur Tailscale-Auth-Key ('tailscale up',
# interaktiv) und das optionale LDAP-Bind-Passwort bleiben Host-lokal.
# ============================================================================

variable "gha_runner" {
  description = "Self-hosted GitHub Actions Runner LXC configuration"
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
    node         = "pve02"
    vm_id        = 4303           # frei nach swarm-control(4300)/etcd-4(4301)/etcd-5(4302)
    ip           = "192.168.4.58" # frei: Lücke zwischen .57 und .60 (VLAN 4)
    hostname     = "gha-runner"
    cores        = 4
    memory       = 6144
    disk_size    = 40     # BuildKit-Layer-Cache wächst schnell
    storage_pool = "tank" # local-lvm voll auf pve02 (vgl. etcd-4)
  }
}

variable "gha_runner_repos" {
  description = "PRIVATE Repos, für die ephemerale Runner registriert werden"
  type        = list(string)
  default = [
    "thorstenhornung1/Reisekosten-Steuer",
    "thorstenhornung1/Reisekostenabrechnung",
    "thorstenhornung1/swarm-stacks",
  ]
}

variable "gha_runner_labels" {
  description = "Runner-Labels (runs-on-Selektor)"
  type        = string
  default     = "self-hosted,linux,x64,homelab"
}

# Fine-grained GitHub PAT (administration:write auf die 3 PRIVATEN Repos),
# nötig für die Runner-Registrierung. Kein Default = Pflicht: ohne Wert
# bricht `terraform plan/apply` mit klarer Fehlermeldung ab statt einen
# toten Runner zu bauen. Wert kommt aus terraform.tfvars (gitignored via
# *.tfvars, NICHT in Git/State-Remote) — exakt dasselbe Muster wie das
# bereits vorhandene `ghcr_pat`. Das Provisioning schreibt den Wert nach
# /opt/gha-runner/.env (chmod 600); kein manueller Post-apply-Schritt mehr.
variable "gha_runner_pat" {
  description = "GitHub fine-grained PAT (administration:write) für Runner-Registrierung — in terraform.tfvars setzen"
  type        = string
  sensitive   = true
}

# ============================================================================
# LXC Template
# ============================================================================

resource "proxmox_virtual_environment_download_file" "ubuntu_lxc_template_gha" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.gha_runner.node

  url = "http://download.proxmox.com/images/system/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  # Eigener file_name: etcd-4 liegt ebenfalls auf pve02 und hält dasselbe
  # Ubuntu-Template unter dem kanonischen Namen schon in `local`. Zwei
  # download_file-Ressourcen auf dieselbe Datei/Node kollidieren (bpg:
  # "refusing to override existing file"). Eigener Name = separater
  # Cache-Eintrag, keine Kollision, kein State-Besitzstreit mit etcd-4.
  file_name = "ubuntu-24.04-standard_24.04-2_amd64-gha-runner.tar.zst"

  overwrite_unmanaged = false
}

# ============================================================================
# Runner LXC Container (privileged — Docker + Tailscale tun)
# ============================================================================

resource "proxmox_virtual_environment_container" "gha_runner" {
  node_name = var.gha_runner.node
  vm_id     = var.gha_runner.vm_id

  description = "Self-hosted GitHub Actions Runner (ephemeral, 3 private repos)"
  tags        = ["ci", "github-actions", "runner", "docker"]

  cpu {
    cores = var.gha_runner.cores
  }

  memory {
    dedicated = var.gha_runner.memory
    swap      = 0
  }

  disk {
    datastore_id = coalesce(var.gha_runner.storage_pool, "local-lvm")
    size         = var.gha_runner.disk_size
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.vlan_id
    firewall = false
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.ubuntu_lxc_template_gha.id
    type             = "ubuntu"
  }

  # Nur nesting: Proxmox erlaubt per API-Token AUSSCHLIESSLICH das
  # nesting-Flag — jedes andere (auch keyctl) braucht root@pam (HTTP 403
  # "changing feature flags (except nesting) is only allowed for
  # root@pam"). nesting allein genügt für Docker-in-unprivileged-LXC
  # (Image-Builds + myoung34-Runner); keyctl nur für Kernel-Keyring-
  # Randfälle, bei Bedarf später einmalig als root@pam nachsetzbar.
  features {
    nesting = true
  }

  # Unprivileged: privilegierte LXCs lassen per API-Token gar keine
  # Feature-Flag-Änderung zu (root@pam-only); unprivileged ist
  # token-fähig (nur nesting, s.o.) UND die stärkere Isolation. Docker-
  # Builds laufen in unprivileged+nesting; das optionale Tailscale nutzt
  # Userspace-Networking (kein /dev/net/tun — im Setup-Skript gesetzt).
  unprivileged = true

  initialization {
    hostname = var.gha_runner.hostname

    ip_config {
      ipv4 {
        address = "${var.gha_runner.ip}/24"
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
    order      = "4" # nach etcd(1)/swarm/swarm-control(3)
    up_delay   = "60"
    down_delay = "30"
  }

  console {
    type = "console"
  }

  provisioner "local-exec" {
    command = "ssh-keygen -R ${var.gha_runner.ip} 2>/dev/null || true"
  }

  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_lxc_template_gha
  ]
}

# ============================================================================
# Provisioning via remote-exec (LXC kann kein cloud-init user_data)
# ============================================================================

resource "null_resource" "gha_runner_setup" {
  triggers = {
    container_id = proxmox_virtual_environment_container.gha_runner.id
    script_hash  = filemd5("${path.module}/terraform/gha-runner/setup-gha-runner.sh.tpl")
    repos        = join(",", var.gha_runner_repos)
  }

  connection {
    type        = "ssh"
    host        = var.gha_runner.ip
    user        = "root"
    private_key = file(replace(var.ssh_public_key_path, ".pub", ""))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/terraform/gha-runner/setup-gha-runner.sh.tpl", {
      hostname       = var.gha_runner.hostname
      dns_servers    = join(" ", var.dns_servers)
      ghcr_user      = var.ghcr_user
      ghcr_pat       = var.ghcr_pat
      gha_runner_pat = var.gha_runner_pat
      repos          = var.gha_runner_repos
      labels         = var.gha_runner_labels
    })
    destination = "/tmp/setup-gha-runner.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/setup-gha-runner.sh",
      "/tmp/setup-gha-runner.sh",
      "rm -f /tmp/setup-gha-runner.sh",
    ]
  }

  depends_on = [
    proxmox_virtual_environment_container.gha_runner
  ]
}

# ============================================================================
# Outputs
# ============================================================================

output "gha_runner" {
  description = "Self-hosted GitHub Actions Runner LXC"
  value = {
    vm_id    = proxmox_virtual_environment_container.gha_runner.vm_id
    hostname = var.gha_runner.hostname
    ip       = var.gha_runner.ip
    node     = var.gha_runner.node
    cpu      = "${var.gha_runner.cores} cores"
    memory   = "${var.gha_runner.memory} MB"
    disk     = "${var.gha_runner.disk_size} GB (${coalesce(var.gha_runner.storage_pool, "local-lvm")})"
    repos    = var.gha_runner_repos
  }
}

output "gha_runner_next_steps" {
  description = "Schritte rund um terraform apply (PAT VOR apply in tfvars)"
  value = join("\n", [
    "VOR apply: PAT (fine-grained, Administration:read+write auf die 3 privaten Repos)",
    "  erstellen und in terraform.tfvars als  gha_runner_pat = \"github_pat_...\"  setzen.",
    "apply: Provisioning schreibt den PAT nach /opt/gha-runner/.env (chmod 600) und",
    "  startet die 3 ephemeralen Runner automatisch (gha-runner.service).",
    "Optional Tailscale: ssh root@${var.gha_runner.ip} && tailscale up (dauerhafter",
    "  Auth-Key, interaktiv — entkoppelt deploy-stacks vom TS_AUTHKEY-Expiry).",
    "Optional LDAP: ldap_default_authtok in /etc/sssd/sssd.conf, systemctl enable --now sssd.",
    "Verifizieren: GitHub → je Repo → Settings → Actions → Runners (3x 'homelab', idle),",
    "  dann Workflows runs-on: ubuntu-latest → [self-hosted, linux, x64, homelab].",
  ])
}
