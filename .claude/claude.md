# Claude Project Memory

## 🔴 CRITICAL DISASTER RECOVERY RULE (MANDATORY - 2025-12-27)

**⚠️ STRICT ENFORCEMENT - NEVER DESTROY DATA WITHOUT SNAPSHOT:**

### Pre-Destruction Snapshot Requirement

**BEFORE** any operation that could destroy data (terraform destroy, VM deletion, disk resize, etc.):

1. ✅ **ALWAYS create a Proxmox snapshot** of the VM/resource
2. ✅ **ALWAYS verify snapshot was created successfully**
3. ✅ **ALWAYS document what data exists on the resource**
4. ❌ **NEVER** proceed with destruction without snapshot

**Example workflow:**
```bash
# 1. Create snapshot FIRST
ssh root@pve01 "qm snapshot 4000 pre-destroy-$(date +%Y%m%d-%H%M%S)"

# 2. Verify snapshot exists
ssh root@pve01 "qm listsnapshot 4000"

# 3. ONLY THEN proceed with terraform destroy
terraform destroy -target=proxmox_virtual_environment_vm.bootstrap_host
```

**Why this rule exists:**
- Production VMs may contain critical secrets (e.g., Infisical SQLite database)
- Snapshots enable instant rollback if destruction was premature
- ZFS snapshots on tank storage are instant and space-efficient
- Violating this rule can cause catastrophic data loss

## 🔴 CRITICAL STORAGE RULES (MANDATORY - 2025-12-26, UPDATED 2025-12-27)

**⚠️ STRICT ENFORCEMENT - VIOLATIONS WILL BE REJECTED:**

### Allowed Storage Usage

1. **VM Disks:**
   - ✅ `local-lvm` - Default for ephemeral K3s cluster VMs
   - ✅ `tank` - ZFS pool for HA-critical VMs (bootstrap host, production databases)
   - ❌ **NEVER** use Synology storage (NFS/iSCSI/SMB) for VM disks

2. **Storage Selection Logic:**
   - **Bootstrap Host (VM 4001)**: `tank` (ZFS) - HA requirement, contains critical secrets
   - **K3s Masters/Workers**: `local-lvm` - Stateless, can be rebuilt
   - **Production databases with backups**: `tank` (ZFS) - Snapshot capability required

2. **Cloud-Init Snippets (ONLY):**
   - ✅ `local` - Snippets directory for cloud-init templates
   - ✅ `Diskstation-NFS` - MAY be used for cloud-init snippets ONLY
   - ⚠️ Cloud-init snippets can be unlinked after VM setup

3. **FORBIDDEN for VMs:**
   - ❌ Synology_SMB (CIFS) - causes deployment failures
   - ❌ Diskstation-NFS - ONLY for cloud-init, NOT for VM disks
   - ❌ Any iSCSI targets - causes orphaned LVM volumes
   - ❌ ZFS pools - reserved for other purposes

### Terraform Configuration Rules

**ALWAYS use this pattern:**
```hcl
disk {
  datastore_id = "local-lvm"  # ← MANDATORY, no variables allowed
  interface    = "scsi0"
  size         = 20
}

# Cloud-init OPTIONAL on Diskstation-NFS
initialization {
  user_data_file_id = proxmox_virtual_environment_file.cloud_init.id  # ← Can use NFS
}
```

**Variables.tf MUST specify:**
```hcl
variable "storage_backend" {
  description = "Storage backend per host"
  type        = map(string)
  default = {
    pve01 = "local-lvm"  # ← ONLY local-lvm
    pve02 = "local-lvm"
    pve03 = "local-lvm"
  }
}
```

### Why These Rules Exist

1. **Synology Storage Issues:**
   - SMB mounts go offline randomly
   - iSCSI creates orphaned LVM volumes
   - NFS shares require manual export configuration
   - Terraform fails when ANY Synology storage is offline

2. **Local-LVM Benefits:**
   - Always available (local to Proxmox node)
   - Fast performance (local SSD/NVMe)
   - No network dependencies
   - Clean destroy operations

3. **Cloud-Init Flexibility:**
   - Snippets can use NFS for centralized management
   - After VM boots, cloud-init is no longer needed
   - Can be unlinked without affecting running VM

## Project Context

This is an infrastructure automation project managing a production Kubernetes (K3s) cluster with:
- Proxmox VE cluster (3 nodes)
- K3s cluster (3 masters, 3 workers)
- **Bootstrap Host** for Infisical secrets management (NEW - 2025-12-14)
- Secrets management via External Secrets Operator
- Application deployments (PostgreSQL, Pi-hole, Gitea, etc.)

## 🆕 Bootstrap Host Architecture (NEW - 2025-12-14)

### Critical Design Change

**Previous Approach (Deprecated):**
- Infisical running INSIDE K3s cluster with PostgreSQL
- ❌ Circular dependency: K3s needs secrets → Infisical needs PostgreSQL → PostgreSQL needs secrets
- ❌ Complex disaster recovery
- ❌ Cannot rebuild cluster without manual intervention

**New Approach (Active):**
- **Bootstrap Host**: Standalone Docker host running Infisical OUTSIDE K3s cluster
- ✅ No circular dependencies
- ✅ K3s cluster can reference Infisical from day 1
- ✅ Simple disaster recovery (single SQLite file)
- ✅ Fully automated cluster rebuilds

