#!/usr/bin/env python3
"""Erzeugt dashboards/synology-nas.json.

Aufruf aus stacks/monitoring/:  python3 dashboards/.gen-synology-nas.py

Quelle aller Metriken ist der Scrape-Job snmp-synology (siehe
prometheus-scrape.yml) gegen den snmp-exporter im selben Stack.

WAS BEIM SCHREIBEN DER ABFRAGEN ZU BEACHTEN WAR
  Die Fallstricke stehen jeweils als description am Panel, damit sie beim
  Weiterbauen im UI sichtbar sind und nicht nur hier im Generator. Die
  wichtigsten in Kurzform:

  hrSystemUptime, NICHT sysUpTime
      sysUpTime ist die Laufzeit des snmpd, nicht des Geraets. Nach der
      SNMP-Umkonfiguration am 2026-08-24 stand sysUpTime bei 13 Minuten,
      waehrend das NAS seit 23 Stunden lief. Ein Uptime-Panel auf sysUpTime
      meldet jede Aenderung an den SNMP-Einstellungen als Neustart.

  hrStorage: nur / und /volume1
      Die DS918+ meldet 39 Dateisysteme, aber rund 30 davon sind
      Bind-Mounts derselben btrfs-Dateisysteme unter
      /volume1/@appdata/ContainerManager/all_shares/*. Sie tragen alle
      identische Groesse und Belegung. Ohne Filter zeigt das Panel 30-mal
      dieselbe Zahl.

  Speicher ohne Puffer und Cache rechnen
      memAvailReal allein sind hier 145 MB von 11,5 GB. Wer daraus die
      Belegung bildet, bekommt 98,8 % und einen Daueralarm. Puffer und
      Cache gehoeren abgezogen; dann sind es realistische 54 %.

  ssCpuRawGuest gehoert NICHT in den Nenner
      Unter Linux ist Guest-Zeit bereits in ssCpuRawUser enthalten. Die
      Gegenprobe: Ohne Guest ergeben die Zaehler 23,0 h Laufzeit und
      decken sich mit hrSystemUptime (23,2 h); mit Guest kaeme man auf
      23,8 h — mehr, als das Geraet ueberhaupt laeuft.

  diskRemainLife >= 0 filtern
      Festplatten melden -1 (nicht anwendbar), nur die beiden Cache-SSDs
      liefern echte Prozentwerte. Ein min() ohne Filter zeigt -1.

  Nur eth1 als Durchsatz
      eth1 ist die einzige aktive physische Schnittstelle. ovs_bond0 ist
      die OVS-Bruecke darueber und zeigt denselben Verkehr ein zweites
      Mal — beides zu summieren zaehlt doppelt.

  rate() mit [10m]
      Der Scrape laeuft alle 120 s. Ein kuerzeres Fenster enthaelt zu
      wenige Punkte, und der Ausdruck liefert dann stumm nichts.
"""
import json
import os

DS = {"type": "prometheus", "uid": "victoriametrics"}
J = 'job="snmp-synology"'

# ---------------------------------------------------------------------------
# CPU-Nenner: Summe aller Verbrauchsarten.
# ssCpuRawGuest/GuestNice fehlen absichtlich (in User enthalten, siehe oben),
# ssCpuRawKernel ebenfalls — den fuellt Linux nicht, dort steht System.
CPU_PARTS = ["Idle", "User", "System", "Nice", "Wait", "SoftIRQ",
             "Interrupt", "Steal"]
CPU_DENOM = " + ".join(f'rate(ssCpuRaw{p}{{{J}}}[10m])' for p in CPU_PARTS)

# Synology-MIB-Statuswerte. Die Zahlen sind nur ueber die MIB lesbar, deshalb
# haengt an jedem Statuspanel eine Wertzuordnung — Farbe allein waere weder
# barrierefrei noch eindeutig.
NORMAL_FAILED = [{"options": {"1": {"text": "Normal", "color": "green", "index": 0},
                              "2": {"text": "Ausgefallen", "color": "red", "index": 1}},
                  "type": "value"}]
DISK_STATUS = [{"options": {
    "1": {"text": "Normal", "color": "green", "index": 0},
    "2": {"text": "Initialisiert", "color": "green", "index": 1},
    "3": {"text": "Nicht initialisiert", "color": "yellow", "index": 2},
    "4": {"text": "Systempartition defekt", "color": "red", "index": 3},
    "5": {"text": "Abgestuerzt", "color": "red", "index": 4}}, "type": "value"}]
