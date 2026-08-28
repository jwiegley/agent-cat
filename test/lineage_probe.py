#!/usr/bin/env python3
"""End-to-end restart/resume/fork fixture; takes the agentic-run binary path."""

import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile

BINARY = os.path.abspath(sys.argv[1])
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(args, store, timeout=20):
    return subprocess.run(
        [BINARY, *args], capture_output=True, text=True, timeout=timeout,
        env={**os.environ, "AGENT_CAT_RUN_STORE": store},
    )


def events(output):
    return [json.loads(line)["event"] for line in output.splitlines()]


def digest_tree(path):
    return {
        name: hashlib.sha256(open(os.path.join(path, name), "rb").read()).hexdigest()
        for name in sorted(os.listdir(path)) if os.path.isfile(os.path.join(path, name))
    }


def assert_completed_lineage(root):
    parent = os.path.join(root, "parent")
    result = run(["machine", "parent", "structured", "--scripted"], parent)
    assert result.returncode == 0, result.stderr
    immutable = digest_tree(parent)
    for operation, attempts, reused in [("resume", 0, 1), ("fork", 0, 1), ("restart", 1, 0)]:
        child = os.path.join(root, operation)
        result = run([f"machine-{operation}", operation, parent, "structured", "--scripted"], child)
        assert result.returncode == 0, result.stderr
        observed = events(result.stdout)
        assert len([event for event in observed if event["type"] == "attempt.started"]) == attempts
        assert len([event for event in observed if event["type"] == "occurrence.reused"]) == reused
        manifest = json.load(open(os.path.join(child, "manifest.json")))["run"]
        assert manifest["parentRunId"] == "parent" and manifest["lineage"] == operation
        assert digest_tree(parent) == immutable
    replacement = os.path.join(root, "replacement.json")
    with open(replacement, "w") as handle:
        json.dump({"priority": 2, "steps": ["replaced"], "title": "Forked"}, handle)
    replaced_store = os.path.join(root, "fork-replaced")
    result = run(["machine-fork", "fork-replaced", parent, "structured", "--set-answer", f"0={replacement}", "--scripted"], replaced_store)
    assert result.returncode == 0, result.stderr
    replaced_events = events(result.stdout)
    assert any(event["type"] == "occurrence.reused" and event["answerGroup"] == "replacement" for event in replaced_events)
    dropped_store = os.path.join(root, "fork-dropped")
    result = run(["machine-fork", "fork-dropped", parent, "structured", "--drop-answer", "0", "--scripted"], dropped_store)
    assert result.returncode == 0, result.stderr
    assert len([event for event in events(result.stdout) if event["type"] == "attempt.started"]) == 1
    assert digest_tree(parent) == immutable
    invalid_store = os.path.join(root, "fork-invalid")
    result = run(["machine-fork", "fork-invalid", parent, "structured", "--drop-answer", "99", "--scripted"], invalid_store)
    assert result.returncode != 0 and not result.stdout and "no persisted answer" in result.stderr
    assert not os.path.exists(os.path.join(invalid_store, "manifest.json"))
    duplicate_store = os.path.join(root, "fork-duplicate")
    result = run(["machine-fork", "fork-duplicate", parent, "structured", "--drop-answer", "0", "--drop-answer", "0", "--scripted"], duplicate_store)
    assert result.returncode != 0 and not result.stdout and "more than once" in result.stderr
    assert not os.path.exists(os.path.join(duplicate_store, "manifest.json"))
    bad_replacement = os.path.join(root, "bad-replacement.json")
    with open(bad_replacement, "w") as handle:
        handle.write("not-json")
    bad_store = os.path.join(root, "fork-bad-json")
    result = run(["machine-fork", "fork-bad-json", parent, "structured", "--set-answer", f"0={bad_replacement}", "--scripted"], bad_store)
    assert result.returncode != 0 and not result.stdout and "not JSON" in result.stderr
    assert not os.path.exists(os.path.join(bad_store, "manifest.json"))
    wrong_shape = os.path.join(root, "wrong-shape.json")
    with open(wrong_shape, "w") as handle:
        json.dump("not a release plan", handle)
    wrong_store = os.path.join(root, "fork-wrong-shape")
    result = run(["machine-fork", "fork-wrong-shape", parent, "structured", "--set-answer", f"0={wrong_shape}", "--scripted"], wrong_store)
    assert result.returncode != 0 and not result.stdout and "does not conform" in result.stderr
    assert not os.path.exists(os.path.join(wrong_store, "manifest.json"))
    assert digest_tree(parent) == immutable
    duplicate_parent = os.path.join(root, "duplicate-parent")
    shutil.copytree(parent, duplicate_parent)
    answers_path = os.path.join(duplicate_parent, "answers.json")
    stored_answers = json.load(open(answers_path))
    stored_answers["answers"].append(stored_answers["answers"][0])
    with open(answers_path, "w") as handle:
        json.dump(stored_answers, handle)
    duplicate_child = os.path.join(root, "duplicate-child")
    result = run(["machine-resume", "duplicate-child", duplicate_parent, "structured", "--scripted"], duplicate_child)
    assert result.returncode != 0 and not result.stdout and "duplicates occurrence" in result.stderr
    assert not os.path.exists(os.path.join(duplicate_child, "manifest.json"))
    os.remove(os.path.join(parent, "checkpoint.json"))
    immutable = digest_tree(parent)
    for operation in ("restart", "fork"):
        child = os.path.join(root, f"no-checkpoint-{operation}")
        result = run([f"machine-{operation}", f"no-checkpoint-{operation}", parent, "structured", "--scripted"], child)
        assert result.returncode == 0, result.stderr
        assert digest_tree(parent) == immutable
    missing_checkpoint = os.path.join(root, "no-checkpoint-resume")
    result = run(["machine-resume", "no-checkpoint-resume", parent, "structured", "--scripted"], missing_checkpoint)
    assert result.returncode != 0 and not result.stdout and "no compatible checkpoint" in result.stderr
    assert not os.path.exists(os.path.join(missing_checkpoint, "manifest.json"))
    mismatch = os.path.join(root, "policy-mismatch")
    adapter = os.path.join(ROOT, "test", "retry_adapter.py")
    result = run(["machine-restart", "mismatch", parent, "structured", "--engine", "acp", "--adapter", sys.executable, "--adapter-arg", adapter], mismatch)
    assert result.returncode != 0 and not result.stdout and "fingerprint/policy" in result.stderr
    assert not os.path.exists(os.path.join(mismatch, "manifest.json"))
    assert digest_tree(parent) == immutable


