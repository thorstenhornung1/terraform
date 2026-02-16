# =============================================================================
# Webhook Runner — GitHub-to-Portainer GitOps bridge
# =============================================================================
# Receives GitHub push webhooks, validates HMAC signatures, and triggers
# Portainer stack redeployments for changed stacks.
#
# Image: ghcr.io/thorstenhornung1/swarm-stacks/webhook-runner:latest
# =============================================================================

FROM alpine:3.21

RUN apk add --no-cache \
    webhook \
    curl \
    jq \
    bash

COPY hooks.json /etc/webhook/hooks.json
COPY redeploy.sh /scripts/redeploy.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /scripts/redeploy.sh /entrypoint.sh

EXPOSE 9000

ENTRYPOINT ["/entrypoint.sh"]
