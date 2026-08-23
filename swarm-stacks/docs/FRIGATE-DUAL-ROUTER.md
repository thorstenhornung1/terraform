# Frigate Zugriffs-Routing — Viewer (LAN) + HA-Integration + Admin (Authentik)

**Datum:** 2026-07-25 (vorher 2026-03-06, BasicAuth-Ära)
**Frigate:** 0.17.2 auf LXC 4502 (192.168.4.70, pve03; HA-managed `ct:4502`)
**Traefik:** v3.6 als Sidecar mit Let's Encrypt DNS-01 (Cloudflare)
**HA-Integration:** frigate-hass-integration 5.15.4

> Der Dateiname sagt noch „Dual" — es sind inzwischen **drei** Router.
> Umbenennung vermieden, weil auf diesen Pfad verlinkt wird.

## Architektur

```
LAN-Browser (Mensch, read-only)
  -> https://frigate.hornung-bn.de
    -> Router "frigate-viewer"  (Default-Prio = Regel-Länge, 29)
      -> viewer-ipwhitelist  : 192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8
      -> viewer-headers      : X-authentik-username=homeassistant
                               Remote-Groups=viewer          <-- erzwungen!
      -> frigate:8971 (Compose-Netz, nginx mit Rollen-Enforcement)

Home Assistant (192.168.2.5, braucht Schreibzugriff)
  -> https://frigate.hornung-bn.de
    -> Router "frigate-ha"      (priority 200, ClientIP-Matcher)
      -> ha-headers          : X-authentik-username=homeassistant
                               Remote-Groups=admin
      -> frigate:8971

Admin (Mensch, Konfiguration)
  -> https://admin.frigate.hornung-bn.de
    -> Router "frigate-admin"
      -> admin-forwardauth   : Authentik Outpost (auth.hornung-bn.de)
      -> admin-role-header   : Remote-Groups=admin
      -> frigate:8971
```

Alle drei Router teilen den Service `frigate-backend` (Port **8971**, `scheme=https`,
`insecureSkipVerify` weil Frigate dort ein self-signed Cert nutzt).

### Ports

| Port | publiziert? | Zweck |
|---|---|---|
| 443 / 80 | ✅ Traefik | alle drei Router; 80 redirected auf 443 |
| 8971 | ❌ **absichtlich nicht** | Traefik erreicht es über das Compose-Netz (172.18.0.x) |
| 5000 | ❌ nie | interner unauthentifizierter Port, ignoriert Rollen |
| 5001 | ❌ nicht mehr | interne FastAPI hinter nginx, **kein** API-Einstiegspunkt |
| 8554 | ✅ | go2rtc RTSP — HA Live-View, **ohne Auth**, nur LAN |
| 8555 | ✅ tcp+udp | go2rtc WebRTC |

**Warum 8971 nicht publiziert wird** (Fix 2026-07-25): Frigates nginx vertraut den
Proxy-Headern auch bei Direktzugriff. Ein publizierter Port war damit ein
LAN-weiter Bypass um IP-Allowlist, Authentik *und* das Let's-Encrypt-Zertifikat:

```bash
curl -k -H 'X-authentik-username: angreifer' -H 'Remote-Groups: admin' \
     https://192.168.4.70:8971/api/profile
# -> {"username":"angreifer","role":"admin",...}      (vor dem Fix)
```

`auth.trusted_proxies` hilft dagegen **nicht** — das Feld steuert laut Doku nur die
`X-Forwarded-For`-Auswertung fürs Rate-Limiting, nicht das Header-Vertrauen.

## Zugriff

| URL | Auth | Rolle | Zweck |
|-----|------|-------|-------|
| `https://frigate.hornung-bn.de` | IP-Allowlist (internes Netz) | **viewer** | Ansehen, HA-Dashboard-iframe |
| `https://frigate.hornung-bn.de` von 192.168.2.5 | ClientIP-Matcher | **admin** | HA-Integration |
| `https://admin.frigate.hornung-bn.de` | Authentik ForwardAuth | **admin** | Konfiguration, User-Management |

Welcher Router eine Anfrage bedient hat, zeigt der Response-Header `X-Frigate-Route`
(`viewer` / `ha` / `admin`). Traefik hat weder `api` noch `accessLog` aktiviert —
das ist die einzige Möglichkeit, das von außen zu sehen.

## Konfiguration

### config.yml (Frigate)

