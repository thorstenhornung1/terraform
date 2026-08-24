#!/usr/bin/env python3
"""Erzeugt die drei Detail-Dashboards zur Synology DS918+.

Aufruf aus stacks/monitoring/:  python3 dashboards/.gen-synology-detail.py

  dashboards/synology-smart.json    Platten und SMART
  dashboards/synology-net.json      Netzwerk
  dashboards/synology-storage.json  Speicher und E/A

Das Uebersichts-Dashboard synology-nas.json entsteht getrennt in
.gen-synology-nas.py und verlinkt hierher.

WARUM DREI DASHBOARDS AUS EINEM SKRIPT
  Alle drei teilen sich dieselben MIB-Wertzuordnungen (Plattenzustand,
  RAID-Zustand, Schnittstellenzustand) und dieselben Join-Bausteine. Vier
  getrennte Generatoren haetten vier Kopien derselben Tabellen — die laufen
  auseinander, sobald jemand nur eine davon anfasst. Die Panel-ID-Zaehlung
  wird je Dashboard zurueckgesetzt.

WAS AM 2026-08-24 GEGEN DIE IST-DATEN GEPRUEFT WURDE
  Jeder Fallstrick steht zusaetzlich als description am betroffenen Panel,
  damit er beim Weiterbauen im UI sichtbar ist. Kurzfassung:

  KEIN iSCSI-Dashboard
      Es gibt genau eine LUN. Saemtliche Leistungswerte — DiskLatencyAvg/
      Read/Write, IopsRead/Write, ThroughputRead/Write, QueueDepth,
      NetworkLatencyRx/Tx, IoSizeRead/Write — stehen ueber die gesamte
      Vorhaltezeit konstant auf 0. Der einzige Wert ungleich 0,
      iSCSILUNThinProvisionVolFreeMBs, ist bis auf Rundung identisch mit
      raidFreeSize{raidName="Volume 1"} (1978589511680 gegen
      1978585194496 Bytes, 0,0002 % Abweichung) und damit nur eine zweite
      Schreibweise des Volume-Werts. Ein iSCSI-Dashboard zeigte also
      entweder Nullen oder eine Zahl, die anderswo schon steht.

  KEINE hrDevice-Panels
      hrDeviceID meldet fuer alle 37 Eintraege "0.0", hrDeviceDescr wird
      gar nicht erhoben. Ausser dem Indexnummern-Rauschen ist kein Geraet
      identifizierbar. Nur hrProcessorLoad traegt einen brauchbaren
      hrDeviceDescr — das Panel steht bereits in der Uebersicht.

  KEINE Broadcast-Panels
      ifHCInBroadcastPkts, ifHCOutBroadcastPkts, ifInBroadcastPkts und
      ifOutBroadcastPkts stehen auf allen acht Schnittstellen auf 0, auch
      im 30-Tage-Maximum. ifInNUcastPkts ist zahlenwertgleich mit
      ifInMulticastPkts, traegt also nichts Eigenes bei. Ausgehender
      Multicast ist ebenfalls durchgehend 0; gezeigt wird nur eingehender.

  SMART gibt es nur fuer die vier SATA-Platten
      diskSMARTInfoDevName kennt /dev/sda bis /dev/sdd. Die beiden
      NVMe-Cache-SSDs liefern keine SMART-Attribute. Panels ueber SMART
      zeigen daher vier Zeilen, Panels ueber die DSM-Plattentabelle sechs.

  /dev/sdX und "Disk N" lassen sich per SNMP NICHT verknuepfen
      Die SMART-Tabelle ist ueber diskSMARTInfoIndex indiziert und nennt
      /dev/sda…/dev/sdd; die DSM-Plattentabelle ist ueber diskID indiziert
      und nennt "Disk 1"…"Disk 4". Ein gemeinsames Label existiert nicht,
      und storageIOIndex taugt nicht als Bruecke, weil er anders sortiert
      (sda=5, sdb=6, sdc=3, sdd=4). Die Zuordnung sda=Disk 1 … sdd=Disk 4
      ist empirisch belegt — Reallocated_Sector_Ct (16/0/32/0) deckt sich
      mit diskBadSector, Temperature_Celsius (27/35/38/38) mit
      diskTemperature — aber sie ist NICHT aus den Daten ableitbar. Sie
      wird deshalb hier auch nicht hartkodiert: SMART-Panels beschriften
      mit /dev/sdX, DSM-Panels mit "Disk N".

  "Kleinster Abstand zum Grenzwert" ist als Rangfolge irrefuehrend
      End-to-End_Error steht bei Current 100 und Threshold 99, Abstand
      also 1 — und ist damit auf allen Platten kerngesund. Wer nach
      kleinstem Abstand sortiert, bekommt zuerst die unauffaelligen
      Attribute. Die Tabelle zeigt deshalb Current, Worst und Threshold
      nebeneinander statt einer einzelnen Abstandszahl.

  Worst = 253 ist kein Messwert
      253 ist der SMART-Sentinel fuer "nie aktualisiert" und steht hier
      bei Head_Flying_Hours, Total_LBAs_Written und Total_LBAs_Read. In
      Abstandsrechnungen wird er ausgefiltert.

  Rohwert 2147483647 ist ein abgeschnittener Zaehler
      2^31-1 ist die Obergrenze von SNMP-Integer32. Betroffen sind
      Total_LBAs_Written und Total_LBAs_Read auf allen vier Platten sowie
      Seek_Error_Rate auf sda und sdc — zusammen 10 der 92 Attribute. Die
      Panels blenden diese Werte aus, statt eine erfundene Zahl zu zeigen.

  Threshold 0 heisst "kein Grenzwert"
      Bei Temperature_Celsius, Power_On_Hours, Load_Cycle_Count und
      weiteren ist Threshold 0. Eine Abstandsrechnung ergaebe dort
      scheinbar riesige Reserven. Alle Abstandspanels filtern auf
      Threshold > 0.

  Attribut 194 ist kein normalisierter Wert
      Bei Temperature_Celsius steht in Current die Temperatur in Grad
      (27/35/38/38), nicht der uebliche 0..253-Gesundheitswert. In einer
      nach Current sortierten Liste stuende die kaelteste Platte oben, als
      waere sie die kranke. Der Threshold-0-Filter haelt das Attribut aus
      allen Abstandspanels heraus.

  Storage Pool 1 steht rechnerisch auf 100 % — das ist der Normalfall
      raidFreeSize meldet fuer den Pool 188 MiB von 18,18 TiB. Der Pool
      ist vollstaendig an Volume 1 zugeteilt; das ist so gewollt und kein
      Platzmangel. Die Tabelle beschriftet den Pool deshalb mit
      "zugeteilt" und das Volume mit "belegt". Volume 1 liegt bei 89,7 %
      und deckt sich exakt mit hrStorage fuer /volume1 — zwei unabhaengige
      SNMP-Tabellen, die sich gegenseitig bestaetigen.

  hrStorage: 46 Eintraege, davon 31 dieselbe Zahl
      /volume1 taucht zusaetzlich unter 30 Bind-Mounts auf
      (/volume1/@appdata/ContainerManager/all_shares/*, /volume1/@docker,
      …/#snapshot) — alle mit identischer Groesse und Belegung. Der Filter
      hrStorageDescr!~"/volume1/.+" laesst /volume1 selbst stehen und
      wirft alles darunter weg; aus 46 Reihen werden 9.

  Nur die X-Varianten der E/A-Zaehler benutzen
      storageIONRead steht bei 55–75 % von 2^32 und laeuft ueber.
      storageIONReadX/storageIONWrittenX sind die Counter64-Fassungen.

  Auslastung nur mit ifHighSpeed > 0 rechnen
      ifHighSpeed ist bei ovs_bond0 und macvlan-shim 0. Ohne Filter
      liefert die Division +Inf, und Grafana zeichnet das kommentarlos.
      Uebrig bleibt eth1 als einzige Schnittstelle mit ausgehandelter
      Geschwindigkeit.

  eth1 und ovs_bond0 nicht summieren
      ovs_bond0 ist die OVS-Bruecke ueber eth1 und zeigt denselben
      Verkehr ein zweites Mal (15,2 gegen 15,8 Mbit/s). Die Panels zeigen
      beide getrennt, bilden aber nie eine Summe.

  rate() mit [10m]
      Der Scrape laeuft alle 120 s. Kuerzere Fenster enthalten zu wenige
      Punkte, und der Ausdruck liefert dann stumm nichts.

  Historie ist jung
      Der Scrape-Job laeuft seit 2026-08-23 09:42. Wachstums- und
      Prognosepanels rechnen auf schmaler Basis; sie werden mit der Zeit
      belastbarer. Das ist in den betroffenen descriptions vermerkt.
"""
import json
import os

