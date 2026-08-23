#!/usr/bin/env python3
"""
Tests fuer die beiden Funktionen, an denen alles haengt.

WARUM GERADE DIESE ZWEI
    extract_hosts() und covers() entscheiden, welche Zertifikate bestellt
    werden. Ein Fehler dort faellt nicht beim Deploy auf, sondern erst, wenn
    ein Browser das falsche Zertifikat bekommt — und bei covers() im
    schlimmsten Fall nie, weil zu viel bestellt wird und alles funktioniert
    (nur das Wochenkontingent von Let's Encrypt schmilzt).

    Der Rest des Controllers ist Orchestrierung um lego und die Docker-API;
    den zu testen hiesse, Mocks zu testen.

    Ausfuehren:  python3 test_cert_controller.py
"""

import importlib.util
import os
import sys
import types
from pathlib import Path

os.environ.setdefault("ACME_EMAIL", "test@example.invalid")
# Das docker-SDK ist fuer die getesteten Funktionen nicht noetig.
sys.modules.setdefault("docker", types.SimpleNamespace(DockerClient=lambda **kw: None))

spec = importlib.util.spec_from_file_location(
    "cc", Path(__file__).with_name("cert_controller.py"))
cc = importlib.util.module_from_spec(spec)
sys.modules["cc"] = cc
spec.loader.exec_module(cc)

FAILS = []


def check(desc, got, want):
    if got == want:
        print(f"  ok   {desc}")
    else:
        print(f"  FAIL {desc}\n         erwartet: {want!r}\n         erhalten: {got!r}")
        FAILS.append(desc)


def test_extract_hosts():
    print("extract_hosts — Router-Regeln parsen")
    check("einfache Regel", cc.extract_hosts("Host(`grafana.hornung-bn.de`)"),
          {"grafana.hornung-bn.de"})
    check("zwei Hosts in einem Host()", cc.extract_hosts("Host(`a.de`, `b.de`)"),
          {"a.de", "b.de"})
    check("ODER-Verknuepfung", cc.extract_hosts("Host(`a.de`) || Host(`b.de`)"),
          {"a.de", "b.de"})
    check("mit PathPrefix", cc.extract_hosts("Host(`a.de`) && PathPrefix(`/api`)"),
          {"a.de"})
    check("doppelte Anfuehrungszeichen", cc.extract_hosts('Host("a.de")'), {"a.de"})
    check("Grossschreibung wird normalisiert",
          cc.extract_hosts("Host(`GRAFANA.Hornung-BN.de`)"), {"grafana.hornung-bn.de"})
    check("Punkt am Ende wird entfernt", cc.extract_hosts("Host(`a.de.`)"), {"a.de"})
    # HostRegexp bewusst nicht ausgewertet: Aus einem regulaeren Ausdruck laesst
    # sich keine Domainliste ableiten, ohne zu raten.
    check("HostRegexp liefert nichts", cc.extract_hosts("HostRegexp(`{s:[a-z]+}.de`)"), set())
    check("Regel ohne Host", cc.extract_hosts("PathPrefix(`/x`)"), set())
    check("zwei Sub-Ebenen", cc.extract_hosts("Host(`admin.frigate.hornung-bn.de`)"),
          {"admin.frigate.hornung-bn.de"})


def test_covers():
    print("\ncovers — ein Wildcard gilt fuer GENAU EINE Ebene")
    wc = ["*.hornung-bn.de", "hornung-bn.de"]
    check("eine Ebene abgedeckt", cc.covers(wc, "grafana.hornung-bn.de"), True)
    check("Zone selbst abgedeckt (steht separat drin)", cc.covers(wc, "hornung-bn.de"), True)
    # Das ist die Regel, die beim Entwurf am haeufigsten uebersehen wird.
    check("ZWEI Ebenen NICHT abgedeckt", cc.covers(wc, "admin.frigate.hornung-bn.de"), False)
    check("fremde Zone nicht abgedeckt", cc.covers(wc, "grafana.example.com"), False)
    # Ohne die Punktpruefung wuerde endswith() hier faelschlich greifen.
    check("Teilstring-Falle", cc.covers(wc, "boesehornung-bn.de"), False)
    check("exakter Treffer ohne Wildcard", cc.covers(["a.de"], "a.de"), True)
    check("Sub-Wildcard deckt die zweite Ebene",
          cc.covers(["*.frigate.hornung-bn.de"], "admin.frigate.hornung-bn.de"), True)
    check("Sub-Wildcard deckt die erste Ebene NICHT",
          cc.covers(["*.frigate.hornung-bn.de"], "frigate.hornung-bn.de"), False)


def test_lego_dateiname():
    """lego benennt nach der ersten Domain, mit '*' -> '_'.

    Der Test haelt fest, was die erste Ausstellung von
    mail.test.hornung-bn.de zum Scheitern brachte: lego schreibt pro
    Zertifikat ZWEI .crt-Dateien — die Kette und <name>.issuer.crt. Wer die
    neueste *.crt im Verzeichnis nimmt, erwischt womoeglich die zweite und
    sucht dann vergeblich nach <name>.issuer.key.
    """
    print("\nlego-Dateiname aus der ersten Domain ableiten")
    check("normale Domain", "mail.test.hornung-bn.de".replace("*", "_"),
          "mail.test.hornung-bn.de")
    check("Wildcard: Stern wird Unterstrich", "*.hornung-bn.de".replace("*", "_"),
          "_.hornung-bn.de")


def test_bestand():
    print("\nRealdaten aus dem Bestand (Stand 2026-08-23)")
    wc = ["*.hornung-bn.de", "hornung-bn.de"]
    einstufig = ["abo", "archive", "assets", "auth", "dns", "grafana", "n8n", "paperless",
                 "paperless-ai", "paperlessai", "photos", "portainer", "rag", "rag2",
                 "reisekosten", "reisekosten-test", "rescue", "rescue-grafana", "steuer",
                 "taiga", "test", "traefik", "uptime", "vault", "webhook", "frigate",
                 "rag-empirical"]
    covered = [d for d in einstufig if cc.covers(wc, f"{d}.hornung-bn.de")]
    check(f"alle {len(einstufig)} einstufigen Domains abgedeckt",
          len(covered), len(einstufig))
    zweistufig = ["admin.frigate.hornung-bn.de", "frigate.beta.hornung-bn.de",
                  "mail.test.hornung-bn.de"]
    uncovered = [d for d in zweistufig if not cc.covers(wc, d)]
    check("alle 3 zweistufigen brauchen ein eigenes Zertifikat", len(uncovered), 3)


if __name__ == "__main__":
    test_extract_hosts()
    test_covers()
    test_lego_dateiname()
    test_bestand()
    print()
    if FAILS:
        print(f"{len(FAILS)} Test(s) fehlgeschlagen: {', '.join(FAILS)}")
        sys.exit(1)
    print("alle Tests bestanden")
