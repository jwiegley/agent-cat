import Lean.Data.Json

/-!
# ACP: the wire, and nothing but the wire

A minimal Agent Client Protocol client — line-delimited JSON-RPC 2.0 over a
child process's stdio — sufficient to start an adapter, open a session in a
working directory, send one prompt and read back the text the agent streamed.

**This module makes no semantic claims, and that is deliberate.** Nothing here
is a morphism, nothing here has an equation, and no theorem in the package
mentions any declaration of this file. It contains no `Ω`, no `Q`, no `Dlg` and
no `Plan`; it does not import `Agentic.Core.Question`, so it *cannot* say
anything about worlds, questions or answers even by accident. What a run means
is settled in `Agentic/Core/Exec.lean` (the memoizing interpreter, whose
`Table` is a finite world) and `Agentic/Core/Certify.lean` (the decidable
per-run certificate); the kernel's account of why the meaning lives there and
not here is `rederivation-kernel.md` §5.

**The trust boundary, stated rather than axiomatized.** Three assumptions are
made *by this file's code* and are discharged by nothing:

1. the child process is the addressee the caller believes it is;
2. the bytes it writes are the bytes that addressee meant;
3. `String`, the type these calls return, is what the answer *is* — turning one
   into an `El c` is the single total parsing function per `Code` that the
   kernel names as the remaining trust boundary, and it lives in `Exec`.

None of the three is an `axiom` command, and none is needed by any proof: the
adequacy theorem quantifies over *all* worlds extending the run's table, so an
adapter that lies merely exhibits a different world and the theorem still holds
of it. That is the whole reason a transport is allowed to be ordinary `IO`
code.

**Totality.** No declaration here is `partial`, and none contains a `panic!`,
an unchecked index or a `sorry`: every loop is structural on an explicit fuel
taken from `Config`, every JSON access goes through `Except`, and every failure
becomes an `IO.userError` quoting the offending line. A wedged adapter is
bounded by `Config.timeoutMs`: each pipe operation runs on a dedicated task and
is polled, so a blocked read *or write* is interruptible.

`#print axioms` on the entry points reports only `propext`, `Classical.choice`
and `Quot.sound`, all of them inherited from Lean core's JSON parser; this
module declares no axiom of its own, and no proof in the package depends on
anything here.

Protocol references (ACP schema v1, `agentclientprotocol.com`): `initialize`
with `protocolVersion := 1`; `session/new` with an absolute `cwd`;
`session/prompt` with a `ContentBlock` array, answered by a `stopReason` after
zero or more `session/update` notifications; `session/cancel` as a
notification. Note that ACP v1 defines **no** `session/set_model`: a model is
not a protocol concept, so `Conn.setMode` (`session/set_mode`) is offered
because it is in the schema, and anything adapter-specific goes through the
public `Conn.request` rather than being guessed at here.

The stub adapter `test/stub_adapter.py` answers this client deterministically;
`test/AcpSmoke.lean` is the round trip.
-/

namespace Agentic.Core.Acp

open Lean (Json)

/-! ## Configuration -/

/-- `[[Config]]` = the recipe for starting one adapter process: which program,
in which directory, and how long the runtime will wait for it to say anything.

The value represents *intent to spawn*, not a live process — `connect` turns it
into a `Conn`. The defaults name the adapter the owner runs
(`claude-agent-acp`) and the current directory; a test overrides `cmd`/`args`
to point at `test/stub_adapter.py`.

The fuels are configuration rather than constants because they are why no loop
in this file is `partial`: `maxMessages` bounds how many wire messages one
request may sift through, and `timeoutMs`/`pollMs` bound one pipe
operation. -/
structure Config where
  /-- The adapter program. -/
  cmd : String := "claude-agent-acp"
  /-- Arguments passed to the adapter. -/
  args : Array String := #[]
  /-- The session's working directory; sent to `session/new` made absolute. -/
  cwd : System.FilePath := "."
  /-- Milliseconds to wait for one pipe operation; `none` blocks forever. -/
  timeoutMs : Option Nat := some 300000
  /-- How often to look at a pending pipe operation, in milliseconds. -/
  pollMs : Nat := 10
  /-- How many wire messages one request may consume before it gives up. -/
  maxMessages : Nat := 100000
  deriving Inhabited