DS = {"type": "prometheus", "uid": "victoriametrics"}
J = 'job="snmp-synology"'

UID_OVERVIEW = "synology-nas"
UID_SMART = "synology-smart"
UID_NET = "synology-net"
UID_STORAGE = "synology-storage"

# --------------------------------------------------------------- Wertzuordnung
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
IF_OPER = [{"options": {
    "1": {"text": "up", "color": "green", "index": 0},
    "2": {"text": "down", "color": "text", "index": 1},
    "3": {"text": "testing", "color": "yellow", "index": 2},
    "4": {"text": "unbekannt", "color": "text", "index": 3},
    "5": {"text": "ruhend", "color": "text", "index": 4},
    "6": {"text": "nicht vorhanden", "color": "text", "index": 5},
    "7": {"text": "Link fehlt", "color": "yellow", "index": 6}}, "type": "value"}]
SMART_OK = [{"options": {"1": {"text": "in Ordnung", "color": "green", "index": 0}},
             "type": "value"},
            {"options": {"match": "null", "result": {"text": "-", "index": 1}},
             "type": "special"}]

# ------------------------------------------------------------------ Bausteine
# Zweistufiger Join: an den Messwert erst den Attributnamen, dann den
# Geraetenamen anhaengen. Beide Info-Metriken tragen den Wert 1, deshalb
# veraendert die Multiplikation die Zahl nicht. Gegengeprueft: 92 Serien rein,
# 92 Serien raus — der Join dupliziert nicht.
NAME_JOIN = (f'* on(diskSMARTInfoIndex) group_left(diskSMARTAttrName) '
             f'diskSMARTAttrName{{{J}}}')
DEV_JOIN = (f'* on(diskSMARTInfoIndex) group_left(diskSMARTInfoDevName) '
            f'diskSMARTInfoDevName{{{J}}}')


def smart_by_id(metric, attr_id):
    """Ein SMART-Attribut je Platte, nur mit dem Geraetenamen als Label.

    Gefiltert wird ueber diskSMARTAttrId, nicht ueber den Namen: die IDs sind
    genormt, die Namen nicht. /dev/sdb meldet zum Beispiel Head_Health (18),
    wo die anderen drei End-to-End_Error (184) melden.

    Das sum by () wirft diskSMARTInfoIndex weg. Ohne das traegt jede Spalte
    einer Tabelle ihren eigenen Index, und joinByField findet keine
    gemeinsame Zeile.
    """
    return (f'sum by (diskSMARTInfoDevName) (({metric}{{{J}}} '
            f'and on(diskSMARTInfoIndex) (diskSMARTAttrId{{{J}}} == {attr_id})) '
            f'{DEV_JOIN})')


# Echte Dateisysteme: alles unterhalb von /volume1 sind Bind-Mounts derselben
# btrfs-Dateisysteme und tragen identische Zahlen.
FS = 'hrStorageDescr=~"/.*",hrStorageDescr!~"/volume1/.+"'

pid = [0]


def reset_ids():
    pid[0] = 0


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
        "targets": [tgt(expr, legend, instant=not graph)],
    }
    if desc:
        p["description"] = desc
    return p


def ts(title, targets, gp, unit="short", dec=1, minv=None, maxv=None, stack=False,
       fill=8, desc=None, legend_calcs=None, width=1, links=None):
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
    if links:
        p["links"] = links
    return p


