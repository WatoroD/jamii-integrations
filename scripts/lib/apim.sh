#!/usr/bin/env bash
# API Manager deployment helpers (apictl 4.x). Source, don't execute.

APICTL="${APICTL:-apictl}"
APIM_SNAPSHOT_DIR=""
APIM_IMPORTED=()          # API projects imported in this run (for rollback, in order)
APIM_PRODUCT_IMPORTED=""  # set once the API product has been imported
PRODUCT_PROJECT="JamiiCoreBanking-1.0.0"
PRODUCT_NAME="$(api_name "$PRODUCT_PROJECT")"; PRODUCT_VERSION="$(api_version "$PRODUCT_PROJECT")"
PRODUCT_PROVIDER="${APIM_USER:-admin}"

apictl_login() {
  "$APICTL" remove env "${APICTL_ENV}" >/dev/null 2>&1 || true
  "$APICTL" add env "${APICTL_ENV}" --apim "${APIM_URL}" >/dev/null
  printf '%s' "${APIM_PASSWORD}" | "$APICTL" login "${APICTL_ENV}" -u "${APIM_USER}" --password-stdin -k >/dev/null
}

# Export the currently published revision (if any) so a failed run can restore it.
# Prints "present" or "absent".
apim_snapshot_api() {
  local project="$1" name version
  name="$(api_name "$project")"; version="$(api_version "$project")"
  # apictl exits 0 even when the export fails (e.g. API absent), so judge by the file it writes.
  local out="${HOME}/.wso2apictl/exported/apis/${APICTL_ENV}/${name}_${version}.zip"
  rm -f "$out"
  "$APICTL" export api -n "$name" -v "$version" -e "${APICTL_ENV}" -k --latest >/dev/null 2>&1 || true
  if [[ -s "$out" ]]; then
    cp "$out" "${APIM_SNAPSHOT_DIR}/${project}.zip"
    echo present
  else
    echo absent
  fi
}

apim_import_api() {
  local project="$1" bundle="${DIST_DIR}/apim/$1.zip" params="${REPO_ROOT}/apim/apis/$1/api_params.yaml"
  [[ -f "$bundle" ]] || die "API bundle not found: ${bundle} (run package-apim.sh)"
  log "importing ${project} into ${APICTL_ENV}"
  "$APICTL" import api -f "$bundle" -e "${APICTL_ENV}" --params "$params" --update --rotate-revision -k
}

apim_snapshot_product() {
  # -v and -r are mandatory; as with APIs, presence is judged by the exported file, not the exit code.
  local out="${HOME}/.wso2apictl/exported/api-products/${APICTL_ENV}/${PRODUCT_NAME}_${PRODUCT_VERSION}.zip"
  rm -f "$out"
  "$APICTL" export api-product -n "$PRODUCT_NAME" -v "$PRODUCT_VERSION" -r "$PRODUCT_PROVIDER" \
    -e "${APICTL_ENV}" -k --latest >/dev/null 2>&1 || true
  if [[ -s "$out" ]]; then
    cp "$out" "${APIM_SNAPSHOT_DIR}/JamiiCoreBanking-product.zip"
    echo present
  else
    echo absent
  fi
}

apim_import_product() {
  local bundle="${DIST_DIR}/apim/${PRODUCT_PROJECT}.zip"
  log "importing API product ${PRODUCT_NAME} into ${APICTL_ENV}"
  "$APICTL" import api-product -f "$bundle" -e "${APICTL_ENV}" --update-api-product -k
}

# Restore every API touched in this run to its pre-deployment state.
apim_rollback() {
  local i project name version rc=0
  if [[ -n "${APIM_PRODUCT_IMPORTED}" ]]; then
    if [[ -f "${APIM_SNAPSHOT_DIR}/JamiiCoreBanking-product.zip" ]]; then
      log "APIM rollback: restoring previous API product"
      "$APICTL" import api-product -f "${APIM_SNAPSHOT_DIR}/JamiiCoreBanking-product.zip" -e "${APICTL_ENV}" --update-api-product -k \
        || { warn "restore of API product failed - manual action required"; rc=1; }
    else
      log "APIM rollback: deleting API product created in this run"
      # Must succeed before the APIs can go: APIM refuses to delete an API a product still uses.
      "$APICTL" delete api-product -n "$PRODUCT_NAME" -v "$PRODUCT_VERSION" -r "$PRODUCT_PROVIDER" -e "${APICTL_ENV}" -k \
        || { warn "could not delete API product"; rc=1; }
    fi
  fi
  for (( i=${#APIM_IMPORTED[@]}-1; i>=0; i-- )); do
    project="${APIM_IMPORTED[$i]}"; name="$(api_name "$project")"; version="$(api_version "$project")"
    if [[ -f "${APIM_SNAPSHOT_DIR}/${project}.zip" ]]; then
      log "APIM rollback: restoring previous revision of ${project}"
      "$APICTL" import api -f "${APIM_SNAPSHOT_DIR}/${project}.zip" -e "${APICTL_ENV}" --update --rotate-revision -k \
        || { warn "restore of ${project} failed - manual action required"; rc=1; }
    else
      log "APIM rollback: ${project} did not exist before this run - deleting it"
      "$APICTL" delete api -n "$name" -v "$version" -e "${APICTL_ENV}" -k || { warn "delete of ${project} failed"; rc=1; }
    fi
  done
  return "$rc"
}
