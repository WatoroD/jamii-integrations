"""Run the real XPath expressions and payload templates from the MI artifacts against real
(captured) backend responses, and validate the rendered JSON against the published OpenAPI."""
import json
import re

import pytest
from jsonschema import Draft4Validator

from conftest import (FIX, MI_ART, NS, api_root, by_description, parse, payload_args,
                      property_expr, render_payload, resolve_schema, soap_body, swagger, xeval, xstr)

REQ_ID = "3f0c8f0e-6a8e-4c1f-9b55-0d8f4b6e2a71"
TS = "2026-10-13T08:15:30.123Z"


def oas_validator(api, schema_name):
    spec = swagger(api)
    return Draft4Validator(resolve_schema(spec, spec["components"]["schemas"][schema_name]))


def assert_valid(validator, doc):
    errors = [e.message for e in validator.iter_errors(doc)]
    assert not errors, errors


# ------------------------------------------------------------------ common ------------------
init = parse(MI_ART / "sequences/Jamii_InitRequest.xml")


@pytest.mark.parametrize("raw,masked", [
    ("1000000001", "******0001"),
    ("12345678", "****5678"),
    ("1", "****"),             # too short to partially reveal
    ("", "****"),
])
def test_reference_masking(raw, masked):
    filt = init.xpath("//s:filter[contains(@xpath,'jamii.rawRef')]", namespaces=NS)[0]
    in_range = xeval(filt.get("xpath"), jamii_rawRef=raw)
    if in_range:
        got = xstr(filt.xpath("s:then/s:property", namespaces=NS)[0].get("expression"), jamii_rawRef=raw)
    else:
        got = filt.xpath("s:else/s:property", namespaces=NS)[0].get("value")
    assert got == masked


@pytest.mark.parametrize("value,accepted", [
    ("smoke-corr-0001", True), (REQ_ID, True), ("short", False),
    ("x" * 65, False), ("abc\r\nInjected: 1", False), ("a b c d e f g h", False),
])
def test_correlation_id_acceptance(value, accepted):
    regex = init.xpath("//s:filter[@source]", namespaces=NS)[0].get("regex")
    assert bool(re.fullmatch(regex, value)) is accepted


def test_error_envelope_matches_openapi_for_every_api():
    seq = parse(MI_ART / "sequences/Jamii_ErrorResponse.xml")
    for pf in seq.xpath("//s:payloadFactory", namespaces=NS):
        n = len(payload_args(pf))
        values = ["DATABASE_UNAVAILABLE", "The account store is temporarily unavailable.", "503", REQ_ID, TS, "detail"][:n]
        doc = json.loads(render_payload(pf, values))
        for api in ("JamiiAccounts", "JamiiCustomers", "JamiiLoans"):
            assert_valid(oas_validator(api, "ErrorResponse"), doc)


def test_error_details_are_sanitised():
    seq = parse(MI_ART / "sequences/Jamii_ErrorResponse.xml")
    expr = property_expr(seq, "jamii.err.details")
    nasty = 'bad "quote" and back\\slash\nnewline\tTab'
    out = xstr(expr, jamii_err_details=nasty)
    assert '"' not in out and "\\" not in out and "\n" not in out
    json.loads('{"d":"%s"}' % out)


# ------------------------------------------------------------------ 1a accounts -------------
acc = api_root("JamiiAccountBalanceAPI")


@pytest.mark.parametrize("fixture,status,failure,not_found", [
    ("ds_account_found.xml", 200, False, False),
    ("ds_account_empty.xml", 200, False, True),
    ("ds_fault_db_down.xml", 500, True, None),
])
def test_account_branching(fixture, status, failure, not_found):
    body = soap_body(FIX / fixture)
    assert xeval(by_description(acc, "ds-failure-check").get("xpath"), body, jamii_backendStatus=status) is failure
    if not failure:
        assert xeval(by_description(acc, "ds-not-found-check").get("xpath"), body) is not_found


def test_account_envelope_matches_openapi():
    body = soap_body(FIX / "ds_account_found.xml")
    pf = by_description(acc, "balance-envelope")
    vals = [xstr(e, body, jamii_requestId=REQ_ID, jamii_timestamp=TS) for e in payload_args(pf)]
    doc = json.loads(render_payload(pf, vals))
    assert doc == {"accountNumber": "1000000001", "status": "ACTIVE",
                   "balance": {"amount": 152340.75, "currency": "KES"},
                   "requestId": REQ_ID, "timestamp": TS}
    assert_valid(oas_validator("JamiiAccounts", "AccountBalance"), doc)


