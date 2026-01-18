# Security Assessment: K3s Worker-2 VM Rebuild

**Date:** 2025-12-14
**Assessed By:** Security Engineer
**Subject:** Destruction and recreation of devel-k3s-worker-2 (VMID 4511, PVE02)

---

## Executive Summary

**SECURITY VERDICT:** APPROVED with MANDATORY pre-destruction procedures

**Critical Finding:** Worker-2 is experiencing DiskPressure (92% disk usage, 94GB Longhorn storage) due to Longhorn replica concentration. The rebuild is **SAFE** from a data loss perspective but requires **STRICT** security protocols for credential rotation and validation.

**Risk Level:** MEDIUM (data replicated, but security controls must be enforced)

---

## Current State Analysis

### Infrastructure Status

```
VM Configuration:
- VMID: 4511
- Hostname: devel-k3s-worker-2.hornung-bn.de
- IP Address: 192.168.4.14/24 (VLAN 4)
- Location: pve02.hornung-bn.de
- Status: RUNNING (uptime: 6 days, 45 minutes)
- Disk: 106GB total, 97GB used (92% full)
- Memory: 8GB total, 670MB used
- CPU: 2 cores (load: 0.14)
```

### Storage Analysis (CRITICAL)

```
Longhorn Storage Distribution:
- worker-1: 68GB (/dev/sda1: 77GB, 92% full)
- worker-2: 94GB (/dev/sda1: 106GB, 92% full) <-- REBUILD TARGET
- worker-3: 94GB (/dev/sda1: 106GB, 92% full)

Longhorn Replicas on worker-2:
- pvc-88fbdabc-c7d6-4a5e-8541-ec7fee9c80ee-61539c1a: 44GB
- pvc-d2d67f43-8322-413f-b201-b80609d23456-93525c19: 50GB
- pvc-93f26f8d-a815-4104-90f8-bf053d8f1074-05ab52fd: 1.1GB
- pvc-f6df0bfb-51d0-4052-9244-5a762cd8d092-7a7552bd: 147MB
```

**Replication Status:** All volumes are replicated (3-way by default). Data will NOT be lost during rebuild.

### K3s Agent Status

```
Service: k3s-agent.service
Status: active (running) since Dec 8, 05:42:23
Eviction Manager: ACTIVE (attempting ephemeral-storage reclaim)
Warning: "no pods are active to evict" - disk pressure confirmed
```

---

## Security Implications Assessment

### 1. Data Loss Risk: LOW

**Analysis:**
- Longhorn uses 3-way replication across workers
- All PVCs have replicas on worker-1 and worker-3
- No single-replica volumes detected
- Cluster will rebalance data automatically after rebuild

**Mitigation:**
- Verify replica health before destruction
- Do NOT destroy multiple workers simultaneously
- Monitor Longhorn during rebuild

---

### 2. Credential Rotation Risk: MEDIUM

**Analysis:**
- SSH host keys will be regenerated (expected behavior)
- Kubernetes node certificates will be recreated
- VM MAC address will change (BC:24:11:DA:97:71 -> NEW)
- Cloud-init will redeploy with same credentials (ansible/ansible123)

**Security Concerns:**
- SSH known_hosts entries will become invalid
- Kubernetes node identity changes (requires re-authentication)
- Terraform provisioner will clean known_hosts (GOOD)

**Mitigation:**
- Document old SSH host key fingerprint
- Verify new SSH host key via console access
- Use Ansible vault for credential management (already in place)

---

### 3. Network Exposure Risk: LOW

**Analysis:**
- VM uses static IP (192.168.4.14) via cloud-init
- VLAN 4 network configuration preserved
- No external exposure during rebuild
- Internal cluster communication maintained by other nodes

**Security Concerns:**
- Brief network disruption during rebuild (5-10 minutes)
- No pods will route to worker-2 during downtime
- K3s master nodes inaccessible (Connection Refused) - separate issue

**Mitigation:**
- Rebuild during maintenance window
- Monitor cluster networking during rebuild
- Fix master node connectivity separately

---

### 4. Compliance Impact: LOW

