#!/bin/sh
# =============================================================================
# Wallos Entrypoint-Wrapper — Docker Secrets -> OIDC-Env
# =============================================================================
# Wallos liest OIDC_CLIENT_SECRET nativ aus einer Datei (OIDC_CLIENT_SECRET_FILE),
# für OIDC_CLIENT_ID gibt es dagegen KEINE _FILE-Variante. Damit die Client-ID
# nicht im Git landet, wird sie hier aus dem Docker Secret gelesen und exportiert.
#
# Fehlt eines der beiden Secrets, startet Wallos trotzdem — ohne SSO, mit
# lokalem Login. Das ist Absicht: Der Stack lässt sich deployen, bevor der
# Authentik-Provider existiert, und ein Ausfall von Authentik legt die
# Abo-Verwaltung nicht mit still.
#
# Am Ende wird der Original-Entrypoint des Images per exec aufgerufen:
#   Entrypoint ["dumb-init","--"] + Cmd /var/www/html/startup.sh
# exec ist wichtig, damit SIGTERM bei dumb-init ankommt und startup.sh seinen
# Shutdown-Trap (php-fpm/nginx/crond) sauber abarbeiten kann.
# =============================================================================

set -eu

CLIENT_ID_FILE="/run/secrets/wallos_oidc_client_id"
CLIENT_SECRET_FILE="/run/secrets/wallos_oidc_client_secret"

if [ -s "$CLIENT_ID_FILE" ] && [ -s "$CLIENT_SECRET_FILE" ]; then
    # tr -d entfernt Trailing-Newlines: über die Portainer-UI angelegte Secrets
    # tragen sie regelmäßig, und ein "\n" in der Client-ID bricht den
    # Token-Request mit einem nichtssagenden invalid_client.
    OIDC_CLIENT_ID="$(tr -d '\r\n' < "$CLIENT_ID_FILE")"
    export OIDC_CLIENT_ID
    # Nativ unterstützt — der Wert selbst wird nie in eine Env-Variable
    # kopiert und taucht damit nicht in /proc/PID/environ auf.
    export OIDC_CLIENT_SECRET_FILE="$CLIENT_SECRET_FILE"
    export OIDC_ENABLED="true"
    echo "[entrypoint-wrapper] OIDC aktiv (Issuer: ${OIDC_ISSUER:-<nicht gesetzt>})"
else
    export OIDC_ENABLED="false"
    echo "[entrypoint-wrapper] WARNUNG: wallos_oidc_client_id/-secret fehlen oder sind leer."
    echo "[entrypoint-wrapper] Starte OHNE SSO — Anmeldung nur über lokale Wallos-Benutzer."
fi

exec dumb-init -- /var/www/html/startup.sh
