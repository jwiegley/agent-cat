import Agentic.Core.Certify

/-!
# The deck engine: a live `agent-deck` session, as an answering service

`Agentic/Core/Acp.lean` speaks a protocol over a pipe **this process owns**, to
an adapter **this process started**. This module does the other thing: it drives
the `agent-deck` command line against a session **somebody else started and is
watching**, one subprocess per operation. Nothing here is a second interpreter —
`Exec.askDecoding` is still the trusted base, `Exec.renderQ` still writes the
bytes and `Exec.nudge` still writes the re-ask — and nothing here is a second
adapter: `Acp.Adapter.ofName` is untouched, because a deck session is not a
program to spawn but a conversation to join.

## Why this exists at all: the negative verdict `--session` returned

`agent-cat run --session ID` is ACP's `session/load`, and `session/load` is a
**sequential handoff**: the adapter this process started restores the transcript,
replays it, and continues it. It cannot attach to a session that already has a
live writer, and there is no lock — so continuing a thread whose TUI is open
produces one interleaved rollout and tells nobody. That hazard is stated at the
flag, in `Acp.Conn.loadSession` and in the README, and it is enforced nowhere,
because nothing in that process is in a position to enforce it.

`agent-deck` **is** in that position: it is the control plane that owns the pane,
and `agent-deck session send` is how a message reaches a session that is being
watched, safely, with the deck arbitrating. So the two ways in are not rivals and
must not be confused:

* a thread with **no** live writer can be continued in place — `--engine acp
  --session ID`, and close the interactive owner first;
* a thread with a live writer must be **sent to** — `--engine deck --session ID`,
  and the pane stays exactly as it is.

**Never `session/load` a thread whose TUI is live.** One writer per rollout; the
deck's `send` is the safe path to a live session, and it is the whole reason this
module exists.

## The transport, in three commands

One question is one turn, and a turn is:

1. `agent-deck session output <id> --json` — *before* sending, to learn the
   timestamp of the reply that is already there. This is the **staleness guard**:
   `send` returns as soon as the message is submitted, so there is a window in
   which the agent has not begun and the session still looks idle. Without the
   guard, that window is read as an instant answer and the *previous* turn's text
   is recorded as this question's.
2. `agent-deck session send <id> <message>` — the question, `Exec.renderQ c q {}`
   plus whatever the re-ask appended. The message is one `argv` entry: no shell is
   involved, so it needs no quoting.
3. `agent-deck session show <id> --json`, every `Config.pollMs`, until the session
   is not working any more, and then `session output <id> --json` for the reply —
   accepted only once its `timestamp` differs from the one recorded in step 1.

The whole turn is bounded by `Config.turnTimeoutMs`: every subprocess call gets
what is left of that budget and the poll loop checks it before each poll, so a
session that never finishes produces `Error.timedOut` — naming the last status
seen — and never a hang.

## How idleness is detected

`session show <id> --json` carries `status` and `substate` (measured against
`agent-deck 1.11.0`; the same two fields appear per session in `status --verbose
--json`, while plain `status --json` is a fleet-wide count and cannot answer a
question about one session at all).

`status` is one of `running`, `waiting`, `idle`, `stopped`, `error`.
`livenessOfStatus` reads `running` as `busy`, `waiting` and `idle` as `idle` — a
Claude session that has finished its turn sits at `"status":"waiting",
"substate":"idle-at-empty-prompt"` — and `stopped` and `error` as `gone`, which is
a named refusal rather than a wait for something that will not happen. An
*unrecognized* status reads as `busy` on purpose: a future `agent-deck` that adds
a word should make this engine wait and then say what it was waiting for, rather
than declare a turn finished on a word it does not know.

## What this transport cannot do, said up front

`Exec.requiresCompletedTurn` says a receipt, or any answer from a person, may not
be recorded from a turn the agent did not finish. The `agent-deck` CLI reports no
stop reason — `session output` returns text and `session show` returns a status,
and neither says whether the agent ended its turn or was cut off — so this engine
**cannot** enforce that rule and does not pretend to: `unreported` is what it
hands `Settings.onTurn`, and a report that quotes it is telling the truth. An
`ack` read here is evidence that something replied; a run that needs more than
that needs the ACP transport, or a check on the workspace of the kind
`Agentic/Core/Artifact.lean` makes.

## The other thing this transport has no channel for

