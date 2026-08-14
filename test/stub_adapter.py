#!/usr/bin/env python3
"""A deterministic ACP adapter, for testing the transport and nothing else.

Line-delimited JSON-RPC 2.0 on stdin/stdout, implementing exactly the calls
`Agentic/Core/Acp.lean` makes: `initialize`, `session/new`, `session/set_mode`,
`session/set_config_option`, `session/prompt`, and the `session/cancel`
notification.

**The wire shapes here are copied from real transcripts**, not invented. Every
response body, every `session/update` kind, the integer ids of agent-initiated
requests, the option list of a permission request and the 39 KB single-line
command catalogue are reproductions of what
`@agentclientprotocol/claude-agent-acp 0.64.0` (ACP SDK 1.3.0) and `codex-acp
0.13.0` were measured sending. A test double whose shapes are easier than the
real thing's tests the client against a protocol nobody speaks; the specific
ways this file used to be too easy are noted at each place below.

The answers are canned and keyed on substrings of the prompt, so that the
workload of `example/HardenPatch.lean` runs end to end with no model and no
network:

    "correct?" / "secure?" / "simpler?"  -> APPROVE
    "Apply this patch?"                  -> yes   (no, with --refuse)
    "Apply:"                             -> DONE, and the patch is applied
    "Draft"                              -> a fixed patch
    "style guide"                        -> a fixed guide
    anything else                        -> a fixed refusal

Order matters: the review prompts embed the guide and the patch, so the most
specific key must be tested first. No canned answer contains a key.

**The act writes a file, because saying DONE is not doing anything.** `Decode
.ack` is total and carries no information, so a stub that only replied `DONE`
would let a harness "check" an act by checking that something replied — which is
exactly the hole `demo/Main.lean` was found to have. This one writes what the
diff in the prompt claims to add, into `applied.c` in the session's working
directory, so the demo's artifact check has something true to be true of.

Flags, each of which exists to put one real-adapter behaviour on the tested
path:

  --refuse            the owner answers *no* to the consent question, which is
                      the hypothesis of `Harden.no_ack_of_refused` made out of
                      bytes. The apply question is then never put, so the
                      "Apply:" answer is unreachable and the run bills six
                      consultations instead of seven (`Harden.bill_refuse_demo`).
  --sloppy-apply      the act writes the lines the patch *removes* instead of
                      the ones it adds: a file on disk that is not the patch
                      that was consented to. This is the measured live failure
                      — an agent that, after consent, reintroduced the defect
                      the panel had objected to — in its smallest reproducible
                      form, and the run that proves the demo's artifact check
                      can fail.
  --cancel=KEY        the turn whose prompt matched KEY answers
                      `{"stopReason":"cancelled"}` after streaming its text.
                      A real turn ends this way when the client cancels or the
                      adapter gives up; the client must refuse to record an
                      acknowledgement of an act that did not complete, while
                      still reading a review that did not finish as a review.
                      Repeatable.
  --refuse-set-mode   `session/set_mode` answers -32602, which is what codex
                      0.13.0 does. Claude implements the call; a client that
                      cannot tolerate both is a client for one adapter.
  --refuse-set-config `session/set_config_option` answers -32601. No measured
                      adapter does this, but an adapter without a `model`
                      option is allowed to, and it is the other half of the
                      fallback the client is supposed to have.
  --write-on-ask      while answering an *ask* — a text, verdict or flag
                      question — request permission for an edit and, if it is
                      granted, replace `parse.c` in the session's working
                      directory with the hardened version. This is the measured
                      defect of `acat-08l` in its smallest reproducible form: in
                      a refusing run against the real adapter, `parse.c` was
                      replaced during the AUTHOR's draft turn, because the
                      client held one connection-wide permission policy and
                      granted every request whatever the question was. Against a
                      client that decides per question (`Exec.permissionByCode`)
                      the request is DENIED and nothing is written, so this flag
                      is the negative control for the fix: the run passes and
                      its workspace is unchanged, and it would not have been.
  --write-anyway      write the same file during an ask *without asking
                      permission at all*. No client policy can stop an adapter
                      that never asks, which is why the run's directory is
                      fingerprinted before and after: this is the negative
                      control for that check, and a refusing run against this
                      flag must FAIL with the unauthorised-write message.

Diagnostics go to stderr, which the client inherits; stdout carries protocol
and nothing else.
"""