# ------------------------------------------------------------------ 1b customers ------------
def test_customer_sensitive_fields_are_all_removed():
    cus = api_root("JamiiCustomerAPI")
    script = by_description(cus, "strip-sensitive-fields").text
    removed = set(re.findall(r"'([A-Za-z]+)'", re.search(r"var drop = \[(.*?)\]", script, re.S).group(1)))
    user = json.loads((FIX / "dummyjson_user_1.json").read_text())
    must_go = {"password", "ssn", "ein", "bank", "crypto", "ip", "macAddress", "userAgent"}
    assert must_go <= removed
    assert removed <= set(user), f"paths not present in the real backend payload: {removed - set(user)}"
    remaining = {k: v for k, v in user.items() if k not in removed}
    assert {"id", "firstName", "lastName", "email"} <= set(remaining)


# ------------------------------------------------------------------ 1c loans ----------------
loan = api_root("JamiiLoanEligibilityAPI")


def loan_props(req):
    """Evaluate the request-mapping property chain exactly as defined in the artifact."""
    p = {"jamii.loan.maxDti": "40"}
    for k in ("monthlyIncome", "existingMonthlyDebt", "requestedAmount", "termMonths", "customerId"):
        p[f"jamii.loan.{k}"] = str(req[k])
    for name in ("jamii.loan.installment", "jamii.loan.soapIntA", "jamii.loan.soapIntB", "jamii.loan.maxAffordable"):
        p[name] = xstr(property_expr(loan, name), **p)
    return p


def test_request_mapping_arithmetic():
    p = loan_props({"customerId": "1", "monthlyIncome": 120000, "existingMonthlyDebt": 15000,
                    "requestedAmount": 300000, "termMonths": 24})
    assert p["jamii.loan.installment"] == "12500"
    assert p["jamii.loan.soapIntA"] == "2750000"       # (15000 + 12500) * 100
    assert p["jamii.loan.soapIntB"] == "120000"
    assert p["jamii.loan.maxAffordable"] == "33000"     # 120000 * 40% - 15000


def test_max_affordable_never_negative():
    p = loan_props({"customerId": "1", "monthlyIncome": 10000, "existingMonthlyDebt": 9000,
                    "requestedAmount": 5000, "termMonths": 10})
    assert p["jamii.loan.maxAffordable"] == "0"


@pytest.mark.parametrize("fixture,is_fault,is_client", [
    ("soap_divide_ok.xml", False, None),
    ("soap_fault_server.xml", True, False),   # real: System.OverflowException in Divide()
    ("soap_fault_client.xml", True, True),    # real: int32 parse failure in request
])
def test_soap_fault_classification(fixture, is_fault, is_client):
    body = soap_body(FIX / fixture)
    assert xeval(by_description(loan, "soap-fault-check").get("xpath"), body) is is_fault
    if is_fault:
        code = xstr(property_expr(loan, "jamii.soap.faultCode"), body)
        assert code in ("soap:Client", "soap:Server")
        assert xeval(by_description(loan, "soap-client-fault-check").get("xpath"), body,
                     jamii_soap_faultCode=code) is is_client
    else:
        assert xeval(by_description(loan, "soap-result-check").get("xpath"), body) is True


def test_soap_fault_log_line_masks_and_truncates():
    body = soap_body(FIX / "soap_fault_client.xml")
    expr = loan.xpath("//s:log/s:property[@name='faultString']", namespaces=NS)[0].get("expression")
    line = xstr(expr, body)
    assert 0 < len(line) <= 160 and "\n" not in line and not re.search(r"\d", line)


def test_eligibility_response_from_real_soap_reply():
    req = {"customerId": "1", "monthlyIncome": 120000, "existingMonthlyDebt": 15000,
           "requestedAmount": 300000, "termMonths": 24}
    p = loan_props(req)
    body = soap_body(FIX / "soap_divide_ok.xml")   # captured: Divide(3700000, 120000) = 30.83 -> 31? (.NET int division)
    p["jamii.loan.dti"] = xstr(property_expr(loan, "jamii.loan.dti"), body)
    p["jamii.loan.eligible"] = xstr(property_expr(loan, "jamii.loan.eligible"), **p)
    p["jamii.loan.decision"] = "ELIGIBLE" if p["jamii.loan.eligible"] == "true" else "NOT_ELIGIBLE"
    p["jamii.requestId"], p["jamii.timestamp"] = REQ_ID, TS
    pf = by_description(loan, "eligibility-response")
    doc = json.loads(render_payload(pf, [xstr(e, **p) for e in payload_args(pf)]))
    assert doc["assessment"]["debtToIncomeRatioPercent"] == int(body.xpath("string(//*[local-name()='DivideResult'])"))
    assert doc["eligible"] is (doc["assessment"]["debtToIncomeRatioPercent"] <= 40)
    assert_valid(oas_validator("JamiiLoans", "LoanEligibilityResponse"), doc)


def test_soap_request_template_is_well_formed():
    pf = by_description(loan, "soap-request")
    xml = render_payload(pf, ["2750000", "120000"])
    from lxml import etree
    root = etree.fromstring(xml)
    assert root.tag == "{http://tempuri.org/}Divide"
    assert [c.text for c in root] == ["2750000", "120000"]
