import Agentic.Core.Deck

/-!
# The deck engine, driven end to end against a fake `agent-deck`

Run from the repository root:

```
lake exe deck_smoke
```

`test/AcpSmoke.lean` checks the wire and `test/ExecSmoke.lean` checks the layer
above it; this checks the *other* transport — `Agentic/Core/Deck.lean`, which
reaches an agent by shelling out to `agent-deck` rather than by owning a pipe.
Every assertion is a claim about the `IO` layer that no proof in the package
makes.

**The fake is `haskell/test/stub-deck.sh`, unmodified and in place.** That is the
point rather than an economy: `haskell/ci/deck.sh` runs the same script against
`Agentic.AgentDeck`, so the Lean engine and the Haskell one are held against
*one* fixture and cannot drift into agreeing with two different fakes about what
`agent-deck` does. It is driven through a three-line wrapper this test writes per
scenario, because the script is configured by environment variables and Lean has
no `setenv`; the wrapper sets them and `exec`s the script, so what runs is the
script's own bytes.

What each scenario is for:

* **happy** — the ordinary turn. Three distinct questions, four `askC` nodes, and
  therefore three messages: the memo table observed *from outside the process*,
  which is the one place `Dlg.execM`'s look-up-before-asking is visible as a
  message that was never sent. The run certifies.
* **the format line** — what actually went out. Every question carried
  `Exec.renderQ`'s header, and every header carried `Exec.answerSpec` for its
  code, checked against the constant rather than against a copy of it: a change
  to the trusted base's wording must break this test.
* **slow** — the same run against a session that reports `running` four times
  before it settles. The poll loop is the whole of what makes a live agent usable
  and it is otherwise unobserved.
* **stale** — a session that answers but never re-stamps its reply. The first
  turn is fine; from the second on, the text lying in the session is the previous
  turn's, and reading it would record an answer to a question that was never put.
  The **send count** is the sharp assertion: an engine without the timestamp guard
  sails through all three questions and exits 0.
* **undecodable** — the owner says `maybe`, twice. `Exec.askDecoding` re-asks once
  with `Exec.nudge` and then abandons rather than recording a consent nobody gave.
  Checked in the trusted base's own words, because the point of `askDecoding`
  taking a transport is that both engines fail identically.
* **hang** — a session that never stops working. Bounded by the turn budget, and a
  named failure rather than a wedged test.
* **stopped** — a session that will never answer at all, told apart from one that
  is merely slow.
* **missing** — no such executable.

