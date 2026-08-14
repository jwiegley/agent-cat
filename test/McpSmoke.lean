import Agentic.Core.Mcp
import Agentic.Core.DslFlagship

/-!
# The server, driven end to end over a scripted stream

Run from the repository root:

```
lake exe mcp_smoke
```

It exits non-zero on the first mismatch and prints what it checked otherwise.

**This drives the server, not a copy of it.** `Mcp.serve` is the function
`mcp/Main.lean` runs; the only difference here is `Mcp.Io.ofList`, which reads
the client's lines from a list and appends the server's frames to an array
instead of using a pipe. A scripted list interleaves correctly with a
server-initiated `elicitation/create`, because the server reads its answer from
the same stream, in the same order, that a real client would write it to — so
the elicitation ladder is tested here and not merely described.

Four scripts, and each checks something the code cannot claim on its own:

1. **The handshake, the tool list, and `workflow_check`.** The cost this server
   quotes for the flagship is checked against the numbers
   `Agentic/Core/DslFlagship.lean` *proves* about it — `minFold_flagship` (5),
   `maxFold_flagship` (15) and `card_leaves_flagship` (9). A tool that
   miscomputed a price would disagree with a theorem here.
2. **A whole run**, question by question, to the refuse path, whose bill
   `Dsl.bill_flagship_refuse` proves is six. Along the way: an answer the
   trusted base cannot read is reported as an error and **not recorded** — the
   transcript is read back to show the log did not move — and the person's
   question comes back marked `relay`.
3. **A declined elicitation is not a `no`.** The client offers a dialog, the
   dialog is dismissed, and the question comes back to be relayed with nothing
   recorded. This is the rule that keeps a refusal somebody gave distinguishable
   from a dialog nobody answered.
4. **An accepted elicitation is an answer**, recorded with the channel that
   carried it, and the run finishes on the apply path — seven consultations,
   `Dsl.bill_flagship_apply`.
-/

open Lean (Json)
open Agentic.Core
open Agentic.Core.Mcp

/-! ## The harness -/

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

/-- Fail loudly on a claim that is simply supposed to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then IO.println s!"ok   {what}" else throw <| IO.userError s!"FAIL {what}"

/-- A JSON path, as a string, or a marker naming what was missing — so a failure
prints the shape that arrived rather than raising. -/
def field (j : Json) : List String → String
  | [] => match j.getStr? with
    | .ok s => s
    | .error _ => j.compress
  | k :: ks => match j.getObjVal? k with
    | .ok v => field v ks
    | .error _ => s!"<no field '{k}' in {j.compress}>"

