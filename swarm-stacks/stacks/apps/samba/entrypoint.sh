#!/bin/bash
# =============================================================================
# Samba Entrypoint — tdbsam Auth + SSSD User/Group Resolution
# =============================================================================
# 1. Creates paperless system user/group (force user/group for file ownership)
# 2. Configures SSSD for user/group resolution via Authentik LDAP Outpost
# 3. Syncs NT-Hashes from Authentik API into tdbsam (initial + cron)
# 4. Starts SSSD + cron + smbd
#
# Authentication flow:
#   SMB client → NTLM Challenge-Response → tdbsam (local NT-Hash lookup)
#   User/Group resolution → SSSD → Authentik LDAP Outpost (@family group)
#   NT-Hash source → Authentik API → sync-samba-users.sh → pdbedit
# =============================================================================
set -e

echo "[samba] Starting..."

LDAP_BIND_PW=$(cat "${LDAP_BIND_PASSWORD_FILE}")

# Paperless system user/group (local fallback for force user)
# GID/UID may already exist in base image — use existing or create
getent group paperless >/dev/null 2>&1 || groupadd -g "${PAPERLESS_GID:-1000}" paperless 2>/dev/null || groupadd paperless
id paperless >/dev/null 2>&1 || useradd -u "${PAPERLESS_UID:-1000}" -g paperless -M -s /usr/sbin/nologin paperless 2>/dev/null || useradd -g paperless -M -s /usr/sbin/nologin paperless

# SSSD configuration: Authentik LDAP for user + group resolution (NSS only)
cat > /etc/sssd/sssd.conf << SSSD_EOF
[sssd]
services = nss, pam
config_file_version = 2
domains = authentik

[domain/authentik]
id_provider = ldap
auth_provider = ldap
ldap_uri = ${LDAP_URI}
ldap_search_base = ${LDAP_SEARCH_BASE}
ldap_default_bind_dn = ${LDAP_BIND_DN}
ldap_default_authtok = ${LDAP_BIND_PW}
ldap_user_search_base = ou=users,${LDAP_SEARCH_BASE}
ldap_group_search_base = ou=groups,${LDAP_SEARCH_BASE}
ldap_schema = rfc2307bis
ldap_user_object_class = user
ldap_group_object_class = group
ldap_user_name = cn
ldap_tls_reqcert = never
cache_credentials = true
enumerate = true
SSSD_EOF
chmod 600 /etc/sssd/sssd.conf

# NSSwitch: SSSD for LDAP user/group resolution
sed -i 's/^passwd:.*/passwd:         files sss/' /etc/nsswitch.conf
sed -i 's/^group:.*/group:          files sss/' /etc/nsswitch.conf
sed -i 's/^shadow:.*/shadow:         files sss/' /etc/nsswitch.conf

# Ensure directories exist
mkdir -p /shares/Posteingang /shares/Archiv /var/log/samba /var/run/sssd
chown paperless:paperless /shares/Posteingang
# /shares/Archiv is mounted read-only — skip chown

# Start SSSD (Linux now resolves Authentik users + groups via NSS)
echo "[samba] Starting SSSD..."
sssd -D 2>/dev/null || sssd --logger=stderr &
sleep 3

# Verify SSSD
if getent group family >/dev/null 2>&1; then
    echo "[samba] SSSD OK — group 'family' resolved"
else
    echo "[samba] WARNING: group 'family' not found via SSSD"
fi

# Initial NT-Hash sync from Authentik API → tdbsam
echo "[samba] Running initial user sync..."
/usr/local/bin/sync-samba-users.sh || echo "[samba] WARNING: Initial sync failed"

# Cron for periodic sync (every 5 minutes)
echo "*/5 * * * * /usr/local/bin/sync-samba-users.sh >> /var/log/samba/sync.log 2>&1" | crontab -
cron

echo "[samba] Starting smbd..."
exec smbd --foreground --no-process-group --debuglevel=1
