#!/usr/bin/env python3
"""Exercise the foreground HTTPS boundary with private local credentials and TLS."""
from pathlib import Path
import hashlib
import http.client
import json
import os
import secrets
import socket
import ssl
import subprocess
import sys
import time

source, work, runner = map(Path, sys.argv[1:4])
native = sys.argv[4]
tui_approval = len(sys.argv) == 6 and sys.argv[5] == "tui-approval"
mixed = len(sys.argv) == 6 and sys.argv[5] in ("mixed", "mixed-confirm", "tui-approval")
confirm_uncertain = mixed and sys.argv[5] == "mixed-confirm"
assert len(sys.argv) == 5 or mixed
assert not tui_approval or os.environ.get("TUI_CHECK")
assert native in ("1", "8")
print(f"work={work}", flush=True)
sys.path.insert(0, str(source / "test"))
import manager_contract_probe as frozen

document = frozen.yaml.load((source / "doc/api/openapi.yaml").read_text(), Loader=frozen.UniqueYamlLoader)


def validate(schema, value, raw=None):
    validator = frozen.ContractValidator(
        {"$id": frozen.BASE_URI, "components": document["components"],
         "allOf": [{"$ref": "#/components/schemas/" + schema}]},
        registry=frozen.Registry(), format_checker=frozen.FORMATS)
    errors = list(validator.iter_errors(value))
    if errors:
        if raw is not None:
            (work / (schema + "-invalid.json")).write_bytes(raw)
        print("SCHEMA", schema, [(list(error.absolute_path), error.validator) for error in errors[:8]], flush=True)
        raise AssertionError(f"actual HTTP {schema} violates frozen contract")


for name in ("manager", "admin"):
    (work / name).mkdir(mode=0o700)
cert, key = work / "certificate.pem", work / "key.pem"
with (work / "certificate.log").open("wb") as log:
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                    "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                    "-keyout", str(key), "-out", str(cert)], check=True, stdout=log, stderr=log, timeout=30)
with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]
configuration = {
    "version": 1, "managerRoot": str(work / "manager"), "localRetentionRoots": [],
    "runners": [{"alias": "runner", "executable": str(runner), "prefix": []}],
    "profiles": [{"id": "profile_1", "runner": "runner", "workspace": str(work),
                  "workspaceLabel": "HTTPS fixture", "targetLabel": "Deterministic scripted",
                  "targetArguments": ["--scripted"], "environment": [], "ownership": "service-owned",
                  "quarantined": False, "personAnswering": "local-control", "resourceKeys": []}],
    "limits": {"drafts": 100, "globalDrafts": 100, "globalCaptureBytes": 67108864,
               "globalPageSets": 2, "globalConnections": 8, "globalDatabaseReaders": 2,
               "globalMutationLedgerBytes": 16777216, "safetyControlsPerMinute": 100, "executionReservations": 1},
    "https": {"host": "127.0.0.1", "port": port, "certificateFile": str(cert), "keyFile": str(key),
              "allowedHosts": [f"127.0.0.1:{port}"], "allowedOrigins": ["https://example.invalid"],
              "allowedPeers": ["127.0.0.1"]}}
if mixed:
    adapters = work / "adapters"
    adapters.mkdir(mode=0o700)
    launcher = adapters / "mixed-adapter"
    program = source / "engine/acp/test/retry_adapter.py"
    launcher.write_text(f"#!{sys.executable} -B\nimport os\nos.execv({sys.executable!r},[{sys.executable!r},'-B',{str(program)!r}])\n")
    launcher.chmod(0o700)
    configuration["profiles"][0].update(
        targetLabel="Deterministic ACP retry", targetArguments=["--engine", "acp", "--adapter", "mixed-adapter"],
        environment=[{"name": "PATH", "value": str(adapters)}])
config = work / "configuration.json"
config.write_text(json.dumps(configuration))
config.chmod(0o600)


def administration(payload):
    completed = subprocess.run([str(runner), "--manager", "admin", "--config", str(config)],
                               input=json.dumps(payload).encode(), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=20)
    value = frozen.parse_json(completed.stdout)
    validate("LocalAdminResponse", value)
    assert not completed.stderr and completed.returncode == 0 and value["ok"], (
        "local administration refused", completed.returncode, value.get("error", {}).get("code"))
    return value


issued = administration({"version": 1, "operation": "issue-credential", "label": "HTTPS fixture",
                         "scopes": ["observe", "submit"] + (["control", "export"] if mixed else []), "profileIds": ["profile_1"],
                         "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential")})
