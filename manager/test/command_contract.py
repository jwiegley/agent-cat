#!/usr/bin/env python3
"""Check emitted receipts with the existing frozen contract validator."""
from pathlib import Path
import sys

source, work = map(Path, sys.argv[1:])
sys.path.insert(0, str(source / "test"))
import manager_contract_probe as frozen

document = frozen.yaml.load((source / "doc/api/openapi.yaml").read_text(), Loader=frozen.UniqueYamlLoader)
rooted = {"$id": frozen.BASE_URI, "components": document["components"],
          "allOf": [{"$ref": "#/components/schemas/CommandReceipt"}]}
validator = frozen.ContractValidator(rooted, registry=frozen.Registry(), format_checker=frozen.FORMATS)
files = sorted([*work.glob("actual-*.json"), work / "worst-case-receipt.json"])
frozen.require(len(files) >= 4, "missing emitted receipt evidence")
for path in files:
    value = frozen.parse_json(path.read_bytes())
    errors = list(validator.iter_errors(value))
    frozen.require(not errors, f"emitted receipt violates frozen contract: {path.name}: {errors}")
    print(f"PASS frozen validator emitted receipt: {path.name}")