def timeline(title, expr, gp, legend, mappings, desc=None, time_from="24h",
             row_height=0.7, links=None):
    """Zustandsverlauf: eine Zeile je Objekt statt einer Kachel je Objekt.

    mergeValues fasst gleiche Nachbarwerte zusammen, sodass eine Platte, die
    24 h lang "Normal" meldet, einen durchgehenden Balken bekommt und nicht
    720 Einzelsegmente. showValue "never" haelt die Zeile lesbar — die
    Bedeutung steht in der Legende und im Tooltip, die Farbe kommt aus den
    Wertzuordnungen und ist damit nicht das einzige Unterscheidungsmerkmal.
    """
    p = {
        "id": nid(), "type": "state-timeline", "title": title, "datasource": DS,
        "gridPos": gp, "timeFrom": time_from,
        "fieldConfig": {"defaults": {
            "custom": {"lineWidth": 0, "fillOpacity": 85, "spanNulls": True,
                       "insertNulls": False,
                       "hideFrom": {"tooltip": False, "viz": False, "legend": False}},
            "mappings": mappings,
            "thresholds": {"mode": "absolute",
                           "steps": [{"color": "text", "value": None}]},
            "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"mergeValues": True, "showValue": "never",
                    "rowHeight": row_height, "alignValue": "center", "perPage": 20,
                    "legend": {"displayMode": "list", "placement": "bottom",
                               "showLegend": True},
                    "tooltip": {"mode": "single", "sort": "none"}},
        "targets": [tgt(expr, legend)],
    }
    if desc:
        p["description"] = desc
    if links:
        p["links"] = links
    return p


def bargauge(title, expr, gp, legend="", unit="percent", dec=1, thresholds=None,
             maxv=100, minv=0, desc=None):
    p = {
        "id": nid(), "type": "bargauge", "title": title, "datasource": DS,
        "gridPos": gp,
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec, "min": minv, "max": maxv, "mappings": [],
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


def table(title, targets, gp, transformations, overrides=None, desc=None,
          sort_by=None, desc_sort=True):
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
    if sort_by:
        p["options"]["sortBy"] = [{"displayName": sort_by, "desc": desc_sort}]
    if desc:
        p["description"] = desc
    return p


def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def dlink(title, uid):
    """Dashboard-Verweis in der Kopfzeile."""
    return {"title": title, "type": "link", "url": f"/d/{uid}/", "tags": [],
            "asDropdown": False, "icon": "external link", "includeVars": False,
            "keepTime": True, "targetBlank": False, "tooltip": ""}


def plink(title, uid):
    """Panel-Verweis: erscheint im Panel-Menue und im Titel-Hover."""
    return [{"title": title, "url": f"/d/{uid}/?${{__url_time_range}}",
             "targetBlank": False}]


def drop_cols(names):
    return {n: True for n in names}


# Spalten, die aus jedem Instant-Query mitkommen und in keiner Tabelle etwas
# verloren haben. Grafana haengt beim Join je Frame eine Nummer an, deshalb
# die Varianten mitgenerieren.
def noise(extra=(), n=9):
    base = ["Time", "job", "instance", "device"] + list(extra)
    out = []
    for b in base:
        out.append(b)
        out.extend(f"{b} {i}" for i in range(1, n + 1))
    return out


def build(uid, title, description, tags, panels, links):
    return {
        "uid": uid, "title": title, "description": description, "tags": tags,
        "timezone": "browser", "editable": True, "schemaVersion": 39, "version": 1,
        "refresh": "1m", "time": {"from": "now-6h", "to": "now"}, "graphTooltip": 1,
        "panels": panels, "links": links,
    }


def write(dash, filename):
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(dash, f, indent=2, ensure_ascii=False)
        f.write("\n")
    n_p = len([p for p in dash["panels"] if p["type"] != "row"])
    n_r = len([p for p in dash["panels"] if p["type"] == "row"])
    print(f"{out} geschrieben — {n_p} Panels, {n_r} Zeilen")


# ===========================================================================
# Dashboard 1 — Platten und SMART
# ===========================================================================
reset_ids()
panels = []

panels.append(row("Zustand der Platten", 0))

panels.append(timeline(
    "Plattenzustand", f'diskStatus{{{J}}}', {"h": 6, "w": 12, "x": 0, "y": 1},
    "{{diskID}}", DISK_STATUS,
    desc="Eine Zeile je Platte ueber 24 h, unabhaengig vom gewaehlten "
         "Zeitbereich. Sechs Zeilen: vier SATA-Platten und zwei "
         "NVMe-Cache-SSDs. Die Zahlen der Synology-MIB sind auf Klartext "
         "abgebildet — 1 und 2 sind beide unauffaellig, erst ab 3 wird es "
         "eng. Kommt eine Platte hinzu, waechst das Panel von selbst mit."))

panels.append(timeline(
    "Plattengesundheit", f'diskHealthStatus{{{J}}}',
    {"h": 6, "w": 12, "x": 12, "y": 1}, "{{diskID}}", DISK_HEALTH,
    desc="Bewusst getrennt von der Zustandsanzeige links: diskStatus und "
         "diskHealthStatus benutzen dieselben Zahlen fuer verschiedene "
         "Dinge — die 2 heisst hier \"Warnung\", dort \"Initialisiert\". "
         "In einem gemeinsamen Panel waere jede Wertzuordnung fuer eine "
         "der beiden Reihen falsch."))

panels.append(row("Fruehwarnzeichen", 7))

# Die fuenf Attribute, die sich in der Backblaze-Auswertung als tatsaechliche
# Vorboten eines Ausfalls erwiesen haben (5, 187, 188, 197, 198), ergaenzt um
# UDMA_CRC (199, Verkabelung) und Spin_Retry (10, Mechanik).
PREDICTORS = [
    (5, "Ersetzte Sektoren"),
    (197, "Schwebende Sektoren"),
    (198, "Nicht korrigierbar (offline)"),
    (187, "Gemeldet unkorrigierbar"),
    (188, "Befehls-Zeitueberschreitungen"),
    (199, "UDMA-CRC-Fehler"),
    (10, "Wiederanlaufversuche"),
]
refs = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
panels.append(table(
    "SMART-Fehlerzaehler je Platte (Rohwerte)",
    [tgt(smart_by_id("diskSMARTAttrRaw", aid), instant=True, fmt="table",
         ref=refs[i]) for i, (aid, _) in enumerate(PREDICTORS)],
    {"h": 7, "w": 14, "x": 0, "y": 8},
    [{"id": "joinByField", "options": {"byField": "diskSMARTInfoDevName",
                                       "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": drop_cols(noise()),
         "renameByName": dict(
             [("diskSMARTInfoDevName", "Platte")] +
             [(f"Value #{refs[i]}", nm) for i, (_, nm) in enumerate(PREDICTORS)])}}],
    overrides=[{"matcher": {"id": "byRegexp", "options": "^(?!Platte$).*$"},
                "properties": [
                    {"id": "custom.cellOptions",
                     "value": {"type": "color-text"}},
                    {"id": "thresholds", "value": {
                        "mode": "absolute",
                        "steps": [{"color": "text", "value": None},
                                  {"color": "orange", "value": 1}]}},
                    {"id": "decimals", "value": 0}]}],
    desc="Absolute Zaehler seit Werk, keine Raten — eine 16 heisst, dass die "
         "Platte in ihrem Leben 16 Sektoren ersetzt hat. Ausschlaggebend ist "
         "nicht die Hoehe, sondern ob die Zahl STEIGT; dafuer ist der "
         "Verlauf unter \"Fehlerzaehler im Verlauf\" da. Gefiltert wird ueber "
         "diskSMARTAttrId, nicht ueber den Attributnamen: die IDs sind "
         "genormt, die Namen nicht — /dev/sdb meldet Head_Health (18), wo die "
         "anderen End-to-End_Error (184) melden. Nur die vier SATA-Platten "
         "liefern SMART; die NVMe-Cache-SSDs fehlen hier zwangslaeufig."))

panels.append(bargauge(
    "Fehlerhafte Sektoren (DSM)", f'diskBadSector{{{J}}} >= 0',
    {"h": 7, "w": 5, "x": 14, "y": 8}, "{{diskID}}", unit="none", dec=0, maxv=100,
    thresholds=[{"color": "green", "value": None},
                {"color": "orange", "value": 1},
                {"color": "red", "value": 50}],
    desc="Der >= 0 Filter ist noetig: die beiden Cache-SSDs melden -1 fuer "
         "\"nicht anwendbar\". Ohne Filter stuenden sie als Messwert unter "
         "null im Balken. Die Zahlen decken sich mit dem SMART-Attribut "
         "Reallocated_Sector_Ct — zwei unabhaengige SNMP-Tabellen, die "
         "dasselbe sagen."))

panels.append(bargauge(
    "Restlebensdauer SSD-Cache", f'diskRemainLife{{{J}}} >= 0',
    {"h": 7, "w": 5, "x": 19, "y": 8}, "{{diskID}}", unit="percent", dec=0,
    thresholds=[{"color": "red", "value": None},
                {"color": "orange", "value": 20},
                {"color": "green", "value": 50}],
    desc="Nur die beiden NVMe-Cache-SSDs liefern hier echte Prozentwerte; die "
         "vier Festplatten melden -1 fuer \"nicht anwendbar\" und werden vom "
         "Filter ausgeschlossen. Ohne ihn erschiene -1 als Messwert."))

panels.append(row("Abstand zum Grenzwert", 15))

panels.append(table(
    "Normalisierte Werte gegen Grenzwert",
    [tgt(f'(diskSMARTAttrCurrent{{{J}}} and (diskSMARTAttrThreshold{{{J}}} > 0)) '
         f'{NAME_JOIN} {DEV_JOIN}', instant=True, fmt="table", ref="A"),
     tgt(f'diskSMARTAttrWorst{{{J}}} != 253', instant=True, fmt="table", ref="B"),
     tgt(f'diskSMARTAttrThreshold{{{J}}}', instant=True, fmt="table", ref="C"),
     tgt(f'diskSMARTAttrId{{{J}}}', instant=True, fmt="table", ref="D")],
    {"h": 9, "w": 14, "x": 0, "y": 16},
    [{"id": "joinByField", "options": {"byField": "diskSMARTInfoIndex",
                                       "mode": "inner"}},
     {"id": "organize", "options": {
         "excludeByName": drop_cols(noise(["diskSMARTInfoIndex"])),
         "renameByName": {"diskSMARTInfoDevName": "Platte",
                          "diskSMARTAttrName": "Attribut",
                          "Value #A": "Aktuell", "Value #B": "Schlechtester",
                          "Value #C": "Grenzwert", "Value #D": "ID"}}}],
    overrides=[
        {"matcher": {"id": "byName", "options": "ID"},
         "properties": [{"id": "decimals", "value": 0},
                        {"id": "custom.width", "value": 55}]},
        {"matcher": {"id": "byRegexp",
                     "options": "^(Aktuell|Schlechtester|Grenzwert)$"},
         "properties": [{"id": "decimals", "value": 0}]}],
    sort_by="Schlechtester", desc_sort=False,
    desc="Bei SMART ist hoeher besser: Current und Worst sind auf 0..253 "
         "normiert, die Platte gilt als verbraucht, sobald Current den "
         "Grenzwert unterschreitet. Worst ist der tiefste je erreichte Stand "
         "und damit die eigentlich interessante Spalte — danach ist "
         "sortiert.\n\n"
         "Drei Filter sind noetig, damit die Tabelle nicht luegt: "
         "Threshold > 0 wirft die Attribute ohne echten Grenzwert heraus "
         "(sonst erschiene Temperature_Celsius, dessen \"Aktuell\" die "
         "Temperatur in Grad ist und kein Gesundheitswert — die kaelteste "
         "Platte stuende dann oben, als waere sie die kranke). "
         "Worst != 253 wirft den SMART-Sentinel fuer \"nie aktualisiert\" "
         "heraus. Der inner join laesst nur Zeilen stehen, die beides "
         "ueberlebt haben.\n\n"
         "Ein kleiner Abstand allein ist KEIN Alarm: End-to-End_Error steht "
         "bei Current 100 gegen Grenzwert 99 und ist damit kerngesund. "
         "Deshalb stehen hier drei Spalten nebeneinander statt einer "
         "Abstandszahl."))

panels.append(ts(
    "Fehlerzaehler im Verlauf",
    [tgt(smart_by_id("diskSMARTAttrRaw", 5), "ersetzte Sektoren {{diskSMARTInfoDevName}}",
         ref="A"),
     tgt(smart_by_id("diskSMARTAttrRaw", 187),
         "unkorrigierbar {{diskSMARTInfoDevName}}", ref="B"),
     tgt(smart_by_id("diskSMARTAttrRaw", 199),
         "UDMA-CRC {{diskSMARTInfoDevName}}", ref="C")],
    {"h": 9, "w": 10, "x": 14, "y": 16}, unit="none", dec=0, minv=0, fill=0,
    width=2, legend_calcs=["min", "max", "lastNotNull"],
    desc="Waagerecht ist gut. Jede Stufe nach oben bedeutet einen neuen "
         "Fehler und ist ein Grund, die Platte im Auge zu behalten — "
         "unabhaengig davon, wie hoch der absolute Wert steht. Bewusst nur "
         "die drei aussagekraeftigsten Zaehler, damit die Stufen sichtbar "
         "bleiben."))

panels.append(row("Betrieb und Verschleiss", 25))

WEAR = [(9, "Betriebsstunden"), (12, "Einschaltzyklen"),
        (4, "Start/Stopp"), (193, "Kopf-Ladezyklen"), (192, "Not-Parkvorgaenge")]
panels.append(table(
    "Betriebsdaten je Platte",
    [tgt(smart_by_id("diskSMARTAttrRaw", aid), instant=True, fmt="table",
         ref=refs[i]) for i, (aid, _) in enumerate(WEAR)],
    {"h": 7, "w": 12, "x": 0, "y": 26},
    [{"id": "joinByField", "options": {"byField": "diskSMARTInfoDevName",
                                       "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": drop_cols(noise()),
         "renameByName": dict(
             [("diskSMARTInfoDevName", "Platte")] +
             [(f"Value #{refs[i]}", nm) for i, (_, nm) in enumerate(WEAR)])}}],
    overrides=[
        {"matcher": {"id": "byName", "options": "Betriebsstunden"},
         "properties": [{"id": "unit", "value": "h"}, {"id": "decimals", "value": 0},
                        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                        {"id": "thresholds", "value": {
                            "mode": "absolute",
                            "steps": [{"color": "text", "value": None},
                                      {"color": "yellow", "value": 43800},
                                      {"color": "orange", "value": 61320}]}}]},
        {"matcher": {"id": "byRegexp", "options": "^(?!Platte$|Betriebsstunden$).*$"},
         "properties": [{"id": "decimals", "value": 0}]}],
    sort_by="Betriebsstunden",
    desc="Betriebsstunden faerben sich ab 5 Jahren (43800 h) gelb und ab "
         "7 Jahren (61320 h) orange — das sind Erfahrungswerte fuer "
         "NAS-Platten, keine Herstellerangaben. Kopf-Ladezyklen sind bei "
         "Seagate-Platten auf einige Hunderttausend ausgelegt; "
         "Not-Parkvorgaenge (Power-Off_Retract) zaehlen ungeplante "
         "Abschaltungen und passen zur Zahl der Stromausfaelle."))

panels.append(ts(
    "Temperatur je Platte",
    [tgt(f'diskTemperature{{{J}}}', "{{diskID}}")],
    {"h": 7, "w": 12, "x": 12, "y": 26}, unit="celsius", dec=0, minv=0, fill=0,
    width=2,
    desc="Aus der DSM-Plattentabelle, deshalb alle sechs Geraete — die "
         "SMART-Tabelle kennt nur die vier SATA-Platten. Die Werte decken "
         "sich mit dem SMART-Attribut Temperature_Celsius (194). Fuer "
         "NAS-Festplatten gilt 60 Grad als Obergrenze; die MIB liefert "
         "keinen Grenzwert mit."))

panels.append(row("Alle SMART-Attribute", 33))

panels.append(table(
    "SMART-Attribute vollstaendig",
    [tgt(f'diskSMARTAttrCurrent{{{J}}} {NAME_JOIN} {DEV_JOIN}',
         instant=True, fmt="table", ref="A"),
     tgt(f'diskSMARTAttrWorst{{{J}}}', instant=True, fmt="table", ref="B"),
     tgt(f'diskSMARTAttrThreshold{{{J}}}', instant=True, fmt="table", ref="C"),
     tgt(f'diskSMARTAttrRaw{{{J}}} < 2147483647', instant=True, fmt="table", ref="D"),
     tgt(f'diskSMARTAttrId{{{J}}}', instant=True, fmt="table", ref="E"),
     tgt(f'diskSMARTAttrStatus{{{J}}}', instant=True, fmt="table", ref="F")],
    {"h": 14, "w": 24, "x": 0, "y": 34},
    [{"id": "joinByField", "options": {"byField": "diskSMARTInfoIndex",
                                       "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": drop_cols(noise(["diskSMARTInfoIndex"])),
         "renameByName": {"diskSMARTInfoDevName": "Platte",
                          "diskSMARTAttrName": "Attribut", "Value #E": "ID",
                          "Value #A": "Aktuell", "Value #B": "Schlechtester",
                          "Value #C": "Grenzwert", "Value #D": "Rohwert",
                          "Value #F": "Status"}}}],
    overrides=[
        {"matcher": {"id": "byName", "options": "ID"},
         "properties": [{"id": "decimals", "value": 0},
                        {"id": "custom.width", "value": 55}]},
        {"matcher": {"id": "byName", "options": "Status"},
         "properties": [{"id": "mappings", "value": SMART_OK},
                        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                        {"id": "custom.width", "value": 95}]},
        {"matcher": {"id": "byName", "options": "Rohwert"},
         "properties": [{"id": "decimals", "value": 0},
                        {"id": "noValue", "value": "abgeschnitten"}]},
        {"matcher": {"id": "byRegexp",
                     "options": "^(Aktuell|Schlechtester|Grenzwert)$"},
         "properties": [{"id": "decimals", "value": 0},
                        {"id": "custom.width", "value": 110}]}],
    sort_by="Platte", desc_sort=False,
    desc="Alle 92 Attribute der vier SATA-Platten. Zwei Eigenheiten sind "
         "hier absichtlich sichtbar gelassen statt versteckt:\n\n"
         "Rohwert leer, beschriftet mit \"abgeschnitten\": der Wert steht auf "
         "2147483647 und damit auf der Obergrenze von SNMP-Integer32 — der "
         "Zaehler ist abgeschnitten, nicht gemessen. Betroffen sind "
         "Total_LBAs_Written und Total_LBAs_Read auf allen vier Platten "
         "sowie Seek_Error_Rate auf sda und sdc.\n\n"
         "Schlechtester 253: SMART-Sentinel fuer \"nie aktualisiert\", "
         "typisch bei Head_Flying_Hours und den Total_LBAs-Attributen.\n\n"
         "Status stand bei allen 92 Attributen ueber die gesamte "
         "Vorhaltezeit auf 1. Die Spalte ist eine Absicherung, kein "
         "Messinstrument — wenn dort je etwas anderes steht, ist das das "
         "Signal."))

write(build(
    UID_SMART, "Synology DS918+ — Platten und SMART",
    "Plattenzustand und SMART-Attribute der Synology DS918+ (192.168.2.3). "
    "Quelle ist der Scrape-Job snmp-synology. SMART liefert nur die vier "
    "SATA-Platten (/dev/sda bis /dev/sdd); die beiden NVMe-Cache-SSDs "
    "erscheinen ausschliesslich in den Panels aus der DSM-Plattentabelle. "
    "Erzeugt von .gen-synology-detail.py — Aenderungen dort vornehmen, "
    "nicht im UI.",
    ["synology", "nas", "storage", "snmp", "smart"], panels,
    [dlink("Uebersicht NAS", UID_OVERVIEW), dlink("Netzwerk", UID_NET),
     dlink("Speicher und E/A", UID_STORAGE)]),
    "synology-smart.json")


# ===========================================================================
# Dashboard 2 — Netzwerk
# ===========================================================================
reset_ids()
panels = []

panels.append(row("Verbindungen", 0))

panels.append(timeline(
    "Betriebszustand je Schnittstelle", f'ifOperStatus{{{J}}}',
    {"h": 6, "w": 16, "x": 0, "y": 1}, "{{ifName}}", IF_OPER,
    desc="Eine Zeile je Schnittstelle ueber 24 h. Dass eth0, ovs-system, "
         "ovs_bond0.12 und sit0 dauerhaft \"down\" zeigen, ist der "
         "Normalzustand: an eth0 steckt kein Kabel, die uebrigen drei sind "
         "Hilfskonstrukte von Open vSwitch und dem IPv6-Tunnel. Sie sind "
         "trotzdem aufgefuehrt, weil ein Wechsel dort eine Aenderung an der "
         "Netzkonfiguration bedeutet.\n\n"
         "Die Liste ist bewusst ungefiltert: in der Historie taucht eine "
         "Schnittstelle tap02113225dad2 auf, die es heute nicht mehr gibt. "
         "Ein fester Namensfilter haette sie verschwiegen."))

panels.append(stat(
    "Schnittstellen betriebsbereit", f'count(ifOperStatus{{{J}}} == 1)',
    {"h": 6, "w": 4, "x": 16, "y": 1}, unit="none", dec=0,
    thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}],
    desc="Zaehlt Zeilen mit Zustand up, derzeit vier: eth1, lo, "
         "macvlan-shim und ovs_bond0.\n\n"
         "An dieser Stelle stand zunaechst eine \"Verbindungsdauer eth1\" aus "
         "sysUpTime - ifLastChange. Sie wurde entfernt: ifLastChange meldet "
         "auf allen acht Schnittstellen 0, DSM fuellt die Groesse also gar "
         "nicht. Die Rechnung haette damit nur sysUpTime angezeigt — und das "
         "ist die Laufzeit des snmpd, nicht die der Verbindung. Aktuell "
         "steht sysUpTime bei 15 h, waehrend das Geraet laut "
         "hrSystemUptime seit 38 h laeuft."))

