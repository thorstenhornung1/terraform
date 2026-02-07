# Container Image Management

Custom Docker images used by this Swarm cluster are built via GitHub Actions and hosted on GitHub Container Registry (GHCR).

## Images

| Image | Tag | Base | Purpose |
|-------|-----|------|---------|
| `ghcr.io/thorstenhornung1/swarm-stacks/patroni-postgres` | `16` | `postgres:16-alpine` | PostgreSQL 16 with Patroni HA |

## How It Works

```
Dockerfile change → push to main → GitHub Actions builds → pushes to ghcr.io
                                                         → Swarm nodes pull on deploy/restart
```

1. The `Dockerfile` lives in `stacks/infrastructure/postgres-ha/docker/`
2. On push to `main` (if docker files changed), GitHub Actions builds and pushes to GHCR
3. A weekly scheduled build (Monday 04:00 UTC) picks up base image security patches
4. The stack file references the GHCR image, so any Swarm node can pull it automatically

## Image Tags

Each build produces three tags:

| Tag | Example | Purpose |
|-----|---------|---------|
| `16` | `patroni-postgres:16` | Mutable "latest PG16" tag, used by the stack |
| `16-<sha>` | `patroni-postgres:16-abc1234` | Immutable, tied to a specific commit |
| `16-<date>` | `patroni-postgres:16-20260206` | Immutable, tied to a build date |

The stack file uses the `:16` tag so that nodes always pull the latest build. The SHA and date tags exist for auditing and rollback.

## Authentication

GHCR requires authentication to pull images, even from a public package. Each Swarm node must be logged in:

```bash
# On EVERY Swarm node (managers + workers):
echo "<GITHUB_PAT>" | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin
```

### Creating a GitHub Personal Access Token (PAT)

1. Go to https://github.com/settings/tokens?type=beta (Fine-grained tokens)
2. Click **Generate new token**
3. Set:
   - **Token name:** `swarm-ghcr-pull`
   - **Expiration:** 90 days (set a calendar reminder to rotate)
   - **Repository access:** Select `swarm-stacks`
   - **Permissions → Packages:** Read
4. Copy the token and run `docker login` on each node

### Automating Login via Ansible (Existing Nodes)

Authenticate all existing Swarm nodes in one command:

```bash
cd ansible/
ansible-playbook -i inventory.ini ghcr-login.yml -e "ghcr_token=<YOUR_PAT>"
```

This also pre-pulls the `patroni-postgres:16` image on each node as verification.

### Automatic Login via Terraform Cloud-Init (New Nodes)

New VMs provisioned via Terraform automatically authenticate to GHCR during cloud-init.
The PAT is stored in `terraform.tfvars` (gitignored) and passed to the cloud-init template:

```hcl
# terraform.tfvars
ghcr_pat = "ghp_xxxx"
```

No manual login needed for freshly provisioned nodes.

### Integration with prepare-infra-nodes.yml

The `prepare-infra-nodes.yml` playbook also configures GHCR login when the token is provided:

```bash
ansible-playbook -i inventory.ini prepare-infra-nodes.yml -e "ghcr_token=<YOUR_PAT>"
```

If no token is provided, the GHCR login steps are skipped (useful when cloud-init already handled it).

## Keeping Images Current

### Automatic Updates (Default)

The GitHub Actions workflow handles updates automatically:

- **Code changes:** Any push to `main` that modifies files in `stacks/infrastructure/postgres-ha/docker/` triggers a rebuild
- **Base image patches:** Weekly scheduled build (Monday 04:00 UTC) pulls the latest `postgres:16-alpine` and rebuilds

### Manual Rebuild

Trigger a rebuild without code changes:

1. Go to **Actions** → **Build patroni-postgres** → **Run workflow**
2. Select `main` branch → **Run workflow**

Or via CLI:

```bash
gh workflow run build-patroni-postgres.yml --repo thorstenhornung1/swarm-stacks
```

### Upgrading Patroni Version

1. Edit `stacks/infrastructure/postgres-ha/docker/Dockerfile`
2. Change the Patroni version pin:
   ```dockerfile
   # Before
   patroni[etcd3]==3.3.2
   # After
   patroni[etcd3]==3.4.0
   ```