`Acp.Permission` answers a `session/request_permission` arriving mid-turn, and
`Exec.permissionByCode` decides — an act may write, an ask may not. There is no
such request here: the agent in the pane asks *its own* operator through the deck,
and this process is never consulted. So `Exec.Settings.permission` is not read by
this engine and a deck run reports no permission decisions, which is a true report
of what this process decided and not evidence that nothing was authorized. The
same follows for the command line's workspace check: the agent works in the deck
session's own directory, so a deck run's fingerprint comparison observes the run's
directory and not what the agent wrote. The run header says so.

## Where the discipline lives

Decoding, re-asking and abandonment are **not** here. `oracle` hands the transport
to `Exec.askDecoding`, which is `Exec.attemptWith` and the exhaustion error, so
the retry wording and the abandonment message exist once in this package and a run
against a deck session fails in the same words as a run against an adapter. The
routing rule is `Exec.toKeyboard`, for the same reason.

## Totality

No declaration here is `partial` and none contains a `panic!`: the poll loop is
structural on an explicit fuel derived from the turn budget, waiting on a
subprocess is `Acp.awaitTask`, and every JSON access goes through `Except` or
`Option`. A wedged session is bounded twice — by the fuel and by the deadline —
and both produce `Error.timedOut`.

## The Haskell counterpart

`haskell/src/Agentic/AgentDeck.hs` is this transport in the other implementation,
and `haskell/test/stub-deck.sh` is the fake both are tested against —
`test/DeckSmoke.lean` runs the *same script* as `haskell/ci/deck.sh`, so the two
implementations stay honest against one fixture. Where the two deliberately
differ is noted at the declaration that differs.
-/

namespace Agentic.Core.Deck

open Lean (Json)

/-! ## Small shared parts -/

/-- One line: a rendered question is one `argv` entry several lines long, and a
diagnostic that reported it whole would lose the line that says which command
failed in the middle of the prompt that failed with it. -/
def oneLine (s : String) : String :=
  String.intercalate " " ((s.splitOn "\n").filter (fun l => !l.trimAscii.isEmpty))

/-- A fragment short enough for a one-line diagnosis. -/
def clip (s : String) : String :=
  if s.length ≤ 120 then s else (s.take 117).toString ++ "..."

/-- `[[excerpt s]]` = a string as a diagnosis quotes it: trimmed, folded onto one
line, and clipped. The house style for a refusal that has to say what arrived. -/
def excerpt (s : String) : String := clip (oneLine s.trimAscii.toString)

/-! ## The configuration -/

/-- `[[Config]]` = which session, how to reach it, and how patiently to wait.

`pollMs` is the gap between two `session show` calls and `turnTimeoutMs` is the
budget for a whole turn — the stamp read, the send, the polling and the reply.
There is deliberately no retry knob: how many times an unreadable answer is
re-asked is `Exec.Settings.retries`, which is a fact about the language's trusted
base rather than about this transport.

The defaults are the deck's own: the binary found on `PATH`, a poll every second,
and ten minutes for a turn — which is `agent-deck session send`'s own `-timeout`
default, so the two agree on how long a live agent is allowed to think. -/
structure Config where
  /-- The session's id, or its title; `agent-deck` accepts either. -/
  session : String
  /-- The executable, looked up on `PATH` when it has no directory part. -/
  binary : String := "agent-deck"
  /-- Milliseconds between two polls of `session show`. -/
  pollMs : Nat := 1000
  /-- Milliseconds for one whole turn, after which `Error.timedOut`. -/
  turnTimeoutMs : Nat := 600000
  /-- Narrate the transport — every command, every poll — on stderr. Distinct
  from `Exec.Settings.log`, which reports what the *run* did about an unreadable
  answer and is never optional. -/
  verbose : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- How often to look at a finished child process, in milliseconds. Distinct from
`Config.pollMs`, which is how often the *session* is asked whether it is done: a
subprocess that has exited should be noticed at once, and a session that is
thinking should not be interrogated every five milliseconds. -/
def spawnPollMs : Nat := 5

/-! ## Failure -/

/-- The five ways this transport fails, each named, because an operator reading
one of these has to know whether to restart a session, fix a path or wait longer.

