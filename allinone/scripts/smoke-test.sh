#!/usr/bin/env bash
# Test de bout en bout de l'image tout-en-un : démarrage, contrôles de santé,
# création de compte, redémarrage du conteneur et reconnexion avec le même compte
# (ce qui prouve la persistance de la base et des secrets).
#
#   ./allinone/scripts/smoke-test.sh [image]      (défaut : nuvio-allinone:local)
#
# Nécessite Docker, curl et jq. Utilise le port local 18000.

set -euo pipefail

IMAGE=${1:-nuvio-allinone:local}
NAME=nuvio-smoke
PORT=${SMOKE_PORT:-18000}
BASE=http://127.0.0.1:$PORT
WORK=$(mktemp -d)
TIMEOUT=${SMOKE_TIMEOUT:-900}

log() { printf '[smoke] %s\n' "$*"; }

cleanup() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        log "ÉCHEC (code $code) - journaux du conteneur :"
        docker logs --tail 300 "$NAME" 2>&1 || true
        log "journaux des fonctions Edge (extrait) :"
        docker logs "$NAME" 2>&1 | grep -E '^\[functions\]|démarrage de functions' | head -n 60 || true
        docker exec "$NAME" sh -c 'ls -la /home/deno/functions /home/deno/functions/main; id -un; echo "ld: $(ls /run/nuvio-loader/functions 2>&1)"' 2>&1 || true
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # Les fichiers de la base appartiennent à un autre utilisateur : on les supprime depuis un conteneur.
    docker run --rm --entrypoint sh -v "$WORK:/work" "$IMAGE" -c 'rm -rf /work/* /work/.[!.]*' >/dev/null 2>&1 || true
    rm -rf "$WORK" 2>/dev/null || true
    exit "$code"
}
trap cleanup EXIT

mkdir -p "$WORK/app" "$WORK/pg" "$WORK/storage"

start_container() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --init -p "$PORT:8000" \
        -e NUVIO_PUBLIC_URL="$BASE" \
        -v "$WORK/app:/data" -v "$WORK/pg:/var/lib/postgresql/data" -v "$WORK/storage:/opt/storage/var/lib/storage" \
        "$IMAGE" >/dev/null
}

wait_healthy() {
    local waited=0 state status
    while [ "$waited" -lt "$TIMEOUT" ]; do
        status=$(docker inspect -f '{{.State.Status}}' "$NAME")
        [ "$status" = running ] || { log "le conteneur s'est arrêté ($status)"; return 1; }
        state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$NAME")
        if [ "$state" = healthy ]; then
            log "conteneur sain après ${waited}s"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    log "le conteneur n'est pas sain après ${TIMEOUT}s"
    return 1
}

anon_key() { docker exec "$NAME" sh -c "sed -n 's/^ANON_KEY=//p' /data/secrets.env"; }

log "démarrage de $IMAGE"
start_container
wait_healthy

log "contrôles de l'installation (nuvio doctor)"
docker exec "$NAME" nuvio doctor

ANON=$(anon_key)
[ -n "$ANON" ] || { log "clé publique introuvable"; exit 1; }

log "découverte et tableau de bord via le port public"
curl -fsS "$BASE/.well-known/nuvio" | jq -e '.service == "nuvio" and .publishable_key != null' >/dev/null
curl -fsS -o /dev/null "$BASE/account/login"

log "une requête sans clé doit être refusée"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/rest/v1/")
[ "$code" = 401 ] || { log "attendu 401, reçu $code"; exit 1; }

EMAIL="smoke-$(date +%s)@example.com"
PASSWORD="Smoke-test-$(date +%s)"
log "création d'un compte"
curl -fsS -X POST "$BASE/auth/v1/signup" \
    -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" \
    | jq -e '.access_token != null' >/dev/null

log "redémarrage du conteneur"
docker restart "$NAME" >/dev/null
wait_healthy

log "reconnexion avec le même compte après redémarrage"
ANON_AFTER=$(anon_key)
[ "$ANON" = "$ANON_AFTER" ] || { log "la clé publique a changé après redémarrage"; exit 1; }
curl -fsS -X POST "$BASE/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" \
    | jq -e '.access_token != null' >/dev/null

log "OK : démarrage, santé, compte, redémarrage et persistance validés"