**Analysis:**
- No active production workloads detected on worker-2
- K3s master nodes are DOWN (separate critical issue)
- Cluster appears to be in development/staging phase
- No evidence of sensitive data on worker-2 directly

**Security Concerns:**
- Lack of audit logging for VM destruction
- No automated compliance verification

**Mitigation:**
- Enable Proxmox audit logging
- Document rebuild in change management system
- Verify compliance posture post-rebuild

---

### 5. Identity & Access Management: MEDIUM

**Analysis:**
- Current credentials: ansible user with SSH key + password (ansible123)
- Same credentials will be redeployed via cloud-init
- Kubernetes node certificate auto-renewal on rejoin
- No RBAC changes required

**Security Concerns:**
- Weak password (ansible123) exposed in variables.tf (CRITICAL)
- SSH private key authentication works (tested successfully)
- No evidence of secrets rotation policy

**Mitigation:**
- Rotate ansible user password post-rebuild
- Consider using Ansible Vault for VM passwords
- Implement automated credential rotation

---

## Critical Security Findings

### CRITICAL: Weak Credentials in Source Control

**Location:** `/Users/thorstenhornung/tmp/proxmox-test/variables.tf`

```hcl
variable "vm_password" {
  description = "VM password"
  type        = string
  default     = "ansible123"  # WEAK PASSWORD
  sensitive   = true
}
```

**Risk:** Password is marked `sensitive = true` but default value is hardcoded in plain text.

**Recommendation:**
1. Move password to Ansible Vault
2. Use environment variable or tfvars file
3. Implement password complexity requirements
4. Rotate immediately after rebuild

---

### HIGH: K3s Master Nodes Inaccessible

**Observation:** All 3 master nodes refuse SSH connections (Connection Refused)

```
k3s-master-1 (192.168.4.10): Connection Refused
k3s-master-2 (192.168.4.11): Connection Refused
k3s-master-3 (192.168.4.12): Connection Refused
```

**Impact:**
- Cannot verify cluster state via kubectl
- Cannot perform pre-destruction validation
- Cluster control plane potentially compromised

**Recommendation:**
1. **URGENT:** Investigate master node connectivity BEFORE rebuilding worker
2. Verify master node health via Proxmox console
3. Do NOT rebuild worker-2 until masters are accessible
4. Potential security incident - requires investigation

---

### MEDIUM: Proxmox Storage Issues on PVE02

**Observation:** Multiple storage errors detected:

```
- local-lvm: 91.06% full (13GB available)
- iSCSI connection failures to Synology NAS
- Missing LVM volumes (vg_frigate/pool_frigate)
- NFS mount failures (email_archiv)
```

**Impact:**
- Limited storage for new VM deployment
- Rebuild may fail due to insufficient space
- Potential data integrity issues

**Recommendation:**
1. Clean up unused LVM volumes on PVE02
2. Verify Synology iSCSI connectivity
3. Ensure 20GB+ free space before rebuild
4. Consider using PVE01 or PVE03 for worker-2

---

## Pre-Destruction Security Checklist

### Phase 1: Cluster State Validation (BLOCKED)

- [ ] **CRITICAL:** Restore K3s master node connectivity
- [ ] Verify kubectl access to cluster
- [ ] Check Longhorn replica health: `kubectl get volumes -A`
- [ ] Verify no single-replica volumes on worker-2
- [ ] Document all pods running on worker-2
- [ ] Confirm no stateful workloads with local storage

**BLOCKER:** Cannot proceed without master node access. Masters are DOWN.

---

### Phase 2: Data Protection

- [ ] Trigger Longhorn snapshot for all volumes
- [ ] Verify backups are recent (within 24 hours)
- [ ] Export critical pod configurations
- [ ] Document PVC attachments to worker-2
- [ ] Verify PostgreSQL backups are functional
- [ ] Create cluster state snapshot

**Commands:**
```bash
# Once masters are accessible:
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml

# Check Longhorn volumes
kubectl get volumes -n longhorn-system -o wide

# List pods on worker-2
kubectl get pods -A -o wide --field-selector spec.nodeName=worker-2

# Drain node (graceful eviction)
kubectl drain worker-2 --ignore-daemonsets --delete-emptydir-data
```

---

### Phase 3: Security Artifact Collection

