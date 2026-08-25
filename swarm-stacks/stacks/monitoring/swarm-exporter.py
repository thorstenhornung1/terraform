#!/usr/bin/env python3
"""
swarm-exporter — Prometheus-Metriken ueber den Zustand des Docker Swarm.

WOZU
    Am 2026-08-25 um 03:01 wurden nach einer Netzstoerung alle Tasks neu
    geplant. paperless-stack_paperless-webserver fand keinen Node mehr
    ("no suitable node ... insufficient resources on 1 node") und blieb VIER
    STUNDEN in `Pending` haengen. Keine einzige Metrik hat das gezeigt:
    {__name__=~"swarm_.*|docker_.*|container_.*"} lieferte 0 Serien.
    Aufgefallen ist es nur, weil die Blackbox-Probe von aussen zufaellig
    HTTP 404 sah — ein Dienst ohne oeffentlichen Endpunkt waere unbemerkt
    tot geblieben.

    Dieses Programm schliesst genau diese Luecke. Der eigentliche Zweck sind
    die Zustaende `pending` und `rejected`: Ein Task, den der Scheduler nicht
    platzieren kann, ist der Ausfall, den man von aussen nicht sieht.

    Zweitens beantwortet es die bindende Betreibervorgabe "Alle Nodes muessen
    alles tragen koennen" fortlaufend statt einmalig per Taschenrechner —
    siehe RECHNUNG weiter unten.

WARUM KEIN FERTIGER EXPORTER
    Es gibt keinen gepflegten. Die bekannten Kandidaten sind seit Jahren
    unberuehrt und haengen an alten Docker-API-Versionen. Ein 400-Zeilen-
    Skript ohne Abhaengigkeiten ist hier das wartbarere Ergebnis als ein
    totes Upstream-Projekt.

WARUM KEIN DOCKER-SOCKET
    Es wird KEIN /var/run/docker.sock eingehaengt. Der rohe Socket ist
    Root-Aequivalent auf dem Host: Wer ihn hat, startet einen privilegierten
    Container mit / als Bind-Mount und ist fertig. Stattdessen liest dieses
    Programm ueber den docker-socket-proxy, der im traefik-Stack ohnehin
    schon laeuft (tecnativa/docker-socket-proxy, mode: global, POST
    standardmaessig gesperrt, freigeschaltet nur NODES/SERVICES/TASKS/SWARM/
    CONTAINERS/NETWORKS). Wir brauchen davon nur die drei Lese-Endpunkte
    /nodes, /services und /tasks — also strikt weniger, als der Proxy Traefik
    schon gewaehrt. Kein neues Recht, keine neue Angriffsflaeche.

NUR STDLIB
    Kein `pip install docker`. Die drei GETs sind vier Zeilen urllib; eine
    Abhaengigkeit weniger ist in fuenf Jahren eine Bruchstelle weniger.

RECHNUNG "Alle Nodes muessen alles tragen koennen"
    Die RBD-gebundenen Dienste (grafana, paperless-webserver,
    openarchiver-meili) haengen per `node.labels.<name>-rbd == active` hart
    an je EINEM Node. Faellt der aus, verschiebt der Watchdog das Label. Kann
    der Zielnode den Dienst nicht aufnehmen, ist der Failover eine Falle: Der
    Dienst ist dann tot statt umgezogen.

    swarm_node_rbd_headroom_bytes beantwortet das pro Node:

        gebraucht(n) = Summe ALLER RBD-Reservierungen
                       - die, die auf n ohnehin schon laufen
        headroom(n)  = frei(n) - gebraucht(n)

    Negativ = der Failover dieses Dienstes auf diesen Node schlaegt fehl.

KARDINALITAET
    Ein Label je DIENST, nie je Task-ID. Task-IDs wechseln bei jedem Neustart
    und wuerden die Datenbank fluten — genau dieser Fehler ist bei
    frigate_cpu_usage_percent mit 1250 Serien fuer 69 Prozesse schon passiert.
    Bei ~55 Diensten und 3 Nodes liegt die Serienzahl hier stabil bei ~650.

BETRIEB
    Ein einziger Task, `replicas: 1` mit `node.role == manager`. Mehr als
    einer wuerde jede Serie doppelt liefern. Der Dienst ist vollstaendig
    zustandslos (die Zaehler leben im Speicher), deshalb braucht der Umzug
    bei Node-Ausfall weder Volume noch Watchdog — Swarm plant ihn selbst neu.
    Die Zaehler beginnen danach wieder bei 0; rate()/increase() erkennen den
    Reset selbst.
"""

