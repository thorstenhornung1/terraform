# Platform Extension Requirements — Infrastructure Provisioning

**Scope:** Terraform/Proxmox-Infrastruktur fuer drei neue Services: Tailscale HA-Cluster,
Paperless-ngx und Authentik. Nur Tailscale braucht neue LXC-Ressourcen.

**Erstellt:** 2026-03-07
**Status:** Requirements — bereit fuer Implementierung

---

## Context

Die Docker-Swarm-Homelab-Plattform hat aktuell keinen permanenten Tailscale-Node. GitHub
Actions CI/CD nutzt einen ephemeren Tailscale-Node pro Run (`TS_AUTHKEY`), aber nach dem
Workflow gibt es keinen Remote-Zugang. Ein permanenter, hochverfuegbarer Subnet-Router
ermoeglicht Zugriff auf alle VLAN 4/12 Hosts von ueberall.

Paperless-ngx und Authentik laufen als Docker Swarm Stacks und brauchen **keine** neuen
Terraform-Ressourcen. Ihre Infrastruktur-Anforderungen (CephFS-Pfade, PostgreSQL-Datenbanken)
werden auf der Stack-Deployment-Ebene gehandhabt und hier nur dokumentiert.

---

## IP-Adress-Allokation — Aktueller Stand

VLAN 4 (192.168.4.0/24) bereits vergeben:

| IP | Ressource | VM ID | Node |
|----|-----------|-------|------|
| .1 | Gateway | — | — |
| .2 | dns1 | 4100 | pve01 |
| .3 | dns2 | 4101 | pve02 |
| .4 | dns3 | 4102 | pve03 |
| .40 | docker-infra-1 | 4200 | pve01 |
| .41 | docker-infra-2 | 4201 | pve02 |
| .42 | docker-infra-3 | 4202 | pve03 |
| .50 | swarm-control | 4300 | pve01 |
| .53 | etcd-4 | 4301 | pve02 |
| .54 | etcd-5 | 4302 | pve03 |
| .55 | influxdb-rescue | 4400 | pve03 |
| .60 | frigate-test | 4500 | pve02 |
| .61 | frigate-prod-beta (archiviert) | 4501 | pve03 |
| .70 | frigate (aktiv) | 4502 | pve03 |

**Freie Bereiche:** .5-.39, .43-.49, .51-.52, .56-.59, .62-.69, .71+

---

## Phase 1: Tailscale HA-Cluster (HOHE PRIORITAET)

### Architekturentscheidung: Privilegierter LXC

Tailscale benoetigt ein `/dev/net/tun` TUN-Device:

| Option | Bewertung |
|--------|-----------|
| Unprivileged LXC | Erfordert `lxc.cgroup2.devices.allow: c 10:200 rwm` + `mknod` — fragil |
| Privileged LXC | TUN funktioniert out-of-the-box, konsistent mit swarm-control Pattern |

**Entscheidung: Privilegierter LXC**, konsistent mit `swarmpit.tf`.

### Ressourcen-Allokation

| Eigenschaft | tailscale-1 | tailscale-2 |
|-------------|-------------|-------------|
| VM ID | 4503 | 4504 |
| Hostname | tailscale-1 | tailscale-2 |
| VLAN 4 IP | 192.168.4.56 | 192.168.4.57 |
| Proxmox Node | pve01 | pve02 |
| Storage | tank (ZFS) | tank (ZFS) |
| Disk | 8 GB | 8 GB |
| CPU | 1 Core | 1 Core |
| RAM | 256 MB | 256 MB |
| Container-Typ | Privilegiert | Privilegiert |
| Ubuntu Template | ubuntu-24.04-standard_24.04-2_amd64.tar.zst | identisch |

### keepalived VIP

| Eigenschaft | Wert |
|-------------|------|
| VIP | 192.168.4.58 |
| VRRP Instance | VI_TAILSCALE |
| virtual_router_id | 51 |
| MASTER Priority | 101 (tailscale-1) |
| BACKUP Priority | 100 (tailscale-2) |
| Auth | PASS (shared password in terraform.tfvars) |

Die VIP wird fuer keepalived Health-Tracking verwendet und optional als statische
"Jump-Host" IP innerhalb des LAN. Kein DNS-Eintrag noetig (optional).

### Tailscale State Storage

