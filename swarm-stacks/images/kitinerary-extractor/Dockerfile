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

# Pin: multi-arch Index-Digest von debian:trixie-slim (abgerufen 2026-08-30).
# Refresh: docker buildx imagetools inspect debian:trixie-slim --format '{{.Manifest.Digest}}'
# Im GitOps wird dieser Pin periodisch (z.B. monatlich) refreshed.
# bookworm -> trixie (2026-08-30, belegparser e201eb0): kitinerary 22.12.3
# (KF5, Dez 2022) -> 24.12.3 (KF6) — zwei Jahre neuere Extraktor-Skripte
# fuer die Lodging-EML-Parser (booking.com/Hotels/DB-Layouts 2023/24).
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

# Reproduzierbares apt-install: keine recommends, keine suggests, keine cache.
# Trixie-Paket heisst `libkitinerary-bin` (KF6-Rename; verifiziert 2026-08-30
# gegen den trixie-Paketindex — in bookworm hiess es `libkpimitinerary-bin`).
# Das Paket liefert das Binary nach
# /usr/lib/x86_64-linux-gnu/libexec/kf6/kitinerary-extractor -- da das
# libexec absichtlich NICHT im PATH ist, setzen wir einen Symlink in
# /usr/local/bin damit ENTRYPOINT + Caller-Aufrufe wie gewohnt kurz bleiben.
RUN set -eux \
    && apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
        libkitinerary-bin \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && ln -s /usr/lib/x86_64-linux-gnu/libexec/kf6/kitinerary-extractor \
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
