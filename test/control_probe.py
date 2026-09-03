#!/usr/bin/env python3
"""Exercise literal workflow stdin and real machine controls without a provider."""

import json
import os
import pty
import queue
import shutil
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 3:
    raise SystemExit("usage: control_probe.py AGENTIC_RUN ROUTING_FIXED_POINT_PROBE")

BINARY = os.path.abspath(sys.argv[1])
CONTROL_BINARY = os.path.abspath(sys.argv[2])
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def event_lines(stream):
    lines = queue.Queue()

    def pump():
        try:
            for line in stream:
                lines.put(line)
        finally:
            lines.put(None)

    import threading
    threading.Thread(target=pump, daemon=True).start()
    return lines


def run_probe(name, adapter_name, trigger_type, control, expected_code=0, terminal_type="run.completed"):
    root = tempfile.mkdtemp(prefix=f"agentic-{name}-")
    store = os.path.join(root, "run")
    adapter = os.path.join(ROOT, "test", adapter_name)
    control_read, control_write = os.pipe()
    try:
        process = subprocess.Popen(
            [
                CONTROL_BINARY, "machine", f"{name}-run", "controlled-single", "--engine", "acp",
                "--adapter", sys.executable, "--adapter-arg", adapter, "--timeout", "10000",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            pass_fds=(control_read,),
            env={
                **clean_env(),
                "AGENT_CAT_CONTROL_FD": str(control_read),
                "AGENT_CAT_RUN_STORE": store,
            },
        )
    except BaseException:
        os.close(control_read)
        os.close(control_write)
        raise
    os.close(control_read)
    controls = os.fdopen(control_write, "w", encoding="utf-8")
    assert process.stdin is not None
    process.stdin.write("CONTROL-STDIN\n")
    process.stdin.close()
    assert process.stdout is not None
    lines = event_lines(process.stdout)
    events = []
    sent = False
    deadline = time.monotonic() + 30
    try:
        while True:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                if process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError(f"{name} machine timed out")
                continue
            if not line:
                break
            envelope = json.loads(line)
            event = envelope["event"]
            events.append(event)
            if not sent and event["type"] == trigger_type:
                if trigger_type == "attempt.started":
                    time.sleep(0.1)
                controls.write(json.dumps(control, separators=(",", ":")) + "\n")
                controls.flush()
                sent = True
        code = process.wait(timeout=10)
        stderr = process.stderr.read()
        assert code == expected_code, f"{name} exited {code}, expected {expected_code}: {stderr}"
        assert sent, f"{name} never emitted {trigger_type}"
        assert any(event["type"] == terminal_type for event in events), events
        assert any(event["type"] == "occurrence.started" and "CONTROL-STDIN" in event["prompt"] for event in events), events
        return events
    finally:
        controls.close()
        if process.poll() is None:
            process.kill()
            process.wait()
        shutil.rmtree(root, ignore_errors=True)


def clean_env():
    env = dict(os.environ)
    env.pop("AGENT_CAT_CONTROL_FD", None)
    env.pop("AGENT_CAT_CONTROL_STDIN", None)
    return env


def stdin_probe():
    payload = b"UNIQUE-A\nUNIQUE-B\n\n"
    command = [BINARY, "run", "review-lite", "--scripted"]
    result = subprocess.run(command, input=payload, capture_output=True, timeout=30, env=clean_env())
    output = result.stdout + result.stderr
    assert result.returncode == 0, output.decode(errors="replace")
    assert b"19 B from standard input" in output, output.decode(errors="replace")

    empty = subprocess.run(command, input=b"", capture_output=True, timeout=30, env=clean_env())
    assert empty.returncode == 0, empty.stderr.decode(errors="replace")
    assert b"0 B from standard input" in empty.stdout + empty.stderr

    invalid = subprocess.run(command, input=b"\xff", capture_output=True, timeout=30, env=clean_env())
    assert invalid.returncode == 1, invalid
    assert b"standard input is not UTF-8" in invalid.stdout + invalid.stderr, invalid.stderr.decode(errors="replace")

    explicit = subprocess.run(
        command + ["--input-arg", "subject=explicit"],
        input=b"\xff", capture_output=True, timeout=30, env=clean_env(),
    )
    assert explicit.returncode == 0, explicit.stderr.decode(errors="replace")

    legacy_env = clean_env()
    legacy_env["AGENT_CAT_CONTROL_STDIN"] = "1"
    legacy = subprocess.run(command, input=payload, capture_output=True, timeout=30, env=legacy_env)
    assert legacy.returncode == 1, legacy
    assert b"conflicts with legacy AGENT_CAT_CONTROL_STDIN" in legacy.stdout + legacy.stderr

    master, slave = pty.openpty()
    try:
        terminal = subprocess.Popen(command, stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=clean_env())
        os.close(slave)
        stdout, stderr = terminal.communicate(timeout=30)
        assert terminal.returncode == 1, (stdout, stderr)
        assert b"pipe UTF-8 text" in stdout + stderr, (stdout, stderr)
    finally:
        os.close(master)


def blocked_stdin_probe(name, control):
    root = tempfile.mkdtemp(prefix=f"agentic-{name}-")
    stdin_read, stdin_write = os.pipe()
    control_read, control_write = os.pipe()
    process = None
    controls = None
    try:
        env = clean_env()
        env.update({
            "AGENT_CAT_CONTROL_FD": str(control_read),
            "AGENT_CAT_RUN_STORE": os.path.join(root, "run"),
        })
        process = subprocess.Popen(
            [BINARY, "machine", f"{name}-run", "review-lite", "--scripted"],
            stdin=stdin_read, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            pass_fds=(control_read,), env=env,
        )
        os.close(stdin_read)
        os.close(control_read)
        controls = os.fdopen(control_write, "w", encoding="utf-8")
        control_write = -1
        if control is None:
            controls.close()
            controls = None
        else:
            controls.write(json.dumps(control, separators=(",", ":")) + "\n")
            controls.flush()
        stdout, stderr = process.communicate(timeout=20)
        events = [json.loads(line)["event"] for line in stdout.splitlines()]
        return process.returncode, events, stderr
    finally:
        if controls is not None:
            controls.close()
        elif control_write >= 0:
            os.close(control_write)
        os.close(stdin_write)
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        shutil.rmtree(root, ignore_errors=True)


def blocked_stdin_control_probe():
    code, cancelled, stderr = blocked_stdin_probe("stdin-cancel", {
        "controlId": "stdin-cancel",
        "expectedOccurrenceId": None,
        "expectedAttemptId": None,
        "command": {"type": "cancelRun"},
    })
    assert code == 130, (code, stderr, cancelled)
    assert [event["type"] for event in cancelled] == ["run.started", "control.ack", "run.cancelled"], cancelled
    assert cancelled[1]["controlId"] == "stdin-cancel" and cancelled[1]["state"] == "accepted", cancelled

    code, eof, stderr = blocked_stdin_probe("stdin-eof", None)
    assert code == 130, (code, stderr, eof)
    assert [event["type"] for event in eof] == ["run.started", "run.cancelled"], eof
    assert eof[-1]["message"] == "control input closed", eof


def routed_control_probe(choice):
    root = tempfile.mkdtemp(prefix=f"agentic-{choice}-")
    control_read, control_write = os.pipe()
    adapter = os.path.join(ROOT, "test", "retry_adapter.py")
    spare = os.path.join(ROOT, "test", "stub_adapter.py")
    process = None
    controls = None
    try:
        env = clean_env()
        env.update({
            "AGENT_CAT_CONTROL_FD": str(control_read),
            "AGENT_CAT_RUN_STORE": os.path.join(root, "run"),
        })
        process = subprocess.Popen(
            [
                CONTROL_BINARY, "machine", f"{choice}-run", "controlled",
                "--engine", "acp", "--adapter", sys.executable,
                "--adapter-arg", adapter, "--route", f"spare=acp:{spare}",
                "--timeout", "10000",
            ],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, pass_fds=(control_read,), env=env,
        )
        os.close(control_read)
        controls = os.fdopen(control_write, "w", encoding="utf-8")
        assert process.stdin is not None and process.stdout is not None and process.stderr is not None
        process.stdin.write("CONTROL-STDIN\n")
        process.stdin.close()
        lines = event_lines(process.stdout)
        events = []
        sent = False
        deadline = time.monotonic() + 60
        while True:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                if process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError(f"{choice} machine timed out after events: {events!r}")
                continue
            if not line:
                break
            event = json.loads(line)["event"]
            events.append(event)
            if sent:
                continue
            if choice == "redirect" and event["type"] == "occurrence.dispatch-pending":
                control = {
                    "controlId": "redirect-probe",
                    "expectedOccurrenceId": event["occurrenceId"],
                    "expectedAttemptId": None,
                    "command": {"type": "redirectOccurrence", "target": event["targets"][-1]},
                }
            elif choice == "failover" and event["type"] == "occurrence.recovery-pending":
                control = {
                    "controlId": "failover-probe",
                    "expectedOccurrenceId": event["occurrenceId"],
                    "expectedAttemptId": None,
                    "command": {"type": "failoverOccurrence"},
                }
            else:
                continue
            controls.write(json.dumps(control, separators=(",", ":")) + "\n")
            controls.flush()
            sent = True
        code = process.wait(timeout=10)
        stderr = process.stderr.read()
        assert code == 0 and sent, (code, stderr, events)
        assert any(event["type"] == "occurrence.started" and "CONTROL-STDIN" in event["prompt"] for event in events), events
        assert any(event["type"] == "run.completed" for event in events), events
        if choice == "redirect":
            redirected = next(event for event in events if event["type"] == "occurrence.redirected")
            completed = next(event for event in events if event["type"] == "occurrence.completed")
            assert completed["source"] == f"asked:{redirected['target']}", events
            assert not any(event["type"] == "occurrence.recovery-pending" for event in events), events
        else:
            assert any(event["type"] == "occurrence.recovery-chosen" and event["choice"] == "failover" for event in events), events
            assert any(event["type"] == "occurrence.retried" for event in events), events
    finally:
        if controls is not None:
            controls.close()
        else:
            os.close(control_write)
        if process is not None and process.poll() is None:
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
    stdin_probe()
    blocked_stdin_control_probe()
    routed_control_probe("redirect")
    routed_control_probe("failover")
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
    print("control probe: stdin, EOF, cancel, steer, retry/failover/abandon, redirect, and frame refusal passed")


if __name__ == "__main__":
    main()
