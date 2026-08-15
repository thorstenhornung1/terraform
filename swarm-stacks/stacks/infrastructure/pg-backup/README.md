# pg-backup — ABGESCHAFFT (2026-08-15)

Der Stack `pg-backup` wurde am **2026-08-15** entfernt. Die logische Sicherung
der PostgreSQL-Datenbanken per `pg_dump` entfällt ersatzlos; die Absicherung
läuft ausschließlich über **PBS-Backups der VM `postgres-prod` (VM 4600)**.

Diese Datei ersetzt `pg-backup-stack.yml` und hält fest, *warum* — damit der
Stack nicht in sechs Monaten ahnungslos wieder angelegt wird.

---

## Warum abgeschafft

### Der Stack war seit dem Patroni-Rückbau faktisch tot

Am **2026-06-15** wurde der Patroni-Cluster gestoppt (Migration auf die
Einzel-VM `postgres-prod`). Der Backup-Stack zeigte weiter auf
`pg-haproxy.hornung-bn.de:5433` — einen Endpunkt, den es seither nicht mehr
gibt. Der Service wurde auf `replicas: 0` gesetzt und blieb es.

**Der letzte logische Dump stammt vom 15.06.2026.** Das fiel zwei Monate lang
niemandem auf: Ein Swarm-Service auf `0/0` ist von einem gesunden Stack nicht
zu unterscheiden — er crasht nicht, er restartet nicht, er schweigt einfach.
Verschärfend kam hinzu, dass der Stack **nie in `webhooks.conf` stand**, also
in keinem GitOps-Diff auftauchte.

### PBS deckt den Katastrophenfall vollständig ab

Geprüft am 2026-08-15:

| Eigenschaft | Wert |
|---|---|
| Frequenz | **2× täglich** (ca. 05:45 und 17:38) |
| Konsistenz | `guest-agent fs-freeze` / `fs-thaw` — in jedem Lauf im Log belegt |
| Retention | `keep-daily=14, keep-weekly=8, keep-monthly=3` |
| Laufzeit | ~3:40 min (inkrementell, ~75 % Reuse) |
| Datastore | `pbs.hornung-bn.de` / `pbsdata` |

`fs-freeze` ist hier der entscheidende Punkt: Das Dateisystem wird vor dem
Snapshot eingefroren, die PostgreSQL-Datendateien sind also an einem sauberen
Punkt erfasst. Beim Restore läuft eine normale WAL-Recovery — das ist ein
vollwertiges physisches Backup, kein bloßer crash-consistent Abzug.

### Was der Stack tatsächlich gekostet hat

Zwei Bugs, die beim Abbau zutage traten:

1. **Der Cleanup-Lauf dumpte statt aufzuräumen.** `backup.sh cleanup` durchlief
   erst die komplette Dump-Schleife nach `$BACKUP_DIR/cleanup/`, bevor der
   eigentliche Aufräum-Block kam. Ergebnis: ein überflüssiger dritter
   Dump-Satz pro Tag, **13 GB in 503 Dateien**.

2. **Die Retention sortierte alphabetisch statt chronologisch.**
   `find … | sort | head -n -112` sortiert Namen der Form
   `<db>_<datum>.dump` zuerst nach Datenbank. Gelöscht wurden damit alle
   `authentik`-Dumps, behalten die jüngsten `vaultwarden`. Die Aufbewahrung
   funktionierte nie wie beschrieben.

Ironischerweise hat Bug 1 die Folgen von Bug 2 kaschiert: Der `cleanup/`-Ordner
enthält heute die meisten erhaltenen Dumps, `daily/` nur noch 383 MB.

---

## Was das kostet — bewusst akzeptiert

Der Verzicht auf `pg_dump` kostet drei Dinge. Sie wurden abgewogen und
akzeptiert:

1. **Kein selektiver Restore.** Auf VM 4600 liegen **11 Datenbanken**. Geht
   eine davon logisch kaputt (fehlgeschlagene App-Migration, versehentliches
   `DELETE`), lässt PBS nur den Rollback der *ganzen VM* zu — alle anderen 10
   DBs verlieren dabei alles seit dem Snapshot. Der Umweg über File-Level-
   Restore existiert (siehe unten), dauert aber Minuten bis Stunden statt
   Sekunden.

2. **Keine Integritätsprüfung.** `pg_dump` liest jede Zeile durch den Server;
   stille Datenkorruption bringt einen Dump zum Scheitern und fällt damit auf.
   PBS kopiert beschädigte Datenseiten klaglos mit und dedupliziert sie über
   alle Snapshots hinweg.

