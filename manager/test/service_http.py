#!/usr/bin/env python3
"""Exercise the foreground HTTPS boundary with private local credentials and TLS."""
from pathlib import Path
import contextlib
import hashlib
import http.client
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import time

source, work, runner = map(Path, sys.argv[1:4])
native = sys.argv[4]
tui_approval = len(sys.argv) == 6 and sys.argv[5] in ("tui-approval", "tui-consent-control", "tui-journey")
# The journey continues the approval steps through the live monitor and the
# decision heads that the manager presents. It answers the question head with
# typed false and retries the recovery head, in the order that the manager
# presents them. It then waits for terminal success and the verified result on
# the screen, and detaches.
journey = len(sys.argv) == 6 and sys.argv[5] == "tui-journey"
# The consent control presses y in the summary, where the approval really
# starts, at the step that expects the detail-view refusal. It must fail with
# the detail-view consent message. It shows only that this assertion detects
# an approval. It does not break an approval guard.
consent_control = len(sys.argv) == 6 and sys.argv[5] == "tui-consent-control"
mixed = len(sys.argv) == 6 and sys.argv[5] in ("mixed", "mixed-confirm", "tui-approval", "tui-consent-control", "tui-journey")
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


# True while a TUI session is open. During the session every mutation belongs
# to the TUI, and the harness only reads.
posts_forbidden = False


@contextlib.contextmanager
def harness_reads_only():
    """Forbid harness POSTs until the TUI session inside this block has ended."""
    global posts_forbidden
    posts_forbidden = True
    try:
        yield
    finally:
        posts_forbidden = False


def exchange(path, headers=None, method="GET", payload=None):
    assert not (posts_forbidden and method == "POST"), "harness POST during a TUI session"
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
    return fetch(path, headers, method, payload)[:3]


def fetch(path, headers=None, method="GET", payload=None):
    deadline = time.monotonic() + 5
    while True:
        status, value, raw, received = exchange(path, headers, method, payload)
        if method != "GET" or status != 503 or time.monotonic() >= deadline:
            return status, value, raw, received
        assert value["code"] == "storage-unavailable"
        # Fresh read observations may contend with original coordinator work.
        # No POST enters this loop.
        time.sleep(0.05)


# The TUI answers every Enter or y on the exact review with one notice line,
# "Approval key N: <fixed text>", where N counts the approval-key presses of
# the session. Only the handling of that press renders its number, so the
# first appearance of a number above every earlier one is the boundary at
# which the TUI has finished processing the press. The not-sent notice keeps
# the number of the approving press, so it never counts as a new press.
#
# The notices are read from the PTY output written after the key, not from
# the final screen. An approval-start notice lasts only until the TUI observes
# the association, and several frames can arrive in one read. Vty rewrites a
# changed row as a whole and the notice text is one span, so a complete row
# ends at the next escape sequence or at the dialog border.
NOTICE = re.compile(r"Approval key (\d+): ([^\x1b\u2502\r\n]*)(?=[\x1b\u2502\r\n])")
ENTER_REFUSED = "Enter does not approve; y approves the exact review"
DETAIL_REFUSED = "y does not approve in the detail view"
APPROVAL_STARTED = "Approval started for the exact displayed review."
NOT_SENT = "Approval was not sent: the preflight check refused it before any send."
# These refusals report a transient lane or observation state that a later
# observation clears, so the positive approval may press y again after one.
APPROVAL_DEFERRED = ("Approval did not start: a manager command is in progress or unresolved.",
                     "Approval did not start: the displayed review is stale.")
OUTPUT_LIMIT = 16 * 1024 * 1024
# The live monitor shows the published runtime status on its own line. Each
# label names exactly one published status. The rank orders the statuses along
# the run lifecycle, so a later observation may only move forward from a
# non-terminal status.
RUNTIME_LINE = re.compile(r"Runtime: (Starting|Running|Cancelling|Succeeded|Failed|Cancelled|Owner unavailable)(?![A-Za-z])")
LABEL_STATUS = {"Starting": "starting", "Running": "running", "Cancelling": "cancelling", "Succeeded": "succeeded",
                "Failed": "failed", "Cancelled": "cancelled", "Owner unavailable": "orphaned"}
STATUS_RANK = {"starting": 0, "running": 1, "cancelling": 2, "succeeded": 3, "failed": 3, "cancelled": 3, "orphaned": 3}
# Rows that only the request screen shows. A live-monitor frame contains none.
REQUEST_SCREEN_ROWS = ("Manager request", "Admission:", "Position:", "Blocking reasons:", "Retained operator literals:")


