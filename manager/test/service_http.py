#!/usr/bin/env python3
"""Exercise the foreground HTTPS boundary with private local credentials and TLS."""
from pathlib import Path
import contextlib
import hashlib
import http.client
import io
import json
import os
import re
import secrets
import socket
import ssl
import stat
import subprocess
import sys
import threading
import time

source, work, runner = map(Path, sys.argv[1:4])
native = sys.argv[4]
JOURNEYS = ("tui-journey", "tui-journey-broken-answer")
APPROVE_FAULT = "tui-flow-approve-fault"
tui_approval = len(sys.argv) == 6 and sys.argv[5] in ("tui-approval", "tui-consent-control", APPROVE_FAULT) + JOURNEYS
# The journey is the gate of the Phase A service journey in one uninterrupted
# TUI session. It continues the approval steps through the live monitor and
# the decision heads that the manager presents. It answers the question head
# with typed false and retries the recovery head, in the order that the
# manager presents them. It then waits for terminal success and the verified
# result on the screen, saves the verified bytes through the TUI, and
# detaches. Each verified fact has its own literal JOURNEY-ASSERT message.
# Deadline messages start with JOURNEY-DEADLINE, so they never match one.
#
# After the TUI session and the wait for the manager process, so that the
# manager log holds its shutdown notice, the journey reads the manager log and
# the run store of the journey with the flow verb of the TUI_CHECK binary. The
# verb must verify both logs and the consent of the start relay. Each fact of
# the manager log and the run log has its own literal FLOW-ASSERT message:
# the command senders, the enqueue command and its receipt, the review, the
# approve command with its selectors, the start relay, the person question,
# the answer command with JSON false, each relayed control and its
# acknowledgement, the retry command and its control, the terminal record,
# the joins of the run-log control and answer records to the commands of the
# principal, and no ask after the terminal record. The journey then prints
# the manager log size and the run-log storage ratio.
journey = len(sys.argv) == 6 and sys.argv[5] in JOURNEYS
# The approve-fault control follows the journey until the approval. Just
# before the TUI presses y, the harness renames the manager log away, so the
# identity check of the manager writer fails the append of the approve command.
# The manager must refuse the approval with storage-unavailable, and the TUI
# must show that refusal. The control checks that the request stays in review,
# that the ledger has no accepted approval, and that no manager log holds an
# approve command or a start relay and no run store exists. It then fails with
# the literal APPROVE_FAULT_REFUSED message. It adds no production hook.
approve_fault = len(sys.argv) == 6 and sys.argv[5] == APPROVE_FAULT
APPROVE_FAULT_REFUSED = "FLOW-FAULT the approve append failed and the manager refused the approval with storage-unavailable"
# The broken-answer control types true at the question. It must fail with the
# typed-answer message.
JOURNEY_ANSWER = b"true" if len(sys.argv) == 6 and sys.argv[5] == "tui-journey-broken-answer" else b"false"
# The consent control presses y in the summary, where the approval really
# starts, at the step that expects the detail-view refusal. It must fail with
# the detail-view consent message. It shows only that this assertion detects
# an approval. It does not break an approval guard.
consent_control = len(sys.argv) == 6 and sys.argv[5] == "tui-consent-control"
# The credential-lifecycle mode checks WM-023 section 7 through the running
# protected manager with the existing local administration operations only:
# rotation overlap and cutoff, a receipt replay across rotation, revocation
# during retained responses with the live run completed by a second
# credential, the scope boundary, and the absence of bearer and marker bytes
# from every fixture file. Each numbered step prints its own PASS line. It
# runs one manager lifetime and does not enter the restart loop.
LIFECYCLE = "credential-lifecycle"
lifecycle = len(sys.argv) == 6 and sys.argv[5] == LIFECYCLE
mixed = len(sys.argv) == 6 and sys.argv[5] in ("mixed", "mixed-confirm", "tui-approval", "tui-consent-control", APPROVE_FAULT, LIFECYCLE, "pages") + JOURNEYS
confirm_uncertain = mixed and sys.argv[5] == "mixed-confirm"
# The boundary mode checks WM-024 through the running protected manager with
# raw socket and ssl connections: plaintext and TLS 1.2 refusal, request
# framing, Host, path, header, body, CORS and slow-input refusals, and the
# connection limit. Each negative prints its own PASS line. It runs one
# manager lifetime and does not enter the restart loop.
BOUNDARY = "boundary"
boundary = len(sys.argv) == 6 and sys.argv[5] == BOUNDARY
# The pages mode checks the WM-025 page and read verification of report
# section 7 through the running protected manager: multi-page sets and their
# exact ETags, token binding and expiry, the per-client quota, a concurrent
# mutation, revocation, an interrupted send, the aggregate bound,
# redaction, concurrent artifact downloads of two credentials, and the
# legacy entry of a bound local retention root. Each numbered case prints its
# own PASS line. It runs one manager
# lifetime and does not enter the restart loop.
PAGES = "pages"
pages_mode = len(sys.argv) == 6 and sys.argv[5] == PAGES
# The events-lifecycle mode checks the WM-026 verification of /v1/events
# through the running protected manager: snapshot attachment of SSE and
# polling, cursor advancement of a credential of another profile over
# invisible records, reconnection after a partial SSE block, and the stream
# alias and cursor across an ordinary restart. Each numbered case prints its
# own PASS line. It runs two manager lifetimes of the scripted base fixture.
EVENTS = "events-lifecycle"
events_mode = len(sys.argv) == 6 and sys.argv[5] == EVENTS
assert len(sys.argv) == 5 or mixed or boundary or pages_mode or events_mode
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
# The base and mixed modes also read the frozen request, run and decision
# collections. A second profile, visible only to a second credential, holds
# a request that the collections of the first credential must not show.
collections = len(sys.argv) == 5 or sys.argv[5] in ("mixed", "mixed-confirm", PAGES, EVENTS)
if collections:
    configuration["profiles"].append(dict(configuration["profiles"][0], id="profile_2", workspaceLabel="HTTPS other fixture"))
# The pages mode raises the global page-set bound above the per-client bound,
# so that the per-client refusal is the one under test. The worker
# environment of its profile holds a marker that no page body may show.
PAGES_ENVIRONMENT_MARKER = "acatpagesenvironment" + secrets.token_hex(16)
if pages_mode:
    configuration["limits"]["globalPageSets"] = 8
# The pages mode also configures one local retention root. A local frontend
# run writes one completed run into it before the manager starts, and the
# manager serves it through --legacy-history as a read-only legacy entry.
LEGACY_ROOT = work / "legacy"
if pages_mode:
    LEGACY_ROOT.mkdir(mode=0o700)
    configuration["localRetentionRoots"] = [str(LEGACY_ROOT)]
if mixed:
    adapters = work / "adapters"
    adapters.mkdir(mode=0o700)
    launcher = adapters / "mixed-adapter"
    program = source / "engine/acp/test/retry_adapter.py"
    launcher.write_text(f"#!{sys.executable} -B\nimport os\nos.execv({sys.executable!r},[{sys.executable!r},'-B',{str(program)!r}])\n")
    launcher.chmod(0o700)
    configuration["profiles"][0].update(
        targetLabel="Deterministic ACP retry", targetArguments=["--engine", "acp", "--adapter", "mixed-adapter"],
        environment=[{"name": "PATH", "value": str(adapters)}]
        + ([{"name": "ACAT_PAGES_MARKER", "value": PAGES_ENVIRONMENT_MARKER}] if pages_mode else []))
config = work / "configuration.json"
config.write_text(json.dumps(configuration))
config.chmod(0o600)


def administration(payload, refused=None):
    """One local administration exchange. It must succeed, or, when refused
    names an error code, it must refuse with exactly that code."""
    completed = subprocess.run([str(runner), "--manager", "admin", "--config", str(config)],
                               input=json.dumps(payload).encode(), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=20)
    value = frozen.parse_json(completed.stdout)
    validate("LocalAdminResponse", value)
    if refused is not None:
        assert not completed.stderr and completed.returncode == 1 and not value["ok"] and value["error"]["code"] == refused, (
            "local administration did not refuse as expected", completed.returncode, value.get("error", {}).get("code"))
        return value
    assert not completed.stderr and completed.returncode == 0 and value["ok"], (
        "local administration refused", completed.returncode, value.get("error", {}).get("code"))
    return value


issued = administration({"version": 1, "operation": "issue-credential", "label": "HTTPS fixture",
                         "scopes": ["observe", "submit"] + (["control", "export"] if mixed else []), "profileIds": ["profile_1"],
                         "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential")})
bearer = (work / "credential").read_bytes().decode("ascii")
if collections:
    administration({"version": 1, "operation": "issue-credential", "label": "HTTPS other profile",
                    "scopes": ["observe", "submit"], "profileIds": ["profile_2"],
                    "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential-other")})
    other_authorized = {"Authorization": "Bearer " + (work / "credential-other").read_bytes().decode("ascii")}
configuration["administrationRoot"] = str(work / "admin")
config.write_text(json.dumps(configuration))
context = ssl.create_default_context(cafile=str(cert))
context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3


# True while a TUI session is open. During the session every mutation belongs
# to the TUI, and the harness only reads. The journey sets it for the whole
# run after fixture setup and credential issuance.
posts_forbidden = journey
if journey:
    print("JOURNEY POST GUARD active: any harness POST through exchange after fixture setup and credential issuance fails", flush=True)


@contextlib.contextmanager
def harness_reads_only():
    """Forbid harness POSTs until the TUI session inside this block has ended."""
    global posts_forbidden
    previous, posts_forbidden = posts_forbidden, True
    try:
        yield
    finally:
        posts_forbidden = previous


def exchange(path, headers=None, method="GET", payload=None):
    assert not (posts_forbidden and method == "POST"), "harness POST while the POST guard is active"
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
    # A JSON read may meet the declared page-set refusal while the TUI holds
    # the page-set capacity. A stream registration keeps its own 429 handling.
    page_set_read = (headers or {}).get("Accept") != "text/event-stream"
    while True:
        status, value, raw, received = exchange(path, headers, method, payload)
        if (method != "GET" or time.monotonic() >= deadline
                or not (status == 503 or (status == 429 and page_set_read and value["code"] == "storage-quota"))):
            return status, value, raw, received
        assert status == 429 or value["code"] == "storage-unavailable"
        # Fresh read observations may contend with original coordinator work
        # or with the page sets of the TUI. Each retry is a new bounded read.
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


def squeeze(text):
    """The text without white space and box drawing, so wrapped rows join."""
    return "".join(char for char in text if not char.isspace() and not "─" <= char <= "╿")


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


MIXED_TEXT = "Café λ — explicit false.\nSecond line."


def mixed_client(capabilities, authorized, attempts=None):
    """The read and mutation steps of the mixed workflow, bound to one
    credential. When attempts is a list, each mutation appends its operation,
    URI, exact headers, exact payload and receipt URI, so a later step can
    repeat the exact attempt."""

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
        if attempts is not None:
            attempts.append((body["operation"], path, headers, payload, receipt["links"]["self"]))
        if body["operation"] == "approve":
            # Runtime association is independent evidence. The approval receipt
            # remains dispatch-attempted and is not reclassified as delivered.
            return receipt["links"]["self"]
        value, _, _ = wait_for(receipt["links"]["self"], "CommandReceipt",
            lambda value: value["state"] in ("effect-observed", "refused", "unresolved"))
        assert value["state"] == "effect-observed", ("mutation not effected", body["operation"], value["state"])
        return receipt["links"]["self"]

    return observed, wait_for, mutate, authorized


def approve_mixed(created, workflow, client):
    """Supply the literal input, enqueue, check the exact review and approve
    it. Returns the approval receipt URI and the associated run."""
    observed, wait_for, mutate, _ = client
    text = MIXED_TEXT
    request_uri = created["links"]["self"]
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
    return approval, current["runId"]


def drive_mixed(run, client, stop_at_question=False, overview=True):
    """Act on each decision head of the run through one credential. The
    question receives typed false and the recovery receives retry. With
    stop_at_question, return the pending question head without answering it,
    so that the worker stays live. Otherwise return at terminal success.
    With overview, each head is also found in the overview snapshot, which
    must then fit one page. Returns the question head, or None, and the
    counts of answers and retries that this call sent."""
    observed, _, mutate, client_authorized = client
    base = "/v1/runs/" + run
    answered = recovered = 0
    deadline = time.monotonic() + 50
    while True:
        snapshot, _, raw = observed(base + "/snapshot", "RunSnapshot")
        assert snapshot["page"]["next"] is None
        runtime = snapshot["runtime"]
        if runtime is not None and runtime["status"] in ("succeeded", "failed", "cancelled"):
            assert runtime["status"] == "succeeded" and not stop_at_question, ("mixed workflow terminal status", runtime["status"])
            (work / "terminal-snapshot.json").write_bytes(raw)
            return None, answered, recovered
        assert time.monotonic() < deadline, "mixed workflow terminal deadline"
        control, control_tag, _ = observed(base + "/control", "RunControl")
        head = control["decisionHeadId"]
        if head is None:
            time.sleep(0.05)
            continue
        decision, decision_tag, _ = observed("/v1/decisions/" + head, "Decision")
        assert decision["position"] == 0 and decision["state"] == "pending" and decision["runId"] == run
        if collections:
            check_collections("head-" + decision["kind"], client_authorized, "profile_1", runs=[run], decisions=[head], queue=run)
            status, problem, _ = request("/v1/decisions?runId=" + run, other_authorized)
            assert status == 403 and problem["code"] == "insufficient-scope", ("other profile run queue", status, problem.get("code"))
            print("PASS decision collection lists the pending", decision["kind"], "head of the mixed run in both the head and the run queue views", flush=True)
        if overview:
            overview_value, _, raw = observed("/v1/snapshot", "OverviewSnapshot")
            assert any(item["kind"] == "run" and item["run"]["id"] == run for item in overview_value["items"])
            assert any(item["kind"] == "decision" and item["decision"]["id"] == head for item in overview_value["items"])
            (work / ("decision-" + decision["kind"] + ".json")).write_bytes(raw)
        body = {"occurrenceId": decision["address"]["occurrenceId"], "generation": decision["generation"]}
        if decision["kind"] == "question":
            assert decision["question"]["code"] == "flag"
            if stop_at_question:
                return head, answered, recovered
            body.update(operation="answer", value=False)
            mutate("/v1/decisions/" + head, body, decision_tag)
            answered += 1
        else:
            assert any(offer["operation"] == "retry" and offer["generation"] == decision["generation"]
                       and offer["address"] == decision["address"] for offer in control["offers"])
            body.update(operation="retry")
            mutate(base + "/control", body, control_tag)
            recovered += 1


def verified_download(run, client, authorized):
    """Read the verified result of a terminal run and download its exact bytes.
    Returns the artifact metadata."""
    observed = client[0]
    base = "/v1/runs/" + run
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
    return artifact


def run_mixed(created, workflow, capabilities, authorized):
    client = mixed_client(capabilities, authorized)
    observed, wait_for, _, _ = client
    request_uri = created["links"]["self"]
    approval, run = approve_mixed(created, workflow, client)
    _, answered, recovered = drive_mixed(run, client)
    assert answered and recovered, ("mixed workflow decisions", answered, recovered)
    verified_download(run, client, authorized)
    pending, _, raw = observed(approval, "CommandReceipt")
    assert pending["state"] == "dispatch-attempted" and pending["effect"] is None
    (work / "approval-still-pending.json").write_bytes(raw)
    released, _, raw = wait_for(request_uri, "Request",
        lambda value: value["runId"] == run and value["admission"]["state"] == "released")
    assert released["phase"] == "associated"
    (work / "released-request.json").write_bytes(raw)
    print("PASS actual HTTP mixed workflow: Unicode, exact approval, typed false, retry, terminal observation and verified bytes; approval delivery remains distinct", flush=True)
    return run


