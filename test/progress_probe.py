#!/usr/bin/env python3
"""Verify protocol-v2 public progress without changing answer or billing semantics."""

from __future__ import annotations

import hashlib
import json
import os
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
    return events, store


def semantic_projection(events: list[dict]) -> tuple[list, list, tuple]:
    occurrences = [
        (event["event"]["occurrenceId"], event["event"]["source"], event["event"]["answer"])
        for event in events if event["event"]["type"] == "occurrence.completed"
    ]
    trace = next(event["event"]["occurrenceIds"] for event in events if event["event"]["type"] == "trace.ordered")
    terminal = events[-1]["event"]
    return occurrences, trace, (terminal["billFresh"], terminal["billMemo"])


def main() -> None:
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: progress_probe.py AGENTIC_RUN [BROKER_RUNNER]")
    runner = Path(sys.argv[1]).resolve()
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
        if len(sys.argv) == 3:
            hello, _ = machine(runner, root, "broker-hello", 2, target, workflow="hello")
            assert hello[-1]["event"]["type"] == "run.completed"
            assert semantic_projection(hello)[2] == ("3", "3")
            broker_runner = Path(sys.argv[2]).resolve()
            brokered, broker_store = machine(
                broker_runner, root, "broker-injected", 2,
                [*target, "--input-arg", "input=broker request"],
                workflow="prompt-source", prefix=("--broker-test",),
            )
            occurrences, trace, bills = semantic_projection(brokered)
            assert len(occurrences) == 1 and occurrences[0][2] == "broker-delivered response"
            assert trace == [occurrences[0][0]] and bills == ("1", "1")
            assert brokered[-1]["event"]["type"] == "run.completed"
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