Decode exhaustion is **not** here: an answer that arrived and could not be read is
`Exec.askDecoding`'s error, in the wording every transport shares. The split is
the useful one — these are failures to *obtain* an answer, that one is a failure
to *read* one. -/
inductive Error where
  /-- The executable could not be run: the path, and what the OS said. -/
  | missing (binary : String) (why : String)
  /-- A command exited nonzero: the command, its exit code, and what it said
  about it — the `error` field of the JSON it refuses with, else its stderr, else
  its stdout. -/
  | commandFailed (cmd : String) (code : Nat) (said : String)
  /-- A command's stdout was not the JSON object expected: the command, and the
  stdout it produced. -/
  | unreadable (cmd : String) (out : String)
  /-- The session is not in a state that can answer: the session, and the
  `status/substate` observed. -/
  | notAlive (session : String) (seen : String)
  /-- The turn outran `Config.turnTimeoutMs`: the session, the budget, and what
  was last observed — the `status/substate` the poll loop had seen, or the
  command that did not return. -/
  | timedOut (session : String) (ms : Nat) (seen : String)
  deriving DecidableEq, Repr, Inhabited

/-- `[[e.render]]` = the failure as one sentence, prefixed `deck:` exactly as the
transport above prefixes its own `acp:`, so an operator reading one line of
stderr knows which engine is talking. -/
def Error.render : Error → String
  | .missing binary why =>
      s!"deck: could not run '{binary}': {why}"
  | .commandFailed cmd code said =>
      s!"deck: '{cmd}' exited {code}" ++ (if said.isEmpty then "" else s!" saying '{said}'")
  | .unreadable cmd out =>
      s!"deck: '{cmd}' did not answer with the JSON object expected; \
         it said '{excerpt out}'"
  | .notAlive session seen =>
      s!"deck: session '{session}' is {seen}, so nothing will answer; start it \
         (agent-deck session start {session}) and run again"
  | .timedOut session ms seen =>
      s!"deck: session '{session}' did not answer within {ms}ms; last observed: \
         {seen}. The question was abandoned rather than answered by this runtime"

/-- `[[e.transient]]` = may a caller reasonably wait and ask again?

Exactly the two failures a *command* can report that a session which has simply
not spoken yet also reports: `agent-deck session output` on a session with no
output exits nonzero, and that is the ordinary state of a session before its first
turn — not an error. A missing binary and an exhausted budget are not transient,
because neither becomes false by waiting, and reading them as "no output yet"
would turn a typo in `--engine deck`'s environment into a silent timeout. -/
def Error.transient : Error → Bool
  | .commandFailed .. | .unreadable .. => true
  | .missing .. | .notAlive .. | .timedOut .. => false

/-- **Clause equation.** A missing executable is never waited through. -/
@[simp] theorem Error.transient_missing (b w : String) :
    (Error.missing b w).transient = false := rfl

/-- **Clause equation.** Neither is an exhausted budget. -/
@[simp] theorem Error.transient_timedOut (s : String) (ms : Nat) (seen : String) :
    (Error.timedOut s ms seen).transient = false := rfl

/-- Abandon the run with this failure, in its own words. -/
def Error.raise {α : Type} (e : Error) : IO α := throw (IO.userError e.render)

/-! ## Liveness -/

/-- What a session's `status` means for a question in flight. -/
inductive Liveness where
  /-- The agent is working; wait. -/
  | busy
  /-- The agent is not working; its reply, if any, is readable. -/
  | idle
  /-- Stopped or errored: nothing will answer. -/
  | gone
  deriving DecidableEq, Repr, Inhabited

/-- The `status` vocabulary of `agent-deck 1.11.0`, read for this purpose.

`waiting` is `idle`, and that is the common case rather than the odd one: it is
what the TUI calls a session that wants the operator's attention, and a Claude
session that has just finished a turn reports `"status":"waiting"` with
`"substate":"idle-at-empty-prompt"`.

An unknown word is `busy` **on purpose**: waiting and then reporting
`Error.timedOut` with the unknown status quoted is a better failure than reading
an unfamiliar word as "the turn is over" and returning whatever text was lying
around. -/
def livenessOfStatus (s : String) : Liveness :=
  if s == "running" then .busy
  else if s == "waiting" then .idle
  else if s == "idle" then .idle
  else if s == "stopped" then .gone
  else if s == "error" then .gone
  else .busy

/-- **Clause equation.** A finished Claude turn sits at `waiting`, which is the
whole reason this engine can ever read a reply. -/
theorem livenessOfStatus_waiting : livenessOfStatus "waiting" = .idle := by decide

