#!/bin/sh
# =============================================================================
# snmp_exporter: Zugangsdaten aus Docker Secrets zusammensetzen
# =============================================================================
# WARUM DIESER WRAPPER
#   Der snmp_exporter nimmt seine Zugangsdaten ausschliesslich aus einer
#   Konfigurationsdatei entgegen — anders als UnPoller kennt er kein
#   file://-Praefix fuer einzelne Werte. Die beiden SNMPv3-Passwoerter liegen
#   aber als getrennte Docker Secrets vor.
#
#   Dieser Wrapper baut daraus zur Laufzeit die auths-Datei. Sie landet in
#   /tmp (tmpfs, nur im Arbeitsspeicher) und beruehrt nie ein Volume.
#
#   Die Moduldefinitionen kommen getrennt als Docker Config: Sie sind 82 KB
#   gross, enthalten nichts Geheimes und gehoeren versioniert ins Repo.
#   snmp_exporter kann seit v0.26 mehrere --config.file laden.
# =============================================================================
set -eu

AUTH_FILE=/tmp/snmp-auth.yml
AUTH_PW_FILE="${SNMP_AUTH_PASSWORD_FILE:-/run/secrets/synology_snmp_auth_password}"
PRIV_PW_FILE="${SNMP_PRIV_PASSWORD_FILE:-/run/secrets/synology_snmp_priv_password}"
SNMP_USER="${SNMP_USERNAME:-grafana}"

for f in "$AUTH_PW_FILE" "$PRIV_PW_FILE"; do
  [ -r "$f" ] || { echo "FEHLER: Secret nicht lesbar: $f" >&2; exit 1; }
done

# tr -d loescht ein etwaiges Trailing-Newline: Portainer schneidet nichts ab,
# und ein \n im Passwort fuehrt zu einer Anmeldung, die kommentarlos scheitert.
AUTH_PW="$(tr -d '\r\n' < "$AUTH_PW_FILE")"
PRIV_PW="$(tr -d '\r\n' < "$PRIV_PW_FILE")"

umask 077
cat > "$AUTH_FILE" <<YAML
auths:
  synology_v3:
    version: 3
    username: ${SNMP_USER}
    security_level: authPriv
    auth_protocol: SHA
    password: ${AUTH_PW}
    priv_protocol: AES
    priv_password: ${PRIV_PW}
YAML

echo "snmp-entrypoint: auths-Datei erzeugt (Benutzer ${SNMP_USER}, SHA/AES)"

exec /bin/snmp_exporter \
  --config.file=/etc/snmp_exporter/snmp-modules.yml \
  --config.file="$AUTH_FILE" \
  "$@"