DISK_HEALTH = [{"options": {
    "1": {"text": "Normal", "color": "green", "index": 0},
    "2": {"text": "Warnung", "color": "yellow", "index": 1},
    "3": {"text": "Kritisch", "color": "red", "index": 2},
    "4": {"text": "Versagend", "color": "red", "index": 3}}, "type": "value"}]
# Nur die Zustaende, die im Alltag vorkommen, sind einzeln benannt. Alles
# ueber 10 ist bei Synology Degrade/Crashed und faerbt rot.
RAID_STATUS = [{"options": {
    "1": {"text": "Normal", "color": "green", "index": 0},
    "2": {"text": "Reparatur laeuft", "color": "yellow", "index": 1},
    "3": {"text": "Migration laeuft", "color": "yellow", "index": 2},
    "4": {"text": "Erweiterung laeuft", "color": "yellow", "index": 3},
    "5": {"text": "Wird geloescht", "color": "yellow", "index": 4},
    "6": {"text": "Wird erstellt", "color": "yellow", "index": 5},
    "7": {"text": "RAID-Sync laeuft", "color": "yellow", "index": 6},
    "8": {"text": "Paritaetspruefung", "color": "yellow", "index": 7},
    "11": {"text": "Degradiert", "color": "red", "index": 8},
    "12": {"text": "Abgestuerzt", "color": "red", "index": 9},
    "13": {"text": "Data-Scrubbing", "color": "yellow", "index": 10}},
    "type": "value"}]
UPGRADE = [{"options": {
    "1": {"text": "Update verfuegbar", "color": "yellow", "index": 0},
    "2": {"text": "Aktuell", "color": "green", "index": 1},
    "3": {"text": "Prueft", "color": "text", "index": 2},
    "4": {"text": "Nicht verbunden", "color": "text", "index": 3},
    "5": {"text": "Unbekannt", "color": "text", "index": 4}}, "type": "value"}]
IF_OPER = [{"options": {
    "1": {"text": "up", "color": "green", "index": 0},
    "2": {"text": "down", "color": "red", "index": 1},
    "3": {"text": "testing", "color": "yellow", "index": 2},
    "4": {"text": "unbekannt", "color": "text", "index": 3},
    "5": {"text": "ruhend", "color": "text", "index": 4},
    "6": {"text": "nicht vorhanden", "color": "text", "index": 5},
    "7": {"text": "Link fehlt", "color": "yellow", "index": 6}}, "type": "value"}]

pid = [0]


def nid():
    pid[0] += 1
    return pid[0]


def tgt(expr, legend="", instant=False, fmt="time_series", ref="A"):
    return {"datasource": DS, "editorMode": "code", "expr": expr,
            "legendFormat": legend, "range": not instant, "instant": instant,
            "format": fmt, "refId": ref}


def stat(title, expr, gp, unit="none", dec=0, thresholds=None, mappings=None,
         text_mode="value", color_mode="value", legend="", graph=False, desc=None):
    p = {
        "id": nid(), "type": "stat", "title": title, "datasource": DS, "gridPos": gp,
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec, "mappings": mappings or [],
            "thresholds": {"mode": "absolute",
                           "steps": thresholds or [{"color": "text", "value": None}]},
            "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"colorMode": color_mode, "graphMode": "area" if graph else "none",
                    "justifyMode": "auto", "orientation": "auto",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "",
                                      "values": False},
                    "textMode": text_mode, "wideLayout": True},
        # graph=True zeichnet einen Sparkline-Hintergrund. Der braucht einen
        # Verlauf — mit instant=True liefert die Datenquelle nur einen einzigen
        # Punkt, und die Flaeche bleibt leer, ohne dass das Panel einen Fehler
        # zeigt. Deshalb nur dort instant, wo gar keine Kurve gezeichnet wird.
        "targets": [tgt(expr, legend, instant=not graph)],
    }
    if desc:
        p["description"] = desc
    return p


