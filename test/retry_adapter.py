#!/usr/bin/env python3
"""Deterministic ACP fixture that needs an interactive retry after its budget."""

import json
import sys

session_id = "00000000-0000-0000-0000-000000000124"
prompts = 0


def send(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def result(request_id, value):
    send({"jsonrpc": "2.0", "id": request_id, "result": value})


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        result(request_id, {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": False},
            "agentInfo": {"name": "retry-fixture", "version": "1"},
        })
    elif method == "session/new":
        result(request_id, {"sessionId": session_id})
    elif method == "session/prompt":
        prompts += 1
        answer = "maybe" if prompts <= 2 else '{"priority":1,"steps":["retry"],"title":"Recovered"}'
        send({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": answer},
                },
            },
        })
        result(request_id, {"stopReason": "end_turn"})