```yaml
auth:
  enabled: false               # MUSS false sein für Proxy-Auth
  trusted_proxies:
    - 172.16.0.0/12            # Docker Bridge-Netzwerke (Traefik -> Frigate)

proxy:
  header_map:
    user: X-authentik-username # Traefik setzt diesen Header
    role: Remote-Groups        # NICHT Remote-Role (nginx-Whitelist, s. Gotcha 2)
  default_role: viewer         # greift nur, wenn der Header FEHLT (s. Gotcha 1)
```

Kein `tls:`-Block → Frigate-Default: nginx auf 8971 mit self-signed Cert. Deshalb
`serversTransport.insecureSkipVerify: true` in `traefik.yml`.

### go2rtc — Restream-Pattern (Live-View für HA)

Ohne `go2rtc.streams` erzeugt Frigate eine **leere** `/dev/shm/go2rtc.yaml`:
8554/8555 lauschen, liefern aber nichts. Die HA-Integration setzt
`CameraEntityFeature.STREAM` zudem nur für Kameras, die dort auftauchen — ohne den
Block gibt es in HA prinzipiell **nur Standbilder**.

**⚠️ go2rtc-Producer laufen PERMANENT, nicht on-demand.** Verifiziert 2026-07-25:
`producers=1` bei `consumers=0` direkt nach dem Restart. Ein go2rtc-Block, dessen
Streams *parallel* zu `cameras.*.ffmpeg.inputs` auf die Kameras zugreifen, erzeugt
also eine **dritte Dauerverbindung** pro Kamera. Genau daran ist der erste Versuch
gescheitert (Commit `6897cd6`, revertiert).

Richtig ist das **Restream-Pattern**: nur go2rtc greift auf die Kameras zu, Frigate
bezieht `detect` **und** `record` von `127.0.0.1:8554`. Verbindungen bleiben damit
konstant — 2 pro Reolink, 1 zur DoorBird — egal wie viele Leute zuschauen.

```yaml
go2rtc:
  streams:
    garten:        ["rtsp://{...}@{FRIGATE_GARTEN_IP}/h264Preview_01_sub"]    # HA + detect
    garten_record: ["rtsp://{...}@{FRIGATE_GARTEN_IP}/h264Preview_01_main"]   # nur record
    garage:        ["rtsp://{...}@{FRIGATE_GARAGE_IP}/h264Preview_01_main"]   # HA + record
    garage_sub:    ["rtsp://{...}@{FRIGATE_GARAGE_IP}/h264Preview_01_sub"]    # nur detect
    doorbird:      ["rtsp://{...}@{FRIGATE_DOORBIRD_URL}/mpeg/media.amp"]     # alles
  webrtc:
    candidates: [192.168.4.70:8555, stun:8555]

cameras:
  garten:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/garten          # detect
          input_args: preset-rtsp-restream
          roles: [detect]
        - path: rtsp://127.0.0.1:8554/garten_record   # record
          input_args: preset-rtsp-restream
          roles: [record]
```

**Namenskonvention (wichtig):** Der Stream, der **exakt wie die Kamera heißt**, muss
immer der HA-taugliche sein — die Integration baut ihre URL als
`rtsp://<host>:8554/<kamera>`, wenn `rtsp_url_template` leer ist. Der jeweils andere
Stream bekommt ein Suffix.

Gemessene Stream-Eigenschaften (2026-07-26):

| Kamera | `_main` | `_sub` | HA bekommt |
|---|---|---|---|
| garten (CX810) | **hevc** 3840×2160 +aac | h264 640×360 +aac | `_sub` |
| garage (E1 Pro) | h264 2560×1440 +aac | h264 640×360 +aac | `_main` |
| doorbird (D2101V) | h264 1280×720, kein Audio | — | den einen Stream |

`garten`s Hauptstream ist **HEVC in 4K** — trotz des Reolink-Pfadnamens
`h264Preview_01_main`. Browser können HEVC in WebRTC nicht, und 4K durch HA zu proxen
ist ohnehin schwer. Deshalb ist dort `_sub` der HA-Stream.

**DoorBird kann natives RTSP:** `rtsp://<user>:<pass>@<host>/mpeg/media.amp` liefert
H.264 1280×720. Das ersetzt den früheren MJPEG-Weg (`-f mpjpeg`) **und** den
`libx264 -preset ultrafast`-Transcode in `output_args`. Messbarer Gewinn: Aufnahme-
Segmente **167 KB / 9 s statt 2,7 MB / 10 s** bei höherer Auflösung (`-c copy`),
`camera_fps` **2.0 statt 0.5**, und die Systemlast **sank** von 2.95 auf 2.12 —
obwohl die vierfache Framezahl verarbeitet wird. `hwaccel_args: []` entfällt dort
ebenfalls, es war nur wegen MJPEG-Inkompatibilität gesetzt.