def other_profile_request():
    """Create one draft in the second profile with the second credential."""
    status, current, _ = request("/v1/capabilities", other_authorized)
    assert status == 200 and current["profileIds"] == ["profile_2"], ("other capabilities", status)
    status, catalogue, _ = request("/v1/workflows?profileId=profile_2", other_authorized)
    assert status == 200 and catalogue["items"], ("other catalogue", status)
    chosen = catalogue["items"][0]
    body = {"workflowId": chosen["id"], "descriptorRevision": chosen["revision"],
            "profileId": chosen["profileId"], "profileRevision": chosen["profileRevision"]}
    key = current["authorityEpoch"] + "." + secrets.token_urlsafe(16)
    status, value, raw = request("/v1/requests", other_authorized | {"Content-Type": "application/json", "Idempotency-Key": key},
                                 method="POST", payload=json.dumps(body, separators=(",", ":")).encode())
    assert status == 201, ("other request", status, value.get("code"))
    validate("Request", value, raw)
    assert value["profileId"] == "profile_2"
    return value


def private_markers():
    """Bytes that no collection body may contain: the fixture root, which holds
    the manager root, every run store and every root identity, the native run
    identifiers, and raw invocation fields."""
    markers = [str(work).encode(), json.dumps(str(work))[1:-1].encode(), b"mixed-adapter", b"--scripted",
               b"targetArguments", b"--engine"]
    stores = work / "manager" / "runs" / "runs"
    if stores.is_dir():
        markers += [entry.name.encode() for entry in stores.iterdir()]
    return markers


def check_collections(name, authorized, profile, requests=(), runs=(), decisions=(), queue=None, absent=()):
    """Read the request, run and decision collections, and the FIFO queue of
    the queue run when one is named. Each body must be one schema-valid page
    of the given profile, must contain the expected identifiers and none of
    the absent ones, and must contain no private marker. The queue must start
    with its expected head."""
    reads = [("requests", "/v1/requests", "RequestPage"), ("runs", "/v1/runs", "RunPage"),
             ("decisions", "/v1/decisions", "DecisionPage")]
    if queue is not None:
        reads.append(("queue", "/v1/decisions?runId=" + queue, "DecisionPage"))
    found = {}
    markers = private_markers()
    for label, path, schema in reads:
        status, value, raw, received = fetch(path, authorized)
        assert status == 200, ("collection read", path, status, value.get("code"))
        validate(schema, value, raw)
        assert value["page"]["next"] is None and value["page"]["totalItems"] == len(value["items"]), ("collection page", path)
        assert received.get("etag", "").startswith('"'), ("collection ETag", path)
        assert all(item["profileId"] == profile for item in value["items"]), ("collection profile", path)
        leaked = [marker for marker in markers if marker in raw]
        assert not leaked, ("collection body holds private bytes", path, leaked)
        (work / f"collection-{name}-{label}.json").write_bytes(raw)
        found[label] = [item["id"] for item in value["items"]]
    for label, expected in (("requests", requests), ("runs", runs), ("decisions", decisions)):
        assert set(expected) <= set(found[label]), ("collection member missing", label, expected, found[label])
    if queue is not None:
        assert found["queue"][:len(decisions)] == list(decisions), ("run queue head", found["queue"])
    hidden = [ident for values in found.values() for ident in values if ident in absent]
    assert not hidden, ("collection shows another profile", hidden)
    return found


def check_run_resources(run, authorized):
    """Read the export and lineage-request collections of the terminal mixed
    run, and an unknown export receipt. Each collection must be one
    schema-valid page of the run with no private marker. The run has no
    export and no child request. Its released reservation leaves every
    lineage operation eligible. The second credential is refused, and an
    unknown export is absent for both credentials."""
    markers = private_markers()
    found = {}
    for label, path, schema in (("exports", f"/v1/runs/{run}/exports", "ExportPage"),
                                ("lineage", f"/v1/runs/{run}/lineage-requests", "LineagePage")):
        status, value, raw, received = fetch(path, authorized)
        assert status == 200, ("run resource read", path, status, value.get("code"))
        validate(schema, value, raw)
        assert value["runId"] == run and value["items"] == [], ("run resource members", path)
        assert value["page"]["next"] is None and value["page"]["totalItems"] == 0, ("run resource page", path)
        assert received.get("etag", "").startswith('"'), ("run resource ETag", path)
        leaked = [marker for marker in markers if marker in raw]
        assert not leaked, ("run resource body holds private bytes", path, leaked)
        (work / f"run-{label}.json").write_bytes(raw)
        found[label] = value
        status, problem, _ = request(path, other_authorized)
        assert status == 403 and problem["code"] == "insufficient-scope", ("other profile run resource", path, status)
        status, problem, _ = request(path + "?runId=" + run, authorized)
        assert status == 400 and problem["code"] == "malformed-request", ("run resource query refusal", path, status)
    lineage = found["lineage"]
    assert lineage["eligible"] == ["restart", "resume", "fork"] and lineage["refusal"] is None, ("lineage eligibility", lineage["eligible"], lineage["refusal"])
    for credential in (authorized, other_authorized):
        status, problem, _ = request("/v1/exports/export_absent", credential)
        assert status == 404 and problem["code"] == "unavailable-resource", ("unknown export", status, problem.get("code"))


def command_receipts(cursor, authorized):
    """The resource and receipt of each command that a command.changed event
    after the cursor names, in event order, from read-only reads."""
    resources = []
    for _ in range(256):
        status, batch, raw, _ = fetch("/v1/events?after=" + cursor, authorized | {"Accept": "application/json"})
        assert status == 200, ("event read", status, batch.get("code"))
        validate("EventBatch", batch, raw)
        for event in batch["events"]:
            if event["event"] == "command.changed" and event["data"]["resource"] not in resources:
                resources.append(event["data"]["resource"])
        cursor = batch["cursor"]
        if not batch["hasMore"]:
            break
    else:
        raise AssertionError("JOURNEY-DEADLINE event pages")
    receipts = []
    for resource in resources:
        status, receipt, raw, _ = fetch(resource, authorized)
        assert status == 200, (resource, status, receipt.get("code"))
        validate("CommandReceipt", receipt, raw)
        receipts.append((resource, receipt))
    return receipts


def read_flow(name, paths):
    """Run the flow verb of the TUI_CHECK binary on the paths and return its
    exit status, its records and its summary. The output is kept in work."""
    completed = subprocess.run([os.environ["TUI_CHECK"], "flow"] + [str(path) for path in paths],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    (work / (name + ".ndjson")).write_bytes(completed.stdout)
    (work / (name + ".stderr")).write_bytes(completed.stderr)
    lines = [json.loads(line) for line in completed.stdout.splitlines()]
    assert lines and "summary" in lines[-1], ("the flow verb printed no summary", completed.returncode, completed.stderr[-2000:])
    return completed.returncode, lines[:-1], lines[-1]["summary"]


def journey_flow_assertions(credential, submitted, preparation, approve_command, answer_command, answer_resource,
                            retry_command, run, question_occurrence):
    """Read the journey manager log and run store with the flow verb, after the
    manager process has exited, and assert each fact of section 6.1 gate 1 of
    the actor-flow design with its own FLOW-ASSERT message."""
    flow_dir = work / "manager" / "flow"
    logs = sorted(flow_dir.glob("*.ndjson"))
    stores = sorted(work.glob("manager/runs/runs/*/runtime"))
    assert len(logs) == 1 and len(stores) == 1, ("FLOW-ASSERT the journey has other than one manager log and one run store", logs, stores)
    manager_path, store = str(logs[0]), stores[0]
    status, records, summary = read_flow("journey-flow", [flow_dir, store])
    assert status == 0 and summary["verified"] and not summary["problems"], (
        "FLOW-ASSERT the flow verb did not verify the journey logs", status, summary["problems"])
    manager = [record for record in records if record["log"] == manager_path]
    runlog = [record for record in records if record["log"] == str(store)]
    assert len(manager) + len(runlog) == len(records), "FLOW-ASSERT the flow verb printed a record of another log"
    at = lambda log, position: {"log": log, "position": position}
    run_log = next(item for item in summary["logs"] if item["kind"] == "run")
    report = run_log["report"]
    native = store.parent.name

    # The senders are the journey credential and client.
    principal = {"principal": "credential", "credentialId": credential["credentialId"], "client": credential["clientId"]}
    commands = [record for record in manager if record["schema"] == "command"]
    receipts = [record for record in manager if record["schema"] == "receipt"]
    assert commands and all(record["from"] == principal for record in commands), (
        "FLOW-ASSERT a manager-log command sender is not the journey credential and client", [record["from"] for record in commands])
    assert all(record["to"] == {"to": principal} for record in receipts), (
        "FLOW-ASSERT a manager-log receipt is not addressed to the journey credential and client")

    def command(operation, failure):
        found = [record for record in commands if record["body"]["operation"] == operation]
        assert len(found) == 1, (failure, operation, len(found))
        found = found[0]
        replies = [record for record in receipts if record["replyTo"] == found["position"]]
        assert len(replies) == 1, (failure, "receipt", len(replies))
        reply = replies[0]
        assert reply["body"]["operation"] == operation and reply["body"]["state"] != "refused", (failure, "receipt", reply["body"]["state"])
        assert reply["body"]["id"] == found["about"]["command"] == reply["about"]["command"], (failure, "receipt identity")
        return found, reply

    enqueue, enqueue_receipt = command("enqueue", "FLOW-ASSERT the manager log has no enqueue command with its receipt")
    assert enqueue["body"]["resource"] == submitted["links"]["self"] and enqueue["about"]["request"] == submitted["id"], (
        "FLOW-ASSERT the manager log has no enqueue command with its receipt", enqueue["body"]["resource"])
    print("FLOW enqueue command", enqueue["about"]["command"], "at position", enqueue["position"], "with its", enqueue_receipt["body"]["state"],
          "receipt at position", enqueue_receipt["position"], flush=True)

    reviews = [record for record in manager if record["schema"] == "review"]
    assert len(reviews) == 1, ("FLOW-ASSERT the manager log has other than one review", len(reviews))
    review = reviews[0]
    assert review["from"] == "manager" and review["to"] == {"approvers": configuration["profiles"][0]["id"]}, (
        "FLOW-ASSERT the review is not from the manager to the approvers of the profile", review["from"], review["to"])
    assert review["about"].get("request") == submitted["id"], ("FLOW-ASSERT the review names another request", review["about"])
    joined = [item for item in summary["joins"]["reviews"] if item["review"] == at(manager_path, review["position"])]
    assert len(joined) == 1 and joined[0]["preparation"] == preparation["id"], ("FLOW-ASSERT the review is not joined to the preparation", joined)
    print("FLOW review at position", review["position"], "for preparation", preparation["id"], flush=True)

    approve, approve_receipt = command("approve", "FLOW-ASSERT the manager log has no approve command with its receipt")
    selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")
    body = approve["body"]["body"]["json"]
    assert approve["about"]["command"] == approve_command and approve["body"]["resource"] == "/v1/preparations/" + preparation["id"], (
        "FLOW-ASSERT the approve command is not the journey approval", approve["about"], approve["body"]["resource"])
    assert all(body.get(selector) == preparation[selector] for selector in selectors), (
        "FLOW-ASSERT the approve command does not carry the five review selectors", body)
    assert joined[0]["commands"] == [approve["position"]], ("FLOW-ASSERT the review is not joined to the approve command", joined[0]["commands"])
    print("FLOW approve command", approve_command, "at position", approve["position"], "carries", ", ".join(selectors), flush=True)

    relays = [record for record in manager if record["schema"] == "relay"]
    starts = [record for record in relays if record["body"]["kind"] == "start"]
    assert len(starts) == 1 and starts[0]["about"]["command"] == approve_command and starts[0]["body"]["nativeRun"] == native, (
        "FLOW-ASSERT the manager log has no start relay of the approval", [record["about"] for record in starts])
    start = starts[0]
    delivered = [item["delivered"] for item in summary["joins"]["relays"] if item["relay"] == at(manager_path, start["position"])]
    first = next(record for record in runlog if record["position"] == 0)
    assert delivered == [at(str(store), 0)] and first["schema"] == "start" and first["from"] == "manager", (
        "FLOW-ASSERT the start relay is not joined to the run-log start", delivered, first["schema"])
    print("FLOW start relay at position", start["position"], "delivered as run-log start 0 of", native, flush=True)

    questions = [record for record in runlog if record["schema"] == "question" and record["to"] == {"to": "manager"}]
    assert len(questions) == 1 and str(questions[0]["about"]["occurrence"]) == str(question_occurrence), (
        "FLOW-ASSERT the run log has no person question of the answered occurrence", [record["about"] for record in questions])
    question = questions[0]
    assert question["body"]["code"] == "flag", ("FLOW-ASSERT the run log has no person question of the answered occurrence", question["body"]["code"])
    print("FLOW person question at run-log position", question["position"], "for occurrence", question_occurrence, flush=True)

    answer, _ = command("answer", "FLOW-ASSERT the manager log has no answer command carrying JSON false")
    value = answer["body"]["body"]["json"].get("value", None)
    assert answer["about"]["command"] == answer_command and answer["body"]["resource"] == answer_resource and value is False, (
        "FLOW-ASSERT the manager log has no answer command carrying JSON false", answer["about"], value)
    print("FLOW answer command", answer_command, "at position", answer["position"], "carries JSON false", flush=True)

    retry, _ = command("retry", "FLOW-ASSERT the manager log has no retry command with its receipt")
    assert retry["about"]["command"] == retry_command and retry["body"]["resource"] == "/v1/runs/" + run + "/control", (
        "FLOW-ASSERT the manager log has no retry command with its receipt", retry["about"], retry["body"]["resource"])

    # Each command reaches the run as one relayed control, received as a
    # run-log control from the manager, with its acknowledgement event.
    controls = {}
    for identity, failure in ((answer_command, "FLOW-ASSERT the answer control is not relayed and acknowledged"),
                              (retry_command, "FLOW-ASSERT the retry command has no relayed and acknowledged control")):
        relayed = [record for record in relays if record["body"]["kind"] == "control" and record["about"]["command"] == identity]
        assert len(relayed) == 1 and relayed[0]["body"]["nativeRun"] == native, (failure, "relay", len(relayed))
        delivered = [item["delivered"] for item in summary["joins"]["relays"] if item["relay"] == at(manager_path, relayed[0]["position"])]
        assert len(delivered) == 1 and delivered[0] is not None and delivered[0]["log"] == str(store), (failure, "delivery", delivered)
        control = next(record for record in runlog if record["position"] == delivered[0]["position"])
        assert control["schema"] == "control" and control["from"] == "manager" and control["about"]["command"] == identity, (
            failure, "run-log control", control["schema"], control["from"], control["about"])
        acknowledged = [item["acknowledgement"] for item in summary["joins"]["controls"] if item["control"] == at(str(store), control["position"])]
        assert len(acknowledged) == 1 and acknowledged[0] is not None, (failure, "acknowledgement", acknowledged)
        controls[identity] = control
        print("FLOW relay at position", relayed[0]["position"], "delivered as run-log control", control["position"],
              "from the manager with command", identity, "and acknowledgement event", acknowledged[0], flush=True)

    # The run-log control and answer records name the manager and the command,
    # and the reader joins them to the commands of the principal.
    run_controls = [record for record in runlog if record["schema"] == "control"]
    assert sorted(record["about"].get("command") for record in run_controls) == sorted([answer_command, retry_command]) and all(
        record["from"] == "manager" for record in run_controls), (
        "FLOW-ASSERT a run-log control does not name the manager and a journey command", [(record["from"], record["about"]) for record in run_controls])
    answers = [record for record in runlog if record["schema"] == "answer" and record["replyTo"] == question["position"]]
    assert len(answers) == 1 and answers[0]["from"] == "manager" and answers[0]["about"].get("command") == answer_command and answers[0]["body"] is False, (
        "FLOW-ASSERT the run-log answer does not name the manager and the answer command", [(record["from"], record["about"], record["body"]) for record in answers])
    joined_answers = [item for item in summary["joins"]["answers"] if item["answer"] == at(str(store), answers[0]["position"])]
    assert joined_answers == [{"answer": at(str(store), answers[0]["position"]), "command": at(manager_path, answer["position"]), "commandId": answer_command}], (
        "FLOW-ASSERT the run-log answer is not joined to the answer command of the principal", joined_answers)
    for identity, control in controls.items():
        relay = next(record for record in relays if record["body"]["kind"] == "control" and record["about"]["command"] == identity)
        issued_command = next(record for record in commands if record["about"]["command"] == identity)
        assert issued_command["from"] == principal and relay["about"]["command"] == control["about"]["command"], (
            "FLOW-ASSERT a run-log control is not joined to a command of the principal", identity)
    print("FLOW run-log answer at position", answers[0]["position"], "names the manager and", answer_command,
          "and joins to manager position", answer["position"], flush=True)

    # The terminal record, and no ask after it.
    stop = report["stop"]
    assert stop is not None and not report["live"] and any(record["position"] == stop for record in runlog), (
        "FLOW-ASSERT the run log has no terminal record", stop, report["live"])
    asks = ("question", "engine-start", "turn", "steer", "command")
    late = [record["position"] for record in runlog if record["position"] > stop and record["schema"] in asks]
    assert not late and not report["states"]["askAfterStop"], ("FLOW-ASSERT an ask follows the terminal record", late, report["states"]["askAfterStop"])
    print("FLOW terminal record at run-log position", stop, "of", report["records"], "records, and no ask follows it", flush=True)

    # Consent verification of the start relay.
    consent = summary["consent"]
    assert len(consent) == 1 and consent[0]["verified"] and not consent[0]["problems"], ("FLOW-ASSERT consent verification failed", consent)
    assert (consent[0]["review"], consent[0]["command"], consent[0]["relay"], consent[0]["runStart"]) == (
        review["position"], approve["position"], at(manager_path, start["position"]), at(str(store), 0)), (
        "FLOW-ASSERT consent verification failed", consent[0])
    print("FLOW consent verified: review", review["position"], "approve", approve["position"], "receipt", consent[0]["receipt"],
          "start relay", start["position"], "run start 0", flush=True)

    # The manager log ends its lifetime with the shutdown notice.
    lifetimes = summary["joins"]["lifetimes"]
    assert lifetimes and all(item["shutdown"] is not None for item in lifetimes), ("FLOW-ASSERT the manager log has no shutdown notice", lifetimes)

    # Gate 9 report: the manager log size and the run-log storage ratio.
    manager_bytes = sum(path.stat().st_size for path in flow_dir.rglob("*") if path.is_file())
    claims = store / "flow-claims"
    logged = (store / "flow.ndjson").stat().st_size + sum(
        path.stat().st_size for path in (claims.rglob("*") if claims.is_dir() else ()) if path.is_file())
    public = sum((store / name).stat().st_size for name in ("events.ndjson", "answers.json", "effects.ndjson") if (store / name).exists())
    ratio = logged / public
    print(f"FLOW manager log size: {len(manager)} records, {manager_bytes} bytes", flush=True)
    print(f"FLOW run-log storage ratio: run log {logged} bytes, public files {public} bytes, ratio {ratio:.3f}", flush=True)
    assert ratio <= 2.5, ("FLOW-ASSERT the run log takes more than 2.5 times the public files", ratio)
    print("PASS flow: the verb verifies the journey manager log and run store, every FLOW-ASSERT holds and consent is verified", flush=True)


def approve_fault_in_session(session, submitted, preparation, preparation_uri, preparation_tag, renamed_log, cursor, authorized):
    """Check, with read-only observations, that the manager refused the
    approval after the manager log was renamed away."""
    assert renamed_log is not None, "the approve-fault control did not rename the manager log"
    refusal = squeeze('Refused 503 "storage-unavailable"')
    deadline = time.monotonic() + 45
    while refusal not in squeeze(session.screen.text()):
        assert "Phase: associated" not in session.screen.text(), "FLOW-FAULT-ASSERT the approval associated a run although the approve append failed"
        if time.monotonic() >= deadline or session.process.poll() is not None:
            (work / "tui-approve-fault-missing.screen.txt").write_text(session.screen.text())
            raise AssertionError("FLOW-FAULT-DEADLINE the TUI showed no storage-unavailable refusal of the approval")
        session.pump()
    session.settle()
    (work / "tui-approve-fault.screen.txt").write_text(session.screen.text())
    print("PASS actual TUI shows the approval send refused with 503 storage-unavailable", flush=True)
    status, current, raw, _ = fetch(submitted["links"]["self"], authorized)
    assert status == 200, ("request read", status, current.get("code"))
    validate("Request", current, raw)
    assert current["runId"] is None and current["phase"] == "review" and current["preparationId"] == preparation["id"], (
        "FLOW-FAULT-ASSERT the refused approval changed the request", current["phase"], current["runId"])
    status, still, raw, received = fetch(preparation_uri, authorized)
    assert status == 200, ("preparation read", status, still.get("code"))
    validate("Preparation", still, raw)
    assert still["state"] == "live" and still["revision"] == preparation["revision"] and received.get("etag") == preparation_tag, (
        "FLOW-FAULT-ASSERT the refused approval changed the preparation", still["state"])
    approvals = [receipt for _, receipt in command_receipts(cursor, authorized) if receipt["operation"] == "approve"]
    assert all(receipt["state"] == "refused" for receipt in approvals), (
        "FLOW-FAULT-ASSERT the ledger holds an accepted approval", [receipt["state"] for receipt in approvals])
    print("PASS the request stays in review, the preparation stays live and unchanged, and the ledger holds no accepted approval",
          "(approve receipts:", len(approvals), ")", flush=True)


def approve_fault_after_shutdown(renamed_log, preparation_uri):
    """After the manager process has exited, check that the manager recorded
    its storage-unavailable response to the approval, that no manager log
    holds an approve command or a start relay, and that no run store exists."""
    faults = (work / "server-0.stderr").read_text(errors="replace").splitlines()
    assert any("response POST " + preparation_uri + " " in line and "public=503 storage-unavailable" in line for line in faults), (
        "FLOW-FAULT-ASSERT the manager recorded no storage-unavailable response to the approval")
    flow_dir = work / "manager" / "flow"
    left = sorted(flow_dir.glob("*.ndjson"))
    assert not left, ("FLOW-FAULT-ASSERT the manager wrote a new log at the renamed path", left)
    stores = sorted(work.glob("manager/runs/runs/*"))
    assert not stores, ("FLOW-FAULT-ASSERT a run store exists after the refused approval", stores)
    _, records, _ = read_flow("approve-fault-flow", [renamed_log])
    schemas = [record["schema"] for record in records]
    assert "review" in schemas, ("FLOW-FAULT-ASSERT the renamed manager log holds no review", schemas)
    approvals = [record["position"] for record in records if record["schema"] == "command" and record["body"]["operation"] == "approve"]
    relays = [record["position"] for record in records if record["schema"] == "relay"]
    assert not approvals and not relays, ("FLOW-FAULT-ASSERT a manager log holds an approve command or a relay", approvals, relays)
    print("PASS the manager recorded its 503 storage-unavailable response to the approval; the renamed manager log holds the review and",
          len(records), "records, and no approve command and no relay; no run store exists and the manager wrote no new log", flush=True)


def wait_ready(process):
    """Wait for HTTPS readiness of the original foreground manager process."""
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


def descendants(root):
    """The current descendant process IDs of root, from one process listing."""
    listing = subprocess.run(["ps", "-Ao", "pid=,ppid="], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, timeout=10, check=True).stdout
    children = {}
    for line in listing.splitlines():
        pid, parent = map(int, line.split())
        children.setdefault(parent, []).append(pid)
    found, frontier = [], [root]
    while frontier:
        for child in children.get(frontier.pop(), []):
            found.append(child)
            frontier.append(child)
    return found


def process_environment(pid):
    """The command and environment that ps shows for one same-user process,
    or None when the process has exited."""
    completed = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=10)
    return completed.stdout if completed.returncode == 0 and completed.stdout.strip() else None