import calendar
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.0"

# Die eigene Pruefsumme als Metrik: Die GitOps-Pipeline benennt Docker-Configs
# nach ihrem Inhalts-Hash. Greift das fuer diese Datei einmal nicht, laeuft
# still die alte Fassung weiter — an swarm_exporter_build_info sieht man,
# welche.
try:
    with open(os.path.abspath(__file__), "rb") as _f:
        SOURCE_SHA = hashlib.sha256(_f.read()).hexdigest()[:12]
except OSError:
    SOURCE_SHA = "unknown"

# tcp://... ist die Schreibweise, die DOCKER_HOST im Rest des Repos benutzt
# (traefik-cert-controller, Traefik selbst). Sie wird hier auf http:// normiert,
# damit dieselbe Variable ohne Sonderfall uebernommen werden kann.
DOCKER_HOST = os.environ.get("DOCKER_HOST", "tcp://docker-socket-proxy:2375")
# Explizit gepinnt statt "was der Daemon gerade fuer neu haelt": Ein
# Engine-Update darf die Feldnamen unter uns nicht wechseln. 1.45 ist
# dieselbe Version, auf die Traefik im traefik-Stack pinnt, und liegt
# komfortabel ueber der MinAPIVersion 1.40 der Engine.
API_VERSION = os.environ.get("DOCKER_API_VERSION", "1.45")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9975"))
# Der Scrape liest nur den zuletzt gerenderten Text. Wuerde er selbst die
# Docker-API befragen, machte eine haengende API aus einem Erkenntnisproblem
# ein Scrape-Timeout — und die Luecke waere wieder da, nur eine Ebene hoeher.
REFRESH_INTERVAL = float(os.environ.get("REFRESH_INTERVAL", "15"))
HTTP_TIMEOUT = float(os.environ.get("HTTP_TIMEOUT", "10"))
# Fenster fuer swarm_service_task_starts_recent. Docker haelt pro Slot nur
# `task-history-limit` (Standard 5) alte Tasks vor — laenger als ein paar
# Stunden lohnt das Fenster deshalb nicht.
RESTART_WINDOW = float(os.environ.get("RESTART_WINDOW", "1800"))

# Ein Task belegt seine Reservierung, solange sein Sollzustand `running` ist
# und er noch nicht endgueltig gestorben ist. Waehrend eines start-first-
# Updates zaehlen kurzzeitig BEIDE Tasks — das ist kein Messfehler, sondern
# genau der Grund, warum start-first-Updates an vollen Nodes scheitern.
ACTIVE_STATES = frozenset((
    "new", "allocated", "pending", "assigned", "accepted",
    "preparing", "ready", "starting", "running",
))
# Zustaende, die immer eine Serie bekommen, auch wenn sie 0 sind. `pending`
# und `rejected` stehen hier, weil sie der Anlass des ganzen Programms sind:
# Eine Regel darf nicht davon abhaengen, dass die Serie erst im Fehlerfall
# entsteht — ein PromQL-Vergleich auf eine fehlende Serie ergibt NoData, und
# mit noDataState:Alerting wird daraus ein Dauerfehlalarm (2026-08-24: 18 von
# 64 Regeln).
ALWAYS_EMIT_STATES = ("pending", "running", "failed", "rejected", "complete")
FAILURE_STATES = frozenset(("failed", "rejected"))

# node.labels.grafana-rbd == active  ->  "grafana-rbd"
RBD_CONSTRAINT = re.compile(
    r"^node\.labels\.([A-Za-z0-9_.-]+-rbd)\s*==\s*active$"
)


# ---------------------------------------------------------------------------
# Docker-API
# ---------------------------------------------------------------------------

def _base_url():
    host = DOCKER_HOST
    for prefix in ("tcp://", "http://"):
        if host.startswith(prefix):
            host = host[len(prefix):]
            break
    return "http://%s/v%s" % (host.rstrip("/"), API_VERSION)


