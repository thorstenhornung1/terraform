import json

DS = {"type": "prometheus", "uid": "victoriametrics"}

# Der Join: PoE-Watt je Port, angereichert um den Client-Namen.
# Zweig 1 = Ports MIT Client (inner join ueber sw_name/sw_port),
# Zweig 2 = Ports OHNE Client (unless), sonst fielen die APs raus.
# "or" allein wuerde doppeln, weil Zweig 1 ein Label mehr traegt.
POE_JOIN = (
 '(label_replace(label_replace(unpoller_device_port_poe_watts > 0, "sw_port","$1","port_num","(.+)"), '
 '"sw_name","$1","name","(.+)") * on(sw_name,sw_port) group_left(client) '
 '(sum by (sw_name,sw_port,client) (label_replace(unpoller_client_uptime_seconds{sw_port!=""}, '
 '"client","$1","name","(.+)")) * 0 + 1)) or '
 '(label_replace(label_replace(unpoller_device_port_poe_watts > 0, "sw_port","$1","port_num","(.+)"), '
 '"sw_name","$1","name","(.+)") unless on(sw_name,sw_port) '
 '(sum by (sw_name,sw_port) (unpoller_client_uptime_seconds{sw_port!=""})))'
)

pid = [0]
def nid():
    pid[0] += 1
    return pid[0]

def tgt(expr, legend="", instant=False, fmt="time_series", ref="A"):
    return {"datasource": DS, "editorMode": "code", "expr": expr, "legendFormat": legend,
            "range": not instant, "instant": instant, "format": fmt, "refId": ref}

def stat(title, expr, gp, unit="watt", dec=1, thresholds=None, text_mode="value",
         color_mode="value", legend="", graph=False):
    steps = thresholds or [{"color": "text", "value": None}]
    return {
        "id": nid(), "type": "stat", "title": title, "datasource": DS, "gridPos": gp,
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec, "mappings": [],
            "thresholds": {"mode": "absolute", "steps": steps},
            "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"colorMode": color_mode, "graphMode": "area" if graph else "none",
                    "justifyMode": "auto", "orientation": "auto",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "textMode": text_mode, "wideLayout": True},
        "targets": [tgt(expr, legend, instant=True)],
    }

def ts(title, targets, gp, unit="watt", dec=1, minv=None, stack=False, fill=8, desc=None):
    p = {
        "id": nid(), "type": "timeseries", "title": title, "datasource": DS, "gridPos": gp,
        "fieldConfig": {"defaults": {
            "unit": unit, "decimals": dec,
            "custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": fill,
                       "gradientMode": "opacity", "showPoints": "never",
                       "spanNulls": 300000, "pointSize": 4,
                       "stacking": {"mode": "normal" if stack else "none", "group": "A"},
                       "axisPlacement": "auto", "scaleDistribution": {"type": "linear"}},
            "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
            "color": {"mode": "palette-classic"}, "mappings": []}, "overrides": []},
        "options": {"legend": {"calcs": ["mean", "max", "lastNotNull"], "displayMode": "table",
                               "placement": "right", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "targets": targets,
    }
    if minv is not None:
        p["fieldConfig"]["defaults"]["min"] = minv
    if desc:
        p["description"] = desc
    return p

def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}

panels = []

# ---------------------------------------------------------------- Kennzahlen
panels.append(row("Überblick", 0))

panels.append(stat("PoE gesamt", "sum(unpoller_device_port_poe_watts)",
    {"h": 4, "w": 4, "x": 0, "y": 1}, thresholds=[
        {"color": "green", "value": None}, {"color": "yellow", "value": 120},
        {"color": "red", "value": 180}], graph=True))

panels.append(stat("USV-Wirkleistung", "ups_realpower_watts",
    {"h": 4, "w": 4, "x": 4, "y": 1}, dec=0, thresholds=[
        {"color": "green", "value": None}, {"color": "yellow", "value": 300},
        {"color": "red", "value": 380}], graph=True))

p = stat("PoE-Anteil an der USV-Last",
    "sum(unpoller_device_port_poe_watts) / scalar(ups_realpower_watts) * 100",
    {"h": 4, "w": 4, "x": 8, "y": 1}, unit="percent", dec=1, thresholds=[
        {"color": "blue", "value": None}, {"color": "yellow", "value": 35}])
