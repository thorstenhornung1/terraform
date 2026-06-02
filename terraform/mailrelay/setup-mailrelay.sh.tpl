#!/usr/bin/env bash
# ============================================================================
# mailrelay LXC provisioning (gerendert via Terraform templatefile)
# Idempotent: Mehrfachlauf (script_hash-Trigger) ist gefahrlos.
# Das EINZIGE Secret (Client Secret) wird hier nach
# /opt/mailrelay/secrets/relay_client_secret (chmod 600, OHNE trailing newline)
# geschrieben. Werte (tenant/client/bind_addr/trusted_networks) sind
# Terraform-gerendert direkt in die compose.yml inlined (kein .env nötig).
# ============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# Diagnose: jeder Abbruch meldet Zeile+Exitcode nach stderr (NUR LINENO,
# KEIN Secret) — eindeutige Fehlersuche statt Raten.
trap 'rc=$?; echo "[mailrelay] ABBRUCH: Zeile $LINENO, Exitcode $rc" >&2' ERR

echo "[mailrelay] (1/8) APT-Proxy (DNS via Technitium)"
cat > /etc/apt/apt.conf.d/01proxy <<'EOF'
Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
Acquire::https::Proxy "DIRECT";
EOF

echo "[mailrelay] (1b) apt-Lock-Contention auflösen + global non-interaktiv"
# Ubuntu-Hintergrund-apt hält beim ersten Boot oft den dpkg-Lock und blockiert
# das Provisioning. Timer/Services stoppen+maskieren, steckende apt/dpkg killen.
# Alle Kill/Stop non-fatal (|| true), sonst bricht set -e bei "kein Prozess".
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl disable --now unattended-upgrades.service 2>/dev/null || true
pkill -9 -x unattended-upgrade 2>/dev/null || true
pkill -9 -x apt-get 2>/dev/null || true
pkill -9 -x apt 2>/dev/null || true
pkill -9 -x dpkg 2>/dev/null || true
sleep 3
cat > /etc/apt/apt.conf.d/90noninteractive <<'EOF'
Dpkg::Options { "--force-confdef"; "--force-confold"; };
APT::Get::Assume-Yes "true";
DPkg::Lock::Timeout "300";
EOF
DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>&1 || true

echo "[mailrelay] (2/8) Pakete"
apt-get update -y </dev/null
apt-get install -y --no-install-recommends \
  ca-certificates curl jq openssl rsyslog \
  docker.io docker-compose-v2 \
  sssd sssd-ldap libnss-sss libpam-sss </dev/null
systemctl enable --now docker

echo "[mailrelay] (3/8) rsyslog -> Loki (TCP @@ + UDP @)"
cat > /etc/rsyslog.d/60-loki.conf <<'EOF'
*.* @@loki.hornung-bn.de:1514
*.* @loki.hornung-bn.de:1514
EOF
systemctl restart rsyslog || true

echo "[mailrelay] (4/8) LDAP/SSSD (Standard-Pattern; Bind-PW = Platzhalter, NICHT enabled)"
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

echo "[mailrelay] (5/8) Projektverzeichnis + Secret + Self-signed Cert"
# KEIN GHCR-Login: boky/postfix (Docker Hub) und
# ghcr.io/justiniven/smtp-oauth-relay (GHCR) sind beide PUBLIC.
mkdir -p /opt/mailrelay/secrets /opt/mailrelay/certs
chmod 700 /opt/mailrelay/secrets

# Das EINZIGE Secret. Quoted Heredoc = sicher gegen Sonderzeichen ($, \, …) im
# Secret. Danach trailing newline entfernen — RELAYHOST_PASSWORD_FILE darf
# KEINES haben (SASL-Auth bräche; Docker-Secrets trailing-newline-Falle).
cat > /opt/mailrelay/secrets/relay_client_secret <<'SECRET_EOF'
${client_secret}
SECRET_EOF
_S="$(cat /opt/mailrelay/secrets/relay_client_secret)"
printf '%s' "$_S" > /opt/mailrelay/secrets/relay_client_secret
unset _S
chmod 600 /opt/mailrelay/secrets/relay_client_secret

