#!/usr/bin/env bash
# ============================================================================
# gha-runner LXC provisioning (gerendert via Terraform templatefile)
# Idempotent: Mehrfachlauf (script_hash-Trigger) ist gefahrlos.
# Secrets (Registrierungs-PAT, Tailscale, LDAP-Bind-PW) werden NICHT hier
# gesetzt — der User trägt sie nach apply ein (siehe Schluss-Ausgabe).
# ============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# Diagnose: jeder Abbruch meldet Zeile+Exitcode nach stderr (NUR LINENO,
# KEIN Secret) — macht künftige Fehlersuche eindeutig statt Raten.
trap 'rc=$?; echo "[gha-runner] ABBRUCH: Zeile $LINENO, Exitcode $rc" >&2' ERR

echo "[gha-runner] (1/9) APT-Proxy (vor jedem apt-get; DNS via Technitium)"
cat > /etc/apt/apt.conf.d/01proxy <<'EOF'
Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
Acquire::https::Proxy "DIRECT";
EOF

echo "[gha-runner] (1b) apt-Lock-Contention auflösen + global non-interaktiv"
# Ubuntu-Hintergrund-apt (apt-daily{,-upgrade}, unattended-upgrades) hält
# beim ersten Boot oft den dpkg-Lock und blockierte das Provisioning
# (Symptom: "lock was locked by another process with pid NNNN (apt-get)").
# Timer+Services stoppen/maskieren, steckengebliebene apt/dpkg killen.
# Für einen CI-Runner ist automatisches apt ohnehin unerwünscht.
# Alle Kill/Stop non-fatal (|| true), sonst bricht set -e bei "kein
# Prozess gefunden" (pkill exit 1) ab.
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl disable --now unattended-upgrades.service 2>/dev/null || true
pkill -9 -x unattended-upgrade 2>/dev/null || true
pkill -9 -x apt-get 2>/dev/null || true
pkill -9 -x apt 2>/dev/null || true
pkill -9 -x dpkg 2>/dev/null || true
sleep 3
# DEBIAN_FRONTEND=noninteractive unterdrückt Conffile-Prompts NICHT — dafür
# explizit --force-confdef/--force-confold global. DPkg::Lock::Timeout lässt
# künftige Lock-Contention WARTEN (300s) statt sofort zu scheitern. Gilt
# auch für das interne apt-get von Tailscales install.sh.
cat > /etc/apt/apt.conf.d/90noninteractive <<'EOF'
Dpkg::Options { "--force-confdef"; "--force-confold"; };
APT::Get::Assume-Yes "true";
DPkg::Lock::Timeout "300";
EOF
# Nach dem Kill evtl. halb-konfigurierte Pakete non-interaktiv reparieren.
# </dev/null → EOF statt Hängen; --force-confold → Conffile behalten.
DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>&1 || true

echo "[gha-runner] (2/9) Pakete"
apt-get update -y </dev/null
apt-get install -y --no-install-recommends \
  ca-certificates curl jq git uidmap rsyslog \
  docker.io docker-compose-v2 \
  sssd sssd-ldap libnss-sss libpam-sss </dev/null
systemctl enable --now docker

echo "[gha-runner] (3/9) Tailscale-FLAGS NICHT vorab anlegen (dpkg-conffile)"
# /etc/default/tailscaled ist ein dpkg-conffile des tailscale-Pakets.
# Vorab-Anlegen → Conffile-Konflikt → interaktive dpkg-Rückfrage, die
# über die nicht-interaktive remote-exec-SSH auf EOF läuft und den
# Paketinstall abbricht. Die Userspace-Networking-FLAGS werden daher
# NACH dem Paketinstall in Schritt 6 gesetzt.

echo "[gha-runner] (4/9) rsyslog -> Loki (TCP @@ + UDP @)"
cat > /etc/rsyslog.d/60-loki.conf <<'EOF'
*.* @@loki.hornung-bn.de:1514
*.* @loki.hornung-bn.de:1514
EOF
systemctl restart rsyslog || true

