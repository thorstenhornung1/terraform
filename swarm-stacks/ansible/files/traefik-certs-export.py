#!/usr/bin/env python3
# =============================================================================
# Zertifikate aus acme.json nach PEM exportieren
# =============================================================================
# Einmalig beim Umstieg auf die zentrale Zertifikatsverwaltung, danach nur noch
# als Notnagel. Im Normalbetrieb schreibt traefik-certs-renew.sh die Dateien.
#
# WARUM EXPORTIEREN STATT NEU AUSSTELLEN
#   Die 27 Zertifikate existieren und sind gueltig. Sie neu anzufordern haette
#   27 von 50 woechentlich erlaubten Ausstellungen verbraucht — und jeder
#   Fehlversuch waere aus demselben Kontingent gegangen. Der Export macht die
#   Umstellung zustandserhaltend: Traefik liefert hinterher exakt dieselben
#   Zertifikate, nur aus einer anderen Quelle.
#
# Das Skript gibt NUR Domainnamen und Ablaufdaten aus, niemals Schluesselmaterial.
# =============================================================================

import base64
import datetime
import json
import os
import subprocess
import sys
import tempfile

ACME = "/mnt/cephfs/swarm-state/traefik/acme.json"
CERTDIR = "/mnt/cephfs/swarm-state/traefik/certs"
DYNDIR = "/mnt/cephfs/swarm-state/traefik/dynamic"
CERTS_YML = os.path.join(DYNDIR, "certs.yml")
# Pfad, unter dem Traefik das Verzeichnis sieht (Mount-Ziel im Container)
CONTAINER_CERTDIR = "/certs"


def cert_enddate(pem_bytes):
    """Ablaufdatum aus einem PEM lesen, ohne es anzuzeigen."""
    with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
        f.write(pem_bytes)
        path = f.name
    try:
        out = subprocess.run(
            ["openssl", "x509", "-noout", "-enddate", "-in", path],
            capture_output=True, text=True).stdout
    finally:
        os.unlink(path)
    if not out:
        return None
    return datetime.datetime.strptime(
        out.strip().split("=", 1)[1], "%b %d %H:%M:%S %Y %Z"
    ).replace(tzinfo=datetime.timezone.utc)


def main():
    if not os.path.exists(ACME):
        print(f"FEHLER: {ACME} fehlt", file=sys.stderr)
        return 1

    os.makedirs(CERTDIR, mode=0o700, exist_ok=True)
    os.makedirs(DYNDIR, mode=0o755, exist_ok=True)

    with open(ACME) as f:
        store = json.load(f)

    now = datetime.datetime.now(datetime.timezone.utc)
    entries = []

    for resolver, data in store.items():
        for cert in (data.get("Certificates") or []):
            domain = cert["domain"]["main"]
            crt = base64.b64decode(cert["certificate"])
            key = base64.b64decode(cert["key"])

            end = cert_enddate(crt)
            days = (end - now).days if end else None

            crt_path = os.path.join(CERTDIR, f"{domain}.crt")
            key_path = os.path.join(CERTDIR, f"{domain}.key")

            # Schluessel mit 0600 anlegen, BEVOR Inhalt hineinkommt —
            # sonst existiert die Datei kurzzeitig mit umask-Rechten.
            for path, content, mode in ((crt_path, crt, 0o644), (key_path, key, 0o600)):
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
                with os.fdopen(fd, "wb") as f:
                    f.write(content)
                os.chmod(path, mode)

            entries.append((domain, days))

    entries.sort()

    # certs.yml IN PLACE schreiben (truncate statt rename): Die Datei ist im
    # Traefik-Container ein Bind-Mount auf genau diese Inode. Ein rename wuerde
    # den Mount ins Leere zeigen lassen, und Traefik saehe nie wieder eine
    # Aenderung — ohne dass etwas kaputt aussieht.
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "# =============================================================================",
        "# Traefik Dynamic Config: TLS-Zertifikate",
        "# =============================================================================",
        "# ERZEUGT — NICHT VON HAND BEARBEITEN.",
        "# Quelle: ansible/files/traefik-certs-export.py bzw. traefik-certs-renew.sh",
        f"# Stand: {stamp}",
        "#",
        "# Der Zeitstempel oben ist kein Schmuck: Traefik laedt diese Datei nur neu,",
        "# wenn sie sich AENDERT. Wird nur ein Zertifikat im certs-Verzeichnis",
        "# ersetzt, bleibt der Inhalt hier sonst identisch und Traefik wuerde",
        "# weiter das alte Zertifikat ausliefern.",
        "# =============================================================================",
        "",
        "tls:",
        "  certificates:",
    ]
    for domain, days in entries:
        lines.append(f"    # {domain} — noch {days} Tage gueltig" if days is not None
                     else f"    # {domain}")
        lines.append(f"    - certFile: {CONTAINER_CERTDIR}/{domain}.crt")
        lines.append(f"      keyFile: {CONTAINER_CERTDIR}/{domain}.key")
    lines.append("")

    with open(CERTS_YML, "w") as f:
        f.write("\n".join(lines))
    os.chmod(CERTS_YML, 0o644)

    print(f"{len(entries)} Zertifikate exportiert nach {CERTDIR}")
    for domain, days in entries:
        flag = "  ← laeuft bald ab" if days is not None and days < 30 else ""
        print(f"  {domain:38} {days:>4} Tage{flag}")
    print(f"\n{CERTS_YML} geschrieben")
    return 0


if __name__ == "__main__":
    sys.exit(main())