def ts(title, targets, gp, unit="short", dec=1, minv=None, maxv=None, stack=False,
       fill=8, desc=None, legend_calcs=None, width=1):
    p = {
        "id": nid(), "type": "timeseries", "title": title, "datasource": DS,
        "gridPos": gp,
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec,
            "custom": {"drawStyle": "line", "lineWidth": width, "fillOpacity": fill,
                       "gradientMode": "opacity", "showPoints": "never",
                       "spanNulls": 600000, "pointSize": 4,
                       "stacking": {"mode": "normal" if stack else "none",
                                    "group": "A"},
                       "axisPlacement": "auto",
                       "scaleDistribution": {"type": "linear"}},
            "thresholds": {"mode": "absolute", "steps": [{"color": "green",
                                                          "value": None}]},
            "color": {"mode": "palette-classic"}, "mappings": []}, "overrides": []},
        "options": {"legend": {"calcs": legend_calcs or ["mean", "max", "lastNotNull"],
                               "displayMode": "table", "placement": "right",
                               "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "targets": targets,
    }
    if minv is not None:
        p["fieldConfig"]["defaults"]["min"] = minv
    if maxv is not None:
        p["fieldConfig"]["defaults"]["max"] = maxv
    if desc:
        p["description"] = desc
    return p


def bargauge(title, expr, gp, legend="", unit="percent", dec=1, thresholds=None,
             maxv=100, desc=None):
    p = {
        "id": nid(), "type": "bargauge", "title": title, "datasource": DS,
        "gridPos": gp,
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec, "min": 0, "max": maxv, "mappings": [],
            "thresholds": {"mode": "absolute",
                           "steps": thresholds or [{"color": "green", "value": None}]},
            "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"displayMode": "gradient", "orientation": "horizontal",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "",
                                      "values": False},
                    "showUnfilled": True, "valueMode": "color", "minVizHeight": 16,
                    "minVizWidth": 8, "namePlacement": "auto", "sizing": "auto"},
        "targets": [tgt(expr, legend, instant=True)],
    }
    if desc:
        p["description"] = desc
    return p


def table(title, targets, gp, transformations, overrides=None, desc=None):
    p = {
        "id": nid(), "type": "table", "title": title, "datasource": DS, "gridPos": gp,
        "fieldConfig": {"defaults": {
            "custom": {"align": "auto", "cellOptions": {"type": "auto"},
                       "inspect": False, "filterable": False},
            "mappings": [],
            "thresholds": {"mode": "absolute",
                           "steps": [{"color": "text", "value": None}]},
            "color": {"mode": "thresholds"}}, "overrides": overrides or []},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "footer": {"show": False, "countRows": False, "reducer": ["sum"],
                               "fields": []}},
        "targets": targets, "transformations": transformations,
    }
    if desc:
        p["description"] = desc
    return p


def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def hide(names):
    return {"id": "organize", "options": {
        "excludeByName": {n: True for n in names}, "renameByName": {}}}


panels = []

# =========================================================== Ueberblick
panels.append(row("Überblick", 0))
Y = 1

panels.append(stat(
    "Systemzustand", f"systemStatus{{{J}}}", {"h": 4, "w": 3, "x": 0, "y": Y},
    mappings=NORMAL_FAILED, color_mode="background",
    thresholds=[{"color": "green", "value": None}],
    desc="Sammelmeldung der DS918+ aus der Synology-MIB (.1.3.6.1.4.1.6574.1.1). "
         "Deckt Netzteil, Luefter und Platten ab — die Einzelwerte stehen in der "
         "Zeile darunter."))

panels.append(stat(
    "Volume-Belegung",
    f'100 * hrStorageUsed{{{J},hrStorageDescr="/volume1"}}'
    f' / hrStorageSize{{{J},hrStorageDescr="/volume1"}}',
    {"h": 4, "w": 3, "x": 3, "y": Y}, unit="percent", dec=1, graph=True,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 80},
                {"color": "red", "value": 90}],
    desc="Belegung von /volume1. Prozent aus hrStorageUsed/hrStorageSize — die "
         "Allokationseinheit kuerzt sich dabei heraus, deshalb steht sie hier "
         "nicht im Ausdruck. Fuer absolute Werte MUSS mit "
         "hrStorageAllocationUnits (16384 Byte) multipliziert werden."))

panels.append(stat(
    "Frei auf /volume1",
    f'(hrStorageSize{{{J},hrStorageDescr="/volume1"}}'
    f' - hrStorageUsed{{{J},hrStorageDescr="/volume1"}})'
    f' * hrStorageAllocationUnits{{{J},hrStorageDescr="/volume1"}}',
    {"h": 4, "w": 3, "x": 6, "y": Y}, unit="bytes", dec=2, graph=True,
    thresholds=[{"color": "red", "value": None},
                {"color": "yellow", "value": 1.5e12},
                {"color": "green", "value": 3e12}],
    desc="Freier Platz in Byte. Schwellen: unter 3 TB gelb, unter 1,5 TB rot."))

