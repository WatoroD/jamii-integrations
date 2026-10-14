Fixtures used by tests/test_mappings.py.

* `soap_*.xml` and `dummyjson_*.json` are **real responses captured from the public backends**
  (DNE Online Calculator, DummyJSON) on 2026-10-13, so the XPath/JSON mappings are tested
  against exactly what those services return - including the .NET stack traces in SOAP faults
  that must never reach a client.
* `ds_*.xml` are the data-service result shapes (as seen by the API after MI wraps the POX
  reply in a SOAP body) for found / not found / DB down.