def api_get(path):
    url = _base_url() + path
    with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:
        return json.load(resp)


def parse_rfc3339(value):
    """Docker liefert UTC mit Nanosekunden ('...53.669431233Z'); datetime kann
    nur Mikrosekunden. Statt einer Bibliothek dafuer: Bruchteil abschneiden.
    timegm() statt mktime(), damit das Ergebnis nicht von der TZ des Containers
    abhaengt — sonst waere `blocked_seconds` je nach Zeitzone um Stunden
    daneben."""
    if not value:
        return None
    try:
        head = value.rstrip("Z").split(".", 1)[0]
        return calendar.timegm(time.strptime(head, "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, OverflowError):
        return None


# ---------------------------------------------------------------------------
# Metrik-Ausgabe
# ---------------------------------------------------------------------------

def escape(value):
    return (str(value).replace("\\", "\\\\")
                      .replace('"', '\\"')
                      .replace("\n", " "))


class Output:
    """Sammelt Zeilen im Prometheus-Textformat und haelt HELP/TYPE-Koepfe
    auseinander — bewusst kein Client-Library-Ersatz, nur so viel, wie fuer
    dieses eine /metrics gebraucht wird."""

    def __init__(self):
        self.lines = []
        self._declared = set()

    def metric(self, name, help_text, mtype, value, **labels):
        if name not in self._declared:
            self._declared.add(name)
            self.lines.append("# HELP %s %s" % (name, help_text))
            self.lines.append("# TYPE %s %s" % (name, mtype))
        if labels:
            rendered = ",".join(
                '%s="%s"' % (k, escape(v)) for k, v in sorted(labels.items())
            )
            self.lines.append("%s{%s} %s" % (name, rendered, fmt(value)))
        else:
            self.lines.append("%s %s" % (name, fmt(value)))

    def text(self):
        return "\n".join(self.lines) + "\n"


def fmt(value):
    if isinstance(value, float):
        if value == int(value) and abs(value) < 1e15:
            return str(int(value))
        return repr(value)
    return str(value)


# ---------------------------------------------------------------------------
# Sammler
# ---------------------------------------------------------------------------

class Collector:
    def __init__(self):
        self.lock = threading.Lock()
        # Signalisiert dem Start, dass /metrics etwas Sinnvolles liefert. NICHT
        # ueber last_refresh loesen: der Wert wird schon vor dem Rendern
        # gesetzt, der Server startete sonst mit der Platzhalterantwort.
        self.ready = threading.Event()
        # Der Cluster-Teil der Antwort, OHNE die Selbstauskunft. Die wird bei
        # jedem Scrape frisch danebengesetzt (siehe snapshot()).
        self.body = "# swarm-exporter: noch kein Durchlauf\n"
        self.last_refresh = 0.0
        self.last_ok = 0
        self.refresh_errors = 0
        self.last_duration = 0.0
        # Zaehler-Zustand. Die Mengen werden bei jedem Durchlauf auf die
        # Task-IDs beschnitten, die die API noch kennt — Docker haelt pro Slot
        # nur `task-history-limit` (Standard 5) alte Tasks vor. Task-IDs werden
        # nie wiederverwendet, das Vergessen ist also gefahrlos.
        self.seen_tasks = set()
        self.counted_failures = set()
        self.starts = {}
        self.failures = {}
        self.seeded = False

    # -- Durchlauf ---------------------------------------------------------

    def refresh(self):
        started = time.time()
        try:
            nodes = api_get("/nodes")
            services = api_get("/services")
            tasks = api_get("/tasks")
        except (urllib.error.URLError, OSError, ValueError) as exc:
            # Der zuletzt gelungene Stand BLEIBT stehen. Ihn durch eine
            # Fehlerausgabe zu ersetzen hiesse, alle ~740 Serien auf einmal
            # verschwinden zu lassen — mit noDataState:Alerting waere das ein
            # Alarmsturm ueber jeden Dienst statt der einen Meldung, die
            # gemeint ist. Dass die Zahlen veralten, sagen refresh_ok und
            # last_refresh_timestamp; genau dafuer gibt es sie.
            with self.lock:
                self.refresh_errors += 1
                self.last_ok = 0
            self.ready.set()
            print("refresh fehlgeschlagen: %s" % exc, file=sys.stderr)
            return
        now = time.time()
        text = self._render(nodes, services, tasks, now)
        with self.lock:
            self.last_duration = time.time() - started
            self.last_refresh = now
            self.last_ok = 1
            self.body = text
        self.ready.set()

    def _emit_self(self, out):
        out.metric("swarm_exporter_build_info",
                   "Version und SHA256 der laufenden Skriptdatei.", "gauge", 1,
                   version=VERSION, source_sha256=SOURCE_SHA)
        out.metric("swarm_exporter_refresh_ok",
                   "1 = letzter Durchlauf gegen die Docker-API war erfolgreich. "
                   "0 = alle swarm_*-Werte sind veraltet.",
                   "gauge", self.last_ok)
        out.metric("swarm_exporter_last_refresh_timestamp_seconds",
                   "Unix-Zeit des letzten erfolgreichen Durchlaufs. Mit "
                   "`time() - <dieser Wert>` wird Veraltung alarmierbar.",
                   "gauge", self.last_refresh)
        out.metric("swarm_exporter_refresh_duration_seconds",
                   "Dauer des letzten erfolgreichen Durchlaufs.",
                   "gauge", round(self.last_duration, 4))
        out.metric("swarm_exporter_refresh_errors_total",
                   "Fehlgeschlagene Durchlaeufe seit Programmstart.",
                   "counter", self.refresh_errors)

    # -- Aufbereitung ------------------------------------------------------

    def _render(self, nodes, services, tasks, now):
        out = Output()

        # --- Nodes ---
        node_name = {}
        capacity = {}
        node_ready = {}
        for n in nodes:
            desc = n.get("Description", {})
            name = desc.get("Hostname", n["ID"])
            node_name[n["ID"]] = name
            capacity[name] = desc.get("Resources", {}).get("MemoryBytes", 0)
            spec = n.get("Spec", {})
            state = n.get("Status", {}).get("State", "unknown")
            availability = spec.get("Availability", "unknown")
            role = spec.get("Role", "unknown")
            ready = 1 if (state == "ready" and availability == "active") else 0
            node_ready[name] = ready
            out.metric("swarm_node_info", "Statische Node-Eigenschaften.",
                       "gauge", 1, node=name, role=role,
                       availability=availability, state=state)
            out.metric("swarm_node_up",
                       "1 = Node ist ready und active, nimmt also Tasks an.",
                       "gauge", ready, node=name)

        # --- Dienste ---
        svc_name, svc_stack, svc_res, svc_mode = {}, {}, {}, {}
        svc_desired, svc_rbd = {}, {}
        rbd_total = 0
        for s in services:
            spec = s["Spec"]
            sid = s["ID"]
            name = spec["Name"]
            svc_name[sid] = name
            svc_stack[sid] = spec.get("Labels", {}).get(
                "com.docker.stack.namespace", name.split("_")[0]
            )
            template = spec.get("TaskTemplate", {}) or {}
            reservations = (template.get("Resources", {}) or {}).get(
                "Reservations", {}) or {}
            svc_res[sid] = reservations.get("MemoryBytes", 0) or 0

            mode = spec.get("Mode", {}) or {}
            if "Replicated" in mode:
                svc_mode[sid] = "replicated"
                svc_desired[sid] = (mode["Replicated"] or {}).get("Replicas", 0)
            else:
                # global / *-job: Das Soll ergibt sich aus den Tasks, nicht aus
                # der Spec. Wird unten aus der Task-Liste nachgetragen.
                svc_mode[sid] = "global"
                svc_desired[sid] = None

            constraints = (template.get("Placement", {}) or {}).get(
                "Constraints") or []
            label = None
            for c in constraints:
                m = RBD_CONSTRAINT.match(c.strip())
                if m:
                    label = m.group(1)
                    break
            svc_rbd[sid] = label
            if label:
                rbd_total += svc_res[sid]

        # --- Tasks ---
        present = set()
        # je Dienst: {state: anzahl}, laengste Blockade, Ist-Replicas
        st_count = {sid: {} for sid in svc_name}
        blocked = {sid: 0.0 for sid in svc_name}
        running = {sid: 0 for sid in svc_name}
        desired_from_tasks = {sid: 0 for sid in svc_name}
        # Juengster abgeraeumter Task je Dienst — gebraucht fuer den Fall
        # "gar kein Task mehr da", siehe unten.
        last_gone = {sid: 0.0 for sid in svc_name}
        recent = {sid: 0 for sid in svc_name}
        # je Node: reservierte Bytes, davon beweglich, aktive Tasks
        reserved = {name: 0 for name in capacity}
        movable = {name: 0 for name in capacity}
        active_tasks = {name: 0 for name in capacity}
        # je Node: welche RBD-Reservierungen liegen schon dort
        rbd_here = {name: 0 for name in capacity}

        for t in tasks:
            tid = t["ID"]
            sid = t.get("ServiceID")
            if sid not in svc_name:
                continue                      # Dienst gerade entfernt
            present.add(tid)
            state = t.get("Status", {}).get("State", "unknown")
            desired = t.get("DesiredState", "unknown")

            # Die beiden Zaehler sehen ALLE Tasks, auch die abgeraeumten in der
            # Historie. Das ist Absicht: Ein `rejected` traegt nur Sekunden
            # lang DesiredState=running, bevor Swarm es auf shutdown setzt und
            # einen neuen Task erzeugt. Der Zaehler erwischt es trotzdem, die
            # Momentaufnahme unten wuerde es zwischen zwei Durchlaeufen
            # verpassen. Umgekehrt ist `pending` genau in der Momentaufnahme
            # sichtbar. Beide zusammen decken den Anlassfall ab.
            if self.seeded and tid not in self.seen_tasks:
                self.starts[sid] = self.starts.get(sid, 0) + 1
            if state in FAILURE_STATES and tid not in self.counted_failures:
                self.counted_failures.add(tid)
                if self.seeded:
                    self.failures[sid] = self.failures.get(sid, 0) + 1

            # Zustandsloses Gegenstueck zum Zaehler oben, gerechnet aus
            # CreatedAt. Der Zaehler faellt beim Neustart des Exporters auf 0
            # zurueck, und increase() deutet den Sprung als Zuwachs — eine
            # Regel darauf meldete dann eine Neustartschleife, die es nie gab.
            # Diese Zahl haengt an nichts, was der Exporter sich merkt.
            created = parse_rfc3339(t.get("CreatedAt"))
            if created and now - created <= RESTART_WINDOW:
                recent[sid] += 1

            if desired != "running":
                # Abgeraeumter Alt-Task. Docker haelt pro Slot
                # `task-history-limit` (Standard 5) davon vor. Wuerden sie in
                # swarm_service_tasks mitzaehlen, stuende dort tagelang ein
                # `failed` aus einem laengst geheilten Deploy — und jede Regel
                # darauf waere ein Dauerfehlalarm.
                ts = parse_rfc3339(t.get("Status", {}).get("Timestamp"))
                if ts:
                    last_gone[sid] = max(last_gone[sid], ts)
                continue
            desired_from_tasks[sid] += 1
            st_count[sid][state] = st_count[sid].get(state, 0) + 1
            if state == "running":
                running[sid] += 1
            else:
                # Kein Task-ID-Label! Der laengste Haenger je Dienst genuegt,
                # um "haengt seit 4 h" alarmierbar zu machen.
                since = (parse_rfc3339(t.get("Status", {}).get("Timestamp"))
                         or parse_rfc3339(t.get("CreatedAt")))
                if since:
                    blocked[sid] = max(blocked[sid], max(0.0, now - since))

            if state not in ACTIVE_STATES:
                continue
            node = node_name.get(t.get("NodeID"))
            if not node or node not in reserved:
                continue                      # noch nicht zugewiesen
            reserved[node] += svc_res[sid]
            active_tasks[node] += 1
            if svc_mode[sid] == "replicated":
                # Nur replizierte Tasks muessen bei Node-Ausfall woanders
                # unterkommen. Ein globaler Task verschwindet mit dem Node und
                # will nirgends hin.
                movable[node] += svc_res[sid]
            if svc_rbd[sid]:
                rbd_here[node] += svc_res[sid]

        # Vergessene Task-IDs aus dem Zaehlerzustand streichen, sonst waechst
        # er ueber Monate unbegrenzt.
        self.seen_tasks = present
        self.counted_failures &= present
        live = set(svc_name)
        self.starts = {k: v for k, v in self.starts.items() if k in live}
        self.failures = {k: v for k, v in self.failures.items() if k in live}
        self.seeded = True

        # --- Dienst-Metriken ---
        for sid, name in sorted(svc_name.items(), key=lambda kv: kv[1]):
            labels = {"service": name, "stack": svc_stack[sid]}
            desired = svc_desired[sid]
            if desired is None:
                desired = desired_from_tasks[sid]
            out.metric("swarm_service_replicas_desired",
                       "Soll-Replicas laut Service-Spec (global: Anzahl "
                       "geplanter Tasks).", "gauge", desired, **labels)
            out.metric("swarm_service_replicas_running",
                       "Tasks, die tatsaechlich laufen.",
                       "gauge", running[sid], **labels)

            # Sonderfall, der am 2026-08-25 an dashboard_docker-swarm-dashboard
            # auffiel: Der Dienst stand DREI TAGE auf 0/1, weil sein Task
            # "assigned node no longer meets constraints" rejected wurde und
            # Swarm danach keinen neuen mehr anlegte. Es gab also GAR KEINEN
            # Task — pending war 0, und ohne diesen Zweig waere auch
            # blocked_seconds 0 gewesen. Die Luecke, die dieses Programm
            # schliessen soll, haette hier also erneut zugeschlagen. Fehlt der
            # Task, zaehlt stattdessen der letzte abgeraeumte.
            gap = blocked[sid]
            if running[sid] < desired and gap == 0 and last_gone[sid]:
                gap = max(0.0, now - last_gone[sid])
            states = dict(st_count[sid])
            for s in ALWAYS_EMIT_STATES:
                states.setdefault(s, 0)
            for state, count in sorted(states.items()):
                out.metric("swarm_service_tasks",
                           "Tasks mit Sollzustand running, je Ist-Zustand. "
                           "Momentaufnahme OHNE Historie. `pending` ist der "
                           "eigentliche Zweck: Der Scheduler findet keinen "
                           "Platz, und von aussen sieht man nichts.",
                           "gauge", count, state=state, **labels)
            out.metric("swarm_service_task_blocked_seconds",
                       "Laengste Zeit, die ein Task mit Sollzustand running "
                       "nicht laeuft; ohne jeden Task die Zeit seit dem "
                       "letzten abgeraeumten. 0 = alles laeuft.",
                       "gauge", round(gap, 1), **labels)
            out.metric("swarm_service_task_starts_total",
                       "Neu gesehene Tasks seit Programmstart. Steigt bei "
                       "jedem Deploy — und in einer Neustartschleife dauernd. "
                       "Fuer Regeln swarm_service_task_starts_recent nehmen.",
                       "counter", self.starts.get(sid, 0), **labels)
            out.metric("swarm_service_task_starts_recent",
                       "Tasks, die in den letzten %d Sekunden angelegt wurden. "
                       "Zustandslos aus CreatedAt gerechnet und deshalb "
                       "immun gegen einen Neustart des Exporters."
                       % int(RESTART_WINDOW),
                       "gauge", recent[sid], **labels)
            out.metric("swarm_service_task_failures_total",
                       "Neu gesehene Tasks, die failed oder rejected wurden.",
                       "counter", self.failures.get(sid, 0), **labels)
            out.metric("swarm_service_memory_reservation_bytes",
                       "Memory-Reservierung je Task laut Spec. 0 = der Dienst "
                       "reserviert nichts und ist fuer den Scheduler unsichtbar.",
                       "gauge", svc_res[sid], **labels)
            out.metric("swarm_service_rbd_bound",
                       "1 = per node.labels.<name>-rbd == active an einen "
                       "einzelnen Node genagelt.",
                       "gauge", 1 if svc_rbd[sid] else 0, **labels)

        # --- Node-Kapazitaet ---
        free = {}
        for name in sorted(capacity):
            free[name] = capacity[name] - reserved[name]
            out.metric("swarm_node_memory_capacity_bytes",
                       "Kapazitaet, mit der der Scheduler rechnet. ACHTUNG: "
                       "Swarm friert sie beim Join ein und sieht damit den "
                       "Ballooning-Boden der VM, nicht ihr konfiguriertes "
                       "Maximum.", "gauge", capacity[name], node=name)
            out.metric("swarm_node_memory_reserved_bytes",
                       "Summe der Reservierungen aller aktiven Tasks. Der "
                       "Scheduler kennt NUR diesen Wert — weder limits noch "
                       "den Ist-Verbrauch.", "gauge", reserved[name], node=name)
            out.metric("swarm_node_memory_free_bytes",
                       "Kapazitaet minus Reservierungen. Was der Scheduler "
                       "noch vergeben kann.", "gauge", free[name], node=name)
            out.metric("swarm_node_tasks_active",
                       "Aktive Tasks auf dem Node.",
                       "gauge", active_tasks[name], node=name)

        # --- Kapazitaets-Waechter ---
        out.metric("swarm_cluster_rbd_reservation_bytes",
                   "Summe der Reservierungen aller RBD-gebundenen Dienste. "
                   "So viel muss jeder Node im schlimmsten Fall zusaetzlich "
                   "stemmen.", "gauge", rbd_total)
        for name in sorted(capacity):
            # "Alle Nodes muessen alles tragen koennen": Was noch fehlt, ist
            # die Summe aller RBD-Dienste MINUS derer, die hier schon laufen.
            needed = rbd_total - rbd_here[name]
            headroom = free[name] - needed
            out.metric("swarm_node_rbd_headroom_bytes",
                       "Rest, wenn ALLE RBD-gebundenen Dienste auf diesen Node "
                       "faellt. Negativ = der Watchdog wuerde das Label auf "
                       "einen Node schieben, der den Dienst nicht starten kann.",
                       "gauge", headroom, node=name)
            out.metric("swarm_node_can_host_all_rbd",
                       "1 = dieser Node koennte alle RBD-gebundenen Dienste "
                       "gleichzeitig aufnehmen.",
                       "gauge", 1 if headroom >= 0 else 0, node=name)

            # Ausfall dieses Nodes: passt seine bewegliche Last auf den Rest?
            # Das ist eine SUMMENRECHNUNG, keine Packungspruefung: <0 heisst
            # sicher "passt nicht", >=0 heisst "die Summe reicht" — ein
            # einzelner grosser Dienst kann trotzdem an der Stueckelung
            # scheitern. Bewusst so: die Summe ist die Zahl, die man
            # verstehen und im Kopf nachrechnen kann.
            rest = sum(free[m] for m in capacity
                       if m != name and node_ready.get(m))
            out.metric("swarm_node_failover_headroom_bytes",
                       "Freier Speicher der uebrigen Nodes minus der "
                       "beweglichen Last dieses Nodes. Untergrenze, keine "
                       "Packungspruefung.",
                       "gauge", rest - movable[name], node=name)
            out.metric("swarm_node_failover_ok",
                       "1 = faellt dieser Node aus, reicht die Summe des "
                       "freien Speichers auf den uebrigen.",
                       "gauge", 1 if rest - movable[name] >= 0 else 0,
                       node=name)

        return out.text()

    def snapshot(self):
        """Cluster-Stand plus frisch gerechnete Selbstauskunft. Die
        Selbstauskunft entsteht hier und nicht im Durchlauf, damit sie auch
        dann stimmt, wenn der letzte Durchlauf fehlschlug und der Cluster-Teil
        deshalb stehengeblieben ist."""
        out = Output()
        with self.lock:
            self._emit_self(out)
            return self.body + out.text()


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    collector = None
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path.split("?")[0] not in ("/metrics", "/"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = self.collector.snapshot().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass          # ein Logeintrag je Scrape alle 30 s hilft niemandem


def main():
    collector = Collector()
    Handler.collector = collector

    def loop():
        while True:
            collector.refresh()
            time.sleep(REFRESH_INTERVAL)

    threading.Thread(target=loop, daemon=True).start()
    # Auf den ersten Durchlauf warten, damit ein Scrape unmittelbar nach dem
    # Start keine leere Antwort bekommt.
    collector.ready.wait(timeout=HTTP_TIMEOUT + 5)

    print("swarm-exporter %s: %s -> :%d (alle %.0fs)"
          % (VERSION, _base_url(), LISTEN_PORT, REFRESH_INTERVAL),
          file=sys.stderr)
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
