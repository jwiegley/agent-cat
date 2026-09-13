#!/usr/bin/env python3
"""Controlled faults around a real native frontend, never a replacement interpreter."""
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import threading
import time

native, mode, evidence, *arguments = sys.argv[1:]
evidence = Path(evidence)
with evidence.open("a") as log:
    log.write(json.dumps({"args": arguments, "cwd": os.getcwd(), "env": dict(os.environ), "pid": os.getpid()}) + "\n")

if arguments != ["frontend"]:
    if mode == "bad-capabilities" and arguments == ["frontend", "--capabilities"] and evidence.with_suffix(".armed").exists():
        sys.stdout.buffer.write(b'{"version":1}\n')
        sys.stdout.buffer.flush()
    else:
        result = subprocess.run([native, *arguments], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        sys.exit(result.returncode)
    sys.exit(0)

if mode == "startup-exit":
    sys.exit(7)
if mode == "startup-hang":
    evidence.with_suffix(".ready").write_text("ready")
    time.sleep(120)
    sys.exit(0)

child = None

def terminate_owned(_signal, _frame):
    if child is not None:
        child.terminate()
        child.wait(timeout=10)
    raise SystemExit(143)

signal.signal(signal.SIGTERM, terminate_owned)
child = subprocess.Popen([native, "frontend"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True, bufsize=0)
evidence.with_suffix(".child").write_text(str(child.pid))

def stderr_reader():
    while True:
        data = child.stderr.read(32768)
        if not data:
            return
        os.write(2, data)

threading.Thread(target=stderr_reader, daemon=True).start()
setup = sys.stdin.buffer.readline(2 * 1024 * 1024 + 2)
child.stdin.write(setup)
child.stdin.flush()
preview = child.stdout.readline(64 * 1024 * 1024 + 4097)
if not preview:
    sys.exit(child.wait())

if mode == "prepared-malformed":
    sys.stdout.buffer.write(b'not-json\n')
elif mode == "prepared-utf8":
    sys.stdout.buffer.write(b'"\xff"\n')
elif mode == "prepared-truncated":
    sys.stdout.buffer.write(preview.rstrip(b'\n'))
    sys.stdout.buffer.flush()
    os.close(1)
elif mode == "prepared-oversized":
    block = b'x' * 65536
    for _ in range(1024):
        sys.stdout.buffer.write(block)
    sys.stdout.buffer.write(b'x' * 4096 + b'\n')
else:
    sys.stdout.buffer.write(preview)
sys.stdout.buffer.flush()
if mode.startswith("prepared-"):
    child.stdin.close()
    child.wait(timeout=15)
    sys.exit(0)
if mode in {"failed-write", "blocked-write"}:
    if mode == "failed-write":
        os.close(0)
    evidence.with_suffix(".ready").write_text("ready")
    if mode == "blocked-write":
        sys.stdin.buffer.readline(2 * 1024 * 1024 + 2)
        first = sys.stdin.buffer.read(1)
        evidence.with_suffix(".write-started").write_bytes(first)
    time.sleep(120)
    sys.exit(0)

if mode == "stderr-flood":
    def flood():
        try:
            while child.poll() is None:
                os.write(2, b'SYNTHETIC_PRIVATE_DIAGNOSTIC\n' * 2048)
                time.sleep(0.001)
        except BrokenPipeError:
            pass
    threading.Thread(target=flood, daemon=True).start()

def input_reader():
    try:
        while True:
            data = os.read(0, 32768)
            if not data:
                child.stdin.close()
                return
            child.stdin.write(data)
            child.stdin.flush()
    except (BrokenPipeError, OSError):
        pass

threading.Thread(target=input_reader, daemon=True).start()
first = True
for frame in iter(child.stdout.readline, b''):
    if first and mode.startswith("runtime-"):
        first = False
        if mode == "runtime-malformed":
            frame = b'not-json\n'
        elif mode == "runtime-utf8":
            frame = b'"\xff"\n'
        elif mode == "runtime-truncated":
            sys.stdout.buffer.write(frame.rstrip(b'\n'))
            sys.stdout.buffer.flush()
            os.close(1)
            child.stdin.close()
            child.wait(timeout=15)
            sys.exit(0)
        elif mode == "runtime-oversized":
            frame = b'x' * (1024 * 1024 + 1) + b'\n'
        elif mode == "runtime-wrong-run":
            value = json.loads(frame)
            value["runId"] = "wrong-run"
            frame = json.dumps(value).encode() + b'\n'
        elif mode == "runtime-gap":
            value = json.loads(frame)
            value["sequence"] = "1"
            frame = json.dumps(value).encode() + b'\n'
    sys.stdout.buffer.write(frame)
    sys.stdout.buffer.flush()
sys.exit(child.wait())
