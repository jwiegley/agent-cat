"""Exercise an exiting audit driver with a live compiler-like descendant."""
import ast
import hashlib
import json
import os
import select
import signal
import subprocess
import sys
import time
import types
from pathlib import Path


def fixture(role, lifetime, report):
    if role == "worker":
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        os.write(report, b"ready\n")
        os.read(lifetime, 1)
        os._exit(0)
    signal.signal(signal.SIGINT, lambda *_: os._exit(23))
    worker = subprocess.Popen(
        [sys.executable, "-u", __file__, "worker", str(lifetime), str(report)],
        pass_fds=(lifetime, report), stdin=subprocess.DEVNULL,
    )
    os.close(lifetime)
    os.close(report)
    while worker.poll() is None:
        time.sleep(0.001)
    os._exit(0)


def check(work):
    root = work.parent.parent
    inputs = json.loads((root / "input.json").read_text())
    helper = Path(inputs["helper"])
    assert hashlib.sha256(helper.read_bytes()).hexdigest() == inputs["helperSha256"]
    nodes = [node for node in ast.parse(helper.read_text()).body
             if isinstance(node, ast.FunctionDef) and node.name == "run"]
    assert len(nodes) == 1 and nodes[0].args.defaults[0].value == 1200
    originals = []
    groups = []
    signals = []
    lifetime_read, lifetime_write = os.pipe()
    report_read, report_write = os.pipe()

    def create_original(command, **kwargs):
        original = subprocess.Popen(
            command, **kwargs, pass_fds=(lifetime_read, report_write),
        )
        originals.append(original)
        groups.append((os.getpgid(original.pid), os.getsid(original.pid)))
        # Only the worker keeps the reporting end after creation.
        os.close(lifetime_read)
        os.close(report_write)
        assert select.select([report_read], [], [], 5)[0], "worker not ready"
        assert os.read(report_read, 6) == b"ready\n"
        return original

    def signal_group(group, signum):
        original = originals[0]
        assert original.returncode is None, "group signalled after original was reaped"
        assert groups == [(original.pid, original.pid)], "not an owned private session"
        assert group == original.pid and signum == signal.SIGKILL
        exited = os.waitid(os.P_PID, original.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
        assert exited is not None and exited.si_pid == original.pid
        signals.append({"group": group, "signal": signum, "originalUnreaped": True})
        return os.killpg(group, signum)

    namespace = {
        "mode": "supervision", "work": work, "copy": work,
        "environment": dict(os.environ), "results": [], "json": json,
        "signal": signal, "time": time,
        "os": types.SimpleNamespace(
            waitid=os.waitid, P_PID=os.P_PID, WEXITED=os.WEXITED,
            WNOWAIT=os.WNOWAIT, killpg=signal_group,
        ),
        "subprocess": types.SimpleNamespace(
            Popen=create_original, STDOUT=subprocess.STDOUT,
            TimeoutExpired=subprocess.TimeoutExpired,
        ),
    }
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(helper), "exec"), namespace)  # noqa: S102 - hash-pinned project-owned helper
    primary = None
    failure = None
    eof_before_release = False
    try:
        try:
            namespace["run"](
                [sys.executable, "-u", __file__, "driver",
                 str(lifetime_read), str(report_write)],
                "child.log", timeout=1.0,
            )
        except subprocess.TimeoutExpired as error:
            primary = error
        assert isinstance(primary, subprocess.TimeoutExpired), type(primary).__name__
        assert len(originals) == 1 and originals[0].returncode == 23
        # An open lifetime pipe still holds the worker; only cleanup may stop it.
        assert select.select([report_read], [], [], 3)[0], "descendant survived driver cleanup"
        eof_before_release = os.read(report_read, 1) == b""
        assert eof_before_release, "descendant kept its report pipe open"
        assert len(signals) == 1, "expected one group signal before original reap"
        result = namespace["results"][0]
        assert result["ownership"] == "original-child-joined"
        assert result["primaryFailure"] == "TimeoutExpired"
        assert result["signalFailure"] is None and result["waitFailure"] is None
        assert result["groupSignalFailure"] is None
        assert result["groupCleanup"] == "owned-group-signalled-before-reap"
        assert hashlib.sha256(helper.read_bytes()).hexdigest() == inputs["helperSha256"]
    except AssertionError as error:
        failure = error
    finally:
        # Failed/negative controls release their own worker without a PID signal.
        os.close(lifetime_write)
        if not originals:
            os.close(lifetime_read)
            os.close(report_write)
        for original in originals:
            original.wait(timeout=5)
        if not eof_before_release:
            assert select.select([report_read], [], [], 5)[0], "fixture failed to release worker"
            assert os.read(report_read, 1) == b""
        os.close(report_read)
    report = {
        "case": "orphan", "passed": failure is None,
        "primaryType": type(primary).__name__ if primary else None,
        "assertionFailure": str(failure) if failure else None,
        "descendantEofBeforeLifetimeRelease": eof_before_release,
        "groupSignals": signals, "helperSha256": inputs["helperSha256"],
        "processCreationTimingUnderTest": False,
    }
    with (work / "case-report.json").open("x") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    print(("PASS" if failure is None else "FAIL") + " orphan", flush=True)
    if failure is not None:
        raise failure


if __name__ == "__main__":
    if sys.argv[1] in {"worker", "driver"}:
        fixture(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
    else:
        assert sys.argv[1] == "orphan"
        check(Path(sys.argv[2]).resolve())
