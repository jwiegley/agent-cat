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
ADAPTER_DIR = os.path.join(ROOT, "engine", "acp", "test")


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
    adapter = os.path.join(ADAPTER_DIR, adapter_name)
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
    adapter = os.path.join(ADAPTER_DIR, "retry_adapter.py")
    stub = os.path.join(ADAPTER_DIR, "stub_adapter.py")
    spare = os.path.join(root, "spare-adapter")
    with open(spare, "w", encoding="utf-8") as wrapper:
        wrapper.write(f"#!{sys.executable}\nimport os\n"
                      f"os.execv({sys.executable!r}, [{sys.executable!r}, {stub!r}])\n")
    os.chmod(spare, 0o700)
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


def live_redirect_probe(case):
    """Redirect an in-flight attempt: accepted for a question that is not an
    effect and a target in its chain, refused otherwise. An accepted redirect
    cancels the held turn at its adapter, and a refused one sends no cancel."""
    root = tempfile.mkdtemp(prefix=f"agentic-{case}-")
    control_read, control_write = os.pipe()
    hold = os.path.join(ADAPTER_DIR, "hold_adapter.py")
    held_log = os.path.join(root, "held.ndjson")
    spare_log = os.path.join(root, "spare.ndjson")
    # The spare candidate holds its own turn for three seconds before it
    # answers, so the run is still open while the probe reads the log of the
    # first candidate. A cancel that only the end of the run sends cannot
    # reach that log in time.
    spare = os.path.join(root, "spare-adapter")
    with open(spare, "w", encoding="utf-8") as wrapper:
        wrapper.write(f"#!{sys.executable}\nimport os\n"
                      f"os.environ['HOLD_ADAPTER_LOG'] = {spare_log!r}\n"
                      f"os.execv({sys.executable!r}, [{sys.executable!r}, {hold!r}, '3'])\n")
    os.chmod(spare, 0o700)
    workflow = "controlled-effect" if case == "live-redirect-effect" else "controlled"
    # The redirected attempt holds its turn until it is stopped. A refused
    # redirect leaves the attempt to answer after three seconds.
    seconds = "3600" if case == "live-redirect" else "3"
    process = None
    controls = None
    try:
        env = clean_env()
        env.update({
            "AGENT_CAT_CONTROL_FD": str(control_read),
            "AGENT_CAT_RUN_STORE": os.path.join(root, "run"),
            "HOLD_ADAPTER_LOG": held_log,
        })
        process = subprocess.Popen(
            [
                CONTROL_BINARY, "machine", f"{case}-run", workflow,
                "--engine", "acp", "--adapter", sys.executable,
                "--adapter-arg", hold, "--adapter-arg", seconds,
                "--route", f"spare=acp:{spare}", "--timeout", "10000",
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
        targets = None
        sent = False
        held_while_spare = None
        deadline = time.monotonic() + 60

        def send(control):
            controls.write(json.dumps(control, separators=(",", ":")) + "\n")
            controls.flush()

        while True:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                if process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError(f"{case} machine timed out after events: {events!r}")
                continue
            if not line:
                break
            event = json.loads(line)["event"]
            events.append(event)
            if event["type"] == "occurrence.dispatch-pending":
                # Close the dispatch window at once on the first candidate, so
                # the attempt starts without the 30-second wait.
                targets = event["targets"]
                send({
                    "controlId": "live-window",
                    "expectedOccurrenceId": event["occurrenceId"],
                    "expectedAttemptId": None,
                    "command": {"type": "redirectOccurrence", "target": targets[0]},
                })
            elif event["type"] == "attempt.started" and sent and held_while_spare is None:
                # The spare candidate holds for three seconds. Within two, the
                # first candidate must have ended its prompt as cancelled.
                held_while_spare = wait_for_hold_log(held_log, 2.0)
            elif event["type"] == "attempt.started" and not sent:
                assert targets is not None and len(targets) == 2, events
                time.sleep(0.2)
                target = "model controlled@elsewhere" if case == "live-redirect-outside" else targets[-1]
                send({
                    "controlId": "live-redirect",
                    "expectedOccurrenceId": event["occurrenceId"],
                    "expectedAttemptId": None,
                    "command": {"type": "redirectOccurrence", "target": target},
                })
                sent = True
        code = process.wait(timeout=10)
        stderr = process.stderr.read()
        assert code == 0 and sent, (case, code, stderr, events)
        assert any(event["type"] == "run.completed" for event in events), events
        acks = [event["state"] for event in events if event["type"] == "control.ack" and event["controlId"] == "live-redirect"]
        attempts = [event for event in events if event["type"].startswith("attempt.") and event["type"] in ("attempt.started", "attempt.completed", "attempt.failed")]
        completed = next(event for event in events if event["type"] == "occurrence.completed")
        if case == "live-redirect":
            assert acks == ["accepted", "delivered"], (acks, events)
            kinds = [event["type"] for event in events]
            redirected = [index for index, event in enumerate(events)
                          if event["type"] == "occurrence.redirected" and event["controlId"] == "live-redirect"]
            assert len(redirected) == 1 and events[redirected[0]]["target"] == targets[-1], events
            first_end = next(index for index, event in enumerate(events)
                             if event["type"] in ("attempt.completed", "attempt.failed"))
            assert redirected[0] < first_end and kinds[first_end] == "attempt.failed", events
            assert [event["type"] for event in attempts] == ["attempt.started", "attempt.failed", "attempt.started", "attempt.completed"], attempts
            assert "live-redirect" in attempts[1]["message"], attempts
            assert completed["source"] == f"asked:{targets[-1]}", events
            flow_records = live_redirect_flow(root)
            controls_seen = [record["about"].get("command") for record in flow_records if record["schema"] == "control"]
            assert controls_seen == ["live-window", "live-redirect"], controls_seen
            questions = [(position, record) for position, record in enumerate(flow_records) if record["schema"] == "question"]
            assert [record["to"]["to"]["model"] for _, record in questions] == [targets[0], targets[-1]], questions
            failures = [record for record in flow_records
                        if record["schema"] == "failure" and record.get("replyTo") == questions[0][1]["position"]]
            assert len(failures) == 1 and "live-redirect" in json.dumps(failures[0]), failures
            acknowledged = [record for record in flow_records if record["schema"] == "event"
                            and record["event"]["line"]["event"]["type"] == "control.ack"
                            and record["event"]["line"]["event"]["controlId"] == "live-redirect"]
            assert len(acknowledged) == 2, flow_records
            assert questions[0][0] < flow_records.index(failures[0]) < questions[1][0], flow_records
            # The adapter of the stopped attempt received session/cancel for
            # the held prompt while the run still ran, and the prompt ended
            # with stopReason cancelled.
            assert held_while_spare is not None, (case, read_hold_log(held_log))
            prompt = next(entry["id"] for entry in held_while_spare if entry.get("method") == "session/prompt")
            cancel = held_while_spare.index({"method": "session/cancel", "id": None})
            ended = held_while_spare.index({"stopReason": "cancelled", "id": prompt})
            assert held_while_spare.index({"method": "session/prompt", "id": prompt}) < cancel < ended, held_while_spare
            assert sum(1 for entry in read_hold_log(spare_log) if entry.get("stopReason") == "end_turn") == 1, read_hold_log(spare_log)
        else:
            reason = "no live re-route of an effect" if case == "live-redirect-effect" else "not a live candidate"
            messages = [event["message"] for event in events if event["type"] == "control.ack" and event["controlId"] == "live-redirect"]
            assert acks == ["rejected-stale"] and reason in messages[0], (messages, events)
            assert not any(event["type"] == "occurrence.redirected" and event["controlId"] == "live-redirect" for event in events), events
            assert [event["type"] for event in attempts] == ["attempt.started", "attempt.completed"], attempts
            assert completed["source"] == f"asked:{targets[0]}", events
            # A refused redirect leaves the turn alone: the held prompt ends
            # with end_turn, and no session/cancel arrives before it ends.
            held = read_hold_log(held_log)
            prompt = next(entry["id"] for entry in held if entry.get("method") == "session/prompt")
            ended = held.index({"stopReason": "end_turn", "id": prompt})
            assert {"method": "session/cancel", "id": None} not in held[:ended], held
    finally:
        if controls is not None:
            controls.close()
        else:
            os.close(control_write)
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        shutil.rmtree(root, ignore_errors=True)


def read_hold_log(path):
    """The entries that hold_adapter.py appended to its HOLD_ADAPTER_LOG."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def wait_for_hold_log(path, seconds):
    """The hold log once it records a cancelled prompt, or None after seconds."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        entries = read_hold_log(path)
        if any(entry.get("stopReason") == "cancelled" for entry in entries):
            return entries
        time.sleep(0.02)
    return None


def live_redirect_flow(root):
    """The records that "agentic-run flow" prints for the run log under root."""
    logs = [os.path.join(directory, "flow.ndjson") for directory, _, files in os.walk(root) if "flow.ndjson" in files]
    assert len(logs) == 1, logs
    result = subprocess.run([BINARY, "flow", os.path.dirname(logs[0])], capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    lines = [json.loads(line) for line in result.stdout.splitlines()]
    assert lines and "summary" in lines[-1], lines[-1:]
    summary = lines[-1]["summary"]
    assert summary["verified"] and not summary["problems"], summary
    return lines[:-1]


def oversize_probe():
    root = tempfile.mkdtemp(prefix="agentic-oversize-")
    try:
        result = subprocess.run(
            [
                BINARY, "machine", "oversize-run", "structured", "--engine", "acp",
                "--adapter", sys.executable, "--adapter-arg", os.path.join(ADAPTER_DIR, "oversize_adapter.py"), "--timeout", "10000",
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
    live_redirect_probe("live-redirect")
    live_redirect_probe("live-redirect-effect")
    live_redirect_probe("live-redirect-outside")
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
    print("control probe: stdin, EOF, cancel, steer, retry/failover/abandon, redirect, live redirect, and frame refusal passed")


if __name__ == "__main__":
    main()
