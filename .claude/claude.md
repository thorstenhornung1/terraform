# Claude Project Memory

## 🔴 CRITICAL DISASTER RECOVERY RULE (MANDATORY - 2025-12-27)

**⚠️ STRICT ENFORCEMENT - NEVER DESTROY DATA WITHOUT SNAPSHOT:**

### Pre-Destruction Snapshot Requirement

**BEFORE** any operation that could destroy data (terraform destroy, VM deletion, disk resize, etc.):

1. ✅ **ALWAYS create a Proxmox snapshot** of the VM/resource
2. ✅ **ALWAYS verify snapshot was created successfully**
3. ✅ **ALWAYS document what data exists on the resource**
4. ❌ **NEVER** proceed with destruction without snapshot

**Example workflow:**
```bash
# 1. Create snapshot FIRST
ssh root@pve01 "qm snapshot 4000 pre-destroy-$(date +%Y%m%d-%H%M%S)"

# 2. Verify snapshot exists
ssh root@pve01 "qm listsnapshot 4000"

# 3. ONLY THEN proceed with terraform destroy
terraform destroy -target=proxmox_virtual_environment_vm.bootstrap_host
```

**Why this rule exists:**
- Production VMs may contain critical secrets (e.g., Infisical SQLite database)
- Snapshots enable instant rollback if destruction was premature
- ZFS snapshots on tank storage are instant and space-efficient
- Violating this rule can cause catastrophic data loss

## 🔴 CRITICAL STORAGE RULES (MANDATORY - 2025-12-26, UPDATED 2025-12-27)

**⚠️ STRICT ENFORCEMENT - VIOLATIONS WILL BE REJECTED:**

### Allowed Storage Usage

1. **VM Disks:**
   - ✅ `local-lvm` - Default for ephemeral K3s cluster VMs
   - ✅ `tank` - ZFS pool for HA-critical VMs (bootstrap host, production databases)
   - ❌ **NEVER** use Synology storage (NFS/iSCSI/SMB) for VM disks

2. **Storage Selection Logic:**
   - **Bootstrap Host (VM 4001)**: `tank` (ZFS) - HA requirement, contains critical secrets
   - **K3s Masters/Workers**: `local-lvm` - Stateless, can be rebuilt
   - **Production databases with backups**: `tank` (ZFS) - Snapshot capability required

2. **Cloud-Init Snippets (ONLY):**
   - ✅ `local` - Snippets directory for cloud-init templates
   - ✅ `Diskstation-NFS` - MAY be used for cloud-init snippets ONLY
   - ⚠️ Cloud-init snippets can be unlinked after VM setup

3. **FORBIDDEN for VMs:**
   - ❌ Synology_SMB (CIFS) - causes deployment failures
   - ❌ Diskstation-NFS - ONLY for cloud-init, NOT for VM disks
   - ❌ Any iSCSI targets - causes orphaned LVM volumes
   - ❌ ZFS pools - reserved for other purposes

### Terraform Configuration Rules

**ALWAYS use this pattern:**
```hcl
disk {
  datastore_id = "local-lvm"  # ← MANDATORY, no variables allowed
  interface    = "scsi0"
  size         = 20
}

# Cloud-init OPTIONAL on Diskstation-NFS
initialization {
  user_data_file_id = proxmox_virtual_environment_file.cloud_init.id  # ← Can use NFS
}
```

**Variables.tf MUST specify:**
```hcl
variable "storage_backend" {
  description = "Storage backend per host"
  type        = map(string)
  default = {
    pve01 = "local-lvm"  # ← ONLY local-lvm
    pve02 = "local-lvm"
    pve03 = "local-lvm"
  }
}
```

### Why These Rules Exist

1. **Synology Storage Issues:**
   - SMB mounts go offline randomly
   - iSCSI creates orphaned LVM volumes
   - NFS shares require manual export configuration
   - Terraform fails when ANY Synology storage is offline

2. **Local-LVM Benefits:**
   - Always available (local to Proxmox node)
   - Fast performance (local SSD/NVMe)
   - No network dependencies
   - Clean destroy operations

3. **Cloud-Init Flexibility:**
   - Snippets can use NFS for centralized management
   - After VM boots, cloud-init is no longer needed
   - Can be unlinked without affecting running VM

## Project Context

> ⚠️ **Korrigiert 2026-08-11:** Dieser Abschnitt beschrieb bis heute einen
> K3s-Cluster. **Den gibt es nicht mehr** — weder VMs (`qm list` auf pve01-03)
> noch Kubeconfig existieren. Die Plattform ist seit der Swarm-Migration
> **Docker Swarm**. Alle `kubectl`-Kommandos unten wurden entfernt.

