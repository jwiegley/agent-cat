#!/usr/bin/env python3
"""Validate actual artifact adapter output against the frozen schemas and bytes."""
from pathlib import Path
import hashlib
import sys

source, work = map(Path, sys.argv[1:])
sys.path.insert(0, str(source / "test"))
import manager_contract_probe as frozen

document = frozen.yaml.load((source / "doc/api/openapi.yaml").read_text(), Loader=frozen.UniqueYamlLoader)

def validate(schema, value):
    validator = frozen.ContractValidator({"$id": frozen.BASE_URI, "components": document["components"],
        "allOf": [{"$ref": "#/components/schemas/" + schema}]}, registry=frozen.Registry(), format_checker=frozen.FORMATS)
    failures = list(validator.iter_errors(value))
    frozen.require(not failures, f"{schema}: invalid generated representation")

for kind in ("source", "export"):
    metadata = frozen.parse_json((work / f"{kind}-metadata.json").read_bytes())
    validate("ArtifactMetadata", metadata)
    raw = (work / f"{kind}-download.utf8").read_bytes()
    expected = source / "test/fixtures/manager/v1/valid" / ("artifact-download.utf8" if kind == "source" else "export-download.utf8")
    assert raw == expected.read_bytes()
    assert metadata["bytes"] == str(len(raw))
    assert metadata["sha256"] == hashlib.sha256(raw).hexdigest()
receipt = frozen.parse_json((work / "export-receipt.json").read_bytes())
validate("ExportReceipt", receipt)
for item in frozen.parse_json((work / "export-items.json").read_bytes()):
    validate("ExportReceipt", item)
items = frozen.parse_json((work / "outputs.json").read_bytes())
for item in items + frozen.parse_json((work / "bounded-outputs.json").read_bytes()):
    validate("OutputItem", item)
expected = frozen.parse_json((source / "test/fixtures/manager/v1/valid/outputs.json").read_bytes())["items"]
assert items[:2] == expected[:2]
assert items[-1]["artifact"]["sha256"] == expected[-1]["artifact"]["sha256"]
assert receipt["bytes"] == "30" and receipt["sha256"] == metadata["sha256"]
validate("ArtifactMetadata", frozen.parse_json((work / "history/history-artifact.json").read_bytes()))
for item in frozen.parse_json((work / "history/history.json").read_bytes()):
    validate("Run", item)
print("PASS frozen Run, OutputItem, ArtifactMetadata, ExportReceipt and exact source/export fixtures")