panels.append(stat(
    "Ausgehandelt eth1", f'ifHighSpeed{{{J},ifName="eth1"}}',
    {"h": 6, "w": 4, "x": 20, "y": 1}, unit="Mbits", dec=0,
    thresholds=[{"color": "red", "value": None},
                {"color": "orange", "value": 100},
                {"color": "green", "value": 1000}],
    desc="Die einzige Schnittstelle mit ausgehandelter Geschwindigkeit. "
         "Faellt der Wert unter 1000, hat die Verbindung auf Fast Ethernet "
         "zurueckgeschaltet — meist ein Kabel- oder Portproblem."))

panels.append(row("Durchsatz", 7))

panels.append(ts(
    "Durchsatz empfangen",
    [tgt(f'(rate(ifHCInOctets{{{J},ifName!="lo"}}[10m]) * 8) '
         f'and on(ifName) (ifOperStatus{{{J}}} == 1)', "{{ifName}}")],
    {"h": 8, "w": 12, "x": 0, "y": 8}, unit="bps", dec=1, minv=0, fill=10,
    desc="eth1 und ovs_bond0 zeigen weitgehend denselben Verkehr — "
         "ovs_bond0 ist die Open-vSwitch-Bruecke ueber eth1. Beide sind "
         "getrennt sichtbar, damit ein Auseinanderlaufen auffaellt; eine "
         "Summe waere doppelt gezaehlt. Der Filter auf ifOperStatus == 1 "
         "haelt die vier dauerhaft stillen Schnittstellen heraus, ohne "
         "einen festen Namensfilter zu brauchen: kommt eine neue "
         "Schnittstelle hoch, erscheint sie von selbst."))

