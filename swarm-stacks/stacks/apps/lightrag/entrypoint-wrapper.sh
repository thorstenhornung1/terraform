#!/bin/sh
# =============================================================================
# LightRAG entrypoint-wrapper
# -----------------------------------------------------------------------------
# Injiziert die Docker-Secrets als Umgebungsvariablen (LightRAG liest reine
# Env-Vars, kein *_FILE-Support) und startet dann den Image-Default-Entrypoint
# `python -m lightrag.api.lightrag_server` (siehe LightRAG-Dockerfile).
# =============================================================================
set -eu

# Postgres-Passwort (muss zum postgres-User 'lightrag' auf postgres-prod passen)
if [ -f /run/secrets/lightrag_db_password ]; then
  POSTGRES_PASSWORD="$(cat /run/secrets/lightrag_db_password)"
  export POSTGRES_PASSWORD
fi

# Server-Bearer-Token (Web-UI / REST / MCP)
if [ -f /run/secrets/lightrag_api_key ]; then
  LIGHTRAG_API_KEY="$(cat /run/secrets/lightrag_api_key)"
  export LIGHTRAG_API_KEY
fi

# LLM-API-Key — NUR wenn ein Cloud-LLM-Secret gemappt ist (P1 Per-Artikel-Extraktion).
# Reihenfolge: openai (gpt-4.1-mini) bevorzugt, anthropic als Fallback. Ohne gemapptes
# Secret bleibt LLM_BINDING_API_KEY aus der Env (=ollama) -> Revert auf phi4/Ollama =
# einfach das Secret-Mapping im Stack entfernen, der Wrapper bleibt unverändert (No-op).
for _s in lightrag_openai_api_key lightrag_anthropic_api_key; do
  if [ -f "/run/secrets/$_s" ]; then
    LLM_BINDING_API_KEY="$(cat "/run/secrets/$_s")"
    export LLM_BINDING_API_KEY
    break
  fi
done

exec python -m lightrag.api.lightrag_server "$@"
