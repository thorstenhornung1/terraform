#!/usr/bin/env python3
"""
traefik-cert-controller — Zertifikatsverwaltung fuer Traefik im Docker Swarm.

WOZU
    Traefik CE kann ACME nicht ueber mehrere Instanzen betreiben: Das
    acme.json-Storage ist laut Doku ausdruecklich nicht teilbar ("For
    concurrency reasons, this file cannot be shared across multiple instances
    of Traefik"), und der Feature-Request fuer verteiltes Zertifikats-Storage
    wurde abgelehnt. Vorgefunden am 2026-08-23: drei Instanzen, drei
    verschiedene Zertifikate pro Domain, bei zwei Domains gar keines.

    Traefik verweist fuer echtes HA auf einen "Certificate Controller such as
    Cert-Manager" — den es aber nur fuer Kubernetes gibt. Dieses Programm ist
    das Aequivalent fuer Swarm: Es uebernimmt die Ableitung "Router-Regel ->
    benoetigtes Zertifikat", die Traefik intern selbst macht.

ARBEITSWEISE — Soll-Ist-Abgleich, nicht Ereignisverarbeitung
    Docker-Events loesen einen Durchlauf aus, liefern aber KEINE Information
    darueber, was zu tun ist. Jeder Durchlauf ermittelt den vollstaendigen
    Sollzustand neu und vergleicht ihn mit dem Ist. Das ist der Unterschied
    zwischen einem Skript und einem Controller: Verpasste Events, Neustarts,
    Umbenennungen und geloeschte Dienste heilen sich von selbst, weil kein
    Zustand zwischen den Durchlaeufen mitgeschleppt wird.

    Zusaetzlich laeuft ein Timer, damit ein Ausfall des Event-Streams das
    System nicht einfriert.

WAS ES NICHT TUT
    Zertifikate loeschen. Ein Dienst kann voruebergehend fehlen (Deploy,
    Node-Ausfall, Umbenennung); ein geloeschtes Zertifikat waere danach nur
    ueber eine neue ACME-Ausstellung zurueckzuholen, und die zaehlt gegen das
    Wochenkontingent. Ungenutzte Zertifikate laufen stattdessen aus und
    werden protokolliert.
"""

import json
import logging
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import docker

# --- Konfiguration -----------------------------------------------------------
DOCKER_HOST = os.environ.get("DOCKER_HOST", "tcp://docker-socket-proxy:2375")
DIST = Path(os.environ.get("DIST_DIR", "/state/dist"))
LEGO_PATH = Path(os.environ.get("LEGO_DIR", "/state/lego"))
ACME_EMAIL = os.environ["ACME_EMAIL"]
DNS_PROVIDER = os.environ.get("DNS_PROVIDER", "cloudflare")
DNS_RESOLVERS = os.environ.get("DNS_RESOLVERS", "1.1.1.1:53,8.8.8.8:53")
RENEW_BELOW_DAYS = int(os.environ.get("RENEW_BELOW_DAYS", "30"))
MAX_PER_RUN = int(os.environ.get("MAX_PER_RUN", "5"))
FULL_RECONCILE_SECONDS = int(os.environ.get("FULL_RECONCILE_SECONDS", "21600"))
# Ereignisse kommen in Schueben (ein Stack-Deploy erzeugt viele). Ohne Wartezeit
# liefe der Abgleich pro Dienst einmal statt einmal fuer den ganzen Deploy.
DEBOUNCE_SECONDS = int(os.environ.get("DEBOUNCE_SECONDS", "15"))

# Wildcards, die immer vorgehalten werden — unabhaengig davon, ob gerade ein
# Dienst sie braucht. Sie decken die Masse ab und machen Discovery fuer den
# Normalfall ueberfluessig.
WILDCARDS = [w for w in os.environ.get(
    "WILDCARD_CERTS", "wildcard.hornung-bn.de=*.hornung-bn.de,hornung-bn.de"
).split(";") if w.strip()]

# Ausdrueckliche Ausnahmen: Domains, um die sich dieser Controller NICHT
# kuemmert. Etwa solche, die ein anderer Proxy bedient.
IGNORE_DOMAINS = {d.strip() for d in os.environ.get(
    "IGNORE_DOMAINS", "").split(",") if d.strip()}

DRY_RUN = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")

