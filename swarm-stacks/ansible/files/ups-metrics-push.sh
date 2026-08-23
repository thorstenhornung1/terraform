#!/bin/bash
# =============================================================================
# USV-Metriken nach VictoriaMetrics schieben
# =============================================================================
# Ausgerollt von ansible/ups-shutdown.yml — NICHT auf dem Host editieren.
# Die Werte stehen in /etc/default/ups-staged-shutdown.
#
# WARUM PUSH STATT EINES EXPORTERS IM SWARM
#   Die Synology gibt den NUT-Server nur fuer die freigegebenen Proxmox-IPs
#   frei; von den Swarm-Nodes kommt "ERR ACCESS-DENIED". Ein nut_exporter als
#   Swarm-Service haette also erst eine weitere DSM-Freigabe gebraucht. Die
#   Hypervisoren duerfen ohnehin zugreifen und erreichen VictoriaMetrics — also
#   lesen sie selbst und schieben die Werte per Prometheus-Import-Endpunkt.
#   Kein zusaetzlicher Container, keine neue Freigabe.
#
# ALLE DREI NODES SCHIEBEN DIESELBEN USV-WERTE
#   Das ist Absicht und kein Versehen: Die Zeitreihen tragen kein Node-Label,
#   ueberschreiben sich also gegenseitig mit demselben Wert. Faellt ein Node
#   aus, liefern die anderen weiter. Wer gerade liefert, steht in
#   ups_reporter_up{node="..."} — daran sieht man, welcher Node den NUT-Server
#   nicht mehr erreicht, ohne die eigentlichen Messwerte zu verdoppeln.
# =============================================================================

set -uo pipefail

CONFIG=/etc/default/ups-staged-shutdown
[ -r "$CONFIG" ] || { echo "FEHLER: $CONFIG fehlt"; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"

UPS="${UPS_NAME:?}@${UPS_SERVER:?}"
VM_URL="${UPS_METRICS_URL:-http://192.168.4.40:8428/api/v1/import/prometheus}"
NODE="$(hostname -s)"

ups_get() { timeout 8 upsc "$UPS" "$1" 2>/dev/null | tr -d '\r'; }

STATUS="$(ups_get ups.status)"

# --- USV nicht erreichbar: nur das melden, keine Altwerte erfinden -----------
if [ -z "$STATUS" ]; then
  printf 'ups_reporter_up{node="%s"} 0\n' "$NODE" \
    | curl -s --max-time 10 -X POST --data-binary @- "$VM_URL" >/dev/null 2>&1
  # exit 0, nicht 1: Dass die USV gerade nicht antwortet, meldet die Metrik
  # ups_reporter_up=0 — dafuer muss der Dienst nicht auch noch "failed" sein.
  exit 0
fi

CHARGE="$(ups_get battery.charge)"
RUNTIME="$(ups_get battery.runtime)"
LOAD="$(ups_get ups.load)"
POWER="$(ups_get ups.power)"
# Wirkleistung: die Zahl, auf die es bei der Lastbilanz ankommt. ups.power ist
# Scheinleistung (VA), ups.realpower die tatsaechlich verbrauchten Watt — bei
# Schaltnetzteilen liegen die spuerbar auseinander (gemessen: 392 VA / 269 W).
REALPOWER="$(ups_get ups.realpower)"
INVOLT="$(ups_get input.voltage)"
OUTVOLT="$(ups_get output.voltage)"
CHARGE_LOW="$(ups_get battery.charge.low)"

num() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && echo "$1" || echo ""; }

# ups.status kann mehrere Flags tragen (z. B. "OB DISCHRG"). Deshalb je Zustand
# eine eigene 0/1-Metrik statt eines Strings — so laesst sich direkt darauf
# alarmieren, ohne im Dashboard Text zu parsen.
online=0;   [[ "$STATUS" == *OL* ]] && online=1
onbatt=0;   [[ "$STATUS" == *OB* ]] && onbatt=1
lowbatt=0;  [[ "$STATUS" == *LB* ]] && lowbatt=1
charging=0; [[ "$STATUS" == *CHRG* ]] && charging=1
replace=0;  [[ "$STATUS" == *RB* ]] && replace=1

