#!/usr/bin/env python3
"""Deterministic ACP fixture that completes its first prompt only after steering."""

import json
import sys
import uuid

session_id = str(uuid.UUID("00000000-0000-0000-0000-000000000123"))
pending = None
prompt_count = 0


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


for line in sys.stdin:
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
        else:
            answer(request_id, "answer")
    elif method == "session/steer":
        accepted = pending is not None
        send({"jsonrpc": "2.0", "method": "session/steer_ack", "params": {"steerId": params.get("steerId"), "accepted": accepted}})
        if accepted:
            answer(pending, '{"priority":1,"steps":["steered"],"title":"Steered"}')
            pending = None
    elif method == "session/cancel" and pending is not None:
        result(pending, {"stopReason": "cancelled"})
        pending = None
