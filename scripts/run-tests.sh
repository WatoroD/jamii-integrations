#!/usr/bin/env bash
# Offline test suite: XML/YAML/OpenAPI validity, cross-artifact contract checks, XPath mapping
# tests against captured real backend responses, JSON-schema tests, shell lint.
set -euo pipefail
STAGE=tests
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require python3
mkdir -p "$REPORTS_DIR"
python3 -m pip install -q --disable-pip-version-check -r "${REPO_ROOT}/tests/requirements.txt" 2>/dev/null \
  || python3 -m pip install -q --disable-pip-version-check --break-system-packages -r "${REPO_ROOT}/tests/requirements.txt"
python3 -m pytest -q "${REPO_ROOT}/tests" --junitxml="${REPORTS_DIR}/unit-tests.xml"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh "${REPO_ROOT}"/tests/sim/run-deploy-sim.sh "${REPO_ROOT}"/tests/sim/apictl
else
  warn "shellcheck not installed - skipping shell lint"
fi