# lego liest das Token selbst aus der Datei (_FILE-Konvention der lego-DNS-
# Provider). Dieses Programm fasst es nie an und kann es folglich auch nicht
# versehentlich ins Log schreiben. Geprueft wird nur, ob die Datei lesbar ist —
# ohne diese Pruefung faellt ein fehlendes Secret erst beim ersten
# Ausstellungsversuch auf, und der zaehlt dann gegen das Wochenkontingent.
TOKEN_FILE = os.environ.get("CLOUDFLARE_DNS_API_TOKEN_FILE",
                            "/run/secrets/traefik_dns_api_token")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
logging.Formatter.converter = time.gmtime
log = logging.getLogger("cert-controller")

# Host(`a.b.de`) und Host(`a.b.de`, `c.b.de`), auch in ||/&&-Verknuepfungen.
# HostRegexp wird BEWUSST nicht ausgewertet: Aus einem regulaeren Ausdruck
# laesst sich keine Domainliste ableiten, ohne zu raten. Solche Faelle
# gehoeren ins Label cert-controller.domains.
_HOST_RE = re.compile(r"Host\(([^)]*)\)", re.IGNORECASE)
_QUOTED_RE = re.compile(r"[`'\"]([^`'\"]+)[`'\"]")
_ROUTER_RULE_RE = re.compile(r"^traefik\.http\.routers\.[^.]+\.rule$")
_DOMAIN_RE = re.compile(r"^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))+$")

_stop = threading.Event()
_wake = threading.Event()


def now():
    return datetime.now(timezone.utc)


# --- Discovery ---------------------------------------------------------------
def extract_hosts(rule: str) -> set:
    """Domains aus einer Traefik-Router-Regel ziehen."""
    found = set()
    for group in _HOST_RE.findall(rule):
        for host in _QUOTED_RE.findall(group):
            host = host.strip().lower().rstrip(".")
            if _DOMAIN_RE.match(host):
                found.add(host)
            else:
                log.warning("Regel enthaelt keinen verwertbaren Hostnamen: %r", host)
    return found


def service_labels(svc) -> dict:
    """Labels eines Dienstes — Swarm kennt zwei Orte dafuer.

    `deploy.labels` landet unter Spec.Labels, `labels` auf Service-Ebene unter
    TaskTemplate.ContainerSpec.Labels. Traefik liest beide, also tun wir es
    auch — sonst wuerde ein Dienst je nach Schreibweise uebersehen.
    """
    spec = svc.attrs.get("Spec", {})
    labels = dict(spec.get("Labels") or {})
    container = (spec.get("TaskTemplate") or {}).get("ContainerSpec") or {}
    labels.update(container.get("Labels") or {})
    return labels


def desired_domains(client) -> tuple:
    """Alle Domains ermitteln, die im Swarm bedient werden."""
    domains, sources = set(), {}
    for svc in client.services.list():
        labels = service_labels(svc)
        name = svc.name

        # Ein ausdrueckliches Label hat Vorrang. Gedacht fuer Regeln, aus denen
        # sich nichts ableiten laesst (HostRegexp) oder fuer Domains, die kein
        # Router traegt.
        explicit = labels.get("cert-controller.domains")
        if explicit:
            for d in explicit.split(","):
                d = d.strip().lower().rstrip(".")
                if _DOMAIN_RE.match(d):
                    domains.add(d)
                    sources.setdefault(d, set()).add(f"{name} (Label)")
                else:
                    log.warning("%s: cert-controller.domains enthaelt %r — ignoriert", name, d)
            continue

        if labels.get("cert-controller.enable", "").lower() == "false":
            continue
        if labels.get("traefik.enable", "").lower() != "true":
            continue

        for key, value in labels.items():
            if not _ROUTER_RULE_RE.match(key):
                continue
            if "hostregexp" in value.lower():
                log.info(
                    "%s: %s nutzt HostRegexp — daraus wird kein Zertifikat "
                    "abgeleitet. Bei Bedarf cert-controller.domains setzen.",
                    name, key)
            for host in extract_hosts(value):
                domains.add(host)
                sources.setdefault(host, set()).add(name)

    return domains - IGNORE_DOMAINS, sources


