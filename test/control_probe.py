#!/usr/bin/env python3
"""Exercise real machine steering and interactive retry without a provider."""

import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

BINARY = os.path.abspath(sys.argv[1])
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_probe(name, adapter_name, trigger_type, control, expected_code=0, terminal_type="run.completed"):
    root = tempfile.mkdtemp(prefix=f"agentic-{name}-")
    store = os.path.join(root, "run")
    adapter = os.path.join(ROOT, "test", adapter_name)
    process = subprocess.Popen(
        [
            BINARY, "machine", f"{name}-run", "structured", "--engine", "acp",
            "--adapter", sys.executable, "--adapter-arg", adapter, "--timeout", "10000",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env={
            **os.environ,
            "AGENT_CAT_CONTROL_STDIN": "1",
            "AGENT_CAT_RUN_STORE": store,
        },
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    events = []
    sent = False
    try:
        while True:
            ready = selector.select(20)
            if not ready:
                raise AssertionError(f"{name} machine timed out; stderr={process.stderr.read()}")
            line = process.stdout.readline()
            if not line:
                break
            envelope = json.loads(line)
            event = envelope["event"]
            events.append(event)
            if not sent and event["type"] == trigger_type:
                if trigger_type == "attempt.started":
                    time.sleep(0.1)
                process.stdin.write(json.dumps(control, separators=(",", ":")) + "\n")
                process.stdin.flush()
                sent = True
        code = process.wait(timeout=10)
        stderr = process.stderr.read()
        assert code == expected_code, f"{name} exited {code}, expected {expected_code}: {stderr}"
        assert sent, f"{name} never emitted {trigger_type}"
        assert any(event["type"] == terminal_type for event in events), events
        return events
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        shutil.rmtree(root, ignore_errors=True)


def oversize_probe():
    root = tempfile.mkdtemp(prefix="agentic-oversize-")
    try:
        result = subprocess.run(
            [
                BINARY, "machine", "oversize-run", "structured", "--engine", "acp",
                "--adapter", sys.executable, "--adapter-arg", os.path.join(ROOT, "test", "oversize_adapter.py"), "--timeout", "10000",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ, "AGENT_CAT_RUN_STORE": os.path.join(root, "run")},
        )
        envelopes = [json.loads(line) for line in result.stdout.splitlines()]
        assert result.returncode != 0, result.stderr
        assert envelopes and all(len(json.dumps(envelope, separators=(",", ":")).encode()) <= 1024 * 1024 for envelope in envelopes)
        assert any(envelope["event"]["type"] == "run.failed" for envelope in envelopes), envelopes
        assert not any(envelope["event"]["type"] == "attempt.output" for envelope in envelopes), envelopes
    finally:
        shutil.rmtree(root, ignore_errors=True)

def main():
    steer = run_probe(
        "steer",
        "steer_adapter.py",
        "attempt.started",
        {
            "controlId": "steer-probe",
            "expectedOccurrenceId": "0",
            "expectedAttemptId": {"occurrenceId": "0", "attemptNumber": "0"},
            "command": {"type": "steerOccurrence", "timing": "interrupt-now", "text": "focus"},
        },
    )
    assert any(event["type"] == "attempt.steered" and event["controlId"] == "steer-probe" for event in steer)
    assert any(event["type"] == "control.ack" and event["controlId"] == "steer-probe" and event["state"] == "delivered" for event in steer)

    retry = run_probe(
        "retry",
        "retry_adapter.py",
        "occurrence.recovery-pending",
        {
            "controlId": "retry-probe",
            "expectedOccurrenceId": "0",
            "expectedAttemptId": None,
            "command": {"type": "retryOccurrence"},
        },
    )
    pending = next(event for event in retry if event["type"] == "occurrence.recovery-pending")
    assert pending["choices"] == [{"choice": "retry"}, {"choice": "abandon"}], pending
    assert any(event["type"] == "occurrence.recovery-chosen" and event["choice"] == "retry" for event in retry)
    assert any(event["type"] == "occurrence.retried" for event in retry)
    assert any(event["type"] == "control.ack" and event["controlId"] == "retry-probe" and event["state"] == "delivered" for event in retry)

    abandon = run_probe(
        "abandon",
        "retry_adapter.py",
        "occurrence.recovery-pending",
        {
            "controlId": "abandon-probe",
            "expectedOccurrenceId": "0",
            "expectedAttemptId": None,
            "command": {"type": "abandonOccurrence"},
        },
        expected_code=3,
        terminal_type="run.failed",
    )
    assert any(event["type"] == "occurrence.recovery-chosen" and event["choice"] == "abandon" for event in abandon)
    assert any(event["type"] == "occurrence.failed" for event in abandon)
    assert any(event["type"] == "control.ack" and event["controlId"] == "abandon-probe" and event["state"] == "delivered" for event in abandon)
    oversize_probe()
    print("control probe: real machine steering, retry, abandon, and oversized-frame refusal passed")


if __name__ == "__main__":
    main()
