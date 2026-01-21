# Docker Swarm Cluster Architektur

## Übersicht

Dieses Dokument beschreibt die Docker Swarm Cluster-Architektur, die Trennung zwischen Terraform und Ansible/manueller Konfiguration sowie die operativen Abläufe.

```
                        Docker Swarm Cluster
    ┌─────────────────────────────────────────────────────────┐
    │                                                         │
    │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
    │   │docker-app-1 │  │docker-app-2 │  │docker-app-3 │    │
    │   │192.168.4.30 │  │192.168.4.31 │  │192.168.4.32 │    │
    │   │   MANAGER   │  │   MANAGER   │  │   MANAGER   │    │
    │   │   (Leader)  │  │ (Reachable) │  │ (Reachable) │    │
    │   │    pve01    │  │    pve02    │  │    pve03    │    │
    │   └─────────────┘  └─────────────┘  └─────────────┘    │
    │                                                         │
    │   ┌─────────────┐                   ┌─────────────┐    │
    │   │docker-infra-1│                  │docker-infra-3│   │
    │   │192.168.4.40 │                   │192.168.4.42 │    │
    │   │   WORKER    │                   │   WORKER    │    │
    │   │    pve01    │                   │    pve03    │    │
    │   └─────────────┘                   └─────────────┘    │
    │                                                         │
    └─────────────────────────────────────────────────────────┘
```

## Node-Konfiguration

| Hostname       | IP (VLAN 4)   | IP (VLAN 12)   | Rolle    | Proxmox | VM-ID |
|----------------|---------------|----------------|----------|---------|-------|
| docker-app-1   | 192.168.4.30  | 192.168.12.30  | Manager  | pve01   | 4100  |
| docker-app-2   | 192.168.4.31  | 192.168.12.31  | Manager  | pve02   | 4101  |
| docker-app-3   | 192.168.4.32  | 192.168.12.32  | Manager  | pve03   | 4102  |
| docker-infra-1 | 192.168.4.40  | 192.168.12.40  | Worker   | pve01   | 4200  |
| docker-infra-3 | 192.168.4.42  | 192.168.12.42  | Worker   | pve03   | 4202  |

### Ressourcen

- **App Nodes:** 4 vCPU, 8 GB RAM, 50 GB Disk
- **Infra Nodes:** 4 vCPU, 8 GB RAM, 30 GB Boot + 50-200 GB Data Disk

---

## Terraform vs. Ansible/Manuelle Konfiguration

### Verantwortlichkeiten im Überblick

```
┌────────────────────────────────────────────────────────────────────────┐
│                         TERRAFORM                                       │
│  (Infrastructure as Code - Deklarativ)                                 │
├────────────────────────────────────────────────────────────────────────┤
│  ✅ VM-Erstellung auf Proxmox                                          │
│  ✅ CPU, RAM, Disk-Zuweisung                                           │
│  ✅ Netzwerk-Konfiguration (VLANs, IPs)                                │
│  ✅ Cloud-Init Template-Bereitstellung                                 │
│  ✅ Docker CE Installation (via Cloud-Init)                            │
│  ✅ LDAP/SSSD-Konfiguration (via Cloud-Init)                           │
│  ✅ Docker daemon.json Konfiguration                                   │
│  ✅ Ansible-User mit SSH-Key                                           │
└────────────────────────────────────────────────────────────────────────┘
                                  │
                                  │ GRENZE
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    ANSIBLE / MANUELL                                    │
│  (Konfiguration - Imperativ / State-abhängig)                          │
├────────────────────────────────────────────────────────────────────────┤
│  ✅ Swarm Cluster initialisieren                                       │
│  ✅ Manager-/Worker-Tokens generieren                                  │
│  ✅ Nodes zum Cluster hinzufügen                                       │
│  ✅ Swarm Services deployen                                            │
│  ✅ Overlay Networks erstellen                                         │
│  ✅ Secrets und Configs verwalten                                      │
│  ✅ Stack Deployments (docker-compose.yml)                             │
└────────────────────────────────────────────────────────────────────────┘
```

### Warum diese Trennung?

#### Terraform-Grenzen

1. **Keine State-Awareness für Swarm:**
   Terraform kann nicht wissen, ob ein Swarm bereits initialisiert ist oder welcher Node der Leader ist.

2. **Token-Dynamik:**
   Swarm Join-Tokens werden dynamisch generiert und ändern sich bei Rotation. Terraform ist für statische Infrastruktur konzipiert.