panels.append(stat(
    "Systemtemperatur", f"temperature{{{J}}}", {"h": 4, "w": 3, "x": 9, "y": Y},
    unit="celsius", graph=True,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 55},
                {"color": "red", "value": 65}]))

panels.append(stat(
    "Wärmste Platte", f"max(diskTemperature{{{J}}})",
    {"h": 4, "w": 3, "x": 12, "y": Y}, unit="celsius", graph=True,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 45},
                {"color": "red", "value": 55}],
    desc="Hoechster Wert ueber alle Platten und Cache-SSDs. Seagate gibt fuer "
         "IronWolf 5-70 °C an; ab 45 °C lohnt ein Blick auf die Luefter."))

panels.append(stat(
    "CPU", f"100 * (1 - rate(ssCpuRawIdle{{{J}}}[10m]) / ({CPU_DENOM}))",
    {"h": 4, "w": 3, "x": 15, "y": Y}, unit="percent", dec=1, graph=True,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 70},
                {"color": "red", "value": 90}],
    desc="Ausgelastete Zeit ueber alle vier Kerne, aus den Rohzaehlern der "
         "UCD-MIB. ssCpuRawGuest steht bewusst NICHT im Nenner — Linux zaehlt "
         "Guest-Zeit bereits in ssCpuRawUser mit, doppelt gerechnet ergaebe "
         "sich mehr Laufzeit, als das Geraet an ist."))

panels.append(stat(
    "RAM belegt",
    f"100 * (memTotalReal{{{J}}} - memAvailReal{{{J}}} - memBuffer{{{J}}}"
    f" - memCached{{{J}}}) / memTotalReal{{{J}}}",
    {"h": 4, "w": 3, "x": 18, "y": Y}, unit="percent", dec=1, graph=True,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 85},
                {"color": "red", "value": 95}],
    desc="Ohne Puffer und Cache gerechnet. memAvailReal allein sind auf diesem "
         "Geraet rund 145 MB von 11,5 GB — daraus gebildet ergaebe sich 98,8 % "
         "und ein Daueralarm, obwohl der Speicher nur als Cache belegt ist."))

panels.append(stat(
    "Laufzeit", f"hrSystemUptime{{{J}}} / 100", {"h": 4, "w": 3, "x": 21, "y": Y},
    unit="s", color_mode="none",
    desc="hrSystemUptime in Hundertstelsekunden, deshalb /100. Bewusst NICHT "
         "sysUpTime: Das ist die Laufzeit des SNMP-Dienstes. Nach dem Umstellen "
         "der SNMP-Einstellungen am 2026-08-24 stand sysUpTime bei 13 Minuten, "
         "waehrend das NAS seit 23 Stunden lief."))

# =========================================================== Zustandsmeldungen
Y = 5
panels.append(row("Zustandsmeldungen", Y))
Y = 6

panels.append(stat("Netzteil", f"powerStatus{{{J}}}", {"h": 4, "w": 3, "x": 0, "y": Y},
                   mappings=NORMAL_FAILED, color_mode="background",
                   thresholds=[{"color": "green", "value": None}]))
panels.append(stat("Systemlüfter", f"systemFanStatus{{{J}}}",
                   {"h": 4, "w": 3, "x": 3, "y": Y}, mappings=NORMAL_FAILED,
                   color_mode="background",
                   thresholds=[{"color": "green", "value": None}]))
panels.append(stat("CPU-Lüfter", f"cpuFanStatus{{{J}}}",
                   {"h": 4, "w": 3, "x": 6, "y": Y}, mappings=NORMAL_FAILED,
                   color_mode="background",
                   thresholds=[{"color": "green", "value": None}]))

panels.append(stat(
    "RAID-Zustand", f"max(raidStatus{{{J}}})", {"h": 4, "w": 4, "x": 9, "y": Y},
    mappings=RAID_STATUS, color_mode="background",
    thresholds=[{"color": "green", "value": None}],
    desc="Schlechtester Zustand ueber Storage Pool 1 und Volume 1. max() statt "
         "min(), weil in der Synology-MIB 1 = Normal ist und alles Groessere "
         "einen Sonderzustand beschreibt."))