/-- The stdio wiring: both directions piped, because the protocol is a
conversation, and the child's stderr inherited, because an adapter's
diagnostics are for the human running the build and not for the parser. -/
abbrev pipes : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  stderr := .inherit

/-- `[[Conn]]` = a handle to one live answering process — the runtime's window
onto a world.

The value represents an *open conversation*: an operating-system child that has
completed the `initialize` handshake, a private monotone supply of JSON-RPC
ids, and (once `newSession` has run) the identifier of the session prompts are
sent to. It represents nothing whatever about what the process will say. No
world, no table and no transcript is reachable from it: a `Conn` is where the
proof boundary begins, and every claim on the far side of it is made in
`Agentic/Core/Exec.lean` against a `Table` the interpreter itself recorded. -/
structure Conn where
  /-- How it was started, and the fuels its pipe operations are bounded by. -/
  cfg : Config
  /-- The child process. -/
  child : IO.Process.Child pipes
  /-- The next JSON-RPC request id; ids are ours alone and strictly increase. -/
  nextId : IO.Ref Nat
  /-- The session opened by `Conn.newSession`, if one has been. -/
  sessionId : IO.Ref (Option String)

/-- `[[Turn]]` = what one `session/prompt` produced: the concatenation of the
agent's message chunks, and the reason the turn ended.

The value represents *the bytes that arrived*, and a caller is not entitled to
read more into it than that. `stopReason` is kept rather than dropped because
`"refusal"` and `"cancelled"` are turns with empty text, and an interpreter
that could not tell those from an agent who said nothing would be recording an
answer nobody gave. -/
structure Turn where
  /-- Every `agent_message_chunk`, concatenated in arrival order. -/
  text : String
  /-- The protocol's `stopReason`: `end_turn`, `refusal`, `cancelled`, … -/
  stopReason : String
  deriving Inhabited, Repr

/-! ## Failure: every one of them quotes the line that caused it -/

/-- Every parse failure in this module goes through here, so the offending line
is in the error text and never in a `panic!`. -/
private def fail {α : Type} (line : String) (msg : String) : IO α :=
  throw <| IO.userError s!"acp: {msg}\n  offending line: {line}"

/-! ## The three shapes a line can have -/

/-- `[[Msg]]` = one decoded line of the wire: JSON-RPC 2.0 admits exactly three
shapes, and this is them.

The value represents *what arrived*, not what it means. Ids stay raw `Json`
rather than `Nat` because JSON-RPC permits string ids and a request from the
agent must be answered with the id it chose, unchanged; our own ids are always
numeric, which is why matching a response needs only `getNat?`. -/
inductive Msg where
  /-- A reply to one of our requests; `Except` is the error/result split. -/
  | response (id : Json) (payload : Except Json Json)
  /-- A request *from* the agent, which must be answered with the same id. -/
  | request (id : Json) (method : String) (params : Json)
  /-- A notification, which must not be answered. -/
  | notification (method : String) (params : Json)

/-- Decode one line. Failure is an `Except` here and becomes an `IO` error at
the call site, where the line is still in hand. -/
def Msg.ofLine (line : String) : Except String Msg := do
  let j ← Json.parse line
  match j.getObjVal? "method" with
  | .ok mj =>
    let method ← mj.getStr?
    let params := j.getObjValD "params"
    match j.getObjVal? "id" with
    | .ok id => return .request id method params
    | .error _ => return .notification method params
  | .error _ =>
    match j.getObjVal? "id" with
    | .error _ => throw "line is neither a request, a notification nor a response"
    | .ok id =>
      match j.getObjVal? "error" with
      | .ok e => return .response id (.error e)
      | .error _ => return .response id (.ok (j.getObjValD "result"))