p["description"] = ("Wie viel der gesamten Wirkleistung an den Switch-Ports haengt. "
                    "Bei Netzausfall ist das der Anteil, den ein PoE-Abwurf einsparen wuerde.")
panels.append(p)

panels.append(stat("Aktive PoE-Ports", "count(unpoller_device_port_poe_watts > 0)",
    {"h": 4, "w": 3, "x": 12, "y": 1}, unit="short", dec=0, color_mode="none"))

p = stat("Ports ohne Client-Zuordnung",
    'count(unpoller_device_port_poe_watts > 0) - count('
    'label_replace(label_replace(unpoller_device_port_poe_watts > 0, "sw_port","$1","port_num","(.+)"), '
    '"sw_name","$1","name","(.+)") and on(sw_name,sw_port) '
    '(sum by (sw_name,sw_port) (unpoller_client_uptime_seconds{sw_port!=""})))',
    {"h": 4, "w": 3, "x": 15, "y": 1}, unit="short", dec=0, thresholds=[
        {"color": "green", "value": None}, {"color": "yellow", "value": 1}])
p["description"] = ("Dort haengen UniFi-Geraete (Access Points, Flex-Mini). Die tauchen nicht als "
                    "Client auf, und UnPoller liefert fuer sie keine Uplink-Portnummer. "
                    "Aufloesbar nur durch Benennen der Ports in der UniFi-Oberflaeche — "
                    "der Name landet dann in port_name und erscheint hier automatisch.")
panels.append(p)

p = stat("Geräte mit Firmware-Update", "sum(unpoller_device_upgradable)",
    {"h": 4, "w": 3, "x": 18, "y": 1}, unit="short", dec=0, thresholds=[
        {"color": "green", "value": None}, {"color": "yellow", "value": 1}])
panels.append(p)

p = stat("UnPoller-Scrape", "time() - timestamp(max(unpoller_device_port_poe_watts))",
    {"h": 4, "w": 3, "x": 21, "y": 1}, unit="s", dec=0, thresholds=[
        {"color": "green", "value": None}, {"color": "yellow", "value": 180},
        {"color": "red", "value": 300}])
p["description"] = "Alter der letzten UnPoller-Daten. Steigt der Wert, sammelt UnPoller nicht mehr."
panels.append(p)

# ---------------------------------------------------------------- PoE-Detail
panels.append(row("PoE je Port", 5))

table = {
    "id": nid(), "type": "table", "title": "PoE-Ports nach Leistung",
    "datasource": DS, "gridPos": {"h": 12, "w": 13, "x": 0, "y": 6},
    "description": ("Die Client-Spalte entsteht durch einen Join ueber sw_name/sw_port aus den "
                    "Client-Metriken. Leer bleibt sie dort, wo ein UniFi-Geraet haengt — "
                    "diese kennt UnPoller nicht als Client. Abhilfe: Port in UniFi benennen, "
                    "dann fuellt sich die Spalte 'Port-Bezeichnung'."),
    "fieldConfig": {"defaults": {
        "unit": "watt", "decimals": 1, "custom": {"align": "auto", "cellOptions": {"type": "auto"},
        "filterable": True, "inspect": False}, "mappings": [],
        "thresholds": {"mode": "absolute", "steps": [{"color": "text", "value": None}]}},
        "overrides": [
            {"matcher": {"id": "byName", "options": "Watt"},
             "properties": [
                 {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "gradient"}},
                 {"id": "max", "value": 15}, {"id": "min", "value": 0},
                 {"id": "custom.width", "value": 170},
                 {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                     {"color": "blue", "value": None}, {"color": "green", "value": 3},
                     {"color": "yellow", "value": 7}, {"color": "orange", "value": 12}]}}]},
            {"matcher": {"id": "byName", "options": "Port"},
             "properties": [{"id": "custom.width", "value": 60}]},
        ]},
    "options": {"showHeader": True, "cellHeight": "sm", "footer": {
        "show": True, "reducer": ["sum"], "fields": ["Watt"], "countRows": False},
        "sortBy": [{"desc": True, "displayName": "Watt"}]},
    "targets": [tgt(POE_JOIN, instant=True, fmt="table")],
    "transformations": [
        {"id": "organize", "options": {
            "excludeByName": {"Time": True, "__name__": True, "instance": True, "job": True,
                              "source": True, "site_name": True, "sw_name": True,
                              "sw_port": True, "port_id": True},
            "indexByName": {"name": 0, "port_num": 1, "port_name": 2, "client": 3, "Value": 4},
            "renameByName": {"name": "Switch", "port_num": "Port",
                             "port_name": "Port-Bezeichnung (UniFi)", "client": "Client",
                             "Value": "Watt"}}},
        {"id": "sortBy", "options": {"fields": {}, "sort": [{"field": "Watt", "desc": True}]}},
    ],
}
panels.append(table)

