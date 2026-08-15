#!/bin/sh
# =============================================================================
# Wallos SQLite-Backup-Sidecar
# =============================================================================
# Warum es diesen Sidecar gibt:
#   Die produktive wallos.db liegt aus SQLite-Gründen LOKAL auf docker-infra-2
#   (kein CephFS wegen WAL/mmap, kein RBD weil der Failover-Apparat überzogen
#   wäre). Damit hängt der Datenbestand an genau einem Node. Dieser Sidecar
#   zieht konsistente Kopien nach CephFS, wo das PBS-Backup sie miterfasst.
#
# Warum `sqlite3 .backup` und nicht `cp`:
#   Ein `cp` einer laufenden SQLite-Datei liefert einen zerrissenen Stand,
#   sobald während des Kopierens geschrieben wird — im WAL-Modus zusätzlich
#   ohne den Inhalt des noch nicht eingecheckten WAL. `.backup` nutzt die
#   Online-Backup-API und liefert einen in sich konsistenten Snapshot, auch
#   unter laufenden Schreibvorgängen.
#
# Zusätzlich läuft ein `PRAGMA integrity_check` auf JEDER Kopie. Das ist die
# Integritätsprüfung, die bei physischen Backups fehlt: ein blockweiser
# Snapshot kopiert eine korrupte Datenbank klaglos mit, ein gescheiterter
# integrity_check macht sie sichtbar. Kopien, die den Check nicht bestehen,
# werden verworfen statt als gültiges Backup liegen zu bleiben.
# =============================================================================

DB_SOURCE="/data/db/wallos.db"
BACKUP_DIR="/backup"
INTERVAL="${BACKUP_INTERVAL_SECONDS:-21600}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Backup-Sidecar gestartet — Quelle: $DB_SOURCE, Ziel: $BACKUP_DIR"
log "Intervall: ${INTERVAL}s, Aufbewahrung: ${RETENTION_DAYS} Tage"

# Wallos legt die DB beim ersten Start selbst an. Vorher gibt es nichts zu
# sichern — warten statt mit Fehler sterben.
while [ ! -f "$DB_SOURCE" ]; do
    log "Warte auf $DB_SOURCE (Wallos initialisiert noch)..."
    sleep 30
done

# Kurz nachlaufen lassen, damit die Migrationen beim allerersten Start durch
# sind, bevor die erste Kopie gezogen wird.
sleep 60

while true; do
    TS="$(date '+%Y%m%d-%H%M%S')"
    DEST="${BACKUP_DIR}/wallos-${TS}.db"

    if sqlite3 "$DB_SOURCE" ".backup '${DEST}'" 2>&1; then
        CHECK="$(sqlite3 "$DEST" 'PRAGMA integrity_check;' 2>&1 | head -1)"
        if [ "$CHECK" = "ok" ]; then
            SIZE="$(du -h "$DEST" | cut -f1)"
            log "OK: $(basename "$DEST") (${SIZE}, integrity_check bestanden)"
        else
            log "FEHLER: integrity_check fehlgeschlagen -> '${CHECK}'"
            log "FEHLER: verwerfe $(basename "$DEST") — eine kaputte Kopie ist"
            log "FEHLER: schlimmer als eine fehlende, weil sie Sicherheit vortäuscht."
            rm -f "$DEST"
        fi
    else
        log "FEHLER: sqlite3 .backup fehlgeschlagen — keine Kopie erzeugt"
        rm -f "$DEST"
    fi

    # Rotation über die Änderungszeit statt über sortierte Dateinamen: Ein
    # `ls | sort | head` sortiert bei gemischten Namen alphabetisch und löscht
    # dann die falschen Dateien — genau der Bug, der den abgeschafften
    # pg-backup-Stack seine Aufbewahrung gekostet hat.
    DELETED="$(find "$BACKUP_DIR" -maxdepth 1 -name 'wallos-*.db' -type f -mtime "+${RETENTION_DAYS}" -print -delete 2>/dev/null | wc -l)"
    if [ "$DELETED" -gt 0 ]; then
        log "Rotation: ${DELETED} Kopie(n) älter als ${RETENTION_DAYS} Tage entfernt"
    fi

    COUNT="$(find "$BACKUP_DIR" -maxdepth 1 -name 'wallos-*.db' -type f 2>/dev/null | wc -l)"
    log "Bestand: ${COUNT} Kopie(n). Nächster Lauf in ${INTERVAL}s."

    sleep "$INTERVAL"
done
