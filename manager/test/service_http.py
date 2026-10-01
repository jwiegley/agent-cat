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
import shutil
import signal
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
mixed = len(sys.argv) == 6 and sys.argv[5] in ("mixed", "mixed-confirm", "tui-approval", "tui-consent-control", APPROVE_FAULT, LIFECYCLE, "pages", "routes", "failures-worker", "failures-manager", "storage") + JOURNEYS
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
# legacy entries of a bound local retention root, more than one window of
# /v1/runs holds. Each numbered case prints its own PASS line. It runs one manager
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
# The routes mode checks GET /v1/runs/{id}/routes and GET /v1/routes through
# the running protected manager after one mixed run: the public records for an
# observe-only credential, the actor records for a control credential, no
# restricted record, the route predicate, paging through after, the 410
# cursors and an unchanged database across route reads. For the manager log
# it also checks the records of the profile of each credential against the
# flow verb, and cursors across a seal and a prune. Cases 14 to 20 read both
# routes as server-sent events: the same records as JSON, attachment at a JSON
# cursor, reconnection after a partial block, cursor blocks, a live manager-log
# record before the next heartbeat, the shared reader quota, the end of open
# streams at an ordinary shutdown, and cursors across a restart. Each numbered
# case prints its own PASS line. It runs five manager lifetimes.
ROUTES = "routes"
routes_mode = len(sys.argv) == 6 and sys.argv[5] == ROUTES
# The mutations-captures mode checks POST /v1/captures through the running
# protected manager with the scripted captured-input workflow: a capture whose
# receipt size and digest equal the uploaded bytes, a same-key replay with the
# same receipt, a 403 refusal for a credential without submit, and the capture
# as the request input through enqueue, the exact review, approval and a
# succeeded run whose program received the captured bytes. Each numbered case
# prints its own PASS line. It runs one manager lifetime.
CAPTURES = "mutations-captures"
captures_mode = len(sys.argv) == 6 and sys.argv[5] == CAPTURES
# The mutations-discard mode checks the discard operation of POST
# /v1/preparations/{id} through the running protected manager with the
# scripted prompt-source workflow: refusals of a stale If-Match and of a
# credential with observe only, a discard of a reviewed preparation whose
# command reaches the effect discarded, the preparation that shows the reason
# discarded and the request that returns to draft, a same-key replay with the
# same receipt, a fresh review after a later enqueue, the state-conflict
# refusal of a discard after approval, and the discard command, its receipt,
# the discard relay and the review and request endings in the manager log
# through the flow verb. Each numbered case prints its own PASS line. It runs
# one manager lifetime.
DISCARD = "mutations-discard"
discard_mode = len(sys.argv) == 6 and sys.argv[5] == DISCARD
# The mutations-exports mode checks POST /v1/runs/{id}/exports through the
# running protected manager after a succeeded run of the scripted
# prompt-source workflow: an export whose command reaches the effect exported,
# whose receipt is published in the export collection and as its detail
# resource, and whose artifact downloads with the bytes and SHA-256 of the
# receipt and of the published file, a same-key replay with the same receipt
# and Location, and a 412 refusal of the stale collection ETag. Each numbered
# case prints its own PASS line. It runs one manager lifetime.
EXPORTS = "mutations-exports"
exports_mode = len(sys.argv) == 6 and sys.argv[5] == EXPORTS
# The mutations-lineage mode checks POST /v1/runs/{id}/lineage-requests
# through the running protected manager after a succeeded run of the scripted
# lineage-typed workflow: a restart request whose child request names the
# parent in its detail, in /v1/requests, in the lineage collection and in the
# lineage of its review, and whose approved child run answers its questions
# and succeeds, a same-key replay with the same receipt and Location, a 412
# refusal of the stale collection ETag, a resume request whose child review
# names the parent, and a fork request with an answer replacement whose child
# review names the parent and the replaced occurrence. Each numbered case
# prints its own PASS line. It runs one manager lifetime.
LINEAGE = "mutations-lineage"
lineage_mode = len(sys.argv) == 6 and sys.argv[5] == LINEAGE
# The controls mode checks the single-candidate controls of WM-027 through
# the running protected manager with the ACP control fixtures: a cancel of a
# running run that is acknowledged and ends the run cancelled, a steer of a
# steerable running attempt that reaches the effect steered and a run-log
# steer record, two credentials that answer the same head decision at the
# same time with one delivered answer and one stale-revision refusal, the
# decision-not-head refusal of a non-head decision and the
# unsupported-operation refusal of an unoffered steer while the per-run FIFO
# order holds, a retry through the run control and a choose-recovery abandon
# through the decision that each reach their effect. Each numbered case
# prints its own PASS line. It runs one manager lifetime.
CONTROLS = "controls"
controls_mode = len(sys.argv) == 6 and sys.argv[5] == CONTROLS
# The controls-routing mode checks the two-candidate controls of WM-027
# through the running protected manager. Only this mode configures
# profile_route, whose first model candidate is the recovery-offering retry
# adapter and whose spare candidate is the stub adapter. Each question with
# two candidates opens the dispatch window that the runtime reserves for a
# redirect before the first attempt. A choose-recovery fail-over through the
# decision asks the spare candidate, and the run log of the run store holds
# the relayed control, its acknowledgement, a failure for the first question
# and a new question to the spare candidate. A redirect through the run
# control inside the dispatch window asks the chosen target, and the run log
# holds the relayed control, its acknowledgement and a question to that
# target, and events.ndjson holds occurrence.redirected. Each numbered case
# prints its own PASS line. It runs one manager lifetime.
ROUTING = "controls-routing"
routing_mode = len(sys.argv) == 6 and sys.argv[5] == ROUTING
# The live-redirect mode checks the live redirect of increment 3 through the
# running protected manager. Only this mode configures profile_live, whose
# first model candidate holds its turn open and whose spare candidate is the
# stub adapter, and profile_live_effect, whose first candidate holds its turn
# for eight seconds. While the first candidate of a question that is not an
# effect holds its turn, the run control offers a redirect to the spare
# target, a redirect command is accepted, and the run completes with the
# answer of the spare candidate. A redirect of an effect in flight refuses
# with unsupported-operation, and nothing is re-routed. After the manager
# exits, the flow verb over the manager log and the run stores joins the
# command, its relay, the run-log control and its acknowledgement, and shows
# the failure of the first question and the new question. Each numbered case
# prints its own PASS line. It runs one manager lifetime.
LIVE = "live-redirect"
live_mode = len(sys.argv) == 6 and sys.argv[5] == LIVE
# The person-answers mode checks the asks that a reviewed policy field names
# through the running protected manager. Only this mode configures profile_1
# with the stub adapter and --person-answer model:fixed-point, so that a
# person answers the model ask of the scripted prompt-source workflow. The
# review shows personAnswers in the target policy, the named ask is a pending
# question decision after the approval, and a typed answer through POST
# /v1/decisions/{id} completes it. The adapter launcher records each request
# that it relays, and no attempt, engine start or turn occurs: the adapter
# receives no session/prompt. The run succeeds with the answer as its result.
# A second profile, profile_plain, has the same launcher without
# --person-answer. Its review has no personAnswers, and its run relays a
# session/prompt, so that the record can show a turn. After the manager
# exits, the flow verb over the manager log and the run store joins the
# run-log answer to the answer command of the credential. Each numbered case
# prints its own PASS line. It runs one manager lifetime.
PERSON = "person-answers"
person_mode = len(sys.argv) == 6 and sys.argv[5] == PERSON
# The failures-worker mode checks the failure ending of a lost worker through
# the running protected manager with the mixed fixture. A mixed-controls run
# waits at its person question, and the harness kills the process groups of
# the worker with SIGKILL. The run must then show lost supervision and no
# successful result, an answer and a cancel for it must be refused or end
# unresolved and never effect-observed, and no worker process may remain or
# start for it. A new mixed-controls request on the same manager must then
# be reviewed, approved and completed with a verified result. After the
# manager exits, the flow verb must report the run log of the lost run as
# ended without its stop, with lost supervision and the question uncertain.
# Each numbered case prints its own PASS line. It runs one manager lifetime.
WORKER_FAILURE = "failures-worker"
worker_failure_mode = len(sys.argv) == 6 and sys.argv[5] == WORKER_FAILURE
# The failures-manager mode checks the failure ending of a lost manager and
# the release of its quarantined reservations through three lifetimes of the
# protected manager with the mixed fixture, one profile and one execution
# reservation. A mixed-controls run waits at its person question, and a
# padding request receives three large literal inputs before it is withdrawn,
# so that the manager log and its claim checks hold more than (L - R) div 2
# bytes. The harness then kills the manager process with SIGKILL. Every worker
# process must end within a bounded wait. While no manager runs, the harness
# seals the manager log in two segments, as the writer seals it: the first
# holds the records of the lost run and the second the padding. It also
# truncates the log after the withdrawal ask of the padding and appends a copy
# of that ask with a fresh command identifier, as crashes before a receipt and
# before a COMMIT leave them. A restart on the same root and configuration
# must begin a new lifetime with its lifetime notice and reconciliation
# counts, answer the withdrawal ask with the receipt that GET returns and the
# other ask with lifetime-ended, execute no command again, answer status and
# check-store through the live channel with the quarantined reservation of the
# lost run, answer check-quarantine with clean cleanup evidence whose digest
# the harness recomputes from the terminal record of the run log, all without
# a database change or a manager-log append, show the run with lost
# supervision, dispatch no start again, return the original receipt for an
# exact replay of an earlier command, and remove the segment of the lost run
# in the pruning round at open, because a lost run is terminal for pruning. A
# new request then stays queued with capacity. A release with a wrong digest
# refuses with cleanup-unverified, and the request stays queued. The release
# with the evidence of check-quarantine frees the capacity, and the request
# reaches review without another client command. Its approved run completes
# with a verified result. A request in review is then lost with a second
# SIGKILL, and the harness appends two release asks without replies to the
# killed log: a copy of the committed release and a copy that names the new
# quarantine. The third lifetime answers them with committed-receipt-lost and
# outcome-uncertain, releases its no-launch quarantine in the same way, and a
# new request runs to completion. After the ordinary end of the third
# lifetime, the flow verb must report no undecided command, the retained
# lifetimes before the third without their shutdown notices and the third with
# it, and decode each release command with its one reply. Each numbered case
# prints its own PASS line. It runs three manager lifetimes.
MANAGER_FAILURE = "failures-manager"
manager_failure_mode = len(sys.argv) == 6 and sys.argv[5] == MANAGER_FAILURE
# The storage mode checks the storage-error endings through four lifetimes of
# the protected manager with the mixed fixture. Case 1 configures the
# smallest globalMutationLedgerBytes that admits the four commands of one
# run, R + 4 * C. A mixed-controls run waits at its person question, the
# next ordinary command is refused with storage-quota by the command-ledger
# check, and a cancel of the run is still accepted and ends the run
# cancelled. After an ordinary restart, ordinary commands are still refused,
# because the command ledger is not pruned, the manager-log positions
# continue and the flow verb reports the floor. Case 2 raises the ceiling,
# as the operator does, and renames the active manager log away while a run
# waits at its question, so that every manager-log append fails. An ordinary
# command is then refused with storage-unavailable and leaves no command row,
# and a cancel still ends the run cancelled. The operator moves the rest of
# the log out, and the next lifetime begins a new log at position 0 with its
# lifetime notice and no gap notice. Case 3 removes the result file of a
# succeeded run and corrupts the result file of a second one. The run stays
# succeeded, its result becomes unavailable with the reason missing or
# corrupt, and the artifact download refuses with unavailable-resource and
# serves no bytes. Each numbered case prints its own PASS line.
STORAGE = "storage"
storage_mode = len(sys.argv) == 6 and sys.argv[5] == STORAGE
# The modes that configure the control fixture profiles in place of the
# scripted profile: profile_1 runs the recovery-offering retry adapter and
# profile_steer runs the steerable adapter. The controls-routing mode also
# configures profile_route, and the live-redirect mode also configures
# profile_live and profile_live_effect. Other modes keep their profiles.
control_profiles = controls_mode or routing_mode or live_mode
assert len(sys.argv) == 5 or mixed or boundary or pages_mode or events_mode or captures_mode or discard_mode or exports_mode or lineage_mode or control_profiles or person_mode
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
# The routes mode also configures the second profile, for a credential that
# must receive no manager-log record of the first profile.
if collections or routes_mode:
    configuration["profiles"].append(dict(configuration["profiles"][0], id="profile_2", workspaceLabel="HTTPS other fixture"))
# The pages mode raises the global page-set bound above the per-client bound,
# so that the per-client refusal is the one under test. The worker
# environment of its profile holds a marker that no page body may show.
PAGES_ENVIRONMENT_MARKER = "acatpagesenvironment" + secrets.token_hex(16)
if pages_mode:
    configuration["limits"]["globalPageSets"] = 8
# The failures-manager mode sets L - R to 4 MiB, so that three large literal
# inputs take the manager log above the byte trigger of the pruner at open,
# while the command ledger keeps room for every command of the mode.
MANAGER_FAILURE_LEDGER = 4 * 1024 * 1024
if manager_failure_mode:
    configuration["limits"]["globalMutationLedgerBytes"] = 16 * 131072 + MANAGER_FAILURE_LEDGER
# The storage mode first sets L to the reserve R = 16 * C and four command
# capacities C = 131072. The command ledger then admits exactly the four
# ordinary commands of one run: create, set-input, enqueue and approve.
# Case 2 raises L to STORAGE_RAISED_LEDGER, as the operator does.
STORAGE_COMMAND_CAPACITY = 131072
STORAGE_LEDGER = 16 * STORAGE_COMMAND_CAPACITY + 4 * STORAGE_COMMAND_CAPACITY
STORAGE_RAISED_LEDGER = 16777216
if storage_mode:
    configuration["limits"]["globalMutationLedgerBytes"] = STORAGE_LEDGER
# The pages mode also configures one local retention root. A local frontend
# run writes one completed run into it before the manager starts, and copies
# of that run under new run identifiers fill the root to LEGACY_ENTRIES
# entries, more than the 256 legacy entries of one window. The manager serves
# them through --legacy-history as read-only legacy entries.
LEGACY_ROOT = work / "legacy"
LEGACY_ENTRIES = 300
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
# The restart quarantines the reservation of the lost run, or of a request
# in review, with its execution slot and resource keys, until the operator
# releases it with cleanup evidence. The failures-manager mode keeps one
# profile and one execution reservation, so that a quarantined reservation
# holds all capacity, and gives the profile its own resource key.
if manager_failure_mode:
    configuration["limits"]["executionReservations"] = 1
    configuration["profiles"][0]["resourceKeys"] = ["fixture_one"]
if control_profiles:
    adapters = work / "adapters"
    adapters.mkdir(mode=0o700)
    # The hold adapters of the live-redirect mode hold each turn open for
    # the given number of seconds.
    for launcher_name, program_name, arguments in (
            ("retry-adapter", "retry_adapter.py", []), ("steer-adapter", "steer_adapter.py", []),
            ("spare-adapter", "stub_adapter.py", []), ("hold-adapter", "hold_adapter.py", ["3600"]),
            ("hold-effect-adapter", "hold_adapter.py", ["8"])):
        launcher = adapters / launcher_name
        program = source / "engine/acp/test" / program_name
        argv = [sys.executable, "-B", str(program)] + arguments
        launcher.write_text(f"#!{sys.executable} -B\nimport os\nos.execv({sys.executable!r},{argv!r})\n")
        launcher.chmod(0o700)
    scripted = configuration["profiles"][0]
    fixture_path = [{"name": "PATH", "value": str(adapters)}]
    configuration["profiles"] = [
        dict(scripted, targetLabel="Deterministic ACP retry",
             targetArguments=["--engine", "acp", "--adapter", "retry-adapter"], environment=fixture_path),
        dict(scripted, id="profile_steer", workspaceLabel="HTTPS steer fixture", targetLabel="Deterministic ACP steer",
             targetArguments=["--engine", "acp", "--adapter", "steer-adapter"], environment=fixture_path)]
    if routing_mode:
        # The route named spare answers the spare candidate of the
        # mixed-controls question. The primary candidate keeps the retry
        # adapter, which offers a recovery after its decoding budget.
        configuration["profiles"].append(
            dict(scripted, id="profile_route", workspaceLabel="HTTPS route fixture", targetLabel="Deterministic ACP route",
                 targetArguments=["--engine", "acp", "--adapter", "retry-adapter", "--route", "spare=acp:spare-adapter"],
                 environment=fixture_path))
    if live_mode:
        # The route named spare answers the spare candidate. The first
        # candidate of profile_live holds its turn until a redirect stops it.
        # The first candidate of profile_live_effect answers after eight
        # seconds, since no redirect may stop an effect.
        for profile_id, label, adapter in (("profile_live", "HTTPS live fixture", "hold-adapter"),
                                           ("profile_live_effect", "HTTPS live effect fixture", "hold-effect-adapter")):
            configuration["profiles"].append(
                dict(scripted, id=profile_id, workspaceLabel=label, targetLabel="Deterministic ACP hold",
                     targetArguments=["--engine", "acp", "--adapter", adapter, "--route", "spare=acp:spare-adapter"],
                     environment=fixture_path))
if person_mode:
    # The launcher relays its input to the stub adapter. It records its
    # launch and the method of each JSON-RPC request that it relays, so that
    # the record shows each engine turn as session/prompt.
    adapters = work / "adapters"
    adapters.mkdir(mode=0o700)
    launcher = adapters / "person-adapter"
    program = source / "engine/acp/test/stub_adapter.py"
    record_path = work / "adapter-requests"
    launcher.write_text("\n".join((
        f"#!{sys.executable} -B",
        "import json, subprocess, sys",
        f"child = subprocess.Popen([{sys.executable!r}, '-B', {str(program)!r}], stdin=subprocess.PIPE)",
        f"with open({str(record_path)!r}, 'a') as record:",
        "    record.write('launch\\n')",
        "    record.flush()",
        "    for line in sys.stdin.buffer:",
        "        try:",
        "            method = json.loads(line).get('method')",
        "        except ValueError:",
        "            method = None",
        "        if method:",
        "            record.write(method + '\\n')",
        "            record.flush()",
        "        child.stdin.write(line)",
        "        child.stdin.flush()",
        "child.stdin.close()",
        "sys.exit(child.wait())",
        "")))
    launcher.chmod(0o700)
    configuration["profiles"][0].update(
        targetLabel="Deterministic ACP person answers",
        targetArguments=["--engine", "acp", "--adapter", "person-adapter", "--person-answer", "model:fixed-point"],
        environment=[{"name": "PATH", "value": str(adapters)}])
    configuration["profiles"].append(dict(
        configuration["profiles"][0], id="profile_plain", workspaceLabel="HTTPS plain fixture", targetLabel="Deterministic ACP model answers",
        targetArguments=["--engine", "acp", "--adapter", "person-adapter"]))
CONTROL_PROFILES = [profile["id"] for profile in configuration["profiles"]] if control_profiles else []
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
                         "scopes": ["observe", "submit"] + (["control", "export"] if mixed else ["control"] if captures_mode or discard_mode or lineage_mode or control_profiles or person_mode else ["control", "export"] if exports_mode else []),
                         "profileIds": CONTROL_PROFILES or (["profile_1", "profile_plain"] if person_mode else
                                                            ["profile_1"]),
                         "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential")})
bearer = (work / "credential").read_bytes().decode("ascii")
if collections:
    administration({"version": 1, "operation": "issue-credential", "label": "HTTPS other profile",
                    "scopes": ["observe", "submit"], "profileIds": ["profile_2"],
                    "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential-other")})
    other_authorized = {"Authorization": "Bearer " + (work / "credential-other").read_bytes().decode("ascii")}
# The captures and discard modes also issue a credential of the first profile
# with observe only, which a capture upload and a discard must refuse.
if captures_mode or discard_mode:
    administration({"version": 1, "operation": "issue-credential", "label": "HTTPS observe only",
                    "scopes": ["observe"], "profileIds": ["profile_1"],
                    "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential-observe")})
