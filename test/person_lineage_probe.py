#!/usr/bin/env python3
"""Verify local-person lineage provenance and blocked cancellation."""

import json
import os
import shutil
import subprocess
import sys
import tempfile

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
    process = subprocess.Popen(
        [BINARY, *invocation],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        pass_fds=(control_read,),
        env={
            **os.environ,
            "AGENT_CAT_RUN_STORE": store,
            "AGENT_CAT_CONTROL_FD": "3",
        },
    )
    os.close(control_read)
    controls = os.fdopen(control_write, "w", encoding="utf-8")
    process.stdin.write(BODY)
    process.stdin.close()
    events = []
    cancel_sent = False
    for line in process.stdout:
        event = json.loads(line)["event"]
        events.append(event)
        if event["type"] == "occurrence.person-answer-pending" and not cancel_sent:
            occurrence = event["occurrenceId"]
            command = (
                {"type": "cancelRun"}
                if cancel
                else {"type": "answerPerson", "answer": True}
            )
            controls.write(
                json.dumps(
                    {
                        "controlId": f"control-{run_id}-{occurrence}",
                        "expectedOccurrenceId": None if cancel else occurrence,
                        "expectedAttemptId": None,
                        "command": command,
                    },
                    separators=(",", ":"),
                )
                + "\n"
            )
            controls.flush()
            cancel_sent = cancel
    controls.close()
    returncode = process.wait(timeout=30)
    stderr = process.stderr.read()
    if cancel:
        assert returncode == 130, (returncode, stderr, events)
    else:
        assert returncode == 0, (returncode, stderr, events)
    return events


def pending(events):
    return [
        event["occurrenceId"]
        for event in events
        if event["type"] == "occurrence.person-answer-pending"
    ]


def main():
    root = tempfile.mkdtemp(prefix="agentic-person-lineage-")
    try:
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

        print(
            "person lineage probe: legacy filtering, local resume, restart, explicit fork replacement, "
            "and blocked cancellation passed"
        )
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
