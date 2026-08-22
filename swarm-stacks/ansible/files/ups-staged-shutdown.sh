#!/bin/bash
# =============================================================================
# Gestaffeltes Herunterfahren der Proxmox-Nodes bei Stromausfall
# =============================================================================
# Ausgerollt von ansible/ups-shutdown.yml — NICHT auf dem Host editieren.
# Die Werte stehen in /etc/default/ups-staged-shutdown, nicht hier.
#
# WAS ES TUT
#   Laeuft alle 30 s per systemd-Timer, liest den USV-Zustand vom NUT-Server
#   auf der Synology und faehrt den eigenen Node zum richtigen Zeitpunkt
#   herunter — spaet genug, dass ein kurzer Netzwischer nichts ausloest, und
#   frueh genug, dass vor der Synology Schluss ist.
#
# WARUM NICHT NUR upsmon
#   NUT kennt von Haus aus nur ONBATT, LOWBATT und ONLINE. Eine prozentgenaue
#   Staffelung gibt es damit nicht. upsmon bleibt als Sicherheitsnetz aktiv
#   (LOWBATT -> FSD), dieses Skript macht die Abstufung darueber.
#
# DIE REIHENFOLGE FOLGT DEN GAESTEN, NICHT DEM HOSTNAMEN
#   Der Cluster faehrt ha-auto-rebalance=1 — Proxmox verschiebt HA-Gaeste
#   selbstaendig. Eine feste Zuordnung "pve02 stirbt zuletzt" waere im Ernstfall
#   womoeglich falsch. Stattdessen zaehlt jeder Node, wie viele kritische Gaeste
#   bei ihm liegen, und leitet daraus seinen Rang ab. Weil /etc/pve clusterweit
#   synchron ist und alle dieselbe Sortierregel verwenden, kommen alle Nodes
#   unabhaengig zum selben Ergebnis — ohne Koordinator.
#
# DEADLINE
#   Die Synology faehrt bei battery.charge <= 20 % herunter und nimmt den
#   NUT-Server mit. Ab da sind die Nodes blind. Die letzte Stufe liegt deshalb
#   bei 30 %, nicht tiefer.
#
# TESTEN
#   UPS_SHUTDOWN_DRYRUN=1 /usr/local/sbin/ups-staged-shutdown.sh
#   /usr/local/sbin/ups-staged-shutdown.sh --print-rank
# =============================================================================

set -uo pipefail