panels.append(ts(
    "Durchsatz gesendet",
    [tgt(f'(rate(ifHCOutOctets{{{J},ifName!="lo"}}[10m]) * 8) '
         f'and on(ifName) (ifOperStatus{{{J}}} == 1)', "{{ifName}}")],
    {"h": 8, "w": 12, "x": 12, "y": 8}, unit="bps", dec=1, minv=0, fill=10,
    desc="Getrennt von der Empfangsrichtung, weil das NAS stark "
         "asymmetrisch arbeitet — es nimmt deutlich mehr entgegen, als es "
         "ausliefert. In einem gemeinsamen Panel verschwaende die kleinere "
         "Richtung an der Nulllinie."))

panels.append(ts(
    "Auslastung der Verbindung",
    [tgt(f'rate(ifHCInOctets{{{J},ifName!="lo"}}[10m]) * 8 '
         f'/ (ifHighSpeed{{{J}}} > 0) / 1000000 * 100', "{{ifName}} empfangen"),
     tgt(f'rate(ifHCOutOctets{{{J},ifName!="lo"}}[10m]) * 8 '
         f'/ (ifHighSpeed{{{J}}} > 0) / 1000000 * 100', "{{ifName}} gesendet",
         ref="B")],
    {"h": 7, "w": 12, "x": 0, "y": 16}, unit="percent", dec=2, minv=0, fill=6,
    desc="Der Filter ifHighSpeed > 0 ist nicht optional: ovs_bond0 und "
         "macvlan-shim melden die Geschwindigkeit 0, und die Division "
         "liefert dort +Inf. Grafana zeichnet das kommentarlos als "
         "Ausschlag ins Nichts. Uebrig bleibt eth1 — die einzige "
         "Schnittstelle mit ausgehandelter Geschwindigkeit."))

panels.append(ts(
    "Paketrate eth1",
    [tgt(f'rate(ifHCInUcastPkts{{{J},ifName="eth1"}}[10m])', "unicast empfangen"),
     tgt(f'rate(ifHCOutUcastPkts{{{J},ifName="eth1"}}[10m])', "unicast gesendet",
         ref="B"),
     tgt(f'rate(ifHCInMulticastPkts{{{J},ifName="eth1"}}[10m])',
         "multicast empfangen", ref="C")],
    {"h": 7, "w": 12, "x": 12, "y": 16}, unit="pps", dec=1, minv=0, fill=0,
    width=2,
    desc="Ausgehender Multicast fehlt, weil ifHCOutMulticastPkts auf allen "
         "Schnittstellen konstant 0 meldet — das NAS versendet keinen "
         "Multicast oder DSM zaehlt ihn nicht. Broadcast fehlt aus "
         "demselben Grund: alle vier Broadcast-Zaehler stehen auch im "
         "30-Tage-Maximum auf 0. Ein Panel dafuer waere eine Nulllinie mit "
         "Ueberschrift."))

