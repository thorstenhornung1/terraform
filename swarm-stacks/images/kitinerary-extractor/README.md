# kitinerary-extractor — Production Container Build

KDE itinerary-extractor CLI (LGPL) packaged as a minimal, hardened container.
Built by GitOps from this `images/` directory, pushed to `ghcr.io/thorstenhornung1/swarm-stacks/kitinerary-extractor`.

## What this is

A thin Debian-based container that wraps `kitinerary-extractor` (Debian package). Reads
EML/HTML/PDF travel documents from stdin, writes schema.org JSON-LD to stdout, then
exits. **No HTTP server, no daemon** — used as a one-shot subprocess by
consumers (currently: belegparser's travel-extraction LLM-fallback adapter).

## How consumers use it

```bash
# Hardened sandbox flags (consumer's responsibility):
docker run --rm -i \
  --network=none \
  --read-only \
  --memory=512m --cpus=1 --pids-limit=64 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  ghcr.io/thorstenhornung1/swarm-stacks/kitinerary-extractor:latest \
  < ticket.pdf > parsed.jsonld
```

The belegparser-Adapter (see `belegparser/extraction/kitinerary.py`) wraps this
automatically and picks the image from `BELEGPARSER_KITINERARY_IMAGE` env-var
(digest-pinned in production).

## Source of truth

The **canonical Dockerfile lives in this repo** (single source for production
builds). The belegparser repo at `thorstenhornung1/belegparser:docker/kitinerary/`
keeps a copy + `build.sh` for **local dev only** — that build helper is
explicitly NOT used for production.

If the belegparser-side Dockerfile changes (rare — it's just a Debian base +
single apt-package install), sync it into this directory and commit:

```bash
# From the swarm-stacks repo root:
curl -sf -H "Authorization: Bearer $GH_PAT" \
  -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/thorstenhornung1/belegparser/contents/docker/kitinerary/Dockerfile \
  > images/kitinerary-extractor/Dockerfile
git diff images/kitinerary-extractor/Dockerfile   # review the delta
```

## Build triggers (see `.github/workflows/build-kitinerary.yml`)

| Event | Why |
|---|---|
| Push to `main` changing `images/kitinerary-extractor/**` | Dockerfile-Update — sync from belegparser-Repo |
| Weekly schedule (Tuesday 05:00 UTC) | Pick up base `debian:bookworm-slim` updates (security CVEs) |
| Manual `workflow_dispatch` | Ad-hoc rebuild |

## Image tags

| Tag | Meaning |
|---|---|
| `latest` | Most recent successful build (rolling) |
| `<YYYYMMDD>` | Date stamp for traceability |
| `<sha-short>` | Short SHA of swarm-stacks commit that built it |

Consumers should pin by **digest** (`@sha256:...`), not tag, for
reproducible deploys. Get digest from `docker pull` output or:

```bash
docker buildx imagetools inspect \
  ghcr.io/thorstenhornung1/swarm-stacks/kitinerary-extractor:latest \
  --format '{{.Manifest.Digest}}'
```

## Refresh debian base digest

The Dockerfile pins `debian:bookworm-slim` by content digest. To refresh
(monthly recommended, or on Debian DSA notification):

```bash
# Get current upstream digest
docker buildx imagetools inspect debian:bookworm-slim --format '{{.Manifest.Digest}}'

# Update the FROM line in Dockerfile, commit, push → triggers rebuild
```

## Security notes

- Container is non-root (`useradd --system kitinerary` in Dockerfile)
- Built with `--no-install-recommends --no-install-suggests` (minimal attack surface)
- No persistent state — stdin → stdout, exits
- Consumer is expected to enforce egress-blocking + cap-drop at runtime
- Image is mounted **read-only** in production by consumer

## Related

- belegparser repo (Dockerfile source-of-truth for local dev): `thorstenhornung1/belegparser:docker/kitinerary/`
- belegparser README §7 (Deployment-Plan): documents the broader integration