/-- **Clause equation.** A stopped session is a named refusal, not a wait. -/
theorem livenessOfStatus_stopped : livenessOfStatus "stopped" = .gone := by decide

/-- **A word this engine has never heard is `busy`.** Stated at a word no build
of `agent-deck` has ever emitted, because the point is precisely the vocabulary
this file does not know: a future status must cost a wait and a named timeout,
never a stale answer. -/
theorem livenessOfStatus_unknown : livenessOfStatus "compacting" = .busy := by decide

/-- The two fields of `session show <id> --json` this engine reads. -/
structure SessionState where
  /-- `status`: one of the five words `livenessOfStatus` classifies. -/
  status : String
  /-- `substate`, when the session's tool reports a finer one. -/
  substate : Option String := none
  deriving DecidableEq, Repr, Inhabited

/-- `[[s.words]]` = `status`, and `substate` after it when there is one — what the
verbose log and the two failure messages quote. -/
def SessionState.words (s : SessionState) : String :=
  match s.substate with
  | some sub => s!"{s.status}/{sub}"
  | none => s.status

/-- `session show <id> --json`'s object, or `none` if that is not what arrived.

An **empty** `substate` is the absence of one — `agent-deck` writes `""` for a
session whose tool reports no finer state — and reading it as a substate would put
a stray `/` in every message that quotes one. A missing session is not diagnosed
here: the CLI answers `{"success":false,"code":"NOT_FOUND",…}` with exit code 2,
so it is the exit code that reports it. -/
def parseSessionState (raw : String) : Option SessionState :=
  match Json.parse raw with
  | .error _ => none
  | .ok j =>
    match j.getObjVal? "status" >>= Json.getStr? with
    | .error _ => none
    | .ok status =>
      let sub := match j.getObjVal? "substate" >>= Json.getStr? with
        | .ok s => if s.isEmpty then none else some s
        | .error _ => none
      some { status, substate := sub }

/-! ## The reply -/

/-- `session output <id> --json`'s object: the last thing the session said, and
when it said it.

The timestamp is what makes a reply *this question's* reply. It is optional
because the guard has to degrade honestly: if a build of `agent-deck` stops
emitting one, `awaitReply` accepts the first reply seen after the session goes
idle rather than waiting for a field that will never change. -/
structure Reply where
  /-- `content`: what the session said. -/
  content : String
  /-- `timestamp`, if the build emits one. -/
  stamp : Option String := none
  deriving DecidableEq, Repr, Inhabited

/-- The reply object, or `none` if stdout was not one. -/
def parseReply (raw : String) : Option Reply :=
  match Json.parse raw with
  | .error _ => none
  | .ok j =>
    match j.getObjVal? "content" >>= Json.getStr? with
    | .error _ => none
    | .ok content =>
      some { content, stamp := (j.getObjVal? "timestamp" >>= Json.getStr?).toOption }

/-- `[[fresh before r]]` = is `r` an answer to the question just put, rather than
the text that was already lying in the session?

The reply is this question's when it is stamped differently from the one that was
there before the send — or when there is no stamp at all to compare, in which case
the wait for idleness is the whole guard. -/
def fresh (before : Option String) (r : Reply) : Bool :=
  r.stamp.isNone || r.stamp != before

/-- **The guard is a guard.** A reply carrying the stamp that was already there
is refused, whatever its text: this is the equation the `stale` fixture exercises,
and an engine without it reads every question's answer off the previous turn. -/
@[simp] theorem fresh_same (t c : String) :
    fresh (some t) { content := c, stamp := some t } = false := by simp [fresh]

/-- **…and an unstamped build still runs.** With no timestamp to compare there is
nothing to refuse, and idleness carries the whole guard. -/
@[simp] theorem fresh_unstamped (before : Option String) (c : String) :
    fresh before { content := c, stamp := none } = true := rfl

/-! ## Deadlines -/

/-- A point on the monotonic clock, in milliseconds. Monotonic and not
wall-clock, so a turn's budget is unaffected by a clock that steps. -/
structure Deadline where
  /-- `IO.monoMsNow` at which the turn's budget is spent. -/
  endMs : Nat
  deriving DecidableEq, Repr, Inhabited