### Gesichtserkennung — `face` darf NICHT in `objects.track`

Die auf den ersten Blick naheliegende Zeile `- face` in `objects.track` **schaltet die
Gesichtserkennung faktisch ab**. Frigate wählt den Detektor danach aus:

```python
requires_face_detection = "face" not in self.config.objects.all_objects
# data_processing/real_time/face.py:56
# all_objects = Vereinigung aller track-Listen (camera/objects.py:121-131),
#               Modell-Attribute zählen NICHT mit
```

| `face` in `track` | Detektor | Arbeitet auf |
|---|---|---|
| ja | nur der Objektdetektor | Frame-Downscale auf **320×320** |
| **nein** | CV2 **YuNet** (`facedet.onnx`) | Person-Crop in **voller detect-Auflösung** |

Mit `face` in `track` war die Erkennung von März bis Juli 2026 komplett tot: **2123
person-Events in 30 Tagen, kein einziges mit `face`-Attribut.** Drei Gründe griffen
gleichzeitig:

1. **Modellauflösung.** Das Frigate+-Modell läuft mit 320×320. Das ist keine
   Fehlkonfiguration — bei 320px ist der Detektor schon zu **57 %** ausgelastet
   (18,7 detection_fps × 30,6 ms); 640×640 bräuchte rechnerisch ~200 %. Das 640er-Modell
   liegt zwar im `model_cache`, ist auf dieser iGPU aber nicht fahrbar.
2. **Hartes `min_score: 0.7`.** Frigate erzwingt das für *alle* Attribut-Labels
   (`config.py:434-439`) — und bumpt einen explizit gesetzten Wert von `0.5` sogar wieder
   auf `0.7` hoch. Ein Absenken hätte nur mit einem krummen Wert wie `0.45` gewirkt.
3. **Objektmasken vererben sich auf `face`.** Die doorbird-Maske (linke 46 %, gegen die
   Glas-Spiegelung in der Terrassentür) maskierte auch den `face`-Filter mit.

Ohne `face` in `track` fallen alle drei weg: YuNet ist ein spezialisierter
Gesichtsdetektor, arbeitet auf dem Person-Crop bei 1280×720 statt auf einem
320px-Downscale, und `face` durchläuft die Objektfilter gar nicht mehr. Zusatzlast ist
gering — YuNet läuft auf der CPU und nur, wenn eine Person getrackt wird.

Empirisch am selben Frame gegengeprüft (2026-07-27): Objektdetektor 0 Gesichter,
YuNet **2 Gesichter mit Score 0.88 / 0.78** bei 60×88 px.

**Die drei Schichten getrennt testen** — jede kann für sich brechen:

```bash
# 1) Detektion: findet YuNet ein Gesicht im Frame?
docker exec frigate python3 -c "
import cv2; from frigate.const import MODEL_CACHE_DIR
img=cv2.imread('/tmp/test.jpg')
d=cv2.FaceDetectorYN.create(MODEL_CACHE_DIR+'/facedet/facedet.onnx',config='',
                            input_size=(320,320),score_threshold=0.5,nms_threshold=0.3)
d.setInputSize((img.shape[1],img.shape[0]))
print(d.detect(img)[1])"

# 2) Erkennung: matcht ein bekanntes Trainingsbild? (muss hohen Score liefern)
curl -s -X POST -F "file=@<trainingsbild>.jpg" http://127.0.0.1:5000/api/faces/recognize

# 3) Live-Pipeline: spricht der Face-Prozessor?
docker logs --since 10m frigate 2>&1 | grep real_time.face
#   "Not processing face for a non person object"  -> Prozessor lebt
#   "No attributes to parse"                       -> face steht (falsch) in track
#   "Detected no faces for person object"          -> YuNet findet nichts
#   "Detected face that is smaller than min_area"  -> min_area zu hoch
```

Für Schritt 3 muss Debug-Logging an sein — `face.py` loggt seine Abbruchgründe
**ausschließlich** auf DEBUG:

```yaml
logger:
  logs:
    frigate.data_processing.real_time.face: debug
```

