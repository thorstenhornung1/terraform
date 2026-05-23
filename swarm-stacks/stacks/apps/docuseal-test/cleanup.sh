#!/bin/bash
# =============================================================================
# DocuSeal Test-Stack — Rückstandsfreie Entfernung
# =============================================================================
# Auszuführen auf einem Swarm Manager, der gleichzeitig der Node mit
# infra_node==1 Label ist (typisch: docker-infra-1, 192.168.4.40).
#
# Entfernt: Stack, Network (auto via stack rm), Volumes (nur auf dem
#           lokalen Node — Single-Node-Pin macht das OK).
#
# Keine Secrets oder Configs in diesem Stack — Credentials sind inline
# im Compose-File (bewusster Wegwerf-Modus). Dieses Skript entfernt
# daher nur Stack + Volumes.
#
# Vorab-Check der zu erwartenden Reste:
#   docker stack services docuseal_test
#   docker volume ls --filter name=docuseal_test_
# =============================================================================

set -euo pipefail

STACK_NAME="docuseal_test"
VOLUMES=("docuseal_test_db_data" "docuseal_test_app_data")

echo "==================================================================="
echo "DocuSeal Test-Stack Cleanup"
echo "==================================================================="
echo "Folgende Ressourcen werden ENTFERNT:"
echo
echo "Stack:    $STACK_NAME"
echo "Volumes:  ${VOLUMES[*]} (mit ALLEN Daten — Postgres-DB, Uploads)"
echo "Network:  docuseal_test_internal (auto-removed via stack rm)"
echo
read -r -p "Wirklich entfernen? Tippe 'JA' zur Bestätigung: " CONFIRM
if [ "$CONFIRM" != "JA" ]; then
  echo "Abgebrochen."
  exit 0
fi

echo
echo "[1/2] Entferne Stack '$STACK_NAME'..."
if docker stack ls --format '{{.Name}}' | grep -qx "$STACK_NAME"; then
  docker stack rm "$STACK_NAME"
  echo "      Warte 20s auf Service-Termination..."
  sleep 20
else
  echo "      Stack existiert nicht — übersprungen."
fi

echo
echo "[2/2] Entferne Volumes (Daten werden gelöscht!)..."
for v in "${VOLUMES[@]}"; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    docker volume rm "$v" && echo "      rm: $v" \
      || echo "      WARN: $v noch in Verwendung — wiederhole nach manuellem stack-rm-Check"
  else
    echo "      $v existiert nicht — übersprungen."
  fi
done

echo
echo "==================================================================="
echo "Cleanup abgeschlossen. Verifikation:"
echo "==================================================================="
echo "Stack:   $(docker stack ls --format '{{.Name}}' | grep -c "^$STACK_NAME\$" || true) Treffer (erwartet: 0)"
echo "Volumes: $(docker volume ls --format '{{.Name}}' | grep -c '^docuseal_test_' || true) Treffer (erwartet: 0)"
echo
echo "Zusätzlich entfernen (manuell, falls erstellt):"
echo "  - DNS-Eintrag test.hornung-bn.de (falls nicht weiter genutzt)"
echo "  - Compose-Datei + Verzeichnis: rm -rf stacks/apps/docuseal-test"
echo "  - webhooks.conf-Zeile entfernen"
