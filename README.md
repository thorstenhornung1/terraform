# Proxmox K3s Infrastructure - Terraform Configuration

This repository contains the clean, production-ready Terraform configuration for deploying a complete K3s cluster on Proxmox VE with supporting infrastructure.

## Architecture Overview

This infrastructure deploys:

1. **K3s Cluster** (6 VMs)
   - 3 Master nodes (HA control plane)
   - 3 Worker nodes (workload execution)
   - Dual VLAN configuration (VLAN 4 for cluster, VLAN 12 for storage)

2. **Bootstrap Host** (1 VM)
   - Standalone Docker host running Infisical
   - Provides secrets management OUTSIDE K3s cluster
   - Eliminates circular dependencies
   - Storage: ZFS tank for HA and snapshots

3. **SeaweedFS Storage** (1 VM)
   - Distributed object storage with S3 API
   - 500GB data disk on ZFS tank
   - Dedicated storage network (VLAN 12)

## Repository Structure

```
.
├── main.tf                      # K3s cluster VMs (masters + workers)
├── variables.tf                 # All configuration variables
├── bootstrap-host.tf            # Bootstrap host for Infisical
├── seaweedfs.tf                # SeaweedFS storage VM
├── .terraform.lock.hcl         # Provider version lock file
├── terraform/
│   ├── bootstrap-host/
│   │   └── cloud-init-docker-infisical.yml
│   ├── k3s-cluster/
│   │   └── cloud-init-k3s-complete.yml
│   └── seaweedfs/
│       └── cloud-init-seaweedfs.yml
└── .claude/                    # Claude Code project configuration
```

## Prerequisites

1. **Proxmox VE Cluster** (3 nodes: pve01, pve02, pve03)
2. **VM Template** (ID 9000) on pve01
3. **Proxmox API Token** (configured in variables.tf)
4. **SSH Public Key** (for VM access)
5. **Storage Requirements:**
   - `local-lvm`: K3s cluster VMs
   - `tank`: Bootstrap host + SeaweedFS data (ZFS pool)

## Deployment Order

**CRITICAL:** Deploy infrastructure in this order to avoid circular dependencies:

### 1. Deploy Bootstrap Host

```bash
terraform init
terraform plan -target=proxmox_virtual_environment_vm.bootstrap_host
terraform apply -target=proxmox_virtual_environment_vm.bootstrap_host -parallelism=2
```

Post-deployment:
- SSH to bootstrap host: `ssh ansible@192.168.4.20`
- Verify Docker services: `docker ps`
- Access Infisical: https://infisical.hornung-bn.de
- Configure initial secrets for K3s cluster

### 2. Deploy K3s Cluster

```bash
terraform plan
terraform apply -parallelism=2
```

### 3. Deploy SeaweedFS (Optional)

```bash
terraform plan -target=proxmox_virtual_environment_vm.seaweedfs
terraform apply -target=proxmox_virtual_environment_vm.seaweedfs -parallelism=2
```

## Configuration

### Key Variables (variables.tf)

**Storage Rules (CRITICAL):**
- K3s VMs: `local-lvm` ONLY (never use Synology storage)
- Bootstrap Host: `tank` (ZFS for HA, snapshots)
- SeaweedFS data disk: `tank` (ZFS for performance)

**Network Configuration:**
- VLAN 4: Cluster network (192.168.4.0/24)
- VLAN 12: Storage network (192.168.12.0/24)
- DNS: Pi-hole cluster (192.168.2.4, 192.168.4.5, 192.168.4.6)

**VM Distribution:**
```
pve01: master-1, worker-1
pve02: master-2, worker-2
pve03: master-3, worker-3
```

### Network Topology

**Dual VLAN Architecture:**
- **VLAN 4** (Primary): Cluster communication, API access, ingress
- **VLAN 12** (Storage): Longhorn replication, SeaweedFS access, Synology NAS

## Storage Architecture

### Storage Tiers

1. **Tier 0 (local-ssd):** Node-local SSD for apps with own replication
2. **Tier 1 (longhorn-replicated):** Default replicated storage (3x)
3. **Tier 2 (synology-iscsi):** Bulk storage for large files (>500GB)
4. **Tier 3 (synology-nfs):** Shared storage with ReadWriteMany
5. **Tier 4 (seaweedfs-s3):** Object storage with S3 API

### Longhorn Storage Calculation

Worker disk sizes are optimized for Longhorn:
- worker-1: 80GB → ~56GB usable (70%)
- worker-2: 110GB → ~77GB usable (70%)
- worker-3: 110GB → ~77GB usable (70%)
- **Total usable**: ~210GB → ~70GB effective with 3x replication

## Bootstrap Host Architecture

**Why Bootstrap Host?**

Previous approach had circular dependency:
- K3s needs secrets → Infisical needs PostgreSQL → PostgreSQL needs secrets ❌

New approach:
- Bootstrap Host provides Infisical OUTSIDE K3s
- K3s can reference secrets from day 1 ✅
- Simple disaster recovery (PostgreSQL backup)

**Services:**
- Docker + Docker Compose
- Traefik (reverse proxy, Let's Encrypt)
- Infisical (latest, PostgreSQL backend)
- Automated backups (daily at 2 AM)

**Access:**
- External HTTPS: https://infisical.hornung-bn.de
- Internal HTTP: http://192.168.4.20:8080

## Important Notes

### Terraform Parallelism

**ALWAYS use `-parallelism=2` to prevent HTTP 596 timeouts:**
```bash
terraform apply -parallelism=2
```

### Cloud-Init Bugs (FIXED)

**Bug #29:** Wrong Docker repository (Debian instead of Ubuntu) - FIXED
- Fixed in `terraform/bootstrap-host/cloud-init-docker-infisical.yml`
- Docker now installs correctly from Ubuntu repositories

**Bug #29:** APT proxy DNS resolution failure - FIXED
- Added Pi-hole cluster DNS servers to variables.tf
- APT cacher operational with local DNS resolution

### Disaster Recovery

**Pre-Destruction Snapshot Requirement (MANDATORY):**

Before ANY operation that could destroy data:
```bash
# 1. Create Proxmox snapshot
ssh root@pve01 "qm snapshot 4001 pre-destroy-$(date +%Y%m%d-%H%M%S)"

# 2. Verify snapshot exists
ssh root@pve01 "qm listsnapshot 4001"

# 3. ONLY THEN proceed with destruction
terraform destroy -target=proxmox_virtual_environment_vm.bootstrap_host
```

## CI/CD Integration

This infrastructure supports full GitOps workflow:

1. **Ansible Playbooks** (main repo) - Application deployment
2. **External Secrets Operator** - Auto-sync from Infisical
3. **Terraform** (this repo) - Infrastructure as Code

See `.claude/CLAUDE.md` for complete CI/CD rules and deployment order.

## Outputs

After successful deployment:

```bash
terraform output cluster_summary         # K3s cluster info
terraform output bootstrap_host_summary  # Bootstrap host info
terraform output seaweedfs_info         # SeaweedFS endpoints
```

## Support

**Documentation:**
- `.claude/CLAUDE.md` - Complete project memory and rules
- `.claude/decisions.md` - Architecture decisions
- `.claude/bugs.md` - Known issues and fixes

**Issues:** https://github.com/thorstenhornung1/terraform/issues

## License

Private infrastructure - Not for redistribution

---

**Last Updated:** 2026-01-18
**Terraform Version:** ~> 1.9
**Proxmox Provider:** bpg/proxmox ~> 0.66