# --- Abdeckung ---------------------------------------------------------------
def covers(cert_domains, host: str) -> bool:
    """Deckt eines der Zertifikats-Namen den Host ab?

    Ein Wildcard gilt fuer GENAU EINE Ebene: *.example.de deckt foo.example.de,
    aber nicht foo.bar.example.de. Genau diese Regel wird beim Entwurf gern
    uebersehen — und faellt erst auf, wenn ein Dienst mit zwei Sub-Ebenen
    deployt wird und still das Default-Zertifikat bekommt.
    """
    for d in cert_domains:
        d = d.lower()
        if d == host:
            return True
        if d.startswith("*."):
            base = d[2:]
            if host.endswith("." + base) and host[: -(len(base) + 1)].count(".") == 0:
                return True
    return False


# --- Zertifikatsbestand ------------------------------------------------------
def cert_names(path: Path) -> list:
    """Subject und SANs eines Zertifikats lesen."""
    out = subprocess.run(
        ["openssl", "x509", "-noout", "-subject", "-ext", "subjectAltName", "-in", str(path)],
        capture_output=True, text=True).stdout
    names = set()
    for m in re.finditer(r"(?:CN\s*=\s*|DNS:)([^,\s]+)", out):
        names.add(m.group(1).strip().lower())
    return sorted(names)


def expires_within(path: Path, days: int) -> bool:
    """True, wenn das Zertifikat binnen `days` ablaeuft (oder unlesbar ist)."""
    rc = subprocess.run(
        ["openssl", "x509", "-checkend", str(days * 86400), "-noout", "-in", str(path)],
        capture_output=True).returncode
    return rc != 0


def enddate(path: Path) -> str:
    out = subprocess.run(
        ["openssl", "x509", "-noout", "-enddate", "-in", str(path)],
        capture_output=True, text=True).stdout
    return out.strip().split("=", 1)[1] if "=" in out else "?"


def inventory() -> dict:
    """Vorhandene Zertifikate: Name -> {path, names, expiring}."""
    inv = {}
    if not DIST.is_dir():
        return inv
    for crt in sorted(DIST.glob("*.crt")):
        key = crt.with_suffix(".key")
        if not key.exists() or key.stat().st_size == 0:
            log.warning("%s hat keinen Schluessel — wird ignoriert", crt.name)
            continue
        inv[crt.stem] = {
            "path": crt,
            "names": cert_names(crt),
            "expiring": expires_within(crt, RENEW_BELOW_DAYS),
            "enddate": enddate(crt),
        }
    return inv


