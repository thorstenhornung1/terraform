# =============================================================================
# kitinerary-extractor — minimaler, gehaerteter Container
# =============================================================================
# Production-Build laeuft im swarm-stacks-GitOps (siehe
# https://github.com/thorstenhornung1/swarm-stacks --> Build-Pipeline pinnt
# eine neue base-Digest periodisch und pushed in die interne Registry).
# Dieses Dockerfile ist die Spezifikation; build.sh ist NUR fuer lokales Dev.
#
# Image enthaelt das KDE-itinerary-extractor-CLI (LGPL). Liest EML/HTML/PDF
# von stdin, schreibt schema.org JSON-LD nach stdout, beendet sich.
# Adapter-Aufruf in belegparser/extraction/kitinerary.py mit Sandbox-Flags
# (--network=none --read-only --memory --cpus --pids-limit --cap-drop=ALL
# --security-opt=no-new-privileges).
# =============================================================================

# Pin: multi-arch Index-Digest von debian:bookworm-slim (2026-05-18 Build).
# Refresh: docker buildx imagetools inspect debian:bookworm-slim --format '{{.Manifest.Digest}}'
# Im GitOps wird dieser Pin periodisch (z.B. monatlich) refreshed.
FROM debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb

# Reproduzierbares apt-install: keine recommends, keine suggests, keine cache.
# kitinerary-extractor-Version ist in bookworm-stable eingefroren -- explizite
# Version-Pin im GitOps via Snapshot-Mirror (snapshot.debian.org) wenn gewuenscht.
RUN set -eux \
    && apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
        kitinerary-extractor \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && useradd --system --no-create-home --shell /usr/sbin/nologin kitinerary

# Non-root: kitinerary-extractor braucht weder root noch Filesystem-Writes.
# Zusammen mit Caller-Flags --read-only / --cap-drop=ALL / no-new-privileges
# bleibt der Subprozess auch bei einem hypothetischen JS-Extraktor-Exploit
# vollstaendig sandboxed.
USER kitinerary

# Healthcheck deaktiviert -- das Image ist On-Demand-CLI, kein Service.
HEALTHCHECK NONE

# stdin -> stdout, kein Argument-Handling im Image (Caller setzt argv strikt).
ENTRYPOINT ["kitinerary-extractor"]