panels.append(stat(
    "Platten nicht Normal", f"count(diskStatus{{{J}}} != 1) or vector(0)",
    {"h": 4, "w": 3, "x": 13, "y": Y},
    thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
    desc="count() liefert bei lauter gesunden Platten gar keine Zeitreihe — das "
         "Panel stuende dann auf 'No data' statt auf 0. Das or vector(0) faengt "
         "genau diesen Fall ab. Beide Zweige sind labelfrei, koennen sich also "
         "nicht zu zwei Serien aufspalten."))

panels.append(stat(
    "DSM-Update", f"upgradeAvailable{{{J}}}", {"h": 4, "w": 4, "x": 16, "y": Y},
    mappings=UPGRADE, color_mode="background",
    thresholds=[{"color": "text", "value": None}],
    desc="2 heisst 'kein Update verfuegbar', nicht '2 Updates'. Eine Schwelle "
         "der Form > 0 wuerde hier dauerhaft anschlagen."))

panels.append(stat(
    "Letzte SNMP-Daten", f"time() - timestamp(systemStatus{{{J}}})",
    {"h": 4, "w": 4, "x": 20, "y": Y}, unit="s",
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 400},
                {"color": "red", "value": 900}],
    desc="Alter des letzten Messwerts. Der Scrape laeuft alle 120 s. Steigt der "
         "Wert, antwortet entweder die Synology nicht mehr oder der "
         "snmp-exporter sammelt nicht."))

# =========================================================== Speicher
Y = 10
panels.append(row("Speicher", Y))
Y = 11

panels.append(bargauge(
    "Belegung je Dateisystem",
    f'100 * hrStorageUsed{{{J},hrStorageDescr=~"/|/volume[0-9]+"}}'
    f' / hrStorageSize{{{J},hrStorageDescr=~"/|/volume[0-9]+"}}',
    {"h": 7, "w": 8, "x": 0, "y": Y}, legend="{{hrStorageDescr}}",
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 80},
                {"color": "red", "value": 90}],
    desc="Nur die echten Dateisysteme. Die DS918+ meldet 39 Eintraege, davon "
         "rund 30 Bind-Mounts derselben btrfs-Dateisysteme unter "
         "/volume1/@appdata/ContainerManager/all_shares/*. Die tragen alle "
         "identische Zahlen — ungefiltert stuende hier 30-mal derselbe Balken. "
         "Der Regex ist in PromQL vollstaendig verankert, '/volume1' trifft "
         "deshalb nicht die Unterpfade."))

panels.append(ts(
    "/volume1 — belegt und Gesamtgröße", [
        tgt(f'hrStorageUsed{{{J},hrStorageDescr="/volume1"}}'
            f' * hrStorageAllocationUnits{{{J},hrStorageDescr="/volume1"}}',
            "belegt"),
        tgt(f'hrStorageSize{{{J},hrStorageDescr="/volume1"}}'
            f' * hrStorageAllocationUnits{{{J},hrStorageDescr="/volume1"}}',
            "Gesamtgröße", ref="B")],
    {"h": 7, "w": 8, "x": 8, "y": Y}, unit="bytes", dec=2, minv=0, fill=6,
    desc="Absolute Werte, deshalb mit hrStorageAllocationUnits (16384 Byte) "
         "multipliziert. Die drei Metriken tragen identische Labels, die "
         "Multiplikation findet ihre Partner also ohne on()/group_left."))

panels.append(table(
    "Speicherpool und Volume", [
        tgt(f"raidStatus{{{J}}}", instant=True, fmt="table", ref="A"),
        tgt(f"raidTotalSize{{{J}}}", instant=True, fmt="table", ref="B"),
        tgt(f"raidFreeSize{{{J}}}", instant=True, fmt="table", ref="C"),
    ],
    {"h": 7, "w": 8, "x": 16, "y": Y},
    [{"id": "joinByField", "options": {"byField": "raidName", "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": {k: True for k in
                           ["Time", "Time 1", "Time 2", "Time 3", "instance",
                            "instance 1", "instance 2", "instance 3", "job",
                            "job 1", "job 2", "job 3", "device", "device 1",
                            "device 2", "device 3"]},
         "renameByName": {"raidName": "Einheit", "Value #A": "Zustand",
                          "Value #B": "Gesamt", "Value #C": "Frei"}}}],
    overrides=[
        {"matcher": {"id": "byName", "options": "Zustand"},
         "properties": [{"id": "mappings", "value": RAID_STATUS},
                        {"id": "custom.cellOptions",
                         "value": {"type": "color-text"}}]},
        {"matcher": {"id": "byName", "options": "Gesamt"},
         "properties": [{"id": "unit", "value": "bytes"},
                        {"id": "decimals", "value": 2}]},
        {"matcher": {"id": "byName", "options": "Frei"},
         "properties": [{"id": "unit", "value": "bytes"},
                        {"id": "decimals", "value": 2}]}],
    desc="Storage Pool 1 zeigt hier nur rund 197 MB frei — das ist KEIN "
         "Warnzeichen. Der Pool ist vollstaendig an Volume 1 vergeben; freier "
         "Platz entsteht dort und nicht im Pool. Eine Belegungswarnung darf "
         "deshalb nur auf das Volume schauen."))

