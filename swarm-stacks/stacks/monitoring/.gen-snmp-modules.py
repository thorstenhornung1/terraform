#!/usr/bin/env python3
"""Erzeugt stacks/monitoring/snmp-modules.yml aus der offiziellen snmp.yml.

WARUM EIN GENERATOR
  Die offizielle snmp.yml des snmp_exporter ist 2 MB gross und spraengt damit
  das 500-KB-Limit fuer Docker Configs. Wir brauchen nur einen Bruchteil.
  Von Hand kopieren waere fehleranfaellig und beim naechsten Upstream-Release
  nicht nachvollziehbar — deshalb dieses Skript.

AUFRUF
  cd stacks/monitoring && python3 .gen-snmp-modules.py

  Laedt snmp.yml der unten gepinnten Version von GitHub (Cache in /tmp) und
  schreibt snmp-modules.yml. Danach committen; der GitOps-Workflow rollt die
  Datei als Docker Config aus.

WAS DAS SKRIPT AM UPSTREAM AENDERT — und warum
  Jede Abweichung steht unten als eigener Block mit Begruendung. Alle wurden
  am 2026-08-24 gegen die echte DS918+ (192.168.2.3, DSM 7.3-86003) verifiziert.
"""
import os
import re
import sys
import urllib.request

VERSION = "v0.30.1"  # muss zum image-Tag in monitoring-stack.yml passen
URL = f"https://raw.githubusercontent.com/prometheus/snmp_exporter/{VERSION}/snmp.yml"
CACHE = f"/tmp/snmp_exporter-{VERSION}-snmp.yml"
OUT = "snmp-modules.yml"

# ---------------------------------------------------------------------------
# 1. WELCHE MODULE
# ---------------------------------------------------------------------------
# Nur Module, die die DS918+ nachweislich befuellt. Geprueft wurde jedes
# einzeln gegen das Geraet (?module=<name> am laufenden Exporter):
#
#   Modul              Serien   Beitrag
#   synology            1104    Vendor-OIDs .1.3.6.1.4.1.6574 — Disk-Temperatur,
#                               Disk-/RAID-Status, Systemtemperatur, Luefter,
#                               SMART, Restlebensdauer der Cache-SSDs
#   if_mib               815    Netzwerkdurchsatz je Interface
#   hrStorage            139    Volume-Belegung, Swap, RAM als Storage-Sicht
#   hrDevice          getrimmt  CPU-Last je Kern, Geraetestatus (siehe unten)
#   ucd_system_stats      29    CPU-Verteilung als Counter
#   ucd_memory            22    RAM und Swap in KB
#   ucd_la_table           9    Load Average 1/5/15
#   hrSystem               7    Uptime, Prozesszahl
#   system                37    sysName/sysDescr/sysLocation
#
# NICHT aufgenommen:
#   ip_mib   Die DS918+ liefert darauf 0 PDUs — ipSystemStatsTable ist im
#            DSM-snmpd schlicht nicht implementiert. Ein Modul ohne Daten
#            kostet Scrape-Zeit und erzeugt ein Panel, das konstant leer
#            bleibt und wie ein Defekt aussieht.
MODULES = [
    "synology",
    "if_mib",
    "hrStorage",
    "hrDevice",
    "hrSystem",
    "system",
    "ucd_system_stats",
    "ucd_memory",
    "ucd_la_table",
]

# ---------------------------------------------------------------------------
# 2. max_repetitions: 10 fuer hrStorage und hrDevice
# ---------------------------------------------------------------------------
# BEFUND: Mit dem Default 25 schlaegt der Walk dieser beiden Module gegen die
# DS918+ IMMER fehl — "error walking target: request timeout (after 3 retries)",
# HTTP 500, keine einzige Serie.
#
# Es ist KEIN Timeout-Problem. Der Gegentest mit timeout: 20s und retries: 1
# lief 40 s und scheiterte genauso; mit max_repetitions: 10 kam die Antwort in
# unter einer Sekunde. Die GETBULK-Antwort bei 25 Repetitions ueberschreitet
# offenbar, was der DSM-snmpd bzw. der UDP-Pfad ausliefern kann, und geht
# verloren — die Retries laufen dann in dieselbe Wand.
#
# Deshalb NUR hier: synology und if_mib laufen bei 25 einwandfrei (1199 bzw.
# 881 PDUs in unter einer Sekunde), da waere eine Senkung nur langsamer.
MAX_REPETITIONS = {"hrStorage": 10, "hrDevice": 10}

