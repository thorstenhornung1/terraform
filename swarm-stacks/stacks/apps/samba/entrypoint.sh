#!/bin/bash
# =============================================================================
# Samba Entrypoint — tdbsam Auth + Local User/Group Resolution
# =============================================================================
# 1. Creates local users and groups (no SSSD, no LDAP dependency)
# 2. Syncs NT-Hashes from Authentik API into tdbsam (initial + cron)
# 3. Starts cron + smbd
#
# Authentication flow:
#   SMB client → NTLM Challenge-Response → tdbsam (local NT-Hash lookup)
#   User/Group resolution → local /etc/passwd + /etc/group
#   NT-Hash source → Authentik API → sync-samba-users.sh → pdbedit
#
# Design: Users/groups are created locally so Samba works even when
# Authentik is offline. Only password sync requires Authentik connectivity.
# =============================================================================
set -e

echo "[samba] Starting..."

# =========================================================================
# 1. Local groups
# =========================================================================
# Create paperless group (force user/group for Paperless shares)
getent group paperless >/dev/null 2>&1 || groupadd -g "${PAPERLESS_GID:-1000}" paperless 2>/dev/null || groupadd paperless
# Create family group (valid users for shared SMB access)
getent group family >/dev/null 2>&1 || groupadd -g "${FAMILY_GID:-2000}" family

echo "[samba] Groups created (paperless, family)"

# =========================================================================
# 2. Local users
# =========================================================================
# Paperless service user (force user for file ownership)
id paperless >/dev/null 2>&1 || useradd -u "${PAPERLESS_UID:-1000}" -g paperless -M -s /usr/sbin/nologin paperless 2>/dev/null || useradd -g paperless -M -s /usr/sbin/nologin paperless

# SMB users — created from SAMBA_USERS env var (comma-separated)
# These are local Unix users needed by pdbedit. Authentication is via
# NT-Hash in tdbsam, NOT via Unix passwords.
SAMBA_USERS="${SAMBA_USERS:-thorsten.hornung,stephanie.hornung,helena.hornung}"
IFS=',' read -ra USERS <<< "$SAMBA_USERS"
for user in "${USERS[@]}"; do
    user=$(echo "$user" | xargs)  # trim whitespace
    [ -z "$user" ] && continue
    if ! id "$user" >/dev/null 2>&1; then
        useradd -M -s /usr/sbin/nologin -G family "$user" 2>/dev/null || true
        echo "[samba] Created user: $user"
    else
        # Ensure existing user is in family group
        usermod -aG family "$user" 2>/dev/null || true
    fi
done

echo "[samba] Users: ${USERS[*]}"

# =========================================================================
# 3. Directories
# =========================================================================
mkdir -p /shares/Posteingang /shares/Archiv /var/log/samba
chown paperless:paperless /shares/Posteingang
# /shares/Archiv is mounted read-only — skip chown

# =========================================================================
# 4. Initial NT-Hash sync from Authentik API → tdbsam
# =========================================================================
echo "[samba] Running initial user sync..."
/usr/local/bin/sync-samba-users.sh || echo "[samba] WARNING: Initial sync failed (Authentik may be unreachable)"

# =========================================================================
# 5. Cron for periodic sync (every 5 minutes)
# =========================================================================
echo "*/5 * * * * /usr/local/bin/sync-samba-users.sh >> /var/log/samba/sync.log 2>&1" | crontab -
cron

echo "[samba] Starting smbd..."
exec smbd --foreground --no-process-group --debuglevel=1