/-- The text of a `session/update` notification when that update is an
`agent_message_chunk`; `none` for every other kind of update (thoughts, tool
calls, plans), which this client is entitled to ignore and does.

An `agent_message_chunk` whose content is not text *is* a protocol violation
and is reported as one — dropping it silently would lose an answer. -/
def chunkText (params : Json) : Except String (Option String) := do
  let upd ← params.getObjVal? "update"
  let kind ← (← upd.getObjVal? "sessionUpdate").getStr?
  if kind != "agent_message_chunk" then return none
  let content ← upd.getObjVal? "content"
  let ty ← (← content.getObjVal? "type").getStr?
  if ty != "text" then
    throw s!"agent_message_chunk carried content of type '{ty}', not 'text'"
  return some (← (← content.getObjVal? "text").getStr?)

/-! ## What a live conversation can be asked to do

Everything taking a `Conn` lives in the `Conn` namespace, so that a caller
writes `conn.prompt "…"`. -/

namespace Conn

/-- Poll a task at most `fuel` times, sleeping `pollMs` between looks; `none`
means it never finished. Structural in `fuel`, which is why this file needs no
`partial`. -/
private def awaitTask {α : Type} (t : Task (Except IO.Error α)) (pollMs : Nat) :
    Nat → IO (Option α)
  | 0 => pure none
  | n + 1 => do
    if ← IO.hasFinished t then
      match t.get with
      | .ok a => return some a
      | .error e => throw e
    else
      IO.sleep pollMs.toUInt32
      awaitTask t pollMs n

/-- Run one blocking pipe operation on a dedicated task, bounded by
`cfg.timeoutMs`, so that a wedged adapter is an error rather than a hung build.
On expiry the child is killed: a read abandoned mid-line, or a write abandoned
mid-message, has desynchronized the stream, and ending the conversation is the
only honest thing left to do. -/
private def withTimeout {α : Type} (conn : Conn) (what : String) (act : IO α) : IO α := do
  match conn.cfg.timeoutMs with
  | none => act
  | some ms =>
    let poll := max 1 conn.cfg.pollMs
    let t ← IO.asTask (prio := .dedicated) act
    match ← awaitTask t poll (ms / poll + 1) with
    | some a => return a
    | none =>
      try conn.child.kill catch _ => pure ()
      throw <| IO.userError
        s!"acp: {what} did not finish within {ms}ms; '{conn.cfg.cmd}' was killed"

/-- One line of adapter output, or an `IO` error. -/
def readLine (conn : Conn) : IO String :=
  conn.withTimeout "a read" conn.child.stdout.getLine

/-- Write one JSON value as one line, and flush: the framing *is* the newline.

Bounded like the read, because the two directions are not concurrent here: a
prompt large enough to fill the pipe while the adapter is filling ours would
otherwise be a deadlock rather than a message. -/
private def writeJson (conn : Conn) (j : Json) : IO Unit :=
  conn.withTimeout "a write" do
    conn.child.stdin.putStr (j.compress ++ "\n")
    conn.child.stdin.flush

/-- Read messages until the reply to request `wantId` arrives, feeding every
`agent_message_chunk` to `onChunk` on the way. Requests *from* the agent are
answered `-32601`: this client advertises no client-side capabilities, and
choosing an answer to `session/request_permission` would be a policy decision,
which belongs to `Exec` and not to a transport.

