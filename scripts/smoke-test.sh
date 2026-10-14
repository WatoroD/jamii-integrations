#!/usr/bin/env bash
# Post-deployment smoke tests. Exit non-zero on any failure (deploy.sh then rolls back).
#   smoke-test.sh mi <env>        - direct to Micro Integrator (dev only)
#   smoke-test.sh gateway <env>   - through the APIM gateway, with real credentials
# Checks that depend on the public third-party mocks (DummyJSON, DNE Online) accept either
# a success OR a correctly-shaped BACKEND_* error: an outage of someone else's demo service
# must not block our release, but a malformed/leaky response must.
set -euo pipefail
STAGE=smoke
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
MODE="${1:?mode: mi|gateway}"; load_env "${2:?env}"
require curl jq
FAILS=0; TOTAL=0
BODY="$(mktemp)"; HDRS="$(mktemp)"

call() {  # call METHOD URL [curl args...] -> sets $STATUS, body in $BODY
  local m="$1" u="$2"; shift 2
  STATUS=$(curl -sk -o "$BODY" -D "$HDRS" -w '%{http_code}' -X "$m" "$@" "$u" || echo 000)
}
check() {  # check NAME CONDITION(jq) EXPECTED_STATUS
  local name="$1" cond="$2" want="$3"; TOTAL=$((TOTAL + 1))
  if [[ "$STATUS" == "$want" ]] && jq -e "$cond" "$BODY" >/dev/null 2>&1; then
    log "PASS ${name} (${STATUS})"
  else
    log "FAIL ${name}: got ${STATUS}, expected ${want} with ${cond}: $(head -c 300 "$BODY")"; FAILS=$((FAILS + 1))
  fi
}
check_status() {  # status-only check (gateway-generated bodies are not ours to assert)
  TOTAL=$((TOTAL + 1))
  if [[ "$STATUS" == "$2" ]]; then log "PASS $1 (${STATUS})"; else log "FAIL $1: got ${STATUS}, expected $2"; FAILS=$((FAILS + 1)); fi
}
ENVELOPE='(.error.code|type=="string") and (.error.message|type=="string") and (.error.status|type=="number") and (.error.requestId|length>0) and (.error.timestamp|length>0)'
check_error() { check "$1" "${ENVELOPE} and .error.code==\"$2\" and .error.status==$3" "$3"; }
check_ok_or_backend_error() {  # for third-party-backed calls
  local name="$1" cond="$2"
  if [[ "$STATUS" =~ ^50[234]$ ]]; then
    check "${name} [backend degraded]" "${ENVELOPE} and (.error.code|test(\"^BACKEND_\"))" "$STATUS"
  else
    check "$name" "$cond" 200
  fi
}
no_leak() {  # response must not contain backend internals
  TOTAL=$((TOTAL + 1))
  if grep -qiE 'soap:|Envelope|faultstring|Exception|stack|password|ssn' "$BODY"; then
    log "FAIL $1: response leaks backend internals/secrets"; FAILS=$((FAILS + 1))
  else log "PASS $1"; fi
}

LOAN_OK='{"customerId":"1","monthlyIncome":120000,"existingMonthlyDebt":15000,"requestedAmount":300000,"termMonths":24}'
LOAN_OVERFLOW='{"customerId":"1","monthlyIncome":50000,"existingMonthlyDebt":0,"requestedAmount":900000000,"termMonths":12}'
LOAN_INVALID='{"customerId":"1","monthlyIncome":0,"termMonths":24}'

if [[ "$MODE" == mi ]]; then
  B="${MI_HTTP_URL}"; AUTH_A=(); AUTH_C=(); AUTH_L=()
  ACC="$B/accounts"; CUS="$B/customers"; LOAN="$B/loans"
