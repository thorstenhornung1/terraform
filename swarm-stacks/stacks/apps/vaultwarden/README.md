# Vaultwarden Stack

Zentraler Password Manager im Docker Swarm. Backend: PostgreSQL (Patroni HA).
Daten: CephFS (`/mnt/cephfs/swarm-state/stack-vaultwarden/data`).

## Zugang

| URL | Zweck |
|-----|-------|
| `https://vault.hornung-bn.de` | Web Vault |
| `https://vault.hornung-bn.de/admin` | Admin Panel (Token-geschuetzt) |

## Credentials rotieren

### 1. Admin Token rotieren

```bash
# Auf einem Swarm Manager:

# Alten Token entfernen + neuen erstellen
docker secret rm vaultwarden_admin_token
NEW_TOKEN=$(openssl rand -hex 32)
printf '%s' "$NEW_TOKEN" | docker secret create vaultwarden_admin_token -

# Service neu starten (liest Secret beim Start)
docker service update --force vaultwarden_vaultwarden

echo "Neuer Admin Token: $NEW_TOKEN"
```

### 2. DB-Passwort rotieren

```bash
# Auf einem Swarm Manager:

# 1. Neues Passwort generieren
NEW_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

# 2. In PostgreSQL aendern
docker run --rm \
  --network postgres-ha-stack_postgres-network \
  --secret pg_superuser_password \
  postgres:16-alpine sh -c "
    export PGPASSWORD=\$(cat /run/secrets/pg_superuser_password)
    psql -h pg-haproxy -p 5433 -U postgres \
      -c \"ALTER USER vaultwarden WITH PASSWORD '$NEW_PASS'\"
  "

# 3. Docker Secret aktualisieren
docker secret rm vaultwarden_db_password
printf '%s' "$NEW_PASS" | docker secret create vaultwarden_db_password -

# 4. Vaultwarden + db-init neu starten
docker service update --force vaultwarden_vaultwarden
docker service update --force postgres-ha-stack_db-init
```

### 3. Frigate Sync-Credentials rotieren (svc-frigate API Key)

Wenn der API Key des `svc-frigate` Users in Vaultwarden rotiert wird:

```bash
# 1. In Vaultwarden Web Vault:
#    Login als svc-frigate -> Settings -> Security -> Keys -> Rotate API Key
#    Neuen client_id + client_secret notieren

# 2. Auf Frigate-LXC (192.168.4.61):
ssh root@192.168.4.61

# bw-api.env aktualisieren
cat > /etc/frigate/bw-api.env <<'EOF'
BW_CLIENTID=user.NEUE-CLIENT-ID
BW_CLIENTSECRET=NEUES-CLIENT-SECRET
BW_PASSWORD=MASTER-PASSWORT-DES-SVC-FRIGATE-USERS
EOF
chmod 600 /etc/frigate/bw-api.env

# Alten bw-State loeschen (erzwingt Re-Login)
rm -rf /root/.config/'Bitwarden CLI'/data.json

# Sync testen
/usr/local/sbin/frigate-secrets-sync
```

### 4. svc-frigate Master-Passwort rotieren

```bash
# 1. In Vaultwarden Web Vault:
#    Login als svc-frigate -> Settings -> Security -> Change Master Password
#    ACHTUNG: Danach wird automatisch ein neuer API Key generiert!

# 2. Neuen API Key holen:
#    Settings -> Security -> Keys -> View API Key

# 3. Auf Frigate-LXC alle drei Werte aktualisieren:
ssh root@192.168.4.61
cat > /etc/frigate/bw-api.env <<'EOF'
BW_CLIENTID=user.NEUE-CLIENT-ID
BW_CLIENTSECRET=NEUES-CLIENT-SECRET
BW_PASSWORD=NEUES-MASTER-PASSWORT
EOF
chmod 600 /etc/frigate/bw-api.env
rm -rf /root/.config/'Bitwarden CLI'/data.json
/usr/local/sbin/frigate-secrets-sync
```

## Architektur

```
Vaultwarden (Swarm)          Frigate-Prod (LXC 4501)
+------------------+         +-------------------------+
| Web Vault :8080  |         | /etc/frigate/bw-api.env |
| PostgreSQL DB    |  bw CLI | /etc/frigate/secrets.env|
| CephFS /data     |<--------| frigate-secrets-sync    |
| Traefik TLS      |  daily  | systemd timer (03:00)   |
+------------------+         +-------------------------+
                              |
                              | env_file
                              v
                              Frigate Container
```

**Fail-safe:** Wenn Vaultwarden nicht erreichbar ist, bleibt die bestehende
`secrets.env` unangetastet. Frigate startet auch nach Reboot ohne Vaultwarden.

## Dateien

| Datei | Zweck |
|-------|-------|
| `vaultwarden-stack.yml` | Docker Swarm Stack Definition |
| `entrypoint-wrapper.sh` | Liest Secrets, setzt DATABASE_URL + ADMIN_TOKEN |
| `create-secrets.sh` | Erstellt Docker Secrets (einmalig) |
| `init-frigate-lxc.sh` | Bootstrap: SSH zum LXC, schreibt Credentials, erster Sync |
| `../frigate-prod/frigate-secrets-sync` | bw CLI Sync-Script (atomisch, fail-safe) |
| `../frigate-prod/frigate-secrets-sync.service` | systemd oneshot Service |
| `../frigate-prod/frigate-secrets-sync.timer` | Taeglicher Timer |
