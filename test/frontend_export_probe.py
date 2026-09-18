#!/usr/bin/env python3
"""Exercise managed verified result export through the real runner boundary."""
from __future__ import annotations

from contextlib import ExitStack, contextmanager
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from frontend_session_probe import Session, encode, query


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: frontend_export_probe.py RUNNER")
    runner = Path(sys.argv[1]).resolve()
    with Session.active:
        temporary = tempfile.mkdtemp(prefix="agent-cat-export-probe-")
        with ExitStack() as exporters:
            case = Path(temporary).resolve()
            session = Session(
                runner,
                case,
                "prompt-source",
                [{"name": "input", "source": "literal", "value": "managed export fixture"}],
            )
            session.send(session.decision("start"))
            events = session.finish()
            reference = events[-1]["event"]["result"]
            identity = session.preview["rootIdentity"]
            state = session.root
            verified = query(runner, case, {
                "version": 1,
                "operation": "read-result",
                "rootIdentity": identity,
                "runId": session.preview["runId"],
                "reference": reference,
            })
            environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_CAT_")}
            environment["XDG_CONFIG_HOME"] = str(case / "invalid-config")

            @contextmanager
            def exporter():
                process = subprocess.Popen(
                    [str(runner), "frontend-export", "--state", str(state)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    cwd=case, env=environment, close_fds=True,
                )
                try:
                    yield process
                finally:
                    failure = sys.exc_info()[1]
                    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT})
                    try:
                        cleanup_failure = None
                        try:
                            try:
                                if process.poll() is None:
                                    process.terminate()
                            except KeyboardInterrupt as interrupted:
                                cleanup_failure = interrupted
                            if process.stdin is not None and process.stdin.closed:
                                process.stdin = None
                            timeout = 10 if cleanup_failure is None else None
                            while True:
                                try:
                                    process.communicate(timeout=timeout)
                                    break
                                except (subprocess.TimeoutExpired, KeyboardInterrupt) as interrupted:
                                    cleanup_failure = cleanup_failure or interrupted
                                    # Failure is final, but ownership lasts through the original join.
                                    timeout = None
                        except BaseException as unjoined:
                            primary = failure or cleanup_failure
                            if primary is None:
                                raise
                            primary.add_note(f"Exporter original join UNPROVEN: {unjoined!r}")
                            raise primary from unjoined
                        if cleanup_failure is not None:
                            if failure is None:
                                raise cleanup_failure
                            failure.add_note(f"Exporter cleanup failed: {cleanup_failure!r}; original child joined")
                    finally:
                        primary = sys.exc_info()[1] or failure
                        try:
                            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                        except KeyboardInterrupt:
                            if primary is None:
                                raise
                            primary.add_note("Caller interruption deferred until original-owner cleanup finished")

            from unittest.mock import patch

            with ExitStack() as interrupted_exporters:
                interrupted_exporter = interrupted_exporters.enter_context(exporter())
                original_communicate = interrupted_exporter.communicate
                first = subprocess.TimeoutExpired(interrupted_exporter.args, 10)
                faults = [first, KeyboardInterrupt(), KeyboardInterrupt()]
                waits = []

                def interrupted_communicate(*args, **kwargs):
                    assert case.is_dir(), "export root disposed before original join"
                    waits.append(kwargs.get("timeout"))
                    if faults:
                        signal.raise_signal(signal.SIGINT)
                        assert signal.SIGINT in signal.sigpending(), "caller SIGINT was not deferred"
                        raise faults.pop(0)
                    return original_communicate(*args, **kwargs)

                with patch.object(interrupted_exporter, "communicate", interrupted_communicate):
                    try:
                        interrupted_exporters.close()
                    except subprocess.TimeoutExpired as observed:
                        assert observed is first
                    else:
                        raise AssertionError("export cleanup timeout became success")
                assert not faults and waits == [10, None, None, None], waits
                assert interrupted_exporter.returncode is not None, "original exporter was not joined"

            def request(name: object, reference_value: object = reference, root_identity: object = identity, **extra: object) -> dict:
                return {
                    "version": 1,
                    "operation": "export-result",
                    "rootIdentity": root_identity,
                    "runId": session.preview["runId"],
                    "reference": reference_value,
                    "name": name,
                    **extra,
                }

            def export(value: object, code: int = 0, configured_state: Path = state) -> bytes:
                result = subprocess.run(
                    [str(runner), "frontend-export", "--state", str(configured_state)],
                    input=encode(value), capture_output=True, cwd=case, env=environment,
                    timeout=30, close_fds=True,
                )
                assert result.returncode == code, (result.returncode, result.stdout, result.stderr)
                if code:
                    assert not result.stdout and 0 < len(result.stderr) <= 4097, result
                else:
                    assert not result.stderr and result.stdout.endswith(b"\n") and result.stdout.count(b"\n") == 1, result
                return result.stdout

            expected = encode({"code": reference["code"], "value": verified["value"]}) + b"\n"
            owner_path = session.run / "owner.json"
            owner_before = owner_path.read_bytes()
            receipt = json.loads(export(request("result.json")))
            destination = state / "exports/result.json"
            assert destination.read_bytes() == expected
            assert destination.stat().st_mode & 0o777 == 0o600
            assert receipt == {
                "version": 1,
                "operation": "export-result",
                "runId": session.preview["runId"],
                "name": "result.json",
                "path": str(destination),
                "bytes": str(len(expected)),
                "sha256": hashlib.sha256(expected).hexdigest(),
                "code": reference["code"],
            }
            assert (state / "exports").stat().st_mode & 0o777 == 0o700
            assert owner_path.read_bytes() == owner_before

            fragmented_request = encode(request("fragmented.json"))
            fragmented = exporters.enter_context(exporter())
            assert fragmented.stdin is not None
            midpoint = len(fragmented_request) // 2
            fragmented.stdin.write(fragmented_request[:midpoint])
            fragmented.stdin.flush()
            time.sleep(0.2)
            assert fragmented.poll() is None, "frontend-export did not wait for request EOF"
            fragmented_output, fragmented_error = fragmented.communicate(fragmented_request[midpoint:], timeout=30)
            assert fragmented.returncode == 0 and not fragmented_error and json.loads(fragmented_output)["name"] == "fragmented.json"
            assert (state / "exports/fragmented.json").read_bytes() == expected

            export(request("result.json"), code=3)
            assert destination.read_bytes() == expected
            existing = state / "exports/existing.json"
            existing.write_bytes(b"sentinel")
            existing.chmod(0o600)
            export(request("existing.json"), code=3)
            assert existing.read_bytes() == b"sentinel"
            directory = state / "exports/directory.json"
            directory.mkdir(mode=0o700)
            export(request("directory.json"), code=3)
            outside = case / "outside"
            outside.write_bytes(b"outside sentinel")
            outside.chmod(0o600)
            linked = state / "exports/linked.json"
            linked.symlink_to(outside)
            export(request("linked.json"), code=3)
            assert outside.read_bytes() == b"outside sentinel" and linked.is_symlink()

            stale = state / "exports/.agentic-tmp-stale"
            stale.write_bytes(b"stale private temporary")
            stale.chmod(0o600)
            export(request("after-stale.json"))
            assert (state / "exports/after-stale.json").read_bytes() == expected
            assert stale.read_bytes() == b"stale private temporary"
            longest = "n" * 255
            export(request(longest))
            assert (state / "exports" / longest).read_bytes() == expected

            malformed = [
                {**request("bad-version.json"), "version": 2},
                {**request("bad-operation.json"), "operation": "write-file"},
                request("unknown.json", body="forbidden"),
                request("destination.json", destination="/tmp/forbidden"),
                request(3),
                request("nested.json", {**reference, "future": True}),
                request("missing-reference.json", None),
                {key: value for key, value in request("missing-name.json").items() if key != "name"},
                request("wrong-root.json", root_identity="[]"),
                {**request("traversal-run.json"), "runId": ".."},
                request("oversized-reference.json", {**reference, "bytes": str(64 * 1024 * 1024 + 1)}),
            ]
            for value in malformed:
                export(value, code=3)
            for name in ["", ".", "..", "a/b", "a\\b", "line\nfeed", "control\x1f", "delete\x7f", "n" * 256]:
                export(request(name), code=3)
            raw = subprocess.run(
                [str(runner), "frontend-export", "--state", str(state)], input=b"not-json",
                capture_output=True, cwd=case, env=environment, timeout=30,
            )
            assert raw.returncode == 3 and not raw.stdout and 0 < len(raw.stderr) <= 4097
            export(json.loads(b"{}"), code=3)
            oversized = subprocess.run(
                [str(runner), "frontend-export", "--state", str(state)], input=b" " * (2 * 1024 * 1024 + 1),
                capture_output=True, cwd=case, env=environment, timeout=30,
            )
            assert oversized.returncode == 3 and not oversized.stdout and len(oversized.stderr) <= 4097

            other = case / "other-state"
            other.mkdir(mode=0o700)
            other_identity = query(runner, case, {"version": 1, "operation": "open-root", "path": str(other)})["rootIdentity"]
            export(request("other-root.json", root_identity=other_identity), code=3)

            result_path = session.run / "runtime/result.json"
            original_result = result_path.read_bytes()
            for field, value in [
                ("artifactVersion", 2),
                ("path", "../result.json"),
                ("sha256", "0" * 64),
                ("bytes", str(int(reference["bytes"]) + 1)),
                ("code", {"wrong": True}),
            ]:
                export(request(f"tampered-{field}.json", {**reference, field: value}), code=3)
            invalid_artifact = b"{invalid-json\n"
            result_path.write_bytes(invalid_artifact)
            export(request("invalid-artifact.json", {
                **reference,
                "bytes": str(len(invalid_artifact)),
                "sha256": hashlib.sha256(invalid_artifact).hexdigest(),
            }), code=3)
            result_path.write_bytes(original_result)

            copied_parent = state / "runs/copied-run"
            copied_parent.mkdir(mode=0o700)
            copied_run = copied_parent / "runtime"
            copied_run.mkdir(mode=0o700)
            (copied_run / "result.json").write_bytes(original_result)
            (copied_run / "result.json").chmod(0o600)
            copied_request = {**request("wrong-run.json"), "runId": "copied-run"}
            export(copied_request, code=3)

            result_path.rename(result_path.with_suffix(".real"))
            result_path.symlink_to(result_path.with_suffix(".real"))
            export(request("result-symlink.json"), code=3)
            result_path.unlink()
            result_path.with_suffix(".real").rename(result_path)
            runs = state / "runs"
            real_runs = state / "real-runs"
            runs.rename(real_runs)
            runs.symlink_to(real_runs, target_is_directory=True)
            export(request("runs-symlink.json"), code=3)
            runs.unlink()
            real_runs.rename(runs)
            exports = state / "exports"
            real_exports = state / "real-exports"
            exports.rename(real_exports)
            exports.symlink_to(real_exports, target_is_directory=True)
            export(request("exports-symlink.json"), code=3)
            exports.unlink()
            real_exports.rename(exports)

            journal = session.run / "runtime/events.ndjson"
            with journal.open("ab") as stream:
                stream.write(b"{torn journal")
            export(request("damaged-journal.json"))
            assert (state / "exports/damaged-journal.json").read_bytes() == expected

            concurrent_name = "concurrent.json"
            processes = [exporters.enter_context(exporter()) for _ in range(8)]
            outcomes = [process.communicate(encode(request(concurrent_name)), timeout=30) + (process.returncode,) for process in processes]
            assert sum(code == 0 for _, _, code in outcomes) == 1, outcomes
            assert all(code in [0, 3] and (output.endswith(b"\n") if code == 0 else not output) and len(error) <= 4097
                       for output, error, code in outcomes)
            assert (state / "exports" / concurrent_name).read_bytes() == expected
            assert [path.name for path in (state / "exports").iterdir() if path.name.startswith(".agentic-tmp-")] == [stale.name]

            race_run_id = "exports-replacement-race"
            race_runtime = state / "runs" / race_run_id / "runtime"
            race_runtime.mkdir(parents=True, mode=0o700)
            (state / "runs" / race_run_id).chmod(0o700)
            race_code = {"kind": "replacement-race"}
            race_value = "x" * (48 * 1024 * 1024)
            race_artifact = encode({
                "artifactVersion": 1,
                "result": {"code": race_code, "value": race_value},
                "runId": race_run_id,
            }) + b"\n"
            assert len(race_artifact) <= 64 * 1024 * 1024
            race_artifact_path = race_runtime / "result.json"
            race_artifact_path.write_bytes(race_artifact)
            race_artifact_path.chmod(0o600)
            race_reference = {
                "artifactVersion": 1,
                "path": "result.json",
                "sha256": hashlib.sha256(race_artifact).hexdigest(),
                "bytes": str(len(race_artifact)),
                "code": race_code,
                "preview": "replacement race",
            }
            race_name = "replaced-during-publication.json"
            race_request = {
                "version": 1,
                "operation": "export-result",
                "rootIdentity": identity,
                "runId": race_run_id,
                "reference": race_reference,
                "name": race_name,
            }
            race_expected = encode({"code": race_code, "value": race_value}) + b"\n"
            before_temporaries = {path.name for path in exports.iterdir() if path.name.startswith(".agentic-tmp-")}
            publishing = exporters.enter_context(exporter())
            assert publishing.stdin is not None and publishing.stdout is not None and publishing.stderr is not None
            publishing.stdin.write(encode(race_request))
            publishing.stdin.close()
            deadline = time.monotonic() + 30
            while True:
                new_temporaries = {
                    path.name for path in exports.iterdir()
                    if path.name.startswith(".agentic-tmp-") and path.name not in before_temporaries
                }
                if new_temporaries and not (exports / race_name).exists():
                    break
                assert publishing.poll() is None and time.monotonic() < deadline, "did not observe export temporary before commit"
            try:
                publishing.send_signal(signal.SIGSTOP)
                time.sleep(0.1)
                assert not (exports / race_name).exists()
                detached_exports = case / "detached-exports"
                exports.rename(detached_exports)
                exports.mkdir(mode=0o700)
            finally:
                failure = sys.exc_info()[1]
                previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT})
                try:
                    interrupted = None
                    while True:
                        try:
                            publishing.send_signal(signal.SIGCONT)
                            break
                        except KeyboardInterrupt as interruption:
                            interrupted = interrupted or interruption
                        except BaseException as cleanup:
                            if failure is None:
                                raise
                            failure.add_note(f"Exporter resume UNPROVEN: {cleanup!r}")
                            raise failure from cleanup
                    if interrupted is not None:
                        if failure is None:
                            raise interrupted
                        failure.add_note(f"Exporter resume interrupted: {interrupted!r}; original exporter resumed")
                finally:
                    primary = sys.exc_info()[1] or failure
                    try:
                        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                    except KeyboardInterrupt:
                        if primary is None:
                            raise
                        primary.add_note("Caller interruption deferred until original-owner cleanup finished")
            publishing.stdin = None
            race_stdout, race_stderr = publishing.communicate(timeout=60)
            race_code_status = publishing.returncode
            assert race_code_status == 3 and not race_stdout and 0 < len(race_stderr) <= 4097, (race_code_status, race_stdout, race_stderr)
            assert not (exports / race_name).exists()
            assert (detached_exports / race_name).read_bytes() == race_expected
            exports.rmdir()
            detached_exports.rename(exports)

            lost_name = "lost-reply.json"
            lost = exporters.enter_context(exporter())
            assert lost.stdout is not None and lost.stdin is not None and lost.stderr is not None
            lost.stdout.close()
            lost.stdin.write(encode(request(lost_name)))
            lost.stdin.close()
            lost.stdin = None
            _, lost_error = lost.communicate(timeout=30)
            lost_code = lost.returncode
            assert lost_code != 0 and len(lost_error) <= 4097, (lost_code, lost_error)
            lost_path = state / "exports" / lost_name
            assert lost_path.read_bytes() == expected
            export(request(lost_name), code=3)
            assert lost_path.read_bytes() == expected

            moved = case / "moved-state"
            state.rename(moved)
            state.mkdir(mode=0o700)
            try:
                export(request("replaced-root.json"), code=3)
                assert not (state / "exports").exists()
            finally:
                state.rmdir()
                moved.rename(state)
            state.rename(moved)
            state.symlink_to(moved, target_is_directory=True)
            try:
                export(request("symlink-root.json"), code=3)
                assert not (moved / "exports/symlink-root.json").exists()
            finally:
                state.unlink()
                moved.rename(state)

            for arguments in [
                ["frontend-export"],
                ["frontend-export", "--state", "relative"],
                ["frontend-export", "--state", str(state), "--overwrite"],
            ]:
                refused = subprocess.run([str(runner), *arguments], input=encode(request("cli.json")), capture_output=True, cwd=case, env=environment, timeout=10)
                assert refused.returncode == 1 and not refused.stdout, refused
    shutil.rmtree(temporary)
    print("frontend export: root binding, strict schema, verified typed bytes, no-clobber concurrency, stale temps, interruption, and lost reply passed")


if __name__ == "__main__":
    main()