import json
import os
import sys

PROTOCOL_VERSION = 1
# A UUID, because both real adapters return one; the old stub's "sess_stub_0001"
# is a shape no adapter produces.
SESSION_ID = "9f3f7b1e-2c4a-4d5e-8f00-000000000001"

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

# What a real agent says when its tool calls were all denied: prose, and a
# `stopReason` of `end_turn`. Measured against claude, which after two refused
# `session/request_permission` requests produced an apology and ended the turn
# normally — there is no protocol-level signal distinguishing this from an
# answer, which is exactly why the client had better grant or deny on purpose.
APOLOGY = (
    "I could not apply the patch. The tool call was blocked by the permission "
    "layer, so nothing was written. Not saying DONE, since the act did not happen."
)

ARGV = sys.argv[1:]

# Whether the owner withholds consent. A flag rather than an environment
# variable because `Acp.Config` can set the child's argv and cannot set its
# environment.
CONSENT = "no" if "--refuse" in ARGV else "yes"
# Whether the act writes the patch it was given, or something else.
SLOPPY_APPLY = "--sloppy-apply" in ARGV
CANCEL_KEYS = [a.split("=", 1)[1] for a in ARGV if a.startswith("--cancel=")]
# Whether answering a question that asked for nothing but an answer also edits
# the working directory, and whether it bothers to ask first.
WRITE_ON_ASK = "--write-on-ask" in ARGV
WRITE_ANYWAY = "--write-anyway" in ARGV
REFUSE_SET_MODE = "--refuse-set-mode" in ARGV
REFUSE_SET_CONFIG = "--refuse-set-config" in ARGV

# (substring, answer), most specific first.
ANSWERS = [
    ("correct?", "APPROVE"),
    ("secure?", "APPROVE"),
    ("simpler?", "APPROVE"),
    ("Apply this patch?", CONSENT),
    ("Apply:", "DONE"),
    ("Draft", PATCH),
    ("style guide", GUIDE),
]

# The session's configuration catalogue, in claude's shape: `session/new`
# returns it, `session/set_config_option` mutates it and returns it again. The
# `model` option is the one that matters — it is how a model is selected in ACP
# 1.3.0, both real adapters offer it, and the old stub had no notion of it.
CONFIG_OPTIONS = [
    {
        "id": "mode",
        "name": "Mode",
        "description": "Session permission mode",
        "category": "mode",
        "type": "select",
        "currentValue": "default",
        "options": [
            {"value": "auto", "name": "Auto",
             "description": "Use a model classifier to approve/deny permission prompts"},
            {"value": "default", "name": "Manual",
             "description": "Standard behavior, prompts for dangerous operations"},
            {"value": "acceptEdits", "name": "Accept Edits",
             "description": "Automatically accept file edits"},
            {"value": "plan", "name": "Plan",
             "description": "Plan without making changes"},
            {"value": "dontAsk", "name": "Don't Ask",
             "description": "Do not prompt for permission"},
            {"value": "bypassPermissions", "name": "Bypass Permissions",
             "description": "Bypass all permission checks"},
        ],
    },
    {
        "id": "model",
        "name": "Model",
        "description": "Model for this session",
        "category": "model",
        "type": "select",
        "currentValue": "stub-default",
        "options": [
            {"value": "stub-default", "name": "Default"},
            {"value": "deep", "name": "Deep"},
            {"value": "reviewer", "name": "Reviewer"},
            {"value": "author", "name": "Author"},
        ],
    },
    {
        "id": "effort",
        "name": "Effort",
        "description": "Thinking effort",
        "category": "thought_level",
        "type": "select",
        "currentValue": "default",
        "options": [
            {"value": "default", "name": "Default"},
            {"value": "low", "name": "Low"},
            {"value": "medium", "name": "Medium"},
            {"value": "high", "name": "High"},
        ],
    },
]

