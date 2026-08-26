#!/usr/bin/env python3
# =============================================================================
# Generator fuer home-overview.json — der Leitstand (Ebene 1)
# =============================================================================
# Gebaut nach docs/LEITSTAND-DESIGN-EEMUA-201.md, Abschnitt 9. Die acht Regeln
# sind hier keine Dekoration — jede hat eine sichtbare Entsprechung im Code:
#
#   R1  Jede Query liefert im Gesundzustand einen WERT. Kein Panel ohne targets.
#       Jede Zaehlung nennt ihren Nenner (text_mode="value_and_name" bzw. der
#       Nenner steht im Titel). Verifiziert mit .verify-home-overview.sh.
#   R2  Gesaettigte Farbe NUR fuer Abweichung. Basis-Schwelle ist ueberall
#       "text" — im Normalbetrieb ist das Bild farblos. Rot nur fuer critical,
#       Orange fuer warning. colorMode "background" ausschliesslich am Alarm-
#       panel.
#   R3  Eine Farbe, eine Bedeutung. Jeder farbige Zustand traegt zusaetzlich
#       einen Text (mappings), ist also in Graustufen lesbar.
#   R4  Keine Zahl ohne Bezugsgroesse: Sollwert im Titel, eingezeichnete Grenze
#       (max/thresholds im Gauge) oder Sparkline (graphMode "area").
#   R5  <= 12 Inhaltspanels, <= 24 Rastereinheiten, kein Scrollen. Gegliedert
#       nach der Abhaengigkeitskette Strom -> Messweg -> Plattform -> Kapazitaet
#       -> Dienste, NICHT nach Herstellern.
#   R6  Jedes Panel hat einen Drill-down auf sein Ebene-2-Dashboard, und jeder
#       Link nimmt den Zeitbereich mit (${__url_time_range}).
#   R7  Genau EINE Alarmkachel: firing, ohne info, nach Schwere. Erledigte
#       Alarme in einer eingeklappten Row — ausgeblendet, aber erreichbar.
#   R8  Der Leitstand zeigt seinen eigenen Ausfall: Datenalter und Zustand der
#       Datenquellen stehen im Panel "Vertraue ich dieser Anzeige?".
#
# Aufruf:  python3 .gen-home-overview.py > home-overview.json
# =============================================================================
import json

DS = {"type": "prometheus", "uid": "victoriametrics"}

# --- Schwellen -------------------------------------------------------------
# R2: Basis IMMER "text" (farblos). Farbe erst ab Abweichung.
def steps(warn=None, crit=None, base="text"):
    s = [{"color": base, "value": None}]
    if warn is not None:
        s.append({"color": "orange", "value": warn})
    if crit is not None:
        s.append({"color": "red", "value": crit})
    return s

# Invers: kleiner Wert ist schlechter (Restlaufzeit, Batterieladung ...)
def steps_low(crit, warn, base="text"):
    return [{"color": "red", "value": None},
            {"color": "orange", "value": crit},
            {"color": base, "value": warn}]

_id = [0]
def nid():
    _id[0] += 1
    return _id[0]

def tgt(expr, legend="", ref="A", instant=True):
    return {"datasource": DS, "editorMode": "code", "expr": expr,
            "legendFormat": legend, "instant": instant, "range": not instant,
            "refId": ref}

# R6: Drill-down mit Zeitbereich. ${__url_time_range} traegt from/to weiter.
def link(title, uid):
    return [{"title": title, "url": "/d/%s?${__url_time_range}" % uid,
             "targetBlank": False}]

def stat(title, targets, gp, unit="none", dec=0, thr=None, mappings=None,
         desc="", links=None, graph=False, text_mode="auto", orient="auto"):
    return {
        "id": nid(), "type": "stat", "title": title, "description": desc,
        "datasource": DS, "gridPos": gp, "targets": targets,
        "links": links or [],
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec, "mappings": mappings or [],
            "thresholds": {"mode": "absolute", "steps": thr or steps()},
            "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"colorMode": "value", "graphMode": "area" if graph else "none",
                    "justifyMode": "auto", "orientation": orient,
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "textMode": text_mode, "wideLayout": True},
    }

