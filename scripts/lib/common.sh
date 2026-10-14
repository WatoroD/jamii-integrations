#!/usr/bin/env bash
# Shared helpers for build/deploy scripts. Source, don't execute.
# shellcheck disable=SC2034

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"
REPORTS_DIR="${REPORTS_DIR:-${REPO_ROOT}/reports}"
APIM_MANIFEST="${REPO_ROOT}/apim/apis.manifest"
APIM_PRODUCT_DIR="${REPO_ROOT}/apim/api-products/JamiiCoreBanking-1.0.0"
MI_PROJECT_DIR="${REPO_ROOT}/mi/JamiiIntegrations"

log()  { printf '%s [%s] %s\n' "$(date -u +%H:%M:%S)" "${STAGE:-jamii}" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }

require() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"; done
}

# Load deploy/environments/<env>.env. Values may reference variables already in the
# environment (Jenkins credential bindings), e.g. APIM_PASSWORD=${APIM_PASSWORD:-admin}.
load_env() {
  local env_name="$1" file="${REPO_ROOT}/deploy/environments/$1.env"
  [[ -f "$file" ]] || die "unknown environment '${env_name}' (no ${file})"
  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a
  log "loaded environment ${ENV_NAME:?${file} must set ENV_NAME}"
}

# API project names from the manifest (one per line, comments allowed).
api_projects() { grep -Ev '^\s*(#|$)' "$APIM_MANIFEST"; }

# "JamiiAccounts-1.0.0" -> name / version
api_name()    { echo "${1%-*}"; }
api_version() { echo "${1##*-}"; }

# MI project coordinates from pom.xml (single source of truth for CAR name/version).
mi_artifact_id() { sed -n 's:.*<artifactId>\(JamiiIntegrations\)</artifactId>.*:\1:p' "${MI_PROJECT_DIR}/pom.xml" | head -1; }
mi_version()     { awk '/<artifactId>JamiiIntegrations<\/artifactId>/{f=1} f && /<version>/{gsub(/.*<version>|<\/version>.*/,""); print; exit}' "${MI_PROJECT_DIR}/pom.xml"; }

# MI API names the CAR must expose once deployed (derived from source, not hard-coded).
mi_expected_apis() {
  grep -ho '<api [^>]*name="[^"]*"' "${MI_PROJECT_DIR}"/src/main/wso2mi/artifacts/apis/*.xml \
    | sed 's/.*name="\([^"]*\)".*/\1/' | sort
}

# Retry "$@" until it succeeds or the timeout (seconds) elapses.
retry_until() {
  local timeout="$1" interval="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    (( SECONDS >= deadline )) && return 1
    sleep "$interval"
  done
}
