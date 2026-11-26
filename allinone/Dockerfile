# syntax=docker/dockerfile:1.7
#
# Image tout-en-un Nuvio (EXPÉRIMENTALE).
#
# Principe : on part de l'image PostgreSQL de Supabase et on y ajoute, chacun dans
# son propre dossier /opt/<service>, le système de fichiers complet de l'image
# officielle de chaque service. nuvio-entrypoint lance ensuite chaque service dans
# un chroot, avec l'ENTRYPOINT, le CMD et l'environnement de son image d'origine.
# Aucune bibliothèque n'est mélangée entre services.
#
# Construction : contexte = racine du dépôt, et les fichiers allinone/svc/*.json
# doivent exister. Passez par allinone/build.sh ou par le workflow GitHub
# "Publish all-in-one image", qui les génèrent avant la construction.
#
#   ./allinone/build.sh
#
# Les versions ci-dessous sont celles de compose.yml : à mettre à jour ensemble.

ARG DB_IMAGE=supabase/postgres:17.6.1.084
ARG AUTH_IMAGE=supabase/gotrue:v2.189.0
ARG REST_IMAGE=postgrest/postgrest:v14.12
ARG STORAGE_IMAGE=supabase/storage-api:v1.60.4
ARG FUNCTIONS_IMAGE=supabase/edge-runtime:v1.74.0
ARG DASHBOARD_IMAGE=ghcr.io/nuviomedia/nuvio-account-dashboard:latest
ARG CADDY_IMAGE=caddy:2.10.0

FROM ${AUTH_IMAGE} AS auth
FROM ${REST_IMAGE} AS rest
FROM ${STORAGE_IMAGE} AS storage
FROM ${FUNCTIONS_IMAGE} AS functions
FROM ${DASHBOARD_IMAGE} AS dashboard
FROM ${CADDY_IMAGE} AS caddy

FROM ${DB_IMAGE}

# Root est nécessaire : le point d'entrée utilise chroot pour isoler chaque service.
# hadolint ignore=DL3002,DL3066
USER root

# Outils requis par le point d'entrée. L'image Supabase est basée sur Alpine
# (pas d'apt) et n'embarque ni jq ni openssl : on installe ce qui manque avec apk.
RUN set -eu; \
    export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; \
    check() { missing=""; for tool in bash curl jq openssl psql mountpoint chroot mknod sed grep; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done; }; \
    check; \
    echo "outils manquants :${missing:- aucun}"; \
    if [ -n "$missing" ]; then \
        if command -v apk >/dev/null 2>&1; then \
            apk add --no-cache bash ca-certificates curl jq openssl; \
        elif command -v apt-get >/dev/null 2>&1; then \
            apt-get update; \
            apt-get install -y --no-install-recommends bash ca-certificates curl jq openssl; \
            rm -rf /var/lib/apt/lists/*; \
        else \
            echo "ni apk ni apt-get : impossible d'installer :$missing" >&2; exit 1; \
        fi; \
        check; \
        [ -z "$missing" ] || { echo "outils toujours manquants :$missing" >&2; exit 1; }; \
    fi

# Passerelle HTTP (remplace Kong)
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

# Système de fichiers complet de chaque service, lancé en chroot
COPY --from=auth / /opt/auth/
COPY --from=rest / /opt/rest/
COPY --from=storage / /opt/storage/
COPY --from=functions / /opt/functions/
COPY --from=dashboard / /opt/dashboard/

# Fonctions Edge de Nuvio (monté dans compose.yml sur /home/deno/functions)
COPY volumes/functions/ /opt/functions/home/deno/functions/

# Dossier des fichiers de Storage : à monter depuis l'extérieur pour persister
RUN mkdir -p /opt/storage/var/lib/storage

# Scripts d'initialisation de la base (mêmes destinations que dans compose.yml)
COPY --chmod=0644 volumes/db/realtime.sql  /docker-entrypoint-initdb.d/migrations/99-realtime.sql
COPY --chmod=0644 volumes/db/webhooks.sql  /docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql
COPY --chmod=0644 volumes/db/roles.sql     /docker-entrypoint-initdb.d/init-scripts/99-roles.sql
COPY --chmod=0644 volumes/db/jwt.sql       /docker-entrypoint-initdb.d/init-scripts/99-jwt.sql
COPY --chmod=0644 volumes/db/_supabase.sql /docker-entrypoint-initdb.d/migrations/97-_supabase.sql
COPY --chmod=0644 volumes/db/logs.sql      /docker-entrypoint-initdb.d/migrations/99-logs.sql
COPY --chmod=0644 volumes/db/pooler.sql    /docker-entrypoint-initdb.d/migrations/99-pooler.sql
COPY --chmod=0644 database/migrations/00000000000000_baseline.sql     /docker-entrypoint-initdb.d/migrations/99999999990000-nuvio-baseline.sql
COPY --chmod=0644 database/migrations/00000000000001_auth_trigger.sql /docker-entrypoint-initdb.d/migrations/99999999990001-nuvio-auth-trigger.sql

# Migrations suivantes, avatars, configuration des services, passerelle, script d'entrée
COPY database/migrations/ /opt/nuvio/database/migrations/
COPY assets/avatars/ /opt/nuvio/assets/avatars/
COPY allinone/svc/ /opt/nuvio/svc/
COPY allinone/Caddyfile /opt/nuvio/Caddyfile
COPY --chmod=0755 allinone/nuvio-entrypoint.sh /usr/local/bin/nuvio-entrypoint

# Copie d'origine du dossier de clés pgsodium, pour initialiser un volume vide
RUN if [ -d /etc/postgresql-custom ]; then cp -a /etc/postgresql-custom /opt/nuvio/postgresql-custom.seed; fi \
    && ln -s /usr/local/bin/nuvio-entrypoint /usr/local/bin/nuvio \
    && for f in db auth rest storage functions dashboard; do \
         test -s "/opt/nuvio/svc/$f.json" || { echo "allinone/svc/$f.json manquant : lancez allinone/scripts/extract-image-config.sh" >&2; exit 1; }; \
       done

ENV NUVIO_HOME=/opt/nuvio \
    NUVIO_DATA_DIR=/data \
    NUVIO_PUBLIC_URL=http://localhost:8000

# 8000 : API et tableau de bord. 80 et 443 : uniquement avec NUVIO_AUTO_HTTPS=true.
EXPOSE 8000
VOLUME ["/data", "/var/lib/postgresql/data", "/opt/storage/var/lib/storage"]

HEALTHCHECK --interval=30s --timeout=15s --start-period=300s --retries=5 \
    CMD ["/usr/local/bin/nuvio", "healthcheck"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/nuvio-entrypoint"]
CMD ["run"]