def agrees(shown, published):
    """Whether a displayed runtime label agrees with a later published status."""
    displayed = LABEL_STATUS[shown]
    return published == displayed or STATUS_RANK[displayed] < min(3, STATUS_RANK[published])


def notice_is(line, number, text):
    """Whether the first displayed row of a notice starts the given notice.

    The TUI wraps a long notice at 80 columns. Every first row is long enough
    to tell the fixed texts apart, and no fixed text is a prefix of another.
    """
    full = f"Approval key {number}: {text}"
    return full.startswith(line) and len(line) >= min(len(full), len(f"Approval key {number}: ") + 30)


def notices(session, start):
    """The notice rows in the PTY output after the byte offset start, in order."""
    # TuiSession keeps the whole output until it reaches this limit.
    assert len(session.output) < OUTPUT_LIMIT, "PTY output reached the retention limit"
    text = bytes(session.output[start:]).decode("utf-8", "replace")
    return [(int(match.group(1)), ("Approval key " + match.group(1) + ": " + match.group(2)).rstrip())
            for match in NOTICE.finditer(text)]


def key_notice(session, key, after, failure):
    """Send one approval key and return the byte offset before it, and the
    number and first row of its notice.

    The wait ends at the first notice numbered above after in the output
    written after the key, or fails with the given message at the deadline.
    No fixed delay takes part.
    """
    start = len(session.output)
    session.send(key)
    deadline = time.monotonic() + 15
    while True:
        newer = [item for item in notices(session, start) if item[0] > after]
        if newer:
            return start, newer[0]
        if time.monotonic() >= deadline or session.process.poll() is not None:
            break
        session.pump()
    (work / "tui-missing-notice.screen.txt").write_text(session.screen.text())
    print("KEY OUTCOME: no approval-key notice above", after, "before the deadline", flush=True)
    raise AssertionError(failure)


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
            # A 503 here means that a Store action waited out its whole allowance.
            # Each retry is a new read observation, never a repeated mutation or
            # an inferred successful effect.
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
                        with harness_reads_only(), TuiSession(runner, client_state, command=command, explicit_state=False) as session:
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
                                preparation_uri = "/v1/preparations/" + submitted["preparationId"]
                                status, preparation, _, received = fetch(preparation_uri, authorized)
                                assert status == 200
                                validate("Preparation", preparation)
                                preparation_tag = received.get("etag")
                                assert preparation_tag is not None and preparation["state"] == "live"
                                if journey:
                                    # The exact review hashes the native input bytes: the
                                    # logical literal plus the declared LF of prompt transport.
                                    journey_workflow = catalogue["items"][index]
                                    declared = {item["name"]: item["source"] for item in journey_workflow["inputs"]}
                                    assert [item["name"] for item in preparation["review"]["inputs"]] == list(declared)
                                    for item in preparation["review"]["inputs"]:
                                        expected = literal.encode() + (b"\n" if declared[item["name"]] == "prompt" else b"")
                                        assert item["source"] == "literal" and item["bytes"] == str(len(expected)), "review input byte count"
                                        assert item["sha256"] == hashlib.sha256(expected).hexdigest(), "review input digest"
                                    print("PASS actual TUI request carries the exact Unicode literal and the native prompt bytes", flush=True)
                                last_key = 0

                                def refused(key, text, failure, name):
                                    """Press a forbidden key and require its refusal and an unapproved manager state.

                                    The harness reads the manager only after the notice of this press
                                    shows that the TUI finished handling it. Any other notice, or none
                                    before the deadline, fails with the consent message.
                                    """
                                    global last_key
                                    _, (number, line) = key_notice(session, key, last_key, failure)
                                    (work / ("tui-" + name + ".screen.txt")).write_text(session.screen.text())
                                    print("KEY OUTCOME:", line, flush=True)
                                    assert notice_is(line, number, text), failure
                                    last_key = number
                                    status, current, raw = request(submitted["links"]["self"], authorized)
                                    assert status == 200, failure
                                    validate("Request", current, raw)
                                    assert current["runId"] is None and current["phase"] == "review", failure
                                    assert current["preparationId"] == preparation["id"], failure
                                    status, still, raw, received = fetch(preparation_uri, authorized)
                                    assert status == 200, failure
                                    validate("Preparation", still, raw)
                                    assert still["state"] == "live" and still["revision"] == preparation["revision"], failure
                                    assert received.get("etag") == preparation_tag, failure
                                    print("PASS actual TUI", name, "refusal left the request in review and the preparation live and unchanged", flush=True)

                                refused(b"\r", ENTER_REFUSED, "Enter approved without exact consent", "summary-enter")
                                if consent_control:
                                    session.wait_screen("y APPROVE EXACT REVIEW")
                                else:
                                    session.send(b"d")
                                    session.wait_screen("Exact manager review")
                                refused(b"y", DETAIL_REFUSED, "detail-view key approved a review", "detail-y")
                                session.send(b"d")
                                for _ in range(5):
                                    visible = session.wait_screen("y APPROVE EXACT REVIEW")
                                    compact = "".join(char for char in visible if not char.isspace() and not "\u2500" <= char <= "\u257f")
                                    for selector in ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration"):
                                        assert selector + preparation[selector] in compact, ("clipped selector", selector)
                                    (work / "tui-approval.screen.txt").write_text(visible)
                                    approval_start, (last_key, line) = key_notice(session, b"y", last_key, "explicit TUI approval showed no notice")
                                    print("KEY OUTCOME:", line, flush=True)
                                    if notice_is(line, last_key, APPROVAL_STARTED):
                                        break
                                    # Only a visible deferral permits another y. A visible start never does.
                                    assert any(notice_is(line, last_key, text) for text in APPROVAL_DEFERRED), ("explicit TUI approval refused", line)
                                else:
                                    raise AssertionError("explicit TUI approval deferred five times")
                                deadline = time.monotonic() + 45
                                while "Phase: associated" not in session.screen.text():
                                    assert not any(number == last_key and notice_is(row, number, NOT_SENT)
                                                   for number, row in notices(session, approval_start)), "explicit TUI approval was not sent"
                                    assert time.monotonic() < deadline and session.process.poll() is None, "explicit TUI approval did not associate a run"
                                    session.pump()
                                (work / "tui-associated.screen.txt").write_text(session.wait_screen("Phase: associated"))
                                status, associated, raw = request(submitted["links"]["self"], authorized)
                                assert status == 200 and associated["runId"] is not None, "explicit TUI approval did not associate a run"
                                validate("Request", associated)
                                (work / "tui-associated-request.json").write_bytes(raw)
                                assert process.poll() is None, "manager exited during frontend approval"
                                if journey:
                                    run = associated["runId"]
                                    base = "/v1/runs/" + run

                                    def frame_kind(visible):
                                        """The kind of one whole service frame of the run, or None.

                                        Every kind needs the header, the service lines with the runtime, and no
                                        row left from the request screen. The live monitor adds both panes and
                                        its footer. A question head adds the answer dialog, and a recovery head
                                        adds the read-only recovery dialog.
                                        """
                                        if (RUNTIME_LINE.search(visible) is None or "elapsed unknown" not in visible or "Run: " + run not in visible
                                                or any(row in visible for row in REQUEST_SCREEN_ROWS) or "RUN DETAILS" in visible):
                                            return None
                                        if "Requests" in visible and "Output · " in visible and "q DETACH" in visible and "d DETAILS" in visible:
                                            return "live"
                                        if "Your answer" in visible and ("Ctrl-D SEND ANSWER" in visible or "WAITING FOR THE MANAGER EFFECT" in visible):
                                            return "question"
                                        if "Recovery required" in visible and (("r RETRY" in visible and "READ-ONLY RECOVERY" not in visible)
                                                                               or ("READ-ONLY RECOVERY" in visible and "Choices (read-only here): " in visible)):
                                            return "recovery"
                                        return None

                                    def wait_frame(kinds, timeout, failure, name):
                                        """Wait with an explicit deadline for a settled whole frame of one of the kinds."""
                                        deadline = time.monotonic() + timeout
                                        while True:
                                            session.pump()
                                            visible = session.screen.text()
                                            if frame_kind(visible) in kinds:
                                                session.settle()
                                                visible = session.screen.text()
                                                if frame_kind(visible) in kinds:
                                                    return frame_kind(visible), visible
                                            if time.monotonic() >= deadline or session.process.poll() is not None:
                                                (work / ("tui-" + name + "-missing.screen.txt")).write_text(visible)
                                                raise AssertionError(failure)

                                    # The numbered outcome of a key that started nothing, on the status line.
                                    KEY_LINE = re.compile(r"Key (\d+): (.*)")
                                    # Texts that the TUI shows once an answer attempt has started.
                                    ANSWER_STARTED = ("preparing explicit answer", "sending one answer attempt", "manager intent accepted",
                                                      "WAITING FOR THE MANAGER EFFECT", "Outcome unresolved")

                                    def key_outcome(visible):
                                        """The highest key outcome number on the screen and its text, or (0, "")."""
                                        found = [(int(match.group(1)), match.group(2).strip()) for match in KEY_LINE.finditer(visible)]
                                        return max(found) if found else (0, "")

                                    def run_read(path, schema):
                                        status, value, raw, headers = fetch(path, authorized)
                                        assert status == 200, (path, status, value.get("code"))
                                        validate(schema, value, raw)
                                        return value, headers.get("etag")

                                    # Segment 1: live runtime progress. The manager may present a decision head
                                    # from the first frame, so a question or recovery frame with the service
                                    # lines also shows the progress.
                                    kind, visible = wait_frame(("live", "question", "recovery"), 45,
                                                               "live monitor showed no whole frame with runtime progress from the snapshot", "live")
                                    live_offset = len(session.output)
                                    (work / "tui-live.screen.txt").write_text(visible)
                                    rows = visible.splitlines()
                                    runtime_rows = [row for row in rows if RUNTIME_LINE.search(row)]
                                    receipt_rows = [row for row in rows if "Approval receipt: " in row]
                                    # The runtime and the approval receipt are distinct rows of one frame.
                                    assert len(runtime_rows) == 1 and len(receipt_rows) == 1, ("runtime or receipt row count", runtime_rows, receipt_rows)
                                    assert "Approval receipt" not in runtime_rows[0] and RUNTIME_LINE.search(receipt_rows[0]) is None, (
                                        "approval receipt state shown as runtime progress", runtime_rows, receipt_rows)
                                    # Each tick starts one run read, and the status line names that read.
                                    session.wait_for(b"reading manager request and run", after=live_offset, timeout=10)
                                    assert len(session.output) < OUTPUT_LIMIT and b"loading manager catalogue" not in bytes(session.output[live_offset:]), (
                                        "run refresh shown as a catalogue load")
                                    shown = RUNTIME_LINE.search(runtime_rows[0]).group(1)
                                    receipt = receipt_rows[0].split("Approval receipt: ", 1)[1].strip()
                                    status, observed_run, raw, _ = fetch(base + "/snapshot", authorized)
                                    assert status == 200, ("snapshot read", status)
                                    validate("RunSnapshot", observed_run, raw)
                                    (work / "tui-live-snapshot.json").write_bytes(raw)
                                    assert observed_run["runId"] == run and observed_run["runtime"] is not None, "displayed runtime absent from the snapshot"
                                    assert agrees(shown, observed_run["runtime"]["status"]), (
                                        "displayed runtime disagrees with the snapshot", shown, observed_run["runtime"]["status"])
                                    assert observed_run["workflow"] is None or observed_run["workflow"] in visible
                                    assert observed_run["targetLabel"] is None or " target " + observed_run["targetLabel"] in visible
                                    print("PASS actual TUI shows runtime", shown, "from the snapshot in a whole", kind, "frame; the snapshot GET shows",
                                          observed_run["runtime"]["status"], "and the approval receipt row stays", repr(receipt), flush=True)

                                    # Segment 2: the decision heads. The manager presents the question and the
                                    # recovery in an order that is not fixed. Each appears exactly once. At the
                                    # question head the TUI types false and presses Ctrl-D. At the recovery head
                                    # the TUI presses r. The harness only reads. It never POSTs a journey step.
                                    RETRY_STARTED = ("preparing explicit retry", "sending one retry attempt", "manager intent accepted", "Outcome unresolved")

                                    def press(key, operation, started_markers, left_kinds, name):
                                        """Press an explicit mutation key until the TUI starts the mutation.

                                        Every press has one visible outcome: a start, or a numbered key outcome on
                                        the status line. A deferral during a page-set read, a stale observation,
                                        or a command that is still in progress permits another explicit press,
                                        as an operator would press again. Any other refusal fails.
                                        """
                                        last_outcome = key_outcome(session.screen.text())[0]
                                        for _ in range(10):
                                            session.send(key)
                                            started, refusal = None, ""
                                            press_deadline = time.monotonic() + 15
                                            while started is None and time.monotonic() < press_deadline and session.process.poll() is None:
                                                session.pump()
                                                visible = session.screen.text()
                                                number, refusal = key_outcome(visible)
                                                if number > last_outcome:
                                                    last_outcome, started = number, False
                                                elif any(marker in visible for marker in started_markers) or frame_kind(visible) in left_kinds:
                                                    started = True
                                            if started:
                                                return
                                            (work / ("tui-" + name + "-refused.screen.txt")).write_text(session.screen.text())
                                            assert started is False, operation + " key showed no outcome before the deadline"
                                            print("KEY OUTCOME:", refusal, flush=True)
                                            assert refusal.startswith((operation + " deferred", operation + " did not start: the decision observation",
                                                                       operation + " did not start: the control observation",
                                                                       operation + " did not start: a command is in progress")), ("TUI did not start the " + operation, refusal)
                                            # Refresh pauses while a deferral is shown, so the read in flight
                                            # ends before the next explicit press. After a stale refusal the
                                            # next current read installs first.
                                            session.pump(1.5)
                                        raise AssertionError("TUI " + operation + " did not start after ten presses")

                                    def await_resolution(head, operation, deadline):
                                        """Wait until the decision leaves the pending and submitting states.

                                        A declared refusal of the send leaves the original attempt unresolved,
                                        and the TUI offers only an exact resend. The harness confirms at most one,
                                        as an operator would. A resolved decision may leave the observable queue,
                                        so a read-only GET answers either its resolved state or
                                        unavailable-resource.
                                        """
                                        resent = False
                                        prompt = "Resend the retained " + operation + " attempt?"
                                        while True:
                                            status, current, raw, _ = fetch("/v1/decisions/" + head, authorized)
                                            if status == 404:
                                                assert current["code"] == "unavailable-resource", (operation + " decision read", current["code"])
                                                return "unavailable-resource"
                                            assert status == 200, (operation + " decision read", status, current.get("code"))
                                            validate("Decision", current, raw)
                                            if current["state"] == "resolved":
                                                return "resolved"
                                            assert current["state"] in ("pending", "submitting"), (operation + " decision state", current["state"])
                                            if "x EXACT RESEND" in session.screen.text() and prompt not in session.screen.text():
                                                (work / ("tui-" + operation + "-unresolved.screen.txt")).write_text(session.screen.text())
                                                assert not resent, "the TUI " + operation + " stayed unresolved after one operator-confirmed exact resend"
                                                print("OPERATOR CONFIRM exact retained " + operation + " attempt", flush=True)
                                                session.send(b"x")
                                                session.wait_screen(prompt)
                                                # The confirmation stays open while a page-set read defers the
                                                # y, and refresh pauses, so a later y finds no read in flight.
                                                for _ in range(10):
                                                    before_y = key_outcome(session.screen.text())[0]
                                                    session.send(b"y")
                                                    confirm_deadline = time.monotonic() + 15
                                                    while time.monotonic() < confirm_deadline and session.process.poll() is None:
                                                        session.pump()
                                                        visible = session.screen.text()
                                                        if prompt not in visible or key_outcome(visible)[0] > before_y:
                                                            break
                                                    visible = session.screen.text()
                                                    if prompt not in visible:
                                                        break
                                                    assert key_outcome(visible)[1].startswith("exact resend deferred"), ("exact resend refused", key_outcome(visible))
                                                    session.pump(1.5)
                                                else:
                                                    raise AssertionError("exact resend deferred ten times")
                                                resent = True
                                            assert time.monotonic() < deadline and session.process.poll() is None, "the " + operation + " decision stayed pending"
                                            session.pump(0.2)

                                    order = []
                                    deadline = time.monotonic() + 150
                                    while len(order) < 2:
                                        kind, visible = wait_frame(("question", "recovery"), max(1.0, deadline - time.monotonic()),
                                                                   "no decision head appeared in the TUI before the deadline", "head")
                                        control, _ = run_read(base + "/control", "RunControl")
                                        head = control["decisionHeadId"]
                                        assert head is not None and control["supervision"] == "owned", ("displayed head not named by owned controls", control)
                                        decision, _ = run_read("/v1/decisions/" + head, "Decision")
                                        assert decision["state"] == "pending" and decision["position"] == 0 and decision["kind"] == kind, (
                                            "displayed head disagrees with the manager head", kind, decision["kind"], decision["state"])
                                        assert kind not in order, ("a decision head kind appeared twice", order, kind)
                                        order.append(kind)
                                        (work / ("tui-head-" + kind + ".screen.txt")).write_text(visible)
                                        print("HEAD", len(order), kind, head, flush=True)
                                        occurrence = decision["address"]["occurrenceId"]
                                        if kind == "question":
                                            assert decision["question"]["code"] == "flag"
                                            assert (decision["question"]["prompt"].splitlines() or [""])[0][:30] in visible, "question prompt not displayed"
                                            before, _ = run_read(base + "/snapshot", "RunSnapshot")
                                            session.send(b"false")
                                            press(b"\x04", "answer", ANSWER_STARTED, ("live", "recovery"), "answer")
                                            answer_deadline = time.monotonic() + 45
                                            resolution = await_resolution(head, "answer", answer_deadline)
                                            while True:
                                                after, _ = run_read(base + "/snapshot", "RunSnapshot")
                                                item = next(value for value in after["items"] if value["occurrenceId"] == occurrence)
                                                acks = [ack for ack in after["controlAcks"] if ack["command"] == "answer" and ack["occurrenceId"] == occurrence
                                                        and ack not in before["controlAcks"]]
                                                if item["answer"] is not None and any(ack["state"] == "delivered" for ack in acks):
                                                    break
                                                assert time.monotonic() < answer_deadline, ("answered occurrence not completed", item["state"], acks)
                                                session.pump(0.2)
                                            (work / "tui-answered-snapshot.json").write_text(json.dumps(after, default=str))
                                            # The snapshot publishes a flag answer as its rendered text, "no" for
                                            # false and "yes" for true. Runtime decodes the typed value without
                                            # coercion, so this answer came from the JSON false that the TUI sent.
                                            assert item["code"] == "flag" and item["answer"] == "no", ("occurrence answer is not the rendered false", item["answer"])
                                            delivered = next(ack for ack in acks if ack["state"] == "delivered")
                                            answer_receipt, _ = run_read("/v1/commands/" + delivered["commandId"], "CommandReceipt")
                                            assert answer_receipt["operation"] == "answer" and answer_receipt["resource"] == "/v1/decisions/" + head, "answer receipt binding"
                                            assert answer_receipt["state"] == "effect-observed" and answer_receipt["effect"]["kind"] == "answer-accepted", "answer effect"
                                            assert answer_receipt["effect"]["address"] == {"occurrenceId": occurrence}, "answer effect address"
                                            now, _ = run_read(base + "/control", "RunControl")
                                            assert now["decisionHeadId"] != head, "the answered decision is still the head"
                                            print("PASS actual TUI answered the question head with typed false: the decision is no longer pending (" + resolution + ")",
                                                  "and no longer the head, the control acknowledgement",
                                                  "has command answer, the receipt is effect-observed answer-accepted for the occurrence, and the occurrence publishes the rendered false answer no", flush=True)
                                            # The TUI leaves the answered question before the next head is read.
                                            wait_frame(("live", "recovery"), 45, "TUI kept the answered question head", "after-answer")
                                            continue
                                        # At the recovery head the TUI offers r for the manager retry offer. The
                                        # local cancel, save and route keys have no binding, and failover and
                                        # abandon are refused as unsupported. The TUI handles keys in order, so
                                        # the key help that ? opens marks the end of their handling.
                                        assert (decision["message"].splitlines() or [""])[0][:30] in visible, "recovery message not displayed"
                                        assert any(offer["operation"] == "retry" and offer["address"] == decision["address"]
                                                   and offer["generation"] == decision["generation"] for offer in control["offers"]), "the manager offers no retry"
                                        assert "r RETRY" in visible and "READ-ONLY RECOVERY" not in visible, "the TUI does not offer the manager retry"
                                        assert not any(text in visible for text in ("c CANCEL RUN", "PgUp/PgDn scroll", "Esc CANCEL RUN")), "local recovery keys offered"
                                        before, _ = run_read(base + "/snapshot", "RunSnapshot")
                                        session.send(b"cs1fa")
                                        session.send(b"?")
                                        session.wait_screen("Keyboard shortcuts")
                                        session.send(b"\x1b")
                                        wait_frame(("recovery",), 15, "Esc did not return to the recovery head", "recovery-return")
                                        still, _ = run_read(base + "/control", "RunControl")
                                        assert still["supervision"] == "owned" and still["cancelAllowed"] and still["decisionHeadId"] == head, "a local key changed the manager run control"
                                        pending, _ = run_read("/v1/decisions/" + head, "Decision")
                                        assert pending["state"] == "pending" and pending["revision"] == decision["revision"], "a local key changed the recovery decision"
                                        after_keys, _ = run_read(base + "/snapshot", "RunSnapshot")
                                        assert after_keys["runtime"]["status"] not in ("cancelling", "cancelled"), "a local key cancelled the manager run"
                                        assert after_keys["controlAcks"] == before["controlAcks"], "a local key sent a manager control"
                                        print("PASS actual TUI recovery head ignores the local c, s and 1 keys and refuses f and a: no control, decision or acknowledgement changed", flush=True)
                                        # The run details open over the recovery head. On a short terminal they
                                        # are longer than their viewport, so End hides their first row and Home
                                        # shows it again.
                                        session.send(b"d")
                                        (work / "tui-live-details.screen.txt").write_text(session.wait_screen("RUN DETAILS"))
                                        first_row = "run " + run
                                        session.resize(18, 140)
                                        short = session.wait_screen("RUN DETAILS")
                                        assert first_row in short and "Home/End" in "\n".join(session.screen.lines()[-2:]), (
                                            "short run details lost their first row or their Home/End hint", short)
                                        session.send(b"\x1b[F")
                                        end_deadline = time.monotonic() + 10
                                        while first_row in session.screen.text():
                                            if time.monotonic() >= end_deadline or session.process.poll() is not None:
                                                (work / "tui-details-end-missing.screen.txt").write_text(session.screen.text())
                                                raise AssertionError("End did not scroll the service run details")
                                            session.pump()
                                        session.settle()
                                        scrolled = session.screen.text()
                                        assert "RUN DETAILS" in scrolled and first_row not in scrolled, ("End did not keep the details at their end", scrolled)
                                        (work / "tui-details-end.screen.txt").write_text(scrolled)
                                        session.send(b"\x1b[H")
                                        (work / "tui-details-home.screen.txt").write_text(session.wait_screen(first_row, timeout=10))
                                        session.resize(36, 140)
                                        session.wait_screen("RUN DETAILS")
                                        session.send(b"\x1b")
                                        wait_frame(("recovery",), 15, "Esc did not close the run details over the recovery head", "details-close")
                                        print("PASS actual TUI service run details open over the recovery head, scroll to their end with End and back to their first row",
                                              "with Home on an 18-row terminal, and Esc returns to the recovery head", flush=True)
                                        before, _ = run_read(base + "/snapshot", "RunSnapshot")
                                        before_item = next(value for value in before["items"] if value["occurrenceId"] == occurrence)
                                        before_attempt = max((int(attempt["address"]["attemptId"]) for attempt in before_item["attempts"]), default=-1)
                                        press(b"r", "retry", RETRY_STARTED, ("live", "question"), "retry")
                                        retry_deadline = time.monotonic() + 45
                                        resolution = await_resolution(head, "retry", retry_deadline)
                                        while True:
                                            after, _ = run_read(base + "/snapshot", "RunSnapshot")
                                            item = next(value for value in after["items"] if value["occurrenceId"] == occurrence)
                                            chosen = (item["recovery"] or {}).get("chosen")
                                            acks = [ack for ack in after["controlAcks"] if ack["command"] == "retry" and ack["occurrenceId"] == occurrence
                                                    and ack not in before["controlAcks"]]
                                            latest = max((int(attempt["address"]["attemptId"]) for attempt in item["attempts"]), default=-1)
                                            if chosen is not None and any(ack["commandId"] == chosen["commandId"] for ack in acks) and latest > before_attempt:
                                                break
                                            assert time.monotonic() < retry_deadline, ("retried occurrence has no chosen retry, acknowledgement or later attempt", chosen, acks, latest)
                                            session.pump(0.2)
                                        (work / "tui-retried-snapshot.json").write_text(json.dumps(after, default=str))
                                        assert chosen["choice"] == "retry", ("recovery choice is not retry", chosen)
                                        while True:
                                            retry_receipt, _ = run_read("/v1/commands/" + chosen["commandId"], "CommandReceipt")
                                            if retry_receipt["state"] != "dispatch-attempted" and retry_receipt["state"] != "accepted":
                                                break
                                            assert time.monotonic() < retry_deadline, ("retry receipt stayed", retry_receipt["state"])
                                            session.pump(0.2)
                                        assert retry_receipt["operation"] == "retry" and retry_receipt["resource"] == base + "/control", "retry receipt binding"
                                        assert retry_receipt["state"] == "effect-observed" and retry_receipt["effect"]["kind"] == "retried", ("retry effect", retry_receipt["state"])
                                        assert retry_receipt["effect"]["address"]["occurrenceId"] == occurrence, "retry effect address"
                                        now, _ = run_read(base + "/control", "RunControl")
                                        assert now["decisionHeadId"] != head, "the retried recovery is still the head"
                                        print("PASS actual TUI retried the recovery head with r: the decision is no longer pending (" + resolution + "), the snapshot",
                                              "recovery.chosen.commandId", chosen["commandId"], "equals the control acknowledgement with command retry, attempt",
                                              latest, "follows attempt", before_attempt, "and the receipt is effect-observed retried for the occurrence", flush=True)
                                        wait_frame(("live", "question"), 45, "TUI kept the retried recovery head", "after-retry")
                                    (work / "head-order.txt").write_text(" ".join(order) + "\n")
                                    print("HEAD ORDER:", " then ".join(order), flush=True)

                                    # Segment 3: terminal success and the verified result. The harness waits with
                                    # an explicit deadline for the snapshot runtime status, then for the TUI to
                                    # show the terminal status and a verified result. The manager records the
                                    # verification of the result reference when the run outputs are read, so the
                                    # harness reads the outputs only after the TUI has shown its result. The size
                                    # and digest on the screen must equal the source-result artifact.
                                    terminal_deadline = time.monotonic() + 90
                                    while True:
                                        final, _ = run_read(base + "/snapshot", "RunSnapshot")
                                        status = final["runtime"]["status"] if final["runtime"] is not None else None
                                        assert status not in ("failed", "cancelled", "orphaned"), ("run did not succeed", status, final["failure"])
                                        if status == "succeeded":
                                            break
                                        assert time.monotonic() < terminal_deadline and session.process.poll() is None, ("terminal success deadline", status)
                                        session.pump(0.2)
                                    result_deadline = time.monotonic() + 45
                                    while not ("Terminal: succeeded" in session.screen.text() and "Result SHA-256: " in session.screen.text()):
                                        if time.monotonic() >= result_deadline or session.process.poll() is not None:
                                            (work / "tui-result-missing.screen.txt").write_text(session.screen.text())
                                            raise AssertionError("TUI did not show terminal success and a verified result")
                                        session.pump(0.2)
                                    session.settle()
                                    shown_result = session.screen.text()
                                    (work / "tui-result.screen.txt").write_text(shown_result)
                                    outputs, _ = run_read(base + "/outputs", "OutputPage")
                                    result = next(item for item in outputs["items"] if item["kind"] == "result")
                                    artifact = result["artifact"]
                                    assert result["verification"]["state"] == "verified" and artifact["kind"] == "source-result" and artifact["runId"] == run
                                    verified_run, _ = run_read(base + "/snapshot", "RunSnapshot")
                                    assert verified_run["verification"] == {"state": "verified", "artifactId": artifact["id"]}, ("snapshot verification", verified_run["verification"])
                                    expected = ("Terminal: succeeded", "Result: verified " + str(int(artifact["bytes"])) + " bytes", "Result SHA-256: " + artifact["sha256"])
                                    assert all(row in shown_result for row in expected), ("TUI result rows disagree with the source-result artifact", expected)
                                    print("PASS actual TUI shows terminal success from the snapshot and the verified result:", expected[1], "and", expected[2], flush=True)
                            session.send(b"q")
                            assert session.wait_exit() == 0, "service TUI did not exit successfully"
                            session.assert_restored()
                        with harness_reads_only(), TuiSession(runner, client_state, command=command, explicit_state=False) as session:
                            session.wait_screen("Manager profiles")
                            session.process.terminate()
                            session.wait_exit()
                            session.assert_restored()
                        assert not client_state.exists(), "service TUI created local runner state"
                        if tui_approval:
                            if journey:
                                # The run finished before the detach, so the detach leaves its
                                # terminal success unchanged.
                                status, final, raw = request("/v1/runs/" + associated["runId"] + "/snapshot", authorized)
                                assert status == 200 and final["runtime"]["status"] == "succeeded", "the run is not succeeded after the detach"
                                (work / "tui-detached-snapshot.json").write_bytes(raw)
                                print("PASS tui-journey: Unicode submission with exact request bytes, explicit approval, live runtime progress from the snapshot, "
                                      "the question and recovery heads each once in the recorded order with the typed false answer and the TUI retry, terminal "
                                      "success from the snapshot, the verified result size and digest on screen, q detach with terminal restoration and no local "
                                      "runner state", flush=True)
                                break
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