# ---------------------------------------------------------------------------
# 3. hrDevice auf hrDeviceTable + hrProcessorTable eindampfen
# ---------------------------------------------------------------------------
# Ungetrimmt liefert hrDevice 647 Serien, davon rund 500 aus hrFSTable und
# hrPartitionTable: hrFSLastFullBackupDate, hrPartitionLabel und Aehnliches.
# Die Volume-Belegung steht bereits in hrStorage, und Backup-Zeitstempel
# pflegt DSM ohnehin nicht. Uebrig bleibt, was wirklich neu ist:
#   1.3.6.1.2.1.25.3.2  hrDeviceTable      — Status und Fehlerzaehler je Geraet
#   1.3.6.1.2.1.25.3.3  hrProcessorTable   — hrProcessorLoad je Kern
# Letzteres ist auf einem 4-Kern-Celeron der DS918+ wertvoll: Ein einzelner
# ausgelasteter Kern (btrfs-Scrub, Indexierung) faellt im Gesamtmittel nicht
# auf, blockiert aber spuerbar.
WALK_OVERRIDE = {"hrDevice": ["1.3.6.1.2.1.25.3.2", "1.3.6.1.2.1.25.3.3"]}

# ---------------------------------------------------------------------------
# 4. OctetString -> DisplayString fuer lesbare Labels
# ---------------------------------------------------------------------------
# BEFUND: Der Exporter rendert OctetString-Werte als Hex. Die Disks der
# Synology kamen dadurch als diskID="0x4469736B2031" statt "Disk 1" an —
# in einem Dashboard unbrauchbar, und in PromQL nicht rueckuebersetzbar.
# Die Bytes sind reiner ASCII-Text; DisplayString ist die korrekte Deklaration.
# Betrifft zwei Stellen:
#   - lookups:  labelname/oid/type-Tripel, das den Index nachschlaegt
#   - metrics:  Metriken, deren Wert selbst als Label ausgegeben wird
DISPLAYSTRING_LOOKUPS = {"diskID", "diskName", "diskRole", "diskType",
                         "hrFSMountPoint", "hrPartitionLabel"}
DISPLAYSTRING_METRICS = {"diskName", "diskRole", "diskType",
                         "hrFSMountPoint", "hrPartitionLabel", "hrPartitionID"}


def load_upstream():
    if not os.path.exists(CACHE):
        sys.stderr.write(f"lade {URL}\n")
        urllib.request.urlretrieve(URL, CACHE)
    return open(CACHE, encoding="utf-8").read().split("\n")


def module_blocks(lines):
    """Zerlegt den modules:-Abschnitt in {name: [zeilen]}."""
    start = lines.index("modules:")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*:\s*$", lines[i]):
            end = i
            break
    # Modulnamen duerfen Bindestriche enthalten (z. B. tplink-ddm) — fehlt der
    # im Muster, verschmilzt so ein Modul unbemerkt mit seinem Vorgaenger.
    heads = [(m.group(1), i) for i in range(start + 1, end)
             if (m := re.match(r"^  ([a-zA-Z_][a-zA-Z0-9_-]*):\s*$", lines[i]))]
    heads.append(("__END__", end))
    return {heads[j][0]: lines[heads[j][1]:heads[j + 1][1]]
            for j in range(len(heads) - 1)}