MODES = {
    "currentModeId": "default",
    "availableModes": [
        {"id": opt["value"], "name": opt["name"], "description": opt.get("description", "")}
        for opt in CONFIG_OPTIONS[0]["options"]
    ],
}


def available_commands():
    """The catalogue the real adapter dumps after the first prompt.

    39,598 bytes on ONE line in the measured run, with multibyte UTF-8 in the
    descriptions. Reproduced at that size on purpose: it is two orders of
    magnitude longer than anything the smoke tests used to exercise, and the
    client's "the framing is the newline" assumption has to survive it.
    """
    commands = []
    n = 0
    while True:
        commands.append({
            "name": "stub-command-%03d" % n,
            "description": (
                "A command whose description exists only to make this line long "
                "· with multibyte punctuation — and a stable shape, so "
                "that a client reading it proves nothing about the parser except "
                "that it survived %d bytes on a single line." % (39598,)
            ),
            "input": {"hint": "optional argument · %03d" % n},
        })
        n += 1
        if len(json.dumps(commands)) >= 39000:
            return commands


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


def error(rid, code, message, data=None):
    body = {"code": code, "message": message}
    if data is not None:
        body["data"] = data
    send({"jsonrpc": "2.0", "id": rid, "error": body})


def update(body):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {"sessionId": SESSION_ID, "update": body},
    })


def chunk(text, message_id="msg_stub_0001"):
    update({
        "sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": text},
        "messageId": message_id,
    })


def usage(used):
    update({"sessionUpdate": "usage_update", "used": used, "size": 200000})


def tool_call(status, extra=None):
    body = {
        "_meta": {"claudeCode": {"toolName": "Write"}},
        "toolCallId": "toolu_stub_0001",
        "sessionUpdate": "tool_call" if status == "pending" else "tool_call_update",
        "status": status,
        "title": "Write",
        "kind": "edit",
        "content": [],
        "locations": [],
    }
    if extra:
        body.update(extra)
    update(body)


# The agent's own request ids. A separate counter from the client's, starting at
# 0, and integers: the old stub used the string "stub-perm-1", which is the one
# case the real adapters never produce, so the numeric id that actually collides
# with the client's own numbering went untested.
NEXT_AGENT_ID = 0


def ask_permission(title="apply the patch"):
    """An agent-initiated request; returns the selected optionId, or None.

    The options are claude's, verbatim: three of them, `allow_always` first,
    with `kind` carrying the meaning and `optionId` carrying the name to send
    back.
    """
    global NEXT_AGENT_ID
    rid = NEXT_AGENT_ID
    NEXT_AGENT_ID += 1
    send({
        "jsonrpc": "2.0",
        "id": rid,
        "method": "session/request_permission",
        "params": {
            "options": [
                {"kind": "allow_always", "name": "Always Allow all Write",
                 "optionId": "allow_always"},
                {"kind": "allow_once", "name": "Allow", "optionId": "allow"},
                {"kind": "reject_once", "name": "Reject", "optionId": "reject"},
            ],
            "sessionId": SESSION_ID,
            "toolCall": {
                "toolCallId": "toolu_stub_0001",
                "title": title,
                "kind": "edit",
                "status": "pending",
                "content": [],
                "locations": [],
            },
        },
    })
    reply = read_message()
    note("permission reply: " + json.dumps(reply))
    if not isinstance(reply, dict) or reply.get("id") != rid:
        return None
    outcome = (reply.get("result") or {}).get("outcome") or {}
    if outcome.get("outcome") == "selected":
        return outcome.get("optionId")
    return None


def prompt_text(params):
    parts = []
    for block in params.get("prompt", []):
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "".join(parts)