{
  printf 'ups_reporter_up{node="%s"} 1\n' "$NODE"
  printf 'ups_status_online{ups="%s"} %d\n'      "$UPS_NAME" "$online"
  printf 'ups_status_on_battery{ups="%s"} %d\n'  "$UPS_NAME" "$onbatt"
  printf 'ups_status_low_battery{ups="%s"} %d\n' "$UPS_NAME" "$lowbatt"
  printf 'ups_status_charging{ups="%s"} %d\n'    "$UPS_NAME" "$charging"
  printf 'ups_status_replace_battery{ups="%s"} %d\n' "$UPS_NAME" "$replace"

  v="$(num "$CHARGE")";     [ -n "$v" ] && printf 'ups_battery_charge_percent{ups="%s"} %s\n' "$UPS_NAME" "$v"
  v="$(num "$RUNTIME")";    [ -n "$v" ] && printf 'ups_battery_runtime_seconds{ups="%s"} %s\n' "$UPS_NAME" "$v"
  v="$(num "$LOAD")";       [ -n "$v" ] && printf 'ups_load_percent{ups="%s"} %s\n' "$UPS_NAME" "$v"
  v="$(num "$POWER")";      [ -n "$v" ] && printf 'ups_power_va{ups="%s"} %s\n' "$UPS_NAME" "$v"
  v="$(num "$REALPOWER")";  [ -n "$v" ] && printf 'ups_realpower_watts{ups="%s"} %s\n' "$UPS_NAME" "$v"
  v="$(num "$INVOLT")";     [ -n "$v" ] && printf 'ups_input_voltage{ups="%s"} %s\n' "$UPS_NAME" "$v"
  v="$(num "$OUTVOLT")";    [ -n "$v" ] && printf 'ups_output_voltage{ups="%s"} %s\n' "$UPS_NAME" "$v"
  v="$(num "$CHARGE_LOW")"; [ -n "$v" ] && printf 'ups_battery_charge_low_percent{ups="%s"} %s\n' "$UPS_NAME" "$v"

  # Die eigene Abschaltschwelle mitschieben: So zeigt das Dashboard, wann
  # welcher Node aussteigt, ohne dass die Werte dort doppelt gepflegt werden
  # muessen. Faellt der Rang aus (Cluster unvollstaendig), fehlt die Metrik.
  if rank_line="$(/usr/local/sbin/ups-staged-shutdown.sh --print-rank 2>/dev/null | grep "^Dieser Node")"; then
    thr="$(grep -oE 'Schwelle [0-9]+' <<<"$rank_line" | grep -oE '[0-9]+')"
    rnk="$(grep -oE 'Rang [0-9]+' <<<"$rank_line" | grep -oE '[0-9]+')"
    [ -n "$thr" ] && printf 'ups_node_shutdown_threshold_percent{node="%s"} %s\n' "$NODE" "$thr"
    [ -n "$rnk" ] && printf 'ups_node_shutdown_rank{node="%s"} %s\n' "$NODE" "$rnk"
  fi
} | curl -s --max-time 10 -X POST --data-binary @- "$VM_URL" >/dev/null 2>&1

# Bewusst immer 0: Ist VictoriaMetrics gerade nicht erreichbar — etwa weil beim
# Kaltstart die Swarm-VMs selbst noch hochfahren —, ist das kein Defekt. Der
# Timer versucht es 30 s spaeter erneut. Ohne dieses exit 0 bliebe der Dienst
# als "failed" stehen und verrauschte genau die systemctl --failed-Uebersicht,
# die nach einem Kaltstart der wichtigste Blick ist. (Beobachtet 2026-08-23:
# status=7/NOTRUNNING, curls Code fuer "konnte nicht verbinden".)
exit 0