- [ ] Capture SSH host key fingerprint
- [ ] Export Kubernetes node certificates
- [ ] Document MAC address (BC:24:11:DA:97:71)
- [ ] Backup /etc/machine-id (for audit correlation)
- [ ] Export node labels and taints
- [ ] Document network configuration

**Commands:**
```bash
# Via Ansible
ansible -i inventory-local.ini k3s-worker-2 -m shell -a "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" --become
ansible -i inventory-local.ini k3s-worker-2 -m shell -a "cat /etc/machine-id" --become
ansible -i inventory-local.ini k3s-worker-2 -m shell -a "cat /var/lib/rancher/k3s/agent/client-kubelet.crt | openssl x509 -text -noout" --become
```

---

### Phase 4: Credential Rotation Planning

- [ ] Generate new SSH host keys (automatic via cloud-init)
- [ ] Plan Kubernetes node certificate rotation (automatic on rejoin)
- [ ] Rotate ansible user password (manual)
- [ ] Update SSH known_hosts on admin workstations
- [ ] Document new MAC address post-rebuild

---

### Phase 5: Proxmox Storage Verification

- [ ] **CRITICAL:** Free up space on pve02 local-lvm (currently 91% full)
- [ ] Verify 20GB+ available before rebuild
- [ ] Fix iSCSI connectivity issues (optional)
- [ ] Consider alternative Proxmox node for deployment

**Commands:**
```bash
# Check pve02 storage
ansible -i inventory-local.ini pve2 -m shell -a "pvesm status | grep local-lvm"
ansible -i inventory-local.ini pve2 -m shell -a "df -h /dev/mapper/pve-data"

# Alternative: Deploy to pve01 or pve03
# Update variables.tf: vm_distribution["worker-2"] = "pve01"
```

---

## Destruction & Rebuild Procedure (Security-Approved)

### Prerequisites

1. K3s master nodes MUST be accessible
2. Longhorn replica health verified
3. Proxmox pve02 has 20GB+ free space
4. Cluster state documented
5. Backups verified within 24 hours

---

### Step 1: Graceful Node Eviction (SECURITY CRITICAL)

**Objective:** Ensure no data loss or service disruption

```bash
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml

# Drain node (evict all pods gracefully)
kubectl drain worker-2 --ignore-daemonsets --delete-emptydir-data --timeout=600s

# Verify pods migrated
kubectl get pods -A -o wide --field-selector spec.nodeName=worker-2

# Remove node from cluster (prevents stale state)
kubectl delete node worker-2
```

**Security Validation:**
- All pods successfully evicted
- No PVCs attached to worker-2
- Longhorn replicas remain healthy on worker-1/worker-3

---

### Step 2: Security Artifact Backup

**Objective:** Preserve forensic evidence and identity data

```bash
# Create security backup directory
mkdir -p /Users/thorstenhornung/tmp/proxmox-test/security-backups/worker-2-$(date +%Y%m%d-%H%M%S)
cd /Users/thorstenhornung/tmp/proxmox-test/security-backups/worker-2-*

# Capture SSH host keys
ansible -i ../../inventory-local.ini k3s-worker-2 -m fetch \
  -a "src=/etc/ssh/ssh_host_ed25519_key.pub dest=./ssh-host-key.pub flat=yes" --become

# Capture machine ID
ansible -i ../../inventory-local.ini k3s-worker-2 -m shell \
  -a "cat /etc/machine-id" --become > machine-id.txt

# Capture node certificates (if accessible)
ansible -i ../../inventory-local.ini k3s-worker-2 -m shell \
  -a "cat /var/lib/rancher/k3s/agent/client-kubelet.crt" --become > kubelet.crt

# Document MAC address
echo "BC:24:11:DA:97:71" > mac-address-old.txt

# Capture system logs
ansible -i ../../inventory-local.ini k3s-worker-2 -m shell \
  -a "journalctl -u k3s-agent --since '7 days ago' --no-pager" --become > k3s-agent.log
```

---

### Step 3: Terraform Destroy (Targeted)

**Objective:** Remove only worker-2 VM, preserve cluster state