def bargauge(title, targets, gp, unit="percent", dec=1, thr=None, desc="",
             links=None, mx=100, mn=0):
    return {
        "id": nid(), "type": "bargauge", "title": title, "description": desc,
        "datasource": DS, "gridPos": gp, "targets": targets, "links": links or [],
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec, "min": mn, "max": mx, "mappings": [],
            "thresholds": {"mode": "absolute", "steps": thr or steps()},
            "color": {"mode": "thresholds"}}, "overrides": []},
        # R4: showUnfilled + max zeichnet die Bezugsgroesse sichtbar mit ein.
        "options": {"displayMode": "gradient", "orientation": "horizontal",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showUnfilled": True, "valueMode": "text", "namePlacement": "left",
                    "minVizHeight": 16, "minVizWidth": 8, "sizing": "auto"},
    }

def row(title, gp, collapsed=False, panels=None):
    return {"id": nid(), "type": "row", "title": title, "gridPos": gp,
            "collapsed": collapsed, "panels": panels or []}

# --- R7: die eine Alarmkachel ---------------------------------------------
def alertlist(title, gp, states, desc="", maxitems=5, label_filter="", links=None):
    return {
        "id": nid(), "type": "alertlist", "title": title, "description": desc,
        "gridPos": gp, "links": links or [],
        "options": {
            "alertInstanceLabelFilter": label_filter,
            "alertName": "", "dashboardAlerts": False, "dashboardTitle": "",
            "datasource": "", "folder": "", "groupBy": [], "groupMode": "default",
            "maxItems": maxitems,
            "sortOrder": 3,          # 3 = nach Wichtigkeit (severity)
            "stateFilter": states,
            "viewMode": "list", "showInstances": True, "showOptions": "current",
            "tags": [],
        },
    }

FIRING = {"firing": True, "pending": False, "noData": False,
          "normal": False, "error": True, "recovering": False}
RESOLVED = {"firing": False, "pending": False, "noData": False,
            "normal": True, "error": False, "recovering": True}

P = []

# =============================================================================
# ZEILE 1 (y=0..6) — Alarme + Strom + Vertrauen in die Anzeige
# =============================================================================
# R7: EINE Alarmkachel, firing, ohne info, nach Schwere sortiert.
# severity!="info" haelt reine Dashboard-Befunde aus der Handlungsliste.
P.append(alertlist(
    "Anstehende Alarme", {"h": 7, "w": 10, "x": 0, "y": 0}, FIRING,
    label_filter='{severity!="info"}',
    links=[{"title": "Alle Alarmregeln", "url": "/alerting/list", "targetBlank": False}],
    desc=("Nur anstehende Alarme, info ausgeschlossen, nach Schwere sortiert. "
          "Zielwert laut Alarmdesign: hoechstens 2 gleichzeitig, 0 laenger als "
          "72 h. Steht hier '+ N weitere', ist nicht die Anlage lauter geworden "
          "— dann ist das Alarmsystem ueber seinem Zielwert. "
          "Erledigte Alarme: Zeile 'Zuletzt erledigt' unten aufklappen."),
))

# --- Strom: traegt alles darunter -----------------------------------------
# R1: upsInfoStatus ist ein LABEL, kein Wert. Bei Netzausfall wechselt es auf
# "OB DISCHRG" und die Serie {upsInfoStatus="OL"} VERSCHWINDET, statt auf 0 zu
# fallen. Ohne 'or vector(0)' waere "Batteriebetrieb" von "SNMP tot" nicht zu
# unterscheiden.
P.append(stat(
    "Strom", [
        tgt('(max(upsInfoStatus{upsInfoStatus="OL"}) or vector(0))', "Netz", "A"),
        tgt('max(upsBatteryRuntimeValue)/60', "Restlaufzeit", "B"),
        tgt('max(upsInfoRealPowerValue)', "Last", "C"),
    ],
    {"h": 7, "w": 7, "x": 10, "y": 0},
    text_mode="value_and_name", orient="vertical",
    desc=("Eaton Ellipse PRO 650 an der Synology. Die Restlaufzeit gilt fuer "
          "die aktuelle Last — bei ~190 W sind es rund 5 Minuten. "
          "ACHTUNG: SNMP und Home Assistant lesen denselben NUT-Daemon auf der "
          "Synology; sie sind KEINE unabhaengige Bestaetigung. Faellt die "
          "Synology aus, sind beide Wege gleichzeitig blind."),
    links=link("USV — Stromversorgung", "ups-power"),
    mappings=[{"type": "value", "options": {
        "0": {"text": "BATTERIE", "color": "red", "index": 0},
        "1": {"text": "Netz", "index": 1}}}],
    thr=steps(),
))

