"""Static checks on the MI artifacts: well-formedness, references, logging/PII hygiene."""
import re

import pytest
from lxml import etree

from conftest import MI_ART, NS, ROOT, SYN, mi_files, parse

ALL = mi_files()
APIS = sorted((MI_ART / "apis").glob("*.xml"))


@pytest.mark.parametrize("path", ALL, ids=lambda p: p.name)
def test_well_formed(path):
    parse(path)


def _defined(kind):
    return {parse(p).get("name") or parse(p).get("key") for p in (MI_ART / kind).glob("*.xml")}


def test_every_reference_resolves():
    sequences, endpoints, entries = _defined("sequences"), _defined("endpoints"), _defined("local-entries")
    problems = []
    for p in ALL:
        root = parse(p)
        for el in root.iter():
            if not isinstance(el.tag, str):
                continue
            tag = etree.QName(el).localname
            key = el.get("key")
            if tag == "sequence" and key and key not in sequences:
                problems.append(f"{p.name}: sequence {key}")
            if tag == "endpoint" and key and key not in endpoints:
                problems.append(f"{p.name}: endpoint {key}")
            if tag == "schema" and key and key not in entries:
                problems.append(f"{p.name}: schema {key}")
            fs = el.get("faultSequence")
            if fs and fs not in sequences:
                problems.append(f"{p.name}: faultSequence {fs}")
    assert not problems, problems


@pytest.mark.parametrize("path", APIS, ids=lambda p: p.name)
def test_every_resource_has_fault_sequence(path):
    for res in parse(path).findall(f"{{{SYN}}}resource"):
        assert res.get("faultSequence"), f"{path.name} {res.get('uri-template')} has no faultSequence"


@pytest.mark.parametrize("path", APIS, ids=lambda p: p.name)
def test_every_resource_inits_request(path):
    """Every resource must run the common init (IDs, masking, header stripping, REQUEST_IN log)."""
    for res in parse(path).findall(f"{{{SYN}}}resource"):
        first_seq = res.find(f"{{{SYN}}}inSequence").xpath(".//s:sequence[@key]", namespaces=NS)
        assert first_seq and first_seq[0].get("key") == "Jamii_InitRequest"


def test_logs_never_contain_raw_identifiers_or_payloads():
    """Log mediators may only log masked refs and metadata - never path params, bodies, or full messages."""
    forbidden = re.compile(r"uri\.var\.|jamii\.rawRef|json-eval|jamii\.loan\.customerId|\$body|ERROR_MESSAGE")
    bad = []
    for p in ALL:
        for log in parse(p).xpath("//s:log", namespaces=NS):
            if log.get("level") in ("full", "headers") or log.get("logFullPayload") == "true":
                bad.append(f"{p.name}: full/headers log level")
            for prop in log.xpath("s:property", namespaces=NS):
                expr = prop.get("expression") or ""
                if expr.startswith("substring(translate(") and "'##########'" in expr:
                    continue  # backend error text with every digit masked, truncated: ops-only
                if expr == "normalize-space($body//*[local-name()='ds_code'])":
                    continue  # data-service error class, no data
                if forbidden.search(expr):
                    bad.append(f"{p.name}: log property {prop.get('name')} = {expr}")
    assert not bad, bad


def test_no_hardcoded_credentials_or_hosts_for_external_backends():
    ds = (MI_ART / "data-services/JamiiAccountDataService.dbs").read_text()
    for prop in ("driverClassName", "url", "username", "password"):
        assert re.search(rf'<property name="{prop}">\$SYSTEM:', ds), f"{prop} must be injected"
    for ep in ("CustomerBackendEP", "LoanEligibilitySoapEP"):
        txt = (MI_ART / f"endpoints/{ep}.xml").read_text()
        assert "$SYSTEM:" in txt, f"{ep} URL must be environment-injected"


def test_queries_are_parameterised():
    ds = parse(MI_ART / "data-services/JamiiAccountDataService.dbs")
    for q in ds.findall("query"):
        sql = q.findtext("sql")
        assert "?" in sql and not re.search(r"[:$]\{|\+|\|\|", sql), sql
        assert len(q.findall("param")) == sql.count("?")


def test_backend_endpoints_have_timeouts():
    for p in (MI_ART / "endpoints").glob("*.xml"):
        root = parse(p)
        dur = root.xpath("//s:timeout/s:duration/text()", namespaces=NS)
        action = root.xpath("//s:timeout/s:responseAction/text()", namespaces=NS)
        assert dur and int(dur[0]) <= 10000, f"{p.name}: timeout missing or > 10s"
        assert action == ["fault"], f"{p.name}: timeout must fault so the error handler runs"


def test_error_codes_are_documented():
    """Every error code the runtime can emit appears in the README error catalogue."""
    codes = set()
    for p in ALL:
        codes |= set(parse(p).xpath("//s:property[@name='jamii.err.code']/@value", namespaces=NS))
    readme = (ROOT / "README.md").read_text()
    missing = sorted(c for c in codes if f"`{c}`" not in readme)
    assert codes and not missing, f"undocumented error codes: {missing}"


def test_responses_leave_through_single_exit():
    """respond/send only in Jamii_SendResponse, so headers/logging are uniform."""
    for p in ALL:
        if p.stem == "Jamii_SendResponse":
            continue
        assert not parse(p).xpath("//s:respond|//s:send", namespaces=NS), f"{p.name} responds directly"
