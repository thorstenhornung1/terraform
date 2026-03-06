#!/bin/bash
# =============================================================================
# Frigate Entrypoint — Environment Variables to Config Substitution
# =============================================================================
# LXC/Docker Compose version — secrets come from environment variables
# (loaded via env_file: .env.secrets in docker-compose.yml), NOT from
# Docker Swarm secret files under /run/secrets/.
#
# This entrypoint:
# 1. Maps Frigate+ env vars to expected names
# 2. Creates a writable copy of config.yml with {ENVVAR} placeholders resolved
# 3. Sets CONFIG_FILE to point Frigate to the resolved config
# 4. Hands off to s6-overlay /init
#
# Camera credentials (from .env.secrets):
#   FRIGATE_GARAGE_USER, FRIGATE_GARAGE_PASSWORD, FRIGATE_GARAGE_IP
#   FRIGATE_GARTEN_USER, FRIGATE_GARTEN_PASSWORD, FRIGATE_GARTEN_IP
#   FRIGATE_DOORBIRD_USER, FRIGATE_DOORBIRD_PASSWORD, FRIGATE_DOORBIRD_URL
#   FRIGATE_MQTT_USER, FRIGATE_MQTT_PASSWORD
#   FRIGATE_PLUS_API_KEY, FRIGATE_PLUS_MODELID_2
# =============================================================================

set -e

# --- Step 1: Map Frigate+ env vars ---
# Frigate+ expects PLUS_API_KEY (not FRIGATE_PLUS_API_KEY)
if [ -n "${FRIGATE_PLUS_API_KEY:-}" ]; then
    export PLUS_API_KEY="$FRIGATE_PLUS_API_KEY"
fi

# --- Step 1b: Fallback — also check /run/secrets/ if present ---
# Supports hybrid mode where some secrets come from Docker secret files
for secret in /run/secrets/frigate_*; do
    [ -f "$secret" ] || continue
    varname=$(basename "$secret" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
    # Only set if not already in environment (env_file takes precedence)
    if [ -z "${!varname:-}" ]; then
        export "$varname"="$(cat "$secret")"
    fi
done

# --- Step 2: Resolve {ENVVAR} placeholders in config ---

CONFIG_SRC="/config/config.yml"
CONFIG_DST="/config/config_resolved.yml"

if [ -f "$CONFIG_SRC" ]; then
    python3 -c "
import os, re
with open('$CONFIG_SRC') as f:
    content = f.read()
def replace_var(m):
    return os.environ.get(m.group(1), m.group(0))
content = re.sub(r'\{(\w+)\}', replace_var, content)
with open('$CONFIG_DST', 'w') as f:
    f.write(content)
"
    export CONFIG_FILE="$CONFIG_DST"
fi

# --- Step 3: Hand off to s6-overlay ---
# s6-overlay (/init) starts nginx (WebUI :8971), go2rtc (WebRTC), and
# frigate (API :5001) as managed services.
exec /init
