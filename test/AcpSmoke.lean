import Agentic.Core.Acp

/-!
# The transport, driven end to end against an adapter

Run from the repository root:

```
lake exe acp_smoke                  # the stub, which is a faithful double
lake exe acp_smoke -- --adapter claude   # the real thing: two short live turns
lake exe acp_smoke -- --adapter codex
```

The stub is found relative to the working directory, so the root is where this
must be run from. It exits non-zero on the first mismatch and prints what it
checked otherwise.

This is a test of the *wire*, not of a meaning: it asserts that the bytes the
adapter was told to say are the bytes that came back, and that the shapes the
client sends are the shapes a real adapter accepts. Since
`test/stub_adapter.py` now reproduces the real transcripts byte for byte, the
assertions below are assertions about the **real** protocol:

* `initialize` negotiates version 1 and answers with an `agentInfo` carrying a
  `title` (both real adapters do; the old stub did not);
* `session/new` answers with a UUID `sessionId` and the mode/model catalogues;
* `session/set_mode` round-trips, and its refusal is a *value*, because codex
  refuses it;
* `session/set_config_option` is how a model is selected — the field is
  `configId` — and an unknown option is refused rather than silently accepted;
* a turn's answer is the concatenation of its `agent_message_chunk`s, sifted out
  of five times as much noise, including one 39 KB line;
* an agent-initiated `session/request_permission` with an **integer** id is
  answered by policy: granting it lets the act happen, and cancelling it gets
  the real adapter's measured behaviour instead — an apology, and `end_turn`;
* the **session handoff**: `initialize`'s capabilities are read rather than
  discarded, `session/load` drains a replayed transcript and leaves the
  connection prompting the loaded session, a `null` result is as good as an
  object, `session/fork` moves the connection to the *new* id it answered with,
  and an adapter that advertised neither call refuses each by name — before a
  session is opened or a prompt is sent.

The `--adapter` mode spends real tokens: two short turns, in a temporary
directory, to check that the handshake, a prompt and the permission grant work
against the adapter this code was written from transcripts of.
-/

open Agentic.Core.Acp

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

/-- Fail loudly on a claim that is simply supposed to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then IO.println s!"ok   {what}" else throw <| IO.userError s!"FAIL {what}"

/-- A field of a JSON object, as a string, or a marker naming what was missing —
so a failure prints the shape that arrived rather than an exception. -/
def field (j : Lean.Json) (path : List String) : String :=
  match path with
  | [] => match j.getStr? with
    | .ok s => s
    | .error _ => j.compress
  | k :: rest =>
    match j.getObjVal? k with
    | .ok v => field v rest
    | .error _ => s!"<no {k} in {j.compress}>"

/-- The stub's canned guide, which is also the first answer of every run. -/
def guideText : String :=
  "House style: two-space indent, no tabs, every public name documented, " ++
    "and failures returned rather than raised."

/-- The stub's canned patch. -/
def patchText : String :=
  "--- a/src/parse.c\n+++ b/src/parse.c\n@@\n" ++
    "-  char buf[64]; strcpy(buf, input);\n" ++
    "+  char buf[64]; snprintf(buf, sizeof buf, \"%s\", input);\n"

/-! ## Against the stub -/

