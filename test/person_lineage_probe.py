#!/usr/bin/env python3
"""Verify local-person lineage provenance and blocked cancellation."""

import json
import os
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 2:
    raise SystemExit("usage: person_lineage_probe.py ROUTING_FIXED_POINT_PROBE")

BINARY = os.path.abspath(sys.argv[1])
BODY = "PERSON-LINEAGE-BODY"


def local_run(run_id, store, lineage=None, parent=None, edit=None, cancel=False):
    control_read, control_write = os.pipe()
    if control_read != 3:
        os.dup2(control_read, 3, inheritable=True)
        os.close(control_read)
        control_read = 3
    invocation = ["machine", run_id, "person-controlled"]
    if lineage:
        invocation = [f"machine-{lineage}", run_id, parent, "person-controlled"]
    if edit:
        invocation += ["--set-answer", edit]
    invocation += [
        "--scripted",
        "--protocol-version",
        "2",
        "--person-answering",
        "local-control",
    ]
    with os.fdopen(control_read, "rb") as control, os.fdopen(control_write, "w", encoding="utf-8") as controls:
        process = subprocess.Popen(
            [BINARY, *invocation],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0, pass_fds=(control.fileno(),),
            env={
                **os.environ,
                "AGENT_CAT_RUN_STORE": store,
                "AGENT_CAT_CONTROL_FD": "3",
            },
        )
        try:
            control.close()
            process.stdin.write(BODY.encode())
            process.stdin.close()
            process.stdin = None
            events = []
            cancel_sent = False
            buffer = b""
            deadline = time.monotonic() + 30
            while True:
                while b"\n" not in buffer:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0 and select.select([process.stdout], [], [], remaining)[0], "person lineage timed out"
                    block = os.read(process.stdout.fileno(), 32768)
                    if not block:
                        assert not buffer, buffer
                        break
                    buffer += block
                else:
                    line, buffer = buffer.split(b"\n", 1)
                    event = json.loads(line)["event"]
                    events.append(event)
                    if event["type"] == "occurrence.person-answer-pending" and not cancel_sent:
                        occurrence = event["occurrenceId"]
                        command = {"type": "cancelRun"} if cancel else {"type": "answerPerson", "answer": True}
                        controls.write(json.dumps({
                            "controlId": f"control-{run_id}-{occurrence}",
                            "expectedOccurrenceId": None if cancel else occurrence,
                            "expectedAttemptId": None,
                            "command": command,
                        }, separators=(",", ":")) + "\n")
                        controls.flush()
                        cancel_sent = cancel
                    continue
                break
            controls.close()
            _, stderr = process.communicate(timeout=max(0, deadline - time.monotonic()))
            returncode = process.returncode
            assert returncode == (130 if cancel else 0), (returncode, stderr, events)
            return events
        finally:
            failure = sys.exc_info()[1]
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT})
            try:
                cleanup_failure = None
                try:
                    try:
                        if process.poll() is None:
                            process.terminate()
                    except KeyboardInterrupt as interrupted:
                        cleanup_failure = interrupted
                    if process.stdin is not None and process.stdin.closed:
                        process.stdin = None
                    timeout = 30 if cleanup_failure is None else None
                    while True:
                        try:
                            process.communicate(timeout=timeout)
                            break
                        except (subprocess.TimeoutExpired, KeyboardInterrupt) as interrupted:
                            cleanup_failure = cleanup_failure or interrupted
                            # Do not retire an original child at an already-failed deadline.
                            timeout = None
                except BaseException as unjoined:
                    primary = failure or cleanup_failure
                    if primary is None:
                        raise
                    primary.add_note(f"Person lineage original join UNPROVEN: {unjoined!r}")
                    raise primary from unjoined
                if cleanup_failure is not None:
                    if failure is None:
                        raise cleanup_failure
                    failure.add_note(f"Person lineage cleanup failed: {cleanup_failure!r}; original child joined")
            finally:
                primary = sys.exc_info()[1] or failure
                try:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                except KeyboardInterrupt:
                    if primary is None:
                        raise
                    primary.add_note("Caller interruption deferred until original-owner cleanup finished")

def pending(events):
    return [
        event["occurrenceId"]
        for event in events
        if event["type"] == "occurrence.person-answer-pending"
    ]


def main():
    root = tempfile.mkdtemp(prefix="agentic-person-lineage-")
    legacy = os.path.join(root, "legacy")
    parent = subprocess.run(
        [BINARY, "machine", "legacy", "person-controlled", "--scripted"],
        input=BODY,
        text=True,
        capture_output=True,
        timeout=30,
        env={**os.environ, "AGENT_CAT_RUN_STORE": legacy},
    )
    assert parent.returncode == 0, parent.stderr
    legacy_answers = json.load(open(os.path.join(legacy, "answers.json")))["answers"]
    assert len(legacy_answers) == 2

    resumed = os.path.join(root, "resumed")
    resumed_events = local_run("resumed", resumed, "resume", legacy)
    assert pending(resumed_events) == ["0", "1"], pending(resumed_events)

    inherited = os.path.join(root, "inherited")
    inherited_events = local_run("inherited", inherited, "resume", resumed)
    assert pending(inherited_events) == [], pending(inherited_events)
    assert sum(event["type"] == "occurrence.reused" for event in inherited_events) == 2

    restarted = os.path.join(root, "restarted")
    restarted_events = local_run("restarted", restarted, "restart", resumed)
    assert pending(restarted_events) == ["0", "1"], pending(restarted_events)

    replacement = os.path.join(root, "replacement.json")
    with open(replacement, "w", encoding="utf-8") as handle:
        json.dump(True, handle)
    forked = os.path.join(root, "forked")
    forked_events = local_run(
        "forked", forked, "fork", legacy, f"0={replacement}"
    )
    assert pending(forked_events) == ["1"], pending(forked_events)
    assert any(
        event["type"] == "occurrence.reused"
        and event.get("occurrenceId") == "0"
        for event in forked_events
    )

    cancelled = os.path.join(root, "cancelled")
    cancelled_events = local_run("cancelled", cancelled, cancel=True)
    assert any(event["type"] == "run.cancelled" for event in cancelled_events)
    answers = json.load(open(os.path.join(cancelled, "answers.json")))["answers"]
    assert answers == []

    shutil.rmtree(root)
    print(
        "person lineage probe: legacy filtering, local resume, restart, explicit fork replacement, "
        "and blocked cancellation passed"
    )


if __name__ == "__main__":
    main()
