#!/usr/bin/env bash
set -euo pipefail
STAGE=env-down
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
docker compose -f "${REPO_ROOT}/docker/docker-compose.yml" down -v --remove-orphans