def apply_patch(text, name="applied.c"):
    """Do what an `apply` tool does: write the patched file, in the cwd.

    The diff is read out of the prompt the act arrived in — the client quotes it
    there — and the lines it adds are written to `applied.c`. Under
    `--sloppy-apply` the lines it *removes* are written instead: a file that is
    not the consented patch, which is what a checker of acts has to be able to
    tell apart from one that is.

    `name` is a parameter because the same tool is what writes during an *ask*
    under `--write-on-ask`, and what it overwrites there is the workspace's own
    `parse.c` — which is what the measured defect did.
    """
    want = "-" if SLOPPY_APPLY else "+"
    body = []
    for raw in text.split("\n"):
        line = raw.strip()
        if line.startswith("+++") or line.startswith("---") or line.startswith("@@"):
            continue
        if line.startswith(want):
            body.append(line[1:].strip())
    path = os.path.join(os.getcwd(), name)
    with open(path, "w") as handle:
        handle.write("\n".join(body) + "\n")
    note("applied %d %s lines to %s" % (len(body), want, path))


def meddle_during_ask():
    """Edit the working directory while answering a question that asked for text.

    Two ways, and the difference between them is the whole of what a permission
    layer can do. Under `--write-on-ask` the edit is announced as a tool call and
    permission is requested for it: a client that decides per question denies it
    and nothing happens, and a client with one connection-wide `grant` — what
    this repository had — allows it and `parse.c` is silently replaced during a
    draft turn. Under `--write-anyway` no permission is requested at all, which
    no client can prevent and only a fingerprint of the directory can detect.
    """
    if WRITE_ANYWAY:
        apply_patch(PATCH, "parse.c")
        note("wrote parse.c during an ask WITHOUT asking permission")
        return
    tool_call("pending")
    tool_call("in_progress", {"rawInput": {"file_path": "parse.c"}})
    granted = ask_permission("edit parse.c while answering")
    if granted is None:
        tool_call("failed", {"rawOutput": "Tool permission request failed"})
        note("permission to write during an ask was DENIED; nothing written")
        return
    apply_patch(PATCH, "parse.c")
    note("permission to write during an ask was granted via optionId %r" % (granted,))
    tool_call("completed", {"rawOutput": "File updated"})


def answer_for(text):
    for key, value in ANSWERS:
        if key in text:
            return key, value
    return None, REFUSAL


FIRST_PROMPT = True


def handle_prompt(rid, params):
    global FIRST_PROMPT
    text = prompt_text(params)
    key, reply = answer_for(text)
    note("prompt matched %r" % (key,))

    # The catalogue arrives after the FIRST prompt, not after session/new; the
    # ratio of noise to answer on the real wire is about five to one.
    if FIRST_PROMPT:
        FIRST_PROMPT = False
        update({"sessionUpdate": "available_commands_update",
                "availableCommands": available_commands()})
    else:
        update({"sessionUpdate": "session_info_update",
                "title": text[:40], "updatedAt": "2026-08-13T20:30:22.832Z"})
    usage(32360)

    if key == "Apply:":
        tool_call("pending")
        tool_call("in_progress", {"rawInput": {"file_path": "patch.diff"}})
        granted = ask_permission()
        if granted is None:
            # The laundering path, measured against the real adapter: the tool
            # fails, the model apologizes, and the TURN ENDS NORMALLY.
            tool_call("failed", {"rawOutput": "Tool permission request failed"})
            usage(32450)
            chunk(APOLOGY[:20])
            chunk(APOLOGY[20:])
            result(rid, {"stopReason": "end_turn",
                         "usage": {"inputTokens": 6, "outputTokens": 564,
                                   "cachedReadTokens": 78378, "cachedWriteTokens": 18549,
                                   "totalTokens": 97497}})
            return
        note("permission granted via optionId %r" % (granted,))
        # The write happens between the grant and the "completed" update, in
        # that order, because that is the order a real adapter reports it in —
        # and because an act that reports completion without acting is the
        # thing this stub exists to not be.
        apply_patch(text)
        tool_call("completed", {"rawOutput": "File updated"})
    elif WRITE_ON_ASK or WRITE_ANYWAY:
        # A question that asked for nothing but an answer, answered by an agent
        # that edits the workspace while it thinks about it.
        meddle_during_ask()

    usage(32400)
    # Every answer is streamed as TWO chunks, so a client that returns only the
    # last one fails the smoke test; real chunks are split at arbitrary points
    # ("D" then "ONE") and carry a messageId.
    half = len(reply) // 2
    chunk(reply[:half])
    chunk(reply[half:])
    usage(32643)

    if key in CANCEL_KEYS:
        result(rid, {"stopReason": "cancelled",
                     "usage": {"inputTokens": 0, "outputTokens": 0,
                               "cachedReadTokens": 0, "cachedWriteTokens": 0,
                               "totalTokens": 0}})
        return
    result(rid, {"stopReason": "end_turn",
                 "usage": {"inputTokens": 2, "outputTokens": 42,
                           "cachedReadTokens": 14057, "cachedWriteTokens": 18299,
                           "totalTokens": 32400}})