bearer = (work / "credential").read_bytes().decode("ascii")
configuration["administrationRoot"] = str(work / "admin")
config.write_text(json.dumps(configuration))
context = ssl.create_default_context(cafile=str(cert))
context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3


def exchange(path, headers=None, method="GET", payload=None):
    connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
    try:
        connection.request(method, path, body=payload, headers=headers or {})
        response = connection.getresponse()
        body = response.read(1048577)
        assert len(body) <= 1048576
        assert response.getheader("Cache-Control") == "no-store"
        assert response.getheader("X-Content-Type-Options") == "nosniff"
        value = frozen.parse_json(body)
        if response.status >= 400:
            validate("Problem", value)
        elif method == "POST":
            assert response.getheader("Location") == value["links"]["self"]
        return response.status, value, body, dict((name.lower(), value) for name, value in response.getheaders())
    finally:
        connection.close()


def request(path, headers=None, method="GET", payload=None):
    deadline = time.monotonic() + 5
    while True:
        status, value, raw = exchange(path, headers, method, payload)[:3]
        if method != "GET" or status != 503 or time.monotonic() >= deadline:
            return status, value, raw
        assert value["code"] == "storage-unavailable"
        # Fresh read observations may contend with original coordinator work.
        # No POST enters this loop.
        time.sleep(0.05)


