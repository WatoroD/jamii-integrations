#!/usr/bin/env bash
# Start the docker-compose target environment (DB + MI + APIM) and wait until healthy.
set -euo pipefail
STAGE=env-up
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require docker
mkdir -p "${REPO_ROOT}/docker/runtime/mi-carbonapps"
chmod 0777 "${REPO_ROOT}/docker/runtime/mi-carbonapps"   # MI runs as uid 802 in the container
docker compose -f "${REPO_ROOT}/docker/docker-compose.yml" up -d --build --wait --wait-timeout 900
log "environment healthy"
