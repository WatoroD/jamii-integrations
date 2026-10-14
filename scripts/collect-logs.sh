#!/usr/bin/env bash
# Archive container logs for the build (MI logs are already PII-masked at source).
set -uo pipefail
STAGE=logs
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
mkdir -p "${REPORTS_DIR}/logs"
for svc in jamii-db jamii-mi jamii-apim; do
  docker compose -f "${REPO_ROOT}/docker/docker-compose.yml" logs --no-color "$svc" > "${REPORTS_DIR}/logs/${svc}.log" 2>&1 || true
done