/-- Run one script against a fresh server and return every frame it wrote. -/
def runScript (lines : List String) (set : Settings := {}) : IO (Array String) := do
  let sink ← IO.mkRef (#[] : Array String)
  let io ← Io.ofList lines sink
  let _ ← serve io set (lines.length + 1) {}
  sink.get

/-- The frame answering request `id`, or a marker. -/
def reply (frames : Array String) (id : Nat) : Json :=
  let parsed := frames.toList.filterMap fun l => (Json.parse l).toOption
  match parsed.find? fun j => (j.getObjVal? "id" >>= Json.getNat?).toOption == some id with
  | some j => j
  | none => Json.str s!"<no reply to request {id}>"

/-- The `structuredContent` of the tool result answering request `id`. -/
def structured (frames : Array String) (id : Nat) : Json :=
  ((reply frames id).getObjValD "result").getObjValD "structuredContent"

/-- Whether the tool result answering request `id` reported a tool execution
error. -/
def isErr (frames : Array String) (id : Nat) : Bool :=
  match ((reply frames id).getObjValD "result").getObjVal? "isError" >>= Json.getBool? with
  | .ok b => b
  | .error _ => false

/-! ## Writing the client's side

Built with `Agentic/Core/Rpc.lean`'s own encoders, so the test exercises the
framing both protocols share rather than a hand-rolled string. -/

/-- One request, as a line. -/
def req (id : Nat) (method : String) (params : Json) : String :=
  (Rpc.request (jnat id) method params).compress

/-- One `tools/call`, as a line. -/
def call (id : Nat) (tool : String) (args : List (String × Json)) : String :=
  req id "tools/call" <| Json.mkObj
    [ ("name", Json.str tool)
    , ("arguments", Json.mkObj args)
    , -- the client sends a `_meta` we did not ask for; this server ignores it,
      -- and the test sends one to prove that it does
      ("_meta", Json.mkObj [("progressToken", jnat 2)]) ]

/-- `workflow_answer`, as a line. -/
def answerLine (id : Nat) (runId text : String) : String :=
  call id "workflow_answer" [("runId", Json.str runId), ("answer", Json.str text)]

/-- The `initialize` a client sends, with or without the elicitation capability.
The shape is the one the installed client was measured sending: a bare `{}` for
elicitation, which the specification reads as form mode. -/
def initLine (id : Nat) (elicitation : Bool) : String :=
  req id "initialize" <| Json.mkObj
    [ ("protocolVersion", Json.str "2025-11-25")
    , ("capabilities", Json.mkObj
        ([("roots", Json.mkObj [("listChanged", Json.bool true)])]
          ++ (if elicitation then [("elicitation", Json.mkObj [])] else [])))
    , ("clientInfo", Json.mkObj
        [("name", Json.str "mcp_smoke"), ("version", Json.str "0")]) ]

/-- The handshake's last word. -/
def initializedLine : String := (Rpc.notification "notifications/initialized" (Json.mkObj [])).compress

/-- An elicitation result, as the client would write it. The id is the server's
own request counter, which starts at zero in a fresh process. -/
def elicitReply (id : Nat) (payload : Json) : String := (Rpc.result (jnat id) payload).compress

/-- The five answers that carry the flagship to its consent question: the style
guide, a patch, and three approving reviews. -/
def leadIn (firstId : Nat) (runId : String) : List String :=
  [ answerLine firstId runId "Keep functions short. Check every index. No new globals."
  , answerLine (firstId + 1) runId
      "--- a/parse.c\n+++ b/parse.c\n@@\n-  int n;\n+  int n = 0;\n"
  , answerLine (firstId + 2) runId "APPROVE"
  , answerLine (firstId + 3) runId "APPROVE"
  , answerLine (firstId + 4) runId "APPROVE" ]

/-! ## 1. The handshake, the tool list, and the price of the flagship -/

/-- A source that does not type-check, with a fault the checker can point at. -/
def brokenSource : String := "workflow {\n  let g = ask tool\n}\n"

/-- A source that type-checks in the mathematics and not on a machine: the bound
takes a `Nat`, and `Plan.revising … n` is an unrolling `n` deep, so the numeral
below asked this server for a billion nested plans and got a stack overflow —
`SIGABRT`, before anything was asked of anybody, taking every other run's state
with it, because `State` lives in this process. `Dsl.maxRevisions` is the
refusal that replaced it, and the `ping` after it is the part that matters: the
server is still there. -/
def hostileSource : String :=
  "workflow {\n" ++
  "  let d = ask model \"a\" for text \"draft\"\n" ++
  "  revising d up to 1000000000 revisions {\n" ++
  "    check given p { ask model \"r\" for verdict \"review {p}\" }\n" ++
  "    revise given p, why { ask model \"a\" for text \"fix {p} {why}\" }\n" ++
  "  }\n" ++
  "  approved given p { }\n" ++
  "  never approved { }\n}\n"

def scriptOne : IO Unit := do
  let src := Json.str Dsl.flagshipSource
  let frames ← runScript
    [ req 0 "tools/list" (Json.mkObj [])          -- before `initialize`
    , initLine 1 false
    , initializedLine
    , req 2 "tools/list" (Json.mkObj [])
    , call 3 "workflow_check" [("source", src)]
    , call 4 "workflow_check" [("source", Json.str brokenSource)]
    , call 5 "no_such_tool" []
    , req 6 "resources/list" (Json.mkObj [])
    , req 7 "ping" (Json.mkObj [])
    , call 8 "workflow_check" [("source", Json.str hostileSource)]
    , req 9 "ping" (Json.mkObj []) ]

  check "a request before initialize is refused" "-32600"
    (field (reply frames 0) ["error", "code"])
  check "initialize answers with the revision this server implements"
    "2025-11-25" (field (reply frames 1) ["result", "protocolVersion"])
  check "…and advertises tools, and only tools"
    "{\"tools\":{\"listChanged\":false}}"
    ((((reply frames 1).getObjValD "result").getObjValD "capabilities").compress)
  check "…and names itself" "agent-cat-workflow"
    (field (reply frames 1) ["result", "serverInfo", "name"])
  checkTrue "the initialized notification is not answered"
    (match reply frames 1 with | .str _ => false | _ => true)

  let names := match ((reply frames 2).getObjValD "result").getObjVal? "tools" with
    | .ok (.arr ts) => ts.toList.map fun t => field t ["name"]
    | _ => ["<no tools>"]
  check "tools/list offers the four tools, in order"
    "workflow_check, workflow_start, workflow_answer, workflow_transcript"
    (String.intercalate ", " names)
  checkTrue "every tool carries an input and an output schema"
    (match ((reply frames 2).getObjValD "result").getObjVal? "tools" with
     | .ok (.arr ts) => ts.toList.all fun t =>
         (t.getObjVal? "inputSchema").toOption.isSome && (t.getObjVal? "outputSchema").toOption.isSome
     | _ => false)

  let chk := structured frames 3
  checkTrue "workflow_check accepts the flagship" (!isErr frames 3)
  check "…at the branch rung" "branch" (field chk ["level"])
  check "…the cheapest run is five consultations (Dsl.minFold_flagship)" "5"
    (field chk ["minBill"])
  check "…the dearest is fifteen (Dsl.maxFold_flagship)" "15" (field chk ["maxBill"])
  check "…over nine paths (Dsl.card_leaves_flagship)" "9" (field chk ["paths"])
  check "…and the question sequence is null, because the program branches" "null"
    (field chk ["shapes"])
  checkTrue "the structured result is duplicated in a text block"
    (match ((reply frames 3).getObjValD "result").getObjVal? "content" with
     | .ok (.arr blocks) => blocks.size == 2
     | _ => false)

  checkTrue "an ill-typed source is a tool execution error, not a protocol error"
    (isErr frames 4)
  check "…diagnosed by kind" "check-error" (field (structured frames 4) ["error", "kind"])
  check "…with a line, a column and an excerpt" "3"
    (field (structured frames 4) ["error", "line"])
  checkTrue "…and a message"
    (!(field (structured frames 4) ["error", "message"]).isEmpty)

  check "an unknown tool is a protocol error" "-32601"
    (field (reply frames 5) ["error", "code"])
  check "an unadvertised capability is refused" "-32601"
    (field (reply frames 6) ["error", "code"])
  check "ping is answered" "{}" (((reply frames 7).getObjValD "result").compress)

  checkTrue "a source-chosen recursion depth is refused, not run" (isErr frames 8)
  check "…as a check error like any other" "check-error"
    (field (structured frames 8) ["error", "kind"])
  check "…pointing at the `revising` that names it" "3"
    (field (structured frames 8) ["error", "line"])
  check "…and the server is still answering afterwards" "{}"
    (((reply frames 9).getObjValD "result").compress)

/-! ## 2. A whole run, to the refuse path -/

def scriptTwo : IO Unit := do
  let src := Json.str Dsl.flagshipSource
  let frames ← runScript <|
    [ initLine 1 false
    , initializedLine
    , call 2 "workflow_start" [("source", src)] ]
      ++ leadIn 3 "r-1"
      ++ [ answerLine 8 "r-1" "maybe, if you think it is fine"   -- unreadable
         , call 9 "workflow_transcript" [("runId", Json.str "r-1")]
         , answerLine 10 "r-1" "no"
         , call 11 "workflow_transcript" [("runId", Json.str "r-1")]
         , answerLine 12 "r-1" "no"                              -- the run is over
         , answerLine 13 "r-2" "no" ]                            -- no such run

  let st := structured frames 2
  check "workflow_start names the run" "r-1" (field st ["runId"])
  check "…and stops at its first question" "asking" (field st ["status"])
  check "…which is put to a tool" "tool" (field st ["question", "addressee", "kind"])
  check "…for text" "text" (field st ["question", "code"])
  check "…with the interpreter's own answer specification, verbatim"
    (Exec.answerSpec .text) (field st ["question", "answerSpec"])
  check "…and is not a relay" "false" (field st ["question", "relay"])

  let consent := structured frames 7
  check "after five answers the consent question is pending" "flag"
    (field consent ["question", "code"])
  check "…addressed to a person" "person" (field consent ["question", "addressee", "kind"])
  check "…marked for relay" "true" (field consent ["question", "relay"])
  checkTrue "…with an instruction not to answer it oneself"
    (!(field consent ["question", "relayInstruction"]).isEmpty)
  check "…and its answer specification is the interpreter's"
    (Exec.answerSpec .flag) (field consent ["question", "answerSpec"])

  checkTrue "an answer the trusted base cannot read is an error" (isErr frames 8)
  check "…diagnosed as such" "undecodable-answer"
    (field (structured frames 8) ["error", "kind"])
  check "…the run is still asking the same question" "5"
    (field (structured frames 8) ["question", "seq"])
  check "…with one attempt left" "0" (field (structured frames 8) ["retriesLeft"])
  check "…and NOTHING was recorded: the log still holds five answers" "5"
    (toString (match (structured frames 9).getObjVal? "transcript" with
      | .ok (.arr es) => es.size | _ => 0))
  check "…and the bill has not moved" "5" (field (structured frames 9) ["bill", "fresh"])

  let done := structured frames 10
  check "the refusal finishes the run" "done" (field done ["status"])
  check "…billed six consultations (Dsl.bill_flagship_refuse)" "6"
    (field done ["report", "bill", "fresh"])
  check "…six of them distinct" "6" (field done ["report", "bill", "memo"])
  check "…the log covers the replay" "true"
    (field done ["report", "certificate", "covered"])
  check "…the certificate holds" "true" (field done ["report", "certificate", "certified"])
  check "…and says that on a closed workflow it is vacuous" "true"
    (field done ["report", "certificate", "vacuous"])
  check "…what the server heard is what the log replays" "true"
    (field done ["report", "heardMatchesReplay"])
  checkTrue "…and the report says a person's answer came through the agent"
    (match (done.getObjValD "report").getObjVal? "caveats" with
     | .ok (.arr cs) => cs.size ≥ 1
     | _ => false)
  check "…the last answer is recorded as having come over a tool call" "tool-call"
    (match (done.getObjValD "report").getObjVal? "transcript" with
     | .ok (.arr es) => match es[5]? with
       | some e => field e ["channel"]
       | none => "<no sixth event>"
     | _ => "<no transcript>")

  check "a finished run takes no further answers" "run-finished"
    (field (structured frames 12) ["error", "kind"])
  check "an unknown run is a tool error, not a protocol error" "no-such-run"
    (field (structured frames 13) ["error", "kind"])

  IO.println "--- the report the client received ---"
  for l in renderOf ((structured frames 10).getObjValD "report") do IO.println s!"  {l}"

/-! ## 3. A declined elicitation is not a `no` -/

def scriptThree : IO Unit := do
  let src := Json.str Dsl.flagshipSource
  let frames ← runScript <|
    [ initLine 1 true
    , initializedLine
    , call 2 "workflow_start" [("source", src)] ]
      ++ leadIn 3 "r-1"
      ++ [ elicitReply 0 (Json.mkObj [("action", Json.str "decline")])
         , call 8 "workflow_transcript" [("runId", Json.str "r-1")]
         , answerLine 9 "r-1" "maybe"
         , answerLine 10 "r-1" "if you insist"
         , answerLine 11 "r-1" "yes"
         , call 12 "workflow_transcript" [("runId", Json.str "r-1")] ]

  checkTrue "the server opened a dialog for the person's question"
    (frames.toList.any fun l => (l.splitOn "elicitation/create").length > 1)
  check "…in form mode" "form"
    (match frames.toList.filterMap (fun l => (Json.parse l).toOption)
            |>.find? (fun j => field j ["method"] == "elicitation/create") with
     | some j => field j ["params", "mode"]
     | none => "<no elicitation>")
  let after := structured frames 7
  check "a dismissed dialog leaves the question pending" "asking" (field after ["status"])
  check "…still at the consent question" "flag" (field after ["question", "code"])
  check "…now handed back to be relayed" "true" (field after ["question", "relay"])
  check "…and NOTHING was recorded: decline is not a refusal somebody gave" "5"
    (toString (match (structured frames 8).getObjVal? "transcript" with
      | .ok (.arr es) => es.size | _ => 0))

  check "the first unreadable answer is re-asked" "undecodable-answer"
    (field (structured frames 9) ["error", "kind"])
  check "…and the retry budget is spent by the second" "run-failed"
    (field (structured frames 10) ["error", "kind"])
  check "…after which the run takes nothing, not even a readable answer" "run-failed"
    (field (structured frames 11) ["error", "kind"])
  check "…and reads back as failed" "failed" (field (structured frames 12) ["status"])
  check "…with the log still holding the five answers somebody did give" "5"
    (toString (match (structured frames 12).getObjVal? "transcript" with
      | .ok (.arr es) => es.size | _ => 0))

/-! ## 4. An accepted elicitation is an answer -/

def scriptFour : IO Unit := do
  let src := Json.str Dsl.flagshipSource
  let frames ← runScript <|
    [ initLine 1 true
    , initializedLine
    , call 2 "workflow_start" [("source", src)] ]
      ++ leadIn 3 "r-1"
      ++ [ elicitReply 0 (Json.mkObj
            [ ("action", Json.str "accept")
            , ("content", Json.mkObj [("consent", Json.bool true)]) ])
         , answerLine 8 "r-1" "DONE"
         , call 9 "workflow_transcript" [("runId", Json.str "r-1")] ]

  let acked := structured frames 7
  check "an accepted dialog answers the question without troubling the caller" "ack"
    (field acked ["question", "code"])
  check "…so the caller is asked for the act next" "tool"
    (field acked ["question", "addressee", "kind"])
  let done := structured frames 8
  check "acknowledging the act finishes the run" "done" (field done ["status"])
  check "…billed seven consultations (Dsl.bill_flagship_apply)" "7"
    (field done ["report", "bill", "fresh"])
  check "…the log covers the replay" "true"
    (field done ["report", "certificate", "covered"])
  check "…and the consent is recorded as having come from the client's own dialog"
    "elicitation"
    (match (done.getObjValD "report").getObjVal? "transcript" with
     | .ok (.arr es) => match es[5]? with
       | some e => field e ["channel"]
       | none => "<no sixth event>"
     | _ => "<no transcript>")
  check "…so the run carries one caveat and not two: the act, and no relay" "1"
    (toString (match (done.getObjValD "report").getObjVal? "caveats" with
      | .ok (.arr cs) => cs.size | _ => 0))
  checkTrue "…and that caveat is the one about what the act did"
    (match (done.getObjValD "report").getObjVal? "caveats" with
     | .ok (.arr cs) => match cs[0]? with
       | some c => ((c.getStr?.toOption.getD "").splitOn "act").length > 1
       | none => false
     | _ => false)
  check "the transcript reads back after the run is over" "done"
    (field (structured frames 9) ["status"])

def main : IO Unit := do
  IO.println "--- 1. handshake, tools, and what the flagship costs ---"
  scriptOne
  IO.println "--- 2. a whole run, to the refuse path ---"
  scriptTwo
  IO.println "--- 3. a declined elicitation is not a `no` ---"
  scriptThree
  IO.println "--- 4. an accepted elicitation is an answer ---"
  scriptFour
  IO.println "all checks passed"
