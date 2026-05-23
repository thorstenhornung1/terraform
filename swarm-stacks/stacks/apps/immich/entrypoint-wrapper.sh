#!/bin/sh
# =============================================================================
# Immich Entrypoint Wrapper
# =============================================================================
# Ersetzt Klartext-Secrets im Compose-File durch Docker-Swarm-Secrets:
#   1. DB_PASSWORD -> aus /run/secrets/immich_db_password als ENV exportiert
#   2. OAuth-Config-JSON -> aus Template substituiert, resolved in /tmp
#
# Warum ein Wrapper? Immich bietet fuer OAuth-Client-ID/Secret keine ENV-Vars
# (Stand v2.7) — die Werte koennen nur ueber die Admin-UI gesetzt werden ODER
# via IMMICH_CONFIG_FILE aus einer JSON-System-Config-Datei gelesen werden.
# Docker Configs werden aber 1:1 ohne Platzhalter-Interpolation gemountet,
# deshalb muessen wir das Template hier zur Laufzeit aufloesen.
#
# Das resolved JSON enthaelt das Klartext-Client-Secret und landet deshalb
# bewusst in tmpfs (/tmp), nicht auf CephFS o.ae. — damit ist es weder im
# PBS-Backup noch ueber `docker cp` von einem anderen Container abrufbar.
#
# Analog zu stacks/apps/vaultwarden/entrypoint-wrapper.sh und taiga.
# =============================================================================

set -eu

# -- DB-Password als ENV-Var exportieren (von Immich-Server nativ gelesen) ----
# tr -d '\r\n' schuetzt gegen Trailing-Whitespace (Portainer-UI-Falle):
# Command-Subst $() strippt nur ein Trailing-\n, nicht aber CR — ein unsichtbares
# \r im Secret-File wuerde PostgreSQL mit "password\r" antreten lassen.
DB_PASSWORD=$(tr -d '\r\n' < /run/secrets/immich_db_password)
export DB_PASSWORD

# -- OAuth-Config aus Template generieren ------------------------------------
# Node statt envsubst/sed, weil der Immich-Server-Container Node.js bereits
# mitbringt und native JSON-Serialisierung robust gegen Sonderzeichen im
# Client-Secret ist (kein Shell-Escaping-Horror bei `/` oder `$`).
node -e '
  const fs = require("fs");
  const tmpl = JSON.parse(
    fs.readFileSync("/etc/immich/immich-oauth-config.template.json", "utf8")
  );
  tmpl.oauth.clientId = fs
    .readFileSync("/run/secrets/immich_oauth_client_id", "utf8")
    .trim();
  tmpl.oauth.clientSecret = fs
    .readFileSync("/run/secrets/immich_oauth_client_secret", "utf8")
    .trim();
  fs.writeFileSync(
    "/tmp/immich-config.json",
    JSON.stringify(tmpl, null, 2),
    { mode: 0o400 }
  );
'

export IMMICH_CONFIG_FILE=/tmp/immich-config.json

# SHELLOPTS kann von bash in start.sh geerbt werden und dort set -eu aktivieren,
# was am ungesetzten DB_URL_FILE zum Abbruch fuehrt. Explizit loeschen.
unset SHELLOPTS || true

# -- Immich-Original-Entrypoint aufrufen -------------------------------------
# Explizites /bin/bash + voller Pfad, damit Shebang-/PATH-Lookup als Fehlerquelle
# ausgeschlossen ist. Original-Image ruft: /bin/bash -c start.sh (via PATH).
exec /bin/bash /usr/src/app/server/bin/start.sh
