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


def person_answer_refusal(args, env, expected):
    """A target with --person-answer outside local control is refused before
    any run store exists."""
    result = subprocess.run(
        [BINARY, *args], env=env, text=True, capture_output=True, timeout=30
    )
    assert result.returncode == 1, (args, result.returncode, result.stdout, result.stderr)
    assert expected in result.stderr, (args, result.stderr)


def controlled_machine(root, run_id, workflow, target, body, respond, prefix=()):
    """Run one protocol-v2 machine under local control. respond(event) returns
    the controls to send for each event. With the counting broker prefix the
    result includes its delivery counts."""
    store = os.path.join(root, run_id, "runtime")
    scratch = os.path.join(root, run_id, "scratch")
    os.makedirs(scratch)
    control_read, control_write = os.pipe()
    if control_read != 3:
        os.dup2(control_read, 3, inheritable=True)
        os.close(control_read)
        control_read = 3
    env = {
        **os.environ,
        "AGENT_CAT_RUN_STORE": store,
        "AGENT_CAT_CONTROL_FD": "3",
        "AGENT_CAT_RUN_OWNER": f"local:person-probe:{run_id}",
    }
    process = subprocess.Popen(
        [
            BINARY, *prefix, "machine", run_id, workflow, *target,
            "--scratch", scratch, "--protocol-version", "2",
            "--person-answering", "local-control",
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
    try:
        process.stdin.write(body)
        process.stdin.close()
        lines = event_lines(process.stdout)
        events = []
        deadline = time.monotonic() + 60
        while True:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                if time.monotonic() >= deadline:
                    raise AssertionError(f"{run_id} timed out after {events[-5:]!r}")
                continue
            if line is None:
                break
            event = json.loads(line)["event"]
            events.append(event)
            for control in respond(event):
                controls.write(json.dumps(control, separators=(",", ":")) + "\n")
                controls.flush()
        returncode = process.wait(timeout=30)
        stderr = process.stderr.read()
    finally:
        controls.close()
        if process.poll() is None:
            process.kill()
            process.wait()
    assert returncode == 0, (run_id, returncode, stderr, events[-5:])
    counted = [line for line in stderr.splitlines() if line.startswith("broker-test counts: ")]
    counts = dict(item.split("=") for line in counted for item in line.split(": ", 1)[1].split())
    records = [json.loads(line) for line in open(os.path.join(store, "flow.ndjson"), "rb").read().splitlines()]
    return store, events, {key: int(value) for key, value in counts.items()}, records, env["AGENT_CAT_RUN_OWNER"]


def person_answers(root):
    """Asks named by --person-answer are answered by a person through the
    local control channel, with no engine start, and a target without the
    field asks the model as before."""
    stub = ["--engine", "acp", "--adapter", "stub", "--timeout", "60000"]
    named = [*stub, "--person-answer", "model:controlled"]
    body = "person-answer body"
    clean = {key: value for key, value in os.environ.items() if key != "AGENT_CAT_CONTROL_FD"}

    # Engine answering mode, plain run, scripted target and malformed addresses.
    refused_store = os.path.join(root, "refused")
    person_answer_refusal(
        ["machine", "refused", "controlled-single", *named, "--protocol-version", "2"],
        {**clean, "AGENT_CAT_RUN_STORE": refused_store},
        "--person-answer requires a machine run with --person-answering local-control",
    )
    person_answer_refusal(
        ["machine", "refused", "controlled-single", *named, "--protocol-version", "2",
         "--person-answering", "engine"],
        {**clean, "AGENT_CAT_RUN_STORE": refused_store},
        "--person-answer requires a machine run with --person-answering local-control",
    )
    person_answer_refusal(
        ["run", "controlled-single", *named],
        clean,
        "--person-answer requires a machine run with --person-answering local-control",
    )
    person_answer_refusal(
        ["machine", "refused", "person-controlled", "--scripted", "--person-answer", "model:controlled",
         "--protocol-version", "2", "--person-answering", "local-control"],
        {**clean, "AGENT_CAT_RUN_STORE": refused_store},
        "--person-answer is not --scripted's to take",
    )
    for address in ("person:owner", "model:", "controlled"):
        person_answer_refusal(
            ["machine", "refused", "controlled-single", *stub, "--person-answer", address,
             "--protocol-version", "2", "--person-answering", "local-control"],
            {**clean, "AGENT_CAT_RUN_STORE": refused_store},
            "--person-answer: a person-answer address is model:NAME or tool:NAME",
        )
    person_answer_refusal(
        ["machine", "refused", "controlled-single", *named, "--person-answer", "model:controlled",
         "--protocol-version", "2", "--person-answering", "local-control"],
        {**clean, "AGENT_CAT_RUN_STORE": refused_store},
        "--person-answer names 'model:controlled' twice",
    )
    assert not os.path.exists(refused_store), "a refused --person-answer target created a run store"

    # The named model ask waits for a person, refuses an ill-typed answer,
    # and completes with the typed answer and no engine start.
    acks = {}

    def answer(event):
        if event["type"] == "occurrence.person-answer-pending":
            return [{"controlId": "model-invalid", "expectedOccurrenceId": event["occurrenceId"],
                     "expectedAttemptId": None, "command": {"type": "answerPerson", "answer": "yes"}}]
        if event["type"] == "control.ack":
            acks.setdefault(event["controlId"], []).append(event)
            if event["controlId"] == "model-invalid" and event["state"] == "failed":
                assert "yes" not in event["message"], event
                return [{"controlId": "model-person", "expectedOccurrenceId": event["occurrenceId"],
                         "expectedAttemptId": None, "command": {"type": "answerPerson", "answer": True}}]
        return []

    store, events, counts, records, owner = controlled_machine(
        root, "person-answer-run", "controlled-single", named, body, answer, ("--broker-test",))
    started = [event for event in events if event["type"] == "occurrence.started"]
    assert len(started) == 1 and started[0]["addressee"] == "person model:controlled", started
    occurrence = started[0]["occurrenceId"]
    pending = [event for event in events if event["type"] == "occurrence.person-answer-pending"]
    assert [event["occurrenceId"] for event in pending] == [occurrence], pending
    assert [event["state"] for event in acks["model-invalid"]] == ["accepted", "failed"], acks
    assert [event["state"] for event in acks["model-person"]] == ["accepted", "delivered"], acks
    assert not any(event["type"].startswith("attempt.") for event in events), events
    completed = [event for event in events if event["type"] == "occurrence.completed"]
    assert [event["occurrenceId"] for event in completed] == [occurrence], completed
    assert events[-1]["type"] == "run.completed", events[-1]
    assert counts["start"] == 0 and counts["turn"] == 0, counts
    assert not any(record["schema"] in ("engine-start", "turn") for record in records), records
    principal = {"principal": "local", "uid": os.getuid(), "owner": owner}
    questions = [(index, record) for index, record in enumerate(records) if record["schema"] == "question"]
    assert len(questions) == 1 and questions[0][1]["to"] == {"to": principal}, questions
    reply = next(record for record in records if record.get("replyTo") == questions[0][0])
    assert reply["schema"] == "answer" and reply["from"] == principal, reply
    assert reply["about"]["command"] == "model-person" and reply["body"]["inline"] is True, reply
    answers = json.load(open(os.path.join(store, "answers.json")))
    assert [record["answer"] for record in answers["answers"]] == [True], answers
    print("person answers: a named model ask waited for a person, refused an ill-typed answer, "
          "completed with no engine start, and its run-log answer names the controlling principal")

    # Without the field the same ask goes to the model under local control.
    def unexpected(event):
        assert event["type"] != "occurrence.person-answer-pending", event
        return []

    _, events, counts, records, _ = controlled_machine(
        root, "model-answer-run", "controlled-single", stub, body, unexpected)
    started = [event for event in events if event["type"] == "occurrence.started"]
    assert len(started) == 1 and started[0]["addressee"] == "model controlled@primary", started
    assert any(event["type"].startswith("attempt.") for event in events), events
    assert events[-1]["type"] == "run.completed", events[-1]
    assert not counts, counts
    assert any(record["schema"] == "engine-start" for record in records), records
    question = next(record for record in records if record["schema"] == "question")
    assert "model" in question["to"]["to"], question
    print("person answers: without --person-answer the model answers as before")


def frontend_request(case, arguments, answering):
    payload = {
        "version": 1,
        "operation": "prepare",
        "workflow": "prompt-source",
        "stateDirectory": os.path.join(case, "state"),
        "targetArguments": arguments,
        "inputs": [{"name": "input", "source": "literal", "value": "frontend person answer"}],
    }
    if answering is not None:
        payload["personAnswering"] = answering
    env = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_CAT_")}
    env["XDG_CONFIG_HOME"] = os.path.join(case, "config")
    return (json.dumps(payload, separators=(",", ":")) + "\n").encode(), env


def frontend_person_answers(root):
    """Frontend preparation shows personAnswers only when the target names an
    address, refuses it outside local control, and the approved run asks the
    named model's question through the person gate."""
    adapter = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "engine", "acp", "test", "stub_adapter.py")
    stub = ["--engine", "acp", "--adapter", sys.executable, "--adapter-arg", adapter, "--timeout", "60000"]
    named = [*stub, "--person-answer", "model:fixed-point"]

    case = tempfile.mkdtemp(dir=root, prefix="frontend-engine-")
    body, env = frontend_request(case, named, "engine")
    refused = subprocess.run([BINARY, "frontend"], input=body, capture_output=True, cwd=case, env=env, timeout=30)
    assert refused.returncode == 3 and not refused.stdout, (refused.returncode, refused.stdout, refused.stderr)
    assert b"--person-answer requires a machine run with --person-answering local-control" in refused.stderr, refused.stderr
    assert not os.path.exists(os.path.join(case, "state", "runs")), "refused preparation created a run"

    policies = {}
    for label, arguments in (("plain", stub), ("named", named)):
        case = tempfile.mkdtemp(dir=root, prefix=f"frontend-{label}-")
        body, env = frontend_request(case, arguments, None)
        process = subprocess.Popen(
            [BINARY, "frontend"], cwd=case, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        process.stdin.write(body)
        lines = event_lines(process.stdout)
        preview = json.loads(lines.get(timeout=30))
        assert preview["operation"] == "prepared", preview
        policies[label] = preview["policy"]
        if label == "plain":
            process.stdin.write((json.dumps({"version": 1, "operation": "discard", "approvalId": preview["approvalId"]}) + "\n").encode())
            process.stdin.close()
            assert process.wait(timeout=30) == 0, process.stderr.read()
            continue
        assert preview["targetArguments"][: len(named)] == named, preview["targetArguments"]
        process.stdin.write((json.dumps({"version": 1, "operation": "start", "approvalId": preview["approvalId"]}) + "\n").encode())
        events = []
        while (line := lines.get(timeout=60)) is not None:
            event = json.loads(line)["event"]
            events.append(event)
            if event["type"] == "occurrence.person-answer-pending":
                process.stdin.write((json.dumps({
                    "controlId": "frontend-invalid", "expectedOccurrenceId": event["occurrenceId"],
                    "expectedAttemptId": None, "command": {"type": "answerPerson", "answer": 42},
                }) + "\n").encode())
            elif event["type"] == "control.ack" and event["controlId"] == "frontend-invalid" and event["state"] == "failed":
                process.stdin.write((json.dumps({
                    "controlId": "frontend-person", "expectedOccurrenceId": event["occurrenceId"],
                    "expectedAttemptId": None, "command": {"type": "answerPerson", "answer": "typed by a person"},
                }) + "\n").encode())
            elif event["type"] == "run.completed":
                process.stdin.close()
        assert process.wait(timeout=30) == 0, process.stderr.read()
        started = [event for event in events if event["type"] == "occurrence.started"]
        assert [event["addressee"] for event in started] == ["person model:fixed-point"], started
        assert not any(event["type"].startswith("attempt.") for event in events), events
        assert any(event.get("controlId") == "frontend-person" and event.get("state") == "delivered" for event in events), events
        assert events[-1]["type"] == "run.completed", events[-1]
    assert "personAnswers" not in policies["plain"], policies["plain"]
    assert policies["named"]["personAnswers"] == ["model:fixed-point"], policies["named"]
    unchanged = {key: value for key, value in policies["named"].items() if key not in ("personAnswers", "scratch")}
    assert unchanged == {key: value for key, value in policies["plain"].items() if key != "scratch"}, policies
    print("person answers: frontend preparation shows personAnswers only when set, refuses it in engine mode, "
          "and the approved run asks the named model through the person gate")


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
        person_answers(root)
        frontend_person_answers(root)
        print(
            "person control probe: setup refusal, typed validation, FIFO, private prompt artifacts, "
            "ack ordering, persistence, and no-attempt invariant passed"
        )
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
