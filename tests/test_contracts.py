"""Cross-artifact contract checks: MI <-> OpenAPI <-> apictl projects <-> API product."""
import copy
import json
import re

import pytest
import yaml
from jsonschema import Draft4Validator
from openapi_spec_validator import validate

from conftest import APIM, MI_ART, SYN, api_yaml, manifest, parse, swagger

APIS = [p.rsplit("-", 1)[0] for p in manifest()]


def norm(path):
    """/{accountNumber}/balance -> /{}/balance (parameter names may differ between layers)."""
    return re.sub(r"\{[^}]+\}", "{}", path.rstrip("/") or "/")


def mi_resources():
    out = {}
    for p in (MI_ART / "apis").glob("*.xml"):
        root = parse(p)
        for r in root.findall(f"{{{SYN}}}resource"):
            for m in r.get("methods").split():
                out[(root.get("context"), m, norm(r.get("uri-template")))] = root.get("name")
    return out


def test_manifest_matches_project_dirs():
    dirs = sorted(p.name for p in (APIM / "apis").iterdir() if p.is_dir())
    assert sorted(manifest()) == dirs


@pytest.mark.parametrize("api", APIS)
def test_openapi_is_valid(api):
    validate(swagger(api))


def test_product_openapi_is_valid():
    validate(yaml.safe_load((APIM / "api-products/JamiiCoreBanking-1.0.0/Definitions/swagger.yaml").read_text()))


@pytest.mark.parametrize("api", APIS)
def test_api_yaml_operations_match_openapi(api):
    ops = {(o["verb"].lower(), o["target"]) for o in api_yaml(api)["operations"]}
    spec = {(verb, path) for path, item in swagger(api)["paths"].items() for verb in item
            if verb in ("get", "post", "put", "delete", "patch")}
    assert ops == spec


@pytest.mark.parametrize("api", APIS)
def test_every_apim_operation_has_an_mi_backend_resource(api):
    data, mi = api_yaml(api), mi_resources()
    params = yaml.safe_load((APIM / "apis" / f"{api}-1.0.0/api_params.yaml").read_text())
    envs = {e["name"]: e for e in params["environments"]}
    assert {"dev", "prod"} <= set(envs), "both environments must be parameterised"
    for env in envs.values():
        url = env["configs"]["endpoints"]["production"]["url"]
        context = "/" + url.split("://", 1)[1].split("/", 1)[1]
        for op in data["operations"]:
            key = (context, op["verb"], norm(op["target"]))
            assert key in mi, f"{api} {op['verb']} {op['target']} -> no MI resource at {context} ({env['name']})"


@pytest.mark.parametrize("api", APIS)
def test_security_and_tiers_declared(api):
    data, spec = api_yaml(api), swagger(api)
    assert {"oauth2", "api_key"} & set(data["securityScheme"]), "an auth scheme is required"
    assert data["policies"], "a subscription tier is required"
    for item in spec["paths"].values():
        for op in item.values():
            assert op.get("security"), "every operation must be secured"


def test_at_least_one_api_uses_a_different_tier():
    tiers = {tuple(api_yaml(a)["policies"]) for a in APIS}
    assert len(tiers) > 1


def test_custom_policy_is_packaged_and_parameterised():
    used = [(a, p) for a in APIS for o in api_yaml(a)["operations"]
            for flow in o["operationPolicies"].values() for p in flow]
    assert used, "at least one custom gateway policy must be attached"
    for api, pol in used:
        base = APIM / "apis" / f"{api}-1.0.0" / "Policies" / f"{pol['policyName']}_{pol['policyVersion']}"
        spec = yaml.safe_load(base.with_suffix(".yaml").read_text())["data"]
        template = base.with_suffix(".j2").read_text()
        attrs = {a["name"]: a for a in spec["policyAttributes"]}
        assert set(pol["parameters"]) == set(attrs)
        for name, value in pol["parameters"].items():
            assert re.fullmatch(attrs[name]["validationRegex"], value)
            assert "{{" + name + "}}" in template
        assert spec["name"] == pol["policyName"] and spec["version"] == pol["policyVersion"]


def test_product_covers_every_operation_of_every_api():
    prod = yaml.safe_load((APIM / "api-products/JamiiCoreBanking-1.0.0/api_product.yaml").read_text())["data"]
    assert sorted(a["name"] for a in prod["apis"]) == sorted(APIS)
    for a in prod["apis"]:
        ops = {(o["verb"], o["target"]) for o in api_yaml(a["name"])["operations"]}
        assert {(o["verb"], o["target"]) for o in a["operations"]} == ops


def test_loan_schema_identical_in_mi_and_openapi(loan_schema):
    mi = copy.deepcopy(loan_schema)
    mi.pop("$schema"); mi.pop("title")
    # The only intended difference: APIM 4.4 can't merge boolean additionalProperties into an
    # API Product definition, so the OpenAPI copy leaves it out and MI alone enforces it.
    assert mi.pop("additionalProperties") is False
    oas = swagger("JamiiLoans")["components"]["schemas"]["LoanEligibilityRequest"]
    assert json.loads(json.dumps(mi, sort_keys=True)) == json.loads(json.dumps(oas, sort_keys=True))


VALID = {"customerId": "1", "monthlyIncome": 120000, "existingMonthlyDebt": 15000,
         "requestedAmount": 300000, "termMonths": 24}


@pytest.mark.parametrize("mutation,ok", [
    ({}, True),
    ({"currency": "KES"}, True),
    ({"monthlyIncome": 0}, False),
    ({"termMonths": 12.5}, False),
    ({"termMonths": 0}, False),
    ({"customerId": 1}, False),
    ({"customerId": "01"}, False),
    ({"requestedAmount": -5}, False),
    ({"currency": "USD"}, False),
    ({"unexpected": True}, False),
    ({"monthlyIncome": "lots"}, False),
])
def test_loan_request_schema(loan_schema, mutation, ok):
    Draft4Validator.check_schema(loan_schema)
    body = {**VALID, **mutation}
    assert Draft4Validator(loan_schema).is_valid(body) is ok


def test_loan_schema_requires_all_fields(loan_schema):
    for f in VALID:
        body = {k: v for k, v in VALID.items() if k != f}
        assert not Draft4Validator(loan_schema).is_valid(body), f"{f} should be required"
