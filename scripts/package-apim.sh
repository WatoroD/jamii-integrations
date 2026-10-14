#!/usr/bin/env bash
# Package every APIM project listed in apim/apis.manifest (plus the API product) into
# importable archives under dist/apim/. One loop for all APIs - adding an API means adding
# a line to the manifest, not another pipeline.
set -euo pipefail
STAGE=package-apim
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require zip
out="${DIST_DIR}/apim"; rm -rf "$out"; mkdir -p "$out"

bundle() {  # <source dir> <archive name>
  local src="$1" name="$2"
  [[ -f "${src}/Definitions/swagger.yaml" ]] || die "${name}: missing Definitions/swagger.yaml"
  # apictl expects a single top-level directory inside the archive.
  (cd "$(dirname "$src")" && zip -qr -X "${out}/${name}.zip" "$(basename "$src")" -x '*/api_params.yaml')
  log "packaged ${name}.zip"
}

count=0
while read -r p; do
  bundle "${REPO_ROOT}/apim/apis/${p}" "$p"
  count=$((count + 1))
done < <(api_projects)
bundle "$APIM_PRODUCT_DIR" "$(basename "$APIM_PRODUCT_DIR")"
(cd "$out" && sha256sum ./*.zip > SHA256SUMS)
log "${count} API archives + 1 product archive in dist/apim"
