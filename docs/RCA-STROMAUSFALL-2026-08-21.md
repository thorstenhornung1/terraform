# RCA: Stromausfall 2026-08-21

**Status:** behoben · **Dauer der Beeinträchtigung:** ~4 h · **Entdeckt:** durch
Nachfrage des Betreibers, **nicht** durch Monitoring

---

## Kurzfassung

Ein Stromausfall legte alle drei Proxmox-Nodes um. Nur **pve02** kam von selbst
wieder hoch — als einziger Node hat er im BIOS `Restore on AC Power Loss = Power On`.

Nachdem pve01 und pve03 (vermutlich manuell) gestartet waren, blieb eine Reihe
von Diensten liegen, weil sie beim Kaltstart in Abhängigkeiten liefen, die im
Normalbetrieb nie sichtbar werden. **Jede einzelne Reparatur war trivial** —
meist ein `systemctl reset-failed && systemctl start`. Die vier Stunden
Ausfallzeit entstanden nicht durch Komplexität, sondern dadurch, dass niemand
davon erfuhr.

---

## Was ausgefallen war

| Dienst | Auswirkung | Ursache |
|---|---|---|
| **Frigate** | ~4 h **keine Videoüberwachung** | NFS-Mount fehlte → Container `Exited (127)` |
| **Ceph osd.0** | ~4 h **33,3 % degraded**, alle Daten nur doppelt | Boot-Race + systemd-Rate-Limit |
| `ceph-mds@pve02`, `ceph-mgr@pve02` | keine Standby-Redundanz | derselbe Boot-Race |
| **GitHub-Runner LXC 4303** | GitOps-Deploys hätten gehangen | `lxc.service` Autoboot gescheitert |
| **paperless-webserver** | Dokumentenverwaltung unten | RBD-Ballung + RAM-Mangel |
| NFS `/mnt/scaninput` (pve02) | — | Karteileiche: Export existiert nicht mehr für pve02 |

Unbeeinträchtigt: Cluster-Quorum, alle HA-Gäste (`haos`, `postgres-prod`,
Frigate-LXC), DNS 1/2/3, Immich, Mail-Relay, Tailscale, 49 von 51 Swarm-Services.

---

## Ursachen im Detail

### 1. Frigate: DNS-Name im fstab, aufgelöst von einem Gast desselben Hosts

```
diskstation.hornung-bn.de:/volume1/frigate/recordings  /mnt/nfs-frigate-recordings  nfs  vers=4,…  0 0
^^^^^^^^^^^^^^^^^^^^^^^^^                                                                 kein nofail
```

Der Name wird von dns1/2/3 aufgelöst — LXC-Containern, die **auf genau diesen
Hosts** laufen und erst *nach* den Mounts starten. Beim Kaltstart gab es
niemanden, der auflösen konnte. Der Mount scheiterte, `/mnt/nfs-frigate-recordings`
blieb ein leeres Verzeichnis, der Bind-Mount reichte diese Leere in LXC 4502
durch, und Frigate fand seine Aufnahmen nicht.

Im Normalbetrieb fällt das nie auf, weil DNS dann längst läuft. **Derselbe
Eintrag stand auf allen drei Nodes.**

### 2. Ceph: systemd-Rate-Limit macht einen transienten Fehler dauerhaft

```
14:58:48  Started ceph-osd@0.service
15:03:48  failed to fetch mon config (--no-mon-config to skip)
15:03:58  Scheduled restart job, restart counter is at 2.
15:03:58  Start request repeated too quickly.
15:03:58  Failed to start ceph-osd@0.service
```

Der OSD wartete fünf Minuten auf ein MON-Quorum, das es noch nicht gab — die
anderen Nodes booteten ja noch. Nach dem **zweiten** Fehlversuch griff systemds
Start-Rate-Limit, und der Dienst blieb dauerhaft `failed`. Er hätte sich nie
von selbst erholt.

Das bestehende Drop-In `ceph-after-pve-cluster.conf` greift hier nicht: Das
Problem war nicht pmxcfs, sondern die MON-Erreichbarkeit der Peers.

