#!/usr/bin/env python3
"""Check schema-vector lifetime through the exact shell block and real JSON Schema probe."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile

from policy_refusal_evidence import run, save


def vectors(label):
    return [
        {"label": label + " integer accepted", "schema": {"type": "integer"}, "value": 7, "accepted": True},
        {"label": label + " text refused", "schema": {"type": "integer"}, "value": "雪", "accepted": False},
        {"label": label + " required field refused", "schema": {"type": "object", "required": ["answer"]}, "value": {}, "accepted": False},
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, help="new private evidence directory")
    parser.add_argument("--baseline", type=Path, help="old policies block, expected lifetime red only")
    args = parser.parse_args()
    checkout = Path(__file__).resolve().parents[1]
    source = args.baseline or checkout / "cli/ci/policies.sh"
    text = source.read_text()
    allocation = 'schema_vectors=$(mktemp "${CABAL_BUILDDIR:?}/answer-schema.XXXXXX.json")\n'
    validation = 'python3 test/answer_schema_probe.py "$schema_vectors"\n'
    assert text.count(allocation) == text.count(validation) == 1
    start = text.index(allocation)
    end = text.index(validation, start) + len(validation)
    block = text[start:end]
    expected = allocation + ('trap \'rm -f "$schema_vectors"\' EXIT\n' if args.baseline else '')
    expected += '"$schema_runner" --answer-schema-vectors > "$schema_vectors"\n' + validation
    assert block == expected, "schema allocation/generator/validator block changed"
    if args.work:
        args.work.mkdir(mode=0o700)
        root = args.work.resolve()
    else:
        root = Path(tempfile.mkdtemp(prefix="answer-schema-data-", dir=os.environ["CABAL_BUILDDIR"])).resolve()
    (root / "extracted-block.sh").write_text(block)
    probe = checkout / "test/answer_schema_probe.py"
    save(root / "source-binding.json", {
        "source": str(source.resolve()), "sourceSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "blockSha256": hashlib.sha256(block.encode()).hexdigest(),
        "startLine": text[:start].count("\n") + 1,
        "validatorSha256": hashlib.sha256(probe.read_bytes()).hexdigest(),
        "fullPoliciesSourced": False, "compiledHaskellDecoderExecuted": False,
    })
    bash, mktemp = shutil.which("bash"), shutil.which("mktemp")
    assert bash and mktemp
    results = []
    repeated = []

    def case(name, payload, generator_exit=0, later_failure=False, validator_failure=False,
             allocation_failure=False, open_failure=False, repeat=False):
        sandbox = root / ("repeated" if repeat else name)
        if not sandbox.exists():
            sandbox.mkdir(mode=0o700)
            (sandbox / "test").mkdir()
            (sandbox / "bin").mkdir()
            shutil.copy2(probe, sandbox / "test/answer_schema_probe.py")
            assert (sandbox / "test/answer_schema_probe.py").read_bytes() == probe.read_bytes()
            runner = sandbox / "schema-runner"
            runner.write_text(
                "#!" + sys.executable + "\n"
                "import json,os,sys\n"
                "from pathlib import Path\n"
                "assert sys.argv[1:]==['--answer-schema-vectors']\n"
                "with open(os.environ['SCHEMA_CALL_RECORD'],'x') as f: json.dump({'argv':sys.argv[1:]},f)\n"
                "os.write(1,Path(os.environ['SCHEMA_BYTES']).read_bytes())\n"
                "code=int(os.environ['SCHEMA_EXIT'])\n"
                "if code: os.write(2,b'INERT_SCHEMA_GENERATOR_FAILURE\\n')\n"
                "raise SystemExit(code)\n"
            )
            runner.chmod(0o700)
            allocator = sandbox / "bin/mktemp"
            allocator.write_text(
                "#!" + bash + "\nset -e\numask 077\n"
                + "allocated=$(" + shlex.quote(mktemp) + ' "$@")\n'
                + 'printf "%s\\n" "$allocated" > "$ALLOCATION_RECORD"\n'
                + 'if [ "$OBSTRUCT_OUTPUT" = 1 ]; then rm "$allocated"; mkdir "$allocated"; fi\n'
                + 'printf "%s\\n" "$allocated"\n'
            )
            allocator.chmod(0o700)
            if not allocation_failure:
                (sandbox / "build").mkdir(mode=0o700)
        supplied = sandbox / (name + ".vectors")
        supplied.write_bytes(payload)
        allocated_record = sandbox / (name + ".allocation")
        call_record = sandbox / (name + ".generator.json")
        driver = sandbox / (name + ".sh")
        driver.write_text('set -euo pipefail\nschema_runner=' + shlex.quote(str(sandbox / "schema-runner")) + '\n' + block
                          + ('echo INJECTED_LATER_FAILURE >&2\nexit 23\n' if later_failure else ''))
        env = dict(os.environ, CABAL_BUILDDIR=str(sandbox / "build"), PATH=str(sandbox / "bin") + os.pathsep + os.environ["PATH"],
                   SCHEMA_BYTES=str(supplied), SCHEMA_EXIT=str(generator_exit), SCHEMA_CALL_RECORD=str(call_record),
                   ALLOCATION_RECORD=str(allocated_record), OBSTRUCT_OUTPUT="1" if open_failure else "0", PYTHONDONTWRITEBYTECODE="1")
        env.pop("GHCRTS", None)
        code, output, errors = run([bash, str(driver)], sandbox, env, sandbox / name)
        summary = b"answer schema probe: 3 bounded schema/decoder comparisons passed\n"
        allocated = Path(allocated_record.read_text().strip()) if allocated_record.exists() else None
        if allocation_failure:
            assert code == 1 and allocated is None and not call_record.exists() and output == b""
            assert b"no such file or directory" in errors.lower()
        elif open_failure:
            assert code == 1 and allocated.is_dir() and not call_record.exists() and output == b""
            assert b"is a directory" in errors.lower()
        else:
            assert json.loads(call_record.read_text()) == {"argv": ["--answer-schema-vectors"]}
            if args.baseline:
                assert code == 0 and output == summary and errors == b""
                save(sandbox / "old-validation-passed.json", {"shellExit": code, "allocated": str(allocated), "deletedByOriginalTrap": not allocated.exists()})
                assert allocated.is_file(), "OLD RED: schema EXIT trap removed validated original vector file"
            assert allocated.read_bytes() == payload and allocated.stat().st_mode & 0o777 == 0o600
            if generator_exit:
                assert code == generator_exit and output == b"" and errors == b"INERT_SCHEMA_GENERATOR_FAILURE\n"
            elif validator_failure:
                assert code == 1 and output == b"" and b"AssertionError: deliberate validator mismatch" in errors
            elif later_failure:
                assert code == 23 and output == summary and errors == b"INJECTED_LATER_FAILURE\n"
            else:
                assert code == 0 and output == summary and errors == b""
            if repeat:
                for previous, contents, identity in repeated:
                    assert previous.read_bytes() == contents
                    st = previous.stat()
                    assert (st.st_ino, st.st_mtime_ns, st.st_ctime_ns) == identity
                    assert previous != allocated and contents != payload
                st = allocated.stat()
                repeated.append((allocated, payload, (st.st_ino, st.st_mtime_ns, st.st_ctime_ns)))
        results.append({"name": name, "shellExit": code, "allocated": str(allocated) if allocated else None,
                        "generatorInvoked": call_record.exists(), "retainedFile": bool(allocated and allocated.is_file()), "passed": True})

    valid = json.dumps(vectors("first"), ensure_ascii=False, indent=2).encode() + b"\n\n"
    if args.baseline:
        case("old-red", valid)
        raise AssertionError("old trap unexpectedly retained the file")
    case("normal-first", valid, repeat=True)
    case("normal-second", json.dumps(vectors("different"), ensure_ascii=False).encode() + b"\n\n\n", repeat=True)
    case("later-failure", valid, later_failure=True)
    case("generator-partial-failure", b'[{"label": "unfinished', generator_exit=7)
    invalid = vectors("invalid")
    invalid[0].update(label="deliberate validator mismatch", accepted=False)
    case("validator-rejection", json.dumps(invalid).encode() + b"\n", validator_failure=True)
    case("allocation-failure", valid, allocation_failure=True)
    case("redirection-failure", valid, open_failure=True)
    save(root / "results.json", {"cases": results, "passed": True, "validator": "unchanged answer_schema_probe.py",
                                 "HaskellDecoderExecuted": False, "fullPoliciesExecuted": False})
    print(f"PASS answer-schema evidence: {len(results)} inert lifecycle cases; retained at {root}")


if __name__ == "__main__":
    main()
