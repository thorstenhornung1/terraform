# Known Issues & Bugs

## Active Issues

### BUG-005: External Secrets Operator v0.9.20 - Infisical Provider Bug
**Status:** 🟡 IN PROGRESS (Migrating to Infisical Operator)
**Severity:** CRITICAL
**Component:** External Secrets Operator
**Discovered:** 2025-12-09

**Symptoms:**
- ClusterSecretStore shows `Ready: True` (misleading status)
- ExternalSecrets using `data` array fail silently
- No Kubernetes secrets are created
- Blocks deployment of Gitea, Uptime Kuma

**Root Cause:**
ESO's Infisical provider expects nested JSON but Infisical stores flat key-value pairs.

**Resolution Strategy:**
Migrating to Infisical's native Kubernetes Operator (v0.10.13)
- ✅ Phase 1-3: Deployed Infisical Operator and InfisicalSecret CRDs
- ✅ Phase 4: Fixing Gitea deployment (SSL configuration issue)
- ⏳ Phase 5: 7-day validation period
- ⏳ Phase 6: ESO removal

---

### BUG-006: Traefik IngressRoute Host Match Syntax Error
**Status:** ✅ RESOLVED
**Severity:** MEDIUM
**Component:** Traefik IngressRoutes, Ansible Playbooks
**Discovered:** 2025-12-13 (KubeView Deployment)
**Resolved:** 2025-12-13

**Symptoms:**
- 404 Not Found when accessing service via HTTPS
- BasicAuth working (no 401 error)
- Request reaching Traefik but not routed to backend service
- Service and endpoints healthy

**Root Cause:**
IngressRoute created with incorrect Host match syntax using single quotes `'` instead of backticks `` ` ``.

**Incorrect:**
```yaml
match: "Host('k3s-status.hornung-bn.de')"  # WRONG - single quotes
```

**Correct:**
```yaml
match: "Host(`k3s-status.hornung-bn.de`)"  # CORRECT - backticks
```

**Solution:**
1. ✅ Patched IngressRoutes with correct backtick syntax
2. ✅ Updated deploy-kubeview.yml with correct syntax + comment
3. ✅ Added note to Traefik IngressRoute documentation

**Prevention:**
- Always use backticks for Traefik Host() match expressions
- Reference working IngressRoutes (uptime-kuma, infisical) as templates
- Added validation in CI/CD documentation

**Files Fixed:**
- `/Users/thorstenhornung/tmp/proxmox-test/deploy-kubeview.yml` (lines 318, 352)

---

### BUG-007: Missing Let's Encrypt Certificate in KubeView Deployment
**Status:** ✅ RESOLVED
**Severity:** MEDIUM
**Component:** cert-manager, KubeView Deployment
**Discovered:** 2025-12-13 (Post-deployment)
**Resolved:** 2025-12-13

**Symptoms:**
- Browser shows "net::ERR_CERT_AUTHORITY_INVALID"
- Certificate shows "TRAEFIK DEFAULT CERT" instead of Let's Encrypt
- Expires: 2026-12-13 (self-signed, 1 year)
- Other services (Uptime Kuma, Infisical, Gitea) have valid Let's Encrypt certificates

**Root Cause:**
Ansible playbook `deploy-kubeview.yml` did not include Certificate resource creation step. IngressRoute referenced `tls: {}` (empty TLS config) instead of specific certificate secret, causing Traefik to use its default self-signed certificate.

**Missing Phase:**
```yaml
# PHASE 5: Let's Encrypt Certificate (WAS MISSING)
- name: Create Let's Encrypt Certificate for KubeView
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: kubeview-tls
        namespace: monitoring
      spec:
        commonName: k3s-status.hornung-bn.de
        dnsNames:
          - k3s-status.hornung-bn.de
        issuerRef:
          kind: ClusterIssuer
          name: letsencrypt-prod
        secretName: kubeview-tls-secret
