"""Shared helpers: locate artifacts and evaluate Synapse XPath expressions with lxml.

Synapse uses XPath 1.0 (Jaxen); lxml uses libxml2's XPath 1.0. To run the *actual*
expressions from the MI artifacts, Synapse-specific constructs are rewritten into XPath
variables:  get-property('a.b')  ->  $a_b ,  $body stays $body.
"""
import json
import re
from pathlib import Path

import pytest
import yaml
from lxml import etree

ROOT = Path(__file__).resolve().parents[1]
MI_ART = ROOT / "mi/JamiiIntegrations/src/main/wso2mi/artifacts"
APIM = ROOT / "apim"
FIX = Path(__file__).parent / "fixtures"
SYN = "http://ws.apache.org/ns/synapse"
NS = {"s": SYN}


def mi_files():
    return sorted(p for p in MI_ART.rglob("*") if p.suffix in (".xml", ".dbs"))


def parse(path):
    return etree.parse(str(path)).getroot()


def api_root(name):
    return parse(MI_ART / "apis" / f"{name}.xml")


def by_description(root, desc):
    found = root.xpath(f"//*[@description='{desc}']")
    assert found, f"no mediator with description={desc!r}"
    return found[0]


def property_expr(root, name):
    found = root.xpath(f"//s:property[@name='{name}' and @expression]", namespaces=NS)
    assert found, f"no property {name!r} with an expression"
    return found[0].get("expression")


_GETPROP = re.compile(r"get-property\('([^']+)'\)")


def var(name):
    return re.sub(r"[^A-Za-z0-9]", "_", name)


def to_lxml(expr):
    return _GETPROP.sub(lambda m: "$" + var(m.group(1)), expr)


def soap_body(xml_path):
    root = parse(xml_path)
    body = root.xpath("/*[local-name()='Envelope']/*[local-name()='Body']")
    assert body, f"{xml_path} has no SOAP body"
    return body[0]


def xeval(expr, body=None, **props):
    """Evaluate a Synapse XPath with $body and properties bound. Returns XPath result."""
    variables = {var(k): str(v) for k, v in props.items()}
    if body is None:
        body = etree.Element("empty")
    variables["body"] = body
    return body.xpath(to_lxml(expr), **variables)


def xstr(expr, body=None, **props):
    """Synapse property semantics: the XPath result rendered as a string."""
    r = xeval(expr, body, **props)
    if isinstance(r, bool):
        return "true" if r else "false"
    if isinstance(r, float):
        return str(int(r)) if r == int(r) else repr(r)
    if isinstance(r, list):
        return r[0].text if r and hasattr(r[0], "text") else (str(r[0]) if r else "")
    return str(r)


def render_payload(pf, values):
    """Render a payloadFactory <format> with already-evaluated arg values."""
    fmt_el = pf.find(f"{{{SYN}}}format")
    children = list(fmt_el)
    fmt = etree.tostring(children[0], encoding="unicode") if children else fmt_el.text
    for i in range(len(values), 0, -1):
        fmt = fmt.replace(f"${i}", values[i - 1])
    return fmt


def payload_args(pf):
    return [a.get("expression") for a in pf.findall(f"{{{SYN}}}args/{{{SYN}}}arg")]


def swagger(api):
    return yaml.safe_load((APIM / "apis" / f"{api}-1.0.0" / "Definitions/swagger.yaml").read_text())


def api_yaml(api):
    return yaml.safe_load((APIM / "apis" / f"{api}-1.0.0" / "api.yaml").read_text())["data"]


def manifest():
    return [l.strip() for l in (APIM / "apis.manifest").read_text().splitlines()
            if l.strip() and not l.startswith("#")]


def resolve_schema(spec, schema):
    """Inline local $refs so jsonschema can validate a fragment of an OpenAPI doc."""
    if isinstance(schema, dict):
        if "$ref" in schema:
            node = spec
            for part in schema["$ref"].lstrip("#/").split("/"):
                node = node[part]
            return resolve_schema(spec, node)
        return {k: resolve_schema(spec, v) for k, v in schema.items()}
    if isinstance(schema, list):
        return [resolve_schema(spec, v) for v in schema]
    return schema


@pytest.fixture(scope="session")
def loan_schema():
    entry = parse(MI_ART / "local-entries/LoanEligibilityRequestSchema.xml")
    return json.loads(entry.text)