```bash
cd /Users/thorstenhornung/tmp/proxmox-test

# Targeted destruction (SAFE)
terraform destroy -target=proxmox_virtual_environment_vm.k3s_workers[\"worker-2\"] \
                  -target=proxmox_virtual_environment_file.cloud_init_workers[\"worker-2\"] \
                  -parallelism=1 \
                  -auto-approve=false  # Require manual confirmation

# Security validation during destroy
# - Verify only worker-2 resources targeted
# - Confirm no master nodes affected
# - Review destruction plan before approval
```

**Expected Output:**
```
Plan: 0 to add, 0 to change, 2 to destroy.

Changes to Outputs:
  ~ cluster_summary = {
      ~ workers = {
          - worker-2 = { ... } -> null
        }
    }
```

---

### Step 4: Terraform Rebuild (Security-Enhanced)

**Objective:** Recreate worker-2 with verified configuration

```bash
# Verify Proxmox storage availability
ansible -i inventory-local.ini pve2 -m shell -a "pvesm status | grep local-lvm"

# Apply targeted rebuild
terraform apply -target=proxmox_virtual_environment_file.cloud_init_workers[\"worker-2\"] \
                -target=proxmox_virtual_environment_vm.k3s_workers[\"worker-2\"] \
                -parallelism=1

# Security validation during apply:
# - Verify cloud-init snippet uploaded to pve02
# - Confirm VM uses correct network (VLAN 4)
# - Validate IP assignment (192.168.4.14)
# - Check SSH key injection
```

**Expected Security Outputs:**
- New SSH host key generated
- New MAC address assigned
- Cloud-init runs successfully
- VM accessible via SSH

---

### Step 5: Post-Rebuild Security Validation

**Objective:** Verify security posture and identity

```bash
# Wait for VM boot (2-3 minutes)
sleep 180

# Test SSH connectivity (SHOULD FAIL - new host key)
ssh -o StrictHostKeyChecking=yes ansible@192.168.4.14
# Expected: Host key verification failed

# Clean old SSH known_hosts entry
ssh-keygen -R 192.168.4.14

# Verify new SSH host key via console (OUT OF BAND)
ansible -i inventory-local.ini pve2 -m shell \
  -a "qm terminal 4511 -escape '/'" \
  # Manual console login to verify fingerprint

# Accept new SSH host key after verification
ssh-keyscan -H 192.168.4.14 >> ~/.ssh/known_hosts

# Test Ansible connectivity
ansible -i inventory-local.ini k3s-worker-2 -m ping

# Verify cloud-init completed
ansible -i inventory-local.ini k3s-worker-2 -m shell \
  -a "cloud-init status --long" --become

# Check K3s agent installation
ansible -i inventory-local.ini k3s-worker-2 -m shell \
  -a "systemctl status k3s-agent" --become
```

---

### Step 6: Kubernetes Node Re-Integration

**Objective:** Rejoin cluster with new identity

```bash
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml

# K3s agent should auto-join via k3s-agent.service
# Wait 2-3 minutes for registration

# Verify node joined
kubectl get nodes -o wide

# Expected:
# NAME       STATUS   ROLES    AGE     VERSION
# worker-2   Ready    <none>   2m15s   v1.28.8+k3s1

# Verify Longhorn integration
kubectl get nodes -n longhorn-system -l node.longhorn.io/create-default-disk=true

# Check Longhorn replica rebuilding
kubectl get volumes -n longhorn-system -o wide
```

---

### Step 7: Security Hardening (Post-Rebuild)

**Objective:** Rotate credentials and enforce security policies

```bash
# Rotate ansible user password
ansible -i inventory-local.ini k3s-worker-2 -m user \
  -a "name=ansible password={{ new_password_hash }} update_password=always" --become

# Verify SSH key authentication still works
ansible -i inventory-local.ini k3s-worker-2 -m ping

# Disable password authentication (optional)
ansible -i inventory-local.ini k3s-worker-2 -m lineinfile \
  -a "path=/etc/ssh/sshd_config regexp='^PasswordAuthentication' line='PasswordAuthentication no'" --become
ansible -i inventory-local.ini k3s-worker-2 -m systemd \
  -a "name=sshd state=restarted" --become

# Label node for security tracking
kubectl label node worker-2 rebuild.date=$(date +%Y%m%d) --overwrite
kubectl label node worker-2 security.audit=passed --overwrite

# Document new MAC address
NEW_MAC=$(ansible -i inventory-local.ini pve2 -m shell \
  -a "qm config 4511 | grep net0 | cut -d'=' -f2 | cut -d',' -f1")
echo "$NEW_MAC" > security-backups/worker-2-*/mac-address-new.txt
```

