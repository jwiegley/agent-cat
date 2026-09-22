#!/usr/bin/env python3
"""Exercise frozen stdin administration offline and through the original live Store."""
from pathlib import Path
import json
import os
import select
import socket
import subprocess
import tempfile
import threading
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

# A separate, short private namespace avoids Unix socket path limits on the data root.
admin_root = Path(tempfile.mkdtemp(prefix="admin.", dir=os.environ["TMPDIR"]))
address = admin_root / "admin.sock"
configuration["administrationRoot"] = str(admin_root)
config.write_text(json.dumps(configuration))
assert work.name in {"N1", "N8"}
owner_command = [str(owner), "serve-credentials", str(config), "+RTS", "-" + work.name, "-RTS"]


def expect_line(process, expected):
    assert select.select([process.stdout], [], [], 15)[0], "live owner barrier timed out"
    assert process.stdout.readline().strip() == expected, "live owner barrier mismatch"


def send_line(process, value):
    process.stdin.write(value + "\n")
    process.stdin.flush()


def raw_request(payload, eof=True):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(str(address))
        connection.sendall(payload)
        if eof:
            connection.shutdown(socket.SHUT_WR)
        with connection.makefile("rb") as stream:
            response = stream.read(1048577)
    assert len(response) < 1048576
    value = frozen.parse_json(response)
    assert not list(validator.iter_errors(value)), "live response violates frozen schema"
    return value


live = subprocess.Popen(owner_command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True)
joined = False
try:
    expect_line(live, "ready")
    assert address.stat().st_mode & 0o777 == 0o600
    assert call({"version": 1, "operation": "list-credentials"})["ok"]
    for payload, code, eof in [
        (b'{', "malformed-request", True),
        (b'{', "malformed-request", False),
        (b'{"version":1,"operation":"list-credentials"} {}', "malformed-request", True),
        (b'{"version":1,"operation":"list-credentials","operation":"private"}', "duplicate-field", True),
        (b' ' * 2097153, "size-limit", False),
    ]:
        refusal = raw_request(payload, eof)
        assert refusal["operation"] is None and refusal["error"]["code"] == code

    live_file = work / "cli-live.credential"
    issue = {"version": 1, "operation": "issue-credential", "label": "Live CLI",
             "scopes": ["observe"], "profileIds": ["profile_1"],
             "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(live_file)}
    live_issued = call(issue)
    assert live_issued["ok"] and live_issued["result"]["secretWritten"]
    secret = live_file.read_bytes()
    assert len(secret) == 64 and all(byte in b"0123456789abcdef" for byte in secret)
    assert live_file.stat().st_mode & 0o777 == 0o600
    assert secret not in json.dumps(live_issued, default=str).encode()
    live_id = live_issued["result"]["credential"]["credentialId"]
    other = call({**issue, "label": "Other live client", "outputFile": str(work / "cli-live-other.credential")})
    assert other["ok"]
    other_rotated = call({"version": 1, "operation": "rotate-credential",
                          "credentialId": other["result"]["credential"]["credentialId"],
                          "expiresAt": "2999-02-01t12:34:56.125z",
                          "outputFile": str(work / "cli-live-rotated.credential")})
    assert other_rotated["ok"]
    assert other_rotated["result"]["credential"]["clientId"] == other["result"]["credential"]["clientId"]
    # Forward one actual mutation, consume its confirmed reply, then drop that reply.
    # This is a connection fault, not a mocked manager success or a power-loss test.
    proxy_root = Path(tempfile.mkdtemp(prefix="reply.", dir=os.environ["TMPDIR"]))
    proxy_address = proxy_root / "admin.sock"
    delivered, relay_errors = [], []
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(proxy_address))
        proxy_address.chmod(0o600)
        listener.listen(1)
        listener.settimeout(10)

        def drop_reply():
            try:
                incoming, _ = listener.accept()
                with incoming:
                    incoming.settimeout(10)
                    with incoming.makefile("rb") as stream:
                        payload = stream.read(2097153)
                    delivered.append(raw_request(payload))
            except Exception as failure:
                relay_errors.append(failure)

        configuration["administrationRoot"] = str(proxy_root)
        config.write_text(json.dumps(configuration))
        relay = threading.Thread(target=drop_reply)
        relay.start()
        lost_file = work / "cli-lost-reply.credential"
        try:
            uncertain = call({**issue, "label": "Lost reply", "outputFile": str(lost_file)})
        finally:
            relay.join(timeout=20)
            configuration["administrationRoot"] = str(admin_root)
            config.write_text(json.dumps(configuration))
        assert not relay.is_alive(), "original reply-fault thread must join"
        assert not relay_errors, "reply-fault fixture must forward a real operation"
        assert len(delivered) == 1 and delivered[0]["ok"]
        assert not uncertain["ok"] and uncertain["error"]["code"] == "storage-unavailable"
        listener.settimeout(0.1)
        try:
            repeated, _ = listener.accept()
        except TimeoutError:
            pass
        else:
            repeated.close()
            raise AssertionError("lost administrative reply must not reconnect or replay")
    proxy_address.unlink()
    assert lost_file.stat().st_mode & 0o777 == 0o600
    retained = call({"version": 1, "operation": "list-credentials"})
    lost_id = delivered[0]["result"]["credential"]["credentialId"]
    assert sum(item["credentialId"] == lost_id for item in retained["result"]["credentials"]) == 1

    send_line(live, "watch")
    expect_line(live, "watching")
    # The native owner now holds response configuration/file scopes and a worker registration.
    assert call({"version": 1, "operation": "revoke-credential",
                 "credentialId": other_rotated["result"]["credential"]["credentialId"]})["ok"]
    send_line(live, "unrelated")
    expect_line(live, "unchanged")
    assert call({"version": 1, "operation": "revoke-credential", "credentialId": live_id})["ok"]
    send_line(live, "revoked")
    expect_line(live, "revoked")
    send_line(live, "stop")
    output, errors = live.communicate(timeout=15)
    joined = True
    assert live.returncode == 0 and output.strip() == "closed" and not errors, errors
