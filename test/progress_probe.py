#!/usr/bin/env python3
"""Verify protocol-v2 public progress without changing answer or billing semantics."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def machine(runner: Path, root: Path, run_id: str, protocol: int, target: list[str]) -> tuple[list[dict], Path]:
    run_root = root / run_id
    scratch = run_root / "scratch"
    store = run_root / "runtime"
    scratch.mkdir(parents=True)
    environment = os.environ.copy()
    environment["AGENT_CAT_RUN_STORE"] = str(store)
    command = [str(runner), "machine", run_id, "harden", *target]
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
    if len(sys.argv) != 2:
        raise SystemExit("usage: progress_probe.py AGENTIC_RUN")
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
    print("progress probe: bounded public progress is persisted, redacted, optional, and answer-neutral")


if __name__ == "__main__":
    main()
