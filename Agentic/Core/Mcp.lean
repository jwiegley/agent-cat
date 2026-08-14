import Agentic.Core.Rpc
import Agentic.Core.Dsl
import Agentic.Core.Explain
import Agentic.Core.Report
import Agentic.Core.Certify

/-!
# MCP: the dialogue, put on the wire, one question per tool call

A Model Context Protocol server over stdio (protocol revision `2025-11-25`),
offering four tools over the closed-plan DSL of `Agentic/Core/Dsl.lean`:
`workflow_check`, `workflow_start`, `workflow_answer`, `workflow_transcript`.

## The one idea

**A resumable ask-and-continue dialogue is already an object in this package: it
is `Dlg`.**

```
Dlg.done : A → Dlg A
Dlg.ask  : (c : Code) → Q c → (El c → Dlg A) → Dlg A
```

`Dlg.ask` *is* "here is a question; give me an `El c` and I will hand you the
rest", and a tool loop is "here is a question; call me again with an answer".
They are the same shape, so this server needs no threads, no coroutines, no
re-entrant interpreter and no replay-from-the-top. **A run in progress is a
`Dlg Unit` together with the `Table` built so far** — a partial world under
construction, exactly as in `Agentic/Core/Exec.lean`, where the same `Table` is
the memo and the world at once.

What is *not* reused is `Exec.oracle`, and the reason is structural rather than
practical: `Oracle m` is `(c : Code) → Q c → Table → m (El c)`, and here **the
client is the oracle**. "A tool call away" is not a monad in this process, so
the loop is turned inside out and the server holds the continuation. The memo
lookup survives the inversion: `Dlg.resume` walks past every question the table
already answers before surfacing one, which is the runtime half of
`Dlg.execM_ask_hit`, and `Dlg.execM_resume` below proves the walk changes
nothing an interpreter would do.

## What each tool means

* `workflow_check(source)` — parse and type-check, run nothing. On success:
  the rung (`Level`), the cost interval read off `Cost.costTree`, the number of
  paths, and the code/shape sequences where the rung admits them. On failure a
  *tool execution error* (`isError`), because an ill-typed source is actionable
  by the caller: it carries line, column, message and excerpt from
  `Dsl.CheckError` and nothing else.
  The cost interval is not decoration. `Cost.costTree` takes
  `level p ≤ Level.branch` **as an argument**, so this tool cannot be written
  without `Dsl.parseAndCheck_level_le`; the theorem is the term that makes it
  compile.
* `workflow_start(source)` — check, denote, and stop at the first question the
  empty table does not answer.
* `workflow_answer(runId, answer)` — **decode `answer` with `Decode`, the same
  trusted base `Exec` uses, and nothing else**. On `some a` the cell
  `⟨c, q, a⟩` is recorded and the dialogue advances; on `none` — provably only
  at `.flag` (`Decode_eq_none`) — the caller is told so with `Exec.nudge`'s
  words and **nothing is recorded**, because a table entry no party said is
  exactly the forgery `Agentic/Core/Certify.lean`'s header warns about. After
  `Settings.retries` such replies the run fails rather than guessing, which is
  `Exec.oracle`'s abort rule carried onto the wire.
* `workflow_transcript(runId)` — read-only recovery: what has been heard, what
  it has cost, and what is pending. Idempotent, so an agent that lost the thread
  need not re-run anything.

The final report is `Agentic.Core.RunReport`, the same object `demo/Main.lean`
prints: the value, the transcript the log *replays* (not the one the server
remembers — see `RunReport`'s docstring on which fields are meaning and which
are observation), the bill fresh and memoised, the table size, coverage, and the
certificate.

**On the certificate, said plainly.** `certify p t v` is `true` for *every*
closed workflow and every table, the empty one included
(`certify_unit_vacuous`), because the DSL's programs are `Plan [] Unit` and
`Unit` is a subsingleton. The report says so in a `vacuous` field rather than
letting a green light mean something it does not. The field that carries content
is `covered`: every event of the replayed transcript is recorded in the log with
the answer the replay reads (`Plan.Covered`), which is what upgrades `certify`
into `Plan.certify_sound_of_covered` — *every* world agreeing with the log gives
this value and this transcript, not merely some. `reporterOf_warrants` below is
that statement at this server's own report, with the free half of the hypothesis
already discharged.

## Person-addressed questions

`Addressee.person` is not a special construct; it is an addressee. But it is the
one addressee the answering agent must not answer for, and this server surfaces
it on a ladder, in this order:

1. **Elicitation**, when the client advertised the capability and
   `Settings.useElicitation` is on: `elicitation/create` in form mode, with a
   flat `requestedSchema` per `Code`. Only `action: "accept"` yields an answer.
   **`decline` and `cancel` are not `false`.** `El .flag` is two-valued and the
   elicitation result is three-valued; mapping either onto `false` would forge a
   refusal nobody gave. They fall through to (2) and never reach `Decode`.
2. **Relay** — the default, and the only universal path: the question is
   returned to the calling agent with `relay: true` and an instruction, in
   words, to put it to the human in the session and return the answer verbatim.

Honest limitation, stated because the package is about not overclaiming:
**relay cannot prove a human was asked.** The agent could answer the consent
question itself and this server could not tell. Every report therefore records,
per event, which channel carried the answer (`tool-call` or `elicitation`), and
a run answered by relay says so in its caveats. Elicitation is better here
precisely because the *client* renders the dialog; that is an argument for
preferring it where available, not for defaulting to it — measured, a headless
session answers `cancel`, so an elicitation-first server would have no
unattended mode, and unattended is what CI is.

## The trust boundary this server adds, beyond `Exec`'s

`Exec`'s boundary is one total parsing function per `Code` plus four assumptions
about the child process (`Agentic/Core/Acp.lean`). This server keeps `Decode`
verbatim — every `El c` that enters a `Table` here came out of `Decode c`
applied to bytes some client sent — and adds exactly five assumptions, none of
them axiomatized and none of them dischargeable here:

1. **The caller is who it claims to be.** A `runId` is a bearer token in the
   sense that anything on this stdio pipe may use it. There is one client per
   process and the pipe is the boundary; a shared server would need one more.
2. **Relay is honest** (above): a person-addressed answer that arrives through
   `workflow_answer` is asserted by the agent to be the person's, and no
   evidence accompanies the assertion.
3. **The act happens elsewhere.** An `.ack` question asks a tool to *do*
   something, and the doing happens in the client's process. This server can pin
   what the act was asked to do — a proposition about a question — and cannot
   pin what it did. `Agentic/Core/Artifact.lean` reads a directory back for that
   and says plainly that no theorem covers it; this server inherits the gap
   unchanged and reports it as a caveat rather than certifying quietly.
4. **Framing** (`Agentic/Core/Rpc.lean`): one line is one JSON value.
5. **stdout is the protocol.** The only writer of it is `Io.send`, one frame at
   a time; every diagnostic goes to stderr through `Settings.log`. A line on
   stdout that is not a frame is a corrupt stream, and nothing here writes
   one.

What the server does *not* assume is worth as much: it never fabricates an
answer, never defaults an unasked cell, never re-asks a question the log already
answers (`Dlg.resume_pending`), and never records an answer it could not decode.
-/

namespace Agentic.Core

open Lean (Json)

/-! ## The engine: a dialogue stopped at a question

Three definitions and four theorems. They belong beside `Dlg.execM` in
`Agentic/Core/Exec.lean` and live here because this server is what needs them;
nothing below mentions `IO`, JSON or MCP. -/

/-- `[[Dlg.Ask A]]` = a dialogue stopped at a question: the code, the question,
and the rest of the dialogue as a function of the answer.

The pair `(Dlg A, Table)` a run in progress consists of cannot be sent over a
wire, but this can: `c` and `q` are data, and `k` stays in the server. -/
structure Dlg.Ask (A : Type) where
  /-- The kind of answer the pending question asks for. -/
  c : Code
  /-- The pending question. -/
  q : Q c
  /-- The rest of the dialogue, waiting for an answer. -/
  k : El c → Dlg A

/-- `[[Dlg.resume t p]]` = `p` walked past every question `t` already answers,
so that what it returns is either finished or stopped at a question **the log
does not answer** (`Dlg.resume_pending`).

This is the memo lookup of `Dlg.execM` — "look up before asking" — with the ask
removed, which is what an interpreter that does not hold the oracle can do on
its own. `Dlg.execM_resume` is the statement that removing the ask removed
nothing. -/
def Dlg.resume {A : Type} (t : Table) : Dlg A → Dlg A
  | .done a => .done a
  | .ask c q f =>
      match lookup t c q with
      | some a => Dlg.resume t (f a)
      | none => .ask c q f

/-- `[[Dlg.pending? p]]` = the question `p` is stopped at, if it is stopped at
one. Applied to `Dlg.resume t p`, this is "what to put to the client next". -/
def Dlg.pending? {A : Type} : Dlg A → Option (Dlg.Ask A)
  | .done _ => none
  | .ask c q f => some ⟨c, q, f⟩

namespace Dlg

variable {m : Type → Type} [Monad m] {A : Type}

/-- A finished dialogue is left alone. -/
@[simp] theorem resume_done (t : Table) (a : A) : resume t (.done a) = .done a := rfl