/-- A budget of `ms` milliseconds, starting now. -/
def Deadline.starting (ms : Nat) : IO Deadline := return ⟨(← IO.monoMsNow) + ms⟩

/-- Milliseconds left, and `0` once the deadline has passed. -/
def Deadline.remainingMs (d : Deadline) : IO Nat := do
  let now ← IO.monoMsNow
  return if d.endMs ≤ now then 0 else d.endMs - now

/-! ## The three commands -/

/-- Transport narration, on stderr, only when asked for. -/
def chat (cfg : Config) (msg : String) : IO Unit :=
  if cfg.verbose then do (← IO.getStderr).putStrLn s!"agent-deck: {msg}"
  else pure ()

/-- What a failed command said about its own failure.

`agent-deck` reports a refusal as JSON on **stdout** with an empty stderr — a
missing session is `{"success":false,"code":"NOT_FOUND","error":"session 'x' not
found"}` and exit 2 — so a diagnosis that quoted stderr alone would say "exited 2"
and nothing else, on the most common mistake there is. Hence: the `error` field
first, then stderr, then stdout. -/
def explain (out err : String) : String :=
  match ([errorField, err, out].filter (fun s => !s.trimAscii.isEmpty)).head? with
  | some d => excerpt d
  | none => ""
where
  errorField : String :=
    match Json.parse out with
    | .ok j => (j.getObjVal? "error" >>= Json.getStr?).toOption.getD ""
    | .error _ => ""

/-- `[[locate cfg]]` = the executable, checked to be there before anything is
spawned, or the failure that names it.

**Why this is a step and not a `catch`.** `IO.Process.spawn` does not report a
missing program portably: on macOS it *succeeds* and the child exits 255 with a
line on stderr, so a run against a machine where `agent-deck` is not installed
would be diagnosed as "the command exited 255", which is the wrong sentence for
the most likely mistake there is. This is `Acp.Adapter.resolve`'s discipline at
the other transport, and it uses the same `Acp.searchPath`: a bare name is looked
up on `PATH`, a name with a directory part is checked where it points, and either
way the failure names the program and where it was looked for.

The spawn is still wrapped, because a program that exists and cannot be executed
— the wrong architecture, a lost permission bit — fails there and nowhere else. -/
def locate (cfg : Config) : IO (Except Error String) := do
  if (cfg.binary.splitOn "/").length > 1 then
    let p := System.FilePath.mk cfg.binary
    if (← p.pathExists) && !(← p.isDir) then return .ok cfg.binary
    return .error (.missing cfg.binary "there is no such file")
  match ← Acp.searchPath cfg.binary with
  | some _ => return .ok cfg.binary
  | none => return .error (.missing cfg.binary
      "it is not on PATH; install agent-deck, or give --engine deck a binary that is")

/-- Run one `agent-deck` command inside what is left of the turn's budget, and
return its stdout together with the command as it would be typed (for a failure
message).

A **value** and not an exception, because one caller — `currentReply` — must be
able to wait through a refusal that means "nothing said yet" while every other
caller abandons the run on the same shape. `Error.transient` is the distinction,
stated once.

Stdout and stderr are read on two tasks because a child that fills one pipe while
the other is being drained deadlocks; this is `IO.Process.output`'s own shape,
spelled out here only because the child is wanted as a value: on expiry it is
killed, which `IO.Process.output` gives no handle to do. -/
def command (cfg : Config) (dl : Deadline) (args : Array String) :
    IO (Except Error (String × String)) := do
  let words := String.intercalate " " (args.toList.map (fun a => clip (oneLine a)))
  let cmd := s!"{cfg.binary} {words}"
  let left ← dl.remainingMs
  if left == 0 then
    return .error (.timedOut cfg.session cfg.turnTimeoutMs
      s!"the turn's budget was spent before `{words}` could be run")
  chat cfg s!"$ {cmd}"
  match ← locate cfg with
  | .error e => return .error e
  | .ok _ =>
  match ← (IO.Process.spawn
      { cmd := cfg.binary, args
      , stdin := .null, stdout := .piped, stderr := .piped }).toBaseIO with
  | .error e => return .error (.missing cfg.binary (toString e))
  | .ok child =>
    let t ← IO.asTask (prio := .dedicated) do
      let errT ← IO.asTask (prio := .dedicated) child.stderr.readToEnd
      let out ← child.stdout.readToEnd
      let err ← IO.ofExcept errT.get
      let code ← child.wait
      return (code, out, err)
    match ← Acp.awaitTask t spawnPollMs (left / spawnPollMs + 1) with
    | none =>
      try child.kill catch _ => pure ()
      return .error (.timedOut cfg.session cfg.turnTimeoutMs
        s!"`{words}` did not return in time")
    | some (code, out, err) =>
      if code == 0 then return .ok (out, cmd)
      else return .error (.commandFailed cmd code.toNat (explain out err))