Tailscale persistiert Auth-State in `/var/lib/tailscale`. Muss Reboots ueberleben,
darf **NICHT** auf CephFS liegen (per MEMORY.md Vorgabe).

Jeder Node authentifiziert sich unabhaengig mit eigenem Auth-Key. Die VIP ist nur
fuer keepalived; Tailscale Subnet-Routing wird pro Node registriert.

### Secrets-Management (analog Frigate-Pattern)

Secrets werden **NICHT** direkt via Terraform `templatefile()` in das Setup-Script
eingebettet, sondern analog zum Frigate-Pattern als Dateien auf ein persistentes
Volume geschrieben. Das Setup-Script liest die Secrets dann von dort.

**Pattern (identisch zu Frigate `/etc/frigate/secrets.env`):**

1. Terraform schreibt eine `secrets.env` Datei auf den LXC-Host:
   ```
   /etc/tailscale/secrets.env
   ```
2. Inhalt (via `provisioner "file"`):
   ```bash
   TAILSCALE_AUTH_KEY=${auth_key}
   KEEPALIVED_VRRP_PASSWORD=${vrrp_password}
   ```
3. Setup-Script sourced die Datei:
   ```bash
   source /etc/tailscale/secrets.env
   tailscale up --authkey=$TAILSCALE_AUTH_KEY ...
   ```
4. Berechtigungen:
   ```bash
   chmod 600 /etc/tailscale/secrets.env
   chown root:root /etc/tailscale/secrets.env
   ```

**Vorteile gegenueber Inline-Secrets:**
- Secrets koennen rotiert werden ohne `terraform apply`
- Konsistent mit Frigate-Pattern (`/etc/frigate/secrets.env`)
- Secrets nicht im Terraform State als Script-Inhalt gespeichert
- Bei Bedarf koennen weitere Secrets (z.B. API-Tokens) ergaenzt werden

**Setup-Script-Aenderung:** Schritt 10 (Tailscale starten) liest den Auth-Key aus
der Datei statt aus einer Template-Variable. Die Variable `auth_key` wird nur fuer
das Schreiben der `secrets.env` benoetigt, nicht direkt im Script.

### Zu bewerbende Subnetze

Beide Nodes bewerben identische Subnetze:
- `192.168.4.0/24` — VLAN 4 (Cluster/Management)
- `192.168.12.0/24` — VLAN 12 (Storage)
- `192.168.2.0/24` — VLAN 2 (Proxmox Management, optional)

Subnet-Routing muss in der Tailscale Admin Console nach Deployment genehmigt werden.

### Netzwerk

Single NIC pro Container — nur VLAN 4. Kein VLAN 12 noetig (Tailscale macht keine
Storage-Replikation). keepalived VRRP-Multicast (224.0.0.18) funktioniert automatisch
auf dem Standard-vmbr0-Bridge-Setup.

### Terraform-Datei: `tailscale-cluster.tf`

Pattern: `dns-cluster.tf` (Single-NIC LXC, `for_each` ueber Map-Variable,
`null_resource` + `remote-exec` Provisioning).

### Neue Variablen in `variables.tf`

(Pattern von `dns_nodes`, Zeilen 318-362)

```hcl
# ============================================================================
# Tailscale HA Subnet Router Cluster
# ============================================================================
# Two privileged LXC containers with keepalived VRRP for HA.
# Provides persistent remote access via Tailscale subnet routing.
# State stored on ZFS tank (NOT CephFS).

variable "tailscale_nodes" {
  description = "Tailscale subnet router LXC cluster configuration"
  type = map(object({
    node         = string
    vm_id        = number
    ip           = string
    priority     = number
    storage_pool = optional(string)
  }))
  default = {
    "1" = {
      node     = "pve01"
      vm_id    = 4503
      ip       = "192.168.4.56"
      priority = 101
    }
    "2" = {
      node     = "pve02"
      vm_id    = 4504
      ip       = "192.168.4.57"
      priority = 100
    }
  }
}

variable "tailscale_vip" {
  description = "keepalived Virtual IP for Tailscale cluster"
  type        = string
  default     = "192.168.4.58"
}

variable "tailscale_vrrp_id" {
  description = "VRRP virtual_router_id (must be unique on VLAN 4)"
  type        = number
  default     = 51
}

variable "tailscale_vrrp_password" {
  description = "keepalived VRRP authentication password"
  type        = string
  sensitive   = true
}

variable "tailscale_auth_key" {
  description = "Tailscale reusable auth key (pre-authenticated, subnet routing)"
  type        = string
  sensitive   = true
}

variable "tailscale_advertise_routes" {
  description = "CIDR subnets to advertise via Tailscale subnet routing"
  type        = string
  default     = "192.168.4.0/24,192.168.12.0/24,192.168.2.0/24"
}

variable "tailscale_node_cores" {
  description = "CPU cores for Tailscale LXC containers"
  type        = number
  default     = 1
}

variable "tailscale_node_memory" {
  description = "Memory in MB for Tailscale LXC containers"
  type        = number
  default     = 256
}

variable "tailscale_node_disk_size" {
  description = "Disk size in GB for Tailscale LXC containers"
  type        = number
  default     = 8
}
```