/-- **The hit walks on**: a question the log answers is not surfaced again, and
the answer used is the logged one. -/
theorem resume_ask_hit (t : Table) (c : Code) (q : Q c) (f : El c → Dlg A) {a : El c}
    (h : lookup t c q = some a) : resume t (.ask c q f) = resume t (f a) := by
  rw [resume, h]

/-- **The miss stops**, with the question intact for the client to answer. -/
theorem resume_ask_miss (t : Table) (c : Code) (q : Q c) (f : El c → Dlg A)
    (h : lookup t c q = none) : resume t (.ask c q f) = .ask c q f := by
  rw [resume, h]

/-- **The server's engine is the interpreter's engine.** For every oracle in
every monad, running the resumed dialogue against the same log is running the
original: walking past cache hits is invisible to `Dlg.execM`.

This is the theorem that makes "the server holds the continuation" a
reformulation rather than a reimplementation. -/
theorem execM_resume (o : Oracle m) (p : Dlg A) (t : Table) :
    execM o (resume t p) t = execM o p t := by
  induction p with
  | done a => rfl
  | ask c q f ih =>
    cases h : lookup t c q with
    | some a => rw [resume_ask_hit t c q f h, ih a, execM_ask_hit o c q f h]
    | none => rw [resume_ask_miss t c q f h]