Infrastruktur-Automatisierung für einen **Docker-Swarm-Cluster auf Proxmox VE**:

- **Proxmox VE Cluster (3 Nodes):** pve01 (15 GB RAM), pve02 (32 GB), pve03 (16 GB)
  mit Ceph (Pools `swarm-volumes` für RBD, CephFS `swarm-shared`)
- **Docker Swarm (3 Nodes, alle Manager):**
  - docker-infra-1 = 192.168.4.40 (VM 4200 auf pve01) — Leader
  - docker-infra-2 = 192.168.4.41 (VM 4201 auf pve02)
  - docker-infra-3 = 192.168.4.42 (VM 4202 auf pve03)
- **Datenbank:** `postgres-prod` (VM 4600 auf pve02, 192.168.4.45) — eine
  einzelne PG-VM, KEIN Patroni-Cluster mehr (Patroni gestoppt, reversibel)
- **Ingress:** Traefik v3 (`traefik.swarm.*`-Labels), **SSO:** Authentik (OIDC)
- **Secrets:** Docker Secrets (Anlage über die Portainer-UI, NICHT per CLI) +
  Ansible Vault für Playbooks
- **GitOps:** `swarm-stacks/.github/workflows/deploy-stacks.yml`, ausgeführt vom
  self-hosted GitHub-Runner (LXC 4303 auf pve03). Steht der LXC, hängt **jeder**
  Deploy still in `queued`.

**Storage-Wahl pro Workload — die wichtigste Entscheidung:**

| Datenart | Ziel | Grund |
|---|---|---|
| Große Dateien, sequenziell (Medien, Backups) | **CephFS** `/mnt/cephfs` | genau dafür gebaut |
| **SQLite / LMDB / mmap-Datenbanken** | **Ceph RBD** `/mnt/rbd/*` (ext4) | SQLite-WAL mmap()t die `-shm`-Datei; upstream: *"WAL does not work over a network filesystem"*. Auf CephFS drohen Timeouts und Korruption. |

Bestehende RBD-Volumes: `frigate-config`, `grafana-data`, `openarchiver-meili`,
`paperless-data`. Jedes hat ein Auto-Failover-Setup (`ansible/rbd-mount-*.yml`):
systemd-Map/Mount + Watchdog-Timer auf allen Nodes, der bei Ausfall den
exclusive-lock stiehlt und das Swarm-Label verschiebt.

## Important Secrets

### Location of Credentials

1. **Ansible Vault Password:** `.vault_pass.txt` (gitignored)
2. **Docker Secrets:** im Swarm hinterlegt, **Anlage ausschließlich über die
   Portainer-UI** — nie per `docker secret create` (führt zu Trailing-Newlines
   und Manager-Lesbarkeitsproblemen)
3. **`*.tfvars`** sind gitignored (enthalten u. a. das GHCR-PAT)

> 🔴 **Secrets NIEMALS auslesen oder anzeigen.** Kein `cat` auf
> `/run/secrets/*`, `*.pw`, `*.key`, Keyrings, `docker config.json`
> (base64 = Klartext) oder `/proc/PID/environ` (enthält `DATABASE_URL`
> samt Passwort — falls unvermeidbar, im **selben** Befehl maskieren).
> Braucht ein Kommando Credentials, führt der Nutzer es aus.

### Critical Configuration Values

**Ceph-Client für Swarm:** `client.docker-swarm`
(`/etc/ceph/ceph.client.docker-swarm.keyring` auf den Infra-Nodes)

**Swarm-Manager-Endpunkt:** `192.168.4.40`; Docker-CLI lokal nicht verfügbar —
der Mac nutzt Podman, Docker-Kommandos laufen per SSH auf den Infra-Nodes.

**Node-Labels steuern Placement:** `app=true` (alle), `apptier`,
`<service>-rbd=active` (folgt dem RBD-Volume, wird vom Watchdog verschoben).

**Swarm-Scheduler kennt NUR `reservations`** — weder `limits` noch den
Ist-Verbrauch, und die Node-Kapazität friert beim Join ein. Eine zu niedrige
Reservation führt daher zu systematischer Überbuchung. Kapazität immer gegen
`free -m` auf dem Node prüfen, nie allein gegen `docker node inspect`
(virtio-Ballooning verschiebt VM-RAM zur Laufzeit).

## Common Operations

### View Ansible Vault Secrets
```bash
ansible-vault view vault/secrets.yml --vault-password-file .vault_pass.txt
```