**Upstream-Bug in `/api/faces/recognize`:** Der Endpoint schneidet die YuNet-Box **ohne
Bounds-Clamping** aus (`face.py:352`), während die Live-Pipeline korrekt
`max(0,…)`/`min(shape,…)` nutzt (`face.py:245`). Bei einem eng zugeschnittenen
Gesichtsbild ragt die Box heraus → leerer Slice → `cv2.error: !_src.empty() in function
'Laplacian'` und HTTP 500. Beim Testen also ein **Vollbild** hochladen oder das Crop mit
`cv2.copyMakeBorder` polstern — betrifft nur diesen Endpoint, nicht die Live-Erkennung.

> **Nachtrag 2026-07-27 — der Abschnitt unten wurde durch Messungen teilweise widerlegt.**
> Die Hochrechnung „selbst nativ bleiben Gesichter 3–6× zu klein" war falsch: sie hat die
> Personendistanz aus einem garten-Sample auf alle Kameras übertragen. Direkt gemessen
> (YuNet auf echten Aufnahmen, Werte wie in `face.py` auf Originalgröße zurückskaliert):
>
> | Kamera | detect | Gesicht | Bewertung |
> |---|---|---|---|
> | garage | 2560×1440 | **17490 px²** | 3,3× die funktionierende doorbird |
> | doorbird | 1280×720 | 5280 px² | Referenz, funktioniert |
> | garten | 3840×2160 | 1800–4640 px² | wäre nutzbar |
> | garten | 640×360 | 52 px² | chancenlos |
>
> Bessere Streams **helfen** also sehr wohl. Der echte Anschlag liegt woanders:
> **pve02 hat 6 physische Cores und 17 an Gäste zugeteilt** — Frigate teilt sie sich mit
> Home Assistant (`vm:100`), postgres-prod (`vm:4600`) und docker-infra-2 (`vm:4201`).
> Zum Vergleich pve01 load 1,3 und pve03 load 1,6 gegen pve02 4,6–9,4. Jede
> Auflösungserhöhung zieht CPU von der Hausautomation und der Produktionsdatenbank ab.
>
> Gemessene Grenzen für garten (4K-HEVC-Quelle):
> `3840×2160@5fps` → 1,9 von 5 fps verworfen · `@3fps` → 1,9 von 3 (nur 1,1 verarbeitet)
> · `2560×1440@5fps` → 2,5 verworfen, 1 % idle, doorbird litt mit.
> **fps senken hilft nicht** — der Engpass ist die Frame-*Größe*: Motion-Resize,
> YUV-Konvertierung und shm-Kopien skalieren mit der Fläche. Der Detektor blieb dabei
> durchweg bei 30–31 ms; es war nie Inferenz.
>
> Zu korrigieren ist auch „die Inferenzkosten sind unabhängig von der detect-Auflösung":
> das stimmt *pro Aufruf* (`create_tensor_input` skaliert immer auf 320×320), aber die
> **Anzahl** der Aufrufe steigt, weil die Mindest-Region von 320 px im größeren Frame
> weniger Bildanteil abdeckt. Detektorlast ging von 57 % auf zeitweise 91 %.
>
> **Endzustand:** doorbird 1280×720 (an) · garage 1920×1080 aus 1440p-Quelle (an, ~9838 px²)
> · garten 640×360 Substream (aus). Was garten freischalten würde, in dieser Reihenfolge:
> Frigate zurück auf pve03 (iGPU-Passthrough dort in Terraform, load 1,6) · garten
> kameraseitig 25 → 15 fps · Motion-Masken auf die Vegetation (derzeit hat **keine**
> Kamera eine).

