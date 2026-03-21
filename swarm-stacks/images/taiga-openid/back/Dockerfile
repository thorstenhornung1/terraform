# =============================================================================
# Taiga Backend with OpenID Connect Plugin
# =============================================================================
# Based on official taigaio/taiga-back with robrotheram's OIDC plugin.
# Fixes PG16 incompatibility of robrotheram/taiga-back-openid:latest
# (built June 2022, Python 3.7, Django 1.9).
#
# Image: ghcr.io/thorstenhornung1/swarm-stacks/taiga-back-openid:latest
# =============================================================================

ARG TAIGA_VERSION=latest
FROM taigaio/taiga-back:${TAIGA_VERSION}

# Install OpenID plugin (adapted from robrotheram/taiga-contrib-openid-auth)
COPY plugin/ /tmp/openid-plugin/
RUN pip install --no-cache-dir /tmp/openid-plugin \
 && cat /tmp/openid-plugin/config.py.snippet >> /taiga-back/settings/config.py \
 && rm -rf /tmp/openid-plugin
