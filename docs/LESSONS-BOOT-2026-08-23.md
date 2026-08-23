# Lessons Learned: Cut-Over-Shutdown und Wiederanlauf, 2026-08-23

Anlass: Umstecken der Hardware an die USV. Erster vollständiger, *geplanter*
Shutdown des Clusters — und der erste Wiederanlauf, bei dem nicht zufällig
mehrere Nodes gleichzeitig zurückkamen.

Der Shutdown lief in 12 Minuten glatt. **Der Wiederanlauf hat die eigentlichen
Erkenntnisse geliefert.**

---

## Die wichtigste: Der WoL-Workaround kann sich nicht selbst starten

```
pve02 bootet allein   →  kein Quorum (1 von 3 Stimmen)
kein Quorum           →  /etc/pve ist read-only, Proxmox startet KEINE Gäste
keine Gäste           →  dns2 (LXC 4101) bleibt aus
kein dns2             →  kein Absender in VLAN 4 für Magic Packets
kein WoL              →  pve01/pve03 bleiben aus
                      →  kein Quorum  ⟲
```

`wol-peer-nodes.service` stand auf `inactive (dead)` mit hängendem `Job: 198` —
er wartete auf einen Container, der ohne Quorum nie starten konnte.

**Warum das am 21.08. nicht auffiel:** Beim Stromausfall kamen mehrere Nodes
gleichzeitig zurück (pve03 und pve02 innerhalb von 27 Sekunden), das Quorum
entstand von selbst, und der Weckruf hatte seinen Absender. Erst der Start aus
dem echten Kaltzustand mit *einem* Node legt die Abhängigkeit frei.

**Das ist dieselbe Bauart wie der NFS-Mount vom 21.08.**, der an einem
DNS-Namen hing, den Container auf demselben Host auflösen sollten. Ein
Mechanismus, der auf einen Dienst angewiesen ist, den er selbst erst
ermöglichen müsste.

**Behelf im Moment:**
```bash
pvecm expected 1     # macht den Einzelnode quorat, Gäste starten, dns2 kommt hoch
/usr/local/sbin/wol-peer-nodes.sh
```

**Richtiger Fix:** Der Weckruf darf nicht von einem Gast abhängen. Zwei Wege:
- Magic Packets direkt aus dem Host-Namespace über `vmbr0.4` senden (Layer 2,
  braucht keine IP auf dem Interface — `ether-wake -i vmbr0.4` oder ein
  `AF_PACKET`-Socket)
- oder ein Boot-Service, der nach N Minuten ohne Quorum `pvecm expected 1`
  setzt und den Weckruf auslöst

Der erste Weg ist der sauberere: Er beseitigt die Abhängigkeit, statt sie zu
umgehen.

---

## `ha-manager set --state stopped` ist persistent

Beim Shutdown gewollt — es verhindert, dass der HA-Stack die Gäste sofort neu
startet. Beim Wiederanlauf eine Falle: **Home Assistant, postgres-prod und
Frigate bleiben aus**, auch wenn ihr Node längst läuft. Sie starten nicht von
selbst und nicht durch `onboot`.

```bash
for sid in vm:4600 vm:100 ct:4502; do ha-manager set "$sid" --state started; done
```

Umgekehrte Reihenfolge zum Shutdown: Postgres zuerst, dann Home Assistant, das
seine Recorder-Datenbank dort führt.

---

## Ceph-Wartungsflags überleben den Neustart

`noout`, `norebalance` und `nobackfill` bleiben gesetzt, bis sie jemand
entfernt. Bleiben sie stehen, **repariert Ceph sich bei künftigen Ausfällen
nicht mehr selbst** — es bliebe degraded, ohne dass etwas kaputt aussieht.

```bash
ceph osd unset noout && ceph osd unset norebalance && ceph osd unset nobackfill
```

`pve-cluster-shutdown.sh` hinterlegt dafür `/root/CEPH-FLAGS-GESETZT.txt`.

---

## Der ceph-osd-Boot-Race ist wieder aufgetreten

