#!/usr/bin/env python3
"""Verify protocol-v2 public progress without changing answer or billing semantics.

Each store-backed run must also write the run log flow.ndjson: line 0 is the
start record from the local account with the owner that AGENT_CAT_RUN_OWNER
declares, and the event records name the sequence numbers of events.ndjson in
order. With a broker runner, the broker-hello and broker-injected run logs must
also hold, for each occurrence, the question, the engine start, the turn, the
engine result and the answer, each reply naming its ask.

With a broker runner, the probe also compares the store-backed broker-hello
events.ndjson, with each timestamp replaced, against the golden file
test/fixtures/flow/hello-events.ndjson or the file that --golden names.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def machine(
    runner: Path, root: Path, run_id: str, protocol: int, target: list[str],
    *, workflow: str = "harden", prefix: tuple[str, ...] = (),
) -> tuple[list[dict], Path]:
    run_root = root / run_id
    scratch = run_root / "scratch"
    store = run_root / "runtime"
    scratch.mkdir(parents=True)
    environment = os.environ.copy()
    environment["AGENT_CAT_RUN_STORE"] = str(store)
    environment["AGENT_CAT_RUN_OWNER"] = owner_for(run_id)
    command = [str(runner), *prefix, "machine", run_id, workflow, *target]
    if "--engine" in target:
        command.extend(["--timeout", "60000", "--scratch", str(scratch)])
    command.extend(["--protocol-version", str(protocol)])
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
        timeout=120,
    )
    if result.returncode != 0:
        raise AssertionError(f"machine protocol {protocol} failed ({result.returncode}): {result.stderr.decode('utf8', 'replace')}")
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert events and all(event["protocolVersion"] == protocol for event in events)
    assert_run_log(store, run_id, protocol)
    return events, store


def owner_for(run_id: str) -> str:
    return f"local:progress-probe:{run_id}"


SHA256 = re.compile(r"[0-9a-f]{64}")


def assert_run_log(store: Path, run_id: str, protocol: int) -> dict:
    """Check the run log of a store-backed run and return its start body."""
    records = [json.loads(line) for line in (store / "flow.ndjson").read_bytes().splitlines()]
    events = [json.loads(line) for line in (store / "events.ndjson").read_bytes().splitlines()]
    assert records, f"{run_id}: flow.ndjson is empty"
    start = records[0]
    assert start["schema"] == "start", f"{run_id}: flow.ndjson line 0 is {start['schema']}"
    assert start["from"] == {"principal": "local", "uid": os.getuid(), "owner": owner_for(run_id)}, start["from"]
    assert start["to"] == {"to": {"workflow": run_id}} and start["about"] == {"nativeRun": run_id}, start
    body = start["body"]["inline"]
    assert body["run"] == run_id and body["lineage"] == "root" and body["parent"] is None, body
    assert SHA256.fullmatch(body["programSha256"]) and SHA256.fullmatch(body["policyDigest"]), body
    assert body["personAnswering"] == (None if protocol == 1 else "engine"), body
    assert [record["schema"] for record in records].count("start") == 1
    numbered = [record["body"]["event"] for record in records if record["schema"] == "event"]
    assert numbered == list(range(len(events))), f"{run_id}: event records {numbered} for {len(events)} events"
    assert [int(event["sequence"]) for event in events] == numbered
    for record in records[1:]:
        if record["schema"] == "event":
            assert record["from"] == {"workflow": run_id} and record["to"] == "public", record
    return body


ANSWERS = {
    "answer": {"question"},
    "engine-result": {"turn"},
    "done": {"engine-start", "steer"},
    "failure": {"question", "engine-start", "turn", "steer", "command"},
}
HELLO_EXCHANGE = ["question", "engine-start", "done", "turn", "engine-result", "answer"]


def assert_carriage(store: Path, run_id: str, expected: list[str]) -> list[dict]:
    """Check the carried records of a run log: each reply names an earlier ask
    that it may answer, carries the identifiers of that ask and comes from its
    addressee, and the records other than events are the expected schemas."""
    records = [json.loads(line) for line in (store / "flow.ndjson").read_bytes().splitlines()]
    for index, record in enumerate(records):
        if record["schema"] in ANSWERS:
            asked = record["replyTo"]
            assert 0 <= asked < index, f"{run_id}: reply {index} names position {asked}"
            ask = records[asked]
            assert ask["schema"] in ANSWERS[record["schema"]], f"{run_id}: {record['schema']} {index} answers {ask['schema']}"
            assert record["about"] == ask["about"], f"{run_id}: reply {index} about {record['about']} differs from its ask {ask['about']}"
            assert {"to": record["from"]} == ask["to"], f"{run_id}: reply {index} from {record['from']} but its ask went {ask['to']}"
        elif record["schema"] in ("question", "engine-start", "turn"):
            assert record["from"] == {"workflow": run_id}, record
            assert record["about"]["nativeRun"] == run_id and "occurrence" in record["about"] and "epoch" in record["about"], record
    schemas = [record["schema"] for record in records if record["schema"] != "event"]
    assert schemas == expected, f"{run_id}: carried schemas {schemas}, expected {expected}"
    return records


DEFAULT_GOLDEN = Path(__file__).resolve().parent / "fixtures" / "flow" / "hello-events.ndjson"
TIMESTAMP = re.compile(rb',"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z"}$')


def normalized_events(path: Path) -> bytes:
    """Return the bytes of an events file with each line's final timestamp replaced."""
    lines = []
    for number, line in enumerate(path.read_bytes().splitlines()):
        normalized, count = TIMESTAMP.subn(b',"timestamp":"<timestamp>"}', line)
        if count != 1:
            raise AssertionError(f"{path} line {number} has no final timestamp field")
        lines.append(normalized + b"\n")
    return b"".join(lines)


