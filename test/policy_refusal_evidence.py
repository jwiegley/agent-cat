#!/usr/bin/env python3
"""Exercise the extracted policies refusal helper with an inert local command producer."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


def save(path, value):
    with path.open("x") as output:
        json.dump(value, output, indent=2)
        output.write("\n")


def run(command, cwd, env, record):
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    tick = time.monotonic()
    process = None
    primary = None
    wait_failure = None
    interruptions = 0
    code = None
    save(record.with_suffix(".command.json"), {
        "command": command, "cwd": str(cwd), "start": start,
        "environmentNames": sorted(env),
        "environmentSha256": hashlib.sha256(json.dumps(env, sort_keys=True).encode()).hexdigest(),
        "externalTimeout": None,
    })
    with record.with_suffix(".stdout").open("xb") as output, record.with_suffix(".stderr").open("xb") as errors:
        try:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=errors)
            while True:
                try:
                    code = process.wait()
                    break
                except KeyboardInterrupt as failure:
                    if primary is None:
                        primary = failure
                    interruptions += 1
        except BaseException as failure:
            if primary is None:
                primary = failure
            wait_failure = type(failure).__name__
    joined = process is not None and process.returncode is not None
    save(record.with_suffix(".completion.json"), {
        "start": start, "end": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "seconds": time.monotonic() - tick, "exit": code, "originalChildJoined": joined,
        "primaryFailure": type(primary).__name__ if primary else None,
        "waitFailure": wait_failure, "deferredInterruptions": interruptions,
    })
    if primary is not None:
        raise primary
    assert joined, "original helper shell not joined"
    return code, record.with_suffix(".stdout").read_bytes(), record.with_suffix(".stderr").read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, help="new private evidence directory")
    parser.add_argument("--baseline", type=Path, help="source-exact old producer, expected retention red only")
    args = parser.parse_args()
    source = args.baseline or Path(__file__).resolve().parents[1] / "cli/ci/policies.sh"
    text = source.read_text()
    assert text.count("refuses_fact() {\n") == 1
    start = text.index("refuses_fact() {\n")
    end = text.index("\n}\n", start) + 2
    helper = text[start:end]
    command_text = helper.replace("\\\n", " ")
    assert " ".join('test/cabal.sh run -v0 agentic-run -- plan review-lite --input-arg "$fact=" 2>&1'.split()) in " ".join(command_text.split())
    if args.work:
        args.work.mkdir(mode=0o700)
        root = args.work.resolve()
    else:
        root = Path(tempfile.mkdtemp(prefix="policy-refusal-data-", dir=os.environ["CABAL_BUILDDIR"])).resolve()
    (root / "extracted-helper.sh").write_text(helper + "\n")
    save(root / "source-binding.json", {
        "source": str(source.resolve()), "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "startLine": text[:start].count("\n") + 1,
        "helperSha256": hashlib.sha256(helper.encode()).hexdigest(),
        "onlyFunctionExtracted": True, "fullPoliciesSourced": False,
    })
    bash = shutil.which("bash")
    mktemp = shutil.which("mktemp")
    assert bash and mktemp
    results = []

    def case(name, facts, status=1, diagnostic=True, obstruction=None, allocation_failure=False):
        sandbox = root / name
        sandbox.mkdir(mode=0o700)
        (sandbox / "test").mkdir()
        (sandbox / "bin").mkdir()
        build = sandbox / "build"
        if not allocation_failure:
            build.mkdir(mode=0o700)
        first = b"original stdout: \xff\n"
        last = (b"is a run fact: the runner binds it" if diagnostic else b"different refusal") + b"\n\n\n"
        streams = [first + f"invocation {index}\n".encode() for index in range(len(facts))]
        expected_streams = {stream + last for stream in streams}
        save(sandbox / "producer-input.json", {"stdout": [stream.hex() for stream in streams], "stderr": last.hex(), "exit": status})
        producer = sandbox / "test/cabal.py"
        producer.write_text(
            "#!" + sys.executable + "\n"
            "import json,os,sys\n"
            "from pathlib import Path\n"
            "root=Path(__file__).resolve().parents[1]\n"
            "assert Path.cwd()==root\n"
            "calls=root/'calls.jsonl'\n"
            "index=len(calls.read_text().splitlines()) if calls.exists() else 0\n"
            "with calls.open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "data=json.loads((root/'producer-input.json').read_text())\n"
            "os.write(1,bytes.fromhex(data['stdout'][index]))\n"
            "os.write(2,bytes.fromhex(data['stderr']))\n"
            "raise SystemExit(data['exit'])\n"
        )
        producer.chmod(0o700)
        wrapper = sandbox / "test/cabal.sh"
        wrapper.write_text("#!" + bash + "\nexec " + shlex.join([sys.executable, str(producer)]) + ' "$@"\n')
        wrapper.chmod(0o700)
        # Actual filesystem obstructions, not a replacement recorder or status producer.
        if obstruction:
            allocation = sandbox / "bin/mktemp"
            allocation.write_text(
                "#!" + bash + "\n"
                "directory=$(" + shlex.quote(mktemp) + ' "$@") || exit $?\n'
                + 'mkdir "$directory/' + obstruction + '" || exit $?\n'
                + 'printf "%s\\n" "$directory"\n'
            )
            allocation.chmod(0o700)
        driver = sandbox / "driver.sh"
        driver.write_text('set -euo pipefail\n' + helper + '\nfor fact in "$@"; do refuses_fact "$fact"; done\n')
        env = dict(os.environ, CABAL_BUILDDIR=str(build), PATH=str(sandbox / "bin") + os.pathsep + os.environ["PATH"],
                   PYTHONDONTWRITEBYTECODE="1")
        env.pop("GHCRTS", None)
        code, output, errors = run([bash, str(driver), *facts], sandbox, env, sandbox / "helper")
        calls = [json.loads(line) for line in (sandbox / "calls.jsonl").read_text().splitlines()] if (sandbox / "calls.jsonl").exists() else []
        expected_calls = [] if allocation_failure else [
            ["run", "-v0", "agentic-run", "--", "plan", "review-lite", "--input-arg", fact + "="] for fact in facts
        ]
        assert calls == expected_calls, (name, calls)
        cases = sorted(build.glob("policy-refusal.*")) if build.exists() else []
        if args.baseline:
            assert code == 0 and output == b"policy probe: --input-arg run.engine is refused, and names who binds it\n"
            save(sandbox / "old-predicate-passed.json", {"originalHelperExit": code, "rawCaseCount": len(cases)})
            assert cases, "OLD RED: original expected refusal passed but raw merged output was not retained"
        if allocation_failure:
            assert code != 0 and not cases and not calls
        else:
            assert len(cases) == len(facts) and len({p.stat().st_ino for p in cases}) == len(facts)
            if obstruction != "observed.log":
                assert {(directory / "observed.log").read_bytes() for directory in cases} == expected_streams
            for directory in cases:
                assert directory.stat().st_mode & 0o777 == 0o700
                if obstruction != "observed.log":
                    assert (directory / "observed.log").read_bytes() in expected_streams
                if obstruction not in ["refusal.log", "observed.log"]:
                    assert (directory / "refusal.log").read_bytes() == (directory / "observed.log").read_bytes()
                    assert (directory / "refusal.log").stat().st_mode & 0o777 == 0o600
                if obstruction != "status":
                    values = (directory / "status").read_text().splitlines()
                    assert len(values) == 2 and values[0].startswith("command=")
                    assert values[1] == ("writer=1" if obstruction else "writer=0")
                    if obstruction != "observed.log":
                        assert values[0] == "command=" + str(status)
            if status != 1:
                assert code == 1 and f"expected exit 1, actual {status}".encode() in errors
            elif not diagnostic:
                assert code == 1 and b"refused, but not as a run fact" in errors
            elif obstruction:
                assert code == 1 and b"policy probe:" not in output
            else:
                assert code == 0 and errors == b""
                assert output == b"".join(f"policy probe: --input-arg {fact} is refused, and names who binds it\n".encode() for fact in facts)
            if obstruction in ["refusal.log", "status"]:
                assert b"refusal evidence failed:" in errors
        results.append({"name": name, "exit": code, "caseDirectories": [str(p) for p in cases], "passed": True})

    if args.baseline:
        case("old-red", ["run.engine"])
        raise AssertionError("old source unexpectedly retained evidence")
    case("facts-and-repeat", ["run.engine", "run.routes", "run.engine"])
    for status in [0, 2, 130]:
        case("wrong-status-" + str(status), ["run.engine"], status=status)
    case("wrong-diagnostic", ["run.routes"], diagnostic=False)
    for obstruction in ["refusal.log", "status"]:
        case(obstruction + "-success", ["run.engine"], obstruction=obstruction)
        case(obstruction + "-wrong-status", ["run.routes"], status=7, obstruction=obstruction)
        case(obstruction + "-wrong-diagnostic", ["run.engine"], diagnostic=False, obstruction=obstruction)
    case("observation-open-failure", ["run.routes"], obstruction="observed.log")
    case("allocation-failure", ["run.engine"], allocation_failure=True)
    save(root / "results.json", {"cases": results, "passed": True, "realCabalOrRunnerInvoked": False})
    print(f"PASS policy refusal evidence: {len(results)} inert cases; evidence retained at {root}")


if __name__ == "__main__":
    main()
