#!/usr/bin/env python3
"""Controlled lifetime/backpressure around the original native frontend only."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import threading
import time

native, mode, evidence, *arguments = sys.argv[1:]
evidence = Path(evidence)
if arguments != ["frontend"]:
    result = subprocess.run([native, *arguments], stdin=subprocess.DEVNULL, capture_output=True, check=False, timeout=30)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)

child = None

def stop_owned(_signal=None, _frame=None):
    if child is not None and child.poll() is None:
        child.terminate()
        child.wait(timeout=10)
    raise SystemExit(143)

signal.signal(signal.SIGTERM, stop_owned)
child = subprocess.Popen([native, "frontend"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True, bufsize=0)

def errors():
    while data := child.stderr.read(32768):
        os.write(2, data)

error_reader = threading.Thread(target=errors, daemon=True)
error_reader.start()
try:
    setup = sys.stdin.buffer.readline(2097153)
    assert setup.endswith(b"\n"), "bounded real setup"
    child.stdin.write(setup)
    child.stdin.flush()
    frame = child.stdout.readline(67108865)
    assert frame.endswith(b"\n"), "bounded real prepared frame"
    prepared = json.loads(frame)
    evidence.with_suffix(".identity").write_text(prepared["runId"])
    if mode == "bad-prefix":
        prepared["targetArguments"] = ["--verbose", *prepared["targetArguments"]]
    elif mode == "bad-scratch":
        prepared["policy"]["scratch"] = str(evidence.parent / "different-scratch")
    elif mode == "bad-target":
        prepared["targetKind"] = "deck" if prepared["targetKind"] != "deck" else "acp"
    elif mode == "bad-suffix":
        prepared["targetArguments"] += ["--timeout", "9"]
    if mode.startswith("bad-"):
        frame = json.dumps(prepared, ensure_ascii=True, separators=(",", ":")).encode() + b"\n"
    sys.stdout.buffer.write(frame)
    sys.stdout.buffer.flush()
    evidence.with_suffix(".prepared").write_text("native prepared relayed")

    def relay():
        while data := child.stdout.read(32768):
            os.write(1, data)

    output_reader = threading.Thread(target=relay, daemon=True)
    output_reader.start()
    started = False
    while child.poll() is None:
        if mode == "exit-on-trigger" and evidence.with_suffix(".exit").exists():
            child.terminate()
            child.wait(timeout=10)
            evidence.with_suffix(".joined").write_text("original native child joined")
            break
        readable, _, _ = select.select([sys.stdin.buffer], [], [], 0.01)
        if not readable:
            continue
        control = sys.stdin.buffer.readline(2097153)
        if not control:
            stop_owned()
        assert control.endswith(b"\n"), "bounded private control"
        child.stdin.write(control)
        child.stdin.flush()
        if json.loads(control).get("operation") == "start":
            assert not started, "one original start"
            started = True
            evidence.with_suffix(".started").write_text("one native start forwarded")
            if mode == "backpressure":
                for index in range(100):
                    stale = {"controlId": f"wm014-pressure-{index}", "expectedOccurrenceId": "999", "expectedAttemptId": None,
                             "command": {"type": "steerOccurrence", "text": "bounded test", "timing": "next-boundary"}}
                    child.stdin.write(json.dumps(stale, separators=(",", ":")).encode() + b"\n")
                child.stdin.flush()
    status = child.wait(timeout=10)
    output_reader.join(timeout=10)
    error_reader.join(timeout=10)
    assert not output_reader.is_alive() and not error_reader.is_alive(), "native drains joined"
    raise SystemExit(status)
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        child.wait(timeout=10)
    if child is not None:
        child.wait(timeout=10)
        evidence.with_suffix(".joined").write_text("original native child joined")
        for pipe in [child.stdin, child.stdout, child.stderr]:
            pipe.close()
