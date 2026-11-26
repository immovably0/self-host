#!/usr/bin/env bash
# Récupère, pour chaque image utilisée par l'image tout-en-un, son ENTRYPOINT,
# son CMD, son répertoire de travail et son environnement. nuvio-entrypoint s'en
# sert pour lancer chaque service exactement comme son image d'origine.
#
# Nécessite Docker, jq et l'accès aux registres. Écrit allinone/svc/<service>.json.
#
# Les images par défaut sont lues dans allinone/Dockerfile (source unique) ;
# une variable d'environnement du même nom (ex. AUTH_IMAGE) les remplace.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:-$ROOT/allinone/svc}

dockerfile_default() {
    sed -n "s/^ARG $1=//p" "$ROOT/allinone/Dockerfile" | head -n1
}

declare -A IMAGES=(
    [db]=${DB_IMAGE:-$(dockerfile_default DB_IMAGE)}
    [auth]=${AUTH_IMAGE:-$(dockerfile_default AUTH_IMAGE)}
    [rest]=${REST_IMAGE:-$(dockerfile_default REST_IMAGE)}
    [storage]=${STORAGE_IMAGE:-$(dockerfile_default STORAGE_IMAGE)}
    [functions]=${FUNCTIONS_IMAGE:-$(dockerfile_default FUNCTIONS_IMAGE)}
    [dashboard]=${DASHBOARD_IMAGE:-$(dockerfile_default DASHBOARD_IMAGE)}
)

command -v docker >/dev/null 2>&1 || { echo "docker est requis" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq est requis" >&2; exit 1; }

mkdir -p "$OUT"
for name in db auth rest storage functions dashboard; do
    image=${IMAGES[$name]}
    [ -n "$image" ] || { echo "image introuvable pour $name dans allinone/Dockerfile" >&2; exit 1; }
    echo "==> $name : $image" >&2
    docker pull --quiet "$image" >/dev/null
    docker image inspect "$image" --format '{{json .Config}}' \
        | jq '{Entrypoint, Cmd, WorkingDir, Env, User, Volumes, ExposedPorts}' > "$OUT/$name.json"
    test -s "$OUT/$name.json"
done

# Diagnostic (affiché dans les journaux) : outils réellement présents dans l'image de base.
echo "==> diagnostic de l'image de base ${IMAGES[db]}" >&2
docker run --rm --entrypoint sh "${IMAGES[db]}" -c '
    echo "PATH=$PATH"; head -n 3 /etc/os-release 2>/dev/null; id -un
    for c in apt-get dpkg bash curl jq openssl psql mountpoint chroot mknod sed grep; do
        printf "%s: " "$c"; command -v "$c" || echo ABSENT
    done
    ls -d /usr/bin/apt* /nix 2>/dev/null
' >&2 || echo "diagnostic impossible (pas de sh dans l'image de base)" >&2

echo "Configuration des images écrite dans $OUT" >&2
