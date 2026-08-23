#!/bin/bash
# =============================================================================
# LightRAG — Docker-Secrets (idempotent). Auf einem Swarm-Manager ausfuehren.
# =============================================================================
# - lightrag_api_key      : Server-Bearer-Token (Web-UI / REST / MCP)
# - lightrag_db_password  : Postgres-Passwort des Users 'lightrag'.
#       Wird beim DB-Setup auf postgres-prod erzeugt (CREATE ROLE ... PASSWORD)
#       und muss EXAKT dazu passen. Wurde i. d. R. schon angelegt — dieses
#       Skript erstellt es NICHT neu (nur Hinweis, falls es fehlt).
# =============================================================================
set -euo pipefail

create_secret() {
  local name="$1" value="$2"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    echo "SECRET EXISTS: $name (skip)"
    return 0
  fi
  printf '%s' "$value" | docker secret create "$name" - >/dev/null
  echo "SECRET CREATED: $name"
}

# Server-Bearer-Token
create_secret "lightrag_api_key" "$(openssl rand -hex 32)"

# DB-Passwort: nur pruefen, nicht neu wuerfeln (muss zum postgres-User passen).
if docker secret inspect lightrag_db_password >/dev/null 2>&1; then
  echo "SECRET EXISTS: lightrag_db_password (skip)"
else
  echo "WARN: lightrag_db_password fehlt!"
  echo "      Es muss zum postgres-User 'lightrag' auf postgres-prod passen:"
  echo "        printf '%s' '<DB-PW>' | docker secret create lightrag_db_password -"
fi

# OpenAI-API-Key (P1 Cloud-Extraktion, gpt-4.1-mini): nur pruefen, NICHT wuerfeln —
# echter API-Key. Nur waehrend des Per-Artikel-Re-Ingests gemappt, danach revert.
if docker secret inspect lightrag_openai_api_key >/dev/null 2>&1; then
  echo "SECRET EXISTS: lightrag_openai_api_key (skip)"
else
  echo "INFO: lightrag_openai_api_key fehlt (nur fuer P1-Cloud-Extraktion noetig):"
  echo "        printf '%s' 'sk-proj-...' | docker secret create lightrag_openai_api_key -"
fi
