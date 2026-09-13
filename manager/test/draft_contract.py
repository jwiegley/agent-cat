#!/usr/bin/env python3
"""Validate actual draft and capture output with the existing frozen validator."""
from pathlib import Path
import sys
source, work = map(Path, sys.argv[1:])
sys.path.insert(0, str(source / "test"))
import manager_contract_probe as frozen
document = frozen.yaml.load((source / "doc/api/openapi.yaml").read_text(), Loader=frozen.UniqueYamlLoader)
for filename, schema in [("actual-request.json", "Request"), ("actual-ready.json", "Request"), ("actual-capture.json", "CaptureReceipt")]:
    validator = frozen.ContractValidator({"$id": frozen.BASE_URI, "components": document["components"],
        "allOf": [{"$ref": "#/components/schemas/" + schema}]}, registry=frozen.Registry(), format_checker=frozen.FORMATS)
    value = frozen.parse_json((work / filename).read_bytes())
    failures = list(validator.iter_errors(value))
    frozen.require(not failures, f"{filename}: {failures}")
    print(f"PASS frozen validator {filename}")
