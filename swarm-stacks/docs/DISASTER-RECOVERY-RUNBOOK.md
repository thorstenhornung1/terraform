# Disaster Recovery Runbook — Swarm / Ceph / PostgreSQL

**Letzte Aktualisierung:** 2026-04-21
**Autor:** Infrastructure Team (Migration zu GitOps-Workflow + DR-Runbook)
**RTO-Ziel:** 3–4 h bei eingeübter Prozedur — 6–10 h ohne Drill
**RPO:**
- PostgreSQL: max. **24 h** (Daily Dump 03:00 + nächster PBS-Sync binnen 2 h)
- CephFS-State: max. **2 h** (PBS-Schedule `0 */2 * * *`)
- Frigate-Config: max. **2 h** (derselbe Schedule)
- Frigate-Recordings: Synology-NFS-Abhängigkeit (siehe Phase 8)

> **Zweck dieses Runbooks:** Komplette Wiederherstellung nach Verlust des
> Proxmox-/Ceph-Clusters ODER des Swarm-Clusters. Enthält konkrete
> Kommandos, Decision-Points und Validierungs-Checks. Bei partiellem
> Verlust (z.B. nur 1 Node tot): Skip zur jeweiligen Teil-Phase.

---

## Table of Contents

1. [Failure-Scenarios & Decision Tree](#1-failure-scenarios--decision-tree)
2. [Pre-Flight Checks & Voraussetzungen](#2-pre-flight-checks--voraussetzungen)
3. [Phase 1 — Proxmox-Cluster neu aufsetzen](#phase-1--proxmox-cluster-neu-aufsetzen)
4. [Phase 2 — Ceph-Cluster initialisieren](#phase-2--ceph-cluster-initialisieren)
5. [Phase 3 — Pools, CephFS, RBD-Images anlegen](#phase-3--pools-cephfs-rbd-images-anlegen)
6. [Phase 4 — Ceph-Client-Auth für Swarm](#phase-4--ceph-client-auth-für-swarm)
7. [Phase 5 — PBS-Restore nach CephFS + RBD](#phase-5--pbs-restore-nach-cephfs--rbd)
8. [Phase 6 — Swarm-Cluster + Docker-Engine](#phase-6--swarm-cluster--docker-engine)
9. [Phase 7 — Bootstrap-Host + Infisical + Secrets](#phase-7--bootstrap-host--infisical--secrets)
10. [Phase 8 — Stacks via GitOps deployen](#phase-8--stacks-via-gitops-deployen)
11. [Phase 9 — PostgreSQL-Daten wiederherstellen](#phase-9--postgresql-daten-wiederherstellen)
12. [Phase 10 — Validierung & Smoke-Tests](#phase-10--validierung--smoke-tests)
13. [Inventar — Wichtige Adressen/IDs](#inventar--wichtige-adressenids)
14. [Troubleshooting & Known Issues](#troubleshooting--known-issues)

---

## 1. Failure-Scenarios & Decision Tree

Bevor du blindlings dieses Runbook von oben ausführst, entscheide, welches
Scenario vorliegt. Jeder Failure-Typ hat einen optimalen Einstiegspunkt:

```
Was ist kaputt?
├── Einzelner Swarm-Service ↗ Kein DR. Log checken, redeploy via Git.
├── Ein Swarm-Node (docker-infra-N) tot
│   └── Terraform neu deployen + Swarm join ↗ Phase 6
├── Alle Swarm-Nodes tot, Ceph OK
│   └── Start bei Phase 6, skippe Phase 1–5
├── Ceph-FS/RBD kaputt, Ceph-MONs OK
│   └── Phase 3 (FS neu anlegen) + Phase 5 (Restore) + Phase 8–9
├── Ceph komplett weg, PVE-Nodes intakt
│   └── Start bei Phase 2, skippe Phase 1
├── Alles tot (Worst Case)
│   └── Start bei Phase 1 und durchlaufen
└── Nur Postgres-Datenverlust, Rest OK
    └── Patroni neu bootstrappen + Phase 9 (pg_restore aus CephFS)
```

**Regel:** Immer die **teuerste** Zerstörung zuerst rückgängig machen
(Infrastruktur → Storage → Services → Daten). Nie Daten in noch nicht
gesunde Storage-Systeme restaurieren.

---

## 2. Pre-Flight Checks & Voraussetzungen

### Was du **brauchst**, bevor du anfängst

- [ ] **PBS-Zugang:** `backup-swarm@pbs` User, Passwort, Fingerprint
  `73:88:10:c6:bc:65:b1:16:24:88:63:4f:ef:7a:97:c7:71:16:a6:64:b9:9c:af:46:8f:28:c2:3f:f2:f4:fe:28`
- [ ] **PBS-Repository:** `backup-swarm@pbs@pbs.hornung-bn.de:swarm-datastore`
- [ ] **Git-Zugang:** `github.com/thorstenhornung1/swarm-stacks`,
  `github.com/thorstenhornung1/terraform`,
  `github.com/thorstenhornung1/ansible`
- [ ] **GHCR-PAT** (Personal Access Token für Image-Pull in
  cloud-init-Templates)
- [ ] **Ansible-Vault-Passwort** (in Password Manager / secure note)
- [ ] **SSH-Key** für Terraform → Proxmox API
- [ ] **Netzwerk-Plan parat:** VLAN 4 (192.168.4.0/24 Services),
  VLAN 12 (192.168.12.0/24 Ceph/Storage), VLAN 2 (192.168.2.0/24 Mgmt)

### Was du **NICHT** brauchst

- Altes Proxmox-System (fresh install)
- Alte Ceph-Cluster-UUID (neu generiert)
- Alten `client.docker-swarm`-Keyring (neu erzeugt und ausgerollt)

### Wichtige Dokumente parallel offen halten

- `docs/BOOTSTRAP_HOST_ARCHITECTURE.md`
- `docs/POSTGRES_HA_SECURITY.md`
- `docs/POSTGRESQL_BACKUP_SYSTEM.md` (Retention, Paths)
- `stacks/infrastructure/postgres-ha/README.md` (Patroni-Init)
- `CLAUDE.md` im terraform-Repo (Storage-Tier-Rules, VM-IDs)

---

## Phase 1 — Proxmox-Cluster neu aufsetzen

**Skippen wenn:** Proxmox-Nodes intakt.

### 1.1 Fresh Install auf 3 Nodes

Für jeden Node (pve01, pve02, pve03):

```bash
# ISO: https://www.proxmox.com/en/downloads
# Während Install:
#  - Hostname: pve01.hornung-bn.de (entsprechend pve02, pve03)
#  - IP: 192.168.2.10/24 gw 192.168.2.1 (pve02: .11, pve03: .12)
#  - Storage: ZFS RAID1 auf System-SSD + separate Disks für Ceph-OSDs
```

Nach Install auf jedem Node:

```bash
# 1. Repos anpassen (kein-Enterprise)
sed -i 's/^deb/# deb/' /etc/apt/sources.list.d/pve-enterprise.list
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
apt update && apt -y dist-upgrade

# 2. Zeit-Sync, DNS
systemctl enable --now chronyd
echo 'nameserver 192.168.4.2' > /etc/resolv.conf

# 3. VLAN-Interfaces (vmbr0 + VLAN-tags für 4/12/2)
# → via /etc/network/interfaces anhand Netzwerk-Plan
```

### 1.2 Cluster initialisieren

```bash
# Auf pve01:
pvecm create homelab-cluster --link0 <pve01-corosync-ip>

# Auf pve02:
pvecm add <pve01-ip> --link0 <pve02-corosync-ip>

# Auf pve03:
pvecm add <pve01-ip> --link0 <pve03-corosync-ip>

# Prüfen:
pvecm status    # muss "Quorate: Yes" zeigen
```

### 1.3 Proxmox VE Firewall aktivieren

```bash
# Cluster-Level: Firewall aktiv, aber alles erlaubt (Regeln pro VM)
pve-firewall compile && pve-firewall start
```

---

## Phase 2 — Ceph-Cluster initialisieren

**Skippen wenn:** Ceph-Cluster läuft.

### 2.1 Ceph installieren (auf allen 3 Nodes)

```bash
pveceph install --repository no-subscription

# Cluster-Netzwerk (VLAN 12) für Ceph-Replikations-Traffic
pveceph init --network 192.168.12.0/24 --cluster-network 192.168.12.0/24
```

### 2.2 Monitors + Managers deployen (je 3 für Quorum)

Für jeden Node (mit entsprechender VLAN-12 IP):

```bash
# Auf pve01:
pveceph mon create
pveceph mgr create

# Auf pve02, pve03: gleich
```

**Verify:**

```bash
ceph -s
# MUSS:
#   cluster: HEALTH_OK (oder warnings bzgl. OSDs — kommen gleich)
#   mon: 3 daemons, quorum pve01,pve02,pve03
#   mgr: pve01(active), standbys: pve02, pve03
```

### 2.3 OSDs anlegen

Für jede dedizierte Ceph-Disk:

```bash
# Auf jedem Node:
pveceph osd create /dev/sdb   # für jede zusätzliche Disk
# oder per GUI: Node → Ceph → OSD → Create

# Nach allen OSDs:
ceph osd tree   # prüfen: 3x host mit OSDs drunter
ceph osd stat   # alle OSDs up + in
```

---

## Phase 3 — Pools, CephFS, RBD-Images anlegen

### 3.1 Pools

```bash
# Pool-Size/Min-Size = 3/2 (3-Nodes-Standard)
# PG-Zahl: Richtwert = (OSDs * 100) / (Replicas * Pools)
#   Bei 3 OSDs, 3 Pools, Replicas=3: ≈ 32 PGs/Pool

# Pool für RBD-Images
ceph osd pool create swarm-volumes 32 32
ceph osd pool application enable swarm-volumes rbd

# Pools für CephFS
ceph osd pool create cephfs_data 32 32
ceph osd pool create cephfs_metadata 32 32
```

### 3.2 CephFS + MDS

```bash
# FS anlegen
ceph fs new swarm-shared cephfs_metadata cephfs_data

# MDS auf allen 3 Nodes (1 active, 2 standby)
pveceph mds create   # auf jedem Node

# Verify
ceph fs status swarm-shared
# MUSS:
#   state: active, MDS 1 active (Rest standby)
```

### 3.3 RBD-Images (aktuell nur frigate-config)

```bash
# 10 GB, features passend zu Swarm-Node-Kernel
rbd create swarm-volumes/frigate-config \
  --size 10G \
  --image-feature layering,exclusive-lock

# Verify
rbd ls -p swarm-volumes
rbd info swarm-volumes/frigate-config
```

> **Merke:** Falls mehr RBD-Images in Zukunft: hier analog anlegen.
> Die Client-Caps in Phase 4 decken alle Pools ab.

### 3.4 CephFS als PVE-Cluster-Storage registrieren (für LXCs mit CephFS-Bedarf)

**Zweck**: Frigate-LXC (VM 4502) und etwaige andere LXCs konsumieren CephFS via
**Kernel-Mount** auf dem PVE-Host + bind-mount ins LXC — **nicht** via ceph-fuse
im LXC-Namespace. Begründung: vzdump-snapshot hängt chronisch auf ceph-fuse,
weil `fsfreeze` im Prep-Schritt auf FUSE-Antworten wartet (siehe Memory
`project_frigate_lxc_cephfs.md` + Troubleshooting-Kapitel am Ende).

```bash
# 1) Ceph-User für PVE-Cluster-Storage anlegen (gleicher user wie Frigate):
ceph auth get-or-create client.frigate-prod \
  mon 'profile rbd, allow r' \
  mds 'allow rw fsname=swarm-shared' \
  osd 'profile rbd pool=frigate-recordings, profile rbd pool=swarm-volumes, allow rw tag cephfs data=swarm-shared'
# Key notieren.

# 2) Secret-File cluster-weit via pmxcfs ablegen:
echo '<ceph-key>' > /etc/pve/priv/ceph/swarm-shared.secret
chmod 600 /etc/pve/priv/ceph/swarm-shared.secret

# 3) Storage registrieren (pvesm scheitert mit „keyring exists"-Check, daher
#    direkter Eintrag in /etc/pve/storage.cfg — pmxcfs propagiert cluster-weit):
cat >> /etc/pve/storage.cfg <<EOF

cephfs: swarm-shared
	monhost 192.168.12.10 192.168.12.11 192.168.12.12
	username frigate-prod
	content vztmpl,iso,backup,snippets
	fs-name swarm-shared
EOF

# 4) Verify auf allen 3 PVE-Nodes:
for ip in 192.168.2.10 192.168.2.11 192.168.2.12; do
  ssh root@$ip "mount | grep 'pve/swarm-shared'"
done
# Erwartung: "192.168.12.10,11,12:/ on /mnt/pve/swarm-shared type ceph"
# WICHTIG: type=ceph (kernel), nicht type=fuse.ceph-fuse
```

### 3.5 Frigate-LXC-spezifische Konfiguration

Nach LXC-Create (in Phase 6) bzw. bei Restore:

```bash
# LXC muss gestoppt sein für diese Config-Änderung
pct stop 4502

# mp2 via pct set (mit shared=1 für HA-Migration-Kompat)
pct set 4502 --mp2 '/mnt/pve/swarm-shared,mp=/mnt/cephfs,backup=0,shared=1'

# Memory (Frigate 0.17 Multi-Cam braucht 12 GiB + swap, sonst OOM-Kills)
pct set 4502 --memory 12288 --swap 4096

# KRITISCH: Vor erstem Start die alte ceph-fuse-Mount-Unit im LXC maskieren
# (sonst startet sie on-demand wenn Docker auf /mnt/cephfs/* zugreift und
#  überlagert den bind-mount mit FUSE)
pct start 4502
pct exec 4502 -- rm -f /etc/systemd/system/mnt-cephfs.mount
pct exec 4502 -- ln -sf /dev/null /etc/systemd/system/mnt-cephfs.mount
pct exec 4502 -- systemctl daemon-reload
pct reboot 4502

# Verify nach Reboot
pct exec 4502 -- mount | grep cephfs
# Erwartung: "192.168.12.10,11,12:/ on /mnt/cephfs type ceph" (kernel-bind)
# NICHT: "ceph-fuse on /mnt/cephfs type fuse.ceph-fuse"
```

---

## Phase 4 — Ceph-Client-Auth für Swarm

### 4.1 Client-User anlegen

```bash
# Auf pve01 (oder irgendeinem PVE-Node mit ceph CLI):
ceph auth get-or-create client.docker-swarm \
  mon 'allow r' \
  mds 'allow rw' \
  osd 'allow rw pool=cephfs_data, allow rw pool=cephfs_metadata' \
  mgr 'allow rw'

# Für RBD-Pool-Zugriff (frigate-config):
ceph auth caps client.docker-swarm \
  mon 'allow r' \
  mds 'allow rw' \
  osd 'allow rw pool=cephfs_data, allow rw pool=cephfs_metadata' \
  mgr 'allow rw' \
  'profile rbd pool=swarm-volumes'

# Keyring exportieren:
ceph auth get client.docker-swarm -o /tmp/ceph.client.docker-swarm.keyring
# Inhalt ansehen und sicher kopieren
```

### 4.2 Keyring + `ceph.conf` auf Swarm-Nodes verteilen

**Passiert später in Phase 6.2** — nach VM-Creation.

---

## Phase 5 — PBS-Restore nach CephFS + RBD

### 5.1 Temp-Mount anlegen auf einem PVE-Node

```bash
# Ceph-Client auf PVE installieren (sollte schon da sein)
apt -y install ceph-common pbs-client

# Temp-Mount-Punkt
mkdir -p /mnt/recovery/cephfs
mount -t ceph -o name=docker-swarm,secret=$(ceph auth print-key client.docker-swarm) \
  192.168.12.10,192.168.12.11,192.168.12.12:/ \
  /mnt/recovery/cephfs

# RBD map
rbd map swarm-volumes/frigate-config --id docker-swarm \
  --keyring /etc/ceph/ceph.client.docker-swarm.keyring
mkfs.ext4 /dev/rbd/swarm-volumes/frigate-config
mkdir -p /mnt/recovery/frigate-config
mount /dev/rbd/swarm-volumes/frigate-config /mnt/recovery/frigate-config
```

### 5.2 PBS-Snapshots listen

```bash
export PBS_PASSWORD='<backup-swarm-password>'
export PBS_FINGERPRINT='73:88:10:c6:bc:65:b1:16:24:88:63:4f:ef:7a:97:c7:71:16:a6:64:b9:9c:af:46:8f:28:c2:3f:f2:f4:fe:28'
export PBS_REPOSITORY='backup-swarm@pbs@pbs.hornung-bn.de:swarm-datastore'

proxmox-backup-client snapshot list
# Zeigt alle host/swarm-backup-client/<timestamp> Einträge
# Neusten aussuchen, Zeitstempel merken → $SNAPSHOT
```

### 5.3 CephFS-Content restauren

```bash
SNAPSHOT='host/swarm-backup-client/2026-04-21T04:12:16Z'   # anpassen!

# Pxar-Archive extrahieren
proxmox-backup-client restore "$SNAPSHOT" swarm-state.pxar /mnt/recovery/cephfs/

# Rechte fixen (uid/gid bleiben drin, müssen zu den neuen Swarm-Nodes passen)
# Standard: ansible:docker ist uid=1000, gid=999 — je nach cloud-init-Template
```

### 5.4 Frigate-RBD-Content restauren

```bash
proxmox-backup-client restore "$SNAPSHOT" frigate-config.pxar /mnt/recovery/frigate-config/
```

### 5.5 Unmount + RBD unmap

```bash
umount /mnt/recovery/frigate-config
rbd unmap /dev/rbd/swarm-volumes/frigate-config
umount /mnt/recovery/cephfs
```

**Verify:** `ceph df` — `cephfs_data` Pool sollte jetzt mehrere GB belegt
zeigen. `rbd du swarm-volumes/frigate-config` sollte Content-Belegung
zeigen.

---

## Phase 6 — Swarm-Cluster + Docker-Engine

### 6.1 Terraform: Swarm-VMs erzeugen

```bash
cd ~/terraform
# tfvars hat Credentials + GHCR-PAT — aus Password Manager holen
terraform apply -target=proxmox_virtual_environment_vm.docker_infra_1 \
                -target=proxmox_virtual_environment_vm.docker_infra_2 \
                -target=proxmox_virtual_environment_vm.docker_infra_3
```

VMs: `docker-infra-1` (192.168.4.40), `-2` (.41), `-3` (.42).
Cloud-Init installiert Docker, richtet LDAP-SSSD, rsyslog→Loki ein.

### 6.2 Ceph-Client auf jeder Swarm-VM

Für jede Swarm-VM (per SSH):

```bash
# Client-Tools installieren
apt -y install ceph-common

# ceph.conf ablegen (aus Phase 2)
cat > /etc/ceph/ceph.conf <<EOF
[global]
  fsid = <FSID-aus-pve-ceph-s>
  mon_initial_members = pve01, pve02, pve03
  mon_host = 192.168.12.10,192.168.12.11,192.168.12.12
  public_network = 192.168.12.0/24
  cluster_network = 192.168.12.0/24
EOF

# Keyring ablegen (aus Phase 4)
cat > /etc/ceph/ceph.client.docker-swarm.keyring <<EOF
[client.docker-swarm]
  key = <base64-key-aus-phase-4>
EOF
chmod 600 /etc/ceph/ceph.client.docker-swarm.keyring

# CephFS-Mount via fstab
mkdir -p /mnt/cephfs
cat >> /etc/fstab <<EOF
192.168.12.10,192.168.12.11,192.168.12.12:/ /mnt/cephfs ceph \
  name=docker-swarm,secretfile=/etc/ceph/cephfs.secret,_netdev,noatime 0 2
EOF
ceph auth print-key client.docker-swarm > /etc/ceph/cephfs.secret
chmod 600 /etc/ceph/cephfs.secret
mount /mnt/cephfs

# RBD-Mount (nur auf docker-infra-3, da frigate placement dort)
# Siehe ansible-Repo: rbd-mount-frigate.yml
```

Alternativ **via Ansible** (empfohlen):

```bash
cd ~/ansible
ansible-playbook -i inventory-local.ini cephfs-mount.yml
ansible-playbook -i inventory-local.ini rbd-mount-frigate.yml
```

### 6.3 Swarm-Cluster initialisieren

```bash
# Auf docker-infra-1:
docker swarm init --advertise-addr 192.168.4.40
docker swarm join-token manager   # Token kopieren

# Auf docker-infra-2 und -3:
docker swarm join --token SWMTKN-<token> 192.168.4.40:2377
docker node promote docker-infra-2 docker-infra-3   # beide zu managern
```

### 6.4 Node-Labels setzen (aus Ansible-Playbook)

```bash
# prepare-infra-nodes.yml sorgt für:
# - infra_node=1/2/3
# - app=true
# - database=true (relevant für Patroni-placement)
# - storage=true

cd ~/ansible
ansible-playbook -i inventory-local.ini prepare-infra-nodes.yml
```

### 6.5 Overlay-Netzwerke anlegen

```bash
# Auf docker-infra-1 (Manager):
docker network create --driver overlay --attachable traefik_public
# weitere bei Bedarf; die meisten werden von den Stacks selbst erzeugt
```

### 6.6 GHCR-Login

```bash
# Auf jedem Swarm-Node (als root, weil Swarm Images als root zieht):
docker login ghcr.io -u thorstenhornung1 -p <GHCR_PAT>
```

---

## Phase 7 — Bootstrap-Host + Infisical + Secrets

### 7.1 Bootstrap-Host-VM erzeugen

```bash
cd ~/terraform
terraform apply -target=proxmox_virtual_environment_vm.bootstrap_host
# VM 4000, 192.168.4.20, Ubuntu 24.04, Docker + Traefik + Infisical
```

Das Cloud-Init-Template (`terraform/bootstrap-host/cloud-init-docker-infisical.yml`)
installiert die Komponenten. Siehe `docs/BOOTSTRAP_HOST_ARCHITECTURE.md`.

### 7.2 Infisical-SQLite-DB restaurieren

Wenn es ein aktuelles Backup gibt (PBS oder lokal):

```bash
# SSH zum Bootstrap-Host
ssh ansible@192.168.4.20

sudo systemctl stop docker   # Infisical-Container stoppen
sudo cp /backup/infisical.db /opt/infisical/data/infisical.db
sudo chown 1000:1000 /opt/infisical/data/infisical.db
sudo systemctl start docker
```

Falls **kein** Infisical-Backup: Neu initialisieren und Secrets manuell
aus dem Ansible-Vault + Password-Manager wieder eintragen. Siehe
`docs/INFISICAL_RESTORE_GUIDE.md`.

### 7.3 Docker-Swarm-Secrets neu erzeugen

Für jeden Stack, der Secrets nutzt (vaultwarden, taiga, authentik, immich,
samba, postgres-ha, etc.):

```bash
# Variante A: Aus Infisical ziehen (wenn Phase 7.2 geklappt hat)
./stacks/apps/<stack>/create-secrets.sh   # liest aus Infisical, legt docker secrets an

# Variante B: Manuell aus Password-Manager
echo -n '<password>' | docker secret create <secret_name> -
# für immich: immich_db_password, immich_oauth_client_id, immich_oauth_client_secret
# für postgres-ha: pg_superuser_password, replicator, + alle app_db_password
# für authentik: authentik_db_password, authentik_secret_key, authentik_ldap_outpost_token
# für vaultwarden: vaultwarden_db_password, vaultwarden_admin_token
# ... siehe jeweilige create-secrets.sh für vollständige Liste
```

**Wichtig:** OAuth/OIDC-Secrets (Authentik-Provider für Immich, etc.)
müssen in **Authentik** neu erzeugt werden (Setup läuft erst in Phase 8
wenn Authentik-Stack up ist). Bis dahin können Immich-OAuth-Secrets
dummy-Werte haben; später synchronisieren.

---

## Phase 8 — Stacks via GitOps deployen

### 8.1 swarm-stacks-Repo clonen auf Deploy-Host (lokaler Laptop reicht)

```bash
git clone git@github.com:thorstenhornung1/swarm-stacks.git
cd swarm-stacks
```

### 8.2 GitHub Actions manuell triggern

```bash
gh -R thorstenhornung1/swarm-stacks workflow run deploy-stacks.yml
# Redeployt ALLE Stacks in webhooks.conf (workflow_dispatch = "alle")
gh -R thorstenhornung1/swarm-stacks run watch $(gh -R thorstenhornung1/swarm-stacks run list --limit 1 --json databaseId -q '.[0].databaseId')
```

### 8.3 Reihenfolge erzwingen (falls Workflow-Parallelität Probleme macht)

Bei Cold-Start empfohlene Deploy-Reihenfolge:

1. `traefik` (Reverse Proxy — muss zuerst, da alle anderen es brauchen)
2. `valkey-stack` (Cache — von Paperless/n8n benötigt)
3. `postgres-ha-stack` (DB-Cluster — alle App-Stacks brauchen es)
   → warten bis `db-init` einmalig durchlief (alle User angelegt)
4. `authentik-stack` (OIDC-Provider — muss vor abhängigen Apps)
5. Rest (immich, paperless, taiga, vaultwarden, n8n, …)
6. `monitoring` (nice-to-have, darf später)
7. `rescue-tracker` (low-prio)
8. `ceph_backup` + `pg-backup` (Meta: wieder Backups aktivieren!)

Wenn ein Stack aufgrund fehlender Abhängigkeit crasht: Einfach ignorieren,
nach dem Abhängigkeits-Stack nochmal deployen.

### 8.4 Authentik-OIDC-Provider neu anlegen

Im **Authentik-Admin-UI** (https://auth.hornung-bn.de/if/admin/):

- Applications → Providers → Create für jeden OIDC-Consumer:
  - Immich (Redirect URIs: `https://photos.hornung-bn.de/auth/login`,
    `https://photos.hornung-bn.de/user-settings`, `app.immich:///oauth-callback`)
  - Evtl. weitere: siehe Stack-YAML-Header-Kommentare
- Client-ID/Secret kopieren → Docker-Swarm-Secret updaten:
  ```bash
  docker secret rm immich_oauth_client_id immich_oauth_client_secret
  echo -n '<new-client-id>' | docker secret create immich_oauth_client_id -
  echo -n '<new-client-secret>' | docker secret create immich_oauth_client_secret -
  docker service update --force immich_immich-server
  ```

---

## Phase 9 — PostgreSQL-Daten wiederherstellen

**Voraussetzung:** postgres-ha-stack läuft (Phase 8), Patroni-Cluster hat
einen Primary, `db-init` hat leere DBs + User angelegt.

### 9.1 Dumps auf Swarm-Manager bereitstellen

Die Dumps liegen nach dem CephFS-Restore automatisch unter
`/mnt/cephfs/swarm-state/stack-postgres-backup/daily/` bzw. `/weekly/`.

### 9.2 Restore in einem temporären Container

Für **jede** DB einzeln:

```bash
# Variable setzen
DB=immich   # bzw. authentik, vaultwarden, taiga, paperless, n8n, homeassistant
DUMP=$(ls -t /mnt/cephfs/swarm-state/stack-postgres-backup/daily/${DB}_*.dump | head -1)
echo "Restoring $DB from $DUMP"

# Temp-Container mit pg_restore
docker run --rm --network postgres-ha-stack_postgres-network \
  -v /mnt/cephfs/swarm-state/stack-postgres-backup/daily:/backup:ro \
  -e PGPASSWORD="$(docker secret inspect pg_superuser_password --format '{{.Spec.Data}}' | base64 -d)" \
  postgres:16-alpine \
  pg_restore -h pg-haproxy -p 5433 -U postgres -d "$DB" --clean --if-exists "$DUMP"
```

> **Achtung:** `--clean --if-exists` droppt und recreated Objects.
> Ideal in eine **leere** DB. Wenn die DB nicht leer ist (z.B. db-init
> hat schon was angelegt), kann es zu Konflikten kommen → ignorieren.
> pg_restore meldet Warnings, aber Daten werden korrekt importiert.

### 9.3 Globals (Roles, Tablespaces)

```bash
# In der Regel NICHT nötig (pg_dumpall --globals-only) — db-init kümmert sich
# um alle App-User. Nur falls globale Objekte manuell angelegt wurden:
GLOBALS=$(ls -t /mnt/cephfs/swarm-state/stack-postgres-backup/daily/globals_*.sql | head -1)
psql -h pg-haproxy.hornung-bn.de -p 5433 -U postgres -f "$GLOBALS"
```

### 9.4 Verify: Daten da?

```bash
# Beispiel Immich
docker exec -it <postgres-1-container> \
  psql -U postgres -d immich -c "SELECT count(*) FROM assets;"

# Beispiel Authentik
docker exec -it <postgres-1-container> \
  psql -U postgres -d authentik -c "SELECT count(*) FROM authentik_core_user;"
```

---

## Phase 10 — Validierung & Smoke-Tests

### 10.1 Swarm-Health

```bash
ssh root@192.168.4.40 "
  echo '=== Nodes ==='
  docker node ls
  echo
  echo '=== Services: alle 1/1 oder höher? ==='
  docker service ls | awk '/0\//'   # sollte leer sein (außer db-init als one-shot)
  echo
  echo '=== Ceph-Health ==='
  ceph -s
"
```

### 10.2 App-Smoke-Tests

```bash
for URL in \
  https://photos.hornung-bn.de/api/server/ping \
  https://auth.hornung-bn.de/if/admin/ \
  https://vault.hornung-bn.de/alive \
  https://paperless.hornung-bn.de \
  https://tasks.taiga.de \
  https://n8n.hornung-bn.de \
  https://traefik.hornung-bn.de \
  https://grafana.hornung-bn.de
do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$URL")
  echo "  $CODE  $URL"
done
```

Erwartung: alle 200 oder 3xx (Login-Redirects).

### 10.3 Backups wieder aktiv?

```bash
ssh root@192.168.4.40 "
  docker service ls | grep -E 'backup|pbs'
  # pg-backup_pg-backup      1/1
  # ceph_backup_pbs-backup-client  1/1
  echo
  # Letzter pg_dump
  ls -laht /mnt/cephfs/swarm-state/stack-postgres-backup/daily/ | head -5
  echo
  # Letzter PBS-Run
  docker service logs --tail 5 ceph_backup_pbs-backup-client 2>&1
"
```

**Erst wenn Backups wieder laufen, ist DR komplett.**

### 10.4 OIDC-Login-Test

- https://photos.hornung-bn.de → „Login mit Authentik" → erfolgreich?
- Immich-Mobile-App → OAuth-Login → erfolgreich?

---

## Inventar — Wichtige Adressen/IDs

### Netzwerk

| VLAN | CIDR | Zweck |
|---|---|---|
| 2 | 192.168.2.0/24 | Management (PVE-Web, Synology, DNS) |
| 4 | 192.168.4.0/24 | Services / VMs / LXCs |
| 12 | 192.168.12.0/24 | Ceph-Replikation / Storage |

### Schlüssel-Infrastruktur

| Component | Adresse |
|---|---|
| PVE-Nodes | 192.168.2.10/11/12 (pve01/02/03) |
| Proxmox-VE-Web | https://pve01.hornung-bn.de:8006 |
| PBS-Server | pbs.hornung-bn.de:8007 |
| Ceph MONs (VLAN 12) | 192.168.12.10, .11, .12 |
| Swarm-Infra-Nodes | 192.168.4.40 (infra-1), .41, .42 |
| Bootstrap-Host (Infisical) | 192.168.4.20 (VM 4000) |
| DNS-Cluster | 192.168.4.2/3/4 (dns1/2/3, LXC) |
| APT-Cacher | apt-cacher.hornung-bn.de |
| LDAP | ldap.hornung-bn.de |
| Loki | loki.hornung-bn.de:1514 |

### Kritische Secrets (Speicherort)

| Secret | Quelle (Primary) | Backup-Quelle |
|---|---|---|
| PBS-Passwort | Password Manager | – (manuell) |
| Ansible Vault | `.vault_pass.txt` (gitignored) | Password Manager |
| Terraform tfvars | `~/terraform/terraform.tfvars` (gitignored) | Password Manager |
| Infisical Universal Auth | Bootstrap-Host SQLite | PBS-Backup des Bootstrap-Hosts (falls konfiguriert) |
| App-Secrets (DB-PWs, OIDC) | Infisical-Projekte | — (regenerierbar via create-secrets.sh) |

---

## Troubleshooting & Known Issues

### Problem: Swarm-Node rejoint mit neuer Node-ID → Labels weg

Nach disk-full oder WAL-Korruption (Memory 2026-02-21):

```bash
# Auf leader:
docker node ls   # finde alte + neue node-IDs
docker node demote <alte-id> && docker node rm --force <alte-id>

# Alle Labels neu setzen (siehe Phase 6.4 — prepare-infra-nodes.yml)
ansible-playbook -i ~/ansible/inventory-local.ini prepare-infra-nodes.yml

# Force-Redeploy pinned Services
docker service update --force postgres-ha-stack_postgres-1
# ... für jeden Service mit placement-constraint
```

### Problem: Patroni-Replica hängt nach Failover (503)

Zu viele Failovers ohne Replica → Timeline-Divergenz → WAL-gap.

```bash
# Fresh pg_basebackup erzwingen (Replica klont vom Primary neu)
curl -X POST http://postgres-<N>:8008/reinitialize

# Dauert pro DB-Größe einige Minuten; Patroni selbst orchestriert
```

### Problem: `docker stack deploy` failed mit `Host key verification failed`

SSH-intermittent-Issue in GitHub Actions. Retry:

```bash
gh -R thorstenhornung1/swarm-stacks workflow run deploy-stacks.yml
```

### Problem: Config-Änderung greift nicht (immutable Docker Config)

Solltest du nach 2026-04-21 **nicht** mehr sehen (Content-Hash-Pattern).
Falls doch (Legacy-Stack): Manuelle `docker config create` +
`docker service update --config-rm/--config-add`. Siehe Git-Historie
der Immich-Integration für Details.

### Problem: Uptime-Kuma kommt nicht hoch

Known Tech-Debt. DB-Schema-Migration von v1→v10 crasht silently auf der
fresh-v1-DB von 2026-02-21. Beide Feb-Backup-DBs ebenfalls corrupt.

Lösungsoptionen:
- `sqlite3 .recover` auf die 621M-Backup-DB probieren
- Fresh v2-DB starten, Monitore neu anlegen
- v1-Image (1.23.16) pinnen und Live-Upgrade-Pfad planen

### Problem: Kein Snapshot im PBS mehr auffindbar

Wenn `proxmox-backup-client snapshot list` leer bleibt:
- PBS-Server selbst down oder unerreichbar?
- Credentials oder Fingerprint falsch?
- Datastore-Retention hat alte Snapshots geprunt und neue kommen nicht rein,
  weil `ceph_backup_pbs-backup-client`-Service offline ist
- In diesem Fall: Last-Resort ist `cephfs_data`-Pool direkt auf den Ceph-OSDs,
  falls die Disks noch leben. Siehe `docs/POSTGRESQL_BACKUP_SYSTEM.md`.

### Problem: vzdump hängt auf FUSE / Container in D-state

**Symptom**: vzdump-Prozess auf PVE-Host steht in `D`-state (kernel IO wait),
`ps aux` zeigt `task UPID:pve0X:...:vzdump:NNNN:root@pam:` seit Stunden
unverändert. `kill -9` wirkungslos (kernel hält Prozess). LXC-config zeigt
`lock: snapshot`. `/var/run/vzdump.lock` wird blockiert, weitere
Backup-Runs timeouten.

**Root-Cause**: FUSE-Daemon im Container-Namespace antwortet nicht auf
`fsfreeze`-Anfrage (typisch: ceph-fuse im LXC unter Load). Der
PVE-vzdump-Prozess blockiert auf `fuse_send_open` → kernel-IO-Wait →
Signal-immun.

**Diagnose + Recovery**:
```bash
# 1) FUSE-Connection mit waiting>0 finden
for c in /sys/fs/fuse/connections/*/waiting; do
  W=$(cat $c); [ "$W" -gt 0 ] && echo "HANGING: $c = $W"
done

# 2) Kernel-Stack des hängenden vzdump-Prozesses prüfen
cat /proc/<PID>/stack | head -15
# Erwartung: fuse_send_open / request_wait_answer / path_openat

# 3) FUSE-Connection aborten (entsperrt alle wartenden Requests)
echo 1 > /sys/fs/fuse/connections/<id>/abort

# 4) vzdump-PIDs nach dem Abort SIGKILL (sollten jetzt killbar sein)
pgrep -f 'vzdump.*<VMID>' | xargs -r kill -9

# 5) LXC-Config-Lock entfernen, falls stale
pct unlock <VMID>

# 6) CephFS neu mounten (wenn via ceph-fuse aborted wurde, ist der Mount tot)
pct exec <VMID> -- systemctl stop mnt-cephfs.mount
pct exec <VMID> -- pkill -9 -f 'ceph-fuse'
pct exec <VMID> -- systemctl start mnt-cephfs.mount

# 7) Container-Services neu starten (bei Docker: docker start <container>)
pct exec <VMID> -- docker start <container>
```

**Strukturelle Prävention**: ceph-fuse durch PVE-Cluster-Storage-bind-mount
ersetzen (siehe Phase 3.4 + 3.5). Nach der Migration existiert kein
FUSE-Endpoint mehr im LXC-Namespace, der vzdump-fsfreeze blockieren
könnte. Das ist die dauerhafte Lösung; obiger Recovery-Pfad ist nur
für Legacy-Setups oder ungewöhnliche Side-Effects (siehe Memory
`project_frigate_lxc_cephfs.md`).

---

## Recovery-Drill-Empfehlung

**Mindestens einmal pro Halbjahr** sollte ein partieller Drill laufen:

1. **Kleiner Drill (1h):** PBS-Restore einer einzelnen App-Database in eine
   temporäre Postgres-Instanz. Verifiziert Backup-Pipeline + Retention.
2. **Mittlerer Drill (4h):** Temporären PVE-Testhost + leeren Ceph-Cluster
   + Subset-Restore von CephFS-Content für einen Stack. Verifiziert
   Ceph-Recovery-Schritt + Keyring-Rollout.
3. **Full-Drill (1 Tag):** Komplettes Runbook gegen eine leere
   Infrastruktur. Nur nötig bei größeren Architektur-Änderungen.

Nach jedem Drill: Abweichungen gegenüber diesem Runbook als PR committen.
Das Runbook **muss** aktuell bleiben, sonst ist es zum Ernstfall wertlos.