# =========================================================== Platten
Y = 18
panels.append(row("Platten", Y))
Y = 19

panels.append(ts(
    "Plattentemperaturen", [tgt(f"diskTemperature{{{J}}}", "{{diskID}}")],
    {"h": 8, "w": 12, "x": 0, "y": Y}, unit="celsius", dec=0, fill=0, minv=20,
    legend_calcs=["min", "mean", "max", "lastNotNull"], width=2,
    desc="Die Bezeichner kommen nur lesbar an, weil die Moduldatei den "
         "diskID-Lookup als DisplayString deklariert. Mit der Upstream-Vorgabe "
         "OctetString stuende hier diskID=\"0x4469736B2031\"."))

panels.append(table(
    "Plattenzustand", [
        tgt(f"diskStatus{{{J}}}", instant=True, fmt="table", ref="A"),
        tgt(f"diskHealthStatus{{{J}}}", instant=True, fmt="table", ref="B"),
        tgt(f"diskTemperature{{{J}}}", instant=True, fmt="table", ref="C"),
        tgt(f"diskRemainLife{{{J}}} >= 0", instant=True, fmt="table", ref="D"),
        tgt(f"diskModel{{{J}}}", instant=True, fmt="table", ref="E"),
    ],
    {"h": 8, "w": 12, "x": 12, "y": Y},
    [{"id": "joinByField", "options": {"byField": "diskID", "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": {k: True for k in
                           ["Time", "Time 1", "Time 2", "Time 3", "Time 4",
                            "Time 5", "instance", "instance 1", "instance 2",
                            "instance 3", "instance 4", "instance 5", "job",
                            "job 1", "job 2", "job 3", "job 4", "job 5",
                            "device", "device 1", "device 2", "device 3",
                            "device 4", "device 5", "Value #E"]},
         "renameByName": {"diskID": "Platte", "Value #A": "Status",
                          "Value #B": "Gesundheit", "Value #C": "Temperatur",
                          "Value #D": "Restlebensdauer", "diskModel": "Modell"}}}],
    overrides=[
        {"matcher": {"id": "byName", "options": "Status"},
         "properties": [{"id": "mappings", "value": DISK_STATUS},
                        {"id": "custom.cellOptions",
                         "value": {"type": "color-text"}}]},
        {"matcher": {"id": "byName", "options": "Gesundheit"},
         "properties": [{"id": "mappings", "value": DISK_HEALTH},
                        {"id": "custom.cellOptions",
                         "value": {"type": "color-text"}}]},
        {"matcher": {"id": "byName", "options": "Temperatur"},
         "properties": [{"id": "unit", "value": "celsius"},
                        {"id": "decimals", "value": 0}]},
        {"matcher": {"id": "byName", "options": "Restlebensdauer"},
         "properties": [
             {"id": "unit", "value": "percent"},
             {"id": "decimals", "value": 0},
             {"id": "max", "value": 100},
             {"id": "min", "value": 0},
             {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}},
             {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                 {"color": "red", "value": None},
                 {"color": "yellow", "value": 20},
                 {"color": "green", "value": 50}]}}]}],
    desc="Restlebensdauer liefern nur die beiden NVMe-Cache-SSDs. Festplatten "
         "melden -1 im Sinne von 'nicht anwendbar'; der Filter >= 0 laesst "
         "deren Zelle deshalb leer, statt -1 als Messwert auszugeben."))

# =========================================================== CPU / Last / RAM
Y = 27
panels.append(row("CPU, Last und Speicher", Y))
Y = 28

