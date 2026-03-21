# =============================================================================
# Taiga Frontend with OpenID Connect Plugin
# =============================================================================
# Based on official taigaio/taiga-front with robrotheram's OIDC button.
# Adds OpenID auth plugin (pre-built JS) and custom conf.json.template
# with OpenID fields.
#
# Image: ghcr.io/thorstenhornung1/swarm-stacks/taiga-front-openid:latest
# =============================================================================

ARG TAIGA_VERSION=latest
FROM taigaio/taiga-front:${TAIGA_VERSION}

# OpenID plugin (pre-built JS + manifest)
COPY dist/ /usr/share/nginx/html/plugins/openid-auth/

# Custom conf.json.template with OpenID fields
COPY conf.json.template /usr/share/nginx/html/conf.json.template

# Custom env subst script with OpenID plugin registration
# Must be +x — nginx docker-entrypoint only runs executable scripts
COPY --chmod=755 30_config_env_subst.sh /docker-entrypoint.d/30_config_env_subst.sh
