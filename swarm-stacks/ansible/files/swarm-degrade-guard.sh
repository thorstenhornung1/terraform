#!/bin/bash
# =============================================================================
# swarm-degrade-guard.sh — RAM-Headroom bei Node-Ausfall
# =============================================================================
# Bei Ausfall eines Swarm-Nodes nicht-kritische, RAM-hungrige Services auf 0
# skalieren -> Headroom fuer das HA-Failover der KRITISCHEN Gaeste (postgres-prod,
# Home Assistant vm:100, Frigate). Bei Node-Rueckkehr automatisch wieder hochfahren
# (Jobs werden nachgeholt: immich-ml + paperless-ai sind queue-basiert/unkritisch).
#
# - Leader-gated: nur der Swarm-Manager-Leader handelt (kein Mehrfach-Scale;
#   ueberlebt Leader-Wechsel, da Marker auf CephFS = shared liegt).
# - Idempotent + alle 60s per systemd-Timer (Deploy: swarm-degrade-guard.yml).
# - Marker speichert die VORHERIGE Replica-Zahl -> exakte Wiederherstellung,
#   kaempft nicht gegen manuelles Scaling (nur was WIR abgeworfen haben).
#
# Erweitern: weitere unkritische Services unten in SHED eintragen.
# =============================================================================
set -uo pipefail

# Nicht-kritische "shed-first"-Services (+ Default-Soll-Replicas als Fallback):
declare -A SHED=(
  [paperless-stack_paperless-ai]=1
  [immich_immich-machine-learning]=1
)
STATE_DIR=/mnt/cephfs/swarm-state
MARKER="$STATE_DIR/swarm-degrade.active"
log(){ logger -t swarm-degrade-guard -- "$*"; }

docker info >/dev/null 2>&1 || exit 0
# Nur der Manager-Leader handelt.
[ "$(docker node inspect self --format '{{ .ManagerStatus.Leader }}' 2>/dev/null)" = "true" ] || exit 0

# Anzahl nicht-Ready Nodes (Down/Unknown).
down=$(docker node ls --format '{{.Status}}' 2>/dev/null | grep -vc '^Ready$')

if [ "${down:-0}" -gt 0 ]; then
  # ---------- DEGRADE ----------
  [ -f "$MARKER" ] && exit 0          # bereits im Degrade-Zustand
  mkdir -p "$STATE_DIR" 2>/dev/null
  : > "$MARKER"
  log "Node-Ausfall erkannt ($down nicht-Ready) -> nicht-kritische Services abwerfen"
  for svc in "${!SHED[@]}"; do
    cur=$(docker service inspect "$svc" --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null) || continue
    echo "$svc ${cur:-${SHED[$svc]}}" >> "$MARKER"   # vorherige Replica-Zahl merken
    if [ "${cur:-0}" != "0" ]; then
      docker service scale "$svc"=0 >/dev/null 2>&1 && log "scaled $svc 0 (war ${cur})"
    fi
  done
else
  # ---------- RESTORE ----------
  [ -f "$MARKER" ] || exit 0          # nichts wiederherzustellen
  log "Alle Nodes Ready -> nicht-kritische Services wiederherstellen"
  while read -r svc rep; do
    [ -n "$svc" ] || continue
    docker service scale "$svc"="${rep:-1}" >/dev/null 2>&1 && log "restored $svc ${rep:-1}"
  done < "$MARKER"
  rm -f "$MARKER"
fi
