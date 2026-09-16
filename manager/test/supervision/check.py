#!/usr/bin/env python3
"""Run real-child supervision regressions: check.py REPOSITORY NEW_PRIVATE_DIRECTORY.

The work directory must not exist. Creation readiness is observed before the
helper's execution timer starts, so process-creation timing is not tested.
"""
from pathlib import Path
import ast
import datetime
import hashlib
import json
import os
import subprocess
import sys
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_new(path, value):
    with path.open("x") as output:
        json.dump(value, output, indent=2)
        output.write("\n")


def main():
    repository = Path(sys.argv[1]).resolve()
    root = Path(sys.argv[2]).absolute()
    scripts = Path(__file__).resolve().parent
    helper = repository / "manager/test/admission_audit.py"
    os.umask(0o077)
    root.mkdir(mode=0o700)
    for directory in ["artifacts", "cases", "home/cache", "tmp", "config"]:
        (root / directory).mkdir(parents=True, exist_ok=True)
    artifacts = root / "artifacts"
    nodes = [node for node in ast.parse(helper.read_text()).body
             if isinstance(node, ast.FunctionDef) and node.name == "run"]
    assert len(nodes) == 1 and nodes[0].args.defaults[0].value == 1200
    inputs = {"helper": str(helper), "helperSha256": sha(helper)}
    write_new(root / "input.json", inputs)
    private = {"HOME": str(root / "home"), "TMPDIR": str(root / "tmp"),
               "XDG_CONFIG_HOME": str(root / "config"),
               "XDG_CACHE_HOME": str(root / "home/cache"),
               "PYTHONDONTWRITEBYTECODE": "1"}
    environment = {key: os.environ[key] for key in ["PATH", "LANG", "LC_ALL", "LC_CTYPE"]
                   if key in os.environ}
    environment.update(private)
    environment_record = {"privateOverrides": private, "names": sorted(environment),
                          "sha256": hashlib.sha256(json.dumps(environment, sort_keys=True).encode()).hexdigest()}
    identities = {str(path): {"sha256": sha(path), "bytes": path.stat().st_size}
                  for path in [helper, scripts / "check.py", scripts / "case.py", scripts / "fixture.py"]}
    write_new(artifacts / "preflight.json", {"identities": identities,
              "environment": environment_record, "python": sys.executable,
              "processCreationTimingUnderTest": False})
    completed = []
    primary = None
    try:
        for mode in ["success", "timeout", "interruption"]:
            assert sha(helper) == inputs["helperSha256"]
            work = root / "cases" / mode
            work.mkdir(mode=0o700)
            command = [sys.executable, "-u", str(scripts / "case.py"), mode, str(work)]
            start = datetime.datetime.now(datetime.timezone.utc).isoformat()
            tick = time.monotonic()
            write_new(work / "command.json", {"command": command, "cwd": str(root),
                      "environment": environment_record, "start": start,
                      "externalTimeout": None, "startNewSession": True})
            original = None
            case_primary = None
            case_cleanup = None
            code = None
            with (work / "supervisor.stdout").open("x") as stdout, (work / "supervisor.stderr").open("x") as stderr:
                try:
                    original = subprocess.Popen(command, cwd=root, env=environment,
                                                stdin=subprocess.DEVNULL, stdout=stdout,
                                                stderr=stderr, start_new_session=True)
                    code = original.wait()
                except BaseException as failure:
                    case_primary = failure
                finally:
                    if case_primary is not None:
                        for name in ["abort.release", "success.release", "cleanup.release"]:
                            (work / name).touch(exist_ok=True)
                    if original is not None and original.returncode is None:
                        try:
                            code = original.wait()
                        except BaseException as failure:
                            case_cleanup = failure
            record = {"case": mode, "command": command, "start": start,
                      "end": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      "seconds": time.monotonic() - tick, "exit": code,
                      "supervisorReaped": original.returncode is not None if original else False,
                      "primaryFailure": type(case_primary).__name__ if case_primary else None,
                      "cleanupFailure": type(case_cleanup).__name__ if case_cleanup else None}
            write_new(work / "completion.json", record)
            if case_primary is not None:
                raise case_primary
            if case_cleanup is not None:
                raise case_cleanup
            assert code == 0, "unexpected test-process exit for " + mode
            assert json.loads((work / "case-report.json").read_text())["passed"], mode
            completed.append(record)
            print("PASS live supervision:", mode, flush=True)
    except BaseException as failure:
        primary = failure
    finally:
        unchanged = sha(helper) == inputs["helperSha256"]
        summary = {"completedCases": [case["case"] for case in completed],
                   "caseRecords": completed, "helperUnchanged": unchanged,
                   "passed": primary is None and len(completed) == 3 and unchanged,
                   "primaryFailure": type(primary).__name__ if primary else None,
                   "actualManagerOrWorkflowTested": False}
        write_new(artifacts / "summary.json", summary)
    if primary is not None:
        raise primary
    assert summary["passed"]
    print("PASS all three supervision regressions; no manager workflow executed", flush=True)


if __name__ == "__main__":
    main()
