import Agentic.Core.Rpc

/-!
# ACP: the wire, and nothing but the wire

A minimal Agent Client Protocol client — line-delimited JSON-RPC 2.0 over a
child process's stdio — sufficient to start an adapter, open a session in a
working directory, send one prompt and read back the text the agent streamed.

**This module makes no claim about meaning, and that is deliberate.** Nothing
here is a morphism, nothing here mentions a world, a question or an answer, and
no theorem about the *semantics* mentions any declaration of this file. It
contains no `Ω`, no `Q`, no `Dlg` and no `Plan`; it does not import
`Agentic.Core.Question`, so it *cannot* say anything about worlds, questions or
answers even by accident. What a run means is settled in `Agentic/Core/Exec.lean`
(the memoizing interpreter, whose `Table` is a finite world) and
`Agentic/Core/Certify.lean` (the decidable per-run certificate); the kernel's
account of why the meaning lives there and not here is `rederivation-kernel.md`
§5.

The one place this file does state and prove something is `StopReason`: the
protocol's own vocabulary for *how a turn ended*, classified into the five words
ACP v1 defines plus a verbatim `other`. That classification is a claim about
bytes, not about meaning, and it is proved lossless (`StopReason.toString_ofString`)
because the interpreter above now refuses to record an acknowledgement from a
turn that did not complete, and a client that silently mangled `cancelled` into
`end_turn` would defeat that refusal.

**The trust boundary, stated rather than axiomatized.** Four assumptions are
made *by this file's code* and are discharged by nothing:

1. the child process is the addressee the caller believes it is;
2. the bytes it writes are the bytes that addressee meant;
3. `String`, the type these calls return, is what the answer *is* — turning one
   into an `El c` is the single total parsing function per `Code` that the
   kernel names as the remaining trust boundary, and it lives in `Exec`;
4. **granting a tool permission inside the session's working directory is
   authorized** — see `Permission` below, where the reasoning is set out. This
   is the one assumption that lets the agent act on the world rather than merely
   talk about it, and it is a policy of the runtime, stated here and proved
   nowhere.

None of the four is an `axiom` command, and none is needed by any proof: the
adequacy theorem quantifies over *all* worlds extending the run's table, so an
adapter that lies merely exhibits a different world and the theorem still holds
of it. That is the whole reason a transport is allowed to be ordinary `IO` code.

**Totality.** No declaration here is `partial`, and none contains a `panic!`,
an unchecked index or a `sorry`: every loop is structural on an explicit fuel
taken from `Config`, every JSON access goes through `Except`, and every failure
becomes an `IO.userError` quoting the offending line. A wedged adapter is
bounded twice: `Config.readTimeoutMs` bounds one pipe operation, so a blocked
read *or write* is interruptible, and `Config.turnTimeoutMs` bounds a whole
request, so an adapter that streams forever without ever answering is an error
rather than a hung build.

`#print axioms` on the entry points reports only `propext`, `Classical.choice`
and `Quot.sound`, all of them inherited from Lean core's JSON parser; this
module declares no axiom of its own, and no proof about the semantics depends on
anything here.

## What the real adapters actually do

Everything below was measured against
`@agentclientprotocol/claude-agent-acp 0.64.0` (on ACP SDK 1.3.0,
`PROTOCOL_VERSION = 1`) and `codex-acp 0.13.0`, driving the owner's authenticated
CLIs. Where the two disagree, both readings are handled.

* `initialize` — request as sent here (`protocolVersion: 1`, `clientCapabilities`
  with `fs.readTextFile`/`fs.writeTextFile`/`terminal` all false, `clientInfo`)
  was accepted verbatim by both. The response carries `protocolVersion`,
  `agentCapabilities`, `agentInfo` (`name`, `title`, `version`) and
  `authMethods`; claude's `authMethods` is empty and codex's is not. Only
  `protocolVersion` is read, and it is *checked*: an agent answering anything but
  `1` is speaking a protocol this client does not implement.
* `session/new` — `{cwd (absolute), mcpServers: []}`. Claude answers
  `{sessionId (a UUID string), modes, configOptions}`; codex answers
  `{sessionId, models}`, and `models` is not a field of `NewSessionResponse` in
  the 1.3.0 schema. Only `sessionId` is read, which is why both work.
* `session/prompt` — `{sessionId, prompt: [{type:"text", text}]}`, answered by a
  `stopReason` (and, on claude, a `usage` object) after zero or more
  `session/update` notifications. Seven kinds of update were observed on the
  wire — `usage_update`, `agent_message_chunk`, `tool_call`, `tool_call_update`,
  `available_commands_update`, `session_info_update`, `config_option_update` —
  and only `agent_message_chunk` is an answer. The noise-to-answer ratio is
  roughly five to one, which is what `Config.maxMessages` is sized for.
  `available_commands_update` arrives right after the *first* prompt and carried
  39,598 bytes on a single line in the measured run: `readLine` must survive a
  line two orders of magnitude longer than any test had exercised, and it does,
  because the framing really is the newline (zero unparseable and zero blank
  lines across three full transcripts).
* `session/set_mode` — `{sessionId, modeId}`; claude answers `{}` (preceded by an
  unsolicited `config_option_update`), **codex answers `-32602`**. A caller must
  therefore be prepared for the call to fail on a conforming adapter.