### Bootstrap Host Specifications

**VM Details:**
- **Hostname:** infisical-bootstrap.hornung-bn.de
- **IP Address:** 192.168.4.20 (static, VLAN 4)
- **VM ID:** 4000
- **Resources:** 2 vCPU, 4GB RAM, 20GB disk
- **Node:** pve01

**Services Stack:**
- **Docker + Docker Compose** (automated installation via cloud-init)
- **Traefik v3.0** (reverse proxy with Let's Encrypt)
- **Infisical** (latest, SQLite backend)
- **Automated Backups** (daily at 2 AM, 30-day retention)

**Network Access:**
- **External:** https://infisical.hornung-bn.de (Let's Encrypt TLS)
- **Internal:** http://192.168.4.20:8080 (direct Infisical access)
- **Traefik Dashboard:** https://traefik.hornung-bn.de

### Why Bootstrap Host?

1. **Eliminates Circular Dependencies**
   - Infisical available before K3s deployment
   - No PostgreSQL required (SQLite)
   - K3s ESO can connect on first boot

2. **Disaster Recovery**
   - Single SQLite file backup
   - Bootstrap host survives K3s failures
   - Complete cluster rebuild from Infisical secrets

3. **Simplified Architecture**
   - 2 containers vs. complex in-cluster deployment
   - 4GB RAM vs. 16GB+ (with PostgreSQL cluster)
   - Independent upgrade cycles

4. **Production Ready**
   - HTTPS with Let's Encrypt (automatic renewal)
   - Daily automated backups
   - Simple monitoring and maintenance

### Deployment Files

- **Terraform:** `bootstrap-host.tf` (VM definition)
- **Variables:** `variables.tf` (bootstrap_host_* variables)
- **Cloud-Init:** `terraform/bootstrap-host/cloud-init-docker-infisical.yml`
- **Documentation:** `docs/BOOTSTRAP_HOST_ARCHITECTURE.md` (comprehensive guide)
- **Deployment Order:** `README-CLUSTER-DEPLOYMENT-ORDER.md` (updated for bootstrap-first)

### ⚠️ IMPORTANT: New Deployment Order

```
1. Deploy Bootstrap Host (terraform apply -target=bootstrap_host)
2. Configure Infisical secrets (Web UI)
3. Deploy K3s cluster (can reference all secrets from Infisical)
4. Deploy External Secrets Operator
5. Deploy applications (secrets auto-synced)
```

See: `docs/BOOTSTRAP_HOST_ARCHITECTURE.md` for complete instructions.

### ⚠️ Bootstrap Host Cloud-Init Issues (FIXED - 2025-12-26)

**Critical bugs discovered in cloud-init template prevented automated deployment:**

#### Bug 1: Wrong Docker Repository (Debian instead of Ubuntu)
**Status:** ✅ FIXED
**GitHub Issue:** [#29](https://github.com/thorstenhornung1/k3s-proxmox-ansible/issues/29)
**File:** `terraform/bootstrap-host/cloud-init-docker-infisical.yml` lines 532-534

**Problem:**
- Cloud-init used Debian Docker repository URLs on Ubuntu 24.04 system
- Docker installation failed silently with no error messages
- Infisical systemd service failed (exit code 203/EXEC)
- Cloud-init reported "done" but services were non-functional

**Fix Applied:**
Changed repository URLs from `/linux/debian` to `/linux/ubuntu`:
```yaml
# BEFORE (BROKEN):
- curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
- echo "deb ... https://download.docker.com/linux/debian ..."

# AFTER (FIXED):
- curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
- echo "deb ... https://download.docker.com/linux/ubuntu ..."
```

#### Bug 2: APT Proxy DNS Resolution Failure
**Status:** ✅ FIXED
**GitHub Issue:** [#29](https://github.com/thorstenhornung1/k3s-proxmox-ansible/issues/29)
**Files:**
- `terraform/bootstrap-host/cloud-init-docker-infisical.yml` lines 34-41
- `variables.tf` lines 115-119

**Problem:**
- APT proxy configured to `apt-cacher.hornung-bn.de:3142`
- DNS resolution failed from bootstrap host during cloud-init
- Only single DNS server configured (192.168.2.4)
- Local DNS entries not accessible from VLAN 4

**Root Cause:**
- Insufficient DNS server redundancy
- Missing Pi-hole cluster DNS servers from VLAN 4

**Fix Applied:**
Added Pi-hole cluster DNS servers to variables.tf for proper local DNS resolution:
```hcl
variable "dns_servers" {
  description = "DNS servers (Pi-hole cluster for local DNS resolution)"
  type        = list(string)
  default     = ["192.168.2.4", "192.168.4.5", "192.168.4.6"]  # Primary + VLAN 4 cluster
}
```

APT proxy re-enabled in cloud-init with updated documentation:
```yaml
# APT Proxy Configuration
# Uses apt-cacher.hornung-bn.de (requires local DNS resolution via Pi-hole)
# DNS servers configured via Terraform: 192.168.2.4, 192.168.4.5, 192.168.4.6
- path: /etc/apt/apt.conf.d/01proxy
  content: |
    Acquire::http::Proxy "http://apt-cacher.hornung-bn.de:3142";
```

**Result:** APT cacher now works with proper DNS resolution from Pi-hole cluster

#### Production Workaround (Already Applied - No Longer Needed)

Bootstrap host (192.168.4.20) was manually recovered during debugging:
1. SSH to bootstrap host: `ssh -i ~/.ssh/id_rsa ansible@192.168.4.20`
2. Remove broken APT proxy: `sudo rm -f /etc/apt/apt.conf.d/01proxy`
3. Install Docker from correct Ubuntu repository
4. Run secret generation: `/usr/local/bin/generate-infisical-secrets.sh`
5. Verify services running: `docker ps`

**Result:** All services operational (Traefik, Infisical, Promtail)

**Note:** This manual workaround is no longer needed - automated deployment now works with fixed cloud-init

#### CI/CD Impact & Compliance

**Before Fix:**
- ❌ Automated deployment broken
- ❌ Manual intervention required
- ❌ Non-obvious failure (cloud-init reports success)
- ❌ APT operations slow (direct internet downloads)

**After Fix:**
- ✅ Fully automated deployment works
- ✅ No manual intervention needed
- ✅ CI/CD compliance restored
- ✅ APT cacher operational (faster package installation)
- ✅ Local DNS resolution via Pi-hole cluster (192.168.2.4, 192.168.4.5, 192.168.4.6)
- ✅ Docker installed from correct Ubuntu repositories

#### Testing Checklist

Before declaring bootstrap host deployment production-ready:
- [ ] Destroy current bootstrap host VM (ID 4000)
- [ ] Re-deploy via Terraform with fixed cloud-init
- [ ] Verify Docker installs automatically from Ubuntu repo
- [ ] Verify Infisical stack starts without intervention
- [ ] Verify HTTPS certificates obtained via Let's Encrypt
- [ ] Verify no manual steps required

## ⚠️ STRICT CI/CD RULES (Updated: 2025-11-29)

### Mandatory Requirements

**🔴 CRITICAL: ALL deployments MUST follow these rules:**

1. **No Manual Deployments**
   - ❌ NEVER deploy services manually with kubectl apply
   - ✅ ALWAYS use Ansible playbooks or deploy-stack.sh
   - ✅ ALL deployments must include complete resource definitions (Deployment, Service, IngressRoute)

2. **Playbook Structure**
   - ❌ NEVER use `import_playbook` within `tasks:` block
   - ✅ Use shell scripts to orchestrate multiple playbooks
   - ✅ Each playbook must be self-contained and idempotent

3. **Pre-Deployment Validation**
   ```bash
   # ALWAYS run before ANY deployment:
   make ci-validate           # Lint + syntax check
   make check-broken-playbooks  # Check for deprecated files
   ```

4. **Deployment Order (STRICT)**
   ```
   1. External Secrets Operator
   2. PostgreSQL Backup Configuration
   3. Longhorn Storage
   4. Applications (Gitea, Uptime Kuma, etc.)
   ```

5. **IngressRoute Requirements**
   - ✅ EVERY web service MUST have HTTP → HTTPS redirect
   - ✅ EVERY web service MUST have TLS configuration
   - ✅ IngressRoutes MUST be deployed with the service, not separately
   - ⚠️ **CRITICAL:** Use backticks for Host match: ``Host(`domain.com`)`` NOT `Host('domain.com')`

6. **Let's Encrypt Certificate Requirements (NEW - 2025-12-13)**
   - ✅ EVERY web service MUST have a Certificate resource (cert-manager)
   - ✅ Certificate MUST be created BEFORE IngressRoute
   - ✅ IngressRoute MUST reference certificate secret: `tls.secretName: service-tls-secret`
   - ❌ NEVER use empty TLS config `tls: {}` - this uses Traefik default self-signed cert
   - ✅ Use ClusterIssuer `letsencrypt-prod` for production
   - ✅ Use ClusterIssuer `letsencrypt-staging` for testing
   - ✅ Wait for certificate to be Ready before proceeding

7. **Linting is MANDATORY**
   ```bash
   make lint-yaml      # Before committing YAML
   make lint-ansible   # Before committing playbooks
   make lint-shell     # Before committing scripts
   make test-syntax    # Before running playbooks
   ```

8. **File Naming Convention**
   - ❌ Broken playbooks: `*.yml.broken` (DO NOT USE)
   - ❌ Deprecated playbooks: `*.yml.deprecated` (DO NOT USE)
   - ✅ Active playbooks: `deploy-*.yml`, `*.yml`

### Traefik IngressRoute Patterns (CRITICAL - 2025-12-13)

**Mandatory Pattern for All Web Services:**
```yaml
# Phase N: Let's Encrypt Certificate
- name: Create Let's Encrypt Certificate
  kubernetes.core.k8s:
    definition:
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: service-tls
        namespace: namespace
      spec:
        commonName: service.domain.com
        dnsNames:
          - service.domain.com
        issuerRef:
          kind: ClusterIssuer
          name: letsencrypt-prod
        secretName: service-tls-secret

# Phase N+1: Wait for Certificate
- name: Wait for certificate readiness
  kubernetes.core.k8s_info:
    api_version: cert-manager.io/v1
    kind: Certificate
    name: service-tls
    namespace: namespace
  register: cert_status
  until: (cert_status.resources[0].status.conditions | selectattr('type', 'equalto', 'Ready') | map(attribute='status') | first) == 'True'
  retries: 60
  delay: 5

# Phase N+2: Traefik Middlewares
- name: Create redirect-https Middleware
  kubernetes.core.k8s:
    definition:
      apiVersion: traefik.io/v1alpha1
      kind: Middleware
      metadata:
        name: redirect-https
        namespace: namespace
      spec:
        redirectScheme:
          scheme: https
          permanent: true

# Phase N+3: HTTP IngressRoute (Redirect)
- name: Create HTTP IngressRoute
  kubernetes.core.k8s:
    definition:
      apiVersion: traefik.io/v1alpha1
      kind: IngressRoute
      metadata:
        name: service-http
        namespace: namespace
      spec:
        entryPoints:
          - web
        routes:
          - match: "Host(`service.domain.com`)"  # ⚠️ BACKTICKS REQUIRED
            kind: Rule
            middlewares:
              - name: redirect-https
            services:
              - name: service
                port: 8000

# Phase N+4: HTTPS IngressRoute (TLS)
- name: Create HTTPS IngressRoute
  kubernetes.core.k8s:
    definition:
      apiVersion: traefik.io/v1alpha1
      kind: IngressRoute
      metadata:
        name: service-https
        namespace: namespace
      spec:
        entryPoints:
          - websecure
        routes:
          - match: "Host(`service.domain.com`)"  # ⚠️ BACKTICKS REQUIRED
            kind: Rule
            services:
              - name: service
                port: 8000
        tls:
          secretName: service-tls-secret  # ⚠️ MUST REFERENCE CERTIFICATE SECRET
```

**Common Mistakes to Avoid:**
1. ❌ `Host('domain.com')` - Wrong! Use backticks `` ` `` not single quotes `'`
2. ❌ `tls: {}` - Wrong! Always specify `secretName`
3. ❌ Creating IngressRoute before Certificate - Wrong! Certificate must be Ready first
4. ❌ Using `traefik.containo.us` API - Use `traefik.io/v1alpha1`

### Deployment Script Usage

**Correct way to deploy complete stack:**
```bash
./deploy-stack.sh
```

**NOT via deploy-complete-stack.yml** (broken - uses import_playbook in tasks)

### Common Anti-Patterns (DO NOT DO)

❌ **Anti-Pattern 1: Manual kubectl apply**
```bash
kubectl apply -f some-manifest.yaml  # WRONG
```

❌ **Anti-Pattern 2: Incomplete deployments**
```bash
# Only deploying Deployment+Service, forgetting IngressRoute
# This causes "Service Unavailable" errors
```

❌ **Anti-Pattern 3: Using broken playbooks**
```bash
ansible-playbook deploy-complete-stack.yml  # BROKEN - will fail
```

### Correct Patterns (DO THIS)

✅ **Pattern 1: Use orchestration script**
```bash
./deploy-stack.sh  # Handles all dependencies
```

✅ **Pattern 2: Individual playbook with full validation**
```bash
make ci-validate
ansible-playbook -i inventory-local.ini deploy-uptime-kuma.yml
```

✅ **Pattern 3: Verify deployment includes all resources**
```yaml
# Playbook must include:
- Deployment/StatefulSet
- Service
- IngressRoute (HTTP + HTTPS)
- Middleware (redirect-https)
```

### Agent Instructions for Claude

When asked to deploy or modify infrastructure:

1. **ALWAYS check for existing playbooks first**
2. **NEVER create kubectl apply commands**
3. **ALWAYS validate with `make ci-validate` before suggesting deployment**
4. **ALWAYS include IngressRoutes with web services**
5. **ALWAYS check deployment logs for errors**
6. **NEVER suggest using `*.broken` or `*.deprecated` files**

## Current State (Last Updated: 2025-11-29)

### Infrastructure
- **K3s Cluster:** Running in production, 6 nodes (3 masters, 3 workers)
- **Infisical:** Deployed with HTTPS/TLS (https://infisical.hornung-bn.de)
- **PostgreSQL:** Production deployment with PgBouncer + automated backups
- **PostgreSQL Backup System:** ✅ Multi-tier automated backups on NFS (Daily, Weekly, Hourly)
- **cert-manager:** Installed, managing Let's Encrypt certificates
- **External Secrets Operator:** Syncing secrets from Infisical
- **Traefik:** Ingress controller with TLS termination
- **NFS Subdir External Provisioner:** ✅ Deployed for dynamic NFS volume provisioning (v4.0.18)
- **Synology CSI Driver:** Partially operational (iSCSI only, NFS replaced by NFS Subdir Provisioner)
- **KubeView:** ✅ Cluster visualization deployed (https://k3s-status.hornung-bn.de) - v2.1.1

### Secrets Management (Updated: 2025-11-12)
- **Universal Auth Identity:** `06394ac4-c015-4468-87a6-235a3cb6c59a`
- **Access Token TTL:** 30 days (2592000 seconds)
- **Infisical Projects:**
  - `k3s-production` - Application secrets
  - `k3s-storage` - Storage secrets (Longhorn, Synology)
  - `k3s-storage-u-m-hd` - Additional storage secrets
  - `traefik-certificates-bq-pt` - Networking secrets
- **Secret Paths Configured:**
  - ✅ `/gitea/database` - Gitea PostgreSQL credentials (k3s-production)
  - ✅ `/gitea/admin` - Gitea admin account (k3s-production)
  - ✅ `/gitea/config` - Gitea application secrets (k3s-production)
  - ✅ `/gitea/smtp` - Gitea email configuration (k3s-production)
  - ✅ `/uptimekuma/config` - Uptime Kuma settings (k3s-production)
  - ✅ `/uptimekuma/notifications` - Notification credentials (k3s-production)
  - ✅ `/storage/longhorn-s3` - Longhorn S3 backup (k3s-storage or k3s-storage-u-m-hd)
  - ✅ `/storage/synology-csi` - Synology CSI credentials (k3s-storage or k3s-storage-u-m-hd)
  - ⏳ `/networking/cloudflare` - Cloudflare DNS API (traefik-certificates-bq-pt)
  - ⏳ `/networking/traefik-dashboard` - Traefik dashboard auth (traefik-certificates-bq-pt)

### Recent Deployments

#### KubeView Cluster Visualization (2025-12-13)
**Objective:** Deploy web-based Kubernetes cluster visualization and monitoring tool

**Problem Solved:**
- Need for visual cluster topology and resource relationships
- Quick access to pod logs without kubectl
- Real-time cluster monitoring for operations team
- Intuitive interface for troubleshooting

**Completed:**
1. ✅ Deployed KubeView v2.1.1 via Helm Chart v2.0.5
2. ✅ Configured BasicAuth via Traefik middleware (admin user)
3. ✅ Set up HTTPS access via Traefik IngressRoute
4. ✅ Implemented HTTP → HTTPS redirect (308 Permanent)
5. ✅ Created read-only RBAC (ClusterRole with get/list/watch only)
6. ✅ Secured container (non-root, ReadOnlyRootFS, dropped capabilities)
7. ✅ Configured MetalLB LoadBalancer (192.168.4.102)
8. ✅ Created comprehensive documentation

**Result:** Production-ready cluster visualization at https://k3s-status.hornung-bn.de with secure read-only access

**Deployment Files:**
- `deploy-kubeview.yml` - Ansible playbook (7-phase deployment)
- `vault/secrets.yml` - Admin password (kubeview_config section)
- `docs/KUBEVIEW_DEPLOYMENT.md` - Comprehensive deployment guide
- `KUBEVIEW_QUICK_REFERENCE.md` - Day-to-day operations reference

**Security Notes:**
- ⚠️ Pod logs enabled (may contain sensitive data) - protected by BasicAuth
- ✅ Read-only RBAC (no create/update/delete permissions)
- ✅ Secret names visible (values hidden)
- ✅ All namespaces visible (including system namespaces)

#### NFS Subdir External Provisioner (2025-11-16)
**Objective:** Deploy dynamic NFS volume provisioning as alternative to Synology CSI Driver

**Problem Solved:**
- Synology CSI Driver creates NFS shares but doesn't automatically export them
- Manual share configuration required for each new volume
- Not suitable for automated backup workflows

**Completed:**
1. ✅ Deployed nfs-subdir-external-provisioner (v4.0.18) via Helm
2. ✅ Configured to use existing Synology NFS share: `192.168.2.3:/volume1/k8s-storage`
3. ✅ Created `nfs-storage` StorageClass with NFSv4.1 and optimized mount options
4. ✅ Migrated PostgreSQL backup PVCs from Synology CSI to nfs-storage
5. ✅ Verified successful backup to NFS (154K compressed dump with checksums)
6. ✅ Validated file ownership and permissions (UID 1024 via "Map all users to admin")

**Result:** Fully automated NFS volume provisioning working for PostgreSQL backups without manual Synology configuration

**Deployment Files:**
- `manifests/storage/nfs-provisioner-values.yaml` - Helm values
- `deploy-nfs-provisioner.yml` - Ansible playbook (optional)

#### PostgreSQL Backup System (2025-11-14, Updated 2025-11-16)
**Objective:** Automated multi-tier backup system for PostgreSQL databases

**Completed:**
1. ✅ Created 3-tier backup strategy (Daily, Weekly, Hourly)
2. ✅ Migrated to Synology NFS storage via nfs-subdir-provisioner
3. ✅ Fixed volume permissions with initContainers
4. ✅ Implemented pg_dump with custom format + gzip compression
5. ✅ Added automatic cleanup based on retention policies
6. ✅ Verified successful backup with checksum validation
7. ✅ Documented complete backup and restore procedures

**Result:** Production-ready automated backup system with 14-day daily, 90-day weekly, and 48-hour hourly retention on NFS.

#### Synology CSI Driver (2025-11-01)
**Objective:** Deploy Tier 2 (iSCSI) and Tier 3 (NFS) storage from Synology NAS

**Completed:**
1. ✅ Fixed host mismatch between StorageClass parameters and Secret
2. ✅ Deployed Synology CSI Controller and Node components
3. ✅ Created StorageClasses: `synology-iscsi` (Tier 2), `synology-nfs` (Tier 3)
4. ✅ Integrated with Infisical for credentials management
5. ✅ Verified volume provisioning (iSCSI: 17s, NFS: 13s)
6. ✅ Documented deployment in `docs/SYNOLOGY_CSI_DEPLOYMENT_SUCCESS.md`

**Result:** Storage Tiers 2 & 3 operational for bulk/shared storage

#### TLS/HTTPS for Infisical (2025-10-22)
**Objective:** Implement TLS/HTTPS security for Infisical as a CI/CD operation

**Completed:**
1. ✅ Configured Let's Encrypt ClusterIssuers (prod + staging)
2. ✅ Issued TLS certificate for infisical.hornung-bn.de
3. ✅ Configured Traefik IngressRoutes with HTTPS
4. ✅ Set up HTTP → HTTPS redirect (308 Permanent)
5. ✅ Integrated External Secrets Operator with Infisical
6. ✅ Synced Cloudflare API token from Infisical to Kubernetes
7. ✅ Documented entire deployment process

**Result:** Infisical now running with production-grade HTTPS/TLS

### Active Configuration

**Infisical:**
- URL: https://infisical.hornung-bn.de ⭐ HTTPS with self-signed cert
- Traefik IP: 192.168.4.100 (MetalLB LoadBalancer)
- TLS: Self-signed certificate (1 year, renewable)
- IngressRoutes:
  - HTTP (port 80) → HTTPS redirect (308)
  - HTTPS (port 443) → TLS termination
- Project Slugs:
  - `k3s-production` - Application secrets (Gitea, Uptime Kuma)
  - `k3s-storage` - Storage secrets (Longhorn, Synology)
  - `k3s-storage-u-m-hd` - Additional storage secrets
  - `traefik-certificates-bq-pt` - Networking/Traefik secrets
- Environment Slug: `prod` (⚠️ not `production`)
- Machine Identity: Universal Auth
  - Client ID: `06394ac4-c015-4468-87a6-235a3cb6c59a`
  - Client Secret: `0b266166252b6110dbb1f2a667b315e95935b4fb42fdeede3a646aed410fc8d3`
  - Token TTL: 30 days
  - Trusted IPs: `0.0.0.0/0, ::/0` (all IPs - consider restricting in production)

**cert-manager:**
- ClusterIssuers: `letsencrypt-prod`, `letsencrypt-staging`
- DNS01 Challenge: Cloudflare
- Auto-renewal: Enabled (30 days before expiration)

**External Secrets Operator:**
- ClusterSecretStore: `infisical-secret-store` (READY)
- Sync interval: 1 hour
- Syncing from: `http://infisical.infisical.svc.cluster.local:8080`

## Important Secrets

### Location of Credentials

1. **Ansible Vault Password:** `.vault_pass.txt` (gitignored)
2. **Infisical Machine Identity:**
   - Kubernetes Secret: `universal-auth-credentials` (external-secrets-system namespace)
   - Fields: `clientId`, `clientSecret`
3. **Kubeconfig:** `/tmp/k3s-kubeconfig-production.yaml`

### Critical Configuration Values

**Infisical Environment Slug:** `prod` (not `production`)
- This is a common gotcha - the UI shows "Production" but the slug is "prod"

**ClusterSecretStore API URL:** `http://infisical.infisical.svc.cluster.local:8080`
- Internal cluster communication uses HTTP
- External access uses HTTPS via Traefik

**ExternalSecret Mapping:**
- ⚠️ Do NOT use `property: value` field with Infisical
- Infisical stores values directly, not as nested JSON

**Synology CSI Configuration:**
- StorageClass `dsm` parameter MUST match Secret `host` value exactly
- Currently using: `diskstation.hornung-bn.de`
- Credentials synced from Infisical via `synology-csi-credentials-default` ExternalSecret
- ClusterSecretStore: `infisical-storage-store`

## Common Operations

### View Ansible Vault Secrets
```bash
ansible-vault view vault/secrets.yml --vault-password-file .vault_pass.txt
```

### Deploy/Update Infisical
```bash
ANSIBLE_CONFIG=.ansible.cfg ansible-playbook \
  -i inventory-local.ini \
  deploy-infisical-simple.yml
```

### Force Secret Sync from Infisical
```bash
kubectl annotate externalsecret -n NAMESPACE SECRET_NAME \
  force-sync=$(date +%s) --overwrite
```

### Check TLS Certificate Status
```bash
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml
kubectl get certificate -n infisical
kubectl describe certificate -n infisical infisical-tls
```

### PostgreSQL Backup Operations

**Trigger Manual Backup:**
```bash
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml
kubectl create job backup-manual --from=cronjob/postgresql-backup-daily -n databases
kubectl logs -n databases -l job-name=backup-manual -f
```

**Check Backup Status:**
```bash
kubectl get cronjobs -n databases
kubectl get jobs -n databases | grep backup
kubectl get pvc -n databases | grep backup
```

**Verify Backup Files:**
```bash
# List backups
kubectl exec -n databases <backup-pod> -- ls -lh /backup/

# Check checksum
kubectl exec -n databases <backup-pod> -- cat /backup/postgresql_daily_*.sha256
```

**Restore from Backup:**
```bash
# Get backup file
kubectl exec -n databases <backup-pod> -- ls -lh /backup/

# Restore database
kubectl exec -n databases <backup-pod> -- bash -c "
  gunzip -c /backup/postgresql_daily_YYYYMMDD_HHMMSS.dump.gz | \
  pg_restore -h infisical-pg-primary.databases.svc.cluster.local \
    -U infisical -d infisical --clean --if-exists
"
```

## Documentation Map

- **Main Knowledge Base:** `.claude/project_knowledge.md`
- **PostgreSQL HA Security:** `docs/POSTGRES_HA_SECURITY.md` ⭐ NEW (2026-01-30)
- **KubeView Deployment:** `docs/KUBEVIEW_DEPLOYMENT.md` (2025-12-13)
- **KubeView Quick Reference:** `KUBEVIEW_QUICK_REFERENCE.md` (2025-12-13)
- **Infisical TLS Deployment:** `docs/INFISICAL_TLS_DEPLOYMENT.md` (2025-12-05)
- **Infisical Recovery Guide:** `docs/INFISICAL_RESTORE_GUIDE.md` (2025-12-05)
- **PostgreSQL Backup System:** `docs/POSTGRESQL_BACKUP_SYSTEM.md` (2025-11-14)
- **Database Deployment Checklist:** `docs/DATABASE_DEPLOYMENT_CHECKLIST.md` (2025-11-14)
- **Infisical Secrets Reference:** `docs/INFISICAL_SECRETS_REFERENCE.md`
- **Synology CSI Deployment:** `docs/SYNOLOGY_CSI_DEPLOYMENT_SUCCESS.md`
- **Storage Tiers:** `docs/STORAGE_TIERS.md`
- **Progress Tracking:** `.claude/progress.md`
- **Architecture Decisions:** `.claude/decisions.md`
- **Known Issues:** `.claude/bugs.md`
- **Secrets Workflow:** `SECRETS_WORKFLOW.md`
- **Deployment Guides:** Various `*_DEPLOYMENT*.md` files in root

## Database Deployment Policy

**⚠️ IMPORTANT:** All PostgreSQL deployments MUST include backup configuration. Never deploy a database without backups.

### Mandatory Requirements

1. **Backup System:** Configure automated backups immediately after database deployment
2. **Storage:** Use Synology iSCSI (Tier 2) for long-term backup retention
3. **Retention:** Minimum 14 days for daily backups, 90 days for weekly
4. **Verification:** Test backup and restore before declaring production-ready
5. **Documentation:** Document database-specific restore procedures

### Checklist for New Database Deployments

See `docs/DATABASE_DEPLOYMENT_CHECKLIST.md` for complete checklist.

Quick checklist:
- [ ] PostgreSQL database deployed with Crunchy Operator
- [ ] Database user added to PostgresCluster CR with CREATEDB rights
- [ ] Backup CronJobs configured (Daily, Weekly, Hourly)
- [ ] PVCs created on Synology iSCSI storage
- [ ] Manual backup test successful
- [ ] Restore procedure tested
- [ ] Backup monitoring/alerting configured
- [ ] Documentation updated

### Adding a New Database to PostgresCluster

```yaml
# Edit PostgresCluster CR
kubectl edit postgrescluster infisical-pg -n databases

# Add new user under spec.users:
users:
  - name: myapp
    databases: ["myapp"]
    options: "CREATEDB"
```

The Crunchy Operator will automatically:
- Create the database
- Create the user with specified permissions
- Generate Kubernetes secret: `<cluster>-pguser-<username>`
- Include database in existing backup jobs (no changes needed)

## Key Learnings

### Cluster Rebuild & CI/CD (2025-12-06)
1. Always update playbooks for idempotency - use `failed_when: false` for operations that may already exist
2. ESO → Infisical requires HTTP internal endpoint to avoid self-signed cert issues
3. ClusterSecretStore shows "Ready" but doesn't create secrets if source paths are empty in Infisical
4. Dynamic pod name discovery prevents hardcoded values from breaking on rebuilds
5. Helm must be installed on K3s master nodes for `kubernetes.core.helm` Ansible module
6. Community Helm charts may be more reliable than official repos (e.g., Synology CSI)

### PostgreSQL Backups
1. Use pg_dump instead of pg_dumpall when running as non-superuser
2. InitContainers with runAsUser: 0 needed to fix volume permissions (UID 26 = postgres)
3. Custom format enables selective restoration and parallel restore
4. Always include checksum verification and metadata files
5. Test restore procedures regularly (monthly recommended)

### Infisical Integration
1. Environment slug in Infisical UI may differ from API slug (e.g., "Production" → "prod")
2. Machine Identity needs explicit project access (Viewer role minimum)
3. ExternalSecret should not use `property` field when syncing from Infisical
4. ClusterSecretStore requires internal cluster URL (not external HTTPS URL)

### cert-manager + Cloudflare
1. DNS01 challenges work well for wildcard certs and internal services
2. Cloudflare API token needs Zone:DNS:Edit permission
3. cert-manager auto-renews certificates 30 days before expiration
4. Let's Encrypt staging should be used for testing to avoid rate limits

### Traefik IngressRoutes
1. Separate IngressRoutes for HTTP and HTTPS
2. Use Middleware for HTTP → HTTPS redirect
3. TLS secret must be in same namespace as IngressRoute
4. HTTP/2 is automatically enabled when using TLS

### Synology CSI Driver
1. StorageClass `dsm` parameter must EXACTLY match the `host` in client-info.yaml
2. Use IP address OR hostname consistently - no mixing
3. Parameters in StorageClass cannot be updated - must delete and recreate
4. ExternalSecret controller will automatically overwrite manually edited secrets
5. Test volume provisioning immediately after deployment to verify configuration

## Storage Architecture

### Storage Tiers (docs/STORAGE_TIERS.md)
- **Tier 0 (local-ssd):** Node-local SSD for apps with own replication
- **Tier 1 (longhorn-replicated):** Default replicated storage for most workloads
- **Tier 2 (synology-iscsi):** ✅ Bulk storage for large files (>500GB)
- **Tier 3 (synology-nfs):** ✅ Shared storage with ReadWriteMany access
- **Tier 4-6:** Backup tiers (Longhorn → Synology → Offline)

### Available StorageClasses
```bash
local-path (default)   # K3s local-path-provisioner
synology-iscsi        # Tier 2: iSCSI for bulk data
synology-nfs          # Tier 3: NFS for shared access
```

## Next Tasks

### High Priority
- [ ] Create Gitea secrets in Infisical (`/gitea/database`, `/gitea/admin`, `/gitea/config`) ⭐ NEW
- [ ] Deploy Gitea with Infisical secrets (playbook ready: deploy-gitea.yml) ⭐ NEW
- [ ] Deploy Uptime Kuma with Infisical secrets ⭐ NEW
- [ ] Upgrade Infisical TLS from self-signed to Let's Encrypt (Cloudflare DNS-01) ⭐ NEW
- [ ] Deploy Synology CSI Driver with correct Helm chart (playbook updated) ⭐ NEW
- [ ] Set up monitoring for certificate expiration
- [ ] Configure alerts for ExternalSecret sync failures

### Medium Priority
- [ ] Deploy production workload using Synology storage (e.g., Frigate NVR)
- [ ] Configure Longhorn backup target to Synology NFS (Tier 4)
- [ ] Document complete cluster rebuild procedure
- [ ] Create automated cluster rebuild script combining all phases

### Long Term (CI/CD Roadmap)
- [ ] Testing Framework (Phase 1 - see CICD_STATUS_AND_ROADMAP.md)
- [ ] Continuous Deployment Pipeline (Phase 2)
- [ ] GitOps Integration with ArgoCD (Phase 3)

## Contact/Escalation

For issues:
1. Check `.claude/bugs.md` for known issues
2. Review troubleshooting in `docs/INFISICAL_TLS_DEPLOYMENT.md`
3. Check git history for recent changes
4. Review deployment logs

---

**Last Updated:** 2026-01-30
**Updated By:** Infrastructure Team (PostgreSQL HA Security Hardening)

## Recent Achievements
- ✅ **PostgreSQL HA security hardening** - 3-layer access control (2026-01-30) ⭐ NEW
  - pg_hba.conf restricted from 0.0.0.0/0 to specific VLAN 12 + overlay CIDRs
  - HAProxy stats port 7000 removed from external access
  - Proxmox VM firewall enabled on all 6 nodes (DROP policy, explicit ACCEPT rules)
  - Only Home Assistant (192.168.2.5) and internal VLANs can reach PostgreSQL
  - Docs: `docs/POSTGRES_HA_SECURITY.md`
- ✅ **Infisical Operator recursive fix** - Resolved secret sync limitation (2025-12-28)
  - Created migration script: `helpers/migrate-infisical-secrets.py` (main branch)
  - Fixed `recursive: true` not syncing subdirectory secrets
  - Flattened 15 secrets to root path with path prefixes
  - All 16 secrets now sync successfully via InfisicalSecret CRD
  - GitHub Issues: #41 (resolved), #42 (documented)
  - Docs: `docs/INFISICAL_OPERATOR_RECURSIVE_FIX.md`
- ✅ KubeView cluster visualization deployed (2025-12-13)
- ✅ Read-only RBAC with BasicAuth + HTTPS security (2025-12-13)
- ✅ Comprehensive KubeView documentation created (2025-12-13)
- ✅ Infisical with TLS via Traefik deployed (2025-12-05)
- ✅ Self-signed certificates via cert-manager (2025-12-05)
- ✅ HTTP → HTTPS redirect configured (2025-12-05)
- ✅ Infisical database restored from backup (2025-12-05)
- ✅ K3s cluster smoke test completed (2025-12-05)
- ✅ PostgreSQL Backup System deployed and verified (2025-11-14)
- ✅ Multi-tier backup strategy (Daily/Weekly/Hourly) operational (2025-11-14)
- ✅ Infisical secrets structure documented (2025-11-12)
- ✅ Universal Auth configured for K8s ESO (2025-11-12)
- ✅ Gitea & Uptime Kuma secret paths created (2025-11-12)
- ✅ Synology CSI Driver deployed and verified (2025-11-01)
- ✅ Storage Tiers 2 & 3 operational
- ✅ Infisical integration for Synology credentials
- ✅ External Secrets Operator working