# --- Ausstellung -------------------------------------------------------------
def run_lego(name: str, domains: list) -> bool:
    """Ein Zertifikat ausstellen und in die Uebergabe-Ablage legen."""
    if DRY_RUN:
        log.info("[Probelauf] wuerde ausstellen: %s -> %s", name, ", ".join(domains))
        return True

    args = ["lego", "--accept-tos", "--email", ACME_EMAIL, "--dns", DNS_PROVIDER]
    for r in DNS_RESOLVERS.split(","):
        args += ["--dns.resolvers", r.strip()]
    for d in domains:
        args += ["--domains", d]
    # "run" statt "renew": renew setzt voraus, dass lego das Zertifikat selbst
    # ausgestellt hat und die zugehoerige .json kennt. Bei uebernommenen
    # Zertifikaten ist das nicht der Fall.
    args += ["--path", str(LEGO_PATH), "run"]

    proc = subprocess.run(args, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        # Die Ausgabe kann Domainnamen und Fehlertexte enthalten, aber kein
        # Token — das liest lego direkt aus der Secret-Datei.
        for line in (proc.stdout + proc.stderr).strip().splitlines()[-6:]:
            log.error("    %s", line)
        return False

    # Den Dateinamen ableiten statt raten: lego benennt nach der ERSTEN
    # Domain und ersetzt darin "*" durch "_".
    #
    # Der naheliegende Weg — die neueste *.crt im Verzeichnis nehmen — geht
    # schief, weil lego pro Zertifikat ZWEI .crt-Dateien schreibt: die Kette
    # und zusaetzlich <name>.issuer.crt. Trifft die Sortierung letztere, sucht
    # with_suffix(".key") nach "<name>.issuer.key", die es nicht gibt. Genau
    # daran scheiterte die erste Ausstellung von mail.test.hornung-bn.de.
    stem = domains[0].replace("*", "_")
    src_crt = LEGO_PATH / "certificates" / f"{stem}.crt"
    src_key = LEGO_PATH / "certificates" / f"{stem}.key"
    if not src_crt.exists() or not src_key.exists():
        log.error("%s: lego meldete Erfolg, aber %s.crt/.key fehlen in %s",
                  name, stem, LEGO_PATH / "certificates")
        vorhanden = sorted(p.name for p in (LEGO_PATH / "certificates").glob(f"{stem}*"))
        log.error("    vorhanden: %s", ", ".join(vorhanden) or "(nichts)")
        return False

    DIST.mkdir(parents=True, exist_ok=True)
    # Ueber eine temporaere Datei und os.replace: Ein halb geschriebenes
    # Zertifikat waere fuer den nachgelagerten Sync ein Fehler, und der koennte
    # genau dann zugreifen.
    for src, dst, mode in ((src_crt, DIST / f"{name}.crt", 0o644),
                           (src_key, DIST / f"{name}.key", 0o600)):
        tmp = DIST / f".{name}.tmp"
        tmp.write_bytes(src.read_bytes())
        tmp.chmod(mode)
        os.replace(tmp, dst)
    return True


# --- Abgleich ----------------------------------------------------------------
def reconcile(client) -> None:
    """Sollzustand ermitteln und herstellen. Idempotent."""
    try:
        domains, sources = desired_domains(client)
    except Exception as exc:
        log.error("Swarm-API nicht lesbar (%s) — Durchlauf uebersprungen", exc)
        return

    inv = inventory()

    # Sollzustand: die konfigurierten Wildcards, dazu jede Domain, die von
    # keinem davon abgedeckt wird.
    wanted = {}
    covered_by_wildcard = set()
    for entry in WILDCARDS:
        if "=" not in entry:
            log.warning("WILDCARD_CERTS-Eintrag ohne '=': %r", entry)
            continue
        name, doms = entry.split("=", 1)
        doms = [d.strip().lower() for d in doms.split(",") if d.strip()]
        wanted[name.strip()] = doms
        for host in domains:
            if covers(doms, host):
                covered_by_wildcard.add(host)

    uncovered = sorted(domains - covered_by_wildcard)
    for host in uncovered:
        wanted[host] = [host]

    log.info("Soll: %d Zertifikat(e) — %d Domain(s) im Swarm, davon %d durch "
             "Wildcard abgedeckt", len(wanted), len(domains), len(covered_by_wildcard))
    for host in uncovered:
        log.info("  ohne Wildcard-Abdeckung: %s (aus %s)",
                 host, ", ".join(sorted(sources.get(host, {"?"}))))

    todo = []
    for name, doms in wanted.items():
        cur = inv.get(name)
        if cur is None:
            todo.append((name, doms, "fehlt"))
        elif cur["expiring"]:
            todo.append((name, doms, f"laeuft am {cur['enddate']} ab"))
        elif not all(covers(cur["names"], d.lstrip("*.")) or d in cur["names"] for d in doms):
            # Die Domainliste hat sich geaendert (z. B. ein Wildcard kam dazu).
            todo.append((name, doms, "Domainliste geaendert"))

    if not todo:
        log.info("nichts zu tun — %d Zertifikat(e) vorhanden und gueltig", len(inv))
        return

    # Zertifikate, die nichts mehr bedienen: nur melden, nicht loeschen.
    # Ein Dienst kann voruebergehend fehlen, und eine Neuausstellung zaehlt
    # gegen das Wochenkontingent.
    orphans = [n for n in inv if n not in wanted]
    if orphans:
        log.info("ohne zugehoerigen Dienst (bleiben bestehen, laufen aus): %s",
                 ", ".join(sorted(orphans)))

    issued = attempts = failures = consecutive = 0
    for name, doms, reason in todo:
        # Die Obergrenze zaehlt VERSUCHE, nicht Erfolge: Bei einem
        # systematischen Problem — falsches Token, kaputte DNS-Propagation —
        # schlaegt jeder Versuch fehl, und eine Erfolgszaehlung wuerde stur
        # alles abarbeiten. Let's Encrypt limitiert auch fehlgeschlagene
        # Validierungen.
        if attempts >= MAX_PER_RUN:
            log.info("%s aufgeschoben (%s) — Obergrenze von %d je Durchlauf erreicht",
                     name, reason, MAX_PER_RUN)
            continue
        # Zwei Fehlschlaege hintereinander sind kein Zufall.
        if consecutive >= 2:
            log.error("Abbruch: zwei Fehlschlaege in Folge — vermutlich ein "
                      "systematisches Problem (Token, DNS, Netz)")
            break

        attempts += 1
        log.info("%s: %s — wird ausgestellt (%s)", name, reason, ", ".join(doms))
        if run_lego(name, doms):
            issued += 1
            consecutive = 0
            log.info("%s ausgestellt", name)
        else:
            failures += 1
            consecutive += 1
            log.error("%s fehlgeschlagen", name)

    if issued and not DRY_RUN:
        # Die Nodes erkennen an dieser Datei, dass es etwas zu holen gibt.
        stamp = DIST / ".updated"
        stamp.write_text(now().strftime("%Y-%m-%dT%H:%M:%SZ") + "\n")
        stamp.chmod(0o644)

    log.info("Durchlauf beendet: %d versucht, %d ausgestellt, %d fehlgeschlagen",
             attempts, issued, failures)


# --- Ereignisse --------------------------------------------------------------
def watch_events(client):
    """Docker-Events als Ausloeser — nicht als Informationsquelle.

    Was passiert ist, interessiert nicht; der Abgleich ermittelt den
    Sollzustand ohnehin vollstaendig neu. Reisst der Stream ab, faengt der
    Timer den Fall auf.
    """
    while not _stop.is_set():
        try:
            for event in client.events(decode=True, filters={"type": "service"}):
                if _stop.is_set():
                    return
                if event.get("Action") in ("create", "update", "remove"):
                    name = (event.get("Actor", {}).get("Attributes", {}) or {}).get("name", "?")
                    log.info("Ereignis: Dienst %s %s", name, event["Action"])
                    _wake.set()
        except Exception as exc:
            if _stop.is_set():
                return
            log.warning("Ereignisstrom abgerissen (%s) — neuer Versuch in 30 s", exc)
            _stop.wait(30)


def main():
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: (_stop.set(), _wake.set()))

    log.info("gestartet — Swarm-API: %s", DOCKER_HOST)
    log.info("Wildcards: %s", "; ".join(WILDCARDS) or "(keine)")
    log.info("Schwelle: %d Tage · max %d Ausstellungen je Durchlauf · "
             "vollstaendiger Abgleich alle %d h",
             RENEW_BELOW_DAYS, MAX_PER_RUN, FULL_RECONCILE_SECONDS // 3600)
    if DRY_RUN:
        log.warning("PROBELAUF — es wird nichts ausgestellt")

    if not DRY_RUN and not os.access(TOKEN_FILE, os.R_OK):
        log.error("DNS-Token nicht lesbar: %s — ohne das kann lego keine "
                  "Challenge loesen. Ist das Secret dem Dienst zugewiesen?",
                  TOKEN_FILE)
        return 1
    os.environ.setdefault("CLOUDFLARE_DNS_API_TOKEN_FILE", TOKEN_FILE)

    client = docker.DockerClient(base_url=DOCKER_HOST)
    threading.Thread(target=watch_events, args=(client,), daemon=True).start()

    last_full = 0.0
    while not _stop.is_set():
        triggered = _wake.is_set()
        if triggered:
            # Ereignisse kommen in Schueben; ein Stack-Deploy erzeugt viele.
            # Kurz sammeln, dann einmal abgleichen statt je Dienst einmal.
            _stop.wait(DEBOUNCE_SECONDS)
            _wake.clear()

        try:
            reconcile(client)
        except Exception:
            # Ein Fehler beendet den Dienst BEWUSST nicht: Eine kaputte
            # DNS-Propagation ist kein Grund, die Erneuerung fuer alle
            # Zertifikate einzustellen.
            log.exception("Durchlauf fehlgeschlagen — naechster Versuch folgt")
        last_full = time.time()

        # Auf das naechste Ereignis warten, spaetestens bis zum Timer.
        while not _stop.is_set():
            if _wake.is_set():
                break
            if time.time() - last_full >= FULL_RECONCILE_SECONDS:
                log.info("Zeitgesteuerter Abgleich")
                break
            _stop.wait(5)

    log.info("beendet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
