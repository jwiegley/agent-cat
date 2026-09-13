#!/usr/bin/env python3
"""Verify native preparation and execution through the real CLI and private pipe."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time


def encode(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class Session:
    active: list[Session] = []

    def __init__(self, runner: Path, directory: Path, workflow: str, inputs: list[dict], arguments: list[str] | None = None, environment: dict[str, str] | None = None, request: dict | None = None, command_prefix: list[str] | None = None, request_bytes: bytes | None = None):
        self.root = Path(request["stateDirectory"]) if request else directory / "state"
        existing = {path.name for path in (self.root / "runs").glob("*")}
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_CAT_")}
        self.environment["XDG_CONFIG_HOME"] = str(directory / "config")
        self.environment.update(environment or {})
        self.process = subprocess.Popen(
            [*(command_prefix or [str(runner)]), "frontend"], cwd=directory, env=self.environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, close_fds=True,
        )
        self.active.append(self)
        self.buffer = b""
        if request_bytes is not None:
            self.send_raw(request_bytes + b"\n")
        else:
            self.send(request or {"version": 1, "operation": "prepare", "workflow": workflow,
                                  "stateDirectory": str(self.root), "targetArguments": arguments or ["--scripted"], "inputs": inputs})
        self.preview = self.read()
        assert self.preview is not None, (workflow, directory, self.process.wait(timeout=10), self.process.stderr.read())
        self.preview_frame = self.last_raw_frame
        assert self.preview["version"] == 1 and self.preview["operation"] == "prepared", self.preview
        assert set(self.preview["server"]) == {"runnerId", "executable", "runnerVersion"}
        assert self.preview["invocation"] == (request or {}).get("invocation")
        assert {path.name for path in (self.root / "runs").glob("*")} == existing, "preparation created a run before approval"

    def send(self, *values: object) -> None:
        self.send_raw(b"".join(encode(value) + b"\n" for value in values))

    def send_raw(self, body: bytes) -> None:
        view = memoryview(body)
        while view:
            written = self.process.stdin.write(view)
            assert written
            view = view[written:]

    def read(self) -> dict | None:
        deadline = time.monotonic() + 20
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.process.stdout], [], [],remaining)[0], "native session timed out"
            block = os.read(self.process.stdout.fileno(), 32768)
            if not block:
                assert not self.buffer, self.buffer
                return None
            self.buffer += block
            assert len(self.buffer) <= 64 * 1024 * 1024 + 4096
        line, self.buffer = self.buffer.split(b"\n", 1)
        self.last_raw_frame = line + b"\n"
        return json.loads(line)

    def decision(self, operation: str, **changes: object) -> dict:
        return {"version": 1, "operation": operation, "approvalId": self.preview["approvalId"], **changes}

    def finish(self, expected: int = 0) -> list[dict]:
        frames = []
        while (frame := self.read()) is not None:
            frames.append(frame)
        code = self.process.wait(timeout=20)
        errors = self.process.stderr.read()
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        assert code == expected, (code, errors, frames[-3:])
        return frames

    @property
    def run(self) -> Path:
        return self.root / "runs" / self.preview["runId"]


def query(runner: Path, directory: Path, request: dict) -> dict:
    answer = subprocess.run([str(runner), "frontend-io"], input=encode(request), capture_output=True, cwd=directory, timeout=10)
    assert answer.returncode == 0, answer.stderr
    return json.loads(answer.stdout)


def capability_discovery(runner: Path, directory: Path) -> tuple[Path, list[str], dict]:
    case = directory / "capabilities"
    case.mkdir()
    state = case / "must-not-exist"
    config = case / "config/agent-cat"
    config.mkdir(parents=True)
    (config / "routing.yaml").write_text("invalid: [routing\n", encoding="utf-8")
    prefix = ["--profile", "work"]
    wrapper = case / "trusted-wrapper.py"
    wrapper.write_text(
        f"#!{sys.executable}\n"
        "import os, sys\n"
        f"expected = {prefix!r}\n"
        f"runner = {str(runner)!r}\n"
        "assert sys.argv[1:1 + len(expected)] == expected, sys.argv\n"
        "os.execv(runner, [runner, *sys.argv[1 + len(expected):]])\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o700)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_CAT_")}
    environment.update(XDG_CONFIG_HOME=str(case / "config"), AGENT_CAT_STATE_DIR=str(state))
    discovered = subprocess.run(
        [str(wrapper), *prefix, "frontend", "--capabilities"], stdin=subprocess.DEVNULL,
        capture_output=True, cwd=case, env=environment, timeout=10,
    )
    assert discovered.returncode == 0 and not discovered.stderr, discovered
    assert discovered.stdout.endswith(b"\n") and discovered.stdout.count(b"\n") == 1
    (case / "capabilities.ndjson").write_bytes(discovered.stdout)
    capabilities = json.loads(discovered.stdout)
    assert capabilities == {
        "version": 1,
        "operation": "capabilities",
        "server": {
            "runnerId": runner.name,
            "executable": str(runner),
            "runnerVersion": capabilities["server"]["runnerVersion"],
        },
        "session": {
            "versions": [1],
            "operations": ["prepare", "prepare-lineage", "start", "discard"],
            "inputSources": ["literal", "file", "transport"],
            "invocationVersions": [1],
            "maxRequestBytes": 2 * 1024 * 1024,
        },
        "io": {
            "versions": [1, 2],
            "operations": ["open-root", "read-question", "read-result", "list-runs", "read-run",
                           "read-run-checkpoint", "read-question-schema"],
        },
        "export": {
            "versions": [1],
            "operations": ["export-result"],
            "format": "result-json",
            "destination": "state-exports",
        },
        "frontendManifestVersions": [2, 3],
        "legacyFrontendManifests": True,
    }
    assert capabilities["server"]["runnerVersion"] and not state.exists()
    return wrapper, prefix, capabilities


def invocation_contract(runner: Path, directory: Path, wrapper: Path, prefix: list[str], capabilities: dict) -> Session:
    case = directory / "invocation"
    case.mkdir()
    invocation = {
        "version": 1,
        "runnerAlias": "configured alias 世界",
        "executable": str(wrapper),
        "prefixArgs": prefix,
    }
    request = {
        "version": 1,
        "operation": "prepare",
        "workflow": "prompt-source",
        "stateDirectory": str(case / "state"),
        "targetArguments": ["--scripted"],
        "inputs": [{"name": "input", "source": "literal", "value": "invocation fixture"}],
        "invocation": invocation,
    }
    session = Session(runner, case, "", [], request=request, command_prefix=[str(wrapper), *prefix])
    assert session.preview["server"] == capabilities["server"]
    assert session.preview["descriptor"]["runnerVersion"] == capabilities["server"]["runnerVersion"]
    assert session.preview["invocation"] == invocation
    session.send(session.decision("start"))
    events = session.finish()
    assert events[-1]["event"]["type"] == "run.completed"
    manifest = json.loads((session.run / "supervisor-manifest.json").read_bytes())
    assert manifest["frontendManifestVersion"] == 3 and manifest["invocation"] == invocation
    assert manifest["runnerId"] == capabilities["server"]["runnerId"]
    assert manifest["runnerExecutable"] == capabilities["server"]["executable"]
    assert manifest["runnerVersion"] == capabilities["server"]["runnerVersion"]
    history = query(runner, case, {"version": 1, "operation": "list-runs", "rootIdentity": session.preview["rootIdentity"]})["runs"]
    row = next(item for item in history if item.get("runId") == session.preview["runId"])
    assert row["invocation"] == invocation
    observed = query(runner, case, {"version": 1, "operation": "read-run", "rootIdentity": session.preview["rootIdentity"], "runId": session.preview["runId"]})["run"]
    assert observed["manifest"] == manifest

    bare = {**invocation, "runnerAlias": "bare", "executable": "configured-command", "prefixArgs": []}
    discarded = Session(runner, case, "", [], request={**request, "stateDirectory": str(case / "bare-state"), "invocation": bare})
    assert discarded.preview["invocation"] == bare
    discarded.send(discarded.decision("discard"))
    assert discarded.finish() == []
    return session


def source_vectors(runner: Path, directory: Path) -> None:
    fixture = json.loads((Path(__file__).parent / "fixtures/runtime/input-sources/v1.json").read_bytes())
    assert fixture["version"] == 1
    values = fixture["vectors"]
    for source in ["prompt", "tail", "stdin"]:
        for mode in ["transport", "literal", "file"]:
            for index, vector in enumerate(values):
                case = directory / f"{source}-{mode}-{index}"
                case.mkdir()
                value = vector["literalValue"]
                raw = bytes.fromhex(vector["utf8Hex"])
                assert raw == value.encode("utf-8") and hashlib.sha256(raw).hexdigest() == vector["sha256"]
                expected = value
                if mode == "literal":
                    inputs = [{"name": "input", "source": "literal", "value": value}]
                    if source == "prompt":
                        raw = bytes.fromhex(vector["literalPromptFile"]["utf8Hex"])
                        assert hashlib.sha256(raw).hexdigest() == vector["literalPromptFile"]["sha256"]
                else:
                    path = case / "source.txt"
                    path.write_bytes(raw)
                    if mode == "transport":
                        inputs = [{"name": "input", "source": "transport", "value": path.read_bytes().decode("utf-8")}]
                        path.write_bytes(b"changed before preparation")
                        path.unlink()
                    else:
                        inputs = [{"name": "input", "source": "file", "path": str(path)}]
                    expected = vector["fileValues"]["command-tail" if source == "tail" else source]
                session = Session(runner, case, source + "-source", inputs)
                preview = session.preview
                assert preview["inputs"] == [{"name": "input", "bytes": str(len(raw)), "sha256": hashlib.sha256(raw).hexdigest()}]
                oracle = subprocess.run(
                    [str(runner), "plan", source + "-source", "--json", "--raw", "--input-arg", "input=" + expected],
                    capture_output=True, cwd=case, env=session.environment, timeout=10,
                )
                assert oracle.returncode == 0, oracle.stderr
                assert preview["plan"]["program"] == json.loads(oracle.stdout)["program"]
                if mode == "file":
                    path.write_text("changed after capture", encoding="utf-8")
                session.send(session.decision("start"))
                events = session.finish()
                assert all(frame["protocolVersion"] == 2 for frame in events)
                assert events[-1]["event"]["type"] == "run.completed"
                stored = session.run / "inputs/0.txt"
                assert stored.read_bytes() == raw
                assert stat.S_IMODE(stored.stat().st_mode) == 0o600
                manifest = json.loads((session.run / "supervisor-manifest.json").read_bytes())
                assert manifest["frontendManifestVersion"] == 2 and "invocation" not in manifest
                assert manifest["inputHashes"] == {"input": hashlib.sha256(raw).hexdigest()}
                restored = subprocess.run(
                    [str(runner), "plan", source + "-source", "--json", "--raw", "--input-file", f"input={stored}"],
                    capture_output=True, cwd=case, env=session.environment, timeout=10,
                )
                assert restored.returncode == 0, restored.stderr
                assert json.loads(restored.stdout)["program"] == preview["plan"]["program"]
                reference = events[-1]["event"]["result"]
                result = query(runner, case, {"version": 1, "operation": "read-result", "rootIdentity": preview["rootIdentity"],
                                               "runId": preview["runId"], "reference": reference})
                assert result["code"] == reference["code"]
                history = query(runner, case, {"version": 1, "operation": "list-runs", "rootIdentity": preview["rootIdentity"]})["runs"]
                assert len(history) == 1 and history[0]["runId"] == preview["runId"]
                assert history[0]["invocation"] is None
                assert history[0]["ownership"] == "terminal" and history[0]["resultReferenceAvailable"] is True
                assert "occurrences" not in history[0]["snapshot"]
                observed = query(runner, case, {"version": 1, "operation": "read-run", "rootIdentity": preview["rootIdentity"],
                                               "runId": preview["runId"]})["run"]
                assert observed["manifest"] == manifest and observed["snapshot"]["status"] == "succeeded"
                assert observed["snapshot"]["result"] == reference


def decisions(runner: Path, directory: Path) -> None:
    for operation in ["discard", "stale", "root-change", "buffered-cancel", "buffered-eof"]:
        case = directory / operation
        case.mkdir()
        workflow = "person-controlled" if operation == "buffered-eof" else "prompt-source"
        session = Session(runner, case, workflow, [{"name": "input", "source": "literal", "value": "private fixture content"}])
        if operation == "discard":
            session.send(session.decision("discard"))
            assert session.finish() == []
            assert not (session.root / "runs").exists()
        elif operation == "stale":
            session.send(session.decision("start", approvalId="another-preparation"))
            assert session.finish(3) == []
            assert not (session.root / "runs").exists()
        elif operation == "root-change":
            session.root.rename(case / "original-root")
            session.root.mkdir(mode=0o700)
            session.send(session.decision("start"))
            assert session.finish(3) == []
            assert not (session.root / "runs").exists()
            assert not (case / "original-root/runs").exists()
        else:
            if operation == "buffered-eof":
                session.send(session.decision("start"))
                session.process.stdin.close()
            else:
                session.send(session.decision("start"), {"controlId": "buffered", "expectedOccurrenceId": None,
                             "expectedAttemptId": None, "command": {"type": "cancelRun"}})
            events = session.finish(130)
            if operation == "buffered-cancel":
                assert any(item["event"].get("controlId") == "buffered" and item["event"].get("state") == "accepted" for item in events)
            assert events[-1]["event"]["type"] == "run.cancelled"
            stored = [json.loads(line) for line in (session.run / "runtime/events.ndjson").read_bytes().splitlines()]
            assert stored == events, (stored, events)
            observed = query(runner, case, {"version": 1, "operation": "read-run",
                             "rootIdentity": session.preview["rootIdentity"], "runId": session.preview["runId"]})["run"]
            assert observed["snapshot"]["status"] == "cancelled", observed


def invalid_sources(runner: Path, directory: Path) -> None:
    for kind in ["utf8", "symlink", "fifo", "oversized", "duplicate", "missing", "unknown", "credential", "frame-bound",
                 "transport-type", "transport-fields", "transport-utf8", "transport-surrogate", "transport-frame-bound",
                 "invocation-null", "invocation-type", "invocation-fields", "invocation-missing", "invocation-version",
                 "invocation-alias-space", "invocation-alias-nul", "invocation-alias-bound", "invocation-executable-space",
                 "invocation-executable-nul", "invocation-executable-bound", "invocation-prefix-type", "invocation-prefix-count",
                 "invocation-prefix-bound", "invocation-prefix-nul", "invocation-prefix-credential"]:
        case = directory / ("invalid-" + kind)
        case.mkdir()
        path = case / "source"
        path.write_bytes(b"valid")
        source = {"name": "input", "source": "file", "path": str(path)}
        payload = {"version": 1, "operation": "prepare", "workflow": "prompt-source", "stateDirectory": str(case / "state"),
                   "targetArguments": ["--scripted"], "inputs": [source]}
        if kind == "utf8":
            path.write_bytes(b"\xff")
        elif kind == "symlink":
            path.rename(case / "real-source")
            path.symlink_to(case / "real-source")
        elif kind == "fifo":
            path.unlink()
            os.mkfifo(path)
        elif kind == "oversized":
            with path.open("wb") as stream:
                stream.truncate(64 * 1024 * 1024 + 1)
        elif kind == "duplicate":
            payload["inputs"] = [source, source]
        elif kind == "missing":
            payload["inputs"] = []
        elif kind == "unknown":
            payload["future"] = True
        elif kind == "credential":
            payload["targetArguments"] = ["--engine", "acp", "--adapter", "stub", "--adapter-arg", "--token=native-private-fixture"]
        elif kind.startswith("transport-"):
            source = {"name": "input", "source": "transport", "value": "captured"}
            payload["inputs"] = [source]
            if kind == "transport-type":
                source["value"] = 42
            elif kind == "transport-fields":
                source["path"] = str(path)
            elif kind == "transport-frame-bound":
                source["value"] = "\0" * 350000
        elif kind.startswith("invocation-"):
            invocation = {"version": 1, "runnerAlias": "alias", "executable": "wrapper", "prefixArgs": ["--profile", "work"]}
            payload["invocation"] = invocation
            if kind == "invocation-null":
                payload["invocation"] = None
            elif kind == "invocation-type":
                payload["invocation"] = []
            elif kind == "invocation-fields":
                invocation["future"] = True
            elif kind == "invocation-missing":
                del invocation["prefixArgs"]
            elif kind == "invocation-version":
                invocation["version"] = 2
            elif kind == "invocation-alias-space":
                invocation["runnerAlias"] = " \t"
            elif kind == "invocation-alias-nul":
                invocation["runnerAlias"] = "bad\0alias"
            elif kind == "invocation-alias-bound":
                invocation["runnerAlias"] = "é" * 129
            elif kind == "invocation-executable-space":
                invocation["executable"] = "\n"
            elif kind == "invocation-executable-nul":
                invocation["executable"] = "bad\0executable"
            elif kind == "invocation-executable-bound":
                invocation["executable"] = "é" * 2049
            elif kind == "invocation-prefix-type":
                invocation["prefixArgs"] = "--profile"
            elif kind == "invocation-prefix-count":
                invocation["prefixArgs"] = [""] * 4097
            elif kind == "invocation-prefix-bound":
                invocation["prefixArgs"] = ["é" * 2048] * 17
            elif kind == "invocation-prefix-nul":
                invocation["prefixArgs"] = ["bad\0argument"]
            elif kind == "invocation-prefix-credential":
                invocation["prefixArgs"] = ["--token=native-private-fixture"]
        environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_CAT_")}
        environment["XDG_CONFIG_HOME"] = str(case / "config")
        body = encode(payload) + b"\n" if kind != "frame-bound" else b" " * (2 * 1024 * 1024 + 1)
        if kind == "transport-utf8":
            body = body.replace(b'"captured"', b'"\xff"')
        elif kind == "transport-surrogate":
            body = body.replace(b'"captured"', b'"\\ud800"')
        elif kind == "transport-frame-bound":
            assert len(source["value"].encode("utf-8")) < 2 * 1024 * 1024 < len(body)
        result = subprocess.run([str(runner), "frontend"], input=body, capture_output=True, cwd=case, env=environment, timeout=15)
        assert result.returncode == 3 and not result.stdout, (kind, result.returncode, result.stdout, result.stderr)
        assert b"native-private-fixture" not in result.stderr
        assert not (case / "state/runs").exists()
        if kind.startswith("invocation-"):
            assert not (case / "state").exists(), kind


def targets(runner: Path, directory: Path) -> None:
    for index, arguments in enumerate([
        ["--scripted"],
        ["--engine", "deck", "--session", "uncontacted-deck"],
        ["--engine", "acp", "--adapter", "/uncontacted/node", "--adapter-arg", "/uncontacted/pi-remote-acp.mjs"],
    ]):
        case = directory / f"target-{index}"
        case.mkdir()
        session = Session(runner, case, "target-sensitive", [], arguments)
        frozen_arguments = session.preview["targetArguments"]
        if index == 2:
            assert frozen_arguments == arguments + ["--scratch", session.preview["policy"]["scratch"]]
            assert not Path(session.preview["policy"]["scratch"]).exists()
        else:
            assert frozen_arguments == arguments
        assert session.preview["targetKind"] == ["scripted", "deck", "acp"][index]
        assert session.preview["plan"]["askNodes"] == [2, 1, 2][index], session.preview["plan"]
        session.send(session.decision("discard"))
        assert session.finish() == []
        assert not (session.root / "runs").exists()


def frozen_routing(runner: Path, directory: Path) -> None:
    case = directory / "frozen-routing"
    case.mkdir()
    config = case / "config/agent-cat/routing.yaml"
    config.parent.mkdir(parents=True)
    stub = Path(__file__).resolve().parents[1] / "engine/acp/test/stub_adapter.py"
    adapters = []
    for name in ["approved", "replacement"]:
        adapter = case / name
        marker = case / (name + ".started")
        adapter.write_text(f"#!{sys.executable}\nimport os, pathlib\n"
                           f"pathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\n"
                           f"os.execv({sys.executable!r}, [{sys.executable!r}, {str(stub)!r}])\n")
        adapter.chmod(0o755)
        adapters.append(adapter)
    def configure(adapter: Path) -> None:
        config.write_text("version: 1\nrouters:\n  - name: fixture\n"
                          f"    backend: {json.dumps('acp:' + str(adapter))}\n"
                          "    provider: fixture\nprofiles:\n  - name: deep\n"
                          "    chain:\n      - router: fixture\n        model: stub-default\n"
                          "        thinking: high\n        max-output: 65536\n")
    configure(adapters[0])
    arguments = ["--routing", "--timeout", "10000"]
    session = Session(runner, case, "pinned", [], arguments)
    assert session.preview["targetKind"] == "routing"
    assert session.preview["policy"]["coverage"] == "full" and "default" not in session.preview["policy"]
    assert not (case / "approved.started").exists() and not (case / "replacement.started").exists()
    policy = session.preview["policy"]
    assert str(adapters[0]) in json.dumps(policy), policy
    configure(adapters[1])
    session.send(session.decision("start"))
    events = session.finish()
    assert events[-1]["event"]["type"] == "run.completed", events
    assert (case / "approved.started").exists() and not (case / "replacement.started").exists()
    observed = query(runner, case, {"version": 1, "operation": "read-run",
                     "rootIdentity": session.preview["rootIdentity"], "runId": session.preview["runId"]})["run"]
    assert observed["policy"] == policy, (observed["policy"], policy)
    fresh = Session(runner, case, "pinned", [], arguments)
    assert str(adapters[1]) in json.dumps(fresh.preview["policy"]), fresh.preview["policy"]
    fresh.send(fresh.decision("discard"))
    assert fresh.finish() == [] and not (case / "replacement.started").exists()
    explicit = Session(runner, case, "convergent", [],
                       ["--routing", "--engine", "acp", "--adapter", str(adapters[0]), "--timeout", "10000"])
    assert explicit.preview["targetKind"] == "acp"
    assert explicit.preview["policy"]["default"] == "acp:" + str(adapters[0])
    assert explicit.preview["policy"]["routingSources"] == []
    explicit.send(explicit.decision("discard"))
    assert explicit.finish() == [] and not (case / "replacement.started").exists()


def process_parents() -> dict[int, int]:
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True, timeout=10).splitlines()
    return {int(pid): int(parent) for pid, parent in (row.split() for row in rows)}


def native_cleanup(runner: Path, directory: Path) -> None:
    for operation in ["discard", "cancel", "terminate"]:
        case = directory / ("native-cleanup-" + operation)
        case.mkdir()
        session = Session(runner, case, "person-controlled",
                          [{"name": "input", "source": "literal", "value": "native cleanup fixture"}])
        workers = {pid for pid, parent in process_parents().items() if parent == session.process.pid}
        assert workers, "native supervisor did not expose its live prepared worker"
        if operation == "cancel":
            session.send(session.decision("start"))
            while True:
                frame = session.read()
                assert frame is not None, "human-controlled run exited before cancellation"
                if frame["event"]["type"] == "occurrence.person-answer-pending":
                    break
            session.send({"controlId": "cleanup", "expectedOccurrenceId": None, "expectedAttemptId": None,
                          "command": {"type": "cancelRun"}})
            assert session.finish(130)[-1]["event"]["type"] == "run.cancelled"
        elif operation == "terminate":
            session.process.terminate()
            assert session.finish(-signal.SIGINT) == []
        else:
            session.send(session.decision("discard"))
            assert session.finish() == []
        assert workers.isdisjoint(process_parents()), (operation, workers)


def person(runner: Path, directory: Path) -> None:
    case = directory / "person"
    case.mkdir()
    session = Session(runner, case, "person-controlled", [{"name": "input", "source": "literal", "value": "native human fixture"}])
    session.send(session.decision("start"))
    pending = []
    events = []
    while (envelope := session.read()) is not None:
        event = envelope["event"]
        events.append(event)
        if event["type"] == "occurrence.person-answer-pending":
            pending.append(event["occurrenceId"])
            observed = query(runner, case, {"version": 1, "operation": "read-run", "rootIdentity": session.preview["rootIdentity"],
                                           "runId": session.preview["runId"]})["run"]
            assert observed["ownership"] == "owned-elsewhere"
            assert any(row.get("personPending") for row in observed["snapshot"]["occurrences"])
            request = {"version": 1, "operation": "prepare-lineage", "stateDirectory": str(session.root),
                       "parentRunId": session.preview["runId"], "lineage": "fork"}
            refused = subprocess.run([str(runner), "frontend"], input=encode(request) + b"\n", capture_output=True, cwd=case, env=session.environment, timeout=15)
            assert refused.returncode == 3 and not refused.stdout and b"another live owner" in refused.stderr, refused
            verified = query(runner, case, {"version": 1, "operation": "read-question", "rootIdentity": session.preview["rootIdentity"],
                                             "runId": session.preview["runId"], "occurrenceId": event["occurrenceId"],
                                             "codeName": "flag", "reference": event["question"]})
            assert verified["question"]["prompt"].endswith("native human fixture")
            editor = query(runner, case, {"version": 2, "operation": "read-question-schema",
                                         "rootIdentity": session.preview["rootIdentity"], "runId": session.preview["runId"],
                                         "occurrenceId": event["occurrenceId"], "reference": event["question"]})
            assert editor == {**verified, "version": 2, "operation": "read-question-schema",
                              "codeName": "flag", "answerSchema": {"type": "boolean"}}
            session.send({"controlId": "answer-" + event["occurrenceId"], "expectedOccurrenceId": event["occurrenceId"],
                          "expectedAttemptId": None, "command": {"type": "answerPerson", "answer": True}})
    assert session.finish() == []
    assert pending == ["0", "1"]
    assert events[-1]["type"] == "run.completed"
    assert not any(event["type"].startswith("attempt.") for event in events)


def legacy_lineage(runner: Path, directory: Path) -> None:
    case = directory / "legacy-lineage"
    case.mkdir()
    scratch = case / "scratch-parent"
    scratch.mkdir()
    adapter = Path(__file__).resolve().parents[1] / "engine/acp/test/stub_adapter.py"
    arguments = ["--engine", "acp", "--adapter", sys.executable, "--adapter-arg", str(adapter)]
    session = Session(runner, case, "prompt-source", [{"name": "input", "source": "literal", "value": "lineage fixture"}],
                      arguments, environment={"TMPDIR": str(scratch)})
    session.send(session.decision("start"))
    events = session.finish()
    assert events[-1]["event"]["type"] == "run.completed"
    manifest = json.loads((session.run / "supervisor-manifest.json").read_bytes())
    assert manifest["frontendManifestVersion"] == 2 and "invocation" not in manifest
    assert manifest["targetArgs"] == session.preview["targetArguments"]
    assert manifest["targetArgs"] == arguments + ["--scratch", session.preview["policy"]["scratch"]]
    result = subprocess.run(
        [str(runner), "lineage-check", "restart", str(session.run / "runtime"), "prompt-source",
         *manifest["targetArgs"], "--protocol-version", "2", "--person-answering", "local-control",
         "--input-file", "input=" + str(session.run / "inputs/0.txt")],
        capture_output=True, cwd=case, env=session.environment, timeout=15,
    )
    assert result.returncode == 0, result.stderr


def invocation_lineage_matrix(runner: Path, directory: Path, wrapper: Path, prefix: list[str], v3_parent: Session) -> None:
    case = directory / "invocation-lineage"
    case.mkdir()
    invocation = v3_parent.preview["invocation"]
    base = {
        "version": 1,
        "operation": "prepare-lineage",
        "stateDirectory": str(v3_parent.root),
        "parentRunId": v3_parent.preview["runId"],
        "lineage": "restart",
    }
    before = {path.name for path in (v3_parent.root / "runs").iterdir()}
    invalid = [
        base,
        {**base, "invocation": {**invocation, "runnerAlias": "missing-alias"}},
        {**base, "invocation": {**invocation, "executable": str(wrapper) + "-stale"}},
        {**base, "invocation": {**invocation, "prefixArgs": list(reversed(prefix))}},
    ]
    for request in invalid:
        refused = subprocess.run(
            [str(wrapper), *prefix, "frontend"], input=encode(request) + b"\n", capture_output=True,
            cwd=case, env=v3_parent.environment, timeout=15,
        )
        assert refused.returncode == 3 and not refused.stdout and b"invocation" in refused.stderr, refused
        assert {path.name for path in (v3_parent.root / "runs").iterdir()} == before

    def run_child(parent: Session, label: str, supplied: dict | None, expected_version: int, command_prefix: list[str] | None = None) -> Session:
        request = {
            "version": 1,
            "operation": "prepare-lineage",
            "stateDirectory": str(parent.root),
            "parentRunId": parent.preview["runId"],
            "lineage": "restart",
        }
        if supplied is not None:
            request["invocation"] = supplied
        child = Session(runner, case, "", [], request=request, command_prefix=command_prefix)
        assert child.preview["invocation"] == supplied
        child.send(child.decision("start"))
        events = child.finish()
        assert events[-1]["event"]["type"] == "run.completed", (label, events[-1])
        manifest = json.loads((child.run / "supervisor-manifest.json").read_bytes())
        assert manifest["frontendManifestVersion"] == expected_version, (label, manifest)
        if expected_version == 3:
            assert manifest["invocation"] == supplied
        else:
            assert "invocation" not in manifest
        return child

    run_child(v3_parent, "v3 exact", invocation, 3, [str(wrapper), *prefix])

    v2_case = case / "v2-parent"
    v2_case.mkdir()
    v2_parent = Session(runner, v2_case, "prompt-source", [{"name": "input", "source": "literal", "value": "v2 lineage"}])
    v2_parent.send(v2_parent.decision("start"))
    v2_parent.finish()
    v2_manifest = json.loads((v2_parent.run / "supervisor-manifest.json").read_bytes())
    assert v2_manifest["frontendManifestVersion"] == 2 and "invocation" not in v2_manifest
    run_child(v2_parent, "v2 omitted", None, 2)
    run_child(v2_parent, "v2 supplied", invocation, 3, [str(wrapper), *prefix])

    legacy_case = case / "legacy-parent"
    legacy_case.mkdir()
    legacy_parent = Session(runner, legacy_case, "prompt-source", [{"name": "input", "source": "literal", "value": "legacy lineage"}])
    legacy_parent.send(legacy_parent.decision("start"))
    legacy_parent.finish()
    manifest_path = legacy_parent.run / "supervisor-manifest.json"
    versioned = json.loads(manifest_path.read_bytes())
    legacy_keys = ["runId", "runnerId", "workflow", "cwd", "targetKind", "targetArgs", "inputHashes", "programHash", "createdAt"]
    manifest_path.write_bytes(encode({key: versioned[key] for key in legacy_keys}) + b"\n")
    run_child(legacy_parent, "legacy omitted", None, 2)
    run_child(legacy_parent, "legacy supplied", invocation, 3, [str(wrapper), *prefix])


def native_lineage(runner: Path, directory: Path) -> None:
    case = directory / "native-lineage"
    case.mkdir()
    parent = Session(runner, case, "prompt-source", [{"name": "input", "source": "literal", "value": "lineage\n"}])
    parent.send(parent.decision("start"))
    parent.finish()
    original = {str(path.relative_to(parent.run)): path.read_bytes() for path in parent.run.rglob("*") if path.is_file()}
    request = {"version": 1, "operation": "prepare-lineage", "stateDirectory": str(parent.root),
               "parentRunId": parent.preview["runId"]}
    for operation, edits, attempts in [
        ("restart", [], 1), ("resume", [], 0), ("fork", [], 0),
        ("fork", [{"operation": "drop", "occurrenceId": "0"}], 1),
        ("fork", [{"operation": "replace", "occurrenceId": "0", "answer": "replacement"}], 0),
    ]:
        child = Session(runner, case, "", [], request={**request, "lineage": operation, "edits": edits})
        assert child.preview["parentRunId"] == parent.preview["runId"] and child.preview["lineage"] == operation
        child.send(child.decision("start"))
        events = child.finish()
        assert events[-1]["event"]["type"] == "run.completed"
        assert sum(row["event"]["type"] == "attempt.started" for row in events) == attempts
        assert (child.run / "inputs/0.txt").read_bytes() == original["inputs/0.txt"]
        manifest = json.loads((child.run / "supervisor-manifest.json").read_bytes())
        assert manifest["frontendManifestVersion"] == 2 and "invocation" not in manifest
        assert manifest["parentRunId"] == parent.preview["runId"] and manifest["lineage"] == operation
        assert "answer" not in json.dumps(manifest["lineageEdits"]), manifest["lineageEdits"]
        assert all((parent.run / name).read_bytes() == value for name, value in original.items())
    for bad in [
        {**request, "lineage": "resume", "edits": [{"operation": "drop", "occurrenceId": "0"}]},
        {**request, "lineage": "fork", "edits": [{"operation": "replace", "occurrenceId": "0", "answer": False}]},
        {**request, "lineage": "fork", "edits": [{"operation": "drop", "occurrenceId": "9"}]},
    ]:
        refused = subprocess.run([str(runner), "frontend"], input=encode(bad) + b"\n", capture_output=True, cwd=case, env=parent.environment, timeout=15)
        assert refused.returncode == 3 and not refused.stdout, refused
    child = Session(runner, case, "", [], request={**request, "lineage": "fork"})
    answers_path = parent.run / "runtime/answers.json"
    saved = answers_path.read_bytes()
    answers = json.loads(saved)
    answers["answers"][0]["answer"] = "changed after approval"
    answers_path.write_bytes(encode(answers) + b"\n")
    child.send(child.decision("start"))
    assert child.finish(3) == []
    answers_path.write_bytes(saved)
    (parent.run / "inputs/0.txt").write_bytes(b"tampered")
    refused = subprocess.run([str(runner), "frontend"], input=encode({**request, "lineage": "restart"}) + b"\n",
                             capture_output=True, cwd=case, env=parent.environment, timeout=15)
    assert refused.returncode == 3 and not refused.stdout, refused
    (parent.run / "inputs/0.txt").write_bytes(original["inputs/0.txt"])
    human_case = directory / "native-person-lineage"
    human_case.mkdir()
    legacy = Session(runner, human_case, "", [], request={
        "version": 1, "operation": "prepare", "stateDirectory": str(human_case / "state"),
        "workflow": "person-controlled", "targetArguments": ["--scripted"], "personAnswering": "engine",
        "inputs": [{"name": "input", "source": "literal", "value": "legacy person"}],
    })
    legacy.send(legacy.decision("start"))
    legacy.finish()
    derived = {"version": 1, "operation": "prepare-lineage", "stateDirectory": str(legacy.root),
               "parentRunId": legacy.preview["runId"], "lineage": "fork",
               "edits": [{"operation": "replace", "occurrenceId": "0", "answer": False}]}
    child = Session(runner, human_case, "", [], request=derived)
    child.send(child.decision("start"))
    pending = []
    events = []
    while (frame := child.read()) is not None:
        event = frame["event"]
        events.append(event)
        if event["type"] == "occurrence.person-answer-pending":
            pending.append(event["occurrenceId"])
            child.send({"controlId": "human-fork", "expectedOccurrenceId": event["occurrenceId"], "expectedAttemptId": None,
                        "command": {"type": "answerPerson", "answer": True}})
    child.finish()
    assert pending == ["1"]
    assert any(event["type"] == "occurrence.reused" and event["occurrenceId"] == "0" for event in events)
    answers = json.loads((child.run / "runtime/answers.json").read_bytes())["answers"]
    assert any(answer["occurrenceId"] == "0" and answer["answer"] is False and answer["replaced"] for answer in answers)


def corrupt_history(runner: Path, directory: Path) -> None:
    case = directory / "history"
    case.mkdir()
    session = Session(runner, case, "prompt-source", [{"name": "input", "source": "literal", "value": "history fixture"}])
    session.send(session.decision("start"))
    events = session.finish()
    reference = events[-1]["event"]["result"]
    damaged = session.root / "runs/damaged"
    damaged.mkdir(mode=0o700)
    base = {"version": 1, "rootIdentity": session.preview["rootIdentity"]}
    history = query(runner, case, {**base, "operation": "list-runs"})["runs"]
    assert {row["kind"] for row in history} == {"run", "corrupt"}
    assert any(row.get("directory") == str(damaged) and row["kind"] == "corrupt" for row in history)
    manifest_path = session.run / "supervisor-manifest.json"
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    manifest["workflow"] = "different-workflow"
    manifest_path.write_bytes(encode(manifest) + b"\n")
    mismatched = query(runner, case, {**base, "operation": "list-runs"})["runs"]
    assert all(row["kind"] == "corrupt" for row in mismatched), mismatched
    manifest_path.write_bytes(manifest_bytes)
    journal = session.run / "runtime/events.ndjson"
    journal_bytes = journal.read_bytes()
    changed = [json.loads(line) for line in journal_bytes.splitlines()]
    changed[0]["event"]["workflow"] = "different-workflow"
    journal.write_bytes(b"".join(encode(frame) + b"\n" for frame in changed))
    mismatched = query(runner, case, {**base, "operation": "list-runs"})["runs"]
    assert all(row["kind"] == "corrupt" for row in mismatched), mismatched
    journal.write_bytes(journal_bytes)
    with journal.open("ab") as stream:
        stream.write(b"{torn")
    history = query(runner, case, {**base, "operation": "list-runs"})["runs"]
    assert all(row["kind"] == "corrupt" for row in history)
    result = query(runner, case, {**base, "operation": "read-result", "runId": session.preview["runId"], "reference": reference})
    assert result["code"] == reference["code"]
    for request in [
        {**base, "operation": "read-run", "runId": session.preview["runId"]},
        {**base, "operation": "list-runs", "ownerId": "forged-owner"},
        {**base, "operation": "read-run", "runId": "../outside"},
    ]:
        refused = subprocess.run([str(runner), "frontend-io"], input=encode(request), capture_output=True, cwd=case, timeout=10)
        assert refused.returncode == 3 and not refused.stdout, refused


def native_controls(runner: Path, directory: Path) -> None:
    adapters = Path(__file__).resolve().parents[1] / "engine/acp/test"
    for choice in ["retry", "abandon", "redirect", "failover", "steer"]:
        case = directory / ("native-control-" + choice)
        case.mkdir()
        adapter = adapters / ("steer_adapter.py" if choice == "steer" else "retry_adapter.py")
        arguments = ["--engine", "acp", "--adapter", sys.executable, "--adapter-arg", str(adapter), "--timeout", "10000"]
        routed = choice in ["redirect", "failover"]
        if routed:
            spare = case / "spare-adapter"
            stub = adapters / "stub_adapter.py"
            spare.write_text(f"#!{sys.executable}\nimport os\n"
                             f"os.execv({sys.executable!r}, [{sys.executable!r}, {str(stub)!r}])\n")
            spare.chmod(0o700)
            arguments.extend(["--route", "spare=acp:" + str(spare)])
        session = Session(runner, case, "controlled" if routed else "controlled-single",
                          [{"name": "input", "source": "literal", "value": "native controls fixture"}],
                          arguments, environment={"TMPDIR": str(case)})
        session.send(session.decision("start"))
        events = []
        sent = False
        while True:
            try:
                frame = session.read()
            except AssertionError as failure:
                raise AssertionError((choice, events)) from failure
            if frame is None:
                break
            event = frame["event"]
            events.append(event)
            if sent:
                continue
            if choice == "failover" and event["type"] == "occurrence.dispatch-pending":
                session.send({"controlId": "dispatch-primary", "expectedOccurrenceId": event["occurrenceId"],
                              "expectedAttemptId": None, "command": {"type": "redirectOccurrence", "target": event["targets"][0]}})
                continue
            command = None
            attempt = None
            if choice == "redirect" and event["type"] == "occurrence.dispatch-pending":
                command = {"type": "redirectOccurrence", "target": event["targets"][-1]}
            elif choice in ["retry", "abandon", "failover"] and event["type"] == "occurrence.recovery-pending":
                command = {"type": {"retry": "retryOccurrence", "abandon": "abandonOccurrence", "failover": "failoverOccurrence"}[choice]}
            elif choice == "steer" and event["type"] == "attempt.started":
                time.sleep(0.1)
                command = {"type": "steerOccurrence", "timing": "interrupt-now", "text": "focus"}
                attempt = {"occurrenceId": event["occurrenceId"], "attemptNumber": event["attempt"]}
            if command:
                session.send({"controlId": choice, "expectedOccurrenceId": event["occurrenceId"],
                              "expectedAttemptId": attempt, "command": command})
                sent = True
        session.finish(3 if choice == "abandon" else 0)
        assert sent and any(event["type"] == "control.ack" and event["controlId"] == choice and event["state"] == "delivered" for event in events), events
        assert events[-1]["type"] == ("run.failed" if choice == "abandon" else "run.completed"), events
        effect = {"retry": "occurrence.retried", "abandon": "occurrence.recovery-chosen", "failover": "occurrence.retried",
                  "redirect": "occurrence.redirected", "steer": "attempt.steered"}[choice]
        assert any(event["type"] == effect for event in events), events


def main() -> None:
    runner = Path(sys.argv[1]).resolve()
    try:
        with tempfile.TemporaryDirectory(prefix="agent-cat-native-probe-") as temporary:
            root = Path(temporary).resolve()
            wrapper, prefix, capabilities = capability_discovery(runner, root)
            v3_parent = invocation_contract(runner, root, wrapper, prefix, capabilities)
            source_vectors(runner, root)
            decisions(runner, root)
            targets(runner, root)
            frozen_routing(runner, root)
            native_cleanup(runner, root)
            person(runner, root)
            native_controls(runner, root)
            invalid_sources(runner, root)
            invocation_lineage_matrix(runner, root, wrapper, prefix, v3_parent)
            native_lineage(runner, root)
            legacy_lineage(runner, root)
            corrupt_history(runner, root)
            bootstrap = root / "inherited-bootstrap"
            bootstrap.mkdir()
            session = Session(runner, bootstrap, "prompt-source", [{"name": "input", "source": "literal", "value": "@literal"}],
                              environment={"AGENT_CAT_TUI_BOOTSTRAP_FD3": "1", "AGENT_CAT_CONTROL_FD": "3"})
            session.send(session.decision("discard"))
            assert session.finish() == []
    finally:
        for session in Session.active:
            if session.process.poll() is None:
                session.process.terminate()
                session.process.wait(timeout=10)
            for pipe in [session.process.stdin, session.process.stdout, session.process.stderr]:
                if not pipe.closed:
                    pipe.close()
    print("native session: capability discovery, exact invocation retention, v2/v3 lineage, transport capture, approval, controls, and local human answers passed")


if __name__ == "__main__":
    main()