def patch_displaystring(block):
    n = 0
    for i, line in enumerate(block):
        m = re.match(r"^(\s+)labelname: (\S+)$", line)
        if m and m.group(2) in DISPLAYSTRING_LOOKUPS:
            if (i + 2 < len(block) and block[i + 1].strip().startswith("oid:")
                    and block[i + 2].strip() == "type: OctetString"):
                block[i + 2] = block[i + 2].replace("OctetString", "DisplayString")
                n += 1
            continue
        m = re.match(r"^(\s+)- name: (\S+)$", line)
        if m and m.group(2) in DISPLAYSTRING_METRICS:
            for k in range(i + 1, min(i + 5, len(block))):
                if block[k].strip() == "type: OctetString":
                    block[k] = block[k].replace("OctetString", "DisplayString")
                    n += 1
                    break
    return n


def trim_walk(block, name, oids):
    """Ersetzt die walk:-Liste und wirft Metriken ausserhalb der OIDs raus."""
    out, i = [], 0
    while i < len(block):
        line = block[i]
        if line.strip() == "walk:":
            out.append(line)
            out += [f"    - {o}" for o in oids]
            i += 1
            while i < len(block) and block[i].lstrip().startswith("- "):
                i += 1
            continue
        if line.strip() == "metrics:":
            out.append(line)
            i += 1
            # Metrikbloecke einzeln pruefen: behalten, wenn die oid passt.
            while i < len(block):
                if not re.match(r"^    - name: ", block[i]):
                    break
                j = i + 1
                while j < len(block) and not re.match(r"^    - name: ", block[j]):
                    j += 1
                chunk = block[i:j]
                oid = next((c.split("oid:", 1)[1].strip() for c in chunk
                            if c.strip().startswith("oid:")), "")
                if any(oid == o or oid.startswith(o + ".") for o in oids):
                    out += chunk
                i = j
            continue
        out.append(line)
        i += 1
    return out


def main():
    lines = load_upstream()
    blocks = module_blocks(lines)
    missing = [m for m in MODULES if m not in blocks]
    if missing:
        sys.exit(f"Module fehlen in {VERSION}: {missing}")

    result, stats = ["modules:"], []
    for name in MODULES:
        block = blocks[name][:]
        while block and not block[-1].strip():
            block.pop()
        if name in WALK_OVERRIDE:
            block = trim_walk(block, name, WALK_OVERRIDE[name])
        patched = patch_displaystring(block)
        if name in MAX_REPETITIONS:
            block.insert(1, f"    max_repetitions: {MAX_REPETITIONS[name]}")
        result += block
        stats.append((name, len(block),
                      sum(1 for l in block if re.match(r"^    - name: ", l)), patched))

    text = "\n".join(result) + "\n"

    # Gegenprobe: Die Metriknamen der Module duerfen sich NICHT ueberschneiden.
    # Der Scrape-Job fragt alle in EINEM Request ab; der Exporter haengt die
    # Ergebnisse ohne unterscheidendes Label aneinander, und Prometheus weist
    # doppelte Serien als Scrape-Fehler zurueck. Ohne diese Pruefung faellt so
    # etwas erst im Betrieb auf — als up=0 ohne erkennbaren Grund.
    seen, dupes = {}, []
    for name in MODULES:
        block = blocks[name]
        for line in block:
            m = re.match(r"^    - name: (\S+)$", line)
            if not m:
                continue
            other = seen.setdefault(m.group(1), name)
            if other != name:
                dupes.append((m.group(1), other, name))
    if dupes:
        sys.exit(f"ABBRUCH — Metriknamen doppelt: {dupes}")

    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)

    print(f"{OUT} geschrieben — {len(text)} Bytes "
          f"(Limit fuer Docker Configs: 500 KB)")
    for name, nlines, nmetrics, npatched in stats:
        extra = []
        if name in MAX_REPETITIONS:
            extra.append(f"max_repetitions={MAX_REPETITIONS[name]}")
        if name in WALK_OVERRIDE:
            extra.append("walk getrimmt")
        if npatched:
            extra.append(f"{npatched}x DisplayString")
        print(f"  {name:18s} {nmetrics:4d} Metriken  {nlines:5d} Zeilen"
              f"  {', '.join(extra)}")
    if len(text) > 500_000:
        sys.exit("ABBRUCH — ueber dem 500-KB-Limit fuer Docker Configs")


if __name__ == "__main__":
    main()