def run_mixed(created, workflow, capabilities, authorized):
    text = "Café λ — explicit false.\nSecond line."
    request_uri = created["links"]["self"]
    receipts = []

    def observed(path, schema):
        deadline = time.monotonic() + 5
        while True:
            status, value, raw, headers = exchange(path, authorized)
            if status != 503:
                break
            assert value["code"] == "storage-unavailable" and time.monotonic() < deadline, ("read unavailable", path)
            # These are new read observations under the fail-fast admission policy,
            # never a repeated mutation or an inferred successful effect.
            time.sleep(0.05)
        assert status == 200, (path, status, value.get("code"))
        validate(schema, value, raw)
        return value, headers.get("etag"), raw

    def wait_for(path, schema, ready):
        deadline = time.monotonic() + 40
        while True:
            value, tag, raw = observed(path, schema)
            if ready(value):
                return value, tag, raw
            if schema == "Request" and value["phase"] in ("draft", "withdrawn", "refused"):
                (work / "wait-last.json").write_bytes(raw)
                raise AssertionError(("request preparation did not remain active", path, value["phase"]))
            if time.monotonic() >= deadline:
                (work / "wait-last.json").write_bytes(raw)
                raise AssertionError(("observation deadline", path))
            time.sleep(0.05)

    def mutate(path, body, tag):
        assert tag is not None and tag.startswith('"') and tag.endswith('"')
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
        headers = authorized | {"Content-Type": "application/json", "Idempotency-Key": key, "If-Match": tag}
        status, receipt, _, _ = exchange(path, headers, method="POST", payload=payload)
        if status == 503 and confirm_uncertain:
            # This optional test scenario explicitly chooses one reconciliation
            # resend, just as it explicitly chooses approval. Production Client
            # must not make this choice. URI/key/body/precondition stay unchanged.
            print("OPERATOR CONFIRM exact retained attempt:", body["operation"], flush=True)
            current, _, _ = observed("/v1/capabilities", "Capabilities")
            assert current["authorityEpoch"] == capabilities["authorityEpoch"]
            status, receipt, _, _ = exchange(path, headers, method="POST", payload=payload)
        assert status == 202, ("mutation refused or uncertain", body["operation"], status, receipt.get("code"))
        validate("CommandReceipt", receipt)
        receipts.append(receipt["links"]["self"])
        if body["operation"] == "approve":
            # Runtime association is independent evidence. The approval receipt
            # remains dispatch-attempted and is not reclassified as delivered.
            return receipt["links"]["self"]
        value, _, _ = wait_for(receipt["links"]["self"], "CommandReceipt",
            lambda value: value["state"] in ("effect-observed", "refused", "unresolved"))
        assert value["state"] == "effect-observed", ("mutation not effected", body["operation"], value["state"])

    for declaration in workflow["inputs"]:
        current, tag, _ = observed(request_uri, "Request")
        mutate(request_uri, {"operation": "set-input", "input": {"name": declaration["name"],
            "source": "literal", "value": text}}, tag)
    current, tag, _ = observed(request_uri, "Request")
    assert not current["readiness"]["missing"] and not current["readiness"]["errors"]
    assert all(item["value"] == text for item in current["readiness"]["supplied"])
    mutate(request_uri, {"operation": "enqueue"}, tag)
    current, _, _ = wait_for(request_uri, "Request", lambda value: value["preparationId"] is not None)
    preparation, tag, raw = observed("/v1/preparations/" + current["preparationId"], "Preparation")
    (work / "exact-review.json").write_bytes(raw)
    assert preparation["requestId"] == created["id"] and preparation["state"] == "live"
    for item in preparation["review"]["inputs"]:
        declaration = next(value for value in workflow["inputs"] if value["name"] == item["name"])
        # The logical literal stays unchanged. Native prompt transport adds its
        # declared LF, and the exact approval hashes those native input bytes.
        expected = text.encode() + (b"\n" if declaration["source"] == "prompt" else b"")
        assert item["source"] == "literal" and item["bytes"] == str(len(expected))
        assert item["sha256"] == hashlib.sha256(expected).hexdigest()
    overview, _, raw = observed("/v1/snapshot", "OverviewSnapshot")
    assert any(item["kind"] == "preparation" and item["preparation"]["id"] == preparation["id"] for item in overview["items"])
    (work / "review-overview.json").write_bytes(raw)
    selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")
    approval = mutate("/v1/preparations/" + preparation["id"],
           {"operation": "approve", **{key: preparation[key] for key in selectors}}, tag)
    current, _, _ = wait_for(request_uri, "Request", lambda value: value["runId"] is not None)
    run = current["runId"]
    base = "/v1/runs/" + run
    answered = recovered = False
    deadline = time.monotonic() + 50
    while True:
        snapshot, _, raw = observed(base + "/snapshot", "RunSnapshot")
        assert snapshot["page"]["next"] is None
        runtime = snapshot["runtime"]
        if runtime is not None and runtime["status"] in ("succeeded", "failed", "cancelled"):
            assert runtime["status"] == "succeeded" and answered and recovered
            (work / "terminal-snapshot.json").write_bytes(raw)
            break
        assert time.monotonic() < deadline, "mixed workflow terminal deadline"
        control, control_tag, _ = observed(base + "/control", "RunControl")
        head = control["decisionHeadId"]
        if head is None:
            time.sleep(0.05)
            continue
        decision, decision_tag, _ = observed("/v1/decisions/" + head, "Decision")
        assert decision["position"] == 0 and decision["state"] == "pending" and decision["runId"] == run
        overview, _, raw = observed("/v1/snapshot", "OverviewSnapshot")
        assert any(item["kind"] == "run" and item["run"]["id"] == run for item in overview["items"])
        assert any(item["kind"] == "decision" and item["decision"]["id"] == head for item in overview["items"])
        (work / ("decision-" + decision["kind"] + ".json")).write_bytes(raw)
        body = {"occurrenceId": decision["address"]["occurrenceId"], "generation": decision["generation"]}
        if decision["kind"] == "question":
            assert decision["question"]["code"] == "flag"
            body.update(operation="answer", value=False)
            mutate("/v1/decisions/" + head, body, decision_tag)
            answered = True
        else:
            assert any(offer["operation"] == "retry" and offer["generation"] == decision["generation"]
                       and offer["address"] == decision["address"] for offer in control["offers"])
            body.update(operation="retry")
            mutate(base + "/control", body, control_tag)
            recovered = True
    value, _, raw = observed(base, "Run")
    (work / "terminal-run.json").write_bytes(raw)
    outputs, _, _ = observed(base + "/outputs", "OutputPage")
    result = next(item for item in outputs["items"] if item["kind"] == "result")
    assert result["verification"]["state"] == "verified" and result["artifact"]["runId"] == run
    artifact = result["artifact"]
    assert artifact["id"] == result["verification"]["artifactId"] and artifact["kind"] == "source-result"
    connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
    try:
        connection.request("GET", artifact["download"], headers=authorized | {"Accept": "application/octet-stream"})
        response = connection.getresponse()
        actual = response.read(int(artifact["bytes"]) + 1)
        assert response.status == 200 and response.getheader("Content-Type") == "application/octet-stream"
        assert response.getheader("Content-Disposition") == "attachment"
        assert response.getheader("Cache-Control") == "no-store" and response.getheader("X-Content-Type-Options") == "nosniff"
        assert len(actual) == int(artifact["bytes"]) and hashlib.sha256(actual).hexdigest() == artifact["sha256"]
        (work / "verified-result.json").write_bytes(actual)
    finally:
        connection.close()
    pending, _, raw = observed(approval, "CommandReceipt")
    assert pending["state"] == "dispatch-attempted" and pending["effect"] is None
    (work / "approval-still-pending.json").write_bytes(raw)
    released, _, raw = wait_for(request_uri, "Request",
        lambda value: value["runId"] == run and value["admission"]["state"] == "released")
    assert released["phase"] == "associated"
    (work / "released-request.json").write_bytes(raw)
    print("PASS actual HTTP mixed workflow: Unicode, exact approval, typed false, retry, terminal observation and verified bytes; approval delivery remains distinct", flush=True)


