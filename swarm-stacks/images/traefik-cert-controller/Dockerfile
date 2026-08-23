# =============================================================================
# traefik-cert-controller — "cert-manager light" fuer Docker Swarm
# =============================================================================
# Liest Traefik-Router-Labels aus der Swarm-API, leitet daraus die benoetigten
# Zertifikate ab und laesst lego sie ausstellen. Traefik selbst betreibt kein
# ACME mehr.
#
# lego wird NICHT nachgebaut, sondern als Binary uebernommen: ACME-Protokoll
# und DNS-Challenge selbst zu implementieren waere das Riskanteste an der
# ganzen Konstruktion. Es ist dieselbe Bibliothek, die Traefik intern nutzt —
# die DNS-Provider-Semantik bleibt damit identisch zu vorher.
# =============================================================================

FROM goacme/lego:v4.17.4 AS lego

FROM python:3.12-alpine

# openssl fuer die Ablaufpruefung. Das lego-Image bringt es nicht mit, und
# `date -d` scheitert unter BusyBox am OpenSSL-Datumsformat — der Weg ueber
# `openssl x509 -checkend` braucht weder Locale noch coreutils.
RUN apk add --no-cache openssl ca-certificates \
    && pip install --no-cache-dir --root-user-action=ignore docker==7.1.0

COPY --from=lego /lego /usr/local/bin/lego
COPY cert_controller.py /app/cert_controller.py
# Die Tests wandern mit ins Image: Der Smoke-Test im Build fuehrt sie im
# tatsaechlich veroeffentlichten Image aus, und sie bleiben spaeter zur Hand,
# um nach einem Update die Kernlogik zu pruefen, ohne das Repo zu brauchen:
#   docker run --rm --entrypoint python -e ACME_EMAIL=x@y.invalid \
#     <image> /app/test_cert_controller.py
COPY test_cert_controller.py /app/test_cert_controller.py

# Unbuffered: Ohne das erscheinen die Logzeilen erst beim Beenden im
# `docker service logs` — bei einem Dauerlaeufer also nie.
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/cert_controller.py"]
