#!/usr/bin/env python3
"""Deterministic machine-protocol runner used only by the TUI PTY stress gate."""

from __future__ import annotations

import hashlib
import json
import os
import select
import signal
import sys
import threading
import time
from pathlib import Path

DESCRIPTOR = {
    "descriptorVersion": 3,
    "runnerVersion": "fixture-1",
    "protocolVersions": [1, 2],
    "storeVersions": [1, 2],
    "capabilities": {
        "structuredRun": True,
        "wholeRunCancel": True,
        "controlFd": 3,
        "requestControls": True,
        "steering": True,
        "interactiveRetry": True,
        "schedulerRedirect": True,
        "semanticResume": True,
        "immutableFork": True,
        "restartFromScratch": True,
        "consults": 1,
        "observes": 0,
        "effects": 0,
        "effectful": False,
        "toolExecution": False,
    },
    "name": "control-stress",
    "blurb": "Exercise controls and bounded event pressure",
    "result": "text",
    "level": "pipeline",
    "size": 1,
    "askNodes": 1,
    "minFold": 1,
    "maxFold": 1,
    "paths": 1,
    "inputs": [],
    "runFacts": [],
    "pins": ["fixture-profile"],
    "personAnsweringModes": ["local-control"],
}


def compact(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def spawn_sleeper(ready: str, redirect: bool = False) -> None:
    reader, writer = os.pipe()
    if os.fork() == 0:
        os.close(reader)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if redirect:
            null = os.open(os.devnull, os.O_RDWR)
            os.dup2(null, 1); os.dup2(null, 2); os.close(null)
        Path(ready).write_text(str(os.getpid()))
        os.write(writer, b"1"); os.close(writer)
        time.sleep(60)
        os._exit(0)
    os.close(writer)
    assert os.read(reader, 1) == b"1"
    os.close(reader)


def main() -> None:
    arguments = sys.argv[1:]
    if arguments[:1] == [os.environ.get("TUI_FIXTURE_PAUSE")]:
        child = os.environ.get("TUI_FIXTURE_HELP_CHILD")
        if child:
            spawn_sleeper(os.environ["TUI_FIXTURE_READY"], child == "redirect")
            print("fixture help")
            return
        term_seen = os.environ.get("TUI_FIXTURE_TERM_SEEN")
        if term_seen:
            signal.signal(signal.SIGTERM, lambda _signal, _frame: Path(term_seen).write_text("TERM"))
        else:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        Path(os.environ["TUI_FIXTURE_READY"]).write_text(str(os.getpid()))
        time.sleep(60)
    if arguments == ["frontend", "--capabilities"]:
        capabilities = {
            "version": 1,
            "operation": "capabilities",
            "server": {
                "runnerId": "fixture",
                "executable": str(Path(__file__).resolve()),
                "runnerVersion": DESCRIPTOR["runnerVersion"],
            },
            "session": {
                "versions": [1],
                "operations": ["prepare", "prepare-lineage", "start", "discard"],
                "inputSources": ["literal", "file", "transport"],
                "invocationVersions": [1],
                "maxRequestBytes": 2 * 1024 * 1024,
            },
            "io": {
                "versions": [1],
                "operations": ["open-root", "read-question", "read-result", "list-runs", "read-run"],
            },
            "export": {
                "versions": [1],
                "operations": ["export-result"],
                "format": "result-json",
                "destination": "state-exports",
            },
            "frontendManifestVersions": [2, 3],
            "legacyFrontendManifests": True,
        }
        sys.stdout.buffer.write(compact(capabilities) + b"\n")
        return
    if arguments[:1] == ["list"]:
        sys.stdout.buffer.write(compact([DESCRIPTOR]) + b"\n")
        return
    if arguments[:1] == ["--routing"]:
        persona_index = arguments.index("--persona") if "--persona" in arguments else -1
        persona = arguments[persona_index + 1] if persona_index >= 0 else "fixture"
        engine = "work-engine" if persona == "work" else "fixture-engine"
        session = "work-session" if persona == "work" else "fixture-session"
        model = "work-model" if persona == "work" else "fixture-model"
        routing = {
            "version": 2,
            "persona": {"name": persona, "source": "command-line" if persona_index >= 0 else "default"},
            "launch": {"targetKind": "routing", "arguments": ["--routing"], "fingerprint": "f" * 64},
            "availablePersonas": ["fixture", "work"],
            "engines": [
                {
                    "name": engine,
                    "backend": f"deck:{session}",
                    "provider": "fixture-provider",
                    "credentialReady": os.environ.get("TUI_FIXTURE_CREDENTIAL_READY", "1") != "0",
                    "launch": {"targetKind": "deck", "arguments": ["--session", session], "fingerprint": "f" * 64},
                },
            ],
            "profiles": [
                {
                    "name": "fixture-profile",
                    "rungs": [
                        {
                            "axis": "fixture",
                            "rung": 0,
                            "backend": f"deck:{session}",
                            "router": engine,
                            "provider": "fixture-provider",
                            "model": model,
                            "thinking": "medium",
                            "maxOutput": 4096,
                            "executionFingerprint": f"sha256:{persona}-execution",
                            "options": {},
                            "inventory": {"source": "static"},
                        }
                    ],
                }
            ],
            "warnings": [],
        }
        sys.stdout.buffer.write(compact(routing) + b"\n")
        return
    if arguments[:1] == ["help"]:
        if os.environ.get("TUI_FIXTURE_IGNORE_TERM") == "1":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(60)
        sys.stdout.write("fixture help\n")
        return
    if arguments[:1] == ["plan"]:
        plan = dict(DESCRIPTOR)
        plan["capabilities"] = dict(DESCRIPTOR["capabilities"])
        plan["descriptorVersion"] = 2
        plan.pop("personAnsweringModes")
        plan.update({
            "codes": ["text"],
            "fold": [{"consults": 1, "paths": 1}],
            "program": {"fixture": True},
        })
        if os.environ.get("TUI_FIXTURE_PLAN_VARIANT") == "post-input":
            plan.update({"size": 7, "askNodes": 4, "minFold": 2, "maxFold": 3, "paths": 4, "pins": ["input-profile"], "runFacts": ["input-selected"]})
            plan["capabilities"].update({"consults": 3, "observes": 0, "effects": 1, "effectful": True, "toolExecution": True})
            plan["fold"] = [{"consults": 2, "paths": 3}, {"consults": 3, "paths": 1}]
        if os.environ.get("TUI_FIXTURE_PLAN_VARIANT") == "malformed":
            plan["unknown"] = True
        if os.environ.get("TUI_FIXTURE_PLAN_VARIANT") == "identity-mismatch":
            plan["name"] = "another-workflow"
        sys.stdout.buffer.write(compact(plan) + b"\n")
        return
    if arguments[:1] == ["machine"]:
        run_machine(arguments[1], os.environ.get("TUI_FIXTURE_MODE", "controls"))
        return
    print("fixture runner: unsupported arguments", arguments, file=sys.stderr)
    raise SystemExit(2)


def run_machine(run_id: str, mode: str) -> None:
    sequence = 0
    runtime_directory = Path(os.environ["AGENT_CAT_RUN_STORE"])
    runtime_directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    journal_path = runtime_directory / "events.ndjson"
    journal = journal_path.open("xb", buffering=0)
    os.chmod(journal_path, 0o600)
    emit_lock = threading.Lock()

    def emit(event: dict[str, object]) -> int:
        nonlocal sequence
        with emit_lock:
            emitted_sequence = sequence
            envelope = {
                "protocolVersion": 2,
                "runId": run_id,
                "sequence": str(sequence),
                "timestamp": "2026-09-04T00:00:00Z",
                "event": event,
            }
            sequence += 1
            encoded = compact(envelope) + b"\n"
            journal.write(encoded)
            sys.stdout.buffer.write(encoded)
            sys.stdout.buffer.flush()
            return emitted_sequence

    if mode == "invalid-transition":
        emit({"type": "occurrence.started", "occurrenceId": "0", "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "before start"})
        time.sleep(60)
        return
    if mode == "no-newline":
        envelope = {
            "protocolVersion": 2,
            "runId": run_id,
            "sequence": "0",
            "timestamp": "2026-09-04T00:00:00Z",
            "event": {"type": "run.started", "workflow": "control-stress", "target": "scripted", "personAnswering": "local-control"},
        }
        sys.stdout.buffer.write(compact(envelope))
        sys.stdout.buffer.flush()
        return
    emit({"type": "run.started", "workflow": "control-stress", "target": "scripted", "personAnswering": "local-control"})
    if mode in {"startup-failure", "request-failure"}:
        message = "Configured model is unavailable. Select an offered model.\n" + "diagnostic context\n" * 80 + "LAST_DIAGNOSTIC"
        if mode == "request-failure":
            emit({"type": "occurrence.started", "occurrenceId": "0", "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "fixture prompt"})
            emit({"type": "attempt.started", "occurrenceId": "0", "attempt": "0", "target": "fixture"})
            emit({"type": "attempt.failed", "occurrenceId": "0", "attempt": "0", "failure": "transport", "message": message})
            emit({"type": "occurrence.failed", "occurrenceId": "0", "failure": "transport", "message": message})
        emit({"type": "run.failed", "failure": "transport", "message": message})
        return
    if mode in {"orphan-pipes", "orphan-redirect", "term-orphan"}:
        spawn_sleeper(os.environ["TUI_FIXTURE_READY"], mode == "orphan-redirect")
        if mode == "term-orphan":
            emit({"type": "occurrence.started", "occurrenceId": "0", "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "orphan ready"})
            time.sleep(60)
        return
    if mode == "count-pressure":
        for occurrence in range(2049):
            emit({"type": "occurrence.started", "occurrenceId": str(occurrence), "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "bounded"})
        time.sleep(60)
        return
    if mode == "malformed":
        sys.stdout.buffer.write(b"{not-json}\n")
        sys.stdout.buffer.flush()
        time.sleep(60)
        return
    if mode == "persons":
        run_persons(emit, run_id)
        return
    if mode in {"recoveries", "auth-recovery"}:
        run_recoveries(emit, run_id, auth_failure=mode == "auth-recovery")
        return
    if mode == "mixed-decisions":
        run_mixed_decisions(emit, run_id)
        return
    if mode == "preempt-editor":
        run_preempt_editor(emit, run_id)
        return
    if mode == "person-retry":
        run_person_retry(emit, run_id)
        return
    if mode == "term-resistant":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        emit({"type": "occurrence.started", "occurrenceId": "0", "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "term resistant"})
        time.sleep(60)
        return
    emit({"type": "occurrence.started", "occurrenceId": "0", "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "fixture prompt"})
    if mode == "ignore-cancel":
        control = json.loads(sys.stdin.buffer.readline())
        assert control["command"]["type"] == "cancelRun", control
        time.sleep(60)
        return
    if mode == "simple":
        emit({"type": "attempt.started", "occurrenceId": "0", "attempt": "0", "target": "fixture-model"})
        emit({"type": "attempt.output", "occurrenceId": "0", "attempt": "0", "stream": "transport-text", "chunk": "fixture answer"})
        emit({"type": "attempt.progress", "occurrenceId": "0", "attempt": "0", "progress": {"kind": "message", "text": "public status"}})
        emit({"type": "attempt.progress", "occurrenceId": "0", "attempt": "0", "progress": {"kind": "tool", "tool": {"id": "tool-1", "title": "Apply diff", "toolKind": "edit", "status": "pending"}}})
        emit({"type": "attempt.progress", "occurrenceId": "0", "attempt": "0", "progress": {"kind": "tool", "tool": {"id": "tool-1", "status": "completed", "summary": "read complete\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new"}}})
        emit({"type": "attempt.progress", "occurrenceId": "0", "attempt": "0", "progress": {"kind": "todos", "items": [{"content": "Check result", "priority": "high", "status": "completed"}]}})
        emit({"type": "attempt.progress", "occurrenceId": "0", "attempt": "0", "progress": {"kind": "usage", "usage": {"used": "10", "size": "100"}}})
        emit({"type": "attempt.progress", "occurrenceId": "0", "attempt": "0", "progress": {"kind": "reasoning-summary", "text": "Public summary"}})
        emit({"type": "attempt.completed", "occurrenceId": "0", "attempt": "0", "source": "fixture"})
        finish(emit, run_id)
        return
    if mode == "stress":
        emit({"type": "occurrence.started", "occurrenceId": "1", "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "concurrent fixture prompt"})
        emit({"type": "attempt.started", "occurrenceId": "0", "attempt": "0", "target": "fixture"})
        emit({"type": "attempt.started", "occurrenceId": "1", "attempt": "0", "target": "fixture"})
        chunk = "x" * 1024
        steered = False
        for index in range(10240):
            occurrence = str(index % 2)
            emit({"type": "attempt.output", "occurrenceId": occurrence, "attempt": "0", "stream": "transport-text", "chunk": chunk})
            if not steered and index % 16 == 0 and select.select([sys.stdin.buffer], [], [], 0)[0]:
                control = read_control("steerOccurrence", "0", {"occurrenceId": "0", "attemptNumber": "0"})
                acknowledge(emit, control, "accepted", "stress steer accepted")
                emit({"type": "attempt.steered", "occurrenceId": "0", "attempt": "0", "controlId": control["controlId"], "timing": control["command"]["timing"], "text": control["command"]["text"]})
                acknowledge(emit, control, "delivered", "stress steer delivered")
                steered = True
        if not steered and select.select([sys.stdin.buffer], [], [], 5)[0]:
            control = read_control("steerOccurrence", "0", {"occurrenceId": "0", "attemptNumber": "0"})
            acknowledge(emit, control, "accepted", "stress steer accepted")
            emit({"type": "attempt.steered", "occurrenceId": "0", "attempt": "0", "controlId": control["controlId"], "timing": control["command"]["timing"], "text": control["command"]["text"]})
            acknowledge(emit, control, "delivered", "stress steer delivered")
            steered = True
        sys.stderr.buffer.write(b"Authoriza")
        sys.stderr.buffer.flush()
        time.sleep(0.05)
        sys.stderr.buffer.write(b"tion: fixture-secret-must-not-persist\n")
        diagnostic_chunk = b"diagnostic filler\n" * 4096
        for _ in range(192):
            sys.stderr.buffer.write(diagnostic_chunk)
        sys.stderr.buffer.flush()
        emit({"type": "attempt.completed", "occurrenceId": "0", "attempt": "0", "source": "fixture"})
        emit({"type": "attempt.completed", "occurrenceId": "1", "attempt": "0", "source": "fixture"})
        emit({"type": "occurrence.completed", "occurrenceId": "0", "source": "fixture", "answer": "fixture answer"})
        emit({"type": "occurrence.completed", "occurrenceId": "1", "source": "fixture", "answer": "fixture answer"})
        complete_run(emit, run_id, ["0", "1"])
        return
    if mode == "unread-control":
        emit({"type": "attempt.started", "occurrenceId": "0", "attempt": "0", "target": "fixture"})
        import array
        import fcntl
        import termios

        pending = array.array("i", [0])
        while pending[0] == 0:
            fcntl.ioctl(sys.stdin.fileno(), termios.FIONREAD, pending, True)
            time.sleep(0.005)
        Path(os.environ["TUI_FIXTURE_READY"]).write_text(str(pending[0]))
        time.sleep(60)
        return
    if mode not in {"controls", "heartbeat"}:
        raise SystemExit(f"unknown TUI_FIXTURE_MODE {mode}")

    emit({"type": "occurrence.dispatch-pending", "occurrenceId": "0", "targets": ["left", "right"]})
    redirect = read_control("redirectOccurrence", "0", None)
    control_id = redirect["controlId"]
    acknowledge(emit, redirect, "accepted", "redirect accepted")
    emit({"type": "occurrence.redirected", "occurrenceId": "0", "controlId": control_id, "target": redirect["command"]["target"]})
    acknowledge(emit, redirect, "delivered", "redirect delivered")

    emit({"type": "attempt.started", "occurrenceId": "0", "attempt": "0", "target": redirect["command"]["target"]})
    steer = read_control("steerOccurrence", "0", {"occurrenceId": "0", "attemptNumber": "0"})
    assert steer["command"]["timing"] == "next-boundary", steer
    assert steer["command"]["text"] == "focus fixture", steer
    acknowledge(emit, steer, "accepted", "steer accepted")
    emit({"type": "attempt.steered", "occurrenceId": "0", "attempt": "0", "controlId": steer["controlId"], "timing": "next-boundary", "text": "focus fixture"})
    acknowledge(emit, steer, "delivered", "steer delivered")
    emit({"type": "attempt.failed", "occurrenceId": "0", "attempt": "0", "failure": "transport", "message": "fixture gap"})
    emit(
        {
            "type": "occurrence.recovery-pending",
            "occurrenceId": "0",
            "gap": "transport",
            "message": "fixture gap",
            "choices": [{"choice": "retry"}, {"choice": "failover", "target": "backup"}, {"choice": "abandon"}],
        }
    )
    recovery = read_control("failoverOccurrence", "0", None)
    acknowledge(emit, recovery, "accepted", "recovery accepted")
    emit({"type": "occurrence.recovery-chosen", "occurrenceId": "0", "controlId": recovery["controlId"], "choice": "failover", "target": "backup"})
    emit({"type": "occurrence.retried", "occurrenceId": "0", "controlId": recovery["controlId"]})
    acknowledge(emit, recovery, "delivered", "recovery delivered")
    emit({"type": "attempt.started", "occurrenceId": "0", "attempt": "1", "target": "backup"})
    emit({"type": "attempt.output", "occurrenceId": "0", "attempt": "1", "stream": "transport-text", "chunk": "fixture answer"})
    emit({"type": "attempt.completed", "occurrenceId": "0", "attempt": "1", "source": "backup"})
    finish(emit, run_id)


def run_recoveries(emit, run_id: str, auth_failure: bool = False) -> None:
    barrier = threading.Barrier(3)
    pending: list[tuple[int, str]] = []
    pending_lock = threading.Lock()

    def produce(occurrence: str) -> None:
        barrier.wait()
        emit({"type": "occurrence.started", "occurrenceId": occurrence, "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": f"recovery {occurrence}"})
        emit({"type": "attempt.started", "occurrenceId": occurrence, "attempt": "0", "target": "primary"})
        message = ("ACP session/prompt failed: Authentication failed: OAuth session expired and could not be refreshed (JSON-RPC -32603)\n" + "Provider diagnostic detail.\n" * 40 + "END_AUTH_DIAGNOSTIC") if auth_failure else f"gap {occurrence}"
        emit({"type": "attempt.failed", "occurrenceId": occurrence, "attempt": "0", "failure": "transport", "message": message})
        recovery_sequence = emit({"type": "occurrence.recovery-pending", "occurrenceId": occurrence, "gap": "transport-refusal", "message": message, "choices": [{"choice": "retry"}]})
        with pending_lock:
            pending.append((recovery_sequence, occurrence))

    producers = [threading.Thread(target=produce, args=(occurrence,)) for occurrence in ["0", "1"]]
    for producer in producers:
        producer.start()
    barrier.wait()
    for producer in producers:
        producer.join()

    for _, occurrence in sorted(pending):
        control = read_control("retryOccurrence", occurrence, None)
        acknowledge(emit, control, "accepted", f"recovery {occurrence} accepted")
        emit({"type": "occurrence.recovery-chosen", "occurrenceId": occurrence, "controlId": control["controlId"], "choice": "retry"})
        emit({"type": "occurrence.retried", "occurrenceId": occurrence, "controlId": control["controlId"]})
        acknowledge(emit, control, "delivered", f"recovery {occurrence} delivered")
        emit({"type": "attempt.started", "occurrenceId": occurrence, "attempt": "1", "target": "primary"})
        emit({"type": "attempt.output", "occurrenceId": occurrence, "attempt": "1", "stream": "transport-text", "chunk": "recovered"})
        emit({"type": "attempt.completed", "occurrenceId": occurrence, "attempt": "1", "source": "primary"})
        emit({"type": "occurrence.completed", "occurrenceId": occurrence, "source": "fixture", "answer": "recovered"})
    complete_run(emit, run_id, ["0", "1"])

def read_control(command_type: str, occurrence: str, attempt: object) -> dict[str, object]:
    line = sys.stdin.buffer.readline()
    if not line:
        raise SystemExit("control input closed")
    control = json.loads(line)
    assert control["expectedOccurrenceId"] == occurrence, control
    assert control.get("expectedAttemptId") == attempt, control
    assert control["command"]["type"] == command_type, control
    return control

def run_mixed_decisions(emit, run_id: str) -> None:
    person = "0"
    recovery = "1"
    prompt = "Answer the earlier cross-kind FIFO decision?"
    reference = write_question(run_id, person, prompt)
    emit({"type": "occurrence.started", "occurrenceId": person, "code": "flag", "intent": "consult", "addressee": "person owner", "prompt": prompt})
    emit({"type": "occurrence.person-answer-pending", "occurrenceId": person, "question": reference})
    emit({"type": "occurrence.started", "occurrenceId": recovery, "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "recover second"})
    emit({"type": "attempt.started", "occurrenceId": recovery, "attempt": "0", "target": "primary"})
    emit({"type": "attempt.failed", "occurrenceId": recovery, "attempt": "0", "failure": "transport", "message": "mixed gap"})
    emit({"type": "occurrence.recovery-pending", "occurrenceId": recovery, "gap": "transport", "message": "mixed gap", "choices": [{"choice": "retry"}]})

    answer = read_control("answerPerson", person, None)
    assert answer["command"]["answer"] is True, answer
    acknowledge(emit, answer, "accepted", "mixed person accepted")
    acknowledge(emit, answer, "delivered", "mixed person delivered")
    emit({"type": "occurrence.completed", "occurrenceId": person, "source": "asked:person owner", "answer": "yes"})

    retry = read_control("retryOccurrence", recovery, None)
    acknowledge(emit, retry, "accepted", "mixed recovery accepted")
    emit({"type": "occurrence.recovery-chosen", "occurrenceId": recovery, "controlId": retry["controlId"], "choice": "retry"})
    emit({"type": "occurrence.retried", "occurrenceId": recovery, "controlId": retry["controlId"]})
    acknowledge(emit, retry, "delivered", "mixed recovery delivered")
    emit({"type": "attempt.started", "occurrenceId": recovery, "attempt": "1", "target": "primary"})
    emit({"type": "attempt.output", "occurrenceId": recovery, "attempt": "1", "stream": "transport-text", "chunk": "mixed recovered"})
    emit({"type": "attempt.completed", "occurrenceId": recovery, "attempt": "1", "source": "primary"})
    emit({"type": "occurrence.completed", "occurrenceId": recovery, "source": "fixture", "answer": "mixed recovered"})
    complete_run(emit, run_id, [person, recovery])


def run_preempt_editor(emit, run_id: str) -> None:
    active = "0"
    person = "1"
    emit({"type": "occurrence.started", "occurrenceId": active, "code": "text", "intent": "consult", "addressee": "model fixture", "prompt": "steer before person"})
    emit({"type": "attempt.started", "occurrenceId": active, "attempt": "0", "target": "primary"})

    def require_person() -> None:
        time.sleep(1.5)
        prompt = "Mandatory answer preempts the steering editor?"
        reference = write_question(run_id, person, prompt)
        emit({"type": "occurrence.started", "occurrenceId": person, "code": "flag", "intent": "consult", "addressee": "person owner", "prompt": prompt})
        emit({"type": "occurrence.person-answer-pending", "occurrenceId": person, "question": reference})

    producer = threading.Thread(target=require_person)
    producer.start()
    answer = read_control("answerPerson", person, None)
    producer.join()
    assert answer["command"]["answer"] is True, answer
    acknowledge(emit, answer, "accepted", "preempting person accepted")
    acknowledge(emit, answer, "delivered", "preempting person delivered")
    emit({"type": "occurrence.completed", "occurrenceId": person, "source": "asked:person owner", "answer": "yes"})

    steer = read_control("steerOccurrence", active, {"occurrenceId": active, "attemptNumber": "0"})
    assert steer["command"]["text"] == "draft-survives", steer
    acknowledge(emit, steer, "accepted", "preserved steer accepted")
    emit({"type": "attempt.steered", "occurrenceId": active, "attempt": "0", "controlId": steer["controlId"], "timing": steer["command"]["timing"], "text": steer["command"]["text"]})
    acknowledge(emit, steer, "delivered", "preserved steer delivered")
    emit({"type": "attempt.output", "occurrenceId": active, "attempt": "0", "stream": "transport-text", "chunk": "preemption complete"})
    emit({"type": "attempt.completed", "occurrenceId": active, "attempt": "0", "source": "primary"})
    emit({"type": "occurrence.completed", "occurrenceId": active, "source": "fixture", "answer": "preemption complete"})
    complete_run(emit, run_id, [active, person])


def run_person_retry(emit, run_id: str) -> None:
    occurrence = "0"
    prompt = "Retry an initially rejected person answer?"
    reference = write_question(run_id, occurrence, prompt)
    emit({"type": "occurrence.started", "occurrenceId": occurrence, "code": "flag", "intent": "consult", "addressee": "person owner", "prompt": prompt})
    emit({"type": "occurrence.person-answer-pending", "occurrenceId": occurrence, "question": reference})
    first = read_control("answerPerson", occurrence, None)
    acknowledge(emit, first, "accepted", "person answer accepted")
    acknowledge(emit, first, "failed", "fixture schema rejection")
    second = read_control("answerPerson", occurrence, None)
    assert second["controlId"] != first["controlId"], (first, second)
    acknowledge(emit, second, "accepted", "person answer accepted")
    acknowledge(emit, second, "delivered", "person answer delivered")
    emit({"type": "occurrence.completed", "occurrenceId": occurrence, "source": "asked:person owner", "answer": "yes"})
    complete_run(emit, run_id, [occurrence])

def run_persons(emit, run_id: str) -> None:
    for occurrence, expected in [("0", True), ("1", False)]:
        prompt = f"Answer person occurrence {occurrence}?"
        reference = write_question(run_id, occurrence, prompt)
        emit({"type": "occurrence.started", "occurrenceId": occurrence, "code": "flag", "intent": "consult", "addressee": f"person owner-{occurrence}", "prompt": prompt})
        emit({"type": "occurrence.person-answer-pending", "occurrenceId": occurrence, "question": reference})
    for occurrence, expected in [("0", True), ("1", False)]:
        answer = read_control("answerPerson", occurrence, None)
        assert answer["command"]["answer"] is expected, answer
        acknowledge(emit, answer, "accepted", "person answer accepted")
        acknowledge(emit, answer, "delivered", "person answer delivered")
        emit({"type": "occurrence.completed", "occurrenceId": occurrence, "source": f"asked:person owner-{occurrence}", "answer": "yes" if expected else "no"})
    complete_run(emit, run_id, ["0", "1"])


def write_question(run_id: str, occurrence: str, prompt: str) -> dict[str, object]:
    artifact = {
        "artifactVersion": 1,
        "intent": "consult",
        "occurrenceId": occurrence,
        "question": {
            "addressee": {"person": {"id": f"owner-{occurrence}"}},
            "code": "flag",
            "draw": 0,
            "prompt": prompt,
            "scope": {"mode": None, "model": None},
        },
        "runId": run_id,
    }
    artifact_bytes = compact(artifact) + b"\n"
    runtime = Path(os.environ["AGENT_CAT_RUN_STORE"])
    directory = runtime / "person" / "questions"
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(runtime, 0o700)
    os.chmod(runtime / "person", 0o700)
    os.chmod(directory, 0o700)
    path = directory / f"{occurrence}.json"
    with path.open("xb") as output:
        os.chmod(path, 0o600)
        output.write(artifact_bytes)
    return {
        "artifactVersion": 1,
        "path": f"person/questions/{occurrence}.json",
        "sha256": hashlib.sha256(artifact_bytes).hexdigest(),
        "bytes": str(len(artifact_bytes)),
    }


def acknowledge(emit, control: dict[str, object], state: str, message: str) -> None:
    emit(
        {
            "type": "control.ack",
            "controlId": control["controlId"],
            "state": state,
            "message": message,
            "command": control["command"]["type"],
            "occurrenceId": control.get("expectedOccurrenceId"),
            "attemptId": control.get("expectedAttemptId"),
        }
    )


def finish(emit, run_id: str) -> None:
    emit({"type": "occurrence.completed", "occurrenceId": "0", "source": "fixture", "answer": "fixture answer"})
    complete_run(emit, run_id, ["0"])


def complete_run(emit, run_id: str, occurrences: list[str]) -> None:
    emit({"type": "trace.ordered", "occurrenceIds": occurrences})
    artifact = {"artifactVersion": 1, "result": {"code": "text", "value": "fixture answer"}, "runId": run_id}
    artifact_bytes = compact(artifact) + b"\n"
    runtime = Path(os.environ["AGENT_CAT_RUN_STORE"])
    runtime.mkdir(parents=True, mode=0o700, exist_ok=True)
    result_path = runtime / "result.json"
    with result_path.open("xb") as output:
        os.chmod(result_path, 0o600)
        output.write(artifact_bytes)
    emit(
        {
            "type": "run.completed",
            "billFresh": "1",
            "billMemo": "1",
            "result": {
                "artifactVersion": 1,
                "path": "result.json",
                "sha256": hashlib.sha256(artifact_bytes).hexdigest(),
                "bytes": str(len(artifact_bytes)),
                "code": "text",
                "preview": "fixture answer",
            },
        }
    )
    time.sleep(float(os.environ.get("TUI_FIXTURE_POST_RESULT_DELAY", "0")))


if __name__ == "__main__":
    main()