def assert_crash_resume(root):
    parent = os.path.join(root, "crashed")
    process = subprocess.Popen(
        [BINARY, "machine", "crashed", "hello", "--scripted"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        env={**os.environ, "AGENT_CAT_RUN_STORE": parent},
    )
    for line in process.stdout:
        event = json.loads(line)["event"]
        if event["type"] == "occurrence.completed" and event["occurrenceId"] == "0":
            os.killpg(process.pid, signal.SIGKILL)
            break
    process.wait(timeout=10)
    assert os.path.exists(os.path.join(parent, "checkpoint.json"))
    immutable = digest_tree(parent)
    child = os.path.join(root, "resumed")
    result = run(["machine-resume", "resumed", parent, "hello", "--scripted"], child)
    assert result.returncode == 0, result.stderr
    observed = events(result.stdout)
    assert any(event["type"] == "occurrence.reused" and event["occurrenceId"] == "0" for event in observed)
    assert len([event for event in observed if event["type"] == "attempt.started"]) == 2
    assert digest_tree(parent) == immutable


def assert_effect_refusal(root):
    parent = os.path.join(root, "effect-crash")
    adapter = os.path.join(ROOT, "test", "effect_hang_adapter.py")
    process = subprocess.Popen(
        [BINARY, "machine", "effect-crash", "hello", "--engine", "acp", "--adapter", sys.executable, "--adapter-arg", adapter, "--timeout", "30000"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        env={**os.environ, "AGENT_CAT_RUN_STORE": parent},
    )
    for line in process.stdout:
        event = json.loads(line)["event"]
        if event["type"] == "attempt.started" and event["occurrenceId"] == "2":
            os.killpg(process.pid, signal.SIGKILL)
            break
    process.wait(timeout=10)
    journal = [json.loads(line) for line in open(os.path.join(parent, "effects.ndjson"))]
    assert len(journal) == 1 and journal[0]["phase"] == "started"
    immutable = digest_tree(parent)
    child = os.path.join(root, "unsafe")
    result = run(["machine-resume", "unsafe", parent, "hello", "--engine", "acp", "--adapter", sys.executable, "--adapter-arg", adapter, "--timeout", "30000"], child)
    assert result.returncode != 0 and not result.stdout and "started or completed effects" in result.stderr
    assert not os.path.exists(os.path.join(child, "manifest.json"))
    assert digest_tree(parent) == immutable


def main():
    root = tempfile.mkdtemp(prefix="agentic-lineage-probe-")
    try:
        assert_completed_lineage(root)
        assert_crash_resume(root)
        assert_effect_refusal(root)
        print("lineage probe: all checks passed")
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