# --- R8: Der Leitstand zeigt seinen eigenen Ausfall ------------------------
P.append(stat(
    "Vertraue ich dieser Anzeige?", [
        tgt('count(up==0) or vector(0)', "Ziele down (von 38)", "A"),
        # Der PVE-Metrikserver PUSHT (InfluxDB-Line-Protocol) und hat deshalb
        # KEIN up{}. Ohne diesen Waechter laufen die Hypervisor-Panels nach 5
        # Minuten still leer, statt einen Ausfall zu melden.
        tgt('max(time()-timestamp(cpustat_avg1{object="nodes"}))', "PVE-Push-Alter", "B"),
        # Loki meldet up=1 und laesst den Empfangszaehler laufen, waehrend es
        # die Zeilen verwirft. Nur diese Quote macht den Ausfall sichtbar.
        tgt('(100*sum(rate(loki_discarded_samples_total[30m]))'
            '/sum(rate(loki_distributor_lines_received_total[30m]))) or vector(0)',
            "Logzeilen verworfen", "C"),
    ],
    {"h": 7, "w": 7, "x": 17, "y": 0},
    text_mode="value_and_name", orient="vertical",
    desc=("Diese Kachel misst den Messweg selbst. Ein Leitstand, der seinen "
          "eigenen Ausfall nicht anzeigen kann, ist gefaehrlicher als keiner. "
          "PVE-Push-Alter > 120 s heisst: die Hypervisor-Panels zeigen "
          "Vergangenheit. Verworfene Logzeilen > 5 % heissen: der Log-Kanal "
          "ist tot, obwohl up=1 meldet. "
          "NICHT abgedeckt: Grafana wird selbst nicht gescrapt, und es gibt "
          "keine Swarm-Task-Metriken — ein Dienst, der nicht eingeplant werden "
          "kann, ist hier unsichtbar."),
    links=link("VictoriaMetrics", "victoriametrics"),
    thr=steps(), dec=0,
))

# =============================================================================
# ZEILE 2 (y=7..11) — Plattform: Ceph, Hypervisoren, Swarm, Datenbank
# =============================================================================
# R1: ceph_osd_up==0 ist im Gesundzustand LEER. Die Differenz zum Sollwert 3
# liefert dagegen immer einen Wert. 'or vector(-1)' unterscheidet "alles ok"
# von "MGR weg" — alle Cluster-Metriken kommen NUR vom aktiven MGR, und bei
# einem MGR-Failover wechselt das instance-Label.
P.append(stat(
    "Ceph", [
        tgt('max(ceph_health_status) or vector(-1)', "Health", "A"),
        tgt('(3 - sum(ceph_osd_up)) or vector(-1)', "OSDs down (von 3)", "B"),
        tgt('(sum(ceph_pg_total)-sum(ceph_pg_clean)) or vector(-1)', "PGs nicht clean", "C"),
    ],
    {"h": 5, "w": 6, "x": 0, "y": 7},
    text_mode="value_and_name", orient="vertical",
    desc=("Health 0=OK, 1=WARN, 2=ERR, -1=Manager nicht erreichbar. "
          "Alle Cluster-Metriken kommen ausschliesslich vom AKTIVEN MGR; die "
          "beiden Standbys melden up=1, liefern aber nur 7 statt 875 Serien. "
          "Deshalb ueberall max()/sum() ueber instance."),
    links=link("Ceph Storage Cluster", "ceph-storage-drill-down"),
    mappings=[{"type": "value", "options": {
        "-1": {"text": "MGR WEG", "color": "red", "index": 0},
        "0": {"text": "OK", "index": 1},
        "1": {"text": "WARN", "color": "orange", "index": 2},
        "2": {"text": "ERR", "color": "red", "index": 3}}}],
    thr=steps(warn=1, crit=2),
))