3. **Reihenfolge-Abhängigkeiten:**
   - Erst muss ein Manager initialisiert werden
   - Dann werden Tokens generiert
   - Erst dann können weitere Nodes joinen

   Diese sequentielle, state-abhängige Logik passt besser zu Ansible.

4. **Idempotenz-Problem:**
   `docker swarm init` ist nicht idempotent - es schlägt fehl, wenn bereits ein Swarm existiert.

#### Was Terraform gut kann

- **Deklarative Infrastruktur:** "Ich will 5 VMs mit diesen Specs"
- **Parallele Erstellung:** Alle VMs gleichzeitig provisionieren
- **State Management:** Wissen welche Ressourcen existieren
- **Lifecycle Management:** VMs erstellen, ändern, löschen

#### Was Ansible/Manuell besser kann

- **Sequentielle Operationen:** Erst A, dann B, dann C
- **Bedingte Logik:** "Nur wenn Swarm nicht existiert, initialisieren"
- **State-Abfragen:** "Welcher Node ist Leader?"
- **Dynamische Werte:** Token auslesen und weiterverwenden

---

## Deployment-Workflow

### Phase 1: Terraform - Infrastruktur erstellen

```bash
cd /Users/thorstenhornung/tmp/terraform

# VMs erstellen (mit reduzierter Parallelität wegen Proxmox API)
terraform apply -parallelism=2
```

**Ergebnis nach terraform apply:**
- 5 VMs laufen auf Proxmox
- Docker ist installiert und gestartet
- Ansible-User kann sich per SSH verbinden
- Swarm ist NICHT konfiguriert (nur standalone Docker)

### Phase 2: Swarm initialisieren (Manuell/Ansible)

#### 2.1 Ersten Manager initialisieren

```bash
ssh ansible@192.168.4.30 "sudo docker swarm init --advertise-addr 192.168.4.30"
```

#### 2.2 Manager-Token holen

```bash
MANAGER_TOKEN=$(ssh ansible@192.168.4.30 "sudo docker swarm join-token manager -q")
echo $MANAGER_TOKEN
```

#### 2.3 Weitere Manager hinzufügen

```bash
ssh ansible@192.168.4.31 "sudo docker swarm join --token $MANAGER_TOKEN 192.168.4.30:2377"
ssh ansible@192.168.4.32 "sudo docker swarm join --token $MANAGER_TOKEN 192.168.4.30:2377"
```

#### 2.4 Worker-Token holen

```bash
WORKER_TOKEN=$(ssh ansible@192.168.4.30 "sudo docker swarm join-token worker -q")
echo $WORKER_TOKEN
```

#### 2.5 Worker hinzufügen

```bash
ssh ansible@192.168.4.40 "sudo docker swarm join --token $WORKER_TOKEN 192.168.4.30:2377"
ssh ansible@192.168.4.42 "sudo docker swarm join --token $WORKER_TOKEN 192.168.4.30:2377"
```

### Phase 3: Verifizierung

```bash
ssh ansible@192.168.4.30 "sudo docker node ls"
```

**Erwartete Ausgabe:**
```
ID             HOSTNAME         STATUS    AVAILABILITY   MANAGER STATUS
xxx *          docker-app-1     Ready     Active         Leader
xxx            docker-app-2     Ready     Active         Reachable
xxx            docker-app-3     Ready     Active         Reachable
xxx            docker-infra-1   Ready     Active
xxx            docker-infra-3   Ready     Active
```

---

## Docker Daemon Konfiguration

### daemon.json

Datei: `terraform/docker-swarm/cloud-init-docker.yml`

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "default-address-pools": [
    {"base": "172.20.0.0/16", "size": 24}
  ]
}
```

### Wichtig: live-restore ist DEAKTIVIERT

**`live-restore: true` wurde entfernt**, weil es mit Docker Swarm Mode inkompatibel ist.

#### Warum?

- `live-restore` hält Container am Leben, wenn der Docker Daemon neu startet
- Im Swarm Mode übernimmt der Swarm Orchestrator diese Aufgabe
- Beide Mechanismen gleichzeitig führen zu Konflikten:
  - Nodes können dem Swarm nicht beitreten
  - Container-Zustand wird inkonsistent
  - Failover funktioniert nicht korrekt

#### Swarm-Alternative

Docker Swarm bietet eigene Hochverfügbarkeits-Mechanismen:
- **Service Replicas:** Automatische Neuverteilung bei Node-Ausfall
- **Rolling Updates:** Unterbrechungsfreie Updates
- **Health Checks:** Automatischer Neustart fehlerhafter Container

---

## Netzwerk-Architektur

### VLANs

| VLAN | Netz           | Zweck                              |
|------|----------------|------------------------------------|
| 4    | 192.168.4.0/24 | Cluster-Management, Anwendungen    |
| 12   | 192.168.12.0/24| Storage-Netzwerk (SeaweedFS, etc.) |

### Swarm Ports

| Port  | Protokoll | Zweck                          |
|-------|-----------|--------------------------------|
| 2377  | TCP       | Cluster Management             |
| 7946  | TCP/UDP   | Node-zu-Node Kommunikation     |
| 4789  | UDP       | Overlay Network Traffic (VXLAN)|

---

## Operative Befehle

### Cluster-Status

```bash
# Node-Liste
ssh ansible@192.168.4.30 "sudo docker node ls"

