#!/bin/bash
# =============================================================================
# Kontrolliertes Herunterfahren des gesamten Proxmox-Clusters
# =============================================================================
# Ausgerollt von ansible/ups-shutdown.yml — NICHT auf dem Host editieren.
#
# WOFUER
#   Geplante Abschaltung: Umbau, Umzug, Wartung, Verkabelung. NICHT fuer den
#   Stromausfall — dafuer gibt es ups-staged-shutdown.sh, das gestaffelt und
#   nach Akkustand arbeitet. Dieses Skript faehrt alles herunter, sofort und
#   in der richtigen Reihenfolge.
#
# AUFRUF
#   /usr/local/sbin/pve-cluster-shutdown.sh --dry-run    # nur zeigen
#   /usr/local/sbin/pve-cluster-shutdown.sh --yes        # wirklich ausfuehren
#
#   Laeuft auf einem beliebigen Cluster-Node. Der Node, auf dem es laeuft,
#   faehrt sich selbst zuletzt herunter — er soll beim Wiederanlauf zuerst
#   hochkommen und per WoL die anderen wecken (wol-peer-nodes.service).
#
# ---------------------------------------------------------------------------
# WAS DER MANUELLE DURCHLAUF AM 2026-08-23 GELEHRT HAT
# ---------------------------------------------------------------------------
# 1. CEPH-ABFRAGEN NUR SOLANGE QUORUM BESTEHT.
#    Nach dem zweiten abgeschalteten Node hat Ceph kein MON-Quorum mehr (1 von
#    3). Jedes `ceph`-Kommando blockiert dann bis zum internen Timeout — im
#    Durchlauf hat das fuenf Minuten gekostet und den nachfolgenden
#    Shutdown-Befehl gar nicht erst zum Zug kommen lassen. Deshalb: alle
#    Ceph-Operationen VOR dem ersten Node-Shutdown, danach nie wieder.
#
# 2. HA-GAESTE NUR UEBER ha-manager STOPPEN.
#    `qm stop` / `pct stop` genuegt nicht — der HA-Stack startet den Gast
#    sofort neu. Richtig ist `ha-manager set <sid> --state stopped`.
#
# 3. DIE REIHENFOLGE DER HA-GAESTE IST NICHT BELIEBIG.
#    Home Assistant fuehrt seine Recorder-Datenbank auf postgres-prod. Geht
#    Postgres zuerst, schreibt HA in eine wegbrechende Verbindung. Also:
#    Frigate (unabhaengig) -> Home Assistant -> postgres-prod.
#
# 4. SWARM-VMS VOR DEN HYPERVISOREN.
#    Ihre CephFS-Mounts sind Hard-Mounts. Verschwindet Ceph zuerst, haengen
#    die Container im D-State und lassen sich nicht mehr sauber beenden.
#
# 5. DNS ZULETZT UNTER DEN GAESTEN.
#    dns1/2/3 laufen als LXC auf den Nodes. Solange noch etwas herunterfaehrt,
#    kann es Namensaufloesung brauchen.
#
# 6. `shutdown` UEBER SSH BRAUCHT nohup UND &.
#    Sonst kappt der beendende sshd die Verbindung, bevor das Kommando greift.
#    Hier irrelevant (wir nutzen die API), aber der Grund, warum der manuelle
#    Durchlauf `nohup shutdown -h now &` verwendete.
#
# ---------------------------------------------------------------------------
# NACH DEM WIEDERANLAUF NICHT VERGESSEN
#   ceph osd unset noout && ceph osd unset norebalance && ceph osd unset nobackfill
#   Das Skript hinterlaesst eine Erinnerung in /root/CEPH-FLAGS-GESETZT.txt
# =============================================================================

set -uo pipefail

CONFIG=/etc/default/ups-staged-shutdown
# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"

