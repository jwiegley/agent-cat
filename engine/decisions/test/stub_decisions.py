#!/usr/bin/env python3
"""A deterministic decisions endpoint on the loopback interface, for testing.

The stub speaks both request dialects of `Agentic.Decisions.Wire`. A POST to
`/system-one` is read as a System One body, with `model`, `state` and a
`questions` object that holds one question under the key `decision`. A POST to
`/openai` is read as an OpenAI body, with `model`, `input` and a `questions`
array that holds one question named `decision`.

The model that a request names chooses what the stub does:

    stub-busy        HTTP 529, which the engine reads as a transport failure
    stub-refusing    an answer of type `refusal`, a protocol failure
    any other model  the distribution that ANSWERS holds for the question

ANSWERS is keyed by the first line of the question's instructions, so one
table answers both dialects. An OpenAI yes/no question carries the meanings of
its answers after the first line, and the key ignores them. A question whose
instructions the table does not hold is answered with HTTP 400, and the stub
never invents a distribution.

Usage:

    stub_decisions.py PORT_FILE LOG_FILE PARENT_PID

The stub binds 127.0.0.1 on a port that the system chooses, writes the port
to PORT_FILE, and appends one JSON line to LOG_FILE for each request it
receives, with the dialect, the model and the first line of the instructions.
It refuses a connection that does not come from a loopback address. It exits
when the process PARENT_PID no longer exists, and in any case after ten
minutes, so a gate that fails to stop it does not leave it running.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT_FILE = Path(sys.argv[1])
LOG_FILE = Path(sys.argv[2])
PARENT_PID = int(sys.argv[3])
LIFETIME_SECONDS = 600

# The probability of each option, in option order, keyed by the first line of
# the instructions. A yes/no question holds the probability of True alone.
ANSWERS: dict[str, object] = {
    "Which team should handle this ticket?": [
        ("Billing", 0.88),
        ("Technical", 0.11),
        ("Account", 0.01),
        ("Other", 0),
    ],
    "The customer explicitly asks for money back.": 0.96,
    "How urgent is this ticket?": [
        ("Routine", 0.1),
        ("Soon", 0.7),
        ("Urgent", 0.2),
    ],
}

LOG_LOCK = threading.Lock()


def log(entry: dict[str, object]) -> None:
    with LOG_LOCK:
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")


def usage() -> dict[str, object]:
    return {"input_tokens": 1, "output_tokens": 0}


def system_one_answer(question: dict[str, object], key: str) -> dict[str, object]:
    kind = question.get("type")
    entry = ANSWERS[key]
    if kind == "noul":
        return {"type": "noul", "noul": entry}
    if kind == "choice":
        return {"type": "choice", "probabilities": {name: p for name, p in entry}}
    if kind == "score":
        return {"type": "score", "probabilities": {str(index): p for index, (_, p) in enumerate(entry)}}
    raise ValueError(f"no answer of type {kind!r}")


def openai_answer(question: dict[str, object], key: str) -> dict[str, object]:
    kind = question.get("type")
    entry = ANSWERS[key]
    if kind == "predicate":
        return {"type": "predicate", "name": "decision", "probability": entry}
    if kind == "choice":
        return {
            "type": "choice",
            "name": "decision",
            "probabilities": [{"value": name, "probability": p} for name, p in entry],
        }
    if kind == "score":
        return {
            "type": "score",
            "name": "decision",
            "probabilities": [
                {"value": index, "label": name, "probability": p} for index, (name, p) in enumerate(entry)
            ],
        }
    raise ValueError(f"no answer of type {kind!r}")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def verify_request(self, _request: object, client_address: object) -> bool:
        host = client_address[0] if isinstance(client_address, tuple) else ""
        return host in ("127.0.0.1", "::1")

    def handle_error(self, _request: object, _client_address: object) -> None:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "agent-cat-decisions-fixture"
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def send_json(self, value: object, status: int = 200) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            self.send_json({"error": {"message": "the body is not JSON"}}, status=400)
            return
        if self.path == "/system-one":
            dialect = "system-one"
            questions = body.get("questions") or {}
            question = questions.get("decision") if isinstance(questions, dict) else None
        elif self.path == "/openai":
            dialect = "openai"
            questions = body.get("questions") or []
            question = questions[0] if isinstance(questions, list) and len(questions) == 1 else None
        else:
            self.send_json({"error": {"message": "no such path"}}, status=404)
            return
        if not isinstance(question, dict):
            self.send_json({"error": {"message": "the body asks no single question"}}, status=400)
            return
        model = body.get("model")
        key = str(question.get("instructions", "")).split("\n", 1)[0]
        log({"dialect": dialect, "model": model, "instructions": key, "type": question.get("type")})

        if model == "stub-busy":
            self.send_json({"error": {"code": 529, "message": "overloaded"}}, status=529)
            return
        answer: dict[str, object]
        if model == "stub-refusing":
            answer = {"type": "refusal"}
        elif key not in ANSWERS:
            self.send_json({"error": {"message": "no canned answer for these instructions"}}, status=400)
            return
        else:
            try:
                answer = (system_one_answer if dialect == "system-one" else openai_answer)(question, key)
            except (TypeError, ValueError) as why:
                self.send_json({"error": {"message": str(why)}}, status=400)
                return
        if dialect == "system-one":
            self.send_json({"model": model, "answers": {"decision": answer}, "usage": usage()})
        else:
            self.send_json({"model": model, "answers": [answer], "usage": usage()})


def watch_parent(server: Server) -> None:
    deadline = time.monotonic() + LIFETIME_SECONDS
    while time.monotonic() < deadline:
        try:
            os.kill(PARENT_PID, 0)
        except ProcessLookupError:
            break
        except PermissionError:
            pass
        time.sleep(0.2)
    server.shutdown()


def main() -> None:
    server = Server(("127.0.0.1", 0), Handler)
    threading.Thread(target=watch_parent, args=(server,), daemon=True).start()
    temporary = PORT_FILE.with_suffix(".tmp")
    temporary.write_text(f"{server.server_address[1]}\n", encoding="ascii")
    temporary.replace(PORT_FILE)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
