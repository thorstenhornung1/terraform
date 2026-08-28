#!/usr/bin/env python3
"""pvesr-Metriken fuer den node-exporter-Textfile-Collector.

Liest die Replikationsjobs, deren Quelle dieser Node ist, ueber die lokale
PVE-API und schreibt sie als Prometheus-Metriken nach
/var/lib/prometheus/node-exporter/pvesr.prom. Der Job pve-node-exporter
nimmt die Datei beim naechsten Scrape automatisch mit.

Anlass (2026-08-28): Der Rolling-Reboot der Daily Maintenance liess die
minuetlichen Replikationsjobs gegen den rebootenden Node laufen — sichtbar
wurde das nur ueber die Fehl-Mails von pvescheduler. postgres-prod (4600),
Home Assistant (100) und Frigate (4502) verlassen sich fuer PVE-HA auf genau
diese Replikate; ein stiller Ausfall heisst veraltetes Failover-Ziel.

Fehlersemantik: Schlaegt die API-Abfrage fehl, wird die .prom-Datei bewusst
NICHT angefasst und mit Exit 1 beendet. Die Datei altert dann, und der Alert
pvesr-metrics-stale (node_textfile_mtime_seconds) schlaegt an — eine leere
oder halbe Datei saehe dagegen wie "keine Jobs, alles gut" aus.
"""

import glob
import json
import os
import platform
import re
import subprocess
import sys
import time

TEXTFILE = "/var/lib/prometheus/node-exporter/pvesr.prom"
# Marker legt roles/proxmox_maintenance/tasks/pvesr_pause.yml an (Repo
# ansible), pvesr_resume.yml entfernt ihn. /etc/pve = pmxcfs, clusterweit.
MARKER_GLOB = "/etc/pve/.pvesr-maint-paused-*.json"
# Unparsebare Kalender-Events (z. B. "mon..fri 5:00") werden als stuendlich
# behandelt: lieber ein zu spaeter Stale-Alarm als ein Daueralarm.
FALLBACK_SCHEDULE_SECONDS = 3600


def schedule_seconds(schedule):
    """'*/5' -> 300. PVE-Default (Feld fehlt) ist '*/15'."""
    m = re.fullmatch(r"\*/(\d+)", (schedule or "*/15").strip())
    return int(m.group(1)) * 60 if m else FALLBACK_SCHEDULE_SECONDS


def fetch_jobs(node):
    out = subprocess.run(
        ["pvesh", "get", f"/nodes/{node}/replication", "--output-format", "json"],
        capture_output=True, text=True, timeout=60,
    )
    if out.returncode != 0:
        raise RuntimeError(f"pvesh rc={out.returncode}: {out.stderr.strip()[:200]}")
    return json.loads(out.stdout)


def pause_age_seconds(now):
    """Alter des aeltesten Wartungs-Markers, 0 = keiner vorhanden."""
    age = 0
    for path in glob.glob(MARKER_GLOB):
        try:
            with open(path) as fh:
                ts = int(json.load(fh).get("ts", 0))
            if ts > 0:
                age = max(age, int(now - ts))
        except (OSError, ValueError):
            # Kaputter Marker ist genau der Fall, den der Alert sehen soll:
            # als maximal alt melden statt still zu ignorieren.
            age = max(age, 10 * 86400)
    return age


def main():
    node = platform.node().split(".")[0]
    now = time.time()
    jobs = fetch_jobs(node)

    lines = [
        "# HELP pvesr_job_fail_count Aufeinanderfolgende Fehlversuche des Replikationsjobs (0 = gesund).",
        "# TYPE pvesr_job_fail_count gauge",
        "# HELP pvesr_job_last_sync_timestamp_seconds Zeitpunkt des letzten erfolgreichen Syncs (Unix-Epoch, 0 = nie).",
        "# TYPE pvesr_job_last_sync_timestamp_seconds gauge",
        "# HELP pvesr_job_last_try_timestamp_seconds Zeitpunkt des letzten Versuchs (Unix-Epoch, 0 = nie).",
        "# TYPE pvesr_job_last_try_timestamp_seconds gauge",
        "# HELP pvesr_job_duration_seconds Dauer des letzten Sync-Laufs.",
        "# TYPE pvesr_job_duration_seconds gauge",
        "# HELP pvesr_job_disabled 1 = Job ist deaktiviert (pvesr disable).",
        "# TYPE pvesr_job_disabled gauge",
        "# HELP pvesr_job_error 1 = Job meldet aktuell einen Fehlertext (Wortlaut steht im Syslog/Loki).",
        "# TYPE pvesr_job_error gauge",
        "# HELP pvesr_job_schedule_seconds Soll-Intervall des Jobs in Sekunden (aus dem Schedule abgeleitet).",
        "# TYPE pvesr_job_schedule_seconds gauge",
        "# HELP pvesr_job_count Anzahl Replikationsjobs mit Quelle auf diesem Node.",
        "# TYPE pvesr_job_count gauge",
        "# HELP pvesr_maintenance_pause_age_seconds Alter des Wartungs-Pause-Markers in /etc/pve (0 = keine Pause aktiv).",
        "# TYPE pvesr_maintenance_pause_age_seconds gauge",
    ]

    for job in sorted(jobs, key=lambda j: str(j.get("id", ""))):
        labels = 'id="{}",guest="{}",target="{}"'.format(
            job.get("id", ""), job.get("guest", ""), job.get("target", ""))
        lines += [
            f'pvesr_job_fail_count{{{labels}}} {int(job.get("fail_count", 0))}',
            f'pvesr_job_last_sync_timestamp_seconds{{{labels}}} {int(job.get("last_sync", 0) or 0)}',
            f'pvesr_job_last_try_timestamp_seconds{{{labels}}} {int(job.get("last_try", 0) or 0)}',
            f'pvesr_job_duration_seconds{{{labels}}} {float(job.get("duration", 0) or 0):.3f}',
            f'pvesr_job_disabled{{{labels}}} {1 if job.get("disable") else 0}',
            f'pvesr_job_error{{{labels}}} {1 if job.get("error") else 0}',
            f'pvesr_job_schedule_seconds{{{labels}}} {schedule_seconds(job.get("schedule"))}',
        ]

    lines.append(f"pvesr_job_count {len(jobs)}")
    lines.append(f"pvesr_maintenance_pause_age_seconds {pause_age_seconds(now)}")

    # Atomar ersetzen: node-exporter darf nie eine halb geschriebene Datei
    # lesen (unvollstaendige Datei = node_textfile_scrape_error).
    tmp = TEXTFILE + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, TEXTFILE)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 — jede Ursache gleich behandeln
        print(f"pvesr-metrics: {exc}", file=sys.stderr)
        sys.exit(1)