### 3. RBD-Ballung: korrektes Verhalten mit falschem Ergebnis

Der Failover-Watchdog zog alle vier RBD-Volumes auf **docker-infra-2**, als die
anderen Nodes weg waren. Das ist genau seine Aufgabe. Aber er holt sie nie
zurück — und infra-2 hatte anschließend 1651 MB frei, während
`paperless-webserver` 2560 MB reserviert.

Nichts an diesem Zustand ist ein Fehler: alle Volumes gemappt, alle Mounts
gesund, Watchdog meldet Vollzug. Erst die **Kombination** aus Konzentration und
RAM-Knappheit kippt einen Dienst — und der Swarm-Scheduler kennt nur
`reservations`, nicht den Ist-Verbrauch.

### 4. Kein Alert erreichte den Betreiber

Der schwerwiegendste Befund. Vier Stunden ohne Videoüberwachung, Ceph auf
zwei Repliken — und die Störung fiel nur auf, weil nachgefragt wurde.

| Alert | Warum er schwieg |
|---|---|
| `frigate-down` | prüft `up{job="frigate"}` über Traefik im Swarm — der lief |
| `frigate-camera-no-detection` | `frigate_camera_fps` kam gar nicht zustande (noData) |
| Ceph | **existiert nicht** |
| PVE-Node-Verfügbarkeit | **existiert nicht** |

---

## Was repariert wurde

| # | Maßnahme | Ergebnis |
|---|---|---|
| 1 | `reset-failed` + Start von `ceph-osd@0`, `ceph-mds@pve02`, `ceph-mgr@pve02` | `3 osds: 3 up, 3 in`, Degradierung weg |
| 2 | fstab **aller drei Nodes**: DNS-Name → `192.168.2.3`, `nofail` ergänzt | Mount überlebt Kaltstart ohne DNS |
| 3 | NFS-Mount auf pve02 hergestellt, Frigate-Container gestartet | `healthy`, **181 Dateien in 10 Min** |
| 4 | `reset-failed` + `pct start 4303` | Runner läuft |
| 5 | `paperless-data`-RBD von infra-2 nach infra-3 umgezogen | `1/1` auf docker-infra-3 |
| 6 | WoL-Weckruf auf pve02 gebaut (**temporär**) | siehe `TEMP-WOL-PEER-WAKEUP.md` |

Der RBD-Umzug in sechs Schritten, als Runbook:

```bash
# 1. Watchdog auf ALLEN Nodes pausieren, sonst funkt er dazwischen
for n in 40 41 42; do ssh root@192.168.4.$n systemctl stop paperless-rbd-failover.timer; done
# 2. Prüfen, dass kein Container das Volume hält
ssh root@<alt> 'fuser -vm /mnt/rbd/paperless-data'
# 3. Lösen (Reihenfolge zwingend: erst Mount, dann Map)
ssh root@<alt> 'systemctl stop "mnt-rbd-paperless\x2ddata.mount"; systemctl stop rbd-map-paperless.service'
# 4. Am Ziel einhängen
ssh root@<neu> 'systemctl start rbd-map-paperless.service; systemctl start "mnt-rbd-paperless\x2ddata.mount"'
# 5. Labels einzeln umsetzen (--label-rm ist NICHT idempotent)
docker node update --label-rm paperless-rbd docker-infra-2
docker node update --label-add paperless-rbd=active docker-infra-3
# 6. Watchdogs wieder aktivieren
for n in 40 41 42; do ssh root@192.168.4.$n systemctl start paperless-rbd-failover.timer; done
```

---

## Lessons Learned

**1. Ein Stromausfall ist kein Reboot.**
Beim geplanten Neustart eines Nodes stehen die anderen und liefern DNS, MON-Quorum
und Netz. Beim Kaltstart aller Nodes gleichzeitig brechen Reihenfolge-Abhängigkeiten
auf, die im Normalbetrieb strukturell unsichtbar sind. Jeder Dienst, der beim Start
etwas von einem *anderen* Node braucht, ist ein Kandidat.