panels.append(ts(
    "CPU-Verteilung", [
        tgt(f"100 * rate(ssCpuRawUser{{{J}}}[10m]) / ({CPU_DENOM})", "Anwendung"),
        tgt(f"100 * rate(ssCpuRawSystem{{{J}}}[10m]) / ({CPU_DENOM})", "System",
            ref="B"),
        tgt(f"100 * rate(ssCpuRawWait{{{J}}}[10m]) / ({CPU_DENOM})", "E/A-Wartezeit",
            ref="C"),
        tgt(f"100 * rate(ssCpuRawNice{{{J}}}[10m]) / ({CPU_DENOM})", "Nice", ref="D"),
        tgt(f"100 * rate(ssCpuRawSoftIRQ{{{J}}}[10m]) / ({CPU_DENOM})", "SoftIRQ",
            ref="E"),
    ],
    {"h": 7, "w": 8, "x": 0, "y": Y}, unit="percent", dec=1, minv=0, maxv=100,
    stack=True, fill=25,
    desc="Gestapelt; die Leerlaufzeit fehlt absichtlich, damit die Hoehe des "
         "Stapels direkt die Auslastung zeigt. E/A-Wartezeit ist auf einem NAS "
         "der interessanteste Anteil: Steigt sie, bremsen die Platten, nicht "
         "die CPU."))

panels.append(ts(
    "Systemlast", [
        tgt(f"laLoadFloat{{{J}}}", "{{laNames}}"),
        tgt(f"ssCpuNumCpus{{{J}}}", "Kerne", ref="B"),
    ],
    {"h": 7, "w": 8, "x": 8, "y": Y}, unit="short", dec=2, minv=0, fill=0, width=2,
    desc="Die Linie 'Kerne' ist die Bezugsgroesse: Oberhalb davon warten mehr "
         "Prozesse auf CPU-Zeit, als die DS918+ Kerne hat."))

panels.append(ts(
    "Auslastung je Kern", [
        tgt(f'label_replace(hrProcessorLoad{{{J}}}, "kern", "$1",'
            f' "hrDeviceIndex", "1966(\\\\d\\\\d)")', "Kern {{kern}}")],
    {"h": 7, "w": 8, "x": 16, "y": Y}, unit="percent", dec=0, minv=0, maxv=100,
    fill=0, width=2,
    desc="hrProcessorLoad je Kern. Die hrDeviceIndex-Werte der DS918+ laufen ab "
         "196608, das label_replace schneidet daraus die letzten beiden Ziffern "
         "als Kennung. Wichtig, weil ein einzelner ausgelasteter Kern (Scrub, "
         "Indexierung) im Gesamtmittel untergeht."))

Y = 35
panels.append(ts(
    "Arbeitsspeicher", [
        tgt(f"(memTotalReal{{{J}}} - memAvailReal{{{J}}} - memBuffer{{{J}}}"
            f" - memCached{{{J}}}) * 1024", "belegt"),
        tgt(f"(memBuffer{{{J}}} + memCached{{{J}}}) * 1024", "Puffer und Cache",
            ref="B"),
        tgt(f"memAvailReal{{{J}}} * 1024", "frei", ref="C"),
    ],
    {"h": 7, "w": 12, "x": 0, "y": Y}, unit="bytes", dec=2, minv=0, stack=True,
    fill=25,
    desc="Die UCD-MIB liefert Kilobyte, deshalb ueberall *1024. Gestapelt "
         "ergeben die drei Reihen memTotalReal. Puffer und Cache sind kein "
         "Verlust — der Kernel gibt sie unter Druck zurueck."))

panels.append(ts(
    "Auslagerungsspeicher", [
        tgt(f"(memTotalSwap{{{J}}} - memAvailSwap{{{J}}}) * 1024", "belegt"),
        tgt(f"memTotalSwap{{{J}}} * 1024", "Gesamtgröße", ref="B"),
    ],
    {"h": 7, "w": 12, "x": 12, "y": Y}, unit="bytes", dec=2, minv=0, fill=6,
    desc="DSM legt Swap auf jeder Platte an, daher die hohe Gesamtgroesse. "
         "Dauerhaft belegter Swap bei gleichzeitig hoher E/A-Wartezeit ist das "
         "Muster, das die Freigaben spuerbar langsam macht."))

# =========================================================== Netzwerk
Y = 42
panels.append(row("Netzwerk", Y))
Y = 43

