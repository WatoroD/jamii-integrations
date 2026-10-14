#!/usr/bin/env bash
# Build the MI composite application (one CAR containing all integrations).
set -euo pipefail
STAGE=build-mi
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require mvn
# shellcheck disable=SC2086  # MAVEN_ARGS is intentionally word-split (multiple -D flags)
# Run from the project dir: the CAR plugin spawns a nested `mvn dependency:copy-dependencies`
# (connector resolution) in the current working directory.
(cd "${MI_PROJECT_DIR}" && mvn -B -ntp clean install ${MAVEN_ARGS:-})
car="${MI_PROJECT_DIR}/target/$(mi_artifact_id)_$(mi_version).car"
[[ -f "$car" ]] || die "expected CAR not produced: $car"
# Guard: every artifact in the source tree must be inside the CAR.
expected=$(find "${MI_PROJECT_DIR}/src/main/wso2mi/artifacts" -type f \( -name '*.xml' -o -name '*.dbs' \) | wc -l | tr -d ' ')
packaged=$(unzip -Z1 "$car" | grep -Ec '^[^/]+_[0-9.]+/[^/]+-[0-9.]+\.(xml|dbs)$' || true)
(( packaged == expected )) || die "CAR contains ${packaged} artifacts but source has ${expected}"
mkdir -p "${DIST_DIR}/mi"
cp "$car" "${DIST_DIR}/mi/"
log "CAR ready: dist/mi/$(basename "$car") (${packaged} artifacts)"