# Konfiguration — ausgerollt von ansible/ups-shutdown.yml
CONFIG=/etc/default/ups-staged-shutdown
[ -r "$CONFIG" ] || { echo "FEHLER: $CONFIG fehlt"; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"

UPS="${UPS_NAME:?}@${UPS_SERVER:?}"
GRACE_SECONDS=${UPS_GRACE_SECONDS:-120}
THRESHOLDS=(${UPS_STAGE_THRESHOLDS:-60 45 30})
CRITICAL_GUESTS=(${UPS_CRITICAL_GUESTS:-})
BALLAST_GUESTS=(${UPS_BALLAST_GUESTS:-})

STATE_DIR=/run/ups-staged-shutdown
GRACE_MARK="$STATE_DIR/onbatt-since"
RANK_MARK="$STATE_DIR/rank"
BALLAST_MARK="$STATE_DIR/ballast-dropped"
LOCK="$STATE_DIR/lock"

DRYRUN="${UPS_SHUTDOWN_DRYRUN:-0}"
SELF="$(hostname -s)"

log() { logger -t ups-staged-shutdown -- "$*"; echo "[ups-staged-shutdown] $*"; }
run() {
  if [ "$DRYRUN" = "1" ]; then log "[dry] wuerde ausfuehren: $*"; return 0; fi
  "$@"
}

mkdir -p "$STATE_DIR"

# --- USV lesen ---------------------------------------------------------------
ups_get() { timeout 10 upsc "$UPS" "$1" 2>/dev/null | tr -d '\r'; }

STATUS="$(ups_get ups.status)"
CHARGE="$(ups_get battery.charge)"

if [ -z "$STATUS" ]; then
  log "FEHLER: USV $UPS nicht erreichbar (Switch weg? Synology aus?) — keine Aktion."
  exit 1
fi
[[ "$CHARGE" =~ ^[0-9]+$ ]] || CHARGE=100

# --- Rangbestimmung ----------------------------------------------------------
# Kritikalitaet = Anzahl kritischer Gaeste auf diesem Node.
# Sortiert aufsteigend; bei Gleichstand nach Hostname (MUSS deterministisch
# sein, sonst schalten sich zwei Nodes gleichzeitig ab und reissen Ceph unter
# min_size). Ausgabe: "<node> <kritikalitaet>" je Zeile, in Abschaltreihenfolge.
compute_ranking() {
  local ha_status node sid
  ha_status="$(ha-manager status 2>/dev/null)"
  for node in $(pvecm nodes 2>/dev/null | awk '/^ +[0-9]+/{print $3}' | tr -d '()' | sort); do
    local count=0
    for sid in "${CRITICAL_GUESTS[@]}"; do
      if grep -qE "^service ${sid} \(${node}," <<<"$ha_status"; then
        count=$((count + 1))
      fi
    done
    printf '%s %s\n' "$count" "$node"
  done | sort -k1,1n -k2,2 | awk '{print $2" "$1}'
}

my_rank_index() {
  local i=0 node
  while read -r node _; do
    [ "$node" = "$SELF" ] && { echo "$i"; return 0; }
    i=$((i + 1))
  done < <(compute_ranking)
  echo "-1"
}

if [ "${1:-}" = "--print-rank" ]; then
  echo "Abschaltreihenfolge (zuerst -> zuletzt), Kritikalitaet = kritische Gaeste:"
  compute_ranking | awk '{printf "  %d. %-8s kritische Gaeste: %s\n", NR, $1, $2}'
  idx="$(my_rank_index)"
  if [ "$idx" -ge 0 ] 2>/dev/null && [ "$idx" -lt "${#THRESHOLDS[@]}" ]; then
    echo "Dieser Node ($SELF): Rang $((idx + 1)), Schwelle ${THRESHOLDS[$idx]} %"
  else
    echo "Dieser Node ($SELF): kein Rang ermittelbar (Cluster unvollstaendig?)"
  fi
  exit 0
fi

# --- Nur eine Instanz --------------------------------------------------------
exec 9>"$LOCK"
flock -n 9 || { log "Ein Lauf ist bereits aktiv — uebersprungen."; exit 0; }

# --- Netz ist da: alles zuruecksetzen ---------------------------------------
if [[ "$STATUS" == *OL* ]]; then
  if [ -f "$GRACE_MARK" ] || [ -f "$BALLAST_MARK" ]; then
    log "Netz zurueck (Status: $STATUS, Akku ${CHARGE} %) — Zustand wird zurueckgesetzt."
    # Ballast wieder hochfahren. Ohne das bliebe der Cluster nach einem
    # ueberstandenen Ausfall dauerhaft halb abgeschaltet — und es faellt
    # niemandem auf, weil nichts kaputt aussieht.
    if [ -f "$BALLAST_MARK" ]; then
      for sid in "${BALLAST_GUESTS[@]}"; do
        [[ "$sid" == *:* ]] || continue
        local_id="${sid#*:}"
        case "$sid" in
          ct:*) pct status "$local_id" >/dev/null 2>&1 && run pct start "$local_id" ;;
          vm:*) qm  status "$local_id" >/dev/null 2>&1 && run qm  start "$local_id" ;;
        esac
      done
      run pvesh set /cluster/options --crs "ha-auto-rebalance=1,ha-rebalance-on-start=1,ha=dynamic"
      log "Ballast wieder gestartet, CRS-Rebalancing reaktiviert."
    fi
    [ "$DRYRUN" = "1" ] || rm -f "$GRACE_MARK" "$RANK_MARK" "$BALLAST_MARK"
  fi
  exit 0
fi

# --- Batteriebetrieb ---------------------------------------------------------
if [[ "$STATUS" != *OB* ]]; then
  log "Unerwarteter USV-Status '$STATUS' (Akku ${CHARGE} %) — keine Aktion."
  exit 0
fi