# Detaillierte Node-Info
ssh ansible@192.168.4.30 "sudo docker node inspect docker-app-1 --pretty"

# Service-Liste
ssh ansible@192.168.4.30 "sudo docker service ls"
```

### Node-Management

```bash
# Node für Wartung vorbereiten (drain)
ssh ansible@192.168.4.30 "sudo docker node update --availability drain docker-infra-1"

# Node wieder aktivieren
ssh ansible@192.168.4.30 "sudo docker node update --availability active docker-infra-1"

# Worker zu Manager befördern
ssh ansible@192.168.4.30 "sudo docker node promote docker-infra-1"

# Manager zu Worker degradieren
ssh ansible@192.168.4.30 "sudo docker node demote docker-app-3"
```

### Token-Management

```bash
# Tokens anzeigen
ssh ansible@192.168.4.30 "sudo docker swarm join-token manager"
ssh ansible@192.168.4.30 "sudo docker swarm join-token worker"

# Tokens rotieren (Sicherheit)
ssh ansible@192.168.4.30 "sudo docker swarm join-token --rotate manager"
ssh ansible@192.168.4.30 "sudo docker swarm join-token --rotate worker"
```

### Node entfernen

```bash
# Auf dem zu entfernenden Node:
ssh ansible@192.168.4.40 "sudo docker swarm leave"

# Auf einem Manager (Node aus Liste entfernen):
ssh ansible@192.168.4.30 "sudo docker node rm docker-infra-1"
```

---

## Troubleshooting

### Problem: Node kann nicht joinen

**Symptom:**
```
Error response from daemon: rpc error: code = Unavailable
```

**Lösung:**
1. Firewall-Ports prüfen (2377, 7946, 4789)
2. Netzwerk-Konnektivität testen: `ping 192.168.4.30`
3. Docker-Dienst neustarten: `sudo systemctl restart docker`

### Problem: "This node is already part of a swarm"

**Lösung:**
```bash
# Swarm verlassen und neu joinen
sudo docker swarm leave --force
sudo docker swarm join --token <TOKEN> 192.168.4.30:2377
```

### Problem: Leader nicht erreichbar

**Symptom:** Cluster-Befehle schlagen fehl

**Lösung:**
```bash
# Auf einem erreichbaren Manager:
sudo docker node ls  # Prüfen welche Nodes "Down" sind

# Wenn Leader down ist, wählt Swarm automatisch neuen Leader
# Bei Quorum-Verlust (weniger als 2 von 3 Managern):
sudo docker swarm init --force-new-cluster  # NUR als letzter Ausweg!
```

### Problem: live-restore Konflikt

**Symptom:**
```
Error response from daemon: manager stopped: can't initialize raft node
```

**Lösung:**
```bash
# live-restore aus daemon.json entfernen
sudo sed -i '/live-restore/d' /etc/docker/daemon.json
sudo systemctl restart docker
```

---

## Dateien und Referenzen

| Datei | Beschreibung |
|-------|--------------|
| `main.tf` | Terraform VM-Definitionen |
| `variables.tf` | Cluster-Variablen (IPs, Ressourcen) |
| `terraform/docker-swarm/cloud-init-docker.yml` | Cloud-Init Template |
| `outputs.tf` | Terraform Outputs (IPs, Hostnames) |

---

## Änderungshistorie

| Datum      | Änderung                                    |
|------------|---------------------------------------------|
| 2025-01-21 | `live-restore: true` entfernt (Swarm-Fix)   |
| 2025-01-21 | Initiale Dokumentation erstellt             |
