# Gitea SSL Configuration Issue (BLOCKED)

**Status:** 🔴 BLOCKED - Needs Resolution
**Priority:** HIGH
**Created:** 2025-12-10
**Chart Version:** v12.3.0 (latest stable)

## Problem

Gitea Helm chart not applying PostgreSQL `SSL_MODE` configuration to app.ini file, causing init container to crash with:

```
pq: SSL required
```

## What Works

✅ Infisical Operator migration (Phases 1-3) COMPLETE
✅ InfisicalSecret resources syncing correctly
✅ All Gitea secrets available: gitea-db-secret, gitea-admin-secret, gitea-config-secret
✅ Chart upgraded to v12.3.0 (latest stable)
✅ Used Perplexity for research as requested

## What Doesn't Work

❌ SSL_MODE configuration not being applied to Gitea's app.ini
❌ Multiple configuration attempts failed:
- `SSL_MODE: "disable"` (quoted string)
- `SSL_MODE: disable` (unquoted)
- `sslmode: disable` (lowercase)

## Configuration Attempted

In `deploy-gitea.yml` line 167:

```yaml
gitea:
  config:
    database:
      DB_TYPE: postgres
      HOST: "{{ postgres_config.host }}:{{ postgres_config.port }}"
      NAME: "{{ postgres_config.database }}"
      USER: "{{ postgres_config.username }}"
      PASSWD:
        valueFrom:
          secretKeyRef:
            name: gitea-db-secret
            key: DB_PASSWORD
      SSL_MODE: "disable"  # ❌ NOT WORKING
```

## Additional Issue

Chart v12.3.0 includes Valkey (Redis alternative) dependency:
- Pods failing with ImagePullBackOff
- Not needed (using memory-based sessions)
- Needs to be disabled in values

## Research Done

1. ✅ Perplexity search: "Gitea Helm chart database SSL_MODE configuration"
2. ✅ Perplexity search: "gitea helm chart values.yaml gitea.config.database SSL_MODE"
3. ✅ Found latest chart version (12.3.0)
4. ✅ Confirmed `SSL_MODE: "disable"` is correct format per PostgreSQL standards

## Hypothesis

The Gitea Helm chart v12.x may have changed how it structures database configuration:
- Templates might not properly render `SSL_MODE` to app.ini
- May need different YAML structure (nested differently)
- Could require chart-specific parameter name

## Next Steps to Try

1. **Inspect Helm chart templates:**
   ```bash
   helm show values gitea-charts/gitea --version 12.3.0 > /tmp/gitea-v12-values.yaml
   helm pull gitea-charts/gitea --version 12.3.0 --untar
   # Check templates for database config rendering
   ```

2. **Try chart v11.x:**
   - May have simpler/different configuration structure
   - Fallback if v12.x is too complex

3. **Disable Valkey dependency:**
   ```yaml
   valkey-cluster:
     enabled: false
   ```

4. **Alternative SSL configuration paths to test:**
   ```yaml
   # Option A: Top-level database config
   database:
     sslmode: disable

   # Option B: Connection string approach
   database:
     DSN: "postgres://user:pass@host:5432/db?sslmode=disable"

   # Option C: Extra parameters
   gitea:
     config:
       database:
         EXTRA_PARAMS: "sslmode=disable"
   ```

5. **Check actual app.ini generated:**
   ```bash
   kubectl exec -n gitea <pod> -c gitea -- cat /data/gitea/conf/app.ini | grep -A 10 "\[database\]"
   ```

## Architecture Context

```
┌─────────┐  SSL:DISABLED  ┌───────────┐  SSL:ENABLED   ┌────────────┐
│  Gitea  │──────────────►│ PgBouncer │──────────────►│ PostgreSQL │
└─────────┘   (Internal)   └───────────┘   (TLS 1.3)    └────────────┘
```

**Why SSL should be disabled for Gitea→PgBouncer:**
- Both run in same K8s cluster (secure network boundary)
- No external network exposure
- PgBouncer→PostgreSQL connection uses TLS (handled by Crunchy Operator)
- Standard practice for internal cluster connections

## Related Files

- Playbook: `deploy-gitea.yml` (line 167)
- InfisicalSecrets: `manifests/infisical-operator/gitea-*.yaml` ✅ WORKING
- Logs: `/tmp/gitea-*.log`
- Bug tracking: `.claude/bugs.md` (BUG-004 documented but not fully resolved)

## Impact

**BLOCKS:**
- Gitea deployment
- Git repository hosting
- CI/CD integration

**DOES NOT BLOCK:**
- ESO → Infisical Operator migration (COMPLETE)
- Uptime Kuma deployment (can proceed independently)

## When to Resume

Resume this issue after:
1. Uptime Kuma is restored from backup
2. Have time for deep dive into Helm chart internals
3. Can test multiple chart versions systematically

## Agent Instructions

When resuming work on Gitea:

1. **START HERE:** Review this file completely
2. **Use Perplexity** to research Gitea Helm chart v12.x database configuration
3. **Check chart repository:** https://gitea.com/gitea/helm-chart
4. **Test with chart v11.x** if v12.x proves too complex
5. **Document all attempts** in `.claude/bugs.md`
6. **Use latest stable chart** as user requested

---

**Last Updated:** 2025-12-10
**Next Review:** When Uptime Kuma deployment complete
