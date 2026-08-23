# =============================================================================
# Open Archiver Reindex Tool — one-off job image
# =============================================================================
# Build (on a Swarm manager, from this directory):
#   docker build -t openarchiver-reindex:local .
#
# Run: see README.md ("Controlled execution"). The tool reaches pg-haproxy,
# openarchiver-meili, openarchiver-tika and s3-rgw over the swarm overlay
# networks, so it must be started as a Swarm SERVICE (one of the required
# overlays, openarchiver_default, is NOT attachable for plain `docker run`).
#
# Node 22-alpine matches the Open Archiver image runtime (node v22, Alpine).
# =============================================================================
FROM node:22-alpine

WORKDIR /app

# Install deps first for layer caching. Use npm ci if a lockfile is present,
# otherwise npm install (the tool has only 4 direct deps).
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev --no-audit --no-fund; \
    else npm install --omit=dev --no-audit --no-fund; fi

COPY src ./src

# Non-root for safety (read-only against DB/S3; only optional --mark-indexed writes).
USER node

ENTRYPOINT ["node", "src/reindex.mjs"]
# Default to the safest possible invocation; override the command to do real work.
CMD ["--dry-run", "--limit=20"]
