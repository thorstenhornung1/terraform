# Leitstanddesign nach EEMUA 201 / ISA-101 — übersetzt auf dieses Homelab

**Stand:** 2026-08-25 · **Datengrundlage:** 20 Dashboards aus
`/mnt/rbd/grafana/grafana.db` (schreibgeschützt gelesen), das Level-1-Dashboard
`home-overview` panelweise vermessen, alle Level-1-Queries gegen die laufende
VictoriaMetrics bzw. Loki gegengeprüft · **Status:** Entwurf, keine Änderung
durchgeführt

> Schwesterdokument zu [`ALARM-DESIGN-EEMUA-191.md`](ALARM-DESIGN-EEMUA-191.md).
> Dort geht es um das, was den Menschen **holt**. Hier um das, was er
> **vorfindet**, wenn er hinsieht.

---

## 0. Kernbefund vorweg

Das Alarmdokument steht und fällt mit einem Satz, der hier wörtlich wieder gilt —
nur auf die Anzeige statt auf die Alarme angewandt:

> Eine Query, die im Gesundzustand nichts liefert, ist von einem Ausfall nicht
> zu unterscheiden.

Auf dem Leitstand ist dieser Fehler **schwerer** als im Alarmsystem, weil er
nicht schreit, sondern beruhigt. Und er ist belegt:

> **Die drei größten Panels des Level-1-Dashboards zeigen fast nichts an — und
> sehen dabei aus wie „alles ruhig".**
>
> Die Panels 106 („Error Rate (alle Hosts)"), 107 („Log Volume (alle Hosts)")
> und 108 („Letzte kritische Meldungen") belegen zusammen den Bereich von
> Rastereinheit 33 bis 49 — **16 der 49 Einheiten, ein Drittel der
> Gesamthöhe** und der mit Abstand größte Block des Dashboards. Gemessen am
> 2026-08-25 gegen die laufende Loki:
>
> | Panel-Query | Ergebnis |
> |---|---|
> | `sum by (host) (count_over_time({job=~".+"}[1m]))` — Panel 107 | **2 Serien**, 625 Zeilen/h — nur `frigate` und `tailscale-1` |
> | dieselbe Query mit `\|~ "(?i)error\|fail\|crit"` — Panel 106 | **0 Serien** |
>
> Der Matcher ist **nicht** der Fehler — `{job=~".+"}` und `{job!=""}` liefern
> beide 26 Serien, sie sind semantisch identisch. Die Ursache liegt eine Ebene
> tiefer, in der Ingestion:
>
> | Messung | Wert |
> |---|---|
> | Hosts, die überhaupt Logs liefern | **3** (`dns2`, `frigate`, `tailscale-1`) von rund 35 |
> | Zeilen, die Loki als `too_far_in_future` verwirft | **7,73 von 7,92 pro Sekunde = 97,7 %** |
> | Zustand des Loki-Dienstes dabei | `up = 1`, Empfangszähler läuft normal weiter |
>
> Die Ursache des Verwurfs ist ein Zeitzonenfehler: RFC3164 überträgt **keine
> Zeitzone** (`Aug 25 07:39:29`), und Alloy las den Sender-Zeitstempel wegen
> `use_incoming_timestamp = true` als UTC. Jede Zeile eines Hosts in CEST lag
> damit zwei Stunden in der Zukunft. Die Trennlinie ist exakt die Zeitzone:
> `frigate` und `dns2` stehen auf UTC und kommen durch, `docker-infra-1/2/3`
> und `postgres-prod` stehen auf CEST und werden verworfen.
>
> Für den Leitstand ist der Unterschied zwischen beiden Ursachen belanglos —
> das Ergebnis ist dasselbe: Ein „Fehler-Rate"-Panel, das dauerhaft auf Null
> steht, ist von einem „keine Fehler"-Panel optisch nicht zu unterscheiden.
> **Und die Anzeige hätte den Ausfall bemerken müssen, egal woran er lag.**

Das ist der Grundfehler, den ein Leitstand nie machen darf, und er ist
strukturell derselbe wie `noDataState` im Alarmsystem:

> **„0 Fehler" und „0 Daten" sehen identisch aus — es sei denn, die Anzeige
> zwingt sich, den Unterschied zu zeigen.**

Ein zweiter Befund derselben Klasse, gemessen am selben Tag:

> **Kein einziges der 20 Dashboards zeigt Alarme an.** Die Suche nach
> `alertlist`, `annolist` und `alertGroups` über alle `dashboard.data`-Blobs
> ergibt null Treffer. Das Alarmsystem und die Anzeige sind vollständig
> entkoppelt. Was der Leitstand über den Zustand der Anlage sagt, hat mit dem,
> was Telegram meldet, keine gemeinsame Oberfläche.

---

## 1. Methode

| Quelle | Was daraus stammt |
|---|---|
| `/mnt/rbd/grafana/grafana.db`, Tabellen `dashboard`, `folder`, `dashboard_provisioning` (`mode=ro&immutable=1`) | Dashboard-Inventar, Panelzahlen, Verlinkung, Provisionierungsherkunft |
| `home-overview`-JSON, panelweise geparst | Geometrie, Schwellwerte, Farbmodi, Drill-down-Links, Query-Duplikate |
| VictoriaMetrics `/api/v1/query` | Liefert jede Level-1-Query einen Wert? Existiert die Metrik? |
| Loki `/loki/api/v1/query` (über den Grafana-Container — Loki ist distroless, kein `sh`) | Gegenprobe der drei Log-Panels |
| Grafana `/metrics` im Container | stehende Alarme, Zustellungen, Laufzeit |
| `docker service ls` / `docker node inspect` | Topologie und Ausfallmodi des Leitstands selbst |
| EEMUA 201 (3. Aufl.), ISA-101.01 / IEC 63303, ASM-Guidelines, HPHMI | Normbezug — mit den Einschränkungen aus 1.1 |

### 1.1 Grenzen der Normbasis — bewusst offengelegt

**Weder EEMUA 201 noch ISA-101.01 lagen im Volltext vor; beide sind
kostenpflichtig.** Verwendet wurden offizielle Geltungsbereiche, ein
Konferenzpapier des Autors der 3. EEMUA-Auflage, das frei zugängliche
ASM-Whitepaper, das PAS-Whitepaper und peer-reviewte Primärliteratur. Drei
Punkte, die man wissen muss, bevor man dieses Dokument gegen jemanden zitiert:

**1. EEMUA 201 ist keine Norm.** Die 3. Auflage (2019) heißt *„Control Rooms:
A Guide to Their Specification, Design, Commissioning and Operation"*; EEMUA
selbst schreibt: *„is not a standard and is not intended to replace any."* Die
ergonomischen Zahlenwerte (Sichtabstände, Maße, Beleuchtungsstärken) liegen
nicht dort, sondern in **ISO 11064** (7 Teile), die EEMUA 201 referenziert.

**2. ISA-101.01-2015 ist inzwischen international: IEC 63303:2024.** Eine
Revision „ISA-101.01-2025" gibt es nicht. Ergänzend existieren
ISA-TR101.01-2022 („HMI Philosophy") und ISA-TR101.02-2019 („HMI Usability and
Performance").

**3. Zur Wirksamkeit des High-Performance-HMI-Ansatzes ist die Beleglage
dünner, als die Fachliteratur vermuten lässt.** Die überall zitierte Zahl
(„Operatoren erkennen Störungen ein Vielfaches häufiger vor dem Alarm") ist auf
**eine** Studie zurückführbar: Errington, Reising, Bullemer et al. (2005),
*Proc. HFES* 49(23), 2036–2040 — **n = 21** Operatoren, Konferenzband, Autoren
sind die Entwickler des getesteten Interfaces. Belegt ist daraus: Störung vor
dem ersten Prozessalarm erkannt in **48 % der Fälle** (+38 Prozentpunkte),
Erfolgsquote **96 %** (+26), Bearbeitung 7,5 min bzw. 41 % schneller. Die oft
danebengestellte EPRI-Studie 1017637 (2009) **stützt das nicht**: Sie ist ein
„Technical Update", von **PAS selbst** verfasst, n = 8, und fand in drei von
vier Szenarien *keine* signifikanten objektiven Unterschiede.

> **Konsequenz für dieses Dokument: Die HPHMI-Gestaltungsprinzipien werden
> übernommen, weil sie sich mit ASM, EEMUA und ISO decken und
> wahrnehmungspsychologisch begründet sind — nicht wegen einer Wirkungszahl.
> Jede Begründung in Abschnitt 6 stützt sich stattdessen auf einen am eigenen
> Bestand gemessenen Defekt.**

**Nicht belegbar und deshalb hier nicht als Normwert ausgegeben:** maximale
Elementanzahl auf einem Übersichtsbild, maximale Navigationstiefe in Klicks
(die kursierende „3-Klick-Regel" ließ sich ausschließlich in generierten
SEO-Blogs finden), maximale Bildaufbauzeit, empfohlene Anzahl gleichzeitiger
Farben. **Wo dieses Dokument solche Zahlen nennt, sind es Festlegungen für
dieses Homelab.** Sie sind als solche gekennzeichnet und aus dem gemessenen Ist
begründet.

---

## 2. Ist-Aufnahme

### 2.1 Dashboard-Inventar

20 Dashboards, 6 Ordner. Panelzahl inklusive Row-Panels.

| Dashboard (uid) | Panels | davon Rows | Panel-Links | aus Git | Ebene (Vorschlag) |
|---|---:|---:|---:|:--:|---|
| `home-overview` | 33 | 7 | 11 | **nein** | **1** |
| `proxmox-cluster` | 11 | 0 | 0 | nein | 2 |
| `pve-hosts` | 14 | 0 | 0 | ja | 2 |
| `ceph-cluster` | 22 | 5 | 0 | nein | 2 |
| `pbs-overview` | 15 | 4 | 0 | nein | 2 |
| `synology-nas` | 38 | 7 | 5 | ja | 2 |
| `unifi-poe` | 24 | 5 | 0 | ja | 2 |
| `ups-power` | 11 | 0 | 0 | ja | 2 |
| `postgres-prod-singlevm` | 9 | 0 | 0 | ja | 2 |
| `ha-infrastructure` | 19 | 4 | 0 | nein | 2 |
| `frigate-detail` | 8 | 0 | 0 | nein | 2 |
| `victoriametrics` | 20 | 4 | 0 | nein | 2 |
| `synology-storage` | 15 | 3 | 0 | ja | 3 |
| `synology-smart` | 15 | 5 | 0 | ja | 3 |
| `synology-net` | 15 | 4 | 0 | ja | 3 |
| `ceph-storage-drill-down` | 9 | 0 | 0 | ja | 3 |
| `ha-energy-correlation` | 23 | 5 | 0 | ja | 3 |
| `000000039` (PostgreSQL Database) | 35 | 3 | 0 | nein | 3 (Altlast) |
| `rYdddlPWk` (Node Exporter Full) | 132 | 16 | 0 | nein | 4 |
| `rescue-tracker` | 7 | 0 | 0 | nein | außerhalb |

**Drei Befunde daraus, alle nachgerechnet:**

1. **13 von 20 Dashboards existieren nur in der SQLite-Datei** — darunter
   `home-overview` selbst. Sie sind nicht aus Git reproduzierbar. Die Datei
   liegt auf `/mnt/rbd/grafana/`, also auf einem RBD-Volume mit exclusive-lock
   hinter einem Watchdog. Geht das Volume verloren, ist der Leitstand weg und
   **nur aus einem PBS-Backup wiederherstellbar**.
2. **Von 19 Nicht-Level-1-Dashboards sind 5 per Drill-down von Ebene 1
   erreichbar** (`proxmox-cluster`, `ceph-cluster`, `000000039`,
   `pbs-overview`, `frigate-detail`). Die übrigen 14 — darunter `pve-hosts`,
   `synology-nas`, `unifi-poe`, `ups-power` und `postgres-prod-singlevm` —
   findet man nur über die Dashboard-Suche.
3. **Kein einziges Dashboard verlinkt zurück auf `home-overview`.** Die
   Synology-Familie verlinkt untereinander (5/3/3/3 Dashboard-Links),
   `unifi-poe` hat einen tag-basierten Link auf die USV. Der Weg zurück zur
   Übersicht existiert nirgends.

### 2.2 `home-overview` im Detail

33 Panels: 7 Rows, 26 Inhaltspanels, davon **3 ohne jede `targets`-Definition**
(112 „Synology", 114 „Synology Storage", 119 „UniFi" — Text: *Coming Soon* bzw.
*Soon*). Netto **23 Panels, die etwas anzeigen sollen**.

| Kennzahl | Messwert |
|---|---|
| Gesamthöhe | **49 Rastereinheiten** (~1.860 px) |
| Sichtbar ohne Scrollen (~24 Einheiten bei 1080p abzüglich Browser- und Grafana-Chrome) | 25 von 33 Panels |
| **Unter der Falz** | 8 Panels — die kompletten Blöcke *Top Consumers* und *Logs Overview* |
| Panels mit Drill-down-Link | **11 von 23** |
| Panels mit `colorMode: background` (ganze Kachel eingefärbt) | **9** |
| Panels, deren Basis-Schwelle (`value: null`) **grün** ist → im Normalbetrieb farbig | **15 von 23** |
| Gleichzeitig verwendete Signalfarben | 5 (`green`, `yellow`, `orange`, `red`, `#444`) |
| Panels, deren Query nachweislich Daten liefert | **20 von 23** |
| Alarmpanels | **0** |
| Aktualisierung / Zeitfenster | `30s` / `now-1h` |
| Sprache | gemischt DE/EN (`PG Verbindungen` neben `PG Connections`, `Datenbank` neben `Top Consumers`) |

**Redundanzen und Widersprüche, einzeln geprüft:**

| Befund | Beleg |
|---|---|
| **Panel 4 und Panel 50** tragen dieselbe Query `pg_up{instance="postgres-prod"}` — Titel „PostgreSQL" und „PostgreSQL DB", in zwei verschiedenen Abschnitten. | bitidentischer `expr` |
| **Panel 3 und Panel 53** zeigen dieselbe Zahl mit **gegensätzlichen Farbskalen**. Beide lieferten am 2026-08-25 den Wert **31**. Panel 3 (`red@null, yellow@3, green@5`) färbt *mehr Verbindungen grüner*; Panel 53 (`green@null, yellow@150, red@190`) färbt *mehr Verbindungen roter*. Bei 200 Verbindungen wäre Panel 3 **grün** und Panel 53 **rot** — auf demselben Bildschirm. | `sum(pg_stat_database_numbackends{instance="postgres-prod"})` = `sum(pg_stat_database_numbackends)` = 31 |
| **Panel 51 „Replication Lag"** zeigt `pg_replication_lag_seconds` = 0, grün. `postgres-prod` ist seit der Patroni-Abschaltung eine **Einzel-VM ohne Replikation**; `pg_stat_replication_*` existiert in VictoriaMetrics **nicht**. Das Panel meldet also nicht „Replikation gesund", sondern „es gibt keine Replikation" — und sieht dabei aus wie Ersteres. | keine Replikations-Slot-Metrik vorhanden |
| **Panel 12 „Node Uptime"**: rot unter 1 h, gelb unter 24 h, grün darüber. pve02 lief zum Messzeitpunkt 3,9 h → das Panel steht **gelb**, obwohl ein Node nach einem geplanten Neustart der Normalzustand ist. | `system_uptime`: pve01 1,4 d · pve02 0,2 d · pve03 2,0 d |
| **Panel 1 „PVE Nodes"**: grün ab 3. Im Normalbetrieb dauerhaft farbig, und die Zahl `3` trägt ihre Bedeutung ausschließlich in der Farbe. | `count(cpustat_cpu{object="nodes"})` = 3 |
| **Panels 112 / 114 / 119** („Coming Soon") liegen prominent in der obersten Zeile bzw. im Storage-Block — obwohl die Daten seit ~2 Tagen vorhanden sind (`up{job="snmp-synology"}` = 1, 45 `snmp_*`-Metriken, 138 `hrStorage*`-Serien; `up{job="unpoller"}` = 1, 2.950 `unpoller_device*`-Serien) und die Level-2-Dashboards `synology-nas` und `unifi-poe` bereits existieren. | vor 3 d: keine Daten; heute: vorhanden |

### 2.3 Zustand des Alarmsystems zum Messzeitpunkt

Der Vergleich zum Alarmdokument (2026-08-24) ist wichtig, weil die
Leitstandsregeln daran andocken:

| Kennzahl | 2026-08-24 | **2026-08-25** |
|---|---:|---:|
| Regeln gesamt | 64 | 68 |
| `critical` / `warning` / `info` | 32 / 30 / 2 | 32 / 34 / 2 |
| `grafana_alerting_alerts{state="alerting"}` | **26** | **4** |
| `{state="normal"}` | — | 138 |
| `alerts_received_total{firing}` | 18.294 (14,5 h) | 646 (3,8 h) |
| Telegram-Zustellungen | 15 (14,5 h) | 6 (3,8 h) |
| `inhibition_rules` | 0 | 0 |

Der Defekt aus Abschnitt 0 des Alarmdokuments ist offenbar behoben — die
stehenden Alarme sind von 26 auf **4** gefallen. Der Zielwert dort lautet
**≤ 2**; er ist noch nicht erreicht, aber in Reichweite. Aus den Annotationen
der letzten 12 h lassen sich die vier plausibel zuordnen: `Synology
SSD-Restlebensdauer sinkt` (seit 04:01), `Paperless unreachable` (seit 03:07),
`HTTPS probe failing` (seit 03:17), `PVE host memory getting tight` (seit 06:15).

**Genau diese vier stehen nirgends auf einem Dashboard.** Sie sind nur in
Telegram und in der Grafana-Alarmansicht sichtbar — nicht dort, wo man
hinsieht, wenn man wissen will, wie es der Anlage geht.

Nebenbefund: `grafana_*`-Metriken sind in VictoriaMetrics **weiterhin nicht
vorhanden** (`count({__name__=~"grafana_.*"})` → leer). Der Scrape-Job aus
Abschnitt 7.1 des Alarmdokuments ist nicht eingerichtet. Ohne ihn lässt sich
die Kernzahl „stehende Alarme" nicht auf ein Dashboard bringen — sie ist nur
per `docker exec` abfragbar.

---

## 3. Der blinde Fleck — was ein Drittel der Anzeigefläche wirklich zeigt

Der Loki-Block ist das Gegenstück zum Störfall vom 23.08. im Alarmdokument: der
eine vollständig dokumentierte Fall, an dem sich das Prinzip zeigt.

```
Rastereinheit   Inhalt                                       Zustand
 0 –  5   Service Health (8 Kacheln)                          liefert
 5 – 10   Storage & Bandbreite (4 Kacheln, 1 leer)            liefert
10 – 16   Proxmox Nodes (3 Panels)                            liefert
16 – 21   Datenbank (3 Panels, 1 ohne Substanz)               liefert
21 – 26   Monitoring (2 Panels)                               liefert
--------  ------------------------------------------- Falz bei ~24 ---
26 – 33   Top Consumers (3 Panels)                            liefert
33 – 49   Logs Overview (3 Panels)                            fast leer
```

Der Loki-Block ist:

- **der größte** Einzelblock des Dashboards (16 von 49 Einheiten — der
  nächstgrößere, *Top Consumers*, hat 7),
- **vollständig unterhalb der Falz**, also nur nach Scrollen sichtbar,
- **praktisch leer**, ohne dass es aufgefallen wäre — 625 Zeilen pro Stunde von
  zwei Hosts, wo 35 Hosts erwartet würden,
- und trägt Titel, die im leeren Zustand **beruhigen**: „Error Rate (alle
  Hosts)" auf Null gelesen heißt „keine Fehler auf keinem Host".

Die Ursache liegt nicht am Panel, sondern an der Ingestion: Loki verwirft
**97,7 %** aller eintreffenden Zeilen als `too_far_in_future` (Zeitzonenfehler,
siehe Abschnitt 0), und auf pve01/pve03 ist rsyslog überhaupt nicht aktiv.
Das ist für die Gestaltungsfrage aber zweitrangig — **ein Leitstand muss einen
Ausfall seiner Datenquelle anzeigen, unabhängig davon, woran der Ausfall
liegt.**

Und selbst nach vollständiger Reparatur bliebe ein zweiter Fehler: das Label
`host` hat in Loki genau **drei** Werte (`dns2`, `frigate`, `tailscale-1`),
während VictoriaMetrics **35 Scrape-Instanzen** kennt. „Alle Hosts" ist also
auch dann falsch — es sind knapp 9 % der Anlage. Der Titel behauptet eine
Vollständigkeit, die die Datenlage nicht hergibt.

Daraus folgt die härteste Regel dieses Dokuments (Abschnitt 6.5):

> **Ein Panel, dessen leerer Zustand wie ein guter Zustand aussieht, ist ein
> Sicherheitsmangel — kein Schönheitsfehler.** Jede Zählung schlechter Dinge
> braucht auf demselben Panel den Nenner: wie viele Dinge wurden überhaupt
> beobachtet.

---

## 4. EEMUA 201 / ISA-101, übersetzt

Der Grundunterschied ist derselbe wie beim Alarmdesign, nur an anderer Stelle:

> **EEMUA 201 gestaltet einen Arbeitsplatz, an dem acht Stunden lang jemand
> sitzt — mit vier Bildschirmen, 30 m² Raum und geregelter Beleuchtung. Hier
> gibt es einen Browser-Tab, in den zweimal täglich dreißig Sekunden lang
> jemand schaut, oft auf einem Telefon, oft nachts im Dunkeln.**

Alles, was aus dieser Prämisse folgt, ändert sich. Die Norm optimiert die
*Daueraufmerksamkeit*; hier muss die *Ersterfassung* optimiert werden.

### 4.1 Die Displayhierarchie (ISA-101 Level 1–4)

Das Ebenenmodell ist der Teil der Norm, der sich am saubersten überträgt, weil
er nichts über Möbel, Licht oder Schichtpläne voraussetzt — nur über
Informationsdichte und Zweck.

> **Ehrlich zur Quellenlage:** Belastbar ist, dass ISA-101 **höchstens vier
> Ebenen** empfiehlt, gestuft *Übersicht → Einheit/Aufgabe → Detail →
> Diagnose*, und dass die Hierarchie der **Aufgabenanalyse** folgt, nicht dem
> Anlagenfließbild. Die exakte Normbenennung der Ebenen ließ sich ohne
> Volltext nicht rekonstruieren; die verfügbaren Sekundärquellen widersprechen
> sich bei Level 2. Die Beschreibungen unten folgen der ausführlichsten
> zitierbaren Darstellung (PAS/Hollifield) und sind für unsere Zwecke
> ausreichend trennscharf.

| ISA-101 | Zweck in der Anlage | **Entsprechung hier** | Dashboards |
|---|---|---|---|
| **Level 1** — Overview | „the operator's entire span of control … **Control interactions are not made from this screen**"; laut EEMUA 201 **dauerhaft angezeigt, für häufige kurze Blicke, ausdrücklich kein Arbeitsbild** | **„Ist die Anlage in Ordnung — und wenn nein, wo?"** Eine Bildschirmhöhe, kein Scrollen. | `home-overview` |
| **Level 2** — Unit | „all the information and controls required to perform most operator tasks associated with that section, **from a single graphic**" | **Fachbild je Teilsystem.** „Was genau ist an diesem Teilsystem los?" | `pve-hosts`, `ceph-cluster`, `synology-nas`, `unifi-poe`, `ups-power`, `postgres-prod-singlevm`, `pbs-overview`, `ha-infrastructure`, `frigate-detail`, `victoriametrics`, `proxmox-cluster` |
| **Level 3** — Detail | „all the detail about **a single piece of equipment** … for a detailed diagnosis of problems" | **Bauteil-/Sonderbild.** „Welche Platte, welcher Port, welche Query?" | `synology-smart`, `synology-storage`, `synology-net`, `ceph-storage-drill-down`, `ha-energy-correlation`, `000000039` |
| **Level 4** — Support / Diagnostics | „the most detail of subsystems, individual sensors, or components … the dividing line between Level 3 and Level 4 **can be somewhat gray**" | **Rohbilder und Explore.** Keine Gestaltungspflicht außer: erreichbar sein und als Level 4 erkennbar sein. | `rYdddlPWk` (Node Exporter Full, 132 Panels), Grafana Explore, Log-Queries |

**Der eine Punkt, an dem die Übersetzung nicht sauber ist — und das muss man
sagen, statt es zu glätten:** ISA-101 Level 2 ist das Bild, an dem der Operator
*handelt*; die Definition sagt wörtlich „information **and controls**". In
Grafana kann man nicht handeln. Gehandelt wird per SSH, Portainer oder
Git-Commit. **Ebene 2 ist hier reine Diagnose.**

Daraus folgt eine Regel, die es in der Norm nicht gibt und hier gebraucht wird:

> **Jedes Level-2-Dashboard muss die Handlung benennen, zu der es führt.** Ein
> Textpanel mit den zwei bis vier Kommandos, die man an dieser Stelle absetzt,
> oder ein Link auf das Runbook. Sonst endet der Drill-down bei einem
> Diagramm — und der Weg vom „hier stimmt was nicht" zum „das tue ich jetzt"
> steht nirgends.

Das ist die Entsprechung zu den *operating procedures*, die in der Leitwarte
neben der Konsole liegen. Nur gibt es hier keine Konsole, neben der etwas
liegen könnte.

**Was auf welcher Ebene ausdrücklich *nichts* zu suchen hat:**

| Ebene | Gehört hin | Gehört **nicht** hin |
|---|---|---|
| **1** | Stehende Alarme · Erreichbarkeit der Teilsysteme als Ja/Nein · Kapazitäten mit eingezeichnetem Sollbereich · eingebettete Kurzverläufe (≤ 4 Spuren) · Alter der eigenen Daten | Freistehende Zeitreihen mit Legende · Top-N-Listen · Logzeilen · Einzelwerte ohne Sollbereich · alles, was man nicht in 5 Sekunden liest · Platzhalter für Geplantes |
| **2** | Der Zustand *eines* Teilsystems über die Zeit · die 5–15 Größen, die dessen Gesundheit ausmachen · die Handlung, zu der das Bild führt | Fremde Teilsysteme · Rohmetriken ohne Interpretation · Panels, die es auf Ebene 1 schon gibt (Duplikate driften auseinander, siehe Panel 3/53) |
| **3** | Einzelkomponente, Einzelgerät, Einzelquery · Diagnose *nach* der Verdachtsbildung | Aggregate über die ganze Anlage (das ist Ebene 1) |
| **4** | Alles Übrige. Bewusst ungestaltet. | Der Einstiegspunkt. Level 4 darf nie das erste sein, was man sieht. |

**Und die Gliederungsmetapher:** ISA-101 leitet die Hierarchie aus der
Aufgabenanalyse ab, nicht aus dem R&I-Fließbild. Hier gibt es keinen Stofffluss,
an dem man sich orientieren könnte. Die tragfähige Metapher ist die
**Abhängigkeitskette**:

```
Strom → Netz → Hypervisor → Storage → Datenbank → Anwendung
```

Danach sollte Ebene 1 gegliedert sein — nicht nach Herstellern („Synology",
„UniFi") und nicht nach Technologien („Logs", „Top Consumers"). Wer die Kette
von links liest, findet die Ursache; wer sie nach Herstellern liest, findet
Symptome.

### 4.2 Navigation

ISA-101 fordert konsistente, vorhersagbare Navigation zwischen den Ebenen per
Drill-down. Übersetzt und geprüft:

| Anforderung | Ist |
|---|---|
| Jedes Element auf Ebene 1 führt zu seinem Ebene-2-Bild | **11 von 23** Panels haben einen Link |
| Jedes Ebene-2-Bild führt zurück auf Ebene 1 | **0 von 19** |
| Der Zeitbereich überlebt den Sprung | **0 von 11** Level-1-Links (kein `keepTime`, kein `${__url_time_range}`) — die Synology-Familie macht es dagegen richtig |
| Der Drill-down führt zum *aktuellen* Fachbild | **nein:** Panels 4, 50, 53 führen auf `/d/000000039/` („PostgreSQL Database", 35 Panels, UI-only, Patroni-Ära) statt auf `postgres-prod-singlevm` (9 Panels, aus Git, aktuell) |
| Keine toten Links | **erfüllt** — alle 16 geprüften Linkziele existieren |

Der `keepTime`-Befund ist kein Detail. Wer um 08:00 auf dem Übersichtsbild eine
Auffälligkeit im Zeitfenster „letzte Stunde" sieht und klickt, landet auf einem
Bild mit dem dort hinterlegten Standardfenster (`now-6h`, `now-24h`, bei
`ha-energy-correlation` sogar `now-7d`) — und sucht dort nach etwas, das er
gerade an einer anderen Stelle der Zeitachse gesehen hat.

### 4.3 Farbe — und eine Korrektur am verbreiteten Verständnis

Hier weicht der Bestand am weitesten ab, und hier zirkuliert zugleich das
hartnäckigste Missverständnis. Es lohnt, es auszuräumen, bevor man Regeln
daraus ableitet:

> **Der „graue Bildschirm" wird von seinen eigenen Urhebern zurückgewiesen.**
> Das ASM Consortium schreibt wörtlich: *„the ASM Consortium **does NOT
> recommend only using grayscale** in display design but to use an effective
> color scheme to establish the relative importance of information."* EEMUA 201
> geht noch weiter: Der Grey-Screen-Ansatz sei bei Operatoren oft unbeliebt,
> und volle Farbminimierung *„is not necessarily the best solution"*.

Die tragfähige Regel ist deshalb **nicht** „keine Farbe", sondern eine Abstufung
nach Salienz — und das ist genau die Formulierung, die alle vier Regelwerke
teilen:

| Rolle | Farbbehandlung | Quelle |
|---|---|---|
| Sicherheitskritisch / dringend | **gesättigt**, maximale Salienz | ASM: „should stand out the most in the display foreground" |
| Status, Kontext | **entsättigt / pastell** | EEMUA 201: kräftige Farben nur für Alarme, pastellige für Statusinformation |
| Statisch (Rahmen, Achsen, Überschriften, Hintergrund) | **keine Farbe** | ASM: „static data or information that provides context … should blend more to the background" |

Dazu kommt die Regel, die ASM **diskriminante Codierung** nennt und die im
Bestand am eindeutigsten verletzt ist:

> *„if red means critical alarm state then it should not also mean a pump is
> off … Non-discriminant coding requires the viewer to use additional mental
> effort and time to exhaustively scan similar colored objects."*

**Eine Farbe, eine Bedeutung.** Panel 3 und Panel 53 zeigen dieselbe Zahl —
Grün heißt auf dem einen „viele Verbindungen", auf dem anderen „wenige". Das
ist non-discriminant coding im Reinformat, auf demselben Bildschirm.

Und die Regel, an der PAS besonders deutlich wird: **das Paradigma „grün = an,
rot = aus" wird ausdrücklich als *improper use of color* verworfen.**
Betriebszustand gehört über **Helligkeit plus Textwort** codiert (heller als
der Hintergrund = in Betrieb, dunkler = aus), Alarmpriorität über **Farbe plus
Form plus Ziffer**. Rot bleibt damit für Alarme reserviert. EEMUA formuliert
denselben Gedanken als Kosten-Nutzen-Rechnung: Wird Rot auch für geschlossene
Ventile benutzt, sinkt die Sichtbarkeit echter Alarme.

Gemessen an `home-overview`:

- **15 der 23 Inhaltspanels sind im Normalbetrieb farbig** — ihre Basis-Schwelle
  (`value: null`) ist `green`.
- **9 Panels färben die gesamte Kachelfläche** (`colorMode: background`). Der
  Bildschirm ist im Gesundzustand ein Farbraster.
- **5 Signalfarben gleichzeitig** im Umlauf.

Die Folge ist nicht ästhetisch, sondern funktional: **Farbe, die im
Normalbetrieb verbraucht wird, steht im Störfall nicht mehr zur Verfügung.**
Eine rote Kachel unter fünfzehn grünen hat keinen Kontrast mehr gegen den
Hintergrund — sie konkurriert mit fünfzehn anderen gesättigten Flächen.

**Zur Rot-Grün-Sehschwäche.** Belastbare Primärzahl (Birch 2012, *JOSA A*
29(3)): **etwa 8 % der Männer und etwa 0,4 % der Frauen europäischer
Abstammung**; häufigste Form ist die Deuteranomalie. Die Konsequenz für die
Gestaltung wird von PAS, ASM und API RP-1165 gleichlautend gefordert:

> *„Color, by itself, is never used as the sole differentiator of an important
> condition or status."*

Ausgerechnet Rot und Grün sind hier das dominante Paar. Panel 4, 50 und 120
machen es richtig — sie setzen Value-Mappings auf `DOWN` / `UP` / `Running`,
die Information steht also auch im Text. Panel 1, 3, 12 und die Gauges tragen
ihre Information **ausschließlich in der Farbe**: Die Zahl `3` bei den
PVE-Nodes ist ohne die grüne Fläche bedeutungslos, weil nirgends steht, dass 3
der Sollwert ist.

### 4.4 Informationsdichte, Bildschirmfläche — und warum Trends *doch* auf Ebene 1 gehören

EEMUA 201 und ISA-101 nennen **keine harte Panel-Obergrenze**. Was EEMUA sagt,
ist konkreter und für uns brauchbarer: Vier Bildschirme an der Konsole sind
normalerweise ausreichend, und **mehr Bildschirme sind ein Indiz für schlechtes
Displaydesign oder für Operator-Überlastung** — nicht für mehr Information. Die
direkte Entsprechung hier ist **Scrollen**: Ein Übersichtsbild, das gescrollt
werden muss, hat dasselbe Problem, nur in der Vertikalen.

Gemessen: `home-overview` ist **49 Rastereinheiten** hoch, also grob **zwei
Bildschirmhöhen**. Acht Panels liegen unter der Falz, darunter der komplette
Loki-Block. Auf einem Telefon — dem realistischen Lesegerät um 08:00 — sind es
deutlich mehr.

Die Anordnung folgt zudem nicht der Bedeutung: Der **Datenbank**-Block liegt auf
Rastereinheit 16–21, aber `pg_up` erscheint zusätzlich als Kachel 4 ganz oben
im Block *Service Health*. Dieselbe Information zweimal, an zwei Orten.

**Ein Punkt, an dem die Norm der naheliegenden Regel widerspricht — und die
Norm hat recht:** Man wäre versucht, Zeitreihen pauschal von Ebene 1 zu
verbannen. EEMUA 201 sagt das Gegenteil: Trends seien *„often the most
effective way of presenting data on Overview displays"*, weil Menschen Muster
besser erkennen als Zahlen. ISO 11064-4 liefert die physiologische Begründung:
Vom Sehfeld von etwa **±35°** um die Blickachse sind nur **1° bis 2° scharf**.
Alles andere wird als Muster, Bewegung und Kontrast wahrgenommen — nicht als
Ziffernfolge.

Die Regel lautet deshalb nicht „keine Kurven", sondern:

> **Eingebettete Kurzverläufe mit eingezeichnetem Sollbereich gehören auf
> Ebene 1. Freistehende Zeitreihen-Panels mit Legende, Achsenbeschriftung und
> unbegrenzter Serienzahl gehören auf Ebene 2.**

Die Trennlinie ist die Frage: *Muss man es lesen oder sieht man es?* PAS nennt
dazu den einzigen konkreten Zahlenwert, der sich belegen ließ: **höchstens 3
bis 4 Spuren je Kurve**. Die Panels 106 und 107 stapeln `sum by (host)` über
eine unbegrenzte Zahl von Hosts — sie sind auch inhaltlich Ebene-2-Material.

### 4.5 Aktualisierung

`home-overview` steht auf `refresh: 30s` bei 23 aktiven Panels und ~30 Queries.
Das ist für ein Bild, das zweimal täglich für dreißig Sekunden geöffnet wird,
Aufwand ohne Nutzen — aber auch kein Schaden, solange niemand das Bild dauerhaft
offen lässt. Relevanter ist die andere Richtung:

> Ein Übersichtsbild, das offen liegen bleibt und **aufhört zu aktualisieren**,
> zeigt einen eingefrorenen Zustand, der von einem gesunden nicht zu
> unterscheiden ist. Derselbe Fehlermodus wie in Abschnitt 0.

Deshalb gehört das **Alter der eigenen Daten** auf Ebene 1 (Abschnitt 7).

### 4.6 Was aus EEMUA 201 / ISA-101 hier *nicht* gilt

Ehrlichkeitshalber, damit die Norm nicht zur Checkliste verkommt — analog zu
Abschnitt 4.7 des Alarmdokuments:

| Normkonzept | Warum hier nicht anwendbar |
|---|---|
| **Leitstandfläche (30 m² für einen Operator, +10 m² je weiterem), Deckenhöhe ≥ 3 m, Fenster, Konsolenanordnung** | Es gibt keinen Leitstand. Das sind Bauanforderungen an ein Gebäude, das nicht existiert. |
| **Bildschirmanzahl und -anordnung (4 Haupt- + bis zu 4 Sekundärschirme, „Quad"-Layout)** | Ein Fenster, wechselnde Größe, oft ein Telefon. Die funktionale Entsprechung ist nicht die Schirmzahl, sondern die **Scrolltiefe** (4.4). |
| **Sichtabstände, Sehwinkel, Arbeitsplatzmaße** (ISO 11064-3/-4) | Nicht kontrollierbar. Was übrig bleibt, ist die *Begründung* dahinter — scharfes Sehen nur in 1–2° — und die gilt weiter (4.4). |
| **Beleuchtungsstärke, Hintergrundbeleuchtung, Notbeleuchtung** (ISO 11064-6) | Nicht kontrollierbar. **Und mehr als das:** Die ASM-Empfehlung heller Displayhintergründe ist ausdrücklich *„coupled to the recommendation for high ambient lighting in the control room"*. Diese Kopplung existiert hier nicht — gelesen wird oft nachts im Dunkeln. **Die Hintergrundhelligkeit muss deshalb dem Betrachter folgen (Grafana-Theme), nicht der Norm.** Was bleibt, ist die *relative* Salienzabstufung (4.3), die in hell wie dunkel funktioniert. |
| **Schichtübergabe-Displays, Übergabeprotokolle** | Keine Schicht. Die funktionale Entsprechung ist das Digest-Fenster um 08:00/18:00 — ein Telegram-Text, kein Bild. |
| **Rollenspezifische Sichten** (Operator / Ingenieur / Manager) | Eine Person in allen drei Rollen. Getrennte Sichten wären reine Mehrarbeit. |
| **Alarmquittierung an der Anzeige, Shelving-Bedienung, Blinken für Unquittiertes** | Grafana kennt weder Quittierung noch Shelving. Ohne Quittierung hat Blinken keine definierte Bedeutung und wäre reine Belästigung. Deckungsgleich mit Abschnitt 4.7 des Alarmdokuments: Nachrüsten lohnt nicht. |
| **Antwortzeitanforderungen für Bedienhandlungen** | Es gibt keine Bedienhandlungen im HMI (4.1). Bildaufbauzeit ist eine Bequemlichkeitsfrage, keine Sicherheitsfrage. |
| **Vollständiger HMI-Lebenszyklus mit Verifikation, Validierung, Schulung, Freigabe, MOC, Audit** | Setzt ein Team und eine Abnahmeinstanz voraus. Es gibt eine Person. Was davon **bleibt**, ist das eine Artefakt, das ISA-101 zwingend verlangt: der **Style Guide** — dieses Dokument. |
| **Mehrere Übersichtsbilder je Betriebsmodus** (An-/Abfahren, Normalbetrieb, Notfall) | Es gibt keine definierten Anlagenzustände. Näherungsweise: Wartungs- und Backup-Fenster — dieselbe Einschränkung wie im Alarmdokument 4.7. |
| **Prozessfließbilder als Grundmetapher** | Kein Stofffluss. Ersatz: die Abhängigkeitskette (4.1). |

Und umgekehrt — was hier **wichtiger** ist als in der Leitwarte:

1. **Ersterfassung statt Daueraufmerksamkeit.** Der Operator in der Leitwarte
   kennt den Normalzustand seines Bildes auswendig; eine Abweichung fällt ihm
   auf, ohne dass er sie liest. Hier sieht jemand nach Stunden oder Tagen wieder
   hin und hat **keinen inneren Vergleichswert**. Deshalb muss **jede Zahl ihren
   Sollbereich mitbringen** — die Anzeige muss die Erfahrung ersetzen, die der
   Leser nicht hat. In der Leitwarte ist das eine Komfortfrage; hier ist es die
   Voraussetzung dafür, dass das Bild überhaupt lesbar ist.
2. **Der leere Zustand.** In der Leitwarte fällt ein totes Bild in Minuten auf,
   weil jemand davorsitzt. Hier war ein leeres Bild **mindestens sieben Tage**
   unbemerkt (Abschnitt 3). Ein Homelab-Leitstand muss deshalb aktiv beweisen,
   dass er lebt — die Leitwarte darf das voraussetzen.
3. **Der Leitstand als eigener Ausfallpunkt.** EEMUA setzt eine redundante,
   gewartete Leitsystem-Infrastruktur voraus. Hier ist es **ein Container mit
   `replicas=1`** (Abschnitt 7).
4. **Das Dashboard ist der einzige Kanal für `info`.** Regel 4 des
   Alarmdokuments verweist selbstheilende Zustände ausdrücklich „ins Dashboard,
   nicht nach Telegram". Damit trägt die Anzeige hier **mehr** Last als in der
   Norm, wo niedrig priorisierte Zustände auf einer Alarmliste landen, die
   ohnehin jemand liest.
5. **Reproduzierbarkeit aus Git.** In der Leitwarte ist das Bildsystem Teil
   eines gewarteten DCS mit Konfigurationsverwaltung. Hier liegt es in einer
   SQLite-Datei auf einem Ceph-Volume — und ist damit ein Datenverlustrisiko,
   das die Norm gar nicht kennt.

---

## 5. Zielwerte für diesen Leitstand

Die Werte, gegen die künftig gemessen wird. **Alle Zahlen sind Festlegungen für
dieses Homelab, keine Normwerte** (siehe 1.1). Die Begründung steht jeweils in
Abschnitt 6.

| Kennzahl | **Ziel** | **Ist (2026-08-25)** |
|---|---|---|
| Inhaltspanels auf Ebene 1 | **≤ 12** | 23 (+3 leere Hüllen) |
| Höhe von Ebene 1 | **≤ 24 Rastereinheiten** (eine Bildschirmhöhe) | 49 |
| Panels ohne `targets` | **0** | 3 |
| Panels, deren Query nachweislich Daten liefert | **100 %** | 20 von 23 |
| Panels, die im Normalbetrieb gesättigte Farbe zeigen | **0** | 15 von 23 |
| Panels mit `colorMode: background` | **≤ 2** (nur Alarmkacheln) | 9 |
| Gleichzeitige Signalfarben | **≤ 3** (+ neutral) | 5 |
| Bedeutungen je Signalfarbe (diskriminante Codierung) | **genau 1** | Grün trägt 2 gegensätzliche (Panel 3 / 53) |
| Zahlen ohne Sollbereich/Bezugsgröße auf Ebene 1 | **0** | 12 |
| Spuren je Kurve auf Ebene 1 | **≤ 4** | unbegrenzt (`sum by (host)`) |
| Level-1-Panels mit Drill-down | **100 %** | 11 von 23 |
| Drill-downs, die den Zeitbereich mitnehmen | **100 %** | 0 von 11 |
| Level-2-Dashboards mit Rücklink auf Ebene 1 | **100 %** | 0 von 19 |
| Level-2-Dashboards von Ebene 1 erreichbar | **100 %** | 5 von 19 |
| Alarmpanels auf Ebene 1 | **genau 1** | 0 |
| Stehende Alarme auf Ebene 1 sichtbar | **ja** | nein |
| Alter der eigenen Daten auf Ebene 1 sichtbar | **ja** | nein |
| Dashboards aus Git provisioniert | **100 %** | 7 von 20 |
| Doppelte oder widersprüchliche Panels je Dashboard | **0** | 2 Paare (4/50, 3/53) |
| Level-2-Dashboards mit benannter Handlung / Runbook | **100 %** | 0 von 19 |

---

## 6. Gestaltungsregeln — konkret, nicht als Prinzip

### 6.1 Ebene 1: die zwölf Kacheln

> **Ebene 1 beantwortet genau eine Frage: „Ist die Anlage in Ordnung — und wenn
> nein, wo?" Alles, was diese Frage nicht beantwortet, gehört auf Ebene 2.**

**Regel:** höchstens **12 Inhaltspanels**, Gesamthöhe höchstens **24
Rastereinheiten**, **kein Scrollen**, **keine Row-Panels** (eine Row ist die
Ankündigung, dass gescrollt wird).

Zwölf ist kein Normwert, sondern aus dem Bestand abgeleitet: Die Anlage hat
nach der Abhängigkeitskette gegliedert genau so viele Teilsysteme, deren
Ausfall man einzeln bemerken muss.

Vorschlag für die Belegung — jede Kachel entspricht einem Level-2-Dashboard und
verlinkt darauf. Die Reihenfolge folgt der Abhängigkeitskette aus 4.1:

| # | Kachel | Zeigt | Level 2 |
|---|---|---|---|
| 1 | **Stehende Alarme** | Liste, sortiert nach Schwere (6.6) | Alarmansicht |
| 2 | **Der Leitstand selbst** | Datenalter, Datenquellen, stehende Alarme gesamt (Abschnitt 7) | `victoriametrics` |
| 3 | **Strom / USV** | Netz vorhanden, Restlaufzeit gegen Sollbereich, Last | `ups-power` |
| 4 | **Netz / UniFi** | Erreichbarkeit, PoE-Last gegen Budget | `unifi-poe` |
| 5 | **Hypervisoren** | 3/3 online, knappste RAM-Reserve gegen Schwelle | `pve-hosts` |
| 6 | **Ceph** | Health, Belegung gegen Schwelle | `ceph-cluster` |
| 7 | **Synology** | Erreichbarkeit, knappstes Volume, RAID-Zustand | `synology-nas` |
| 8 | **PostgreSQL** | `pg_up`, Verbindungen gegen `max_connections` | `postgres-prod-singlevm` |
| 9 | **Swarm** | Manager im Quorum, Services im Soll | (fehlt — anzulegen) |
| 10 | **Anwendungen** | die extern erreichbaren Dienste als Ja/Nein | (fehlt — anzulegen) |
| 11 | **Smart Home / Frigate** | HA erreichbar, Kameras aufzeichnend | `ha-infrastructure`, `frigate-detail` |
| 12 | **Backups (PBS)** | jüngstes Backup, Alter gegen Sollintervall | `pbs-overview` |

Was damit **von Ebene 1 verschwindet**: freistehende Zeitreihen (106, 107),
Logzeilen (108), Top-N-Listen (30, 31, 32), Einzelmetriken ohne Lagebildwert
(51, 52, 115), Duplikate (50 oder 4; 3 oder 53) und die Platzhalter (112, 114,
119).

Was **bleiben darf**, obwohl es eine Kurve ist: ein eingebetteter Kurzverlauf
*innerhalb* einer Kachel, mit eingezeichnetem Sollbereich und höchstens vier
Spuren (4.4). Er ersetzt die Erfahrung, die der Leser nicht hat.

### 6.2 Farbe

Grundlage ist die Salienzabstufung aus 4.3 — **nicht** „grauer Bildschirm".

1. **Gesättigte Farbe ausschließlich für Abweichung vom Sollzustand.** Die
   Basis-Schwelle (`value: null`) jedes Panels ist `text` — Grafanas neutrale
   Vordergrundfarbe. **Grün ist keine Statusfarbe:** Es ist nicht die Aussage
   „gut", sondern die Abwesenheit von Farbe, und die heißt in Grafana `text`.
2. **Rot ausschließlich für `critical`.** Deckungsgleich mit dem Alarmdokument:
   `critical` heißt „dafür stehe ich nachts um drei auf". Rot auf dem Bildschirm
   muss dasselbe heißen — sonst lernt der Leser, Rot zu ignorieren, und die
   Kopplung zwischen Anzeige und Alarm zerfällt.
3. **Orange für `warning`, sonst nichts. Gelb entfällt.** Der Unterschied
   zwischen Gelb und Orange ist genau die Unterscheidung, die
   Rot-Grün-Sehschwäche und Telefondisplays am schlechtesten hergeben. Damit
   bleiben **drei Signalfarben plus neutral**.
4. **Eine Farbe, eine Bedeutung** (diskriminante Codierung nach ASM). Dieselbe
   Farbe darf auf keinem Dashboard zwei Dinge heißen. Prüfung: Für jede
   verwendete Farbe muss sich der Satz „Diese Farbe bedeutet …" eindeutig
   vervollständigen lassen.
5. **Kein „grün = an, rot = aus".** Betriebszustand wird über **Textwort plus
   Helligkeit** codiert (`IN BETRIEB` / `AUS`), nicht über das Ampelpaar. Rot
   bleibt für Alarme reserviert. Panel 4, 50 und 120 tragen das Textwort bereits —
   ihnen fehlt nur der Verzicht auf Rot/Grün.
6. **`info` bekommt keine Farbe**, sondern eine Position: unterhalb der
   kritischen Zeilen, in normaler Schrift.
7. **`colorMode: background` nur für die Alarmkachel.** Eine eingefärbte Fläche
   ist die stärkste verfügbare Auszeichnung; neun davon gleichzeitig sind keine
   Auszeichnung mehr. Alle übrigen Panels nutzen `colorMode: value`.
8. **Farbe ist nie der einzige Träger.** Jeder farbige Zustand muss zusätzlich
   als **Text** lesbar sein (Value-Mapping), als **Position** (Alarmzeile oben)
   oder als **Form**. Prüfung: Das Dashboard einmal in Graustufen ansehen. Was
   dann nicht mehr lesbar ist, verstößt gegen diese Regel.
9. **Keine Farbe für statische Elemente** — Überschriften, Rahmen, Achsen,
   Legenden bleiben neutral.
10. **Die Hintergrundhelligkeit folgt dem Betrachter, nicht der Norm.** Die
    ASM-Empfehlung heller Hintergründe hängt an heller Leitwartenbeleuchtung,
    die es hier nicht gibt (4.6). Maßgeblich ist, dass die *relative*
    Salienzabstufung in hell wie dunkel trägt.

### 6.3 Keine Zahl ohne Bezugsgröße

> **Eine Zahl auf Ebene 1 ohne Sollbereich ist keine Information, sondern eine
> Aufforderung, sich zu erinnern.** Der Leser hier hat nichts, woran er sich
> erinnern könnte.

Jedes Level-1-Panel, das eine Zahl zeigt, muss mindestens eines mitliefern:

- eine **Einheit und einen Sollbereich** im Panel-Text („31 / 200
  Verbindungen"), oder
- eine **Analoganzeige mit eingezeichneten Grenzen** — EEMUA 201 zeigt das als
  Musterlösung: Ist-Wert als Zeiger, dazu **Zielbereich, Alarmschwelle und
  Abschaltschwelle** in derselben Skala. Die Panels 7, 8, 10 und 11 machen das
  bereits, oder
- einen **eingebetteten Kurzverlauf**, gegen den sich der aktuelle Wert lesen
  lässt (≤ 4 Spuren).

Negativbeispiele aus dem Bestand: Panel 1 zeigt `3` (Soll: 3 — steht nirgends).
Panel 3 zeigt `31` (Soll: unbekannt, und die Farbskala behauptet, mehr sei
besser). Panel 52 zeigt eine Uptime in Sekunden und eine Insert-Rate ohne jeden
Vergleichswert. Panel 115 zeigt Ceph-I/O in Bytes/s — ohne Bezug eine Zahl, die
man nicht bewerten kann.

Zusatzregel für Gauges: Die **Skalengrenzen** müssen der physikalischen Realität
entsprechen, nicht `0..1` aus Bequemlichkeit. Ein Gauge, dessen Nadel nie den
unteren oder oberen Anschlag erreicht, verschenkt Auflösung genau dort, wo sie
gebraucht wird.

### 6.4 Navigation

1. **Jedes Inhaltspanel auf Ebene 1 hat genau einen Drill-down-Link** auf sein
   Level-2-Dashboard. Ausnahmslos — auch die Alarmkachel.
2. **Der Zeitbereich wird mitgenommen.** `keepTime: true` bei Dashboard-Links,
   `?${__url_time_range}` bei Panel-Links.
3. **Jedes Dashboard ab Ebene 2 hat einen Dashboard-Link „Übersicht"** zurück
   auf `home-overview`, an derselben Stelle, mit demselben Titel.
4. **Der Drill-down überspringt keine Ebene.** Ebene 1 verlinkt auf Ebene 2,
   Ebene 2 auf Ebene 3. Ein Sprung von 1 nach 3 überspringt den Kontext, in dem
   die Detailzahl zu lesen wäre.
5. **Linkziele werden geprüft, wenn ein Dashboard umgezogen oder ersetzt wird.**
   Der Bestand hat keine toten Links, aber drei Links auf ein *veraltetes* Ziel
   (`000000039` statt `postgres-prod-singlevm`) — das ist schlimmer als ein
   toter Link, weil es funktioniert und trotzdem falsch ist.
6. **Level 4 wird nie von Ebene 1 aus verlinkt.**

### 6.5 Der leere Zustand — die Regel aus Abschnitt 0

Dies ist die Übertragung von Regel 1 des Alarmdokuments auf die Anzeige.

1. **Jede Panel-Query wird vor dem Deploy gegen die laufende Datenquelle
   geprüft.** Leeres Ergebnis heißt: Panel ist falsch gebaut — nicht „gerade
   ist nichts los".
   ```bash
   # VictoriaMetrics
   ssh root@192.168.4.41 "curl -s 'http://127.0.0.1:8428/api/v1/query' \
     --data-urlencode 'query=<EXPR>'"

   # Loki (distroless, kein sh im Container — über den Grafana-Container)
   GC=$(ssh root@192.168.4.40 "docker ps -q -f name=monitoring_grafana")
   ssh root@192.168.4.40 "docker exec $GC wget -qO- \
     --post-data='query=<EXPR>' http://loki:3100/loki/api/v1/query"
   ```
2. **Kein Panel ohne `targets`.** Ein Platzhalter auf Ebene 1 lehrt den Leser,
   leere Kacheln zu überblättern — und macht ihn damit blind für die Kacheln,
   die *unbeabsichtigt* leer sind. Geplante Erweiterungen gehören in ein Issue,
   nicht auf den Leitstand.
3. **`noValue` ist Pflicht und muss „kaputt" heißen, nicht „gut".** Der
   Standardtext lautet `KEINE DATEN`, die Farbe ist die Warnfarbe. Panel 5
   („PBS") macht das bereits richtig (`noValue: OFFLINE`).
4. **Jede Zählung schlechter Dinge braucht ihren Nenner.** „3 Ziele down" ist
   nur zusammen mit „von 38" lesbar. „0 Fehler" nur zusammen mit „aus 18.259
   beobachteten Zeilen". Ohne Nenner ist eine Null zweideutig — und die
   freundlichere der beiden Deutungen ist immer die falsche.
5. **Ebene 1 zeigt das Alter ihrer eigenen Daten** (Abschnitt 7a).
6. **Titel dürfen keine Vollständigkeit behaupten, die die Datenlage nicht
   hergibt.** „Error Rate (alle Hosts)" bei drei von 35 Hosts ist eine
   Falschaussage im Panel-Titel. Entweder die Abdeckung herstellen oder den
   Titel korrigieren („Error Rate — Syslog-Clients (3)").

### 6.6 Die Alarmkachel — Kopplung an das Alarmdesign

Der Leitstand muss zeigen, was ansteht. Heute zeigt er es nicht (Abschnitt 0).

**Was auf Ebene 1 gehört:**

- **Alle Alarme mit `severity: critical` oder `warning` im Zustand `firing`.**
  Nicht `pending` — die `for`-Zeit ist genau die Aussage „das ist noch keine
  Störung"; sie auf dem Übersichtsbild vorwegzunehmen, hebt sie auf.
- **Nicht `info`.** Regel 4 des Alarmdokuments verweist selbstheilende Zustände
  ausdrücklich ins Dashboard — aber in die *Fachpanels*, nicht in die
  Alarmliste. Eine Alarmliste, in der `info` steht, ist die
  Prioritätsinflation aus Abschnitt 2.4 des Alarmdokuments, eine Ebene weiter.
- **Sortierung nach Schwere, dann nach Standzeit** — der älteste offene
  `critical` oben.
- **Jede Zeile mit Link** auf das Level-2-Dashboard ihres Teilsystems
  (`dashboardUID`-Annotation an der Alarmregel).
- **Jede Zeile redundant codiert**: Schwere steht als **Wort** (`KRITISCH` /
  `WARNUNG`) am Zeilenanfang, nicht nur als Farbpunkt (4.3).

**Erledigte Alarme:**

> **Standardmäßig ausgeblendet, aber mit einem Klick erreichbar.**

Konkret: Die Alarmkachel auf Ebene 1 filtert auf `state: firing` und zeigt
ausschließlich Anstehendes. Die Historie — was in den letzten 24 h auftrat und
wieder verschwand — liegt auf **Ebene 2** als eigenes Alarmhistorie-Dashboard,
verlinkt aus der Kachelüberschrift.

Die Begründung steht bereits im Alarmdokument (4.4): Ein Alarm, der ohne
Eingriff verschwindet, hat niemandem etwas mitgeteilt — er ist **Statistik**.
Statistik gehört auf Ebene 2, wo man sie liest, wenn man sie sucht. Auf Ebene 1
verdrängt sie das, was gerade ansteht. Gemessen: p50 der Episodendauer liegt
bei 11 min, rund die Hälfte aller Alarme heilt von selbst. Eine Ebene-1-Liste
mit erledigten Alarmen wäre zur Hälfte aus Vergangenheit gebaut.

**Damit die Alarmliste nicht selbst zum Rauschen wird:**

1. **Die Kachel ist für den Zielwert dimensioniert, nicht für den Ist-Zustand.**
   Zielwert aus Abschnitt 5 des Alarmdokuments: **≤ 2 stehende Alarme, 0
   chronische**. Die Kachel zeigt maximal **5 Zeilen**. Was darüber hinausgeht,
   erscheint als eine einzige Zeile „**+ N weitere**" in der Warnfarbe.
2. **Diese Überlaufzeile ist selbst die Meldung.** Sie sagt nicht „es sind viele
   Alarme", sondern „das Alarmsystem ist über seinem Zielwert". Ein Leitstand,
   dessen Alarmliste gescrollt werden muss, zeigt nicht mehr die Anlage, sondern
   ein defektes Regelwerk — und genau das soll er dann sagen. Am 2026-08-24
   hätte diese Zeile `+ 21 weitere` gelautet.
3. **Die Kachel wächst nicht.** Feste Höhe. Eine Liste, die sich ausdehnt,
   verschiebt den Rest des Lagebilds genau dann, wenn man ihn braucht.
4. **Eine zweite, kleine Kachel zeigt die Alarmgüte selbst:**
   `grafana_alerting_alerts{state="alerting"}` gegen den Zielwert **≤ 2**.
   Direkte Kopplung an Abschnitt 7.2 des Alarmdokuments. **Voraussetzung:** Der
   Grafana-Scrape-Job aus Abschnitt 7.1 dort fehlt weiterhin
   (`count({__name__=~"grafana_.*"})` → leer). Ohne ihn ist diese Kachel nicht
   baubar.
5. **Kein Alarmzustand wird auf Ebene 1 doppelt dargestellt.** Wenn die
   Alarmkachel „PostgreSQL down" zeigt, muss die PostgreSQL-Kachel nicht
   zusätzlich rot leuchten. Doppelte Darstellung desselben Ereignisses ist auf
   der Anzeige dasselbe wie das Alarm-zu-Ursache-Verhältnis von 20:1 im
   Alarmdokument: ein Ereignis, das wie mehrere aussieht.
6. **Schwellwerte in Panels und Alarmregeln stammen aus derselben Quelle.** Ein
   Panel, das bei 80 % orange wird, während die Alarmregel bei 85 % feuert,
   erzeugt eine Zone, in der die Anzeige warnt und das Alarmsystem schweigt.
   Der Leser lernt daraus, der Anzeige nicht zu glauben.

### 6.7 Handwerk

1. **Eine Sprache pro Dashboard.** Der Bestand mischt („PG Verbindungen" neben
   „PG Connections", „Datenbank" neben „Top Consumers"). Festlegung: **Deutsch**,
   wie in `ups-power`, `pve-hosts` und der Synology-Familie bereits umgesetzt.
   Metriknamen und Kommandos bleiben englisch.
2. **Jedes Dashboard wird aus Git provisioniert.** 13 von 20 sind es heute
   nicht — darunter `home-overview`. Ein Leitstand, der nur in einer
   SQLite-Datei auf einem RBD-Volume existiert, ist ein Single Point of Failure
   mit Datenverlustrisiko und ohne Änderungshistorie.
3. **Keine zwei Panels mit derselben Query auf demselben Dashboard.** Duplikate
   driften auseinander — Panel 3 und 53 sind der Beweis: gleiche Zahl,
   gegensätzliche Farbskala.
4. **Panels, deren Metrik keine Substanz mehr hat, werden entfernt, nicht
   stehen gelassen.** Panel 51 („Replication Lag" auf einer Einzel-VM ohne
   Replikation) zeigt eine grüne Null, die als „Replikation gesund" gelesen
   wird. Das ist die Anzeigen-Entsprechung zu den Alarmregeln auf nicht
   existierende Metriken (Alarmdokument 6.4).
5. **Bei jeder Architekturänderung werden die Dashboards mitgezogen.** Panel 51
   und der Drill-down auf `000000039` sind beides Reste der Patroni-Ära, die
   die Migration überlebt haben. Sie stehen exakt für den Fehler, den die
   Projektregel „Shared Infra: ALLE Consumer updaten" adressiert.

---

## 7. Der Leitstand als eigener Ausfallpunkt

Abschnitt 4.7 des Alarmdokuments nennt „den Zustellweg selbst" als das, was hier
wichtiger ist als in der Leitwarte. Für die Anzeige gilt dasselbe, gemessen:

| | |
|---|---|
| Grafana | `monitoring_grafana` **1/1**, `max 1 per node`, Image `grafana/grafana:12.4.8` |
| Läuft auf | `docker-infra-1` — festgenagelt über das Label `grafana-rbd=active` |
| Zustand | `grafana.db` auf `/mnt/rbd/grafana/` (RBD, exclusive-lock, Watchdog-Failover) |
| VictoriaMetrics | **1/1** |
| vmagent | **1/1** |
| Loki | **1/1**, auf `docker-infra-3` |
| Namensauflösung | Technitium-Cluster; die Grafana-URL, die Datenquellen und der Zugriffsweg hängen daran |

**Jedes Glied dieser Kette ist einfach ausgelegt.** Fällt `docker-infra-1` aus,
verschiebt der RBD-Watchdog das Volume und Grafana startet neu — in dieser Zeit
gibt es keinen Leitstand. Fällt DNS aus, ist er nicht erreichbar. Fällt
VictoriaMetrics aus, zeigt er leere Panels — und leere Panels sehen aus wie
Ruhe (Abschnitt 0).

Der entscheidende Punkt ist nicht die Verfügbarkeit. Es ist:

> **Ein Leitstand, der seinen eigenen Ausfall nicht anzeigen kann, ist
> gefährlicher als keiner** — denn er erzeugt die Überzeugung, nachgesehen zu
> haben.

Die Regel dazu hat vier Teile, weil es vier Ausfallarten gibt:

**(a) Der Leitstand ist erreichbar, aber seine Daten sind alt.**
→ Ebene 1 trägt eine Kachel **„Datenalter"**: die Zeit seit dem letzten
erfolgreichen Scrape, mit Sollbereich. Ist sie älter als zwei
Scrape-Intervalle, steht die Kachel in der Warnfarbe und **alle anderen Zahlen
auf dem Bild sind ungültig**. Diese Kachel ist die einzige, die man zuerst
liest — sie steht deshalb an Position 2, direkt neben den Alarmen.

**(b) Der Leitstand ist erreichbar, aber eine Datenquelle ist tot.**
→ Ebene 1 zeigt die Erreichbarkeit **jeder** genutzten Datenquelle als eigene
Zeile — VictoriaMetrics, Loki. Ein Panel, dessen Datenquelle nicht antwortet,
darf nicht als „Null" gerendert werden. Solange Grafana das nicht von sich aus
unterscheidet, ist die explizite Datenquellen-Zeile der Ersatz. **Der
Loki-Befund aus Abschnitt 0 wäre damit am ersten Tag aufgefallen.**

**(c) Der Leitstand ist ganz weg.**
→ Das kann er konstruktionsbedingt nicht selbst melden. Es braucht eine
**Totmannschaltung außerhalb der Anzeigekette** — genau wie beim Alarmsystem.
Praktikabel ist derselbe Ort: `~/Documents/projects/ansible/daily-maintenance.sh`
ruft das Level-1-Dashboard und `grafana_alerting_alerts` ab und meldet
**separat**, wenn keine Antwort kommt. Eine Ausfallmeldung, die über den
Leitstand liefe, wäre zirkulär.

**(d) Der Leitstand ist weg und kommt nicht wieder.**
→ Weil `home-overview` nur in der SQLite-Datei existiert. Reproduzierbarkeit
aus Git ist kein Ordnungsbedürfnis, sondern der Wiederherstellungsplan
(6.7.2).

---

## 8. Reihenfolge

Nach Wirkung pro Aufwand:

1. **Die drei Loki-Panels reparieren oder entfernen** (Abschnitt 0/3). Solange
   ein Drittel der Anzeigefläche stumm ist, ist jede weitere Regel Kosmetik.
2. **Alarmkachel auf Ebene 1** (6.6). Der Leitstand zeigt zum ersten Mal, was
   ansteht. Die vier stehenden Alarme wären seit heute Morgen sichtbar.
3. **Datenalter- und Datenquellen-Kachel** (7a/7b). Verhindert die Wiederholung
   von Befund 1 — und zwar dauerhaft, unabhängig von der Panel-Reparatur.
4. **Platzhalter 112 / 114 / 119 durch echte Kacheln ersetzen** (6.5.2) — die
   Daten und die Level-2-Dashboards existieren seit zwei Tagen.
5. **Duplikate und Altlasten entfernen**: 50 oder 4, 3 oder 53, Panel 51.
   Drill-down von 4/50/53 auf `postgres-prod-singlevm` umbiegen (6.4.5).
6. **`home-overview` auf 12 Kacheln und eine Bildschirmhöhe kürzen** (6.1),
   gegliedert nach der Abhängigkeitskette. Zeitreihen, Top-N und Logs wandern
   auf Ebene 2.
7. **Farbregel umsetzen** (6.2): Basis-Schwelle überall `text`,
   `colorMode: background` nur an der Alarmkachel, Gelb entfällt, Textworte
   statt Rot/Grün.
8. **Navigation vervollständigen** (6.4): Drill-down an allen Kacheln,
   `keepTime`, Rücklinks auf allen 19 Dashboards.
9. **`home-overview` und die 12 weiteren UI-only-Dashboards nach Git
   überführen** (6.7.2).
10. **Grafana-Scrape-Job** (Alarmdokument 7.1) — Voraussetzung für die
    Alarmgüte-Kachel (6.6.4).
11. **Runbook-Panel auf jedem Level-2-Dashboard** (4.1).

---

<!-- ============================================================ -->
<!-- ABSCHNITT 9 IST ZUR ÜBERNAHME NACH .claude/CLAUDE.md GEDACHT -->
<!-- ============================================================ -->

## 9. Bindende Regeln — Entwurf zur Übernahme nach `.claude/CLAUDE.md`

> **Dieser Abschnitt ist der einzige Teil des Dokuments, der als verbindliche
> Regel gedacht ist.** Die Übernahme nach `.claude/CLAUDE.md` erfolgt durch den
> Betreiber — dieses Dokument ändert `CLAUDE.md` nicht.

---

### Leitstanddesign (EEMUA 201 / ISA-101, übersetzt) — Stand 2026-08-25

**Vor jeder Änderung an einem Grafana-Dashboard:**

1. **Jede Panel-Query wird vor dem Deploy gegen die laufende Datenquelle
   geprüft. Ein leeres Ergebnis heißt: Panel ist falsch gebaut — nicht „gerade
   ist nichts los".** Panels ohne `targets` sind auf Ebene 1 verboten; `noValue`
   muss „kaputt" heißen, nie „gut"; jede Zählung schlechter Dinge nennt ihren
   Nenner.
   *(Verstoß hat die drei größten Panels des Leitstands — ein Drittel seiner
   Anzeigefläche — mindestens sieben Tage stumm laufen lassen, ohne dass es
   auffiel: Loki verwarf 97,7 % aller Zeilen als `too_far_in_future`, und nur
   3 von 35 Hosts lieferten überhaupt — bei `up = 1` und normal laufendem
   Empfangszähler.)*

2. **Gesättigte Farbe ausschließlich für Abweichung vom Sollzustand. Grün ist
   keine Statusfarbe.** Basis-Schwelle (`value: null`) überall `text`; Rot nur
   für `critical`, Orange für `warning`, `info` ohne Farbe; kein „grün = an,
   rot = aus"; `colorMode: background` nur an der Alarmkachel; höchstens drei
   Signalfarben plus neutral.
   *(Heute sind 15 von 23 Panels im Normalbetrieb farbig und 9 färben die ganze
   Kachel — im Störfall bleibt kein Kontrast übrig.)*

3. **Eine Farbe, eine Bedeutung — und Farbe nie als einziger Träger.** Jeder
   farbige Zustand muss zusätzlich als Text, Position oder Form lesbar sein.
   Prüfung: Dashboard in Graustufen ansehen; was dann fehlt, verstößt gegen die
   Regel.
   *(Grün heißt heute auf Panel 3 „viele Verbindungen" und auf Panel 53
   „wenige" — dieselbe Zahl 31, gegensätzliche Skalen. Rot-Grün-Sehschwäche
   betrifft rund 8 % der Männer europäischer Abstammung, Birch 2012.)*

4. **Keine Zahl auf Ebene 1 ohne Bezugsgröße** — Sollbereich im Text,
   eingezeichnete Grenze in der Skala oder eingebetteter Kurzverlauf mit
   höchstens 4 Spuren.
   *(„3" bei den PVE-Nodes ist ohne den Sollwert 3 bedeutungslos; der Leser hat
   keinen inneren Vergleichswert, weil er nur zweimal täglich hinsieht.)*

5. **Ebene 1 hat höchstens 12 Inhaltspanels, passt ohne Scrollen auf einen
   Bildschirm (≤ 24 Rastereinheiten) und ist nach der Abhängigkeitskette
   gegliedert** (Strom → Netz → Hypervisor → Storage → Datenbank → Anwendung),
   nicht nach Herstellern. Freistehende Zeitreihen, Top-N-Listen, Logzeilen und
   Rohmetriken gehören auf Ebene 2.
   *(Heute: 49 Rastereinheiten, 23 Inhaltspanels, 8 Panels unter der Falz.)*

6. **Jedes Level-1-Panel hat einen Drill-down auf sein Level-2-Dashboard, jedes
   Dashboard ab Ebene 2 einen Rücklink auf `home-overview`, und beide nehmen den
   Zeitbereich mit** (`keepTime` / `${__url_time_range}`). Keine Ebene wird
   übersprungen.
   *(Heute: 11 von 23 Panels verlinken, 0 von 19 Dashboards verlinken zurück,
   0 Links erhalten den Zeitbereich, 3 Links zeigen auf ein veraltetes Ziel.)*

7. **Ebene 1 trägt genau eine Alarmkachel: `firing`, ohne `info`, nach Schwere
   sortiert, Schwere als Wort, feste Höhe, maximal 5 Zeilen, darüber „+ N
   weitere".** Erledigte Alarme sind ausgeblendet und über einen Link auf
   Ebene 2 erreichbar. Panel- und Alarmschwellen stammen aus derselben Quelle.
   *(Heute zeigt kein einziges der 20 Dashboards Alarme an — die vier stehenden
   Alarme sind auf keinem Bild sichtbar.)*

8. **Der Leitstand muss seinen eigenen Ausfall anzeigen können.** Ebene 1 trägt
   das Alter der eigenen Daten und den Zustand jeder genutzten Datenquelle; die
   Meldung „Leitstand ganz weg" läuft über eine Totmannschaltung außerhalb der
   Anzeigekette; jedes Dashboard ist aus Git reproduzierbar.
   *(Grafana, VictoriaMetrics, vmagent und Loki laufen alle mit `replicas=1`;
   `home-overview` existiert nur in `grafana.db` auf einem RBD-Volume.)*

**Zielwerte (gemessen, nicht geraten):**

| Kennzahl | Ziel | Ist 2026-08-25 |
|---|---|---|
| Inhaltspanels auf Ebene 1 | ≤ 12 | 23 (+3 leer) |
| Höhe Ebene 1 | ≤ 24 Rastereinheiten | 49 |
| Panels, die im Normalbetrieb gesättigt farbig sind | 0 | 15 von 23 |
| Panels, deren Query nachweislich Daten liefert | 100 % | 20 von 23 |
| Zahlen ohne Bezugsgröße auf Ebene 1 | 0 | 12 |
| Level-1-Panels mit Drill-down | 100 % | 11 von 23 |
| Level-2-Dashboards mit Rücklink | 100 % | 0 von 19 |
| Alarmpanels auf Ebene 1 | 1 | 0 |
| Dashboards aus Git provisioniert | 100 % | 7 von 20 |

**Der Satz, der beide Dokumente verbindet:** Im Alarmsystem ist eine Query, die
im Gesundzustand nichts liefert, ein Dauer-Fehlalarm. Auf dem Leitstand ist sie
eine **Dauer-Entwarnung**. Der zweite Fehler ist der gefährlichere, weil er
nicht auffällt.

---

## 10. Ist-Verstöße des aktuellen `home-overview`

Vollständige Liste, jeder Punkt am 2026-08-25 nachgemessen.

| # | Regel | Panel | Befund |
|---|---|---|---|
| 1 | 9.1 leerer Zustand | **106, 107, 108** | Panel 107 liefert 2 Serien / 625 Zeilen pro Stunde von 35 erwarteten Hosts, Panel 106 **0 Serien**. Ursache ist die Ingestion (97,7 % als `too_far_in_future` verworfen), nicht die Query. Rastereinheit 33–49 (16 von 49, ein Drittel der Fläche) zeigt praktisch nichts und sieht dabei ruhig aus. |
| 2 | 9.1 kein Panel ohne `targets` | **112, 114, 119** | Leere Hüllen mit `noValue: "Coming Soon"` / `"Soon"` — obwohl `snmp-synology` (45 Metriken, 138 `hrStorage*`-Serien) und `unpoller` (2.950 Serien) seit ~2 Tagen liefern und `synology-nas` / `unifi-poe` existieren. |
| 3 | 9.1 Nenner bei Zählungen | **54, 106** | „Targets Down" nennt die Zahl der ausgefallenen Ziele ohne die Gesamtzahl (38). „Error Rate" nennt Fehler ohne beobachtete Zeilen. |
| 4 | 9.7 Alarmkachel | **ganzes Dashboard** | Kein `alertlist`-, `annolist`- oder `alertGroups`-Panel. Die 4 stehenden Alarme (`Synology SSD`, `Paperless`, `HTTPS probe`, `PVE memory`) sind auf keinem Bild sichtbar. |
| 5 | 9.5 eine Bildschirmhöhe | **ganzes Dashboard** | 49 Rastereinheiten (~1.860 px), 23 Inhaltspanels, 7 Rows. 8 Panels unter der Falz, darunter der komplette Loki-Block. |
| 6 | 9.5 Gliederung nach Abhängigkeitskette | **Rows 100/118/101/116/117/103/105** | Gegliedert nach Technologie („Logs Overview", „Top Consumers") und Hersteller, nicht nach Strom → Netz → Hypervisor → Storage → DB → Anwendung. Strom und Netz kommen überhaupt nicht vor. |
| 7 | 9.2 Grün ist keine Statusfarbe | **2, 4, 5, 7, 8, 10, 11, 30, 31, 32, 51, 52, 53, 54, 115** | 15 von 23 Panels haben `green` als Basis-Schwelle → im Normalbetrieb dauerhaft gesättigt farbig. |
| 8 | 9.2 `colorMode: background` nur an der Alarmkachel | **1, 3, 4, 5, 50, 51, 54, 112, 119** | 9 Panels färben die gesamte Kachelfläche. |
| 9 | 9.2 höchstens 3 Signalfarben | **ganzes Dashboard** | 5 gleichzeitig: `green`, `yellow`, `orange`, `red`, `#444`. |
| 10 | 9.2 kein „grün = an, rot = aus" | **4, 50, 120** | Betriebszustand über das Ampelpaar codiert. Immerhin mit Textwort (`UP`/`DOWN`/`Running`) — die Farbwahl bleibt trotzdem falsch, weil sie Rot für Nicht-Alarme verbraucht. |
| 11 | 9.3 eine Farbe, eine Bedeutung | **3 ↔ 53** | Beide zeigten **31**. Panel 3: `red@null, yellow@3, green@5` (mehr = grüner). Panel 53: `green@null, yellow@150, red@190` (mehr = roter). Bei 200 Verbindungen wäre 3 grün und 53 rot. Non-discriminant coding im Reinformat. |
| 12 | 9.3 Farbe nicht als einziger Träger | **1, 3, 12**, Gauges **7, 8, 10, 11** | Information steckt allein in der Farbe. `3` bei den PVE-Nodes ist ohne die grüne Fläche bedeutungslos. |
| 13 | 9.4 keine Zahl ohne Bezugsgröße | **1, 3, 5, 12, 51, 52, 53, 54, 115** und die Legenden von **30, 31, 32** | Kein Sollwert, kein Bereich, kein Verlauf. |
| 14 | 9.4 höchstens 4 Spuren je Kurve | **106, 107** | `sum by (host)` ohne `topk` — unbegrenzte Serienzahl, gestapelt. |
| 15 | 9.4 Schwellen bilden den Sollzustand ab | **12** | Grün erst ab 24 h Uptime. pve02 lief 3,9 h → Panel steht **gelb** nach einem normalen Neustart. |
| 16 | 6.7.3 keine doppelten Queries | **4 ↔ 50** | Bitidentisch `pg_up{instance="postgres-prod"}`, Titel „PostgreSQL" und „PostgreSQL DB", zwei Abschnitte. |
| 17 | 6.7.4 keine Panels ohne Substanz | **51** | „Replication Lag" = 0, grün — auf einer Einzel-VM ohne Replikation. `pg_stat_replication_*` existiert nicht. Liest sich als „Replikation gesund". |
| 18 | 9.6 Drill-down überall | **3, 12, 30, 31, 32, 51, 52, 54, 106, 107, 108, 112, 114, 115, 119** | 15 von 23 Inhaltspanels ohne Link. |
| 19 | 9.6 Zeitbereich mitnehmen | **1, 2, 4, 5, 7, 8, 10, 11, 50, 53** | Alle 10 Panel-Links sind `type: absolute` ohne `keepTime` / `${__url_time_range}`. Ziele stehen auf `now-6h`, `now-24h`, `now-7d`. |
| 20 | 9.6 Drill-down auf das aktuelle Fachbild | **4, 50, 53** | Zeigen auf `/d/000000039/` („PostgreSQL Database", 35 Panels, UI-only, Patroni-Ära) statt auf `postgres-prod-singlevm` (aus Git, aktuell). |
| 21 | 9.6 Rücklink auf Ebene 1 | **alle 19 anderen Dashboards** | Kein einziger Rücklink auf `home-overview`. |
| 22 | 6.5.6 Titel behaupten keine Vollständigkeit | **106, 107, 108** | „(alle Hosts)" bei 3 Loki-`host`-Werten gegen 35 Scrape-Instanzen. |
| 23 | 6.7.1 eine Sprache | **ganzes Dashboard** | „PG Verbindungen" neben „PG Connections", „Datenbank" neben „Top Consumers", „Storage & Bandbreite" neben „Service Health". |
| 24 | 9.8 aus Git reproduzierbar | **`home-overview`** | Nur in `grafana.db` auf `/mnt/rbd/grafana/`. Kein Eintrag in `dashboard_provisioning`. Gilt für 13 von 20 Dashboards. |
| 25 | 9.8 eigenen Ausfall anzeigen | **ganzes Dashboard** | Weder Datenalter noch Datenquellen-Zustand. Grafana, VictoriaMetrics, vmagent, Loki laufen alle `replicas=1`. |
| 26 | 6.1 Ebene-1-Inhalt | **30, 31, 32, 106, 107, 108, 115** | Top-N-Listen, freistehende Zeitreihen und Logzeilen beantworten nicht „ist die Anlage in Ordnung" — Ebene-2-Inhalt. |
| 27 | 6.6.4 Alarmgüte messbar | — | `count({__name__=~"grafana_.*"})` → leer. Der Scrape-Job aus Alarmdokument 7.1 fehlt weiterhin; die Kennzahl „stehende Alarme" ist nicht auf ein Dashboard zu bringen. |

**Was der Bestand richtig macht** — damit die Liste nicht nur anklagt:

- Panel **5** („PBS") setzt `noValue: OFFLINE` — die vorbildliche Behandlung des
  leeren Zustands.
- Panel **4, 50, 120** tragen Value-Mappings (`UP`/`DOWN`/`Running`), die
  Information also auch im Text. Ihnen fehlt nur die richtige Farbwahl.
- Panel **54** (`count(up == 0) or vector(0)`) ist die einzige Query auf dem
  Dashboard, die im Gesundzustand nachweislich einen Wert liefert — exakt das
  Muster aus Regel 1 des Alarmdokuments.
- Die **Gauges 7, 8, 10, 11** zeichnen ihre Grenzwerte in die Skala ein und
  erfüllen damit 6.3 bereits — das ist genau die Analogdarstellung, die EEMUA
  201 als Musterlösung zeigt.
- Die **Synology-Familie** (`synology-nas` → `-smart` / `-storage` / `-net`)
  ist die einzige Stelle im Bestand mit sauberer Ebenennavigation samt
  Zeitbereichs-Übernahme — sie ist das Vorbild für Regel 6.4.

---

## Anhang: Quellen und ihre Belastbarkeit

| Quelle | Verwendet für | Belastbarkeit |
|---|---|---|
| EEMUA Publication 201, 3. Aufl. 2019, *Control Rooms: A Guide to Their Specification, Design, Commissioning and Operation* | Geltungsbereich; „is not a standard" | offizieller Scope |
| Brazier, A. (2019), *Control room design — guidance document EEMUA 201 3rd edition*, IChemE Hazards 29, Symposium Series 166 | Bildschirmanzahl, Raumfläche, Beleuchtung, Übersichtsbild-Definition, Trendempfehlung, Analogdarstellung, Farbposition | Konferenzpapier des Autors der 3. Auflage — die ergiebigste frei zugängliche Quelle |
| ANSI/ISA-101.01-2015; **IEC 63303:2024** (internationale Übernahme); ISA-TR101.01-2022, ISA-TR101.02-2019 | Lebenszyklusmodell, Style Guide als Pflichtartefakt, max. 4 Ebenen | offizielle Scopes; **Volltext lag nicht vor** |
| Hollifield & Perez (PAS, 2012), *High Performance Graphics to Maximize Operator Effectiveness* v2.0 | Ebenenbeschreibungen L1–L4, „color never the sole differentiator", Verwerfung von grün/rot = an/aus, ≤ 3–4 Spuren je Trend | Anbieter-Whitepaper, von ISA gehostet; Autor im ISA-SP101-Komitee |
| ASM Consortium (Bullemer, Reising, Laberge), *Why Gray Backgrounds for DCS Operating Displays?* | Salienzabstufung, diskriminante Codierung, Kopplung Hintergrund ↔ Raumbeleuchtung, ausdrückliche Absage an reines Graustufendesign | frei zugängliches Konsortiums-Whitepaper |
| ISO 11064-4:2013, Abschn. 3.11 | Sehfeld ±35°, davon 1–2° scharf | offizielle Normvorschau |
| Birch, J. (2012), *Worldwide prevalence of red-green color deficiency*, JOSA A 29(3), 313–320 | 8 % Männer / 0,4 % Frauen europäischer Abstammung | peer-reviewed Primärquelle |
| Errington, Reising, Bullemer et al. (2005), *Proc. HFES* 49(23), 2036–2040 | Wirksamkeitszahlen des ASM-Interfaces (48 % / 96 % / 41 %), n = 21 | peer-reviewed, aber kleine Stichprobe und Autoren = Entwickler |
| EPRI 1017637 (2009), *Operator HMI Case Study* | **Gegenbeleg** — von PAS verfasst, n = 8, keine signifikanten Unterschiede in 3 von 4 Szenarien | „Technical Update", Interessenkonflikt |

**Nicht verwendet:** Blogs ohne Quellenangaben, die konkrete Zahlen für
Klicktiefe, Panelzahl oder Antwortzeit als Normwerte ausgeben. Solche Werte
stehen in diesem Dokument ausschließlich als **eigene Festlegung** und sind als
solche gekennzeichnet.