```

**Solution:**
1. ✅ Created Certificate resource manually (`kubectl apply`)
2. ✅ Updated IngressRoute TLS config to reference `kubeview-tls-secret`
3. ✅ Added Certificate creation as new Phase 5 in deploy-kubeview.yml
4. ✅ Added wait condition for certificate readiness (60 retries × 5s = 5 min timeout)
5. ✅ Updated IngressRoute TLS from `tls: {}` to `tls: {secretName: kubeview-tls-secret}`

**Prevention:**
- ✅ All future web service deployments MUST include Certificate resource
- ✅ Updated deployment template checklist in .claude/CLAUDE.md
- ✅ Added cert-manager validation to CI/CD pipeline documentation

**Pattern for All Web Services:**
```yaml
# Phase N: Certificate
# Phase N+1: Traefik Middlewares
# Phase N+2: IngressRoutes (referencing certificate secret in tls.secretName)
```

**Files Fixed:**
- `/Users/thorstenhornung/tmp/proxmox-test/deploy-kubeview.yml` (added Phase 5, lines 247-280)
- IngressRoute patched: `spec.tls.secretName: kubeview-tls-secret` (line 397)

**Certificate Status:**
```bash
kubectl get certificate -n monitoring kubeview-tls
# NAME           READY   SECRET                AGE
# kubeview-tls   True    kubeview-tls-secret   5m
```

---

## Resolved Issues

### BUG-001: Infisical Environment Slug Mismatch
**Status:** ✅ Resolved
**Severity:** High
**Discovered:** 2025-10-22 05:00 GMT
**Resolved:** 2025-10-22 05:15 GMT

**Symptoms:**
```
Error: Folder with path '/' in environment with slug 'production' not found
```

**Root Cause:**
ClusterSecretStore configured with `environmentSlug: production`, but Infisical project uses slug `prod`. The UI displays "Production" but the API slug is different.

**Solution:**
Updated ClusterSecretStore to use correct slug:
```yaml
spec:
  provider:
    infisical:
      secretsScope:
        environmentSlug: prod  # Changed from 'production'
```

**Lessons Learned:**
- Always verify environment slug in Infisical URL
- UI display names != API slugs
- Document actual slug values for future reference

**Prevention:**
- Added note in `.claude/project_knowledge.md`
- Documented in `docs/INFISICAL_TLS_DEPLOYMENT.md`
- Added comment in `clustersecretstore.yaml` manifest

---

### BUG-002: ExternalSecret Property Field Error
**Status:** ✅ Resolved
**Severity:** High
**Discovered:** 2025-10-22 05:30 GMT
**Resolved:** 2025-10-22 05:35 GMT

**Symptoms:**
```
Error: property value does not exist in secret cloudflare-api-token
```

**Root Cause:**
ExternalSecret configured with `property: value` field, but Infisical stores secrets as direct values, not nested JSON objects.

**Original Configuration (Wrong):**
```yaml
data:
- secretKey: api-token
  remoteRef:
    key: cloudflare-api-token
    property: value  # ❌ This is wrong for Infisical
```

**Fixed Configuration:**
```yaml
data:
- secretKey: api-token
  remoteRef:
    key: cloudflare-api-token  # ✅ No property field
```

**Solution:**
Removed `property` field from ExternalSecret:
```bash
kubectl patch externalsecret -n cert-manager cloudflare-dns-token --type=json \
  -p='[{"op": "remove", "path": "/spec/data/0/remoteRef/property"}]'
