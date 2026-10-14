#!/usr/bin/env bash
# Install apictl into ./.tools (skipped if an apictl of the right version is already on PATH).
set -euo pipefail
STAGE=apictl
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
version="${APICTL_VERSION:-4.4.0}"
if command -v apictl >/dev/null 2>&1 && apictl version 2>/dev/null | grep -q "$version"; then
  log "apictl ${version} already installed"; exit 0
fi
dest="${REPO_ROOT}/.tools"; mkdir -p "$dest"
url="https://github.com/wso2/product-apim-tooling/releases/download/v${version}/apictl-${version}-linux-amd64.tar.gz"
log "downloading ${url}"
curl -fsSL "$url" | tar -xz -C "$dest"
"${dest}/apictl/apictl" set --vcs-config-path "${dest}/vcs-config.yaml" >/dev/null 2>&1 || true
log "apictl installed at ${dest}/apictl/apictl (add to PATH)"
