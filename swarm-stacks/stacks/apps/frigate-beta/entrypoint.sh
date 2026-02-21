#!/bin/bash
# =============================================================================
# Frigate Entrypoint — Docker Secrets to Environment Variables
# =============================================================================
# Docker Swarm mounts secrets as files under /run/secrets/.
# Frigate uses {ENVVAR} substitution in config.yml.
# This script bridges the two by exporting secret file contents as env vars.
#
# Camera credentials:
#   The secret "frigate_camera_credentials" is a key=value file with one
#   env var per camera password. Example content:
#
#     FRIGATE_CAM_FRONT_DOOR_PW=secretA
#     FRIGATE_CAM_GARAGE_PW=secretB
#     FRIGATE_CAM_GARDEN_PW=secretC
#
#   Then reference in config.yml per camera:
#     path: rtsp://admin:{FRIGATE_CAM_FRONT_DOOR_PW}@192.168.x.x:554/stream1
#
#   This allows different passwords per camera while keeping them out of Git.
# =============================================================================

set -e

# Load per-camera RTSP credentials (key=value file)
if [ -f /run/secrets/frigate_camera_credentials ]; then
    set -a
    source /run/secrets/frigate_camera_credentials
    set +a
fi

# Load MQTT credentials
if [ -f /run/secrets/frigate_mqtt_user ]; then
    export FRIGATE_MQTT_USER=$(cat /run/secrets/frigate_mqtt_user)
fi

if [ -f /run/secrets/frigate_mqtt_password ]; then
    export FRIGATE_MQTT_PASSWORD=$(cat /run/secrets/frigate_mqtt_password)
fi

# Execute the original command (passed as CMD from compose)
exec "$@"
