#!/bin/bash
# =============================================================================
# Traefik neu laden, wenn sich die Zertifikate geaendert haben
# =============================================================================
# Ausgerollt von ansible/traefik-certs-reload.yml — NICHT auf dem Host editieren.
#
# WARUM DAS NOETIG IST — obwohl die Datei inzwischen LOKAL liegt
#   Seit die Zertifikate lokal liegen (traefik-certs-sync.sh), koennte
#   Traefiks fsnotify-Watcher die Aenderung theoretisch selbst bemerken. In
#   der Praxis ist darauf kein Verlass:
#
#   - Die Traefik-Doku warnt ausdruecklich vor gemounteten Dateisystemen:
#     "If the link between the file systems is broken, when a source file is
#     changed/renamed, nothing will be reported to the linked file, so the
#     file system notifications will be neither triggered nor caught."
#     certs-local.yml ist genau so ein Bind-Mount einer einzelnen Datei.
#   - Schreibt jemand mit `sed -i` statt in-place, wechselt die Inode und der
#     Mount zeigt lautlos ins Leere. Am 2026-08-23 im Test genau passiert.
#   - Traefik-Issue #5495 (offen seit Jahren) beschreibt exakt den Fall:
#     extern erzeugte Zertifikate, Traefik bemerkt die Aenderung nicht.
#
#   Dieser Timer ist deshalb kein Ersatz fuer den Watcher, sondern das Netz
#   darunter. Er kostet einen rollierenden Neustart alle ~60 Tage.
#
# WARUM NICHT AUS DEM ERNEUERUNGSDIENST HERAUS
#   Der haette Schreibzugriff auf die Docker-API gebraucht. Der Socket-Proxy
#   im traefik-Stack ist aber mit Traefik im selben Netz — POST dort zu
#   erlauben, haette dem internetexponierten Ingress Schreibrechte auf die
#   Orchestrierung gegeben. Ein Node-Skript braucht das nicht.
#
# 🔴 IMMER "docker service update --force", NIE "docker restart"
#   Swarm fuehrt den Sollzustand ueber Tasks, nicht ueber Container. Ein
#   direkter Container-Neustart laesst Swarm den Task als beendet werten; bei
#   mehreren Nodes kurz hintereinander landet der Service auf 0/0. Am
#   2026-08-23 fiel dadurch zweimal der komplette Ingress aus.
# =============================================================================

set -uo pipefail

# Quelle ist die LOKALE dynamische Konfiguration, nicht mehr die auf CephFS.
# Der Ingress liest seit 2026-08-23 lokal; CephFS ist nur noch Transportweg.
STAMP=/opt/traefik/dynamic/certs.yml
MARKER=/opt/traefik/.last-reload
# Der Lock liegt weiterhin auf CephFS — er muss clusterweit gelten, damit
# nicht alle drei Nodes denselben Reload ausloesen. Faellt CephFS aus, gibt
# es nichts zu reloaden (dann synct auch nichts), also ist das unkritisch.
LOCK=/mnt/cephfs/swarm-state/traefik/.reload.lock
SERVICE=traefik_traefik

log() { logger -t traefik-certs-reload "$*"; echo "$*"; }

[ -r "$STAMP" ] || { log "certs.yml nicht lesbar ($STAMP) — lief traefik-certs-sync schon?"; exit 0; }

# Der Timer laeuft auf allen drei Nodes. Der Lock sorgt dafuer, dass genau
# einer den Reload ausloest — sonst wuerde Traefik dreimal hintereinander
# durchgestartet. Liegt auf CephFS, gilt also clusterweit.
exec 9>"$LOCK" || { log "Lock-Datei nicht anlegbar"; exit 0; }
if ! flock -n 9; then
  log "anderer Node haelt den Lock — nichts zu tun"
  exit 0
fi

if [ -e "$MARKER" ] && [ ! "$STAMP" -nt "$MARKER" ]; then
  exit 0   # nichts geaendert, der Normalfall
fi

log "certs.yml ist neuer als der letzte Reload — Traefik wird neu geladen"

# --detach: Ohne das wartet der Befehl auf die Konvergenz und laeuft in den
# Timeout der systemd-Unit. Der Fortschritt steht ohnehin in "docker service ps".
if docker service update --force --detach "$SERVICE" >/dev/null 2>&1; then
  # Marker auf den Zeitstempel der Quelle setzen, nicht auf "jetzt": Sonst
  # wuerde eine Erneuerung, die WAEHREND des Reloads passiert, uebersehen.
  touch -r "$STAMP" "$MARKER"
  log "Reload ausgeloest"
else
  log "FEHLER: docker service update fehlgeschlagen — naechster Lauf versucht es erneut"
  exit 1
fi