NOW="$(date +%s)"
if [ ! -f "$GRACE_MARK" ]; then
  echo "$NOW" > "$GRACE_MARK"
  log "Netzausfall erkannt (Akku ${CHARGE} %). Karenz laeuft ${GRACE_SECONDS} s."
  exit 0
fi

ELAPSED=$(( NOW - $(cat "$GRACE_MARK" 2>/dev/null || echo "$NOW") ))
if [ "$ELAPSED" -lt "$GRACE_SECONDS" ]; then
  log "Batteriebetrieb seit ${ELAPSED} s, Karenz ${GRACE_SECONDS} s — noch abwarten."
  exit 0
fi

# --- Stufe 1: Ballast abwerfen, Rang einfrieren ------------------------------
if [ ! -f "$BALLAST_MARK" ]; then
  log "Karenz vorbei (${ELAPSED} s, Akku ${CHARGE} %) — Stufe 1: Ballast abwerfen."

  # CRS anhalten, sonst schiebt Proxmox waehrend der Abschaltkette Gaeste auf
  # einen Node, der gleich abgeschaltet wird.
  run pvesh set /cluster/options --crs "ha-auto-rebalance=0,ha-rebalance-on-start=0,ha=dynamic"

  compute_ranking > "$RANK_MARK.tmp" 2>/dev/null && mv "$RANK_MARK.tmp" "$RANK_MARK"
  log "Rangfolge eingefroren: $(awk '{printf "%s(%s) ", $1, $2}' "$RANK_MARK" 2>/dev/null)"

  for sid in "${BALLAST_GUESTS[@]}"; do
    [[ "$sid" == *:* ]] || continue
    id="${sid#*:}"
    case "$sid" in
      ct:*) if pct status "$id" 2>/dev/null | grep -q running; then run pct shutdown "$id" --forceStop 1 --timeout 60; log "Ballast gestoppt: $sid"; fi ;;
      vm:*) if qm  status "$id" 2>/dev/null | grep -q running; then run qm  shutdown "$id" --forceStop 1 --timeout 60; log "Ballast gestoppt: $sid"; fi ;;
    esac
  done

  [ "$DRYRUN" = "1" ] || touch "$BALLAST_MARK"
  exit 0
fi

# --- Stufen 2-4: eigene Schwelle pruefen -------------------------------------
IDX=-1
if [ -f "$RANK_MARK" ]; then
  i=0
  while read -r node _; do
    [ "$node" = "$SELF" ] && { IDX="$i"; break; }
    i=$((i + 1))
  done < "$RANK_MARK"
fi

if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "${#THRESHOLDS[@]}" ]; then
  log "WARNUNG: kein gueltiger Rang fuer $SELF — upsmon/LOWBATT bleibt als Netz."
  exit 0
fi

MY_THRESHOLD="${THRESHOLDS[$IDX]}"
if [ "$CHARGE" -gt "$MY_THRESHOLD" ]; then
  log "Akku ${CHARGE} % > eigene Schwelle ${MY_THRESHOLD} % (Rang $((IDX + 1))) — warten."
  exit 0
fi

log "Akku ${CHARGE} % <= Schwelle ${MY_THRESHOLD} % (Rang $((IDX + 1))) — dieser Node faehrt herunter."

# Kritische Gaeste hier zuerst geordnet stoppen. Bei HA-verwalteten Gaesten
# NICHT qm/pct stop verwenden — der HA-Stack startet sie sonst sofort neu.
HA_STATUS="$(ha-manager status 2>/dev/null)"
for sid in "${CRITICAL_GUESTS[@]}"; do
  if grep -qE "^service ${sid} \(${SELF}," <<<"$HA_STATUS"; then
    log "Stoppe HA-Gast $sid auf $SELF"
    run ha-manager set "$sid" --state stopped
  fi
done

# Kurz Zeit zum sauberen Beenden geben, bevor der Node ausgeht.
[ "$DRYRUN" = "1" ] || sleep 45

log "Shutdown von $SELF."
run /sbin/shutdown -h now "USV: Akku ${CHARGE} %, Schwelle ${MY_THRESHOLD} % erreicht"