* `session/set_config_option` — `{sessionId, configId, value}`; this is in the
  1.3.0 schema (`SetSessionConfigOptionRequest`), the field really is `configId`
  and not `configOptionId`, and *both* adapters implement it with a `model`
  option. Selecting a model is therefore a protocol operation after all, and
  `Conn.setConfigOption` is it.
* **Which values `model` takes, re-measured.** Claude's `session/new` publishes
  four `configOptions` — `mode`, `model`, `effort`, `agent` — each a `select`
  with a `currentValue` and an `options` array of `{value, name, description}`.
  For `model` the values were, verbatim: `default`, `opus[1m]`,
  `claude-fable-5`, `sonnet`, `haiku`. Nothing there is `deep`, which is what a
  live run of the flagship found out the hard way (`Invalid value for config
  option model: deep`), and nothing there resembles it closely enough for any
  matcher to bridge — which is why `Exec.Settings.modelAliases` exists and why
  `resolveValue` below is forbidden to guess. Codex publishes no `configOptions`
  at all, and `configCatalogue` reads that as "said nothing" rather than "said
  no".
* `session/set_model` — **does not exist**: claude answers `-32601`, and no such
  method is in the schema. It is deliberately absent here.
* `session/cancel` — a notification; the outstanding `session/prompt` then
  answers `{"stopReason":"cancelled"}`, and the session remains usable
  afterwards.
* **Ids.** The agent's own request ids are small integers from a counter that
  starts at `0` — the same numbers ours start at. They cannot be confused,
  because `Msg.ofLine` splits on the presence of `method` before it looks at
  `id`, and an inbound request carries a method. Ids stay raw `Json` because a
  request from the agent must be answered with the id it chose, unchanged: codex
  echoes a string id verbatim, claude uses integers.

The stub adapter `test/stub_adapter.py` reproduces these shapes byte for byte,
including the 40 KB line, the integer-id permission request and the
non-`agent_message_chunk` noise; `test/AcpSmoke.lean` is the round trip.
-/

namespace Agentic.Core.Acp

open Lean (Json)

/-! ## Which program is the adapter -/

/-- The machine-local pin for the claude adapter: the nix store path the owner
built. Used only when `claude-agent-acp` is not on `PATH`. It is a *pin*, not a
requirement — a store path is machine-local by construction, and naming it here
is what makes an unconfigured `.claude` run work on this machine without making
it a dependency anywhere else. -/
def claudePin : String :=
  "/nix/store/vhmm2z9psm5vcwgl8p6sa4c99y4chn0m-claude-agent-acp-0.64.0/bin/claude-agent-acp"

/-- The machine-local pin for the codex adapter; see `claudePin`. -/
def codexPin : String :=
  "/nix/store/i0wl19lx66n2093bv9g4g3lsxj16f9ry-codex-acp-0.13.0/bin/codex-acp"

/-- Where the test double lives, relative to the repository root. -/
def stubScript : String := "test/stub_adapter.py"

/-- `[[Adapter]]` = which answering program to start, named rather than spelled.

The value represents an *intent*, not a path: `.claude` means "the claude ACP
adapter, wherever this machine keeps it", and `Adapter.resolve` is what turns
that into an executable. Named resolution exists because the two facts a caller
actually knows — *which* agent, and that it is installed — are not the fact a
`spawn` needs, and making the caller carry a store path around is how a
configuration rots. -/
inductive Adapter where
  /-- The deterministic test double, run under `python3`. -/
  | stub (script : String)
  /-- Claude's ACP adapter: `claude-agent-acp` on `PATH`, else `claudePin`. -/
  | claude
  /-- Codex's ACP adapter: `codex-acp` on `PATH`, else `codexPin`. -/
  | codex
  /-- An explicit program, taken as given. -/
  | path (prog : String)
  deriving DecidableEq, Repr, Inhabited

/-- `[[Adapter.ofName s]]` = the adapter a command line names: `stub`, `claude`
and `codex` are the three names, and anything else is read as a path, so a
caller can point at an adapter this file has never heard of. -/
def Adapter.ofName (s : String) : Adapter :=
  if s == "stub" then .stub stubScript
  else if s == "claude" then .claude
  else if s == "codex" then .codex
  else .path s

/-- The first entry of `PATH` holding a non-directory of this name, if any. -/
private def searchPath (name : String) : IO (Option String) := do
  let some path ← IO.getEnv "PATH" | return none
  for dir in path.splitOn ":" do
    if !dir.isEmpty then
      let p : System.FilePath := System.FilePath.mk dir / name
      if ← p.pathExists then
        if !(← p.isDir) then return some p.toString
  return none

