#!/usr/bin/env python3
"""Exercise shared codecs against real private frontend sessions and replies."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from frontend_session_probe import Session, capability_discovery, encode


def main():
    runner, checker = (Path(value).resolve(strict=True) for value in sys.argv[1:])

    def codec(kind, body, approval=None):
        arguments = [str(checker), "--frontend-codec-test", kind]
        if approval is not None:
            arguments.append(approval)
        response = subprocess.run(arguments, input=body, capture_output=True, timeout=30)
        assert response.returncode == 0, (kind, response.stderr)
        assert b"\n" not in response.stdout, "shared encoder must leave framing to the caller"
        assert json.loads(response.stdout) == json.loads(body), kind
        return response.stdout

    try:
        with tempfile.TemporaryDirectory(prefix="agent-cat-frontend-codecs-") as temporary:
            root = Path(temporary).resolve()
            wrapper, prefix, _ = capability_discovery(runner, root)
            codec("capabilities", (root / "capabilities/capabilities.ndjson").read_bytes())
            invocation = {"version": 1, "runnerAlias": "work", "executable": str(wrapper), "prefixArgs": prefix}
            text = "\ufeff雪\r\ntrailing\n"
            for mode in ["literal", "transport", "file"]:
                directory = root / mode
                directory.mkdir()
                supplied = {"name": "input", "source": mode}
                if mode == "file":
                    source = directory / "input.txt"
                    source.write_bytes(text.encode("utf-8"))
                    supplied["path"] = str(source)
                else:
                    supplied["value"] = text
                request = {"version": 1, "operation": "prepare", "workflow": "prompt-source",
                           "stateDirectory": str(directory / "state"), "targetArguments": ["--scripted"],
                           "personAnswering": "local-control", "inputs": [supplied], "invocation": invocation}
                session = Session(runner, directory, "", [], request=request,
                                  command_prefix=[str(wrapper), *prefix], request_bytes=codec("request", encode(request)))
                codec("prepared", session.preview_frame)
                expected = text.encode("utf-8") + (b"\n" if mode == "literal" else b"")
                assert session.preview["inputs"] == [{"name": "input", "bytes": str(len(expected)),
                                                      "sha256": hashlib.sha256(expected).hexdigest()}]
                if mode == "file":
                    source.write_bytes(b"changed after preparation")
                    decision = session.decision("start")
                else:
                    decision = session.decision("discard")
                session.send_raw(codec("decision", encode(decision), session.preview["approvalId"]) + b"\n")
                events = session.finish()
                if mode != "file":
                    assert events == []
                    continue
                assert events, "approved file-backed session produced no runtime observations"
                assert (session.run / "inputs/0.txt").read_bytes() == expected
                for operation in ["restart", "resume", "fork"]:
                    lineage = {"version": 1, "operation": "prepare-lineage", "stateDirectory": str(session.root),
                               "parentRunId": session.preview["runId"], "lineage": operation, "edits": [],
                               "personAnswering": "local-control", "invocation": invocation}
                    derived = Session(runner, directory, "", [], request=lineage,
                                      command_prefix=[str(wrapper), *prefix], request_bytes=codec("request", encode(lineage)))
                    codec("prepared", derived.preview_frame)
                    assert derived.preview["inputs"] == session.preview["inputs"]
                    discard = derived.decision("discard")
                    derived.send_raw(codec("decision", encode(discard), derived.preview["approvalId"]) + b"\n")
                    assert derived.finish() == []
    finally:
        for session in Session.active:
            if session.process.poll() is None:
                session.process.terminate()
                session.process.wait(timeout=10)
            for pipe in [session.process.stdin, session.process.stdout, session.process.stderr]:
                if not pipe.closed:
                    pipe.close()
    print("shared frontend codecs: real capabilities, preparation/lineage, exact invocation, Unicode/CRLF capture, "
          "start/discard and frozen file bytes passed")


if __name__ == "__main__":
    main()