# PoE-Budget je Switch
bg = {
    "id": nid(), "type": "bargauge", "title": "PoE-Budget je Switch",
    "datasource": DS, "gridPos": {"h": 6, "w": 11, "x": 13, "y": 6},
    "description": "Abgerufene Leistung gegen das PoE-Budget des jeweiligen Switches.",
    "fieldConfig": {"defaults": {
        "unit": "percent", "decimals": 1, "min": 0, "max": 100, "mappings": [],
        "thresholds": {"mode": "absolute", "steps": [
            {"color": "green", "value": None}, {"color": "yellow", "value": 70},
            {"color": "red", "value": 90}]}}, "overrides": []},
    "options": {"displayMode": "gradient", "orientation": "horizontal",
                "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                "showUnfilled": True, "valueMode": "color", "minVizHeight": 16,
                "minVizWidth": 8, "namePlacement": "auto", "sizing": "auto"},
    "targets": [tgt('(sum by (name) (unpoller_device_port_poe_watts) / on(name) group_left() '
                    'sum by (name) (unpoller_device_max_power_total) * 100) '
                    'or (sum by (name) (unpoller_device_max_power_total) * 0)',
                    "{{name}}", instant=True)],
}
panels.append(bg)

panels.append(stat("Watt je Switch", "sum by (name) (unpoller_device_port_poe_watts)",
    {"h": 6, "w": 11, "x": 13, "y": 12}, legend="{{name}}", text_mode="value_and_name",
    color_mode="background", thresholds=[
        {"color": "blue", "value": None}, {"color": "green", "value": 20},
        {"color": "yellow", "value": 100}]))

# ------------------------------------------------------------ Zeitverlauf
panels.append(row("Verlauf", 18))

panels.append(ts("PoE je Port (gestapelt)", [
    tgt(POE_JOIN, "{{name}} P{{port_num}} {{client}}")],
    {"h": 9, "w": 12, "x": 0, "y": 19}, stack=True, fill=60, minv=0,
    desc="Gestapelt ergibt die Kurve die PoE-Gesamtlast. Sprünge zeigen, welcher Port sie verursacht."))

panels.append(ts("USV-Wirkleistung und PoE-Anteil", [
    tgt("ups_realpower_watts", "USV gesamt (Wirkleistung)"),
    tgt("ups_power_va", "USV Scheinleistung (VA)", ref="B"),
    tgt("sum(unpoller_device_port_poe_watts)", "PoE gesamt", ref="C")],
    {"h": 9, "w": 12, "x": 12, "y": 19}, dec=0, minv=0, fill=10,
    desc=("Scheinleistung (VA) und Wirkleistung (W) laufen bei Schaltnetzteilen auseinander; "
          "fuer die Batterielaufzeit zaehlt die Wirkleistung.")))

# ------------------------------------------------------------ Geräte
panels.append(row("UniFi-Geräte", 28))

