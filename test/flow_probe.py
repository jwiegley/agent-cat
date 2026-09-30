#!/usr/bin/env python3
"""Check the senders, retry forms and carriage of machine run logs.

Every run below is store-backed and reads flow.ndjson as JSON lines, joined to
events.ndjson by the sequence number that each event record names.

Attribution. A registry tool, a program command, a fixture, a model and a local
person answer each name the sender that the runtime resolved. An engine answer
that names another target does not change the sender. A person question in
engine mode goes to the model. A model answer that holds approval phrases and
control frames adds no start and no control record. The start record names the
owner that AGENT_CAT_RUN_OWNER declares.

Retry forms. A transport-gap retry shows two engine-start records under one
question. A decoding re-ask shows two turn records under one question. A
fail-over shows two question records for one occurrence.

Carriage. Every attempt.started event lies inside an open question of its
occurrence, and inside an open turn when that question goes to a model. Every
acknowledgement of a control that the runtime received after activation
follows a control record with its identifier. A control delivered before
activation has only its acknowledgement. In a broker-test run, the counts of
the inner broker equal the records of the run log. The checker fails on a copy
of a log without one turn record. The static check lists every source line
that names inProcessBroker under runtime/src and cli/src and fails on a line
outside the allowlist, and it fails when a synthetic extra line is added.

With --journey FIXTURE, the probe instead checks every run log under the
fixture directory of a tui-journey: each control record and each answer that a
control supplied comes from the manager and names a command identifier.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADAPTERS = ROOT / "engine" / "acp" / "test"
STUB = ["--engine", "acp", "--adapter", "stub", "--timeout", "60000"]

# Each source line that may name inProcessBroker: the definition and its
# exports and imports, the command-line default, and the wrappers that take no
# run store.
ALLOWLIST = {
    ("runtime/src/Agentic/Runtime.hs", "inProcessBroker,"),
    ("runtime/src/Agentic/Runtime.hs", "import Agentic.Runtime.Broker (DataBroker (..), inProcessBroker)"),
    ("runtime/src/Agentic/Runtime/Broker.hs", "inProcessBroker,"),
    ("runtime/src/Agentic/Runtime/Broker.hs", "inProcessBroker :: DataBroker"),
    ("runtime/src/Agentic/Runtime/Broker.hs", "inProcessBroker ="),
    ("runtime/src/Agentic/Runtime/Machine.hs", "import Agentic.Runtime.Broker (DataBroker (..), inProcessBroker)"),
    ("runtime/src/Agentic/Runtime/Machine.hs", "activateEventSink = activateEventSinkBrokered inProcessBroker"),
    ("runtime/src/Agentic/Runtime/Machine.hs", "withBufferedControlInputFor = withBufferedControlInputBrokered inProcessBroker"),
    ("runtime/src/Agentic/Exec.hs", "import Agentic.Runtime.Broker (DataBroker (..), inProcessBroker, PersistenceHooks (..), nullPersistenceHooks)"),
    ("runtime/src/Agentic/Exec.hs", "{ worldAskIO = \\c q -> announce (brokerLog inProcessBroker out) c q (worldAskIO inner c q),"),
    ("runtime/src/Agentic/Exec.hs", "worldOfEngineWith = worldOfEngineBrokered inProcessBroker"),
    ("runtime/src/Agentic/Exec.hs", "runPlanObservedWith controls = runPlanBrokered inProcessBroker controls nullPersistenceHooks"),
    ("cli/src/Agentic/Cli.hs", "import Agentic.Runtime (DataBroker (..), inProcessBroker, ControlRuntime, newControlRuntimeFor)"),
    ("cli/src/Agentic/Cli.hs", "cliMain = cliMainWithBroker inProcessBroker"),
}


def broker_lines(extra: list[tuple[str, str]] = ()) -> list[tuple[str, str]]:
    """Every non-comment source line under runtime/src and cli/src that names
    inProcessBroker, as (path, stripped line), followed by the extra lines."""
    found = []
    for top in ("runtime/src", "cli/src"):
        for path in sorted((ROOT / top).rglob("*.hs")):
            for line in path.read_text(encoding="utf-8").splitlines():
                text = line.strip()
                if "inProcessBroker" in text and not text.startswith("--"):
                    found.append((str(path.relative_to(ROOT)), text))
    return found + list(extra)


def allowlist_violations(lines: list[tuple[str, str]]) -> list[tuple[str, str]]:
    return [line for line in lines if line not in ALLOWLIST]


def check_allowlist() -> None:
    lines = broker_lines()
    assert not allowlist_violations(lines), f"inProcessBroker outside the allowlist: {allowlist_violations(lines)}"
    missing = ALLOWLIST - set(lines)
    assert not missing, f"allowlist entries without a source line: {sorted(missing)}"
    synthetic = ("cli/src/Agentic/Cli.hs", "runMachineWith inProcessBroker options control lineage parent inherited reg")
    assert allowlist_violations(broker_lines([synthetic])) == [synthetic]
    print(f"allowlist: {len(lines)} lines name inProcessBroker, all allowed; a synthetic extra line fails")


# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------


class Run:
    def __init__(self, store: Path, run_id: str, events: list[dict], stderr: str):
        self.store = store
        self.run_id = run_id
        self.events = events
        self.stderr = stderr
        self.records = read_records(store / "flow.ndjson")
        self.journal = [json.loads(line) for line in (store / "events.ndjson").read_bytes().splitlines()]

    def carried(self, schema: str) -> list[dict]:
        return [record for record in self.records if record["schema"] == schema]

    def reply_to(self, position: int) -> dict | None:
        return next((record for record in self.records if record.get("replyTo") == position), None)

    def counts(self) -> dict[str, int]:
        line = next(line for line in self.stderr.splitlines() if line.startswith("broker-test counts: "))
        return {key: int(value) for key, value in (item.split("=") for item in line.split(": ", 1)[1].split())}


def read_records(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_bytes().splitlines()]


def owner_for(run_id: str) -> str:
    return f"local:flow-probe:{run_id}"


def local(run_id: str) -> dict:
    return {"principal": "local", "uid": os.getuid(), "owner": owner_for(run_id)}


def environment_for(store: Path, run_id: str, control: int | None = None) -> dict:
    environment = {key: value for key, value in os.environ.items() if key not in ("AGENT_CAT_CONTROL_FD", "AGENT_CAT_CONTROL_STDIN")}
    environment["AGENT_CAT_RUN_STORE"] = str(store)
    environment["AGENT_CAT_RUN_OWNER"] = owner_for(run_id)
    if control is not None:
        environment["AGENT_CAT_CONTROL_FD"] = str(control)
    return environment


def machine(root: Path, binary: Path, run_id: str, workflow: str, target: list[str], *,
            prefix: tuple[str, ...] = (), stdin: str | None = None, expected: int = 0) -> Run:
    store = root / run_id / "runtime"
    scratch = root / run_id / "scratch"
    scratch.mkdir(parents=True)
    command = [str(binary), *prefix, "machine", run_id, workflow, *target]
    if "--engine" in target:
        command.extend(["--scratch", str(scratch)])
    command.extend(["--protocol-version", "2"])
    result = subprocess.run(
        command, input=(stdin or "").encode(), capture_output=True,
        env=environment_for(store, run_id), check=False, timeout=180,
    )
    stderr = result.stderr.decode("utf8", "replace")
    assert result.returncode == expected, f"{run_id} exited {result.returncode}: {stderr}"
    events = [json.loads(line)["event"] for line in result.stdout.splitlines()]
    run = Run(store, run_id, events, stderr)
    check_start(run)
    return run


def controlled_machine(root: Path, binary: Path, run_id: str, workflow: str, target: list[str], stdin: str,
                       respond, *, prefix: tuple[str, ...] = (), early: list[dict] = ()) -> Run:
    """Run a machine with a control channel. The early controls go out before
    stdin closes, so the runtime receives them before activation. Then
    respond(event) returns the controls to send for each event."""
    store = root / run_id / "runtime"
    scratch = root / run_id / "scratch"
    scratch.mkdir(parents=True)
    command = [str(binary), *prefix, "machine", run_id, workflow, *target]
    if "--engine" in target:
        command.extend(["--scratch", str(scratch)])
    command.extend(["--protocol-version", "2"])
    control_read, control_write = os.pipe()
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, pass_fds=(control_read,), env=environment_for(store, run_id, control_read),
    )
    os.close(control_read)
    controls = os.fdopen(control_write, "w", encoding="utf-8")

    def send(control: dict) -> None:
        controls.write(json.dumps(control, separators=(",", ":")) + "\n")
        controls.flush()

    try:
        for control in early:
            send(control)
        # The reader acknowledges the early controls into the deferred sink
        # while the run still waits for its standard input.
        time.sleep(0.5)
        assert process.stdin is not None and process.stdout is not None and process.stderr is not None
        process.stdin.write(stdin)
        process.stdin.close()
        lines: queue.Queue = queue.Queue()
        threading.Thread(target=lambda: [lines.put(line) for line in process.stdout] + [lines.put(None)], daemon=True).start()
        events = []
        deadline = time.monotonic() + 120
        while True:
            try:
                line = lines.get(timeout=1)
            except queue.Empty:
                assert time.monotonic() < deadline, f"{run_id} timed out after {events[-5:]}"
                continue
            if line is None:
                break
            event = json.loads(line)["event"]
            events.append(event)
            for control in respond(event):
                send(control)
        code = process.wait(timeout=30)
        stderr = process.stderr.read()
        assert code == 0, f"{run_id} exited {code}: {stderr} {events[-5:]}"
    finally:
        controls.close()
        if process.poll() is None:
            process.kill()
            process.wait()
    run = Run(store, run_id, events, stderr)
    check_start(run)
    return run


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def check_start(run: Run) -> None:
    start = run.records[0]
    assert start["schema"] == "start" and start["from"] == local(run.run_id), f"{run.run_id}: {start}"
    assert [record["schema"] for record in run.records].count("start") == 1


def event_of(run: Run, record: dict) -> dict:
    return run.journal[record["body"]["event"]]["event"]


def carriage_problems(records: list[dict], journal: list[dict], early: set[str] = frozenset()) -> list[str]:
    """The structural bypass check. It returns every attempt.started event that
    no open ask of its occurrence encloses, and every acknowledgement of a
    control received after activation that no earlier control record names."""
    problems = []
    open_asks: dict[int, dict] = {}
    controls: set[str] = set()
    for position, record in enumerate(records):
        schema = record["schema"]
        if record.get("replyTo") is not None:
            open_asks.pop(record["replyTo"], None)
        if schema in ("question", "engine-start", "turn", "steer"):
            open_asks[position] = record
        if schema == "control":
            controls.add(record["about"]["command"])
        if schema != "event":
            continue
        event = journal[record["body"]["event"]]["event"]
        if event["type"] == "attempt.started":
            occurrence = int(event["occurrenceId"])
            mine = [ask for ask in open_asks.values() if ask["about"].get("occurrence") == occurrence]
            questions = [ask for ask in mine if ask["schema"] == "question"]
            if not questions:
                problems.append(f"event {position}: attempt.started of occurrence {occurrence} has no enclosing question")
            elif "model" in questions[-1]["to"]["to"] and not any(ask["schema"] == "turn" for ask in mine):
                problems.append(f"event {position}: attempt.started of occurrence {occurrence} has no enclosing turn")
        elif event["type"] == "control.ack" and event["controlId"] != "invalid":
            if event["controlId"] in early:
                if event["controlId"] in controls:
                    problems.append(f"event {position}: control {event['controlId']} delivered before activation has a control record")
            elif event["controlId"] not in controls:
                problems.append(f"event {position}: acknowledgement of {event['controlId']} has no control record")
    return problems


def check_carriage(run: Run, early: set[str] = frozenset()) -> None:
    problems = carriage_problems(run.records, run.journal, early)
    assert not problems, f"{run.run_id}: {problems}"
    numbered = [record["body"]["event"] for record in run.carried("event")]
    assert numbered == list(range(len(run.journal))), f"{run.run_id}: event records {numbered}"
    for index, record in enumerate(run.records):
        if record.get("replyTo") is not None:
            ask = run.records[record["replyTo"]]
            assert record["replyTo"] < index and ask["schema"] != "event", f"{run.run_id}: reply {index}"
            identifiers = {key: value for key, value in record["about"].items() if key != "command"}
            assert identifiers == ask["about"], f"{run.run_id}: reply {index} about {record['about']}, ask {ask['about']}"


def check_counts(run: Run, early: int = 0) -> None:
    counts = run.counts()
    carried = {
        "control": len(run.carried("control")) + early,
        "request": len(run.carried("question")),
        "start": len(run.carried("engine-start")),
        "steer": len(run.carried("steer")),
        "turn": len(run.carried("turn")),
    }
    assert counts == carried, f"{run.run_id}: inner broker counts {counts}, run log {carried}"


def answers(run: Run) -> list[tuple[dict, dict]]:
    """Each question with its reply."""
    return [(question, run.reply_to(run.records.index(question))) for question in run.carried("question")]


def check_sender(run: Run, question: dict, reply: dict, sender: dict) -> None:
    assert question["to"] == {"to": sender}, f"{run.run_id}: question to {question['to']}, expected {sender}"
    assert reply is not None and reply["schema"] == "answer" and reply["from"] == sender, f"{run.run_id}: reply {reply}"


def negative_control(run: Run) -> None:
    """A copy of a log without one turn record fails the carriage check."""
    turns = [index for index, record in enumerate(run.records) if record["schema"] == "turn"]
    assert turns, f"{run.run_id}: no turn record to remove"
    copy = run.store.parent / "flow-without-turn.ndjson"
    lines = (run.store / "flow.ndjson").read_bytes().splitlines(keepends=True)
    copy.write_bytes(b"".join(line for index, line in enumerate(lines) if index != turns[0]))
    problems = carriage_problems(read_records(copy), run.journal)
    assert any("no enclosing turn" in problem for problem in problems), problems
    print(f"negative control: the log of {run.run_id} without turn record {turns[0]} fails: {problems[0]}")


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------


def attribution(root: Path, frontend: Path, fixed: Path) -> None:
    capital = machine(root, frontend, "flow-capital", "capital", STUB)
    check_carriage(capital)
    pairs = answers(capital)
    models = [(q, r) for q, r in pairs if "model" in q["to"]["to"]]
    tools = [(q, r) for q, r in pairs if "tool" in q["to"]["to"]]
    assert len(models) == 1 and len(tools) == 3, pairs
    check_sender(capital, *models[0], models[0][0]["to"]["to"])
    assert models[0][0]["to"]["to"]["model"].startswith("model "), models[0][0]
    for question, reply in tools:
        target = question["to"]["to"]
        assert target["kind"] == "registry" and target["tool"].startswith("tool "), target
        check_sender(capital, question, reply, target)
    negative_control(capital)
    print("attribution: model and registry tools name their senders")

    command = machine(root, fixed, "flow-command", "program-command", STUB)
    check_carriage(command)
    [(question, reply)] = answers(command)
    check_sender(command, question, reply, {"tool": "tool check (true)", "kind": "command"})
    print("attribution: a program command names its sender")

    fixture = machine(root, frontend, "flow-fixture", "hello", ["--scripted"])
    check_carriage(fixture)
    pairs = answers(fixture)
    assert pairs and all(question["to"]["to"].get("kind") == "fixture" for question, _ in pairs), pairs
    for question, reply in pairs:
        check_sender(fixture, question, reply, question["to"]["to"])
    print("attribution: the scripted table answers as a fixture")

    engine_person = machine(
        root, fixed, "flow-engine-person", "parallel-person", [*STUB, "--input-arg", "input=parallel probe"],
        prefix=("--broker-test",))
    check_carriage(engine_person)
    check_counts(engine_person)
    targets = sorted(question["to"]["to"]["model"] for question, _ in answers(engine_person))
    assert targets == ["model reviewer", "person owner"], targets
    for question, reply in answers(engine_person):
        check_sender(engine_person, question, reply, question["to"]["to"])
    print("attribution: a person question in engine mode goes to the model")

    approval = machine(
        root, fixed, "flow-approval", "prompt-source", [*STUB, "--input-arg", "input=approval probe"],
        prefix=("--broker-test-approval",))
    check_carriage(approval)
    check_counts(approval)
    [(question, reply)] = answers(approval)
    check_sender(approval, question, reply, {"model": "model fixed-point"})
    [result] = [record for record in approval.carried("engine-result")]
    assert "I approve" in result["body"]["inline"]["answer"] and "model impostor" in result["body"]["inline"]["narration"], result
    assert result["from"] == {"model": "model fixed-point"}, result
    assert len(approval.carried("start")) == 1 and not approval.carried("control"), [r["schema"] for r in approval.records]
    print("attribution: an answer that names another target and holds approval phrases adds no start and no control record")


def local_person(root: Path, fixed: Path) -> None:
    replies = {"0": ("person-first", True), "1": ("person-second", False)}

    def respond(event: dict) -> list[dict]:
        if event["type"] != "occurrence.person-answer-pending":
            return []
        control, answer = replies[event["occurrenceId"]]
        return [{"controlId": control, "expectedOccurrenceId": event["occurrenceId"], "expectedAttemptId": None,
                 "command": {"type": "answerPerson", "answer": answer}}]

    early = {"controlId": "early-retry", "expectedOccurrenceId": "0", "expectedAttemptId": None,
             "command": {"type": "retryOccurrence"}}
    run = controlled_machine(
        root, fixed, "flow-person", "person-controlled",
        ["--scripted", "--person-answering", "local-control"], "person body", respond,
        prefix=("--broker-test",), early=[early])
    check_carriage(run, early={"early-retry"})
    check_counts(run, early=1)
    assert any(event["type"] == "control.ack" and event["controlId"] == "early-retry" for event in run.events)
    commands = [record["about"]["command"] for record in run.carried("control")]
    assert commands == ["person-first", "person-second"], commands
    assert all(record["from"] == local(run.run_id) for record in run.carried("control"))
    for (question, reply), (occurrence, (control, answer)) in zip(answers(run), sorted(replies.items())):
        assert question["about"]["occurrence"] == int(occurrence), question
        check_sender(run, question, reply, local(run.run_id))
        assert reply["about"]["command"] == control and reply["body"]["inline"] is answer, reply
    print("attribution: local person answers come from the intake and name their controls; an early control has only its acknowledgement")


def retry_forms(root: Path, fixed: Path) -> None:
    def retry(event: dict) -> list[dict]:
        if event["type"] != "occurrence.recovery-pending":
            return []
        return [{"controlId": "transport-retry", "expectedOccurrenceId": event["occurrenceId"],
                 "expectedAttemptId": None, "command": {"type": "retryOccurrence"}}]

    gap = controlled_machine(
        root, fixed, "flow-transport-gap", "prompt-source", [*STUB, "--input-arg", "input=transport probe"], "",
        retry, prefix=("--broker-test-transport-gap",))
    check_carriage(gap)
    check_counts(gap)
    [(question, reply)] = answers(gap)
    starts = [record for record in gap.carried("engine-start") if record["about"] == question["about"]]
    assert len(starts) == 2, starts
    first = gap.reply_to(gap.records.index(starts[0]))
    assert first["schema"] == "failure" and reply["schema"] == "answer", (first, reply)
    assert [record["about"]["command"] for record in gap.carried("control")] == ["transport-retry"]
    print("retry forms: a transport-gap retry shows two engine-start records under one question")

    spare = root / "spare-adapter"
    spare.write_text(f"#!{sys.executable}\nimport os\n"
                     f"os.execv({sys.executable!r}, [{sys.executable!r}, {str(ADAPTERS / 'stub_adapter.py')!r}])\n")
    spare.chmod(0o700)
    failover = machine(
        root, fixed, "flow-failover", "controlled",
        ["--engine", "acp", "--adapter", sys.executable, "--adapter-arg", str(ADAPTERS / "retry_adapter.py"),
         "--route", f"spare=acp:{spare}", "--timeout", "10000"],
        stdin="FLOW-STDIN\n")
    check_carriage(failover)
    pairs = answers(failover)
    assert [question["to"]["to"]["model"] for question, _ in pairs] == ["model controlled@primary", "model controlled@spare"], pairs
    assert pairs[0][0]["about"]["occurrence"] == pairs[1][0]["about"]["occurrence"]
    (primary, failed), (_, answered) = pairs
    assert failed["schema"] == "failure" and answered["schema"] == "answer", pairs
    start, end = failover.records.index(primary), failover.records.index(failed)
    turns = [record for record in failover.records[start:end] if record["schema"] == "turn"]
    assert len(turns) == 2, turns
    print("retry forms: a decoding re-ask shows two turn records, and a fail-over shows two question records")


def journey(fixture: Path) -> None:
    logs = sorted(fixture.rglob("flow.ndjson"))
    assert logs, f"no run log under {fixture}"
    controls = answered = 0
    for path in logs:
        records = read_records(path)
        assert records[0]["schema"] == "start" and records[0]["from"] == "manager", (path, records[0])
        for record in records:
            if record["schema"] == "control":
                assert record["from"] == "manager" and record["about"]["command"].startswith("command_"), record
                controls += 1
            if record["schema"] == "answer" and "command" in record["about"]:
                assert record["from"] == "manager" and record["about"]["command"].startswith("command_"), record
                answered += 1
        journal = [json.loads(line) for line in (path.parent / "events.ndjson").read_bytes().splitlines()]
        problems = carriage_problems(records, journal)
        assert not problems, (path, problems)
        for record in records:
            if record["schema"] in ("control", "answer") and record["from"] == "manager":
                print(f"{path.parent.name}: {record['schema']} from manager, command {record['about'].get('command')}")
    assert controls and answered, (controls, answered)
    print(f"journey: {len(logs)} run logs, {controls} control records and {answered} answers name the manager and a command")


def main() -> None:
    arguments = sys.argv[1:]
    if arguments[:1] == ["--journey"] and len(arguments) == 2:
        journey(Path(arguments[1]))
        return
    if len(arguments) != 2:
        raise SystemExit("usage: flow_probe.py AGENTIC_RUN ROUTING_FIXED_POINT_PROBE | flow_probe.py --journey FIXTURE")
    frontend, fixed = (Path(argument).resolve() for argument in arguments)
    check_allowlist()
    root = Path(tempfile.mkdtemp(prefix="agent-cat-flow-"))
    print(f"fixture root {root} (removed only after every check passes)")
    attribution(root, frontend, fixed)
    local_person(root, fixed)
    retry_forms(root, fixed)
    shutil.rmtree(root)
    print("flow probe: attribution, retry forms and carriage passed")


if __name__ == "__main__":
    main()
