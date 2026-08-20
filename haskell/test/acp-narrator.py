#!/usr/bin/env python3
"""An ACP adapter that narrates itself into the answer stream, and tells on the
client if the narration comes back.

`agent-cat/test/stub_adapter.py` is a *conforming* adapter and this behaviour is
not conformance: it is `claude-agent-acp` announcing a model substitution by
writing a sentence about its own routing into the turn, as an ordinary
`agent_message_chunk`, in the model's voice, because the ACP schema carries no
field for it. Measured verbatim (`doc/research/pal-subsumption`, and the issue
`acat-owa`):

    **Model fallback:** claude-fable-5 declined this request (cyber); retried
    with claude-opus-4-8. The session will continue on claude-opus-4-8.

So this is a *proxy*, not a second stub: it speaks to the real one over pipes
and adds exactly two things, which are the two halves of the defect.

  1. **It narrates.** Before each `session/prompt` reaches the stub, one extra
     `agent_message_chunk` carrying the banner is written toward the client. It
     is emitted *before* the prompt is forwarded, so the stub has not begun
     answering and the banner is necessarily the head of the turn — the ordering
     is a fact about the sequence and not a race that usually goes our way.

  2. **It watches.** Every prompt going the other way is inspected for the
     banner and the result is printed on stderr, which the client inherits. That
     is the assertion no client-side log can make: the banner rode into a
     downstream prompt, or it did not. In the measured run it rode into five —
     the three reviewers, the revision and the consent — because it was part of
     the answer the table recorded.

The gate is `ci/acp.sh` scenario 16. A client that separates the banner from the
answer (`Agentic.Exec.splitTransportNarration`) settles the flagship in 7/7 with
every prompt clean; one that does not reads a reviewer's `APPROVE` under the
banner as an objection, buys a revision round, and cannot read the owner's `yes`
at all.

Not a general test double: the stub speaks the protocol and this only puts
somebody else's voice in front of it. Sibling of `test/acp-misbehave.sh`, which
does the same job for a protocol nobody speaks.
"""

import json
import os
import subprocess
import sys
import threading

# The marker the client's pattern is anchored on (`Exec.transportBanners`), and
# the whole measured sentence. Separate, because the marker is what a downstream
# prompt is searched for: a client that stripped the sentence but left the label
# would pass a search for the sentence and fail the one that matters.
MARKER = "**Model fallback:**"
BANNER = (
    MARKER + " claude-fable-5 declined this request (cyber); "
    "retried with claude-opus-4-8. The session will continue on "
    "claude-opus-4-8."
)

# The stub, by default the one this file sits beside: `haskell/test/` is one
# level down from the repository root and the stub is under `test/` there.
DEFAULT_STUB = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "test",
                 "stub_adapter.py"))

# stdout is shared by both directions — the stub's replies and our injected
# chunks — and a JSON-RPC frame is a line, so a half-written one is a protocol
# violation rather than a slow write.
OUT = threading.Lock()


def note(msg):
    sys.stderr.write("acp-narrator: " + msg + "\n")
    sys.stderr.flush()


def emit(obj):
    line = (json.dumps(obj) + "\n").encode("utf-8")
    with OUT:
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()


def forward(line):
    with OUT:
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()


def prompt_text(params):
    return "".join(
        block.get("text", "")
        for block in params.get("prompt", [])
        if block.get("type") == "text")


def pump_client(sink):
    """Client -> stub, narrating each turn and inspecting each prompt."""
    puts = 0
    for line in sys.stdin.buffer:
        try:
            msg = json.loads(line)
        except ValueError:
            msg = {}
        if msg.get("method") == "session/prompt":
            puts += 1
            params = msg.get("params", {})
            if MARKER in prompt_text(params):
                note("prompt %d CARRIED THE TRANSPORT BANNER downstream" % puts)
            else:
                note("prompt %d carried no transport banner" % puts)
            # The transport's own voice, first, while the request is outstanding.
            emit({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": params.get("sessionId"),
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": BANNER + "\n\n"},
                        "messageId": "msg_narrator_%04d" % puts,
                    },
                },
            })
        sink.write(line)
        sink.flush()
    # EOF from the client is how a conforming adapter is told the conversation is
    # over; pass it on rather than making the stub wait to be killed.
    try:
        sink.close()
    except IOError:
        pass


def main():
    argv = sys.argv[1:]
    stub = argv[0] if argv else DEFAULT_STUB
    child = subprocess.Popen(
        [sys.executable, stub] + argv[1:],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    # Both pipes exist because both were asked for on the line above, but that
    # is an argument a reader has to make and a type checker cannot: `Popen`
    # types them as optional whatever it was passed. Named here once, so the
    # proxy's two halves take pipes rather than a process and neither has to
    # re-make the argument.
    to_stub, from_stub = child.stdin, child.stdout
    if to_stub is None or from_stub is None:
        note("the stub was started without its pipes; nothing to proxy")
        child.kill()
        return 1
    threading.Thread(target=pump_client, args=(to_stub,), daemon=True).start()
    for line in from_stub:
        forward(line)
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
