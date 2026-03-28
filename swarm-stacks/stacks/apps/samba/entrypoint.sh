#!/bin/bash
# =============================================================================
# Samba Entrypoint — Authentik LDAP User Provisioning
# =============================================================================
# 1. Creates paperless system user (force user/group for file ownership)
# 2. Queries Authentik LDAP Outpost for "family" group members
# 3. Provisions each member as Samba user with shared SMB password
# 4. Starts smbd in foreground
# =============================================================================
set -e

echo "[samba] Starting Samba entrypoint..."

# Read secrets from Docker secret files
LDAP_BIND_PW=$(cat "${LDAP_BIND_PASSWORD_FILE}")
SMB_PASSWORD=$(cat /run/secrets/samba_smb_password)

# Create paperless system user/group (matches Paperless container UID/GID)
groupadd -g "${PAPERLESS_GID:-1000}" paperless 2>/dev/null || true
useradd -u "${PAPERLESS_UID:-1000}" -g paperless -M -s /usr/sbin/nologin paperless 2>/dev/null || true

# Ensure share directories exist with correct ownership
mkdir -p /shares/Posteingang /shares/Archiv
chown paperless:paperless /shares/Posteingang /shares/Archiv

# Query Authentik LDAP Outpost for family group members
echo "[samba] Querying LDAP for family group members..."
MEMBERS=$(ldapsearch -LLL -H "$LDAP_URI" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PW" \
  -b "ou=users,$LDAP_SEARCH_BASE" "(memberOf=cn=family,ou=groups,$LDAP_SEARCH_BASE)" cn 2>/dev/null \
  | grep "^cn:" | awk '{print $2}') || true

if [ -z "$MEMBERS" ]; then
  echo "[samba] WARNING: No LDAP members found in family group. Check LDAP connectivity."
  echo "[samba] LDAP URI: $LDAP_URI"
  echo "[samba] Search Base: ou=users,$LDAP_SEARCH_BASE"
fi

# Provision each LDAP user as Samba user
USER_COUNT=0
for user in $MEMBERS; do
  useradd -M -s /usr/sbin/nologin -g paperless "$user" 2>/dev/null || true
  printf "%s\n%s\n" "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -a -s "$user"
  echo "[samba] User provisioned: $user"
  USER_COUNT=$((USER_COUNT + 1))
done

echo "[samba] Provisioned $USER_COUNT users from LDAP"
echo "[samba] Starting smbd..."

exec smbd --foreground --no-process-group --debuglevel=1