echo "[gha-runner] (5/9) LDAP/SSSD (Standard-Pattern; Bind-PW = Platzhalter)"
cat > /etc/sssd/sssd.conf <<'EOF'
[sssd]
config_file_version = 2
services = nss, pam
domains = hornung-bn.de

[domain/hornung-bn.de]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://ldap.hornung-bn.de
ldap_search_base = dc=ldap,dc=hornung-bn,dc=de
ldap_default_bind_dn = uid=root,cn=users,dc=ldap,dc=hornung-bn,dc=de
ldap_default_authtok = SET_BIND_PASSWORD_HERE
cache_credentials = true
enumerate = false

[nss]
[pam]
EOF
chmod 600 /etc/sssd/sssd.conf
if ! grep -q 'passwd:.*sss' /etc/nsswitch.conf; then
  sed -i 's/^passwd:.*/&  sss/; s/^group:.*/&  sss/; s/^shadow:.*/&  sss/' /etc/nsswitch.conf
fi
grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session || \
  echo 'session optional pam_mkhomedir.so skel=/etc/skel umask=077' >> /etc/pam.d/common-session
# sssd NICHT aktivieren — Bind-PW ist Platzhalter (User-Schritt).

echo "[gha-runner] (6/9) Tailscale-Paket (optional; kein 'up' — Auth-Key = User)"
# OPTIONAL — darf die Kern-Runner-Einrichtung (7-9) NIEMALS blockieren:
# im if gekapselt (set -e greift in if-Bedingungen nicht). Da
# Pending dpkg-State + globales --force-confold sind bereits in (1b)
# behandelt → hier kein rm/Prompt mehr nötig. install.sh ist non-fatal
# gekapselt (set -e greift in if-Bedingungen nicht).
if curl -fsSL https://tailscale.com/install.sh | sh; then
  # Userspace-Networking: unprivileged LXC hat kein /dev/net/tun; Docker
  # braucht kein tun. FLAGS idempotent ins Paket-Conffile schreiben.
  if grep -q '^FLAGS=' /etc/default/tailscaled 2>/dev/null; then
    sed -i 's|^FLAGS=.*|FLAGS="--tun=userspace-networking"|' /etc/default/tailscaled
  else
    echo 'FLAGS="--tun=userspace-networking"' >> /etc/default/tailscaled
  fi
  systemctl restart tailscaled 2>/dev/null || true
  echo "[gha-runner] Tailscale ok (userspace-networking; 'tailscale up' = User-Schritt)"
else
  echo "[gha-runner] WARN: Tailscale-Install fehlgeschlagen — Kern-Runner läuft weiter"
fi

echo "[gha-runner] (7/9) GHCR-Login (Pull privater Base-Images bei Builds)"
echo '${ghcr_pat}' | docker login ghcr.io -u '${ghcr_user}' --password-stdin || \
  echo "[gha-runner] WARN: GHCR-Login fehlgeschlagen (Builds ohne private Base-Images ok)"

echo "[gha-runner] (8/9) Compose + .env (Image-Pull übernimmt 'compose up')"
# KEIN explizites 'docker pull' — war der Abbruchpunkt (set -e, vor mkdir)
# und ist überflüssig: 'docker compose up -d' im Service zieht das Image.
mkdir -p /opt/gha-runner

cat > /opt/gha-runner/.env <<'EOF'
# Registrierungs-PAT — von Terraform aus terraform.tfvars (gitignored via
# *.tfvars) injiziert. Datei root-only chmod 600, NICHT in Git/State-Remote.
ACCESS_TOKEN=${gha_runner_pat}
EOF
chmod 600 /opt/gha-runner/.env

