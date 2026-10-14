#!/usr/bin/env bash
# Live walkthrough of the three Jamii APIs (+ the dashboard bonus) through the APIM gateway,
# for a screen recording. Onboards a throwaway DevPortal application the way a consumer would,
# then makes each call, showing the command, status, key headers and JSON body.
#
#   scripts/demo.sh            # press Enter to advance (narrated recording)
#   DEMO_AUTO=1 scripts/demo.sh  # advance on a timer (DEMO_DELAY seconds, default 18; ~4.5 min)
#
# Needs the docker-compose stack up and deployed (scripts/env-up.sh && scripts/deploy.sh dev).
set -euo pipefail
STAGE=demo
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
load_env dev 2>/dev/null
require curl jq

AUTO="${DEMO_AUTO:-}"; DELAY="${DEMO_DELAY:-18}"
GW="${APIM_GATEWAY_URL}/jamii"
B=$'\e[1m'; DIM=$'\e[2m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; R=$'\e[0m'
BODY="$(mktemp)"; HDRS="$(mktemp)"

pause() {
  if [[ -n "$AUTO" ]]; then sleep "${1:-$DELAY}"
  else printf '\n%s[Enter]%s ' "$DIM" "$R"; read -r _; fi
}
title() { clear; printf '%s%s== %s ==%s\n\n' "$B" "$CYAN" "$1" "$R"; }
say()   { printf '%s\n' "$*" | fold -s -w 96; }

# call "<what to look for>" <curl args...>  - prints the command (credentials abbreviated),
# runs it, then shows status, the headers that matter and the JSON body.
call() {
  local note="$1"; shift
  local a shown="curl -sk"
  for a in "$@"; do [[ "$a" =~ [[:space:]\"{}] ]] && shown+=" '${a}'" || shown+=" ${a}"; done
  shown="${shown//${ACCESS_TOKEN}/\$TOKEN}"; shown="${shown//${API_KEY}/\$API_KEY}"
  shown="${shown//${APIM_GATEWAY_URL}/https://gateway:8243}"
  # Variables are shown in double quotes so the command can be copied as-is.
  shown="${shown//\'Authorization: Bearer \$TOKEN\'/\"Authorization: Bearer \$TOKEN\"}"
  shown="${shown//\'apikey: \$API_KEY\'/\"apikey: \$API_KEY\"}"
  printf '%s$ %s%s\n\n' "$YELLOW" "$shown" "$R"
  local code
  code=$(curl -sk -o "$BODY" -D "$HDRS" -w '%{http_code}' "$@")
  local colour="$GREEN"; [[ "$code" -ge 400 ]] && colour="$RED"
  printf '%sHTTP %s%s   ' "$colour$B" "$code" "$R"
  { grep -iE '^(x-correlation-id|x-request-id):' "$HDRS" || true; } | tr -d '\r' | tr '\n' ' '; printf '\n'
  jq -C . "$BODY" 2>/dev/null | head -"${JSON_LINES:-32}" || head -c 1500 "$BODY"
  LAST_REQ_ID=$(grep -i '^x-request-id:' "$HDRS" | tr -d '\r' | awk '{print $2}' || true)
  printf '\n%s> %s%s\n' "$B" "$note" "$R" | fold -s -w 100
}

cleanup() {
  [[ -n "${APP_ID:-}" ]] && curl -sk -X DELETE -H "Authorization: Bearer ${PORTAL_TOKEN}" \
    "${APIM_URL}/api/am/devportal/v3/applications/${APP_ID}" >/dev/null 2>&1 || true
  rm -f "$BODY" "$HDRS"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
title "Jamii Savings - WSO2 Micro Integrator + API Manager"
say "Three integrations built in WSO2 MI and published through API Manager:"
say "  1a  GET  /accounts/{n}/balance   - MySQL via an MI data service"
say "  1b  GET  /customers/{id}         - managed proxy in front of DummyJSON"
say "  1c  POST /loans/eligibility      - REST/JSON -> SOAP (DNE Online Calculator) -> JSON"
say "  +   GET  /customers/{id}/dashboard - parallel aggregation (bonus)"
printf '\n%sRunning stack:%s\n' "$B" "$R"
if command -v docker >/dev/null 2>&1; then
  docker ps --filter name=jamii --format '  {{.Names}}  {{.Image}}  {{.Status}}'
fi
printf '\n%sPublished in the Developer Portal:%s\n' "$B" "$R"
curl -sk "${APIM_URL}/api/am/devportal/v3/apis?limit=20" \
  | jq -r '.list[] | "  \(.type)\t\(.name)\t\(.context)\ttier: \([.throttlingPolicies[]?]|join(","))"' | column -t -s $'\t'
pause

title "Onboarding as a consumer (Developer Portal REST API)"
say "A consuming app discovers the APIs, creates an application, subscribes on each API's tier and generates credentials: an OAuth2 token for Accounts/Customers, an API key for Loans."
# shellcheck disable=SC2016  # the command is shown, not run
printf '\n%s$ eval "$(scripts/devportal-onboard.sh dev DemoApp)"%s\n\n' "$YELLOW" "$R"
eval "$("${REPO_ROOT}/scripts/devportal-onboard.sh" dev "JamiiDemo-$$" 2>/dev/null)"
printf '  application %s\n  ACCESS_TOKEN=%s...\n  API_KEY=%s...\n' "$APP_ID" "${ACCESS_TOKEN:0:16}" "${API_KEY:0:16}"
AUTH=(-H "Authorization: Bearer ${ACCESS_TOKEN}"); KEY=(-H "apikey: ${API_KEY}")
pause 8

# ---------------------------------------------------------------------------------------------
title "1a  Account balance (DB-backed)"
call "Required envelope: status, balance {amount, currency}, requestId (UUID), ISO-8601 timestamp. The query is parameterised." \
  "${AUTH[@]}" "$GW/accounts/1.0.0/1000000001/balance"
BALANCE_REQ_ID="$LAST_REQ_ID"
pause

title "1a  Unknown account and malformed input"
call "Unknown account -> 404 in the shared error shape." "${AUTH[@]}" "$GW/accounts/1.0.0/9999999999/balance"
printf '\n'
call "Malformed account number -> 400, never 500." "${AUTH[@]}" "$GW/accounts/1.0.0/12ab/balance"
pause

title "1a  No credentials"
call "The gateway rejects calls without a valid OAuth2 token (401) before anything reaches MI." \
  "$GW/accounts/1.0.0/1000000001/balance"
pause

# ---------------------------------------------------------------------------------------------
title "1b  Customer proxy (DummyJSON)"
JSON_LINES=26 call "Our correlation ID is passed through and echoed. DummyJSON also returns password, SSN, bank card and crypto wallet: MI strips them, so none appear here." \
  "${AUTH[@]}" -H "X-Correlation-ID: demo-call-0001" "$GW/customers/1.0.0/1"
LEAK_FILTER='[has("password","ssn","bank","crypto","ip")] | any'
printf "\n%s\$ jq '%s'%s  ->  %s\n" "$YELLOW" "$LEAK_FILTER" "$R" "$(jq "$LEAK_FILTER" "$BODY")"
pause

title "1b  Unknown customer and malformed id"
call "The backend's 404 is mapped to CUSTOMER_NOT_FOUND - same error shape as the DB API." \
  "${AUTH[@]}" "$GW/customers/1.0.0/999999"
printf '\n'
call "Invalid id -> 400. A correlation ID was minted because the caller sent none." \
  "${AUTH[@]}" "$GW/customers/1.0.0/abc"
pause

# ---------------------------------------------------------------------------------------------
LOAN=(-H "Content-Type: application/json" "${KEY[@]}" "$GW/loans/1.0.0/eligibility")
title "1c  Loan eligibility (REST -> SOAP -> REST), API-key secured"
call "MI computes the instalment, sends Divide(obligations x 100, income) to the SOAP service and maps DivideResult to a debt-to-income ratio: 23% <= 40% cap -> ELIGIBLE." \
  -d '{"customerId":"1","monthlyIncome":120000,"existingMonthlyDebt":15000,"requestedAmount":300000,"termMonths":24}' "${LOAN[@]}"
pause

title "1c  Not eligible"
call "Same SOAP call, high debt load: DTI 200% -> NOT_ELIGIBLE, with the largest affordable instalment." \
  -d '{"customerId":"1","monthlyIncome":20000,"existingMonthlyDebt":15000,"requestedAmount":300000,"termMonths":12}' "${LOAN[@]}"
pause

title "1c  SOAP fault -> clean REST error"
call "These values overflow the service's Int32, so it returns a soap:Client fault with a .NET stack trace. The client gets a 422 in the shared shape; no SOAP XML leaks." \
  -d '{"customerId":"1","monthlyIncome":50000,"existingMonthlyDebt":0,"requestedAmount":900000000,"termMonths":12}' "${LOAN[@]}"
pause

title "1c  Malformed input"
call "Broken JSON -> 400 MALFORMED_REQUEST." -d '{"customerId":' "${LOAN[@]}"
printf '\n'
call "Valid JSON that breaks the JSON Schema -> 400 INVALID_REQUEST with the reason." \
  -d '{"customerId":"1","monthlyIncome":-5}' "${LOAN[@]}"
pause

# ---------------------------------------------------------------------------------------------
title "Bonus A  Customer dashboard (parallel aggregation)"
call "MI calls DummyJSON and the account database in parallel and merges the results. If one side fails, the response is 200 with partial:true and that section flagged." \
  "${AUTH[@]}" "$GW/customers/1.0.0/4/dashboard"
pause

title "Logging with masking"
say "Every request logs REQUEST_IN, BACKEND_CALL, BACKEND_RESPONSE and RESPONSE_OUT with its requestId, and the account number is masked. Here is the MI log for the first balance call (account 1000000001):"
printf '\n'
if command -v docker >/dev/null 2>&1; then
  docker logs jamii-jamii-mi-1 2>&1 | grep -F "${BALANCE_REQ_ID:-none}" \
    | sed -E 's/^\[[^ ]* ([^,]*),[0-9]*\] +[A-Z]+ \{LogMediator\} - \{api:[^}]*\} /\1 /; s/, (method|correlationIdSource|correlationId|consumerApp|backendType|api|backend) = [^,]*//g; s/, requestId = .*//' \
    | cut -c1-100
fi
printf '\n%sRepository: scripts/deploy.sh does all of this from one Jenkins pipeline, all-or-nothing.%s\n' "$B" "$R"
pause 10