```

**Lessons Learned:**
- Infisical provider does not support `property` field
- Different secret backends have different data models
- AWS Secrets Manager uses `property`, Infisical does not

**Prevention:**
- Documented in ExternalSecret manifest with comment
- Added to troubleshooting section in TLS deployment guide
- Created example manifests without property field

---

### BUG-003: Machine Identity Missing Project Access
**Status:** ✅ Resolved
**Severity:** High
**Discovered:** 2025-10-22 04:45 GMT
**Resolved:** 2025-10-22 05:05 GMT

**Symptoms:**
```
ClusterSecretStore Status: InvalidProviderConfig
Error: Authentication failed
```

**Root Cause:**
Machine Identity `k8s-external-secrets` was created but not granted access to the project `traefik-certificates-bq-pt`.

**Solution:**
In Infisical UI:
1. Navigate to Project Settings → Machine Identities
2. Click "+ Add Identity"
3. Select: `k8s-external-secrets`
4. Role: Viewer
5. Environments: production (or all)
6. Save

**Verification:**
```bash
kubectl get clustersecretstore infisical-secret-store
# STATUS: Valid, READY: True
```

**Lessons Learned:**
- Creating Machine Identity is not enough
- Must explicitly grant per-project access
- Viewer role is sufficient for read-only access

**Prevention:**
- Added step-by-step instructions in deployment guide
- Screenshot in documentation would be helpful

---

### BUG-004: Gitea PostgreSQL SSL Configuration Missing
**Status:** ✅ Resolved
**Severity:** HIGH
**Component:** Gitea Deployment
**Discovered:** 2025-12-09
**Resolved:** 2025-12-09

**Symptoms:**
```
2025/12/09 10:34:16 cmd/migrate.go:40:runMigrate() [F] Failed to initialize ORM engine: pq: SSL required
```

**Root Cause Analysis:**

1. **Immediate Cause**: Gitea Helm chart missing explicit `SSL_MODE` parameter for PostgreSQL connection
2. **Technical Detail**: Go lib/pq driver defaults to `sslmode=prefer`, causing SSL verification failure
3. **Architecture Context**:
   - Crunchy PostgreSQL Operator requires SSL by default
   - PgBouncer acts as connection pool within cluster
   - Gitea connects to PgBouncer (not directly to PostgreSQL)

**Security Architecture (Research-Backed Solution):**

Multi-layer SSL strategy based on Crunchy PostgreSQL best practices:

```
┌─────────┐  SSL:DISABLED  ┌───────────┐  SSL:ENABLED   ┌────────────┐
│  Gitea  │──────────────►│ PgBouncer │──────────────►│ PostgreSQL │
└─────────┘   (Internal)   └───────────┘   (TLS 1.3)    └────────────┘
```

**Why This Architecture Works:**
1. **Client → PgBouncer (SSL disabled)**:
   - Both run in same Kubernetes cluster (secure network boundary)
   - No external network exposure
   - Minimal overhead for connection pooling
   - Follows Crunchy's recommended practice for internal connections

2. **PgBouncer → PostgreSQL (SSL enabled)**:
   - Crunchy Operator automatically configures TLS
   - Uses TLS 1.3 with certificate validation
   - Protects data at the database layer

**Solution:**
Updated `deploy-gitea.yml` (line 167):
```yaml
database:
  SSL_MODE: disable  # PgBouncer internal connection - SSL not required within cluster
