#!/bin/bash
# =============================================================================
# Zertifikate von der Uebergabe-Ablage nach lokal holen
# =============================================================================
# Ausgerollt von ansible/traefik-certs-sync.yml — NICHT auf dem Host editieren.
#
# WARUM LOKAL UND NICHT DIREKT VON CEPHFS
#   Zwei Gruende, beide praktisch belegt:
#
#   1. Der laufende Ingress soll nicht an CephFS haengen. Liest Traefik seine
#      Zertifikate direkt von dort, macht ein CephFS-Ausfall den Proxy
#      angreifbar — und CephFS faellt in diesem Cluster gelegentlich aus
#      (stale mounts, min_size bei zwei ausgefallenen Nodes).
#
#   2. Traefiks fsnotify-Watcher sieht Aenderungen nicht, die ein ANDERER
#      CephFS-Client geschrieben hat. Nachgewiesen am 2026-08-23: Nach einer
#      Erneuerung sah der Container die neue Datei (Inhalt und Zeitstempel per
#      docker exec bestaetigt), lieferte aber weiter das alte Zertifikat.
#      Eine LOKALE Aenderung dagegen erzeugt ein lokales inotify-Event.
#
#   Fehlt CephFS beim Lauf, passiert schlicht nichts: Die lokalen Kopien
#   bleiben gueltig, Traefik laeuft weiter. Das ist der eigentliche Gewinn.
# =============================================================================

set -uo pipefail

SRC=/mnt/cephfs/swarm-state/traefik/dist
DST=/opt/traefik/certs
DYN=/opt/traefik/dynamic
STAMP="$SRC/.updated"
MARKER="$DST/.synced"

log() { logger -t traefik-certs-sync "$*"; echo "$*"; }

mkdir -p "$DST" "$DYN"
chmod 755 "$DYN"
chmod 700 "$DST"

# Kein CephFS? Dann gibt es nichts zu holen — und das ist ausdruecklich KEIN
# Fehler. Die lokalen Kopien tragen den Betrieb weiter.
if [ ! -d "$SRC" ] || [ ! -r "$STAMP" ]; then
  log "Uebergabe-Ablage nicht erreichbar — lokale Zertifikate bleiben in Kraft"
  exit 0
fi

# Die Pruefung auf certs.yml gehoert mit in die Bedingung: Ohne sie stieg das
# Skript hier aus, sobald der Marker aktuell war — auch wenn die dynamische
# Konfiguration fehlte. Genau das passierte beim ersten Ausrollen, und die
# Datei waere nie nachgezogen worden.
if [ -e "$MARKER" ] && [ ! "$STAMP" -nt "$MARKER" ] && [ -f "$DYN/certs.yml" ]; then
  exit 0   # nichts Neues, der Normalfall
fi

log "neue Zertifikate in der Ablage — wird geholt"

changed=0
for src in "$SRC"/*.crt; do
  [ -e "$src" ] || { log "FEHLER: keine Zertifikate in $SRC"; exit 1; }
  name="$(basename "$src" .crt)"
  key="$SRC/$name.key"
  [ -s "$key" ] || { log "WARNUNG: $name ohne Schluessel, uebersprungen"; continue; }

  # Vergleich vor dem Kopieren: Sonst wuerde jede Datei bei jedem Lauf neu
  # geschrieben und Traefik luede ohne Anlass neu.
  if cmp -s "$src" "$DST/$name.crt" && cmp -s "$key" "$DST/$name.key"; then
    continue
  fi

  # Ueber eine temporaere Datei und mv: Ein halb geschriebenes Zertifikat
  # waere fuer Traefik ein Parse-Fehler, und der Watcher koennte genau dann
  # zuschlagen. mv im selben Dateisystem ist atomar.
  install -m 644 "$src" "$DST/.$name.crt.tmp" && mv -f "$DST/.$name.crt.tmp" "$DST/$name.crt"
  install -m 600 "$key" "$DST/.$name.key.tmp" && mv -f "$DST/.$name.key.tmp" "$DST/$name.key"
  log "$name aktualisiert"
  changed=$((changed + 1))
done

# --- dynamische Konfiguration lokal erzeugen ---------------------------------
# BEWUSST bei JEDEM Lauf, nicht nur wenn sich Zertifikate geaendert haben.
# Zuerst war es andersherum — mit der Folge, dass certs.yml dauerhaft fehlte,
# nachdem der erste Lauf die Dateien kopiert hatte und alle weiteren Laeufe
# mit "nichts geaendert" aussstiegen. Geschrieben wird trotzdem nur bei
# Unterschied (siehe unten), ein Reload wird also nicht grundlos ausgeloest.
# In place schreiben (truncate statt rename): Die Datei ist im Traefik-
# Container ein Bind-Mount auf genau diese Inode. Ein rename wuerde den Mount
# ins Leere zeigen lassen — und zwar lautlos.
tmp="$(mktemp)"
{
  echo "# ============================================================================="
  echo "# Traefik Dynamic Config: TLS-Zertifikate"
  echo "# ============================================================================="
  echo "# ERZEUGT von traefik-certs-sync.sh — NICHT VON HAND BEARBEITEN."
  echo "# Quelle: $SRC (geschrieben vom Swarm-Dienst traefik_certs-renew)"
  echo "# Stand:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "#"
  echo "# Das Wildcard deckt jeden Dienst dieser Zone ab. Ein neuer Stack mit"
  echo "# Host(\`irgendwas.hornung-bn.de\`) braucht daher KEINE Zertifikatsaktion —"
  echo "# Traefik erkennt den Router ueber die Swarm-API, das Zertifikat passt."
  echo "# ============================================================================="
  echo ""
  echo "tls:"
  echo "  certificates:"
  for crt in "$DST"/*.crt; do
    [ -e "$crt" ] || continue
    n="$(basename "$crt" .crt)"
    [ -s "$DST/$n.key" ] || continue
    # /certs-local, nicht /certs: Unter /certs liegt noch der alte
    # CephFS-Mount. Solange beide Quellen parallel laufen, muessen sich die
    # Pfade unterscheiden.
    echo "    - certFile: /certs-local/$n.crt"
    echo "      keyFile: /certs-local/$n.key"
  done
} > "$tmp"

# Nur schreiben, wenn sich der Inhalt unterscheidet — sonst wuerde jeder
# Lauf Traefik zum Neuladen bringen. Der Zeitstempel im Kopf ist dabei
# ausgenommen, sonst waere die Datei immer verschieden.
if [ -f "$DYN/certs.yml" ] && \
   diff -q <(grep -v '^# Stand:' "$DYN/certs.yml") <(grep -v '^# Stand:' "$tmp") >/dev/null 2>&1; then
  rm -f "$tmp"
  touch -r "$STAMP" "$MARKER"
  [ "$changed" -gt 0 ] && log "$changed Zertifikat(e) uebernommen (certs.yml unveraendert)"
  exit 0
fi

if [ -f "$DYN/certs.yml" ]; then
  # In place (truncate statt rename): Die Datei ist im Traefik-Container ein
  # Bind-Mount auf genau diese Inode. Ein rename wuerde den Mount ins Leere
  # zeigen lassen — und zwar lautlos.
  cat "$tmp" > "$DYN/certs.yml"
else
  install -m 644 "$tmp" "$DYN/certs.yml"
fi
rm -f "$tmp"
chmod 644 "$DYN/certs.yml"

touch -r "$STAMP" "$MARKER"
log "certs.yml geschrieben ($changed Zertifikat(e) neu uebernommen)"
