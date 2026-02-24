#!/bin/bash
# =============================================================================
# Frigate Entrypoint — Docker Secrets to Config Substitution
# =============================================================================
# Docker Swarm mounts secrets as read-only files under /run/secrets/ and
# configs as read-only files. Frigate 0.17 does NOT perform {ENVVAR}
# substitution in its config parser (ruamel.yaml loads values literally).
#
# This entrypoint:
# 1. Loads Docker secrets into environment variables
# 2. Creates a writable copy of config.yml with {ENVVAR} placeholders resolved
# 3. Sets CONFIG_FILE to point Frigate to the resolved config
# 4. Hands off to s6-overlay /init (starts nginx, go2rtc, frigate)
#
# Camera credentials (individual secrets per camera):
#   frigate_garage_user, frigate_garage_password, frigate_garage_ip
#   frigate_garten_user, frigate_garten_password, frigate_garten_ip
#   frigate_doorbird_user, frigate_doorbird_password, frigate_doorbird_url
#   Then in config.yml:
#     path: rtsp://{FRIGATE_GARAGE_USER}:{FRIGATE_GARAGE_PASSWORD}@{FRIGATE_GARAGE_IP}/...
#     path: http://{FRIGATE_DOORBIRD_USER}:{FRIGATE_DOORBIRD_PASSWORD}@{FRIGATE_DOORBIRD_URL}/bha-api/video.cgi
#
# Frigate+ (optional):
#   frigate_plus_api_key, frigate_plus_modelid
# =============================================================================

set -e

# --- Step 1: Load secrets into environment ---
# Each Docker secret file becomes an uppercase env var for {ENVVAR} substitution.

for secret in /run/secrets/frigate_*; do
    [ -f "$secret" ] || continue
    varname=$(basename "$secret" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
    export "$varname"="$(cat "$secret")"
done

# --- Step 1b: Map secrets to Frigate-expected env vars ---
# Frigate+ expects PLUS_API_KEY (not FRIGATE_PLUS_API_KEY)
if [ -n "${FRIGATE_PLUS_API_KEY:-}" ]; then
    export PLUS_API_KEY="$FRIGATE_PLUS_API_KEY"
fi

# Versioned model ID secret → generic FRIGATE_PLUS_MODELID
# Secret "frigate_plus_modelid_2026.1" → env var FRIGATE_PLUS_MODELID_2026_1
if [ -n "${FRIGATE_PLUS_MODELID_2026_1:-}" ]; then
    export FRIGATE_PLUS_MODELID="$FRIGATE_PLUS_MODELID_2026_1"
fi

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
# frigate (API :5001) as managed services. nginx reverse-proxies to
# uvicorn on 127.0.0.1:5001, so no bind-address patching needed.
exec /init