panels.append(row("Fehler und Verwuerfe", 23))

ERRCOLS = [("ifInErrors", "Fehler empfangen"), ("ifOutErrors", "Fehler gesendet"),
           ("ifInDiscards", "verworfen empfangen"),
           ("ifOutDiscards", "verworfen gesendet"),
           ("ifInUnknownProtos", "unbekanntes Protokoll"),
           ("ifOutQLen", "Warteschlange")]
panels.append(table(
    "Fehlerzaehler je Schnittstelle",
    [tgt(f'{m}{{{J}}}', instant=True, fmt="table", ref=refs[i])
     for i, (m, _) in enumerate(ERRCOLS)],
    {"h": 8, "w": 18, "x": 0, "y": 24},
    [{"id": "joinByField", "options": {"byField": "ifName", "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": drop_cols(noise(["ifIndex", "ifDescr", "ifAlias"])),
         "renameByName": dict(
             [("ifName", "Schnittstelle")] +
             [(f"Value #{refs[i]}", nm) for i, (_, nm) in enumerate(ERRCOLS)])}}],
    overrides=[{"matcher": {"id": "byRegexp", "options": "^(?!Schnittstelle$).*$"},
                "properties": [
                    {"id": "decimals", "value": 0},
                    {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                    {"id": "thresholds", "value": {
                        "mode": "absolute",
                        "steps": [{"color": "text", "value": None},
                                  {"color": "orange", "value": 1}]}}]}],
    desc="Absolutzaehler seit dem letzten Neustart des Zaehlwerks, keine "
         "Raten. Aktuell steht hier fast ueberall 0; im 30-Tage-Maximum gab "
         "es genau zwei Ausnahmen — ein einzelner ifOutErrors auf ovs_bond0 "
         "und 206 ifOutDiscards auf einer inzwischen verschwundenen "
         "VM-Schnittstelle tap02113225dad2.\n\n"
         "Ein Zeitreihen-Panel waere hier die falsche Darstellung: eine "
         "Kurve, die monatelang auf 0 liegt, sieht aus wie ein kaputtes "
         "Panel. Die Tabelle faerbt stattdessen jeden Wert ab 1 orange."))

panels.append(stat(
    "Fehler und Verwuerfe gesamt",
    f'sum(ifInErrors{{{J}}}) + sum(ifOutErrors{{{J}}}) '
    f'+ sum(ifInDiscards{{{J}}}) + sum(ifOutDiscards{{{J}}})',
    {"h": 8, "w": 6, "x": 18, "y": 24}, unit="none", dec=0, graph=True,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 1},
                {"color": "orange", "value": 100}],
    desc="Eine Zahl ueber alle Schnittstellen und alle vier Zaehlerarten, "
         "damit man nicht die ganze Tabelle absuchen muss. Steht derzeit "
         "auf 1 — der einzelne ifOutErrors auf ovs_bond0.\n\n"
         "Hier stand zunaechst eine Zeitreihe mit rate(...) > 0. Die blieb "
         "dauerhaft leer, weil seit Messbeginn keine Fehlerrate ungleich 0 "
         "aufgetreten ist, und ein dauerhaft leeres Panel ist von einem "
         "kaputten Panel nicht zu unterscheiden. Der Summenzaehler ist "
         "stattdessen immer belegt und steigt sichtbar, sobald irgendwo "
         "etwas passiert — die Sparkline zeigt wann."))

panels.append(row("Dienste", 32))

panels.append(bargauge(
    "Verbindungen je Dienst", f'serviceUsers{{{J}}}',
    {"h": 7, "w": 10, "x": 0, "y": 33}, "{{serviceName}}", unit="none", dec=0,
    maxv=20, thresholds=[{"color": "green", "value": None}],
    desc="Aus der Synology-MIB-Diensttabelle. NFS bedient die drei "
         "Swarm-Knoten, HTTP/HTTPS die DSM-Oberflaeche. Dass TELNET, FTP "
         "und AFP auf 0 stehen, ist der erwuenschte Zustand — ein Wert "
         "ungleich 0 dort waere begruendungsbeduerftig."))

panels.append(ts(
    "Verbindungen je Dienst im Verlauf", [tgt(f'serviceUsers{{{J}}}',
                                              "{{serviceName}}")],
    {"h": 7, "w": 14, "x": 10, "y": 33}, unit="none", dec=0, minv=0, fill=0,
    width=2, legend_calcs=["max", "lastNotNull"],
    desc="Zeigt, wann Freigaben tatsaechlich benutzt werden. Ein Einbruch "
         "der NFS-Zahl auf 0 bedeutet, dass die Swarm-Knoten die Freigabe "
         "verloren haben — das ist frueher sichtbar als ein Anwendungsfehler "
         "im Stack."))

write(build(
    UID_NET, "Synology DS918+ — Netzwerk",
    "Schnittstellen, Durchsatz, Fehlerzaehler und Dienstverbindungen der "
    "Synology DS918+ (192.168.2.3). Quelle ist der Scrape-Job snmp-synology. "
    "eth1 ist die einzige aktive physische Schnittstelle; ovs_bond0 ist die "
    "Open-vSwitch-Bruecke darueber und zeigt denselben Verkehr ein zweites "
    "Mal — die Panels summieren beide nie. Erzeugt von "
    ".gen-synology-detail.py — Aenderungen dort vornehmen, nicht im UI.",
    ["synology", "nas", "network", "snmp"], panels,
    [dlink("Uebersicht NAS", UID_OVERVIEW), dlink("Platten und SMART", UID_SMART),
     dlink("Speicher und E/A", UID_STORAGE)]),
    "synology-net.json")


# ===========================================================================
# Dashboard 3 — Speicher und E/A
# ===========================================================================
reset_ids()
panels = []

VOL_USED = (f'hrStorageUsed{{{J},hrStorageDescr="/volume1"}} '
            f'* on(hrStorageIndex) group_left() '
            f'hrStorageAllocationUnits{{{J},hrStorageDescr="/volume1"}}')
# Wachstum in Bytes/s. Die Blockgroesse kommt aus der Metrik selbst und ist
# nicht als 16384 einprogrammiert — sonst rechnete das Panel falsch, sobald
# ein Volume mit anderer Blockgroesse dazukommt.
VOL_GROWTH = (f'(scalar(deriv(hrStorageUsed{{{J},hrStorageDescr="/volume1"}}[24h])) '
              f'* scalar(hrStorageAllocationUnits{{{J},hrStorageDescr="/volume1"}}))')

panels.append(row("Pool und Volume", 0))

panels.append(timeline(
    "RAID-Zustand", f'raidStatus{{{J}}}', {"h": 5, "w": 12, "x": 0, "y": 1},
    "{{raidName}}", RAID_STATUS,
    desc="Zwei Zeilen: der Speicherpool und das darauf liegende Volume. "
         "Beide stehen im Normalfall auf 1. Die gelben Zustaende (Reparatur, "
         "Migration, Erweiterung, Data-Scrubbing) sind Arbeitsvorgaenge und "
         "kein Fehler — sie erklaeren aber, warum das NAS in dieser Zeit "
         "langsam ist. Rot ab 11 bedeutet degradiert oder abgestuerzt."))

