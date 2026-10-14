#!/usr/bin/env bash
# Deploy ALL Jamii integrations to one environment, all-or-nothing.
#
#   scripts/deploy.sh <dev|prod>
#
# Order: preflight -> snapshot current state -> MI CAR (verified via Management API)
#        -> MI smoke tests -> each APIM API from apim/apis.manifest -> API product
#        -> gateway smoke tests -> commit.
# Any failure at any step triggers a rollback of everything this run changed (APIM first,
# then MI) and the script exits non-zero, so Jenkins marks the stage failed. Nothing is
# left half-deployed: either all three APIs move to the new version or none do.
set -euo pipefail
STAGE=deploy
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/mi.sh
source "$(dirname "$0")/lib/mi.sh"
# shellcheck source=lib/apim.sh
source "$(dirname "$0")/lib/apim.sh"

ENV_ARG="${1:?usage: deploy.sh <env>}"
load_env "$ENV_ARG"
require curl jq "$APICTL"

CAR="${DIST_DIR}/mi/$(mi_artifact_id)_$(mi_version).car"
PHASE="preflight"
MI_TOUCHED=""
STATE_FILE="${REPORTS_DIR}/deploy-${ENV_NAME}.json"
mkdir -p "$REPORTS_DIR"

DEPLOY_OK=""
on_exit() {
  local rc=$?
  [[ -n "$DEPLOY_OK" ]] && return 0
  if [[ "$PHASE" == preflight ]]; then
    log "DEPLOYMENT ABORTED in preflight (exit ${rc}) - nothing was changed in ${ENV_NAME}"
    exit "$(( rc == 0 ? 1 : rc ))"
  fi
  log "DEPLOYMENT FAILED during phase '${PHASE}' (exit ${rc}) - rolling back ${ENV_NAME}"
  local result=ROLLED_BACK
  apim_rollback || result=ROLLBACK_INCOMPLETE
  if [[ -n "$MI_TOUCHED" ]]; then mi_rollback || result=ROLLBACK_INCOMPLETE; fi
  jq -n --arg env "$ENV_NAME" --arg phase "$PHASE" --arg build "${BUILD_NUMBER:-local}" --arg result "$result" \
     '{env:$env, result:$result, failedPhase:$phase, build:$build}' > "$STATE_FILE" || true
  if [[ "$result" == ROLLBACK_INCOMPLETE ]]; then
    log "ROLLBACK INCOMPLETE - ${ENV_NAME} needs manual repair (see WARN lines above); failing the build"
  else
    log "rollback finished; failing the build"
  fi
  exit "$(( rc == 0 ? 1 : rc ))"
}
# EXIT (not ERR) so that explicit `die`/`exit` calls and Ctrl-C/abort also roll back.
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---- preflight: everything reachable and every input present BEFORE changing anything
[[ -f "$CAR" ]] || die "missing ${CAR} - run build-mi.sh first"
while read -r p; do [[ -f "${DIST_DIR}/apim/${p}.zip" ]] || die "missing bundle for ${p}"; done < <(api_projects)
mi_login || die "cannot authenticate to MI Management API at ${MI_MGMT_URL}"
apictl_login || die "cannot log in to API Manager at ${APIM_URL}"
log "preflight OK: CAR $(basename "$CAR"), $(api_projects | wc -l | tr -d ' ') APIs + 1 product"

# ---- snapshot current APIM state for rollback
PHASE="snapshot"
APIM_SNAPSHOT_DIR="$(mktemp -d)"
declare -A BEFORE=()
while read -r p; do BEFORE[$p]="$(apim_snapshot_api "$p")"; log "  ${p}: ${BEFORE[$p]} before deploy"; done < <(api_projects)
PRODUCT_BEFORE="$(apim_snapshot_product)"; log "  JamiiCoreBanking product: ${PRODUCT_BEFORE} before deploy"

# ---- 1. Micro Integrator
PHASE="mi-deploy"
MI_TOUCHED=1
mi_deploy "$CAR"
log "MI: $(mi_artifact_id) $(mi_version) ACTIVE with all APIs + data service"

if [[ -n "${MI_HTTP_URL:-}" ]]; then
  PHASE="mi-smoke"
  "${REPO_ROOT}/scripts/smoke-test.sh" mi "$ENV_NAME"
fi

# ---- 2. API Manager: every API in the manifest, then the product
PHASE="apim-import"
while read -r p; do
  APIM_IMPORTED+=("$p")   # register before importing: a half-applied import is rolled back too
  apim_import_api "$p"
done < <(api_projects)
PHASE="apim-product"
APIM_PRODUCT_IMPORTED=1
apim_import_product

if [[ "${GATEWAY_SMOKE:-false}" == true ]]; then
  PHASE="gateway-smoke"
  "${REPO_ROOT}/scripts/smoke-test.sh" gateway "$ENV_NAME"
fi

DEPLOY_OK=1
jq -n --arg env "$ENV_NAME" --arg build "${BUILD_NUMBER:-local}" --arg car "$(basename "$CAR")" \
   --argjson apis "$(api_projects | jq -R . | jq -s .)" \
   '{env:$env, result:"DEPLOYED", build:$build, car:$car, apis:$apis, product:"JamiiCoreBanking-1.0.0"}' > "$STATE_FILE"
log "SUCCESS: all integrations deployed to ${ENV_NAME}"