# Each foreground process is the original Popen object. Restart is attempted only
# after its own wait, and must reacquire the same Store and administration leases.
for iteration in range(2):
    with (work / f"server-{iteration}.stdout").open("wb") as output, (work / f"server-{iteration}.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            deadline = time.monotonic() + 40
            while True:
                assert process.poll() is None, "foreground manager exited before HTTPS readiness"
                try:
                    status, _, _ = request("/v1/profiles")
                    break
                except ConnectionRefusedError:
                    assert time.monotonic() < deadline, "HTTPS readiness deadline"
                    time.sleep(0.05)
            assert status == 401
            unknown, _, _ = request("/v1/unknown")
            assert unknown == 401, "authentication must precede resource existence"
            authorized = {"Authorization": "Bearer " + bearer}
            if iteration == 0:
                status, value, body = request("/v1/profiles", authorized)
                assert status == 200
                validate("ProfilePage", value)
                assert [item["id"] for item in value["items"]] == ["profile_1"]
                (work / "profiles.json").write_bytes(body)
                status, catalogue, raw = request("/v1/workflows?profileId=profile_1", authorized)
                assert status == 200
                validate("WorkflowPage", catalogue)
                assert catalogue["items"] and catalogue["page"]["next"] is None
                for workflow in catalogue["items"]:
                    assert workflow["help"] and "controlFd" not in workflow["capabilities"]
                    assert workflow["profileRevision"] == value["items"][0]["revision"]
                (work / "workflows.json").write_bytes(raw)
                workflow = next(item for item in catalogue["items"] if item["name"] == "mixed-controls") if mixed else catalogue["items"][0]
                status, individual, _ = request("/v1/workflows/" + workflow["id"], authorized)
                assert status == 200 and individual == workflow
                validate("Workflow", individual)
                status, _, _ = request("/v1/workflows?profileId=not_authorized", authorized)
                assert status == 403
                status, _, _ = request("/v1/workflows?profileId=profile_1&profileId=profile_1", authorized)
                assert status == 400
                status, _, _ = request("/v1/workflows", authorized)
                assert status == 400
                for extra in ({"Origin": "https://untrusted.invalid"}, {"Cookie": "session=not-authority"},
                              {"Forwarded": "for=127.0.0.1"}, {"Host": "untrusted.invalid"}):
                    status, _, _ = request("/v1/profiles", authorized | extra)
                    assert status in (400, 403)
                status, capabilities, raw = request("/v1/capabilities", authorized)
                assert status == 200
                validate("Capabilities", capabilities)
                assert capabilities["transports"] == ["sse", "polling"]
                assert capabilities["versions"]["managerStore"] == list(range(1, 13))
                (work / "capabilities.json").write_bytes(raw)
                if os.environ.get("CLIENT_CHECK") is not None or os.environ.get("TUI_CHECK") is not None:
                    client_profile = work / "client-profile.json"
                    client_profile.write_text(json.dumps({"version": 1, "endpoint": f"https://127.0.0.1:{port}/v1",
                        "credentialFile": str(work / "credential"), "caFile": str(cert)}))
                    client_profile.chmod(0o600)
                    if os.environ.get("CLIENT_CHECK") is not None:
                        with (work / "client-check.log").open("wb") as log:
                            subprocess.run([os.environ["CLIENT_CHECK"], "real", str(client_profile),
                                            "+RTS", "-N" + native, "-RTS"], stdout=log, stderr=log, check=True, timeout=30)
                        print("PASS public Client facade against the running protected manager", flush=True)
                    if os.environ.get("TUI_CHECK") is not None:
                        from tui_probe import TuiSession
                        client_state = work / "unused-client-state"
                        command = [os.environ["TUI_CHECK"], "--tui", "--service", str(client_profile),
                                   "+RTS", "-N" + native, "-RTS"]
                        with TuiSession(runner, client_state, command=command, explicit_state=False) as session:
                            session.wait_screen("Manager profiles")
                            session.wait_screen("profile_1")
                            session.send(b"\r")
                            screen = session.wait_screen("Manager workflows")
                            (work / "tui-catalogue.screen.txt").write_text(screen)
                            session.wait_screen(catalogue["items"][0]["name"])
                            session.send(b"slmfci1\t")
                            session.wait_screen("Manager workflows")
                            session.send(b"h")
                            session.wait_screen(catalogue["items"][0]["help"].splitlines()[0][:30])
                            session.send(b"\x1b")
                            session.wait_screen("Manager workflows")
                            if tui_approval:
                                index = next(i for i, item in enumerate(catalogue["items"]) if item["name"] == "mixed-controls")
                                session.send(b"\x1b[B" * index + b"\r")
                                session.wait_screen("request validator current")
                                literal = "Café λ — explicit false.\nSecond line."
                                session.send(b"\x1b[200~" + literal.encode() + b"\x1b[201~")
                                session.send(b"\x04")
                                session.wait_screen("Enter REQUEST REVIEW")
                                session.send(b"\r")
                                deadline = time.monotonic() + 45
                                resent = False
                                while time.monotonic() < deadline:
                                    session.pump()
                                    visible = session.screen.text()
                                    if "Approve exact manager review" in visible:
                                        break
                                    if "x EXACT RESEND" in visible and not resent:
                                        session.send(b"x")
                                        session.wait_screen("Resend the retained enqueue attempt?")
                                        session.send(b"y")
                                        resent = True
                                else:
                                    (work / "tui-waiting.screen.txt").write_text(session.screen.text())
                                    raise AssertionError("TUI preparation deadline after at most one operator-confirmed exact resend")
                                status, snapshot, _ = request("/v1/snapshot", authorized)
                                assert status == 200
                                validate("OverviewSnapshot", snapshot)
                                drafts = [item["request"] for item in snapshot["items"] if item["kind"] == "request"]
                                assert len(drafts) == 1
                                submitted = drafts[0]
                                assert submitted["readiness"]["supplied"] == [{"name": "input", "source": "literal", "value": literal}]
                                status, preparation, _ = request("/v1/preparations/" + submitted["preparationId"], authorized)
                                assert status == 200
                                validate("Preparation", preparation)
                                session.send(b"\r")
                                status, not_started, _ = request(submitted["links"]["self"], authorized)
                                assert status == 200 and not_started["runId"] is None, "Enter approved without exact consent"
                                session.send(b"d")
                                session.wait_screen("Exact manager review")
                                session.send(b"y")
                                status, not_started, _ = request(submitted["links"]["self"], authorized)
                                assert status == 200 and not_started["runId"] is None, "detail-view key approved a review"
                                session.send(b"d")
                                for _ in range(3):
                                    visible = session.wait_screen("y APPROVE EXACT REVIEW")
                                    compact = "".join(char for char in visible if not char.isspace() and not "\u2500" <= char <= "\u257f")
                                    for selector in ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration"):
                                        assert selector + preparation[selector] in compact, ("clipped selector", selector)
                                    (work / "tui-approval.screen.txt").write_text(visible)
                                    session.send(b"y")
                                    session.settle()
                                    status, associated, raw = request(submitted["links"]["self"], authorized)
                                    assert status == 200
                                    if associated["runId"] is not None:
                                        break
                                else:
                                    raise AssertionError("explicit TUI approval did not associate a run")
                                validate("Request", associated)
                                (work / "tui-associated-request.json").write_bytes(raw)
                                (work / "tui-associated.screen.txt").write_text(session.wait_screen("Phase: associated"))
                                assert process.poll() is None, "manager exited during frontend approval"
                            session.send(b"q")
                            assert session.wait_exit() == 0, "service TUI did not exit successfully"
                            session.assert_restored()
                        with TuiSession(runner, client_state, command=command, explicit_state=False) as session:
                            session.wait_screen("Manager profiles")
                            session.process.terminate()
                            session.wait_exit()
                            session.assert_restored()
                        assert not client_state.exists(), "service TUI created local runner state"
                        if tui_approval:
                            status, control, raw = request("/v1/runs/" + associated["runId"] + "/control", authorized)
                            assert status == 200
                            validate("RunControl", control)
                            assert control["supervision"] == "owned" and control["cancelAllowed"], "frontend detach stopped the original manager run"
                            (work / "tui-detached-control.json").write_bytes(raw)
                            print("PASS actual TUI Unicode submission, full five-selector display, explicit approval and detach preserving the original owned run", flush=True)
                            break
                        print("PASS actual service TUI catalogue/help, local-action refusal, original quit/signal joins and terminal restoration (read-only)", flush=True)
                status, before, raw = request("/v1/snapshot", authorized)
                assert status == 200 and before["items"] == []
                validate("OverviewSnapshot", before)
                (work / "overview-before.json").write_bytes(raw)
                create = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                          "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
                key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
                status, created, raw = request("/v1/requests", authorized | {
                    "Content-Type": "application/json", "Idempotency-Key": key},
                    method="POST", payload=json.dumps(create, separators=(",", ":")).encode())
                assert status == 201
                validate("Request", created)
                (work / "created-request.json").write_bytes(raw)
                status, overview, raw = request("/v1/snapshot", authorized)
                assert status == 200
                validate("OverviewSnapshot", overview)
                assert overview["items"] == [{"kind": "request", "request": created}]
                assert overview["cursor"] != before["cursor"] and overview["page"]["next"] is None
                (work / "overview-after.json").write_bytes(raw)
                if mixed:
                    run_mixed(created, workflow, capabilities, authorized)
                cursor = before["cursor"]
                status, batch, raw = request("/v1/events?after=" + cursor, authorized | {"Accept": "application/json"})
                assert status == 200 and batch["events"]
                validate("EventBatch", batch)
                (work / "events.json").write_bytes(raw)
                streams = []
                try:
                    for index in range(2):
                        deadline = time.monotonic() + 5
                        while True:
                            connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
                            connection.request("GET", "/v1/events?after=" + cursor,
                                               headers=authorized | {"Accept": "text/event-stream"})
                            response = connection.getresponse()
                            if response.status == 200:
                                streams.append((connection, response))
                                break
                            raw = response.read(1048577)
                            status = response.status
                            response.close()
                            connection.close()
                            refused = frozen.parse_json(raw)
                            validate("Problem", refused)
                            assert status in (429, 503) and time.monotonic() < deadline, ("reader admission", status, refused["code"])
                            # A refused read registration owns no subscription.
                            # This is not a mutation replay or a cleanup inference.
                            time.sleep(0.05)
                        assert response.getheader("Content-Type") == "text/event-stream"
                        assert response.getheader("Cache-Control") == "no-store"
                        block = bytearray()
                        while not block.endswith(b"\n\n"):
                            line = response.readline(16385)
                            assert line and len(block) + len(line) <= 16384
                            block.extend(line)
                        assert frozen.parse_sse(bytes(block)) == batch["events"][:1]
                        (work / f"stream-{index}.sse").write_bytes(block)
                    deadline = time.monotonic() + 5
                    while True:
                        status, problem, _ = request("/v1/events?after=" + cursor, authorized | {"Accept": "text/event-stream"})
                        if status != 503:
                            break
                        assert time.monotonic() < deadline, "third reader authentication admission"
                        time.sleep(0.05)
                    assert status == 429 and problem["code"] == "storage-quota"
                    administration({"version": 1, "operation": "revoke-credential",
                                    "credentialId": issued["result"]["credential"]["credentialId"]})
                    for _, response in streams:
                        try:
                            tail = response.read(1048577)
                        except http.client.IncompleteRead as failure:
                            tail = failure.partial
                        assert len(tail) <= 1048576, "bounded stream termination after revocation"
                finally:
                    for connection, response in streams:
                        if response is not None:
                            response.close()
                        connection.close()
            status, _, _ = request("/v1/profiles", authorized)
            assert status == 401, "live revocation must survive restart"
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / f"server-{iteration}.exit").write_text(str(process.returncode) + "\n")
    assert not (work / "admin/admin.sock").exists(), "joined original local administration leaves no socket"
    for channel in ("stdout", "stderr"):
        assert bearer.encode() not in (work / f"server-{iteration}.{channel}").read_bytes()
if tui_approval:
    assert not (work / "admin/admin.sock").exists(), "joined original local administration leaves no socket"
    for channel in ("stdout", "stderr"):
        assert bearer.encode() not in (work / f"server-0.{channel}").read_bytes()
    print("PASS original protected manager shutdown after TUI approval fixture")
else:
    print("PASS actual TLS1.3 foreground capabilities/profiles, matching polling/SSE, reader quota, live stream revocation, original joins and same-root restart")
