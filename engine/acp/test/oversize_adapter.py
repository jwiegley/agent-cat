#!/usr/bin/env python3
"""ACP fixture that sends one protocol line beyond the 1 MiB bound."""

import json
import sys

session_id = "00000000-0000-0000-0000-000000000125"


def send(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": False}, "agentInfo": {"name": "oversize-fixture", "version": "1"}}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id}})
    elif method == "session/prompt":
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "x" * (1024 * 1024)}}}})
