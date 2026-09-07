#!/usr/bin/env python3
"""Exercise protocol-v2 local person answers without a provider."""

import hashlib
import json
import os
import queue
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

if len(sys.argv) != 2:
    raise SystemExit("usage: person_control_probe.py ROUTING_FIXED_POINT_PROBE")

BINARY = os.path.abspath(sys.argv[1])


def event_lines(stream):
    lines = queue.Queue()

    def pump():
        try:
            for line in stream:
                lines.put(line)
        finally:
            lines.put(None)

    threading.Thread(target=pump, daemon=True).start()
    return lines


def refusal(args, env, expected):
    result = subprocess.run(
        [BINARY, *args], env=env, text=True, capture_output=True, timeout=30
    )
    assert result.returncode == 3, (result.returncode, result.stdout, result.stderr)
    assert expected in result.stderr, result.stderr


def main():
    root = tempfile.mkdtemp(prefix="agentic-person-control-")
    store = os.path.join(root, "run")
    body = "line one\n" + "x" * 700 + "\nline three"
    clean = {**os.environ}
    try:
        refusal(
            [
                "machine",
                "no-store",
                "person-controlled",
                "--scripted",
                "--protocol-version",
                "2",
                "--person-answering",
                "local-control",
                "--input-arg",
                f"input={body}",
            ],
            clean,
            "protocol version 2 requires AGENT_CAT_RUN_STORE",
        )
        refusal(
            [
                "machine",
                "no-control",
                "person-controlled",
                "--scripted",
                "--protocol-version",
                "2",
                "--person-answering",
                "local-control",
                "--input-arg",
                f"input={body}",
            ],
            {**clean, "AGENT_CAT_RUN_STORE": store},
            "local person answering requires AGENT_CAT_CONTROL_FD=3",
        )
        assert not os.path.exists(store), "refused setup created a run store"

        control_read, control_write = os.pipe()
        if control_read != 3:
            os.dup2(control_read, 3, inheritable=True)
            os.close(control_read)
            control_read = 3
        env = {
            **clean,
            "AGENT_CAT_RUN_STORE": store,
            "AGENT_CAT_CONTROL_FD": "3",
        }
        process = subprocess.Popen(
            [
                BINARY,
                "machine",
                "person-run",
                "person-controlled",
                "--scripted",
                "--protocol-version",
                "2",
                "--person-answering",
                "local-control",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            pass_fds=(control_read,),
            env=env,
        )
        os.close(control_read)
        controls = os.fdopen(control_write, "w", encoding="utf-8")
        assert process.stdin is not None
        process.stdin.write(body)
        process.stdin.close()
        assert process.stdout is not None
        lines = event_lines(process.stdout)
        events = []
        references = []
        pending = []
        invalid_sent = False
        valid_first_sent = False
        deadline = time.monotonic() + 30
        while True:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                if process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError(f"person control timed out after {events!r}")
                continue
            if line is None:
                break
            envelope = json.loads(line)
            assert envelope["protocolVersion"] == 2
            event = envelope["event"]
            events.append(event)
            if event["type"] == "run.completed":
                result_reference = event["result"]
                result_path = os.path.join(store, result_reference["path"])
                assert os.path.isfile(result_path), "run.completed preceded its result artifact"
                result_bytes = open(result_path, "rb").read()
                assert len(result_bytes) == int(result_reference["bytes"])
                assert hashlib.sha256(result_bytes).hexdigest() == result_reference["sha256"]
            if event["type"] == "occurrence.person-answer-pending":
                pending.append(event["occurrenceId"])
                references.append(event["question"])
                if len(pending) == 1:
                    controls.write(
                        json.dumps(
                            {
                                "controlId": "person-invalid",
                                "expectedOccurrenceId": event["occurrenceId"],
                                "expectedAttemptId": None,
                                "command": {
                                    "type": "answerPerson",
                                    "answer": "yes",
                                },
                            },
                            separators=(",", ":"),
                        )
                        + "\n"
                    )
                    controls.flush()
                    invalid_sent = True
                else:
                    controls.write(
                        json.dumps(
                            {
                                "controlId": "person-second",
                                "expectedOccurrenceId": event["occurrenceId"],
                                "expectedAttemptId": None,
                                "command": {
                                    "type": "answerPerson",
                                    "answer": False,
                                },
                            },
                            separators=(",", ":"),
                        )
                        + "\n"
                    )
                    controls.flush()
            elif (
                event["type"] == "control.ack"
                and event.get("controlId") == "person-invalid"
                and event.get("state") == "failed"
            ):
                assert "yes" not in event["message"]
                controls.write(
                    json.dumps(
                        {
                            "controlId": "person-first",
                            "expectedOccurrenceId": event["occurrenceId"],
                            "expectedAttemptId": None,
                            "command": {
                                "type": "answerPerson",
                                "answer": True,
                            },
                        },
                        separators=(",", ":"),
                    )
                    + "\n"
                )
                controls.flush()
                valid_first_sent = True

        controls.close()
        returncode = process.wait(timeout=30)
        stderr = process.stderr.read() if process.stderr is not None else ""
        assert returncode == 0, (returncode, stderr, events[-8:])
        assert invalid_sent and valid_first_sent
        assert pending == ["0", "1"], pending
        assert events[-1]["type"] == "run.completed" and "result" in events[-1]
        assert not any(
            event["type"].startswith("attempt.")
            and event.get("occurrenceId") in pending
            for event in events
        )

        for occurrence, reference in zip(pending, references):
            expected_path = f"person/questions/{occurrence}.json"
            assert reference["path"] == expected_path
            path = os.path.join(store, expected_path)
            raw = open(path, "rb").read()
            assert len(raw) == int(reference["bytes"])
            assert hashlib.sha256(raw).hexdigest() == reference["sha256"]
            assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
            artifact = json.loads(raw)
            assert artifact["runId"] == "person-run"
            assert artifact["occurrenceId"] == occurrence
            assert artifact["question"]["prompt"].endswith(body)
            assert len(artifact["question"]["prompt"]) > 500

        first_pending = next(
            index
            for index, event in enumerate(events)
            if event["type"] == "occurrence.person-answer-pending"
            and event["occurrenceId"] == "0"
        )
        first_accepted = next(
            index
            for index, event in enumerate(events)
            if event.get("controlId") == "person-first"
            and event.get("state") == "accepted"
        )
        first_delivered = next(
            index
            for index, event in enumerate(events)
            if event.get("controlId") == "person-first"
            and event.get("state") == "delivered"
        )
        first_completed = next(
            index
            for index, event in enumerate(events)
            if event["type"] == "occurrence.completed"
            and event.get("occurrenceId") == "0"
        )
        second_pending = next(
            index
            for index, event in enumerate(events)
            if event["type"] == "occurrence.person-answer-pending"
            and event["occurrenceId"] == "1"
        )
        assert first_pending < first_accepted < first_delivered < first_completed < second_pending

        answers = json.load(open(os.path.join(store, "answers.json")))
        values = [record["answer"] for record in answers["answers"]]
        assert sorted(values) == [False, True]
        manifest = json.load(open(os.path.join(store, "manifest.json")))
        assert manifest["storeVersion"] == 2
        assert manifest["protocolVersion"] == 2
        assert manifest["run"]["personAnswering"] == "local-control"
        assert body not in json.dumps(manifest)
        assert body not in stderr
        print(
            "person control probe: setup refusal, typed validation, FIFO, private prompt artifacts, "
            "ack ordering, persistence, and no-attempt invariant passed"
        )
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
