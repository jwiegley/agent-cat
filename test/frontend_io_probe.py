#!/usr/bin/env python3
"""Exercise read-only frontend IO through the real runner process boundary."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def encoded(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: frontend_io_probe.py RUNNER [WORKFLOW [NAME=VALUE ...]]")
    runner = Path(sys.argv[1]).resolve()
    workflow_name = sys.argv[2] if len(sys.argv) > 2 else "structured-result"
    bindings = [argument.split("=", 1) for argument in sys.argv[3:]]
    supplied = dict(bindings)
    assert len(supplied) == len(bindings), "duplicate test input"
    fixture = Path(__file__).parent / "fixtures/runtime/frontend-manifest/v2.json"
    with tempfile.TemporaryDirectory(prefix="agent-cat-frontend-io-") as directory:
        root = Path(directory)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_CAT_")}
        environment["XDG_CONFIG_HOME"] = str(root / "config")
        routing = root / "config/agent-cat/routing.yaml"
        routing.parent.mkdir(parents=True, mode=0o700)
        routing.write_text("invalid: [routing\n")

        def invoke(*args: str, data: bytes = b"", code: int = 0, env: dict[str, str] | None = None) -> bytes:
            result = subprocess.run(
                [str(runner), *args], input=data, capture_output=True, cwd=root,
                env=env or environment, timeout=30, close_fds=True,
            )
            assert result.returncode == code, (args, result.returncode, result.stderr.decode("utf-8", "replace"))
            if code:
                assert not result.stdout, result.stdout
            return result.stdout

        def query(operation: str, *, code: int = 0, **fields: object) -> object:
            response = invoke("frontend-io", data=encoded({"version": 1, "operation": operation, **fields}), code=code)
            if code:
                return None
            result = json.loads(response)
            assert result["version"] == 1 and result["operation"] == operation
            return result

        identity = query("open-root", path=str(root))["rootIdentity"]
        query("open-root", path=str(root / "missing"), code=3)
        assert not (root / "missing").exists()
        invoke("frontend-io", data=b"not-json", code=3)
        invoke("frontend-io", data=b" " * (2 * 1024 * 1024 + 1), code=3)
        invoke("frontend-io", data=encoded({"version": 99, "operation": "open-root", "path": str(root)}), code=3)
        query("open-root", path=str(root), unexpected=True, code=3)
        for operation in ["answerPerson", "cancelRun", "steerOccurrence", "retryOccurrence", "failoverOccurrence", "abandonOccurrence", "redirectOccurrence"]:
            query(operation, code=3)

        rows = json.loads(invoke("list", "--json"))
        workflow = next(row for row in rows if row["name"] == workflow_name)
        assert not workflow["capabilities"]["effectful"]
        assert set(supplied) == {item["name"] for item in workflow["inputs"]}
        run_id = "frontend-io-probe"
        runs = root / "runs"
        runs.mkdir(mode=0o700)
        run = runs / run_id
        run.mkdir(mode=0o700)
        inputs = run / "inputs"
        inputs.mkdir(mode=0o700)
        input_args = []
        input_hashes = {}
        for index, item in enumerate(workflow["inputs"]):
            contents = supplied[item["name"]].encode("utf-8")
            path = inputs / f"{index}.txt"
            path.write_bytes(contents)
            path.chmod(0o600)
            input_args.extend(["--input-file", f'{item["name"]}={path}'])
            input_hashes[item["name"]] = hashlib.sha256(contents).hexdigest()
        plan = json.loads(invoke("plan", workflow["name"], "--json", "--raw", *input_args))
        runtime = run / "runtime"
        child_environment = {**environment, "AGENT_CAT_RUN_STORE": str(runtime)}
        events = [json.loads(line) for line in invoke(
            "machine", run_id, workflow["name"], "--scripted", "--protocol-version", "2", *input_args, env=child_environment,
        ).splitlines()]
        assert events[-1]["event"]["type"] == "run.completed", events[-1]
        reference = events[-1]["event"]["result"]
        manifest = json.loads(fixture.read_bytes())
        manifest.update(
            runId=run_id, runnerId="probe", runnerExecutable=str(runner), runnerVersion=workflow["runnerVersion"],
            workflow=workflow["name"], cwd=str(root), inputHashes=input_hashes, policyDigest=None,
            programHash=hashlib.sha256(encoded(plan["program"])).hexdigest(), createdAt=events[0]["timestamp"], ownerId="probe:owner",
        )
        manifest_path = run / "supervisor-manifest.json"
        manifest_path.write_bytes(encoded(manifest) + b"\n")
        manifest_path.chmod(0o600)
        request = {"rootIdentity": identity, "runId": run_id, "reference": reference}
        original = (runtime / "result.json").read_bytes()
        result = query("read-result", **request)
        assert result["value"] == json.loads(original)["result"]["value"]
        assert result["code"] == reference["code"]
        wrong_code = "flag" if reference["code"] == "text" else "text"
        for field, value in [("sha256", "0" * 64), ("bytes", str(int(reference["bytes"]) + 1)), ("path", "../result.json"), ("code", wrong_code)]:
            query("read-result", **{**request, "reference": {**reference, field: value}}, code=3)
        for invalid in [b"{invalid-json\n", b"\xef\xbb\xbf" + original]:
            (runtime / "result.json").write_bytes(invalid)
            changed = {**reference, "bytes": str(len(invalid)), "sha256": hashlib.sha256(invalid).hexdigest()}
            query("read-result", **{**request, "reference": changed}, code=3)
        (runtime / "result.json").write_bytes(original)
        moved = root / "moved-runs"
        runs.rename(moved)
        runs.symlink_to(moved, target_is_directory=True)
        query("read-result", **request, code=3)
        runs.unlink()
        moved.rename(runs)
        assert query("read-result", **request) == result
    print("frontend IO: real scripted result, identity/reference validation, canonical bytes, ancestor confinement, bounds, and read-only commands passed")


if __name__ == "__main__":
    main()
