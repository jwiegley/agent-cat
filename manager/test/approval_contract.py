#!/usr/bin/env python3
"""Check generated public preparation/receipt values with the frozen contract."""
from pathlib import Path
import sys

source, work = map(Path, sys.argv[1:])
sys.path.insert(0, str(source / "test"))
import manager_contract_probe as frozen

document = frozen.yaml.load((source / "doc/api/openapi.yaml").read_text(), Loader=frozen.UniqueYamlLoader)
files = [(path,"Preparation") for path in sorted(work.glob("public-preparation*.json")) + sorted(work.glob("preparation.json"))]
files += [(path,"CommandReceipt") for path in work.glob("approved-receipt.json")]
if not files:
    raise RuntimeError("no real public preparation evidence")
for path, schema in files:
    validator = frozen.ContractValidator({"$id": frozen.BASE_URI, "components": document["components"],
        "allOf": [{"$ref": "#/components/schemas/" + schema}]}, registry=frozen.Registry(), format_checker=frozen.FORMATS)
    value = frozen.parse_json(path.read_bytes())
    failures = list(validator.iter_errors(value))
    frozen.require(not failures, f"{path.name}: {failures}")
    print(f"PASS frozen public preparation: {path.name}")
