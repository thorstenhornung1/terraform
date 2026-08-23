# =============================================================================
# email-oauth2-proxy — OAuth2/XOAUTH2 ⇄ plain-IMAP bridge for Open Archiver
# =============================================================================
# Übersetzt O365 OAuth2 (Client-Credentials-Grant, app-only) in lokales
# plain-IMAP, damit Open Archivers Generic-IMAP-Quelle pro Postfach ziehen kann
# (M365 Basic-Auth ist tenant-weit blockiert; CCG ist der modern-auth Pull-Weg).
#
# Image: ghcr.io/thorstenhornung1/swarm-stacks/email-oauth2-proxy:latest
# Upstream: github.com/simonrob/email-oauth2-proxy (Apache-2.0)
#
# Secrets:
#   /run/secrets/oa_oauth_imap  - O365 App client_secret
# Environment:
#   O365_CLIENT_ID   - Azure App (client) ID
#   O365_TENANT_ID   - Directory (tenant) ID
#   O365_MAILBOXES   - comma-separated Postfach-Adressen (je ein account-Block)
#   PROXY_PORT       - lokaler IMAP-Port (default 1993)
# =============================================================================

FROM python:3.12-slim

# emailproxy + dessen Laufzeit-Deps (cryptography liefert manylinux-wheels → kein gcc nötig)
RUN pip install --no-cache-dir emailproxy

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Token-Cache (CCG: transient, access-tokens ~1h, jederzeit neu holbar)
RUN mkdir -p /cache

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
