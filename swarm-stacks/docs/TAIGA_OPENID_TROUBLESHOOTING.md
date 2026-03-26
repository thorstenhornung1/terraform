# Taiga OpenID/OIDC Troubleshooting

**Stack:** `stacks/apps/taiga/taiga-stack.yml`
**Custom Images:** `images/taiga-openid/back/` + `images/taiga-openid/front/`
**Identity Provider:** Authentik (https://authentik.hornung-bn.de)
**GHCR:** `ghcr.io/thorstenhornung1/swarm-stacks/taiga-back-openid:latest`

---

## Architecture Overview

Taiga uses a custom OpenID Connect plugin (`taiga_contrib_openid_auth`) to authenticate
users via Authentik. The plugin consists of:

| Component | File | Purpose |
|-----------|------|---------|
| `connector.py` | `images/taiga-openid/back/plugin/.../connector.py` | OAuth2 token exchange + userinfo fetch |
| `services.py` | `images/taiga-openid/back/plugin/.../services.py` | User registration + admin group sync |
| `config.py.snippet` | `images/taiga-openid/back/plugin/config.py.snippet` | Django settings injection |
| `openid-auth.js` | `images/taiga-openid/front/dist/openid-auth.js` | Frontend login button + redirect |

### OIDC Login Flow

```
1. User clicks "Login with OpenID" on Taiga frontend
2. Frontend redirects to Authentik authorization endpoint
3. User authenticates on Authentik
4. Authentik redirects back to Taiga with authorization code
5. Taiga backend exchanges code for access token (connector.py:login)
6. Taiga backend fetches user profile from Authentik (connector.py:get_user_profile)
7. User is created/updated in Taiga DB (services.py:openid_register)
8. Admin status synced from OIDC groups (services.py:openid_login_func)
```

---

## Known Issues & Fixes

### Issue 1: Missing `import logging` (2026-03-26)

**Symptom:** "Oompa Loompas" error page on OpenID login button click.
Backend returns HTTP 500 for any OIDC-related API call.

**Root Cause:** Commit `beaec5b` added `logger = logging.getLogger(__name__)` to
`connector.py` but forgot to add `import logging`. This causes a `NameError` at
module import time, which prevents the entire OIDC plugin from loading.

**Fix:** Add `import logging` after `import requests` in `connector.py` line 10.
Commit: `3591dff`.

**Verification:**
```bash
# Check backend logs for NameError
docker service logs taiga_taiga-back --tail 50 2>&1 | grep -i "NameError"

# Should return empty (no errors)
```

**Key Insight:** Module-level `NameError` in Python kills the entire module import,
not just the failing line. Since `services.py` does `from . import connector`, the
entire plugin becomes unavailable when `connector.py` fails to import.

### Issue 2: Wrong Authentik Admin Group Name (2026-03-25)

**Symptom:** OIDC login works, but admin users don't get `is_superuser`/`is_staff`
status synced from Authentik groups.

**Root Cause:** `OPENID_ADMIN_GROUP` was set to `"Admins"` but Authentik group is
named `"admin"` (lowercase, singular).

**Fix:** Set `OPENID_ADMIN_GROUP=admin` in Taiga environment. Commit: `beaec5b`.

### Issue 3: Docker Config Immutability

**Symptom:** After changing `taiga-gateway.conf` or other config files, `docker stack deploy`
reports success but the old config is still in use.

**Root Cause:** Docker Swarm configs are **immutable objects**. Once created, they cannot
be updated in-place.

**Workaround:**
```bash
# Full stack redeploy required for config changes
docker stack rm taiga
# Wait for all containers to stop
docker stack deploy -c taiga-stack.yml --resolve-image always taiga
```

---

## Deployment & Update

### Update Backend Image (after code changes)

```bash
# 1. Push changes to swarm-stacks repo
git push

# 2. GitHub Actions builds new image automatically (Build taiga-openid workflow)

# 3. Force pull new image on Swarm
docker service update --force \
  --image ghcr.io/thorstenhornung1/swarm-stacks/taiga-back-openid:latest \
  taiga_taiga-back

docker service update --force \
  --image ghcr.io/thorstenhornung1/swarm-stacks/taiga-back-openid:latest \
  taiga_taiga-async
```

### Full Stack Redeploy

```bash
docker stack deploy -c /opt/stacks/taiga/taiga-stack.yml \
  --resolve-image always taiga
```

---

## Debugging Checklist

When Taiga OIDC login fails:

1. **Check backend logs:**
   ```bash
   docker service logs taiga_taiga-back --tail 100 2>&1 | grep -iE "error|exception|openid"
   ```

2. **Verify plugin loads:**
   ```bash
   # Exec into backend container
   docker exec -it $(docker ps -q -f name=taiga_taiga-back) python -c \
     "from taiga_contrib_openid_auth import connector; print('OK')"
   ```

3. **Check environment variables:**
   ```bash
   docker exec -it $(docker ps -q -f name=taiga_taiga-back) env | grep -i openid
   ```
   Expected: `ENABLE_OPENID=true`, `OPENID_CLIENT_ID`, `OPENID_CLIENT_SECRET`,
   `OPENID_TOKEN_URL`, `OPENID_USER_URL`, `OPENID_SCOPE`.

4. **Test Authentik connectivity:**
   ```bash
   docker exec -it $(docker ps -q -f name=taiga_taiga-back) \
     python -c "import requests; r=requests.get('https://authentik.hornung-bn.de/.well-known/openid-configuration'); print(r.status_code)"
   ```

5. **Verify admin group sync:**
   Check `OPENID_ADMIN_GROUP` env var matches the exact Authentik group name
   (case-sensitive!). Currently: `admin`.

---

## Git History (Taiga-related commits)

| Commit | Description |
|--------|-------------|
| `3591dff` | fix: Add missing `import logging` — fixes OIDC login |
| `beaec5b` | fix: Use correct Authentik group name "admin" |
| `5df379c` | feat: OIDC group-based admin mapping |
| `57d4e0b` | fix: Case-insensitive ENABLE_OPENID check |
| `167a914` | fix: Add execute permission to frontend entrypoint |
| `136e20b` | fix: Backend healthcheck + Celery root compatibility |
| `6d7e45c` | feat: Build custom Taiga OIDC images for PG16 |
| `ae8ad7f` | feat: Add Taiga stack with Authentik SSO |