/-- `agent-deck session send <id> <message>`.

No liveness check precedes it, on purpose: `session send` waits for the agent to
be ready before it types, which is a better version of the check this module could
make, and a session that cannot take a message at all fails here with what it said
about why. -/
def sendMessage (cfg : Config) (dl : Deadline) (message : String) : IO Unit := do
  match ← command cfg dl #["session", "send", cfg.session, message] with
  | .ok _ => pure ()
  | .error e => e.raise

/-- `agent-deck session show <id> --json`, parsed. Every failure here abandons the
run: a session whose state cannot be read is not a session that might answer in a
moment. -/
def sessionState (cfg : Config) (dl : Deadline) : IO SessionState := do
  match ← command cfg dl #["session", "show", cfg.session, "--json"] with
  | .error e => e.raise
  | .ok (out, cmd) =>
    match parseSessionState out with
    | some s => return s
    | none => (Error.unreadable cmd out).raise

/-- `agent-deck session output <id> --json`, parsed — `none` when the session has
not said anything this command can return.

A session with no reply yet is not an error: it is the ordinary state of a session
that was just started, and the caller's job is to keep waiting. So a transient
refusal is swallowed *here* and nowhere else in this module. -/
def currentReply (cfg : Config) (dl : Deadline) : IO (Option Reply) := do
  match ← command cfg dl #["session", "output", cfg.session, "--json"] with
  | .ok (out, _) => return parseReply out
  | .error e =>
    if e.transient then
      chat cfg s!"no output yet: {e.render}"
      return none
    else e.raise

/-- The timestamp of whatever the session last said, before this question is put.
`none` when there is nothing, which makes the first reply fresh. -/
def currentStamp (cfg : Config) (dl : Deadline) : IO (Option String) :=
  return (← currentReply cfg dl) >>= Reply.stamp

/-! ## Waiting for the answer -/

/-- Wait for the session to stop working and say something new.

Two conditions, and both are needed. The session must be `idle` — it is `busy`
while the agent is composing — and the reply must be `fresh`, because `session
send` returns as soon as the message is submitted. Without the second condition
that window is read as an instant answer and the previous turn's text is recorded
as this question's.

`fuel` is the totality witness and the deadline is the guard: the fuel is derived
from the budget and the poll gap, so in every reachable configuration the deadline
fires first, and a fuel that ran out anyway reports the same timeout rather than
returning something it did not observe. -/
def awaitReply (cfg : Config) (dl : Deadline) (before : Option String) :
    Nat → String → IO String
  | 0, lastSeen => (Error.timedOut cfg.session cfg.turnTimeoutMs
      s!"{lastSeen}, with nothing said since the question went out").raise
  | n + 1, lastSeen => do
    if (← dl.remainingMs) == 0 then
      (Error.timedOut cfg.session cfg.turnTimeoutMs
        s!"{lastSeen}, with nothing said since the question went out").raise
    let st ← sessionState cfg dl
    let seen := st.words
    chat cfg s!"poll: {seen}"
    let again : IO String := do
      IO.sleep (max 1 cfg.pollMs).toUInt32
      awaitReply cfg dl before n seen
    match livenessOfStatus st.status with
    | .gone => (Error.notAlive cfg.session seen).raise
    | .busy => again
    | .idle =>
      match ← currentReply cfg dl with
      | some r =>
        if fresh before r then
          chat cfg s!"read {r.content.length} characters"
          return r.content
        else again
      | none => again

/-- How many times `awaitReply` may go round: the turn's budget divided by the
poll gap, and two to spare so that the *deadline* is what a wedged session runs
into rather than an off-by-one in the fuel. -/
def pollFuel (cfg : Config) : Nat := cfg.turnTimeoutMs / max 1 cfg.pollMs + 2

/-! ## One question, one turn -/

/-- Put the rendered question to the session and return what it said.

