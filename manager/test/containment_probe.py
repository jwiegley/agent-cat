#!/usr/bin/env python3
"""Exercise process-group limits and signal-safe cleanup of detached fixtures."""

from contextlib import ExitStack
import os
import select
import signal
import subprocess
import sys
import threading
import time


def receive(stream) -> bytes:
    assert select.select([stream], [], [], 5)[0], "fixture response timed out"
    return stream.read(64)


def pipe(stack):
    reader, writer = os.pipe()
    return (stack.enter_context(os.fdopen(reader, "rb", buffering=0)),
            stack.enter_context(os.fdopen(writer, "wb", buffering=0)))


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


SOURCE = """
import os, signal, sys
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
control, report, lifetime = map(int, sys.argv[1:])
if os.fork() == 0:
    os.setsid()
    os.close(lifetime)
    if os.read(control, 1) != b'g':
        os._exit(0)
    os.write(report, b'ready\\n')
    while True:
        if os.read(control, 1) != b'p':
            os._exit(0)
        os.write(report, b'alive\\n')
os.close(control)
os.close(report)
os.read(lifetime, 1)
os._exit(0)
"""


def run_probe(interrupt_at=None):
    previous_handler = signal.signal(signal.SIGTERM, interrupted)
    signals = {signal.SIGTERM, signal.SIGINT}
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    try:
        with ExitStack() as stack:
            control_read, control_write = pipe(stack)
            report_read, report_write = pipe(stack)
            lifetime_read, lifetime_write = pipe(stack)
            leader = subprocess.Popen(
                [sys.executable, "-c", SOURCE, str(control_read.fileno()),
                 str(report_write.fileno()), str(lifetime_read.fileno())],
                pass_fds=(control_read.fileno(), report_write.fileno(), lifetime_read.fileno()),
                start_new_session=True, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            )
            control_read.close()
            report_write.close()
            lifetime_read.close()
            timer = None
            try:
                if interrupt_at == "startup":
                    os.kill(os.getpid(), signal.SIGTERM)
                # Pending termination is delivered only after cleanup owns the process.
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                if interrupt_at == "readiness":
                    signal.pthread_sigmask(signal.SIG_BLOCK, signals)
                    timer = threading.Timer(0.01, os.kill, (os.getpid(), signal.SIGTERM))
                    timer.start()
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                else:
                    control_write.write(b"g")
                assert receive(report_read) == b"ready\n"
                assert leader.poll() is None
                os.killpg(leader.pid, signal.SIGTERM)
                assert leader.wait(timeout=5) == -signal.SIGTERM
                control_write.write(b"p")
                assert receive(report_read) == b"alive\n", "detached child did not demonstrate the group boundary"
            finally:
                signal.pthread_sigmask(signal.SIG_BLOCK, signals)
                if timer is not None:
                    timer.cancel()
                    timer.join(timeout=1)
                control_write.close()
                lifetime_write.close()
                try:
                    leader.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    leader.kill()
                    leader.wait(timeout=5)
                deadline = time.monotonic() + 5
                while True:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0 and select.select([report_read], [], [], remaining)[0], "escaped fixture cleanup timed out"
                    if not report_read.read(64):
                        break
                errors = leader.stderr.read()
                leader.stderr.close()
                assert not errors, errors
                print("fixture cleanup verified", flush=True)
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--interrupt-at":
        assert sys.argv[2] in {"startup", "readiness"}
        run_probe(sys.argv[2])
        raise AssertionError("planned interruption did not occur")
    run_probe()
    for phase in ["startup", "readiness"]:
        result = subprocess.run([sys.executable, __file__, "--interrupt-at", phase],
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 128 + signal.SIGTERM, (phase, result)
        assert "fixture cleanup verified" in result.stdout and not result.stderr, (phase, result)
    print("containment limit: detached sessions escape groups; normal and interrupted fixture cleanup verified")
