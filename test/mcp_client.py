#!/usr/bin/env python3
"""A minimal MCP client, driving `workflow_mcp` over a real pipe.

Line-delimited JSON-RPC 2.0 on the server's stdin/stdout, implementing exactly
the client half `Agentic/Core/Mcp.lean` speaks: `initialize`, the
`notifications/initialized` that closes the handshake, `tools/list`,
`tools/call` for the four tools, and — where the mode advertises the capability
— an answer to the server's own `elicitation/create`.

**This is the calling agent, played by a script.** It answers each question the
server hands back with a canned reply keyed on a substring of the prompt,
exactly as `test/stub_adapter.py` answers an ACP turn, so the flagship workflow
of `Agentic/Core/Dsl.lean` runs end to end with no model and no network:

    "correct?" / "secure?" / "simpler?"  -> APPROVE
    "Apply this patch?"                  -> yes   (no, in the refuse mode)
    "Apply:"                             -> DONE
    "Revise this patch"                  -> a second fixed patch
    "Draft"                              -> a fixed patch
    "style guide"                        -> a fixed guide
    anything else                        -> a fixed refusal

Order matters: the review prompts embed the guide and the patch, so the most
specific key is tested first, and no canned answer contains a key.

**The workflow source is `example/harden.wf`**, not copied here: that file is
the program `agent-cat run` runs, and `Dsl.flagshipSource` is `include_str` of
it, so the program this client drives over MCP is the very text the theorems of
`Agentic/Core/Dsl.lean` price — one file, three consumers, nothing to drift.
`--source` overrides the file it is read from.

What is asserted of a finished run, in every mode:

  * the run completes — `status: done`, with a report;
  * the bill is one of {6, 7, 10, 11, 13, 14, 15}, the seven leaves of the
    flagship's cost tree that a world can actually attain, between
    `Dsl.minFold_flagship` (5, attained by none) and `Dsl.maxFold_flagship`
    (15), and equal to the number the server quoted before the run;
  * the guide question is consulted **exactly once**, though four later prompts
    quote it: the memo table is what makes that so;
  * consent implies exactly one `ack` and refusal implies none — the shape of
    `Harden.no_ack_of_refused` made out of frames;
  * the certificate is true, and so is `covered`, which is the field that
    carries content: every event of the replayed transcript is in the log.

Modes, one per behaviour of the client this server has to survive:

  --mode consent      the person consents; the act is put and acknowledged, and
                      the run bills seven (`Dsl.bill_flagship_apply`).
  --mode refuse       the person refuses; no act is put, and the run bills six
                      (`Dsl.bill_flagship_refuse`).
  --mode undecodable  the consent question is answered "maybe, if you think it
                      is fine", which the interpreter's own trusted base cannot
                      read. The client asserts the server reported an error, did
                      NOT record anything — the transcript and the bill are read
                      back to show the log did not move — and is still asking the
                      same question, then finishes the run on the refuse path.
  --mode elicit       the client advertises the elicitation capability, so the
                      person's question is put to the client's own dialog inside
                      the `tools/call` and never reaches the answering loop. The
                      consent is then recorded with `channel: elicitation`, and
                      the report carries one caveat rather than two.
  --mode revise       one reviewer objects the first time it is asked, so the
                      revision loop turns once: two rounds of three verdicts, a
                      revised draft, consent and an act — eleven consultations,
                      a different leaf of the same cost tree, and the path on
                      which the guide is quoted in four later prompts while
                      still being consulted once.

A word on what this client is *not* entitled to do. In the first three modes it
answers a question addressed to a person, which is precisely what
`Mcp.relayInstruction` tells a calling agent not to do; it is a test harness
standing in for the human, and the assertions below check that the server
*marked* the question for relay and handed it over rather than answering it
itself. Nothing here can make a relayed answer evidence that a human was asked,
which is why the server's report carries that caveat and this client asserts it
is there.

Diagnostics go to this process's stdout; the server's stderr is collected and
printed at the end, under its own heading, so the protocol, the assertions and
the server's log stay legible apart. Exits non-zero on the first failed
assertion.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SERVER = os.path.join(ROOT, ".lake", "build", "bin", "workflow_mcp")
DEFAULT_SOURCE = os.path.join(ROOT, "example", "harden.wf")

# The bills a run of the flagship can actually present: 5 questions to the first
# verdict plus a consent (6) plus an act (7), and the same again with one
# revision round (10, 11) and with two (13, 14, 15 — the last being the
# `never approved` outcome's own tail).
LEGAL_BILLS = {6, 7, 10, 11, 13, 14, 15}

# What each mode's path through that tree costs: five questions to the first
# verdict, plus consent, plus an act where there is one, plus four more per turn
# of the revision loop.
EXPECTED_BILL = {"consent": 7, "refuse": 6, "undecodable": 6, "elicit": 7, "revise": 11}

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

REVISED = (
    "--- a/src/parse.c\n"
    "+++ b/src/parse.c\n"
    "@@\n"
    "-  char buf[64]; strcpy(buf, input);\n"
    "+  char buf[64];\n"
    "+  if (snprintf(buf, sizeof buf, \"%s\", input) >= (int) sizeof buf) return -1;\n"
)

REFUSAL = "I have nothing canned for that."

# The answer the trusted base cannot read. `Decode` is total everywhere but
# `.flag` (`Exec.Decode_eq_none`), so the consent question is the only place a
# client can be wrong about the words.
UNREADABLE = "maybe, if you think it is fine"

# The one answer that turns the revision loop, in the words `verdictSpec` asks
# for. It contains no key of the table below: the objection is spliced into the
# revision prompt, and a reason that matched a key would answer the next
# question by accident.
OBJECTION = "OBJECTION: the length check is still missing"


def answers(consent):
    """(substring, answer) pairs, most specific first."""
    return [
        ("correct?", "APPROVE"),
        ("secure?", "APPROVE"),
        ("simpler?", "APPROVE"),
        ("Apply this patch?", "yes" if consent else "no"),
        ("Apply:", "DONE"),
        ("Revise this patch", REVISED),
        ("Draft", PATCH),
        ("style guide", GUIDE),
    ]


def answer_for(prompt, consent):
    for key, value in answers(consent):
        if key in prompt:
            return key, value
    return None, REFUSAL


def flagship_source(path):
    """The program, read off the file `Dsl.flagshipSource` is included from."""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as err:
        raise SystemExit("mcp_client: cannot read the workflow at %s: %s" % (path, err))


# --- assertions -------------------------------------------------------------

FAILURES = []


def check(what, expected, actual):
    if expected == actual:
        print("ok   %s" % what)
    else:
        FAILURES.append(what)
        print("FAIL %s\n  expected: %r\n  actual:   %r" % (what, expected, actual))


def check_true(what, claim):
    if claim:
        print("ok   %s" % what)
    else:
        FAILURES.append(what)
        print("FAIL %s" % what)


# --- the client -------------------------------------------------------------

class Client(object):
    """One live conversation with one server process."""

    def __init__(self, server, log, verbose=False, elicit=None):
        self.verbose = verbose
        # What to answer an `elicitation/create` with: a content object to
        # accept with, or None to decline. A declined dialog is not a `no` —
        # the server relays the question instead — which is the rule
        # `Mcp.elicit` exists to keep.
        self.elicit = elicit
        self.proc = subprocess.Popen(
            [server],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=log,
            cwd=ROOT,
            text=True,
            bufsize=1,
        )
        self.next_id = 0

    def send(self, obj):
        line = json.dumps(obj)
        if self.verbose:
            print("  -> %s" % line[:400])
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def read_frame(self):
        line = self.proc.stdout.readline()
        if line == "":
            raise SystemExit("mcp_client: the server closed its stdout")
        if self.verbose:
            print("  <- %s" % line.rstrip()[:400])
        return json.loads(line)

    def request(self, method, params):
        """One request, and the frame that answers it.

        Frames that are not that answer are handled on the way past: a
        server-initiated `elicitation/create` is answered here, because the
        server is blocked on it inside the very call we are waiting for.
        """
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            msg = self.read_frame()
            if "method" in msg and "id" in msg:
                self.handle_request(msg)
            elif "method" in msg:
                print("  (notification %s ignored)" % msg["method"])
            elif msg.get("id") == rid:
                return msg
            else:
                raise SystemExit("mcp_client: a frame answers no request: %r" % msg)

    def handle_request(self, msg):
        if msg.get("method") != "elicitation/create":
            self.send({"jsonrpc": "2.0", "id": msg["id"],
                       "error": {"code": -32601,
                                 "message": "this client implements only elicitation"}})
            return
        params = msg.get("params", {})
        print("  dialog (%s): %s" % (params.get("mode"),
                                     params.get("message", "").split("\n")[0]))
        if self.elicit is None:
            body = {"action": "decline"}
        else:
            body = {"action": "accept", "content": self.elicit}
        self.send({"jsonrpc": "2.0", "id": msg["id"], "result": body})

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def call(self, tool, arguments):
        """One `tools/call`: its structured content, and whether it is an error."""
        frame = self.request("tools/call", {"name": tool, "arguments": arguments})
        if "error" in frame:
            raise SystemExit("mcp_client: protocol error from %s: %r" % (tool, frame["error"]))
        result = frame.get("result", {})
        return result.get("structuredContent", {}), bool(result.get("isError", False))

    def close(self):
        self.proc.stdin.close()
        return self.proc.wait()


# --- the run ----------------------------------------------------------------

def handshake(client, mode, expect_server):
    caps = {"roots": {"listChanged": True}}
    if mode == "elicit":
        # A bare object, which the specification reads as form mode; it is what
        # the installed client was measured sending.
        caps["elicitation"] = {}
    frame = client.request("initialize", {
        "protocolVersion": "2025-11-25",
        "capabilities": caps,
        "clientInfo": {"name": "mcp_client.py", "version": "0"},
    })
    result = frame.get("result", {})
    info = result.get("serverInfo", {})
    said = "%s %s %s" % (info.get("name"), info.get("version"),
                         result.get("protocolVersion"))
    if expect_server:
        check("the server is the one this test was built against", expect_server, said)
    else:
        print("ok   server: %s" % said)
    check("it advertises tools, and only tools",
          {"tools": {"listChanged": False}}, result.get("capabilities"))
    check_true("…and carries instructions for the model",
               bool(result.get("instructions")))
    client.notify("notifications/initialized", {})

    frame = client.request("tools/list", {})
    names = [t["name"] for t in frame.get("result", {}).get("tools", [])]
    check("tools/list offers the four tools, in order",
          ["workflow_check", "workflow_start", "workflow_answer", "workflow_transcript"],
          names)


def check_source(client, source):
    quoted, is_error = client.call("workflow_check", {"source": source})
    check_true("workflow_check accepts the flagship", not is_error)
    check("…at the branch rung", "branch", quoted.get("level"))
    check("…the cheapest run is five consultations (Dsl.minFold_flagship)",
          5, quoted.get("minBill"))
    check("…the dearest is fifteen (Dsl.maxFold_flagship)", 15, quoted.get("maxBill"))
    check("…over nine paths (Dsl.card_leaves_flagship)", 9, quoted.get("paths"))
    return quoted


def poison(client, run_id, question):
    """Answer the consent question with words the trusted base cannot read.

    Asserts the three things that make this a safety property rather than a
    message: it is an error, nothing was recorded, and the same question is
    still pending.
    """
    before, _ = client.call("workflow_transcript", {"runId": run_id})
    body, is_error = client.call("workflow_answer", {"runId": run_id, "answer": UNREADABLE})
    check_true("an answer the trusted base cannot read is an error", is_error)
    check("…diagnosed as such", "undecodable-answer",
          (body.get("error") or {}).get("kind"))
    check("…the run is still asking", "asking", body.get("status"))
    check("…the same question, at the same seq", question["seq"],
          (body.get("question") or {}).get("seq"))
    check("…with one attempt left", 0, body.get("retriesLeft"))
    after, _ = client.call("workflow_transcript", {"runId": run_id})
    check("…and NOTHING was recorded: the log has not moved",
          len(before["transcript"]), len(after["transcript"]))
    check("…nor has the bill", before["bill"]["fresh"], after["bill"]["fresh"])
    check("…nor the source it is a run of", before["source"], after["source"])


def consents(mode):
    """Does the person say yes in this mode? The undecodable mode refuses, so
    that the answer the server rejected and the answer it accepted are the same
    question answered twice and told apart."""
    return mode in ("consent", "elicit", "revise")


def drive(client, mode, source):
    """Start the flagship and answer until the report comes back."""
    consent = consents(mode)
    body, is_error = client.call("workflow_start", {"source": source})
    check_true("workflow_start accepts the flagship", not is_error)
    run_id = body.get("runId")
    check("…and names the run", "r-1", run_id)
    check("…stopping at its first question", "asking", body.get("status"))

    relayed = 0
    poisoned = mode != "undecodable"
    objections = 1 if mode == "revise" else 0
    for _ in range(64):
        if body.get("status") != "asking":
            break
        question = body["question"]
        key, reply = answer_for(question["prompt"], consent)
        if objections > 0 and key == "correct?":
            objections -= 1
            reply = OBJECTION
        print("  Q%d %-7s %s/%-16s %s" % (
            question["seq"], question["code"],
            question["addressee"]["kind"], question["addressee"]["id"],
            question["prompt"].split("\n")[0][:60]))
        if question["relay"]:
            relayed += 1
            check_true("a person's question carries the relay instruction",
                       bool(question.get("relayInstruction")))
            check_true("…and the bytes an interpreter would have sent",
                       bool(question.get("rendered")))
        check_true("Q%d has an answer specification and a schema" % question["seq"],
                   bool(question.get("answerSpec")) and bool(question.get("answerSchema")))
        check_true("Q%d is one the canned client has an answer for" % question["seq"],
                   key is not None)
        if not poisoned and question["code"] == "flag":
            poisoned = True
            poison(client, run_id, question)
        print("  A%d %s" % (question["seq"], reply.split("\n")[0][:60]))
        body, is_error = client.call("workflow_answer", {"runId": run_id, "answer": reply})
        if is_error:
            raise SystemExit("mcp_client: the server refused a canned answer: %r"
                             % body.get("error"))
    return run_id, body, relayed


def assertions(mode, quoted, body, relayed):
    consent = consents(mode)
    check("the run completes", "done", body.get("status"))
    report = body.get("report")
    check_true("…with a report", report is not None)
    if report is None:
        return report

    bill = report["bill"]["fresh"]
    check_true("the bill (%d) is a leaf of the flagship's cost tree" % bill,
               bill in LEGAL_BILLS)
    check_true("…between the cheapest and the dearest the server quoted",
               quoted["minBill"] <= bill <= quoted["maxBill"])
    check("…and it is the bill this path was priced at", EXPECTED_BILL[mode], bill)
    check("…every question of which was asked once: memo equals fresh",
          bill, report["bill"]["memo"])
    check("…and the table holds one answer per consultation",
          bill, report["table"]["size"])

    transcript = report["transcript"]
    check("the transcript has one event per consultation", bill, len(transcript))
    guides = [e for e in transcript
              if e["addressee"] == {"kind": "tool", "id": "cat"}]
    check("the guide is consulted exactly once, though later prompts quote it",
          1, len(guides))
    quoting = [e for e in transcript
               if e is not guides[0] and guides[0]["answer"] in e["prompt"]]
    check_true("…and its answer is quoted in %d later prompts" % len(quoting),
               len(quoting) >= 2)

    verdicts = [e for e in transcript if e["code"] == "verdict"]
    check("the panel sat once per round of the revision loop",
          6 if mode == "revise" else 3, len(verdicts))
    if mode == "revise":
        # `sayVerdict` writes the three cases `Plan.caseV` branches on: an
        # approval is "approve", a decline is "declined", and an objection is
        # its own reasons, joined.
        objected = [e for e in verdicts if e["answer"] not in ("approve", "declined")]
        check("exactly one verdict is an objection", 1, len(objected))
        check_true("…carrying the reason this client gave",
                   "length check is still missing" in objected[0]["answer"])
        check("…and the author was asked for a revision",
              1, len([e for e in transcript if "Revise this patch" in e["prompt"]]))

    flags = [e for e in transcript if e["code"] == "flag"]
    acks = [e for e in transcript if e["code"] == "ack"]
    check("the person was asked for consent exactly once", 1, len(flags))
    check("…and answered as this mode says", "yes" if consent else "no",
          flags[0]["answer"])
    check("consent implies an act, refusal implies none",
          1 if consent else 0, len(acks))
    if consent:
        check("…and the act is acknowledged", "done", acks[0]["answer"])

    cert = report["certificate"]
    check("the certificate is true", True, cert["certified"])
    check("…and the log covers the replay, which is the field with content",
          True, cert["covered"])
    check("…and the server says the certificate is vacuous on a closed workflow",
          True, cert["vacuous"])
    check("what the server heard is what the log replays",
          True, report["heardMatchesReplay"])

    if mode == "elicit":
        check("the consent came over the client's own dialog", "elicitation",
              flags[0]["channel"])
        check("…so no question was relayed to the caller", 0, relayed)
        check("…and the run carries one caveat: the act, and no relay",
              1, len(report["caveats"]))
    else:
        check("the consent came over a tool call", "tool-call", flags[0]["channel"])
        check("…the person's question having been relayed exactly once", 1, relayed)
        check("…so the run carries a caveat about relay",
              True, any("Relay" in c or "relay" in c for c in report["caveats"]))
        check("…and one about the act where there was one",
              2 if consent else 1, len(report["caveats"]))
    return report


def main():
    ap = argparse.ArgumentParser(description="drive workflow_mcp over stdio")
    ap.add_argument("--mode", default="consent",
                    choices=["consent", "refuse", "undecodable", "elicit", "revise"])
    ap.add_argument("--server", default=DEFAULT_SERVER,
                    help="the workflow_mcp binary (default: %s)" % DEFAULT_SERVER)
    ap.add_argument("--source", default=DEFAULT_SOURCE,
                    help="the .wf program to drive (default: %s)" % DEFAULT_SOURCE)
    ap.add_argument("--expect-server", default=None,
                    help='"name version protocolVersion" the server must answer with')
    ap.add_argument("--verbose", action="store_true", help="print every frame")
    args = ap.parse_args()

    if not os.path.exists(args.server):
        raise SystemExit("mcp_client: no server at %s — run `lake build` first"
                         % args.server)
    source = flagship_source(args.source)

    print("--- mcp_client: mode %s ---" % args.mode)
    log = tempfile.TemporaryFile(mode="w+", encoding="utf-8")
    client = Client(args.server, log, verbose=args.verbose,
                    elicit={"consent": True} if args.mode == "elicit" else None)
    code = 1
    try:
        handshake(client, args.mode, args.expect_server)
        quoted = check_source(client, source)
        run_id, body, relayed = drive(client, args.mode, source)
        report = assertions(args.mode, quoted, body, relayed)
        # The run reads back after it is over, which is what makes the
        # transcript tool a recovery path and not a debug print.
        readback, _ = client.call("workflow_transcript", {"runId": run_id})
        check("the run reads back as finished", "done", readback.get("status"))
        check("…with the source it was started from", source, readback.get("source"))
        if report is not None:
            print("--- the report the client received ---")
            for line in report["render"]:
                print("  " + line)
    finally:
        code = client.close()
        log.seek(0)
        text = log.read().strip()
        log.close()
        if text:
            print("--- the server's stderr ---")
            for line in text.split("\n"):
                print("  " + line)

    check("the server exited cleanly when its stdin closed", 0, code)
    if FAILURES:
        print("FAILED %d assertion(s): %s" % (len(FAILURES), "; ".join(FAILURES)))
        return 1
    print("all checks passed (mode %s)" % args.mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