/-- **A surfaced question is one the log does not answer.** Hence the client is
never asked twice for the same answer, and hence the cell the answer goes into
is fresh — the two facts a bill and a certificate depend on. -/
theorem resume_pending (t : Table) (p : Dlg A) {c : Code} {q : Q c} {f : El c → Dlg A}
    (h : resume t p = .ask c q f) : lookup t c q = none := by
  induction p with
  | done a => nomatch h
  | ask c' q' f' ih =>
    cases hl : lookup t c' q' with
    | some a => exact ih a (by rw [← resume_ask_hit t c' q' f' hl]; exact h)
    | none =>
      rw [resume_ask_miss t c' q' f' hl] at h
      cases h
      exact hl

/-- **…so recording the client's answer extends the log**, in the extension
order of `Agentic/Core/World.lean`: nothing already recorded is disturbed. -/
theorem le_cons_of_resume (t : Table) (p : Dlg A) {c : Code} {q : Q c} {f : El c → Dlg A}
    (h : resume t p = .ask c q f) (a : El c) : t ≤ Table.cons c q a t :=
  le_cons_of_lookup_none a (resume_pending t p h)

/-- **Delivering an answer is `Dlg.execM`'s miss branch**, for any oracle that
would have given that answer.

Together with `execM_resume` this is the whole correspondence between this
server's state machine and the trusted interpreter, stated one step at a time.
It is stated one step at a time on purpose: the composite statement would have
to quantify over the client, and the client is not a value in this process —
that is the very fact that turned the loop inside out. -/
theorem execM_deliver [LawfulMonad m] (o : Oracle m) (t : Table) (c : Code) (q : Q c)
    (f : El c → Dlg A) (a : El c) (hmiss : lookup t c q = none) (ho : o c q t = pure a) :
    execM o (.ask c q f) t = execM o (resume (Table.cons c q a t) (f a)) (Table.cons c q a t) := by
  rw [execM_ask_miss o c q f hmiss, ho, pure_bind, execM_resume]

end Dlg

/-! ### The engine's axiom cost

`Agentic/Core/Certify.lean` pins the axioms of `certify_sound` and
`Plan.adequacy` because a proof that quietly acquired one would be a different
proof. The two theorems that say this server's loop is the interpreter's are
pinned for the same reason: an engine justified by `Classical.choice` would be
an engine whose justification does not compute. -/

/-- info: 'Agentic.Core.Dlg.execM_resume' does not depend on any axioms -/
#guard_msgs in
#print axioms Dlg.execM_resume

/-- info: 'Agentic.Core.Dlg.resume_pending' does not depend on any axioms -/
#guard_msgs in
#print axioms Dlg.resume_pending

/-- info: 'Agentic.Core.Dlg.execM_deliver' does not depend on any axioms -/
#guard_msgs in
#print axioms Dlg.execM_deliver

namespace Mcp

/-! ## The revision, and what this server says it is -/

/-- The protocol revision this server implements: the current one, and the one
the installed client was measured announcing. -/
def protocolVersion : String := "2025-11-25"

/-- The server's own name on the wire. -/
def serverName : String := "agent-cat-workflow"

/-- The server's version, moved by hand when the tool surface changes. -/
def serverVersion : String := "0.1.0"

/-! The rung's name on the wire is `Agentic.Core.levelName`, of
`Agentic/Core/Explain.lean`, and not a table of this server's own: a client that
reads `"branch"` off a `workflow_check` and a reader who reads it off
`agent-cat cost` are reading one function, whose injectivity —
`levelName_injective`, so that the word determines the rung and a client that
reads it back has lost nothing — is proved there. -/

/-! ## Small JSON helpers

Named rather than inlined so that a field is spelled once. -/

/-- A `Nat` as JSON. -/
def jnat (n : Nat) : Json := Json.num (Lean.JsonNumber.fromNat n)

/-- A list of values as a JSON array. -/
def jarr (l : List Json) : Json := Json.arr l.toArray

/-- An optional string as a string or `null`: the protocol distinguishes "the
author set no model axis" from "the author set the empty one". -/
def jstr? : Option String → Json
  | some s => Json.str s
  | none => Json.null

/-- An optional number as a number or `null`. -/
def jnat? : Option Nat → Json
  | some n => jnat n
  | none => Json.null

/-- A required string argument of a tool call, or the name of what was missing. -/
def strArg (args : Json) (key : String) : Except String String :=
  match args.getObjVal? key with
  | .error _ => .error s!"missing required argument '{key}'"
  | .ok v => match v.getStr? with
    | .error _ => .error s!"argument '{key}' must be a string"
    | .ok s => .ok s

/-! ## Questions on the wire -/

/-- `[[addresseeJson a]]` = who is being asked, split into the kind and the
identifier, because a client that must route a question needs the kind as data
and not as a prefix of a rendered string. `Exec.Addressee.render` is the same
information for a reader and is carried alongside. -/
def addresseeJson : Addressee → Json
  | .model id => Json.mkObj [("kind", Json.str "model"), ("id", Json.str id)]
  | .tool id => Json.mkObj [("kind", Json.str "tool"), ("id", Json.str id)]
  | .person id => Json.mkObj [("kind", Json.str "person"), ("id", Json.str id)]

/-- `[[isPerson a]]` = is this question addressed to a human being? The one
addressee an answering agent must not answer for. -/
def isPerson : Addressee → Bool
  | .person _ => true
  | _ => false

/-- `[[answerSchema c]]` = the JSON Schema of a well-formed answer to a question
of this code, for a caller that validates before it replies.

It is a *description* of what `Decode c` accepts and cannot be more than that:
`Decode .verdict` accepts every string (silence declines, a lone approve word
approves, anything else objects), so the schema for a verdict is `string` with
the shape stated in words. The authority is `Exec.answerSpec`, which is carried
verbatim beside it. -/
def answerSchema : Code → Json
  | .text => Json.mkObj [("type", Json.str "string")]
  | .flag => Json.mkObj [("type", Json.str "string"),
      ("enum", jarr [Json.str "yes", Json.str "no"])]
  | .verdict => Json.mkObj [("type", Json.str "string"),
      ("description", Json.str (Exec.answerSpec .verdict))]
  | .ack => Json.mkObj [("type", Json.str "string"),
      ("description", Json.str (Exec.answerSpec .ack))]

/-- What the calling agent is told to do with a question addressed to a person.

The words matter, so they are one constant: an agent that answers this itself is
an agent that consents on the owner's behalf, which is the failure
`demo/Main.lean` avoids by moving person-questions off the adapter entirely. -/
def relayInstruction : String :=
  "This question is addressed to a person, not to you. Put it to the human in \
   this session, in these words, and call workflow_answer with the human's \
   reply verbatim. Do not answer it yourself and do not paraphrase the reply: \
   an agent that answers a person's question is an agent that consents on that \
   person's behalf. If no human is available, stop and say so — a run that \
   cannot ask its owner is a run that must not proceed."

/-- `[[questionJson seq c q]]` = one pending question as the client sees it.

`answerSpec` is `Exec.answerSpec c` **verbatim** — the same constant the trusted
base's own prompts carry, so the caller is told exactly the format `Decode` will
accept and this server does not invent a second spelling. `model` and `mode` are
`Exec.modelAxis`/`Exec.modeAxis` of the question's scope: the author's request,
reported rather than enforced, since nothing in this process can make a client
honour it. `rendered` is `Exec.renderQ c q {}` — the bytes `Exec` would have put
on an adapter's wire, so a relaying agent relays what an interpreter would have
sent. -/
def questionJson (seq : Nat) (c : Code) (q : Q c) : Json :=
  let relay := isPerson q.addressee
  Json.mkObj <|
    [ ("seq", jnat seq)
    , ("code", Json.str (Exec.Code.name c))
    , ("addressee", addresseeJson q.addressee)
    , ("addresseeRendered", Json.str (Exec.Addressee.render q.addressee))
    , ("model", jstr? (Exec.modelAxis q))
    , ("mode", jstr? (Exec.modeAxis q))
    , ("draw", jnat q.draw)
    , ("prompt", Json.str q.prompt)
    , ("answerSpec", Json.str (Exec.answerSpec c))
    , ("answerSchema", answerSchema c)
    , ("rendered", Json.str (Exec.renderQ c q {}))
    , ("relay", Json.bool relay) ]
    ++ (if relay then [("relayInstruction", Json.str relayInstruction)] else [])

/-! ## Elicitation: the client's own dialog, where there is one -/

/-- `[[elicitSchema c]]` = the `requestedSchema` of an `elicitation/create` for a
question of this code.

Form-mode elicitation restricts `requestedSchema` to a **flat object of
primitives** — no nesting, no arrays of objects — which is why a verdict is an
enum plus a separate objection string rather than the list of objections it
denotes. That flattening is undone by `elicitedText` below, which writes the
answer back out in the vocabulary `Decode` reads. -/
def elicitSchema : Code → Json
  | .text =>
    Json.mkObj
      [ ("type", Json.str "object")
      , ("properties", Json.mkObj [("answer", Json.mkObj
          [ ("type", Json.str "string"), ("title", Json.str "Your answer") ])])
      , ("required", jarr [Json.str "answer"]) ]
  | .flag =>
    Json.mkObj
      [ ("type", Json.str "object")
      , ("properties", Json.mkObj [("consent", Json.mkObj
          [ ("type", Json.str "boolean"), ("title", Json.str "Yes or no?") ])])
      , ("required", jarr [Json.str "consent"]) ]
  | .verdict =>
    Json.mkObj
      [ ("type", Json.str "object")
      , ("properties", Json.mkObj
          [ ("verdict", Json.mkObj
              [ ("type", Json.str "string")
              , ("title", Json.str "Approve, or object?")
              , ("enum", jarr [Json.str "APPROVE", Json.str "OBJECT"]) ])
          , ("objection", Json.mkObj
              [ ("type", Json.str "string")
              , ("title", Json.str "If objecting, why — one line") ]) ])
      , ("required", jarr [Json.str "verdict"]) ]
  | .ack =>
    Json.mkObj
      [ ("type", Json.str "object")
      , ("properties", Json.mkObj [("done", Json.mkObj
          [ ("type", Json.str "boolean"), ("title", Json.str "Was it done?") ])])
      , ("required", jarr [Json.str "done"]) ]

/-- `[[elicitedText c content]]` = the accepted elicitation content, written out
as the **text** a person would have typed, or `none` when the content answers
nothing.

There is one decode site in this server and this is not it: the string returned
here goes through `Decode c` like every other answer, so the elicitation path
adds a *renderer* to the trusted base and not a second parser. The renderers are
`sayFlag`, the person's text verbatim, and the two words `Exec.answerSpec` asks
for; their round trips through `Decode` are pinned by `#guard` below.

`done: false` is `none` on purpose: `Decode .ack` accepts everything, so a
person who says the act was *not* done would otherwise be recorded as having
acknowledged it. -/
def elicitedText (c : Code) (content : Json) : Option String :=
  match c with
  | .text => (content.getObjVal? "answer" >>= Json.getStr?).toOption
  | .flag => match (content.getObjVal? "consent" >>= Json.getBool?).toOption with
    | some b => some (sayFlag b)
    | none => none
  | .verdict =>
    match (content.getObjVal? "verdict" >>= Json.getStr?).toOption with
    | some "APPROVE" => some "APPROVE"
    | some "OBJECT" =>
      match (content.getObjVal? "objection" >>= Json.getStr?).toOption with
      | some why => some s!"OBJECTION: {why}"
      | none => some "OBJECTION: (no reason given)"
    | _ => none
  | .ack => match (content.getObjVal? "done" >>= Json.getBool?).toOption with
    | some true => some "DONE"
    | _ => none

/-! ### The round trips of the elicitation renderers, pinned rather than proved

Each `#guard` puts a rendered answer through the trusted base and asks whether
what comes back is what the person said. They are not theorems: `Decode .flag`
runs through `Exec.words`, which normalizes with `String.trimAscii` and
`String.toLower`, and neither reduces in the kernel — `decide` and `decide
+kernel` both get stuck, measured. `native_decide` would close them and is
forbidden here (it adds `Lean.ofReduceBool` to the axiom set, and
`Agentic/Core/Certify.lean`'s `#guard_msgs` pins must keep elaborating). A
`#guard` runs at elaboration time, fails the build when it is false, and
declares nothing, so it adds no axiom to anything. That is weaker than a theorem
and is labelled as such.

The safety of the server does not rest on them: an elicited text that `Decode`
cannot read is treated exactly like a relayed one it cannot read — nothing is
recorded and the question is put again. -/

/-! Consent survives the elicitation round trip. -/
#guard (Decode .flag (sayFlag true) == some true)

/-! …and so does refusal, which is the direction that matters. -/
#guard (Decode .flag (sayFlag false) == some false)

/-! An accepted `APPROVE` is the unit of the verdict monoid. -/
#guard (Exec.decodeVerdict "APPROVE" == Verdict.approve)

/-! An objection is an objection, and not an approval. -/
#guard (!(Exec.approvesB "OBJECTION: unsafe"))

/-! An objection carries the reason into the verdict it denotes. -/
#guard (Exec.decodeVerdict "OBJECTION: unsafe" == Verdict.object ["OBJECTION: unsafe"])

/-! A consenting form renders to text the trusted base reads as consent. -/
#guard (match elicitedText .flag (Json.mkObj [("consent", Json.bool true)]) with
        | some s => Decode .flag s == some true
        | none => false)

/-! …and a refusing one to text it reads as refusal, which is the direction a
mistake would be unrecoverable in. -/
#guard (match elicitedText .flag (Json.mkObj [("consent", Json.bool false)]) with
        | some s => Decode .flag s == some false
        | none => false)

/-! …and a `decline`-shaped content — no `consent` field at all — yields no text,
so nothing can be recorded from it. -/
#guard (elicitedText .flag (Json.mkObj []) |>.isNone)

/-! An act that was *not* done is not an acknowledgement. -/
#guard (elicitedText .ack (Json.mkObj [("done", Json.bool false)]) |>.isNone)

/-! ## What the server remembers -/

/-- `[[Channel]]` = which wire carried an answer into the log.

Recorded per event because the two are not equally good evidence, and a report
that hid the difference would be claiming more than it knows: an `elicitation`
answer was rendered by the client's own dialog, and a `toolCall` answer is
whatever the calling agent said it was. -/
inductive Channel where
  /-- The calling agent supplied the text — by relay, if the addressee was a
  person, and relay cannot prove a human was asked. -/
  | toolCall
  /-- The client's own elicitation dialog supplied it. -/
  | elicitation
  deriving DecidableEq, Repr

/-- The channel's name on the wire. -/
def Channel.name : Channel → String
  | .toolCall => "tool-call"
  | .elicitation => "elicitation"

/-- `[[Heard]]` = one answer as it arrived: which question it answered, in what
order, and over which wire.

The `Event` is the semantic part and the rest is observation, exactly the split
`RunReport`'s docstring draws. The final report's transcript is **not** built
from these: it is replayed from the log by `RunReport.of`, and comparing the two
is a check on this server rather than a description of it. -/
structure Heard where
  /-- Which question of the run this answered, counting from zero. -/
  seq : Nat
  /-- The question and the answer, as the semantics records them. -/
  event : Event
  /-- Which wire carried it. -/
  channel : Channel

/-- `[[Reporter]]` = a plan's residual meaning as a *report of a log*:
`fun t => RunReport.of p () t (certify p t ())`.

**Why a closure and not the plan.** `Plan` lives in `Type 1` — its `case` node
stores the arms as a function of a `FinEnum` tag — and `IO α` requires
`α : Type`, so a server that threads its state through `IO` cannot carry a plan
at all. It does not need to: everything it wanted the plan for is *this
function*, the plan's meaning applied to a log. `RunReport.of` recomputes the
transcript and the coverage verdict from the plan and the log alone, so a report
built this way still cannot report a transcript the log does not denote. -/
abbrev Reporter : Type := Table → RunReport Unit

/-- `[[reporterOf p]]` = the plan, kept as what a report needs of it. The
certificate is recomputed from the log rather than remembered, which is what
`RunReport`'s docstring asks a consumer that does not trust the field to do. -/
def reporterOf (p : Plan [] Unit) : Reporter := fun t => RunReport.of p () t (certify p t ())

/-- **What a report of a log warrants, on the workflows this server runs.**
Coverage alone is the whole of it: on a closed workflow the certificate is free
(`certify_unit_vacuous`), so `RunReport.warrants` discharges its second
hypothesis by itself and what remains is the field the report calls `covered`.
Given it, **every** world agreeing with the log assigns the plan the reported
value and the reported transcript — not merely some world, which is what
`certify` on its own says.

This is the theorem the `certificate` object in every finished report is
reporting, and the reason its `note` says the honest thing about `certified`. -/
theorem reporterOf_warrants (p : Plan [] Unit) (t : Table)
    (hcov : (reporterOf p t).covered = true) (ω : Ω) (hω : Extends ω t) :
    Plan.run ω p Env.nil = (reporterOf p t).value ∧
      Plan.trace ω p Env.nil = (reporterOf p t).transcript :=
  RunReport.warrants p () t (certify p t ()) [] hcov (certify_unit_vacuous p t) ω hω

/-- `[[Run]]` = a run in progress: the dialogue that is left, the partial world
built so far, and the plan's report-of-a-log.

`dlg` is always **resumed** — `Dlg.resume table dlg = dlg` is the invariant every
transition below preserves — so `Dlg.pending?` of it is the question to put, and
`Dlg.resume_pending` says the log does not already answer it. -/
structure Run where
  /-- The identifier the client uses. -/
  id : String
  /-- The source the run was started from, kept for `workflow_transcript`. -/
  source : String
  /-- The rung the checked plan sits at. -/
  level : Level
  /-- What `workflow_check` would have said about this source, computed once
  when the run started, so that a report can price the program it ran. -/
  cost : Json
  /-- The plan, as the report of a log; see `Reporter`. -/
  report : Reporter
  /-- What is left of the dialogue, resumed past every logged answer. -/
  dlg : Dlg Unit
  /-- The partial world: every cell some client put there through `Decode`. -/
  table : Table
  /-- What was heard, in arrival order. -/
  heard : List Heard
  /-- How many questions have been answered, which is also the `seq` of the one
  now pending: a question re-asked after an unreadable reply keeps its number,
  because it is the same question. -/
  asked : Nat
  /-- Consecutive replies to the pending question that `Decode` could not read.
  Reset by every answer it could. -/
  attempts : Nat
  /-- Why the run was abandoned, if it was. -/
  failed : Option String

/-- The transcript as the server heard it, in arrival order. Compared with the
replayed one in the final report; never substituted for it. -/
def Run.trace (r : Run) : Trace := r.heard.map (·.event)

/-- Was any answer relayed through the calling agent on behalf of a person?
The caveat this puts in the report is the one thing a reader must not miss. -/
def Run.relayedPerson (r : Run) : Bool :=
  r.heard.any fun h => h.channel == Channel.toolCall && isPerson h.event.q.addressee

/-- Did the run put an `.ack` — a question that asks a tool to *act*? Then
something happened outside this process that no theorem here covers. -/
def Run.acted (r : Run) : Bool := r.heard.any fun h => h.event.c == Code.ack

/-- `[[Client]]` = what the peer said about itself in `initialize`, insofar as
this server acts on it. -/
structure Client where
  /-- The client's name, for the log. -/
  name : String
  /-- Its version, for the log. -/
  version : String
  /-- The revision it asked for, which may not be the one we answer with. -/
  protocolVersion : String
  /-- Did it advertise form-mode elicitation? A bare `{}` counts: per the
  specification's backwards-compatibility rule, `"elicitation": {}` is
  `{"form": {}}`, form mode only. URL mode is never used by this server. -/
  elicitation : Bool

/-- `[[State]]` = the whole server: who is on the other end, and every run.

Threaded through the loop as a value rather than held in an `IO.Ref`, because a
fold over a list of lines is then a complete test of the dispatcher, which is
what `test/McpSmoke.lean` is: the executable and the test drive the same
function over the same states. -/
structure State where
  /-- `none` until `initialize` arrives. -/
  client : Option Client := none
  /-- Whether `notifications/initialized` has been seen. Reported, not enforced:
  the specification lets a client send it late, and refusing work over it would
  invent a requirement. -/
  ready : Bool := false
  /-- Every run, newest first. -/
  runs : List Run := []
  /-- The counter behind run identifiers, so ids are `r-1`, `r-2`, … and a test
  can name them. -/
  nextRun : Nat := 0

/-- Find a run by its identifier. -/
def State.find? (st : State) (id : String) : Option Run := st.runs.find? (·.id == id)

/-- Replace a run by its identifier, or add it if it is new. -/
def State.put (st : State) (r : Run) : State :=
  if st.runs.any (·.id == r.id) then
    { st with runs := st.runs.map fun r' => if r'.id == r.id then r else r' }
  else
    { st with runs := r :: st.runs }

/-! ## The runtime's policy, which no theorem mentions -/

/-- `[[Settings]]` = the policy this server needs and the semantics does not.

Nothing here is visible to any theorem; two servers with different settings
exhibit two worlds, and every result above quantifies over all of them. -/
structure Settings where
  /-- How many further attempts a caller gets after a reply `Decode` could not
  read. `Exec.Settings.retries`, on the wire; only a `.flag` can trigger it
  (`Decode_eq_none`). -/
  retries : Nat := 1
  /-- Try `elicitation/create` for person-addressed questions when the client
  advertised the capability. On by default *and harmless when unattended*: a
  headless client answers `cancel`, which falls through to relay. -/
  useElicitation : Bool := true
  /-- How many messages this server will read before it stops listening. The
  loop is structural in this number, which is why this file needs no `partial`.
  -/
  maxMessages : Nat := 1000000
  /-- How many frames to read while waiting for one elicitation result. -/
  maxElicitWait : Nat := 64
  /-- How many questions one tool call may answer by elicitation before it
  returns to the caller regardless. A bound on work done between a request and
  its response, not a semantic limit. -/
  maxElicitChain : Nat := 64
  /-- Where a diagnostic goes. **stderr, always**: stdout is the protocol. -/
  log : String → IO Unit := fun msg => do (← IO.getStderr).putStrLn s!"workflow-mcp: {msg}"

/-! ## The stream, as a value

The two directions of the pipe, plus the counter for our own request ids, behind
an interface — so that `test/McpSmoke.lean` drives the *same* dispatcher over a
list of lines that the executable drives over stdio, and the test is a test of
the server rather than of a copy of it.

The trust boundary here is `Agentic/Core/Rpc.lean`'s: one line is one JSON
value. -/
structure Io where
  /-- One line of input, or `none` at end of stream — which is how an MCP stdio
  session ends: the client closes the pipe, and closing is the shutdown. -/
  readLine : IO (Option String)
  /-- Write one frame and flush; the framing *is* the newline. -/
  writeLine : String → IO Unit
  /-- The next id for a request *this* server originates. -/
  nextId : IO Nat

/-- The real thing: stdin, stdout, and a counter. -/
def Io.stdio : IO Io := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let ids ← IO.mkRef (0 : Nat)
  let readLine : IO (Option String) := do
    let l ← stdin.getLine
    return if l.isEmpty then none else some l
  let writeLine (s : String) : IO Unit := do
    stdout.putStr (s ++ "\n")
    stdout.flush
  return { readLine := readLine, writeLine := writeLine
         , nextId := ids.modifyGet fun n => (n, n + 1) }

/-- `[[Io.ofList lines sink]]` = the stream a harness drives: `lines` are read in
order and then the stream ends, and every frame written is appended to `sink`.

This is what makes `test/McpSmoke.lean` a test of the server rather than of a
copy of it: the same `serve`, over the same `State`, with a list where the pipe
was. Note that a scripted list interleaves correctly with a server-initiated
`elicitation/create`, because the server reads its answer from the same stream,
in the same order, that a real client would write it to. -/
def Io.ofList (lines : List String) (sink : IO.Ref (Array String)) : IO Io := do
  let rest ← IO.mkRef lines
  let ids ← IO.mkRef (0 : Nat)
  let readLine : IO (Option String) :=
    rest.modifyGet fun l => match l with
      | [] => (none, [])
      | x :: xs => (some x, xs)
  return { readLine := readLine
         , writeLine := fun s => sink.modify (·.push s)
         , nextId := ids.modifyGet fun n => (n, n + 1) }

/-- Write one JSON value as one frame. -/
def Io.send (io : Io) (j : Json) : IO Unit := io.writeLine j.compress

/-! ## The tools, and their schemas

The schemas are values in this file and are what `tools/list` returns; there is
no second copy in a README to drift from them. -/

/-- `[[Tool]]` = one entry of `tools/list`: what it is called, what it does, what
it takes and what it gives back. -/
structure Tool where
  /-- The name the client calls. -/
  name : String
  /-- A human title for a picker. -/
  title : String
  /-- What the tool does and what it promises, in words. This is the only
  documentation a calling agent has, so it carries the semantics and not a
  summary of it. -/
  description : String
  /-- The JSON Schema of the arguments. -/
  inputSchema : Json
  /-- The JSON Schema of `structuredContent`. Results conform to it, error
  results included: only `ok` is required, and a failure is `ok: false` with
  `error` filled in. -/
  outputSchema : Json

/-- The `tools/list` entry for a tool, with the read-only/destructive
annotations a client may show. Only `workflow_answer` can cause anything to
happen in the world, and only because an `.ack` question asks a tool to act. -/
def Tool.json (t : Tool) (readOnly : Bool) : Json :=
  Json.mkObj
    [ ("name", Json.str t.name)
    , ("title", Json.str t.title)
    , ("description", Json.str t.description)
    , ("inputSchema", t.inputSchema)
    , ("outputSchema", t.outputSchema)
    , ("annotations", Json.mkObj
        [ ("title", Json.str t.title)
        , ("readOnlyHint", Json.bool readOnly)
        , ("openWorldHint", Json.bool (!readOnly)) ]) ]

/-- An object schema from its properties and its required keys. -/
def objSchema (props : List (String × Json)) (required : List String) : Json :=
  Json.mkObj
    [ ("type", Json.str "object")
    , ("properties", Json.mkObj props)
    , ("required", jarr (required.map Json.str))
    , ("additionalProperties", Json.bool false) ]

/-- A property of a stated JSON type, with a description. -/
def prop (ty : String) (desc : String) : Json :=
  Json.mkObj [("type", Json.str ty), ("description", Json.str desc)]

/-- A property that may also be `null`, which is how every "not applicable at
this rung" field is reported: a missing field and a field that is `null` say
different things, and this server says the second. -/
def propOrNull (ty : String) (desc : String) : Json :=
  Json.mkObj [("type", jarr [Json.str ty, Json.str "null"]), ("description", Json.str desc)]

/-- The `error` object every tool shares: a message, and where in the source it
was, when the failure was a type error. -/
def errorSchema : Json :=
  Json.mkObj
    [ ("type", jarr [Json.str "object", Json.str "null"])
    , ("description", Json.str
        "Why the call failed. `kind` is one of check-error, no-such-run, \
         undecodable-answer, run-finished, run-failed.") ]

/-- The `question` object every asking result carries. -/
def questionSchema : Json :=
  Json.mkObj
    [ ("type", jarr [Json.str "object", Json.str "null"])
    , ("description", Json.str
        "The pending question: seq, code, addressee {kind,id}, model, mode, \
         draw, prompt, answerSpec (verbatim from the interpreter's own trusted \
         base), answerSchema, rendered (the bytes the interpreter would have \
         put on an adapter's wire), relay, and relayInstruction when relay is \
         true.") ]

/-- The `report` object a finished run carries. -/
def reportSchema : Json :=
  Json.mkObj
    [ ("type", jarr [Json.str "object", Json.str "null"])
    , ("description", Json.str
        "The finished run: value, transcript (replayed from the log, not \
         remembered), bill {fresh, memo, unit}, table {size}, certificate \
         {certified, covered, vacuous, note}, cost (what the program was \
         quoted before it ran), channels, and caveats.") ]

/-- `workflow_check`. -/
def checkTool : Tool where
  name := "workflow_check"
  title := "Check a workflow program"
  description :=
    "Parse and type-check a workflow written in the closed-plan DSL. Runs \
     nothing, asks nobody, costs nothing.\n\n\
     A program is `workflow { … }` over braced blocks: `let x = ask <model|tool|\
     person> \"name\" [using model \"m\"] for <text|verdict|flag|ack> \"words\"` \
     binds an answer, `{x}` splices a text answer into a later prompt, `panel \
     [ ask …, ask … ]` combines verdicts, `act <addressee> \"words\"` is the \
     effect, `if x { … } else { … }` branches on a flag, `case v { approve { … } \
     object { … } declined { … } }` on a verdict, and `revising a up to n \
     revisions { check given p { … } revise given p, why { … } } approved given \
     p { … } never approved { … }` is the bounded revision loop. A block that \
     runs out of statements is over; `{ }` does nothing.\n\n\
     On success it reports the rung the program sits at (batch, pipeline or \
     branch — the language has no syntax for the dynamic rung, so every \
     accepted program is at most branch, and that is a theorem about the \
     language rather than an observation about this program), the cost \
     interval read off the program's cost tree, and the number of distinct \
     paths through it. minBill and maxBill are the fewest and the most \
     consultations any run of this program can put, one unit per consultation; \
     at the branch rung the question count is path-dependent, and this \
     interval is the honest summary of it. codes and shapes are the exact \
     question sequence, and are null exactly when a branch makes the sequence \
     depend on an answer.\n\n\
     On failure it returns isError with the line, the column, the message and \
     the offending fragment. That is a tool execution error and not a protocol \
     error, because it is the actionable kind: fix the source and call again."
  inputSchema := objSchema
    [("source", prop "string" "The workflow program.")] ["source"]
  outputSchema := Json.mkObj
    [ ("type", Json.str "object")
    , ("properties", Json.mkObj
        [ ("ok", prop "boolean" "Did the source type-check?")
        , ("level", propOrNull "string" "The rung: batch, pipeline or branch.")
        , ("questions", propOrNull "integer"
            "The number of questions, where the term fixes it; null at branch.")
        , ("minBill", propOrNull "integer" "The cheapest run, in consultations.")
        , ("maxBill", propOrNull "integer" "The dearest run, in consultations.")
        , ("paths", propOrNull "integer" "Leaves of the cost tree.")
        , ("codes", Json.mkObj [("type", jarr [Json.str "array", Json.str "null"])])
        , ("shapes", Json.mkObj [("type", jarr [Json.str "array", Json.str "null"])])
        , ("error", errorSchema)
        , ("render", Json.mkObj [("type", Json.str "array")]) ])
    , ("required", jarr [Json.str "ok"]) ]

/-- `workflow_start`. -/
def startTool : Tool where
  name := "workflow_start"
  title := "Start a workflow run"
  description :=
    "Type-check a workflow and begin it, stopping at its first question.\n\n\
     The server holds, for this run, the dialogue the plan denotes together \
     with the answer table built so far — a partial world under construction, \
     exactly as the interpreter holds it. Nothing is asked of anybody by this \
     call: it returns the first question and waits.\n\n\
     Answer it with workflow_answer. A question whose addressee is a person is \
     marked relay: true, and must be put to the human in your session and \
     answered verbatim in their words, never in yours."
  inputSchema := objSchema
    [("source", prop "string" "The workflow program.")] ["source"]
  outputSchema := Json.mkObj
    [ ("type", Json.str "object")
    , ("properties", Json.mkObj
        [ ("ok", prop "boolean" "Did the source type-check?")
        , ("runId", propOrNull "string" "The identifier for this run.")
        , ("status", propOrNull "string" "asking, done or failed.")
        , ("question", questionSchema)
        , ("report", reportSchema)
        , ("error", errorSchema)
        , ("render", Json.mkObj [("type", Json.str "array")]) ])
    , ("required", jarr [Json.str "ok"]) ]

/-- `workflow_answer`. -/
def answerTool : Tool where
  name := "workflow_answer"
  title := "Answer the pending question"
  description :=
    "Supply the answer to a run's pending question and advance it to the next \
     one, or to its final report.\n\n\
     The answer is text, and it is read by the interpreter's own trusted base \
     — the same total parsing function per kind of answer that a live run \
     uses, never a second parser. An answer it cannot read is reported back to \
     you as an error with a restatement of the format, and the cell is NOT \
     recorded: nothing enters the log that no party said. Only a yes/no \
     question can fail to parse this way; text, verdicts and acknowledgements \
     always read. After the retry budget is spent the run fails rather than \
     guessing.\n\n\
     A question already answered in this run's log is never asked again, so \
     each answer is billed once.\n\n\
     When the dialogue finishes, the report carries the value, the transcript \
     replayed from the log, the bill fresh and memoised, the table size, \
     whether the log covers the replay, and the certificate — with a plain \
     statement of what the certificate is worth on a closed workflow."
  inputSchema := objSchema
    [ ("runId", prop "string" "The run, from workflow_start.")
    , ("answer", prop "string"
        "The answer, in the words the question's answerSpec asked for.") ]
    ["runId", "answer"]
  outputSchema := Json.mkObj
    [ ("type", Json.str "object")
    , ("properties", Json.mkObj
        [ ("ok", prop "boolean" "Was the answer read and recorded?")
        , ("runId", propOrNull "string" "The run.")
        , ("status", propOrNull "string" "asking, done or failed.")
        , ("question", questionSchema)
        , ("report", reportSchema)
        , ("retriesLeft", propOrNull "integer"
            "Attempts remaining at this question after an unreadable answer.")
        , ("error", errorSchema)
        , ("render", Json.mkObj [("type", Json.str "array")]) ])
    , ("required", jarr [Json.str "ok"]) ]

/-- `workflow_transcript`. -/
def transcriptTool : Tool where
  name := "workflow_transcript"
  title := "Read a run back"
  description :=
    "What a run has heard so far, what it has cost so far, and what it is \
     waiting for. Read-only and idempotent: an agent that lost the thread can \
     recover with this and re-run nothing.\n\n\
     The transcript is what arrived, event by event, with the channel that \
     carried each answer — tool-call or elicitation. The distinction is \
     reported because the two are not equally good evidence: an answer relayed \
     through you is whatever you said it was."
  inputSchema := objSchema
    [("runId", prop "string" "The run.")] ["runId"]
  outputSchema := Json.mkObj
    [ ("type", Json.str "object")
    , ("properties", Json.mkObj
        [ ("ok", prop "boolean" "Is there such a run?")
        , ("runId", propOrNull "string" "The run.")
        , ("status", propOrNull "string" "asking, done or failed.")
        , ("source", propOrNull "string" "The program this run is of.")
        , ("cost", Json.mkObj [("type", jarr [Json.str "object", Json.str "null"])])
        , ("transcript", Json.mkObj [("type", jarr [Json.str "array", Json.str "null"])])
        , ("bill", Json.mkObj [("type", jarr [Json.str "object", Json.str "null"])])
        , ("question", questionSchema)
        , ("report", reportSchema)
        , ("error", errorSchema)
        , ("render", Json.mkObj [("type", Json.str "array")]) ])
    , ("required", jarr [Json.str "ok"]) ]

/-- Every tool, in the order `tools/list` returns them, paired with whether it
is read-only. `workflow_answer` is the one that is not: an `.ack` question asks
a tool to act, and the act happens in the client's process. -/
def tools : List (Tool × Bool) :=
  [(checkTool, true), (startTool, true), (answerTool, false), (transcriptTool, true)]

/-! ## Results

Every result carries both a structured object and a text rendering of the same
thing: `structuredContent` for a client that validates it against
`outputSchema`, and two text blocks for one that does not — first the report as
lines a reader can take in, then the serialised JSON the specification asks a
structured tool to duplicate. Neither says anything the other does not. -/

/-- A text content block. -/
def textBlock (s : String) : Json :=
  Json.mkObj [("type", Json.str "text"), ("text", Json.str s)]

/-- `[[renderOf j]]` = the lines an object carries for a reader, in its `render`
field. Every structured result this server builds has one. -/
def renderOf (j : Json) : List String :=
  match j.getObjVal? "render" with
  | .ok (.arr xs) => xs.toList.filterMap fun x => x.getStr?.toOption
  | _ => []

/-- `[[toolResult structured isError]]` = one `tools/call` result.

The text blocks are derived from the structured object rather than passed
alongside it, so the two cannot drift: the first is the object's own `render`
lines and the second is the object itself, serialised as the specification asks
a structured tool to duplicate it.

`isError` is the *tool execution* error of the specification — the actionable
kind, fed back to the model — and never a JSON-RPC error: a source that does not
type-check, a run identifier that does not exist and an answer that cannot be
read are all things the caller can fix. -/
def toolResult (structured : Json) (isError : Bool := false) : Json :=
  Json.mkObj
    [ ("content", jarr [ textBlock (String.intercalate "\n" (renderOf structured))
                       , textBlock structured.compress ])
    , ("structuredContent", structured)
    , ("isError", Json.bool isError) ]

/-- The `render` field: the same lines as the first text block, inside the
structured object, so that a client reading only `structuredContent` still has
something for a human to read. -/
def withRender (fields : List (String × Json)) (render : List String) : Json :=
  Json.mkObj (fields ++ [("render", jarr (render.map Json.str))])

/-- A tool error whose diagnosis is a kind and a message. -/
def errObj (kind : String) (message : String) (extra : List (String × Json) := []) : Json :=
  Json.mkObj ([("kind", Json.str kind), ("message", Json.str message)] ++ extra)

/-! ## `workflow_check` -/

/-! The cost quoted here is `Explain.costSummary` — the cheapest bill, the
dearest bill and the number of paths, from `Cost.costTree` — and not a second
fold: what a client is quoted over the wire and what `agent-cat cost` prints for
a reader are the same three numbers out of the same tree. -/

/-- A question shape as JSON: who would be asked, under what scope, at which
draw. `Q.Shape.withPrompt` with the empty prompt is how the scope axes are read
off a shape — `Q.withPrompt_shape` says it changes no shape, so this reads the
shape's own axes and not another question's. -/
def shapeJson (s : Shape) : Json :=
  let q := s.2.withPrompt ""
  Json.mkObj
    [ ("code", Json.str (Exec.Code.name s.1))
    , ("addressee", addresseeJson s.2.addressee)
    , ("model", jstr? (Exec.modelAxis q))
    , ("mode", jstr? (Exec.modeAxis q))
    , ("draw", jnat s.2.draw) ]

/-- The diagnosis of an ill-typed source, with the position the DSL's own error
type carries. Three consumers must report a type error identically; this is the
one built from `Dsl.CheckError` rather than from a message. -/
def checkErrorJson (e : Dsl.CheckError) : Json :=
  errObj "check-error" e.message
    [ ("line", jnat e.pos.line)
    , ("col", jnat e.pos.col)
    , ("excerpt", Json.str e.excerpt)
    , ("rendered", Json.str (toString e)) ]

/-- `[[checkSummary p h]]` = what this server knows about an accepted program
without running it: the rung, the cost interval, the paths, and the question
sequence where the term fixes one — as the structured object and as the lines
that say the same thing.

Shared by `workflow_check` and `workflow_start`, so a run reports the same
prices its source was quoted. -/
def checkSummary (p : Plan [] Unit) (h : level p ≤ Level.branch) : Json × List String :=
  let (lo, hi, paths) := Explain.costSummary p h
  let cs := codes p
  let shs := shapes p
  let render :=
    [ s!"level: {levelName (level p)}"
    , s!"bill: {sayNat? lo} … {sayNat? hi} consultations over {paths} path(s)" ]
      ++ (match shs with
          | some l => l.map fun s =>
              s!"  {Exec.Code.name s.1}  {Exec.Addressee.render s.2.addressee}"
          | none => ["  (the question sequence depends on an answer: this program branches)"])
  ( Json.mkObj
      [ ("ok", Json.bool true)
      , ("level", Json.str (levelName (level p)))
      , ("questions", jnat? (shs.map (·.length)))
      , ("minBill", jnat? lo)
      , ("maxBill", jnat? hi)
      , ("paths", jnat paths)
      , ("codes", match cs with
          | some l => jarr (l.map fun c => Json.str (Exec.Code.name c))
          | none => Json.null)
      , ("shapes", match shs with
          | some l => jarr (l.map shapeJson)
          | none => Json.null)
      , ("error", Json.null) ]
  , render )

/-- Add a `render` array to an object already built. -/
def addRender (j : Json) (render : List String) : Json :=
  match j with
  | .obj kvs => Json.obj (kvs.insert "render" (jarr (render.map Json.str)))
  | _ => j

/-- `workflow_check`, as a function of the source alone: no state, no IO. -/
def runCheck (source : String) : Json :=
  match h : Dsl.parseAndCheckE source with
  | .error e =>
    let render := [s!"workflow_check: {toString e}"]
    toolResult (withRender [("ok", Json.bool false), ("error", checkErrorJson e)] render) true
  | .ok p =>
    let hlv := Dsl.parseAndCheck_level_le source p ((Dsl.parseAndCheck_ok_iff source p).mpr h)
    let (summary, render) := checkSummary p hlv
    toolResult (addRender summary render)

/-! ## Reporting a run -/

/-- One heard event as JSON: the question, the answer, and the wire that carried
it. `sayAnswer` writes the answer back out in the vocabulary of its code, so a
reader sees what `Decode` read and not the bytes it read it from. -/
def heardJson (h : Heard) : Json :=
  Json.mkObj
    [ ("seq", jnat h.seq)
    , ("code", Json.str (Exec.Code.name h.event.c))
    , ("addressee", addresseeJson h.event.q.addressee)
    , ("prompt", Json.str h.event.q.prompt)
    , ("answer", Json.str (sayAnswer h.event.c h.event.a))
    , ("channel", Json.str h.channel.name) ]

/-- The caveats a report must carry, because they are the things this server
cannot check. Empty is a claim too, so it is never omitted. -/
def caveats (r : Run) : List String :=
  (if r.relayedPerson then
    ["A question addressed to a person was answered through the calling agent. \
      Relay cannot prove a human was asked: this report records what the agent \
      said the person said."] else [])
  ++ (if r.acted then
    ["This run put an act (an `ack` question). The act happened in the client's \
      process, not here; what it was asked to do is in the transcript, what it \
      did is not, and no theorem in this package covers the difference."] else [])

/-- `[[reportJson r]]` = the finished run.

The transcript is `RunReport.of`'s — replayed from the log by the plan's own
meaning — and the bills are folds of that replay, not counters this server kept.
`heardMatchesReplay` compares the replay with what actually arrived; it is a
check on this server and, under `covered`, `Plan.certify_sound_of_covered` says
it cannot fail. -/
def reportJson (r : Run) : Json :=
  let rep := r.report r.table
  let cert := rep.certified
  let agrees := decide (r.trace = rep.transcript)
  let render :=
    [ "--- transcript (addressee | scope | code | prompt | answer) ---" ]
      ++ Trace.render rep.transcript
      ++ [ "---"
         , s!"bill: {rep.billFresh} consultations fresh, {rep.billMemo} memoized \
              (tick: one unit per consultation)"
         , s!"table: {rep.tableSize} answers"
         , s!"covered: {rep.covered}   certified: {cert} (vacuous on a closed \
              workflow: certify is true for every Plan [] Unit and every table)"
         , s!"heard transcript agrees with the replay: {agrees}" ]
      ++ caveats r
  Json.mkObj
    [ ("value", Json.str "()")
    , ("level", Json.str (levelName r.level))
    , ("transcript", jarr (r.heard.map heardJson))
    , ("replay", jarr ((Trace.render rep.transcript).map Json.str))
    , ("bill", Json.mkObj
        [ ("fresh", jnat rep.billFresh)
        , ("memo", jnat rep.billMemo)
        , ("unit", Json.str "consultations (tick: one unit per consultation)") ])
    , ("table", Json.mkObj [("size", jnat rep.tableSize)])
    , ("certificate", Json.mkObj
        [ ("certified", Json.bool cert)
        , ("covered", Json.bool rep.covered)
        , ("vacuous", Json.bool true)
        , ("note", Json.str
            "certified is `certify p t ()`, and on a closed workflow — a \
             Plan [] Unit, which is what this language builds — it is true for \
             every table, the empty one included. The field that carries \
             content is `covered`: every event of the replayed transcript is \
             recorded in the log with the answer the replay reads, which is \
             what turns the certificate from `some world agrees` into `every \
             world agreeing with this log agrees`.") ])
    , ("cost", r.cost)
    , ("heardMatchesReplay", Json.bool agrees)
    , ("caveats", jarr ((caveats r).map Json.str))
    , ("render", jarr (render.map Json.str)) ]

/-- The bill so far, for a run in progress: the fold of what has actually been
heard. `billNat` and `memoNat` are the library's, so the number a run reports
mid-flight and the number it reports at the end are the same function. -/
def partialBillJson (r : Run) : Json :=
  Json.mkObj
    [ ("fresh", jnat (billNat r.trace))
    , ("memo", jnat (memoNat r.trace))
    , ("unit", Json.str "consultations so far (tick: one unit per consultation)") ]

/-- The run's status word. -/
def Run.status (r : Run) : String :=
  match r.failed with
  | some _ => "failed"
  | none => match r.dlg.pending? with
    | some _ => "asking"
    | none => "done"

/-! ## The loop

`surface` is where a run meets the wire: it puts the pending question to the
client's own dialog where there is one, and hands it back to the caller
otherwise. -/

/-- Await the result of one `elicitation/create`, by id.

While waiting, notifications are ignored and inbound *requests* are refused with
`-32603` naming the reason: this server is single-threaded on purpose, and a
truthful refusal is better than a queue that reorders a consent dialog. The wait
is bounded by `Settings.maxElicitWait` frames, which is what makes it structural
rather than `partial`. -/
def awaitElicit (io : Io) (set : Settings) (wantId : Nat) : Nat → IO (Option Json)
  | 0 => do set.log "gave up waiting for an elicitation result"; return none
  | n + 1 => do
    match ← io.readLine with
    | none => return none
    | some line =>
      if line.all Char.isWhitespace then awaitElicit io set wantId n
      else match Rpc.Msg.ofLine line with
      | .error e => do
        io.send (Rpc.errorFrame Json.null Rpc.parseError s!"could not parse a line: {e}")
        awaitElicit io set wantId n
      | .ok (.response id payload) =>
        if id.getNat? == .ok wantId then
          match payload with
          | .ok res => return some res
          | .error e => do
            set.log s!"the client refused the elicitation: {e.compress}"
            return none
        else awaitElicit io set wantId n
      | .ok (.notification _ _) => awaitElicit io set wantId n
      | .ok (.request id _ _) => do
        io.send (Rpc.errorFrame id Rpc.internalError
          "this server is waiting for an elicitation result and answers one \
           request at a time")
        awaitElicit io set wantId n

/-- `[[elicit io set c q]]` = put a person's question to the client's own dialog,
and return the text they typed.

`none` covers every case that is not an answer, and they are not the same case:
the capability was not advertised, the client declined, the dialog was
cancelled, or the content answered nothing. **None of them becomes an answer.**
`decline` and `cancel` in particular are not `false`: `El .flag` is two-valued
and this result is three-valued, and mapping the third onto a refusal would
forge a log entry indistinguishable from one the owner gave. -/
def elicit (io : Io) (set : Settings) (c : Code) (q : Q c) : IO (Option String) := do
  let id ← io.nextId
  io.send <| Rpc.request (jnat id) "elicitation/create" <| Json.mkObj
    [ ("mode", Json.str "form")
    , ("message", Json.str (Exec.renderQ c q {}))
    , ("requestedSchema", elicitSchema c) ]
  match ← awaitElicit io set id set.maxElicitWait with
  | none => return none
  | some res =>
    match (res.getObjVal? "action" >>= Json.getStr?).toOption with
    | some "accept" =>
      match res.getObjVal? "content" with
      | .ok content => return elicitedText c content
      | .error _ => do
        set.log "the client accepted an elicitation with no content"
        return none
    | some a => do
      set.log s!"the person did not answer ({a}); relaying the question instead"
      return none
    | none => return none

/-- Record one answer: the cell goes into the log, the dialogue advances, and
the log is walked past everything it now answers.

This is `Dlg.execM`'s miss branch — `Dlg.execM_deliver` is the equation — and it
is the only function in this file that writes to a `Table`. -/
def deliver (r : Run) (a : Dlg.Ask Unit) (x : El a.c) (ch : Channel) : Run :=
  let t := Table.cons a.c a.q x r.table
  { r with
    table := t
    dlg := Dlg.resume t (a.k x)
    heard := r.heard ++ [{ seq := r.asked, event := ⟨a.c, a.q, x⟩, channel := ch }]
    asked := r.asked + 1
    attempts := 0 }

/-- `[[surface io set client r]]` = advance a run as far as this server can on
its own, and return it with the question the caller must answer — or with
nothing, if the run is finished.

"As far as it can on its own" is exactly the elicitation ladder: a question
addressed to a person, in a session whose client renders dialogs, is put to the
person here and now, and the caller is never troubled with it. Everything else,
and every person's question the dialog did not answer, comes back for the
caller to relay. The chain is bounded by `Settings.maxElicitChain`, which is
what makes this structural. -/
def surface (io : Io) (set : Settings) (client : Option Client) :
    Nat → Run → IO (Run × Option (Dlg.Ask Unit))
  | 0, r => return (r, r.dlg.pending?)
  | n + 1, r =>
    match r.dlg.pending? with
    | none => return (r, none)
    | some a =>
      if !(set.useElicitation && isPerson a.q.addressee
            && (client.map (·.elicitation)).getD false) then
        return (r, some a)
      else do
        match ← elicit io set a.c a.q with
        | none => return (r, some a)
        | some text =>
          match Decode a.c text with
          | none => do
            set.log "the elicited answer could not be read; relaying the question instead"
            return (r, some a)
          | some x => surface io set client n (deliver r a x .elicitation)

/-- The payload of a tool result that describes where a run now stands: the
question it waits on, or the report it finished with. -/
def runStateJson (r : Run) (pending : Option (Dlg.Ask Unit)) : Json :=
  let fields :=
    [ ("ok", Json.bool true)
    , ("runId", Json.str r.id)
    , ("status", Json.str r.status)
    , ("question", match pending with
        | some a => questionJson r.asked a.c a.q
        | none => Json.null)
    , ("report", match pending with
        | some _ => Json.null
        | none => if r.failed.isSome then Json.null else reportJson r)
    , ("error", match r.failed with
        | some why => errObj "run-failed" why
        | none => Json.null) ]
  let render := match pending with
    | some a =>
      [ s!"run {r.id}: question {r.asked} for {Exec.Addressee.render a.q.addressee} \
           ({Exec.Code.name a.c})"
      , Exec.renderQ a.c a.q {} ]
        ++ (if isPerson a.q.addressee then ["", "RELAY: " ++ relayInstruction] else [])
    | none => match r.failed with
      | some why => [s!"run {r.id} failed: {why}"]
      | none => renderOf (reportJson r)
  withRender fields render

/-! ## The four tools, as functions of the state -/

/-- `workflow_start`. -/
def runStart (io : Io) (set : Settings) (st : State) (source : String) : IO (State × Json) := do
  match h : Dsl.parseAndCheckE source with
  | .error e =>
    return (st, toolResult
      (withRender [("ok", Json.bool false), ("runId", Json.null), ("error", checkErrorJson e)]
        [s!"workflow_start: {toString e}"]) true)
  | .ok p =>
    let hlv := Dsl.parseAndCheck_level_le source p ((Dsl.parseAndCheck_ok_iff source p).mpr h)
    let (summary, _) := checkSummary p hlv
    let id := s!"r-{st.nextRun + 1}"
    let r : Run :=
      { id := id, source := source, level := level p, cost := summary
      , report := reporterOf p
      , dlg := Dlg.resume Table.nil (denote p Env.nil)
      , table := Table.nil, heard := [], asked := 0, attempts := 0, failed := none }
    let (r, pending) ← surface io set st.client set.maxElicitChain r
    let st := { st.put r with nextRun := st.nextRun + 1 }
    return (st, toolResult (runStateJson r pending))

/-- `workflow_answer`: the loop.

The order of the three tests is the semantics. A run that is finished or failed
takes no answer; a reply the trusted base cannot read is an error that records
nothing; and only a reply it *can* read reaches `deliver`. -/
def runAnswer (io : Io) (set : Settings) (st : State) (runId answer : String) :
    IO (State × Json) := do
  match st.find? runId with
  | none =>
    return (st, toolResult
      (withRender
        [ ("ok", Json.bool false), ("runId", Json.str runId)
        , ("error", errObj "no-such-run" s!"there is no run '{runId}'") ]
        [s!"no such run: {runId}"]) true)
  | some r =>
    match r.failed with
    | some why =>
      return (st, toolResult
        (withRender
          [ ("ok", Json.bool false), ("runId", Json.str runId)
          , ("status", Json.str "failed"), ("error", errObj "run-failed" why) ]
          [s!"run {runId} has failed: {why}"]) true)
    | none =>
      match r.dlg.pending? with
      | none =>
        return (st, toolResult
          (withRender
            [ ("ok", Json.bool false), ("runId", Json.str runId)
            , ("status", Json.str "done")
            , ("error", errObj "run-finished" "this run has no pending question")
            , ("report", reportJson r) ]
            [s!"run {runId} is finished"]) true)
      | some a =>
        match Decode a.c answer with
        | some x => do
          let (r, pending) ← surface io set st.client set.maxElicitChain (deliver r a x .toolCall)
          return (st.put r, toolResult (runStateJson r pending))
        | none =>
          -- `Decode_eq_none` proves this branch is reachable only at `.flag`.
          let left := set.retries - r.attempts
          if left = 0 then
            let why := s!"the answer to question {r.asked} could not be read after \
                          {set.retries + 1} attempts"
            let r := { r with failed := some why }
            return (st.put r, toolResult
              (withRender
                [ ("ok", Json.bool false), ("runId", Json.str runId)
                , ("status", Json.str "failed"), ("error", errObj "run-failed" why) ]
                [s!"run {runId} failed: {why}"]) true)
          else
            let r := { r with attempts := r.attempts + 1 }
            let msg := Exec.nudge a.c answer
            return (st.put r, toolResult
              (withRender
                [ ("ok", Json.bool false), ("runId", Json.str runId)
                , ("status", Json.str "asking")
                , ("error", errObj "undecodable-answer" msg
                    [("retriesLeft", jnat (left - 1))])
                , ("retriesLeft", jnat (left - 1))
                , ("question", questionJson r.asked a.c a.q)
                , ("report", Json.null) ]
                [s!"the answer was not recorded.{msg}"]) true)

/-- `workflow_transcript`. -/
def runTranscript (st : State) (runId : String) : Json :=
  match st.find? runId with
  | none =>
    toolResult
      (withRender
        [ ("ok", Json.bool false), ("runId", Json.str runId)
        , ("error", errObj "no-such-run" s!"there is no run '{runId}'") ]
        [s!"no such run: {runId}"]) true
  | some r =>
    let pending := r.dlg.pending?
    let render :=
      [s!"run {r.id}: {r.status}"]
        ++ Trace.render r.trace
        ++ [s!"heard so far: {billNat r.trace} consultations \
              ({memoNat r.trace} distinct questions)"]
        ++ (match pending with
            | some a => [s!"waiting on question {r.asked} for \
                            {Exec.Addressee.render a.q.addressee}"]
            | none => [])
    toolResult
      (withRender
        [ ("ok", Json.bool true)
        , ("runId", Json.str r.id)
        , ("status", Json.str r.status)
        , ("source", Json.str r.source)
        , ("cost", r.cost)
        , ("transcript", jarr (r.heard.map heardJson))
        , ("bill", partialBillJson r)
        , ("question", match pending with
            | some a => questionJson r.asked a.c a.q
            | none => Json.null)
        , ("report", if pending.isNone && r.failed.isNone then reportJson r else Json.null)
        , ("error", match r.failed with
            | some why => errObj "run-failed" why
            | none => Json.null) ]
        render)

/-- Dispatch one `tools/call`. `Except` on the left is a **protocol** error —
an unknown tool, or arguments of the wrong shape — and on the right is a result,
which may itself carry `isError`. The split is the specification's and it is not
cosmetic: the left is a client bug, the right is work for the model. -/
def callTool (io : Io) (set : Settings) (st : State) (name : String) (args : Json) :
    IO (State × Except (Int × String) Json) := do
  match name with
  | "workflow_check" =>
    match strArg args "source" with
    | .error e => return (st, .error (Rpc.invalidParams, e))
    | .ok source => return (st, .ok (runCheck source))
  | "workflow_start" =>
    match strArg args "source" with
    | .error e => return (st, .error (Rpc.invalidParams, e))
    | .ok source => do
      let (st, res) ← runStart io set st source
      return (st, .ok res)
  | "workflow_answer" =>
    match strArg args "runId", strArg args "answer" with
    | .error e, _ => return (st, .error (Rpc.invalidParams, e))
    | _, .error e => return (st, .error (Rpc.invalidParams, e))
    | .ok runId, .ok answer => do
      let (st, res) ← runAnswer io set st runId answer
      return (st, .ok res)
  | "workflow_transcript" =>
    match strArg args "runId" with
    | .error e => return (st, .error (Rpc.invalidParams, e))
    | .ok runId => return (st, .ok (runTranscript st runId))
  | _ => return (st, .error (Rpc.methodNotFound, s!"no such tool: '{name}'"))

/-! ## The protocol -/

/-- What this server advertises: tools, and nothing else. No resources, no
prompts, no completions, no logging — a capability not implemented is a
capability not announced. -/
def serverCapabilities : Json :=
  Json.mkObj [("tools", Json.mkObj [("listChanged", Json.bool false)])]

/-- The prose a client shows the model about this server as a whole. -/
def instructions : String :=
  "Four tools over workflows written in a small DSL for closed plans — braced \
   blocks, `let x = ask … for …` bindings, `panel`, `act`, `if`/`else`, `case` \
   and `revising … up to n revisions`; workflow_check's description carries the \
   whole of it. Check a program with workflow_check; run one by calling workflow_start and then \
   workflow_answer once per question until the report comes back; recover with \
   workflow_transcript. Answers are read by the interpreter's own trusted base, \
   so reply in the words each question's answerSpec asks for. A question marked \
   relay: true is addressed to a person: put it to the human in the session and \
   return their answer verbatim — never your own."

/-- The `initialize` result. The revision answered with is this server's own:
one revision is implemented and announcing another would be a claim about
frames this server cannot write. -/
def initializeResult : Json :=
  Json.mkObj
    [ ("protocolVersion", Json.str protocolVersion)
    , ("capabilities", serverCapabilities)
    , ("serverInfo", Json.mkObj
        [ ("name", Json.str serverName)
        , ("title", Json.str "agent-cat workflows")
        , ("version", Json.str serverVersion) ])
    , ("instructions", Json.str instructions) ]

/-- What `initialize` said about the client, insofar as this server acts on it.
A bare `"elicitation": {}` counts as form mode, per the specification's
backwards-compatibility rule. -/
def clientOf (params : Json) : Client :=
  let info := params.getObjValD "clientInfo"
  { name := (info.getObjVal? "name" >>= Json.getStr?).toOption.getD "?"
  , version := (info.getObjVal? "version" >>= Json.getStr?).toOption.getD "?"
  , protocolVersion :=
      (params.getObjVal? "protocolVersion" >>= Json.getStr?).toOption.getD "?"
  , elicitation :=
      ((params.getObjValD "capabilities").getObjVal? "elicitation").toOption.isSome }

/-- `tools/list`. No cursor: four tools fit in one page, and a `nextCursor` that
is never read is a field that lies. -/
def toolsListResult : Json :=
  Json.mkObj [("tools", jarr (tools.map fun (t, ro) => t.json ro))]

/-- Answer one request. Every branch writes exactly one frame, carrying the
request's own id — except `tools/call`, which may write an
`elicitation/create` and read its answer first. -/
def handleRequest (io : Io) (set : Settings) (st : State) (id : Json) (method : String)
    (params : Json) : IO State := do
  match method with
  | "initialize" =>
    let c := clientOf params
    set.log s!"initialize from {c.name} {c.version} (revision {c.protocolVersion}, \
               elicitation {c.elicitation})"
    io.send (Rpc.result id initializeResult)
    return { st with client := some c }
  | "ping" => do io.send (Rpc.result id (Json.mkObj [])); return st
  | _ =>
    if st.client.isNone then do
      io.send (Rpc.errorFrame id Rpc.invalidRequest
        s!"'{method}' arrived before 'initialize'")
      return st
    else match method with
    | "tools/list" => do io.send (Rpc.result id toolsListResult); return st
    | "tools/call" => do
      -- `_meta` (the client sends `progressToken` and its own tool-use id) is
      -- deliberately ignored: this server reports no progress and invents no
      -- correlation the caller did not ask for.
      let name := (params.getObjVal? "name" >>= Json.getStr?).toOption.getD ""
      let args := params.getObjValD "arguments"
      let (st, res) ← callTool io set st name args
      match res with
      | .ok payload => do io.send (Rpc.result id payload); return st
      | .error (code, msg) => do io.send (Rpc.errorFrame id code msg); return st
    | _ => do
      io.send (Rpc.errorFrame id Rpc.methodNotFound
        s!"'{method}': this server advertised only tools")
      return st

/-- Handle one notification: `notifications/initialized` is the handshake's last
word, and everything else is ignored on purpose — a cancelled `tools/call` still
completes here, because a run is addressed by its identifier and abandoning one
mid-answer would leave a log nobody could read back. -/
def handleNotification (set : Settings) (st : State) (method : String) : IO State := do
  match method with
  | "notifications/initialized" => return { st with ready := true }
  | m => do set.log s!"ignoring notification '{m}'"; return st

/-- Handle one line of input. A line that is not JSON gets a `-32700` with a
null id, which is the only frame the specification allows when the id is
unknown. -/
def handleLine (io : Io) (set : Settings) (st : State) (line : String) : IO State := do
  match Rpc.Msg.ofLine line with
  | .error e => do
    io.send (Rpc.errorFrame Json.null Rpc.parseError s!"could not parse a line: {e}")
    return st
  | .ok (.request id method params) => handleRequest io set st id method params
  | .ok (.notification method _) => handleNotification set st method
  | .ok (.response _ _) => do
    set.log "a response arrived that answers no outstanding request; ignored"
    return st

/-- The server: read a line, answer it, repeat, until the client closes the
stream.

**Shutdown is the stream closing**, which is what MCP over stdio prescribes:
there is no `shutdown` method, the client closes stdin, `readLine` sees the end,
and this returns the final state so a caller can inspect it. The fuel is what
makes the loop structural — this file has no `partial` — and exhausting it is
reported rather than silently treated as an end of stream. -/
def serve (io : Io) (set : Settings) : Nat → State → IO State
  | 0, st => do
    set.log "message budget exhausted; no longer listening"
    return st
  | n + 1, st => do
    match ← io.readLine with
    | none => return st
    | some line =>
      if line.all Char.isWhitespace then serve io set n st
      else do
        let st ← handleLine io set st line
        serve io set n st

/-- Run the server on this process's stdio until the client closes it. -/
def main (set : Settings := {}) : IO Unit := do
  let io ← Io.stdio
  let _ ← serve io set set.maxMessages {}
  pure ()

end Mcp
end Agentic.Core