3. **Keine Zielunabhängigkeit.** Ein Custom-Format-Dump lässt sich in PG 17,
   in einen Container oder auf fremde Hardware zurückspielen. Ein PBS-Image
   geht nur auf dieselbe VM-Plattform zurück.

---

## Restore-Verfahren

### Fall A — Totalverlust der VM (der Regelfall)

Standard-PBS-Restore der VM 4600 über die PVE-UI oder:

```bash
qmrestore pbs:backup/vm/4600/<TIMESTAMP> 4600 --storage <ziel>
```

Erwartete Dauer: bei ~160 MB/s und 40 GB Image rund 5–10 Minuten.
PostgreSQL fährt hoch und macht WAL-Recovery.

### Fall B — Eine einzelne Datenbank zurückholen

Es gibt **keinen** direkten Weg. Das Verfahren:

1. Snapshot auswählen:
   ```bash
   pvesm list pbs --vmid 4600
   ```
2. File-Level-Restore starten (PVE-UI → Backup → *File Restore*, oder
   `proxmox-file-restore`). PBS fährt dafür eine temporäre VM hoch, die das
   Blockgerät mountet — im Snapshot selbst liegt nur `drive-scsi0.img.fidx`,
   also das rohe Image.
3. `/var/lib/postgresql/16/main` (PGDATA) herausziehen.
4. Auf einem Wegwerf-Host einen PostgreSQL 16 darauf starten.
5. Dort `pg_dump -Fc -d <datenbank>` ziehen.
6. Auf `postgres-prod` zurückspielen:
   ```bash
   pg_restore -h 192.168.4.45 -U postgres -d <datenbank> --clean <dump>
   ```

> **Nicht verifiziert:** Geprüft wurden am 2026-08-15 die Existenz aktueller
> Snapshots, der `fs-freeze` in jedem Backup-Lauf und die Adressierbarkeit des
> Images über die File-Restore-API. Der eigentliche Datei-Extract und der
> Wiederanlauf eines PostgreSQL aus dem extrahierten PGDATA wurden **nicht
> durchgespielt** — das startet eine zusätzliche VM auf dem RAM-knappen pve02
> und gehört in einen eigenen, geplanten Restore-Drill.
>
> **Empfehlung:** Diesen Drill einmal durchführen, das Ergebnis hier eintragen.
> Ein Restore-Pfad, den niemand je gegangen ist, ist eine Annahme, kein Backup.

---

## Altbestand

Unter `/mnt/cephfs/swarm-state/stack-postgres-backup/` liegen weiterhin **19 GB**
Dumps vom Juni 2026:

| Ordner | Größe | Inhalt |
|---|---|---|
| `cleanup/` | 13 GB | Produkt von Bug 1, enthält aber die meisten erhaltenen Dumps |
| `manual/` | 5,7 GB | manuell gezogene Dumps (u. a. vor Migrationen) |
| `daily/` | 383 MB | Rest nach der defekten Retention |
| `weekly/` | 100 MB | |

Diese Dateien wurden **bewusst nicht gelöscht**. Sie sind der letzte logische
Stand vor dem Patroni-Rückbau und kosten 19 GB von rund 300 GB freiem CephFS.
Wer sie aufräumt, sollte vorher sicherstellen, dass kein Bedarf mehr an
Juni-Ständen besteht.

---

## Reaktivierung

Falls ein logisches Backup doch wieder gebraucht wird, **nicht** die alte
Stack-Datei aus der Git-Historie wiederbeleben — sie enthält beide oben
beschriebenen Bugs und die tote Patroni-Adressierung. Neu aufsetzen mit:

- `PGHOST=192.168.4.45`, `PGPORT=5432` (postgres-prod, PG 16.14)
- Datenbankliste zur Laufzeit ermitteln statt hartkodieren
  (`SELECT datname FROM pg_database WHERE datistemplate = false`)
- Retention über `find -mtime` statt `sort | head`
- Cleanup als eigener Codepfad, **nicht** als `$TYPE`-Wert der Dump-Funktion
- Eintrag in `webhooks.conf`, damit der Stack im GitOps-Diff sichtbar ist
- Achtung bei `lightrag`: nutzt die Extensions `age` und `vector` — ein
  Custom-Format-Dump ist ohne Restore-Test trügerisch
