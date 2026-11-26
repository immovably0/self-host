#!/usr/bin/env bash
# Point d'entrée de l'image tout-en-un Nuvio.
#
# Rôle : générer et conserver les secrets, démarrer PostgreSQL, Auth, PostgREST,
# Storage, les fonctions Edge, le tableau de bord et Caddy dans un seul
# conteneur, appliquer les migrations Nuvio, puis superviser l'ensemble.
#
# Sous-commandes : run (défaut) | doctor | credentials | healthcheck
#
# STATUT : expérimental, non testé de bout en bout (voir allinone/README.md).

set -uo pipefail

NUVIO_HOME=${NUVIO_HOME:-/opt/nuvio}
DATA_DIR=${NUVIO_DATA_DIR:-/data}
SECRETS_FILE="$DATA_DIR/secrets.env"
GATEWAY_URL="http://127.0.0.1:8001"
DASHBOARD_URL="http://127.0.0.1:8080"

CHROOT_BIN=chroot
CHROOT_SKIP_CHDIR=0
declare -A PIDS=()
declare -A SAVED=()
SECRET_NAMES=(POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET)
RESERVED_PORTS=" 3000 3001 5000 5432 8001 8080 9000 9999 "

log() { printf '[nuvio] %s\n' "$*" >&2; }
die() { log "ERREUR : $*"; exit 1; }

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

