#!/usr/bin/env bash
# Exercises scripts/deploy.sh end-to-end against a fake MI Management API and a fake apictl,
# to prove the all-or-nothing behaviour without a WSO2 runtime:
#   1. clean deploy succeeds and deploys everything
#   2. redeploy where the 3rd API import fails -> exit != 0, all APIs + CAR restored to step-1 state
#   3. faulty CAR -> exit != 0, previous CAR restored, no API touched
#   4. API product import fails half-applied on redeploy -> product + APIs + CAR restored
#   5. the same on an empty environment -> nothing left behind
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; export SIM_STATE="$WORK/state" HOME="$WORK/home"; mkdir -p "$SIM_STATE" "$HOME"
PORT=$((20000 + RANDOM % 20000)); CAPPS="$WORK/carbonapps"; mkdir -p "$CAPPS"
python3 "$REPO/tests/sim/fake_mi.py" "$PORT" "$CAPPS" & SRV=$!
ENVF="$REPO/deploy/environments/sim.env"
trap 'kill $SRV 2>/dev/null; rm -f "$ENVF"; rm -rf "$WORK"' EXIT
cat > "$ENVF" <<ENV
ENV_NAME=sim
APICTL_ENV=sim
APIM_URL=https://apim.invalid
MI_MGMT_URL=http://127.0.0.1:${PORT}/management
MI_HTTP_URL=
MI_DEPLOY_MODE=hotdeploy
MI_CARBONAPPS_DIR=${CAPPS}
APIM_USER=a
APIM_PASSWORD=b
MI_USER=a
MI_PASSWORD=b
GATEWAY_SMOKE=false
DEPLOY_TIMEOUT_SECONDS=15
ENV
export APICTL="$REPO/tests/sim/apictl"
sleep 0.5
run() { BUILD_NUMBER="$1" "$REPO/scripts/deploy.sh" sim >"$WORK/out-$1.log" 2>&1; }
state() { (shopt -s nullglob; cd "$SIM_STATE/apim" && for f in *; do printf '%s=%s ' "$f" "$(cat "$f")"; done); ls "$CAPPS"; }

# 1. clean deploy
run 1 || { cat "$WORK/out-1.log"; echo "SIM FAIL: clean deploy failed"; exit 1; }
S1="$(state)"; echo "after build 1: $S1"
if ! grep -q "JamiiLoans-1.0.0=new-1" <<<"$S1" || ! grep -q "product=new-1" <<<"$S1"; then cat "$WORK/out-1.log"; echo "SIM FAIL: not fully deployed"; exit 1; fi

# 2. third API import fails on redeploy -> everything back to build-1 state
if SIM_FAIL_IMPORT=JamiiLoans run 2; then echo "SIM FAIL: deploy should have failed"; exit 1; fi
S2="$(state)"; echo "after failed build 2: $S2"
[[ "$S1" == "$S2" ]] || { cat "$WORK/out-2.log"; echo "SIM FAIL: state not restored"; exit 1; }
grep -q "rolling back" "$WORK/out-2.log"
# ...and the first two APIs really had been switched to build 2 before being restored
grep -q "JamiiAccounts-1.0.0.zip -e sim" "$SIM_STATE/apictl.log"
grep -q "restoring previous revision of JamiiCustomers-1.0.0" "$WORK/out-2.log"

# 3. faulty CAR -> previous CAR restored, APIM untouched
cp "$REPO/dist/mi/JamiiIntegrations_1.0.0.car" "$WORK/good.car"
printf 'FAULTY' >> "$REPO/dist/mi/JamiiIntegrations_1.0.0.car"
if run 3; then cp "$WORK/good.car" "$REPO/dist/mi/JamiiIntegrations_1.0.0.car"; echo "SIM FAIL: faulty CAR accepted"; exit 1; fi
cp "$WORK/good.car" "$REPO/dist/mi/JamiiIntegrations_1.0.0.car"
S3="$(state)"; echo "after faulty build 3: $S3"
[[ "$S1" == "$S3" ]] || { cat "$WORK/out-3.log"; echo "SIM FAIL: state not restored after faulty CAR"; exit 1; }
grep -q "phase 'mi-deploy'" "$WORK/out-3.log"
# 4. product import fails half-applied on redeploy -> product AND APIs back to build-1 state
if SIM_FAIL_PRODUCT=1 run 4; then echo "SIM FAIL: product failure accepted"; exit 1; fi
S4="$(state)"; echo "after failed build 4: $S4"
[[ "$S1" == "$S4" ]] || { cat "$WORK/out-4.log"; echo "SIM FAIL: state not restored after product failure"; exit 1; }
grep -q "restoring previous API product" "$WORK/out-4.log"

# 5. same failure on an EMPTY environment (what happened on the first real APIM run) -> nothing left
rm -f "$SIM_STATE"/apim/* "$CAPPS"/*.car
if SIM_FAIL_PRODUCT=1 run 5; then echo "SIM FAIL: product failure accepted"; exit 1; fi
S5="$(state)"; echo "after failed build 5 on empty env: '${S5}'"
[[ -z "${S5//[[:space:]]/}" ]] || { cat "$WORK/out-5.log"; echo "SIM FAIL: partial deployment left behind"; exit 1; }
if grep -q "ROLLBACK INCOMPLETE" "$WORK/out-5.log"; then echo "SIM FAIL: rollback incomplete"; exit 1; fi
echo "SIM OK: deploy is all-or-nothing"