def assert_golden(actual: bytes, golden: Path) -> None:
    expected = golden.read_bytes()
    if actual == expected:
        return
    actual_lines, expected_lines = actual.splitlines(), expected.splitlines()
    for number, (seen, wanted) in enumerate(zip(actual_lines, expected_lines)):
        if seen != wanted:
            raise AssertionError(f"broker-hello events.ndjson differs from {golden} at line {number}:\n  got  {seen!r}\n  want {wanted!r}")
    raise AssertionError(f"broker-hello events.ndjson has {len(actual_lines)} lines, {golden} has {len(expected_lines)}")


def semantic_projection(events: list[dict]) -> tuple[list, list, tuple]:
    occurrences = [
        (event["event"]["occurrenceId"], event["event"]["source"], event["event"]["answer"])
        for event in events if event["event"]["type"] == "occurrence.completed"
    ]
    trace = next(event["event"]["occurrenceIds"] for event in events if event["event"]["type"] == "trace.ordered")
    terminal = events[-1]["event"]
    return occurrences, trace, (terminal["billFresh"], terminal["billMemo"])


def main() -> None:
    arguments = sys.argv[1:]
    golden = DEFAULT_GOLDEN
    if arguments[:1] == ["--golden"]:
        golden = Path(arguments[1]).resolve() if len(arguments) > 1 else Path()
        arguments = arguments[2:]
    if len(arguments) not in (1, 2) or golden == Path():
        raise SystemExit("usage: progress_probe.py [--golden PATH] AGENTIC_RUN [BROKER_RUNNER]")
    runner = Path(arguments[0]).resolve()
    with tempfile.TemporaryDirectory(prefix="agent-cat-progress-") as directory:
        root = Path(directory)
        target = ["--engine", "acp", "--adapter", "stub"]
        legacy, _ = machine(runner, root, "progress-v1", 1, target)
        latest, latest_store = machine(runner, root, "progress-v2", 2, target)
        assert semantic_projection(legacy) == semantic_projection(latest)
        assert not any(event["event"]["type"] == "attempt.progress" for event in legacy)
        progress = [event["event"]["progress"] for event in latest if event["event"]["type"] == "attempt.progress"]
        assert any(update["kind"] == "tool" for update in progress)
        assert any(update["kind"] == "usage" for update in progress)
        assert any(update["kind"] == "todos" for update in progress)
        encoded = b"\n".join(json.dumps(event, separators=(",", ":")).encode() for event in latest)
        assert b"fixture-progress-value-8675309" not in encoded
        assert b"opaque-value-8675309" not in encoded
        assert b"private-reasoning-sentinel" not in encoded
        assert any(update.get("tool", {}).get("summary") == "<redacted public update>" for update in progress)
        persisted = [json.loads(line) for line in (latest_store / "events.ndjson").read_text().splitlines()]
        assert [event["event"] for event in persisted] == [event["event"] for event in latest]

        scripted, _ = machine(runner, root, "progress-none", 2, ["--scripted"])
        assert not any(event["event"]["type"] == "attempt.progress" for event in scripted)
        if len(arguments) == 2:
            hello, hello_store = machine(runner, root, "broker-hello", 2, target, workflow="hello")
            assert hello[-1]["event"]["type"] == "run.completed"
            assert semantic_projection(hello)[2] == ("3", "3")
            assert_golden(normalized_events(hello_store / "events.ndjson"), golden)
            print(f"golden probe: broker-hello events.ndjson equals {golden.name} except timestamps")
            carried = assert_carriage(hello_store, "broker-hello", ["start", *HELLO_EXCHANGE * 3])
            questions = [record["to"] for record in carried if record["schema"] == "question"]
            assert questions == [{"to": {"model": "model namer"}}, {"to": {"model": "model greeter"}}, {"to": {"model": "tool say"}}], questions
            print("carriage probe: broker-hello records a question, engine start, turn, engine result and answer for each occurrence")
            broker_runner = Path(arguments[1]).resolve()
            brokered, broker_store = machine(
                broker_runner, root, "broker-injected", 2,
                [*target, "--input-arg", "input=broker request"],
                workflow="prompt-source", prefix=("--broker-test",),
            )
            occurrences, trace, bills = semantic_projection(brokered)
            assert len(occurrences) == 1 and occurrences[0][2] == "broker-delivered response"
            assert trace == [occurrences[0][0]] and bills == ("1", "1")
            assert brokered[-1]["event"]["type"] == "run.completed"
            inputs = assert_run_log(broker_store, "broker-injected", 2)["inputs"]
            injected = assert_carriage(broker_store, "broker-injected", ["start", *HELLO_EXCHANGE])
            results = [record["body"]["inline"]["answer"] for record in injected if record["schema"] == "engine-result"]
            assert results == ["broker-delivered response"], results
            request = b"broker request"
            assert inputs == [{"name": "input", "bytes": len(request), "sha256": hashlib.sha256(request).hexdigest()}], inputs
            persisted_broker = [json.loads(line) for line in (broker_store / "events.ndjson").read_text().splitlines()]
            assert [event["event"] for event in persisted_broker] == [event["event"] for event in brokered]
            reference = brokered[-1]["event"]["result"]
            assert reference["preview"] == "broker-delivered result" and reference["path"] == "result.json"
            result_bytes = (broker_store / "result.json").read_bytes()
            assert len(result_bytes) == int(reference["bytes"])
            assert hashlib.sha256(result_bytes).hexdigest() == reference["sha256"]
            artifact = json.loads(result_bytes)
            assert artifact["runId"] == "broker-injected"
            assert artifact["result"] == {"code": "receipt", "value": None}
            assert artifact["result"]["code"] == reference["code"]
            print("broker probe: real ACP replies and verified final publication cross the injected broker")
    print("progress probe: bounded public progress is persisted, redacted, optional, and answer-neutral")


if __name__ == "__main__":
    main()