`fuel` bounds how many messages are sifted through, so the loop is structural
and this file needs no `partial`. -/
private def pump (conn : Conn) (wantId : Nat) (onChunk : String → IO Unit) (fuel : Nat) :
    IO Json := do
  match fuel with
  | 0 =>
    throw <| IO.userError
      s!"acp: no reply to request {wantId} within {conn.cfg.maxMessages} messages"
  | n + 1 =>
    let line ← conn.readLine
    if line.isEmpty then
      throw <| IO.userError
        s!"acp: '{conn.cfg.cmd}' closed its output while request {wantId} was outstanding"
    else if line.all Char.isWhitespace then
      pump conn wantId onChunk n
    else
      match Msg.ofLine line with
      | .error e => fail line e
      | .ok (.response id payload) =>
        let mine := match id.getNat? with
          | .ok k => k == wantId
          | .error _ => false
        if mine then
          match payload with
          | .ok result => return result
          | .error e =>
            throw <| IO.userError
              s!"acp: '{conn.cfg.cmd}' answered request {wantId} with error {e.compress}"
        else
          pump conn wantId onChunk n
      | .ok (.request id method _) =>
        writeJson conn <| Json.mkObj
          [ ("jsonrpc", Json.str "2.0")
          , ("id", id)
          , ("error", Json.mkObj
              [ ("code", ((-32601 : Int) : Json))
              , ("message",
                  Json.str s!"{method}: this client implements no client-side methods") ]) ]
        pump conn wantId onChunk n
      | .ok (.notification method params) =>
        if method == "session/update" then
          match chunkText params with
          | .error e => fail line e
          | .ok (some txt) => onChunk txt
          | .ok none => pure ()
        pump conn wantId onChunk n
  termination_by fuel

/-! ### The calls -/

/-- Send a request and return its `result`. Public because it *is* the
transport: anything an adapter offers beyond the calls below is reachable from
here without extending this module. -/
def request (conn : Conn) (method : String) (params : Json)
    (onChunk : String → IO Unit := fun _ => pure ()) : IO Json := do
  let id ← conn.nextId.modifyGet (fun n => (n, n + 1))
  writeJson conn <| Json.mkObj
    [ ("jsonrpc", Json.str "2.0")
    , ("id", (id : Nat))
    , ("method", Json.str method)
    , ("params", params) ]
  pump conn id onChunk conn.cfg.maxMessages

/-- Send a notification: no id, and no reply expected or waited for. -/
def notify (conn : Conn) (method : String) (params : Json) : IO Unit :=
  writeJson conn <| Json.mkObj
    [ ("jsonrpc", Json.str "2.0")
    , ("method", Json.str method)
    , ("params", params) ]

/-- The `initialize` handshake, returning the agent's raw result (capabilities,
version) for a caller who wants to look. We advertise no filesystem and no
terminal capability, so a conforming agent sends us no `fs/*` or `terminal/*`
request; `session/request_permission` is not capability-gated and is refused by
`pump` anyway, because granting it is policy and policy is not transport. -/
def handshake (conn : Conn) : IO Json :=
  conn.request "initialize" <| Json.mkObj
    [ ("protocolVersion", (1 : Nat))
    , ("clientCapabilities", Json.mkObj
        [ ("fs", Json.mkObj [("readTextFile", false), ("writeTextFile", false)])
        , ("terminal", false) ])
    , ("clientInfo", Json.mkObj
        [ ("name", Json.str "agentic-lean"), ("version", Json.str "0.1.0") ]) ]

