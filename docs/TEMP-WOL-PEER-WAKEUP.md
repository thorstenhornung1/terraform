# ⚠️ TEMPORÄR: WoL-Weckruf von pve02 an pve01/pve03

> **Status:** aktiv seit 2026-08-21 · **Muss zurückgebaut werden** ·
> Rückbau-Bedingung siehe [Rückbau](#rückbau--der-eigentliche-fix)

## Warum es das gibt

Beim Stromausfall am 2026-08-21 kam nur **pve02** von selbst hoch — als
einziger Node hat er im BIOS `Restore on AC Power Loss = Power On` gesetzt.
pve01 und pve03 blieben aus. Folge: kein Cluster-Quorum, Ceph auf einer
einzigen OSD, praktisch keine Dienste.

Dieser Workaround lässt pve02 die beiden anderen per Wake-on-LAN wecken.

## Warum der Versand aus einem LXC läuft

WoL-Magic-Packets müssen **L2-lokal in VLAN 4** entstehen.

pve02 hat zwar ein VLAN-4-Subinterface, aber **ohne IPv4-Adresse**:

```
vmbr0          UP   192.168.2.11/24
vmbr0.4@vmbr0  UP   (nur IPv6 link-local)   ← kein IPv4
vmbr0.12@vmbr0 UP   192.168.12.11/24
```

Ein `wakeonlan` direkt auf pve02 findet deshalb kein Source-Interface für den
Broadcast an `192.168.4.255`, routet über das Default-Gateway und landet im
falschen L2-Segment — obwohl das Tool installiert ist und keinen Fehler meldet.

Der Weckruf geht daher über **LXC 4101 (dns2, 192.168.4.3)**, der auf pve02
läuft und eine echte IP in VLAN 4 hat. Das ist derselbe Weg, der schon am
2026-04-11 verifiziert wurde (siehe Memory `feedback_wol_vlan4`).

Verifiziert am 2026-08-21 per `tcpdump -i vmbr0.4 udp port 9`:

```
20:54:59  IP 192.168.4.3.48487 > 192.168.4.255.9: UDP, length 102
20:55:05  IP 192.168.4.3.32880 > 192.168.4.255.9: UDP, length 102
```

`length 102` = 6 Sync-Bytes + 16 × 6 MAC-Bytes — ein korrektes Magic Packet.

## Beteiligte Dateien (auf pve02)

| Pfad | Zweck |
|---|---|
| `/usr/local/sbin/wol-peer-nodes.sh` | Der Weckruf, mit Rückbau-Anleitung im Kopf |
| `/etc/systemd/system/wol-peer-nodes.service` | Oneshot beim Boot, `After=pve-guests.service` |
| `/etc/wol-peer-nodes.disabled` | Existiert diese Datei, tut das Skript nichts |

## Verhalten

1. Wartet bis zu 120 s darauf, dass LXC 4101 läuft (ohne ihn kein Versand).
2. Pingt jeden Peer. Wer antwortet, wird übersprungen — das Skript ist
   idempotent und weckt niemanden unnötig.
3. Bis zu 3 Runden im Abstand von 45 s Magic Packets an die fehlenden Peers.
4. Schreibt jeden Schritt nach `journalctl -t wol-peer-nodes`.

**WoL-MACs:** pve01 `98:e7:f4:bc:cd:91` · pve03 `98:e7:f4:bc:6f:8c`
(beide `Wake-on: g` aktiv, geprüft mit `ethtool eno1`)

## Warum das keine Lösung ist

- **Single Point of Failure:** Der Weckruf hängt daran, dass ausgerechnet
  pve02 hochkommt. Fällt pve02 aus, greift gar nichts — und pve02 trägt
  ohnehin schon die drei HA-Gäste (`haos`, `postgres-prod`, Frigate-LXC).
- **Abhängig von der Gast-Startreihenfolge:** Ohne LXC 4101 kein VLAN-4-Absender.
- **Weckt auch ungewollt:** Startet pve02 neu, während pve01/pve03 absichtlich
  aus sind, werden sie geweckt. Unterdrücken mit:
  `touch /etc/wol-peer-nodes.disabled`
- Es kaschiert eine **BIOS-Fehlkonfiguration** auf zwei von drei Nodes, statt
  sie zu beheben.

## Rückbau — der eigentliche Fix

**Bedingung:** In BIOS/UEFI von **pve01 und pve03** setzen:

```
Restore on AC Power Loss = Power On
```

(Je nach Board auch „After Power Failure", „AC Back Function" oder
„Power On After Power Loss". pve02 zeigt, wie es aussehen muss.)

Danach auf pve02 entfernen:

```bash
systemctl disable --now wol-peer-nodes.service
rm -f /etc/systemd/system/wol-peer-nodes.service
rm -f /usr/local/sbin/wol-peer-nodes.sh
rm -f /etc/wol-peer-nodes.disabled
systemctl daemon-reload
```

Anschließend diese Datei löschen und den Verweis in `.claude/CLAUDE.md`
entfernen.

## Testen ohne Stromausfall

Das Skript direkt aufrufen — **nicht** `systemctl start`, denn
`RemainAfterExit=yes` macht einen zweiten Start zum No-op:

```bash
ssh root@192.168.2.11 /usr/local/sbin/wol-peer-nodes.sh
```

Laufen beide Peers, meldet es „bereits erreichbar" und beendet sich in ~1 s.
Um den Sendepfad zu prüfen, parallel auf pve02 mitschneiden:

```bash
tcpdump -i vmbr0.4 -nn "udp port 9"
```
