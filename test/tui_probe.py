#!/usr/bin/env python3
"""Deterministic PTY contract probe for the agent-cat terminal frontend."""

from __future__ import annotations

import argparse
import json
import os
import pty
import select
import shutil
import signal
import stat
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

ESC_DOWN = b"\x1b[B"
ESCAPE = b"\x1b"
ENTER = b"\r"
CTRL_D = b"\x04"


class TuiSession:
    def __init__(
        self,
        runner: Path,
        state: Path,
        *,
        rows: int = 36,
        columns: int = 140,
        command: list[str] | None = None,
        extra_environment: dict[str, str] | None = None,
        explicit_state: bool = True,
    ):
        self.master, self.slave = pty.openpty()
        self.before = termios.tcgetattr(self.slave)
        os.set_blocking(self.master, False)
        import fcntl

        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        environment = os.environ.copy()
        environment["TERM"] = "xterm-256color"
        if explicit_state:
            environment["AGENT_CAT_STATE_DIR"] = str(state)
        else:
            environment.pop("AGENT_CAT_STATE_DIR", None)
            environment["XDG_STATE_HOME"] = str(state)
        environment.update(extra_environment or {})
        self.process = subprocess.Popen(
            command or [str(runner), "--tui"],
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env=environment,
            start_new_session=True,
            close_fds=True,
        )
        self.output = bytearray()

    def pump(self, wait: float = 0.05) -> None:
        readable, _, _ = select.select([self.master], [], [], wait)
        if not readable:
            return
        try:
            chunk = os.read(self.master, 65536)
        except (BlockingIOError, OSError):
            return
        self.output.extend(chunk)
        if len(self.output) > 16 * 1024 * 1024:
            del self.output[: len(self.output) - 16 * 1024 * 1024]

    def settle(self) -> None:
        for _ in range(20):
            self.pump(0.01)

    def wait_for(self, needle: bytes, *, after: int = 0, timeout: float = 45.0) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump()
            position = self.output.find(needle, after)
            if position >= 0:
                return position + len(needle)
            if self.process.poll() is not None:
                break
        tail = bytes(self.output[-4000:]).decode("utf-8", "replace")
        raise AssertionError(f"TUI did not render {needle!r}; exit={self.process.poll()}; tail={tail!r}")

    def send(self, value: bytes) -> None:
        pending = memoryview(value)
        deadline = time.monotonic() + 10
        while pending and time.monotonic() < deadline:
            _, writable, _ = select.select([], [self.master], [], 0.05)
            if writable:
                try:
                    pending = pending[os.write(self.master, pending):]
                except BlockingIOError:
                    pass
            self.pump(0)
        assert not pending, "PTY input did not drain before the timeout"

    def wait_exit(self, timeout: float = 8.0) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump()
            status = self.process.poll()
            if status is not None:
                self.settle()
                return status
        raise AssertionError("TUI did not exit before the timeout")

    def assert_restored(self) -> None:
        after = termios.tcgetattr(self.slave)
        pendin = getattr(termios, "PENDIN", 0)
        before_lflag = self.before[3] & ~pendin
        after_lflag = after[3] & ~pendin
        assert self.before[:3] == after[:3], (self.before, after)
        assert before_lflag == after_lflag, (self.before[3], after[3])
        assert self.before[4:] == after[4:], (self.before, after)
        assert b"\x1b[?1049l" in self.output, "alternate screen was not restored"
        assert b"\x1b[?25h" in self.output, "cursor was not restored"

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)
        os.close(self.slave)

    def __enter__(self) -> "TuiSession":
        return self

    def __exit__(self, _kind, _value, _traceback) -> None:
        self.close()


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def runs(state: Path) -> list[Path]:
    root = state / "runs"
    return sorted(root.iterdir()) if root.exists() else []

def resident_kib(pid: int) -> int:
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "rss="], check=False, capture_output=True, text=True)
    return int(result.stdout.strip() or "0")


def select_workflow(session: TuiSession, downward_moves: int) -> int:
    cursor = session.wait_for(b"Workflows")
    session.settle()
    session.send(ESC_DOWN * downward_moves + ENTER)
    return cursor

def quit_completed_run(session: TuiSession, after: int) -> None:
    session.send(ESCAPE)
    session.wait_for(b"browser", after=after)
    deadline = time.monotonic() + 8
    while session.process.poll() is None and time.monotonic() < deadline:
        session.settle()
        session.send(b"q")
        session.pump(0.2)
    assert session.process.poll() is not None, "completed machine child remained owned by the TUI"
    assert session.wait_exit() == 0

def quit_failed_run(session: TuiSession, after: int) -> None:
    session.send(ESCAPE)
    session.wait_for(b"browser", after=after)
    deadline = time.monotonic() + 12
    while session.process.poll() is None and time.monotonic() < deadline:
        session.settle()
        session.send(ESCAPE)
        session.pump(0.1)
        session.send(b"q")
        session.pump(0.2)
    assert session.process.poll() is not None, "failed machine child remained owned by the TUI"
    assert session.wait_exit() == 0