# Self-signed Cert für den INTERNEN Postfix->relay STARTTLS-Hop (nur falls
# absent — idempotent). encrypt-Level erzwingt STARTTLS, prüft den Cert-Namen
# NICHT -> self-signed genügt ohne PKI-Aufwand.
if [ ! -f /opt/mailrelay/certs/cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /opt/mailrelay/certs/key.pem -out /opt/mailrelay/certs/cert.pem \
    -subj "/CN=smtp-oauth-relay" 2>/dev/null
  chmod 600 /opt/mailrelay/certs/key.pem
fi

echo "[mailrelay] (6/8) docker-compose.yml (Werte Terraform-gerendert)"
# Variante C: unauthentifizierte LAN-Einlieferung -> Postfix-Null-Client (Queue)
# -> SASL/STARTTLS -> smtp-oauth-relay -> OAuth2 Client-Credentials -> MS Graph.
# WICHTIG (Spec-Korrektur): boky/postfix nutzt POSTFIX_mynetworks und
# POSTFIX_smtp_tls_security_level — NICHT MYNETWORKS/RELAYHOST_TLS_LEVEL (die
# würde es still ignorieren).
cat > /opt/mailrelay/docker-compose.yml <<'COMPOSE_EOF'
services:
  smtp-oauth-relay:
    image: ghcr.io/justiniven/smtp-oauth-relay:latest
    restart: unless-stopped
    networks: [mailnet]
    # 8025 NUR auf Loopback published — erreichbar allein vom host-net-Postfix,
    # nie aus dem LAN.
    ports:
      - "127.0.0.1:8025:8025"
    environment:
      LOG_LEVEL: INFO
      TLS_SOURCE: file             # self-signed Cert in ./certs (interner Hop)
      REQUIRE_TLS: "true"
    volumes:
      - ./certs:/usr/src/smtp-relay/certs:ro

  postfix:
    image: boky/postfix:latest
    restart: unless-stopped
    depends_on: [smtp-oauth-relay]
    # network_mode: host → Postfix bindet 587 direkt auf der LXC-IP und sieht
    # die ECHTEN Quell-IPs (kein Docker-NAT) → POSTFIX_mynetworks greift exakt
    # auf VLAN4 + die 3 PVEs + PBS. Fallback bei boky-host-net-Zicken: bridge +
    # '{"userland-proxy": false}' in /etc/docker/daemon.json. Host-net lauscht
    # nur auf 587 (kein 25->587-Remap); PVE/Grafana/… können alle 587.
    network_mode: host
    environment:
      ALLOW_EMPTY_SENDER_DOMAINS: "true"
      POSTFIX_myhostname: relay.hornung-bn.de
      POSTFIX_mynetworks: "${trusted_networks}"
      RELAYHOST: "[127.0.0.1]:8025"
      RELAYHOST_USERNAME: "${tenant_id}@${client_id}"
      RELAYHOST_PASSWORD_FILE: /run/secrets/relay_client_secret
      POSTFIX_smtp_tls_security_level: encrypt
    volumes:
      - ./secrets/relay_client_secret:/run/secrets/relay_client_secret:ro

networks:
  mailnet:
    driver: bridge
COMPOSE_EOF

echo "[mailrelay] (7/8) systemd-Unit + Start"
cat > /etc/systemd/system/mailrelay.service <<'EOF'
[Unit]
Description=Homelab Mail-Relay (postfix null-client + smtp-oauth-relay, docker compose)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
WorkingDirectory=/opt/mailrelay
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
# Nur starten, wenn das Secret nicht-leer ist (defensive Guard).
if [ -s /opt/mailrelay/secrets/relay_client_secret ]; then
  systemctl enable mailrelay.service 2>/dev/null || true
  if systemctl start mailrelay.service; then
    echo "[mailrelay] mailrelay.service aktiviert + gestartet"
  else
    echo "[mailrelay] WARN: Service-Start fehlgeschlagen — 'cd /opt/mailrelay && docker compose logs' prüfen"
  fi
  # Re-apply idempotent: 'systemctl start' ist no-op auf bereits-aktiver
  # RemainAfterExit-Unit; 'compose up -d' rechnet den Diff selbst.
  cd /opt/mailrelay && docker compose up -d --remove-orphans 2>&1 | tail -20 || \
    echo "[mailrelay] WARN: 'docker compose up -d' fehlgeschlagen — manuell prüfen"
else
  echo "[mailrelay] WARN: Secret leer — Service NICHT gestartet (mailrelay_client_secret in terraform.tfvars setzen, dann re-apply)"
fi

echo "[mailrelay] (8/8) fertig"
cat <<'EOF'

=====================================================================
 mailrelay provisioniert (${bind_addr}). Apps senden OHNE Auth an :587
 (oder :25). M365-Prereqs müssen erledigt sein: App-Reg, Mail.Send +
 Admin-Consent, ApplicationAccessPolicy (App nur als smtp-relay@).
 VERIFY:
  - swaks --server ${bind_addr} --port 587 --from homelab@hornung-bn.de --to thorsten@hornung-bn.de --h-Subject 'mailrelay test'
  - cd /opt/mailrelay && docker compose logs smtp-oauth-relay   (Token + Graph sendMail 202)
  - docker compose exec postfix postqueue -p                    ("Mail queue is empty")
 PVE-Anbindung (natives smtp-Target, keine Auth):
  - pvesh create /cluster/notifications/endpoints/smtp --name o365-relay --server ${bind_addr} --port 587 --mode insecure --from-address homelab@hornung-bn.de --mailto thorsten@hornung-bn.de
  - pvesh set /cluster/notifications/matchers/default-matcher --target telegram-backup --target o365-relay
=====================================================================
EOF
