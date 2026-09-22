#!/usr/bin/env python3
"""Exercise the real offline stdin CLI against the frozen response validator."""
from pathlib import Path
import json
import os
import subprocess
import sys

source, work, runner, owner = map(Path, sys.argv[1:])
sys.path.insert(0, str(source / "test"))
import manager_contract_probe as frozen

document = frozen.yaml.load((source / "doc/api/openapi.yaml").read_text(), Loader=frozen.UniqueYamlLoader)
validator = frozen.ContractValidator(
    {"$id": frozen.BASE_URI, "components": document["components"],
     "allOf": [{"$ref": "#/components/schemas/LocalAdminResponse"}]},
    registry=frozen.Registry(), format_checker=frozen.FORMATS)
original = work / "credentials.json"
configuration = json.loads(original.read_bytes())
for profile in configuration["profiles"]:
    profile["targetArguments"] = ["--scripted"]
config = work / "credential-cli.json"
config.write_text(json.dumps(configuration))
config.chmod(0o600)


def call(request):
    payload = request if isinstance(request, bytes) else json.dumps(request).encode()
    result = subprocess.run([str(runner), "--manager", "admin", "--config", str(config)],
                            input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    assert not result.stderr, "admin diagnostics must not contain private input or paths"
    assert len(result.stdout) <= 1048576, "bounded JSON including terminating newline"
    value = frozen.parse_json(result.stdout)
    assert not list(validator.iter_errors(value)), "actual admin output violates frozen schema"
    assert result.returncode == (0 if value["ok"] else 1), "admin exit mapping"
    return value


for payload, code in [
    (b'{', "malformed-request"),
    (b'{"version":1}', "malformed-request"),
    (b'{"version":1,"operation":"private-unknown"}', "unknown-operation"),
    (b'{"version":2,"operation":"list-credentials"}', "unsupported-version"),
    (b'{"version":1,"operation":"list-credentials","secret":"private"}', "unknown-field"),
    (b'{"version":1,"operation":"list-credentials","operation":"private"}', "duplicate-field"),
    (b' ' * 2097153, "size-limit"),
]:
    value = call(payload)
    assert value["operation"] is None and value["error"]["code"] == code
    assert value["error"]["message"] == ""

for operation in ["status", "reload-profiles", "drain", "shutdown", "check-store"]:
    value = call({"version": 1, "operation": operation})
    assert not value["ok"] and value["error"]["code"] == "state-conflict"

holding = subprocess.Popen([str(owner), "hold-credentials", str(original)],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert holding.stdout.readline().strip() == "ready", "original Store owner did not acquire lease"
    value = call({"version": 1, "operation": "list-credentials"})
    assert not value["ok"] and value["error"]["code"] == "storage-unavailable"
finally:
    holding.terminate()
    holding.communicate(timeout=10)

assert call({"version": 1, "operation": "list-credentials"})["ok"]
destination = work / "cli-one-time.credential"
issued = call({"version": 1, "operation": "issue-credential", "label": "CLI",
               "scopes": ["observe"], "profileIds": ["profile_1"],
               "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(destination)})
assert issued["ok"] and issued["result"]["secretWritten"]
bearer = destination.read_bytes()
assert len(bearer) == 64 and all(byte in b"0123456789abcdef" for byte in bearer)
assert os.stat(destination).st_mode & 0o777 == 0o600
assert bearer not in json.dumps(issued, default=str).encode() and str(destination) not in json.dumps(issued, default=str)
rotated = call({"version": 1, "operation": "rotate-credential",
                "credentialId": issued["result"]["credential"]["credentialId"],
                "expiresAt": "2999-01-01T00:00:00Z",
                "outputFile": str(work / "cli-rotated.credential")})
assert rotated["ok"] and rotated["result"]["credential"]["clientId"] == issued["result"]["credential"]["clientId"]
revoked = call({"version": 1, "operation": "revoke-credential",
                "credentialId": rotated["result"]["credential"]["credentialId"]})
assert revoked["ok"]
print("PASS frozen stdin CLI, exclusive offline ownership, private issuance and revocation")
