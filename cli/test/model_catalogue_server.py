#!/usr/bin/env python3
"""Deterministic loopback-only model catalogue fixture; never records headers."""

from __future__ import annotations

import json
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PORT_FILE = Path(sys.argv[1])
COUNT_FILE = Path(sys.argv[2])
CONTROL_FILE = Path(sys.argv[3])
CERT_FILE = Path(sys.argv[4]) if len(sys.argv) > 4 else None
KEY_FILE = Path(sys.argv[5]) if len(sys.argv) > 5 else None
COUNT = 0


def write_count() -> None:
    COUNT_FILE.write_text(f"{COUNT}\n", encoding="ascii")


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, _request: object, _client_address: object) -> None:
        pass

class Handler(BaseHTTPRequestHandler):
    server_version = "agent-cat-fixture"
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

    def do_GET(self) -> None:
        global COUNT
        COUNT += 1
        write_count()
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        using_tls = isinstance(self.connection, ssl.SSLSocket)
        if CONTROL_FILE.exists() and CONTROL_FILE.read_text(encoding="ascii").strip() == "fail":
            self.send_json({"error": "controlled failure"}, status=503)
            return

        if parsed.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/openai")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if parsed.path == "/slow":
            time.sleep(0.35)
            self.send_json({"object": "list", "data": []})
            return
        if parsed.path == "/large":
            self.send_json({"object": "list", "data": [{"id": "x" * 2048}]})
            return
        if parsed.path == "/chunked-large":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for _ in range(8):
                    chunk = b"x" * 64
                    self.wfile.write(f"{len(chunk):X}\r\n".encode("ascii") + chunk + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except BrokenPipeError:
                pass
            return
        if parsed.path == "/malformed":
            body = b"{not-json"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                pass
            return
        if parsed.path == "/status":
            self.send_json({"error": "fixture"}, status=503)
            return
        if parsed.path == "/duplicate":
            self.send_json({"object": "list", "data": [{"id": "same"}, {"id": "same"}]})
            return
        if parsed.path == "/too-many":
            self.send_json({"object": "list", "data": [{"id": f"model-{index}"} for index in range(10001)]})
            return
        if parsed.path == "/large-id":
            self.send_json({"object": "list", "data": [{"id": "x" * 513}]})
            return
        if parsed.path == "/bad-created":
            self.send_json({"object": "list", "data": [{"id": "model", "created": 1.5}]})
            return
        if parsed.path == "/openai":
            authorization = self.headers.get("Authorization")
            if authorization != "Bearer fixture-secret" and (using_tls or authorization is not None):
                self.send_json({"error": "unauthorized"}, status=401)
                return
            self.send_json(
                {
                    "object": "list",
                    "data": [
                        {"id": "gpt-sol-z", "created": 1769904000, "owned_by": "fixture"},
                        {"id": "gpt-sol-old", "created": 1767225600},
                        {"id": "gpt-sol-a", "created": 1769904000},
                        {"id": "stub-default", "created": 1767225600},
                    ],
                    "unknown": "accepted",
                }
            )
            return
        if parsed.path.startswith("/anthropic"):
            api_key = self.headers.get("x-api-key")
            if (api_key != "fixture-secret" and (using_tls or api_key is not None)) or self.headers.get("anthropic-version") != "2023-06-01":
                self.send_json({"error": "unauthorized"}, status=401)
                return
            if query.get("limit") != ["1000"]:
                self.send_json({"error": "missing limit"}, status=400)
                return
            cursor = query.get("after_id", [None])[0]
            if parsed.path == "/anthropic-missing-bounds":
                self.send_json(
                    {
                        "data": [{"id": "claude-unbounded", "created_at": "2026-01-01T00:00:00Z"}],
                        "has_more": False,
                    }
                )
                return
            if parsed.path == "/anthropic-pages":
                number = 1 if cursor is None else int(cursor.removeprefix("page-")) + 1
                identifier = f"page-{number}"
                self.send_json(
                    {
                        "data": [{"id": identifier, "created_at": "2026-01-01T00:00:00Z"}],
                        "has_more": True,
                        "first_id": identifier,
                        "last_id": identifier,
                    }
                )
                return
            if parsed.path == "/anthropic-loop":
                self.send_json(
                    {
                        "data": [{"id": "claude-loop", "created_at": "2026-01-01T00:00:00Z"}],
                        "has_more": True,
                        "first_id": "claude-loop",
                        "last_id": "claude-loop",
                    }
                )
                return
            if cursor is None:
                self.send_json(
                    {
                        "data": [{"id": "claude-old", "created_at": "2026-01-01T00:00:00Z"}],
                        "has_more": True,
                        "first_id": "claude-old",
                        "last_id": "claude-old",
                    }
                )
            else:
                tail = [
                    {"id": "claude-z", "created_at": "2026-02-01T00:00:00Z"},
                    {"id": "claude-a", "created_at": "2026-02-01T00:00:00Z"},
                ]
                if parsed.path == "/anthropic-duplicate":
                    tail.append({"id": "claude-old", "created_at": "2026-01-01T00:00:00Z"})
                self.send_json(
                    {
                        "data": tail,
                        "has_more": False,
                        "first_id": tail[0]["id"],
                        "last_id": tail[-1]["id"],
                        "unknown": True,
                    }
                )
            return

        self.send_json({"error": "not found"}, status=404)


server = QuietThreadingHTTPServer(("127.0.0.1", 0), Handler)
if CERT_FILE is not None and KEY_FILE is not None:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(CERT_FILE, KEY_FILE)
    server.socket = context.wrap_socket(server.socket, server_side=True)
PORT_FILE.write_text(f"{server.server_address[1]}\n", encoding="ascii")
write_count()
server.serve_forever()
