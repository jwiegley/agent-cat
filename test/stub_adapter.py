#!/usr/bin/env python3
"""A deterministic ACP adapter, for testing the transport and nothing else.

Line-delimited JSON-RPC 2.0 on stdin/stdout, implementing exactly the calls
`Agentic/Core/Acp.lean` makes: `initialize`, `session/new`, `session/set_mode`,
`session/prompt`, and the `session/cancel` notification.

The answers are canned and keyed on substrings of the prompt, so that the
workload of `example/HardenPatch.lean` runs end to end with no model and no
network:

    "correct?" / "secure?" / "simpler?"  -> APPROVE
    "Apply this patch?"                  -> yes   (no, with --refuse)
    "Apply:"                             -> ok
    "Draft"                              -> a fixed patch
    "style guide"                        -> a fixed guide
    anything else                        -> a fixed refusal

Order matters: the review prompts embed the guide and the patch, so the most
specific key must be tested first. No canned answer contains a key.

`--refuse` is the one variant: the owner answers *no* to the consent question,
which is the hypothesis of `Harden.no_ack_of_refused` made out of bytes. The
apply question is then never put, so the "Apply:" answer is unreachable and the
run bills six consultations instead of seven (`Harden.bill_refuse_demo`).

Two things beyond the happy path are exercised on purpose:

  * every answer is streamed as TWO `agent_message_chunk` notifications, so a
    client that returns only the last chunk fails the smoke test;
  * the "Apply:" turn first sends a `session/request_permission` REQUEST to the
    client and reads its reply, so the client's handling of an agent-initiated
    request (ours answers -32601) is on the tested path.

Diagnostics go to stderr, which the client inherits; stdout carries protocol
and nothing else.
"""

import json
import sys

PROTOCOL_VERSION = 1
SESSION_ID = "sess_stub_0001"

GUIDE = (
    "House style: two-space indent, no tabs, every public name documented, "
    "and failures returned rather than raised."
)

PATCH = (
    "--- a/src/parse.c\n"
    "+++ b/src/parse.c\n"
    "@@\n"
    "-  char buf[64]; strcpy(buf, input);\n"
    "+  char buf[64]; snprintf(buf, sizeof buf, \"%s\", input);\n"
)

REFUSAL = "I have nothing canned for that."

# Whether the owner withholds consent. A flag rather than an environment
# variable because `Acp.Config` can set the child's argv and cannot set its
# environment.
CONSENT = "no" if "--refuse" in sys.argv[1:] else "yes"

# (substring, answer), most specific first.
ANSWERS = [
    ("correct?", "APPROVE"),
    ("secure?", "APPROVE"),
    ("simpler?", "APPROVE"),
    ("Apply this patch?", CONSENT),
    ("Apply:", "ok"),
    ("Draft", PATCH),
    ("style guide", GUIDE),
]


def answer_for(text):
    for key, value in ANSWERS:
        if key in text:
            return key, value
    return None, REFUSAL


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def note(msg):
    sys.stderr.write("stub_adapter: " + msg + "\n")
    sys.stderr.flush()


def read_message():
    line = sys.stdin.readline()
    if line == "":
        return None
    if line.strip() == "":
        return read_message()
    return json.loads(line)


def result(rid, value):
    send({"jsonrpc": "2.0", "id": rid, "result": value})


def error(rid, code, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


def chunk(text):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": SESSION_ID,
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "messageId": "msg_stub",
                "content": {"type": "text", "text": text},
            },
        },
    })


def thought(text):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": SESSION_ID,
            "update": {
                "sessionUpdate": "agent_thought_chunk",
                "content": {"type": "text", "text": text},
            },
        },
    })


def ask_permission():
    """An agent-initiated request; the reply is read and ignored."""
    send({
        "jsonrpc": "2.0",
        "id": "stub-perm-1",
        "method": "session/request_permission",
        "params": {
            "sessionId": SESSION_ID,
            "toolCall": {"toolCallId": "call_stub_1", "title": "apply the patch"},
            "options": [
                {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                {"optionId": "deny", "name": "Deny", "kind": "reject_once"},
            ],
        },
    })
    reply = read_message()
    note("permission reply: " + json.dumps(reply))


def prompt_text(params):
    parts = []
    for block in params.get("prompt", []):
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "".join(parts)


def handle_prompt(rid, params):
    text = prompt_text(params)
    key, reply = answer_for(text)
    note("prompt matched %r" % (key,))
    if key == "Apply:":
        ask_permission()
    thought("deciding")
    half = len(reply) // 2
    chunk(reply[:half])
    chunk(reply[half:])
    result(rid, {"stopReason": "end_turn"})


def main():
    while True:
        msg = read_message()
        if msg is None:
            return 0
        method = msg.get("method")
        rid = msg.get("id")
        if method is None:
            continue  # a reply to one of our requests; nothing to do here.
        if rid is None:
            if method == "session/cancel":
                note("cancelled")
            continue  # notifications are never answered.
        if method == "initialize":
            result(rid, {
                "protocolVersion": PROTOCOL_VERSION,
                "agentCapabilities": {"loadSession": False},
                "agentInfo": {"name": "stub_adapter", "version": "1.0.0"},
                "authMethods": [],
            })
        elif method == "session/new":
            note("cwd " + str(msg.get("params", {}).get("cwd")))
            result(rid, {"sessionId": SESSION_ID})
        elif method == "session/set_mode":
            result(rid, {})
        elif method == "session/prompt":
            handle_prompt(rid, msg.get("params", {}))
        else:
            error(rid, -32601, "stub_adapter implements no " + method)


if __name__ == "__main__":
    sys.exit(main())