cat > /opt/gha-runner/docker-compose.yml <<'EOF'
# Ephemeral self-hosted Runner — ${runners_per_repo} Service(s) je privatem
# Repo (Skalierung gegen FIFO-Queue-Stau am ein-Runner-pro-Repo-Bottleneck).
# myoung34 vergibt mit EPHEMERAL=true + RUNNER_NAME_PREFIX selbst eindeutige
# Suffixe pro Container → keine Namens-Kollision zwischen den Replicas.
# ACCESS_TOKEN kommt aus /opt/gha-runner/.env (env_file).
# Service-Name-Schema: runner-<repo-kebab>-<idx>  (idx = 1..runners_per_repo)
services:
%{ for repo in repos ~}
%{ for idx in range(1, runners_per_repo + 1) ~}
  runner-${lower(replace(element(split("/", repo), 1), "_", "-"))}-${idx}:
    image: myoung34/github-runner:latest
    restart: unless-stopped
    environment:
      REPO_URL: "https://github.com/${repo}"
      RUNNER_NAME_PREFIX: "homelab"
      LABELS: "${labels}"
      EPHEMERAL: "true"
      DISABLE_AUTO_UPDATE: "false"
    env_file:
      - /opt/gha-runner/.env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
%{ endfor ~}
%{ endfor ~}
EOF

cat > /etc/systemd/system/gha-runner.service <<'EOF'
[Unit]
Description=Self-hosted GitHub Actions Runner (ephemeral, docker compose)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=/opt/gha-runner
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
# PAT kam aus terraform.tfvars → .env ist gefüllt: Runner direkt starten.
# Defensive Guard, falls gha_runner_pat ausnahmsweise leer gesetzt wurde.
if grep -qE '^ACCESS_TOKEN=.+' /opt/gha-runner/.env; then
  systemctl enable gha-runner.service 2>/dev/null || true
  if systemctl start gha-runner.service; then
    echo "[gha-runner] gha-runner.service aktiviert + gestartet"
  else
    echo "[gha-runner] WARN: Service-Start fehlgeschlagen (Unit ist definiert+enabled; 'journalctl -u gha-runner' bzw. 'cd /opt/gha-runner && docker compose logs' prüfen) — Script läuft weiter"
  fi
  # Compose-Änderungen idempotent anwenden — `systemctl start` ist no-op auf
  # bereits-aktiver RemainAfterExit=true Unit (Fall: re-apply nach script_hash-
  # Bump verändert compose.yml, Service läuft schon). `compose up -d` rechnet
  # selbst den Diff (neue Services starten, orphans killen, unveränderte
  # Container bleiben unangefasst).
  cd /opt/gha-runner && docker compose up -d --remove-orphans 2>&1 | tail -20 || \
    echo "[gha-runner] WARN: 'docker compose up -d --remove-orphans' fehlgeschlagen — manuell auf LXC prüfen"
else
  echo "[gha-runner] WARN: ACCESS_TOKEN leer — Service NICHT gestartet (gha_runner_pat in terraform.tfvars setzen, dann re-apply)"
fi

echo "[gha-runner] (9/9) Wöchentlicher Image-Pull (Runner-Aktualität)"
cat > /etc/cron.weekly/gha-runner-update <<'EOF'
#!/bin/sh
docker pull myoung34/github-runner:latest && \
  cd /opt/gha-runner && /usr/bin/docker compose up -d --remove-orphans
EOF
chmod +x /etc/cron.weekly/gha-runner-update

cat <<'EOF'

=====================================================================
 gha-runner provisioniert. PAT kam aus terraform.tfvars → Runner laufen
 bereits (sofern gha_runner_pat gesetzt war). OPTIONAL / VERIFY:
  - Tailscale (deploy-stacks): tailscale up  (dauerhafter Auth-Key,
    interaktiv — entkoppelt vom TS_AUTHKEY-Expiry)
  - LDAP: ldap_default_authtok in /etc/sssd/sssd.conf,
    dann  systemctl enable --now sssd
  - GitHub → je Repo → Settings → Actions → Runners: 3x "homelab" idle
  - dann Workflows: runs-on: ubuntu-latest →
    [self-hosted, linux, x64, homelab]  (swarm-stacks deploy-stacks zuerst)
=====================================================================
EOF