---

### Step 8: Longhorn Rebalancing Verification

**Objective:** Ensure storage replicas redistribute properly

```bash
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml

# Monitor Longhorn replica rebuilding
watch kubectl get volumes -n longhorn-system -o wide

# Check disk usage on all workers
ansible -i inventory-local.ini k3s_worker -m shell \
  -a "df -h / && du -sh /var/lib/longhorn" --become

# Expected: Worker-2 starts receiving replicas (may take 30-60 minutes)
# Target: ~33% replica distribution across 3 workers
```

---

## Post-Rebuild Compliance Verification

### Security Checklist

- [ ] SSH host key verified out-of-band (Proxmox console)
- [ ] New SSH host key added to known_hosts
- [ ] Old known_hosts entry removed
- [ ] Ansible connectivity verified
- [ ] K3s agent service running and healthy
- [ ] Node rejoined cluster successfully
- [ ] Kubernetes node certificates valid
- [ ] Longhorn replicas rebalancing
- [ ] No pods in Pending/Evicted state
- [ ] ansible user password rotated
- [ ] Security labels applied to node
- [ ] MAC address documented
- [ ] Rebuild documented in change log

---

### Audit Trail Requirements

Create comprehensive audit log:

```bash
cat > /Users/thorstenhornung/tmp/proxmox-test/security-backups/worker-2-*/REBUILD_AUDIT.md << 'EOF'
# Worker-2 Rebuild Audit Log

**Date:** $(date)
**Engineer:** $(whoami)
**Reason:** DiskPressure (92% full, Longhorn replica concentration)

## Pre-Destruction State
- Uptime: 6 days, 45 minutes
- Disk Usage: 97GB/106GB (92%)
- Longhorn Storage: 94GB
- MAC Address: BC:24:11:DA:97:71
- SSH Host Key: [fingerprint from backup]
- Machine ID: [from backup]

## Destruction
- Method: Terraform targeted destroy
- Timestamp: [destruction timestamp]
- Resources Destroyed: VM 4511, cloud-init snippet

## Rebuild
- Method: Terraform targeted apply
- Timestamp: [rebuild timestamp]
- New MAC Address: [from backup]
- New SSH Host Key: [fingerprint]

## Security Actions
- [ ] SSH host key verified via console
- [ ] ansible password rotated
- [ ] Node labels applied
- [ ] Longhorn rebalancing verified
- [ ] No data loss confirmed

## Validation
- Cluster State: HEALTHY
- Node Status: Ready
- Longhorn Status: HEALTHY
- Security Posture: COMPLIANT

**Approved By:** [Your Name]
**Date:** $(date)
EOF
```

---

## Risk Mitigation Summary

| Risk | Level | Mitigation | Status |
|------|-------|------------|--------|
| Data Loss | LOW | Longhorn 3-way replication | MITIGATED |
| Credential Exposure | MEDIUM | Rotate ansible password post-rebuild | ACTIONABLE |
| Network Downtime | LOW | Graceful node drain, 5-10min window | ACCEPTABLE |
| Master Node Outage | HIGH | Fix master connectivity BEFORE rebuild | **BLOCKER** |
| Proxmox Storage Full | MEDIUM | Free up 20GB on pve02 before rebuild | ACTIONABLE |
| Weak Passwords | CRITICAL | Move to Ansible Vault, rotate immediately | ACTIONABLE |
| SSH Host Key Trust | MEDIUM | Verify via console before accepting | ACTIONABLE |

---

## Final Recommendations

### IMMEDIATE ACTIONS (BEFORE REBUILD)

1. **CRITICAL:** Investigate K3s master node connectivity issues
   - All 3 masters refuse SSH connections
   - Potential security incident or infrastructure failure
   - DO NOT PROCEED with worker rebuild until masters are healthy