```

**Testing:**
1. ✅ Updated playbook with SSL_MODE parameter
2. ✅ Gitea pod init container completed successfully
3. ✅ Database connection established
4. ✅ No SSL errors in logs

**Lessons Learned:**
1. All PostgreSQL-connected apps MUST specify `SSL_MODE` explicitly
2. Understand the connection path: App → PgBouncer → PostgreSQL
3. Different SSL requirements for different connection segments
4. Crunchy Operator handles PostgreSQL-side TLS automatically

**Prevention:**
- Added to Database Deployment Checklist: explicit SSL_MODE requirement
- Documented in `.claude/CLAUDE.md` under "Database Deployment Policy"
- Created template Helm values with SSL_MODE for future deployments

**References:**
- Crunchy PostgreSQL TLS: https://www.crunchydata.com/blog/set-up-tls-for-postgresql-in-kubernetes
- PgBouncer SSL Config: https://www.crunchydata.com/blog/deploy-tls-for-pgbouncer-in-kubernetes
- PostgreSQL libpq SSL: https://www.postgresql.org/docs/current/libpq-ssl.html

---

### BUG-005-HISTORICAL: Certificate Namespace Mismatch (Prevented)
**Status:** ✅ Prevented
**Severity:** Medium
**Discovered:** N/A (Design review)
**Prevented:** 2025-10-22 06:00 GMT

**Potential Issue:**
TLS secret must be in same namespace as IngressRoute. If certificate is in different namespace, Traefik cannot access it.

**Prevention:**
- Created certificate in `infisical` namespace (same as IngressRoute)
- Documented namespace requirement
- Added verification step in deployment guide

**Note:**
This was caught during design review, not encountered as actual bug.

---

## Common Pitfalls

### 1. Cloudflare API Token Permissions

**Issue:** Certificate challenges fail due to insufficient Cloudflare API token permissions

**Required Permissions:**
- Zone → DNS → Edit

**Verification:**
```bash
# Test token permissions via Cloudflare API
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer YOUR_TOKEN"
```

---

### 2. cert-manager Rate Limiting

**Issue:** Let's Encrypt rate limits exceeded (50 certs/domain/week)

**Prevention:**
- Use `letsencrypt-staging` for testing
- Switch to `letsencrypt-prod` only for final deployment
- Consolidate certificates where possible

**If Rate Limited:**
- Wait for rate limit window to reset (1 week)
- Use staging issuer for testing
- Consider wildcard certificates

---

### 3. DNS Propagation Delays

**Issue:** DNS01 challenge stuck in pending due to DNS propagation

**Normal Behavior:**
- DNS01 challenges take 1-3 minutes
- Don't panic if challenge is pending for 2 minutes

**Troubleshooting:**
```bash
# Check if TXT record is propagating
dig _acme-challenge.infisical.hornung-bn.de TXT +short

# Check challenge status
kubectl describe challenge -n infisical
```

**When to Worry:**
- Challenge pending for > 5 minutes
- DNS TXT record not visible after 5 minutes
- Challenge shows error in events

---

### 4. ExternalSecret Sync Delays

**Issue:** Secret changes in Infisical not immediately reflected in Kubernetes

**Expected Behavior:**
- Default sync interval: 1 hour
- Secret changes can take up to 1 hour to sync

**Force Immediate Sync:**
```bash
kubectl annotate externalsecret -n NAMESPACE SECRET_NAME \
  force-sync=$(date +%s) --overwrite
```

---

## Monitoring & Alerts

### Recommended Alerts

1. **Certificate Expiration**
   - Alert if certificate expires in < 14 days
   - cert-manager should renew at 30 days

2. **ExternalSecret Sync Failures**
   - Alert if ExternalSecret status != SecretSynced
   - Check ESO logs for errors

3. **ClusterSecretStore Unavailable**
   - Alert if ClusterSecretStore READY != True
   - Check Infisical service availability

4. **Challenge Failures**
   - Alert if cert-manager challenges fail
   - Check DNS provider API status

### Health Checks

```bash
# Check all critical components
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml

echo "=== ClusterIssuers ==="
kubectl get clusterissuer

echo "=== Certificates ==="
kubectl get certificate -A

echo "=== ClusterSecretStore ==="
kubectl get clustersecretstore

echo "=== ExternalSecrets ==="
kubectl get externalsecret -A

echo "=== Challenges (should be empty if all certs issued) ==="
kubectl get challenge -A
```

---

## Reporting New Issues

When reporting new issues:

1. **Create entry above in "Active Issues"**
2. **Include:**
   - Severity (Low/Medium/High/Critical)
   - Discovery date/time
   - Symptoms (error messages, logs)
   - Steps to reproduce
   - Impact (what's affected)

3. **When resolved:**
   - Move to "Resolved Issues"
   - Add resolution date
   - Document root cause and solution
   - Add lessons learned
   - Update prevention measures

---

**Last Updated:** 2025-10-22 08:45 GMT
**Next Review:** 2025-10-29