# The control modes also issue a peer credential of both fixture profiles.
# It answers concurrently with the first credential, and it sends the
# controls of the recovery runs, so that each credential stays within its
# ordinary mutation rate.
if control_profiles:
    administration({"version": 1, "operation": "issue-credential", "label": "HTTPS control peer",
                    "scopes": ["observe", "submit", "control"], "profileIds": CONTROL_PROFILES,
                    "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(work / "credential-peer")})
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
    URI, exact headers, exact payload, receipt URI and original receipt, so a
    later step can repeat the exact attempt."""

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
            attempts.append((body["operation"], path, headers, payload, receipt["links"]["self"], receipt))
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
    enqueue_mixed(created, workflow, client)
    return approve_review(created, workflow, client)


def enqueue_mixed(created, workflow, client):
    """Supply the literal input of each declaration and enqueue the request."""
    observed, _, mutate, _ = client
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


def approve_review(created, workflow, client):
    """Wait until the enqueued request is in review, check the exact review
    and approve it. Returns the approval receipt URI and the associated run."""
    observed, wait_for, mutate, _ = client
    text = MIXED_TEXT
    request_uri = created["links"]["self"]
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
        assert received.get("etag", "").startswith('"'), ("collection ETag", path)
        # The run collection of the pages mode also lists the legacy entries
        # of its bound root, which span more than one window. The check
        # follows every page of that set. Every other collection is one page.
        pages, bodies = [value], [raw]
        while pages_mode and label == "runs" and pages[-1]["page"]["next"] is not None:
            status, following, following_raw, _ = fetch(pages[-1]["page"]["next"], authorized)
            assert status == 200, ("collection continuation", path, status, following.get("code"))
            validate(schema, following, following_raw)
            pages.append(following)
            bodies.append(following_raw)
        items = [item for page in pages for item in page["items"]]
        assert pages[-1]["page"]["next"] is None and value["page"]["totalItems"] == len(items), ("collection page", path)
        assert len({item["id"] for item in items}) == len(items), ("collection duplicate", path)
        assert all(item["profileId"] == profile for item in items), ("collection profile", path)
        leaked = [marker for marker in markers for body in bodies if marker in body]
        assert not leaked, ("collection body holds private bytes", path, leaked)
        (work / f"collection-{name}-{label}.json").write_bytes(raw)
        found[label] = [item["id"] for item in items]
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


def read_flow(name, paths, binary=None):
    """Run the flow verb of the given binary, or else of the TUI_CHECK binary,
    on the paths and return its exit status, its records and its summary. The
    output is kept in work."""
    completed = subprocess.run([str(binary or os.environ["TUI_CHECK"]), "flow"] + [str(path) for path in paths],
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
            _, enqueue_path, enqueue_headers, enqueue_payload, receipt_uri, _ = next(item for item in a_attempts if item[0] == "enqueue")
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


def clone_legacy_runs(directory, count):
    """Copy the completed run directory count times into the same retention
    root, each copy under a new run identifier, so that the root holds
    count + 1 legacy entries without count more runs. The catalogue reader
    checks the run identifier of the supervisor manifest against the
    directory name, the runtime manifest and every event envelope against the
    supervisor manifest, and the result document against the run. Each copy
    therefore replaces the original identifier in every file that holds it,
    and then records the size and SHA-256 digest of its rewritten result in
    the run.completed event. Each file and directory of a copy keeps the
    private mode of its original. Returns the result bytes of every entry."""
    original = directory.name.encode()
    results = [(directory / "runtime" / "result.json").read_bytes()]
    for number in range(1, count + 1):
        name = f"{directory.name}-clone-{number:03d}"
        target = directory.parent / name
        shutil.copytree(directory, target, symlinks=True)
        for path in sorted(target.rglob("*")):
            source_mode = stat.S_IMODE((directory / path.relative_to(target)).lstat().st_mode)
            assert stat.S_IMODE(path.lstat().st_mode) == source_mode, ("clone mode", path)
            if path.is_file() and original in (raw := path.read_bytes()):
                path.write_bytes(raw.replace(original, name.encode()))
        result = (target / "runtime" / "result.json").read_bytes()
        events = target / "runtime" / "events.ndjson"
        lines = events.read_bytes().splitlines()
        completed = json.loads(lines[-1])
        reference = completed["event"].get("result") or {}
        assert completed["event"]["type"] == "run.completed" and reference.get("path") == "result.json", (
            "clone result reference", completed["event"])
        reference.update(bytes=str(len(result)), sha256=hashlib.sha256(result).hexdigest())
        lines[-1] = json.dumps(completed, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
        events.write_bytes(b"\n".join(lines) + b"\n")
        assert json.loads((target / "supervisor-manifest.json").read_bytes())["runId"] == name
        assert json.loads(result)["runId"] == name
        results.append(result)
    return results


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
            # The first page of an export or lineage collection carries the
            # strong collection revision, which an export or lineage POST
            # supplies as If-Match.
            expected = ('"' + value["page"]["revision"] + '"'
                        if re.fullmatch(r"/v1/runs/[A-Za-z0-9_-]+/(exports|lineage-requests)", target)
                        else representation_tag(target, raw))
            assert received.get("etag") == expected, ("page ETag", target, received.get("etag"))
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
    legacy_results = clone_legacy_runs(legacy_frontend_run(), LEGACY_ENTRIES - 1)
    assert len(set(legacy_results)) == LEGACY_ENTRIES
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
                whole(path, authorized, "RunPage" if path == "/v1/runs" else "RunSnapshot")
            print("PASS pages case 7: a request with one item larger than the page bound made /v1/requests and",
                  "/v1/snapshot return 413 view-too-large, and the refused sets held no capacity", flush=True)

            # Case 8. Redaction over every page body of this mode.
            for path, schema in (("/v1/runs", "RunPage"), ("/v1/decisions", "DecisionPage"),
                                 (f"/v1/decisions?runId={run}", "DecisionPage"), (f"/v1/runs/{run}/snapshot", "RunSnapshot"),
                                 (f"/v1/runs/{run}/outputs", "OutputPage"), (f"/v1/runs/{run}/exports", "ExportPage"),
                                 (f"/v1/runs/{run}/lineage-requests", "LineagePage"), ("/v1/profiles", "ProfilePage")):
                whole(path, authorized, schema)
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

            # Case 10. The legacy entries of the bound retention root: the
            # completed run and its copies, more than the 256 legacy entries
            # that one window of /v1/runs decodes.
            run_pages = whole("/v1/runs", authorized, "RunPage")
            union(run_pages)
            items = [item for value in run_pages for item in value["items"]]
            assert [item["id"] for item in items] == sorted(item["id"] for item in items), "run collection order"
            legacy = [item for item in items if item.get("supervision") == "observer"]
            assert len(legacy) == LEGACY_ENTRIES, ("every legacy entry", len(legacy), LEGACY_ENTRIES)
            assert [item["id"] for item in items if item.get("supervision") != "observer"] == [run], "the managed run"
            assert len(run_pages) >= 2 and run_pages[0]["page"]["totalItems"] == LEGACY_ENTRIES + 1, (
                len(run_pages), run_pages[0]["page"]["totalItems"])
            prompt_source = next(item["id"] for item in catalogue["items"] if item["name"] == "prompt-source")
            for entry in legacy:
                validate("Run", entry)
                assert entry["id"] != run and entry["profileId"] == "profile_1" and entry["requestId"] is None
                assert entry["manifest"] == {"kind": "versioned", "frontendManifestVersion": 2}, entry["manifest"]
                assert entry["runtime"]["status"] == "succeeded" and entry["integrity"] == "valid", (entry["runtime"], entry["integrity"])
                assert entry["verification"]["state"] == "referenced", entry["verification"]
                assert entry["workflowId"] == prompt_source
            # The detail of the first, middle and last legacy entry. At least
            # two of the three are copies.
            for entry in (legacy[0], legacy[len(legacy) // 2], legacy[-1]):
                base = "/v1/runs/" + entry["id"]
                status, detail, raw, received = fetch(base, authorized)
                assert status == 200, ("legacy detail", status, detail.get("code"))
                validate("Run", detail, raw)
                assert detail == entry, ("legacy detail differs from its collection item", detail, entry)
                assert received.get("etag") == representation_tag(base, raw), ("legacy detail ETag", received.get("etag"))
            # The checks below use the last of these entries, its base path and its detail.
            status, again, _, _ = fetch(base, authorized)
            assert status == 200 and again == detail, "a second legacy detail read differs"

            def legacy_download(entry):
                connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
                try:
                    connection.request("GET", "/v1/artifacts/" + entry["verification"]["artifactId"],
                                       headers=authorized | {"Accept": "application/octet-stream"})
                    response = connection.getresponse()
                    downloaded = response.read(max(map(len, legacy_results)) + 1)
                    assert response.status == 200 and response.getheader("Content-Type") == "application/octet-stream", (
                        "legacy result download", response.status)
                finally:
                    connection.close()
                assert downloaded in legacy_results, "legacy result bytes"
                return downloaded

            # Each entry has its own result, so two different downloads
            # include the result of at least one copy.
            assert legacy_download(legacy[0]) != legacy_download(legacy[-1]), "two legacy entries downloaded one result"
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
            print(f"PASS pages case 10: {len(run_pages)} pages of /v1/runs listed each of the {LEGACY_ENTRIES} legacy",
                  "entries of the bound retention root (one completed run and its copies) and the managed run once,",
                  "in identifier order; the item and GET", "/v1/runs/{id}", "were equal and schema-valid for three",
                  "legacy entries, two results downloaded with the exact retained bytes of two different entries,",
                  "a control POST and every run subresource returned 403 insufficient-scope, a POST to the run",
                  "returned 405, and another profile's credential received 404", flush=True)
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

def route_checks():
    """GET /v1/runs/{id}/routes through the real HTTPS manager after one
    mixed run. Each numbered case prints one PASS line."""
    import sqlite3
    import urllib.parse
    authorized = {"Authorization": "Bearer " + bearer}
    json_accept = {"Accept": "application/json"}
    restricted = {"engine-result", "failure"}

    def number(cursor):
        alias, _, position = cursor.rpartition(".")
        assert alias.startswith("route_") and position.isdigit(), ("route cursor form", cursor)
        return int(position)

    def alias(cursor):
        return cursor.rpartition(".")[0]

    def batch(run, credential, after=None, route=None, extra=None):
        query = []
        if after is not None:
            query.append("after=" + after)
        if route is not None:
            query.append("route=" + urllib.parse.quote(route, safe=""))
        target = f"/v1/runs/{run}/routes" + ("?" + "&".join(query) if query else "")
        return request(target, credential | json_accept | (extra or {}))

    def walk(run, credential, route=None):
        """Every batch from the start until hasMore is false. Returns the
        records in order, the final cursor and the number of batches."""
        records, cursor, batches = [], None, 0
        while True:
            status, value, raw = batch(run, credential, cursor, route)
            assert status == 200, ("route batch", status, value.get("code"))
            validate("RouteBatch", value, raw)
            assert len(raw) <= 1048576
            if cursor is not None:
                assert alias(value["cursor"]) == alias(cursor) and number(value["cursor"]) >= number(cursor), ("route cursor", cursor, value["cursor"])
            assert value["oldestCursor"] == alias(value["cursor"]) + ".0", ("route floor", value["oldestCursor"])
            for record in value["records"]:
                assert record["id"] == alias(value["cursor"]) + "." + str(record["position"] + 1), ("record id", record["id"], record["position"])
                assert record["position"] < number(value["cursor"]), ("record after the batch cursor", record["position"], value["cursor"])
            records += value["records"]
            cursor = value["cursor"]
            batches += 1
            if not value["hasMore"]:
                return records, cursor, batches
            assert batches < 1024, "route pages did not end"

    def database_rows():
        """Every row of every table of the coordination database, read through
        a read-only connection."""
        found = sorted((work / "manager").rglob("coordination.sqlite3"))
        assert len(found) == 1, ("coordination database", found)
        connection = sqlite3.connect(found[0].as_uri() + "?mode=ro", uri=True)
        try:
            tables = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
            return {table: sorted(repr(row) for row in connection.execute(f'SELECT * FROM "{table}"')) for table in tables}
        finally:
            connection.close()

    def manager_batch(credential, after=None, route=None, extra=None):
        query = []
        if after is not None:
            query.append("after=" + after)
        if route is not None:
            query.append("route=" + urllib.parse.quote(route, safe=""))
        return request("/v1/routes" + ("?" + "&".join(query) if query else ""), credential | json_accept | (extra or {}))

    def manager_walk(credential, route=None, after=None):
        """Every manager route batch from the cursor, or from the floor, until
        hasMore is false. Returns the records, the final cursor and the floor."""
        records, cursor, batches = [], after, 0
        while True:
            status, value, raw = manager_batch(credential, cursor, route)
            assert status == 200, ("manager route batch", status, value.get("code"))
            validate("ManagerRouteBatch", value, raw)
            assert len(raw) <= 1048576
            floor = number(value["oldestCursor"])
            assert alias(value["oldestCursor"]) == alias(value["cursor"]), ("manager route floor alias", value["oldestCursor"])
            if cursor is not None:
                assert alias(value["cursor"]) == alias(cursor) and number(value["cursor"]) >= number(cursor), ("manager cursor", cursor, value["cursor"])
            for record in value["records"]:
                assert record["id"] == alias(value["cursor"]) + "." + str(record["position"] + 1), ("manager record id", record["id"])
                assert floor <= record["position"] < number(value["cursor"]), ("manager record outside the batch", record["position"])
            records += value["records"]
            cursor = value["cursor"]
            batches += 1
            if not value["hasMore"]:
                return records, cursor, floor
            assert batches < 1024, "manager route pages did not end"

    def manager_named(records, request_id, run_id):
        """The enqueue and approve commands with their receipts, the review and
        the start relay of the request and its run, each found exactly once."""
        def one(label, predicate):
            found = [record for record in records if predicate(record)]
            assert len(found) == 1, ("manager route record", label, len(found))
            return found[0]
        named = {}
        for operation in ("enqueue", "approve"):
            # The run has exactly one enqueue and one approve command.
            named[operation] = one(operation, lambda r: r["schema"] == "command" and r["body"]["operation"] == operation)
            named[operation + "-receipt"] = one(operation + " receipt", lambda r: r["schema"] == "receipt"
                                                and r["replyTo"] == named[operation]["position"])
            assert named[operation + "-receipt"]["about"]["command"] == named[operation]["about"]["command"]
        assert named["enqueue"]["about"]["request"] == request_id, ("enqueue request", named["enqueue"]["about"])
        named["review"] = one("review", lambda r: r["schema"] == "review" and r["about"].get("request") == request_id)
        named["start"] = one("start relay", lambda r: r["schema"] == "relay" and r["about"].get("managerRun") == run_id
                             and r["about"].get("command") == named["approve"]["about"]["command"])
        if "body" in named["start"]:
            assert named["start"]["body"]["kind"] == "start"
        return named

    def flow_entries(name, flow_dir, active):
        """The manager-log entries that the flow verb of the runner reads, by
        position, and the retained floor, after the manager has exited. The
        run store of the run is read with it, so that the relays join."""
        stores = sorted(work.glob("manager/runs/runs/*/runtime"))
        completed = subprocess.run([str(runner), "flow", str(flow_dir)] + [str(store) for store in stores],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        (work / (name + ".ndjson")).write_bytes(completed.stdout)
        (work / (name + ".stderr")).write_bytes(completed.stderr)
        lines = [json.loads(line) for line in completed.stdout.splitlines()]
        assert lines and "summary" in lines[-1], ("flow verb", completed.returncode, completed.stderr[-2000:])
        entries = {line["position"]: line for line in lines[:-1] if line["log"] == str(active)}
        assert entries and all(line["log"] in [str(active)] + [str(store) for store in stores] for line in lines[:-1])
        manager_logs = [item for item in lines[-1]["summary"]["logs"] if item["kind"] == "manager"]
        assert len(manager_logs) == 1, ("flow verb manager logs", lines[-1]["summary"]["logs"])
        return entries, manager_logs[0]["floor"]

    def compare_flow(records, entries):
        for record in records:
            entry = entries[record["position"]]
            for field in ("schema", "from", "to", "about", "replyTo", "at"):
                assert record[field] == entry.get(field), ("manager record differs from the flow verb", record["position"], field)
            if "claim" in record:
                assert record["claim"] == entry["claim"] and "body" not in record, ("manager claim check", record["position"])
            else:
                assert record["body"] == entry["body"], ("manager inline body", record["position"])

    def record_owner(entry):
        """The owner row of a manager-log entry, by the rule of the manager route."""
        about, schema = entry.get("about", {}), entry.get("schema")
        if schema in ("command", "receipt"):
            return ("commands", about.get("command"))
        if schema == "review":
            return ("requests", about.get("request"))
        if schema == "relay":
            return ("runs", about["managerRun"]) if "managerRun" in about else ("requests", about.get("request"))
        if schema == "notice" and isinstance(entry.get("body"), dict):
            kind = entry["body"].get("notice")
            if kind == "command-changed":
                return ("commands", about.get("command"))
            if kind in ("review-ended", "request-ended"):
                return ("requests", about.get("request"))
        return None

    def database_owners():
        """Every command, request and run identifier of profile_1."""
        found = sorted((work / "manager").rglob("coordination.sqlite3"))
        connection = sqlite3.connect(found[0].as_uri() + "?mode=ro", uri=True)
        try:
            return {(table, row[0]) for table in ("commands", "requests", "runs")
                    for row in connection.execute(f"SELECT id FROM {table} WHERE profile_id='profile_1'")}
        finally:
            connection.close()

    def seal(active, sealed_dir, start):
        sealed_dir.parent.mkdir(mode=0o700, exist_ok=True)
        sealed_dir.mkdir(mode=0o700, exist_ok=True)
        active.rename(sealed_dir / ("%020d.ndjson" % start))

    def route_block(response):
        """One complete block of an open route stream."""
        found = bytearray()
        while not found.endswith(b"\n\n"):
            line = response.readline(16385)
            assert line and len(found) + len(line) <= 16384, "complete route stream block"
            found.extend(line)
        return bytes(found)

    def route_open(path, credential, cursor=None, seconds=30):
        """Open one route stream and read its first complete block, which the
        manager writes at once. A registration refused with 429 storage-quota
        is tried again: a stream whose client closed its connection keeps its
        subscription until its next write fails, at the latest at its next
        heartbeat."""
        deadline = time.monotonic() + seconds
        headers = credential | {"Accept": "text/event-stream"} | ({"Last-Event-ID": cursor} if cursor else {})
        while True:
            connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=20)
            connection.request("GET", path, headers=headers)
            response = connection.getresponse()
            if response.status == 200:
                break
            raw = response.read(1048577)
            status = response.status
            response.close()
            connection.close()
            refused = frozen.parse_json(raw)
            validate("Problem", refused)
            assert status == 429 and refused["code"] == "storage-quota" and time.monotonic() < deadline, (
                "route stream admission", path, status, refused["code"])
            time.sleep(0.25)
        assert response.getheader("Content-Type") == "text/event-stream"
        return connection, response, route_block(response)

    def route_read(response, first, until):
        """The blocks and completed entries of an open route stream, from its
        first block until an entry whose id names at least the position."""
        blocks, entries = [first], frozen.parse_route_sse(first)
        while not entries or number(entries[-1]["id"]) < until:
            blocks.append(route_block(response))
            entries += frozen.parse_route_sse(blocks[-1])
        return blocks, entries

    def same_record(streamed, polled):
        """Whether a streamed record is the polled record, or the polled
        record with its body replaced by the size notice of an oversized block."""
        if streamed == polled:
            return True
        body = streamed.get("body")
        rest = {key: value for key, value in streamed.items() if key != "body"}
        return ("body" in polled and isinstance(body, dict) and body.get("omitted") == "size"
                and isinstance(body.get("bytes"), int) and body["bytes"] > 0
                and rest == {key: value for key, value in polled.items() if key != "body"})

    def records_of(entries, schema):
        found = [entry["data"] for entry in entries if "data" in entry]
        for entry in entries:
            if "data" in entry:
                assert entry["event"] == "route." + entry["data"]["schema"], ("route event name", entry["event"])
                validate(schema, entry["data"])
        return found

    def issue(label):
        output = work / ("credential-" + label)
        administration({"version": 1, "operation": "issue-credential", "label": "Routes " + label,
                        "scopes": ["observe", "control"], "profileIds": ["profile_1"],
                        "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(output)})
        return {"Authorization": "Bearer " + output.read_bytes().decode("ascii")}

    def closing(connection, response):
        response.close()
        connection.close()

    @contextlib.contextmanager
    def serving(index):
        with (work / f"server-{index}.stdout").open("wb") as output, (work / f"server-{index}.stderr").open("wb") as errors:
            process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                        "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
            try:
                wait_ready(process)
                yield process
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=25)

    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            status, capabilities, _ = request("/v1/capabilities", authorized)
            assert status == 200
            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
            assert status == 200
            workflow = next(item for item in catalogue["items"] if item["name"] == "mixed-controls")
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            body = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                    "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
            status, created, raw = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": key},
                                           method="POST", payload=json.dumps(body, separators=(",", ":")).encode())
            assert status == 201, ("request creation", status, created.get("code"))
            run = run_mixed(created, workflow, capabilities, authorized)
            observer_file = work / "credential-observer"
            administration({"version": 1, "operation": "issue-credential", "label": "Routes observer",
                            "scopes": ["observe"], "profileIds": ["profile_1"],
                            "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(observer_file)})
            observer = {"Authorization": "Bearer " + observer_file.read_bytes().decode("ascii")}
            stranger_file = work / "credential-stranger"
            administration({"version": 1, "operation": "issue-credential", "label": "Routes other profile",
                            "scopes": ["observe", "control"], "profileIds": ["profile_2"],
                            "expiresAt": "2999-01-01T00:00:00Z", "outputFile": str(stranger_file)})
            stranger = {"Authorization": "Bearer " + stranger_file.read_bytes().decode("ascii")}

            # The local run store of the run: its event log and its run log.
            stores = [entry for entry in (work / "manager" / "runs" / "runs").iterdir()]
            assert len(stores) == 1, ("run stores", stores)
            runtime = stores[0] / "runtime"
            sequences = [int(json.loads(line)["sequence"]) for line in (runtime / "events.ndjson").read_bytes().splitlines()]
            local = [frozen.parse_json(line) for line in (runtime / "flow.ndjson").read_bytes().splitlines()]
            schemas = [line["schema"] for line in local]
            assert sequences and restricted & set(schemas), ("the mixed run log has no event or no restricted record", schemas)
            before = database_rows()

            # Case 1. An observe-only credential receives exactly the event
            # records, each naming a line of the event log in order.
            public, public_end, _ = walk(run, observer)
            (work / "routes-observer.json").write_text(json.dumps(public, indent=1, ensure_ascii=False, default=str))
            assert all(record["class"] == "public" and record["schema"] == "event" for record in public), "observer received a non-public record"
            assert [record["event"]["sequence"] for record in public] == sequences, ("event records differ from the event log", len(public), len(sequences))
            assert [record["position"] for record in public] == [i for i, name in enumerate(schemas) if name == "event"]
            assert number(public_end) == len(local), ("observer cursor end", public_end, len(local))
            print(f"PASS routes case 1: the observe-only credential received the {len(public)} event records, which name",
                  "the lines of the event log of the run in order", flush=True)

            # Case 2. A control credential of the same profile also receives
            # the actor records, and no credential receives a restricted one.
            served, served_end, batches = walk(run, authorized)
            (work / "routes-control.json").write_text(json.dumps(served, indent=1, ensure_ascii=False, default=str))
            expected = [i for i, name in enumerate(schemas) if name not in restricted]
            assert [record["position"] for record in served] == expected, "control credential records differ from the local run log"
            for record in served:
                line = local[int(record["position"])]
                assert record["class"] == ("public" if record["schema"] == "event" else "actor")
                for field in ("schema", "from", "to", "about", "at"):
                    assert record[field] == line[field], ("record field differs from the run log", record["position"], field)
                assert record["replyTo"] == line.get("replyTo"), ("record replyTo differs from the run log", record["position"])
                content = line["body"]
                if "inline" in content:
                    assert record["body"] == content["inline"] and "claim" not in record, ("inline body", record["position"])
                elif "claim" in content:
                    assert record["claim"] == content["claim"] and "body" not in record, ("claim check", record["position"])
                else:
                    assert record["event"] == {"sequence": content["event"]}, ("event number", record["position"])
            for name in ("start", "question", "answer", "control"):
                assert name in {record["schema"] for record in served}, ("control credential missed a record schema", name)
            assert not restricted & {record["schema"] for record in served + public}, "a restricted record was served"
            assert number(served_end) == number(public_end) == len(local)
            print(f"PASS routes case 2: the control credential received {len(served)} public and actor records in {batches}",
                  f"batches, including start, question, answer and control, and no credential received one of the",
                  f"{len(local) - len(expected)} restricted records", flush=True)

            # Case 3. The route predicate filters.
            questions, _, _ = walk(run, authorized, "schema=question")
            assert questions and questions == [record for record in served if record["schema"] == "question"], "route schema=question"
            workflow_events, _, _ = walk(run, observer, "schema=event,from=workflow:" + local[0]["about"]["nativeRun"])
            assert workflow_events == public, "route schema=event,from=workflow"
            hidden, _, _ = walk(run, observer, "schema=question")
            assert hidden == [], "the route predicate exposed an actor record to the observer"
            status, problem, _ = batch(run, authorized, route="unknown=1")
            assert status == 400 and problem["code"] == "malformed-request", ("malformed route", status, problem.get("code"))
            print(f"PASS routes case 3: schema=question selected the {len(questions)} question records, a sender term kept",
                  "every event record, the observer received no question, and an unknown field refused", flush=True)

            # Case 4. Paging through after returns every record once.
            for index, record in enumerate(served):
                status, value, raw = batch(run, authorized, record["id"])
                assert status == 200, ("resume", status, value.get("code"))
                validate("RouteBatch", value, raw)
                following = served[index + 1:index + 1 + len(value["records"])]
                assert value["records"] == following, ("resume from a record id", record["id"])
            status, value, _ = batch(run, authorized, served_end)
            assert status == 200 and value["records"] == [] and not value["hasMore"] and value["cursor"] == served_end
            status, problem, _ = batch(run, authorized, served[0]["id"], extra={"Last-Event-ID": served[0]["id"]})
            assert status == 400 and problem["code"] == "malformed-request", ("after with Last-Event-ID", status)
            status, value, _ = request(f"/v1/runs/{run}/routes", authorized | json_accept | {"Last-Event-ID": served[0]["id"]})
            assert status == 200 and value["records"][0] == served[1], "Last-Event-ID resume"
            print(f"PASS routes case 4: resuming after each of the {len(served)} record ids returned the following records",
                  "exactly once, the end cursor returned an empty final batch, and Last-Event-ID resumes", flush=True)

            # Case 5. A wrong-alias or future cursor returns 410.
            wrong = "route_" + "0" * 64 + ".1"
            status, problem, _ = batch(run, authorized, wrong)
            assert status == 410 and problem["code"] == "view-expired", ("wrong alias", status, problem.get("code"))
            status, problem, _ = batch(run, authorized, public_end)
            assert status == 410 and problem["code"] == "view-expired", ("another credential's alias", status, problem.get("code"))
            future = alias(served_end) + "." + str(number(served_end) + 1)
            status, problem, _ = batch(run, authorized, future)
            assert status == 410 and problem["code"] == "cursor-expired", ("future cursor", status, problem.get("code"))
            status, problem, _ = request(f"/v1/runs/{run}/routes", authorized | {"Accept": "text/plain"})
            assert status == 409 and problem["code"] == "unsupported-operation", ("route Accept", status, problem.get("code"))
            print("PASS routes case 5: a wrong alias and the alias of another credential returned 410 view-expired, a",
                  "future cursor returned 410 cursor-expired, and Accept text/plain returned 409", flush=True)

            # Case 6. Route reads write nothing to the database.
            after = database_rows()
            changed = [table for table in sorted(set(before) | set(after)) if before.get(table) != after.get(table)]
            assert not changed, ("route reads changed the database", changed)
            print(f"PASS routes case 6: the {len(before)} tables of the database are unchanged across the route reads", flush=True)

            # Case 7. A control credential of the profile receives the
            # manager-log records of the mixed run as actor records.
            managed, managed_end, floor = manager_walk(authorized)
            (work / "manager-routes-control.json").write_text(json.dumps(managed, indent=1, ensure_ascii=False, default=str))
            assert floor == 0, ("manager route floor before any prune", floor)
            assert managed and all(record["class"] == "actor" for record in managed), "manager route served a record of another class"
            assert {record["schema"] for record in managed} <= {"command", "receipt", "review", "relay", "notice"}
            named = manager_named(managed, created["id"], run)
            print("PASS routes case 7: the control credential received", len(managed), "manager-log records, including the enqueue",
                  "command at", named["enqueue"]["position"], "and its receipt, the review at", named["review"]["position"],
                  "the approve command at", named["approve"]["position"], "and its receipt, and the start relay at",
                  named["start"]["position"], flush=True)

            # Case 8. An observe-only credential receives no manager-log record,
            # and its cursor advances over every record as a filtered gap.
            hidden, hidden_end, _ = manager_walk(observer)
            assert hidden == [], ("the observe-only credential received manager-log records", [r["position"] for r in hidden])
            assert number(hidden_end) >= number(managed_end) > named["start"]["position"], ("observe-only cursor", hidden_end, managed_end)
            print("PASS routes case 8: the observe-only credential received no manager-log record, and its cursor advanced to",
                  number(hidden_end), flush=True)

            # Case 9. A control credential of another profile receives none of
            # the records of the first profile.
            foreign, foreign_end, _ = manager_walk(stranger)
            assert not {record["position"] for record in foreign} & {record["position"] for record in managed}, "another profile received a record"
            assert foreign == [] and number(foreign_end) >= number(managed_end), ("other profile manager route", foreign_end)
            print("PASS routes case 9: a control credential of profile_2 received no manager-log record of profile_1, and its",
                  "cursor advanced to", number(foreign_end), flush=True)

            # Case 10. The route predicate, paging and the 410 cursors of the
            # manager route behave as those of the run route.
            commands, _, _ = manager_walk(authorized, "schema=command")
            expected = [record for record in managed if record["schema"] == "command"]
            assert commands[:len(expected)] == expected and all(r["schema"] == "command" for r in commands), "manager route schema=command"
            for index, record in enumerate(managed):
                status, value, raw = manager_batch(authorized, record["id"])
                assert status == 200, ("manager resume", status, value.get("code"))
                validate("ManagerRouteBatch", value, raw)
                following = managed[index + 1:index + 1 + len(value["records"])]
                assert value["records"][:len(following)] == following, ("manager resume from a record id", record["id"])
            status, problem, _ = manager_batch(authorized, "route_" + "0" * 64 + ".1")
            assert status == 410 and problem["code"] == "view-expired", ("manager wrong alias", status, problem.get("code"))
            status, problem, _ = manager_batch(authorized, served_end)
            assert status == 410 and problem["code"] == "view-expired", ("run-route alias on the manager route", status, problem.get("code"))
            status, problem, _ = manager_batch(authorized, alias(managed_end) + "." + str(number(hidden_end) + 100000))
            assert status == 410 and problem["code"] == "cursor-expired", ("manager future cursor", status, problem.get("code"))
            status, problem, _ = request("/v1/routes", authorized | {"Accept": "text/plain"})
            assert status == 409 and problem["code"] == "unsupported-operation", ("manager route Accept", status, problem.get("code"))
            status, problem, _ = manager_batch(authorized, managed[0]["id"], extra={"Last-Event-ID": managed[0]["id"]})
            assert status == 400 and problem["code"] == "malformed-request", ("manager after with Last-Event-ID", status)
            after = database_rows()
            changed = [table for table in sorted(set(before) | set(after)) if before.get(table) != after.get(table)]
            assert not changed, ("manager route reads changed the database", changed)
            print(f"PASS routes case 10: schema=command selected the {len(expected)} commands, resuming after each of the",
                  f"{len(managed)} record ids returned the following records, a wrong alias and a run-route cursor returned",
                  "410 view-expired, a future cursor returned 410 cursor-expired, Accept text/plain returned 409, and the",
                  "database is unchanged", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)

    # Case 11. Each served record is the entry that the flow verb reads from
    # the same manager log, and every other retained record is a gap: a
    # failure record, or a record whose profile does not resolve.
    flow_dir = work / "manager" / "flow"
    logs = sorted(flow_dir.glob("*.ndjson"))
    assert len(logs) == 1, ("manager logs", logs)
    active, stream = logs[0], logs[0].stem
    entries, flow_floor = flow_entries("manager-flow-1", flow_dir, active)
    assert flow_floor == 0
    owners = database_owners()
    compare_flow(managed, entries)
    ends = number(managed_end)
    expected = [p for p in sorted(entries) if p < ends and entries[p]["schema"] != "failure" and record_owner(entries[p]) in owners]
    assert [record["position"] for record in managed] == expected, ("served positions differ from the resolved flow records",
                                                                     [record["position"] for record in managed], expected)
    gaps = [p for p in sorted(entries) if p < ends and p not in expected]
    assert any(entries[p]["schema"] == "notice" and entries[p]["body"].get("notice") == "lifetime" for p in gaps), "no lifetime gap"
    print(f"PASS routes case 11: the {len(managed)} served records equal the flow-verb entries of the manager log, and the",
          f"{len(gaps)} other records, lifetime notices included, are gaps", flush=True)

    # Case 12. A cursor survives a seal. The first lifetime left one active
    # file. Sealing moves it to its segment name, as the writer does, and the
    # next lifetime writes a new active file.
    sealed_dir = flow_dir / "sealed" / stream
    assert not sealed_dir.exists() or not any(sealed_dir.iterdir()), ("the manager log already has sealed segments", sealed_dir)
    first_count = len(active.read_bytes().splitlines())
    seal(active, sealed_dir, 0)
    with serving(1):
        resumed, resumed_end, floor = manager_walk(authorized, after=named["enqueue"]["id"])
        index = managed.index(named["enqueue"])
        assert floor == 0 and alias(resumed_end) == alias(managed_end), ("manager cursor after a seal", floor, resumed_end)
        assert resumed[:len(managed) - index - 1] == managed[index + 1:], "resume across a seal"
        status, capabilities, _ = request("/v1/capabilities", authorized)
        assert status == 200
        status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
        workflow = next(item for item in catalogue["items"] if item["name"] == "mixed-controls")
        body = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        status, draft, _ = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": key},
                                   method="POST", payload=json.dumps(body, separators=(",", ":")).encode())
        assert status == 201, ("draft creation", status, draft.get("code"))
        later, later_end, _ = manager_walk(authorized, after=managed_end)
        creation = [record for record in later if record["schema"] == "command" and record["body"]["operation"] == "create"]
        assert len(creation) == 1 and creation[0]["position"] >= first_count, ("draft create command after the seal", creation, first_count)
        replies = [record for record in later if record["schema"] == "receipt" and record["replyTo"] == creation[0]["position"]]
        assert len(replies) == 1, "draft create receipt after the seal"
        whole, whole_end, _ = manager_walk(authorized)
        assert whole[:len(managed)] == managed and whole[len(managed):] == later, "a walk from the floor crosses the sealed segment"
    print(f"PASS routes case 12: after a seal at position {first_count}, a cursor of the first lifetime resumed across the",
          f"sealed segment with the same alias, and the create command at {creation[0]['position']} and its receipt followed",
          "in the new active file", flush=True)

    # Case 13. The oldest cursor is the retained floor, and a cursor below it
    # returns 410. The second lifetime is sealed as well, and the oldest
    # segment is then removed, as the pruner removes it.
    second_count = len(active.read_bytes().splitlines())
    seal(active, sealed_dir, first_count)
    (sealed_dir / ("%020d.ndjson" % 0)).unlink()
    with serving(2):
        kept, kept_end, floor = manager_walk(authorized)
        assert floor == first_count, ("retained floor after a prune", floor, first_count)
        assert alias(kept_end) == alias(managed_end)
        retained = [record for record in later if record["position"] >= first_count]
        assert retained and kept[:len(retained)] == retained, "the records above the floor after a prune"
        status, value, raw = manager_batch(authorized)
        assert status == 200 and value["oldestCursor"] == alias(managed_end) + "." + str(first_count), ("oldest cursor", value["oldestCursor"])
        for position in (0, first_count - 1):
            status, problem, _ = manager_batch(authorized, alias(managed_end) + "." + str(position))
            assert status == 410 and problem["code"] == "cursor-expired", ("cursor below the floor", position, status, problem.get("code"))
        status, value, raw = manager_batch(authorized, alias(managed_end) + "." + str(first_count))
        assert status == 200 and value["records"][:1] == retained[:1], "cursor at the floor"
        status, value, raw = manager_batch(authorized, creation[0]["id"])
        assert status == 200 and value["records"][:1] == replies, "resume after the create command above the floor"
    entries, flow_floor = flow_entries("manager-flow-3", flow_dir, active)
    assert flow_floor == first_count, ("flow verb floor", flow_floor)
    compare_flow(kept, entries)
    print(f"PASS routes case 13: after a prune the oldest cursor names the floor {first_count}, cursors at 0 and",
          f"{first_count - 1} returned 410 cursor-expired, the cursor at the floor and the create command id resumed, and",
          f"the {len(kept)} records above the floor equal the flow-verb entries; the second sealed segment holds {second_count} records", flush=True)
    # Cases 14 to 20 read both routes as server-sent events.
    run_path = f"/v1/runs/{run}/routes"
    with serving(3) as process:
        status, capabilities, _ = request("/v1/capabilities", authorized)
        assert status == 200
        stream_before = capabilities["streamId"]

        # Case 14. SSE on the run route delivers the records of the JSON
        # batches, each as one block named route.<schema>, and the route
        # predicate selects the same records as in JSON.
        polled, polled_end, _ = walk(run, authorized)
        assert polled == served and polled_end == served_end, "the run log changed after the run"
        connection, response, first = route_open(run_path, authorized)
        try:
            blocks, entries = route_read(response, first, number(served[-1]["id"]))
        finally:
            closing(connection, response)
        (work / "routes-run.sse").write_bytes(b"".join(blocks))
        streamed = records_of(entries, "RouteRecord")
        assert len(streamed) == len(served) and all(same_record(a, b) for a, b in zip(streamed, served)), (
            "SSE and JSON records of the run route differ", len(streamed), len(served))
        oversized = sum(1 for a, b in zip(streamed, served) if a != b)
        connection, response, first = route_open(run_path + "?route=" + urllib.parse.quote("schema=question", safe=""), authorized)
        try:
            _, entries = route_read(response, first, number(questions[-1]["id"]))
        finally:
            closing(connection, response)
        assert [record for record in records_of(entries, "RouteRecord")] == questions, "SSE route predicate"
        print(f"PASS routes case 14: SSE on the run route delivered the {len(streamed)} records of the JSON batches in",
              f"order, one block each with the event route.<schema> ({oversized} with an omitted body), and",
              f"schema=question selected the same {len(questions)} records", flush=True)

        # Case 15. Attaching at a JSON cursor delivers the later records
        # exactly once, through Last-Event-ID and through after, and an
        # attachment at the end cursor starts with a heartbeat.
        middle = len(served) // 2
        for label, path, cursor in (("Last-Event-ID", run_path, served[middle]["id"]),
                                    ("after", run_path + "?after=" + served[middle]["id"], None)):
            connection, response, first = route_open(path, authorized, cursor)
            try:
                _, entries = route_read(response, first, number(served[-1]["id"]))
            finally:
                closing(connection, response)
            later = records_of(entries, "RouteRecord")
            assert len(later) == len(served) - middle - 1 and all(same_record(a, b) for a, b in zip(later, served[middle + 1:])), (
                "attachment at a JSON cursor", label)
        connection, response, first = route_open(run_path, authorized, served_end)
        closing(connection, response)
        assert first == b": heartbeat\n\n", ("attachment at the end cursor", first)
        print(f"PASS routes case 15: attaching at the JSON cursor of record {middle} through Last-Event-ID and through",
              f"after delivered the {len(served) - middle - 1} later records exactly once, and the end cursor started",
              "with a heartbeat", flush=True)

        # Case 16. A stream dropped inside its third block is resumed with the
        # id of its last complete block, and no complete block is repeated.
        # A request with after and Last-Event-ID returns 400 on both routes.
        assert len(served) >= 3
        connection, response, first = route_open(run_path, authorized)
        try:
            complete = records_of(frozen.parse_route_sse(first) + frozen.parse_route_sse(route_block(response)), "RouteRecord")
            assert complete == served[:2], "the first two blocks of the dropped stream"
            partial = response.readline(16385)
            assert partial == ("id: " + served[2]["id"] + "\n").encode(), ("partial block start", partial)
        finally:
            closing(connection, response)
        connection, response, first = route_open(run_path, authorized, served[1]["id"])
        try:
            _, entries = route_read(response, first, number(served[-1]["id"]))
        finally:
            closing(connection, response)
        resumed = records_of(entries, "RouteRecord")
        assert len(resumed) == len(served) - 2 and all(same_record(a, b) for a, b in zip(resumed, served[2:])), (
            "the reconnection repeated or lost a block")
        for path, cursor in ((run_path, served[0]["id"]), ("/v1/routes", managed[0]["id"])):
            status, problem, _ = request(path + "?after=" + cursor, authorized | {"Accept": "text/event-stream", "Last-Event-ID": cursor})
            assert status == 400 and problem["code"] == "malformed-request", ("after with Last-Event-ID on SSE", path, status)
        print(f"PASS routes case 16: after a drop inside block {number(served[2]['id'])}, Last-Event-ID",
              f"{number(served[1]['id'])} delivered that record complete and the {len(resumed) - 1} later records, with",
              "no complete block repeated, and after with Last-Event-ID returned 400 on both routes", flush=True)

        # Case 17. SSE on the manager route delivers the records of the JSON
        # batches. An observe-only credential receives cursor blocks only. A
        # record appended while a stream is open reaches it before the next
        # heartbeat.
        managed_now, managed_now_end, floor = manager_walk(authorized)
        assert managed_now and floor == first_count
        connection, response, first = route_open("/v1/routes", authorized)
        try:
            _, entries = route_read(response, first, number(managed_now[-1]["id"]))
        finally:
            closing(connection, response)
        streamed_managed = records_of(entries, "ManagerRouteRecord")
        assert len(streamed_managed) == len(managed_now) and all(same_record(a, b) for a, b in zip(streamed_managed, managed_now)), (
            "SSE and JSON records of the manager route differ")
        _, observer_end, _ = manager_walk(observer)
        connection, response, first = route_open("/v1/routes", observer)
        try:
            _, entries = route_read(response, first, number(observer_end))
        finally:
            closing(connection, response)
        assert entries and all(set(entry) == {"id"} for entry in entries), ("the observe-only manager stream", entries[:2])
        assert entries[-1]["id"] == observer_end, ("the cursor block of the observe-only stream", entries[-1], observer_end)
        live_credential = issue("live")
        # A cursor alias belongs to the credential, so the live stream
        # attaches at the end cursor of its own credential.
        _, live_start, _ = manager_walk(live_credential)
        connection, response, first = route_open("/v1/routes", live_credential, live_start)
        try:
            attached = time.monotonic()
            assert first == b": heartbeat\n\n", ("the live manager stream starts with a heartbeat", first)
            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
            workflow = next(item for item in catalogue["items"] if item["name"] == "mixed-controls")
            body = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                    "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, draft, _ = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": key},
                                       method="POST", payload=json.dumps(body, separators=(",", ":")).encode())
            assert status == 201, ("live draft creation", status, draft.get("code"))
            posted = time.monotonic()
            live = frozen.parse_route_sse(route_block(response))
            arrived = time.monotonic()
        finally:
            closing(connection, response)
        live_records = records_of(live, "ManagerRouteRecord")
        assert live_records and live_records[0]["schema"] == "command" and live_records[0]["body"]["operation"] == "create", (
            "the first block after the heartbeat is the live create command", live)
        assert arrived - attached < 15, ("the live record came after the heartbeat interval", arrived - attached)
        live_command = live_records[0]
        polled_live, _, _ = manager_walk(live_credential, after=live_start)
        assert polled_live[:1] == [live_command], "the live record differs from its JSON batch"
        print(f"PASS routes case 17: SSE on the manager route delivered the {len(streamed_managed)} records of the JSON",
              f"batches, the observe-only stream carried cursor blocks only up to {number(observer_end)}, and the create",
              f"command at {live_command['position']} reached an open stream {arrived - posted:.2f} s after its POST",
              f"and {arrived - attached:.2f} s after the attaching heartbeat", flush=True)

        # Case 18. Route streams share the per-client reader quota of
        # /v1/events: with an event stream and a run-route stream open, a
        # manager-route stream and a third event stream of the same client
        # are refused as /v1/events refuses them.
        quota = issue("quota")
        status, snapshot, _ = request("/v1/snapshot", quota)
        assert status == 200
        _, quota_end, _ = walk(run, quota)
        held = [open_stream("/v1/events", quota | {"Last-Event-ID": snapshot["cursor"]})[:2],
                route_open(run_path, quota, quota_end)[:2]]
        try:
            status, refused_route, _ = request("/v1/routes", quota | {"Accept": "text/event-stream"})
            status_events, refused_events, _ = request("/v1/events", quota | {"Accept": "text/event-stream", "Last-Event-ID": snapshot["cursor"]})
        finally:
            for pair in held:
                closing(*pair)
        assert (status, refused_route["code"]) == (status_events, refused_events["code"]) == (429, "storage-quota"), (
            "the reader quota", status, refused_route.get("code"), status_events, refused_events.get("code"))
        print("PASS routes case 18: with one event stream and one run-route stream open, a manager-route stream and a",
              "third event stream of the same client both returned 429 storage-quota", flush=True)

        # Case 19. An ordinary shutdown ends open route streams at a block
        # boundary with a complete response.
        ending_credential = issue("shutdown")
        _, ending_run, _ = walk(run, ending_credential)
        _, ending_manager, _ = manager_walk(ending_credential)
        held = [route_open(run_path, ending_credential, ending_run), route_open("/v1/routes", ending_credential, ending_manager)]
        restart_cursor = live_command["id"]
        try:
            process.terminate()
            ending = time.monotonic()
            for connection, response, _ in held:
                tail = bytearray()
                while True:
                    try:
                        line = response.readline(16385)
                    except http.client.IncompleteRead:
                        line = b""
                    if not line:
                        break
                    tail.extend(line)
                    assert time.monotonic() < ending + 10, "a route stream did not end at the shutdown"
                assert tail.endswith(b"\n\n") or not tail, "a route stream ended inside a block"
                frozen.parse_route_sse(bytes(tail))
            ended = time.monotonic() - ending
        finally:
            for connection, response, _ in held:
                closing(connection, response)
        process.wait(timeout=25)
        exited = time.monotonic() - ending
    print(f"PASS routes case 19: an ordinary shutdown ended an open run-route stream and an open manager-route stream",
          f"completely after {ended:.1f} s, and the manager exited after {exited:.1f} s", flush=True)

    # Case 20. After an ordinary restart the stream alias is unchanged, and
    # cursors taken before the restart resume both route streams.
    with serving(4):
        status, capabilities, _ = request("/v1/capabilities", authorized)
        assert status == 200 and capabilities["streamId"] == stream_before, "the restart changed the stream alias"
        connection, response, first = route_open(run_path, authorized, served[middle]["id"])
        try:
            _, entries = route_read(response, first, number(served[-1]["id"]))
        finally:
            closing(connection, response)
        later = records_of(entries, "RouteRecord")
        assert len(later) == len(served) - middle - 1 and all(same_record(a, b) for a, b in zip(later, served[middle + 1:])), (
            "run-route resume after the restart")
        following, _, _ = manager_walk(live_credential, after=restart_cursor)
        assert following, "no manager record after the live command"
        connection, response, first = route_open("/v1/routes", live_credential, restart_cursor)
        try:
            _, entries = route_read(response, first, number(following[-1]["id"]))
        finally:
            closing(connection, response)
        resumed_managed = records_of(entries, "ManagerRouteRecord")
        assert len(resumed_managed) == len(following) and all(same_record(a, b) for a, b in zip(resumed_managed, following)), (
            "manager-route resume after the restart")
        assert resumed_managed[0]["schema"] == "receipt" and resumed_managed[0]["replyTo"] == live_command["position"], (
            "the first record after the live command is its receipt", resumed_managed[0]["schema"])
    print(f"PASS routes case 20: after an ordinary restart the streamId is unchanged, the run-route cursor of record",
          f"{middle} resumed with {len(later)} records, and the manager-route cursor of the live command resumed with",
          f"its receipt and {len(resumed_managed) - 1} later records", flush=True)
    print("PASS routes: every run-route and manager-route case held against the running TLS 1.3 manager", flush=True)


def capture_checks():
    """POST /v1/captures through the real HTTPS manager. Each numbered case
    prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    observer = {"Authorization": "Bearer " + (work / "credential-observe").read_bytes().decode("ascii")}
    # Raw UTF-8 with a BOM, CRLF, a trailing LF and multibyte code points,
    # longer than one 65536-byte upload chunk.
    line = "\ufeffCapture λ — café 雪\r\n".encode()
    content = line * (200000 // len(line)) + b"last line\n"

    def upload(credential, request_id, key, body):
        """One capture POST. Returns the status, the decoded body, the raw body and the headers."""
        connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=15)
        try:
            connection.request("POST", "/v1/captures?requestId=" + request_id, body=body,
                               headers=credential | {"Content-Type": "application/octet-stream", "Idempotency-Key": key})
            response = connection.getresponse()
            raw = response.read(1048577)
            assert len(raw) <= 1048576
            assert response.getheader("Cache-Control") == "no-store"
            assert response.getheader("X-Content-Type-Options") == "nosniff"
            value = frozen.parse_json(raw)
            if response.status >= 400:
                validate("Problem", value, raw)
            return response.status, value, raw, dict((name.lower(), text) for name, text in response.getheaders())
        finally:
            connection.close()

    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            status, capabilities, _ = request("/v1/capabilities", authorized)
            assert status == 200
            validate("Capabilities", capabilities)
            assert capabilities["limits"]["captureBytes"] == 67108864
            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
            assert status == 200
            workflow = next(item for item in catalogue["items"] if item["name"] == "captured-input")
            assert [item["name"] for item in workflow["inputs"]] == ["input"]
            create = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                      "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
            key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, created, raw = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": key},
                                           method="POST", payload=json.dumps(create, separators=(",", ":")).encode())
            assert status == 201, ("request creation", status, created.get("code"))
            validate("Request", created, raw)

            # Case 1. The capture receipt names the exact uploaded bytes.
            capture_key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, receipt, raw, headers = upload(authorized, created["id"], capture_key, content)
            assert status == 202, ("capture upload", status, receipt.get("code"))
            validate("CaptureReceipt", receipt, raw)
            (work / "capture-receipt.json").write_bytes(raw)
            assert receipt["requestId"] == created["id"] and receipt["profileId"] == "profile_1"
            assert receipt["bytes"] == str(len(content)) and receipt["sha256"] == hashlib.sha256(content).hexdigest(), (
                "capture receipt differs from the uploaded bytes", receipt["bytes"], receipt["sha256"])
            location = headers.get("location", "")
            assert location.startswith("/v1/commands/"), ("capture Location", location)
            status, command, raw = request(location, authorized)
            assert status == 200, ("capture command", status, command.get("code"))
            validate("CommandReceipt", command, raw)
            assert command["operation"] == "capture" and command["links"]["self"] == location, (command["operation"], command["links"])
            print("PASS captures case 1: POST /v1/captures returned 202 with a CaptureReceipt of", receipt["bytes"],
                  "bytes and SHA-256", receipt["sha256"], "equal to the uploaded bytes, and Location names its capture command", flush=True)

            # Case 2. A same-key replay returns the same receipt and command.
            status, replay, raw, replay_headers = upload(authorized, created["id"], capture_key, content)
            assert status == 202, ("capture replay", status, replay.get("code"))
            validate("CaptureReceipt", replay, raw)
            assert replay == receipt and replay_headers.get("location") == location, ("capture replay differs", replay, replay_headers.get("location"))
            print("PASS captures case 2: a same-key capture replay returned the same receipt", receipt["id"], "and the same command", flush=True)

            # Case 3. A credential without the submit scope is refused.
            other_key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            status, problem, _, _ = upload(observer, created["id"], other_key, b"observe only\n")
            assert status == 403 and problem["code"] == "insufficient-scope", ("observe-only capture", status, problem.get("code"))
            print("PASS captures case 3: a credential with observe only received 403 insufficient-scope", flush=True)

            # Case 4. The capture is the request input through the exact review.
            observed, wait_for, mutate, _ = mixed_client(capabilities, authorized)
            request_uri = created["links"]["self"]
            current, tag, _ = observed(request_uri, "Request")
            mutate(request_uri, {"operation": "set-input", "input": {"name": "input", "source": "capture", "captureId": receipt["id"]}}, tag)
            current, tag, raw = observed(request_uri, "Request")
            (work / "capture-request.json").write_bytes(raw)
            assert not current["readiness"]["missing"] and not current["readiness"]["errors"], current["readiness"]
            assert current["readiness"]["supplied"] == [{"name": "input", "source": "capture", "captureId": receipt["id"]}], current["readiness"]["supplied"]
            mutate(request_uri, {"operation": "enqueue"}, tag)
            current, _, _ = wait_for(request_uri, "Request", lambda value: value["preparationId"] is not None)
            preparation, tag, raw = observed("/v1/preparations/" + current["preparationId"], "Preparation")
            (work / "capture-review.json").write_bytes(raw)
            assert preparation["state"] == "live"
            assert preparation["review"]["inputs"] == [{"name": "input", "source": "capture", "bytes": receipt["bytes"], "sha256": receipt["sha256"]}], (
                "exact review of the capture", preparation["review"]["inputs"])
            print("PASS captures case 4: set-input bound the capture, and the exact review names the input as capture with the receipt size and digest", flush=True)

            # Case 5. Approval starts the run, and the program receives the capture.
            selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")
            mutate("/v1/preparations/" + preparation["id"], {"operation": "approve", **{name: preparation[name] for name in selectors}}, tag)
            current, _, _ = wait_for(request_uri, "Request", lambda value: value["runId"] is not None)
            run = current["runId"]
            snapshot, _, raw = wait_for("/v1/runs/" + run + "/snapshot", "RunSnapshot",
                lambda value: value["runtime"] is not None and value["runtime"]["status"] in ("succeeded", "failed", "cancelled"))
            (work / "capture-terminal-snapshot.json").write_bytes(raw)
            assert snapshot["runtime"]["status"] == "succeeded", ("capture run terminal status", snapshot["runtime"]["status"])
            answer_files = sorted(work.glob("manager/runs/runs/*/runtime/answers.json"))
            assert len(answer_files) == 1, ("capture run store answers", answer_files)
            prompts = [entry["question"].get("prompt") for entry in json.loads(answer_files[0].read_bytes())["answers"]]
            assert "fixed-point source: " + hashlib.sha256(content).hexdigest() in prompts, ("the program did not receive the captured bytes", prompts)
            print("PASS captures case 5: approval started run", run, "which succeeded, and its program received the SHA-256 of the captured bytes", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")
    print("PASS mutations-captures: every capture case held against the running TLS 1.3 manager", flush=True)


def discard_checks():
    """The discard operation of POST /v1/preparations/{id} through the real
    HTTPS manager. Each numbered case prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    observer = {"Authorization": "Bearer " + (work / "credential-observe").read_bytes().decode("ascii")}
    discard_body = json.dumps({"operation": "discard"}, separators=(",", ":")).encode()

    def discard(credential, preparation_id, key, tag):
        """One discard POST. Returns the status, the decoded body and the raw body."""
        headers = credential | {"Content-Type": "application/json", "Idempotency-Key": key, "If-Match": tag}
        status, value, raw, _ = exchange("/v1/preparations/" + preparation_id, headers, method="POST", payload=discard_body)
        validate("Problem" if status >= 400 else "CommandReceipt", value, raw)
        return status, value, raw

    def settled(path, schema, ready, failure):
        """Read the resource until ready holds, within a deadline."""
        deadline = time.monotonic() + 40
        while True:
            value, tag, raw = observed(path, schema)
            if ready(value):
                return value, tag, raw
            if time.monotonic() >= deadline:
                (work / "discard-wait-last.json").write_bytes(raw)
                raise AssertionError(failure)
            time.sleep(0.05)

    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            status, capabilities, _ = request("/v1/capabilities", authorized)
            assert status == 200
            validate("Capabilities", capabilities)
            new_key = lambda: capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            observed, wait_for, mutate, _ = mixed_client(capabilities, authorized)
            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
            assert status == 200
            workflow = next(item for item in catalogue["items"] if item["name"] == "prompt-source")
            assert [item["name"] for item in workflow["inputs"]] == ["input"]
            create = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                      "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
            status, created, raw = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": new_key()},
                                           method="POST", payload=json.dumps(create, separators=(",", ":")).encode())
            assert status == 201, ("request creation", status, created.get("code"))
            validate("Request", created, raw)
            request_uri = created["links"]["self"]
            current, tag, _ = observed(request_uri, "Request")
            mutate(request_uri, {"operation": "set-input", "input": {"name": "input", "source": "literal", "value": "Discard fixture input."}}, tag)
            current, tag, _ = observed(request_uri, "Request")
            mutate(request_uri, {"operation": "enqueue"}, tag)
            current, _, _ = wait_for(request_uri, "Request", lambda value: value["preparationId"] is not None)
            first, first_tag, raw = observed("/v1/preparations/" + current["preparationId"], "Preparation")
            (work / "discard-review.json").write_bytes(raw)
            assert first["state"] == "live" and first["reason"] is None and current["phase"] == "review", (first["state"], current["phase"])
            first_uri = "/v1/preparations/" + first["id"]

            # Case 1. A stale If-Match refuses and changes nothing.
            status, problem, _ = discard(authorized, first["id"], new_key(), '"' + current["revision"] + '"')
            assert status == 412 and problem["code"] == "stale-revision", ("stale discard", status, problem.get("code"))
            still, still_tag, _ = observed(first_uri, "Preparation")
            assert still["state"] == "live" and still_tag == first_tag, ("stale discard changed the preparation", still["state"])
            print("PASS discard case 1: a discard with a stale If-Match received 412 stale-revision, and the preparation stayed live", flush=True)

            # Case 2. A credential without submit and control is refused.
            status, problem, _ = discard(observer, first["id"], new_key(), first_tag)
            assert status == 403 and problem["code"] == "insufficient-scope", ("observe-only discard", status, problem.get("code"))
            still, still_tag, _ = observed(first_uri, "Preparation")
            assert still["state"] == "live" and still_tag == first_tag, ("observe-only discard changed the preparation", still["state"])
            print("PASS discard case 2: a credential with observe only received 403 insufficient-scope, and the preparation stayed live", flush=True)

            # Case 3. The discard ends the review as discarded and returns the request to draft.
            discard_key = new_key()
            status, receipt, raw = discard(authorized, first["id"], discard_key, first_tag)
            assert status == 202, ("discard", status, receipt.get("code"))
            (work / "discard-receipt.json").write_bytes(raw)
            assert receipt["operation"] == "discard" and receipt["resource"] == first_uri, (receipt["operation"], receipt["resource"])
            command_uri = receipt["links"]["self"]
            command, _, raw = settled(command_uri, "CommandReceipt",
                lambda value: value["state"] in ("effect-observed", "refused", "unresolved"), "discard command deadline")
            (work / "discard-command.json").write_bytes(raw)
            assert command["state"] == "effect-observed", ("discard command", command["state"], command.get("refusal"))
            assert command["effect"]["kind"] == "discarded" and command["effect"]["resource"] == request_uri, command["effect"]
            ended, _, raw = observed(first_uri, "Preparation")
            (work / "discard-preparation.json").write_bytes(raw)
            assert ended["state"] == "invalidated" and ended["reason"] == "discarded", (ended["state"], ended["reason"])
            current, tag, raw = settled(request_uri, "Request", lambda value: value["phase"] == "draft", "request did not return to draft")
            (work / "discard-request.json").write_bytes(raw)
            assert current["admission"]["state"] == "released" and current["preparationId"] is None and current["runId"] is None, (
                current["admission"], current["preparationId"], current["runId"])
            print("PASS discard case 3: discard command", receipt["id"], "reached effect-observed with the effect discarded,",
                  "preparation", first["id"], "shows invalidated with the reason discarded, and the request returned to draft",
                  "with admission released and a null preparationId", flush=True)

            # Case 4. A same-key replay returns the same receipt.
            status, replay, _ = discard(authorized, first["id"], discard_key, first_tag)
            assert status == 202 and replay["id"] == receipt["id"] and replay["links"]["self"] == command_uri, (
                "discard replay", status, replay.get("id"), replay.get("code"))
            print("PASS discard case 4: a same-key discard replay returned the same receipt", receipt["id"], flush=True)

            # Case 5. A later enqueue of the draft publishes a fresh review.
            mutate(request_uri, {"operation": "enqueue"}, tag)
            current, _, _ = wait_for(request_uri, "Request",
                lambda value: value["phase"] == "review" and value["preparationId"] not in (None, first["id"]))
            second, second_tag, _ = observed("/v1/preparations/" + current["preparationId"], "Preparation")
            assert second["state"] == "live" and second["id"] != first["id"], (second["state"], second["id"])
            print("PASS discard case 5: a later enqueue of the draft published the fresh review", second["id"], flush=True)

            # Case 6. A discard after approval refuses with state-conflict.
            selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")
            mutate("/v1/preparations/" + second["id"], {"operation": "approve", **{name: second[name] for name in selectors}}, second_tag)
            current, _, _ = wait_for(request_uri, "Request", lambda value: value["runId"] is not None)
            consumed, consumed_tag, _ = observed("/v1/preparations/" + second["id"], "Preparation")
            assert consumed["state"] == "consumed", consumed["state"]
            status, problem, _ = discard(authorized, second["id"], new_key(), consumed_tag)
            assert status == 409 and problem["code"] == "state-conflict", ("discard after approval", status, problem.get("code"))
            _, ended_tag, _ = observed(first_uri, "Preparation")
            status, problem, _ = discard(authorized, first["id"], new_key(), ended_tag)
            assert status == 409 and problem["code"] == "state-conflict", ("discard of a discarded preparation", status, problem.get("code"))
            snapshot, _, _ = wait_for("/v1/runs/" + current["runId"] + "/snapshot", "RunSnapshot",
                lambda value: value["runtime"] is not None and value["runtime"]["status"] in ("succeeded", "failed", "cancelled"))
            assert snapshot["runtime"]["status"] == "succeeded", snapshot["runtime"]["status"]
            print("PASS discard case 6: a discard after approval and a new-key discard of the discarded preparation received",
                  "409 state-conflict, and run", current["runId"], "succeeded", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")

    # Case 7. The manager log records the discard command, its receipt, the
    # discard relay and the review and request endings.
    flow_dir = work / "manager" / "flow"
    stores = sorted(work.glob("manager/runs/runs/*/runtime"))
    completed = subprocess.run([str(runner), "flow", str(flow_dir)] + [str(store) for store in stores],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    (work / "discard-flow.ndjson").write_bytes(completed.stdout)
    (work / "discard-flow.stderr").write_bytes(completed.stderr)
    lines = [json.loads(line) for line in completed.stdout.splitlines()]
    assert lines and "summary" in lines[-1], ("flow verb", completed.returncode, completed.stderr[-2000:])
    summary = lines[-1]["summary"]
    assert completed.returncode == 0 and summary["verified"] and not summary["problems"], ("flow verb", completed.returncode, summary["problems"])
    logs = sorted(flow_dir.glob("*.ndjson"))
    assert len(logs) == 1, logs
    manager = [line for line in lines[:-1] if line["log"] == str(logs[0])]
    commands = [line for line in manager if line["schema"] == "command" and line["about"].get("command") == receipt["id"]]
    assert len(commands) == 1 and commands[0]["body"]["operation"] == "discard" and commands[0]["body"]["resource"] == first_uri, (
        "discard command record", [line["body"] for line in commands])
    logged = commands[0]
    replies = [line for line in manager if line["schema"] == "receipt" and line["replyTo"] == logged["position"]]
    assert len(replies) == 1 and replies[0]["body"]["id"] == receipt["id"] and replies[0]["body"]["operation"] == "discard", "discard receipt record"
    relays = [line for line in manager if line["schema"] == "relay" and line["body"]["kind"] == "discard"
              and line["about"].get("command") == receipt["id"]]
    assert len(relays) == 1 and relays[0]["body"]["command"] == receipt["id"] and relays[0]["body"]["managerRun"] is None, (
        "discard relay record", [line["body"] for line in relays])
    notices = [line for line in manager if line["schema"] == "notice" and isinstance(line.get("body"), dict)]
    review_endings = [line for line in notices if line["body"].get("notice") == "review-ended" and line["body"]["preparation"] == first["id"]]
    assert len(review_endings) == 1 and review_endings[0]["body"]["reason"] == "discarded", ("review ending", [line["body"] for line in review_endings])
    request_endings = [line for line in notices if line["body"].get("notice") == "request-ended" and line["body"]["request"] == created["id"]]
    assert len(request_endings) == 1 and request_endings[0]["body"]["cause"] == "discarded" and request_endings[0]["about"].get("command") == receipt["id"], (
        "request ending", [(line["body"], line["about"]) for line in request_endings])
    assert logged["position"] < replies[0]["position"] < relays[0]["position"] < request_endings[0]["position"], (
        "manager-log order", logged["position"], replies[0]["position"], relays[0]["position"], request_endings[0]["position"])
    reviews = [item for item in summary["joins"]["reviews"] if item["preparation"] == first["id"]]
    assert len(reviews) == 1 and reviews[0]["commands"] == [logged["position"]] and reviews[0]["endings"] == [review_endings[0]["position"]], (
        "review join", reviews)
    print("PASS discard case 7: the manager log holds discard command", receipt["id"], "at position", logged["position"],
          "its receipt at", replies[0]["position"], "the discard relay that names it at", relays[0]["position"],
          "the review ending discarded at", review_endings[0]["position"], "and the request ending discarded at",
          request_endings[0]["position"], "and the flow verb joins the review to the command and the ending", flush=True)
    print("PASS mutations-discard: every discard case held against the running TLS 1.3 manager", flush=True)


if discard_mode:
    discard_checks()
    raise SystemExit(0)


def export_checks():
    """POST /v1/runs/{id}/exports through the real HTTPS manager. Each
    numbered case prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    name = "c14-export.json"
    body = json.dumps({"name": name}, separators=(",", ":")).encode()

    def export(run, key, tag, payload=body):
        """One export POST. Returns the status, the decoded body, the raw body and the headers."""
        headers = authorized | {"Content-Type": "application/json", "Idempotency-Key": key, "If-Match": tag}
        status, value, raw, received = exchange("/v1/runs/" + run + "/exports", headers, method="POST", payload=payload)
        validate("Problem" if status >= 400 else "CommandReceipt", value, raw)
        return status, value, raw, received

    def collection(run):
        """The first page of the export collection of the run and its ETag."""
        status, value, raw, received = fetch("/v1/runs/" + run + "/exports", authorized)
        assert status == 200, ("export collection", status, value.get("code"))
        validate("ExportPage", value, raw)
        assert value["runId"] == run and value["page"]["next"] is None, ("export collection page", value["page"])
        tag = received.get("etag")
        assert tag == '"' + value["page"]["revision"] + '"', ("export collection ETag", tag, value["page"]["revision"])
        return value, tag, raw

    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            status, capabilities, _ = request("/v1/capabilities", authorized)
            assert status == 200
            validate("Capabilities", capabilities)
            assert "export" in capabilities["scopes"], capabilities["scopes"]
            new_key = lambda: capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            observed, wait_for, mutate, _ = mixed_client(capabilities, authorized)
            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
            assert status == 200
            workflow = next(item for item in catalogue["items"] if item["name"] == "prompt-source")
            create = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                      "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
            status, created, raw = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": new_key()},
                                           method="POST", payload=json.dumps(create, separators=(",", ":")).encode())
            assert status == 201, ("request creation", status, created.get("code"))
            validate("Request", created, raw)
            request_uri = created["links"]["self"]
            current, tag, _ = observed(request_uri, "Request")
            mutate(request_uri, {"operation": "set-input", "input": {"name": "input", "source": "literal", "value": "Export fixture input."}}, tag)
            current, tag, _ = observed(request_uri, "Request")
            mutate(request_uri, {"operation": "enqueue"}, tag)
            current, _, _ = wait_for(request_uri, "Request", lambda value: value["preparationId"] is not None)
            preparation, tag, _ = observed("/v1/preparations/" + current["preparationId"], "Preparation")
            selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")
            mutate("/v1/preparations/" + preparation["id"], {"operation": "approve", **{item: preparation[item] for item in selectors}}, tag)
            current, _, _ = wait_for(request_uri, "Request", lambda value: value["runId"] is not None)
            run = current["runId"]
            snapshot, _, _ = wait_for("/v1/runs/" + run + "/snapshot", "RunSnapshot",
                lambda value: value["runtime"] is not None and value["runtime"]["status"] in ("succeeded", "failed", "cancelled"))
            assert snapshot["runtime"]["status"] == "succeeded", snapshot["runtime"]["status"]
            # The release of the worker after the terminal status changes the
            # supervision of the run and with it the collection revision, so
            # the export waits until the supervision settles.
            wait_for("/v1/runs/" + run, "Run", lambda value: value["supervision"] not in ("owned", "cleanup-pending"))
            before, before_tag, raw = collection(run)
            (work / "exports-before.json").write_bytes(raw)
            assert before["items"] == [] and before["page"]["totalItems"] == 0, before["items"]

            # Case 1. The export is accepted, published and downloadable.
            export_key = new_key()
            status, receipt, raw, headers = export(run, export_key, before_tag)
            assert status == 202, ("export", status, receipt.get("code"))
            (work / "export-receipt.json").write_bytes(raw)
            collection_uri = "/v1/runs/" + run + "/exports"
            assert receipt["operation"] == "export" and receipt["resource"] == collection_uri, (receipt["operation"], receipt["resource"])
            assert headers.get("location") == "/v1/commands/" + receipt["id"], ("export Location", headers.get("location"))
            command, _, raw = wait_for(receipt["links"]["self"], "CommandReceipt",
                lambda value: value["state"] in ("effect-observed", "refused", "unresolved"))
            (work / "export-command.json").write_bytes(raw)
            export_uri = "/v1/exports/export_" + receipt["id"]
            assert command["state"] == "effect-observed", ("export command", command["state"], command.get("refusal"))
            assert command["effect"]["kind"] == "exported" and command["effect"]["resource"] == export_uri, command["effect"]
            detail, _, raw = observed(export_uri, "ExportReceipt")
            (work / "export-detail.json").write_bytes(raw)
            assert detail["state"] == "published" and detail["name"] == name and detail["runId"] == run, (detail["state"], detail["name"])
            assert detail["commandId"] == receipt["id"] and detail["download"] is not None, (detail["commandId"], detail["download"])
            after, after_tag, raw = collection(run)
            (work / "exports-after.json").write_bytes(raw)
            assert after["items"] == [detail] and after_tag != before_tag, ("export collection after the export", after["items"])
            connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=15)
            try:
                connection.request("GET", detail["download"], headers=authorized | {"Accept": "application/octet-stream"})
                response = connection.getresponse()
                downloaded = response.read(int(detail["bytes"]) + 1)
                assert response.status == 200 and response.getheader("Content-Type") == "application/octet-stream", (
                    "export download", response.status)
            finally:
                connection.close()
            (work / "export-download.bin").write_bytes(downloaded)
            published = work / "manager" / "runs" / "exports" / name
            assert len(downloaded) == int(detail["bytes"]) and hashlib.sha256(downloaded).hexdigest() == detail["sha256"], (
                "export download differs from its receipt", len(downloaded), detail["bytes"])
            assert published.read_bytes() == downloaded, "export download differs from the published file"
            print("PASS exports case 1: export command", receipt["id"], "of run", run, "reached effect-observed with the effect exported,",
                  "the collection and", export_uri, "show it published, and", detail["download"], "returned", detail["bytes"],
                  "bytes with SHA-256", detail["sha256"], "equal to the receipt and to the published file", flush=True)

            # Case 2. A same-key replay returns the same receipt.
            status, replay, _, replay_headers = export(run, export_key, before_tag)
            assert status == 202 and replay["id"] == receipt["id"] and replay_headers.get("location") == headers.get("location"), (
                "export replay", status, replay.get("id"), replay.get("code"))
            again, again_tag, raw = collection(run)
            (work / "exports-replay.json").write_bytes(raw)
            assert again["items"] == [detail] and again_tag == after_tag, ("the replay changed the export collection", again_tag, after_tag)
            print("PASS exports case 2: a same-key export replay returned the same receipt", receipt["id"],
                  "and Location, and the collection kept one export", flush=True)

            # Case 3. The stale collection ETag refuses.
            other = json.dumps({"name": "c14-stale.json"}, separators=(",", ":")).encode()
            status, problem, _, _ = export(run, new_key(), before_tag, other)
            assert status == 412 and problem["code"] == "stale-revision", ("stale export", status, problem.get("code"))
            again, again_tag, _ = collection(run)
            assert again["items"] == [detail] and again_tag == after_tag, "the stale export changed the export collection"
            assert not (work / "manager" / "runs" / "exports" / "c14-stale.json").exists(), "the stale export published a file"
            print("PASS exports case 3: an export with the collection ETag from before the first export received",
                  "412 stale-revision, and the collection kept one export", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")
    print("PASS mutations-exports: every export case held against the running TLS 1.3 manager", flush=True)


def lineage_checks():
    """POST /v1/runs/{id}/lineage-requests through the real HTTPS manager.
    Each numbered case prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    # The typed answers of the three person questions of lineage-typed, by
    # occurrence. Occurrence 0 is the scripted model question.
    answers = {"1": False, "2": None, "3": {"ok": False, "notes": []}}

    def lineage(run, key, tag, body):
        """One lineage POST. Returns the status, the decoded body, the raw body and the headers."""
        payload = json.dumps(body, separators=(",", ":")).encode()
        headers = authorized | {"Content-Type": "application/json", "Idempotency-Key": key, "If-Match": tag}
        status, value, raw, received = exchange("/v1/runs/" + run + "/lineage-requests", headers, method="POST", payload=payload)
        validate("Problem" if status >= 400 else "CommandReceipt", value, raw)
        return status, value, raw, received

    def collection(run):
        """The first page of the lineage collection of the run and its ETag."""
        status, value, raw, received = fetch("/v1/runs/" + run + "/lineage-requests", authorized)
        assert status == 200, ("lineage collection", status, value.get("code"))
        validate("LineagePage", value, raw)
        assert value["runId"] == run and value["page"]["next"] is None, ("lineage collection page", value["page"])
        tag = received.get("etag")
        assert tag == '"' + value["page"]["revision"] + '"', ("lineage collection ETag", tag, value["page"]["revision"])
        return value, tag, raw

    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            status, capabilities, _ = request("/v1/capabilities", authorized)
            assert status == 200
            validate("Capabilities", capabilities)
            new_key = lambda: capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
            observed, wait_for, mutate, _ = mixed_client(capabilities, authorized)
            selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")

            def review(request_uri, name):
                """Enqueue the draft and return its live preparation and ETag."""
                current, tag, _ = observed(request_uri, "Request")
                mutate(request_uri, {"operation": "enqueue"}, tag)
                current, _, _ = wait_for(request_uri, "Request", lambda value: value["preparationId"] is not None)
                preparation, tag, raw = observed("/v1/preparations/" + current["preparationId"], "Preparation")
                (work / (name + "-review.json")).write_bytes(raw)
                assert preparation["state"] == "live", (name, preparation["state"])
                return preparation, tag

            def run_to_success(request_uri, preparation, tag, name):
                """Approve the preparation, answer every question of the run and
                return the run after its terminal success and settled supervision."""
                mutate("/v1/preparations/" + preparation["id"], {"operation": "approve", **{item: preparation[item] for item in selectors}}, tag)
                current, _, _ = wait_for(request_uri, "Request", lambda value: value["runId"] is not None)
                run = current["runId"]
                base = "/v1/runs/" + run
                deadline = time.monotonic() + 60
                while True:
                    snapshot, _, raw = observed(base + "/snapshot", "RunSnapshot")
                    runtime = snapshot["runtime"]
                    if runtime is not None and runtime["status"] in ("succeeded", "failed", "cancelled"):
                        (work / (name + "-terminal.json")).write_bytes(raw)
                        assert runtime["status"] == "succeeded", (name, runtime["status"])
                        break
                    assert time.monotonic() < deadline, (name, "terminal deadline")
                    control, _, _ = observed(base + "/control", "RunControl")
                    head = control["decisionHeadId"]
                    if head is None:
                        time.sleep(0.05)
                        continue
                    decision, decision_tag, _ = observed("/v1/decisions/" + head, "Decision")
                    occurrence = decision["address"]["occurrenceId"]
                    assert decision["kind"] == "question" and occurrence in answers, (name, decision["kind"], occurrence)
                    mutate("/v1/decisions/" + head, {"operation": "answer", "occurrenceId": occurrence,
                                                      "generation": decision["generation"], "value": answers[occurrence]}, decision_tag)
                wait_for(request_uri, "Request", lambda value: value["admission"]["state"] == "released")
                value, _, _ = wait_for(base, "Run", lambda value: value["supervision"] not in ("owned", "cleanup-pending"))
                return value

            def create_child(run, tag, body, name):
                """One accepted lineage request. Returns the key, receipt, headers and child request."""
                key = new_key()
                status, receipt, raw, headers = lineage(run, key, tag, body)
                assert status == 202, (name, status, receipt.get("code"))
                (work / (name + "-receipt.json")).write_bytes(raw)
                assert receipt["operation"] == body["operation"] and receipt["resource"] == "/v1/runs/" + run + "/lineage-requests", (
                    name, receipt["operation"], receipt["resource"])
                assert headers.get("location") == "/v1/commands/" + receipt["id"], (name, headers.get("location"))
                command, _, raw = wait_for(receipt["links"]["self"], "CommandReceipt",
                    lambda value: value["state"] in ("effect-observed", "refused", "unresolved"))
                (work / (name + "-command.json")).write_bytes(raw)
                assert command["state"] == "effect-observed" and command["effect"]["kind"] == "lineage-created", (
                    name, command["state"], command.get("effect"), command.get("refusal"))
                child, _, raw = observed(command["effect"]["resource"], "Request")
                (work / (name + "-child.json")).write_bytes(raw)
                assert child["parentRunId"] == run and child["lineage"] == body["operation"] and child["phase"] == "draft", (
                    name, child["parentRunId"], child["lineage"], child["phase"])
                return key, receipt, headers, child

            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
            assert status == 200
            workflow = next(item for item in catalogue["items"] if item["name"] == "lineage-typed")
            create = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                      "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
            status, created, raw = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": new_key()},
                                           method="POST", payload=json.dumps(create, separators=(",", ":")).encode())
            assert status == 201, ("request creation", status, created.get("code"))
            validate("Request", created, raw)
            request_uri = created["links"]["self"]
            current, tag, _ = observed(request_uri, "Request")
            mutate(request_uri, {"operation": "set-input", "input": {"name": "input", "source": "literal", "value": "Lineage fixture input."}}, tag)
            preparation, tag = review(request_uri, "parent")
            assert "lineage" not in preparation["review"], "a root review has a lineage"
            parent = run_to_success(request_uri, preparation, tag, "parent")
            run = parent["id"]
            before, before_tag, raw = collection(run)
            (work / "lineage-before.json").write_bytes(raw)
            assert before["items"] == [] and before["eligible"] == ["restart", "resume", "fork"] and before["refusal"] is None, (
                "lineage collection before the first request", before["items"], before["eligible"], before["refusal"])

            # Case 1. A restart creates a child request that names the parent,
            # and the approved child runs to success.
            restart_key, receipt, headers, child = create_child(run, before_tag, {"operation": "restart"}, "restart")
            after, after_tag, raw = collection(run)
            (work / "lineage-after.json").write_bytes(raw)
            assert [item["id"] for item in after["items"]] == [child["id"]] and after_tag != before_tag, (
                "lineage collection after the restart", [item["id"] for item in after["items"]])
            requests, _, raw = observed("/v1/requests", "RequestPage")
            (work / "requests-after.json").write_bytes(raw)
            listed = [item for item in requests["items"] if item["id"] == child["id"]]
            assert len(listed) == 1 and listed[0]["parentRunId"] == run and listed[0]["lineage"] == "restart", ("/v1/requests child", listed)
            child_uri = child["links"]["self"]
            preparation, tag = review(child_uri, "restart")
            assert preparation["review"].get("lineage") == {"parentRunId": run, "operation": "restart", "edits": []}, (
                "restart review lineage", preparation["review"].get("lineage"))
            restarted = run_to_success(child_uri, preparation, tag, "restart")
            assert restarted["parentRunId"] == run and restarted["lineage"] == "restart" and restarted["id"] != run, (
                "restarted run", restarted["parentRunId"], restarted["lineage"])
            print("PASS lineage case 1: restart command", receipt["id"], "of run", run, "created request", child["id"],
                  "that names the parent in its detail, /v1/requests, the lineage collection and its review lineage, and its approved run",
                  restarted["id"], "answered three questions and succeeded", flush=True)

            # Case 2. A same-key replay returns the same receipt.
            status, replay, _, replay_headers = lineage(run, restart_key, before_tag, {"operation": "restart"})
            assert status == 202 and replay["id"] == receipt["id"] and replay_headers.get("location") == headers.get("location"), (
                "lineage replay", status, replay.get("id"), replay.get("code"))
            again, again_tag, raw = collection(run)
            (work / "lineage-replay.json").write_bytes(raw)
            assert [item["id"] for item in again["items"]] == [child["id"]], ("the replay changed the lineage collection", again["items"])
            print("PASS lineage case 2: a same-key restart replay returned the same receipt", receipt["id"],
                  "and Location, and the collection kept one child", flush=True)

            # Case 3. The stale collection ETag refuses.
            status, problem, _, _ = lineage(run, new_key(), before_tag, {"operation": "restart"})
            assert status == 412 and problem["code"] == "stale-revision", ("stale lineage request", status, problem.get("code"))
            again, again_tag, _ = collection(run)
            assert [item["id"] for item in again["items"]] == [child["id"]], "the stale lineage request changed the collection"
            print("PASS lineage case 3: a restart with the collection ETag from before the first request received",
                  "412 stale-revision, and the collection kept one child", flush=True)

            # Case 4. A resume creates a child whose review names the parent.
            _, resume_receipt, _, resumed = create_child(run, again_tag, {"operation": "resume"}, "resume")
            preparation, tag = review(resumed["links"]["self"], "resume")
            assert preparation["review"].get("lineage") == {"parentRunId": run, "operation": "resume", "edits": []}, (
                "resume review lineage", preparation["review"].get("lineage"))
            discard = json.dumps({"operation": "discard"}, separators=(",", ":")).encode()
            status, discarded, _, _ = exchange("/v1/preparations/" + preparation["id"],
                authorized | {"Content-Type": "application/json", "Idempotency-Key": new_key(), "If-Match": tag},
                method="POST", payload=discard)
            assert status == 202, ("resume discard", status, discarded.get("code"))
            wait_for(resumed["links"]["self"], "Request", lambda value: value["phase"] == "draft" and value["admission"]["state"] == "released")
            print("PASS lineage case 4: resume command", resume_receipt["id"], "created request", resumed["id"],
                  "whose review names the parent", run, "with the operation resume", flush=True)

            # Case 5. A fork with an answer replacement reaches the child review.
            _, current_tag, _ = collection(run)
            edits = [{"occurrenceId": "1", "operation": "replace", "answer": True}]
            _, fork_receipt, _, forked = create_child(run, current_tag, {"operation": "fork", "edits": edits}, "fork")
            preparation, _ = review(forked["links"]["self"], "fork")
            shown = preparation["review"].get("lineage")
            assert shown is not None and shown["parentRunId"] == run and shown["operation"] == "fork", ("fork review lineage", shown)
            assert [(edit["operation"], edit["occurrenceId"]) for edit in shown["edits"]] == [("replace", "1")] and re.fullmatch(
                "[0-9a-f]{64}", shown["edits"][0]["sha256"]), ("fork review edits", shown["edits"])
            final, _, raw = collection(run)
            (work / "lineage-final.json").write_bytes(raw)
            assert [item["id"] for item in final["items"]] == sorted([child["id"], resumed["id"], forked["id"]]), (
                "final lineage collection", [item["id"] for item in final["items"]])
            print("PASS lineage case 5: fork command", fork_receipt["id"], "with a replacement of occurrence 1 created request",
                  forked["id"], "whose review names the parent", run, "and the replaced occurrence", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")
    print("PASS mutations-lineage: every lineage case held against the running TLS 1.3 manager", flush=True)


def control_checks():
    """Cancel, steer, retry, abandon and answer through POST
    /v1/runs/{id}/control and POST /v1/decisions/{id} of the real HTTPS
    manager. Each numbered case prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    peer = {"Authorization": "Bearer " + (work / "credential-peer").read_bytes().decode("ascii")}
    terminal = ("succeeded", "failed", "cancelled")
    # The live-redirect cases leave here the facts that the joined flow check
    # reads after the manager exits.
    live_facts = {}

    def post(path, credential, capabilities, body, tag):
        """One control POST. Returns the status and the decoded body."""
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        payload = json.dumps(body, separators=(",", ":")).encode()
        headers = credential | {"Content-Type": "application/json", "Idempotency-Key": key, "If-Match": tag}
        status, value, raw, _ = exchange(path, headers, method="POST", payload=payload)
        validate("Problem" if status >= 400 else "CommandReceipt", value, raw)
        return status, value

    def start(client, capabilities, profile, name="mixed-controls"):
        """Create, enqueue and approve one request of the named workflow of
        the profile. Returns the run."""
        credential = client[3]
        status, catalogue, _ = request("/v1/workflows?profileId=" + profile, credential)
        assert status == 200, ("control catalogue", profile, status)
        workflow = next(item for item in catalogue["items"] if item["name"] == name)
        create = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                  "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        status, created, raw = request("/v1/requests", credential | {"Content-Type": "application/json", "Idempotency-Key": key},
                                       method="POST", payload=json.dumps(create, separators=(",", ":")).encode())
        assert status == 201, ("control request creation", profile, status, created.get("code"))
        validate("Request", created, raw)
        _, run = approve_mixed(created, workflow, client)
        return run

    def run_records(run, credential):
        """Every run-log route record of the run that the credential receives."""
        records, cursor = [], None
        for _ in range(1024):
            target = f"/v1/runs/{run}/routes" + ("" if cursor is None else "?after=" + cursor)
            status, value, raw = request(target, credential | {"Accept": "application/json"})
            assert status == 200, ("run route batch", run, status, value.get("code"))
            validate("RouteBatch", value, raw)
            records += value["records"]
            cursor = value["cursor"]
            if not value["hasMore"]:
                return records
        raise AssertionError(("run route pages did not end", run))

    def ended(client, run, expected):
        """Wait for the terminal runtime status of the run and require the expected one."""
        snapshot, _, raw = client[1](f"/v1/runs/{run}/snapshot", "RunSnapshot",
            lambda value: value["runtime"] is not None and value["runtime"]["status"] in terminal)
        (work / f"control-{run}-terminal.json").write_bytes(raw)
        assert snapshot["runtime"]["status"] == expected, ("control run terminal status", run, snapshot["runtime"]["status"], expected)

    def effect(client, receipt_uri, kind):
        """The effect-observed receipt of a control command with the effect kind."""
        command, _, raw = client[0](receipt_uri, "CommandReceipt")
        assert command["state"] == "effect-observed" and command["effect"]["kind"] == kind, (
            "control effect", receipt_uri, command["state"], command["effect"])
        return command

    def queue(client, run):
        """The identifiers of the pending FIFO queue of the run, in order."""
        page, _, _ = client[0]("/v1/decisions?runId=" + run, "DecisionPage")
        return [item["id"] for item in page["items"]]

    def act(client, capabilities, run, head, choice):
        """Act on the head decision of the run. A question receives typed
        false through the decision. A recovery receives retry through the
        run control, or choose-recovery with the choice through the
        decision. Returns the receipt URI and the expected effect kind."""
        observed, _, mutate, _ = client
        decision, decision_tag, _ = observed("/v1/decisions/" + head, "Decision")
        assert decision["position"] == 0 and decision["state"] == "pending" and decision["runId"] == run, (
            "control head", head, decision["position"], decision["state"])
        body = {"occurrenceId": decision["address"]["occurrenceId"], "generation": decision["generation"]}
        if decision["kind"] == "question":
            return mutate("/v1/decisions/" + head, dict(body, operation="answer", value=False), decision_tag), "answer-accepted"
        control, control_tag, _ = observed(f"/v1/runs/{run}/control", "RunControl")
        assert control["decisionHeadId"] == head, ("control head moved", control["decisionHeadId"], head)
        if choice == "retry":
            assert any(offer["operation"] == "retry" and offer["generation"] == decision["generation"]
                       and offer["address"] == decision["address"] for offer in control["offers"]), ("retry not offered", control["offers"])
            return mutate(f"/v1/runs/{run}/control", dict(body, operation="retry"), control_tag), "retried"
        assert any(offer["operation"] == "choose-recovery" and offer["generation"] == decision["generation"]
                   and any(item["choice"] == choice for item in offer["choices"]) for offer in control["offers"]), (
            "recovery choice not offered", choice, control["offers"])
        return mutate("/v1/decisions/" + head, dict(body, operation="choose-recovery", choice=choice), decision_tag), "recovery-chosen"

    def new_store(before):
        """The one run store that appeared after the stores in before."""
        deadline = time.monotonic() + 20
        while True:
            stores = sorted(set(work.glob("manager/runs/runs/*/runtime")) - before)
            if len(stores) == 1:
                return stores[0]
            assert len(stores) == 0 and time.monotonic() < deadline, ("new run store", stores)
            time.sleep(0.05)

    def store_flow(name, store):
        """The run-log records and the summary that the flow verb of the
        runner reads from the run store of an ended run."""
        completed = subprocess.run([str(runner), "flow", str(store)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        (work / (name + ".ndjson")).write_bytes(completed.stdout)
        (work / (name + ".stderr")).write_bytes(completed.stderr)
        lines = [json.loads(line) for line in completed.stdout.splitlines()]
        assert lines and "summary" in lines[-1], ("flow verb", name, completed.returncode, completed.stderr[-2000:])
        summary = lines[-1]["summary"]
        assert completed.returncode == 0 and summary["verified"] and not summary["problems"] and not summary["live"], (
            "the flow verb did not verify the ended run log", name, completed.returncode, summary["problems"])
        assert not summary["states"]["unacknowledged"], ("the run log has an unacknowledged control", name, summary["states"]["unacknowledged"])
        return lines[:-1], summary

    def acknowledged_control(records, identity):
        """The one run-log control of the command, from the manager, and the
        position of the first later event record that acknowledges it."""
        found = [record for record in records if record["schema"] == "control" and record["about"].get("command") == identity]
        assert len(found) == 1 and found[0]["from"] == "manager", ("run-log control of command", identity, [record["from"] for record in found])
        control = found[0]
        acknowledgements = [record["position"] for record in records if record["schema"] == "event" and record["position"] > control["position"]
                            and record["event"]["line"]["event"]["type"] == "control.ack"
                            and record["event"]["line"]["event"]["controlId"] == identity]
        assert acknowledgements, ("run-log control acknowledgement", identity)
        return control, acknowledgements[0]

    def model_questions(records, occurrence):
        """The run-log questions of the occurrence to a model, in log order."""
        return [record for record in records if record["schema"] == "question" and str(record["about"].get("occurrence")) == occurrence
                and isinstance(record["to"].get("to"), dict) and "model" in record["to"]["to"]]

    def settle(client, capabilities, run, choice):
        """Act on each head decision of the run until it ends: typed false
        for a question and choose-recovery with the choice for a recovery.
        Returns the recovery commands and the decisions they acted on."""
        recoveries = []
        deadline = time.monotonic() + 90
        while True:
            snapshot, _, _ = client[0](f"/v1/runs/{run}/snapshot", "RunSnapshot")
            if snapshot["runtime"] is not None and snapshot["runtime"]["status"] in terminal:
                return recoveries
            assert time.monotonic() < deadline, ("routing run terminal deadline", run)
            control, _, _ = client[0](f"/v1/runs/{run}/control", "RunControl")
            if control["decisionHeadId"] is None:
                time.sleep(0.05)
                continue
            decision, _, _ = client[0]("/v1/decisions/" + control["decisionHeadId"], "Decision")
            uri, kind = act(client, capabilities, run, control["decisionHeadId"], choice)
            command = effect(client, uri, kind)
            if command["operation"] == "choose-recovery":
                recoveries.append((command, decision))

    def routing_cases(first, first_capabilities):
        """Fail-over and redirect of the two-candidate question of
        profile_route through /v1, with the run-log and event evidence."""
        # Case 1. A choose-recovery fail-over through the decision asks the
        # spare candidate. The run log holds the relayed control and its
        # acknowledgement, a failure for the first question and a new question
        # to the spare candidate.
        before = set(work.glob("manager/runs/runs/*/runtime"))
        run = start(first, first_capabilities, "profile_route")
        store = new_store(before)
        recoveries = settle(first, first_capabilities, run, "failover")
        ended(first, run, "succeeded")
        assert len(recoveries) == 1, ("fail-over recoveries", [command["id"] for command, _ in recoveries])
        failover, decision = recoveries[0]
        assert any(item["choice"] == "failover" for item in decision["choices"]), ("failover not offered", decision["choices"])
        occurrence = decision["address"]["occurrenceId"]
        records, _ = store_flow("routing-failover-flow", store)
        control, acknowledgement = acknowledged_control(records, failover["id"])
        questions = model_questions(records, occurrence)
        assert len(questions) == 2, ("fail-over questions", [(record["position"], record["to"]) for record in questions])
        asked, spare = questions
        failures = [record for record in records if record["schema"] == "failure" and record.get("replyTo") == asked["position"]]
        assert len(failures) == 1 and asked["position"] < control["position"] < failures[0]["position"] < spare["position"], (
            "fail-over order", asked["position"], control["position"], [record["position"] for record in failures], spare["position"])
        first_target, spare_target = asked["to"]["to"]["model"], spare["to"]["to"]["model"]
        assert first_target.endswith("@primary") and spare_target.endswith("@spare"), ("fail-over targets", first_target, spare_target)
        answers = [record for record in records if record["schema"] == "answer" and record.get("replyTo") == spare["position"]]
        assert len(answers) == 1 and answers[0]["from"] == {"model": spare_target}, ("spare answer", [record["from"] for record in answers])
        print("PASS controls-routing case 1: choose-recovery command", failover["id"], "chose failover for occurrence", occurrence,
              "of run", run, "and the run succeeded; the run log holds control", control["position"], "from the manager with",
              "acknowledgement event", acknowledgement, "failure", failures[0]["position"], "for question", asked["position"], "to",
              first_target, "and question", spare["position"], "to", spare_target, "with its answer", flush=True)

        # Case 2. A redirect through the run control inside the dispatch
        # window asks the chosen target. The run log holds the relayed control,
        # its acknowledgement and a question to that target, and events.ndjson
        # holds occurrence.redirected.
        before = set(work.glob("manager/runs/runs/*/runtime"))
        run = start(first, first_capabilities, "profile_route")
        store = new_store(before)
        base = "/v1/runs/" + run
        control, tag, raw = first[1](base + "/control", "RunControl",
            lambda value: any(offer["operation"] == "redirect" for offer in value["offers"]))
        (work / "control-redirect-before.json").write_bytes(raw)
        offer = next(offer for offer in control["offers"] if offer["operation"] == "redirect")
        occurrence = offer["address"]["occurrenceId"]
        assert len(offer["targets"]) == 2 and offer["targets"][0].endswith("@primary"), ("redirect targets", offer["targets"])
        target = offer["targets"][-1]
        uri = first[2](base + "/control", {"operation": "redirect", "occurrenceId": occurrence, "target": target}, tag)
        redirect = effect(first, uri, "redirected")
        assert settle(first, first_capabilities, run, "abandon") == [], "a redirected run offered a recovery"
        ended(first, run, "succeeded")
        records, _ = store_flow("routing-redirect-flow", store)
        control, acknowledgement = acknowledged_control(records, redirect["id"])
        questions = model_questions(records, occurrence)
        assert len(questions) == 1 and questions[0]["to"] == {"to": {"model": target}} and control["position"] < questions[0]["position"], (
            "redirected questions", control["position"], [(record["position"], record["to"]) for record in questions])
        answers = [record for record in records if record["schema"] == "answer" and record.get("replyTo") == questions[0]["position"]]
        assert len(answers) == 1 and answers[0]["from"] == {"model": target}, ("redirected answer", [record["from"] for record in answers])
        events = [json.loads(line) for line in (store / "events.ndjson").read_bytes().splitlines()]
        events = [event.get("event", event) for event in events]
        redirected = [event for event in events if event["type"] == "occurrence.redirected"]
        assert len(redirected) == 1 and redirected[0]["target"] == target and str(redirected[0]["occurrenceId"]) == occurrence, (
            "occurrence.redirected event", redirected)
        print("PASS controls-routing case 2: redirect command", redirect["id"], "sent occurrence", occurrence, "of run", run,
              "to", target, "inside the dispatch window and reached the effect redirected; the run log holds control",
              control["position"], "from the manager with acknowledgement event", acknowledgement, "and question", questions[0]["position"],
              "to", target, "with its answer, events.ndjson holds occurrence.redirected, and the run succeeded", flush=True)

    def occurrence_of(snapshot, occurrence):
        """The occurrence of a run snapshot with the identifier."""
        assert snapshot["page"]["next"] is None, "the run snapshot has more than one page"
        found = [item for item in snapshot["items"] if item["occurrenceId"] == occurrence]
        assert len(found) == 1, ("snapshot occurrence", occurrence, len(found))
        return found[0]

    def running_attempts(snapshot, occurrence):
        """The running attempts of the occurrence in a run snapshot, or none
        when the snapshot does not hold the occurrence yet."""
        found = [item for item in snapshot["items"] if item["occurrenceId"] == occurrence]
        return [attempt for item in found for attempt in item.get("attempts", []) if attempt["state"] == "running"]

    def close_window(client, run):
        """Close the dispatch window of the two-candidate question of the run
        at once by a redirect to its first target. Returns the occurrence,
        the two targets and the redirect command."""
        base = "/v1/runs/" + run
        control, tag, _ = client[1](base + "/control", "RunControl",
            lambda value: any(offer["operation"] == "redirect" and len(offer["targets"]) == 2 for offer in value["offers"]))
        window = next(offer for offer in control["offers"] if offer["operation"] == "redirect")
        occurrence = window["address"]["occurrenceId"]
        first_target, spare_target = window["targets"]
        assert first_target.endswith("@primary") and spare_target.endswith("@spare"), ("dispatch targets", window["targets"])
        uri = client[2](base + "/control", {"operation": "redirect", "occurrenceId": occurrence, "target": first_target}, tag)
        return occurrence, first_target, spare_target, effect(client, uri, "redirected")

    def attempt_events(store, occurrence):
        """The attempt start and end events and the occurrence.redirected
        events of the occurrence in events.ndjson of the run store."""
        events = [json.loads(line) for line in (store / "events.ndjson").read_bytes().splitlines()]
        events = [event.get("event", event) for event in events]
        mine = lambda event: str(event.get("occurrenceId", (event.get("attemptId") or {}).get("occurrenceId"))) == occurrence
        attempts = [event for event in events if event["type"] in ("attempt.started", "attempt.completed", "attempt.failed") and mine(event)]
        redirected = [event for event in events if event["type"] == "occurrence.redirected" and mine(event)]
        return attempts, redirected

    def live_cases(first, first_capabilities):
        """Live redirect of an in-flight attempt through /v1, and its refusal
        for an effect in flight."""
        # Case 1. While the first candidate of a question that is not an
        # effect holds its turn, the run control offers a redirect to the
        # spare target from the approved policy. The redirect is accepted, and
        # the run completes with the answer of the spare candidate.
        before = set(work.glob("manager/runs/runs/*/runtime"))
        run = start(first, first_capabilities, "profile_live")
        store = new_store(before)
        base = "/v1/runs/" + run
        occurrence, first_target, spare_target, window_command = close_window(first, run)
        control, tag, raw = first[1](base + "/control", "RunControl",
            lambda value: any(offer["operation"] == "redirect" for offer in value["offers"]))
        (work / "live-redirect-offer.json").write_bytes(raw)
        offers = [offer for offer in control["offers"] if offer["operation"] == "redirect"]
        assert len(offers) == 1 and offers[0]["address"] == {"occurrenceId": occurrence} and offers[0]["targets"] == [spare_target], (
            "live redirect offer", offers)
        snapshot, _, _ = first[0](base + "/snapshot", "RunSnapshot")
        running = running_attempts(snapshot, occurrence)
        assert len(running) == 1, ("running attempt", running)
        uri = first[2](base + "/control", {"operation": "redirect", "occurrenceId": occurrence, "target": spare_target}, tag)
        live_command = effect(first, uri, "redirected")
        assert settle(first, first_capabilities, run, "abandon") == [], "a redirected run offered a recovery"
        ended(first, run, "succeeded")
        snapshot, _, _ = first[0](base + "/snapshot", "RunSnapshot")
        completed = occurrence_of(snapshot, occurrence)
        assert completed["state"] == "completed" and completed["source"] == "asked:" + spare_target, (
            "live redirect answer source", completed["state"], completed["source"])
        attempts, redirected = attempt_events(store, occurrence)
        assert [event["type"] for event in attempts] == ["attempt.started", "attempt.failed", "attempt.started", "attempt.completed"], (
            "live redirect attempts", attempts)
        assert live_command["id"] in attempts[1]["message"], ("stopped attempt message", attempts[1])
        assert [(event["controlId"], event["target"]) for event in redirected] == [
            (window_command["id"], first_target), (live_command["id"], spare_target)], ("occurrence.redirected events", redirected)
        live_facts["redirect"] = (run, store, occurrence, first_target, spare_target, live_command["id"], window_command["id"])
        print("PASS live-redirect case 1: while", first_target, "held its turn, the run control of run", run, "offered redirect of",
              "occurrence", occurrence, "to", spare_target, "only; redirect command", live_command["id"], "reached the effect redirected,",
              "the stopped attempt ended attempt.failed naming the command, the run succeeded with the answer of", spare_target,
              "and events.ndjson holds occurrence.redirected for the window command and the live command", flush=True)

        # Case 2. A redirect of an effect in flight refuses at admission with
        # unsupported-operation. The attempt keeps running, the run completes
        # with the answer of the first candidate, and nothing is re-routed.
        before = set(work.glob("manager/runs/runs/*/runtime"))
        run = start(first, first_capabilities, "profile_live_effect", "controlled-effect")
        store = new_store(before)
        base = "/v1/runs/" + run
        occurrence, first_target, spare_target, window_command = close_window(first, run)
        snapshot, _, _ = first[1](base + "/snapshot", "RunSnapshot", lambda value: running_attempts(value, occurrence))
        effect_occurrence = occurrence_of(snapshot, occurrence)
        assert effect_occurrence["intent"] == "effect", ("effect occurrence intent", effect_occurrence["intent"])
        running = running_attempts(snapshot, occurrence)
        control, tag, raw = first[0](base + "/control", "RunControl")
        (work / "live-redirect-effect-control.json").write_bytes(raw)
        assert not any(offer["operation"] == "redirect" for offer in control["offers"]), ("effect redirect offered", control["offers"])
        status, problem = post(base + "/control", authorized, first_capabilities,
                               {"operation": "redirect", "occurrenceId": occurrence, "target": spare_target}, tag)
        assert status == 409 and problem["code"] == "unsupported-operation", ("effect live redirect", status, problem.get("code"))
        snapshot, _, _ = first[0](base + "/snapshot", "RunSnapshot")
        still = running_attempts(snapshot, occurrence)
        assert [attempt["address"] for attempt in still] == [attempt["address"] for attempt in running], (
            "the effect attempt ended before the refusal was checked", running, still)
        assert settle(first, first_capabilities, run, "abandon") == [], "the effect run offered a recovery"
        ended(first, run, "succeeded")
        snapshot, _, _ = first[0](base + "/snapshot", "RunSnapshot")
        assert occurrence_of(snapshot, occurrence)["source"] == "asked:" + first_target, (
            "effect answer source", occurrence_of(snapshot, occurrence)["source"])
        attempts, redirected = attempt_events(store, occurrence)
        assert [event["type"] for event in attempts] == ["attempt.started", "attempt.completed"], ("effect attempts", attempts)
        assert [(event["controlId"], event["target"]) for event in redirected] == [(window_command["id"], first_target)], (
            "effect occurrence.redirected events", redirected)
        records, _ = store_flow("live-redirect-effect-flow", store)
        questions = model_questions(records, occurrence)
        assert [record["to"] for record in questions] == [{"to": {"model": first_target}}], ("effect questions", questions)
        assert not [record for record in records if record["schema"] == "failure"], "the effect run log holds a failure"
        assert [record["about"].get("command") for record in records if record["schema"] == "control"] == [window_command["id"]], (
            "effect run-log controls", [record["about"] for record in records if record["schema"] == "control"])
        print("PASS live-redirect case 2: the run control of run", run, "offered no redirect of effect occurrence", occurrence,
              "in flight, a redirect to", spare_target, "refused with 409 unsupported-operation while attempt", running[0]["address"]["attemptId"],
              "kept running, the run succeeded with the answer of", first_target, "and the run log holds one question and",
              "only the window control", flush=True)

    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            clients = {}
            for label, credential in (("first", authorized), ("peer", peer)):
                status, capabilities, _ = request("/v1/capabilities", credential)
                assert status == 200 and "control" in capabilities["scopes"], ("control capabilities", label, status)
                validate("Capabilities", capabilities)
                assert sorted(capabilities["profileIds"]) == sorted(CONTROL_PROFILES), capabilities["profileIds"]
                clients[label] = (mixed_client(capabilities, credential), capabilities)
            first, first_capabilities = clients["first"]
            second, second_capabilities = clients["peer"]
            if routing_mode:
                routing_cases(first, first_capabilities)
                return
            if live_mode:
                live_cases(first, first_capabilities)
                return live_facts

            # Case 1. A cancel of a running run is acknowledged, and the run ends cancelled.
            run = start(first, first_capabilities, "profile_steer")
            base = "/v1/runs/" + run
            control, tag, raw = first[1](base + "/control", "RunControl",
                lambda value: any(offer["operation"] == "steer" for offer in value["offers"]))
            (work / "control-cancel-before.json").write_bytes(raw)
            assert control["cancelAllowed"] and control["supervision"] == "owned", ("cancel not allowed", control["cancelAllowed"])
            status, receipt = post(base + "/control", authorized, first_capabilities, {"operation": "cancel"}, tag)
            assert status == 202 and receipt["operation"] == "cancel" and receipt["resource"] == base + "/control", (
                "cancel", status, receipt.get("code"))
            command, _, raw = first[1](receipt["links"]["self"], "CommandReceipt",
                lambda value: value["acknowledgement"] is not None or value["state"] in ("refused", "unresolved"))
            (work / "control-cancel-command.json").write_bytes(raw)
            assert command["state"] in ("acknowledged", "effect-observed") and command["acknowledgement"]["state"] in ("accepted", "delivered"), (
                "cancel acknowledgement", command["state"], command["acknowledgement"])
            ended(first, run, "cancelled")
            records = run_records(run, authorized)
            controls = [record for record in records if record["schema"] == "control" and record["about"].get("command") == receipt["id"]]
            assert len(controls) == 1 and controls[0]["from"] == "manager", ("cancel run-log control", len(controls))
            print("PASS controls case 1: cancel command", receipt["id"], "of running run", run, "was acknowledged",
                  command["acknowledgement"]["state"], "and the run ended cancelled, with one run-log control from the manager", flush=True)

            # Case 2. A steer of the steerable running attempt reaches the effect steered.
            run = start(first, first_capabilities, "profile_steer")
            base = "/v1/runs/" + run
            control, tag, raw = first[1](base + "/control", "RunControl",
                lambda value: any(offer["operation"] == "steer" for offer in value["offers"]))
            (work / "control-steer-before.json").write_bytes(raw)
            offer = next(offer for offer in control["offers"] if offer["operation"] == "steer")
            assert "interrupt-now" in offer["timings"] and "attemptId" in offer["address"], offer
            steer_uri = first[2](base + "/control", {"operation": "steer", "occurrenceId": offer["address"]["occurrenceId"],
                                 "attemptId": offer["address"]["attemptId"], "timing": "interrupt-now",
                                 "text": "Focus on the patch."}, tag)
            steer = effect(first, steer_uri, "steered")
            assert steer["effect"]["address"] == offer["address"], ("steer effect address", steer["effect"]["address"], offer["address"])
            records = run_records(run, authorized)
            steers = [record for record in records if record["schema"] == "steer"]
            controls = [record for record in records if record["schema"] == "control" and record["about"].get("command") == steer["id"]]
            assert steers and len(controls) == 1 and controls[0]["from"] == "manager", ("steer run-log records", len(steers), len(controls))
            print("PASS controls case 2: steer command", steer["id"], "of attempt", offer["address"], "of run", run,
                  "reached the effect steered, and the run log holds the relayed control and", len(steers), "steer record", flush=True)

            # Case 3. Two credentials answer the same head decision at the same time.
            control, _, _ = first[1](base + "/control", "RunControl", lambda value: value["decisionHeadId"] is not None)
            head = control["decisionHeadId"]
            decision, decision_tag, _ = first[0]("/v1/decisions/" + head, "Decision")
            assert decision["kind"] == "question" and decision["state"] == "pending", ("concurrent head", decision["kind"], decision["state"])
            body = {"operation": "answer", "occurrenceId": decision["address"]["occurrenceId"],
                    "generation": decision["generation"], "value": False}
            barrier = threading.Barrier(2)
            outcomes = {}

            def answer(label, credential, capabilities):
                barrier.wait(timeout=10)
                outcomes[label] = post("/v1/decisions/" + head, credential, capabilities, body, decision_tag)

            threads = [threading.Thread(target=answer, args=(label, credential, capabilities))
                       for label, credential, capabilities in (("first", authorized, first_capabilities), ("peer", peer, second_capabilities))]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=30)
            assert len(outcomes) == 2, ("concurrent answers did not return", sorted(outcomes))
            accepted = [(label, value) for label, (status, value) in outcomes.items() if status == 202]
            refused = [(label, status, value) for label, (status, value) in outcomes.items() if status != 202]
            assert len(accepted) == 1 and len(refused) == 1, ("concurrent answers", {label: status for label, (status, _) in outcomes.items()})
            winner, receipt = accepted[0]
            loser, refused_status, problem = refused[0]
            assert refused_status == 412 and problem["code"] == "stale-revision", ("concurrent answer refusal", refused_status, problem["code"])
            client = first if winner == "first" else second
            command, _, raw = client[1](receipt["links"]["self"], "CommandReceipt",
                lambda value: value["state"] in ("effect-observed", "refused", "unresolved"))
            (work / "control-answer-command.json").write_bytes(raw)
            assert command["state"] == "effect-observed" and command["effect"]["kind"] == "answer-accepted", ("answer effect", command["state"])
            assert command["acknowledgement"]["state"] == "delivered", ("answer acknowledgement", command["acknowledgement"])
            ended(first, run, "succeeded")
            records = run_records(run, authorized)
            questions = [record for record in records if record["schema"] == "question" and record["to"] == {"to": "manager"}]
            assert len(questions) == 1, ("person questions", len(questions))
            answers = [record for record in records if record["schema"] == "answer" and record["replyTo"] == questions[0]["position"]]
            assert len(answers) == 1 and answers[0]["about"].get("command") == receipt["id"] and answers[0]["body"] is False, (
                "run-log answers of the question", [(record["about"], record["body"]) for record in answers])
            print("PASS controls case 3: of two concurrent answers to head", head, "the", winner, "credential's command", receipt["id"],
                  "was delivered and reached answer-accepted, the", loser, "credential received 412 stale-revision,",
                  "and the run log holds one answer, and the run succeeded", flush=True)

            # Case 4. A non-head answer and an unoffered steer refuse, the
            # per-run FIFO order holds, and a retry through the run control
            # reaches the effect retried.
            run = start(second, second_capabilities, "profile_1")
            base = "/v1/runs/" + run
            pending = None
            deadline = time.monotonic() + 40
            while pending is None or len(pending) < 2:
                assert time.monotonic() < deadline, ("two pending decisions deadline", pending)
                time.sleep(0.05)
                pending = queue(second, run)
            head, later = pending
            control, control_tag, raw = second[0](base + "/control", "RunControl")
            (work / "control-fifo-before.json").write_bytes(raw)
            assert control["decisionHeadId"] == head, ("run control head", control["decisionHeadId"], head)
            assert not any(offer["operation"] == "steer" for offer in control["offers"]), ("unexpected steer offer", control["offers"])
            decision, decision_tag, _ = second[0]("/v1/decisions/" + later, "Decision")
            assert decision["position"] == 1 and decision["state"] == "pending", ("non-head decision", decision["position"], decision["state"])
            body = {"occurrenceId": decision["address"]["occurrenceId"], "generation": decision["generation"]}
            body.update({"operation": "answer", "value": False} if decision["kind"] == "question" else {"operation": "choose-recovery", "choice": "retry"})
            status, problem = post("/v1/decisions/" + later, peer, second_capabilities, body, decision_tag)
            assert status == 409 and problem["code"] == "decision-not-head", ("non-head answer", status, problem.get("code"))
            recovery = decision if decision["kind"] == "recovery" else second[0]("/v1/decisions/" + head, "Decision")[0]
            assert recovery["kind"] == "recovery", ("mixed-controls recovery decision", recovery["kind"])
            status, problem = post(base + "/control", peer, second_capabilities,
                                   {"operation": "steer", "occurrenceId": recovery["address"]["occurrenceId"], "attemptId": "0",
                                    "timing": "interrupt-now", "text": "No steer is offered."}, control_tag)
            assert status == 409 and problem["code"] == "unsupported-operation", ("unoffered steer", status, problem.get("code"))
            assert queue(second, run) == [head, later], ("the refusals changed the run queue", queue(second, run))
            order = []
            for expected in (head, later):
                control, _, _ = second[1](base + "/control", "RunControl", lambda value: value["decisionHeadId"] is not None)
                assert control["decisionHeadId"] == expected, ("per-run FIFO order", control["decisionHeadId"], expected)
                uri, kind = act(second, second_capabilities, run, expected, "retry")
                order.append(effect(second, uri, kind))
            ended(second, run, "succeeded")
            retried = next(command for command in order if command["operation"] == "retry")
            print("PASS controls case 4: non-head", later, "refused with 409 decision-not-head, an unoffered steer refused with",
                  "409 unsupported-operation, the queue kept", head, "before", later, "and the heads were acted on in that order,",
                  "retry command", retried["id"], "reached the effect retried, and run", run, "succeeded", flush=True)

            # Case 5. A choose-recovery abandon through the decision reaches
            # the effect recovery-chosen, and the run ends failed.
            run = start(second, second_capabilities, "profile_1")
            base = "/v1/runs/" + run
            abandoned = None
            deadline = time.monotonic() + 50
            while True:
                snapshot, _, _ = second[0](base + "/snapshot", "RunSnapshot")
                if snapshot["runtime"] is not None and snapshot["runtime"]["status"] in terminal:
                    break
                assert time.monotonic() < deadline, "abandon run terminal deadline"
                control, _, _ = second[0](base + "/control", "RunControl")
                if control["decisionHeadId"] is None:
                    time.sleep(0.05)
                    continue
                uri, kind = act(second, second_capabilities, run, control["decisionHeadId"], "abandon")
                command = effect(second, uri, kind)
                if command["operation"] == "choose-recovery":
                    abandoned = command
            assert abandoned is not None, "no recovery decision was abandoned"
            ended(second, run, "failed")
            print("PASS controls case 5: choose-recovery command", abandoned["id"], "chose abandon through the decision,",
                  "reached the effect recovery-chosen, and run", run, "ended failed", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")


def live_flow_checks(facts):
    """Read the manager log and the run stores with the flow verb after the
    manager exits, and require the joins of the live redirect command."""
    run, store, occurrence, first_target, spare_target, identity, window = facts["redirect"]
    flow_dir = work / "manager" / "flow"
    stores = sorted(work.glob("manager/runs/runs/*/runtime"))
    completed = subprocess.run([str(runner), "flow", str(flow_dir)] + [str(path) for path in stores],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    (work / "live-redirect-joined.ndjson").write_bytes(completed.stdout)
    (work / "live-redirect-joined.stderr").write_bytes(completed.stderr)
    lines = [json.loads(line) for line in completed.stdout.splitlines()]
    assert lines and "summary" in lines[-1], ("flow verb", completed.returncode, completed.stderr[-2000:])
    summary = lines[-1]["summary"]
    assert completed.returncode == 0 and summary["verified"] and not summary["problems"], ("flow verb", completed.returncode, summary["problems"])
    at = lambda log, position: {"log": log, "position": position}
    runlog = [line for line in lines[:-1] if line["log"] == str(store)]
    manager = [line for line in lines[:-1] if line["log"] not in [str(path) for path in stores]]
    commands = [line for line in manager if line["schema"] == "command" and line["about"].get("command") == identity]
    assert len(commands) == 1 and commands[0]["body"]["operation"] == "redirect" and commands[0]["body"]["resource"] == f"/v1/runs/{run}/control", (
        "live redirect command record", [line["body"] for line in commands])
    command = commands[0]
    receipts = [line for line in manager if line["schema"] == "receipt" and line["replyTo"] == command["position"] and line["log"] == command["log"]]
    assert len(receipts) == 1 and receipts[0]["body"]["id"] == identity and receipts[0]["body"]["state"] != "refused", (
        "live redirect receipt record", [line["body"] for line in receipts])
    relays = [line for line in manager if line["schema"] == "relay" and line["body"]["kind"] == "control" and line["about"].get("command") == identity]
    assert len(relays) == 1 and relays[0]["body"]["nativeRun"] == store.parent.name, ("live redirect relay record", [line["body"] for line in relays])
    relay = relays[0]
    delivered = [item["delivered"] for item in summary["joins"]["relays"] if item["relay"] == at(relay["log"], relay["position"])]
    assert len(delivered) == 1 and delivered[0] is not None and delivered[0]["log"] == str(store), ("live redirect relay delivery", delivered)
    control = next(line for line in runlog if line["position"] == delivered[0]["position"])
    assert control["schema"] == "control" and control["from"] == "manager" and control["about"].get("command") == identity, (
        "live redirect run-log control", control["schema"], control["from"], control["about"])
    acknowledged = [item["acknowledgement"] for item in summary["joins"]["controls"] if item["control"] == at(str(store), control["position"])]
    assert len(acknowledged) == 1 and acknowledged[0] is not None, ("live redirect acknowledgement", acknowledged)
    questions = [line for line in runlog if line["schema"] == "question" and str(line["about"].get("occurrence")) == occurrence
                 and isinstance(line["to"].get("to"), dict) and "model" in line["to"]["to"]]
    assert [line["to"]["to"]["model"] for line in questions] == [first_target, spare_target], (
        "live redirect questions", [(line["position"], line["to"]) for line in questions])
    asked, spare = questions
    failures = [line for line in runlog if line["schema"] == "failure" and line.get("replyTo") == asked["position"]]
    assert len(failures) == 1 and identity in json.dumps(failures[0]), ("live redirect failure", failures)
    assert asked["position"] < control["position"] < failures[0]["position"] < spare["position"], (
        "live redirect order", asked["position"], control["position"], failures[0]["position"], spare["position"])
    answers = [line for line in runlog if line["schema"] == "answer" and line.get("replyTo") == spare["position"]]
    assert len(answers) == 1 and answers[0]["from"] == {"model": spare_target}, ("spare answer", [line["from"] for line in answers])
    print("PASS live-redirect case 3: the flow verb joins redirect command", identity, "at manager position", command["position"],
          "its receipt at", receipts[0]["position"], "and its relay at", relay["position"], "to run-log control", control["position"],
          "from the manager with acknowledgement", acknowledged[0], "and the run log holds failure", failures[0]["position"],
          "for question", asked["position"], "to", first_target, "and question", spare["position"], "to", spare_target,
          "with its answer", flush=True)


def person_checks():
    """Asks named by the personAnswers policy field through the real HTTPS
    manager. Each numbered case prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    requests = work / "adapter-requests"
    answer_text = "Answered by a person through the manager."
    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            status, capabilities, _ = request("/v1/capabilities", authorized)
            assert status == 200
            validate("Capabilities", capabilities)
            observed, wait_for, mutate, _ = mixed_client(capabilities, authorized)
            def prepare(profile):
                """Create and enqueue one prompt-source request of the profile.
                Returns the request URI, the live preparation and its ETag."""
                status, catalogue, _ = request("/v1/workflows?profileId=" + profile, authorized)
                assert status == 200, ("person-answers catalogue", profile, status)
                workflow = next(item for item in catalogue["items"] if item["name"] == "prompt-source")
                create = {"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                          "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]}
                key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
                status, created, raw = request("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": key},
                                               method="POST", payload=json.dumps(create, separators=(",", ":")).encode())
                assert status == 201, ("request creation", profile, status, created.get("code"))
                validate("Request", created, raw)
                request_uri = created["links"]["self"]
                current, tag, _ = observed(request_uri, "Request")
                mutate(request_uri, {"operation": "set-input", "input": {"name": "input", "source": "literal", "value": "Person answers fixture input."}}, tag)
                current, tag, _ = observed(request_uri, "Request")
                mutate(request_uri, {"operation": "enqueue"}, tag)
                current, _, _ = wait_for(request_uri, "Request", lambda value: value["preparationId"] is not None)
                preparation, tag, raw = observed("/v1/preparations/" + current["preparationId"], "Preparation")
                (work / ("person-review-" + profile + ".json")).write_bytes(raw)
                assert preparation["state"] == "live", preparation["state"]
                return request_uri, preparation, tag

            def approve(request_uri, preparation, tag):
                """Approve the exact review. Returns the run."""
                selectors = ("reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration")
                mutate("/v1/preparations/" + preparation["id"], {"operation": "approve", **{name: preparation[name] for name in selectors}}, tag)
                current, _, _ = wait_for(request_uri, "Request", lambda value: value["runId"] is not None)
                return current["runId"]

            # Case 1. The review shows personAnswers in the target policy.
            request_uri, preparation, tag = prepare("profile_1")
            review = preparation["review"]
            assert review["personAnswering"] == "local-control", review["personAnswering"]
            assert review["policy"]["kind"] == "routed" and review["policy"].get("personAnswers") == ["model:fixed-point"], (
                "the review does not show personAnswers in the target policy", review["policy"])
            print("PASS person-answers case 1: the review of preparation", preparation["id"], "shows personAnswers",
                  review["policy"]["personAnswers"], "in the routed target policy under local-control", flush=True)

            # Case 2. After the approval the named ask is a pending question decision.
            run = approve(request_uri, preparation, tag)
            base = "/v1/runs/" + run
            control, _, _ = wait_for(base + "/control", "RunControl", lambda value: value["decisionHeadId"] is not None)
            head = control["decisionHeadId"]
            decision, decision_tag, raw = observed("/v1/decisions/" + head, "Decision")
            (work / "person-decision.json").write_bytes(raw)
            assert decision["kind"] == "question" and decision["state"] == "pending" and decision["runId"] == run, (
                "the named ask is not a pending question decision", decision["kind"], decision["state"])
            assert decision["question"]["code"] == "text" and decision["question"]["addressee"] == "person model:fixed-point", (
                "the named ask has another answer type or addressee", decision["question"]["code"], decision["question"]["addressee"])
            stores = sorted(work.glob("manager/runs/runs/*/runtime"))
            assert len(stores) == 1, ("person-answers run stores", stores)
            store = stores[0]
            events = [json.loads(line)["event"] for line in (store / "events.ndjson").read_bytes().splitlines()]
            started = [event for event in events if event["type"] == "occurrence.started"]
            assert [event["addressee"] for event in started] == ["person model:fixed-point"], (
                "the named ask did not start as a person ask", [event.get("addressee") for event in started])
            assert any(event["type"] == "occurrence.person-answer-pending" for event in events), "no person answer is pending"
            print("PASS person-answers case 2: after the approval run", run, "has the pending question decision", head,
                  "of answer type", decision["question"]["code"], "addressed to", decision["question"]["addressee"], "as its ask started", flush=True)

            # Case 3. A typed answer through the decision completes the ask
            # without an engine turn, and the run succeeds.
            body = {"operation": "answer", "occurrenceId": decision["address"]["occurrenceId"],
                    "generation": decision["generation"], "value": answer_text}
            answer_receipt = mutate("/v1/decisions/" + head, body, decision_tag)
            answer_command = answer_receipt.rsplit("/", 1)[1]
            snapshot, _, raw = wait_for(base + "/snapshot", "RunSnapshot",
                lambda value: value["runtime"] is not None and value["runtime"]["status"] in ("succeeded", "failed", "cancelled"))
            (work / "person-terminal-snapshot.json").write_bytes(raw)
            assert snapshot["runtime"]["status"] == "succeeded", ("person-answers run terminal status", snapshot["runtime"]["status"])
            answers = json.loads((store / "answers.json").read_bytes())["answers"]
            assert [record["answer"] for record in answers] == [answer_text], ("recorded answers", [record["answer"] for record in answers])
            events = [json.loads(line)["event"] for line in (store / "events.ndjson").read_bytes().splitlines()]
            assert not any(event["type"].startswith("attempt.") for event in events), (
                "an attempt happened for the named ask", [event["type"] for event in events if event["type"].startswith("attempt.")])
            relayed = requests.read_text().splitlines() if requests.exists() else []
            assert "session/prompt" not in relayed, ("the adapter received a turn for the named ask", relayed)
            print("PASS person-answers case 3: answer command", answer_command, "of decision", head, "delivered the typed answer,",
                  "the run succeeded with it as the only recorded answer, and no attempt happened and the adapter received no",
                  "session/prompt among its requests", relayed, flush=True)

            # Case 4. Without --person-answer the same launcher relays a turn,
            # so that the record of case 3 can show one. The model answers
            # and no decision is pending.
            request_uri, plain, tag = prepare("profile_plain")
            assert "personAnswers" not in plain["review"]["policy"], ("the plain review shows personAnswers", plain["review"]["policy"])
            plain_run = approve(request_uri, plain, tag)
            snapshot, _, _ = wait_for("/v1/runs/" + plain_run + "/snapshot", "RunSnapshot",
                lambda value: value["runtime"] is not None and value["runtime"]["status"] in ("succeeded", "failed", "cancelled"))
            assert snapshot["runtime"]["status"] == "succeeded", ("plain run terminal status", snapshot["runtime"]["status"])
            later = requests.read_text().splitlines()[len(relayed):]
            assert "session/prompt" in later, ("the plain run relayed no turn", later)
            status, queue, _ = request("/v1/decisions?runId=" + plain_run, authorized)
            assert status == 200 and queue["items"] == [], ("plain run decisions", status, queue.get("items"))
            print("PASS person-answers case 4: without --person-answer the review of", plain["id"], "has no personAnswers,",
                  "run", plain_run, "succeeded with no decision, and the same launcher relayed", later, flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")

    # Case 5. The flow verb shows the answer from the answering principal.
    flow_dir = work / "manager" / "flow"
    stores = sorted(work.glob("manager/runs/runs/*/runtime"))
    assert len(stores) == 2 and store in stores, ("person-answers run stores", stores)
    completed = subprocess.run([str(runner), "flow", str(flow_dir)] + [str(path) for path in stores],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    (work / "person-answers-joined.ndjson").write_bytes(completed.stdout)
    (work / "person-answers-joined.stderr").write_bytes(completed.stderr)
    lines = [json.loads(line) for line in completed.stdout.splitlines()]
    assert lines and "summary" in lines[-1], ("flow verb", completed.returncode, completed.stderr[-2000:])
    summary = lines[-1]["summary"]
    assert completed.returncode == 0 and summary["verified"] and not summary["problems"], ("flow verb", completed.returncode, summary["problems"])
    at = lambda log, position: {"log": log, "position": position}
    runlog = [line for line in lines[:-1] if line["log"] == str(store)]
    manager = [line for line in lines[:-1] if line["log"] not in [str(path) for path in stores]]
    credential = issued["result"]["credential"]
    principal = {"principal": "credential", "credentialId": credential["credentialId"], "client": credential["clientId"]}
    commands = [line for line in manager if line["schema"] == "command" and line["about"].get("command") == answer_command]
    assert len(commands) == 1 and commands[0]["from"] == principal and commands[0]["body"]["operation"] == "answer", (
        "person answer command record", [(line["from"], line["body"].get("operation")) for line in commands])
    command = commands[0]
    assert command["body"]["body"]["json"].get("value") == answer_text, ("person answer command value", command["body"]["body"]["json"])
    questions = [line for line in runlog if line["schema"] == "question" and line["to"] == {"to": "manager"}]
    assert len(questions) == 1, ("person questions in the run log", [line["about"] for line in questions])
    question = questions[0]
    replies = [line for line in runlog if line["schema"] == "answer" and line.get("replyTo") == question["position"]]
    assert len(replies) == 1 and replies[0]["from"] == "manager" and replies[0]["about"].get("command") == answer_command and replies[0]["body"] == answer_text, (
        "run-log person answer", [(line["from"], line["about"], line["body"]) for line in replies])
    reply = replies[0]
    joined = [item for item in summary["joins"]["answers"] if item["answer"] == at(str(store), reply["position"])]
    assert joined == [{"answer": at(str(store), reply["position"]), "command": at(command["log"], command["position"]), "commandId": answer_command}], (
        "the run-log answer is not joined to the answer command of the credential", joined)
    engine = [line["position"] for line in runlog if line["schema"] in ("engine-start", "turn")]
    assert not engine, ("the run log has an engine start or turn", engine)
    print("PASS person-answers case 5: the flow verb joins run-log answer", reply["position"], "to question", question["position"],
          "and to answer command", answer_command, "at manager position", command["position"], "from credential", credential["credentialId"],
          "and the run log has no engine start or turn", flush=True)
    print("PASS person-answers: every person-answer case held against the running TLS 1.3 manager", flush=True)


def worker_failure_checks():
    """The failure ending of a lost worker through the real HTTPS manager.
    Each numbered case prints one PASS line."""
    authorized = {"Authorization": "Bearer " + bearer}
    terminal = ("succeeded", "failed", "cancelled")

    def groups(pids):
        """The process group of each live process in pids, with its command."""
        listing = subprocess.run(["ps", "-o", "pid=,pgid=,command="] + sum((["-p", str(pid)] for pid in pids), []),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10).stdout
        return [(int(pid), int(pgid), command) for pid, pgid, command in
                (line.strip().split(None, 2) for line in listing.splitlines() if line.strip())]

    def attempt(path, body, tag):
        """Send one command and return its status and its final receipt
        state, or the refusal code. A receipt that stays accepted or
        dispatch-attempted past the bound fails."""
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        payload = json.dumps(body, separators=(",", ":")).encode()
        headers = authorized | {"Content-Type": "application/json", "Idempotency-Key": key, "If-Match": tag}
        status, receipt, raw, _ = exchange(path, headers, method="POST", payload=payload)
        if status != 202:
            return status, receipt["code"], None
        validate("CommandReceipt", receipt, raw)
        value, _, raw = wait_for(receipt["links"]["self"], "CommandReceipt",
            lambda value: value["state"] in ("effect-observed", "refused", "unresolved"))
        (work / ("lost-" + body["operation"] + "-receipt.json")).write_bytes(raw)
        return status, value["state"], value

    with (work / "server-0.stdout").open("wb") as output, (work / "server-0.stderr").open("wb") as errors:
        process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                    "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        try:
            wait_ready(process)
            status, capabilities, raw = request("/v1/capabilities", authorized)
            assert status == 200
            validate("Capabilities", capabilities, raw)
            client = mixed_client(capabilities, authorized)
            observed, wait_for, _, _ = client
            status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
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

            # Case 1. A run waits at its person question with a live worker.
            _, run = approve_mixed(create_request(), workflow, client)
            base = "/v1/runs/" + run
            head, _, _ = drive_mixed(run, client, stop_at_question=True, overview=False)
            control, _, _ = observed(base + "/control", "RunControl")
            assert control["supervision"] == "owned" and control["decisionHeadId"] == head, (control["supervision"], control["decisionHeadId"])
            decision, _, _ = observed("/v1/decisions/" + head, "Decision")
            # The worker is the frontend proxy that the manager starts, in its
            # own process group, and the inner frontend worker that the proxy
            # starts in a second process group with the engine adapter. Both
            # groups are read from the live processes, never from a stored
            # PID. The proxy alone is not the worker: the inner worker
            # inherits the pipes of the manager and continues the run when
            # only the proxy dies.
            manager_group = os.getpgid(process.pid)
            tree = groups(descendants(process.pid))
            (work / "worker-processes.txt").write_text("".join(f"{pid} {pgid} {command}\n" for pid, pgid, command in tree))
            targets = sorted({pgid for _, pgid, _ in tree})
            assert targets and manager_group not in targets, ("worker process groups", targets, manager_group)
            print("PASS failures-worker case 1: run", run, "waits at person question", head, "under owned supervision, with",
                  len(tree), "worker processes in process groups", targets, flush=True)

            # Case 2. SIGKILL of the worker process groups ends in lost
            # supervision and never in a successful result.
            for group in targets:
                os.killpg(group, signal.SIGKILL)
            killed = time.monotonic()
            value, _, raw = wait_for(base, "Run", lambda value: value["supervision"] == "lost")
            lost_after = time.monotonic() - killed
            (work / "lost-run.json").write_bytes(raw)
            assert value["runtime"] is None or value["runtime"]["status"] != "succeeded", ("lost run runtime", value["runtime"])
            assert value["verification"]["state"] != "verified", ("lost run verification", value["verification"])
            assert "lost-supervision" in value["limitations"], ("lost run limitations", value["limitations"])
            control, control_tag, raw = observed(base + "/control", "RunControl")
            (work / "lost-control.json").write_bytes(raw)
            assert control["supervision"] == "lost" and not control["cancelAllowed"], ("lost run control", control["supervision"], control["cancelAllowed"])
            snapshot, _, _ = observed(base + "/snapshot", "RunSnapshot")
            assert snapshot["runtime"] is None or snapshot["runtime"]["status"] != "succeeded", ("lost run snapshot", snapshot["runtime"])
            outputs, _, _ = observed(base + "/outputs", "OutputPage")
            assert not [item for item in outputs["items"] if item["kind"] == "result" and item["verification"]["state"] == "verified"], (
                "the lost run shows a verified result", outputs["items"])
            print("PASS failures-worker case 2: after SIGKILL of the worker process groups, run", run, "shows lost supervision after",
                  round(lost_after, 2), "seconds with runtime", value["runtime"] and value["runtime"]["status"], "verification",
                  value["verification"]["state"], "and limitations", value["limitations"], flush=True)

            # Case 3. An answer and a cancel for the lost run are refused or
            # end unresolved, and neither is effect-observed.
            status, decision_now, raw, headers = exchange("/v1/decisions/" + head, authorized)
            (work / "lost-decision.json").write_bytes(raw)
            if status == 200:
                answer = {"operation": "answer", "occurrenceId": decision["address"]["occurrenceId"],
                          "generation": decision["generation"], "value": False}
                outcome = attempt("/v1/decisions/" + head, answer, headers["etag"])
            else:
                outcome = (status, decision_now["code"], None)
            assert outcome[0] != 202 or outcome[1] in ("refused", "unresolved"), ("lost run answer", outcome[:2])
            assert outcome[2] is None or outcome[2]["effect"] is None, ("lost run answer effect", outcome[2]["effect"])
            cancel = attempt(base + "/control", {"operation": "cancel"}, control_tag)
            assert cancel[0] != 202 or cancel[1] in ("refused", "unresolved"), ("lost run cancel", cancel[:2])
            assert cancel[2] is None or cancel[2]["effect"] is None, ("lost run cancel effect", cancel[2]["effect"])
            value, _, _ = observed(base, "Run")
            assert value["supervision"] == "lost" and (value["runtime"] is None or value["runtime"]["status"] != "succeeded")
            print("PASS failures-worker case 3: the answer of decision", head, "ended as", outcome[:2], "and the cancel ended as",
                  cancel[:2], "with no effect, and the run stays lost", flush=True)

            # Case 4. No worker process remains or starts for the lost run.
            remaining = descendants(process.pid)
            assert not remaining, ("processes remain after the worker loss", groups(remaining))
            stores = sorted(work.glob("manager/runs/runs/*/runtime"))
            assert len(stores) == 1, ("run stores after the worker loss", stores)
            lost_store = stores[0]
            starts = [line for line in (lost_store / "events.ndjson").read_bytes().splitlines()
                      if json.loads(line)["event"]["type"] == "run.started"]
            assert len(starts) == 1, ("the lost run started again", len(starts))
            print("PASS failures-worker case 4: no manager descendant remains and the run store of", run,
                  "holds one run start", flush=True)

            # Case 5. A new request on the same manager is reviewed,
            # approved and completes with a verified result.
            _, fresh = approve_mixed(create_request(), workflow, client)
            _, answered, recovered = drive_mixed(fresh, client, overview=False)
            assert answered and recovered, ("new run decisions", answered, recovered)
            artifact = verified_download(fresh, client, authorized)
            value, _, _ = observed(base, "Run")
            assert value["supervision"] == "lost", ("lost run after the new run", value["supervision"])
            print("PASS failures-worker case 5: new run", fresh, "on the same manager was reviewed, approved, answered and",
                  "retried, and succeeded with verified result", artifact["id"], flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=25)
            (work / "server-0.exit").write_text(str(process.returncode) + "\n")

    # Case 6. The flow verb reports the run log of the lost run as ended
    # without its stop, never as complete.
    completed = subprocess.run([str(runner), "flow", str(lost_store)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    (work / "lost-flow.ndjson").write_bytes(completed.stdout)
    (work / "lost-flow.stderr").write_bytes(completed.stderr)
    lines = [json.loads(line) for line in completed.stdout.splitlines()]
    assert lines and "summary" in lines[-1], ("flow verb", completed.returncode, completed.stderr[-2000:])
    summary = lines[-1]["summary"]
    questions = [line["position"] for line in lines[:-1] if line.get("schema") == "question" and line["to"] == {"to": "manager"}]
    assert completed.returncode == 2 and summary["stop"] is None and summary["states"]["lostSupervision"], (
        "the flow verb does not report lost supervision", completed.returncode, summary["stop"], summary["states"])
    assert questions and set(questions) <= set(summary["states"]["uncertain"]), ("the person question is not uncertain", questions, summary["states"]["uncertain"])
    print("PASS failures-worker case 6: the flow verb exits 2 for the lost run log, with no stop, lost supervision and",
          "uncertain asks", summary["states"]["uncertain"], flush=True)
    print("PASS failures-worker: every worker-loss case held against the running TLS 1.3 manager", flush=True)


if worker_failure_mode:
    worker_failure_checks()
    raise SystemExit(0)


def manager_failure_checks():
    """The failure ending of a lost manager and the release of its quarantined
    reservations through three lifetimes of the real HTTPS manager with one
    profile and one execution reservation. Each numbered case prints one PASS
    line."""
    import sqlite3
    authorized = {"Authorization": "Bearer " + bearer}
    flow_dir = work / "manager" / "flow"
    half = MANAGER_FAILURE_LEDGER // 2

    def serve(index):
        """Start one foreground manager lifetime on the same root and
        configuration and wait for HTTPS readiness."""
        with (work / f"server-{index}.stdout").open("wb") as output, (work / f"server-{index}.stderr").open("wb") as errors:
            process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                        "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        wait_ready(process)
        return process

    def process_groups():
        """Every live process with its process group and command, from one
        process listing."""
        listing = subprocess.run(["ps", "-Ao", "pid=,pgid=,command="], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, timeout=10, check=True).stdout
        return [(int(pid), int(pgid), command) for pid, pgid, command in
                (line.strip().split(None, 2) for line in listing.splitlines() if len(line.split(None, 2)) == 3)]

    def workers(process, index):
        """The worker processes of a manager lifetime and their process
        groups, which must differ from the process group of the manager."""
        tree = [entry for entry in process_groups() if entry[0] in set(descendants(process.pid))]
        (work / f"worker-processes-{index}.txt").write_text("".join(f"{pid} {pgid} {command}\n" for pid, pgid, command in tree))
        targets = sorted({pgid for _, pgid, _ in tree})
        assert targets and os.getpgid(process.pid) not in targets, ("worker process groups", targets, os.getpgid(process.pid))
        return tree, targets

    def kill(process, targets, index):
        """SIGKILL of the manager process. Each worker process sees its
        control channel end and stops within the bound. Returns the seconds
        until no process of the worker groups remained."""
        process.kill()
        process.wait(timeout=25)
        killed = time.monotonic()
        while True:
            remaining = [entry for entry in process_groups() if entry[1] in targets]
            if not remaining or time.monotonic() - killed > 30:
                break
            time.sleep(0.1)
        (work / f"worker-processes-after-kill-{index}.txt").write_text("".join(f"{pid} {pgid} {command}\n" for pid, pgid, command in remaining))
        assert not remaining, ("worker processes remain after the manager loss", remaining)
        return time.monotonic() - killed

    def ended(process, index, killed):
        """End a lifetime that a case left running, and check how it ended."""
        if process.poll() is None:
            process.kill() if killed else process.terminate()
        process.wait(timeout=25)
        (work / f"server-{index}.exit").write_text(str(process.returncode) + "\n")

    def log_files():
        """The sealed segments in start order, then the active file."""
        sealed = sorted((flow_dir / "sealed").glob("*/*.ndjson"))
        return sealed + sorted(flow_dir.glob("*.ndjson"))

    def log_bytes():
        """The bytes of the manager log and of its claim checks, as the
        writer counts them."""
        claims = [path for path in (flow_dir / "claims").rglob("*") if path.is_file()] if (flow_dir / "claims").is_dir() else []
        return sum(path.stat().st_size for path in log_files() + claims)

    def log_records():
        """Every record line of the manager log, in position order."""
        return [json.loads(line) for path in log_files() for line in path.read_bytes().splitlines()]

    def positioned():
        """Every record line of the manager log with its position: the
        sealed segments from the start of the oldest, then the active file."""
        sealed = sorted((flow_dir / "sealed").glob("*/*.ndjson"))
        position = int(sealed[0].name[:20]) if sealed else 0
        found = []
        for path in log_files():
            assert path not in sealed or int(path.name[:20]) == position, ("a sealed segment does not continue the positions", path, position)
            for line in path.read_bytes().splitlines():
                found.append((position, json.loads(line)))
                position += 1
        return found

    def orphan_replies(asks):
        """For each orphaned ask, by position, its sender and its expected
        reply body, the replies of the manager log that name it. Each must be
        the one reply of the manager to the sender, with that body."""
        replies = {}
        for position, record in positioned():
            if record.get("replyTo") in asks:
                replies.setdefault(record["replyTo"], []).append(record)
        for position, (sender, schema, body) in asks.items():
            found = replies.get(position, [])
            assert len(found) == 1 and found[0]["schema"] == schema and found[0]["from"] == "manager" \
                and found[0]["to"] == {"to": sender} and found[0]["body"] == {"inline": body}, (
                "the reply to an orphaned ask", position, schema, body, found)
        return sorted(asks)

    def lifetime_notice():
        """The body of the lifetime notice of the newest lifetime."""
        return [record for record in log_records() if record["schema"] == "notice"
                and record["body"]["inline"]["notice"] == "lifetime"][-1]["body"]["inline"]

    def names(record, identities):
        return bool(set(record["about"].values()) & identities)

    def start_relays(run):
        return [record for record in log_records() if record["schema"] == "relay"
                and record["body"].get("inline", {}).get("kind") == "start" and record["about"].get("managerRun") == run]

    def run_starts(store):
        return [line for line in (store / "events.ndjson").read_bytes().splitlines()
                if json.loads(line)["event"]["type"] == "run.started"]

    def mixed_workflow(profile):
        status, catalogue, _ = request("/v1/workflows?profileId=" + profile, authorized)
        assert status == 200
        found = next(item for item in catalogue["items"] if item["name"] == "mixed-controls")
        return found, json.dumps({"workflowId": found["id"], "descriptorRevision": found["revision"],
                                  "profileId": found["profileId"], "profileRevision": found["profileRevision"]},
                                 separators=(",", ":")).encode()

    def create_request(epoch, payload):
        key = epoch + "." + secrets.token_urlsafe(16)
        status, created, raw = request("/v1/requests", authorized | {
            "Content-Type": "application/json", "Idempotency-Key": key}, method="POST", payload=payload)
        assert status == 201, ("request creation", status, created.get("code"))
        validate("Request", created, raw)
        return created

    def database():
        found = sorted((work / "manager").rglob("coordination.sqlite3"))
        assert len(found) == 1, ("coordination database", found)
        return found[0].as_uri() + "?mode=ro"

    def read_store(statement, parameters=()):
        """The rows of one read-only query of the coordination database."""
        connection = sqlite3.connect(database(), uri=True)
        try:
            return [tuple(row) for row in connection.execute(statement, parameters)]
        finally:
            connection.close()

    def unchanged(action):
        """The value of the action, and whether no other connection changed
        the database and nothing was appended to the manager log meanwhile."""
        observer = sqlite3.connect(database(), uri=True)
        try:
            version_before = observer.execute("PRAGMA data_version").fetchone()[0]
            log_before = log_bytes()
            value = action()
            version_after = observer.execute("PRAGMA data_version").fetchone()[0]
        finally:
            observer.close()
        return value, version_after == version_before and log_bytes() == log_before

    def canonical_digest(facts):
        """The SHA-256 of the canonical JSON bytes of the facts: sorted keys,
        no whitespace, and UTF-8 text."""
        return hashlib.sha256(json.dumps(facts, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()

    def release(quarantine, evidence, digest, refused=None):
        return administration({"version": 1, "operation": "release-quarantine", "quarantineId": quarantine,
                               "cleanupEvidenceId": evidence, "cleanupEvidenceDigest": digest}, refused=refused)

    def release_and_run(epoch, client, quarantine, facts, case):
        """A new request stays queued with capacity behind the quarantined
        reservation. check-store lists the reservation and check-quarantine
        gives the clean evidence of the facts, without a change. A release
        with a wrong digest and a release of an unknown identity refuse
        without a change, and the request stays queued. The release with the
        evidence frees the capacity. The request then reaches review without
        another client command, and its approved run completes with a
        verified result. Releases of the held reservation of that run and of
        the released reservation refuse with state-conflict."""
        observed, wait_for, _, _ = client
        workflow, payload = mixed_workflow("profile_1")
        waiting = create_request(epoch, payload)
        waiting_uri = waiting["links"]["self"]
        enqueue_mixed(waiting, workflow, client)
        current, _, _ = wait_for(waiting_uri, "Request", lambda value: value["admission"]["reasons"] == ["capacity"])
        assert current["phase"] == "queued" and current["preparationId"] is None, ("queued request", current["phase"], current["preparationId"])
        (checked, answers), same = unchanged(lambda: (
            administration({"version": 1, "operation": "check-store"})["result"],
            [administration({"version": 1, "operation": "check-quarantine", "quarantineId": quarantine})["result"] for _ in range(2)]))
        assert same, ("check-store or check-quarantine changed the database or the manager log", case)
        assert checked == {"integrity": "valid", "quarantineIds": [quarantine]}, ("check-store", case, checked, quarantine)
        once, twice = answers
        digest = canonical_digest(facts)
        assert once["quarantineId"] == quarantine and once["state"] == "clean" and once["processGeneration"] == facts["processGeneration"], (
            "check-quarantine of a quarantined reservation", case, once)
        assert once["cleanupEvidenceDigest"] == digest and once["cleanupEvidenceId"] == "cleanup_" + digest[:32], (
            "the evidence digest differs from the canonical facts", case, once, facts)
        assert once["expiresAt"] is not None and all(twice[key] == once[key] for key in
            ("quarantineId", "state", "cleanupEvidenceId", "cleanupEvidenceDigest", "processGeneration")), ("two checks differ", case, once, twice)
        _, same = unchanged(lambda: (
            release(quarantine, once["cleanupEvidenceId"], "0" * 64, refused="cleanup-unverified"),
            release("reservation_unknown", once["cleanupEvidenceId"], digest, refused="state-conflict")))
        assert same, ("a refused release changed the database or the manager log", case)
        time.sleep(1)
        current, _, _ = observed(waiting_uri, "Request")
        assert current["phase"] == "queued" and current["preparationId"] is None and current["admission"]["reasons"] == ["capacity"], (
            "the request left the queue after a refused release", case, current["phase"], current["admission"])
        released = release(quarantine, once["cleanupEvidenceId"], digest)["result"]
        assert released == {"quarantineId": quarantine, "state": "released"}, ("release-quarantine", case, released)
        _, run = approve_review(waiting, workflow, client)
        held = [ident for (ident,) in read_store("SELECT id FROM reservations WHERE request_id=? AND state='held'", (waiting["id"],))]
        assert len(held) == 1, ("the held reservation of the new run", case, held)
        administration({"version": 1, "operation": "check-quarantine", "quarantineId": held[0]}, refused="state-conflict")
        release(held[0], once["cleanupEvidenceId"], digest, refused="state-conflict")
        release(quarantine, once["cleanupEvidenceId"], digest, refused="state-conflict")
        assert read_store("SELECT state,slot FROM reservations WHERE id=?", (quarantine,)) == [("released", None)]
        assert not read_store("SELECT 1 FROM reservation_resources WHERE reservation_id=?", (quarantine,))
        _, answered, recovered = drive_mixed(run, client, overview=False)
        assert answered and recovered, ("decisions of the new run", case, answered, recovered)
        artifact = verified_download(run, client, authorized)
        print(f"PASS failures-manager case {case}: request", waiting["id"], "waited with capacity behind quarantined reservation",
              quarantine, "; check-quarantine gave", once["cleanupEvidenceId"], "over the recomputed facts of", facts["evidence"],
              "; a wrong digest refused with cleanup-unverified and an unknown identity with state-conflict without a change;",
              "the release freed the capacity, the request reached review without another client command, and run", run,
              "succeeded with verified result", artifact["id"], "; releases of held reservation", held[0],
              "and of the released reservation refused with state-conflict", flush=True)
        return waiting, run

    # The first lifetime.
    first = serve(0)
    try:
        status, capabilities, raw = request("/v1/capabilities", authorized)
        assert status == 200
        validate("Capabilities", capabilities, raw)
        epoch = capabilities["authorityEpoch"]
        attempts = []
        client = mixed_client(capabilities, authorized, attempts)
        observed, wait_for, mutate, _ = client
        workflow, create = mixed_workflow("profile_1")

        # Case 1. A run waits at its person question with a live worker, and
        # a withdrawn padding request takes the manager log above the byte
        # trigger of the pruner.
        lost_request = create_request(epoch, create)
        _, run = approve_mixed(lost_request, workflow, client)
        base = "/v1/runs/" + run
        head, _, _ = drive_mixed(run, client, stop_at_question=True, overview=False)
        control, _, _ = observed(base + "/control", "RunControl")
        assert control["supervision"] == "owned" and control["decisionHeadId"] == head, (control["supervision"], control["decisionHeadId"])
        padding = create_request(epoch, create)
        padding_uri = padding["links"]["self"]
        # Each literal replaces the previous one, so that the request view
        # stays within its one-MiB bound, while each command record keeps its
        # own claim check.
        for letter in "abc":
            current, tag, _ = observed(padding_uri, "Request")
            mutate(padding_uri, {"operation": "set-input", "input": {"name": workflow["inputs"][0]["name"],
                "source": "literal", "value": letter * 900000}}, tag)
        current, tag, _ = observed(padding_uri, "Request")
        mutate(padding_uri, {"operation": "withdraw"}, tag)
        current, _, _ = observed(padding_uri, "Request")
        assert current["phase"] == "withdrawn", ("padding request phase", current["phase"])
        assert not (flow_dir / "sealed").exists(), ("the first lifetime sealed a segment", sorted((flow_dir / "sealed").rglob("*")))
        before_kill = log_bytes()
        assert before_kill > half, ("the manager log does not reach the byte trigger", before_kill, half)
        tree, targets = workers(first, 0)
        print("PASS failures-manager case 1: run", run, "waits at person question", head, "under owned supervision, with",
              len(tree), "worker processes in process groups", targets, "and the manager log holds", before_kill,
              "bytes above the byte trigger", half, flush=True)

        # Case 2. SIGKILL of the manager process.
        stopped_after = kill(first, targets, 0)
    finally:
        ended(first, 0, True)
    assert first.returncode == -signal.SIGKILL, ("the first lifetime did not end by SIGKILL", first.returncode)
    # The run store of the lost run, by the native run identity of the Store.
    native_runs = {native for (native,) in read_store("SELECT native_run_id FROM runs WHERE id=?", (run,))}
    assert len(native_runs) == 1, ("native run of the lost run", native_runs)
    lost_store = work / "manager" / "runs" / "runs" / native_runs.pop() / "runtime"
    initial_stores = sorted(work.glob("manager/runs/runs/*/runtime"))
    assert initial_stores == [lost_store], ("run stores after the manager loss", initial_stores)
    assert len(run_starts(lost_store)) == 1 and len(start_relays(run)) == 1, ("starts of the lost run", len(run_starts(lost_store)), len(start_relays(run)))
    print("PASS failures-manager case 2: after SIGKILL of the manager, no process of the worker groups", targets, "remains after",
          round(stopped_after, 2), "seconds", flush=True)

    # Case 3. While no manager runs, seal the manager log in two segments as
    # the writer seals it: the records of the lost run, then the padding.
    actives = sorted(flow_dir.glob("*.ndjson"))
    assert len(actives) == 1, ("manager logs after the first lifetime", actives)
    active = actives[0]
    stream = active.name[:-len(".ndjson")]
    raw_lines = active.read_bytes().splitlines(keepends=True)
    assert raw_lines and all(line.endswith(b"\n") for line in raw_lines), "the first lifetime left a torn manager log"
    records = [json.loads(line) for line in raw_lines]
    first_lifetime = records[0]
    assert first_lifetime["schema"] == "notice" and first_lifetime["body"]["inline"]["notice"] == "lifetime", ("first record", first_lifetime["schema"])
    assert not [record for record in records if record["schema"] == "notice" and record["body"]["inline"]["notice"] == "shutdown"], (
        "the killed lifetime wrote a shutdown notice")
    split = next(index for index, record in enumerate(records) if record["about"].get("request") == padding["id"])
    # A crash after the COMMIT of the padding withdrawal and before its
    # receipt leaves its command ask without a reply, and a crash after the
    # command record of a further command and before its COMMIT leaves an ask
    # whose command has no ledger row. The harness truncates the log after the
    # withdrawal ask and appends such an ask, a copy of the withdrawal ask
    # with a fresh command identifier.
    withdrawal = next(item[5] for item in attempts if item[0] == "withdraw")
    withdraw_at = next(index for index, record in enumerate(records)
                       if record["schema"] == "command" and record["about"].get("command") == withdrawal["id"])
    assert split < withdraw_at and all(names(record, {padding["id"], withdrawal["id"]}) for record in records[withdraw_at + 1:]), (
        "a record after the withdrawal ask names other work", [record["schema"] for record in records[withdraw_at + 1:]])
    rolled_id = "command_" + secrets.token_hex(24)
    assert len(rolled_id) == len(withdrawal["id"]) and raw_lines[withdraw_at].count(withdrawal["id"].encode()) == 1
    raw_lines = raw_lines[:withdraw_at + 1] + [raw_lines[withdraw_at].replace(withdrawal["id"].encode(), rolled_id.encode())]
    records = [json.loads(line) for line in raw_lines]
    rolled_at = len(raw_lines) - 1
    ledger_before = dict(read_store("SELECT id,state FROM commands"))
    assert withdrawal["id"] in ledger_before and rolled_id not in ledger_before, "the ledger rows of the orphaned asks"
    lost_identities = {lost_request["id"], run}
    assert any(names(record, lost_identities) for record in records[:split]), "the first segment names no record of the lost run"
    assert not [index for index, record in enumerate(records) if index >= split and names(record, lost_identities)], (
        "a record of the lost run follows the padding")
    sealed_dir = flow_dir / "sealed" / stream
    sealed_dir.parent.mkdir(mode=0o700, exist_ok=True)
    sealed_dir.mkdir(mode=0o700)
    for start, end in ((0, split), (split, len(raw_lines))):
        segment = sealed_dir / ("%020d.ndjson" % start)
        segment.write_bytes(b"".join(raw_lines[start:end]))
        segment.chmod(0o600)
    active.unlink()
    sealed_bytes = log_bytes()
    assert sealed_bytes > half, ("the sealed manager log does not reach the byte trigger", sealed_bytes, half)
    print("PASS failures-manager case 3: the manager log of the killed lifetime has no shutdown notice and is sealed at",
          split, "of", len(records), "records, with", sealed_bytes, "bytes above the byte trigger", half,
          "; the withdrawal ask at", withdraw_at, "and the ask at", rolled_at, "without a ledger row have no reply", flush=True)

    lost_reservations = [ident for (ident,) in read_store(
        "SELECT id FROM reservations WHERE request_id=? AND state!='released'", (lost_request["id"],))]
    assert len(lost_reservations) == 1, ("the reservation of the lost run", lost_reservations)

    # The second lifetime.
    second = serve(1)
    try:
        # Case 4. The new lifetime begins with its lifetime notice and
        # reconciliation counts, and answers each orphaned command ask of the
        # killed lifetime: the withdrawal with its current receipt and the
        # ask without a ledger row with lifetime-ended. No command executes
        # again. A lost run is terminal for pruning, so the pruning round at
        # open removes the segment of the lost run and moves the floor.
        status, capabilities, raw = request("/v1/capabilities", authorized)
        assert status == 200
        validate("Capabilities", capabilities, raw)
        client = mixed_client(capabilities, authorized)
        observed, wait_for, mutate, _ = client
        actives = sorted(flow_dir.glob("*.ndjson"))
        assert actives == [active], ("manager logs of the second lifetime", actives)
        body = lifetime_notice()
        generation = body["processGeneration"]
        reconciliation = body["reconciliation"]
        assert generation != first_lifetime["body"]["inline"]["processGeneration"], ("the second lifetime notice", generation)
        # The owned run becomes lost, its dispatch-attempted approval becomes
        # unresolved, and its reservation is quarantined. Nothing else changes.
        assert reconciliation == {"preparations": 0, "requests": 0, "runs": 1, "commands": 1, "reservations": 1,
                                  "observations": 0, "uploads": 0}, ("the reconciliation counts of the second lifetime", reconciliation)
        starts = sorted(int(path.name[:20]) for path in sealed_dir.glob("*.ndjson"))
        assert starts == [split], ("the pruning round at open kept the segment of the lost run", starts)
        assert positioned()[0][0] == split and not start_relays(run), ("the floor after the pruning round at open", positioned()[0][0])
        ledger_after = dict(read_store("SELECT id,state FROM commands"))
        changed = {ident for ident in ledger_after if ledger_after[ident] != ledger_before.get(ident)}
        assert ledger_after.keys() == ledger_before.keys() and len(changed) == 1 and ledger_after[changed.pop()] == "unresolved", (
            "the restart executed or changed a command beyond the reconciliation", ledger_before, ledger_after)
        current_withdrawal, _, _ = observed(withdrawal["links"]["self"], "CommandReceipt")
        credential_sender = records[withdraw_at]["from"]
        answered = orphan_replies({
            withdraw_at: (credential_sender, "receipt", current_withdrawal),
            rolled_at: (credential_sender, "failure", {"class": "refused", "message": "lifetime-ended"})})
        print("PASS failures-manager case 4: the second lifetime begins with lifetime notice", generation,
              "and reconciliation counts", reconciliation, "; it answers the orphaned asks at", answered,
              "with the receipt that GET returns and with lifetime-ended, executes no command again,",
              "and the pruning round at open removes the segment of the lost run and keeps", starts, flush=True)

        # Case 4a. status through the live channel reports the serving
        # lifetime and the quarantined reservation, without a change.
        status_value, same = unchanged(lambda: administration({"version": 1, "operation": "status"})["result"])
        assert same, "status changed the database or the manager log"
        assert status_value["state"] == "serving" and status_value["processGeneration"] == generation, ("status of the second lifetime", status_value)
        assert status_value["activeReservations"] == 1, ("active reservations after the restart", status_value)
        print("PASS failures-manager case 4a: status reports", status_value["state"], "with", status_value["activeReservations"],
              "active reservation, without a database change or a manager-log append", flush=True)

        # Case 5. The run shows lost supervision, and no start is dispatched
        # again.
        value, _, raw = observed(base, "Run")
        (work / "lost-run.json").write_bytes(raw)
        assert value["supervision"] == "lost" and "lost-supervision" in value["limitations"], (
            "lost run", value["supervision"], value["limitations"])
        assert value["runtime"] is None or value["runtime"]["status"] != "succeeded", ("lost run runtime", value["runtime"])
        assert value["verification"]["state"] != "verified", ("lost run verification", value["verification"])
        control, _, raw = observed(base + "/control", "RunControl")
        (work / "lost-control.json").write_bytes(raw)
        assert control["supervision"] == "lost" and not control["cancelAllowed"], ("lost run control", control["supervision"], control["cancelAllowed"])
        assert sorted(work.glob("manager/runs/runs/*/runtime")) == initial_stores, "a run store appeared after the restart"
        assert len(run_starts(lost_store)) == 1 and not start_relays(run), ("starts of the lost run after the restart",
            len(run_starts(lost_store)), len(start_relays(run)))
        print("PASS failures-manager case 5: run", run, "shows lost supervision with runtime", value["runtime"] and value["runtime"]["status"],
              "and verification", value["verification"]["state"], "; its store holds one run start and the retained manager log no new start relay", flush=True)

        # Case 6. An exact replay of an earlier command returns the receipt
        # of its first response. The approval of the lost run is unresolved,
        # and its replay dispatches no start.
        replays = []
        for operation in ("enqueue", "approve"):
            _, path, headers, payload, receipt_uri, original = next(item for item in attempts if item[0] == operation)
            status, replayed, raw, _ = exchange(path, headers, method="POST", payload=payload)
            assert status == 202, ("exact replay after the restart", operation, status, replayed.get("code"))
            validate("CommandReceipt", replayed, raw)
            assert replayed == original and replayed["links"]["self"] == receipt_uri, (
                "the replay receipt differs from the original receipt", operation, replayed, original)
            current, _, _ = observed(receipt_uri, "CommandReceipt")
            replays.append((operation, original["id"], original["state"], current["state"]))
        assert replays[1][3] == "unresolved", ("the approval of the lost run", replays[1])
        assert sorted(work.glob("manager/runs/runs/*/runtime")) == initial_stores and not start_relays(run), (
            "the replay of the approval dispatched a start")
        print("PASS failures-manager case 6: exact replays returned the original receipts (operation, command, original state,",
              "current state)", replays, "and the replay of the unresolved approval dispatched no start", flush=True)

        # Case 7. The quarantined reservation of the lost run holds the only
        # execution slot until the operator releases it with the evidence of
        # its terminal record: the first event record of the run log whose
        # event ends the run.
        events = {json.loads(line)["sequence"]: json.loads(line)["event"]["type"]
                  for line in (lost_store / "events.ndjson").read_bytes().splitlines()}
        run_log = (lost_store / "flow.ndjson").read_bytes().splitlines()
        stop = next(index for index, line in enumerate(run_log) if json.loads(line)["schema"] == "event"
                    and events.get(str(json.loads(line)["body"]["event"])) in ("run.completed", "run.failed", "run.cancelled"))
        terminal_facts = {"evidence": "terminal-record", "reservationId": lost_reservations[0], "runId": run, "position": stop,
                          "recordSha256": hashlib.sha256(run_log[stop]).hexdigest(), "processGeneration": generation}
        _, second_run = release_and_run(epoch, client, lost_reservations[0], terminal_facts, "7")
        value, _, _ = observed(base, "Run")
        assert value["supervision"] == "lost", ("the lost run after the release", value["supervision"])
        assert len(run_starts(lost_store)) == 1 and not start_relays(run), "the lost run started again"

        # Case 8. A request waits in review with a live preparation when the
        # manager is killed again.
        workflow, create = mixed_workflow("profile_1")
        review_request = create_request(epoch, create)
        review_uri = review_request["links"]["self"]
        enqueue_mixed(review_request, workflow, client)
        current, _, _ = wait_for(review_uri, "Request", lambda value: value["preparationId"] is not None)
        review_preparation, _, _ = observed("/v1/preparations/" + current["preparationId"], "Preparation")
        assert current["phase"] == "review" and review_preparation["state"] == "live", (
            "request in review", current["phase"], review_preparation["state"])
        tree, targets = workers(second, 1)
        review_stopped = kill(second, targets, 1)
    finally:
        ended(second, 1, True)
    assert second.returncode == -signal.SIGKILL, ("the second lifetime did not end by SIGKILL", second.returncode)
    review_reservations = [ident for (ident,) in read_store(
        "SELECT id FROM reservations WHERE request_id=? AND state!='released'", (review_request["id"],))]
    assert len(review_reservations) == 1, ("the reservation of the request in review", review_reservations)
    review_natives = {native for (native,) in read_store("SELECT native_run_id FROM preparations WHERE request_id=?", (review_request["id"],))}
    # A crash after the command record of a release and before its receipt
    # leaves an administration ask without a reply. The harness appends two
    # such asks to the killed log: a copy of the committed release of the
    # second lifetime, whose reservation is released, and a copy that names
    # the reservation of the request in review, which no release committed.
    release_line = next(line for path in log_files() for line in path.read_bytes().splitlines()
                        if json.loads(line)["schema"] == "command"
                        and json.loads(line)["body"].get("inline", {}).get("quarantineId") == lost_reservations[0])
    uncertain_line = release_line.replace(lost_reservations[0].encode(), review_reservations[0].encode()).replace(
        lost_request["id"].encode(), review_request["id"].encode())
    assert release_line.count(lost_reservations[0].encode()) == 1 and release_line.count(lost_request["id"].encode()) == 1 \
        and len(uncertain_line) == len(release_line), "the release ask copies"
    active_bytes = active.read_bytes()
    assert active_bytes.endswith(b"\n"), "the second lifetime left a torn manager log"
    committed_at = positioned()[-1][0] + 1
    active.write_bytes(active_bytes + release_line + b"\n" + uncertain_line + b"\n")
    operator_sender = json.loads(release_line)["from"]
    print("PASS failures-manager case 8: request", review_request["id"], "waited in review with", len(tree),
          "worker processes in process groups", targets, "; after SIGKILL of the manager none remained after",
          round(review_stopped, 2), "seconds ; the release asks at", [committed_at, committed_at + 1], "have no reply", flush=True)

    # The third lifetime.
    third = serve(2)
    try:
        # Case 9. The restart invalidates the live preparation and the
        # prepared admission observation of the request in review, refuses
        # the request and quarantines its reservation, which never launched a
        # run. The approval of the completed run of the second lifetime stays
        # dispatch-attempted, as every approval does, so it becomes
        # unresolved. The operator releases the quarantine with its
        # no-launch evidence, and a new request runs.
        status, capabilities, raw = request("/v1/capabilities", authorized)
        assert status == 200
        validate("Capabilities", capabilities, raw)
        client = mixed_client(capabilities, authorized)
        observed, _, _, _ = client
        body = lifetime_notice()
        generation = body["processGeneration"]
        assert body["reconciliation"] == {"preparations": 1, "requests": 1, "runs": 0, "commands": 1, "reservations": 1,
                                          "observations": 1, "uploads": 0}, ("the reconciliation counts of the third lifetime", body["reconciliation"])
        # The open answers the orphaned release asks: the committed release
        # with committed-receipt-lost and the other with outcome-uncertain.
        # Neither releases a reservation.
        released = orphan_replies({
            committed_at: (operator_sender, "failure", {"class": "refused", "message": "committed-receipt-lost"}),
            committed_at + 1: (operator_sender, "failure", {"class": "refused", "message": "outcome-uncertain"})})
        assert read_store("SELECT state FROM reservations WHERE id=?", (review_reservations[0],)) == [("quarantined",)], (
            "an orphaned release ask released a reservation")
        status_value = administration({"version": 1, "operation": "status"})["result"]
        assert status_value["processGeneration"] == generation and status_value["activeReservations"] == 1, ("status of the third lifetime", status_value)
        quarantine = review_reservations[0]
        (review_phase,), = read_store("SELECT phase FROM requests WHERE id=?", (review_request["id"],))
        no_launch_facts = {
            "evidence": "no-launch", "reservationId": quarantine, "requestId": review_request["id"], "requestPhase": review_phase,
            "preparationStates": [state for (state,) in read_store(
                "SELECT state FROM preparations WHERE reservation_id=? ORDER BY id", (quarantine,))],
            "admissionObservationState": next((state for (state,) in read_store(
                "SELECT state FROM admission_observations WHERE reservation_id=?", (quarantine,))), None),
            "resourceKeys": [[kind, key] for kind, key in read_store(
                "SELECT kind,resource_key FROM reservation_resources WHERE reservation_id=? ORDER BY kind,resource_key", (quarantine,))],
            "processGeneration": generation}
        assert review_phase == "refused" and no_launch_facts["resourceKeys"] == [["operator", "fixture_one"]], (
            "the facts of the request in review", no_launch_facts)
        _, third_run = release_and_run(epoch, client, quarantine, no_launch_facts, "9")
        value, _, _ = observed(base, "Run")
        assert value["supervision"] == "lost", ("the lost run in the third lifetime", value["supervision"])
        print("PASS failures-manager case 9a: the third lifetime answers the orphaned release asks at", released,
              "with committed-receipt-lost and outcome-uncertain and releases no reservation for them", flush=True)
    finally:
        ended(third, 2, False)

    # Case 10. The flow verb reports no undecided command, the retained
    # lifetimes before the third without their shutdown notices and the third
    # with it, the floor past the pruned segment of the lost run, the consent
    # of each retained start relay, and each release command with its one
    # reply: a receipt for the two releases that committed with their
    # receipts, and the failure of the two orphaned release asks. The run log
    # of the lost run ends with the stop that the worker wrote when its
    # control input closed.
    stores = [store for store in sorted(work.glob("manager/runs/runs/*/runtime")) if store.parent.name not in review_natives]
    assert len(stores) == 3 and lost_store in stores, ("run stores after the third lifetime", stores)
    retained = positioned()
    flow_status, flowed, summary = read_flow("manager-failure-flow", [flow_dir] + stores)
    assert flow_status == 2 and summary["verified"] and not summary["problems"], (
        "the flow verb does not verify the logs of the three lifetimes", flow_status, summary["problems"])
    assert summary["states"]["undecided"] == [], ("undecided commands after the restarts", summary["states"]["undecided"])
    manager_summary = next(item for item in summary["logs"] if item["kind"] == "manager")
    floor = retained[0][0]
    assert manager_summary["floor"] == floor and floor >= split, ("manager log floor", manager_summary["floor"], floor, split)
    lifetimes = summary["joins"]["lifetimes"]
    notices = [position for position, record in retained if record["schema"] == "notice" and record["body"]["inline"]["notice"] == "lifetime"]
    assert [item["lifetime"]["position"] for item in lifetimes] == notices and notices[0] > 0 and lifetimes[-1]["shutdown"] is not None \
        and all(item["shutdown"] is None for item in lifetimes[:-1]), ("lifetimes", lifetimes, notices)
    assert summary["states"]["lifetimeWithoutShutdown"] == [item["lifetime"] for item in lifetimes[:-1]], (
        "lost lifetimes", summary["states"]["lifetimeWithoutShutdown"])
    assert not summary["states"]["unresolvedDelivery"], ("unresolved deliveries", summary["states"]["unresolvedDelivery"])
    starts_flowed = [record for record in flowed if record["schema"] == "relay" and record["body"]["kind"] == "start"]
    assert starts_flowed and len(summary["consent"]) == len(starts_flowed) and all(item["verified"] for item in summary["consent"]), (
        "consent", summary["consent"])
    relays = [record for record in starts_flowed if record["about"].get("managerRun") == run]
    assert not relays, ("start relays of the lost run in the flow verb", len(relays))
    releases = [record for record in flowed if record["schema"] == "command" and record["body"].get("administration") == "release-quarantine"]
    orphaned_releases = {committed_at: "committed-receipt-lost", committed_at + 1: "outcome-uncertain"}
    assert [record["body"]["quarantineId"] for record in releases] == [lost_reservations[0], lost_reservations[0], quarantine, quarantine] \
        and [record["position"] for record in releases][1:3] == sorted(orphaned_releases), (
        "release commands in the flow verb", [(record["position"], record["body"]) for record in releases])
    for record in releases:
        replies = [reply for reply in flowed if reply.get("replyTo") == record["position"]]
        if record["position"] in orphaned_releases:
            assert len(replies) == 1 and replies[0]["schema"] == "failure" and replies[0]["body"] == {
                "class": "refused", "message": orphaned_releases[record["position"]]}, ("the reply to an orphaned release ask", record["position"], replies)
        else:
            assert len(replies) == 1 and replies[0]["schema"] == "receipt" and replies[0]["body"]["operation"] == "release-quarantine" \
                and replies[0]["body"]["result"] == {"quarantineId": record["body"]["quarantineId"], "state": "released"}, (
                "the receipt of a release command", record["position"], replies)
    lost_report = next(item["report"] for item in summary["logs"] if item["kind"] == "run" and item["log"] == str(lost_store))
    last_event = json.loads((lost_store / "events.ndjson").read_bytes().splitlines()[-1])["event"]
    assert lost_report["stop"] is not None and last_event["type"] == "run.cancelled", (
        "the run log of the lost run has no stop of its worker", lost_report["stop"], last_event["type"])
    print("PASS failures-manager case 10: the flow verb exits 2 with no undecided command and verifies", len(summary["consent"]),
          "retained consents; it reports lifetimes", [item["lifetime"]["position"] for item in lifetimes[:-1]],
          "without their shutdown notices and the third lifetime with shutdown notice", lifetimes[-1]["shutdown"],
          "; it decodes the release commands at", [record["position"] for record in releases],
          "each with its one reply; floor", floor, "past the pruned segment of the lost run, and its run log stops at", lost_report["stop"],
          "with", last_event["type"], repr(last_event.get("message")), flush=True)
    print("PASS failures-manager: every manager-loss and quarantine-release case held across three lifetimes of the TLS 1.3 manager",
          second_run, third_run, flush=True)


if manager_failure_mode:
    manager_failure_checks()
    raise SystemExit(0)


def storage_checks():
    """The storage-error endings through four lifetimes of the real HTTPS
    manager. Each numbered case prints one PASS line."""
    import sqlite3
    authorized = {"Authorization": "Bearer " + bearer}
    flow_dir = work / "manager" / "flow"
    capacity = STORAGE_COMMAND_CAPACITY
    reserve = 16 * capacity
    ordinary_ceiling = STORAGE_LEDGER - reserve - capacity
    terminal = ("succeeded", "failed", "cancelled")

    def serve(index):
        """Start one foreground manager lifetime on the same root and wait
        for HTTPS readiness."""
        with (work / f"server-{index}.stdout").open("wb") as output, (work / f"server-{index}.stderr").open("wb") as errors:
            process = subprocess.Popen([str(runner), "--manager", "serve", "--config", str(config),
                                        "+RTS", "-N" + native, "-RTS"], stdout=output, stderr=errors)
        wait_ready(process)
        return process

    def stop(process, index):
        """End one lifetime as the operator stops it and keep its exit status."""
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=25)
        (work / f"server-{index}.exit").write_text(str(process.returncode) + "\n")

    def database(statement, parameters=()):
        """The rows of one query through a read-only connection to the
        coordination database."""
        found = sorted((work / "manager").rglob("coordination.sqlite3"))
        assert len(found) == 1, ("coordination database", found)
        connection = sqlite3.connect(found[0].as_uri() + "?mode=ro", uri=True)
        try:
            return connection.execute(statement, parameters).fetchall()
        finally:
            connection.close()

    def ledger():
        """The charge of the command ledger, as Commands.checkCapacity reads it."""
        rows = database("SELECT bytes FROM command_ledger_usage WHERE singleton=1")
        assert len(rows) == 1, ("command ledger usage", rows)
        return rows[0][0]

    def commands():
        return database("SELECT count(*) FROM commands")[0][0]

    def setup():
        """The capabilities, the mixed client, the mixed-controls workflow and
        its creation body for the current lifetime."""
        status, capabilities, raw = request("/v1/capabilities", authorized)
        assert status == 200
        validate("Capabilities", capabilities, raw)
        client = mixed_client(capabilities, authorized)
        status, catalogue, _ = request("/v1/workflows?profileId=profile_1", authorized)
        assert status == 200
        workflow = next(item for item in catalogue["items"] if item["name"] == "mixed-controls")
        create = json.dumps({"workflowId": workflow["id"], "descriptorRevision": workflow["revision"],
                             "profileId": workflow["profileId"], "profileRevision": workflow["profileRevision"]},
                            separators=(",", ":")).encode()
        return capabilities, client, workflow, create

    def create_attempt(capabilities, create):
        """One ordinary command, a request creation. Returns the status, the
        decoded body and the idempotency key."""
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        status, value, raw, _ = exchange("/v1/requests", authorized | {"Content-Type": "application/json", "Idempotency-Key": key},
                                         method="POST", payload=create)
        if status == 201:
            validate("Request", value, raw)
        return status, value, key

    def created_request(capabilities, create):
        status, value, _ = create_attempt(capabilities, create)
        assert status == 201, ("request creation", status, value.get("code"))
        return value

    def unknown_key(key):
        return not database("SELECT id FROM commands WHERE idempotency_key=?", (key,))

    def cancel(capabilities, client, run, name):
        """Cancel the running run through its control and wait for the run to
        end. Returns the receipt and the acknowledged command."""
        observed, wait_for, _, _ = client
        base = "/v1/runs/" + run
        control, tag, _ = observed(base + "/control", "RunControl")
        assert control["cancelAllowed"] and control["supervision"] == "owned", ("cancel not allowed", control["cancelAllowed"], control["supervision"])
        key = capabilities["authorityEpoch"] + "." + secrets.token_urlsafe(16)
        status, receipt, raw, _ = exchange(base + "/control", authorized | {"Content-Type": "application/json", "Idempotency-Key": key,
                                           "If-Match": tag}, method="POST", payload=b'{"operation":"cancel"}')
        assert status == 202, (name + " cancel", status, receipt.get("code"))
        validate("CommandReceipt", receipt, raw)
        command, _, raw = wait_for(receipt["links"]["self"], "CommandReceipt",
            lambda value: value["acknowledgement"] is not None or value["state"] in ("refused", "unresolved"))
        (work / (name + "-cancel-command.json")).write_bytes(raw)
        assert command["state"] in ("acknowledged", "effect-observed"), (name + " cancel state", command["state"])
        snapshot, _, raw = wait_for(base + "/snapshot", "RunSnapshot",
            lambda value: value["runtime"] is not None and value["runtime"]["status"] in terminal)
        (work / (name + "-cancel-terminal.json")).write_bytes(raw)
        assert snapshot["runtime"]["status"] == "cancelled", (name + " run terminal status", snapshot["runtime"]["status"])
        return receipt, command

    def refused_download(artifact, name):
        """Request the content of the artifact and require a refusal. Returns
        the status and the frozen problem code."""
        connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=7)
        try:
            connection.request("GET", artifact["download"], headers=authorized | {"Accept": "application/octet-stream"})
            response = connection.getresponse()
            body = response.read(1048577)
            status = response.status
            media = response.getheader("Content-Type")
        finally:
            connection.close()
        (work / (name + "-download.body")).write_bytes(body)
        assert status != 200 and media != "application/octet-stream", (name + " download served bytes", status, media, len(body))
        value = frozen.parse_json(body)
        validate("Problem", value, body)
        return status, value["code"]

    def result_ending(client, run, name):
        """The result item of the run from a fresh outputs read, and then the run."""
        observed = client[0]
        base = "/v1/runs/" + run
        outputs, _, raw = observed(base + "/outputs", "OutputPage")
        (work / (name + "-outputs.json")).write_bytes(raw)
        result = next(item for item in outputs["items"] if item["kind"] == "result")
        value, _, raw = observed(base, "Run")
        (work / (name + "-run.json")).write_bytes(raw)
        return value, result

    # Case 1. At the command-ledger ceiling, an ordinary command is refused
    # with storage-quota while a run waits at its person question.
    first = serve(0)
    try:
        capabilities, client, workflow, create = setup()
        observed, wait_for, _, _ = client
        assert ledger() == 0, ("the command ledger is not empty before the first command", ledger())
        _, ceiling_run = approve_mixed(created_request(capabilities, create), workflow, client)
        head, _, _ = drive_mixed(ceiling_run, client, stop_at_question=True, overview=False)
        run_charge = ledger()
        assert run_charge == 4 * capacity, ("the commands of one run", run_charge)
        accepted = []
        for _ in range(8):
            used = ledger()
            status, value, key = create_attempt(capabilities, create)
            if used <= ordinary_ceiling:
                assert status == 201, ("ordinary command below the ledger ceiling", used, status, value.get("code"))
                accepted.append(value["id"])
                continue
            assert status == 429 and value["code"] == "storage-quota", ("ordinary command at the ledger ceiling", used, status, value.get("code"))
            assert unknown_key(key), "the refused command left a command row"
            break
        else:
            raise AssertionError("no ordinary command reached the command-ledger ceiling")
        print("PASS storage case 1: with globalMutationLedgerBytes", STORAGE_LEDGER, "the four commands of run", ceiling_run,
              "charge", run_charge, "bytes, run", ceiling_run, "waits at question", head, "and the next ordinary command after",
              len(accepted), "more is refused with 429 storage-quota at charge", used, "above", ordinary_ceiling, "with no command row", flush=True)

        # Case 2. A cancel uses the reserve and still ends the run cancelled.
        receipt, command = cancel(capabilities, client, ceiling_run, "ceiling")
        after_cancel = ledger()
        assert after_cancel == run_charge + (len(accepted) + 1) * capacity, ("the charge of the cancel", after_cancel)
        print("PASS storage case 2: cancel", receipt["id"], "was accepted at the ceiling and", command["state"], "and run", ceiling_run,
              "ended cancelled; the command ledger charge is", after_cancel, "of", STORAGE_LEDGER, flush=True)
    finally:
        stop(first, 0)

    # Case 3. After an ordinary restart, ordinary commands are still refused,
    # because the command ledger is not pruned.
    restarted = serve(1)
    try:
        capabilities, client, workflow, create = setup()
        status, value, key = create_attempt(capabilities, create)
        assert status == 429 and value["code"] == "storage-quota", ("ordinary command after the restart", status, value.get("code"))
        assert unknown_key(key), "the refused command left a command row after the restart"
        assert ledger() == after_cancel, ("the command ledger changed across the restart", ledger(), after_cancel)
        snapshot, _, _ = client[0]("/v1/runs/" + ceiling_run + "/snapshot", "RunSnapshot")
        assert snapshot["runtime"]["status"] == "cancelled", ("the cancelled run after the restart", snapshot["runtime"]["status"])
        print("PASS storage case 3: after an ordinary restart an ordinary command is still refused with 429 storage-quota, the command",
              "ledger keeps its charge", after_cancel, "and run", ceiling_run, "stays cancelled", flush=True)
    finally:
        stop(restarted, 1)

    # Case 4. The manager-log positions continue across the restart, and the
    # flow verb reports the floor.
    sealed = sorted((flow_dir / "sealed").glob("*/*.ndjson"))
    expected_floor = int(sealed[0].name[:20]) if sealed else 0
    stores = sorted(work.glob("manager/runs/runs/*/runtime"))
    flow_status, flowed, summary = read_flow("storage-ledger-flow", [flow_dir] + stores, runner)
    manager_summary = next(item for item in summary["logs"] if item["kind"] == "manager")
    lifetimes = summary["joins"]["lifetimes"]
    assert summary["verified"] and not summary["problems"], ("the flow verb does not verify the ledger lifetimes", flow_status, summary["problems"])
    assert manager_summary["floor"] == expected_floor, ("manager log floor", manager_summary["floor"], expected_floor)
    assert len(lifetimes) == 2 and all(item["shutdown"] is not None for item in lifetimes), ("lifetimes", lifetimes)
    assert lifetimes[1]["lifetime"]["position"] == lifetimes[0]["shutdown"] + 1, ("the positions do not continue", lifetimes)
    print("PASS storage case 4: the flow verb exits", flow_status, "and verifies both lifetimes; the second lifetime notice at",
          lifetimes[1]["lifetime"]["position"], "follows the shutdown notice at", lifetimes[0]["shutdown"], "and the floor is",
          manager_summary["floor"], "with", len(sealed), "sealed segments", flush=True)

    # Case 5. The operator raises the ceiling. While a run waits at its
    # question, the active manager log is renamed away, so that every append
    # fails, and an ordinary command is refused with storage-unavailable.
    configuration["limits"]["globalMutationLedgerBytes"] = STORAGE_RAISED_LEDGER
    config.write_text(json.dumps(configuration))
    archive = work / "storage-fault-flow"
    faulted = serve(2)
    try:
        capabilities, client, workflow, create = setup()
        _, fault_run = approve_mixed(created_request(capabilities, create), workflow, client)
        head, _, _ = drive_mixed(fault_run, client, stop_at_question=True, overview=False)
        actives = sorted(flow_dir.glob("*.ndjson"))
        assert len(actives) == 1, ("manager logs before the fault", actives)
        stream = actives[0].name[:-len(".ndjson")]
        archive.mkdir(mode=0o700)
        archived = archive / actives[0].name
        os.rename(actives[0], archived)
        rows = commands()
        status, value, key = create_attempt(capabilities, create)
        assert status == 503 and value["code"] == "storage-unavailable", ("ordinary command with every append failing", status, value.get("code"))
        assert commands() == rows and unknown_key(key), ("the refused command left a command row", rows, commands())
        print("PASS storage case 5: with the active manager log renamed away while run", fault_run, "waits at question", head,
              "an ordinary command is refused with 503 storage-unavailable and the ledger keeps its", rows, "command rows", flush=True)

        # Case 6. A cancel still ends the running run cancelled, and the
        # writer creates no new log at the renamed path.
        receipt, command = cancel(capabilities, client, fault_run, "fault")
        assert commands() == rows + 1, ("the cancel row", rows, commands())
        assert not sorted(flow_dir.glob("*.ndjson")), "the broken writer created a new manager log"
        print("PASS storage case 6: cancel", receipt["id"], "was accepted and", command["state"], "and run", fault_run,
              "ended cancelled while every manager-log append failed; the writer created no new log", flush=True)
    finally:
        stop(faulted, 2)
    assert not sorted(flow_dir.glob("*.ndjson")), "the broken writer created a new manager log at shutdown"

    # Case 7. The archived log ends without the cancel and without the
    # shutdown notice of the faulted lifetime. After the operator moves the
    # rest of the log out, the next lifetime begins a new log at position 0
    # with its lifetime notice and no gap notice.
    for part in ("sealed", "claims"):
        if (flow_dir / part / stream).exists():
            (archive / part).mkdir(mode=0o700)
            os.rename(flow_dir / part / stream, archive / part / stream)
    fault_stores = sorted(work.glob("manager/runs/runs/*/runtime"))
    flow_status, flowed, summary = read_flow("storage-fault-flow", [archived] + fault_stores, runner)
    lifetimes = summary["joins"]["lifetimes"]
    assert summary["verified"] and not summary["problems"], ("the flow verb does not verify the archived log", flow_status, summary["problems"])
    assert len(lifetimes) == 3 and lifetimes[2]["shutdown"] is None, ("archived lifetimes", lifetimes)
    assert summary["states"]["lifetimeWithoutShutdown"] == [lifetimes[2]["lifetime"]], ("archived lost lifetimes", summary["states"]["lifetimeWithoutShutdown"])
    assert not [record for record in flowed if record["schema"] == "command" and record["body"].get("operation") == "cancel"
                and record["position"] > lifetimes[2]["lifetime"]["position"]], "the archived log holds the cancel of the faulted lifetime"
    assert not [record for record in flowed if record["schema"] == "notice" and record["body"].get("notice") == "gap"], "the archived log holds a gap notice"
    recovered = serve(3)
    try:
        actives = sorted(flow_dir.glob("*.ndjson"))
        assert actives == [flow_dir / (stream + ".ndjson")], ("manager logs after the recovery", actives)
        opening = [json.loads(line) for line in actives[0].read_bytes().splitlines()]
        assert opening and opening[0]["schema"] == "notice" and opening[0]["body"]["inline"]["notice"] == "lifetime", ("first record of the new log", opening[:1])
        assert not [record for record in opening if record["schema"] == "notice" and record["body"]["inline"]["notice"] == "gap"], "the new log holds a gap notice"
        print("PASS storage case 7: the flow verb verifies the archived log with", len(lifetimes), "lifetimes, the last without its shutdown notice, and no cancel",
              "command and no gap notice of the faulted lifetime; the new log begins with lifetime notice",
              opening[0]["body"]["inline"]["processGeneration"], "and reconciliation counts", opening[0]["body"]["inline"]["reconciliation"],
              "and holds no gap notice", flush=True)

        # Case 8. A removed result keeps the run succeeded, and the result
        # and its download become unavailable.
        capabilities, client, workflow, create = setup()
        observed = client[0]
        result_stores = []
        for name, damage in (("removed", "missing"), ("corrupted", "corrupt")):
            before = set(work.glob("manager/runs/runs/*/runtime"))
            _, run = approve_mixed(created_request(capabilities, create), workflow, client)
            _, answered, retried = drive_mixed(run, client, overview=False)
            assert answered and retried, ("result run decisions", answered, retried)
            artifact = verified_download(run, client, authorized)
            store = sorted(set(work.glob("manager/runs/runs/*/runtime")) - before)
            assert len(store) == 1, ("run store of the result run", store)
            result_stores += store
            result_file = store[0] / "result.json"
            original = result_file.read_bytes()
            assert len(original) == int(artifact["bytes"]), ("result file length", len(original), artifact["bytes"])
            if damage == "missing":
                result_file.unlink()
            else:
                # One changed byte keeps the length and breaks the digest.
                mode = stat.S_IMODE(result_file.stat().st_mode)
                result_file.chmod(mode | stat.S_IWUSR)
                middle = len(original) // 2
                result_file.write_bytes(original[:middle] + bytes([original[middle] ^ 0x01]) + original[middle + 1:])
                result_file.chmod(mode)
            status, code = refused_download(artifact, name)
            assert (status, code) == (404, "unavailable-resource"), (name + " download", status, code)
            value, _, _ = observed("/v1/runs/" + run, "Run")
            assert value["runtime"]["status"] == "succeeded" and value["verification"]["state"] == "verified", (
                name + " run after the refused download", value["runtime"], value["verification"])
            value, result = result_ending(client, run, name)
            assert value["runtime"]["status"] == "succeeded", (name + " run runtime", value["runtime"])
            assert result["verification"] == {"state": "unavailable", "artifactId": artifact["id"], "reason": damage} and result["artifact"] is None, (
                name + " result item", result)
            assert value["verification"]["state"] == "unavailable", (name + " run verification", value["verification"])
            status, code = refused_download(artifact, name + "-again")
            assert (status, code) == (404, "unavailable-resource"), (name + " second download", status, code)
            print(f"PASS storage case {8 if damage == 'missing' else 9}: the", name, "result of run", run, "keeps runtime succeeded",
                  "with verification unavailable and reason", damage, "and GET", artifact["download"], "refuses with", status, code,
                  "and serves no bytes", flush=True)
    finally:
        stop(recovered, 3)

    # Case 10. The flow verb reads the new log from position 0 with one
    # lifetime and its shutdown notice.
    flow_status, flowed, summary = read_flow("storage-new-flow", [flow_dir] + result_stores, runner)
    lifetimes = summary["joins"]["lifetimes"]
    assert flow_status == 0 and summary["verified"] and not summary["problems"], ("the flow verb does not verify the new log", flow_status, summary["problems"])
    assert flowed and flowed[0]["position"] == 0 and flowed[0]["schema"] == "notice" and flowed[0]["body"].get("notice") == "lifetime", (
        "the new log does not begin with its lifetime notice at 0", flowed[:1])
    assert len(lifetimes) == 1 and lifetimes[0]["shutdown"] is not None, ("new log lifetimes", lifetimes)
    assert not [record for record in flowed if record["schema"] == "notice" and record["body"].get("notice") == "gap"], "the new log holds a gap notice"
    print("PASS storage case 10: the flow verb exits", flow_status, "and reads the new log from position 0 with one lifetime and its",
          "shutdown notice at", lifetimes[0]["shutdown"], "and no gap notice", flush=True)
    print("PASS storage: every storage-error ending held across four lifetimes of the TLS 1.3 manager", flush=True)


if storage_mode:
    storage_checks()
    raise SystemExit(0)


if person_mode:
    person_checks()
    raise SystemExit(0)


if control_profiles:
    facts = control_checks()
    if live_mode:
        live_flow_checks(facts)
    print("PASS", sys.argv[5] + ": every control case held against the running TLS 1.3 manager", flush=True)
    raise SystemExit(0)


if exports_mode:
    export_checks()
    raise SystemExit(0)


if lineage_mode:
    lineage_checks()
    raise SystemExit(0)


if captures_mode:
    capture_checks()
    raise SystemExit(0)


if routes_mode:
    route_checks()
    raise SystemExit(0)


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
                                # The number of deferred-key outcomes that the journey sees. A page-set
                                # read in flight defers a mutation key, and the journey presses it again.
                                deferred_keys = [0]

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
                                            if refusal.startswith(operation + " deferred during a page-set read"):
                                                deferred_keys[0] += 1
                                            assert refusal.startswith((operation + " deferred", operation + " did not start: the decision observation",
                                                                       operation + " did not start: the control observation",
                                                                       operation + " did not start: a command is in progress")), ("TUI did not start the " + operation, refusal)
                                            # A deferral pauses automatic refresh until the deferring read
                                            # completes, for at most 3 seconds, and the next explicit press
                                            # follows. After a stale refusal the next current read installs
                                            # first.
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
                                                # y, and a later y follows the bounded refresh pause.
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
                                                    print("KEY OUTCOME:", key_outcome(visible)[1], flush=True)
                                                    deferred_keys[0] += 1
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
                                (work / "journey-deferred-keys.txt").write_text(str(deferred_keys[0]) + "\n")
                                print("JOURNEY deferred-key outcomes:", deferred_keys[0], flush=True)
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