### Sensitive Variablen in `terraform.tfvars`

```hcl
tailscale_auth_key      = "tskey-auth-..."   # Reusable, pre-authenticated
tailscale_vrrp_password = "..."               # Shared VRRP password
```

### Setup-Script: `terraform/tailscale/setup-tailscale.sh.tpl`

Template-Variablen (via `templatefile()`):
- `hostname`, `ip`, `vip`, `vrrp_id`, `vrrp_password`, `priority`
- `auth_key`, `advertise_routes`, `peer_ip`

Script-Schritte (in Reihenfolge):
1. APT-Proxy Konfiguration (`/etc/apt/apt.conf.d/01proxy`) — identisch zu `setup-dns.sh.tpl`
2. Pakete installieren: `curl ca-certificates keepalived`
3. SSSD/LDAP Konfiguration — identisch zu `setup-dns.sh.tpl` (Zeilen 54-91)
4. NSSwitch — identisch (Zeilen 97-110)
5. PAM mkhomedir — identisch (Zeilen 118-127)
6. rsyslog nach Loki — identisch (Zeilen 137-144)
7. SSSD + rsyslog starten — identisch (Zeilen 152-154)
8. Tailscale installieren:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   ```
9. IP-Forwarding aktivieren:
   ```bash
   echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-tailscale.conf
   echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale.conf
   sysctl -p /etc/sysctl.d/99-tailscale.conf
   ```
10. Tailscale starten:
    ```bash
    tailscale up --authkey=${auth_key} \
      --advertise-routes=${advertise_routes} \
      --accept-routes=false \
      --hostname=${hostname}
    ```
11. keepalived konfigurieren:
    ```bash
    cat > /etc/keepalived/keepalived.conf << KEEPALIVED_EOF
    vrrp_instance VI_TAILSCALE {
        state $([ ${priority} -gt 100 ] && echo "MASTER" || echo "BACKUP")
        interface eth0
        virtual_router_id ${vrrp_id}
        priority ${priority}
        advert_int 1

        authentication {
            auth_type PASS
            auth_pass ${vrrp_password}
        }

        virtual_ipaddress {
            ${vip}/24
        }
    }
    KEEPALIVED_EOF

    systemctl enable keepalived
    systemctl start keepalived
    ```

### Startup-Reihenfolge

```hcl
startup {
  order      = "2"    # Nach DNS (order=1), vor Docker Swarm (order=3+)
  up_delay   = "20"
  down_delay = "10"
}
```

### Manuelle Post-Deployment-Schritte

1. **Tailscale Admin Console:** Subnet-Routes fuer beide Nodes genehmigen
2. **Technitium DNS** (optional):
   - `tailscale-1.hornung-bn.de` -> `192.168.4.56`
   - `tailscale-2.hornung-bn.de` -> `192.168.4.57`
3. **GitHub Actions** (optional): CI/CD kann weiterhin eigenen ephemeren Node nutzen,
   oder auf SSH ueber Tailscale VIP umgestellt werden

### Verifikation

```bash
# SSH zu tailscale-1
ssh root@192.168.4.56

# Tailscale Status
tailscale status
# Erwartet: Beide Nodes + Subnet-Routes gelistet

# keepalived Status
systemctl status keepalived
# tailscale-1: MASTER
# tailscale-2: BACKUP

# VIP auf MASTER
ip addr show eth0 | grep 192.168.4.58
# Erwartet: nur auf tailscale-1