def handle_set_mode(rid, params):
    if REFUSE_SET_MODE:
        # codex 0.13.0's answer, verbatim.
        error(rid, -32602, "Invalid params")
        return
    mode = params.get("modeId")
    for opt in CONFIG_OPTIONS:
        if opt["id"] == "mode":
            opt["currentValue"] = mode
    # Claude sends the notification BEFORE the response.
    update({"sessionUpdate": "config_option_update", "configOptions": CONFIG_OPTIONS})
    result(rid, {})


def handle_set_config_option(rid, params):
    if REFUSE_SET_CONFIG:
        error(rid, -32601, '"Method not found": session/set_config_option',
              {"method": "session/set_config_option"})
        return
    config_id = params.get("configId")
    if not isinstance(config_id, str):
        # The exact error claude returns for the wrong field name: the field is
        # `configId`, and `configOptionId` earns this.
        error(rid, -32602, "Invalid params",
              {"_errors": [],
               "configId": {"_errors": ["Invalid input: expected string, received undefined"]}})
        return
    known = [opt for opt in CONFIG_OPTIONS if opt["id"] == config_id]
    if not known:
        error(rid, -32602, "Invalid params",
              {"_errors": [], "configId": {"_errors": ["Unknown config option"]}})
        return
    value = params.get("value")
    if value not in [o["value"] for o in known[0]["options"]]:
        # A value outside a `select` option's own list. The -32602 shape is
        # claude's; that claude rejects an unlisted value was NOT measured, and
        # is assumed here because the alternative — a select that accepts
        # anything — would leave the client's fallback path untested.
        error(rid, -32602, "Invalid params",
              {"_errors": [], "value": {"_errors": ["Not an option of " + config_id]}})
        return
    known[0]["currentValue"] = value
    result(rid, {"configOptions": CONFIG_OPTIONS})


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
        params = msg.get("params", {})
        if method == "initialize":
            # Claude's shape: nested capability objects, an agentInfo with a
            # `title`, and an authMethods array. The old stub's
            # `{"loadSession": false}` is a shape no adapter sends.
            result(rid, {
                "protocolVersion": PROTOCOL_VERSION,
                "agentCapabilities": {
                    "_meta": {"stub": {"promptQueueing": True}},
                    "promptCapabilities": {"image": False, "embeddedContext": False},
                    "mcpCapabilities": {"http": False, "sse": False},
                    "auth": {"logout": {}},
                    "providers": {},
                    "loadSession": False,
                    "sessionCapabilities": {"close": {}, "list": {}},
                },
                "agentInfo": {"name": "stub_adapter", "title": "Stub Agent",
                              "version": "2.0.0"},
                "authMethods": [],
                "_meta": {"steering": {"supported": False}},
            })
        elif method == "session/new":
            note("cwd " + str(params.get("cwd")))
            result(rid, {"sessionId": SESSION_ID, "modes": MODES,
                         "configOptions": CONFIG_OPTIONS})
        elif method == "session/set_mode":
            handle_set_mode(rid, params)
        elif method == "session/set_config_option":
            handle_set_config_option(rid, params)
        elif method == "session/prompt":
            handle_prompt(rid, params)
        else:
            error(rid, -32601, '"Method not found": ' + method, {"method": method})


if __name__ == "__main__":
    sys.exit(main())