# R4: Prozent mit eingezeichneter Grenze statt nackter Zahl.
P.append(bargauge(
    "Hypervisoren — RAM", [
        tgt('100*(1-node_memory_MemAvailable_bytes{job="pve-node-exporter"}'
            '/node_memory_MemTotal_bytes{job="pve-node-exporter"})', "{{host}}", "A"),
    ],
    {"h": 5, "w": 6, "x": 6, "y": 7},
    thr=steps(warn=88, crit=93),
    desc=("Belegter Arbeitsspeicher der drei Proxmox-Hosts. Quelle ist der "
          "node-exporter auf dem Blech (hat up{} und ist damit "
          "ausfallerkennbar), NICHT der pvestatd-Push. "
          "pve01 und pve03 haben nur 15 GB und sind dauerhaft hoch belegt — "
          "das ist der Normalzustand, nicht der Alarm."),
    links=link("Proxmox Hypervisoren", "pve-hosts"),
))

# Der Balloon-BODEN ist die Kapazitaet, gegen die Swarm plant — nicht memory:.
P.append(bargauge(
    "Swarm-Nodes — RAM", [
        tgt('100*(1-node_memory_MemAvailable_bytes{job="node-exporter",instance=~"docker-infra-.*"}'
            '/node_memory_MemTotal_bytes{job="node-exporter",instance=~"docker-infra-.*"})',
            "{{instance}}", "A"),
    ],
    {"h": 5, "w": 6, "x": 12, "y": 7},
    thr=steps(warn=85, crit=92),
    desc=("Ist-Belegung der drei Swarm-VMs. Wichtig: Der Swarm-SCHEDULER sieht "
          "diesen Wert NICHT — er plant ausschliesslich gegen die Summe der "
          "reservations und gegen eine Node-Kapazitaet, die beim Start des "
          "Docker-Daemons eingefroren wurde. Ein Node kann hier harmlos "
          "aussehen und trotzdem keinen neuen Dienst mehr aufnehmen."),
    links=link("Node Exporter Full", "rYdddlPWk"),
))

P.append(stat(
    "Datenbank", [
        tgt('min_over_time(pg_up{instance="postgres-prod"}[3m])', "postgres-prod", "A"),
        tgt('100*sum(pg_stat_activity_count)/max(pg_settings_max_connections)',
            "Verbindungen (von 100)", "B"),
        tgt('sum(rate(pg_stat_database_xact_commit[5m]))', "Transaktionen/s", "C"),
    ],
    {"h": 5, "w": 6, "x": 18, "y": 7},
    text_mode="value_and_name", orient="vertical", dec=0,
    desc=("Eine einzelne PostgreSQL-VM (4600), kein Patroni-Cluster mehr. "
          "Es gibt KEINE Replikation — pg_replication_lag_seconds liefert auf "
          "einem Primary strukturell immer 0 und ist deshalb hier bewusst "
          "nicht dargestellt."),
    links=link("PostgreSQL — postgres-prod", "postgres-prod-singlevm"),
    mappings=[{"type": "value", "options": {
        "0": {"text": "DOWN", "color": "red", "index": 0},
        "1": {"text": "laeuft", "index": 1}}}],
    thr=steps(),
))

