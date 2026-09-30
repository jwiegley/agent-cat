#!/usr/bin/env python3
"""ACP fixture that holds each prompt open for a fixed time.

The first argument is the hold in seconds. A prompt that is still open when the
hold ends is answered "yes". A session/cancel notification ends the open prompt
at once with stopReason "cancelled", as a real adapter ends a cancelled turn.
"""

import json
import selectors
import sys
import time

hold = float(sys.argv[1]) if len(sys.argv) > 1 else 3600.0
session_id = "00000000-0000-0000-0000-000000000126"
pending = None
deadline = None


def send(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def result(request_id, value):
    send({"jsonrpc": "2.0", "id": request_id, "result": value})


def answer(request_id, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": session_id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}},
    }})
    result(request_id, {"stopReason": "end_turn"})


def handle(message):
    global pending, deadline
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        result(request_id, {"protocolVersion": 1, "agentCapabilities": {"loadSession": False}})
    elif method == "session/new":
        result(request_id, {"sessionId": session_id})
    elif method == "session/prompt":
        pending = request_id
        deadline = time.monotonic() + hold
    elif method == "session/cancel" and pending is not None:
        result(pending, {"stopReason": "cancelled"})
        pending = None
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "method not found"}})


buffered = b""
with selectors.DefaultSelector() as selector:
    selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
    while True:
        if pending is not None and time.monotonic() >= deadline:
            answer(pending, "yes")
            pending = None
        if not selector.select(0.05):
            continue
        chunk = sys.stdin.buffer.read1(65536)
        if not chunk:
            break
        buffered += chunk
        while b"\n" in buffered:
            line, buffered = buffered.split(b"\n", 1)
            if line.strip():
                handle(json.loads(line))
