#!/usr/bin/env python3
"""Deterministic ACP fixture that completes its first prompt only after steering."""

import json
import os
from pathlib import Path
import selectors
import sys
import time
import uuid

session_id = str(uuid.UUID("00000000-0000-0000-0000-000000000123"))
pending = None
pending_flag = False
prompt_count = 0
barriers = [arg.split("=", 1)[1] for arg in sys.argv[1:] if arg.startswith("--completion-barrier=")]
if len(barriers) > 1:
    raise RuntimeError("duplicate completion barrier")
completion_barrier = Path(barriers[0]) if barriers else None
pending_deadline = None


def send(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def result(request_id, value):
    send({"jsonrpc": "2.0", "id": request_id, "result": value})


def answer(request_id, text):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": session_id,
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text},
            },
        },
    })
    result(request_id, {"stopReason": "end_turn"})


def messages():
    global pending, pending_deadline
    if completion_barrier is None:
        yield from sys.stdin
        return
    buffered = b""
    with selectors.DefaultSelector() as selector:
        selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
        while True:
            if pending is not None:
                if completion_barrier.exists():
                    original, pending = pending, None
                    answer(original, "yes" if pending_flag else '{"priority":1,"steps":["steered"],"title":"Steered"}')
                elif time.monotonic() >= pending_deadline:
                    raise RuntimeError("completion barrier expired")
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                yield line
            if not selector.select(0.05):
                continue
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                if buffered:
                    raise RuntimeError("partial ACP fixture input")
                return
            buffered += chunk
            if len(buffered) > 67108864:
                raise RuntimeError("ACP fixture input exceeded bound")


for line in messages():
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params", {})
    if method == "initialize":
        result(request_id, {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": False, "agentCat": {"steer": True}},
            "agentInfo": {"name": "steer-fixture", "version": "1"},
        })
    elif method == "session/new":
        result(request_id, {"sessionId": session_id})
    elif method == "session/prompt":
        prompt_count += 1
        if prompt_count == 1:
            pending = request_id
            pending_deadline = time.monotonic() + 60
            text = "".join(block.get("text", "") for block in params.get("prompt", []) if block.get("type") == "text")
            pending_flag = "Apply this patch?" in text
            if completion_barrier is not None and not pending_flag:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": session_id, "update": {"sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "partial "}}}})
        else:
            answer(request_id, "answer")
    elif method == "session/steer":
        accepted = pending is not None
        if accepted and completion_barrier is not None:
            pending_deadline = time.monotonic() + 60
        send({"jsonrpc": "2.0", "method": "session/steer_ack", "params": {"steerId": params.get("steerId"), "accepted": accepted}})
        if accepted and completion_barrier is None:
            answer(pending, "yes" if pending_flag else '{"priority":1,"steps":["steered"],"title":"Steered"}')
            pending = None
    elif method == "session/cancel" and pending is not None:
        result(pending, {"stopReason": "cancelled"})
        pending = None
