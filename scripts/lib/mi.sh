#!/usr/bin/env bash
# Micro Integrator deployment helpers (Management API + hot deployment). Source, don't execute.

MI_TOKEN=""
MI_BACKUP_DIR=""
MI_DEPLOYED_CAR=""

mi_login() {
  MI_TOKEN="$(curl -skf -u "${MI_USER}:${MI_PASSWORD}" "${MI_MGMT_URL}/login" | jq -r '.AccessToken // empty')" \
    || return 1
  [[ -n "$MI_TOKEN" ]]
}

mi_get() { curl -skf -H "Authorization: Bearer ${MI_TOKEN}" "${MI_MGMT_URL}/$1"; }

# Prints ACTIVE, FAULTY or ABSENT for a CApp name.
mi_capp_state() {
  local name="$1" apps
  apps="$(mi_get applications)" || { echo "UNKNOWN"; return 0; }
  if jq -e --arg n "$name" '.activeList[]? | select(.name == $n)' <<<"$apps" >/dev/null; then
    echo ACTIVE
  elif jq -e --arg n "$name" '.faultyList[]? | select((.name // .) | tostring | test($n))' <<<"$apps" >/dev/null; then
    echo FAULTY
  else
    echo ABSENT
  fi
}

mi_wait_state() {
  local name="$1" want="$2" timeout="${3:-${DEPLOY_TIMEOUT_SECONDS:-180}}" deadline state
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    state="$(mi_capp_state "$name")"
    [[ "$state" == "$want" ]] && return 0
    if [[ "$state" == FAULTY && "$want" == ACTIVE ]]; then
      log "CApp ${name} is FAULTY on the runtime"
      mi_get applications | jq '.faultyList' >&2 || true
      return 1
    fi
    sleep 3
  done
  log "timed out waiting for CApp ${name} to become ${want} (last: ${state:-?})"
  return 1
}

# Every MI API from the source tree must be registered, plus the data service.
mi_verify_artifacts() {
  local apis expected missing=0
  apis="$(mi_get apis)" || return 1
  while read -r expected; do
    if ! jq -e --arg n "$expected" '.list[]? | select(.name == $n)' <<<"$apis" >/dev/null; then
      log "MI API missing after deployment: ${expected}"; missing=1
    fi
  done < <(mi_expected_apis)
  if ! mi_get data-services | jq -e '.list[]? | select(.name == "JamiiAccountDataService")' >/dev/null; then
    log "data service JamiiAccountDataService not deployed"; missing=1
  fi
  return "$missing"
}

# Hot-deploy directory: absolute, or relative to the repo root.
mi_capps_dir() { [[ "${MI_CARBONAPPS_DIR}" == /* ]] && echo "${MI_CARBONAPPS_DIR}" || echo "${REPO_ROOT}/${MI_CARBONAPPS_DIR}"; }

# Deploy the CAR. Hot-deploy mode: remove current CAR -> wait undeploy -> copy new -> wait ACTIVE.
# The previous CAR is kept for rollback.
mi_deploy() {
  local car="$1" name; name="$(mi_artifact_id)"
  [[ -f "$car" ]] || die "CAR not found: $car"
  case "${MI_DEPLOY_MODE}" in
    hotdeploy)
      local dir; dir="$(mi_capps_dir)"
      mkdir -p "$dir"
      MI_BACKUP_DIR="$(mktemp -d)"
      if compgen -G "${dir}/${name}_*.car" >/dev/null; then
        log "backing up current ${name} CAR(s) for rollback"
        mv "${dir}/${name}"_*.car "${MI_BACKUP_DIR}/"
        mi_wait_state "$name" ABSENT 120 || return 1
      fi
      cp "$car" "${dir}/"
      chmod a+r "${dir}/$(basename "$car")"
      MI_DEPLOYED_CAR="${dir}/$(basename "$car")"
      log "copied $(basename "$car") to hot-deploy directory; waiting for ACTIVE"
      mi_wait_state "$name" ACTIVE && mi_verify_artifacts
      ;;
    image)
      # Conceptual prod path: immutable image per release, rolled out by the platform.
      require docker
      local tag
      tag="${MI_IMAGE_REPO}:$(mi_version)-${BUILD_NUMBER:-local}"
      log "building immutable MI image ${tag}"
      docker build -t "$tag" --build-arg CAR="$(basename "$car")" -f - "$(dirname "$car")" <<'DOCKERFILE'
FROM jamii-mi-base:latest
ARG CAR
COPY ${CAR} /home/wso2carbon/wso2mi-4.4.0/repository/deployment/server/carbonapps/
DOCKERFILE
      docker push "$tag"
      die "image rollout is platform-specific (kubectl set image / helm upgrade) and not wired up for ${ENV_NAME}"
      ;;
    *) die "unknown MI_DEPLOY_MODE=${MI_DEPLOY_MODE}" ;;
  esac
}

mi_rollback() {
  [[ "${MI_DEPLOY_MODE}" == hotdeploy && -n "${MI_BACKUP_DIR}" ]] || return 0
  local name dir; name="$(mi_artifact_id)"; dir="$(mi_capps_dir)"
  log "MI rollback: removing new CAR and restoring previous one (if any)"
  [[ -n "${MI_DEPLOYED_CAR}" ]] && rm -f "${MI_DEPLOYED_CAR}"
  mi_wait_state "$name" ABSENT 120 || warn "new CAR did not undeploy cleanly"
  if compgen -G "${MI_BACKUP_DIR}/*.car" >/dev/null; then
    cp "${MI_BACKUP_DIR}"/*.car "${dir}/"
    mi_wait_state "$name" ACTIVE || { warn "previous CAR failed to come back ACTIVE"; return 1; }
    log "MI rollback complete: previous CAR is ACTIVE"
  else
    log "MI rollback complete: there was no previous CAR (runtime left without ${name})"
  fi
}