# Reihenfolge ist Absicht — siehe Lektion 3.
# Das Word-Splitting hier ist gewollt: aus dem Konfigurationsstring wird ein
# Array. Deshalb bewusst ohne Anfuehrungszeichen.
# shellcheck disable=SC2206
HA_GUESTS_ORDERED=(${PVE_SHUTDOWN_HA_ORDER:-"ct:4502 vm:100 vm:4600"})
# shellcheck disable=SC2206
SWARM_VMS=(${PVE_SHUTDOWN_SWARM_VMS:-"4202 4201 4200"})
# shellcheck disable=SC2206
DNS_GUESTS=(${PVE_SHUTDOWN_DNS_GUESTS:-"4100 4101 4102"})

GUEST_TIMEOUT=${PVE_SHUTDOWN_GUEST_TIMEOUT:-120}
SELF="$(hostname -s)"
DRYRUN=1
FLAG_FILE=/root/CEPH-FLAGS-GESETZT.txt

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; logger -t pve-cluster-shutdown -- "$*"; }
run() { if [ "$DRYRUN" = "1" ]; then log "[dry] $*"; else "$@"; fi; }

case "${1:-}" in
  --yes)     DRYRUN=0 ;;
  --dry-run) DRYRUN=1 ;;
  *) echo "Aufruf: $0 --dry-run | --yes"; exit 2 ;;
esac
[ "$DRYRUN" = "1" ] && log "TROCKENLAUF — es wird nichts abgeschaltet."

# --- Hilfsfunktionen ---------------------------------------------------------
guest_node()   { pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
                   | grep -oE "\{[^}]*\"vmid\":$1[,}][^}]*\}" | grep -oE '"node":"[^"]*"' | cut -d'"' -f4 | head -1; }
guest_status() { pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
                   | grep -oE "\{[^}]*\"vmid\":$1[,}][^}]*\}" | grep -oE '"status":"[^"]*"' | cut -d'"' -f4 | head -1; }
guest_type()   { pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
                   | grep -oE "\{[^}]*\"vmid\":$1[,}][^}]*\}" | grep -oE '"type":"[^"]*"' | cut -d'"' -f4 | head -1; }

# Ueber die API statt per SSH: funktioniert clusterweit, ohne Schluesselverteilung
shutdown_guest() {
  local id="$1" node type
  node="$(guest_node "$id")"; type="$(guest_type "$id")"
  [ -z "$node" ] && { log "  Gast $id nicht gefunden — uebersprungen"; return 0; }
  [ "$(guest_status "$id")" != "running" ] && { log "  Gast $id laeuft nicht — uebersprungen"; return 0; }
  log "  fahre $type $id auf $node herunter"
  run pvesh create "/nodes/$node/$type/$id/status/shutdown" --timeout "$GUEST_TIMEOUT" --forceStop 1
}

wait_guests_down() {
  local ids=("$@") left i
  [ "$DRYRUN" = "1" ] && return 0
  for i in $(seq 1 60); do
    left=0
    for id in "${ids[@]}"; do
      [ "$(guest_status "$id")" = "running" ] && left=$((left + 1))
    done
    [ "$left" -eq 0 ] && { log "  alle gestoppt (nach ${i}0 s)"; return 0; }
    sleep 10
  done
  log "  WARNUNG: nach 10 min laufen noch $left Gaeste — trotzdem weiter"
}

# --- Vorbedingungen ----------------------------------------------------------
log "=== Vorbedingungen ==="
if ! pvecm status 2>/dev/null | grep -q "Quorate:.*Yes"; then
  log "FEHLER: Cluster hat kein Quorum. Abbruch — in diesem Zustand ist ein"
  log "        geordnetes Herunterfahren nicht moeglich."
  exit 1
fi
log "  Cluster-Quorum: ok"

NODES="$(pvecm nodes 2>/dev/null | awk '/^ +[0-9]+/{print $3}' | tr -d '()' | sort)"
log "  Nodes: $(echo "$NODES" | tr '\n' ' ')"

# --- Ceph in Wartung — MUSS vor dem ersten Node-Shutdown passieren (Lektion 1)
if command -v ceph >/dev/null 2>&1; then
  log "=== Ceph in Wartungsmodus ==="
  log "  (nach dem zweiten Node-Shutdown ist Ceph nicht mehr auskunftsfaehig —"
  log "   deshalb geschieht hier alles, was Ceph betrifft)"
  for f in noout norebalance nobackfill; do
    run ceph osd set "$f"
  done
  if [ "$DRYRUN" = "0" ]; then
    cat > "$FLAG_FILE" << EOF