### Swarm-Zustand prüfen
```bash
ssh root@192.168.4.40 "docker node ls"
ssh root@192.168.4.40 "docker service ls"
ssh root@192.168.4.40 "docker service ps <stack>_<service> --no-trunc"
```

### Stack deployen
Deploy erfolgt über **GitOps**: Commit auf `main` im Repo `swarm-stacks` unter
`stacks/**` → GitHub-Actions-Workflow `deploy-stacks.yml` → SSH-Deploy.
Manuelles `docker stack deploy` umgeht die Pipeline und erzeugt Drift.

```bash
gh run list -R thorstenhornung1/swarm-stacks --workflow=deploy-stacks.yml --limit 3
```

> Das Repo `terraform` enthält `swarm-stacks/` als **eigenständiges** Git-Repo
> (eigener `origin`). Änderungen müssen in **beiden** committet werden.

### In einen Container schauen
```bash
# s6-basierte Images (paperless, …): docker exec erbt die Env NICHT
ssh root@<node> "docker exec <cid> /command/with-contenv <befehl>"
```

> ⚠️ **Rechte immer als Dienstnutzer testen**, nicht als root — `docker exec`
> läuft als root und ignoriert Verzeichnisrechte, meldet also fälschlich Erfolg:
> `docker exec <cid> /command/with-contenv s6-setuidgid <user> touch <pfad>`

### RBD-Volume: Zustand und Failover
```bash
ssh root@<node> "rbd showmapped"
ssh root@<node> "systemctl list-timers '*-rbd-failover.timer'"
# Entscheidung des Watchdogs ansehen, ohne etwas zu ändern:
ssh root@<node> "<SERVICE>_FAILOVER_DRYRUN=1 /usr/local/bin/<service>-rbd-failover.sh"
```

### PostgreSQL (postgres-prod, VM 4600)
```bash
ssh root@pve02 "qm guest exec 4600 -- <befehl>"     # ohne SSH in die VM
```
Backups laufen über den `pg-backup`-Stack
(`stacks/infrastructure/pg-backup/`), nicht mehr über K8s-CronJobs.

## Key Learnings

> 📦 **Historisch (K3s-Ära, bis zur Swarm-Migration).** Die folgenden vier
> Abschnitte — Cluster Rebuild, Infisical, cert-manager, Synology CSI —
> beziehen sich auf den **abgebauten** K3s-Cluster und sind für die heutige
> Swarm-Plattform nicht mehr anwendbar. Aufbewahrt als Kontext für alte
> Commits; nicht als Handlungsanweisung lesen.

### Cluster Rebuild & CI/CD (2025-12-06) — historisch
1. Always update playbooks for idempotency - use `failed_when: false` for operations that may already exist
2. ESO → Infisical requires HTTP internal endpoint to avoid self-signed cert issues
3. ClusterSecretStore shows "Ready" but doesn't create secrets if source paths are empty in Infisical
4. Dynamic pod name discovery prevents hardcoded values from breaking on rebuilds
5. Helm must be installed on K3s master nodes for `kubernetes.core.helm` Ansible module
6. Community Helm charts may be more reliable than official repos (e.g., Synology CSI)

### PostgreSQL Backups
1. Use pg_dump instead of pg_dumpall when running as non-superuser
2. InitContainers with runAsUser: 0 needed to fix volume permissions (UID 26 = postgres)
3. Custom format enables selective restoration and parallel restore
4. Always include checksum verification and metadata files
5. Test restore procedures regularly (monthly recommended)

### Infisical Integration
1. Environment slug in Infisical UI may differ from API slug (e.g., "Production" → "prod")
2. Machine Identity needs explicit project access (Viewer role minimum)
3. ExternalSecret should not use `property` field when syncing from Infisical
4. ClusterSecretStore requires internal cluster URL (not external HTTPS URL)

### cert-manager + Cloudflare
1. DNS01 challenges work well for wildcard certs and internal services
2. Cloudflare API token needs Zone:DNS:Edit permission
3. cert-manager auto-renews certificates 30 days before expiration
4. Let's Encrypt staging should be used for testing to avoid rate limits

### Traefik IngressRoutes
1. Separate IngressRoutes for HTTP and HTTPS
2. Use Middleware for HTTP → HTTPS redirect
3. TLS secret must be in same namespace as IngressRoute
4. HTTP/2 is automatically enabled when using TLS