Nach dem Kaltstart war **osd.0 auf pve02 `failed`** — dasselbe Muster wie am
21.08. ([swarm-stacks#123](https://github.com/thorstenhornung1/swarm-stacks/issues/123)),
das damals vier Stunden lang 33 % Degradierung verursacht hat. Der OSD startet,
findet kein MON-Quorum, gibt auf, und systemds Rate-Limit macht den
vorübergehenden Fehler dauerhaft.

Die Behebung ist trivial und immer dieselbe:
```bash
systemctl reset-failed ceph-osd@0 && systemctl start ceph-osd@0
```

**Dass es sich exakt wiederholt hat, ist das eigentliche Argument** für den in
#123 vorgeschlagenen Drop-In mit größerem `StartLimitBurst` und längerem
`RestartSec`. Ein Kaltstart braucht mehr als zwei Versuche.

---

## Mount-Units scheitern beim Boot, funktionieren aber manuell

Nach dem Start standen auf `failed`:
`mnt-nfs-frigate-recordings.mount`, `mnt-pve-swarm-shared.mount`,
`mnt-scaninput.mount`

Ein anschließendes `mount /mnt/nfs-frigate-recordings` von Hand lief **sofort
durch** (18 TB, 1,8 TB frei). Es war also kein Konfigurations-, sondern ein
Zeitproblem: Beim Mount-Versuch war das Netz beziehungsweise Ceph noch nicht so
weit.

Das `nofail` aus der Härtung vom 21.08. tut hier genau das, was es soll — der
Boot läuft durch statt in den Emergency Mode. Aber die Unit bleibt `failed`,
und **niemand merkt das**, solange niemand `systemctl --failed` aufruft. Für
Frigate hieße das: Container läuft, Aufnahmen landen im Leeren.

`mnt-scaninput.mount` ist ein Sonderfall — der Export existiert auf der
Synology für pve02 gar nicht. Karteileiche, gehört aus der fstab entfernt.

---

## Der eigene Metrik-Push scheitert beim Boot

`ups-metrics-push.service` stand auf `failed`, `status=7/NOTRUNNING` — das ist
curls Exit-Code für „konnte nicht verbinden". Beim Boot war VictoriaMetrics noch
nicht da, weil die Swarm-VMs zu dem Zeitpunkt selbst noch starteten.

Sachlich harmlos: Der Timer versucht es 30 Sekunden später erneut und ist dann
erfolgreich. Aber der Dienst bleibt als `failed` stehen und verrauscht damit
genau die `systemctl --failed`-Übersicht, die nach einem Kaltstart der
wichtigste Blick ist.

**Fix:** Ist das Ziel nicht erreichbar, soll das Skript mit 0 enden statt mit
einem Fehler. „Noch nicht da" ist kein Defekt.

---

## Interne Namensauflösung fehlt, bis die DNS-Container laufen

dns1/2/3 laufen als LXC auf den Nodes. Zwischen Boot und ihrem Start gibt es
**keine interne Namensauflösung** — extern erreichbar (HTTPS zu GitHub
funktionierte), intern nicht. Alles, was beim Start Namen braucht, scheitert in
diesem Fenster.

Genau deshalb wurde am 21.08. der NFS-Mount von `diskstation.hornung-bn.de` auf
`192.168.2.3` umgestellt. Die Lehre gilt allgemein: **Was vor den Gästen läuft,
muss ohne die Gäste auskommen.**

---

## Was der Shutdown selbst gelehrt hat

Ausführlich im Kopf von `ansible/files/pve-cluster-shutdown.sh`. Die
folgenreichste Einzelheit:

**Ceph-Abfragen blockieren, sobald das MON-Quorum weg ist.** Nach dem zweiten
abgeschalteten Node läuft jedes `ceph`-Kommando in einen internen Timeout. Im
Durchlauf hing der Statusbericht fünf Minuten — und weil der `shutdown`-Befehl
in derselben Kommandokette dahinter stand, **kam er gar nicht zum Zug**. pve02
lief weiter, während er als abgeschaltet galt. Ohne Nachfrage wäre das erst
beim Umstecken aufgefallen.

Deshalb: alles Ceph-Bezogene vor den ersten Node-Shutdown, danach nie wieder.

---

## Ableitungen

| Was | Wohin |
|---|---|
| WoL-Weckruf vom Gast entkoppeln (Layer 2 über `vmbr0.4`) | neu, blockiert den autonomen Wiederanlauf |
| `ceph-osd`-Drop-In mit größerem Rate-Limit | [#123](https://github.com/thorstenhornung1/swarm-stacks/issues/123), jetzt zum zweiten Mal belegt |
| Post-Boot-Sweep über `systemctl --failed` | [#124](https://github.com/thorstenhornung1/swarm-stacks/issues/124), hätte alle sechs Funde oben selbst gemeldet |
| `ups-metrics-push` still beenden, wenn das Ziel fehlt | klein, aber es verrauscht sonst den Sweep |
| `mnt-scaninput.mount` aus der fstab entfernen | Karteileiche |
| Wiederanlauf-Reihenfolge als Gegenstück zum Shutdown-Skript | ergänzt `pve-cluster-shutdown.sh` |

**Der rote Faden durch beide Tage:** Nicht die Ausfälle sind das Problem,
sondern dass sie sich lautlos einrichten. Jeder einzelne Fund oben war in
Sekunden zu beheben — osd.0 mit zwei Kommandos, die Mounts mit einem, die
HA-Gäste mit einer Schleife. Was fehlt, ist nicht Reparaturfähigkeit, sondern
**der Blick darauf, dass etwas zu reparieren wäre**.