…and then the command line, twice, against the same fake on a private `PATH`:
once with the routing default (a `person` is asked at *this* terminal, so the
pane is sent six of the flagship's seven questions) and once with
`--all-to-session` (the pane is sent all seven). The gap between six and seven is
the routing rule, made out of bytes.
-/

open Agentic.Core
open Agentic.Core.Plan

/-! ## The program -/

/-- The guide question: asked twice by the plan, sent once to the session. -/
def guideQ : Q .text :=
  { addressee := .model "author", scope := 1, prompt := "Write out the house style guide.",
    draw := 0 }

/-- The consent question, addressed to a **person** — the addressee whose routing
is a decision (`Exec.toKeyboard`) and not a default. -/
def consentQ : Q .flag :=
  { addressee := .person "owner", scope := 1, prompt := "Apply this patch?", draw := 0 }

/-- The act: an `.ack` addressed to a tool. -/
def actQ : Q .ack :=
  { addressee := .tool "apply", scope := 1, prompt := "Apply:\nthe patch", draw := 0 }

/-- Guide, consent, act, then the guide **again** — the same question, so the
fourth node must be a table hit and not a fourth message. -/
def smoke : Plan [] (El .text × El .flag × El .ack × El .text) :=
  .askC .text guideQ <|
    .askC .flag consentQ <|
      .askC .ack actQ <|
        .askC .text guideQ <|
          .ret (fun γ =>
            ( Var.get (.there (.there (.there .here))) γ
            , Var.get (.there (.there .here)) γ
            , Var.get (.there .here) γ
            , Var.get .here γ ))

/-- What the fixture answers a `text` question about the house style with. -/
def guideText : String :=
  "House style: two-space indent, no tabs, every public name documented, " ++
    "and failures returned rather than raised."

/-! ## Assertions -/

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

/-- Fail loudly on a claim that is simply supposed to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then IO.println s!"ok   {what}" else throw <| IO.userError s!"FAIL {what}"

/-- `hay` contains `needle`. Substring and not equality: a diagnosis is one long
sentence and what is under test is the part of it that names the fault. -/
def has (needle hay : String) : Bool := (hay.splitOn needle).length > 1

/-- …and the same as an assertion, quoting what was searched when it fails. -/
def checkHas (what needle hay : String) : IO Unit :=
  if has needle hay then IO.println s!"ok   {what}"
  else throw <| IO.userError s!"FAIL {what}\n  wanted to find: {needle}\n  in:             {hay}"

/-- How a liveness reading prints, for a check that quotes both sides. -/
def sayLiveness : Deck.Liveness → String
  | .busy => "busy"
  | .idle => "idle"
  | .gone => "gone"

/-- What a run that was supposed to be abandoned actually did, as one word. -/
def outcome {α : Type} : Except IO.Error α → String
  | .ok _ => "completed"
  | .error _ => "abandoned"

/-- …and what it said about it, for the assertions that read the diagnosis. -/
def said {α : Type} : Except IO.Error α → String
  | .ok _ => ""
  | .error e => toString e

/-! ## The fake -/

/-- The fake `agent-deck`, where it lives — in the Haskell tree, because it is
*shared* and not copied. `haskell/ci/deck.sh` installs this same file for
`Agentic.AgentDeck`; running the two implementations against one fixture is the
only thing that keeps them honest about a CLI neither of them may call for real
in a test. -/
def stubDeck : String := "haskell/test/stub-deck.sh"

/-- One scenario's private world: a state directory the script owns, and a `bin`
holding the wrapper that `PATH` or `Config.binary` reaches. -/
structure Fake where
  /-- `DECK_STUB_STATE`: where the fixture keeps its reply, its seq and its send
  count. -/
  state : String
  /-- The directory holding the `agent-deck` wrapper, for `PATH`. -/
  bin : String

/-- Install the fixture for one scenario.

The wrapper exists because the script is configured by environment variables and
this Lean has no `setenv`: three lines that set the three variables and `exec` the
script, so the bytes that answer are the script's own and the mode is per
scenario rather than per process. -/
def install (root name mode : String) (busy : Nat := 1) : IO Fake := do
  let state := s!"{root}/{name}"
  let bin := s!"{state}/bin"
  IO.FS.createDirAll (System.FilePath.mk bin)
  let script := (← IO.FS.realPath (System.FilePath.mk stubDeck)).toString
  let wrapper := s!"{bin}/agent-deck"
  IO.FS.writeFile (System.FilePath.mk wrapper) (String.intercalate "\n"
    [ "#!/bin/sh"
    , s!"DECK_STUB_STATE='{state}' DECK_STUB_MODE='{mode}' DECK_STUB_BUSY='{busy}'; \
         export DECK_STUB_STATE DECK_STUB_MODE DECK_STUB_BUSY"
    , s!"exec '{script}' \"$@\""
    , "" ])
  discard <| IO.Process.run { cmd := "chmod", args := #["+x", wrapper] }
  -- **Refuse to continue if the fake is not there.** The command-line scenarios
  -- put this directory first on `PATH` so that the lookup a real invocation makes
  -- is the lookup under test; if the wrapper were missing, that same lookup would
  -- find a *real* `agent-deck` on a developer's machine and this test would send
  -- the flagship's questions into somebody's live session. It has never happened
  -- and it must never be able to.
  unless (← System.FilePath.pathExists (System.FilePath.mk wrapper)) do
    throw <| IO.userError s!"deck_smoke: the fake agent-deck was not installed at \
      '{wrapper}'; refusing to run, because a PATH lookup that misses it finds a \
      real agent-deck instead"
  return { state, bin }

/-- A file the fixture may not have written yet, or the fallback. -/
def readOr (path fallback : String) : IO String := do
  if ← System.FilePath.pathExists (System.FilePath.mk path) then
    return (← IO.FS.readFile (System.FilePath.mk path)).trimAscii.toString
  else return fallback

/-- How many messages the session was actually sent — the number no assertion
inside the process can produce, and therefore the one that says what the memo
table and the staleness guard really did. -/
def sends (f : Fake) : IO String := readOr s!"{f.state}/sends" "0"

/-- Every message the session was sent, concatenated: what went on the wire. -/
def prompts (f : Fake) : IO String := readOr s!"{f.state}/prompts" ""

/-- The engine, pointed at one scenario's fixture. The clocks are short because
the fixture answers instantly: the generous defaults are for an agent that
thinks, and a test that hangs for ten minutes is a test nobody runs. -/
def cfgOf (f : Fake) (turnTimeoutMs : Nat := 30000) : Deck.Config :=
  { session := "stub", binary := s!"{f.bin}/agent-deck", pollMs := 20, turnTimeoutMs }

/-- Settings that keep their warnings instead of printing them, and that route a
`person` into the session, because this test has no keyboard. That is
`agent-cat --all-to-session`'s setting, and the *other* half of the routing rule
is checked through the command line below, where stdin can be piped. -/
def settings (warnings : IO.Ref (Array String)) (retries : Nat := 1) : Exec.Settings :=
  { retries, askPersonOnStdin := false, log := fun m => warnings.modify (·.push m) }

/-! ## The command line, against the same fake -/

/-- Where the built command line is, relative to the repository root — which is
therefore where this must be run from. -/
def cliPath : String := ".lake/build/bin/agent-cat"

/-- The flagship, whose seven questions include exactly one addressed to a
person: the program that can tell the two routings apart. -/
def hardenPath : String := "example/harden.wf"

/-- Run the built command line with this scenario's fixture first on `PATH`, so
that a run passing no path to the binary exercises the same lookup a real
invocation does. -/
def cli (f : Fake) (args : List String) (stdin : Option String := none) :
    IO (UInt32 × String) := do
  let path := (← IO.getEnv "PATH").getD ""
  let r ← IO.Process.output
    { cmd := cliPath, args := args.toArray
    , env := #[("PATH", some s!"{f.bin}:{path}")] } stdin
  return (r.exitCode, r.stdout ++ r.stderr)

/-! ## The run -/

def main : IO UInt32 := do
  IO.println "deck smoke: the deck engine against haskell/test/stub-deck.sh"
  let root := (← IO.Process.run { cmd := "mktemp", args := #["-d"] }).trimAscii.toString
  try
    -- The readings first, and without a process: these need no fixture, and an
    -- engine that misreads `session show` has nothing else worth checking.
    check "livenessOfStatus 'running'" "busy" (sayLiveness (Deck.livenessOfStatus "running"))
    check "livenessOfStatus 'waiting' (a finished Claude turn)" "idle"
      (sayLiveness (Deck.livenessOfStatus "waiting"))
    check "livenessOfStatus 'idle'" "idle" (sayLiveness (Deck.livenessOfStatus "idle"))
    check "livenessOfStatus 'stopped'" "gone" (sayLiveness (Deck.livenessOfStatus "stopped"))
    check "livenessOfStatus 'error'" "gone" (sayLiveness (Deck.livenessOfStatus "error"))
    check "livenessOfStatus of a word this engine has never heard is busy, so it waits"
      "busy" (sayLiveness (Deck.livenessOfStatus "compacting"))
    -- …on the shapes the fixture (and agent-deck 1.11.0) really emit.
    check "session show, parsed"
      "waiting/idle-at-empty-prompt"
      (match Deck.parseSessionState
        "{\"id\":\"s\",\"title\":\"stub\",\"status\":\"waiting\",\"substate\":\"idle-at-empty-prompt\"}" with
       | some st => st.words
       | none => "unreadable")
    check "…and an empty substate is the absence of one, not a stray slash"
      "waiting"
      (match Deck.parseSessionState "{\"status\":\"waiting\",\"substate\":\"\"}" with
       | some st => st.words
       | none => "unreadable")
    check "…and anything that is not that object is unreadable" "unreadable"
      (match Deck.parseSessionState "not json" with
       | some st => st.words
       | none => "unreadable")
    check "session output, parsed" "yes@stub-1"
      (match Deck.parseReply "{\"content\":\"yes\",\"timestamp\":\"stub-1\"}" with
       | some r => s!"{r.content}@{r.stamp.getD "-"}"
       | none => "unreadable")
    checkTrue "a reply stamped as it was before the send is not this question's answer"
      (!Deck.fresh (some "stub-1") { content := "yes", stamp := some "stub-1" })
    checkTrue "…and a reply stamped later is"
      (Deck.fresh (some "stub-1") { content := "yes", stamp := some "stub-2" })
    checkTrue "…and a build that emits no timestamp still runs, on idleness alone"
      (Deck.fresh (some "stub-1") { content := "yes", stamp := none })
    -- The routing rule, which both engines share (`Exec.toKeyboard`).
    checkTrue "a model is never asked at the keyboard"
      (!Exec.toKeyboard { askPersonOnStdin := true } (.model "author"))
    checkTrue "…nor a tool" (!Exec.toKeyboard { askPersonOnStdin := true } (.tool "apply"))
    checkTrue "…and a person is, exactly when the runtime was told one is there"
      (Exec.toKeyboard { askPersonOnStdin := true } (.person "owner")
        && !Exec.toKeyboard { askPersonOnStdin := false } (.person "owner"))

    -- 1. The ordinary turn.
    let warnings ← IO.mkRef (#[] : Array String)
    let happy ← install root "happy" "happy"
    let res ← Deck.execCertifiedIO (cfg := cfgOf happy) (st := settings warnings) smoke
    let g₁ : String := res.1.1
    let consented : Bool := res.1.2.1
    let g₂ : String := res.1.2.2.2
    check "the guide, read off the session" guideText g₁
    check "the consent" "yes" (if consented then "yes" else "no")
    check "the guide again, from the memo table" guideText g₂
    check "table size (one entry per distinct question)" "3"
      (toString (List.length (res.2.1 : List ((c : Code) × Q c × El c))))
    check "the run certifies" "true" (toString res.2.2)
    -- The memo table, from outside the process: four ask nodes, three messages.
    check "…and the session was sent one message per distinct question, not per node"
      "3" (← sends happy)

    -- 2. What actually went on the wire.
    let sent ← prompts happy
    checkHas "every question carried Exec.renderQ's header"
      "[question for model author" sent
    checkHas "…including the person's, routed into the session by askPersonOnStdin := false"
      "[question for person owner" sent
    checkHas "…and the text question's answer format, from Exec.answerSpec itself"
      s!"answer (text): {Exec.answerSpec .text}]" sent
    checkHas "…and the flag's" s!"answer (flag): {Exec.answerSpec .flag}]" sent
    checkHas "…and the act's" s!"answer (ack): {Exec.answerSpec .ack}]" sent

    -- 3. A session that takes its time.
    let slow ← install root "slow" "happy" (busy := 4)
    -- …and with the transport narrating itself, so `Config.verbose`'s path runs
    -- here rather than only in an operator's terminal. The poll lines go to
    -- stderr; what is asserted is the answer, which must be unchanged by them.
    let slowRes ← Deck.execCertifiedIO (cfg := { cfgOf slow with verbose := true })
      (st := settings warnings) smoke
    check "a session that reports `running` four times before it settles still answers"
      guideText (slowRes.1.1 : String)
    check "…and was sent the same three messages" "3" (← sends slow)

    -- 4. The staleness guard.
    let stale ← install root "stale" "stale"
    -- 8000ms, not 1500: the assertion is about the GUARD, not the clock, and a
    -- loaded machine once starved the 1500ms budget before the first send went
    -- out (0 sends observed where the guard's 2 were expected). The scenario is
    -- still bounded — the stub never re-stamps, so the run always abandons.
    let staleRun ← (Deck.execCertifiedIO (cfg := cfgOf stale (turnTimeoutMs := 8000))
      (st := settings warnings) smoke).toBaseIO
    check "a session that never re-stamps its reply is not read twice from one turn"
      "abandoned" (outcome staleRun)
    checkHas "…and says which budget it outran" "did not answer within 8000ms" (said staleRun)
    -- The sharp one: without the guard the previous turn's text answers every
    -- question, all three sends go out and the run exits 0.
    check "…having stopped at the second question rather than reading the first one's text again"
      "2" (← sends stale)

    -- 5. An answer nobody can read: the nudge, then abandonment.
    let reAsk ← IO.mkRef (#[] : Array String)
    let maybe ← install root "undecodable" "undecodable"
    let maybeRun ← (Deck.execCertifiedIO (cfg := cfgOf maybe)
      (st := settings reAsk) smoke).toBaseIO
    check "a flag nobody can read abandons the run" "abandoned" (outcome maybeRun)
    checkHas "…in the words every transport in this package abandons a run with"
      "no readable flag from person owner after 2 attempts" (said maybeRun)
    checkHas "…quoting what was actually said" "last reply: 'maybe'" (said maybeRun)
    checkTrue "…having warned before it re-asked"
      ((← reAsk.get).any (has "could not read a flag from 'maybe'; re-asking"))
    checkHas "…and the second attempt carried Exec.nudge, not a verbatim repeat"
      (Exec.nudge .flag "maybe") (← prompts maybe)
    check "…and the session saw three messages: the guide, the flag, the flag again"
      "3" (← sends maybe)

    -- 6. A session that never finishes.
    let hang ← install root "hang" "hang"
    let hangRun ← (Deck.execCertifiedIO (cfg := cfgOf hang (turnTimeoutMs := 800))
      (st := settings warnings) smoke).toBaseIO
    check "a session that never stops working is a named failure, not a hang"
      "abandoned" (outcome hangRun)
    checkHas "…naming the session and the budget"
      "deck: session 'stub' did not answer within 800ms" (said hangRun)

    -- 7. A session that will never answer.
    let stopped ← install root "stopped" "stopped"
    let stoppedRun ← (Deck.execCertifiedIO (cfg := cfgOf stopped)
      (st := settings warnings) smoke).toBaseIO
    check "a stopped session is a refusal and not a wait" "abandoned" (outcome stoppedRun)
    checkHas "…said as itself" "deck: session 'stub' is stopped, so nothing will answer"
      (said stoppedRun)
    checkHas "…with what to do about it" "agent-deck session start stub" (said stoppedRun)

    -- 8. No such executable.
    let missing ← install root "missing" "happy"
    let missingRun ← (Deck.execCertifiedIO
      (cfg := { cfgOf missing with binary := s!"{root}/no-such-agent-deck" })
      (st := settings warnings) smoke).toBaseIO
    check "a binary that is not there is a named failure" "abandoned" (outcome missingRun)
    checkHas "…naming the path that was tried"
      s!"deck: could not run '{root}/no-such-agent-deck'" (said missingRun)
    check "…and nothing was sent" "0" (← sends missing)

    -- 9. The command line, and the routing rule made out of bytes.
    if !(← System.FilePath.pathExists (System.FilePath.mk cliPath)) then
      throw <| IO.userError
        s!"deck_smoke: no binary at '{cliPath}' — run `lake build` from the repository root first"
    let viaCli ← install root "cli" "happy"
    let (code, out) ← cli viaCli
      ["run", hardenPath, "--engine", "deck", "--session", "stub",
       "--poll-ms", "20", "--turn-timeout-ms", "30000", "--quiet"]
      (stdin := some "yes\n")
    check "a --engine deck run of the flagship exits 0" "0" (toString code)
    checkTrue "…and bills the flagship's seven consultations"
      (has "agent-cat: 7 consultations" out)
    -- The routing default: the operator watching the pane is the person, so the
    -- owner's question was asked *here* and the pane never saw it.
    check "…of which the pane was sent six, the owner having been asked at this terminal"
      "6" (← sends viaCli)
    let allTo ← install root "cli-all" "happy"
    let (codeAll, outAll) ← cli allTo
      ["run", hardenPath, "--engine", "deck", "--session", "stub",
       "--poll-ms", "20", "--turn-timeout-ms", "30000", "--all-to-session", "--quiet"]
    check "…and with --all-to-session it exits 0 too" "0" (toString codeAll)
    checkTrue "…billing the same seven" (has "agent-cat: 7 consultations" outAll)
    check "…all seven of which the pane was sent" "7" (← sends allTo)
    -- The header, where the operator is looking: the safety fact, and the
    -- workspace caveat that a deck run's directory is not the agent's.
    let (codeLoud, outLoud) ← cli allTo
      ["run", "example/hello.wf", "--engine", "deck", "--session", "stub",
       "--poll-ms", "20", "--turn-timeout-ms", "30000", "--all-to-session"]
    check "a loud --engine deck run exits 0" "0" (toString codeLoud)
    checkHas "…and its header says the deck owns the pane and this is the safe way in"
      "which owns the pane; this is the safe way into a session whose TUI is live" outLoud
    checkHas "…and names the call that must never be aimed there"
      "--engine acp --session must never be aimed at" outLoud
    checkHas "…and says the workspace check cannot see what the agent wrote"
      "the agent works in the deck session's own directory" outLoud

    IO.println "deck smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"deck smoke: {e}"
    return 1
  finally
    discard <| IO.Process.run { cmd := "rm", args := #["-rf", root] }
