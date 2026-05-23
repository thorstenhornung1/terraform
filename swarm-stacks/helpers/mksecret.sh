#!/bin/sh
# =============================================================================
# mksecret — create a Docker Swarm secret WITHOUT trailing newline
# =============================================================================
# `echo "value" | docker secret create x -` adds \n to the value. For password
# secrets this causes silent auth failures (the stored value is "value\n",
# the consumer reads "value\n", Postgres / OIDC providers / etc. compare
# byte-wise and fail).
#
# This wrapper uses `printf '%s'` which writes the value verbatim — no
# newline, no escapes — and pipes it into `docker secret create`. Works
# with both stdin-supplied values and value-from-argument.
#
# Usage:
#   helpers/mksecret.sh <name>                # reads value from stdin
#   helpers/mksecret.sh <name> <value>        # value as argument (avoid in
#                                             # shell history; prefer stdin)
#
# Examples:
#   openssl rand -hex 32 | helpers/mksecret.sh app_session_key
#   helpers/mksecret.sh app_db_password "$(openssl rand -base64 24)"
#
# =============================================================================

set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: $0 <secret-name> [value]" >&2
    echo "  if value is omitted, the secret value is read from stdin" >&2
    exit 1
fi

name="$1"

if [ $# -eq 2 ]; then
    value="$2"
    printf '%s' "$value" | docker secret create "$name" -
else
    # Read stdin verbatim. Use `cat` to capture and re-emit so we can pipe
    # into docker secret create.
    cat | docker secret create "$name" -
fi

echo "secret '$name' created (no trailing newline)" >&2