The three commands in order, on a fresh budget. Every turn gets its own
`turnTimeoutMs`, re-asks included: a second attempt is a second turn, and charging
it what the first one spent would make a slow answer unaskable twice. -/
def sayToSession (cfg : Config) (c : Code) (q : Q c) (text : String) : IO String := do
  let dl ← Deadline.starting cfg.turnTimeoutMs
  chat cfg s!"put {Exec.Code.name c} to {Exec.Addressee.render q.addressee} \
              ({text.length} characters)"
  let before ← currentStamp cfg dl
  sendMessage cfg dl text
  awaitReply cfg dl before (pollFuel cfg) "not yet polled"

/-- What this engine hands `Exec.Settings.onTurn` as a stop reason, because the
`agent-deck` CLI reports none.

`Acp.StopReason.other` is the constructor for a word this package did not coin,
and it renders verbatim (`Acp.StopReason.render_ofString`), so a report of a deck
run says `unreported` where an ACP run says `end_turn`. That is the honest entry:
the alternative — writing `end_turn` — would be this runtime asserting that a turn
completed when nothing on the wire said so, which is exactly the assertion
`Exec.requiresCompletedTurn` exists to refuse. -/
def unreported : Acp.StopReason := .other "unreported"

/-- `[[say cfg st c q extra]]` = `Exec.say` at this transport: render the
question, append what the caller wants appended, and get the bytes — from the
person at the keyboard, or from the session.

**The routing rule is `Exec.toKeyboard` and not a rule of this module's own.** A
`person` question goes to stdin when `Exec.Settings.askPersonOnStdin` is set —
which for a deck run is the default, because the operator watching the pane *is*
the person the workflow means — and to the pane otherwise. `agent-cat
--all-to-session` clears the setting, which sends the person's questions into the
pane with everybody else's; that is the Haskell reference's unconditional
behaviour (`Agentic.AgentDeck`: "everything goes to the one session"), offered
here as a choice rather than as the only option, because a person answering in
their own terminal costs no tokens and cannot be answered by an agent playing
their part.

`extra` is `Exec.nudge`'s output on a re-ask and empty on a first attempt; it is
appended after the prompt, so the addressee sees what it said and why it could not
be read at the end of the message rather than before the question. -/
def say (cfg : Config) (st : Exec.Settings) (c : Code) (q : Q c) (extra : String) :
    IO String := do
  let t₀ ← IO.monoMsNow
  let text := Exec.renderQ c q {} ++ extra
  let reply ← match q.addressee, Exec.toKeyboard st q.addressee with
    | .person who, true => Exec.askPersonStdin who text
    | _, _ => sayToSession cfg c q text
  st.onTurn c q.addressee unreported ((← IO.monoMsNow) - t₀)
  return reply

/-- `[[Deck.oracle cfg st]]` = the answering service that puts questions to a live
`agent-deck` session.

One line, and every part of it is elsewhere: `Exec.askDecoding` is the trusted
base's discipline — the attempts, the nudge, the abandonment — and `say` is the
bytes. There is no scope call, because the `agent-deck` CLI has neither
`session/set_mode` nor `session/set_config_option`, so both axes of a question's
scope travel in `Exec.renderQ`'s header with `Selected` empty. That is the
fallback `Exec.renderQ` documents, not an invention here.

Note what this function is *not*, exactly as `Exec.oracle` is not: it is an
`Oracle IO`, the argument the theorems quantify over, and a session that lies
through it merely exhibits a different world. -/
def oracle (cfg : Config) (st : Exec.Settings) : Oracle IO := fun c q _ =>
  Exec.askDecoding st (fun c q extra => say cfg st c q extra) c q

/-- `[[Deck.execCertifiedIO cfg st p]]` = the plan run against a live deck
session, with the warrant attached: the answer, the world the run constructed, and
whether replaying that world reproduces the answer.

`Agentic.Core.execCertifiedIO` with one argument replaced, so a deck run is
checked by exactly the machinery an ACP run is checked by
(`Plan.runCertified_certified` at `Id`). There is no bracket to open and close:
this engine owns no process that outlives a command. -/
def execCertifiedIO {A : Type} [DecidableEq A] (cfg : Config) (st : Exec.Settings := {})
    (p : Plan [] A) : IO (A × Table × Bool) :=
  Plan.runCertified (oracle cfg st) p

end Agentic.Core.Deck