def open_stream(path, authorized):
    """Open one SSE response and read its first complete block, which the
    manager writes at once as an event batch or a heartbeat."""
    deadline = time.monotonic() + 5
    while True:
        connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
        connection.request("GET", path, headers=authorized | {"Accept": "text/event-stream"})
        response = connection.getresponse()
        if response.status == 200:
            break
        raw = response.read(1048577)
        status = response.status
        response.close()
        connection.close()
        refused = frozen.parse_json(raw)
        validate("Problem", refused)
        # A refused read registration owns no subscription. This is not a
        # mutation replay or a cleanup inference.
        assert status in (429, 503) and time.monotonic() < deadline, ("stream admission", status, refused["code"])
        time.sleep(0.05)
    assert response.getheader("Content-Type") == "text/event-stream"
    block = bytearray()
    while not block.endswith(b"\n\n"):
        line = response.readline(16385)
        assert line and len(block) + len(line) <= 16384, "first stream block"
        block.extend(line)
    return connection, response, bytes(block)


def stream_ends(response, seconds):
    """Whether the open stream reaches its end within the wall deadline.
    Heartbeats and event blocks before the end are read and discarded."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            line = response.readline(16385)
        except http.client.IncompleteRead:
            return True
        except (ConnectionError, ssl.SSLError):
            return True
        if not line:
            return True
    return False


def credential_lifecycle():
    """WM-023 section 7 through the real HTTPS manager, numbered as in the
    B8 requirement. Store-level rotation, cutoff and idempotency facts stay
    with manager/test/CommandCheck.hs and credential_cli.py."""
    marker = "acatambientmarker" + secrets.token_hex(16)
    synthetic = "acatsyntheticbearer" + secrets.token_hex(24)
    bearers = {"fixture": bearer}
    outputs = [work / "credential"]

    def issue(name, scopes):
        output = work / ("credential-" + name)
        value = administration({"version": 1, "operation": "issue-credential", "label": "Lifecycle " + name,
                                "scopes": scopes, "profileIds": ["profile_1"],
                                "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(output)})
        outputs.append(output)
        bearers[name] = output.read_bytes().decode("ascii")
        return value["result"]["credential"], {"Authorization": "Bearer " + bearers[name]}

    def listed():
        values = administration({"version": 1, "operation": "list-credentials"})["result"]["credentials"]
        return {item["credentialId"]: item for item in values}

    def status_of(path, authorized, method="GET", payload=None, headers=None):
        return request(path, authorized | (headers or {}), method=method, payload=payload)[:2]

    environment = dict(os.environ, ACAT_LIFECYCLE_MARKER=marker)
    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors, env=environment)
        try:
            wait_ready(process)
            for _ in range(3):
                status, problem, _ = request("/v1/capabilities", {"Authorization": "Bearer " + synthetic})
                assert status == 401 and problem["code"] == "unauthenticated", "a synthetic bearer marker must not authenticate"

            # Step 1. Credentials A and B, and a live worker at the person question.
            credential_a, a_auth = issue("a", ["observe", "submit", "control"])
            credential_b, b_auth = issue("b", ["observe", "control"])
            status, capabilities, raw = request("/v1/capabilities", a_auth)
            assert status == 200 and capabilities["scopes"] == ["observe", "submit", "control"]
            validate("Capabilities", capabilities, raw)
            status, catalogue, raw = request("/v1/workflows?profileId=profile_1", a_auth)
            assert status == 200
            validate("WorkflowPage", catalogue, raw)
            workflow = next(item for item in catalogue["items"] if item["name"] == "mixed-controls")
            create = json.dumps({"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                                 "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]},
                                separators=(",", ":")).encode()

            def create_request(authorized):
                key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
                status, created, raw = request("/v1/requests", authorized | {
                    "Content-Type": "application/json", "Idempotency-Key": key}, method="POST", payload=create)
                assert status == 201, ("request creation", status, created.get("code"))
                validate("Request", created, raw)
                return created

            created = create_request(a_auth)
            a_attempts = []
            a_client = mixed_client(capabilities, a_auth, a_attempts)
            approval, run = approve_mixed(created, workflow, a_client)
            base = "/v1/runs/" + run
            head, answered, recovered_by_a = drive_mixed(run, a_client, stop_at_question=True)
            assert head is not None and answered == 0
            control, _, _ = a_client[0](base + "/control", "RunControl")
            assert control["supervision"] == "owned" and control["decisionHeadId"] == head
            cursor = a_client[0]("/v1/snapshot", "OverviewSnapshot")[0]["cursor"]
            status, value, _ = request(base + "/control", b_auth)
            assert status == 200 and value["decisionHeadId"] == head, "credential B observes the live run"
            # The worker environment is the explicit operator environment of the
            # profile. The ambient marker of the manager process is the positive
            # control that ps shows environments at all.
            shown = process_environment(process.pid)
            assert shown is not None and marker.encode() in shown, "ps does not show the manager environment"
            inspected = [(pid, shown) for pid in descendants(process.pid)
                         for shown in [process_environment(pid)] if shown is not None]
            assert inspected, "the live run has no worker process to inspect"
            assert not [pid for pid, shown in inspected if marker.encode() in shown], "a worker inherited the ambient manager environment"
            workers = len(inspected)
            print("PASS credential-lifecycle step 1: credentials A (observe, submit, control) and B (observe, control) issued through",
                  "the administration socket; A created, enqueued and approved mixed-controls run", run,
                  "and the worker waits live at person question", head, flush=True)

            # Step 2. Rotation overlap, receipt replay across rotation, and the cutoff.
            before = time.monotonic()
            rotated = administration({"version": 1, "operation": "rotate-credential",
                                      "credentialId": credential_a["credentialId"],
                                      "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential-a2")})
            after = time.monotonic()
            outputs.append(work / "credential-a2")
            bearers["a2"] = (work / "credential-a2").read_bytes().decode("ascii")
            a2_auth = {"Authorization": "Bearer " + bearers["a2"]}
            credential_a2 = rotated["result"]["credential"]
            assert rotated["result"]["previousCredentialId"] == credential_a["credentialId"]
            metadata = listed()
            old, new = metadata[credential_a["credentialId"]], metadata[credential_a2["credentialId"]]
            assert old["state"] == "active" and old["expiresAt"] == "2999-01-01T00:00:00Z", ("predecessor during overlap", old)
            assert new["state"] == "active" and new["clientId"] == old["clientId"] and new["scopes"] == old["scopes"]
            for name, authorized in (("A", a_auth), ("A'", a2_auth)):
                for path in ("/v1/capabilities", base + "/control", approval):
                    status, value = status_of(path, authorized)
                    assert status == 200, ("overlap authentication", name, path, status, value.get("code"))
            _, enqueue_path, enqueue_headers, enqueue_payload, receipt_uri = next(item for item in a_attempts if item[0] == "enqueue")
            status, replayed, _, _ = exchange(enqueue_path, enqueue_headers | a2_auth, method="POST", payload=enqueue_payload)
            assert status == 202 and replayed["links"]["self"] == receipt_uri, ("rotated replay", status, replayed.get("code"))
            validate("CommandReceipt", replayed)
            status, original = status_of(receipt_uri, a2_auth)
            assert status == 200 and original["id"] == replayed["id"] and original["operation"] == "enqueue"
            # Four drafts with large literals make the overview of this client
            # a page set of at least four pages for step 3.
            drafts = []
            for _ in range(4):
                draft = create_request(a2_auth)
                a2_client = mixed_client(capabilities, a2_auth)
                current, tag, _ = a2_client[0](draft["links"]["self"], "Request")
                a2_client[2](draft["links"]["self"], {"operation": "set-input", "input": {
                    "name": workflow["inputs"][0]["name"], "source": "literal", "value": "x" * 600000}}, tag)
                drafts.append(draft["id"])
            last_accepted = None
            while True:
                status, value = status_of("/v1/capabilities", a_auth)
                now = time.monotonic()
                if status == 401:
                    break
                assert status == 200 and now < after + 65, ("predecessor during overlap", status, value.get("code"))
                last_accepted = now
                time.sleep(0.25)
            assert last_accepted is not None and before + 59.5 <= now <= after + 63, (
                "the predecessor cutoff is not sixty seconds after rotation", now - before, now - after)
            assert value["code"] == "unauthenticated"
            operation_id = receipt_uri.rsplit("/", 1)[1]
            preparation = next(item for item in a_attempts if item[0] == "approve")[1]
            refused_paths = ["/v1/capabilities", "/v1/profiles", "/v1/snapshot", "/v1/workflows?profileId=profile_1",
                             "/v1/workflows/" + workflow["id"], created["links"]["self"], preparation, receipt_uri,
                             base, base + "/control", base + "/snapshot", base + "/outputs", "/v1/decisions/" + head,
                             "/v1/artifacts/artifact_" + "0" * 32, "/v1/events?after=" + cursor]
            for path in refused_paths:
                status, value = status_of(path, a_auth)
                assert status == 401 and value["code"] == "unauthenticated", ("predecessor after cutoff", path, status)
            status, value = status_of("/v1/events?after=" + cursor, a_auth, headers={"Accept": "text/event-stream"})
            assert status == 401, ("predecessor stream after cutoff", status)
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, value = status_of("/v1/requests", a_auth, method="POST", payload=create,
                                      headers={"Content-Type": "application/json", "Idempotency-Key": key})
            assert status == 401, ("predecessor POST after cutoff", status)
            status, value = status_of(enqueue_path, a_auth, method="POST", payload=enqueue_payload, headers=enqueue_headers)
            assert status == 401, ("predecessor replay after cutoff", status)
            status, value = status_of("/v1/capabilities", a2_auth)
            assert status == 200, "the rotated credential outlives the predecessor cutoff"
            metadata = listed()
            old, new = metadata[credential_a["credentialId"]], metadata[credential_a2["credentialId"]]
            assert old["state"] == "revoked" and old["expiresAt"] == "2999-01-01T00:00:00Z", ("predecessor after cutoff", old)
            assert new["state"] == "active"
            print(f"PASS credential-lifecycle step 2: A' rotated from A; A and A' both authenticated during the overlap; A' replayed",
                  f"the retained enqueue receipt {operation_id} through the Idempotency-Key of A; A was refused 401 on",
                  f"{len(refused_paths) + 3} routes from {now - before:.2f} s after the rotation start while list-credentials",
                  "reports A revoked with expiry 2999-01-01T00:00:00Z still in the future", flush=True)

            # Step 3. Revocation of A' during a retained page set, an open
            # stream, a known receipt and a known outputs page.
            status, first, raw = request("/v1/snapshot", a2_auth)
            assert status == 200, ("overview page", status, first.get("code"))
            validate("OverviewSnapshot", first, raw)
            assert first["page"]["index"] == 0 and first["page"]["next"] is not None
            status, second, raw = request(first["page"]["next"], a2_auth)
            assert status == 200 and second["page"]["setId"] == first["page"]["setId"], ("second page", status, second.get("code"))
            validate("OverviewSnapshot", second, raw)
            # A page token binds its client. Credential B presents the retained
            # continuation of A' and receives view-expired, and A' then reads
            # that page of its retained set.
            status, value = status_of(second["page"]["next"], b_auth)
            assert status == 410 and value["code"] == "view-expired", ("foreign page token", status, value.get("code"))
            status, third, raw = request(second["page"]["next"], a2_auth)
            assert status == 200 and third["page"]["setId"] == first["page"]["setId"], ("third page", status, third.get("code"))
            validate("OverviewSnapshot", third, raw)
            continuation = third["page"]["next"]
            assert continuation is not None, "the overview page set has fewer than four pages"
            connection, stream, block = open_stream("/v1/events?after=" + first["cursor"], a2_auth)
            try:
                for path in (receipt_uri, base + "/outputs"):
                    status, value = status_of(path, a2_auth)
                    assert status == 200, ("retained read before revocation", path, status, value.get("code"))
                administration({"version": 1, "operation": "revoke-credential", "credentialId": credential_a2["credentialId"]})
                ended = stream_ends(stream, 15)
            finally:
                stream.close()
                connection.close()
            assert ended, "the open stream of the revoked credential did not end"
            for path in (continuation, receipt_uri, base + "/outputs"):
                status, value = status_of(path, a2_auth)
                assert status == 401 and value["code"] == "unauthenticated", ("revoked retained read", path, status)
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, value = status_of("/v1/requests", a2_auth, method="POST", payload=create,
                                      headers={"Content-Type": "application/json", "Idempotency-Key": key})
            assert status == 401, ("revoked POST", status)
            assert listed()[credential_a2["credentialId"]]["state"] == "revoked"
            b_client = mixed_client(capabilities, b_auth)
            control, _, _ = b_client[0](base + "/control", "RunControl")
            assert control["supervision"] == "owned" and control["decisionHeadId"] == head, (
                "the revocation stopped the live run", control["supervision"], control["decisionHeadId"])
            # The overview now holds the large drafts, so B reads the run and its
            # decisions directly.
            _, answered_by_b, recovered_by_b = drive_mixed(run, b_client, overview=False)
            assert answered_by_b == 1 and recovered_by_a + recovered_by_b >= 1
            artifact = verified_download(run, b_client, b_auth)
            for authorized in (a2_auth, a_auth):
                status, value = status_of(artifact["download"], authorized, headers={"Accept": "application/octet-stream"})
                assert status == 401 and value["code"] == "unauthenticated", ("revoked download", status)
            print("PASS credential-lifecycle step 3: after revoking A', its page continuation, command receipt, outputs page,",
                  "artifact download and new POST each returned 401 and its open stream ended; B then saw the run owned,",
                  "answered the question, and the run reached terminal success with verified bytes", flush=True)

            # Step 4. The scope boundary. The administration command refuses
            # reload-profiles, and no local operation changes the scopes or
            # profiles of a credential, so an observe-only credential shows it.
            administration({"version": 1, "operation": "reload-profiles"}, refused="state-conflict")
            credential_o, o_auth = issue("o", ["observe"])
            for path in ("/v1/profiles", base, base + "/control", base + "/outputs"):
                status, value = status_of(path, o_auth)
                assert status == 200, ("observe-only read", path, status, value.get("code"))
            # A receipt read requires observe and the scopes of its operation, so
            # the receipt of the enqueue, a submit operation, stays hidden.
            status, value = status_of(receipt_uri, o_auth)
            assert status == 403 and value["code"] == "insufficient-scope", ("observe-only receipt read", status)
            for name, authorized in (("observe-only", o_auth), ("B", b_auth)):
                key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
                status, value = status_of("/v1/requests", authorized, method="POST", payload=create,
                                          headers={"Content-Type": "application/json", "Idempotency-Key": key})
                assert status == 403 and value["code"] == "insufficient-scope", ("submit without scope", name, status)
            print("PASS credential-lifecycle step 4: the administration command refused reload-profiles with state-conflict; an",
                  "observe-only credential read the run with 200, and received 403 insufficient-scope for the enqueue receipt",
                  "and for POST, as did B without submit; B presenting the retained page token of A' received 410 view-expired",
                  "while A' then read that page", flush=True)
            status, value = status_of("/v1/capabilities", {"Authorization": "Bearer " + synthetic})
            assert status == 401
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")
    assert not (work / "admin/admin.sock").exists(), "joined original local administration leaves no socket"

    # Step 5. No bearer and no marker bytes in any fixture file except the
    # credential output files.
    for path in outputs:
        assert path.read_bytes().decode("ascii") in bearers.values(), "a credential output file does not hold its bearer"
    needles = [("bearer " + name, value.encode()) for name, value in bearers.items()]
    needles += [("ambient marker", marker.encode()), ("synthetic bearer marker", synthetic.encode())]
    scanned = []
    for path in sorted(work.rglob("*")):
        if path in outputs or path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        found = [name for name, needle in needles if needle in data]
        assert not found, ("secret bytes in a fixture file", str(path.relative_to(work)), found)
        scanned.append(path.relative_to(work))
    names = [str(path) for path in scanned]
    required = {"server stdout": ["server-0.stdout"], "server stderr": ["server-0.stderr"],
                "manager log": [name for name in names if name.startswith("manager/flow/") and name.endswith(".ndjson")],
                "run flow log": [name for name in names if name.startswith("manager/runs/") and name.endswith("/flow.ndjson")],
                "run events": [name for name in names if name.startswith("manager/runs/") and name.endswith("/events.ndjson")],
                "database": [name for name in names if name.endswith("coordination.sqlite3")]}
    missing = [kind for kind, found in required.items() if not found or not all(name in names for name in found)]
    assert not missing, ("the scan did not cover", missing)
    print(f"PASS credential-lifecycle step 5: {len(scanned)} fixture files, including server output, the manager log, the run",
          f"flow and event logs and the database, hold none of {len(bearers)} bearers, the ambient marker or the synthetic",
          f"bearer marker; {workers} live worker processes show no ambient marker", flush=True)


if lifecycle:
    credential_lifecycle()
    raise SystemExit(0)


# The fixed bytes that warp-tls 3.4.14 writes for DenyInsecure "HTTPS required"
# before it closes a plaintext connection. Its source string continues the
# first three header lines with twelve spaces, a backslash and the letter r
# before each line feed, so these bytes are not a well-formed HTTP response.
PLAINTEXT_REFUSAL = (b"HTTP/1.1 426 Upgrade Required" + b" " * 12 + b"\\r\n"
                     b"Upgrade: TLS/1.0, HTTP/1.1" + b" " * 12 + b"\\r\n"
                     b"Connection: Upgrade" + b" " * 12 + b"\\r\n"
                     b"Content-Type: text/plain\r\n\r\nHTTPS required")
ALLOWED_ORIGIN = "https://example.invalid"
# Header names that a response may carry besides CORS headers when it holds
# no resource state: the protected headers and the Warp transport headers.
TRANSPORT_HEADERS = {"cache-control", "x-content-type-options", "vary", "date", "server", "content-length",
                     "transfer-encoding"}


class Replay:
    """Received response bytes presented to http.client as a socket."""
    def __init__(self, data):
        self.data = data

    def makefile(self, mode):
        return io.BytesIO(self.data)


def boundary_checks():
    """WM-024 through the real TLS 1.3 manager, one PASS line per negative."""
    host = f"127.0.0.1:{port}"
    authorization = "Bearer " + bearer
    responses = []

    def connect(timeout=10):
        return context.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=timeout),
                                   server_hostname="127.0.0.1")

    def read_response(connection, method):
        response = http.client.HTTPResponse(connection, method=method)
        response.begin()
        body = response.read(2097153)
        headers = [(name.lower(), value) for name, value in response.getheaders()]
        return response.status, headers, body

    def check(status, headers, body):
        """Every response carries the protected headers and exposes Location
        only on 201 and 202. A refusal is a frozen-contract problem."""
        names = [name for name, _ in headers]
        received = dict(headers)
        assert received.get("cache-control") == "no-store", ("Cache-Control", status, headers)
        assert received.get("x-content-type-options") == "nosniff", ("nosniff", status, headers)
        assert received.get("vary") == "Origin", ("Vary", status, headers)
        assert names.count("vary") == 1 and names.count("cache-control") == 1, ("duplicate protected header", headers)
        assert "location" not in received or status in (201, 202), ("Location outside 201 and 202", status, headers)
        assert not 300 <= status < 400, ("redirect", status, headers)
        responses.append(status)
        if status >= 400:
            value = frozen.parse_json(body)
            validate("Problem", value, body)
            return value["code"]
        return None

    def raw(data, method="GET", timeout=10):
        """Send raw request bytes over one new TLS connection and read one response."""
        with connect(timeout) as connection:
            connection.sendall(data)
            status, headers, body = read_response(connection, method)
        return status, check(status, headers, body), dict(headers), body

    def compose(method, target, fields, body=b""):
        lines = [f"{method} {target} HTTP/1.1"] + [f"{name}: {value}" for name, value in fields]
        return ("\r\n".join(lines) + "\r\n\r\n").encode() + body

    def get(target, fields=None, method="GET"):
        base = [("Host", host), ("Authorization", authorization)] if fields is None else fields
        return raw(compose(method, target, base), method)

    def refused(result, status, code, what):
        assert result[0] == status and (code is None or result[1] == code), (what, result[0], result[1])

    environment = dict(os.environ)
    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors, env=environment)
        try:
            wait_ready(process)
            status, capabilities, _ = request("/v1/capabilities", {"Authorization": authorization})
            assert status == 200
            validate("Capabilities", capabilities)
            limit = int(capabilities["limits"]["globalConnections"])
            assert limit == configuration["limits"]["globalConnections"]
            refused(get("/v1/capabilities"), 200, None, "authorized control request")

            # Plaintext HTTP bytes receive only the fixed DenyInsecure refusal.
            for data in (compose("GET", "/v1/capabilities", [("Host", host), ("Authorization", authorization)]),
                         compose("GET", "/v1/unknown", [("Host", host)]),
                         compose("POST", "/v1/requests", [("Host", host), ("Authorization", authorization),
                                                          ("Content-Type", "application/json"), ("Content-Length", "2")], b"{}")):
                with socket.create_connection(("127.0.0.1", port), timeout=10) as plain:
                    plain.sendall(data)
                    received = bytearray()
                    while True:
                        chunk = plain.recv(65536)
                        if not chunk:
                            break
                        received.extend(chunk)
                        assert len(received) <= 65536
                assert bytes(received) == PLAINTEXT_REFUSAL, ("plaintext refusal", bytes(received))
            print("PASS boundary plaintext: three plaintext HTTP requests, one with a valid bearer, each received only the fixed",
                  "warp-tls DenyInsecure bytes (426 Upgrade Required, text/plain \"HTTPS required\") and a close, with no",
                  "resource state, no authentication and no bearer path", flush=True)

            legacy = ssl.create_default_context(cafile=str(cert))
            legacy.minimum_version = legacy.maximum_version = ssl.TLSVersion.TLSv1_2
            try:
                with legacy.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10),
                                        server_hostname="127.0.0.1") as connection:
                    raise AssertionError("a TLS 1.2-only client completed a handshake " + str(connection.version()))
            except ssl.SSLError as failure:
                reason = failure.reason
            print("PASS boundary TLS 1.2: a TLS 1.2-only client was refused during the handshake:", reason, flush=True)

            # Host.
            refused(raw(b"GET /v1/capabilities HTTP/1.1\r\nAuthorization: " + authorization.encode() + b"\r\n\r\n"),
                    400, "malformed-request", "missing Host")
            refused(get("/v1/capabilities", [("Host", "untrusted.invalid"), ("Authorization", authorization)]),
                    400, "malformed-request", "different Host")
            refused(get("/v1/capabilities", [("Host", "127.0.0.1:1"), ("Authorization", authorization)]),
                    400, "malformed-request", "Host with another port")
            refused(get("/v1/capabilities", [("Host", "127.0.0.1"), ("Authorization", authorization)]),
                    400, "malformed-request", "Host without its port")
            for target in (f"https://{host}/v1/capabilities", f"http://{host}/v1/capabilities",
                           "https://untrusted.invalid/v1/capabilities"):
                refused(get(target), 400, "malformed-request", ("absolute-form target", target))
            refused(get("*", method="OPTIONS"), 400, "malformed-request", "asterisk-form target")
            print("PASS boundary Host: a missing Host, a different Host, another port, a Host without its port, three",
                  "absolute-form request targets and an asterisk-form OPTIONS target each returned 400 malformed-request",
                  "with a valid bearer", flush=True)

            # Paths.
            outcomes = {}
            for target in ("/v1//capabilities", "//v1/capabilities", "/v1/./capabilities", "/v1/../v1/capabilities",
                           "/v1/%2e/capabilities", "/v1/%2E%2E/v1/capabilities", "/v1/capabilities/", "/v1/",
                           "/v1/capabilities/.", "/./v1/capabilities"):
                result = get(target)
                assert result[0] in (400, 404), ("path refusal", target, result[0], result[1])
                outcomes[target] = f"{result[0]} {result[1]}"
            print("PASS boundary paths: empty, dot and trailing segments gave 400 or 404 and never a 3xx:", outcomes, flush=True)

            # Ambient authority carriers.
            for extra in (("Cookie", "session=not-authority"), ("Forwarded", "for=127.0.0.1"),
                          ("X-Forwarded-For", "127.0.0.1"), ("X-Forwarded-Host", host)):
                refused(get("/v1/capabilities", [("Host", host), ("Authorization", authorization), extra]),
                        400, "malformed-request", extra[0])
            for name in ("token", "access_token", "authorization", "Access_Token"):
                refused(get("/v1/capabilities?" + name + "=" + bearer, [("Host", host)]), 400, "malformed-request", name)
                refused(get("/v1/capabilities?" + name + "=" + bearer), 400, "malformed-request", name)
            print("PASS boundary ambient authority: Cookie, Forwarded, X-Forwarded-For, X-Forwarded-Host and query parameters",
                  "token, access_token, authorization and Access_Token each returned 400 malformed-request, with and without",
                  "a bearer header", flush=True)

            # Duplicate framing headers.
            refused(get("/v1/capabilities", [("Host", host), ("Authorization", authorization), ("Authorization", authorization)]),
                    400, "malformed-request", "duplicate Authorization")
            refused(get("/v1/capabilities", [("Host", host), ("Host", host), ("Authorization", authorization)]),
                    400, "malformed-request", "duplicate Host")
            refused(get("/v1/capabilities", [("Host", host), ("Authorization", authorization),
                                             ("Content-Length", "0"), ("Content-Length", "0")]),
                    400, "malformed-request", "duplicate Content-Length")
            print("PASS boundary duplicates: duplicate Authorization, Host and Content-Length each returned 400 malformed-request", flush=True)

            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            mutation = [("Host", host), ("Authorization", authorization), ("Content-Type", "application/json"),
                        ("Idempotency-Key", key)]
            body = b'{"workflowId":"workflow_x"}'
            refused(raw(compose("POST", "/v1/requests", mutation + [("Transfer-Encoding", "chunked"), ("Content-Length", str(len(body)))],
                                f"{len(body):x}\r\n".encode() + body + b"\r\n0\r\n\r\n"), "POST"),
                    400, "malformed-request", "Transfer-Encoding with Content-Length")
            print("PASS boundary Transfer-Encoding: Transfer-Encoding with Content-Length returned 400 malformed-request", flush=True)
            for coding in ("gzip", "identity"):
                refused(raw(compose("POST", "/v1/requests", mutation + [("Content-Encoding", coding), ("Content-Length", str(len(body)))],
                                    body), "POST"), 415, "content-coding-refused", ("Content-Encoding", coding))
            refused(get("/v1/capabilities", [("Host", host), ("Authorization", authorization), ("Content-Encoding", "gzip")]),
                    415, "content-coding-refused", "Content-Encoding on GET")
            print("PASS boundary Content-Encoding: gzip and identity on POST and gzip on GET each returned 415 content-coding-refused", flush=True)

            duplicate = b'{"workflowId":"workflow_a","workflowId":"workflow_b"}'
            refused(raw(compose("POST", "/v1/requests", mutation + [("Content-Length", str(len(duplicate)))], duplicate), "POST"),
                    400, "duplicate-field", "duplicate JSON field")
            print("PASS boundary duplicate field: a JSON body with a repeated member returned 400 duplicate-field", flush=True)

            # The strict decoder checks members in order, so a repeated member
            # after the nested one is reached only when the nesting is admitted.
            def nested(depth):
                return b'{"extra":' + b"[" * (depth - 1) + b"]" * (depth - 1) + b',"extra":1}'
            deep = raw(compose("POST", "/v1/requests", mutation + [("Content-Length", str(len(nested(65))))], nested(65)), "POST")
            refused(deep, 400, "malformed-request", "JSON nesting of depth 65")
            shallow = raw(compose("POST", "/v1/requests", mutation + [("Content-Length", str(len(nested(64))))], nested(64)), "POST")
            refused(shallow, 400, "duplicate-field", "JSON nesting of depth 64")
            print("PASS boundary nesting: JSON nesting of depth 65 returned 400 malformed-request, while the same body at depth",
                  "64 passed the nesting check and reached its repeated member, which returned 400 duplicate-field", flush=True)

            # A declared body above 2 MiB refuses before the body is read.
            started = time.monotonic()
            refused(raw(compose("POST", "/v1/requests", mutation + [("Content-Length", str(2097153))]), "POST", timeout=10),
                    413, "size-limit", "declared body above 2 MiB")
            elapsed = time.monotonic() - started
            assert elapsed < 5, ("declared body refusal waited for the body", elapsed)
            print(f"PASS boundary body limit: Content-Length 2097153 with no body bytes returned 413 size-limit after {elapsed:.2f} s,",
                  "before any body byte was sent", flush=True)

            # Header limits.
            refused(get("/v1/capabilities", [("Host", host), ("Authorization", authorization), ("X-Pad", "a" * 16500)]),
                    400, "malformed-request", "headers above 16 KiB")
            fields = [("Host", host), ("Authorization", authorization)]
            hundred = fields + [(f"X-Field-{index}", "v") for index in range(100 - len(fields))]
            refused(get("/v1/capabilities", hundred), 200, None, "exactly 100 header fields")
            over = hundred + [("X-Field-extra", "v")]
            many = get("/v1/capabilities", over)
            refused(many, 413, "size-limit", "101 header fields")
            print("PASS boundary headers: a 16.5 KiB header block returned 400 malformed-request; exactly 100 header fields were",
                  "served with 200, and 101 header fields returned 413 size-limit", flush=True)

            # CORS preflight and origin refusals.
            preflight = [("Host", host), ("Origin", ALLOWED_ORIGIN), ("Access-Control-Request-Method", "GET"),
                         ("Access-Control-Request-Headers", "authorization, if-match")]
            status, code, headers, body = get("/v1/capabilities", preflight, method="OPTIONS")
            assert status == 204 and not body, ("allowed preflight", status, code)
            assert headers.get("access-control-allow-origin") == ALLOWED_ORIGIN
            assert headers.get("access-control-allow-methods") == "GET"
            assert headers.get("access-control-allow-headers") == "authorization, if-match"
            extra = [name for name in headers if not name.startswith("access-control-") and name not in TRANSPORT_HEADERS]
            assert not extra and "etag" not in headers and "content-type" not in headers, ("preflight state", headers)
            actual = get("/v1/capabilities", [("Host", host), ("Origin", ALLOWED_ORIGIN)])
            refused(actual, 401, "unauthenticated", "actual request without a bearer")
            assert actual[2].get("access-control-allow-origin") == ALLOWED_ORIGIN
            print("PASS boundary preflight: an allowed origin, method and headers without a bearer returned 204 with only",
                  sorted(headers), "and no body; the same actual request without a bearer returned 401 unauthenticated", flush=True)
            for name, fields in (("forbidden origin", [("Host", host), ("Origin", "https://untrusted.invalid"),
                                                       ("Access-Control-Request-Method", "GET")]),
                                 ("null origin", [("Host", host), ("Origin", "null"), ("Access-Control-Request-Method", "GET")]),
                                 ("forbidden method", [("Host", host), ("Origin", ALLOWED_ORIGIN),
                                                       ("Access-Control-Request-Method", "POST")]),
                                 ("forbidden header", [("Host", host), ("Origin", ALLOWED_ORIGIN),
                                                       ("Access-Control-Request-Method", "GET"),
                                                       ("Access-Control-Request-Headers", "authorization, x-custom")]),
                                 ("absent origin", [("Host", host), ("Access-Control-Request-Method", "GET")])):
                result = get("/v1/capabilities", fields, method="OPTIONS")
                refused(result, 403, "origin-refused", ("preflight", name))
                assert not [key for key in result[2] if key.startswith("access-control-allow-")] or name in (
                    "forbidden method", "forbidden header"), ("refused preflight grants", name, result[2])
            for origin in ("https://untrusted.invalid", "null", "https://example.invalid:443", "http://example.invalid"):
                result = get("/v1/capabilities", [("Host", host), ("Authorization", authorization), ("Origin", origin)])
                refused(result, 403, "origin-refused", ("actual request origin", origin))
                assert not [key for key in result[2] if key.startswith("access-control-")], ("refused origin exposure", origin)
            print("PASS boundary origin: a preflight with a forbidden origin, Origin null, a forbidden method, a forbidden header",
                  "or no origin, and an authorized request from four origins outside the allowlist, each returned 403",
                  "origin-refused", flush=True)
            _, _, allowed, _ = get("/v1/capabilities", [("Host", host), ("Authorization", authorization), ("Origin", ALLOWED_ORIGIN)])
            assert allowed.get("access-control-allow-origin") == ALLOWED_ORIGIN
            assert allowed.get("access-control-expose-headers") == "ETag, Location, Retry-After"
            _, _, native_headers, _ = get("/v1/capabilities")
            assert not [key for key in native_headers if key.startswith("access-control-")], native_headers
            # A created draft is the one 201 of this mode. Its Location is exposed
            # to the allowed origin.
            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", {"Authorization": authorization})
            assert status == 200
            workflow = catalogue["items"][0]
            create = json.dumps({"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                                 "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]},
                                separators=(",", ":")).encode()
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, code, created, body = raw(compose("POST", "/v1/requests", [
                ("Host", host), ("Authorization", authorization), ("Origin", ALLOWED_ORIGIN), ("Content-Type", "application/json"),
                ("Idempotency-Key", key), ("Content-Length", str(len(create)))], create), "POST")
            assert status == 201 and created.get("location") == frozen.parse_json(body)["links"]["self"], ("created draft", status, code)
            assert created.get("access-control-expose-headers") == "ETag, Location, Retry-After"
            assert created.get("access-control-allow-origin") == ALLOWED_ORIGIN
            print("PASS boundary exposure: every response carried Cache-Control no-store, nosniff and Vary: Origin; ETag,",
                  "Location and Retry-After were exposed only to the allowed origin, including the Location of a 201 draft,",
                  f"and no response outside 201 and 202 carried Location ({len(responses)} responses checked)", flush=True)

            # Slow input.
            started = time.monotonic()
            received = b""
            with connect(40) as connection:
                connection.sendall(b"GET /v1/capabilities HTTP/1.1\r\nHost: " + host.encode() + b"\r\n")
                connection.settimeout(0.5)
                closed = None
                while closed is None and time.monotonic() - started < 40:
                    try:
                        connection.sendall(b"X")
                    except (ConnectionError, ssl.SSLError, OSError):
                        closed = time.monotonic() - started
                        break
                    try:
                        chunk = connection.recv(65536)
                        if not chunk:
                            closed = time.monotonic() - started
                        received += chunk
                    except (TimeoutError, socket.timeout):
                        pass
                    except (ConnectionError, ssl.SSLError, OSError):
                        closed = time.monotonic() - started
            assert closed is not None and 14 <= closed <= 35, ("trickled headers", closed)
            assert received == b"", ("trickled headers received a response", received[:200])
            print(f"PASS boundary slow headers: headers trickled one byte every 0.5 s were closed after {closed:.1f} s with no",
                  "response bytes", flush=True)
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            slow_fields = [("Host", host), ("Authorization", authorization), ("Content-Type", "application/json"),
                           ("Idempotency-Key", key), ("Content-Length", "200")]
            started = time.monotonic()
            with connect(40) as connection:
                connection.sendall(compose("POST", "/v1/requests", slow_fields))
                connection.settimeout(0.5)
                answered = None
                reply = bytearray()
                ended = None
                while answered is None and time.monotonic() - started < 40:
                    try:
                        connection.sendall(b" ")
                    except (ConnectionError, ssl.SSLError, OSError) as failure:
                        ended = (time.monotonic() - started, repr(failure))
                        break
                    # Application data only. The ssl module consumes the TLS 1.3
                    # session tickets that make the raw socket readable at once.
                    try:
                        chunk = connection.recv(65536)
                    except (TimeoutError, socket.timeout):
                        continue
                    answered = time.monotonic() - started
                    reply.extend(chunk)
                assert answered is not None and reply, ("trickled body received no response", answered, ended)
                connection.settimeout(10)
                while True:
                    try:
                        chunk = connection.recv(65536)
                    except (ConnectionError, ssl.SSLError):
                        break
                    if not chunk:
                        break
                    reply.extend(chunk)
                    assert len(reply) <= 1048576
            status, headers, body = read_response(Replay(bytes(reply)), "POST")
            code = check(status, headers, body)
            assert status == 400 and code == "malformed-request" and 14 <= answered <= 20, ("trickled body", status, code, answered)
            print(f"PASS boundary slow body: a JSON body trickled one byte every 0.5 s returned 400 malformed-request after",
                  f"{answered:.1f} s", flush=True)

            # Connection limit.
            held = [connect() for _ in range(limit)]
            waiting = context.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10),
                                          server_hostname="127.0.0.1", do_handshake_on_connect=False)
            try:
                waiting.settimeout(3)
                try:
                    waiting.do_handshake()
                    raise AssertionError("a connection above the limit was served while the limit was held")
                except (TimeoutError, socket.timeout):
                    pass
                held.pop().close()
                waiting.settimeout(10)
                released = time.monotonic()
                waiting.do_handshake()
                waiting.sendall(compose("GET", "/v1/capabilities", [("Host", host), ("Authorization", authorization)]))
                status, headers, body = read_response(waiting, "GET")
                check(status, headers, body)
                assert status == 200, ("released connection", status)
                served = time.monotonic() - released
            finally:
                waiting.close()
                for connection in held:
                    connection.close()
            refused(get("/v1/capabilities"), 200, None, "authorized request after the connection limit")
            print(f"PASS boundary connections: with {limit} idle TLS connections held, one more connection received no",
                  f"handshake for 3 s; it completed and was served 200 {served:.2f} s after one held connection was released,",
                  "and a new authorized request then returned 200", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")
    assert not (work / "admin/admin.sock").exists(), "joined original local administration leaves no socket"
    for channel in ("stdout", "stderr"):
        assert bearer.encode() not in (work / f"server-0.{channel}").read_bytes()
    print("PASS boundary: every WM-024 negative held against the running TLS 1.3 manager, and the manager shut down",
          "with its original joins", flush=True)


if boundary:
    boundary_checks()
    raise SystemExit(0)


def legacy_frontend_run():
    """Complete one scripted prompt-source run through the local frontend
    session of the runner, with the legacy retention root as its state
    directory. The frontend writes a version-2 supervisor manifest and a
    runtime store with a result. Returns the run directory."""
    workspace = work / "legacy-workspace"
    workspace.mkdir(mode=0o700)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_CAT_")}
    environment["XDG_CONFIG_HOME"] = str(workspace / "config")
    prepare = {"version": 1, "operation": "prepare", "workflow": "prompt-source", "stateDirectory": str(LEGACY_ROOT),
               "targetArguments": ["--scripted"],
               "inputs": [{"name": "input", "source": "literal", "value": "legacy history fixture"}]}
    with (work / "legacy-frontend.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "frontend"], cwd=workspace, env=environment,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        try:
            process.stdin.write(json.dumps(prepare).encode() + b"\n")
            process.stdin.flush()
            preview = json.loads(process.stdout.readline())
            assert preview["operation"] == "prepared", ("legacy frontend preparation", preview)
            process.stdin.write(json.dumps({"version": 1, "operation": "start",
                                            "approvalId": preview["approvalId"]}).encode() + b"\n")
            process.stdin.flush()
            frames = [json.loads(line) for line in process.stdout]
            assert process.wait(timeout=60) == 0, ("legacy frontend exit", process.returncode)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    assert frames and frames[-1]["event"]["type"] == "run.completed", ("legacy frontend run", frames[-1:])
    directory = LEGACY_ROOT / "runs" / preview["runId"]
    manifest = json.loads((directory / "supervisor-manifest.json").read_bytes())
    assert manifest["frontendManifestVersion"] == 2 and "invocation" not in manifest
    return directory


def page_checks():
    """WM-025 page and read verification through the real HTTPS manager,
    numbered as in the B13 requirement. Each case prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    bodies = []
    big = 900000

    def representation_tag(target, raw):
        return '"http_' + hashlib.sha256(target.encode() + b"\n" + raw).hexdigest() + '"'

    def page(target, credential, schema):
        """One page read. A 200 page must be schema-valid and carry the
        representation tag of its exact bytes. A 503 is a new bounded read."""
        deadline = time.monotonic() + 5
        while True:
            status, value, raw, received = exchange(target, credential)
            if status != 503 or time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        if status == 200:
            validate(schema, value, raw)
            assert received.get("etag") == representation_tag(target, raw), ("page ETag", target, received.get("etag"))
            bodies.append((target, raw))
        return status, value

    def refused(target, credential, status, code, what):
        actual, value = page(target, credential, "Problem")
        assert actual == status and value.get("code") == code, (what, target, actual, value.get("code"))

    def opened(path, credential, schema):
        status, value = page(path, credential, schema)
        assert status == 200, ("first page", path, status, value.get("code"))
        assert value["page"]["index"] == 0 and value["page"]["next"] is not None, ("multi-page set", path)
        return value

    def rest(pages, credential, schema, between=None):
        """Read the remaining pages of an open set. The between callback runs
        once after the first page. Every page has the set, revision, count and
        index of its position."""
        value = pages[-1]
        while value["page"]["next"] is not None:
            if between is not None:
                between()
                between = None
            status, value = page(value["page"]["next"], credential, schema)
            assert status == 200, ("continuation", status, value.get("code"))
            for key in ("setId", "revision", "expiresAt", "totalItems"):
                assert value["page"][key] == pages[0]["page"][key], ("page set field", key)
            assert value["page"]["index"] == len(pages), ("page index", value["page"]["index"], len(pages))
            pages.append(value)
        return pages

    def whole(path, credential, schema, between=None):
        status, value = page(path, credential, schema)
        assert status == 200, ("first page", path, status, value.get("code"))
        assert value["page"]["index"] == 0
        return rest([value], credential, schema, between)

    def identities(pages):
        found = []
        for value in pages:
            for item in value["items"]:
                found.append((item["kind"], item[item["kind"]]["id"]) if "kind" in item and item["kind"] in item else item["id"])
        return found

    def union(pages):
        found = identities(pages)
        assert len(found) == len(set(found)), ("duplicate page items", len(found), len(set(found)))
        assert len(found) == pages[0]["page"]["totalItems"], ("missing page items", len(found), pages[0]["page"]["totalItems"])
        return set(found)

    def issue(name, scopes):
        output = work / ("credential-" + name)
        value = administration({"version": 1, "operation": "issue-credential", "label": "Pages " + name,
                                "scopes": scopes, "profileIds": ["profile_1"],
                                "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(output)})
        return value["result"]["credential"], {"Authorization": "Bearer " + output.read_bytes().decode("ascii")}

    def interrupted(target, credential):
        """Send one page request over a raw TLS connection with a small
        receive buffer, read the start of the response and reset the
        connection while the manager is still sending the page."""
        raw_socket = socket.socket()
        raw_socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        raw_socket.settimeout(10)
        raw_socket.connect(("127.0.0.1", port))
        connection = context.wrap_socket(raw_socket, server_hostname="127.0.0.1")
        try:
            connection.sendall((f"GET {target} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                                f"Authorization: {credential['Authorization']}\r\n\r\n").encode())
            start = connection.recv(64)
            assert start.startswith(b"HTTP/1.1 200"), ("interrupted page status", start[:32])
            connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, (1).to_bytes(4, sys.byteorder) + (0).to_bytes(4, sys.byteorder))
        finally:
            connection.close()

    environment = dict(os.environ)
    legacy_run = legacy_frontend_run()
    legacy_result = (legacy_run / "runtime" / "result.json").read_bytes()
    # A binding of a path that is not a configured retention root refuses
    # the start before the listener opens.
    unbound = subprocess.run([str(runner), "--manager", "serve", "--config", str(config),
                              "--legacy-history", str(work / "unconfigured") + "=profile_1"],
                             capture_output=True, env=environment, timeout=60)
    assert unbound.returncode == 1 and b"manager configuration or HTTPS listener is unavailable" in unbound.stderr, (
        "unconfigured legacy root", unbound.returncode, unbound.stderr[-400:])
    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "--legacy-history", f"{LEGACY_ROOT}=profile_1",
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors, env=environment)
        try:
            wait_ready(process)
            status, capabilities, raw = request("/v1/capabilities", authorized)
            assert status == 200 and capabilities["limits"]["pageSetsPerClient"] == 2
            assert capabilities["limits"]["globalPageSets"] == 8 and capabilities["limits"]["pageSetLifetimeSeconds"] == 60
            status, catalogue, raw = request("/v1/workflows?profileId=profile_1", authorized)
            assert status == 200
            workflow = next(item for item in catalogue["items"] if item["name"] == "mixed-controls")
            create = json.dumps({"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                                 "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]},
                                separators=(",", ":")).encode()

            def create_request():
                key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
                status, created, raw = request("/v1/requests", authorized | {
                    "Content-Type": "application/json", "Idempotency-Key": key}, method="POST", payload=create)
                assert status == 201, ("request creation", status, created.get("code"))
                validate("Request", created, raw)
                return created

            # A terminal run gives the pages a run store, native identifiers
            # and a worker invocation for case 8.
            run = run_mixed(create_request(), workflow, capabilities, authorized)
            client = mixed_client(capabilities, authorized)
            observed, _, mutate, _ = client
            name = workflow["inputs"][0]["name"]

            def set_input(draft, value):
                _, tag, _ = observed(draft["links"]["self"], "Request")
                mutate(draft["links"]["self"], {"operation": "set-input", "input": {
                    "name": name, "source": "literal", "value": value}}, tag)

            drafts = []
            for letter in "abc":
                draft = create_request()
                set_input(draft, letter * big)
                drafts.append(draft)
            _, e_auth = issue("expiry", ["observe"])
            credential_v, v_auth = issue("view", ["observe"])
            credential_r, r_auth = issue("revoked", ["observe"])

            # The set of the expiry credential opens now and is read again
            # after its sixty-second lifetime.
            expiry_start = time.monotonic()
            expiring = opened("/v1/snapshot", e_auth, "OverviewSnapshot")
            status, second = page(expiring["page"]["next"], e_auth, "OverviewSnapshot")
            assert status == 200 and second["page"]["next"] is not None, ("expiry set continuation", status)
            expiring_token = second["page"]["next"]

            # Case 1. Every page of two multi-page sets.
            snapshot_pages = whole("/v1/snapshot", authorized, "OverviewSnapshot")
            request_pages = whole("/v1/requests", authorized, "RequestPage")
            snapshot_union, request_union = union(snapshot_pages), union(request_pages)
            assert len(snapshot_pages) >= 2 and len(request_pages) >= 2, (len(snapshot_pages), len(request_pages))
            assert {draft["id"] for draft in drafts} <= request_union
            assert {("request", draft["id"]) for draft in drafts} <= snapshot_union

            # Case 2. Binding and expiry.
            bound = opened("/v1/snapshot", authorized, "OverviewSnapshot")
            continuation = bound["page"]["next"]
            token = continuation.split("pageToken=", 1)[1]
            refused(continuation, other_authorized, 410, "view-expired", "another client")
            for target in ("/v1/requests?pageToken=" + token, f"/v1/runs/{run}/snapshot?pageToken=" + token,
                           f"/v1/decisions?runId={run}&pageToken=" + token, "/v1/decisions?pageToken=" + token):
                refused(target, authorized, 410, "view-expired", "another path or query")
            rest([bound], authorized, "OverviewSnapshot")
            viewed = opened("/v1/snapshot", v_auth, "OverviewSnapshot")
            rotated = administration({"version": 1, "operation": "rotate-credential",
                                      "credentialId": credential_v["credentialId"],
                                      "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential-view2")})
            assert rotated["result"]["previousCredentialId"] == credential_v["credentialId"]
            v2_auth = {"Authorization": "Bearer " + (work / "credential-view2").read_bytes().decode("ascii")}
            status, _, _ = request("/v1/capabilities", v_auth)
            assert status == 200, "the rotated predecessor still authenticates during the overlap"
            refused(viewed["page"]["next"], v_auth, 410, "view-expired", "predecessor after the view change")
            refused(viewed["page"]["next"], v2_auth, 410, "view-expired", "successor after the view change")
            remaining = expiry_start + 62 - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
            refused(expiring_token, e_auth, 410, "view-expired", "token after its lifetime")
            print("PASS pages case 2: a continuation token returned 410 view-expired for another client, on four other",
                  "paths or queries, after a credential rotation changed the view (for the predecessor and the successor)",
                  "and 62 s after its set was reserved; the owner then read the refused set to its end", flush=True)

            # Case 3. The per-client quota, and retirement at the last page.
            held_snapshot = opened("/v1/snapshot", authorized, "OverviewSnapshot")
            held_requests = opened("/v1/requests", authorized, "RequestPage")
            status, value, _, _ = exchange("/v1/snapshot", authorized)
            assert status == 429 and value["code"] == "storage-quota", ("third page set", status, value.get("code"))
            validate("Problem", value)
            rest([held_snapshot], authorized, "OverviewSnapshot")
            print("PASS pages case 3: with two open sets of one client, a third first page returned 429 storage-quota",
                  "while the global bound of 8 had room", flush=True)

            # Case 6. An interrupted send releases its set. The client holds
            # one set, so a released interrupted set leaves room for one more.
            interrupted("/v1/snapshot", authorized)
            deadline = time.monotonic() + 5
            while True:
                status, value = page("/v1/snapshot", authorized, "OverviewSnapshot")
                if status == 200 or time.monotonic() >= deadline:
                    break
                assert status == 429 and value["code"] == "storage-quota", ("set after interruption", status, value.get("code"))
                time.sleep(0.05)
            assert status == 200 and value["page"]["next"] is not None, ("set after interruption", status, value.get("code"))
            after_interruption = value
            status, value, _, _ = exchange("/v1/snapshot", authorized)
            assert status == 429 and value["code"] == "storage-quota", ("quota after interruption", status, value.get("code"))
            rest([held_requests], authorized, "RequestPage")
            rest([after_interruption], authorized, "OverviewSnapshot")
            print("PASS pages case 6: a client reset its connection during a first page; the manager released that set,",
                  "so the client with one open set was admitted one more and then refused a third with 429; the last",
                  "pages of both sets then released them", flush=True)

            # Case 4. A mutation between page 1 and page 2.
            added = []
            retained = whole("/v1/requests", authorized, "RequestPage", between=lambda: added.append(create_request()))
            assert union(retained) == request_union, ("retained set items", union(retained) ^ request_union)
            assert added[0]["id"] not in identities(retained[1:]), "the retained page 2 lists the new request"
            fresh = whole("/v1/requests", authorized, "RequestPage")
            assert union(fresh) == request_union | {added[0]["id"]} and fresh[0]["page"]["revision"] != retained[0]["page"]["revision"]
            print("PASS pages case 4: a request created between page 1 and page 2 was absent from the", len(retained),
                  "pages of the retained set, which kept its revision and items, and a fresh set listed it", flush=True)

            # Case 5. Revocation.
            revoked = opened("/v1/snapshot", r_auth, "OverviewSnapshot")
            administration({"version": 1, "operation": "revoke-credential", "credentialId": credential_r["credentialId"]})
            refused(revoked["page"]["next"], r_auth, 401, "unauthenticated", "revoked continuation")
            print("PASS pages case 5: a revoked credential received 401 unauthenticated for the continuation of its open set", flush=True)

            # Case 1, completed. The same identities in one page after the
            # large literals are removed.
            for draft in drafts:
                _, tag, _ = observed(draft["links"]["self"], "Request")
                mutate(draft["links"]["self"], {"operation": "remove-input", "name": name}, tag)
            one_snapshot = whole("/v1/snapshot", authorized, "OverviewSnapshot")
            one_requests = whole("/v1/requests", authorized, "RequestPage")
            assert len(one_snapshot) == 1 and len(one_requests) == 1
            assert union(one_snapshot) == snapshot_union | {("request", added[0]["id"])}, "snapshot union differs from one page"
            assert union(one_requests) == request_union | {added[0]["id"]}, "request union differs from one page"
            print(f"PASS pages case 1: /v1/snapshot spanned {len(snapshot_pages)} pages and /v1/requests {len(request_pages)};",
                  "each page ETag equalled the representation tag of its exact bytes, and the union of each set had no",
                  "duplicate and no missing item against a later one-page read of the same view with smaller items", flush=True)

            # Case 7. One item larger than a page.
            oversized = create_request()
            set_input(oversized, "z" * 1100000)
            for path in ("/v1/requests", "/v1/snapshot"):
                refused(path, authorized, 413, "view-too-large", "oversized item")
            for path in ("/v1/runs", f"/v1/runs/{run}/snapshot"):
                status, value = page(path, authorized, "RunPage" if path == "/v1/runs" else "RunSnapshot")
                assert status == 200, ("page after the refusals", path, status, value.get("code"))
            print("PASS pages case 7: a request with one item larger than the page bound made /v1/requests and",
                  "/v1/snapshot return 413 view-too-large, and the refused sets held no capacity", flush=True)

            # Case 8. Redaction over every page body of this mode.
            for path, schema in (("/v1/runs", "RunPage"), ("/v1/decisions", "DecisionPage"),
                                 (f"/v1/decisions?runId={run}", "DecisionPage"), (f"/v1/runs/{run}/snapshot", "RunSnapshot"),
                                 (f"/v1/runs/{run}/outputs", "OutputPage"), (f"/v1/runs/{run}/exports", "ExportPage"),
                                 (f"/v1/runs/{run}/lineage-requests", "LineagePage"), ("/v1/profiles", "ProfilePage")):
                status, value = page(path, authorized, schema)
                assert status == 200, ("redaction read", path, status, value.get("code"))
            markers = private_markers() + [PAGES_ENVIRONMENT_MARKER.encode()]
            stores = work / "manager" / "runs" / "runs"
            assert stores.is_dir() and any(stores.iterdir()), "the run has no run store to redact"
            # The frozen run snapshot carries the runtime backend spelling of
            # its target and attempts, "acp:<adapter>", as targetLabel. That
            # public runtime label is the only permitted form of the adapter
            # name, and only in run snapshot pages. No other argv element may
            # appear in any page.
            runtime_label = b'"targetLabel":"acp:mixed-adapter"'
            labelled, leaked = 0, []
            for target, raw in bodies:
                if re.fullmatch(r"/v1/runs/[A-Za-z0-9_-]+/snapshot(\?pageToken=[A-Za-z0-9_-]+)?", target):
                    labelled += raw.count(runtime_label)
                    raw = raw.replace(runtime_label, b"")
                leaked += [(target, marker) for marker in markers if marker in raw]
            assert not leaked, ("page body holds private bytes", leaked[:4])
            assert labelled, "no run snapshot page carried the runtime target label"
            print(f"PASS pages case 8: {len(bodies)} page bodies hold none of {len(markers)} private markers: the fixture",
                  "root with the manager root and run stores, native run identifiers, argv and the worker environment value;",
                  f"the adapter name appears only in {labelled} runtime targetLabel values of run snapshot pages", flush=True)

            # Case 9. Two credentials download the same artifact at the same
            # time. The Store has two artifact response places, so neither
            # download is refused, and both receive the verified bytes.
            artifact = verified_download(run, client, authorized)
            _, d_auth = issue("download", ["observe"])
            rounds = 8
            for number in range(rounds):
                start = threading.Barrier(2)
                received = [None, None]

                def download(slot, credential):
                    connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
                    try:
                        connection.connect()
                        start.wait(timeout=7)
                        connection.request("GET", artifact["download"], headers=credential | {"Accept": "application/octet-stream"})
                        response = connection.getresponse()
                        received[slot] = (response.status, response.getheader("Content-Type"),
                                          response.read(int(artifact["bytes"]) + 1048577))
                    finally:
                        connection.close()

                threads = [threading.Thread(target=download, args=(slot, credential))
                           for slot, credential in enumerate((authorized, d_auth))]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join(timeout=20)
                for slot, outcome in enumerate(received):
                    assert outcome is not None, ("concurrent download ended without a response", number, slot)
                    status, kind, body = outcome
                    assert status == 200, ("concurrent download refused", number, slot, status, body[:200])
                    assert kind == "application/octet-stream", ("concurrent download type", number, slot, kind)
                    assert len(body) == int(artifact["bytes"]) and hashlib.sha256(body).hexdigest() == artifact["sha256"], (
                        "concurrent download bytes", number, slot)
            print(f"PASS pages case 9: in {rounds} rounds, two credentials downloaded the same artifact at the same time",
                  "through the running manager, and both received its exact verified bytes", flush=True)

            # Case 10. The legacy entry of the bound retention root.
            run_pages = whole("/v1/runs", authorized, "RunPage")
            union(run_pages)
            items = [item for value in run_pages for item in value["items"]]
            assert [item["id"] for item in items] == sorted(item["id"] for item in items), "run collection order"
            legacy = [item for item in items if item.get("supervision") == "observer"]
            assert len(legacy) == 1, ("one legacy entry", [item.get("supervision") for item in items])
            entry = legacy[0]
            validate("Run", entry)
            assert entry["id"] != run and entry["profileId"] == "profile_1" and entry["requestId"] is None
            assert entry["manifest"] == {"kind": "versioned", "frontendManifestVersion": 2}, entry["manifest"]
            assert entry["runtime"]["status"] == "succeeded" and entry["integrity"] == "valid", (entry["runtime"], entry["integrity"])
            assert entry["verification"]["state"] == "referenced", entry["verification"]
            assert entry["workflowId"] == next(item["id"] for item in catalogue["items"] if item["name"] == "prompt-source")
            base = "/v1/runs/" + entry["id"]
            status, detail, raw, received = fetch(base, authorized)
            assert status == 200, ("legacy detail", status, detail.get("code"))
            validate("Run", detail, raw)
            assert detail == entry, ("legacy detail differs from its collection item", detail, entry)
            assert received.get("etag") == representation_tag(base, raw), ("legacy detail ETag", received.get("etag"))
            status, again, _, _ = fetch(base, authorized)
            assert status == 200 and again == detail, "a second legacy detail read differs"
            connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
            try:
                connection.request("GET", "/v1/artifacts/" + entry["verification"]["artifactId"],
                                   headers=authorized | {"Accept": "application/octet-stream"})
                response = connection.getresponse()
                downloaded = response.read(len(legacy_result) + 1)
                assert response.status == 200 and response.getheader("Content-Type") == "application/octet-stream", (
                    "legacy result download", response.status)
            finally:
                connection.close()
            assert downloaded == legacy_result, "legacy result bytes"
            tag = '"' + entry["revision"] + '"'
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, value, _, _ = exchange(base + "/control", authorized | {
                "Content-Type": "application/json", "Idempotency-Key": key, "If-Match": tag},
                method="POST", payload=b'{"operation":"cancel"}')
            assert status == 403 and value["code"] == "insufficient-scope", ("legacy control", status, value.get("code"))
            for path in (base + "/control", base + "/snapshot", base + "/outputs", base + "/exports",
                         base + "/lineage-requests", "/v1/decisions?runId=" + entry["id"]):
                status, value, _, _ = exchange(path, authorized)
                assert status == 403 and value["code"] == "insufficient-scope", ("legacy run resource", path, status, value.get("code"))
            connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
            try:
                connection.request("POST", base, body=b"{}", headers=authorized | {"Content-Type": "application/json"})
                response = connection.getresponse()
                response.read(65536)
                assert response.status == 405, ("legacy run mutation", response.status)
            finally:
                connection.close()
            status, value, _, _ = exchange(base, other_authorized)
            assert status == 404 and value["code"] == "unavailable-resource", ("legacy entry of another profile", status, value.get("code"))
            status, after, _, _ = fetch(base, authorized)
            assert status == 200 and after == detail, "a refused mutation changed the legacy entry"
            (work / "legacy-run.json").write_bytes(raw)
            print("PASS pages case 10: /v1/runs listed the legacy entry of the bound retention root in identifier order;",
                  "the item and GET", "/v1/runs/{id}", "were equal and schema-valid, its result downloaded with the exact",
                  "retained bytes, a control POST and every run subresource returned 403 insufficient-scope, a POST",
                  "to the run returned 405, and another profile's credential received 404", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")
    assert not (work / "admin/admin.sock").exists(), "joined original local administration leaves no socket"
    print("PASS pages: every WM-025 page case held against the running TLS 1.3 manager", flush=True)


if pages_mode:
    page_checks()
    raise SystemExit(0)


def event_checks():
    """WM-026 event verification through the real HTTPS manager, numbered as
    in the B14 requirement. Each case prints one PASS line. Subscriber quota
    and revocation of open streams are shown by the base mode and by the
    manager-artifact-check stream-ingestion and ordinary-stream modes, so this
    mode does not repeat them."""
    authorized = {"Authorization": "Bearer " + bearer}
    json_accept = {"Accept": "application/json"}

    def number(cursor):
        alias, _, position = cursor.rpartition(".")
        assert alias and position.isdigit(), ("cursor form", cursor)
        return int(position)

    def alias(cursor):
        return cursor.rpartition(".")[0]

    def poll(cursor, credential):
        """Every JSON batch from the cursor until hasMore is false. Returns
        the events in order and the final cursor."""
        events = []
        while True:
            status, batch, raw = request("/v1/events?after=" + cursor, credential | json_accept)
            assert status == 200, ("poll", status, batch.get("code"))
            validate("EventBatch", batch, raw)
            assert alias(batch["cursor"]) == alias(cursor) and number(batch["cursor"]) >= number(cursor), ("poll cursor", cursor, batch["cursor"])
            events += batch["events"]
            cursor = batch["cursor"]
            if not batch["hasMore"]:
                return events, cursor

    def block(response):
        """One complete SSE block, heartbeat or event."""
        found = bytearray()
        while not found.endswith(b"\n\n"):
            line = response.readline(16385)
            assert line and len(found) + len(line) <= 16384, "complete stream block"
            found.extend(line)
        return bytes(found)

    def streamed(response, first, last):
        """The events of the complete blocks of an open stream, from its first
        block until the event with the given number. Heartbeats carry no event."""
        blocks, events = [first], frozen.parse_sse(first)
        while not events or number(events[-1]["id"]) < last:
            blocks.append(block(response))
            events += frozen.parse_sse(blocks[-1])
        return blocks, events

    def attach(credential, cursor):
        return open_stream("/v1/events", credential | {"Last-Event-ID": cursor})

    def create_request(credential, capabilities, workflow):
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        body = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
        status, created, raw = request("/v1/requests", credential | {"Content-Type": "application/json", "Idempotency-Key": key},
                                       method="POST", payload=json.dumps(body, separators=(",", ":")).encode())
        assert status == 201, ("request creation", status, created.get("code"))
        validate("Request", created, raw)
        return created

    def resources(events):
        return [event["data"]["resource"] for event in events]

    def serve(iteration):
        output = (work / f"server-{iteration}.stdout").open("wb")
        errors = (work / f"server-{iteration}.stderr").open("wb")
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        return process, output, errors

    def stop(iteration, process, output, errors):
        try:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / f"server-{iteration}.exit").write_text(str(process.returncode) + "\n")
        finally:
            output.close()
            errors.close()

    process, output, errors = serve(0)
    try:
        wait_ready(process)
        status, capabilities, _ = request("/v1/capabilities", authorized)
        assert status == 200
        status, other_capabilities, _ = request("/v1/capabilities", other_authorized)
        assert status == 200
        status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
        assert status == 200 and catalogue["items"]
        workflow = catalogue["items"][0]
        status, other_catalogue, _ = request("/v1/workflows?profileId=profile_2", other_authorized)
        assert status == 200 and other_catalogue["items"]
        other_workflow = other_catalogue["items"][0]

        # Case 1. Both credentials take a snapshot and its cursor before any
        # mutation. The mutations then commit, and SSE and polling attach at
        # the snapshot cursor of the first credential.
        status, snapshot, raw = request("/v1/snapshot", authorized)
        assert status == 200 and snapshot["items"] == [] and snapshot["page"]["next"] is None
        validate("OverviewSnapshot", snapshot, raw)
        status, other_snapshot, raw = request("/v1/snapshot", other_authorized)
        assert status == 200 and other_snapshot["items"] == []
        validate("OverviewSnapshot", other_snapshot, raw)
        start, other_start = snapshot["cursor"], other_snapshot["cursor"]
        assert alias(start) == capabilities["streamId"] and alias(other_start) == other_capabilities["streamId"]
        assert number(start) == number(other_start), ("both snapshots share one durable position", start, other_start)
        mine, theirs = [], []
        mine.append(create_request(authorized, capabilities, workflow)["id"])
        mine.append(create_request(authorized, capabilities, workflow)["id"])
        theirs.append(create_request(other_authorized, other_capabilities, other_workflow)["id"])
        mine.append(create_request(authorized, capabilities, workflow)["id"])
        polled, high = poll(start, authorized)
        (work / "events-polled.json").write_text(json.dumps(polled, indent=1, default=str))
        numbers = [number(event["id"]) for event in polled]
        assert numbers and numbers[0] == number(start) + 1, ("gap between the snapshot and the first event", start, numbers[:1])
        assert numbers == sorted(set(numbers)) and numbers[-1] == number(high), ("polled order", numbers, high)
        assert all(event["data"]["resource"].rsplit("/", 1)[-1] not in theirs for event in polled), "the first credential saw the other profile"
        for ident in mine:
            assert "/v1/requests/" + ident in resources(polled), ("mutation without an invalidation", ident)
        connection, response, first = attach(authorized, start)
        try:
            blocks, sse = streamed(response, first, number(high))
            assert sse == polled, ("SSE and polling differ", resources(sse), resources(polled))
            # One later mutation reaches the open stream once, after every
            # earlier event, and polling from the old end sees exactly it.
            mine.append(create_request(authorized, capabilities, workflow)["id"])
            live, latest = poll(high, authorized)
            assert live and all(number(event["id"]) > number(high) for event in live), ("live poll", live)
            more, streamed_live = streamed(response, block(response), number(latest))
            assert streamed_live == live, ("live SSE and polling differ", resources(streamed_live), resources(live))
            assert "/v1/requests/" + mine[-1] in resources(live)
            blocks += more
            (work / "events-attached.sse").write_bytes(b"".join(blocks))
        finally:
            response.close()
            connection.close()
        polled += live
        high = latest
        print(f"PASS events case 1: SSE and polling attached at snapshot cursor {number(start)} delivered the same",
              f"{len(polled)} events in order, each once, from {number(start) + 1} with no gap after the snapshot, and one",
              "live mutation reached the open stream once after them", flush=True)

        # Case 2. The credential of the other profile polls the same range.
        # Its cursor advances over every invisible record to the same durable
        # position, and it receives none of the invisible resources.
        seen, other_high = poll(other_start, other_authorized)
        (work / "events-other.json").write_text(json.dumps(seen, indent=1, default=str))
        other_numbers = [number(event["id"]) for event in seen]
        assert number(other_high) == number(high) and alias(other_high) == alias(other_start), ("filtered advance", other_high, high)
        assert other_numbers == sorted(set(other_numbers)), ("filtered order", other_numbers)
        leaked = [event for event in seen if any(event["data"]["resource"].endswith("/" + ident) for ident in mine)]
        assert not leaked, ("the other credential received invisible resources", leaked[:2])
        assert "/v1/requests/" + theirs[0] in resources(seen), "the other credential missed its own request"
        assert other_numbers[0] > number(other_start) + 1, ("no numeric gap before the first visible event", other_numbers)
        # Together the two filtered projections cover every durable position
        # of the range, so each gap of one is a record of the other.
        covered = set(number(event["id"]) for event in polled) | set(other_numbers)
        assert covered == set(range(number(start) + 1, number(high) + 1)), ("uncovered positions", sorted(covered))
        print(f"PASS events case 2: the other-profile credential advanced from {number(other_start)} to {number(other_high)}",
              f"over {len(polled) - len(seen)} invisible records, accepted numeric gaps {other_numbers}, and received",
              f"none of the {len(mine)} invisible requests", flush=True)

        # Case 3. A stream is dropped in the middle of a block. Reconnection
        # at the last complete identifier delivers the partial block again,
        # complete, and repeats no complete block.
        assert len(polled) >= 3
        connection, response, first = attach(authorized, start)
        try:
            complete = frozen.parse_sse(first)
            assert complete == polled[:1], "first reconnect-case block"
            complete += frozen.parse_sse(block(response))
            assert complete == polled[:2], "second reconnect-case block"
            partial = response.readline(16385)
            assert partial == ("id: " + polled[2]["id"] + "\n").encode(), ("partial block start", partial)
        finally:
            response.close()
            connection.close()
        connection, response, first = attach(authorized, complete[-1]["id"])
        try:
            _, resumed = streamed(response, first, number(high))
        finally:
            response.close()
            connection.close()
        assert resumed == polled[2:], ("reconnection repeated or lost a block", resources(resumed)[:3])
        for accept in ("text/event-stream", "application/json"):
            status, problem, _ = request("/v1/events?after=" + start, authorized | {"Accept": accept, "Last-Event-ID": start})
            assert status == 400 and problem["code"] == "malformed-request", ("both cursor channels", accept, status, problem.get("code"))
        print(f"PASS events case 3: after a drop inside block {number(polled[2]['id'])}, Last-Event-ID {number(complete[-1]['id'])}",
              f"delivered that block complete and the {len(resumed) - 1} later blocks, with no complete block repeated;",
              "after with Last-Event-ID returns 400 malformed-request for SSE and polling", flush=True)
        before_restart = (capabilities["streamId"], other_capabilities["streamId"], high, other_high)
        # An ordinary shutdown ends an attached stream at a block boundary
        # with a complete response, and the manager then exits. The stream
        # belongs to the other client, because the two streams that this
        # client closed in case 3 keep its subscriptions until their next
        # write fails.
        connection, response, first = attach(other_authorized, other_high)
        try:
            assert frozen.parse_sse(first) == [], "the held stream starts with a heartbeat"
            process.terminate()
            ending = time.monotonic()
            tail = bytearray()
            while True:
                line = response.readline(16385)
                if not line:
                    break
                tail.extend(line)
                assert len(tail) <= 16384 and time.monotonic() < ending + 10, "the held stream did not end"
            assert tail.endswith(b"\n\n") or not tail, "the held stream ended inside a block"
            assert frozen.parse_sse(bytes(tail)) == [], "the held stream carried an event after the shutdown"
            ended = time.monotonic() - ending
        finally:
            response.close()
            connection.close()
        process.wait(timeout=25)
        exited = time.monotonic() - ending
    finally:
        stop(0, process, output, errors)
    print(f"PASS events shutdown: an ordinary shutdown ended the attached stream completely after {ended:.1f} s,",
          f"and the manager exited after {exited:.1f} s", flush=True)

    # Case 4. An ordinary restart keeps the public stream alias and every
    # cursor taken before it.
    process, output, errors = serve(1)
    try:
        wait_ready(process)
        status, capabilities, _ = request("/v1/capabilities", authorized)
        assert status == 200
        status, other_capabilities, _ = request("/v1/capabilities", other_authorized)
        assert status == 200
        assert (capabilities["streamId"], other_capabilities["streamId"]) == before_restart[:2], ("restart changed a stream alias", before_restart[:2])
        replayed, replay_high = poll(start, authorized)
        assert replayed[:len(polled)] == polled and alias(replay_high) == alias(start), "restart changed the retained replay"
        after, after_high = poll(before_restart[2], authorized)
        assert after == replayed[len(polled):] and after_high == replay_high
        other_after, other_after_high = poll(before_restart[3], other_authorized)
        assert number(other_after_high) == number(replay_high)
        connection, response, first = attach(authorized, before_restart[2])
        response.close()
        connection.close()
        status, snapshot, _ = request("/v1/snapshot", authorized)
        assert status == 200 and alias(snapshot["cursor"]) == capabilities["streamId"] and number(snapshot["cursor"]) == number(replay_high)
        print(f"PASS events case 4: after an ordinary restart the streamIds are unchanged, the snapshot cursor {number(start)}",
              f"replays the same {len(polled)} events, and the pre-restart cursors {number(before_restart[2])} and",
              f"{number(before_restart[3])} resume by polling and SSE with {len(after)} later events", flush=True)
    finally:
        stop(1, process, output, errors)
    assert not (work / "admin/admin.sock").exists(), "joined original local administration leaves no socket"
    for iteration in (0, 1):
        for channel in ("stdout", "stderr"):
            assert bearer.encode() not in (work / f"server-{iteration}.{channel}").read_bytes()
    print("NOTE events case 5: the subscriber quota and revocation of open streams are shown by the base mode of this",
          "harness and by the B7 stream checks, and are not repeated here", flush=True)
    print("PASS events-lifecycle: every WM-026 event case held against the running TLS 1.3 manager", flush=True)