/-- `PATH` first, then the machine-local pin, and an error naming both if the
program is in neither place. -/
private def resolveNamed (name pin : String) : IO (String × Array String) := do
  match ← searchPath name with
  | some p => return (p, #[])
  | none =>
    if ← System.FilePath.pathExists (System.FilePath.mk pin) then
      return (pin, #[])
    throw <| IO.userError
      s!"acp: no adapter '{name}': it is not on PATH and the machine-local pin \
         '{pin}' does not exist"

/-- `[[Adapter.resolve a]]` = the program and the arguments that start `a`.

`PATH` first, then the machine-local pin: an owner who has installed the adapter
gets theirs, and an owner who has only the nix store path gets that. A named
adapter that is in neither place is an error *here*, naming both places looked
in, rather than an `ENOENT` from `spawn` naming neither. -/
def Adapter.resolve : Adapter → IO (String × Array String)
  | .stub script => return ("python3", #[script])
  | .path prog => return (prog, #[])
  | .claude => resolveNamed "claude-agent-acp" claudePin
  | .codex => resolveNamed "codex-acp" codexPin

/-! ## Permission: the one policy the transport is allowed to have -/

/-- `[[Permission]]` = what this client answers a `session/request_permission`
request with.

**Why the transport decides this, having once refused to.** The refusal
(`-32601`, "this client implements no client-side methods") was measured against
the real adapter and it does not do what it appears to do. The agent does not
end the turn: the tool call fails, the model *retries with another tool*, that
fails too, and the turn ends `end_turn` with an apology as its text — ninety-odd
thousand tokens spent to produce prose that `Decode` will read as an answer,
with nothing on the wire to distinguish it from one. A refusal that launders
itself into a non-answer is worse than either honest alternative, so this client
now takes one of them explicitly.

* `.grant` selects the agent's own least-standing-authority allow option —
  `allow_once` if it is offered, then `allow_always`, then whatever is first —
  and is the default. **The assumption**: the runtime is speaking to an adapter
  it started, in a working directory the caller chose, and a tool call inside
  that directory is authorized by the act of starting the run there. That is a
  policy, it is stated, and it is proved nowhere. A caller who does not want it
  should not be pointing the runtime at a directory they care about.
* `.cancel` answers in the schema's own vocabulary — `{"outcome":"cancelled"}` —
  which is the *documented* way to decline, and unlike `-32601` it tells the
  agent that the request was understood and denied.

Either way the answer is immediate and unattended: nothing here asks a human,
because `pump` runs inside somebody else's `session/prompt` and a client that
blocked there would deadlock the turn it is trying to complete. -/
inductive Permission where
  /-- Select an allow option, preferring the one that grants least. -/
  | grant
  /-- Decline, in the schema's own words. -/
  | cancel
  deriving DecidableEq, Repr, Inhabited

/-! ## Configuration -/

/-- `[[Config]]` = the recipe for starting one adapter process: which program,
in which directory, how it answers a permission request, and how long the
runtime will wait for it to say anything.

The value represents *intent to spawn*, not a live process — `connect` turns it
into a `Conn`. The default is the claude adapter in the current directory; a
test overrides `adapter` with `.stub`.

The fuels are configuration rather than constants because they are why no loop
in this file is `partial`: `maxMessages` bounds how many wire messages one
request may sift through, `readTimeoutMs`/`pollMs` bound one pipe operation, and
`turnTimeoutMs` bounds a whole request. The two clocks are separate because they
fail differently: a wedged pipe stops producing bytes, and a runaway agent
produces them forever. -/
structure Config where
  /-- Which adapter to start. -/
  adapter : Adapter := .claude
  /-- Extra arguments, appended to whatever `Adapter.resolve` supplies. -/
  args : Array String := #[]
  /-- The session's working directory; sent to `session/new` made absolute. -/
  cwd : System.FilePath := "."
  /-- How a `session/request_permission` request is answered. -/
  permission : Permission := .grant
  /-- Milliseconds to wait for one pipe operation; `none` blocks forever. Five
  minutes by default: the longest measured gap between two lines of a real turn
  was seconds, so this is generous by two orders of magnitude and still leaves a
  truly wedged adapter killable. -/
  readTimeoutMs : Option Nat := some 300000
  /-- Milliseconds one request may take in total; `none` is unbounded. Fifteen
  minutes by default, because a real turn that writes code can legitimately run
  for minutes while never leaving the pipe silent for long. -/
  turnTimeoutMs : Option Nat := some 900000
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

/-! ## What an adapter says it will accept, and what a scope asked for

A scope names a model the *author* chose — `deep`, in the flagship — and an
adapter accepts the values the *adapter* publishes. `session/new` publishes
them, in `configOptions`, and the measured failure that makes this section exist
is that nobody read it: a live run sent `model='deep'`, claude answered
`Invalid value for config option model: deep`, and the axis fell silently back
to a line in the prompt header.

The two halves of the fix are separate on purpose. **Resolution** is pure, total
and proved not to invent values (`resolveValue_value_mem`); it is the same
discipline `agent-functor` applies to key lookup, where an ambiguous key is an
error and never a guess. **Aliasing** is a caller's business and lives in
`Exec.Settings`, because `deep` is not a misspelling of anything claude
advertises — no amount of matching bridges it, and pretending otherwise would be
the guess this refuses to make.
-/

/-- `[[Resolution]]` = what a requested value came to, among the values an
adapter advertised for one config option.

`ambiguous` is a constructor and not a silent first-match: two candidates mean
the caller has not said which one they want, and answering anyway is how a
configuration comes to mean something nobody chose. -/
inductive Resolution where
  /-- The adapter advertises exactly this value. -/
  | exact (value : String)
  /-- One advertised value matched, but not literally; `how` says in what way. -/
  | fuzzy (value : String) (how : String)
  /-- More than one advertised value matched, so none was chosen. -/
  | ambiguous (candidates : List String)
  /-- No advertised value matched. -/
  | unknown
  deriving DecidableEq, Repr, Inhabited

/-- The value a resolution settled on, if it settled on one. -/
def Resolution.value? : Resolution → Option String
  | .exact v | .fuzzy v _ => some v
  | .ambiguous _ | .unknown => none

/-- Does `needle` occur in `hay`? `splitOn` cuts at every occurrence, so "more
than one piece" is "at least one occurrence". Local rather than imported:
`Agentic/Core/Artifact.lean`'s `occursIn` is the same function, and this module
imports nothing above `Agentic.Core.Rpc` on purpose. -/
private def infixOf (hay needle : String) : Bool := (hay.splitOn needle).length > 1

/-- `[[resolveValue advertised want]]` = which advertised value `want` names.

Four rungs, tried in order, and each one only accepted when it picks out exactly
one candidate: literal equality, then case, then prefix, then substring. A rung
that matches two or more stops the search with `ambiguous` rather than falling
through to a looser rung, because a looser rung cannot make a choice the tighter
one already showed to be underdetermined. -/
def resolveValue (advertised : List String) (want : String) : Resolution :=
  if advertised.contains want then .exact want else
  match advertised.filter (fun v => v.toLower == want.toLower) with
  | [v] => .fuzzy v "case-insensitively"
  | cs@(_ :: _ :: _) => .ambiguous cs
  | [] =>
    match advertised.filter (fun v => v.toLower.startsWith want.toLower) with
    | [v] => .fuzzy v "as a unique prefix"
    | cs@(_ :: _ :: _) => .ambiguous cs
    | [] =>
      match advertised.filter (fun v => infixOf v.toLower want.toLower) with
      | [v] => .fuzzy v "as a unique substring"
      | cs@(_ :: _ :: _) => .ambiguous cs
      | [] => .unknown

/-- A singleton `filter` names a member of the list it filtered: the one step
every rung of `resolveValue` takes. -/
private theorem mem_of_filter_eq_singleton {p : String → Bool} {l : List String} {v : String}
    (h : l.filter p = [v]) : v ∈ l :=
  (List.mem_filter.mp (by rw [h]; exact List.mem_singleton_self v)).1

/-- **Resolution never invents a value.** Whatever comes out of `resolveValue`
is a value the adapter itself advertised — so a successful resolution cannot be
the source of an `Invalid value for config option` on the next call. -/
theorem resolveValue_value_mem (advertised : List String) (want v : String)
    (h : (resolveValue advertised want).value? = some v) : v ∈ advertised := by
  unfold resolveValue at h
  split at h
  · rename_i hc
    simp only [Resolution.value?, Option.some.injEq] at h
    subst h
    simpa using hc
  · split at h
    · rename_i hf
      simp only [Resolution.value?, Option.some.injEq] at h
      subst h
      exact mem_of_filter_eq_singleton hf
    · simp [Resolution.value?] at h
    · split at h
      · rename_i hf
        simp only [Resolution.value?, Option.some.injEq] at h
        subst h
        exact mem_of_filter_eq_singleton hf
      · simp [Resolution.value?] at h
      · split at h
        · rename_i hf
          simp only [Resolution.value?, Option.some.injEq] at h
          subst h
          exact mem_of_filter_eq_singleton hf
        · simp [Resolution.value?] at h
        · simp [Resolution.value?] at h

/-- **An adapter that advertises nothing resolves nothing.** The case the caller
must handle separately: codex publishes no `configOptions`, and a client that
read this as "no model is acceptable" would refuse an axis the adapter would
have taken. -/
theorem resolveValue_nil (want : String) : resolveValue [] want = .unknown := rfl

/-- **A value the adapter advertises resolves to itself, literally.** -/
theorem resolveValue_exact (advertised : List String) (want : String)
    (h : want ∈ advertised) : resolveValue advertised want = .exact want := by
  have hc : advertised.contains want = true := by simpa using h
  unfold resolveValue
  rw [if_pos hc]

/-- `[[configCatalogue res]]` = the `configOptions` of a `session/new` or
`session/set_config_option` result, as option id and the values it accepts.

Total and forgiving: a result with no catalogue, an entry with no id, or an
option with no enumerated values yields the empty list for that part rather than
an error. An adapter is entitled not to publish a catalogue — codex does not —
and "it did not say" must not be read as "it said no". -/
def configCatalogue (res : Json) : List (String × List String) :=
  match res.getObjVal? "configOptions" >>= Json.getArr? with
  | .error _ => []
  | .ok opts => opts.toList.filterMap fun o =>
      match o.getObjVal? "id" >>= Json.getStr? with
      | .error _ => none
      | .ok id =>
        let values := match o.getObjVal? "options" >>= Json.getArr? with
          | .error _ => []
          | .ok vs => vs.toList.filterMap fun v => (v.getObjVal? "value" >>= Json.getStr?).toOption
        some (id, values)

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
  /-- The resolved program, for error messages that name what actually ran. -/
  prog : String
  /-- The child process. -/
  child : IO.Process.Child pipes
  /-- The next JSON-RPC request id; ids are ours alone and strictly increase. -/
  nextId : IO.Ref Nat
  /-- The session opened by `Conn.newSession`, if one has been. -/
  sessionId : IO.Ref (Option String)
  /-- What the adapter published at `session/new`: for each config option, the
  values it says it will accept. Empty for an adapter that publishes no
  catalogue, which is a fact about the adapter and not a refusal. -/
  configValues : IO.Ref (List (String × List String))
  /-- The keys a fallback has already been reported under, so that a run whose
  every question carries the same unusable axis says so once and then gets on
  with it. A warning repeated forty times is a warning nobody finishes reading. -/
  warned : IO.Ref (List String)

/-! ## How a turn ended -/

/-- `[[StopReason]]` = the protocol's account of why a turn stopped.

ACP v1 defines five words and this is them, plus `other` for a word a future
adapter invents. The distinction is not decoration: `end_turn` is the only one
of the five that means *the agent finished saying what it had to say*, and
`Agentic/Core/Exec.lean` refuses to record an acknowledgement — the answer to a
question that asks somebody to **do** something — from any of the others. -/
inductive StopReason where
  /-- The agent finished its turn. The only completed one. -/
  | endTurn
  /-- The model hit its output limit mid-answer. -/
  | maxTokens
  /-- The turn hit the adapter's cap on agent round trips. -/
  | maxTurnRequests
  /-- The model declined to answer. -/
  | refusal
  /-- The turn was cancelled — by `Conn.cancel`, or by the adapter. -/
  | cancelled
  /-- A word this client does not know, kept verbatim rather than flattened. -/
  | other (s : String)
  deriving DecidableEq, Repr, Inhabited

namespace StopReason

/-- `[[StopReason.ofString s]]` = the wire's word, classified. -/
def ofString (s : String) : StopReason :=
  if s == "end_turn" then .endTurn
  else if s == "max_tokens" then .maxTokens
  else if s == "max_turn_requests" then .maxTurnRequests
  else if s == "refusal" then .refusal
  else if s == "cancelled" then .cancelled
  else .other s

/-- `[[r.render]]` = the wire's word again. -/
def render : StopReason → String
  | .endTurn => "end_turn"
  | .maxTokens => "max_tokens"
  | .maxTurnRequests => "max_turn_requests"
  | .refusal => "refusal"
  | .cancelled => "cancelled"
  | .other s => s

/-- **The classification is lossless.** Whatever the adapter said, rendering the
classification of it gives the adapter's word back — so nothing downstream can
be misled by a stop reason this client did not recognize, and an operator
reading a log sees what arrived rather than what was understood.

This is the one theorem in the transport, and it is here because the refusal to
record an acknowledgement from an incomplete turn is only as good as the reading
of the word `end_turn`. -/
theorem render_ofString (s : String) : (ofString s).render = s := by
  unfold ofString
  split
  · next h => exact (eq_of_beq h).symm
  split
  · next h => exact (eq_of_beq h).symm
  split
  · next h => exact (eq_of_beq h).symm
  split
  · next h => exact (eq_of_beq h).symm
  split
  · next h => exact (eq_of_beq h).symm
  rfl

/-- **Clause equation.** -/
theorem ofString_end_turn : ofString "end_turn" = .endTurn := by decide

/-- **Clause equation.** A cancelled turn is recognized as one, which is what
makes `Conn.cancel` observable to the caller rather than to the log only. -/
theorem ofString_cancelled : ofString "cancelled" = .cancelled := by decide

/-- **Clause equation.** -/
theorem ofString_refusal : ofString "refusal" = .refusal := by decide

/-- `[[r.completed]]` = did the agent finish? Exactly one stop reason says so. -/
def completed : StopReason → Bool
  | .endTurn => true
  | _ => false

/-- **…and that is the whole of it**: completion *is* `end_turn`, so a caller
enforcing "the turn must have completed" is enforcing one protocol word and not
a heuristic. -/
theorem completed_iff (r : StopReason) : r.completed = true ↔ r = .endTurn := by
  cases r <;> simp [completed]

end StopReason

/-- `[[Turn]]` = what one `session/prompt` produced: the concatenation of the
agent's message chunks, and the reason the turn ended.

The value represents *the bytes that arrived*, and a caller is not entitled to
read more into it than that. `stopReason` is kept rather than dropped because
`refusal` and `cancelled` are turns with (usually) empty text, and an
interpreter that could not tell those from an agent who said nothing would be
recording an answer nobody gave. -/
structure Turn where
  /-- Every `agent_message_chunk`, concatenated in arrival order. -/
  text : String
  /-- Why the turn ended. -/
  stopReason : StopReason
  deriving Inhabited, Repr

/-! ## Failure: every one of them quotes the line that caused it -/

/-- Every parse failure in this module goes through here, so the offending line
is in the error text and never in a `panic!`. -/
private def fail {α : Type} (line : String) (msg : String) : IO α :=
  throw <| IO.userError s!"acp: {msg}\n  offending line: {line}"

/-! ## The three shapes a line can have

The decoder is `Agentic/Core/Rpc.lean`'s, not this file's: `Agentic/Core/Mcp.lean`
speaks the same line-delimited JSON-RPC 2.0 from the other side of the wire, and
one decoder read by both is one decoder to be wrong. The abbreviation keeps this
file's own vocabulary (`Acp.Msg`) pointing at it. -/

/-- `[[Acp.Msg]]` = `Agentic.Core.Rpc.Msg`: one decoded line of the wire. -/
abbrev Msg : Type := Rpc.Msg

/-- Decode one line; `Rpc.Msg.ofLine`. Failure is an `Except` here and becomes an
`IO` error at the call site, where the line is still in hand. -/
abbrev Msg.ofLine : String → Except String Msg := Rpc.Msg.ofLine

/-- The text of a `session/update` notification when that update is an
`agent_message_chunk`; `none` for every other kind of update.

The other six kinds observed on the real wire — `usage_update`, `tool_call`,
`tool_call_update`, `available_commands_update`, `session_info_update`,
`config_option_update` — are progress, not answer, and this client is entitled
to ignore them and does. (`agent_thought_chunk`, which the old stub emitted, was
never once sent by either real adapter.)

An `agent_message_chunk` whose content is not text *is* a protocol violation
and is reported as one — dropping it silently would lose an answer.

What this cannot do is tell an answer from the adapter's own narration: codex
was measured prefixing a turn with "Model metadata for `gpt-5.6-sol` not
found…" as a genuine `agent_message_chunk`, indistinguishable on the wire from
the model speaking. That is a fact about adapters, recorded here because a
reader is owed it, and it is one more reason the trusted base downstream is
narrow. -/
def chunkText (params : Json) : Except String (Option String) := do
  let upd ← params.getObjVal? "update"
  let kind ← (← upd.getObjVal? "sessionUpdate").getStr?
  if kind != "agent_message_chunk" then return none
  let content ← upd.getObjVal? "content"
  let ty ← (← content.getObjVal? "type").getStr?
  if ty != "text" then
    throw s!"agent_message_chunk carried content of type '{ty}', not 'text'"
  return some (← (← content.getObjVal? "text").getStr?)

/-! ## Answering the agent's own requests -/

/-- The `optionId` of the first option of this `kind`, if the request offers
one. -/
private def optionOfKind (opts : Array Json) (kind : String) : Option String :=
  let isKind (o : Json) : Bool :=
    match o.getObjVal? "kind" >>= Json.getStr? with
    | .ok k => k == kind
    | .error _ => false
  match opts.find? isKind with
  | some o => (o.getObjVal? "optionId" >>= Json.getStr?).toOption
  | none => none

/-- `[[pickAllow params]]` = the option this client selects when it grants a
permission request: `allow_once` if the agent offered one, else `allow_always`,
else the first option of any kind, else nothing at all.

Least standing authority first, deliberately: `allow_once` makes the agent ask
again for the next tool call, which costs one round trip and keeps every act
individually visible on the wire, whereas `allow_always` was measured silencing
every subsequent request in the session. A request with no options is not
grantable and falls through to `cancelled`. -/
def pickAllow (params : Json) : Option String :=
  match params.getObjVal? "options" >>= Json.getArr? with
  | .error _ => none
  | .ok opts =>
    match optionOfKind opts "allow_once" with
    | some id => some id
    | none =>
      match optionOfKind opts "allow_always" with
      | some id => some id
      | none => match opts[0]? with
        | some o => (o.getObjVal? "optionId" >>= Json.getStr?).toOption
        | none => none

/-- `[[permissionResult p params]]` = the `RequestPermissionResponse` this
client sends back: `{"outcome":{"outcome":"selected","optionId":…}}` when it
grants, and `{"outcome":{"outcome":"cancelled"}}` when it declines or when the
request offered nothing to select. Both are the schema's own shapes; neither is
an error, because a permission request is a question and not a call the client
failed to implement. -/
def permissionResult (p : Permission) (params : Json) : Json :=
  let cancelled := Json.mkObj [("outcome", Json.mkObj [("outcome", Json.str "cancelled")])]
  match p with
  | .cancel => cancelled
  | .grant =>
    match pickAllow params with
    | none => cancelled
    | some id =>
      Json.mkObj
        [ ("outcome", Json.mkObj
            [ ("outcome", Json.str "selected"), ("optionId", Json.str id) ]) ]

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
`cfg.readTimeoutMs`, so that a wedged adapter is an error rather than a hung
build. On expiry the child is killed: a read abandoned mid-line, or a write
abandoned mid-message, has desynchronized the stream, and ending the
conversation is the only honest thing left to do. -/
private def withTimeout {α : Type} (conn : Conn) (what : String) (act : IO α) : IO α := do
  match conn.cfg.readTimeoutMs with
  | none => act
  | some ms =>
    let poll := max 1 conn.cfg.pollMs
    let t ← IO.asTask (prio := .dedicated) act
    match ← awaitTask t poll (ms / poll + 1) with
    | some a => return a
    | none =>
      try conn.child.kill catch _ => pure ()
      throw <| IO.userError
        s!"acp: {what} did not finish within {ms}ms; '{conn.prog}' was killed"

/-- One line of adapter output, or an `IO` error. Lines are not small: the real
adapter's command catalogue arrived as a single 39,598-byte line. -/
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

/-- Answer a request the agent made of us. `session/request_permission` is
answered by policy (`Config.permission`); everything else — every `fs/*` and
`terminal/*` method — is answered `-32601`, honestly, because the `initialize`
handshake advertised no such capability and a conforming agent should not have
asked. -/
private def answerAgentRequest (conn : Conn) (id : Json) (method : String)
    (params : Json) : IO Unit :=
  if method == "session/request_permission" then
    writeJson conn <| Rpc.result id (permissionResult conn.cfg.permission params)
  else
    writeJson conn <| Rpc.errorFrame id Rpc.methodNotFound
      s!"{method}: this client advertised no such capability"

/-- Read messages until the reply to request `wantId` arrives, feeding every
`agent_message_chunk` to `onChunk` on the way and answering every request the
agent makes of us as it comes.

Two fuels bound this loop and they are both real: `fuel` counts messages, so an
adapter that chatters without answering stops being listened to, and `deadline`
(a monotone-clock reading in milliseconds, or `none`) bounds the wall time of the
whole request, so an adapter that chatters *slowly* does too. The message fuel is
what makes the recursion structural. -/
private def pump (conn : Conn) (wantId : Nat) (onChunk : String → IO Unit)
    (deadline : Option Nat) (fuel : Nat) : IO (Except Json Json) := do
  match fuel with
  | 0 =>
    throw <| IO.userError
      s!"acp: no reply to request {wantId} within {conn.cfg.maxMessages} messages"
  | n + 1 =>
    if let some d := deadline then
      if (← IO.monoMsNow) > d then
        try conn.child.kill catch _ => pure ()
        throw <| IO.userError
          s!"acp: request {wantId} was still unanswered after \
             {conn.cfg.turnTimeoutMs.getD 0}ms; '{conn.prog}' was killed"
    let line ← conn.readLine
    if line.isEmpty then
      throw <| IO.userError
        s!"acp: '{conn.prog}' closed its output while request {wantId} was outstanding"
    else if line.all Char.isWhitespace then
      pump conn wantId onChunk deadline n
    else
      match Msg.ofLine line with
      | .error e => fail line e
      | .ok (.response id payload) =>
        let mine := match id.getNat? with
          | .ok k => k == wantId
          | .error _ => false
        if mine then
          return payload
        else
          pump conn wantId onChunk deadline n
      | .ok (.request id method params) =>
        conn.answerAgentRequest id method params
        pump conn wantId onChunk deadline n
      | .ok (.notification method params) =>
        if method == "session/update" then
          match chunkText params with
          | .error e => fail line e
          | .ok (some txt) => onChunk txt
          | .ok none => pure ()
        pump conn wantId onChunk deadline n
  termination_by fuel

/-! ### The calls -/

/-- `[[Conn.tryRequest]]` = send a request and hand back **either** the agent's
`result` **or** the agent's `error` object, as a value.

The `Except` is the protocol's own error/result split and nothing else: a
transport failure (a dead pipe, a timeout, an unparseable line) is still an
exception, because that is the conversation ending rather than the agent
declining. This distinction is not fussiness — `session/set_mode` answers `{}`
on claude and `-32602` on codex, so a caller that could not tell "this adapter
does not offer that" from "the adapter is gone" would have to choose between
failing on one conforming adapter and ignoring a dead pipe on the other. -/
def tryRequest (conn : Conn) (method : String) (params : Json)
    (onChunk : String → IO Unit := fun _ => pure ()) : IO (Except Json Json) := do
  let id ← conn.nextId.modifyGet (fun n => (n, n + 1))
  let deadline ← match conn.cfg.turnTimeoutMs with
    | none => pure none
    | some ms => do let now ← IO.monoMsNow; pure (some (now + ms))
  writeJson conn <| Rpc.request ((id : Nat) : Json) method params
  pump conn id onChunk deadline conn.cfg.maxMessages

/-- Send a request and return its `result`, raising the agent's error if it sent
one. Public because it *is* the transport: anything an adapter offers beyond the
calls below is reachable from here without extending this module. -/
def request (conn : Conn) (method : String) (params : Json)
    (onChunk : String → IO Unit := fun _ => pure ()) : IO Json := do
  match ← conn.tryRequest method params onChunk with
  | .ok result => return result
  | .error e =>
    throw <| IO.userError
      s!"acp: '{conn.prog}' answered '{method}' with error {e.compress}"

/-- Send a notification: no id, and no reply expected or waited for. -/
def notify (conn : Conn) (method : String) (params : Json) : IO Unit :=
  writeJson conn <| Rpc.notification method params

/-- The `initialize` handshake, returning the agent's raw result (capabilities,
version, `agentInfo`, `authMethods`) for a caller who wants to look.

We advertise no filesystem and no terminal capability, so a conforming agent
sends us no `fs/*` or `terminal/*` request. `session/request_permission` is not
capability-gated and arrives anyway; `Config.permission` is the answer to it.

The negotiated `protocolVersion` is the one field this client reads, and it
insists on `1`: the shapes above are v1's, and an agent announcing anything else
is not the addressee this code was written for. -/
def handshake (conn : Conn) : IO Json := do
  let res ← conn.request "initialize" <| Json.mkObj
    [ ("protocolVersion", (1 : Nat))
    , ("clientCapabilities", Json.mkObj
        [ ("fs", Json.mkObj [("readTextFile", false), ("writeTextFile", false)])
        , ("terminal", false) ])
    , ("clientInfo", Json.mkObj
        [ ("name", Json.str "agentic-lean"), ("version", Json.str "0.1.0") ]) ]
  match res.getObjVal? "protocolVersion" >>= Json.getNat? with
  | .ok 1 => return res
  | .ok v =>
    throw <| IO.userError
      s!"acp: '{conn.prog}' speaks ACP protocol version {v}; this client implements 1"
  | .error e =>
    throw <| IO.userError
      s!"acp: initialize returned no protocolVersion ({e}): {Json.compress res}"

/-- Open a session in `cfg.cwd` — made absolute, because the protocol requires
an absolute path — and remember its id.

`sessionId` is what the session *is*, and `configOptions` is recorded beside it
because it is the only place an adapter says which values it will accept: the
model axis is resolved against it (`Conn.optionValues`, `resolveValue`). Codex
returns a nonstandard `models` and no `configOptions`, which `configCatalogue`
reads as "published nothing"; a caller who wants the rest can have the whole
result from `Conn.request`. -/
def newSession (conn : Conn) : IO String := do
  let dir ← IO.FS.realPath conn.cfg.cwd
  let res ← conn.request "session/new" <| Json.mkObj
    [ ("cwd", Json.str dir.toString), ("mcpServers", Json.arr #[]) ]
  conn.configValues.set (configCatalogue res)
  match res.getObjVal? "sessionId" >>= Json.getStr? with
  | .ok sid => conn.sessionId.set (some sid); return sid
  | .error e =>
    throw <| IO.userError
      s!"acp: session/new returned no sessionId ({e}): {Json.compress res}"

/-- `[[conn.optionValues id]]` = the values the adapter published for config
option `id`, or `[]` if it published none. -/
def optionValues (conn : Conn) (configId : String) : IO (List String) := do
  let cat ← conn.configValues.get
  return match cat.find? (fun o => o.1 == configId) with
    | some o => o.2
    | none => []

/-- `[[conn.firstWarning key]]` = is this the first time anything has asked
about `key` on this connection? True once, false thereafter.

A connection and not a session, deliberately: `freshSessionPerQuestion` opens a
session per question, and an axis that a model cannot take is a fact about the
adapter, so reporting it once per session would report it once per question. -/
def firstWarning (conn : Conn) (key : String) : IO Bool := do
  let seen ← conn.warned.get
  if seen.contains key then return false
  conn.warned.set (key :: seen)
  return true

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
  | .ok stop => return { text := ← acc.get, stopReason := StopReason.ofString stop }
  | .error e =>
    throw <| IO.userError
      s!"acp: session/prompt returned no stopReason ({e}): {Json.compress res}"

/-- Send one text prompt and return what the agent said, discarding *why the
turn ended*. For a caller who has no act to record — the smoke test, a script —
and never for the interpreter, which needs the stop reason
(`Agentic/Core/Exec.lean`). -/
def prompt (conn : Conn) (text : String) : IO String :=
  return (← conn.promptTurn text).text

/-- Select a session mode (`session/set_mode`), reporting the agent's own error
rather than raising it: claude implements this call and **codex answers
`-32602`**, so a caller that treated failure as fatal would work against one
conforming adapter and not the other. -/
def setMode (conn : Conn) (modeId : String) : IO (Except Json Json) := do
  let sid ← conn.theSession
  conn.tryRequest "session/set_mode" <|
    Json.mkObj [("sessionId", Json.str sid), ("modeId", Json.str modeId)]

/-- Set a session configuration option (`session/set_config_option`), reporting
the agent's own error rather than raising it.

**This is how a model is selected.** ACP v1 has no `session/set_model` — claude
answers `-32601` and the schema has no such method — but it does have
`SetSessionConfigOptionRequest`, whose fields are `sessionId`, `configId` and
`value` (`configOptionId` is *not* the name; it earns a `-32602`). Both real
adapters implement it, and both offer a `model` option, so selecting a model is
a protocol operation and not an adapter-specific guess. What is adapter-specific
is the *value*: `haiku` for one, `gpt-5.4-mini/low` for the other, which is why
this takes a string the caller supplies and validates nothing. -/
def setConfigOption (conn : Conn) (configId value : String) : IO (Except Json Json) := do
  let sid ← conn.theSession
  conn.tryRequest "session/set_config_option" <| Json.mkObj
    [ ("sessionId", Json.str sid)
    , ("configId", Json.str configId)
    , ("value", Json.str value) ]

/-- Cancel the turn in flight, if there is a session at all. A notification, so
it does not wait: the outstanding `session/prompt` is what reports `cancelled`,
and the session stays usable afterwards. -/
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
  let (prog, baseArgs) ← cfg.adapter.resolve
  let child ← IO.Process.spawn
    { toStdioConfig := pipes, cmd := prog, args := baseArgs ++ cfg.args, cwd := some cfg.cwd }
  let nextId ← IO.mkRef 0
  let sessionId ← IO.mkRef none
  let configValues ← IO.mkRef []
  let warned ← IO.mkRef []
  let conn : Conn := { cfg, prog, child, nextId, sessionId, configValues, warned }
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