dev = {
    "id": nid(), "type": "table", "title": "Geräteübersicht",
    "datasource": DS, "gridPos": {"h": 11, "w": 14, "x": 0, "y": 29},
    "description": ("Port 'wire'/'eth0'/'uplink' = kabelgebunden (also PoE-versorgt), "
                    "'wireless' = Mesh-Uplink."),
    "fieldConfig": {"defaults": {
        "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": True},
        "mappings": [], "thresholds": {"mode": "absolute",
        "steps": [{"color": "text", "value": None}]}},
        "overrides": [
            {"matcher": {"id": "byName", "options": "Uptime"},
             "properties": [{"id": "unit", "value": "s"}, {"id": "decimals", "value": 0}]},
            {"matcher": {"id": "byName", "options": "Temperatur"},
             "properties": [{"id": "unit", "value": "celsius"}, {"id": "decimals", "value": 0},
                            {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                                {"color": "green", "value": None},
                                {"color": "yellow", "value": 60},
                                {"color": "red", "value": 75}]}}]},
            {"matcher": {"id": "byName", "options": "CPU"},
             "properties": [{"id": "unit", "value": "percentunit"}, {"id": "decimals", "value": 1}]},
            {"matcher": {"id": "byName", "options": "RAM"},
             "properties": [{"id": "unit", "value": "percentunit"}, {"id": "decimals", "value": 1}]},
            {"matcher": {"id": "byName", "options": "Update"},
             "properties": [{"id": "mappings", "value": [
                 {"type": "value", "options": {"0": {"text": "—", "index": 0},
                                               "1": {"text": "verfügbar", "color": "yellow", "index": 1}}}]},
                            {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
        ]},
    "options": {"showHeader": True, "cellHeight": "sm",
                "sortBy": [{"desc": False, "displayName": "Gerät"}]},
    "targets": [
        tgt("unpoller_device_uptime_seconds", instant=True, fmt="table", ref="A"),
        tgt("unpoller_device_temperature_celsius", instant=True, fmt="table", ref="B"),
        tgt("unpoller_device_cpu_utilization_ratio", instant=True, fmt="table", ref="C"),
        tgt("unpoller_device_memory_utilization_ratio", instant=True, fmt="table", ref="D"),
        tgt("unpoller_device_stations", instant=True, fmt="table", ref="E"),
        tgt("unpoller_device_upgradable", instant=True, fmt="table", ref="F"),
    ],
    "transformations": [
        {"id": "joinByField", "options": {"byField": "name", "mode": "outer"}},
        {"id": "organize", "options": {
            "excludeByName": {"Time": True, "Time 1": True, "Time 2": True, "Time 3": True,
                              "Time 4": True, "Time 5": True, "Time 6": True,
                              "instance": True, "job": True, "source": True, "site_name": True,
                              "instance 1": True, "instance 2": True, "instance 3": True,
                              "instance 4": True, "instance 5": True, "instance 6": True,
                              "job 1": True, "job 2": True, "job 3": True, "job 4": True,
                              "job 5": True, "job 6": True,
                              "source 1": True, "source 2": True, "source 3": True,
                              "source 4": True, "source 5": True, "source 6": True,
                              "site_name 1": True, "site_name 2": True, "site_name 3": True,
                              "site_name 4": True, "site_name 5": True, "site_name 6": True,
                              "port": True, "type 2": True, "type 3": True, "type 4": True,
                              "type 5": True, "type 6": True},
            "renameByName": {"name": "Gerät", "type": "Typ", "type 1": "Typ",
                             "Value #A": "Uptime", "Value #B": "Temperatur",
                             "Value #C": "CPU", "Value #D": "RAM",
                             "Value #E": "Clients", "Value #F": "Update"}}},
    ],
}
panels.append(dev)

panels.append(ts("Gerätetemperaturen", [
    tgt("unpoller_device_temperature_celsius", "{{name}}")],
    {"h": 11, "w": 10, "x": 14, "y": 29}, unit="celsius", dec=1, fill=0))

# ------------------------------------------------------------ WAN
panels.append(row("WAN und Portqualität", 40))

panels.append(ts("WAN-Durchsatz", [
    tgt("unpoller_device_wan_receive_rate_bytes", "Empfang {{name}}"),
    tgt("unpoller_device_wan_transmit_rate_bytes", "Senden {{name}}", ref="B")],
    {"h": 8, "w": 12, "x": 0, "y": 41}, unit="Bps", dec=0, fill=15))

panels.append(ts("WAN-Latenz und Uplink", [
    tgt("unpoller_device_uplink_latency_seconds > 0", "{{name}} ({{port}})")],
    {"h": 8, "w": 6, "x": 12, "y": 41}, unit="s", dec=3, fill=0))