if events_mode:
    event_checks()
    raise SystemExit(0)


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
                        if journey or approve_fault:
                            # The event cursor before the session bounds the read-only command evidence.
                            status, start_overview, raw = request("/v1/snapshot", authorized)
                            assert status == 200 and start_overview["items"] == [], "the journey does not start from an empty manager"
                            validate("OverviewSnapshot", start_overview, raw)
                            journey_cursor = start_overview["cursor"]
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
                                        assert item["source"] == "literal" and item["bytes"] == str(len(expected)), "JOURNEY-ASSERT request bytes differ from the typed literal"
                                        assert item["sha256"] == hashlib.sha256(expected).hexdigest(), "JOURNEY-ASSERT request bytes differ from the typed literal"
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
                                renamed_log = None
                                for _ in range(5):
                                    visible = session.wait_screen("y APPROVE EXACT REVIEW")
                                    compact = squeeze(visible)
                                    selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")
                                    for selector in selectors:
                                        assert selector + preparation[selector] in compact, ("JOURNEY-ASSERT a displayed review selector is clipped", selector)
                                    (work / "tui-approval.screen.txt").write_text(visible)
                                    if journey:
                                        print("PASS actual TUI shows the five review selectors unclipped:", ", ".join(selectors), flush=True)
                                    if approve_fault and renamed_log is None:
                                        # The fault: the manager log path no longer names the file
                                        # that the manager writer opened.
                                        logs = sorted((work / "manager" / "flow").glob("*.ndjson"))
                                        assert len(logs) == 1, ("the manager has other than one manager log before the approval", logs)
                                        (work / "approve-fault-flow").mkdir(mode=0o700)
                                        renamed_log = work / "approve-fault-flow" / logs[0].name
                                        os.rename(logs[0], renamed_log)
                                        print("FAULT renamed the manager log", logs[0].name, "away before the approval key", flush=True)
                                    approval_start, (last_key, line) = key_notice(session, b"y", last_key, "explicit TUI approval showed no notice")
                                    print("KEY OUTCOME:", line, flush=True)
                                    if notice_is(line, last_key, APPROVAL_STARTED):
                                        break
                                    # Only a visible deferral permits another y. A visible start never does.
                                    assert any(notice_is(line, last_key, text) for text in APPROVAL_DEFERRED), ("explicit TUI approval refused", line)
                                else:
                                    raise AssertionError("explicit TUI approval deferred five times")
                                if approve_fault:
                                    approve_fault_in_session(session, submitted, preparation, preparation_uri, preparation_tag,
                                                             renamed_log, journey_cursor, authorized)
                                    session.send(b"q")
                                    assert session.wait_exit() == 0, "service TUI did not exit successfully after the refused approval"
                                    session.assert_restored()
                                    # The manager process is joined in the finally block below, and the
                                    # control ends after its shutdown checks.
                                    break
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
                                                raise AssertionError("JOURNEY-DEADLINE " + failure)

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
                                    assert observed_run["runId"] == run and observed_run["runtime"] is not None, "JOURNEY-ASSERT displayed runtime disagrees with the snapshot"
                                    assert agrees(shown, observed_run["runtime"]["status"]), (
                                        "JOURNEY-ASSERT displayed runtime disagrees with the snapshot", shown, observed_run["runtime"]["status"])
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
                                            if time.monotonic() >= deadline or session.process.poll() is not None:
                                                (work / ("tui-" + operation + "-pending.screen.txt")).write_text(session.screen.text())
                                                raise AssertionError("JOURNEY-DEADLINE the " + operation + " decision stayed pending")
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
                                            question_occurrence = occurrence
                                            session.send(JOURNEY_ANSWER)
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
                                            # coercion. The value is compared by identity, so neither the string
                                            # "false" nor null passes. The run store check after terminal success
                                            # compares the recorded JSON value the same way.
                                            typed = {"no": False, "yes": True}.get(item["answer"], item["answer"])
                                            assert item["code"] == "flag" and typed is False, "JOURNEY-ASSERT typed answer is not JSON false"
                                            delivered = next(ack for ack in acks if ack["state"] == "delivered")
                                            answer_command = delivered["commandId"]
                                            answer_receipt, _ = run_read("/v1/commands/" + answer_command, "CommandReceipt")
                                            assert answer_receipt["operation"] == "answer" and answer_receipt["resource"] == "/v1/decisions/" + head, "JOURNEY-ASSERT answer effect is not correlated with the question"
                                            assert answer_receipt["state"] == "effect-observed" and answer_receipt["effect"]["kind"] == "answer-accepted", "JOURNEY-ASSERT answer effect is not correlated with the question"
                                            assert answer_receipt["effect"]["address"] == {"occurrenceId": occurrence}, "JOURNEY-ASSERT answer effect is not correlated with the question"
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
                                        assert chosen["choice"] == "retry", ("JOURNEY-ASSERT retry effect is not correlated with the recovery", chosen)
                                        retry_command = chosen["commandId"]
                                        while True:
                                            retry_receipt, _ = run_read("/v1/commands/" + chosen["commandId"], "CommandReceipt")
                                            if retry_receipt["state"] != "dispatch-attempted" and retry_receipt["state"] != "accepted":
                                                break
                                            assert time.monotonic() < retry_deadline, ("retry receipt stayed", retry_receipt["state"])
                                            session.pump(0.2)
                                        assert retry_receipt["operation"] == "retry" and retry_receipt["resource"] == base + "/control", "JOURNEY-ASSERT retry effect is not correlated with the recovery"
                                        assert retry_receipt["state"] == "effect-observed" and retry_receipt["effect"]["kind"] == "retried", ("JOURNEY-ASSERT retry effect is not correlated with the recovery", retry_receipt["state"])
                                        assert retry_receipt["effect"]["address"]["occurrenceId"] == occurrence, "JOURNEY-ASSERT retry effect is not correlated with the recovery"
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
                                        assert status not in ("failed", "cancelled", "orphaned"), ("JOURNEY-ASSERT terminal evidence is not success", status, final["failure"])
                                        if status == "succeeded":
                                            break
                                        assert time.monotonic() < terminal_deadline and session.process.poll() is None, ("JOURNEY-DEADLINE terminal success", status)
                                        session.pump(0.2)
                                    result_deadline = time.monotonic() + 45
                                    while not ("Terminal: succeeded" in session.screen.text() and "Result SHA-256: " in session.screen.text()):
                                        if time.monotonic() >= result_deadline or session.process.poll() is not None:
                                            (work / "tui-result-missing.screen.txt").write_text(session.screen.text())
                                            raise AssertionError("JOURNEY-DEADLINE TUI terminal success and verified result")
                                        session.pump(0.2)
                                    session.settle()
                                    shown_result = session.screen.text()
                                    (work / "tui-result.screen.txt").write_text(shown_result)
                                    outputs, _ = run_read(base + "/outputs", "OutputPage")
                                    result = next(item for item in outputs["items"] if item["kind"] == "result")
                                    artifact = result["artifact"]
                                    assert result["verification"]["state"] == "verified" and artifact["kind"] == "source-result" and artifact["runId"] == run, (
                                        "JOURNEY-ASSERT terminal evidence is not success")
                                    verified_run, _ = run_read(base + "/snapshot", "RunSnapshot")
                                    assert verified_run["verification"] == {"state": "verified", "artifactId": artifact["id"]}, (
                                        "JOURNEY-ASSERT terminal evidence is not success", verified_run["verification"])
                                    assert "Terminal: succeeded" in shown_result, "JOURNEY-ASSERT terminal evidence is not success"
                                    expected = ("Terminal: succeeded", "Result: verified " + str(int(artifact["bytes"])) + " bytes", "Result SHA-256: " + artifact["sha256"])
                                    assert all(row in shown_result for row in expected[1:]), ("JOURNEY-ASSERT result size or digest differs from the verified artifact", expected)
                                    print("PASS actual TUI shows terminal success from the snapshot and the verified result:", expected[1], "and", expected[2], flush=True)

                                    # The run store records each answer as its typed JSON value. This
                                    # read-only check compares the recorded answer of the question
                                    # occurrence with JSON false by identity.
                                    answer_files = sorted(work.glob("manager/runs/runs/*/runtime/answers.json"))
                                    assert len(answer_files) == 1, ("journey run store answers", answer_files)
                                    recorded = [entry for entry in json.loads(answer_files[0].read_bytes())["answers"] if entry["occurrenceId"] == question_occurrence]
                                    assert len(recorded) == 1 and recorded[0]["answer"] is False, "JOURNEY-ASSERT typed answer is not JSON false"
                                    print("PASS the run store records the answer of occurrence", question_occurrence, "as JSON false by identity (read-only)", flush=True)

                                    # Segment 4: save the verified bytes through the TUI. A save onto an
                                    # existing entry is refused and leaves it unchanged. A save to a fresh
                                    # absolute path writes the verified bytes with mode 0600.
                                    def save_through_tui(path, outcome, name):
                                        """Open the save dialog with s, type the path, press Ctrl-D and wait for the outcome text."""
                                        session.wait_screen("s SAVE RESULT", timeout=15)
                                        session.send(b"s")
                                        session.wait_screen("Save verified result", timeout=15)
                                        session.send(str(path).encode())
                                        session.send(b"\x04")
                                        save_deadline = time.monotonic() + 15
                                        while squeeze(outcome) not in squeeze(session.screen.text()):
                                            if time.monotonic() >= save_deadline or session.process.poll() is not None:
                                                (work / ("tui-" + name + "-missing.screen.txt")).write_text(session.screen.text())
                                                raise AssertionError("JOURNEY-DEADLINE TUI " + name + " outcome")
                                            session.pump()
                                        (work / ("tui-" + name + ".screen.txt")).write_text(session.screen.text())

                                    def independent_download(location, size):
                                        """One read-only GET of the artifact bytes. A declared refusal permits a new bounded read."""
                                        download_deadline = time.monotonic() + 5
                                        while True:
                                            connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
                                            try:
                                                connection.request("GET", location, headers=authorized | {"Accept": "application/octet-stream"})
                                                response = connection.getresponse()
                                                body = response.read(max(size, 1048576) + 1)
                                                if response.status == 200:
                                                    assert len(body) == size and response.getheader("Content-Type") == "application/octet-stream", "independent download shape"
                                                    return body
                                                problem = frozen.parse_json(body)
                                                assert response.status in (429, 503) and time.monotonic() < download_deadline, (
                                                    "JOURNEY-DEADLINE independent download", response.status, problem.get("code"))
                                            finally:
                                                connection.close()
                                            time.sleep(0.05)

                                    size = int(artifact["bytes"])
                                    existing_path = work / "journey-existing-result.bin"
                                    existing_path.write_bytes(b"keep\n")
                                    existing_before = os.lstat(existing_path)
                                    save_through_tui(existing_path, "ERROR: Save refused: an entry already exists at the destination. Nothing was written. Path: "
                                                     + str(existing_path), "save-refused")
                                    existing_after = os.lstat(existing_path)
                                    metadata = lambda status: (status.st_ino, status.st_mode, status.st_size, status.st_mtime_ns)
                                    assert existing_path.read_bytes() == b"keep\n" and metadata(existing_after) == metadata(existing_before), (
                                        "JOURNEY-ASSERT a refused save changed the existing destination")
                                    print("PASS actual TUI refused the save onto an existing file with the fixed message and its path, and left its bytes and metadata unchanged", flush=True)
                                    session.send(b"\x1b")
                                    wait_frame(("live",), 15, "Esc did not close the save dialog", "save-close")
                                    saved_path = work / "journey-saved-result.bin"
                                    assert not os.path.lexists(saved_path), "the fresh save path exists before the save"
                                    save_through_tui(saved_path, "Saved the verified " + str(size) + " bytes to " + str(saved_path), "save")
                                    saved = saved_path.read_bytes()
                                    saved_status = os.lstat(saved_path)
                                    assert stat.S_ISREG(saved_status.st_mode) and stat.S_IMODE(saved_status.st_mode) == 0o600, (
                                        "JOURNEY-ASSERT the saved file is not a regular file with mode 0600", oct(saved_status.st_mode))
                                    assert len(saved) == size and hashlib.sha256(saved).hexdigest() == artifact["sha256"], (
                                        "JOURNEY-ASSERT saved bytes differ from the output size or digest")
                                    downloaded = independent_download(artifact["download"], size)
                                    (work / "journey-independent-download.bin").write_bytes(downloaded)
                                    assert saved == downloaded, "JOURNEY-ASSERT saved bytes differ from the verified download"
                                    print("PASS actual TUI saved the verified", size, "bytes to a fresh absolute path with mode 0600; they equal an independent",
                                          "read-only GET download and the outputs size and SHA-256", artifact["sha256"], flush=True)

                                    # Single-command evidence: the command.changed events since the cursor
                                    # read before the session name every command of the journey. Each
                                    # receipt names its operation. Approve, answer and retry each have
                                    # exactly one command identity.
                                    identities = {}
                                    for resource, receipt in command_receipts(journey_cursor, authorized):
                                        identities.setdefault(receipt["operation"], []).append(resource.rsplit("/", 1)[1])
                                    (work / "journey-commands.json").write_text(json.dumps(identities, indent=1))
                                    for operation in ("approve", "answer", "retry"):
                                        assert len(identities.get(operation, [])) == 1, (
                                            "JOURNEY-ASSERT an operation has other than one command identity", operation, identities.get(operation))
                                    assert identities["answer"] == [answer_command] and identities["retry"] == [retry_command], (
                                        "JOURNEY-ASSERT an operation has other than one command identity", identities)
                                    print("PASS single command identity per operation from read-only events and receipts: approve", identities["approve"][0],
                                          "answer", answer_command, "retry", retry_command, "; operations",
                                          {operation: len(values) for operation, values in sorted(identities.items())}, flush=True)
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
                                      "success from the snapshot, the verified result size and digest on screen, the refused and the fresh TUI save of the "
                                      "verified bytes, one command identity per operation, q detach with terminal restoration and no local runner state, and "
                                      "no harness POST under the active guard", flush=True)
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
                if collections:
                    other_created = other_profile_request()
                    check_collections("created", authorized, "profile_1", requests=[created["id"]], absent=[other_created["id"]])
                    check_collections("other", other_authorized, "profile_2", requests=[other_created["id"]], absent=[created["id"]])
                    for path in ("/v1/requests?runId=x", "/v1/runs?pageToken=", "/v1/decisions?profileId=profile_1",
                                 "/v1/decisions?runId=run_1&runId=run_1", "/v1/decisions?runId=a%2Fb"):
                        status, problem, _ = request(path, authorized)
                        assert status == 400 and problem["code"] == "malformed-request", ("collection query refusal", path, status)
                    print("PASS request, run and decision collections are schema-valid single pages of the credential's own profile, "
                          "hide the other profile's request and hold no private path or native identifier; malformed queries refuse", flush=True)
                if mixed:
                    mixed_run = run_mixed(created, workflow, capabilities, authorized)
                    if collections:
                        check_collections("terminal", authorized, "profile_1", requests=[created["id"]], runs=[mixed_run], absent=[other_created["id"]])
                        print("PASS collections list the mixed request and its terminal run after completion", flush=True)
                        check_run_resources(mixed_run, authorized)
                        print("PASS export and lineage-request collections of the terminal run are schema-valid single pages "
                              "with every lineage operation eligible, refuse the other profile, hold no private path or native "
                              "identifier, and an unknown export is absent", flush=True)
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
    print("PASS original protected manager shutdown after TUI approval fixture", flush=True)
    if journey:
        journey_flow_assertions(issued["result"]["credential"], submitted, preparation, identities["approve"][0], answer_command,
                                answer_receipt["resource"], retry_command, associated["runId"], question_occurrence)
    if approve_fault:
        approve_fault_after_shutdown(renamed_log, preparation_uri)
        raise AssertionError(APPROVE_FAULT_REFUSED)
else:
    print("PASS actual TLS1.3 foreground capabilities/profiles, matching polling/SSE, reader quota, live stream revocation, original joins and same-root restart")