def test_spawn_descriptors(driver: Path, root: Path) -> None:
    import fcntl
    import resource
    import sys

    original = resource.getrlimit(resource.RLIMIT_NOFILE)
    soft, hard = original
    if sys.platform.startswith("linux"):
        soft = min(1073741816, hard) if hard != resource.RLIM_INFINITY else 1073741816
    descriptor = None
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))
        with (root / "descriptor-sentinel").open("w") as sentinel:
            descriptor = fcntl.fcntl(sentinel.fileno(), fcntl.F_DUPFD, min(65536, soft - 1))
        child = '''import json, os, resource, sys
try:
    os.fstat(int(sys.argv[1]))
    closed = False
except OSError:
    closed = True
print(json.dumps({"closed": closed, "limit": resource.getrlimit(resource.RLIMIT_NOFILE),
                  "session": os.getsid(0) == os.getpid(), "input": sys.stdin.read()}))
print("probe stderr", file=sys.stderr)
'''
        limits = [soft, 256] if sys.platform.startswith("linux") and soft > 256 else [soft]
        for limit in limits:
            resource.setrlimit(resource.RLIMIT_NOFILE, (limit, hard))
            process = subprocess.Popen(
                [str(driver), "--spawn-probe", sys.executable, "-c", child, str(descriptor)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(descriptor,),
            )
            try:
                output, errors = process.communicate(timeout=10)
            finally:
                if process.poll() is None:
                    for pid in child_processes(process.pid):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
            assert process.returncode == 0, errors
            assert json.loads(output) == {
                "closed": True, "limit": [limit, hard], "session": True, "input": "probe stdin",
            }, output
            assert errors == b"probe stderr\n", errors
            assert resource.getrlimit(resource.RLIMIT_NOFILE) == (limit, hard)
        missing = subprocess.run(
            [str(driver), "--spawn-probe", str(root / "missing-spawn-executable")],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
        )
        assert missing.returncode != 0 and b"missing-spawn-executable" in missing.stderr, missing
    finally:
        resource.setrlimit(resource.RLIMIT_NOFILE, original)
        if descriptor is not None:
            os.close(descriptor)
    print(f"spawn probe: nofile={soft}, inherited FD closure, stdio, session, and exec failure passed")


def test_interrupted_helper_shutdown(driver: Path, fixture: Path, root: Path) -> None:
    for first in ("quit", "signal"):
        state = root / f"interrupted-shutdown-{first}"
        ready = root / f"shutdown-helper-{first}"
        term_seen = root / f"shutdown-term-{first}"
        command = [str(driver), str(fixture), str(state), str(root)]
        baseline = processes_matching(str(fixture))
        try:
            with TuiSession(driver, state, command=command, extra_environment={
                "TUI_FIXTURE_PAUSE": "help", "TUI_FIXTURE_READY": str(ready),
                "TUI_FIXTURE_TERM_SEEN": str(term_seen),
            }) as session:
                session.wait_for(b"Workflows"); session.settle(); session.send(b"h")
                deadline = time.monotonic() + 5
                while (not ready.exists() or not ready.read_text()) and time.monotonic() < deadline:
                    session.pump(0.005)
                assert ready.exists() and ready.read_text(), "shutdown helper did not start"
                if first == "quit":
                    cursor = len(session.output); session.send(ESCAPE)
                    session.wait_for(b"filter /", after=cursor); session.send(b"q")
                else:
                    session.process.send_signal(signal.SIGTERM)
                deadline = time.monotonic() + 5
                while not term_seen.exists() and time.monotonic() < deadline:
                    session.pump(0.005)
                assert term_seen.exists(), "helper cleanup did not enter TERM grace"
                assert session.process.poll() is None, "owner exited before cleanup interruption"
                session.process.send_signal(signal.SIGINT)
                assert session.wait_exit(timeout=10) != 0
                session.assert_restored()
            survivors = processes_matching(str(fixture)) - baseline
            assert not survivors, f"helper survived interrupted shutdown: {survivors}"
        finally:
            for pid in processes_matching(str(fixture)) - baseline:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


def test_helper_ownership(driver: Path, fixture: Path, root: Path) -> None:
    for label in ["list", "--routing", "help", "plan", "help-child", "help-redirect"]:
        verb = "help" if label in ("help-child", "help-redirect") else label
        state = root / f"helper-owner-{label}"
        ready = root / f"helper-ready-{label}"
        command = [str(driver), str(fixture), str(state), str(root)]
        children = set()
        try:
            with TuiSession(driver, state, command=command, extra_environment={
                "TUI_FIXTURE_PAUSE": verb, "TUI_FIXTURE_READY": str(ready),
                "TUI_FIXTURE_HELP_CHILD": "redirect" if label == "help-redirect" else "pipes" if label == "help-child" else "",
            }) as session:
                if verb == "help":
                    session.wait_for(b"Workflows"); session.settle(); session.send(b"h")
                elif verb == "plan":
                    select_workflow(session, 0)
                    session.wait_for(b"execution target"); session.send(b"s")
                deadline = time.monotonic() + 10
                while (not ready.exists() or not ready.read_text()) and time.monotonic() < deadline:
                    session.pump()
                assert ready.exists() and ready.read_text(), f"{verb} helper did not start; exit={session.process.poll()}; output={bytes(session.output[-1500:])!r}"
                first = int(ready.read_text()); children.add(first)
                if label in ("help-child", "help-redirect"):
                    session.wait_for(b"fixture help")
                if verb in ("list", "--routing"):
                    session.process.send_signal(signal.SIGTERM)
                    assert session.wait_exit(timeout=10) != 0
                    assert termios.tcgetattr(session.slave) == session.before
                else:
                    cursor = len(session.output); session.send(ESCAPE)
                    session.wait_for(b"filter /", after=cursor)
                    if verb == "help":
                        session.send(b"h")
                        deadline = time.monotonic() + 10
                        while int(ready.read_text() or first) == first and time.monotonic() < deadline:
                            session.pump()
                        second = int(ready.read_text()); children.add(second)
                        assert second != first, "superseding help did not start a new worker"
                        deadline = time.monotonic() + 3
                        while process_exists(first) and time.monotonic() < deadline:
                            time.sleep(0.05)
                        assert not process_exists(first), "superseded helper was not reaped"
                        cursor = len(session.output); session.send(ESCAPE)
                        session.wait_for(b"filter /", after=cursor)
                    session.send(b"q")
                    assert session.wait_exit(timeout=10) == 0
                    session.assert_restored()
                deadline = time.monotonic() + 3
                while any(process_exists(pid) for pid in children) and time.monotonic() < deadline:
                    time.sleep(0.05)
                assert not any(process_exists(pid) for pid in children), f"{label} orphaned helpers: {children}"
        finally:
            for pid in children:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


def test_catalogue_fifo(runner: Path, root: Path) -> None:
    state = root / "fifo-state"
    state.mkdir(mode=0o700)
    (state / "runs").mkdir(mode=0o700)
    good = state / "runs" / "healthy"; good.mkdir(mode=0o700)
    bad = state / "runs" / "bad-fifo"; bad.mkdir(mode=0o700)
    manifest = json.loads(Path("test/fixtures/runtime/frontend-manifest/v2.json").read_text())
    manifest["runId"] = "healthy"
    path = good / "supervisor-manifest.json"
    path.write_text(json.dumps(manifest)); path.chmod(0o600)
    os.mkfifo(bad / "supervisor-manifest.json", 0o600)
    with TuiSession(runner, state, columns=200) as session:
        cursor = session.wait_for(b"Workflows", timeout=5)
        session.settle(); session.send(b"\t")
        session.wait_for(b"healthy", after=cursor)
        session.wait_for(b"not a regular file", after=cursor)
        session.send(b"q")
        assert session.wait_exit() == 0
        session.assert_restored()


def test_non_tty(runner: Path) -> None:
    result = subprocess.run(
        [str(runner), "--tui"],
        input=b"",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=20,
    )
    assert result.returncode != 0
    assert b"--tui requires terminal input and output" in result.stderr

def test_state_root_confinement(runner: Path, root: Path) -> None:
    external = root / "outside-state"
    external.mkdir(mode=0o700)
    linked = root / "linked-state"
    linked.symlink_to(external, target_is_directory=True)
    with TuiSession(runner, linked) as session:
        assert session.wait_exit() != 0
        assert b"state root is not a no-follow directory" in session.output
        assert termios.tcgetattr(session.slave) == session.before
    assert list(external.iterdir()) == [], "symlinked state root received TUI files"

    public = root / "public-state"
    public.mkdir(mode=0o755)
    with TuiSession(runner, public) as session:
        assert session.wait_exit() != 0
        assert b"state root permissions are not private" in session.output
        assert termios.tcgetattr(session.slave) == session.before
    assert mode(public) == 0o755, "TUI silently changed an existing state root"

    anchored = root / "anchored-state"
    escaped = root / "replacement-target"
    escaped.mkdir(mode=0o700)
    with TuiSession(runner, anchored) as session:
        cursor = session.wait_for(b"Workflows")
        moved = root / "moved-anchored-state"
        anchored.rename(moved)
        anchored.symlink_to(escaped, target_is_directory=True)
        select_workflow(session, 1)
        target = session.wait_for(b"execution target", after=cursor)
        session.send(b"s")
        failure = session.wait_for(b"TUI state root", after=target)
        assert list(escaped.iterdir()) == [], "replacement state root received preview files"
        session.settle()
        before_escape = len(session.output)
        session.send(ESCAPE)
        session.wait_for(b"filter /", after=before_escape)
        session.send(b"q")
        assert session.wait_exit() == 0
        session.assert_restored()
        anchored.unlink()
        moved.rename(anchored)

    if os.geteuid() != 0:
        with TuiSession(runner, Path("/")) as session:
            assert session.wait_exit() != 0
            assert b"state root is not owned by the effective user" in session.output
            assert termios.tcgetattr(session.slave) == session.before

def test_child_state_anchor(runner: Path, root: Path) -> None:
    state = root / "child-anchor-state"
    state.mkdir(mode=0o700)
    subject = state / "subject.txt"
    subject.write_text("original input")
    subject.chmod(0o600)
    descriptor = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        identity = os.fstat(descriptor)
        environment = os.environ.copy()
        environment["AGENT_CAT_STATE_ANCHOR"] = json.dumps([str(state), identity.st_dev, identity.st_ino])
        environment["AGENT_CAT_RUN_STORE"] = str(state / "runs" / "anchor-run" / "runtime")
        plan = [str(runner), "plan", "review-lite", "--json", "--raw", "--input-file", f"subject={subject}"]
        machine = [str(runner), "machine", "anchor-run", "hello", "--scripted", "--protocol-version", "2"]
        for command in (plan, machine):
            result = subprocess.run(command, env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            assert result.returncode == 0, result.stderr
        moved = root / "child-anchor-moved"
        state.rename(moved)
        state.mkdir(mode=0o700)
        subject.write_text("replacement input must not be read")
        for command in (plan, machine):
            result = subprocess.run(command, env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            assert result.returncode != 0, "child accepted a replacement state root"
            assert b"state root identity changed" in result.stderr, result.stderr
            assert b"replacement input" not in result.stdout
            assert sorted(path.name for path in state.iterdir()) == ["subject.txt"]
    finally:
        os.close(descriptor)


def test_default_state_isolation(runner: Path, root: Path) -> None:
    state_home = root / "default-state-home"
    with TuiSession(runner, state_home, explicit_state=False) as session:
        session.wait_for(b"Workflows")
        session.settle()
        session.send(b"q")
        assert session.wait_exit() == 0
        session.assert_restored()
    assert (state_home / "agent-cat" / "tui" / "agentic-run").is_dir()


def test_filter_and_responsive_browser(driver: Path, fixture: Path, root: Path) -> None:
    state = root / "filter-layout-state"
    command = [str(driver), str(fixture), str(state), str(Path.cwd())]
    with TuiSession(driver, state, rows=24, columns=80, command=command) as session:
        cursor = session.wait_for(b"Workflows")
        session.send(b"/")
        editor = session.wait_for(b"Fuzzy workflow filter", after=cursor)
        session.send(b"ctrl" + CTRL_D)
        filtered = session.wait_for(b"filter /ctrl/", after=editor)
        session.wait_for(b"control-stress", after=filtered)
        session.send(b"\t\t")
        routing = session.wait_for(b"profile fixture-profile chain", after=filtered)
        session.wait_for(b"inventory static", after=routing)
        session.send(b"q")
        assert session.wait_exit() == 0
        session.assert_restored()

def test_startup_and_input(runner: Path, root: Path) -> None:
    state = root / "input-state"
    marker = b"TUI_SECRET_BODY_slyncq\nsecond line"
    with TuiSession(runner, state) as session:
        cursor = session.wait_for(b"Workflows")
        session.settle()
        session.send(b"h")
        help_screen = session.wait_for(b"Corpus entry `example-000`", after=cursor)
        assert runs(state) == [], "workflow help created a run"
        session.send(ESCAPE)
        session.wait_for(b"browser", after=help_screen)
        session.settle()
        session.send(ESC_DOWN * 5 + ENTER)
        cursor = session.wait_for(b"standard input")
        session.send(marker)
        session.wait_for(b"TUI_SECRET_BODY_slyncq", after=cursor)
        session.send(CTRL_D)
        cursor = session.wait_for(b"execution target", after=cursor)
        session.send(b"s")
        confirmation = session.wait_for(b"launch confirmation", after=cursor)
        assert marker.splitlines()[0] not in session.output[confirmation:], "confirmation repeated an input body"
        assert runs(state) == [], "preview created a run before confirmation"
        session.send(b"n")
        session.wait_for(b"execution target", after=confirmation)
        assert runs(state) == [], "declined confirmation created a run"
        session.send(ESCAPE)
        session.wait_for(b"browser", after=confirmation)
        session.settle()
        session.send(b"q")
        assert session.wait_exit() == 0
        session.assert_restored()


def test_exact_controls_and_stress(driver: Path, fixture: Path, root: Path) -> None:
    working_directory = Path.cwd()
    live_state = root / "live-routing-state"
    live_command = [str(driver), str(fixture), str(live_state), str(working_directory)]
    with TuiSession(
        driver,
        live_state,
        command=live_command,
        extra_environment={"TUI_FIXTURE_MODE": "simple"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.settle()
        session.send(b"p")
        cursor = session.wait_for(b"Persona: work", after=cursor)
        session.send(b"l")
        confirmation = session.wait_for(b"launch confirmation", after=cursor)
        session.wait_for(b"work-model", after=confirmation)
        session.wait_for(b"Exact-input plan:", after=confirmation)
        arguments = session.wait_for(b"Exact target arguments", after=confirmation)
        session.wait_for(b"--expect-routing-fingerprint", after=arguments)
        session.wait_for(b"work-session", after=arguments)
        session.wait_for(b"fixture-provider", after=confirmation)
        session.send(b"y")
        live_header = session.wait_for(b"workflow control-stress", after=confirmation)
        session.wait_for(b"persona work", after=live_header)
        session.wait_for(b"work-model", after=live_header)
        session.wait_for(b"elapsed", after=live_header)
        terminal = session.wait_for(b"RunSucceeded", after=confirmation)
        bill = session.wait_for(b"bill 1 fresh / 1", after=live_header)
        session.wait_for(b"memo", after=bill)
        session.wait_for(b"public status", after=confirmation)
        session.wait_for(b"tool completed", after=confirmation)
        session.wait_for(b"diff --git a/x b/x", after=confirmation)
        session.wait_for(b"--- a/x", after=confirmation)
        session.wait_for(b"+++ b/x", after=confirmation)
        session.wait_for(b"@@ -1 +1 @@", after=confirmation)
        session.wait_for(b"-old", after=confirmation)
        session.wait_for(b"+new", after=confirmation)
        session.wait_for(b"todo completed/high", after=confirmation)
        session.wait_for(b"usage: 10/100", after=confirmation)
        session.wait_for(b"reasoning summary: Public summary", after=confirmation)
        save_ready = session.wait_for(b"s save/copy result", after=terminal)
        saved_result = live_state / "saved-result.json"
        session.send(b"s")
        save_prompt = session.wait_for(b"Copy the verified final JSON result", after=save_ready)
        session.send(str(saved_result).encode() + CTRL_D)
        saved = session.wait_for(b"saved verified final result", after=save_prompt)
        assert json.loads(saved_result.read_text()) == "fixture answer"
        assert mode(saved_result) == 0o600
        session.send(b"s")
        second_prompt = session.wait_for(b"Copy the verified final JSON result", after=saved)
        session.send(str(saved_result).encode() + CTRL_D)
        refused = session.wait_for(b"exists", after=second_prompt)
        session.send(ESCAPE)
        save_closed = session.wait_for(b"s save/copy result", after=refused)
        quit_completed_run(session, save_closed)
        session.assert_restored()
    live_record = runs(live_state)[0]
    live_manifest = json.loads((live_record / "supervisor-manifest.json").read_text())
    assert live_manifest["targetKind"] == "routing"
    assert live_manifest["targetArgs"] == [
        "--routing",
        "--persona", "work",
        "--offline",
        "--expect-routing-fingerprint", "f" * 64,
    ]

    for mode_name, expected_failure in [
        ("malformed", b"machine protocol decode failed"),
        ("invalid-transition", b"occurrence started before run"),
        ("no-newline", b"without a terminating newline"),
        ("count-pressure", b"exceeds 2048 occurrences"),
    ]:
        failure_state = root / f"{mode_name}-state"
        failure_command = [str(driver), str(fixture), str(failure_state), str(working_directory)]
        with TuiSession(driver, failure_state, command=failure_command, extra_environment={"TUI_FIXTURE_MODE": mode_name}) as session:
            select_workflow(session, 0)
            cursor = session.wait_for(b"execution target")
            session.send(b"s")
            cursor = session.wait_for(b"launch confirmation", after=cursor)
            session.send(b"y")
            failure = session.wait_for(expected_failure, after=cursor)
            quit_failed_run(session, failure)
            session.assert_restored()

    ignored_state = root / "ignored-cancel-state"
    ignored_command = [str(driver), str(fixture), str(ignored_state), str(working_directory)]
    with TuiSession(driver, ignored_state, command=ignored_command, extra_environment={"TUI_FIXTURE_MODE": "ignore-cancel"}) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        live = session.wait_for(b"live run", after=cursor)
        session.send(b"c")
        confirmation = session.wait_for(b"Cancel the machine child", after=live)
        started = time.monotonic()
        session.send(b"y")
        failure = session.wait_for(b"machine child exited before a terminal protocol event", after=confirmation, timeout=15)
        assert time.monotonic() - started >= 4.5
        quit_failed_run(session, failure)
        session.assert_restored()

    heartbeat_state = root / "heartbeat-failure-state"
    heartbeat_command = [str(driver), str(fixture), str(heartbeat_state), str(working_directory)]
    with TuiSession(driver, heartbeat_state, command=heartbeat_command, extra_environment={"TUI_FIXTURE_MODE": "heartbeat"}) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        live = session.wait_for(b"1 left", after=cursor)
        heartbeat_record = runs(heartbeat_state)[0]
        heartbeat_record.chmod(0o500)
        try:
            failure = session.wait_for(b"owner heartbeat failed", after=live, timeout=10)
        finally:
            heartbeat_record.chmod(0o700)
        quit_failed_run(session, failure)
        session.assert_restored()
    control_state = root / "control-state"
    control_command = [str(driver), str(fixture), str(control_state), str(working_directory)]
    with TuiSession(
        driver,
        control_state,
        rows=40,
        columns=150,
        command=control_command,
        extra_environment={"TUI_FIXTURE_MODE": "controls"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        live = session.wait_for(b"1 left", after=cursor)
        owner_path = runs(control_state)[0] / "owner.json"
        initial_heartbeat = json.loads(owner_path.read_text())["heartbeat"]
        heartbeat_deadline = time.monotonic() + 2.5
        while time.monotonic() < heartbeat_deadline:
            session.pump(0.05)
        assert json.loads(owner_path.read_text())["heartbeat"] != initial_heartbeat
        session.send(ESCAPE)
        detached = session.wait_for(b"browser", after=live)
        session.send(ENTER)
        reattached = session.wait_for(b"live run", after=detached)
        assert len(runs(control_state)) == 1, "detached workflow activation started a second child"
        session.send(b"2")
        redirected = session.wait_for(b"redirect delivered", after=reattached)
        session.wait_for(b"steer-next", after=redirected)
        session.send(b"b")
        steer = session.wait_for(b"next-boundary", after=redirected)
        session.send(b"focus fixture" + CTRL_D)
        steered = session.wait_for(b"Recovery required for occurrence 0", after=steer)
        session.send(b"f")
        terminal = session.wait_for(b"RunSucceeded", after=steered)
        session.wait_for(b"final result", after=terminal)
        quit_completed_run(session, terminal)
        session.assert_restored()
    control_record = runs(control_state)[0]
    assert (control_record / "stderr.log").read_bytes() == b""

    recovery_state = root / "fifo-recovery-state"
    recovery_command = [str(driver), str(fixture), str(recovery_state), str(working_directory)]
    with TuiSession(
        driver, recovery_state, rows=36, columns=130, command=recovery_command,
        extra_environment={"TUI_FIXTURE_MODE": "recoveries"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        pending_screen = session.wait_for(b"Recovery required for occurrence", after=cursor)
        journal = runs(recovery_state)[0] / "runtime" / "events.ndjson"
        deadline = time.monotonic() + 10
        recovery_order: list[str] = []
        while time.monotonic() < deadline:
            session.pump(0.05)
            events = [json.loads(line)["event"] for line in journal.read_text().splitlines()]
            recovery_order = [event["occurrenceId"] for event in events if event["type"] == "occurrence.recovery-pending"]
            if len(recovery_order) == 2:
                break
        assert sorted(recovery_order) == ["0", "1"], recovery_order
        first_id, second_id = recovery_order
        first = session.wait_for(f"Recovery required for occurrence {first_id}".encode(), after=cursor)
        session.send(b"j")
        session.send(b"r")
        second = session.wait_for(f"Recovery required for occurrence {second_id}".encode(), after=first)
        session.send(b"k")
        session.send(b"r")
        terminal = session.wait_for(b"RunSucceeded", after=second)
        quit_completed_run(session, terminal)
        session.assert_restored()

    person_state = root / "fifo-person-state"
    person_command = [str(driver), str(fixture), str(person_state), str(working_directory)]
    with TuiSession(
        driver,
        person_state,
        rows=36,
        columns=130,
        command=person_command,
        extra_environment={"TUI_FIXTURE_MODE": "persons"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        first = session.wait_for(b"Person answer required for occurrence 0", after=cursor)
        session.send(b"yes" + CTRL_D)
        second = session.wait_for(b"Person answer required for occurrence 1", after=first)
        session.send(b"no" + CTRL_D)
        terminal = session.wait_for(b"RunSucceeded", after=second)
        quit_completed_run(session, terminal)
        session.assert_restored()
    person_record = runs(person_state)[0]
    assert (person_record / "stderr.log").read_bytes() == b""

    retry_state = root / "person-retry-state"
    retry_command = [str(driver), str(fixture), str(retry_state), str(working_directory)]
    with TuiSession(
        driver,
        retry_state,
        command=retry_command,
        extra_environment={"TUI_FIXTURE_MODE": "person-retry"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        prompt = session.wait_for(b"Person answer required for occurrence 0", after=cursor)
        session.send(b"yes" + CTRL_D)
        rejected = session.wait_for(b"fixture schema rejection", after=prompt)
        session.send(CTRL_D)
        terminal = session.wait_for(b"RunSucceeded", after=rejected)
        quit_completed_run(session, terminal)
        session.assert_restored()
    retry_record = runs(retry_state)[0]
    assert (retry_record / "stderr.log").read_bytes() == b""

    stress_state = root / "stress-state"
    stress_command = [str(driver), str(fixture), str(stress_state), str(working_directory)]
    with TuiSession(
        driver,
        stress_state,
        rows=32,
        columns=120,
        command=stress_command,
        extra_environment={"TUI_FIXTURE_MODE": "stress"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        active = session.wait_for(b"AttemptRunning", after=cursor, timeout=30)
        session.send(b"i")
        editor = session.wait_for(b"interrupt-now", after=active)
        session.send(b"responsive under pressure" + CTRL_D)
        steered = session.wait_for(b"responsive under pressure", after=editor, timeout=30)
        deadline = time.monotonic() + 180
        maximum_rss = resident_kib(session.process.pid)
        next_rss_sample = time.monotonic() + 0.5
        terminal = -1
        while time.monotonic() < deadline:
            session.pump(0.05)
            if time.monotonic() >= next_rss_sample:
                maximum_rss = max(maximum_rss, resident_kib(session.process.pid))
                next_rss_sample = time.monotonic() + 0.5
            position = session.output.find(b"RunSucceeded", steered)
            if position >= 0:
                terminal = position + len(b"RunSucceeded")
                break
        assert terminal >= 0, "stress run did not complete"
        assert maximum_rss < 300 * 1024, f"TUI RSS grew to {maximum_rss} KiB"
        session.wait_for(b"final result", after=terminal)
        quit_completed_run(session, terminal)
        session.assert_restored()
    stress_record = runs(stress_state)[0]
    stress_events = stress_record / "runtime" / "events.ndjson"
    assert stress_events.stat().st_size > 10 * 1024 * 1024
    stress_diagnostics = (stress_record / "stderr.log").read_bytes()
    assert 0 < len(stress_diagnostics) <= 10 * 1024 * 1024
    assert b"fixture-secret-must-not-persist" not in stress_diagnostics
    assert b"<redacted diagnostic>" in stress_diagnostics

    helper_state = root / "term-resistant-helper-state"
    helper_command = [str(driver), str(fixture), str(helper_state), str(working_directory)]
    baseline_helpers = processes_matching(str(fixture))
    with TuiSession(
        driver, helper_state, command=helper_command,
        extra_environment={"TUI_FIXTURE_IGNORE_TERM": "1"},
    ) as session:
        cursor = session.wait_for(b"Workflows")
        started = time.monotonic()
        session.send(b"h")
        failure = session.wait_for(b"runner subprocess exceeded 30 seconds", after=cursor, timeout=40)
        assert 30 <= time.monotonic() - started < 38
        session.send(ESCAPE)
        browser = session.wait_for(b"browser", after=failure)
        deadline = time.monotonic() + 8
        while session.process.poll() is None and time.monotonic() < deadline:
            session.settle()
            session.send(b"q")
            session.pump(0.2)
        assert session.wait_exit() == 0
        session.assert_restored()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and processes_matching(str(fixture)) - baseline_helpers:
        time.sleep(0.05)
    assert not (processes_matching(str(fixture)) - baseline_helpers), "TERM-resistant helper was not killed and reaped"

    resistant_state = root / "term-resistant-machine-state"
    resistant_command = [str(driver), str(fixture), str(resistant_state), str(working_directory)]
    with TuiSession(
        driver, resistant_state, command=resistant_command,
        extra_environment={"TUI_FIXTURE_MODE": "term-resistant"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        session.wait_for(b"term resistant", after=cursor)
        child_pids = child_processes(session.process.pid)
        assert child_pids, "TERM-resistant machine child was not present"
        session.process.send_signal(signal.SIGTERM)
        assert session.wait_exit(timeout=12) != 0
        session.assert_restored()
    assert not any(process_exists(pid) for pid in child_pids), child_pids

    launch_signal_state = root / "launch-signal-state"
    launch_signal_command = [str(driver), str(fixture), str(launch_signal_state), str(working_directory)]
    baseline_fixture_pids = processes_matching(str(fixture))
    with TuiSession(
        driver,
        launch_signal_state,
        command=launch_signal_command,
        extra_environment={"TUI_FIXTURE_MODE": "persons"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        session.process.send_signal(signal.SIGTERM)
        assert session.wait_exit() != 0
        session.assert_restored()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and processes_matching(str(fixture)) - baseline_fixture_pids:
        time.sleep(0.05)
    assert not (processes_matching(str(fixture)) - baseline_fixture_pids), "signal during launch orphaned a machine child"

    signal_state = root / "active-signal-state"
    signal_command = [str(driver), str(fixture), str(signal_state), str(working_directory)]
    with TuiSession(
        driver,
        signal_state,
        command=signal_command,
        extra_environment={"TUI_FIXTURE_MODE": "persons"},
    ) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        session.wait_for(b"Person answer required for occurrence 0", after=cursor)
        child_pids = child_processes(session.process.pid)
        assert child_pids, "active machine child was not present"
        session.process.send_signal(signal.SIGTERM)
        assert session.wait_exit() != 0
        session.assert_restored()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(process_exists(pid) for pid in child_pids):
            time.sleep(0.05)
        assert not any(process_exists(pid) for pid in child_pids), child_pids

def processes_matching(fragment: str) -> set[int]:
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True).splitlines()
    return {int(fields[0]) for row in rows if len(fields := row.strip().split(maxsplit=1)) == 2 and fragment in fields[1]}


def child_processes(parent: int) -> list[int]:
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True).splitlines()
    return [int(fields[0]) for row in rows if len(fields := row.split()) == 2 and int(fields[1]) == parent]


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True

def test_lineage_owner_refresh(runner: Path, root: Path) -> None:
    import datetime
    import shutil

    source = next(record for record in runs(root / "launch-state")
                  if json.loads((record / "supervisor-manifest.json").read_text())["parentRunId"] is None)
    for stage in ("preview", "confirmation"):
        for key in (b"r", b"m", b"f"):
            state = root / f"owner-refresh-{stage}-{key.decode()}"
            state.mkdir(mode=0o700); (state / "runs").mkdir(mode=0o700)
            parent = state / "runs" / source.name
            shutil.copytree(source, parent)
            journal = parent / "runtime" / "events.ndjson"
            journal.write_bytes(journal.read_bytes().splitlines(keepends=True)[0])
            owner_path = parent / "owner.json"
            owner = json.loads(owner_path.read_text())
            owner["heartbeat"] = "2000-01-01T00:00:00Z"
            owner_path.write_text(json.dumps(owner))
            with TuiSession(runner, state, columns=200) as session:
                cursor = session.wait_for(b"Workflows")
                session.settle(); session.send(b"\t")
                cursor = session.wait_for(b"RunOwnerStale", after=cursor)
                if stage == "confirmation":
                    session.send(key)
                    cursor = session.wait_for(b"launch confirmation", after=cursor)
                owner["heartbeat"] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
                owner_path.write_text(json.dumps(owner))
                session.send(key if stage == "preview" else b"y")
                failure = session.wait_for(b"another live owner", after=cursor, timeout=5)
                assert runs(state) == [parent], "fresh foreign owner did not prevent child-directory creation"
                assert not child_processes(session.process.pid), "fresh foreign owner did not prevent child launch"
                session.send(ESCAPE)
                session.wait_for(b"r restart", after=failure)
                session.send(b"q")
                assert session.wait_exit() == 0
                session.assert_restored()


def test_machine_group_ownership(driver: Path, fixture: Path, root: Path) -> None:
    for scenario in ("orphan-pipes", "orphan-redirect", "term-orphan", "unread-control"):
        state = root / f"machine-group-{scenario}"
        ready = root / f"machine-descendant-{scenario}"
        command = [str(driver), str(fixture), str(state), str(root)]
        baseline = processes_matching(str(fixture))
        try:
            with TuiSession(driver, state, command=command, extra_environment={
                "TUI_FIXTURE_MODE": scenario, "TUI_FIXTURE_READY": str(ready),
            }) as session:
                select_workflow(session, 0)
                cursor = session.wait_for(b"execution target")
                session.send(b"s")
                cursor = session.wait_for(b"launch confirmation", after=cursor)
                session.send(b"y")
                if scenario.startswith("orphan-"):
                    failure = session.wait_for(b"machine child exited before a terminal", after=cursor, timeout=8)
                    assert ready.exists(), "descendant did not publish its synchronized PID"
                    quit_failed_run(session, failure)
                else:
                    marker = b"orphan ready" if scenario == "term-orphan" else b"AttemptRunning"
                    active = session.wait_for(marker, after=cursor)
                    if scenario == "unread-control":
                        session.send(b"i")
                        editor = session.wait_for(b"interrupt-now", after=active)
                        session.send(b"\x1b[200~" + (b"x" * 64 + b"\n") * 4096 + b"END-BLOCKED\x1b[201~")
                        session.wait_for(b"END-BLOCKED", after=editor, timeout=10)
                        submitted = len(session.output)
                        session.send(CTRL_D)
                        deadline = time.monotonic() + 5
                        while (not ready.exists() or not ready.read_text()) and time.monotonic() < deadline:
                            session.pump()
                        assert ready.exists() and 0 < int(ready.read_text()) < 256 * 1024, "control write did not enter the unread pipe"
                        session.settle()
                        assert b"control sent" not in session.output[submitted:], "large control unexpectedly fit the unread pipe"
                    session.process.send_signal(signal.SIGTERM)
                    assert session.wait_exit(timeout=12) != 0
                session.assert_restored()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and processes_matching(str(fixture)) - baseline:
                time.sleep(0.05)
            survivors = processes_matching(str(fixture)) - baseline
            assert not survivors, f"{scenario} left group members alive: {survivors}"
        finally:
            for pid in processes_matching(str(fixture)) - baseline:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


def test_confirmed_machine_launch(runner: Path, root: Path) -> None:
    state = root / "launch-state"
    with TuiSession(runner, state) as session:
        select_workflow(session, 1)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        confirmation = session.wait_for(b"launch confirmation", after=cursor)
        assert runs(state) == [], "plan preview crossed the launch confirmation boundary"
        session.send(b"y")
        launching = session.wait_for(b"validated run.started", after=confirmation)
        live = session.wait_for(b"live run", after=launching)
        session.wait_for(b"workflow hello", after=launching)
        session.wait_for(b"realization scripted", after=launching)
        session.wait_for(b"elapsed", after=launching)
        assert live > launching
        terminal = session.wait_for(b"RunSucceeded", after=live)
        session.wait_for(b"final result", after=terminal)
        run_name = runs(state)[0].name.encode()
        session.send(ESCAPE)
        browser = session.wait_for(b"browser", after=terminal)
        session.send(b"\t")
        refreshed = session.wait_for(run_name, after=browser)
        session.wait_for(b"lineage root", after=browser)
        session.wait_for(b"persona none", after=browser)
        session.wait_for(b"bills", after=browser)
        session.wait_for(b"result available", after=browser)
        deadline = time.monotonic() + 8
        while session.process.poll() is None and time.monotonic() < deadline:
            session.settle()
            session.send(b"q")
            session.pump(0.2)
        assert session.process.poll() is not None, "refreshed terminal run remained owned"
        assert session.wait_exit() == 0
        session.assert_restored()

    records = runs(state)
    assert len(records) == 1, records
    record = records[0]
    manifest_path = record / "supervisor-manifest.json"
    owner_path = record / "owner.json"
    stderr_path = record / "stderr.log"
    assert mode(record) == 0o700
    assert mode(record / "inputs") == 0o700
    assert mode(manifest_path) == 0o600
    assert mode(owner_path) == 0o600
    assert mode(stderr_path) == 0o600
    manifest = json.loads(manifest_path.read_text())
    assert manifest["frontendManifestVersion"] == 2
    assert manifest["runnerId"] == "agentic-run"
    assert manifest["workflow"] == "hello"
    assert manifest["targetKind"] == "scripted"
    assert manifest["targetArgs"] == ["--scripted"]
    assert manifest["personAnswering"] == "local-control"
    assert manifest["runtimeStore"] == "runtime"
    assert len(manifest["programHash"]) == 64
    events = [json.loads(line) for line in (record / "runtime" / "events.ndjson").read_text().splitlines()]
    assert events
    assert all(event["protocolVersion"] == 2 for event in events)
    assert events[0]["event"]["type"] == "run.started"
    assert events[-1]["event"]["type"] == "run.completed"
    assert stderr_path.read_bytes() == b""

    with TuiSession(runner, state) as session:
        cursor = session.wait_for(b"Workflows")
        session.settle()
        session.send(b"\t")
        cursor = session.wait_for(manifest["runId"].encode(), after=cursor)
        session.send(ENTER)
        live = session.wait_for(b"live run", after=cursor)
        session.wait_for(b"final result", after=live)
        session.send(ESCAPE)
        browser = session.wait_for(b"browser", after=live)
        session.settle()
        session.send(b"q")
        assert session.wait_exit() == 0
        session.assert_restored()

    with TuiSession(runner, state) as session:
        cursor = session.wait_for(b"Workflows")
        session.settle()
        session.send(b"\t")
        cursor = session.wait_for(manifest["runId"].encode(), after=cursor)
        session.send(b"r")
        confirmation = session.wait_for(b"restart from", after=cursor)
        session.send(b"y")
        terminal = session.wait_for(b"RunSucceeded", after=confirmation)
        quit_completed_run(session, terminal)
        session.assert_restored()
    lineage_records = runs(state)
    assert len(lineage_records) == 2, lineage_records
    child_record = next(item for item in lineage_records if item != record)
    child_manifest = json.loads((child_record / "supervisor-manifest.json").read_text())
    assert child_manifest["parentRunId"] == manifest["runId"]
    assert child_manifest["lineage"] == "restart"
    assert child_manifest["programHash"] == manifest["programHash"]
    assert (child_record / "stderr.log").read_bytes() == b""

def test_local_person_answer_and_cancel(runner: Path, root: Path) -> None:
    answer_state = root / "person-answer-state"
    with TuiSession(runner, answer_state, rows=40, columns=150) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        person = session.wait_for(b"Person answer required", after=cursor, timeout=45)
        session.send(b"no" + CTRL_D)
        terminal = session.wait_for(b"RunSucceeded", after=person, timeout=45)
        session.wait_for(b"final result", after=terminal)
        quit_completed_run(session, terminal)
        session.assert_restored()
    record = runs(answer_state)[0]
    assert mode(record / "runtime" / "person" / "questions" / "5.json") == 0o600
    events = [json.loads(line)["event"] for line in (record / "runtime" / "events.ndjson").read_text().splitlines()]
    acknowledgements = [event for event in events if event["type"] == "control.ack" and event.get("command") == "answerPerson"]
    assert [event["state"] for event in acknowledgements] == ["accepted", "delivered"]
    pending_index = next(index for index, event in enumerate(events) if event["type"] == "occurrence.person-answer-pending")
    accepted_index = events.index(acknowledgements[0])
    delivered_index = events.index(acknowledgements[1])
    completed_index = next(index for index, event in enumerate(events) if event["type"] == "occurrence.completed" and event["occurrenceId"] == "5")
    assert pending_index < accepted_index < delivered_index < completed_index
    assert events[-1]["type"] == "run.completed"

    cancel_state = root / "person-cancel-state"
    with TuiSession(runner, cancel_state, rows=40, columns=150) as session:
        select_workflow(session, 0)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        cursor = session.wait_for(b"launch confirmation", after=cursor)
        session.send(b"y")
        person = session.wait_for(b"Person answer required", after=cursor, timeout=45)
        session.send(b"c")
        confirmation = session.wait_for(b"Cancel the machine child", after=person)
        session.send(b"n")
        person_again = session.wait_for(b"Person answer required", after=confirmation)
        session.send(b"c")
        confirmation = session.wait_for(b"Cancel the machine child", after=person_again)
        session.send(b"y")
        terminal = session.wait_for(b"RunCancelledStatus", after=confirmation, timeout=20)
        quit_completed_run(session, terminal)
        session.assert_restored()
    cancel_events = [json.loads(line)["event"] for line in (runs(cancel_state)[0] / "runtime" / "events.ndjson").read_text().splitlines()]
    assert cancel_events[-1]["type"] == "run.cancelled"
    assert not any(event.get("command") == "answerPerson" for event in cancel_events)


def test_child_exec_failure(runner: Path, root: Path) -> None:
    state = root / "failure-state"
    copied_runner = root / "ephemeral-agentic-run"
    shutil.copy2(runner, copied_runner)
    copied_runner.chmod(0o700)
    with TuiSession(copied_runner, state) as session:
        select_workflow(session, 1)
        cursor = session.wait_for(b"execution target")
        session.send(b"s")
        confirmation = session.wait_for(b"launch confirmation", after=cursor)
        copied_runner.unlink()
        session.send(b"y")
        failure = session.wait_for(b"error", after=confirmation)
        session.send(ESCAPE)
        session.wait_for(b"browser", after=failure)
        session.settle()
        session.send(b"q")
        assert session.wait_exit() == 0
        session.assert_restored()
    assert runs(state) == [], "failed child setup left a discoverable partial run"


def test_signal_restoration(runner: Path, root: Path) -> None:
    state = root / "signal-state"
    with TuiSession(runner, state) as session:
        session.wait_for(b"Workflows")
        session.settle()
        session.process.send_signal(signal.SIGTERM)
        status = session.wait_exit()
        assert status != 0
        session.assert_restored()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("runner", type=Path)
    parser.add_argument("--driver", type=Path)
    parser.add_argument("--fixture", type=Path, default=Path("test/tui_fixture_runner.py"))
    arguments = parser.parse_args()
    runner = arguments.runner.resolve()
    with tempfile.TemporaryDirectory(prefix="agent-cat-tui-probe-") as directory:
        root = Path(directory)
        test_non_tty(runner)
        if arguments.driver is not None:
            test_spawn_descriptors(arguments.driver.resolve(), root)
        test_startup_and_input(runner, root)
        test_default_state_isolation(runner, root)
        test_state_root_confinement(runner, root)
        test_catalogue_fifo(runner, root)
        test_child_state_anchor(runner, root)
        test_confirmed_machine_launch(runner, root)
        test_lineage_owner_refresh(runner, root)
        if arguments.driver is not None:
            test_helper_ownership(arguments.driver.resolve(), arguments.fixture.resolve(), root)
            test_interrupted_helper_shutdown(arguments.driver.resolve(), arguments.fixture.resolve(), root)
            test_machine_group_ownership(arguments.driver.resolve(), arguments.fixture.resolve(), root)
            test_filter_and_responsive_browser(arguments.driver.resolve(), arguments.fixture.resolve(), root)
            test_exact_controls_and_stress(arguments.driver.resolve(), arguments.fixture.resolve(), root)
        test_local_person_answer_and_cancel(runner, root)
        test_child_exec_failure(runner, root)
        test_signal_restoration(runner, root)
    print("tui probe: all checks passed")


if __name__ == "__main__":
    main()