/-- Open a session in `cfg.cwd` — made absolute, because the protocol requires
an absolute path — and remember its id. -/
def newSession (conn : Conn) : IO String := do
  let dir ← IO.FS.realPath conn.cfg.cwd
  let res ← conn.request "session/new" <| Json.mkObj
    [ ("cwd", Json.str dir.toString), ("mcpServers", Json.arr #[]) ]
  match res.getObjVal? "sessionId" >>= Json.getStr? with
  | .ok sid => conn.sessionId.set (some sid); return sid
  | .error e =>
    throw <| IO.userError
      s!"acp: session/new returned no sessionId ({e}): {Json.compress res}"

/-- The session id, or an error naming the call that was skipped. -/
private def theSession (conn : Conn) : IO String := do
  match ← conn.sessionId.get with
  | some sid => return sid
  | none => throw <| IO.userError "acp: no session; call `newSession` (or `connect`) first"

/-- Send one text prompt and collect the turn. Chunks accumulate in arrival
order; the request's own reply is what ends the turn, so no heuristic decides
when the agent has finished speaking. -/
def promptTurn (conn : Conn) (text : String) : IO Turn := do
  let sid ← conn.theSession
  let acc ← IO.mkRef ""
  let res ← conn.request "session/prompt"
    (Json.mkObj
      [ ("sessionId", Json.str sid)
      , ("prompt",
          Json.arr #[Json.mkObj [("type", Json.str "text"), ("text", Json.str text)]]) ])
    (fun chunk => acc.modify (· ++ chunk))
  match res.getObjVal? "stopReason" >>= Json.getStr? with
  | .ok stop => return { text := ← acc.get, stopReason := stop }
  | .error e =>
    throw <| IO.userError
      s!"acp: session/prompt returned no stopReason ({e}): {Json.compress res}"

/-- Send one text prompt and return what the agent said. -/
def prompt (conn : Conn) (text : String) : IO String :=
  return (← conn.promptTurn text).text

/-- Select a session mode (`session/set_mode`). This is the only selection call
ACP v1 defines by name; a *model*, in this protocol, would be an
adapter-specific `session/set_config_option`, so it is deliberately absent
rather than invented — reach for `request` when an adapter documents one. -/
def setMode (conn : Conn) (modeId : String) : IO Unit := do
  let sid ← conn.theSession
  discard <| conn.request "session/set_mode" <|
    Json.mkObj [("sessionId", Json.str sid), ("modeId", Json.str modeId)]

/-- Cancel the turn in flight, if there is a session at all. A notification, so
it does not wait: the outstanding `session/prompt` is what reports
`cancelled`. -/
def cancel (conn : Conn) : IO Unit := do
  match ← conn.sessionId.get with
  | none => pure ()
  | some sid => conn.notify "session/cancel" (Json.mkObj [("sessionId", Json.str sid)])

/-- End the conversation. Every step is best-effort and swallows its own
failure, because this runs on exit paths — including failing ones, where a
second error would hide the first. -/
def close (conn : Conn) : IO Unit := do
  try conn.cancel catch _ => pure ()
  try conn.child.kill catch _ => pure ()
  try discard conn.child.wait catch _ => pure ()

end Conn

/-! ## Opening one -/

/-- Spawn the adapter, shake hands, open a session. On any failure the child is
closed before the error is re-thrown, so a failed `connect` leaves no process
behind. -/
def connect (cfg : Config := {}) : IO Conn := do
  -- Flush first: `spawn` forks, and a fork inherits the parent's *unflushed*
  -- stdout buffer, which the child would then deliver into the pipe we are
  -- about to read as protocol. Observed on macOS when the adapter fails to
  -- exec: without this line the first "message" is the parent's own output.
  (← IO.getStdout).flush
  let child ← IO.Process.spawn
    { toStdioConfig := pipes, cmd := cfg.cmd, args := cfg.args, cwd := some cfg.cwd }
  let nextId ← IO.mkRef 0
  let sessionId ← IO.mkRef none
  let conn : Conn := { cfg, child, nextId, sessionId }
  try
    discard <| conn.handshake
    discard <| conn.newSession
  catch e =>
    conn.close
    throw e
  return conn

/-- The bracket: one live conversation for the duration of `k`, closed on every
exit path, success or exception. This is the form callers should use. -/
def withConn {α : Type} (cfg : Config := {}) (k : Conn → IO α) : IO α := do
  let conn ← connect cfg
  try k conn finally conn.close

end Agentic.Core.Acp