/-- The handshake and the session, checked for the fields a real adapter sends.
`connect` has already made both calls; these repeat them on the live connection,
which is also a check that a second `initialize` is harmless. -/
def checkShapes (conn : Conn) : IO Unit := do
  let init ← conn.handshake
  check "initialize protocolVersion" "1" (field init ["protocolVersion"])
  check "initialize agentInfo.title" "Stub Agent" (field init ["agentInfo", "title"])
  checkTrue "initialize authMethods is an array"
    (match init.getObjVal? "authMethods" >>= Lean.Json.getArr? with
     | .ok _ => true | .error _ => false)
  let sess ← conn.request "session/new"
    (Lean.Json.mkObj [("cwd", Lean.Json.str (← IO.currentDir).toString),
                      ("mcpServers", Lean.Json.arr #[])])
  check "session/new sessionId is a 36-character UUID"
    "36" (toString (field sess ["sessionId"]).length)
  check "session/new currentModeId" "default" (field sess ["modes", "currentModeId"])
  checkTrue "session/new offers a configOptions catalogue"
    (match sess.getObjVal? "configOptions" >>= Lean.Json.getArr? with
     | .ok opts => opts.size > 0 | .error _ => false)

/-- Mode and model selection, both of which are protocol calls and either of
which a conforming adapter may refuse. -/
def checkSelection (conn : Conn) : IO Unit := do
  match ← conn.setMode "plan" with
  | .ok _ => IO.println "ok   session/set_mode"
  | .error e => throw <| IO.userError s!"FAIL session/set_mode: {e.compress}"
  -- What the adapter published at `session/new`, read back — the thing the live
  -- run against claude never looked at, and the reason `model='deep'` came back
  -- `Invalid value for config option model: deep` with no list of what would
  -- have worked.
  let models ← conn.optionValues "model"
  checkTrue "session/new's model catalogue was recorded" (models.length > 0)
  checkTrue "…a value the adapter advertises resolves to itself"
    (resolveValue models "reviewer" == .exact "reviewer")
  checkTrue "…a case variant resolves to the advertised spelling"
    (resolveValue models "REVIEWER" == .fuzzy "reviewer" "case-insensitively")
  checkTrue "…a name the adapter never advertised resolves to nothing at all"
    (resolveValue models "deeeep" == .unknown)
  checkTrue "…and whatever does resolve is a value the adapter itself named"
    (match (resolveValue models "stub").value? with
     | some v => models.contains v
     | none => true)
  -- An option the adapter does not publish is not a refusal: `optionValues`
  -- reads "it did not say" as the empty list, and `Exec.selectModel` sends the
  -- value as written in that case, which is what keeps codex working.
  check "an option the adapter never published reads as empty" "0"
    (toString (← conn.optionValues "no-such-option").length)
  match ← conn.setConfigOption "model" "reviewer" with
  | .ok res =>
    checkTrue "session/set_config_option returns the updated catalogue"
      (match res.getObjVal? "configOptions" >>= Lean.Json.getArr? with
       | .ok opts => opts.size > 0 | .error _ => false)
  | .error e =>
    throw <| IO.userError s!"FAIL session/set_config_option: {e.compress}"
  -- An option the adapter does not have is refused, and the refusal is a value:
  -- this is the path `Exec.selectScope` falls back to the prompt header on.
  match ← conn.setConfigOption "model" "no-such-model" with
  | .ok res => throw <| IO.userError s!"FAIL an unknown model was accepted: {res.compress}"
  | .error _ => IO.println "ok   an unknown model is refused, as a value"
  -- …and the wrong field name is a -32602, which is how `configOptionId` was
  -- found not to be the name of the field.
  match ← conn.tryRequest "session/set_config_option"
      (Lean.Json.mkObj [("sessionId", Lean.Json.str "9f3f7b1e-2c4a-4d5e-8f00-000000000001"),
                        ("configOptionId", Lean.Json.str "model"),
                        ("value", Lean.Json.str "reviewer")]) with
  | .ok _ => throw <| IO.userError "FAIL 'configOptionId' was accepted; the field is 'configId'"
  | .error e =>
    check "the wrong field name earns -32602" "-32602" (field e ["code"])

/-- The words `Agentic/Core/HardenPatch.lean` ends a verdict question with,
copied rather than imported: this module knows about the wire and not about the
semantics, and the point of repeating them here is that the answer-format
sentence is *part of the prompt the stub is keyed against*, so a stub that
matched on the whole prompt rather than on the question would fail. -/
def verdictSpec : String :=
  "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."

/-- The canned answers, which are also the check that chunks are concatenated
and that the 39 KB command catalogue did not break the framing. The prompts are
the flagship workload's, verbatim. -/
def checkAnswers (conn : Conn) : IO Unit := do
  let guide ← conn.prompt "Write out the house style guide, at most four short lines."
  check "guide (after a 39 KB catalogue line)" guideText guide
  let patch ← conn.prompt
    s!"Draft a patch satisfying:\nharden the parser\nReply with a unified diff only."
  check "draft" patchText patch
  -- The review prompts embed the guide and the patch: the stub must still key
  -- on the question, which is the one ordering fact the harness relies on.
  check "correct?" "APPROVE"
    (← conn.prompt s!"{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}")
  check "secure?" "APPROVE"
    (← conn.prompt s!"{guide}\nIs this patch secure?\n{patch}\n{verdictSpec}")
  check "simpler?" "APPROVE"
    (← conn.prompt s!"Could this patch be simpler?\n{patch}\n{verdictSpec}")
  check "consent" "yes"
    (← conn.prompt s!"Apply this patch?\n{patch}\nReply with exactly yes or no.")

/-- The stub, with the permission request granted (the default): the act
happens and the agent says so. -/
def granting (cfg : Config) : IO Unit := do
  withConn cfg fun conn => do
    checkShapes conn
    checkSelection conn
    checkAnswers conn
    let act ← conn.promptTurn
      s!"Apply:\n{patchText}\nWrite the patched file here, then reply DONE."
    check "act (permission granted)" "DONE" act.text
    check "act stopReason" "end_turn" act.stopReason.render

/-- The stub, with the permission request cancelled: **the turn still ends
`end_turn`**, and its text is an apology rather than an answer. This is the
measured behaviour of the real adapter when the client declines, and the reason
declining is a policy decision and not a default. -/
def cancelling (cfg : Config) : IO Unit := do
  withConn { cfg with permission := .cancel } fun conn => do
    let act ← conn.promptTurn s!"Apply:\n{patchText}"
    check "act stopReason when permission is cancelled" "end_turn" act.stopReason.render
    checkTrue "a cancelled permission launders into prose, not an error"
      (act.text != "DONE" && act.text.length > 0)

/-- The stub told to end the act turn as `cancelled`: the transport reports it
as such rather than flattening it to `end_turn`. -/
def cancelled (cfg : Config) : IO Unit := do
  withConn { cfg with args := cfg.args.push "--cancel=Apply:" } fun conn => do
    let act ← conn.promptTurn s!"Apply:\n{patchText}"
    check "a cancelled turn is reported as cancelled" "cancelled" act.stopReason.render

/-- The stub told to refuse `session/set_mode`, which is what codex does: the
refusal is a value and the connection is still usable. -/
def modeRefused (cfg : Config) : IO Unit := do
  withConn { cfg with args := cfg.args.push "--refuse-set-mode" } fun conn => do
    match ← conn.setMode "plan" with
    | .ok _ => throw <| IO.userError "FAIL set_mode was supposed to be refused"
    | .error e => check "a refused set_mode is a value" "-32602" (field e ["code"])
    check "…and the session still answers" guideText
      (← conn.prompt "Write out the house style guide, at most four short lines.")

/-! ## The handoff: a session this client did not open

Everything below is `Acp.Conn`'s three ways into a session, driven against the
stub's reproduction of the 0.66.0 shapes. The facts being checked are the two an
operator can act on — *the run is in the session it named*, and *none of that
session's history was read as an answer* — plus the two refusals, which are the
whole reason `initialize`'s capabilities are now read instead of discarded. -/

/-- The session the handoff tests continue. Deliberately **not** the stub's own
`SESSION_ID`: the point of a handoff is that the client asks for a session it
never opened, and the stub adopts the id it is given, exactly as the real
adapter's `getOrCreateSession` does. -/
def handoffId : String := "handoff-0001"

/-- The prompt whose canned answer is the guide; the first turn of every run. -/
def guidePrompt : String := "Write out the house style guide, at most four short lines."

/-- What the adapter said it would do, read off the handshake rather than
assumed. Both facts are gates: `loadSession` is a top-level boolean and `fork` is
a presence under `sessionCapabilities`, so a client that looked in one place
would have got one of them wrong. -/
def advertised (cfg : Config) : IO Unit := do
  withConn cfg fun conn => do
    let caps ← conn.capabilities
    checkTrue "initialize advertises loadSession, and it was recorded" caps.loadSession
    checkTrue "…and session/fork, which lives under sessionCapabilities" caps.forkSession
    checkTrue "…and the whole agentCapabilities object is kept for a caller who wants more"
      (match caps.raw.getObjVal? "promptCapabilities" with
       | .ok _ => true | .error _ => false)

/-- `session/load`: the run continues a transcript somebody else started.

The stub replays four canned updates before answering — a user chunk, an agent
chunk *saying `DONE`*, a tool call, and a chunk carrying an image — so this
checks three things at once: that the replay is drained rather than mistaken for
a reply, that a content type the answer-reader would refuse does not abort the
handoff, and that the connection afterwards prompts the **loaded** session (the
stub answers `-32602` to a prompt naming any other). -/
def loading (cfg : Config) : IO Unit := do
  withConn { cfg with session := .load handoffId } fun conn => do
    check "session/load leaves the connection in the session it asked for"
      handoffId ((← conn.sessionId.get).getD "<no session>")
    checkTrue "…and the loaded session's config catalogue was recorded, as after session/new"
      ((← conn.optionValues "model").length > 0)
    check "…and nothing replayed leaked into the next turn's answer" guideText
      (← conn.prompt guidePrompt)

/-- The same handoff against an adapter that answers `session/load` with `null`.
The schema requires no field of a `LoadSessionResponse`, so this is conforming,
and a client that demanded an object would refuse a session it could have had —
the catalogue is then empty, which `optionValues` already reads as "said
nothing" rather than "said no". -/
def loadingNull (cfg : Config) : IO Unit := do
  withConn { cfg with args := cfg.args.push "--load-null", session := .load handoffId }
    fun conn => do
      check "a null session/load result is a loaded session all the same"
        handoffId ((← conn.sessionId.get).getD "<no session>")
      check "…with no catalogue, which is not a refusal" "0"
        (toString (← conn.optionValues "model").length)
      check "…and the session answers" guideText (← conn.prompt guidePrompt)

/-- An adapter that never advertised `loadSession` — codex's position — refuses
the handoff *before* it is attempted, naming the adapter the caller named and the
flag to drop. -/
def loadRefused (cfg : Config) : IO Unit := do
  let complaint ← IO.mkRef ""
  try
    withConn { cfg with args := cfg.args.push "--no-load-session", session := .load handoffId }
      fun _ => pure ()
  catch e => complaint.set (toString e)
  let said ← complaint.get
  checkTrue s!"an adapter without loadSession refuses --session, by name (said: '{said}')"
    ((said.splitOn "adapter stub does not advertise loadSession").length > 1
      && (said.splitOn "run without --session").length > 1)

/-- `session/fork`: the run happens in a copy, and the copy has an id of its own.
That the connection moves to the **new** id is the whole difference from a load —
a client that kept the old one would be writing into the transcript a fork exists
to leave alone. -/
def forking (cfg : Config) : IO Unit := do
  withConn { cfg with session := .fork handoffId } fun conn => do
    check "session/fork leaves the connection in the NEW session it answered with"
      s!"{handoffId}-fork-1" ((← conn.sessionId.get).getD "<no session>")
    check "…and the fork answers" guideText (← conn.prompt guidePrompt)

/-- …and an adapter whose `sessionCapabilities` has no `fork` key refuses that
one, by name, in the same way. -/
def forkRefused (cfg : Config) : IO Unit := do
  let complaint ← IO.mkRef ""
  try
    withConn { cfg with args := cfg.args.push "--no-fork-session", session := .fork handoffId }
      fun _ => pure ()
  catch e => complaint.set (toString e)
  let said ← complaint.get
  checkTrue s!"an adapter without session/fork refuses --fork-session, by name (said: '{said}')"
    ((said.splitOn "adapter stub does not advertise session/fork").length > 1
      && (said.splitOn "run without --fork-session").length > 1)

/-! ## Against a real adapter -/

/-- Two short turns against a live adapter, in a fresh temporary directory: one
that only needs the model to speak, and one that needs a tool permission, which
is the path that cannot be tested any other way.

The second turn is deliberately the smallest act there is — write one word into
one file — and the check is on the *file*, not on the prose, because prose is
what a refused agent produces too. -/
def realChecks (adapter : Adapter) : IO Unit := do
  let dir := (← IO.Process.run { cmd := "mktemp", args := #["-d"] }).trimAscii.toString
  IO.println s!"real: cwd {dir}"
  let cfg : Config := { adapter, cwd := dir }
  try
    withConn cfg fun conn => do
      let turn ← conn.promptTurn "Reply with exactly: PONG"
      check "a real turn completes" "end_turn" turn.stopReason.render
      checkTrue s!"a real turn answers (said: '{turn.text}')"
        (turn.text.trimAscii.toString.endsWith "PONG")
      let act ← conn.promptTurn
        "Create a file named ok.txt here whose only content is the word HI. Then reply DONE."
      check "a real act turn completes" "end_turn" act.stopReason.render
      let wrote ← System.FilePath.pathExists (System.FilePath.mk dir / "ok.txt")
      checkTrue s!"the granted permission let the act happen (said: '{act.text}')" wrote
  finally
    discard <| IO.Process.run { cmd := "rm", args := #["-rf", dir] }

/-- A directory for the stub to act in, and the path to the stub made absolute.

The stub's `Apply:` turn *writes a file* now — an act that only says `DONE` is
an act nothing can be checked against — and it writes it in the session's
working directory, so that directory had better not be the repository. Making
the script path absolute is the other half: the child is started in the scratch
directory, where `test/stub_adapter.py` names nothing. -/
def stubScratch : IO (String × String) := do
  let dir := (← IO.Process.run { cmd := "mktemp", args := #["-d"] }).trimAscii.toString
  return (dir, (← IO.FS.realPath stubScript).toString)

def main (argv : List String) : IO UInt32 := do
  let adapterName := match argv.dropWhile (· != "--adapter") with
    | _ :: name :: _ => name
    | _ => "stub"
  try
    if adapterName == "stub" then
      let (dir, script) ← stubScratch
      -- Short timeouts: the stub answers instantly, and the generous defaults
      -- are for an agent that thinks.
      let cfg : Config :=
        { adapter := .stub script, cwd := dir
        , readTimeoutMs := some 20000, turnTimeoutMs := some 60000 }
      try
        granting cfg
        cancelling cfg
        cancelled cfg
        modeRefused cfg
        advertised cfg
        loading cfg
        loadingNull cfg
        loadRefused cfg
        forking cfg
        forkRefused cfg
      finally
        discard <| IO.Process.run { cmd := "rm", args := #["-rf", dir] }
    else
      realChecks (Adapter.ofName adapterName)
    IO.println s!"acp smoke: all checks passed ({adapterName})"
    return 0
  catch e =>
    IO.eprintln s!"acp smoke: {e}"
    return 1
