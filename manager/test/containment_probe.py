#!/usr/bin/env python3
"""Demonstrate the process-group limit without leaving an escaped fixture alive."""

import os
import select
import signal
import subprocess
import sys
import time


def receive(fd: int) -> bytes:
    assert select.select([fd], [], [], 5)[0], "fixture response timed out"
    return os.read(fd, 64)


control_read, control_write = os.pipe()
report_read, report_write = os.pipe()
source = """
import os, signal, sys
control, report = map(int, sys.argv[1:])
if os.fork() == 0:
    os.setsid()
    os.write(report, b'ready\\n')
    while True:
        command = os.read(control, 1)
        if command != b'p':
            os._exit(0)
        os.write(report, b'alive\\n')
os.close(control)
os.close(report)
while True:
    signal.pause()
"""
leader = subprocess.Popen(
    [sys.executable, "-c", source, str(control_read), str(report_write)],
    pass_fds=(control_read, report_write), start_new_session=True,
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
)
os.close(control_read)
os.close(report_write)
try:
    assert receive(report_read) == b"ready\n"
    assert leader.poll() is None
    os.killpg(leader.pid, signal.SIGTERM)
    assert leader.wait(timeout=5) == -signal.SIGTERM
    os.write(control_write, b"p")
    assert receive(report_read) == b"alive\n", "detached child did not demonstrate the group boundary"
finally:
    try:
        os.write(control_write, b"q")
    except BrokenPipeError:
        pass
    os.close(control_write)
    if leader.poll() is None:
        leader.terminate()
        leader.wait(timeout=5)
    deadline = time.monotonic() + 5
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([report_read], [], [], remaining)[0], "escaped fixture cleanup timed out"
        if not os.read(report_read, 64):
            break
    os.close(report_read)
    errors = leader.stderr.read()
    leader.stderr.close()
    assert not errors, errors
print("containment limit: a new session escapes group termination; private fixture cleanup verified")