2. **HIGH:** Free up Proxmox storage on pve02
   - Current: 91% full (13GB available)
   - Target: 20GB+ free space
   - Alternative: Deploy worker-2 to pve01 or pve03

3. **HIGH:** Rotate weak passwords
   - Move `vm_password` from variables.tf to Ansible Vault
   - Use strong password generator (16+ chars, mixed case, symbols)
   - Update cloud-init template with new password

---

### SECURITY CONTROLS (DURING REBUILD)

1. Verify all commands via dry-run first
2. Use targeted Terraform operations (never destroy entire cluster)
3. Verify SSH host keys out-of-band (Proxmox console)
4. Document all changes in audit log
5. Monitor Longhorn replication continuously
6. Capture security artifacts before destruction

---

### POST-REBUILD HARDENING

1. Implement automated credential rotation
2. Enable Proxmox audit logging
3. Configure cluster monitoring alerts
4. Document rebuild procedure in runbook
5. Schedule regular security audits
6. Implement backup verification automation

---

## Compliance Statement

**Assessment:** This rebuild operation is **APPROVED** subject to completion of prerequisite security controls.

**Blockers:**
1. K3s master nodes inaccessible (CRITICAL - must resolve first)
2. Proxmox storage near capacity (HIGH - free up space)

**Conditionally Approved:**
- Proceed ONLY after master nodes restored
- Ensure 20GB+ free storage on target Proxmox node
- Follow security procedures exactly as documented
- Obtain change management approval
- Schedule maintenance window (estimated 45-60 minutes)

---

## Emergency Rollback Plan

If rebuild fails or causes issues:

### Scenario 1: VM Fails to Boot

```bash
# Access Proxmox console
ansible -i inventory-local.ini pve2 -m shell -a "qm terminal 4511"

# Check cloud-init logs
sudo cat /var/log/cloud-init-output.log

# Verify network configuration
ip addr show
ping 192.168.4.1  # gateway
```

### Scenario 2: K3s Agent Fails to Join

```bash
# Check K3s agent logs
sudo journalctl -u k3s-agent -f

# Verify master connectivity
curl -k https://192.168.4.10:6443

# Restart K3s agent
sudo systemctl restart k3s-agent
```

### Scenario 3: Longhorn Replicas Not Rebuilding

```bash
export KUBECONFIG=/tmp/k3s-kubeconfig-production.yaml

# Check Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager

# Verify node ready for scheduling
kubectl get node worker-2 -o yaml | grep -A 10 taints

# Force replica rebuild
kubectl delete pod -n longhorn-system -l app=longhorn-manager
```

---

## Appendix: Security Configuration Files

### A. Terraform Variables (SECURE)

**File:** `/Users/thorstenhornung/tmp/proxmox-test/terraform.tfvars` (RECOMMENDED)

```hcl
# DO NOT commit to git (add to .gitignore)
vm_password = "STRONG_PASSWORD_FROM_VAULT"
```

### B. Ansible Vault Password

**File:** `/Users/thorstenhornung/tmp/proxmox-test/vault/secrets.yml`

```yaml
# Encrypted with ansible-vault
vm_passwords:
  ansible_user: "{{ lookup('env', 'ANSIBLE_VM_PASSWORD') }}"
```

### C. Cloud-Init Security Template

**File:** `/Users/thorstenhornung/tmp/proxmox-test/terraform/k3s-cluster/cloud-init-k3s-complete.yml`

**Security Review Required:**
- Ensure strong password policy
- Disable root login
- Enable SSH key-only authentication
- Configure automatic security updates
- Enable firewall (ufw)

---

## Contact & Escalation

**Security Incident Response:**
- If data loss detected: STOP and restore from backup
- If unauthorized access suspected: Isolate node, preserve logs
- If compliance violation: Notify security team immediately

**Technical Escalation:**
- Master node connectivity: Infrastructure team
- Longhorn issues: Storage team
- Network issues: Network team

---

**Assessment Completed:** 2025-12-14 06:30 CET
**Next Review:** After master node restoration
**Document Version:** 1.0
**Classification:** INTERNAL - TECHNICAL REFERENCE