# =============================================================================
# ZEILE 3 (y=12..17) — Kapazitaet und Dienste
# =============================================================================
# R4: bargauge mit min=0/max=100 und showUnfilled zeichnet die Bezugsgroesse
# sichtbar mit. Eine nackte "89,8" saehe genauso aus wie eine nackte "12,3".
P.append(bargauge(
    "Kapazitaet — wo laeuft es zuerst voll?", [
        tgt('100*(1-raidFreeSize{raidName="Volume 1"}/raidTotalSize{raidName="Volume 1"})',
            "Synology Volume 1", "A"),
        tgt('100*max(pbs_used)/max(pbs_size)', "PBS Datastore", "B"),
        tgt('max(100*(1-node_filesystem_avail_bytes{mountpoint="/srv/data"}'
            '/node_filesystem_size_bytes{mountpoint="/srv/data"}))',
            "/srv/data (voller Node)", "C"),
        tgt('100*max(ceph_cluster_total_used_bytes)/max(ceph_cluster_total_bytes)',
            "Ceph Cluster", "D"),
        tgt('max(100*(1-node_filesystem_avail_bytes{mountpoint="/mnt/cephfs"}'
            '/node_filesystem_size_bytes{mountpoint="/mnt/cephfs"}))', "CephFS", "E"),
        # Als VERSCHLEISS statt Restlebensdauer, damit die Skala mit den
        # uebrigen Balken zusammenpasst: groesser = naeher am Ende. 28 %
        # Restlebensdauer sind 72 % verschlissen.
        # Steht hier, weil es genau NICHT in den Alarmkanal gehoert: Der Wert
        # bewegt sich um wenige Prozent im Monat. Der Alarm greift erst bei
        # 15 % Rest (= 85 % hier) und erinnert dann monatlich; alles davor ist
        # Beobachtung, keine Handlung.
        tgt('100 - min(diskRemainLife{job="snmp-synology"} >= 0)',
            "SSD-Verschleiss (Cache)", "F"),
    ],
    {"h": 6, "w": 10, "x": 0, "y": 12},
    thr=steps(warn=80, crit=90),
    desc=("Der SSD-Verschleiss steht bewusst hier und nicht im Alarmkanal: Er "
          "bewegt sich um wenige Prozent im Monat, und ein taeglicher Alarm "
          "darueber traegt keine neue Information. "
          "NICHT enthalten: 'Storage Pool 1' der Synology steht bei 99,999 % — "
          "das ist der NORMALZUSTAND (vollstaendig an das Volume vergeben) und "
          "kein Alarm. Ebenso weggelassen: der Frigate-Aufnahmespeicher, weil "
          "er dieselbe Platte misst wie Synology Volume 1. "
          "pbs_used erscheint unter zwei Datastore-Namen mit identischen Werten "
          "— deshalb max(), nicht sum()."),
    links=link("Synology DS918+", "synology-nas"),
))