panels.append(stat(
    "Volume 1 belegt",
    f'100 * (raidTotalSize{{{J},raidName="Volume 1"}} '
    f'- raidFreeSize{{{J},raidName="Volume 1"}}) '
    f'/ raidTotalSize{{{J},raidName="Volume 1"}}',
    {"h": 5, "w": 4, "x": 12, "y": 1}, unit="percent", dec=1, graph=True,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 80},
                {"color": "orange", "value": 90},
                {"color": "red", "value": 95}],
    desc="Deckt sich mit der hrStorage-Angabe fuer /volume1 — zwei "
         "unabhaengige SNMP-Tabellen, die dasselbe sagen. Bewusst NICHT auf "
         "den Speicherpool angewandt: der steht rechnerisch immer bei "
         "100 %, siehe Tabelle unten."))

panels.append(stat(
    "Volume 1 frei", f'raidFreeSize{{{J},raidName="Volume 1"}}',
    {"h": 5, "w": 4, "x": 16, "y": 1}, unit="bytes", dec=2, graph=True,
    thresholds=[{"color": "red", "value": None},
                {"color": "orange", "value": 500 * 1024**3},
                {"color": "green", "value": 1024**4}],
    desc="Absolut statt prozentual, weil bei 17,5 TiB Gesamtgroesse ein "
         "Prozentpunkt schon 175 GiB sind. Rot unter 500 GiB, gruen ab "
         "1 TiB."))

panels.append(stat(
    "Tage bis voll",
    f'scalar(raidFreeSize{{{J},raidName="Volume 1"}}) / ({VOL_GROWTH} > 0) / 86400',
    {"h": 5, "w": 4, "x": 20, "y": 1}, unit="d", dec=0,
    thresholds=[{"color": "red", "value": None},
                {"color": "orange", "value": 60},
                {"color": "yellow", "value": 180},
                {"color": "green", "value": 365}],
    desc="Freier Platz geteilt durch das Wachstum der letzten 24 h. Der "
         "Filter > 0 ist Absicht: schrumpft das Volume gerade, zeigt das "
         "Panel KEINEN Wert statt einer negativen Tageszahl.\n\n"
         "Die Zahl ist eine lineare Fortschreibung eines Tagesmittels und "
         "keine Prognose — ein einzelner grosser Kopiervorgang zieht sie "
         "stark nach unten. Ausserdem laeuft der Scrape-Job erst seit dem "
         "2026-08-23, die Datenbasis ist also noch schmal und wird mit der "
         "Zeit belastbarer."))

panels.append(table(
    "Speicherpool gegen Volume",
    [tgt(f'raidTotalSize{{{J}}}', instant=True, fmt="table", ref="A"),
     tgt(f'raidFreeSize{{{J}}}', instant=True, fmt="table", ref="B"),
     tgt(f'100 * (raidTotalSize{{{J}}} - raidFreeSize{{{J}}}) '
         f'/ raidTotalSize{{{J}}}', instant=True, fmt="table", ref="C"),
     tgt(f'raidHotspareCnt{{{J}}}', instant=True, fmt="table", ref="D")],
    {"h": 6, "w": 12, "x": 0, "y": 6},
    [{"id": "joinByField", "options": {"byField": "raidName", "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": drop_cols(noise(["raidIndex"])),
         "renameByName": {"raidName": "Einheit", "Value #A": "Gesamt",
                          "Value #B": "Frei", "Value #C": "Belegt bzw. zugeteilt",
                          "Value #D": "Reserveplatten"}}}],
    overrides=[
        {"matcher": {"id": "byRegexp", "options": "^(Gesamt|Frei)$"},
         "properties": [{"id": "unit", "value": "bytes"},
                        {"id": "decimals", "value": 2}]},
        {"matcher": {"id": "byName", "options": "Belegt bzw. zugeteilt"},
         "properties": [{"id": "unit", "value": "percent"},
                        {"id": "decimals", "value": 1}]},
        {"matcher": {"id": "byName", "options": "Reserveplatten"},
         "properties": [{"id": "decimals", "value": 0}]}],
    desc="Die Spalte heisst absichtlich \"Belegt bzw. zugeteilt\", weil sie "
         "fuer die beiden Zeilen Verschiedenes bedeutet.\n\n"
         "Storage Pool 1 steht bei 100 % und meldet 188 MiB frei von "
         "18,18 TiB. Das ist KEIN Platzmangel: der Pool ist vollstaendig an "
         "Volume 1 zugeteilt, so wie es sein soll. Erst wenn ein zweites "
         "Volume angelegt werden soll, wird diese Zahl relevant.\n\n"
         "Volume 1 bei 89,7 % ist die Zahl, auf die es ankommt — das ist "
         "der tatsaechlich belegte Platz. Reserveplatten 0 heisst: faellt "
         "eine Platte aus, springt nichts automatisch ein, die Wiederher"
         "stellung beginnt erst nach dem Tausch."))

panels.append(ts(
    "/volume1 — belegt im Verlauf",
    [tgt(VOL_USED, "belegt"),
     tgt(f'hrStorageSize{{{J},hrStorageDescr="/volume1"}} '
         f'* on(hrStorageIndex) group_left() '
         f'hrStorageAllocationUnits{{{J},hrStorageDescr="/volume1"}}',
         "Gesamtgroesse", ref="B")],
    {"h": 6, "w": 12, "x": 12, "y": 6}, unit="bytes", dec=2, minv=0, fill=6,
    desc="Belegung und Gesamtgroesse in Bytes. Die Blockgroesse wird aus "
         "hrStorageAllocationUnits geholt und nicht als 16384 fest "
         "eingetragen — sonst rechnete das Panel falsch, sobald ein Volume "
         "mit anderer Blockgroesse dazukommt.\n\n"
         "Der Abstand zwischen beiden Kurven ist der freie Platz. Eine "
         "Stufe nach oben ist ein Kopiervorgang, ein Absacken eine "
         "Loeschung oder ein abgelaufener Snapshot."))

panels.append(row("Dateisysteme", 12))

panels.append(bargauge(
    "Belegung je Dateisystem",
    f'100 * hrStorageUsed{{{J},{FS}}} / (hrStorageSize{{{J},{FS}}} > 0)',
    {"h": 8, "w": 10, "x": 0, "y": 13}, "{{hrStorageDescr}}", unit="percent", dec=1,
    thresholds=[{"color": "green", "value": None},
                {"color": "yellow", "value": 80},
                {"color": "orange", "value": 90},
                {"color": "red", "value": 95}],
    desc="Neun Zeilen statt 46. Die DS918+ meldet 46 hrStorage-Eintraege, "
         "aber 30 davon sind Bind-Mounts desselben btrfs-Dateisystems "
         "unter /volume1/@appdata/ContainerManager/all_shares/*, dazu "
         "/volume1/@docker und ein Snapshot-Pfad. Alle tragen exakt "
         "dieselbe Groesse und Belegung wie /volume1 — ungefiltert stuende "
         "hier 31-mal die Zahl 89,7 untereinander.\n\n"
         "Der Filter hrStorageDescr!~\"/volume1/.+\" laesst /volume1 selbst "
         "stehen und wirft alles darunter weg. Der Praefix-Filter "
         "hrStorageDescr=~\"/.*\" haelt zusaetzlich die "
         "Arbeitsspeicher-Eintraege heraus, die hrStorage ebenfalls fuehrt "
         "(Physical memory, Cached memory, Swap space) — die gehoeren ins "
         "Uebersichts-Dashboard, nicht in eine Dateisystemliste."))