### Synology CSI Driver
1. StorageClass `dsm` parameter must EXACTLY match the `host` in client-info.yaml
2. Use IP address OR hostname consistently - no mixing
3. Parameters in StorageClass cannot be updated - must delete and recreate
4. ExternalSecret controller will automatically overwrite manually edited secrets
5. Test volume provisioning immediately after deployment to verify configuration

## Standard LXC Provisioning Patterns (2026-02-14)

When creating new LXC containers, ALWAYS include the following standard configurations.
LXC containers do NOT support `user_data_file_id` (Cloud-Init user data). Instead, use
`null_resource` + `remote-exec` with a setup script template (`setup-*.sh.tpl`).

### Mandatory Components for Every LXC Container

1. **APT Proxy (apt-cacher-ng)**
   ```bash
   cat > /etc/apt/apt.conf.d/01proxy << 'EOF'
   Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
   EOF
   ```
   - Must be configured BEFORE `apt-get update`
   - DNS resolution requires Technitium DNS (192.168.4.2, 192.168.2.3, 192.168.2.4, 192.168.2.5)

2. **LDAP/SSSD Authentication**
   - Packages: `sssd sssd-ldap libnss-sss libpam-sss`
   - LDAP URI: `ldap://ldap.hornung-bn.de`
   - Search Base: `dc=ldap,dc=hornung-bn,dc=de`
   - Bind DN: `uid=root,cn=users,dc=ldap,dc=hornung-bn,dc=de`
   - Config: `/etc/sssd/sssd.conf` (chmod 600!)
   - NSSwitch: `/etc/nsswitch.conf` → add `sss` to passwd/group/shadow
   - PAM: `/etc/pam.d/common-session` → add `pam_mkhomedir.so`

3. **Logging — rsyslog → Loki/Promtail**
   ```bash
   cat > /etc/rsyslog.d/60-loki.conf << 'EOF'
   *.* @@loki.hornung-bn.de:1514
   *.* @loki.hornung-bn.de:1514
   EOF
   ```
   - TCP (`@@`) for reliability, UDP (`@`) as fallback
   - Port 1514 on loki.hornung-bn.de

4. **SSH Access**
   - SSH key set via `initialization.user_account.keys`
   - Password set via `initialization.user_account.password` (var.vm_password)
   - SSH public key: `var.ssh_public_key_path`

### LXC Container Terraform Pattern

```hcl
# Template download (one per Proxmox node)
resource "proxmox_virtual_environment_download_file" "template_name" {
  for_each     = var.node_map
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = each.value.node
  url          = "http://download.proxmox.com/images/system/..."
  file_name    = "template-filename.tar.zst"
  overwrite_unmanaged = false
}

# Container resource
resource "proxmox_virtual_environment_container" "nodes" {
  for_each  = var.node_map
  node_name = each.value.node
  vm_id     = each.value.vm_id
  # ... cpu, memory, disk, network_interface ...
  initialization {
    hostname = "name"
    ip_config { ipv4 { address = "x.x.x.x/24"; gateway = var.network_gateway } }
    dns { servers = var.dns_servers }
    user_account { keys = [file(var.ssh_public_key_path)]; password = var.vm_password }
  }
}

# Provisioning via remote-exec (NOT cloud-init)
resource "null_resource" "setup" {
  for_each = var.node_map
  connection { type = "ssh"; host = each.value.ip; user = "root"; private_key = file(...) }
  provisioner "file" { content = templatefile("terraform/service/setup.sh.tpl", {...}); destination = "/tmp/setup.sh" }
  provisioner "remote-exec" { inline = ["chmod +x /tmp/setup.sh", "/tmp/setup.sh", "rm -f /tmp/setup.sh"] }
}
```

### Existing LXC Containers (Reference)
| Container | Type | VM IDs | Nodes | Storage | File |
|-----------|------|--------|-------|---------|------|
| dns1/2/3 | Unprivileged (Ubuntu 24.04) | 4100-4102 | pve01/02/03 | tank | `dns-cluster.tf` |
| swarm-control | Privileged (Ubuntu 24.04) | 4300 | pve01 | tank | `swarmpit.tf` |
| etcd-4/5 | Unprivileged (Ubuntu 24.04) | 4301-4302 | pve02/03 | tank/local-lvm | `etcd-cluster.tf` |

## Contact/Escalation

For issues:
1. Check `.claude/bugs.md` for known issues
2. Review troubleshooting in `docs/INFISICAL_TLS_DEPLOYMENT.md`
3. Check git history for recent changes
4. Review deployment logs

---

**Last Updated:** 2026-01-30
**Updated By:** Infrastructure Team (PostgreSQL HA Security Hardening)

