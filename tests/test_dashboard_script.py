"""Bonus A: run the real aggregation script from Dashboard_Collect under Node with a mock
MessageContext, covering every aggregation outcome and the payload shapes MI can produce."""
import json
import shutil
import subprocess

import pytest

from conftest import MI_ART, NS, parse

NODE = shutil.which("node")
pytestmark = pytest.mark.skipif(NODE is None, reason="node not installed")

SCRIPT = parse(MI_ART / "sequences/Dashboard_Collect.xml").xpath("//s:script", namespaces=NS)[0].text

HARNESS = """
const input = JSON.parse(process.argv[process.argv.length - 1]);
const props = {'uri.var.customerId': '1', 'jamii.requestId': 'rid', 'jamii.timestamp': 'ts'};
let out = null;
const mc = {
  getPayloadJSON: () => input,
  setPayloadJSON: (o) => { out = JSON.parse(JSON.stringify(o)); },
  getProperty: (k) => props[k],
  setProperty: (k, v) => { props[k] = v; },
};
%s
console.log(JSON.stringify({outcome: props['jamii.dash.outcome'], body: out}));
""" % SCRIPT

PROFILE_OK = {"section": "profile", "status": "OK", "data": {"firstName": "Emily", "lastName": "Johnson", "email": "e@x", "phone": "1"}}
ROWS = [{"accountNumber": 1000000001, "accountType": "SAVINGS", "status": "ACTIVE", "balance": 152340.75, "currency": "KES"},
        {"accountNumber": "1000000002", "accountType": "CURRENT", "status": "ACTIVE", "balance": "8420.00", "currency": "KES"}]
ACCOUNTS_OK = {"section": "accounts", "status": "OK", "data": {"CustomerAccounts": {"CustomerAccount": ROWS}}}


def run(payload):
    res = subprocess.run([NODE, "-e", HARNESS, json.dumps(payload)], capture_output=True, text=True, check=True)
    return json.loads(res.stdout)


def test_both_ok_array_shape():
    r = run([PROFILE_OK, ACCOUNTS_OK])
    assert r["outcome"] == "OK" and r["body"]["partial"] is False
    accts = r["body"]["accounts"]["data"]
    assert [a["accountNumber"] for a in accts] == ["1000000001", "1000000002"]   # numbers normalised to strings
    assert accts[1]["balance"] == {"amount": 8420.0, "currency": "KES"}         # strings normalised to numbers


def test_wrapped_and_single_row_shapes():
    single = {"section": "accounts", "status": "OK", "data": {"CustomerAccounts": {"CustomerAccount": ROWS[0]}}}
    r = run({"Aggregated_Responses": [single, PROFILE_OK]})
    assert r["outcome"] == "OK" and len(r["body"]["accounts"]["data"]) == 1


def test_customer_with_no_accounts():
    r = run([PROFILE_OK, {"section": "accounts", "status": "OK", "data": {"CustomerAccounts": {}}}])
    assert r["outcome"] == "OK" and r["body"]["accounts"]["data"] == [] and r["body"]["partial"] is False


def test_profile_down_is_partial():
    r = run([{"section": "profile", "status": "UNAVAILABLE", "reason": "TIMEOUT"}, ACCOUNTS_OK])
    assert r["outcome"] == "OK" and r["body"]["partial"] is True
    assert r["body"]["profile"] == {"status": "UNAVAILABLE", "reason": "TIMEOUT"}


def test_branch_missing_after_aggregate_timeout_is_partial():
    r = run([PROFILE_OK])
    assert r["body"]["partial"] is True and r["body"]["accounts"]["reason"] == "TIMEOUT"


def test_unknown_customer_is_404_even_if_accounts_ok():
    r = run([{"section": "profile", "status": "NOT_FOUND", "reason": "CUSTOMER_NOT_FOUND"}, ACCOUNTS_OK])
    assert r["outcome"] == "NOT_FOUND"


def test_everything_down_is_unavailable():
    r = run([{"section": "profile", "status": "UNAVAILABLE", "reason": "BACKEND_ERROR"},
             {"section": "accounts", "status": "UNAVAILABLE", "reason": "DATABASE_UNAVAILABLE"}])
    assert r["outcome"] == "UNAVAILABLE"