3. Commit and push to `main`
4. GitHub Actions builds and pushes the new image
5. Redeploy the stack to pick up the new image:
   ```bash
   # On a Swarm manager:
   docker service update --force postgres_postgres-1
   docker service update --force postgres_postgres-2
   docker service update --force postgres_postgres-3
   ```

### Upgrading PostgreSQL Major Version (e.g., 16 → 17)

**This requires a database migration. Do NOT just change the tag.**

1. Plan the migration (pg_dumpall / pg_upgrade)
2. Create a new Dockerfile with `FROM postgres:17-alpine`
3. Update the workflow to produce `:17` tags
4. Update `postgres-ha-stack.yml` to reference `:17`
5. Follow the PostgreSQL major version upgrade procedure

## Manual Build & Push

If GitHub Actions is unavailable, build and push manually:

```bash
# 1. Clone the repo
git clone https://github.com/thorstenhornung1/swarm-stacks.git
cd swarm-stacks/stacks/infrastructure/postgres-ha/docker

# 2. Build
docker build -t ghcr.io/thorstenhornung1/swarm-stacks/patroni-postgres:16 .

# 3. Log in to GHCR
echo "$GITHUB_PAT" | docker login ghcr.io -u thorstenhornung1 --password-stdin

# 4. Push
docker push ghcr.io/thorstenhornung1/swarm-stacks/patroni-postgres:16
```

## Verifying the Image

### Check Available Tags

```bash
# List tags via GitHub CLI
gh api user/packages/container/swarm-stacks%2Fpatroni-postgres/versions \
  --jq '.[].metadata.container.tags[]'

# Or via the web UI
# https://github.com/thorstenhornung1/swarm-stacks/pkgs/container/swarm-stacks%2Fpatroni-postgres
```

### Check What's Running on Nodes

```bash
# On a Swarm manager:
docker service inspect postgres_postgres-1 --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'

# Check image digest on a specific node:
ssh docker-infra-1 "docker images ghcr.io/thorstenhornung1/swarm-stacks/patroni-postgres --digests"
```

### Force Pull Latest Image

```bash
# On each node:
docker pull ghcr.io/thorstenhornung1/swarm-stacks/patroni-postgres:16

# Then rolling-update the services:
docker service update --force postgres_postgres-1
docker service update --force postgres_postgres-2
docker service update --force postgres_postgres-3
```

## Rollback

If a new image causes issues, pin to a specific build:

```bash
# Find the last known-good tag
gh api user/packages/container/swarm-stacks%2Fpatroni-postgres/versions \
  --jq '.[] | "\(.metadata.container.tags | join(", ")) — \(.created_at)"' | head -10

# Update the service to a specific SHA tag
docker service update --image ghcr.io/thorstenhornung1/swarm-stacks/patroni-postgres:16-abc1234 \
  postgres_postgres-1
```

After stabilizing, update `postgres-ha-stack.yml` to pin the tag and commit.

## Troubleshooting

### "manifest unknown" or "denied" on Pull

```bash
# Verify login
docker login ghcr.io
# Re-authenticate if expired
echo "$GITHUB_PAT" | docker login ghcr.io -u <USERNAME> --password-stdin
```

### Image Not Updating After Push

Docker Swarm caches images. Force an update:

```bash
docker service update --force --image ghcr.io/thorstenhornung1/swarm-stacks/patroni-postgres:16 \
  postgres_postgres-1
```

### Build Fails in GitHub Actions

1. Check the **Actions** tab for error logs
2. Common issues:
   - `pip install` failure: Check Patroni version exists on PyPI
   - Base image unavailable: Check Docker Hub status
   - GHCR push denied: Verify `packages: write` permission in workflow

## Background: Why GHCR?

On 2026-02-02, `docker-infra-2` ran out of disk space. Docker pruned the locally-built `patroni-postgres:16` image to reclaim space, which caused the PostgreSQL replica to fail and unable to restart (no image to pull). See [terraform#1](https://github.com/thorstenhornung1/terraform/issues/1) for the full incident report.

Hosting the image in GHCR means:
- **No image loss** — images survive local Docker prune operations
- **Any node can pull** — no need to manually transfer images between nodes
- **Automatic rebuilds** — weekly builds pick up security patches from the base image
- **Audit trail** — every build is tagged with commit SHA and date
