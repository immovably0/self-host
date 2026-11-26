#!/usr/bin/env bash
# Construit l'image tout-en-un en local.
#   ./allinone/build.sh [nom:étiquette]
# Nécessite Docker (BuildKit) avec accès à Docker Hub et ghcr.io.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TAG=${1:-nuvio-allinone:local}

"$ROOT/allinone/scripts/extract-image-config.sh"
docker build -f "$ROOT/allinone/Dockerfile" -t "$TAG" "$ROOT"
echo "Image construite : $TAG" >&2
