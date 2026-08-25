# Alarmdesign nach EEMUA 191 — übersetzt auf dieses Homelab

**Stand:** 2026-08-24 · **Datengrundlage:** 130,5 Tage Grafana-Alarmhistorie
(2026-04-16 bis 2026-08-24), 28.520 Zustandswechsel · **Status:** Analyse, keine
Regeländerung durchgeführt

---

## 0. Kernbefund vorweg

Die Messung hat einen akuten Defekt aufgedeckt, der schwerer wiegt als jede
Kennzahl-Diskussion:

> **18 der 64 Alarmregeln feuern in diesem Moment dauerhaft und falsch** —
> 11 davon als `critical`. Sie stehen seit dem Deploy vom 2026-08-24 an,
> obwohl alle 38 Scrape-Ziele `up == 1` melden.

Ursache ist die Umstellung von `noDataState: OK` auf `Alerting` (Commit
`5921b8e`, swarm-stacks#126) in Kombination mit dem Aufbau der Queries. Eine
Query wie `up{job="node-exporter"} == 0` liefert im **Gesundzustand ein leeres
Ergebnis** — PromQL filtert die gesunden Serien weg. Grafana kann „gesund" und
„keine Daten" nicht unterscheiden und wertet beides als `NoData`. Mit
`noDataState: Alerting` wird daraus ein Dauer-Alarm.

Die Absicht von #126 war richtig und bleibt richtig: Ein toter Dienst darf nicht
schweigen. Die Umsetzung hat den Fehler aber nur umgedreht — statt „schweigt
immer" gilt jetzt „schreit immer". Beides trägt dieselbe Information: null.

Der Fix ist **nicht**, `noDataState` zurückzudrehen. Er besteht darin, die
Queries so zu schreiben, dass sie im Gesundzustand einen Wert liefern
(Abschnitt 6.1). Zwölf Regeln im selben File machen das bereits vor.

---

## 1. Methode

| Quelle | Was daraus stammt |
|---|---|
| `/mnt/rbd/grafana/grafana.db`, Tabelle `annotation` (schreibgeschützt geöffnet, `mode=ro`) | 28.520 Zustandswechsel, 2.651 Alarmauslösungen, Episodenrekonstruktion |
| `grafana.db`, Tabelle `alert_rule` | Regelinventar, `severity`, `for`, `noDataState` |
| Grafana `/metrics` (`grafana_alerting_*`) | Ist-Zahl der stehenden Alarme, tatsächlich versendete Benachrichtigungen |
| VictoriaMetrics `/api/v1/query` | Gegenprobe: Feuert ein Alarm zu Recht? Existiert die Metrik überhaupt? |
| `stacks/monitoring/alerting/*.yml` | Regeldefinitionen, Routing, Digest-Fenster |

**Grenzen der Daten — bewusst nicht extrapoliert:**

- `alert_instance` in der DB ist ein **veralteter Snapshot** (letzte Auswertung
  dort: 2026-07-07 bzw. 2026-08-09). Grafana hält den Alarmzustand im Speicher
  und schreibt ihn nur sporadisch. Für „was steht gerade an?" ist ausschließlich
  `grafana_alerting_alerts{state="alerting"}` aus `/metrics` belastbar.
- Grafana schreibt **keine Auflösungs-Annotation**, wenn eine Regel neu
  provisioniert wird oder der Dienst neu startet. Episoden, die so enden, wirken
  in der Historie „offen". Episodendauern über mehrere Tage sind deshalb eher
  Obergrenzen.
- Zwei Instanzen (`patroni-no-leader`, `etcd-no-leader`) stehen seit ~52 Tagen
  auf `Alerting`, **obwohl die zugehörigen Regeln gelöscht sind**. Das sind
  verwaiste DB-Zeilen, keine echten stehenden Alarme. Sie sind aus allen
  Kennzahlen unten herausgerechnet, aber selbst ein Befund (Abschnitt 7.4).
- Die Historie umfasst den Patroni-Betrieb, die Migration auf `postgres-prod`
  und zwei größere Störfälle. Sie ist **nicht** repräsentativ für einen
  eingeschwungenen Normalbetrieb — es gibt keinen Zeitraum, in dem die Anlage
  längere Zeit unverändert lief.

---

## 2. Ist-Aufnahme

### 2.1 Regelinventar

| Kennzahl | Wert |
|---|---|
| Regeln gesamt | 64 (15 Gruppen, 5 Ordner) |
| `severity: critical` | 32 (50,0 %) |
| `severity: warning` | 30 (46,9 %) |
| `severity: info` | 2 (3,1 %) |
| Weitere Labels | **keine** — außer `notify: email` an genau einer Regel |
| `noDataState: Alerting` / `OK` | 30 / 34 (`execErrState` in allen 64 Regeln identisch zu `noDataState`) |
| `unless`-Guards im gesamten File | **0** |
| Auswertungsintervall | 60 s (61 Regeln), 300 s (3 Regeln) |
| Regeln, die in 130 Tagen **nie** ausgelöst haben | **24 von 64 (38 %)** |

### 2.2 Alarmaufkommen

| EEMUA-Kennzahl | Messwert |
|---|---|
| Auslösungen gesamt (130,5 Tage) | 2.651 |
| **Ø Alarme/Tag** | **20,2** (Median 8, Maximum 117 am 2026-06-28) |
| Tage ganz ohne `critical` | 44 von 131 (34 %) |
| Ø Alarme/10 min (über alle Fenster) | 0,141 |
| 10-Min-Fenster mit ≥1 Alarm | 1.821 von 18.790 (9,7 %) |
| Verteilung in aktiven Fenstern | p50 = 1 · p90 = 2 · p95 = 4 · p99 = 7 · **max = 30** |
| Fenster mit ≥10 Alarmen (Flood) | 11 (0,6 % der aktiven Fenster) |

### 2.3 Episoden, stehende und flatternde Alarme

| Kennzahl | Messwert |
|---|---|
| Alarmepisoden gesamt | 2.101 |
| Episodendauer | p50 = 11 min · p90 = 9,4 h · p95 = 19,0 h |
| Episoden > 24 h (**standing** nach EEMUA) | 63 (3,0 %) |
| Episoden > 7 Tage | 7 (0,3 %) |
| Episoden < 2 min (**fleeting**) | 169 (8,0 %) |
| Episoden < 5 min | 528 (25,1 %) |
| **Chattering strikt nach EEMUA** (≥3 Auslösungen derselben Instanz in 1 min) | **0 Instanzen** |
| Höchste Auslösefrequenz einer Instanz in 1 Stunde | 5 (`Open Archiver unreachable`) |
| **Stehende Alarme JETZT** (`grafana_alerting_alerts{state="alerting"}`) | **26** — davon 13 `critical` |

Das strenge EEMUA-Chattering-Kriterium (≥3/min) wird **nirgends** erreicht. Die
Glättung durch `for`, `keep_firing_for` und `*_over_time`-Fenster funktioniert.
Das eigentliche Problem liegt eine Ebene darüber: bei den Regeln, die über Tage
hinweg im Stundentakt an- und abschwellen.

**Größte Einzelquellen (Auslösungen/Tag über 130 Tage):**

| Regel | /Tag | gesamt | severity |
|---|---|---|---|
| Open Archiver unreachable | 6,87 | 897 | critical |
| Paperless unreachable | 1,69 | 220 | critical |
| Ceph cluster warning | 1,33 | 174 | info |
| postgres-prod PostgreSQL down | 0,98 | 128 | critical |
| Swarm node OOM-killed a process | 0,86 | 112 | critical |
| Daily backup missed | 0,85 | 111 | warning |
| Backup older than 48h | 0,83 | 108 | warning |

`Open Archiver unreachable` allein stellt **34 % aller Alarmauslösungen**. Eine
einzige Regel dominiert das Aufkommen — das ist der wirksamste Hebel überhaupt.

### 2.4 Prioritätsverteilung — die 80/15/5-Regel

EEMUA 191 empfiehlt für Prozessleitwarten grob **~5 % hoch / ~15 % mittel /
~80 % niedrig**. Gemessen:

| | Regeln definiert | Auslösungen 130 d | Auslösungen 30 d | EEMUA-Ziel |
|---|---|---|---|---|
| critical | 32 (50 %) | 1.681 (72 %) | 312 (77 %) | ~5 % |
| warning | 30 (47 %) | 445 (19 %) | 54 (13 %) | ~15 % |
| info | 2 (3 %) | 207 (9 %) | 41 (10 %) | ~80 % |

Die Verteilung ist **exakt invertiert**. Drei von vier Alarmen, die den Menschen
sofort und ungefiltert erreichen, sind als `critical` eingestuft. Das ist der
klassische EEMUA-Befund „alarm priority inflation": Wenn fast alles Prio 1 ist,
ist nichts Prio 1.

Das ist hier allerdings **nicht ausschließlich** ein Bewertungsfehler. Ein
Homelab hat objektiv wenig, was „interessant, aber unwichtig" ist — es gibt
keine Prozessgrößen, die man beobachtet, ohne zu handeln. Realistisch ist
für dieses Setup eher **10 / 30 / 60** als **5 / 15 / 80** (Abschnitt 4.5).
Von 50 % `critical` ist das trotzdem weit entfernt.

### 2.5 Tageszeit — der schlafende Operator

| Zeitraum | Anteil Auslösungen | Anteil der Stunden |
|---|---|---|
| 23:00–07:00 (Nacht) | 34,0 % | 33 % |
| 09:00–18:00 (Kernzeit) | 33,9 % | 38 % |
| nur `critical`, nachts | 34,6 % | 33 % |

Die Verteilung ist **flach**. Alarme richten sich nicht nach dem Tagesrhythmus
des Betreibers — ein Drittel fällt zuverlässig in die Zeit, in der niemand
hinsieht. Es gibt keine „ruhige Phase", die man ausnutzen könnte, und keinen
Grund anzunehmen, nächtliche Alarme seien seltener oder harmloser. Der einzige
sichtbare Ausschlag ist 06:00 (207 Auslösungen) — das ist das Backup- und
Wartungsfenster, also selbst erzeugt.

### 2.6 Was den Menschen tatsächlich erreicht

Das Routing bündelt stark. Gemessen an der laufenden Grafana-Instanz
(14,5 h Laufzeit):

```
grafana_alerting_alerts_received_total{status="firing"}    18294
grafana_alerting_alerts_received_total{status="resolved"}      3
grafana_alerting_notifications_total{integration="telegram"}  15
grafana_alerting_notifications_total{integration="email"}      1
grafana_alerting_alertmanager_inhibition_rules                 0
```

- **~25 Telegram-Nachrichten/Tag** im aktuellen (defekten) Zustand.
- Die 18.294 „firing"-Ereignisse sind fast vollständig die **Neuzustellung der
  26 Dauer-Alarme im 60-Sekunden-Takt** an den internen Alertmanager. Die
  Deduplizierung fängt das ab — aber sie kaschiert damit auch, wie kaputt der
  Zustand ist.
- `inhibition_rules = 0` bestätigt: Grafana Unified Alerting kennt keine
  Inhibition. Bestätigt, nicht vermutet.

---

## 3. Der Störfall vom 2026-08-23 — peak alarm rate nach upset

Der einzige vollständig protokollierte Großstörfall im Messzeitraum. 60
Auslösungen aus 20 verschiedenen Regeln.

```
Zeit ab erstem Alarm      Auslösungen im 10-Min-Fenster
 +  0 min  (21:45)   17   #################   <- EEMUA-Grenze: 10
 + 10 min  (21:55)    6   ######
 + 20 min             0
 + 30 min             2   ##
 + 40..80 min         0
 + 90 min  (23:15)    7   #######
 +100 min  (23:25)   24   ########################   <- zweite Welle
 +110 min             0
```

| | |
|---|---|
| Alarme in den ersten 10 min | **17** (EEMUA-Ziel: ≤ 10) |
| Kumulativ nach 30 min | 23 |
| Kumulativ nach 4 h | 60 |
| Distinkte Regeln | 20 (13 critical, 6 warning, 1 info) |
| **Telegram-Nachrichten daraus** | **4 sofort** (je ein Ordner: Infrastructure, Databases, Smart Home, Applications) **+ 1 Digest** |

Zwei Dinge sind bemerkenswert:

**Die zweite Welle bei +100 min ist größer als die erste.** Sie besteht fast
vollständig aus Wiederholungen: dieselben 13 Regeln gingen `Alerting` → `Normal`
→ `Alerting`, sichtbar an den Zustandswechseln `Alerting (NoData)` →
`Alerting (Error)` → `Alerting (NoData)`. Das ist kein neues Ereignis, sondern
die Datasource, die kurz zurückkam und wieder wegbrach. Für den Menschen sieht
es aus wie ein zweiter Störfall.

**Die Bündelung funktioniert.** 60 Auslösungen wurden zu 4 Telegram-Nachrichten.
`group_by: [grafana_folder]` ist die wirksamste Einzelmaßnahme im ganzen Setup.
Der Preis: Die 4 Nachrichten enthalten zusammen 20 Zeilen, in denen die eine
Ursache (pve02 weg) nicht markiert ist. Bündelung reduziert die *Unterbrechungen*,
nicht die *Diagnosearbeit*.

---

## 4. Die EEMUA-Kennzahlen, übersetzt

Der Grundunterschied: EEMUA 191 beschreibt eine Leitwarte mit durchgehend
besetztem Operator, der in Minuten reagiert. Hier gibt es **eine Person, die
schläft, arbeitet und vielleicht zweimal täglich hinsieht**. Alle
Ratenkennzahlen der Norm messen *Operatorbelastung pro Zeit* — diese Größe ist
hier nur definiert, wenn jemand hinschaut.

Daraus folgt die zentrale Übersetzungsregel:

> **EEMUA misst Alarme pro Zeit. Hier muss man Alarme pro Hinsehen messen.**

### 4.1 Alarms per operator per 10 minutes

| | |
|---|---|
| **EEMUA-Original** | ≤ 1 pro 10 min im Normalbetrieb ist „acceptable", > 2 „over-demanding" |
| **Ist hier** | 0,141/10 min über alle Fenster; 1,46 in aktiven Fenstern; p99 = 7 |
| **Sinnvolle Entsprechung** | **Nicht übertragbar als Dauerkennzahl.** Ersatz: *Alarme pro Zustellfenster.* |

Begründung: Der Nenner „Operator-10-Minuten" existiert nicht. 91 % aller
10-Minuten-Fenster sind ohnehin leer — die Kennzahl misst über weite Strecken
nur, dass niemand da ist. Sie über den ganzen Tag zu mitteln, macht jedes
Problem unsichtbar.

Die Größe, die hier wirklich zählt, ist die **Zahl der Meldungen, die im
Digest-Fenster um 08:00 bzw. 18:00 ankommen**, plus die Zahl der
`critical`-Unterbrechungen dazwischen. Vorschlag:

- **Digest-Last:** ≤ 5 Meldungen je Fenster. Darüber wird der Digest überflogen
  statt gelesen.
- **Unterbrechungsrate:** ≤ 1 `critical`-Telegram/Tag im Mittel, ≤ 3 am
  schlechtesten Tag eines Monats. Ist heute: Ø 16,3 geschätzte
  critical-Nachrichten an Tagen mit critical, Median 8, Maximum 83.

### 4.2 Alarm flood

| | |
|---|---|
| **EEMUA-Original** | > 10 Alarme in 10 min = flood; Ende, wenn wieder < 10 pro 10 min über 5 min |
| **Ist hier** | 11 Flood-Fenster in 130 Tagen (0,6 % der aktiven Fenster); Störfall-Spitze 17 in 10 min, zweite Welle 24 |
| **Sinnvolle Entsprechung** | Schwelle **beibehalten** — aber auf *Telegram-Nachrichten* statt Auslösungen anwenden |

Ein flood ist definiert über die Frage „kann der Operator noch folgen?". Bei
einem Menschen, der aufs Handy sieht, ist die Einheit die **Nachricht**, nicht
die Auslösung. Gemessen daran hatte der Störfall vom 23.08. **4 Nachrichten in
10 Minuten** — das ist bearbeitbar. Die Bündelung hat den flood bereits
entschärft.

Zwei Kennzahlen sind deshalb nötig, und sie messen Verschiedenes:

| Kennzahl | Einheit | Misst | Zielwert |
|---|---|---|---|
| **Meldungsrate** | Auslösungen/10 min | Qualität des Regelwerks | Spitze ≤ 10 |
| **Unterbrechungsrate** | Telegram-Nachrichten/10 min | Belastung des Menschen | Spitze ≤ 3 |

Damit ist die Frage aus dem Auftrag beantwortet — *zählt eine gebündelte
Nachricht mit neun Meldungen als eine oder als neun?*: **Als neun für die
Regelwerksgüte, als eine für die Operatorbelastung.** Beide Zahlen getrennt
führen, denn Bündelung verbessert nur die zweite. Wer nur die
Unterbrechungsrate misst, hält ein kaputtes Regelwerk für gesund, sobald er es
gut genug bündelt — genau das passiert hier gerade mit den 26 Dauer-Alarmen,
die zu 15 Telegram-Nachrichten zusammenschrumpfen.

### 4.3 Standing alarms

| | |
|---|---|
| **EEMUA-Original** | Alarm > 24 h aktiv; Ziel: „the alarm list should be empty", < 10 stehende Alarme |
| **Ist hier** | **26 stehende Alarme**, davon 25 länger als 8 h; historisch 63 Episoden > 24 h (3,0 %) |
| **Sinnvolle Entsprechung** | **Schwelle deutlich senken: 8 Stunden statt 24.** |

Die 24-Stunden-Grenze der Norm stammt aus dem Schichtbetrieb: Ein Alarm, der
eine volle Schichtübergabe übersteht, ist per Definition nicht bearbeitet
worden. Hier ist die Übergabe der Blick aufs Handy — zweimal täglich, im
Abstand von 10 bzw. 14 Stunden. **Ein Alarm, der ein Digest-Fenster überlebt,
hat dieselbe diagnostische Bedeutung wie ein Alarm über Schichtwechsel in der
Leitwarte: Er wurde gesehen und nicht behoben.**

Vorschlag: `standing` ab **8 h** (überlebt ein Zustellfenster), `chronic` ab
**72 h**. Ein chronischer Alarm ist keine Störung mehr, sondern ein
Konfigurationsfehler oder eine akzeptierte Abweichung — beides gehört aus dem
Alarmkanal heraus und in ein Ticket oder eine Ausnahmeliste.

Gegen die Norm gesprochen: EEMUAs „the alarm list should be empty" ist hier
**strenger anwendbar als in der Prozessindustrie**, nicht laxer. Eine Leitwarte
kann sich einen dauerhaft stehenden Alarm leisten, weil ein Mensch danebensitzt,
der weiß, was er bedeutet. Hier gibt es niemanden, der das Wissen bereithält —
ein stehender Alarm wird nach zwei Tagen zum Hintergrundrauschen und maskiert
jeden neuen Alarm derselben Regel vollständig, weil `repeat_interval: 4h` nur
den *bestehenden* Zustand wiederholt.

### 4.4 Chattering / fleeting alarms

| | |
|---|---|
| **EEMUA-Original** | chattering: ≥ 3 Auslösungen derselben Instanz in 1 min; fleeting: Alarm kommt und geht, bevor reagiert werden kann |
| **Ist hier** | chattering strikt: **0 Instanzen**. fleeting < 2 min: 169 Episoden (8,0 %); < 5 min: 528 (25,1 %) |
| **Sinnvolle Entsprechung** | Chattering-Fenster von **1 Minute auf 1 Tag** dehnen; „fleeting" neu definieren |

Das 1-Minuten-Kriterium ist hier **wirkungslos** und sollte nicht verfolgt
werden: Bei 60 s Auswertungsintervall und `for`-Zeiten von 2–30 Minuten *kann*
eine Regel gar nicht dreimal pro Minute auslösen. Die Norm setzt Sekundentakt
und Prozesssignale voraus.

Die homelab-taugliche Entsprechung: **≥ 3 Auslösungen derselben Instanz an einem
Tag = Chatterer.** Danach sind `Open Archiver unreachable` (6,87/Tag),
`Paperless unreachable` (1,69/Tag) und `Ceph cluster warning` (1,33/Tag) klare
Fälle.

„Fleeting" hat hier eine andere Bedeutung als in der Leitwarte. Dort heißt es
„der Operator konnte nicht reagieren". Hier reagiert ohnehin niemand in
Minuten — **jeder** Alarm unter ~8 Stunden ist im Wortsinn fleeting. Die
nützliche Frage ist nicht „war er kurz?", sondern: **„War er kurz *und* ist er
von selbst weggegangen?"** Ein Alarm, der ohne Eingriff verschwindet, hat
niemandem etwas mitgeteilt. Mit p50 = 11 min Episodendauer gilt das für die
Hälfte aller Alarme hier.

Das ist der wichtigste Unterschied zur Norm überhaupt: **Selbstheilende Zustände
sind in einem unbeaufsichtigten System keine Alarme, sondern Statistik.** Sie
gehören ins Dashboard, nicht nach Telegram.

### 4.5 Prioritätsverteilung

| | |
|---|---|
| **EEMUA-Original** | ~5 % hoch / ~15 % mittel / ~80 % niedrig |
| **Ist hier** | Regeln: 50 / 47 / 3 · Auslösungen: 72 / 19 / 9 |
| **Sinnvolle Entsprechung** | **10 / 30 / 60**, gemessen an **Auslösungen**, nicht an Regeln |

Die 80/15/5-Regel setzt voraus, dass es viele Zustände gibt, die man anzeigt,
ohne zu handeln. Eine Raffinerie hat Hunderte davon. Ein Homelab hat kaum
welche — deshalb ist die Ziel-Verteilung hier flacher.

Entscheidend ist aber die **Bezugsgröße**: EEMUA misst die Verteilung der
*ausgelösten* Alarme, nicht der konfigurierten Regeln. Eine seltene
critical-Regel schadet nicht; eine, die täglich siebenmal feuert, definiert den
Kanal. Hier stellen 72 % aller Auslösungen `critical` — und eine einzige Regel
(`Open Archiver unreachable`) macht 34 % des Gesamtaufkommens aus.

Das operative Kriterium für `critical` sollte nicht „ist wichtig" sein, sondern:

> **`critical` = Ich stehe dafür nachts um drei auf.**

Alles andere ist `warning` (Digest) oder `info` (nur Dashboard). Nach diesem
Maßstab sind mindestens 8 der 32 critical-Regeln falsch eingestuft
(Abschnitt 6.3).

### 4.6 Peak alarm rate nach einem Störfall

| | |
|---|---|
| **EEMUA-Original** | ≤ 10 Alarme in den ersten 10 min nach einem major upset |
| **Ist hier** | **17** (2026-08-23), zweite Welle **24** bei +100 min |
| **Sinnvolle Entsprechung** | Schwelle **beibehalten**, gemessen an Auslösungen; zusätzlich: keine zweite Welle |

Diese Kennzahl überträgt sich am besten von allen, weil sie nichts über die
Anwesenheit des Operators voraussetzt — sie misst, ob das Regelwerk ein
Ereignis als *ein* Ereignis darstellt oder als Dutzend.

Der Störfall vom 23.08. verletzt die Grenze um 70 %. Und die zweite Welle bei
+100 min ist der eigentliche Skandal: Sie enthält keine einzige neue
Information, nur Wiederholungen. EEMUA hat dafür keinen eigenen Begriff; die
passende Formulierung wäre **„flood echo"** — ein Nachbeben aus reinen
Zustandswechseln, das der Operator vom echten Ereignis nicht unterscheiden kann.

Zusatzkennzahl, die hier wichtiger ist als in der Norm:

> **Alarm-zu-Ursache-Verhältnis.** 20 Regeln für einen ausgefallenen Node = 20:1.
> Ziel: ≤ 5:1.

### 4.7 Was aus EEMUA 191 hier *nicht* gilt

Ehrlichkeitshalber, weil die Norm sonst zur Checkliste verkommt:

| EEMUA-Konzept | Warum hier nicht anwendbar |
|---|---|
| **Alarm response time** (Ziel: Minuten) | Es gibt keine garantierte Reaktionszeit. Sinnvoll ist nur „Zeit bis zum nächsten Zustellfenster" — 0 bis 14 Stunden. |
| **Operator loading / Belastungsgrad** | Setzt einen anwesenden Operator voraus. Nicht messbar. |
| **Alarm shelving** mit Rückkehrpflicht | Grafana hat kein Shelving. Die Digest-Fenster sind ein grober Ersatz. Nachrüsten lohnt nicht. |
| **Chattering ≥3/min** | Physikalisch unerreichbar bei 60 s Auswertung (Abschnitt 4.4). |
| **Dynamische Alarmunterdrückung nach Betriebszustand** | Es gibt keine definierten Anlagenzustände („Anfahren", „Volllast"). Näherungsweise: Wartungsfenster, Backup-Fenster. |
| **80/15/5** unverändert | Zu wenige „nur beobachten"-Zustände (Abschnitt 4.5). |

Und umgekehrt — was hier **wichtiger** ist als in der Leitwarte:

1. **Stehende Alarme.** Kein Mensch daneben, der ihre Bedeutung im Kopf hat.
2. **Selbstheilende Alarme.** In der Leitwarte reagiert jemand, hier nicht —
   ein Alarm ohne Eingriff war überflüssig.
3. **Der Zustellweg selbst.** EEMUA setzt voraus, dass die Anzeige funktioniert.
   Hier hängt sie an DNS, Netz und einem einzelnen Grafana-Container
   (Abschnitt 7.2).

---

## 5. Zielwerte für dieses Homelab

Zusammenfassung der Übersetzung — die Werte, gegen die künftig gemessen wird.

| Kennzahl | EEMUA | **Ziel hier** | **Ist (2026-08-24)** |
|---|---|---|---|
| Meldungen/Tag | — | **≤ 5** | 20,2 (Median 8) |
| Meldungen je Digest-Fenster | — | **≤ 5** | nicht separat gemessen |
| `critical`-Telegram/Tag | — | **≤ 1** (Ø), ≤ 3 (Spitze) | Ø 16,3 an Tagen mit critical |
| Spitze nach Störfall (10 min) | ≤ 10 | **≤ 10** Meldungen / **≤ 3** Nachrichten | 17 / 4 |
| Alarm-zu-Ursache-Verhältnis | — | **≤ 5:1** | 20:1 |
| Stehende Alarme (> 8 h) | < 10 (>24 h) | **≤ 2** | **26** |
| Chronische Alarme (> 72 h) | — | **0** | mind. 3 |
| Chatterer (≥ 3 Auslösungen/Tag) | — | **0** | 3 Regeln |
| Selbstheilende Episoden (< 8 h, ohne Eingriff) | — | **< 20 %** | ~50 % (p50 = 11 min) |
| Anteil `critical` an Auslösungen | ~5 % | **≤ 10 %** | 72 % |
| Regeln, die nie feuern | — | Jährlich prüfen | 24 von 64 (38 %) |

---

## 6. Vorschläge — konkret, nicht als Prinzip

> Nichts davon ist umgesetzt. Alle PromQL-Ausdrücke unten wurden gegen die
> laufende VictoriaMetrics geprüft und liefern im aktuellen Gesundzustand einen
> Wert (das ist genau der Punkt).

### 6.1 Vordringlich: die 18 dauerhaft falsch feuernden Regeln

**Das Muster.** Eine Regel darf im Gesundzustand nicht „nichts" liefern, sonst
ist sie von einem Ausfall ununterscheidbar. Die 12 korrekt gebauten Regeln im
File machen es vor: `min_over_time(up{...}[5m])` liefert `1`, wenn alles läuft,
`0` beim Ausfall und **NoData nur, wenn die Serie wirklich verschwunden ist**.
Der Vergleich wandert aus PromQL in die Grafana-Threshold-Bedingung.

```promql
# FALSCH — liefert im Gesundzustand nichts, mit noDataState:Alerting = Dauer-Alarm
up{job="node-exporter"} == 0

# RICHTIG — liefert immer einen Wert; Grafana-Bedingung: IS BELOW 1
min_over_time(up{job="node-exporter", instance!="postgres-prod"}[3m])
```

Betroffene Regeln und geprüfte Ersatzausdrücke:

| Regel | sev | Neuer Ausdruck (Grafana-Bedingung) |
|---|---|---|
| Swarm node down | crit | `min_over_time(up{job="node-exporter",instance!="postgres-prod"}[3m])` → `< 1` |
| PVE host unreachable | crit | `min_over_time(up{job="pve-node-exporter"}[3m])` → `< 1` |
| postgres-prod PostgreSQL down | crit | `min_over_time(pg_up{instance="postgres-prod"}[3m]) * min_over_time(up{job="postgres-exporter"}[3m])` → `< 1` |
| postgres-prod VM unreachable | crit | `min_over_time(up{job="node-exporter",instance="postgres-prod"}[3m])` → `< 1` |
| Home Assistant unreachable | crit | `min_over_time(up{job="homeassistant"}[3m])` → `< 1` |
| Zigbee2MQTT bridge offline | crit | `min_over_time(homeassistant_binary_sensor_state{entity="binary_sensor.zigbee2mqtt_bridge_connection_state"}[5m])` → `< 1` |
| Synology SNMP nicht erreichbar | crit | `min_over_time(up{job="snmp-synology"}[5m])` → `< 1` |
| Ceph OSD down | crit | `count(ceph_osd_up == 0) or vector(0)` → `> 0` |
| Ceph cluster unhealthy | crit | `max(ceph_health_status)` → `>= 2` |
| ALLE DNS-Resolver down | crit | `count(max_over_time(probe_success{job="blackbox-dns"}[3m]) == 1) or vector(0)` → `< 1` |
| DNS-Resolver unreachable | warn | `min_over_time(probe_success{job="blackbox-dns"}[3m])` → `< 1` |
| PBS exporter unreachable | warn | `min_over_time(up{job="pbs-exporter"}[10m])` → `< 1` |
| Monitoring scrape target down | warn | `min_over_time(up{job!~"ceph\|homeassistant\|node-exporter\|pve-node-exporter\|postgres-exporter\|frigate"}[5m])` → `< 1` |
| Frigate camera not detecting | warn | `min_over_time(frigate_camera_fps{job="frigate"}[10m])` → `<= 0` |
| HTTPS probe failing | warn | `min_over_time(probe_success{job="blackbox-https"}[15m])` → `< 1` |
| Backup older than 48h | warn | Existenz-Guard `and on(vm_id)` beibehalten, aber `noDataState: OK` setzen (siehe unten) |
| Daily backup missed | warn | dito |
| postgres-prod postmaster restart loop | crit | **Metrik existiert nicht — Regel streichen oder neu bauen**, siehe 6.4 |

`or vector(0)` ist das Mittel der Wahl, wenn eine Aggregation (`count`, `sum`)
im Gesundzustand leer bleibt: Es erzwingt einen Wert, ohne die Semantik zu
verändern. Für `min_over_time` ist es nicht nötig — solange die Serie existiert,
liefert sie einen Wert.

**Die Regel, die daraus folgt:**

> `noDataState: Alerting` ist nur zulässig, wenn die Query im Gesundzustand
> nachweislich einen Wert liefert. Vor jedem Deploy einer solchen Regel gegen
> die laufende VictoriaMetrics prüfen — ein leeres Ergebnis heißt: Regel ist
> falsch gebaut, nicht „gerade nichts kaputt".

### 6.2 Den Node-Ausfall-Flood bändigen

Zwei Wege, beide mit ihren Risiken bewertet:

**Weg A — Query-Guards (`unless on(...)`).** Die Warn-Regel wird unterdrückt,
solange die Crit-Regel greift:

```promql
# swarm-disk-warning, entschärft gegen swarm-disk-critical
  (100 - (node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"}
        / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"} * 100) > 80)
unless
  (100 - (node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"}
        / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"} * 100) > 90)
```

**Das Risiko ist real und in diesem Setup gravierend:** Ein `unless`-Guard macht
die Query zu einer filternden Query — sie liefert im Normalfall **nichts**. Das
ist exakt der Defekt aus Abschnitt 0. Eine Regel mit `unless`-Guard **muss**
daher `noDataState: OK` behalten, und damit verliert sie die
Ausfallerkennung, die #126 gerade eingebaut hat. Guard und
NoData-Alarmierung schließen einander aus.

> **Guards sind deshalb nur für Schwellwert-Leitern zulässig** (warning
> unterdrückt sich gegen critical), wo die Crit-Regel die Ausfallerkennung
> ohnehin übernimmt. Für Ausfall-Regeln sind sie verboten — dort unterdrückt
> ein falsch gesetzter Guard den Alarm **still**, und niemand merkt es, bis es
> darauf ankommt. Genau dieser Fehlermodus hat Frigate vier Stunden ohne
> Aufzeichnung laufen lassen.

Betroffene Leitern (fünfmal dasselbe Muster, aktuell alle ohne Guard, beide
Stufen feuern gemeinsam):

| warning | critical |
|---|---|
| `swarm-disk-warning` > 80 % | `swarm-disk-critical` > 90 % |
| `pve-host-root-disk-warning` > 80 % | `pve-host-root-disk-critical` > 90 % |
| `tls-cert-expiring-warn` < 14 d | `tls-cert-expiring-crit` < 3 d |
| `frigate-recordings-disk-warning` < 500 GB | `-critical` < 250 GB |
| `synology-volume-low` < 1 TB | `synology-volume-critical` < 400 GB |

**Weg B — Priorisierung und Bündelung.** Kein Eingriff in die Queries, kein
Risiko stiller Unterdrückung. Drei Maßnahmen:

1. **`group_by` um eine Ursachenebene erweitern.** Heute gruppiert die
   critical-Route auf `[grafana_folder]`. Ein Node-Ausfall verteilt sich über
   4 Ordner → 4 Nachrichten. Ein zusätzliches Label `blast_radius` an den
   Regeln (`node`, `cluster`, `service`) und `group_by: [blast_radius]` fasst
   den Störfall zu **einer** Nachricht zusammen. Das ist der wirksamste
   risikoarme Hebel.
2. **`group_wait` für critical von 30 s auf 90 s.** Der Störfall vom 23.08.
   entfaltete sich über 3,5 Minuten (21:45:20 bis 21:49:00). 30 s Sammelzeit
   erwischt davon nur den ersten Schwung. 90 s fasst 13 der 20 Regeln in eine
   Nachricht — auf Kosten von einer Minute Verzögerung, die bei einem
   Homelab-Alarm ohne Bereitschaft nicht ins Gewicht fällt.
3. **Eine explizite Ursachen-Regel oberhalb der Symptome.** Statt 3× „Swarm node
   down" eine Cluster-Sicht, die den Umfang benennt:
   ```promql
   count(min_over_time(up{job="node-exporter",instance!="postgres-prod"}[3m]) == 0) or vector(0)
   ```
   → `>= 2` = `critical` („Mehrheit des Swarm weg"), `== 1` = eigener,
   niedriger priorisierter Alarm. Ein einzelner ausgefallener Node ist im
   3-Manager-Swarm kein Notfall; zwei sind der Quorumverlust.

**Empfehlung: Weg B zuerst, Weg A nur für die fünf Leitern.** Weg B kann nichts
still unterdrücken — im schlimmsten Fall kommt eine Nachricht später oder
enthält mehr Zeilen. Weg A greift in die Alarmlogik ein und kostet die
NoData-Erkennung.

### 6.3 Herabstufen

Nach dem Kriterium aus 4.5 („stehe ich dafür nachts auf?"):

| Regel | heute | Vorschlag | Begründung |
|---|---|---|---|
| `Open Archiver unreachable` | critical | **warning** | 897 Auslösungen = 34 % des Gesamtaufkommens. Ein Mail-Archiv, das nachts kurz weg ist, kostet nichts. Größter Einzelhebel überhaupt. |
| `Paperless unreachable` | critical | **warning** | 220 Auslösungen; Dokumentenarchiv, kein Echtzeitdienst. |
| `Open Archiver Tika unreachable` | warning | **info** | Reiner Nachverarbeitungsdienst, holt auf. |
| `Ollama (Mac Studio) unreachable` | critical | **warning** | Der Mac Studio ist ein Arbeitsplatzrechner, kein Server — er darf aus sein. `for: 1m` ist zudem die zweitkürzeste Pending-Zeit im ganzen File. |
| `Swarm node OOM-killed a process` | critical | **warning** | 112 Auslösungen. Ein OOM-Kill ist ein Ereignis der Vergangenheit; nachts geweckt zu werden ändert nichts mehr. |
| `Zigbee2MQTT bridge offline` | critical | **warning** | Smart-Home-Komfort, keine Sicherheitsfunktion. |
| `Home Assistant update available` | info | **streichen** | 33 Auslösungen für eine Information, die im HA-UI steht. Gehört nicht in ein Alarmsystem. |
| `Ceph cluster warning` | info | **beibehalten**, aber Episodenlänge prüfen | 174 Auslösungen, mehrfach > 60 h stehend. `info` ist richtig; die Regel gehört ins Dashboard, nicht in den Digest. |

Erwartete Wirkung: `critical`-Anteil an den Auslösungen fällt von 72 % auf
grob 25–30 %.

### 6.4 Zusammenlegen und streichen

**Bitidentische Duplikate:**

| Regeln | Befund |
|---|---|
| `pve-host-oom-kill` (crit) ↔ `frigate-lxc-oom` (warn) | **Identische Query**, identisches `for`, identisches `keep_firing_for`, gleiche 3 Hosts. Jeder Host-OOM erzeugt zwei Alarme auf zwei Zustellwegen. → auf **eine** Regel reduzieren, Frigate-Kontext ins Runbook. |
| `swarm-node-down` ↔ `postgres-prod-node-down` | `up{job="node-exporter"} == 0` hat **keinen** instance-Filter; `postgres-prod` hängt im selben Job. Ein DB-Ausfall meldet sich zusätzlich als „Swarm node down". → `instance!="postgres-prod"` ergänzen (schon in 6.1 enthalten). |
| `paperless-down` / `openarchiver-down` ↔ `tls-probe-failed` | Beide Hosts stehen in `blackbox-apps` **und** `blackbox-https`. Jeder App-Ausfall = 1 critical + 1 warning. → Hosts aus einem der beiden Jobs nehmen. |
| `vm-scrape-target-down` ↔ `pbs-down` / `synology-snmp-down` | `pbs-exporter` und `snmp-synology` fehlen in der Ausschlussliste → doppelte Meldung. → Ausschlussliste ergänzen. |

**Streichen:**

| Regel | Grund |
|---|---|
| `postgres-prod postmaster restart loop` | **`pg_postmaster_start_time_seconds` existiert nicht** in VictoriaMetrics (geprüft: 308 `pg_*`-Metriken vorhanden, diese nicht). Die Regel kann eine Restart-Schleife nie erkennen und feuert seit #126 ausschließlich als NoData-Fehlalarm. Entweder streichen oder auf eine vorhandene Metrik umbauen. |
| `Home Assistant update available` | Siehe 6.3 — keine Alarmfunktion. |

**Repariert, nicht gestrichen:**

| Regel | Grund |
|---|---|
| `VictoriaMetrics slow inserts` | Nutzt `vm_slow_inserts_total`. Die Metrik heißt heute **`vm_slow_row_inserts_total`**. Mit `noDataState: OK` ist das ein **stiller blinder Fleck** — die Regel hat in 130 Tagen nie gefeuert und *kann* nicht feuern. |

**Schwellen prüfen, nicht zusammenlegen:**

`pve-host-memory-pressure` (crit, < 1,25 GiB **absolut**) und
`pve-host-memory-warning` (warn, < 8 % **relativ**) liegen auf pve01 (15 GB →
1,20 GiB) und pve03 (16 GB → 1,28 GiB) faktisch **auf derselben Schwelle**. Die
im Kommentar behauptete Vorwarnzeit existiert dort nicht — nur auf pve02
(32 GB → 2,56 GiB) funktioniert die Staffelung. Beide Regeln auf eine
einheitliche Bezugsgröße bringen.

### 6.5 Die 24 nie ausgelösten Regeln

38 % des Regelwerks hat in 130 Tagen nie gefeuert. Das ist **kein Fehler an
sich** — `Synology RAID nicht normal` soll nie feuern. Aber jede dieser Regeln
ist unbewiesen: Niemand weiß, ob sie funktioniert.

Zwei Fälle sind belegt problematisch (`VictoriaMetrics slow inserts` mit falscher
Metrik; `Loki ingestion dead`, dessen Kanal laut Projektstand ohnehin im Umbau
ist). Vorschlag: **einmal jährlich einen Alarmtest**, bei dem jede nie
ausgelöste Regel einmal künstlich zum Feuern gebracht wird — analog zum
Prüfen von Rauchmeldern. Für die meisten genügt ein temporär verschobener
Schwellwert.

---

## 7. Laufende Messung: das eigentliche Werkzeug

Ein Dashboard, das die eigene Alarmgüte zeigt, ist wichtiger als jede
Einzelregel — es ist die einzige Möglichkeit, eine Verschlechterung zu bemerken,
bevor sie sich als verpasster Störfall zeigt. Der Vorfall von heute wäre damit
binnen einer Stunde aufgefallen.

### 7.1 Voraussetzung: Grafana scrapen (fehlt komplett)

**Es gibt derzeit keine einzige `grafana_*`-Metrik in VictoriaMetrics.** Der
Job fehlt in `stacks/monitoring/prometheus-scrape.yml`. Grafana exponiert
`/metrics` ohne Authentifizierung; alles Nötige ist bereits da (verifiziert am
laufenden Container).

```yaml
  # stacks/monitoring/prometheus-scrape.yml
  - job_name: grafana
    metrics_path: /metrics
    static_configs:
      - targets: ['grafana:3000']
```

### 7.2 Kennzahlen-Dashboard „Alarmgüte"

| Panel | Ausdruck | Zielwert |
|---|---|---|
| **Stehende Alarme** (Kernzahl) | `grafana_alerting_alerts{state="alerting"}` | ≤ 2 |
| Meldungen/Tag | `sum(increase(grafana_alerting_alerts_received_total{status="firing"}[24h]))` | ≤ 5 (siehe Warnung unten) |
| **Unterbrechungen/Tag** | `sum(increase(grafana_alerting_notifications_total{integration="telegram"}[24h]))` | ≤ 2 |
| Spitze/10 min | `max_over_time(sum(increase(grafana_alerting_notifications_total[10m]))[24h:1m])` | ≤ 3 |
| Zustellfehler | `sum(increase(grafana_alerting_notification_errors_total[1h]))` | 0 |
| Regel-Auswertungsfehler | `sum(increase(grafana_alerting_rule_evaluation_failures_total[1h]))` | 0 |
| Aktive Gruppen | `grafana_alerting_dispatcher_aggregation_groups` | Kontext |
| Inhibition-Regeln | `grafana_alerting_alertmanager_inhibition_rules` | konstant 0 (Erinnerung: gibt es hier nicht) |

> ⚠️ `grafana_alerting_alerts_received_total` zählt **jede Neuzustellung** eines
> anstehenden Alarms an den internen Alertmanager, nicht nur neue Auslösungen.
> Bei 26 Dauer-Alarmen und 60 s Takt sind das ~37.000/Tag. Als Meldungsrate ist
> die Metrik damit **unbrauchbar** — sie eignet sich aber hervorragend als
> **Dauer-Alarm-Detektor**: Steigt sie über ~2.000/Tag, stehen Alarme an, die
> niemand abarbeitet.

### 7.3 Die eine Regel, die dieses Dokument rechtfertigt

Ein Alarm über die Alarmgüte selbst — er hätte den heutigen Defekt sofort
gemeldet:

```yaml
# Vorschlag, nicht deployt
title: Alarmsystem ueberlastet (zu viele stehende Alarme)
severity: warning          # bewusst nicht critical: es ist kein Anlagenproblem
for: 2h
noDataState: OK            # Grafana tot -> andere Regeln greifen; hier kein Wert
expr: grafana_alerting_alerts{state="alerting"}
condition: IS ABOVE 5
```

Bei 26 stehenden Alarmen wäre das seit heute Morgen gefeuert. `for: 2h`
verhindert, dass ein normaler Störfall die Regel auslöst.

Ergänzend, gegen den Fehlermodus „Grafana selbst ist weg" — den einzigen, den
Grafana konstruktionsbedingt nicht melden kann: eine **Totmannschaltung
außerhalb** der Alarmkette. VictoriaMetrics kann das nicht leisten (Grafana
alarmiert, nicht VM). Praktikabel ist ein Eintrag im täglichen
Wartungsskript (`~/Documents/projects/ansible/daily-maintenance.sh`), der
`grafana_alerting_alerts` abfragt und bei fehlender Antwort separat meldet.

### 7.4 Verwaiste Alarminstanzen aufräumen

`patroni-no-leader` und `etcd-no-leader` stehen seit 52 Tagen auf `Alerting`,
obwohl die Regeln aus dem Provisioning entfernt wurden. Grafana räumt
`alert_instance`-Zeilen gelöschter Regeln nicht ab — bekanntes Muster, deckt
sich mit dem dokumentierten Problem file-provisionierter Regeln, die sich über
die API nicht löschen lassen.

Bereinigung nur über die DB, **bei gestopptem Grafana** und nach Sicherung der
`grafana.db` (sie liegt auf `/mnt/rbd/grafana/`, also auf dem RBD-Volume mit
exclusive-lock — der Node muss der `grafana-rbd=active`-Node sein):

```sql
DELETE FROM alert_instance
 WHERE rule_uid NOT IN (SELECT uid FROM alert_rule);
```

Vorher zählen, nicht blind löschen. Das ist ein schreibender Eingriff und war
nicht Teil dieser Analyse.

---

## 8. Reihenfolge

Nach Wirkung pro Aufwand:

1. **Die 18 Queries auf „liefert immer einen Wert" umbauen** (6.1). Behebt 26
   Fehlalarme und stellt die Ausfallerkennung aus #126 erst wirklich her.
   Ohne diesen Schritt ist jede weitere Kennzahl bedeutungslos.
2. **`Home Assistant update available` streichen, `postgres-prod postmaster
   restart loop` streichen oder umbauen** (6.4). Zwei Regeln, sofort.
3. **Grafana-Scrape-Job + Dashboard + Übermeldungs-Alarm** (7.1–7.3). Ab hier
   ist die Alarmgüte messbar statt vermutet.
4. **Herabstufungen** (6.3), beginnend mit `Open Archiver unreachable` — allein
   das nimmt ein Drittel des Aufkommens aus dem Kanal.
5. **`blast_radius`-Label + `group_wait` 90 s** (6.2, Weg B). Fasst den
   Node-Flood zu einer Nachricht.
6. **Duplikate zusammenlegen** (6.4), **`unless`-Guards für die fünf Leitern**
   (6.2, Weg A).
7. **Verwaiste Instanzen bereinigen** (7.4).
8. **Jährlicher Alarmtest** für die 24 nie ausgelösten Regeln (6.5).

---

<!-- ============================================================ -->
<!-- ABSCHNITT 9 IST ZUR ÜBERNAHME NACH .claude/CLAUDE.md GEDACHT -->
<!-- ============================================================ -->

## 9. Bindende Regeln — Entwurf zur Übernahme nach `.claude/CLAUDE.md`

> **Dieser Abschnitt ist der einzige Teil des Dokuments, der als verbindliche
> Regel gedacht ist.** Er ist bewusst kurz gehalten. Die Übernahme nach
> `.claude/CLAUDE.md` erfolgt durch den Betreiber — dieses Dokument ändert
> `CLAUDE.md` nicht.

---

### Alarmdesign (EEMUA 191, übersetzt) — Stand 2026-08-24

**Vor jeder Änderung an `stacks/monitoring/alerting/`:**

1. **`noDataState: Alerting` nur mit Query, die im Gesundzustand einen Wert
   liefert.** `X == 0`, `count(...) > 0` und jeder andere filternde Vergleich
   liefern im Gesundzustand **nichts** — Grafana macht daraus `NoData` und mit
   `Alerting` einen Dauer-Fehlalarm. Richtig ist
   `min_over_time(X[3m])` (Vergleich in die Grafana-Bedingung) oder
   `count(...) or vector(0)`.
   **Pflichtprüfung vor dem Deploy:**
   ```bash
   ssh root@192.168.4.41 "curl -s 'http://127.0.0.1:8428/api/v1/query' \
     --data-urlencode 'query=<EXPR>'"
   ```
   Leeres `result` = Regel ist falsch gebaut. Nicht deployen.
   *(Verstoß hat am 2026-08-24 18 von 64 Regeln dauerhaft falsch feuern lassen,
   11 davon critical.)*

2. **`unless`-Guards nur für Schwellwert-Leitern (warning gegen critical),
   niemals für Ausfall-Regeln.** Ein Guard macht die Query filternd und erzwingt
   damit `noDataState: OK` — die Ausfallerkennung geht verloren, und ein falsch
   gesetzter Guard unterdrückt **still**. Guard und NoData-Alarmierung schließen
   einander aus.

3. **`critical` heißt: dafür stehe ich nachts um drei auf.** Alles andere ist
   `warning` (Digest 08:00/18:00) oder `info` (nur Dashboard). Zielverteilung
   der **Auslösungen** (nicht der Regeln): ≤ 10 % critical.

4. **Selbstheilende Zustände sind keine Alarme.** Ein Alarm, der ohne Eingriff
   verschwindet, gehört ins Dashboard. Faustregel: Wer regelmäßig unter 8 h von
   selbst zurückgeht, ist Statistik, nicht Alarm.

5. **Metrik-Existenz prüfen, bevor eine Regel geschrieben wird.** Zwei Regeln
   im Bestand referenzieren nicht existierende Metriken
   (`pg_postmaster_start_time_seconds`, `vm_slow_inserts_total`). Mit
   `noDataState: OK` ist das ein stiller blinder Fleck, mit `Alerting` ein
   Dauer-Fehlalarm.

6. **Nach jedem Deploy von Alarmregeln:** `grafana_alerting_alerts{state="alerting"}`
   prüfen. Steigt der Wert dauerhaft über 5, ist eine Regel falsch gebaut.

**Zielwerte (gemessen, nicht geraten):**

| Kennzahl | Ziel | Ist 2026-08-24 |
|---|---|---|
| Stehende Alarme (> 8 h) | ≤ 2 | **26** |
| Chronische Alarme (> 72 h) | 0 | ≥ 3 |
| Meldungen/Tag | ≤ 5 | 20,2 |
| `critical`-Telegram/Tag | ≤ 1 | Ø 16,3 |
| Spitze nach Störfall (10 min) | ≤ 10 Meldungen / ≤ 3 Nachrichten | 17 / 4 |
| Alarm-zu-Ursache-Verhältnis | ≤ 5:1 | 20:1 |
| Anteil `critical` an Auslösungen | ≤ 10 % | 72 % |

**Zwei Kennzahlen, nicht eine.** *Meldungsrate* (Auslösungen) misst die Güte des
Regelwerks, *Unterbrechungsrate* (Telegram-Nachrichten) die Belastung des
Menschen. Bündelung verbessert nur die zweite. Wer nur die Unterbrechungsrate
misst, hält ein kaputtes Regelwerk für gesund.

---

## Anhang: was gemessen wurde und was nicht

**Belastbar gemessen:** Regelinventar (64), Auslösungen (2.651 über 130,5 Tage),
Episodendauern, Tageszeitverteilung, Prioritätsverteilung, Störfallverlauf vom
2026-08-23, aktuelle Zahl stehender Alarme (26, aus `/metrics`), Ergebnis aller
30 `noDataState: Alerting`-Queries gegen die laufende VictoriaMetrics,
Existenz aller referenzierten Metriken.

**Nicht belastbar / bewusst offen gelassen:**

- Die Historie enthält keinen eingeschwungenen Normalbetrieb. Alle
  „pro Tag"-Werte mitteln über Patroni-Ära, Migration und zwei Störfälle.
- Ohne aufgezeichnete `grafana_alerting_*`-Metriken (Abschnitt 7.1) ist die
  Zahl real versendeter Telegram-Nachrichten pro Tag nur für die letzten 14,5 h
  bekannt (15 Stück), und zwar im defekten Zustand.
- Episodendauern > 1 Tag sind Obergrenzen (fehlende Auflösungs-Annotationen bei
  Neuprovisionierung).
- Ob die 24 nie ausgelösten Regeln funktionieren, ist **unbekannt** — für zwei
  ist belegt, dass sie es nicht können.