# Failover testen
ssh root@192.168.4.56 "systemctl stop keepalived"
ssh root@192.168.4.57 "ip addr show eth0 | grep 192.168.4.58"
# Erwartet: VIP ist auf tailscale-2

# Subnet-Routing testen (von einem Tailscale-Device)
ping 192.168.4.40   # docker-infra-1
ping 192.168.4.2    # dns1
```

---

## Phase 2: CephFS-Verzeichnisse fuer Paperless-ngx

Keine Terraform-Ressourcen noetig. CephFS-Verzeichnisse vor Stack-Deployment anlegen:

```bash
# Auf einem beliebigen Infra-Node (z.B. docker-infra-1)
mkdir -p /mnt/cephfs/swarm-state/stack-paperless/{data,media,export,consume}
chown -R 1000:1000 /mnt/cephfs/swarm-state/stack-paperless
```

| Pfad | Zweck |
|------|-------|
| `stack-paperless/data` | Suchindex, Anwendungsdaten |
| `stack-paperless/media` | Dokumentenspeicher (PDFs, Scans) |
| `stack-paperless/export` | Export-Verzeichnis |
| `stack-paperless/consume` | Import-Inbox (Eingangskorb) |

### PBS Backup

Automatisch abgedeckt — `pbs-backup-stack.yml` mounted `/mnt/cephfs/swarm-state/` als
Read-Only Volume. Neue Unterverzeichnisse werden automatisch mit gesichert.

---

## Phase 3: CephFS-Verzeichnisse fuer Authentik

Keine Terraform-Ressourcen noetig. CephFS-Verzeichnisse vor Stack-Deployment anlegen:

```bash
mkdir -p /mnt/cephfs/swarm-state/stack-authentik/{media,certs}
chown -R 1000:1000 /mnt/cephfs/swarm-state/stack-authentik
```

| Pfad | Zweck |
|------|-------|
| `stack-authentik/media` | Custom Branding (Logos, Hintergruende) |
| `stack-authentik/certs` | Custom TLS-Zertifikate |

### PBS Backup

Ebenfalls automatisch abgedeckt.

---

## Vollstaendige IP-Allokationstabelle nach allen Aenderungen

| IP | Ressource | VM ID | Node | Storage | Status |
|----|-----------|-------|------|---------|--------|
| 192.168.4.2 | dns1 | 4100 | pve01 | tank | bestehend |
| 192.168.4.3 | dns2 | 4101 | pve02 | tank | bestehend |
| 192.168.4.4 | dns3 | 4102 | pve03 | tank | bestehend |
| 192.168.4.40 | docker-infra-1 | 4200 | pve01 | tank | bestehend |
| 192.168.4.41 | docker-infra-2 | 4201 | pve02 | local-lvm | bestehend |
| 192.168.4.42 | docker-infra-3 | 4202 | pve03 | tank | bestehend |
| 192.168.4.50 | swarm-control | 4300 | pve01 | tank | bestehend |
| 192.168.4.53 | etcd-4 | 4301 | pve02 | tank | bestehend |
| 192.168.4.54 | etcd-5 | 4302 | pve03 | local-lvm | bestehend |
| 192.168.4.55 | influxdb-rescue | 4400 | pve03 | tank | bestehend |
| 192.168.4.56 | **tailscale-1** | **4503** | **pve01** | **tank** | **NEU** |
| 192.168.4.57 | **tailscale-2** | **4504** | **pve02** | **tank** | **NEU** |
| 192.168.4.58 | **tailscale VIP** | — | — | — | **NEU (VRRP)** |
| 192.168.4.60 | frigate-test | 4500 | pve02 | tank | bestehend |
| 192.168.4.61 | frigate-prod-beta | 4501 | pve03 | tank | archiviert |
| 192.168.4.70 | frigate | 4502 | pve03 | tank | bestehend |

---

## Referenz-Dateien

| Datei | Verwendung |
|-------|-----------|
| `dns-cluster.tf` | Exaktes Terraform-Pattern fuer Tailscale LXC |
| `terraform/dns/setup-dns.sh.tpl` | Basis fuer setup-tailscale.sh.tpl (APT/SSSD/rsyslog Abschnitte 1-7 sind copy-paste-ready) |
| `variables.tf` (Zeilen 318-362) | `dns_nodes` Variable als Pattern fuer `tailscale_nodes` |
| `swarmpit.tf` | Privilegierter LXC Pattern (`unprivileged = false`) |