# R1 + R3: Tabelle statt Ampel — der Zustand steht als WORT da, nicht nur als
# Farbe, und ist damit in Graustufen lesbar.
P.append({
    "id": nid(), "type": "table", "title": "Dienste — von aussen geprueft",
    "description": ("Blackbox-Proben auf die oeffentlichen Endpunkte. "
                    "HTTP 302 und 401 sind NORMAL (Weiterleitung auf Login "
                    "bzw. Authentik) — nur probe_success zaehlt. "
                    "Diese Zeile ist bei Anwendungen ohne HTTP-Endpunkt blind: "
                    "am 2026-08-25 war Paperless vier Stunden weg, und nur "
                    "diese Probe hat es bemerkt."),
    "datasource": DS, "gridPos": {"h": 6, "w": 14, "x": 10, "y": 12},
    "links": link("VictoriaMetrics", "victoriametrics"),
    "targets": [
        {"datasource": DS, "editorMode": "code", "instant": True, "range": False,
         "format": "table", "expr": 'probe_success{job=~"blackbox-.*"}', "refId": "A"},
        {"datasource": DS, "editorMode": "code", "instant": True, "range": False,
         "format": "table", "expr": 'probe_http_status_code{job=~"blackbox-.*"}', "refId": "B"},
        {"datasource": DS, "editorMode": "code", "instant": True, "range": False,
         "format": "table",
         "expr": '(probe_ssl_earliest_cert_expiry-time())/86400', "refId": "C"},
    ],
    "transformations": [
        {"id": "joinByField", "options": {"byField": "instance", "mode": "outer"}},
        {"id": "organize", "options": {
            "excludeByName": {"Time": True, "Time 1": True, "Time 2": True, "Time 3": True,
                              "job": True, "job 1": True, "job 2": True, "job 3": True,
                              "__name__": True, "__name__ 1": True, "__name__ 2": True,
                              "__name__ 3": True},
            "renameByName": {"instance": "Ziel", "Value #A": "Zustand",
                             "Value #B": "HTTP", "Value #C": "Zert. Tage"}}},
        {"id": "sortBy", "options": {"fields": {}, "sort": [{"field": "Zustand"}]}},
    ],
    "fieldConfig": {"defaults": {
        "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": False},
        "thresholds": {"mode": "absolute", "steps": steps()},
        "color": {"mode": "thresholds"}, "mappings": []},
        "overrides": [
            {"matcher": {"id": "byName", "options": "Zustand"},
             "properties": [
                 {"id": "mappings", "value": [{"type": "value", "options": {
                     "0": {"text": "AUSGEFALLEN", "color": "red", "index": 0},
                     "1": {"text": "erreichbar", "index": 1}}}]},
                 {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                 {"id": "custom.width", "value": 130}]},
            {"matcher": {"id": "byName", "options": "Zert. Tage"},
             "properties": [
                 {"id": "decimals", "value": 0}, {"id": "unit", "value": "d"},
                 {"id": "thresholds", "value": {"mode": "absolute",
                     "steps": steps_low(7, 21)}},
                 {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                 {"id": "custom.width", "value": 110}]},
            {"matcher": {"id": "byName", "options": "HTTP"},
             "properties": [{"id": "custom.width", "value": 80},
                            {"id": "decimals", "value": 0}]},
        ]},
    "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False},
                "sortBy": [{"displayName": "Zustand", "desc": False}]},
})

# =============================================================================
# ZEILE 4 (y=18..22) — Sicherung, Kameras, Netz
# =============================================================================
# R1: Der Join gegen system_uptime ist PFLICHT. pbs_snapshot_vm_last_timestamp
# traegt 12 Karteileichen geloeschter Gaeste (bis 241 Tage alt) — ohne Join
# alarmiert die Kachel auf ewig auf Geistern.
P.append(stat(
    "Sicherung", [
        tgt('max((time()-pbs_snapshot_vm_last_timestamp) and on(vm_id) '
            'label_replace(system_uptime{object=~"qemu|lxc"},"vm_id","$1","vmid","(.+)"))/3600',
            "aeltestes Backup (Ziel < 48 h)", "A"),
        tgt('100*max(pbs_used)/max(pbs_size)', "PBS belegt", "B"),
    ],
    {"h": 5, "w": 8, "x": 0, "y": 18},
    text_mode="value_and_name", orient="vertical", dec=1,
    desc=("Alter der juengsten Sicherung ueber alle LEBENDEN Gaeste. Der Join "
          "gegen system_uptime blendet 12 Karteileichen aus — Eintraege "
          "geloeschter Gaeste, bis zu 241 Tage alt, die sich nie wieder "
          "aendern. "
          "OFFEN: pbs_snapshot_vm_last_verify steht bei fast allen lebenden "
          "Gaesten auf 0 — die aktuellen Sicherungen sind unverifiziert."),
    links=link("Proxmox Backup Server", "pbs-overview"),
    thr=steps(warn=48, crit=72),
))

# R1: detection_fps ist bewegungsabhaengig und nachts legitim 0 — als
# Defektindikator unbrauchbar. Nur die Inferenzzeit zeigt einen Detektor-Hang.
P.append(stat(
    "Kameras", [
        tgt('max(frigate_detector_inference_speed_seconds)*1000',
            "Inferenzzeit (normal ~28 ms)", "A"),
        tgt('count(frigate_camera_fps > 0) or vector(0)', "Kameras liefern Bild (von 3)", "B"),
    ],
    {"h": 5, "w": 8, "x": 8, "y": 18},
    text_mode="value_and_name", orient="vertical", dec=1,
    desc=("Die Inferenzzeit ist der EINZIGE verlaessliche Hinweis auf einen "
          "haengenden Detektor. detection_fps ist bewegungsabhaengig und "
          "nachts legitim 0 — daraus laesst sich kein Defekt ableiten."),
    links=link("Frigate NVR Detail", "frigate-detail"),
    thr=steps(warn=60, crit=120),
))

