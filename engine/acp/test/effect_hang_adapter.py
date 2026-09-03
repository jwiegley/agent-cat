#!/usr/bin/env python3
"""ACP fixture that hangs once the workflow reaches its effect turn."""

import json
import sys

session_id = "00000000-0000-0000-0000-000000000125"
prompts = 0


def send(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": False}}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id}})
    elif method == "session/prompt":
        prompts += 1
        if prompts < 3:
            text = "sunrise" if prompts == 1 else "Good morning"
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
            send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})
    elif method == "session/cancel":
        break