**Warum nur `doorbird` Gesichter erkennt — und warum bessere Streams nichts ändern.**
Frigate 0.17 hat **keine** eigene Stream-Rolle für Gesichter (`CameraRoleEnum = [audio,
record, detect]`, `CameraTypeEnum = [generic, lpr]`) — die Erkennung läuft immer auf dem
`detect`-Frame. Naheliegender Gedanke: dann eben den Hauptstream für `detect` nehmen. Die
Maintainer empfehlen genau das ([FAQ](https://github.com/blakeblackshear/frigate/discussions/18048)):
*„Use the main stream for the `detect` role but set your `detect` `width`/`height` to 1280
and 720 so that your GPU will be used to scale it."* Für **diese** Kameras reicht das nicht:

| detect-Auflösung | Gesicht garten/garage | vs. `min_area` 500 | vs. doorbird 5280 px² |
|---|---|---|---|
| 640×360 (Substream) | 52 px² | ❌ | 1 % |
| 1280×720 (FAQ-Empfehlung) | 208 px² | ❌ **darunter** | 4 % |
| 1920×1080 | 468 px² | ❌ | 9 % |
| 2560×1440 (garage nativ) | 832 px² | ✅ | 16 % |
| 3840×2160 (garten nativ) | 1872 px² | ✅ | 35 % |
| *ArcFace-Eingang 112×112* | *12.544 px²* | | |

Selbst nativ bleiben die Gesichter 3–6× kleiner als das, was auf der doorbird funktioniert.
Unabhängig bestätigt durch die **DORI-Spezifikation**: die CX810 hat ~7 m
Identification-Range bei vollen 4K, linear skaliert sind das ~2,4 m bei detect 1280.
Die Doku dazu: *„the distance listed by the camera is the furthest that face recognition
will realistically work."* Das Limit ist die **Pixeldichte auf der Distanz**, nicht die
Konfiguration.

Dazu die Kosten (eigene `ffmpeg -benchmark`-Messung, VAAPI, 60 Frames):
`detect.fps` reduziert die **Dekodierung nicht** — der fps-Filter sitzt hinter dem Decoder,
ffmpeg dekodiert jedes Quellframe. garage main = 14,9 ms/Frame × 15 fps = **22 % eines
Cores**, garten main = 23,8 ms × 25 fps = **60 %**. Permanenter 4K-HEVC-Decode auf der HD630
neben OpenVINO ist zudem genau das Lastprofil des dokumentierten i915-Livelocks auf pve03.

**Der Upscale auf 1280×720 ist KEIN Fehler.** `garten`/`garage` liefern real 640×360, sind
aber auf `detect: 1280×720` konfiguriert — ffmpeg interpoliert hoch. Das sieht nach
Verschwendung aus, hilft aber der Personenerkennung: Frigates Mindest-Region ist 320 px im
detect-Frame, im hochskalierten Bild füllt dieselbe Person mehr vom 320×320-Modelleingang.
[camera_setup](https://docs.frigate.video/frigate/camera_setup): *„Larger resolutions do
improve performance if the objects are very small in the frame."* **Nicht zurückbauen** —
die 2123 Person-Events pro Monat kommen daher. Umgekehrt gilt aber: `detect.width/height`
nie *über* die Quellauflösung setzen, wenn Gesichter das Ziel sind — interpolierte Pixel
tragen keine Information und kosten zusätzlich Confidence (`blur_confidence_filter` zieht
bis zu 6 Prozentpunkte ab, wenn die Laplacian-Varianz < 120 liegt).

**Reolink `_ext`:** Es gibt einen dritten Stream („Balanced", ~896×512), aber meist nur über
HTTP-FLV statt RTSP: `ffmpeg:http://<ip>/flv?port=1935&app=bcs&stream=channel0_ext.bcs&…`.
Voraussetzung: HTTP **und** RTMP an der Kamera aktivieren, dann **rebooten**. Der RTSP-Pfad
`h264Preview_01_ext` gibt hier 404. Würde die Objekterkennung verbessern, für Gesichter
aber nur 1,4× lineare Auflösung bringen — rettet nichts. Beim E1 Pro fehlt `_ext` meist ganz.
Und: Auflösung *senken* schneidet bei CX810/CX820 das Bild zu, statt zu skalieren.

**Größter Qualitätshebel ist kameraseitig, nicht in Frigate:** I-frame-Intervall auf **1×
fps** und **CBR**. In [#19332](https://github.com/blakeblackshear/frigate/discussions/19332)
brachte das mehr als jede Auflösungsänderung — *„the number of false matches is down to
almost 0"*. Bei der CX-Serie kommt Motion-Smoothing/Ghosting dazu, das Gesichter unbrauchbar
macht, unabhängig von der Auflösung.

**Fazit:** Gesichtserkennung gehört auf eine Kamera, die Menschen auf kurzer Distanz und auf
Kopfhöhe sieht — hier `doorbird`. Für Gartentor/Einfahrt wäre eine dedizierte, eng
eingestellte Kamera im Zulaufbereich der einzige Weg, der die DORI-Physik respektiert.

**Trainingsbilder sind der zweite Blocker.** Die Doku fordert **mindestens 5–10 Bilder pro
Person**, empfiehlt 20–30, und warnt vor mehr als 4–6 *ähnlichen* Bildern (Overfitting).
Gemessen mit einem einzigen Trainingsbild: das Bild gegen sich selbst → Score **0.94**,
ein Live-Profilgesicht derselben Person → **`unknown`, Score 0**. Frontalbilder sind laut
Doku die Grundlage, leicht schräge kommen später dazu.

Nachschub liefert `save_attempts: 200`: `write_face_attempt()` schreibt **jeden**
erkannten Gesichts-Crop nach `/media/frigate/clips/faces/train/` — auch nicht erkannte
(`…-unknown-0.0.webp`), rollierend begrenzt. Diese Kandidaten werden in der UI unter
*Face Library → Train* einer Person zugeordnet.

### DNS

- `frigate.hornung-bn.de` → 192.168.4.70 (A-Record, Technitium, **nur auf dns1 pflegen**)
- `admin.frigate.hornung-bn.de` → 192.168.4.70 (A-Record)
- Kein Wildcard: `ha.frigate…` und `test.frigate…` lösen nicht auf. Deshalb nutzt der
  HA-Router denselben Host per `ClientIP` — kein neuer DNS-Eintrag, kein neuer ACME-Order.

## Auth-Flow im Detail

```
1. Request an frigate.hornung-bn.de
2. Traefik: Router-Auswahl. ClientIP(192.168.2.5) -> frigate-ha (prio 200),
   sonst frigate-viewer. ClientIP nutzt die echte TCP-Peer-IP
   (RemoteAddrStrategy), NICHT X-Forwarded-For.
3. Traefik: Middleware injiziert X-authentik-username UND Remote-Groups.
   customrequestheaders überschreibt dabei einen vom Client gesendeten Header.
4. Traefik -> nginx:8971 (HTTPS, Cert-Verify aus)
5. nginx: auth_request Subrequest an FastAPI /auth (127.0.0.1:5001)
   - proxy_trusted_headers.conf leitet die Auth-Header weiter
   - auth.enabled=false -> Proxy-Auth aktiv
   - header_map.user/-role werden gelesen
6. FastAPI antwortet 202 mit remote-user + remote-role
7. nginx leitet den Request mit der Rolle ans Backend weiter
8. Frigate lädt ohne Login-Prompt in der zugewiesenen Rolle
```

## Gotchas und Lessons Learned

### 1. ⚠️ Jeder ausgewertete Header MUSS explizit gesetzt werden

**Das war eine ausnutzbare Rechteausweitung** (gefunden und behoben 2026-07-25).
`viewer-headers` setzte nur `X-authentik-username`. Traefiks `customrequestheaders`
überschreibt aber **nur Header, die es selbst setzt** — ein vom Client mitgeschickter
`Remote-Groups` wurde ungefiltert durchgereicht, und `header_map.role` liest genau den:

```bash
curl -H 'Remote-Groups: admin' https://frigate.hornung-bn.de/api/profile
# -> {"role":"admin"}     jedes LAN-Gerät konnte Aufnahmen löschen + Config schreiben
```

`default_role: viewer` greift **nur, wenn der Header fehlt** — nicht, wenn er lügt.
Merksatz: bei Header-basierter Proxy-Auth jeden Header belegen, den das Backend liest.

### 2. Remote-Role wird von nginx gedroppt

Frigates nginx hat eine Header-Whitelist (`proxy_trusted_headers.conf`) für die
Auth-Subrequest. Weitergeleitet werden u. a.:

- `Remote-User`, `Remote-Groups`, `Remote-Email`, `Remote-Name`
- `X-Forwarded-User`, `X-Forwarded-Groups`, `X-Forwarded-Email`
- `X-authentik-username`, `X-authentik-groups`, `X-authentik-email`, `X-authentik-name`, `X-authentik-uid`

**`Remote-Role` ist NICHT in der Liste** — deshalb `Remote-Groups` fürs Rollen-Mapping.
Erweiterbar per Bind-Mount auf `/usr/local/nginx/conf/proxy_trusted_headers.conf`.

### 3. Die HA-Integration darf KEINE Credentials haben

Sind in der Integration `username` **und** `password` gesetzt, ruft
`api.py::get_auth_headers()` zwingend `POST /api/login`. Mit `auth.enabled: false`
existiert kein User-Store → **401** → die Integration bricht ab, *bevor* sie einen
einzigen Daten-Request stellt. Symptom im nginx-Log:

```
"POST /api/login HTTP/1.1" 401 ... "HomeAssistant/…" "192.168.2.5"
```

und **kein einziger** `GET /api/config` o. ä. Der Gate ist reine Truthiness
(`if self._username and self._password:`) — beide Felder in der HA-UI unter
**„Neu konfigurieren"** (nicht „Konfigurieren") leeren genügt. Die Authentifizierung
übernimmt der Proxy-Header.

Ebenfalls beachten: `rtsp_url_template` erwartet ein **`rtsp://`**-Jinja2-Template
(Variablen aus dem Frigate-camera-dict, z. B. `{{ name }}`) — keine HTTPS-Basis-URL.
Leer lassen ist meist richtig: die Integration baut dann selbst `<host>:8554/<kamera>`.
Alle fünf Options sind nur bei aktiviertem **Advanced Mode** sichtbar.

### 4. Frigate-User werden automatisch erstellt

Sendet Proxy-Auth einen unbekannten User, erstellt Frigate ihn automatisch mit der
`default_role`. Kein manuelles User-Setup nötig.

### 5. Bestehende User-Datenbank bleibt erhalten

Das Umschalten von `auth.enabled: true` auf `false` löscht **keine** User aus
`frigate.db`. Die DB liegt auf Ceph RBD (`/db/frigate.db`) und ist persistent.

### 6. Port 5000 ≠ API-Einstiegspunkt für Integrationen

Das alte Port-Mapping `5001:5001` war als „HA Frigate Integration connects here"
kommentiert — falsch. nginx lauscht auf **5000** (plain, unauthenticated) und **8971**
(ssl, authenticated); **5001** ist die interne FastAPI *hinter* nginx und hat weder
Auth-Layer noch `/api/version`. Laut Frigate-Doku gilt für 5000 außerdem: „Headers are
ignored for role enforcement. All requests are treated as anonymous. The `remote-role`
value is overridden to admin-level access." Wer 5000 erreicht, ist Admin.

### 7. UI-Config-Editor vs. GitOps — Drift-Gefahr

Frigates UI-Config-Editor schreibt in **dieselbe** `config.yml`, die die CI
überschreibt. **Vor jedem Deploy** diffen:

```bash
ssh root@192.168.4.70 'cat /mnt/cephfs/swarm-state/stack-frigate/config/config.yml' > /tmp/live.yml
diff /tmp/live.yml stacks/apps/frigate/config.yml
```

Sonst gehen live gezeichnete Masken und Zonen verloren.

### 8. Deploy erzeugt 2–4 min Aufnahme-Lücke

`deploy-stacks.yml` matcht per `[[ "$changed_file" == "$stack_dir"/* ]]` — **jede**
Datei unter `stacks/apps/frigate/` löst `docker compose up -d --force-recreate` aus,
auch ein reiner `config.yml`-Diff. Mit `semantic_search: large`,
`face_recognition: large` und OpenVINO-Modell-Load dauert der Neustart 2–4 Minuten
**ohne Aufnahme und ohne Detection**. Änderungen bündeln.

Schnellster Rollback bei kaputter Config (statt `git revert` + Pipeline):

```bash
ssh root@192.168.4.70 'cp /mnt/cephfs/swarm-state/stack-frigate/config/config.yml.bak-<datum> \
  /mnt/cephfs/swarm-state/stack-frigate/config/config.yml && docker restart frigate'
```

`entrypoint.sh` resubstituiert die Platzhalter beim Restart — kein `--force-recreate`
nötig, solange sich die Secrets nicht geändert haben.

### 9. go2rtc-Cold-Start gibt 404

Der erste RTSP-Abruf eines kalten Streams kann mit `404 Not Found` scheitern, weil
go2rtc den Producer erst aufbaut und die Kamera-Verbindung timeoutet
(`[rtsp] error="streams: dial tcp …: i/o timeout"`). Der zweite Versuch klappt.
Für HA irrelevant (retry), beim manuellen `ffprobe`-Test aber verwirrend.

## Verifikation

```bash
# Rechteausweitung geschlossen — MUSS viewer bleiben
curl -sk -H 'Remote-Groups: admin' https://frigate.hornung-bn.de/api/profile

# Welcher Router bedient? (viewer vom LAN, ha von 192.168.2.5)
curl -skI https://frigate.hornung-bn.de/api/version | grep -i x-frigate-route

# 8971/5001 dürfen NICHT erreichbar sein
nc -z -G 3 192.168.4.70 8971 && echo FEHLER || echo ok
nc -z -G 3 192.168.4.70 5001 && echo FEHLER || echo ok

# Traefik-Weg lebt + Zertifikat ist Let's Encrypt
curl -sk https://frigate.hornung-bn.de/api/version
echo | openssl s_client -connect frigate.hornung-bn.de:443 \
  -servername frigate.hornung-bn.de 2>/dev/null | openssl x509 -noout -issuer

# Admin-Router leitet zu Authentik (302)
curl -sk -o /dev/null -w '%{http_code}\n' https://admin.frigate.hornung-bn.de/

# go2rtc-Streams vorhanden (nicht {})
curl -sk https://frigate.hornung-bn.de/api/go2rtc/streams
ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name,width,height \
  -of default=nw=1 rtsp://192.168.4.70:8554/garage

# HA-Integration gesund: KEIN "POST /api/login … 401" mehr
ssh root@192.168.4.70 'docker logs --since 20m frigate 2>&1 | grep HomeAssistant'

# Proxy-Auth Debug innerhalb des Containers
docker exec frigate curl -s -D- \
  -H 'X-authentik-username: homeassistant' -H 'Remote-Groups: admin' \
  -H 'X-Original-URL: https://admin.frigate.hornung-bn.de/' -H 'X-Server-Port: 8971' \
  http://127.0.0.1:5001/auth
# -> 202 Accepted, remote-role: admin

# Header-Debug in Frigate aktivieren (config.yml)
#   logger: { default: info, logs: { frigate.api.auth: debug } }
```

## Dateien

| Datei | Beschreibung |
|-------|-------------|
| `stacks/apps/frigate/config.yml` | Frigate-Config: `auth`, `proxy`, `go2rtc`, Kameras |
| `stacks/apps/frigate/docker-compose.yml` | Traefik-Labels (3 Router, 5 Middlewares), Ports |
| `stacks/apps/frigate/traefik.yml` | Traefik static Config (EntryPoints, ACME DNS-01) |
| `stacks/apps/frigate/dynamic.yml` | Authentik-Outpost-Callback-Router (File-Provider) |
| `stacks/apps/frigate/entrypoint.sh` | `{VAR}`-Substitution → `config_resolved.yml` |
| `docs/FRIGATE-DUAL-ROUTER.md` | Diese Dokumentation |

## Offene Punkte

- **`dynamic.yml` ist nicht GitOps-verwaltet.** Der `lxc-deploy`-Branch in
  `deploy-stacks.yml` kopiert `config.yml`, `entrypoint.sh` und `traefik.yml` gezielt
  an ihre Zielorte, `dynamic.yml` aber **nicht** nach `/opt/frigate/traefik/`
  (= Mount `/etc/traefik`). Die Live-Datei liegt dort nur, weil sie manuell platziert
  wurde — Repo-Änderungen erreichen Traefik nie, und bei einem LXC-Rebuild fehlt der
  Authentik-Callback-Router. Fix analog zum `traefik.yml`-Block, aber **ohne**
  Traefik-Restart: der File-Provider hat `watch: true`.
- **`authentik-outpost` hat keinen Host-Matcher.** `priority: 150` und nur
  `PathPrefix(/outpost.goauthentik.io/)` — der Router fängt damit auch
  `frigate.hornung-bn.de/outpost.goauthentik.io/*` ab, unter Umgehung der
  IP-Allowlist. Auf ``Host(`admin.frigate.hornung-bn.de`) && PathPrefix(…)`` verengen.
- **`admin-role-header` sollte `proxy.role_map` werden.** Aktuell wird *jeder*, der
  Authentiks ForwardAuth passiert, zum Frigate-Admin; die Autorisierung hängt
  vollständig am Authentik-Application-Binding statt an Gruppen. Besser
  `header_map.role: X-authentik-groups` plus
  `role_map: {admin: [<gruppe>], viewer: [<gruppe>]}` — Authentik trennt Gruppen mit
  `|`, was Frigates Default-`separator` entspricht.
- **`rtsp_url_template` in HA leer lassen.** Die Integration baut dann selbst
  `rtsp://<host>:8554/<kamera>` — genau die Namenskonvention oben. Ein handgeschriebenes
  Template müsste bei jeder Stream-Umbenennung nachgezogen werden.
- **Nach Änderungen an `go2rtc.streams` die HA-Integration neu laden.** Sie liest die
  Frigate-Config beim Setup und erkennt `CameraEntityFeature.STREAM` sonst nicht.
