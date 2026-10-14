#!/usr/bin/env bash
# What a consuming application does, scripted against the Developer Portal REST API (v3):
#   1. discover the Jamii APIs (search the catalogue)
#   2. create an application
#   3. subscribe it to each API on that API's tier (Gold / Gold / Bronze)
#   4. generate OAuth2 keys (client_credentials) + an API key
# Prints shell exports (ACCESS_TOKEN, API_KEY, APP_ID, ...) on stdout.
#
#   eval "$(scripts/devportal-onboard.sh dev MyApp)"
set -euo pipefail
STAGE=onboard
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
load_env "${1:?usage: devportal-onboard.sh <env> [app-name]}" >/dev/null 2>&1
APP_NAME="${2:-JamiiSmoke-${BUILD_NUMBER:-$$}}"
require curl jq
DP="${APIM_URL}/api/am/devportal/v3"
c() { curl -sSkf "$@"; }

# 0. Register an OAuth client for the DevPortal REST API (DCR) and get a portal token.
dcr=$(c -u "${APIM_USER}:${APIM_PASSWORD}" -H 'Content-Type: application/json' \
  -d "{\"callbackUrl\":\"https://localhost\",\"clientName\":\"jamii_onboard_${APP_NAME}\",\"owner\":\"${APIM_USER}\",\"grantType\":\"password client_credentials refresh_token\",\"saasApp\":true}" \
  "${APIM_URL}/client-registration/v0.17/register")
cid=$(jq -r .clientId <<<"$dcr"); csec=$(jq -r .clientSecret <<<"$dcr")
ptok=$(c -u "${cid}:${csec}" --data-urlencode grant_type=password \
  --data-urlencode "username=${APIM_USER}" --data-urlencode "password=${APIM_PASSWORD}" \
  --data-urlencode "scope=apim:subscribe apim:app_manage apim:sub_manage apim:api_key" \
  "${APIM_URL}/oauth2/token" | jq -r .access_token)
H=(-H "Authorization: Bearer ${ptok}" -H 'Content-Type: application/json')

# 1. Discover
declare -A TIER=([JamiiAccounts]=Gold [JamiiCustomers]=Gold [JamiiLoans]=Bronze)
declare -A API_ID=()
for name in "${!TIER[@]}"; do
  id=""
  for _ in $(seq 1 20); do   # DevPortal search index can lag a fresh import by a few seconds
    id=$(c "${H[@]}" "${DP}/apis?query=name:${name}&limit=10" | jq -r --arg n "$name" '.list[] | select(.name==$n and .version=="1.0.0") | .id' | head -1)
    [[ -n "$id" ]] && break; sleep 3
  done
  [[ -n "$id" ]] || die "API ${name} not visible in the DevPortal"
  API_ID[$name]="$id"; log "discovered ${name} -> ${id}"
done

# 2. Application (delete a stale one with the same name first)
old=$(c "${H[@]}" "${DP}/applications?query=${APP_NAME}" | jq -r --arg n "$APP_NAME" '.list[]? | select(.name==$n) | .applicationId')
[[ -n "$old" ]] && c -X DELETE "${H[@]}" "${DP}/applications/${old}" >/dev/null
app=$(c "${H[@]}" -d "{\"name\":\"${APP_NAME}\",\"throttlingPolicy\":\"Unlimited\",\"description\":\"Jamii onboarding/smoke test\",\"tokenType\":\"JWT\"}" "${DP}/applications" | jq -r .applicationId)
log "application ${APP_NAME} -> ${app}"

# 3. Subscribe
for name in "${!API_ID[@]}"; do
  c "${H[@]}" -d "{\"apiId\":\"${API_ID[$name]}\",\"applicationId\":\"${app}\",\"throttlingPolicy\":\"${TIER[$name]}\"}" "${DP}/subscriptions" >/dev/null
  log "subscribed to ${name} on tier ${TIER[$name]}"
done

# 4. Credentials
keys=$(c "${H[@]}" -d '{"keyType":"PRODUCTION","keyManager":"Resident Key Manager","grantTypesToBeSupported":["client_credentials"],"callbackUrl":"","scopes":["default"],"validityTime":3600}' \
  "${DP}/applications/${app}/generate-keys")
apikey=$(c "${H[@]}" -d '{"validityPeriod":3600,"additionalProperties":{}}' "${DP}/applications/${app}/api-keys/PRODUCTION/generate" | jq -r .apikey)

echo "export APP_ID='${app}'"
echo "export CONSUMER_KEY='$(jq -r .consumerKey <<<"$keys")'"
echo "export CONSUMER_SECRET='$(jq -r .consumerSecret <<<"$keys")'"
echo "export ACCESS_TOKEN='$(jq -r .token.accessToken <<<"$keys")'"
echo "export API_KEY='${apikey}'"
echo "export PORTAL_TOKEN='${ptok}'"