err = {
    "id": nid(), "type": "table", "title": "Ports mit Fehlern oder Drops",
    "datasource": DS, "gridPos": {"h": 8, "w": 6, "x": 18, "y": 41},
    "description": ("Kumulativ seit dem letzten Neustart des Geraets. Hohe Werte auf einem "
                    "einzelnen Port deuten auf Kabel, SFP oder Duplex-Mismatch. Ob das Problem "
                    "noch besteht, zeigt das Panel daneben — der Zaehler allein kann alt sein."),
    "fieldConfig": {"defaults": {
        "unit": "short", "decimals": 0,
        "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": True},
        "mappings": [], "thresholds": {"mode": "absolute", "steps": [
            {"color": "text", "value": None}]}},
        "overrides": [
            {"matcher": {"id": "byName", "options": "Fehler"},
             "properties": [{"id": "custom.cellOptions", "value": {"type": "color-text"}},
                            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                                {"color": "green", "value": None},
                                {"color": "yellow", "value": 1},
                                {"color": "red", "value": 1000}]}}]},
        ]},
    "options": {"showHeader": True, "cellHeight": "sm",
                "sortBy": [{"desc": True, "displayName": "Fehler"}]},
    "targets": [
        tgt("topk(10, unpoller_device_port_receive_errors_total > 0)", instant=True,
            fmt="table", ref="A"),
        tgt("topk(10, unpoller_device_port_receive_dropped_total > 0)", instant=True,
            fmt="table", ref="B"),
    ],
    "transformations": [
        {"id": "joinByField", "options": {"byField": "port_id", "mode": "outer"}},
        {"id": "organize", "options": {
            "excludeByName": {k: True for k in
                ["Time", "Time 1", "Time 2", "instance", "instance 1", "instance 2",
                 "job", "job 1", "job 2", "source", "source 1", "source 2",
                 "site_name", "site_name 1", "site_name 2", "port_id",
                 "port_name", "port_name 1", "port_name 2", "name 2", "port_num 2"]},
            "renameByName": {"name": "Gerät", "name 1": "Gerät", "port_num": "Port",
                             "port_num 1": "Port", "Value #A": "Fehler", "Value #B": "Drops"}}},
    ],
}
panels.append(err)

panels.append(ts("Fehlerrate — besteht das Problem noch?", [
    tgt("rate(unpoller_device_port_receive_errors_total[10m]) > 0", "Empfang {{name}} P{{port_num}}"),
    tgt("rate(unpoller_device_port_transmit_errors_total[10m]) > 0", "Senden {{name}} P{{port_num}}", ref="B")],
    {"h": 5, "w": 12, "x": 0, "y": 49}, unit="pps", dec=3, fill=0, minv=0,
    desc=("Nur laufende Fehler erscheinen hier. Eine flache Linie bei einem Port mit hohem "
          "Zaehlerstand heisst: das Problem ist vorbei, der Zaehler erinnert nur daran.")))

panels.append(ts("Drop-Rate", [
    tgt("rate(unpoller_device_port_receive_dropped_total[10m]) > 0", "Empfang {{name}} P{{port_num}}"),
    tgt("rate(unpoller_device_port_transmit_dropped_total[10m]) > 0", "Senden {{name}} P{{port_num}}", ref="B")],
    {"h": 5, "w": 12, "x": 12, "y": 49}, unit="pps", dec=3, fill=0, minv=0))

dash = {
    "uid": "unifi-poe",
    "title": "UniFi — PoE und Netzwerkgeräte",
    "description": ("Leistungsaufnahme der PoE-Ports mit Zuordnung zu den angeschlossenen "
                    "Geräten, im Verhältnis zur USV-Wirkleistung. Datenquelle: UnPoller "
                    "(Swarm-Service im monitoring-Stack) gegen die UDM Pro."),
    "tags": ["unifi", "poe", "power", "network"],
    "timezone": "browser",
    "editable": True,
    "schemaVersion": 39,
    "version": 1,
    "refresh": "1m",
    "time": {"from": "now-6h", "to": "now"},
    "graphTooltip": 1,
    "panels": panels,
    "links": [
        {"title": "USV / Stromversorgung", "type": "dashboards", "tags": ["ups"],
         "asDropdown": False, "icon": "external link", "includeVars": False,
         "keepTime": True, "targetBlank": False, "tooltip": "", "url": ""},
    ],
}

out = "dashboards/unifi-poe.json"
with open(out, "w") as f:
    json.dump(dash, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"{out} geschrieben — {len([p for p in panels if p['type']!='row'])} Panels, "
      f"{len([p for p in panels if p['type']=='row'])} Zeilen")