panels.append(table(
    "Dateisysteme",
    [tgt(f'hrStorageSize{{{J},{FS}}} * hrStorageAllocationUnits{{{J},{FS}}}',
         instant=True, fmt="table", ref="A"),
     tgt(f'hrStorageUsed{{{J},{FS}}} * hrStorageAllocationUnits{{{J},{FS}}}',
         instant=True, fmt="table", ref="B"),
     tgt(f'(hrStorageSize{{{J},{FS}}} - hrStorageUsed{{{J},{FS}}}) '
         f'* hrStorageAllocationUnits{{{J},{FS}}}',
         instant=True, fmt="table", ref="C"),
     tgt(f'100 * hrStorageUsed{{{J},{FS}}} / (hrStorageSize{{{J},{FS}}} > 0)',
         instant=True, fmt="table", ref="D"),
     tgt(f'hrStorageAllocationUnits{{{J},{FS}}}', instant=True, fmt="table",
         ref="E")],
    {"h": 8, "w": 14, "x": 10, "y": 13},
    [{"id": "joinByField", "options": {"byField": "hrStorageDescr",
                                       "mode": "outer"}},
     {"id": "organize", "options": {
         "excludeByName": drop_cols(noise(["hrStorageIndex"])),
         "renameByName": {"hrStorageDescr": "Dateisystem", "Value #A": "Gesamt",
                          "Value #B": "Belegt", "Value #C": "Frei",
                          "Value #D": "Belegt %", "Value #E": "Blockgroesse"}}}],
    overrides=[
        {"matcher": {"id": "byRegexp", "options": "^(Gesamt|Belegt|Frei)$"},
         "properties": [{"id": "unit", "value": "bytes"},
                        {"id": "decimals", "value": 2}]},
        {"matcher": {"id": "byName", "options": "Belegt %"},
         "properties": [{"id": "unit", "value": "percent"},
                        {"id": "decimals", "value": 1},
                        {"id": "custom.cellOptions",
                         "value": {"type": "gauge", "mode": "gradient"}},
                        {"id": "max", "value": 100}, {"id": "min", "value": 0},
                        {"id": "thresholds", "value": {
                            "mode": "absolute",
                            "steps": [{"color": "green", "value": None},
                                      {"color": "yellow", "value": 80},
                                      {"color": "orange", "value": 90},
                                      {"color": "red", "value": 95}]}}]},
        {"matcher": {"id": "byName", "options": "Blockgroesse"},
         "properties": [{"id": "unit", "value": "bytes"},
                        {"id": "decimals", "value": 0},
                        {"id": "custom.width", "value": 105}]}],
    sort_by="Belegt", desc_sort=True,
    desc="Dieselben neun Dateisysteme wie im Balkenpanel links, aber mit "
         "absoluten Zahlen. Die Spalte Blockgroesse steht hier, weil sie "
         "erklaert, wie die Byte-Werte zustande kommen: hrStorage zaehlt "
         "Bloecke, nicht Bytes. /volume1 rechnet mit 16 KiB, die "
         "tmpfs-Dateisysteme mit 4 KiB.\n\n"
         "Die Einheit bytes ist einzeln je Spalte gesetzt und nicht als "
         "Tabellen-Vorgabe — sonst bekaeme auch die Blockgroesse-Spalte "
         "eine sinnlose Byte-Formatierung und die Prozentspalte stuende in "
         "Bytes da."))

panels.append(row("E/A je Platte", 21))

panels.append(ts(
    "Datendurchsatz je Platte",
    [tgt(f'rate(storageIONReadX{{{J}}}[10m])', "lesen {{storageIODevice}}"),
     tgt(f'- rate(storageIONWrittenX{{{J}}}[10m])', "schreiben {{storageIODevice}}",
         ref="B")],
    {"h": 8, "w": 12, "x": 0, "y": 22}, unit="Bps", dec=1, fill=6,
    desc="Lesen nach oben, Schreiben nach unten — das Minus vor der "
         "Schreibrate ist Darstellung, kein Rechenfehler.\n\n"
         "Benutzt werden die X-Varianten der Zaehler. Die kurzen Fassungen "
         "storageIONRead und storageIONWritten sind Counter32 und stehen "
         "bereits bei 55 bis 75 % von 2^32; sie laufen also regelmaessig "
         "ueber. Die X-Fassungen sind Counter64.\n\n"
         "Dass nvme0n1 und nvme1n1 identisch schreiben, ist richtig so: der "
         "SSD-Cache ist gespiegelt. Dass sda deutlich weniger schreibt als "
         "sdb bis sdd, liegt an SHR mit gemischten Plattengroessen — sda "
         "ist die 4-TB-Platte unter drei 8-TB-Platten und traegt nur den "
         "unteren Bereich des Verbunds."))

panels.append(ts(
    "E/A-Vorgaenge je Platte",
    [tgt(f'rate(storageIOReads{{{J}}}[10m])', "lesen {{storageIODevice}}"),
     tgt(f'- rate(storageIOWrites{{{J}}}[10m])', "schreiben {{storageIODevice}}",
         ref="B")],
    {"h": 8, "w": 12, "x": 12, "y": 22}, unit="iops", dec=1, fill=6,
    desc="Vorgaenge statt Bytes, wieder Lesen oben und Schreiben unten. Der "
         "Vergleich mit dem Durchsatzpanel links zeigt die mittlere "
         "Anfragegroesse: viele Vorgaenge bei wenig Durchsatz bedeuten "
         "kleine, verstreute Zugriffe — genau das, was Festplatten "
         "ausbremst und wofuer der SSD-Cache da ist."))

panels.append(ts(
    "Auslastung je Platte",
    [tgt(f'storageIOLA1{{{J}}}', "{{storageIODevice}}")],
    {"h": 7, "w": 12, "x": 0, "y": 30}, unit="percent", dec=0, minv=0, maxv=100,
    fill=4,
    desc="storageIOLA1 ist das 1-Minuten-Mittel der Geraeteauslastung, "
         "vergleichbar mit der Spalte %util aus iostat — der Anteil der "
         "Zeit, in dem mindestens ein Vorgang anstand. Dauerhaft nahe 100 "
         "heisst, dass die Platte die Warteschlange nicht mehr abarbeitet.\n\n"
         "Die Werte kommen bereits als Prozentzahl aus der MIB und werden "
         "nicht umgerechnet."))

panels.append(ts(
    "E/A des Volumes",
    [tgt(f'rate(spaceIONReadX{{{J}}}[10m])', "lesen {{spaceIODevice}}"),
     tgt(f'- rate(spaceIONWrittenX{{{J}}}[10m])', "schreiben {{spaceIODevice}}",
         ref="B")],
    {"h": 7, "w": 12, "x": 12, "y": 30}, unit="Bps", dec=1, fill=6,
    desc="Dieselbe Messung eine Ebene hoeher: dm-2 ist das Device-Mapper-"
         "Geraet unter /volume1, also die Sicht der Anwendungen auf den "
         "gesamten Verbund. Der Vergleich mit der Summe der Einzelplatten "
         "zeigt, was RAID-Paritaet und SSD-Cache zusaetzlich an "
         "Schreiblast erzeugen — deshalb stehen die beiden Panels "
         "nebeneinander und sind bewusst nicht zusammengerechnet."))

write(build(
    UID_STORAGE, "Synology DS918+ — Speicher und E/A",
    "Speicherpool, Volume, Dateisysteme und Ein-/Ausgabelast der Synology "
    "DS918+ (192.168.2.3). Quelle ist der Scrape-Job snmp-synology.\n\n"
    "Kein iSCSI: es gibt genau eine LUN, deren Leistungswerte (Latenz, "
    "IOPS, Durchsatz, Warteschlange) ueber die gesamte Vorhaltezeit "
    "konstant 0 sind. Der einzige Wert ungleich 0 ist bis auf Rundung "
    "identisch mit raidFreeSize des Volumes und steht dort bereits. "
    "Erzeugt von .gen-synology-detail.py — Aenderungen dort vornehmen, "
    "nicht im UI.",
    ["synology", "nas", "storage", "snmp"], panels,
    [dlink("Uebersicht NAS", UID_OVERVIEW), dlink("Platten und SMART", UID_SMART),
     dlink("Netzwerk", UID_NET)]),
    "synology-storage.json")
