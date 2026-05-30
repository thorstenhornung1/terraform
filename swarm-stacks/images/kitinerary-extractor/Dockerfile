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
# Debian-Paket heisst `libkpimitinerary-bin` (verifiziert 2026-05-30 gegen
# bookworm-Paketindex: das ehemals vermutete `kitinerary-extractor`-Paket
# existiert in bookworm nicht). Das Paket liefert das Binary nach
# /usr/lib/x86_64-linux-gnu/libexec/kf5/kitinerary-extractor -- da KF5
# libexec absichtlich NICHT im PATH ist, setzen wir einen Symlink in
# /usr/local/bin damit ENTRYPOINT + Caller-Aufrufe wie gewohnt kurz bleiben.
# In trixie heisst das Paket `libkitinerary-bin` (KF6-Rename) -- bei
# Base-Image-Bump auf trixie hier mit anpassen.
RUN set -eux \
    && apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
        libkpimitinerary-bin \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && ln -s /usr/lib/x86_64-linux-gnu/libexec/kf5/kitinerary-extractor \
             /usr/local/bin/kitinerary-extractor \
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