sign_jwt() {
    local role=$1 header payload signature
    header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$JWT_IAT" "$JWT_EXP_AT" | b64url)
    signature=$(printf '%s' "$header.$payload" | openssl dgst -binary -sha256 -hmac "$JWT_SECRET" | b64url)
    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

gen_postgres_password() { openssl rand -hex 24; }
gen_jwt_secret()        { openssl rand -hex 32; }
gen_anon_key()          { sign_jwt anon; }
gen_service_key()       { sign_jwt service_role; }
gen_s3_key_id()         { openssl rand -hex 16; }
gen_s3_key_secret()     { openssl rand -hex 32; }

load_saved_secrets() {
    [ -f "$SECRETS_FILE" ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            SAVED[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        fi
    done < "$SECRETS_FILE"
}

# Priorité : fichier déjà enregistré > variable d'environnement > génération.
# Le fichier prime car le mot de passe de la base et les clés JWT sont figés
# au premier démarrage : les changer plus tard casserait l'installation.
resolve_secret() {
    local name=$1 generator=$2 current=${!1:-}
    if [ -n "${SAVED[$name]:-}" ]; then
        if [ -n "$current" ] && [ "$current" != "${SAVED[$name]}" ]; then
            log "ATTENTION : $name défini dans l'environnement est ignoré, la valeur enregistrée dans $SECRETS_FILE est conservée."
        fi
        printf -v "$name" '%s' "${SAVED[$name]}"
    elif [ -z "$current" ]; then
        printf -v "$name" '%s' "$("$generator")"
    fi
    case "${!name}" in
        *$'\n'*|*$'\r'*) die "$name ne doit pas contenir de saut de ligne" ;;
    esac
    export "${name?}"
}

persist_secrets() {
    local tmp="$SECRETS_FILE.tmp" name
    ( umask 077; : > "$tmp" ) || die "impossible d'écrire dans $DATA_DIR"
    for name in "${SECRET_NAMES[@]}"; do
        printf '%s=%s\n' "$name" "${!name}" >> "$tmp"
    done
    chmod 600 "$tmp"
    mv "$tmp" "$SECRETS_FILE"
}

setup_secrets() {
    mkdir -p "$DATA_DIR" || die "impossible de créer $DATA_DIR"
    load_saved_secrets
    JWT_IAT=$(date +%s)
    JWT_EXP_AT=$((JWT_IAT + 5 * 365 * 24 * 60 * 60))
    resolve_secret POSTGRES_PASSWORD gen_postgres_password
    resolve_secret JWT_SECRET gen_jwt_secret
    resolve_secret ANON_KEY gen_anon_key
    resolve_secret SERVICE_ROLE_KEY gen_service_key
    resolve_secret S3_PROTOCOL_ACCESS_KEY_ID gen_s3_key_id
    resolve_secret S3_PROTOCOL_ACCESS_KEY_SECRET gen_s3_key_secret

    # Le mot de passe est inséré tel quel dans des URL de connexion.
    [[ "$POSTGRES_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]] \
        || die "POSTGRES_PASSWORD ne peut contenir que des lettres, chiffres et . _ ~ -"

    persist_secrets
}

# Relit le fichier de secrets (utilisé par doctor, credentials, healthcheck).
load_secrets_readonly() {
    [ -f "$SECRETS_FILE" ] || die "$SECRETS_FILE introuvable : le conteneur n'a pas encore démarré"
    load_saved_secrets
    ANON_KEY=${SAVED[ANON_KEY]:-}
    SERVICE_ROLE_KEY=${SAVED[SERVICE_ROLE_KEY]:-}
    [ -n "$ANON_KEY" ] || die "ANON_KEY absente de $SECRETS_FILE"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

setup_config() {
    [ "$(id -u)" -eq 0 ] || die "le conteneur doit tourner en root (chroot des services)"

    : "${NUVIO_PUBLIC_URL:=http://localhost:8000}"
    : "${NUVIO_HTTP_PORT:=8000}"
    : "${NUVIO_AUTO_HTTPS:=false}"
    : "${NUVIO_SITE_URL:=https://nuvio.tv}"
    : "${DEFAULT_CATALOG_URL:=https://catalog.nuvio.tv/manifest.json}"

    NUVIO_PUBLIC_URL=${NUVIO_PUBLIC_URL%/}
    [[ "$NUVIO_PUBLIC_URL" =~ ^(https?)://([A-Za-z0-9.-]+)(:[0-9]+)?$ ]] \
        || die "NUVIO_PUBLIC_URL doit ressembler à https://nuvio.exemple.fr (schéma, nom d'hôte, port facultatif, sans chemin)"
    PUBLIC_SCHEME=${BASH_REMATCH[1]}
    PUBLIC_HOST=${BASH_REMATCH[2]}

    [[ "$NUVIO_HTTP_PORT" =~ ^[0-9]+$ ]] && [ "$NUVIO_HTTP_PORT" -ge 1 ] && [ "$NUVIO_HTTP_PORT" -le 65535 ] \
        || die "NUVIO_HTTP_PORT doit être un numéro de port"
    case "$RESERVED_PORTS" in
        *" $NUVIO_HTTP_PORT "*) die "NUVIO_HTTP_PORT=$NUVIO_HTTP_PORT est réservé à un service interne" ;;
    esac

    case "$NUVIO_AUTO_HTTPS" in
        true)
            [ "$PUBLIC_SCHEME" = "https" ] || die "NUVIO_AUTO_HTTPS=true exige un NUVIO_PUBLIC_URL en https://"
            [[ "$NUVIO_PUBLIC_URL" =~ ^https://[A-Za-z0-9.-]+$ ]] || die "NUVIO_AUTO_HTTPS=true : indiquez un nom de domaine sans port"
            [[ "$PUBLIC_HOST" =~ ^[0-9.]+$ || "$PUBLIC_HOST" = "localhost" ]] && die "NUVIO_AUTO_HTTPS=true exige un vrai nom de domaine"
            NUVIO_SITE_ADDRESS=$PUBLIC_HOST
            ;;
        false) NUVIO_SITE_ADDRESS=":$NUVIO_HTTP_PORT" ;;
        *) die "NUVIO_AUTO_HTTPS doit valoir true ou false" ;;
    esac

    [[ "$DEFAULT_CATALOG_URL" =~ ^https?://[^[:space:]]+$ ]] || die "DEFAULT_CATALOG_URL doit être une URL http(s) sans espace"

    # Réglages de l'installation classique (.env.example), modifiables par variable d'environnement.
    : "${POSTGRES_DB:=postgres}"
    : "${POSTGRES_PORT:=5432}"
    : "${SITE_URL:=$NUVIO_PUBLIC_URL}"
    : "${ADDITIONAL_REDIRECT_URLS:=$NUVIO_PUBLIC_URL}"
    : "${MAILER_EXTERNAL_HOSTS:=$PUBLIC_HOST}"
    : "${WEBAUTHN_RP_ID:=$PUBLIC_HOST}"
    : "${WEBAUTHN_RP_ORIGINS:=$NUVIO_PUBLIC_URL}"
    : "${WEBAUTHN_RP_DISPLAY_NAME:=Nuvio}"
    : "${PASSKEY_ENABLED:=false}"
    : "${JWT_EXPIRY:=7200}"
    : "${DISABLE_SIGNUP:=false}"
    : "${ENABLE_EMAIL_SIGNUP:=true}"
    : "${ENABLE_EMAIL_AUTOCONFIRM:=true}"
    : "${ENABLE_ANONYMOUS_USERS:=true}"
    : "${ENABLE_PHONE_SIGNUP:=false}"
    : "${ENABLE_PHONE_AUTOCONFIRM:=false}"
    : "${MAILER_URLPATHS_CONFIRMATION:=/auth/v1/verify}"
    : "${MAILER_URLPATHS_INVITE:=/auth/v1/verify}"
    : "${MAILER_URLPATHS_RECOVERY:=/auth/v1/verify}"
    : "${MAILER_URLPATHS_EMAIL_CHANGE:=/auth/v1/verify}"
    : "${MAILER_SECURE_EMAIL_CHANGE_ENABLED:=true}"
    : "${PASSWORD_MIN_LENGTH:=6}"
    : "${AUTH_REFRESH_TOKEN_ROTATION_ENABLED:=true}"
    : "${AUTH_REFRESH_TOKEN_REUSE_INTERVAL:=120}"
    : "${RATE_LIMIT_TOKEN_REFRESH:=150}"
    : "${RATE_LIMIT_ANONYMOUS_USERS:=600}"
    : "${RATE_LIMIT_VERIFY:=3000}"
    : "${RATE_LIMIT_HEADER:=X-Forwarded-For}"
    : "${SMTP_ADMIN_EMAIL:=admin@example.com}"
    : "${SMTP_HOST:=supabase-mail}"
    : "${SMTP_PORT:=2500}"
    : "${SMTP_USER:=fake_mail_user}"
    : "${SMTP_PASS:=fake_mail_password}"
    : "${SMTP_SENDER_NAME:=Nuvio}"
    : "${MFA_TOTP_ENROLL_ENABLED:=true}"
    : "${MFA_TOTP_VERIFY_ENABLED:=true}"
    : "${MFA_MAX_ENROLLED_FACTORS:=10}"
    : "${GLOBAL_S3_BUCKET:=nuvio}"
    : "${STORAGE_TENANT_ID:=nuvio}"
    : "${REGION:=local}"
    : "${FUNCTIONS_VERIFY_JWT:=false}"
    : "${PGRST_DB_SCHEMAS:=public,storage,graphql_public}"
    : "${PGRST_DB_MAX_ROWS:=1000}"
    : "${PGRST_DB_EXTRA_SEARCH_PATH:=public}"

    export NUVIO_PUBLIC_URL NUVIO_SITE_ADDRESS
}

# ---------------------------------------------------------------------------
# Environnement de chaque service (équivalent des blocs `environment:` de compose.yml)
# ---------------------------------------------------------------------------

db_url() { printf 'postgres://%s:%s@127.0.0.1:%s/%s' "$1" "$POSTGRES_PASSWORD" "$POSTGRES_PORT" "$POSTGRES_DB"; }

env_auth() {
    cat <<EOF
GOTRUE_API_HOST=127.0.0.1
GOTRUE_API_PORT=9999
API_EXTERNAL_URL=$NUVIO_PUBLIC_URL
GOTRUE_DB_DRIVER=postgres
GOTRUE_DB_DATABASE_URL=$(db_url supabase_auth_admin)
GOTRUE_DB_MAX_POOL_SIZE=60
GOTRUE_DB_MAX_IDLE_POOL_SIZE=30
GOTRUE_DB_CONN_MAX_LIFETIME=10m
GOTRUE_DB_CONN_MAX_IDLE_TIME=2m
GOTRUE_SITE_URL=$SITE_URL
GOTRUE_URI_ALLOW_LIST=$ADDITIONAL_REDIRECT_URLS
GOTRUE_DISABLE_SIGNUP=$DISABLE_SIGNUP
GOTRUE_JWT_ADMIN_ROLES=service_role
GOTRUE_JWT_AUD=authenticated
GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
GOTRUE_JWT_EXP=$JWT_EXPIRY
GOTRUE_JWT_SECRET=$JWT_SECRET
GOTRUE_JWT_KEYS=[]
GOTRUE_JWT_ISSUER=$NUVIO_PUBLIC_URL/auth/v1
GOTRUE_EXTERNAL_EMAIL_ENABLED=$ENABLE_EMAIL_SIGNUP
GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED=$ENABLE_ANONYMOUS_USERS
GOTRUE_MAILER_AUTOCONFIRM=$ENABLE_EMAIL_AUTOCONFIRM
GOTRUE_MAILER_SECURE_EMAIL_CHANGE_ENABLED=$MAILER_SECURE_EMAIL_CHANGE_ENABLED
GOTRUE_MAILER_EXTERNAL_HOSTS=$MAILER_EXTERNAL_HOSTS
GOTRUE_PASSWORD_MIN_LENGTH=$PASSWORD_MIN_LENGTH
GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED=$AUTH_REFRESH_TOKEN_ROTATION_ENABLED
GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL=$AUTH_REFRESH_TOKEN_REUSE_INTERVAL
GOTRUE_RATE_LIMIT_TOKEN_REFRESH=$RATE_LIMIT_TOKEN_REFRESH
GOTRUE_RATE_LIMIT_ANONYMOUS_USERS=$RATE_LIMIT_ANONYMOUS_USERS
GOTRUE_RATE_LIMIT_VERIFY=$RATE_LIMIT_VERIFY
GOTRUE_RATE_LIMIT_HEADER=$RATE_LIMIT_HEADER
GOTRUE_PASSKEY_ENABLED=$PASSKEY_ENABLED
GOTRUE_WEBAUTHN_RP_ID=$WEBAUTHN_RP_ID
GOTRUE_WEBAUTHN_RP_DISPLAY_NAME=$WEBAUTHN_RP_DISPLAY_NAME
GOTRUE_WEBAUTHN_RP_ORIGINS=$WEBAUTHN_RP_ORIGINS
GOTRUE_SMTP_ADMIN_EMAIL=$SMTP_ADMIN_EMAIL
GOTRUE_SMTP_HOST=$SMTP_HOST
GOTRUE_SMTP_PORT=$SMTP_PORT
GOTRUE_SMTP_USER=$SMTP_USER
GOTRUE_SMTP_PASS=$SMTP_PASS
GOTRUE_SMTP_SENDER_NAME=$SMTP_SENDER_NAME
GOTRUE_MAILER_URLPATHS_INVITE=$MAILER_URLPATHS_INVITE
GOTRUE_MAILER_URLPATHS_CONFIRMATION=$MAILER_URLPATHS_CONFIRMATION
GOTRUE_MAILER_URLPATHS_RECOVERY=$MAILER_URLPATHS_RECOVERY
GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE=$MAILER_URLPATHS_EMAIL_CHANGE
GOTRUE_EXTERNAL_PHONE_ENABLED=$ENABLE_PHONE_SIGNUP
GOTRUE_SMS_AUTOCONFIRM=$ENABLE_PHONE_AUTOCONFIRM
GOTRUE_MFA_TOTP_ENROLL_ENABLED=$MFA_TOTP_ENROLL_ENABLED
GOTRUE_MFA_TOTP_VERIFY_ENABLED=$MFA_TOTP_VERIFY_ENABLED
GOTRUE_MFA_MAX_ENROLLED_FACTORS=$MFA_MAX_ENROLLED_FACTORS
EOF
}

env_rest() {
    cat <<EOF
PGRST_DB_URI=$(db_url authenticator)
PGRST_DB_SCHEMAS=$PGRST_DB_SCHEMAS
PGRST_DB_MAX_ROWS=$PGRST_DB_MAX_ROWS
PGRST_DB_EXTRA_SEARCH_PATH=$PGRST_DB_EXTRA_SEARCH_PATH
PGRST_DB_ANON_ROLE=anon
PGRST_SERVER_HOST=127.0.0.1
PGRST_SERVER_PORT=3000
PGRST_ADMIN_SERVER_PORT=3001
PGRST_ADMIN_SERVER_HOST=127.0.0.1
PGRST_JWT_SECRET=$JWT_SECRET
PGRST_DB_USE_LEGACY_GUCS=false
PGRST_APP_SETTINGS_JWT_SECRET=$JWT_SECRET
PGRST_APP_SETTINGS_JWT_EXP=$JWT_EXPIRY
EOF
}

env_storage() {
    cat <<EOF
ANON_KEY=$ANON_KEY
SERVICE_KEY=$SERVICE_ROLE_KEY
POSTGREST_URL=http://127.0.0.1:3000
AUTH_JWT_SECRET=$JWT_SECRET
JWT_JWKS={"keys":[]}
DATABASE_URL=$(db_url supabase_storage_admin)
STORAGE_PUBLIC_URL=$NUVIO_PUBLIC_URL
REQUEST_ALLOW_X_FORWARDED_PATH=true
FILE_SIZE_LIMIT=52428800
STORAGE_BACKEND=file
GLOBAL_S3_BUCKET=$GLOBAL_S3_BUCKET
FILE_STORAGE_BACKEND_PATH=/var/lib/storage
TENANT_ID=$STORAGE_TENANT_ID
REGION=$REGION
ENABLE_IMAGE_TRANSFORMATION=false
S3_PROTOCOL_ACCESS_KEY_ID=$S3_PROTOCOL_ACCESS_KEY_ID
S3_PROTOCOL_ACCESS_KEY_SECRET=$S3_PROTOCOL_ACCESS_KEY_SECRET
EOF
}

env_functions() {
    cat <<EOF
JWT_SECRET=$JWT_SECRET
SUPABASE_URL=$GATEWAY_URL
SUPABASE_PUBLIC_URL=$NUVIO_PUBLIC_URL
SUPABASE_ANON_KEY=$ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
SUPABASE_PUBLISHABLE_KEYS={"default":""}
SUPABASE_SECRET_KEYS={"default":""}
SUPABASE_DB_URL=$(db_url postgres)
VERIFY_JWT=$FUNCTIONS_VERIFY_JWT
EOF
}

env_dashboard() {
    cat <<EOF
NUVIO_SUPABASE_URL=$NUVIO_PUBLIC_URL
NUVIO_SUPABASE_ANON_KEY=$ANON_KEY
NUVIO_PUBLIC_SITE_URL=$NUVIO_SITE_URL
EOF
}

# ---------------------------------------------------------------------------
# Lancement des processus
# ---------------------------------------------------------------------------

# Préfixe chaque ligne de journal avec le nom du service, sans changer le PID
# du processus lancé (le sous-shell est remplacé par exec).
prefix_output() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        printf '[%s] %s\n' "$1" "$line"
    done
}

prepare_jail() {
    local root=$1 node name type major minor
    mkdir -p "$root/dev" "$root/proc" "$root/tmp" "$root/etc" "$root/root"
    chmod 1777 "$root/tmp"
    cp -f /etc/resolv.conf "$root/etc/resolv.conf" 2>/dev/null || true
    cp -f /etc/hosts "$root/etc/hosts" 2>/dev/null || true
    for node in "null c 1 3" "zero c 1 5" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
        read -r name type major minor <<< "$node"
        if [ ! -c "$root/dev/$name" ]; then
            rm -rf "${root:?}/dev/$name"
            mknod -m 666 "$root/dev/$name" "$type" "$major" "$minor" 2>/dev/null \
                || log "ATTENTION : impossible de créer $root/dev/$name"
        fi
    done
    # /proc n'est disponible que si le conteneur a CAP_SYS_ADMIN ; sinon on continue sans.
    if ! mountpoint -q "$root/proc" 2>/dev/null; then
        mount -t proc proc "$root/proc" 2>/dev/null || true
    fi
}

# start_jail NOM [ARGUMENTS...]
# Lance le service NOM dans son propre système de fichiers (/opt/NOM) avec
# l'ENTRYPOINT, le répertoire de travail et l'environnement de son image
# d'origine (svc/NOM.json). Les ARGUMENTS remplacent le CMD de l'image,
# comme `command:` dans compose.
start_jail() {
    local name=$1; shift
    local root="/opt/$name" cfg="$NUVIO_HOME/svc/$name.json"
    [ -d "$root" ] || die "système de fichiers du service $name introuvable ($root)"
    [ -s "$cfg" ] || die "configuration d'image $cfg introuvable (l'image doit être construite avec allinone/scripts/extract-image-config.sh)"

    prepare_jail "$root"

    local -a entry=() cmd=() image_env=() extra_env=()
    local workdir
    mapfile -t entry < <(jq -r '(.Entrypoint // [])[]' "$cfg")
    if [ $# -gt 0 ]; then
        cmd=("$@")
    else
        mapfile -t cmd < <(jq -r '(.Cmd // [])[]' "$cfg")
    fi
    mapfile -t image_env < <(jq -r '(.Env // [])[]' "$cfg")
    mapfile -t extra_env < <("env_$name")
    workdir=$(jq -r '.WorkingDir // "" | if . == "" then "/" else . end' "$cfg")
    [ -d "$root$workdir" ] || workdir=/

    local -a argv=("${entry[@]}" "${cmd[@]}")
    [ ${#argv[@]} -gt 0 ] || die "aucune commande à lancer pour le service $name"

    log "démarrage de $name : ${argv[*]}"
    local -a envcmd=(env -i
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
        "${image_env[@]}" "${extra_env[@]}")
    (
        exec > >(prefix_output "$name") 2>&1
        if [ "$CHROOT_SKIP_CHDIR" -eq 1 ]; then
            # chroot GNU : on se place dans le dossier de travail avant d'entrer dans le chroot
            cd "$root$workdir" || exit 1
            exec "${envcmd[@]}" "$CHROOT_BIN" --skip-chdir "$root" "${argv[@]}"
        elif [ "$workdir" = "/" ]; then
            exec "${envcmd[@]}" "$CHROOT_BIN" "$root" "${argv[@]}"
        else
            # chroot BusyBox (Alpine) : pas d'option, on change de dossier depuis l'intérieur
            # shellcheck disable=SC2016
            exec "${envcmd[@]}" "$CHROOT_BIN" "$root" /bin/sh -c 'cd "$1" || exit 1; shift; exec "$@"' sh "$workdir" "${argv[@]}"
        fi
    ) &
    PIDS[$name]=$!
}

# start_loader NOM [ARGUMENTS...]
# Variante sans chroot, pour les services qui ont besoin de /proc (fonctions Edge) :
# le binaire de l'image est lancé avec le chargeur dynamique (ld.so) et les
# bibliothèques de cette image, sans les mélanger avec celles de l'image de base.
start_loader() {
    local name=$1; shift
    local root="/opt/$name" cfg="$NUVIO_HOME/svc/$name.json"
    [ -d "$root" ] || die "système de fichiers du service $name introuvable ($root)"
    [ -s "$cfg" ] || die "configuration d'image $cfg introuvable"

    local -a entry=() cmd=() image_env=() extra_env=()
    mapfile -t entry < <(jq -r '(.Entrypoint // [])[]' "$cfg")
    if [ $# -gt 0 ]; then
        cmd=("$@")
    else
        mapfile -t cmd < <(jq -r '(.Cmd // [])[]' "$cfg")
    fi
    mapfile -t image_env < <(jq -r '(.Env // [])[]' "$cfg")
    mapfile -t extra_env < <("env_$name")

    local bin=${entry[0]:-} binary="" dir
    [ -n "$bin" ] || die "le service $name n'a pas d'ENTRYPOINT : lancement sans chroot impossible"
    if [[ "$bin" = /* ]]; then
        binary="$root$bin"
    else
        for dir in usr/local/sbin usr/local/bin usr/sbin usr/bin sbin bin; do
            if [ -x "$root/$dir/$bin" ]; then binary="$root/$dir/$bin"; break; fi
        done
    fi
    [ -x "$binary" ] || die "binaire $bin introuvable dans $root"

    local loader="" libpath cand
    for cand in "$root"/lib64/ld-linux-*.so.* "$root"/lib/ld-linux-*.so.* \
        "$root"/lib/*-linux-gnu/ld-linux-*.so.* "$root"/usr/lib/*-linux-gnu/ld-linux-*.so.*; do
        if [ -e "$cand" ]; then loader=$cand; break; fi
    done
    [ -n "$loader" ] || die "chargeur dynamique (ld-linux) introuvable dans $root"
    libpath="$root/lib:$root/lib64:$root/usr/lib:$root/usr/lib64:$root/usr/local/lib"
    for dir in "$root"/lib/*-linux-gnu "$root"/usr/lib/*-linux-gnu; do
        [ -d "$dir" ] && libpath="$libpath:$dir"
    done

    # Certains runtimes déduisent leur dossier de travail du nom de leur exécutable
    # (/proc/self/exe) : on lance donc une copie du chargeur portant le nom d'origine du binaire.
    local launcher="/run/nuvio-loader/$name/${bin##*/}"
    mkdir -p "${launcher%/*}"
    cp -f "$loader" "$launcher"
    chmod 0755 "$launcher"

    local -a argv=("${entry[@]:1}" "${cmd[@]}")
    local -a envcmd=(env -i
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
        "${image_env[@]}" "${extra_env[@]}")
    log "démarrage de $name (sans chroot) : $bin ${argv[*]}"
    (
        exec > >(prefix_output "$name") 2>&1
        exec "${envcmd[@]}" "$launcher" --library-path "$libpath" "$binary" "${argv[@]}"
    ) &
    PIDS[$name]=$!
}

find_db_entrypoint() {
    local cfg="$NUVIO_HOME/svc/db.json" candidate
    DB_ENTRY=()
    if [ -s "$cfg" ]; then
        mapfile -t DB_ENTRY < <(jq -r '(.Entrypoint // [])[]' "$cfg")
    fi
    [ ${#DB_ENTRY[@]} -gt 0 ] && return 0
    for candidate in docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh /docker-entrypoint.sh; do
        if command -v "$candidate" >/dev/null 2>&1; then
            DB_ENTRY=("$candidate")
            return 0
        fi
    done
    die "point d'entrée de PostgreSQL introuvable (ni svc/db.json, ni docker-entrypoint.sh)"
}

setup_db_dirs() {
    # Clé pgsodium : doit persister entre les redémarrages (volume nommé dans compose.yml).
    local keydir=/etc/postgresql-custom persisted="$DATA_DIR/postgresql-custom"
    mkdir -p "$persisted"
    if [ -d "$NUVIO_HOME/postgresql-custom.seed" ] && [ -z "$(ls -A "$persisted" 2>/dev/null)" ]; then
        cp -a "$NUVIO_HOME/postgresql-custom.seed/." "$persisted/"
    fi
    if mountpoint -q "$keydir" 2>/dev/null; then
        if [ -d "$NUVIO_HOME/postgresql-custom.seed" ] && [ -z "$(ls -A "$keydir" 2>/dev/null)" ]; then
            cp -a "$NUVIO_HOME/postgresql-custom.seed/." "$keydir/"
        fi
    elif [ ! -L "$keydir" ]; then
        rm -rf "$keydir"
        ln -s "$persisted" "$keydir"
    fi
    chown -R postgres:postgres "$persisted" 2>/dev/null || true

    # Données PostgreSQL : le dossier doit appartenir à l'utilisateur postgres.
    local pgdata=/var/lib/postgresql/data
    mkdir -p "$pgdata"
    chown postgres:postgres "$pgdata" 2>/dev/null || true
    chmod 700 "$pgdata" 2>/dev/null || true

    # Stockage de fichiers de Storage (dossier à monter dans le chroot du service).
    mkdir -p /opt/storage/var/lib/storage
}

start_db() {
    find_db_entrypoint
    setup_db_dirs
    log "démarrage de postgres : ${DB_ENTRY[*]} postgres"
    (
        exec > >(prefix_output db) 2>&1
        export POSTGRES_HOST=/var/run/postgresql
        export PGPORT=$POSTGRES_PORT
        export PGPASSWORD=$POSTGRES_PASSWORD
        export PGDATABASE=$POSTGRES_DB
        export JWT_EXP=$JWT_EXPIRY
        exec "${DB_ENTRY[@]}" postgres \
            -c config_file=/etc/postgresql/postgresql.conf \
            -c log_min_messages=fatal
    ) &
    PIDS[db]=$!
}

start_caddy() {
    export XDG_DATA_HOME="$DATA_DIR/caddy/data" XDG_CONFIG_HOME="$DATA_DIR/caddy/config"
    mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
    log "démarrage de caddy (adresse publique : $NUVIO_SITE_ADDRESS)"
    (
        exec > >(prefix_output caddy) 2>&1
        exec caddy run --config "$NUVIO_HOME/Caddyfile" --adapter caddyfile
    ) &
    PIDS[caddy]=$!
}

# ---------------------------------------------------------------------------
# Attentes et tâches de démarrage
# ---------------------------------------------------------------------------

PG_HOST=""

psql_admin() {
    PGPASSWORD=$POSTGRES_PASSWORD psql -X -v ON_ERROR_STOP=1 \
        -h "$PG_HOST" -p "$POSTGRES_PORT" -U supabase_admin -d "$POSTGRES_DB" "$@"
}

wait_for_db() {
    local host
    log "attente de PostgreSQL (la première initialisation peut durer plusieurs minutes)"
    for _ in $(seq 1 900); do
        for host in 127.0.0.1 /var/run/postgresql; do
            if PGPASSWORD=$POSTGRES_PASSWORD psql -X -h "$host" -p "$POSTGRES_PORT" -U supabase_admin -d "$POSTGRES_DB" -Atqc \
                "select exists(select 1 from nuvio_migrations.schema_migrations where version = '00000000000000')" 2>/dev/null | grep -qx t; then
                PG_HOST=$host
                log "PostgreSQL prêt (connexion via $PG_HOST)"
                return 0
            fi
        done
        kill -0 "${PIDS[db]}" 2>/dev/null || die "PostgreSQL s'est arrêté pendant le démarrage"
        sleep 1
    done
    die "PostgreSQL n'est pas prêt après 15 minutes"
}

wait_for_url() {
    local label=$1 timeout=$2; shift 2
    for _ in $(seq 1 "$timeout"); do
        if curl -fsS -o /dev/null --max-time 5 "$@" 2>/dev/null; then
            log "OK  $label"
            return 0
        fi
        sleep 1
    done
    log "ÉCHEC $label (pas de réponse après ${timeout}s)"
    return 1
}

run_migrations() {
    local file name version table_exists applied
    for file in "$NUVIO_HOME"/database/migrations/*.sql; do
        [ -f "$file" ] || continue
        name=$(basename "$file")
        version=${name%%_*}
        table_exists=$(psql_admin -Atc "select to_regclass('nuvio_migrations.schema_migrations') is not null" 2>/dev/null || true)
        applied=f
        if [ "$table_exists" = t ]; then
            applied=$(psql_admin -Atc "select exists(select 1 from nuvio_migrations.schema_migrations where version = '$version')" 2>/dev/null || true)
        fi
        [ "$applied" = t ] && continue
        log "application de la migration $name"
        psql_admin -f "$file" || die "la migration $name a échoué"
    done
}

configure_instance() {
    psql_admin -v "catalog_url=$DEFAULT_CATALOG_URL" <<'SQL' || die "configuration de l'instance impossible"
INSERT INTO nuvio_private.instance_settings (key, value, updated_at)
VALUES ('default_catalog_url', :'catalog_url', now())
ON CONFLICT (key) DO UPDATE
SET value = excluded.value,
    updated_at = excluded.updated_at;
SQL
}

seed_avatar_assets() {
    local dir="$NUVIO_HOME/assets/avatars" asset name url count=0 uploaded=0 response
    [ -d "$dir" ] || { log "ATTENTION : dossier d'avatars absent ($dir)"; return 0; }
    for asset in "$dir"/*.png; do
        [ -f "$asset" ] || continue
        name=$(basename "$asset")
        count=$((count + 1))
        url="$GATEWAY_URL/storage/v1/object"
        if curl -fsSI -o /dev/null "$url/public/avatars/$name" 2>/dev/null; then
            continue
        fi
        response=$(mktemp)
        if ! curl --fail-with-body -sS -o "$response" -X POST \
            -H "apikey: $SERVICE_ROLE_KEY" \
            -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
            -H "Content-Type: image/png" \
            -H "Cache-Control: public, max-age=31536000, immutable" \
            -H "x-upsert: true" \
            --data-binary "@$asset" "$url/avatars/$name"; then
            log "ERREUR : échec de l'envoi de l'avatar $name"
            [ -s "$response" ] && cat "$response" >&2
            rm -f "$response"
            return 1
        fi
        rm -f "$response"
        uploaded=$((uploaded + 1))
    done
    log "OK  Avatars ($count présents, $uploaded envoyés)"
}

# Exécute une vérification et mémorise l'échec dans CHECK_FAILED.
check() {
    local label=$1; shift
    if "$@" > /dev/null 2>&1; then
        log "OK  $label"
    else
        log "ÉCHEC $label"
        CHECK_FAILED=1
    fi
}

# Équivalent de `./nuvio doctor`, via la passerelle interne.
check_services() {
    local json
    CHECK_FAILED=0
    check "Tableau de bord" curl -fsS "$DASHBOARD_URL/account/login"

    json=$(curl -fsS "$GATEWAY_URL/.well-known/nuvio" 2>/dev/null || true)
    if grep -Fq '"service":"nuvio"' <<< "$json" && grep -Fq "\"backend_url\":\"$NUVIO_PUBLIC_URL\"" <<< "$json"; then
        log "OK  Découverte du backend"
    else
        log "ÉCHEC Découverte du backend"
        CHECK_FAILED=1
    fi

    check "Auth" curl -fsS -H "apikey: $ANON_KEY" "$GATEWAY_URL/auth/v1/health"
    check "Base de données et API REST" curl -fsS -X POST -H "apikey: $ANON_KEY" \
        -H "Authorization: Bearer $ANON_KEY" "$GATEWAY_URL/rest/v1/rpc/health_ping"
    check "Storage" curl -fsS -H "apikey: $ANON_KEY" "$GATEWAY_URL/storage/v1/status"
    check "Fonctions Edge" curl -fsS -H "apikey: $ANON_KEY" \
        -H "Authorization: Bearer $ANON_KEY" "$GATEWAY_URL/functions/v1/health-check"
    return "$CHECK_FAILED"
}

print_credentials() {
    local url=${NUVIO_PUBLIC_URL:-}
    if [ -z "$url" ]; then
        url=$(grep -F '"backend_url"' <<< "$(curl -fsS "$GATEWAY_URL/.well-known/nuvio" 2>/dev/null)" | sed -n 's/.*"backend_url":"\([^"]*\)".*/\1/p')
    fi
    cat >&2 <<EOF
[nuvio] ------------------------------------------------------------
[nuvio] Tableau de bord du compte : ${url:-<NUVIO_PUBLIC_URL>}
[nuvio] URL du backend (à saisir dans les applications Nuvio) : ${url:-<NUVIO_PUBLIC_URL>}
[nuvio] Découverte : ${url:-<NUVIO_PUBLIC_URL>}/.well-known/nuvio
[nuvio] Clé publique : $ANON_KEY
[nuvio] ------------------------------------------------------------
EOF
}

# ---------------------------------------------------------------------------
# Supervision et arrêt
# ---------------------------------------------------------------------------

stopping=0

shutdown() {
    local code=${1:-0} name pid
    [ "$stopping" -eq 0 ] || return 0
    stopping=1
    trap - TERM INT
    log "arrêt en cours"
    for name in caddy dashboard functions storage rest auth; do
        pid=${PIDS[$name]:-}
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
    done
    # PostgreSQL : arrêt rapide (SIGINT) une fois les clients fermés.
    for _ in $(seq 1 15); do
        local alive=0
        for name in caddy dashboard functions storage rest auth; do
            pid=${PIDS[$name]:-}
            [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
        done
        [ "$alive" -eq 0 ] && break
        sleep 1
    done
    for name in caddy dashboard functions storage rest auth; do
        pid=${PIDS[$name]:-}
        [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
    done
    pid=${PIDS[db]:-}
    if [ -n "$pid" ]; then
        kill -INT "$pid" 2>/dev/null
        for _ in $(seq 1 60); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$pid" 2>/dev/null
    fi
    exit "$code"
}

supervise() {
    local name pid
    while true; do
        wait -n 2>/dev/null
        for name in "${!PIDS[@]}"; do
            pid=${PIDS[$name]}
            if ! kill -0 "$pid" 2>/dev/null; then
                log "le service $name s'est arrêté de façon inattendue : arrêt du conteneur"
                shutdown 1
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Commandes
# ---------------------------------------------------------------------------

cmd_run() {
    command -v jq >/dev/null 2>&1 || die "jq est requis"
    command -v openssl >/dev/null 2>&1 || die "openssl est requis"
    command -v curl >/dev/null 2>&1 || die "curl est requis"
    CHROOT_BIN=$(command -v chroot) || die "chroot est introuvable"
    local chroot_help
    chroot_help=$("$CHROOT_BIN" --help 2>&1 || true)
    if grep -q -- '--skip-chdir' <<< "$chroot_help"; then CHROOT_SKIP_CHDIR=1; else CHROOT_SKIP_CHDIR=0; fi

    setup_config
    setup_secrets
    export POSTGRES_PASSWORD POSTGRES_DB POSTGRES_PORT

    trap 'shutdown 0' TERM INT

    start_db
    wait_for_db

    start_jail auth
    start_jail rest postgrest
    start_jail storage
    start_loader functions start --main-service /home/deno/functions/main
    start_jail dashboard
    start_caddy

    wait_for_url "Passerelle" 60 -H "apikey: $ANON_KEY" "$GATEWAY_URL/auth/v1/health" || true
    # Storage crée ses propres tables au démarrage : les migrations Nuvio en dépendent.
    wait_for_url "Storage" 300 -H "apikey: $ANON_KEY" "$GATEWAY_URL/storage/v1/status" \
        || log "ATTENTION : Storage ne répond pas, la migration du stockage risque d'échouer"
    run_migrations
    configure_instance
    seed_avatar_assets || log "ATTENTION : avatars non initialisés (le conteneur continue)"

    check_services || log "ATTENTION : certains contrôles ont échoué, consultez les journaux ci-dessus"
    print_credentials

    supervise
}

cmd_doctor() {
    load_secrets_readonly
    NUVIO_PUBLIC_URL=${NUVIO_PUBLIC_URL:-}
    if [ -z "$NUVIO_PUBLIC_URL" ]; then
        NUVIO_PUBLIC_URL=$(curl -fsS "$GATEWAY_URL/.well-known/nuvio" 2>/dev/null | sed -n 's/.*"backend_url":"\([^"]*\)".*/\1/p')
    fi
    check_services
}

cmd_credentials() {
    load_secrets_readonly
    NUVIO_PUBLIC_URL=${NUVIO_PUBLIC_URL:-}
    print_credentials
}

cmd_healthcheck() {
    load_secrets_readonly
    curl -fsS -o /dev/null --max-time 5 -H "apikey: $ANON_KEY" "$GATEWAY_URL/auth/v1/health" \
        && curl -fsS -o /dev/null --max-time 5 -X POST -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
            "$GATEWAY_URL/rest/v1/rpc/health_ping" \
        && curl -fsS -o /dev/null --max-time 5 "$DASHBOARD_URL/account/login"
}

main() {
    local command=${1:-run}
    [ $# -eq 0 ] || shift
    case "$command" in
        run) cmd_run "$@" ;;
        doctor) cmd_doctor "$@" ;;
        credentials) cmd_credentials "$@" ;;
        healthcheck) cmd_healthcheck "$@" ;;
        *) die "commande inconnue : $command (run, doctor, credentials, healthcheck)" ;;
    esac
}

# Permet de charger le fichier dans les tests sans exécuter main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