P.append(stat(
    "Netz", [
        tgt('count(unpoller_device_uptime_seconds==0) or vector(0)',
            "UniFi-Geraete offline (von 15)", "A"),
        tgt('sum(unpoller_device_port_poe_watts) or vector(0)', "PoE-Leistung", "B"),
        tgt('count(max_over_time(probe_success{job="blackbox-dns"}[3m]) == 1) or vector(0)',
            "DNS-Resolver erreichbar (von 3)", "C"),
    ],
    {"h": 5, "w": 8, "x": 16, "y": 18},
    text_mode="value_and_name", orient="vertical", dec=1,
    desc=("Die PoE-Metrik existiert nur fuer Ports MIT Last — ein "
          "abgeschalteter Port verschwindet, statt auf 0 zu fallen. Die "
          "Summe sinkt also, wenn Geraete ausfallen. "
          "Faellt 'DNS-Resolver erreichbar' auf 0, erreicht die zugehoerige "
          "Telegram-Meldung ihr Ziel womoeglich nicht mehr."),
    links=link("UniFi — PoE und Netzwerkgeraete", "unifi-poe"),
    thr=steps(),
))

# =============================================================================
# ZEILE 5 (y=23) — R7: erledigte Alarme, eingeklappt = ausgeblendet, aber da
# =============================================================================
P.append(row(
    "Zuletzt erledigt — aufklappen", {"h": 1, "w": 24, "x": 0, "y": 23},
    collapsed=True,
    panels=[alertlist(
        "Erledigte Alarme", {"h": 8, "w": 24, "x": 0, "y": 24}, RESOLVED,
        maxitems=20,
        desc=("Alarme, die von selbst zurueckgegangen sind. Absichtlich "
              "eingeklappt: Ein erledigter Alarm verlangt keine Handlung und "
              "wuerde die Handlungsliste oben verwaessern. "
              "Trotzdem hier, weil er eine Frage beantwortet, die die "
              "Alarmliste nicht beantwortet — war das schon einmal da? "
              "Faustregel aus dem Alarmdesign: Was regelmaessig binnen 8 h "
              "ohne Eingriff verschwindet, ist Statistik und kein Alarm."),
    )],
))

DASH = {
    "uid": "home-overview",
    "title": "Home — Infrastructure Overview",
    "description": ("Leitstand (Ebene 1) nach docs/LEITSTAND-DESIGN-EEMUA-201.md. "
                    "Gegliedert nach der Abhaengigkeitskette: Strom -> Messweg -> "
                    "Plattform -> Kapazitaet -> Dienste. Farbe bedeutet Abweichung; "
                    "ein farbloses Bild ist ein gesundes Bild. "
                    "Generiert aus .gen-home-overview.py — nicht in der UI bearbeiten."),
    "tags": ["leitstand", "ebene-1", "overview"],
    "timezone": "browser",
    "editable": True,
    "graphTooltip": 1,
    "schemaVersion": 39,
    "version": 0,
    "refresh": "1m",
    "time": {"from": "now-6h", "to": "now"},
    "timepicker": {},
    "templating": {"list": []},
    "annotations": {"list": [{
        "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
        "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts", "type": "dashboard"}]},
    "links": [
        {"title": "Alle Dashboards", "type": "dashboards", "tags": [],
         "asDropdown": True, "icon": "external link", "includeVars": False,
         "keepTime": True, "targetBlank": False, "tooltip": "", "url": ""},
    ],
    "panels": P,
}

print(json.dumps(DASH, indent=2, ensure_ascii=False))