panels.append(ts(
    "Durchsatz eth1", [
        tgt(f'rate(ifHCInOctets{{{J},ifName="eth1"}}[10m]) * 8', "empfangen"),
        tgt(f'rate(ifHCOutOctets{{{J},ifName="eth1"}}[10m]) * 8', "gesendet",
            ref="B"),
    ],
    {"h": 7, "w": 16, "x": 0, "y": Y}, unit="bps", dec=1, minv=0, fill=10,
    desc="Nur eth1 — die einzige aktive physische Schnittstelle. ovs_bond0 ist "
         "die OVS-Bruecke darueber und zeigt weitgehend denselben Verkehr; "
         "beides zu summieren zaehlt doppelt. Container- und VM-Interfaces "
         "verwirft bereits der Scrape-Job, weil ihre Namen bei jedem "
         "Neustart wechseln."))

panels.append(table(
    "Schnittstellen", [
        tgt(f"ifOperStatus{{{J}}}", instant=True, fmt="table", ref="A"),
        tgt(f"ifHighSpeed{{{J}}}", instant=True, fmt="table", ref="B"),
    ],
    {"h": 7, "w": 8, "x": 16, "y": Y},
    [{"id": "joinByField", "options": {"byField": "ifName", "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": {k: True for k in
                           ["Time", "Time 1", "Time 2", "instance", "instance 1",
                            "instance 2", "job", "job 1", "job 2", "device",
                            "device 1", "device 2", "ifAlias", "ifAlias 1",
                            "ifAlias 2", "ifDescr", "ifDescr 1", "ifDescr 2",
                            "ifIndex", "ifIndex 1", "ifIndex 2"]},
         "renameByName": {"ifName": "Schnittstelle", "Value #A": "Zustand",
                          "Value #B": "Aushandlung"}}}],
    overrides=[
        {"matcher": {"id": "byName", "options": "Zustand"},
         "properties": [{"id": "mappings", "value": IF_OPER},
                        {"id": "custom.cellOptions",
                         "value": {"type": "color-text"}}]},
        {"matcher": {"id": "byName", "options": "Aushandlung"},
         "properties": [{"id": "unit", "value": "Mbits"},
                        {"id": "decimals", "value": 0}]}],
    desc="Aushandlung 0 heisst, dass der Treiber keine Geschwindigkeit meldet — "
         "typisch fuer virtuelle Schnittstellen und fuer eth0, an dem kein "
         "Kabel steckt."))

# =========================================================== Geraet
Y = 50
panels.append(row("Gerät", Y))
Y = 51

for title, metric, label, x in [
        ("Modell", "modelName", "modelName", 0),
        ("DSM-Version", "version", "version", 6),
        ("Name", "sysName", "sysName", 12),
        ("Standort", "sysLocation", "sysLocation", 18)]:
    panels.append(stat(
        title, f"{metric}{{{J}}}", {"h": 3, "w": 6, "x": x, "y": Y},
        legend=f"{{{{{label}}}}}", text_mode="name", color_mode="none"))

dash = {
    "uid": "synology-nas",
    "title": "Synology DS918+",
    "description": (
        "Zustand und Auslastung der Synology DS918+ (192.168.2.3, Werkraum). "
        "Quelle ist der Scrape-Job snmp-synology gegen den snmp-exporter im "
        "monitoring-Stack, per SNMPv3 (SHA/AES). Erzeugt von "
        ".gen-synology-nas.py — Aenderungen dort vornehmen, nicht im UI."),
    "tags": ["synology", "nas", "storage", "snmp"],
    "timezone": "browser",
    "editable": True,
    "schemaVersion": 39,
    "version": 1,
    "refresh": "1m",
    "time": {"from": "now-6h", "to": "now"},
    "graphTooltip": 1,
    "panels": panels,
    "links": [
        {"title": "Ceph / Storage", "type": "dashboards", "tags": ["ceph"],
         "asDropdown": False, "icon": "external link", "includeVars": False,
         "keepTime": True, "targetBlank": False, "tooltip": "", "url": ""},
        {"title": "USV / Stromversorgung", "type": "dashboards", "tags": ["ups"],
         "asDropdown": False, "icon": "external link", "includeVars": False,
         "keepTime": True, "targetBlank": False, "tooltip": "", "url": ""},
    ],
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "synology-nas.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(dash, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"{out} geschrieben — "
      f"{len([p for p in panels if p['type'] != 'row'])} Panels, "
      f"{len([p for p in panels if p['type'] == 'row'])} Zeilen")