**2. Zirkuläre Abhängigkeiten verstecken sich in Konfigurationsdetails.**
Ein Hostname in `/etc/fstab` sieht harmlos aus — bis man merkt, dass der Resolver
ein Gast auf demselben Host ist. Faustregel: **Alles, was vor den Gästen läuft,
muss ohne die Gäste auskommen.** Also IPs, keine Namen.

**3. `nofail` ist kein Komfort, sondern eine Sicherung.**
Ein Mount ohne `nofail` kann einen Node in den Emergency Mode zwingen — dieselbe
Lektion wie seinerzeit bei `/srv/data`. Der Eintrag stand auf allen drei Nodes.

**4. systemd-Rate-Limits verwandeln transiente Fehler in dauerhafte.**
`StartLimitBurst` ist für Crashloops gedacht, nicht für „die Peers booten noch".
Zwei Versuche reichen für einen Cluster-Kaltstart nicht.

**5. „up" ist nicht „funktioniert".**
Die Metrik-Historie belegt, dass Frigate durchgehend `up=1.00` meldete und alle
Kameras konstante 5,1 fps lieferten — *während* die Aufzeichnung stand. Ein
Verfügbarkeitscheck auf den Prozess sagt nichts über das Ergebnis seiner Arbeit.
Alarmiere auf **Wirkung**, nicht auf Erreichbarkeit.

**6. Watchdogs konsolidieren, aber sie rebalancieren nicht.**
Failover ist Einbahnverkehr. Nach jedem Ausfall bleibt eine Schieflage zurück,
die niemand meldet, weil formal alles gesund ist.

**7. Redundanz durch Zufall ist keine Redundanz.**
Dass GitOps weiterlief, verdankt sich `gha-runner-2` auf pve01 — der nicht als
Redundanz geplant, sondern übrig war. Solche Glücksfälle gehören entweder
dokumentiert und überwacht oder abgeräumt.

**8. Die eigentliche Ausfallzeit war Erkennungszeit.**
Alle fünf Reparaturen zusammen dauerten Minuten. Was vier Stunden dauerte, war
das Bemerken. Jede Investition ins Monitoring zahlt hier direkt, jede in
Automatisierung der Reparatur kaum.

---

## Offene Härtung

| Issue | Titel | Prio |
|---|---|---|
| [#121](https://github.com/thorstenhornung1/swarm-stacks/issues/121) | Kein einziger Alert erreichte den Betreiber | P1 |
| [#122](https://github.com/thorstenhornung1/swarm-stacks/issues/122) | BIOS `Restore on AC Power Loss` fehlt auf pve01/pve03 | P1 |
| [#123](https://github.com/thorstenhornung1/swarm-stacks/issues/123) | ceph-osd Boot-Race: Rate-Limit macht Startfehler dauerhaft | P1 |
| [#124](https://github.com/thorstenhornung1/swarm-stacks/issues/124) | LXC-Autoboot scheitert nach Kaltstart | P2 |
| [#125](https://github.com/thorstenhornung1/swarm-stacks/issues/125) | RBD-Ballung ohne Rückkehr und ohne Alert | P2 |

**Aktiver temporärer Workaround:** WoL-Weckruf auf pve02
(→ [TEMP-WOL-PEER-WAKEUP.md](TEMP-WOL-PEER-WAKEUP.md)), Rückbau sobald #122 erledigt ist.

### Zwei Punkte, die noch niemand geprüft hat

- **`dashboard_docker-swarm-dashboard` 0/1** — der Fehler (`assigned node no
  longer meets constraints`) ist 4 Tage alt und damit **älter als der
  Stromausfall**. Eigenständiges Problem.
- **Grafana-State-Lage unklar:** `monitoring_grafana` lief auf infra-3, während
  `grafana-rbd=active` auf infra-2 stand und `grafana.db` unter
  `/mnt/rbd/grafana-data` dort nicht auffindbar war. Entweder liegt Grafanas
  State woanders als angenommen, oder Label und Realität weichen ab. Relevant,
  weil davon abhängt, ob Alert-Historie einen Neustart überlebt (Teil von #121).