else
  eval "$("${REPO_ROOT}/scripts/devportal-onboard.sh" "$ENV_NAME" "JamiiSmoke-${BUILD_NUMBER:-$$}")"
  trap 'curl -sk -X DELETE -H "Authorization: Bearer ${PORTAL_TOKEN}" "${APIM_URL}/api/am/devportal/v3/applications/${APP_ID}" >/dev/null || true' EXIT
  B="${APIM_GATEWAY_URL}"
  AUTH_A=(-H "Authorization: Bearer ${ACCESS_TOKEN}"); AUTH_C=("${AUTH_A[@]}"); AUTH_L=(-H "apikey: ${API_KEY}")
  ACC="$B/jamii/accounts/1.0.0"; CUS="$B/jamii/customers/1.0.0"; LOAN="$B/jamii/loans/1.0.0"
  # Gateway needs a moment to pick up each new revision, and the APIs arrive one by one:
  # wait until EVERY API is routed (a 404 means "not on the gateway yet"), not just the first.
  gw_ready() {
    [[ $(curl -sk -o /dev/null -w '%{http_code}' "${AUTH_A[@]}" "${ACC}/1000000001/balance") == 200 ]] &&
    [[ $(curl -sk -o /dev/null -w '%{http_code}' "${AUTH_C[@]}" "${CUS}/1") != 404 ]] &&
    [[ $(curl -sk -o /dev/null -w '%{http_code}' "${AUTH_L[@]}" -H 'Content-Type: application/json' -d '{}' "${LOAN}/eligibility") == 400 ]]
  }
  retry_until 90 5 gw_ready || log "gateway not routing all three APIs yet - continuing so failures are reported"
  call GET "$ACC/1000000001/balance";               check_status "gw: accounts requires credentials" 401
  call POST "$LOAN/eligibility" -H 'Content-Type: application/json' -d "$LOAN_OK"; check_status "gw: loans requires api key" 401
fi

# ---- 1a accounts (our DB: hard assertions)
call GET "$ACC/1000000001/balance" "${AUTH_A[@]}" -H 'X-Correlation-ID: smoke-corr-0001'
check "accounts: 200 envelope" '.accountNumber=="1000000001" and (.status|IN("ACTIVE","DORMANT","CLOSED")) and (.balance.amount|type=="number") and .balance.currency=="KES" and (.requestId|length==36) and (.timestamp|length>0)' 200
TOTAL=$((TOTAL + 1)); if grep -qi '^x-correlation-id: smoke-corr-0001' "$HDRS"; then log "PASS accounts: correlation id echoed"; else log "FAIL accounts: correlation id not echoed"; FAILS=$((FAILS + 1)); fi
call GET "$ACC/9999999999/balance" "${AUTH_A[@]}";  check_error "accounts: unknown -> 404" ACCOUNT_NOT_FOUND 404
call GET "$ACC/12ab/balance" "${AUTH_A[@]}";        check_error "accounts: malformed -> 400" INVALID_ACCOUNT_NUMBER 400

# ---- 1b customers (third-party mock)
call GET "$CUS/1" "${AUTH_C[@]}";   check_ok_or_backend_error "customers: 200 profile" '.id==1 and (.firstName|length>0)'; no_leak "customers: sensitive fields stripped"
call GET "$CUS/abc" "${AUTH_C[@]}"; check_error "customers: malformed -> 400" INVALID_CUSTOMER_ID 400
call GET "$CUS/999999" "${AUTH_C[@]}"
if [[ "$STATUS" == 404 ]]; then check_error "customers: unknown -> 404" CUSTOMER_NOT_FOUND 404; else check_ok_or_backend_error "customers: unknown" 'false'; fi

# ---- 1c loans (third-party SOAP mock)
call POST "$LOAN/eligibility" "${AUTH_L[@]}" -H 'Content-Type: application/json' -d "$LOAN_OK"
check_ok_or_backend_error "loans: 200 decision" '(.eligible|type=="boolean") and (.decision|IN("ELIGIBLE","NOT_ELIGIBLE")) and (.assessment.debtToIncomeRatioPercent|type=="number")'
call POST "$LOAN/eligibility" "${AUTH_L[@]}" -H 'Content-Type: application/json' -d '{"customerId": "1",'
check_error "loans: malformed JSON -> 400" MALFORMED_REQUEST 400
call POST "$LOAN/eligibility" "${AUTH_L[@]}" -H 'Content-Type: application/json' -d "$LOAN_INVALID"
check_error "loans: schema violation -> 400" INVALID_REQUEST 400
call POST "$LOAN/eligibility" "${AUTH_L[@]}" -H 'Content-Type: text/plain' -d 'hello'
check_error "loans: wrong media type -> 415" UNSUPPORTED_MEDIA_TYPE 415
call POST "$LOAN/eligibility" "${AUTH_L[@]}" -H 'Content-Type: application/json' -d "$LOAN_OVERFLOW"
if [[ "$STATUS" == 422 ]]; then check_error "loans: SOAP Client fault -> 422" ELIGIBILITY_INPUT_REJECTED 422; else check_ok_or_backend_error "loans: SOAP fault" 'false'; fi
no_leak "loans: SOAP fault not leaked"

# ---- bonus A dashboard
call GET "$CUS/1/dashboard" "${AUTH_C[@]}"
check_ok_or_backend_error "dashboard: aggregated" '(.partial|type=="boolean") and .accounts.status=="OK" and (.accounts.data|length==2)'

log "smoke (${MODE}/${ENV_NAME}): $((TOTAL - FAILS))/${TOTAL} passed"
(( FAILS == 0 ))