finally:
    if not joined:
        if live.poll() is None:
            live.terminate()
        output, errors = live.communicate(timeout=15)
        if errors:
            sys.stderr.write(errors)
assert not address.exists(), "normal original-owner cleanup removes its socket"

# The configured channel never falls back to offline mutation, even when its owner is gone.
unavailable_file = work / "cli-no-offline-fallback.credential"
unavailable = call({**issue, "outputFile": str(unavailable_file)})
assert not unavailable["ok"] and unavailable["error"]["code"] == "storage-unavailable"
assert not unavailable_file.exists()

# A stale private socket name is disposable only after acquiring its exclusive directory lease.
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
    stale.bind(str(address))
    address.chmod(0o600)
restarted = subprocess.run(owner_command, input="stop\n", stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, timeout=30)
assert restarted.returncode == 0 and restarted.stdout.splitlines() == ["ready", "closed"], restarted.stderr
assert not address.exists()

# An unrelated file and a symbolic link are never removed as stale socket entries.
sentinel = work / "cli-socket-sentinel"
sentinel.write_bytes(b"keep")
for symbolic in [False, True]:
    if symbolic:
        address.symlink_to(sentinel)
    else:
        address.write_bytes(b"keep")
    refused = subprocess.run(owner_command, input="stop\n", stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, timeout=30)
    assert refused.returncode != 0, "non-socket endpoint must refuse startup"
    assert sentinel.read_bytes() == b"keep"
    assert address.is_symlink() if symbolic else address.read_bytes() == b"keep"
    address.unlink()
print("PASS live original-Store administration, retained-response revocation, endpoint ownership and no offline fallback")