Ceph-Wartungsflags wurden am $(date '+%Y-%m-%d %H:%M:%S') gesetzt
von pve-cluster-shutdown.sh auf $SELF.

NACH DEM WIEDERANLAUF ENTFERNEN:
  ceph osd unset noout
  ceph osd unset norebalance
  ceph osd unset nobackfill

Bleiben sie gesetzt, repariert Ceph sich bei kuenftigen Ausfaellen nicht
selbst — es wuerde degraded bleiben, ohne dass es auffaellt.
EOF
    log "  Erinnerung hinterlegt: $FLAG_FILE"
  fi
fi

# --- Gaeste in Abhaengigkeitsreihenfolge ------------------------------------
log "=== HA-verwaltete Gaeste (Reihenfolge: Frigate -> HA -> Postgres) ==="
HA_IDS=()
for sid in "${HA_GUESTS_ORDERED[@]}"; do
  id="${sid#*:}"
  if ha-manager status 2>/dev/null | grep -qE "^service ${sid} "; then
    log "  stoppe $sid ueber ha-manager (nicht qm/pct — sonst startet HA neu)"
    run ha-manager set "$sid" --state stopped
    HA_IDS+=("$id")
    sleep 3
  else
    log "  $sid ist nicht HA-verwaltet — wird spaeter als normaler Gast behandelt"
  fi
done
[ ${#HA_IDS[@]} -gt 0 ] && wait_guests_down "${HA_IDS[@]}"

log "=== Swarm-VMs (vor den Hypervisoren — CephFS sind Hard-Mounts) ==="
for id in "${SWARM_VMS[@]}"; do shutdown_guest "$id"; done
wait_guests_down "${SWARM_VMS[@]}"

log "=== Uebrige Gaeste, ausser DNS ==="
OTHERS=()
while read -r id; do
  [ -z "$id" ] && continue
  skip=0
  for d in "${DNS_GUESTS[@]}" "${SWARM_VMS[@]}"; do [ "$id" = "$d" ] && skip=1; done
  for sid in "${HA_GUESTS_ORDERED[@]}"; do [ "$id" = "${sid#*:}" ] && skip=1; done
  [ "$skip" = "1" ] && continue
  OTHERS+=("$id")
done < <(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
         | grep -oE '"vmid":[0-9]+' | cut -d: -f2 | sort -u)
for id in "${OTHERS[@]}"; do shutdown_guest "$id"; done
[ ${#OTHERS[@]} -gt 0 ] && wait_guests_down "${OTHERS[@]}"

log "=== DNS zuletzt ==="
for id in "${DNS_GUESTS[@]}"; do shutdown_guest "$id"; done
wait_guests_down "${DNS_GUESTS[@]}"

# --- Nodes -------------------------------------------------------------------
# Ab hier keine Ceph- oder Cluster-Abfragen mehr (Lektion 1).
log "=== Nodes herunterfahren ==="
for node in $NODES; do
  [ "$node" = "$SELF" ] && continue
  log "  $node"
  run ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$node" \
      "nohup shutdown -h now 'pve-cluster-shutdown' >/dev/null 2>&1 &"
done

if [ "$DRYRUN" = "0" ]; then
  log "  warte, bis die anderen Nodes weg sind"
  for i in $(seq 1 36); do
    up=0
    for node in $NODES; do
      [ "$node" = "$SELF" ] && continue
      ping -c 1 -W 2 "$node" >/dev/null 2>&1 && up=$((up + 1))
    done
    [ "$up" -eq 0 ] && { log "  alle anderen sind aus"; break; }
    sleep 5
  done
fi

log "=== $SELF faehrt als letzter herunter ==="
log "    Wiederanlauf: diesen Node einschalten, er weckt die anderen per WoL"
log "    Danach nicht vergessen: ceph osd unset noout/norebalance/nobackfill"
run shutdown -h now "pve-cluster-shutdown: letzter Node"
