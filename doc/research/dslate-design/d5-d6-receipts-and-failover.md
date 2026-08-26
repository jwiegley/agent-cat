# D5 and D6-failover: the world authors the receipt, and the pin has a spare

> **Superseded refinement (2026-08-26).** This implementation record predates
> typed execution intent. Value `toolExec` is annotated `observe`; `act` is
> `effect`; permission follows annotation rather than `.ack`. Failover preserves
> the authored request and records a separate dispatched target. Bare-Q meaning
> remains unchanged. Historical design below is unaltered.

Implementation design for wave 3. Owner-ruled decisions D5 (`doc/research/isaac-workflows.md`
§6) and the deferred half of D6 (fail-over), designed against G4 and G5's evidence and against
the mechanism Isaac actually built.

Two sentences of orientation, because the two halves are more alike than they look:

* **D5** adds an addressee whose answer the *runner* obtains by running a program-authored
  command, so a check can be an exit code rather than a model's claim about one.
* **D6-failover** adds, to a `served by` pin, the models that may answer in its place, and the
  Exec-layer walk that reaches them — with the trace recording *who actually answered*.

Both are Exec policy. Neither changes what a plan *means*: no new plan node, no new price, no
change to `costSummary`, `level`, `size`, `askNodes`, `blockAsks` or `fnAsks`.

---

## Part 0 — the two things we are deliberately not inheriting

### 0.1 `Agent.Grant`, characterized precisely

`~/src/agent-functor/src/Agent/Grant.hs` is a 139-line **deny-by-default capability lattice**:
a `Grant` is four axes (`gRead`, `gWrite` as `Set PathGlob`, `gExec` as `Set CommandGlob`,
`gNetwork` as `Bool`); `mempty` grants nothing; `(<>)` is a genuine lattice join (set union,
disjunctive network), so it is idempotent and commutative and "composing grants can only widen
access". Querying is `permitRead`/`permitWrite`/`permitExec`; `matchGlob` is a linear
two-pointer glob matcher, deliberately linear because it "matches untrusted input";
`canonicalizePath` collapses `.` and `..` before matching, which is the fix for
`/repo/src/../../etc/passwd` slipping past `/repo/src/*`.

Three things about it matter to us:

1. **`permitExec` matches the whole command line.** `execGrant ["git*","cabal*","gh*"]` allows
   any git/cabal/gh invocation; `execGrant ["git commit *"]` denies `git push`. It exists
   because `Agent.Op.Exec` leaves carry commands the *agent* chooses at run time.
2. **Enforcement is not here.** The module header says enforcement "happens at the ACP boundary
   (the `fs/*`, `terminal/*` and permission handlers, M8) — this module is just the lattice."
   The lattice is the easy half; the boundary is where it can be got wrong.
3. **The admitted residual, in his own words:** "__This is lexical only — it does not resolve
   symlinks.__ A symlink inside the worktree pointing outside it can still escape the grant
   lexically. Closing that is a residual IO-side obligation: the ACP fs handler must `realpath`
   the target (or refuse symlinked paths) before this check."

Grant is well-built and honest about its hole. We do not need it, and §1.6 says exactly why:
**our argv cannot come from an answer.** A lattice over agent-chosen strings is the answer to a
question we decline to ask.

### 0.2 The fail-over mechanism he built, characterized precisely

`Agent.Run.overChain` (`Run.hs:2596`–`:2657`) is the whole of it, and its docstring is the best
specification either repository contains. The five properties, kept verbatim as the criteria
this design is measured against:

* **Only `ModelExhausted` moves on.** Not `ErrorCall`, not `SomeException`. "failing over on a
  generic failure would re-run broken work on a second, pricier model and bill twice for hiding
  the defect."
* **The whole action is retried, not just the turn.** "a rate-limited turn produced nothing at
  all — no tool call, no edit — so there is no partial work to reconcile."
* **The action is re-run under the *next* connection's own recorder.** "the cache salt, the
  reported backend label and the model name all follow the model that actually ran. Recording a
  fallback's answer under the primary's key would make a later replay serve one model's work as
  another's."
* **`ModelExhausted` never escapes.** When the last connection is spent, it rethrows as the
  `ErrorCall` there would have been with no chain at all, "so every layer above … sees precisely
  what it saw before fallbacks existed, and needed no change."
* **A failed turn is asked about, not acted on.** `TurnUnresolved` arrives with its re-asks
  already spent, and `overChain` "is the only layer that can answer it: it knows whether the
  chain has somewhere else to go". `RetryHere` re-runs, `FailOver` moves on, `Abandon` raises.

Supporting facts, all load-bearing below:

* `TurnGap` (`Run.hs:4693`) is three constructors: `TurnFailed` (the backend reported a
  failure), `TurnEmpty` (the turn ended cleanly producing nothing), `TurnExhausted` (this model
  has nothing left to spend — "the one gap where the same question put to a *different* model is
  expected to succeed").
* Budgets (`nextAsk`, `Run.hs:4869`, with `turnRetryBudget = 2` at `:4841`): `TurnFailed` 2,
  `TurnEmpty` 1, `TurnExhausted` 0.
* `unattendedRecovery` (`Run.hs:2674`) is one line: `pure (maybe Abandon (const FailOver)
  (raNext ask))` — fail over if the flow declared somewhere to fail over to, else halt.
  "Retrying is deliberately not on this path… spending more on an unattended run is spending
  money on a guess with nobody watching."
* **`AgentChain` is a property of the scope, not of the agent's identity** (`Agent/Op.hs:196`):
  "An `AgentSpec` is an *identity*… A fallback is not part of that identity — `claude-agent/fable`
  is the same connection whether or not the flow author wrote a spare beside it — so folding the
  chain into the spec would key two identical subprocesses off two specs that differ only in a
  field neither process knows about."

  That last one is the single most useful sentence for us. Read at our types it says: **the
  alternates must not be part of the question's identity**, because `EventKey` *is* our identity
  and our memo table *is* his connection map. §2.2 and §2.5 are that sentence, applied.

---

## Part 1 — D5: a tool party with an argv, whose receipt the World writes

### 1.1 Where the argv goes, and why not the two obvious places

The brief asks the question three ways; the answer is decided by one fact, not by taste.

**Rejected — a field on `RawAsk` beside `model`.** Two reasons, one fatal.

* *Fatal:* an argv on `RawAsk` never reaches `Q`. `Check.askShape` builds a `Q.Shape` out of
  `addressee`, `scope` and `draw` and nothing else, so the argv would be invisible to
  `EventKey` (`World.hs:392`: code, addressee, scope, prompt, draw — "the answer is not part of
  the key… two syntactically distinct asks that say the same words, to the same addressee, in
  the same scope, at the same draw, are **one question**"). Two acts saying the same words to
  the same tool id with *different commands* would then be one question, and the second would be
  answered from the memo table without running. That is not a corner case; it is the ordinary
  case of a gate run twice in one program, and the failure mode is a command that silently does
  not run while the table reports it did. Everything in this package's memo argument
  (`Exec.hs:230`–`:240`) is built on "equal questions have equal answers"; an argv outside the
  key breaks that hypothesis at the runner.
* *Expensive:* the codec is strict on output — "Encoding is strict: the explicit `null` is
  always emitted" (`Raw.hs:36`) — and mirrors Lean's derived `ToJson`, which writes every field
  of a structure. A new `RawAsk` field therefore adds a key to **every ask node of every corpus
  entry**, refreezing all 106 programs. G4's honest cost ("touches the corpus for any entry that
  uses it (none today — new fixtures only)") is only *true* under the design below.

**Rejected — a field on `RawTarget`.** `RawTarget` is documented in `Syntax.lean:183` as "the
part of `Q.Shape` an author writes"; its two fields are exactly the two shape fields the syntax
can spell. A third field that does not reach the shape makes that sentence false, and it inherits
the same refreeze.

**Decided — a fourth `Addressee` flavour.**

```lean
inductive Addressee where
  | model  (id : String)
  | tool   (id : String)
  | person (id : String)
  | toolExec (id : String) (cmd : String) (args : List String)   -- new
```

This is the design that makes all three properties come out right at once:

* The argv rides in the addressee, so it is **in `Q`, in `EventKey`, and in the trace event**
  for free, and two commands are two questions by construction.
* A sum constructor is written only where it is used, so **no existing corpus entry's printed
  program changes by one byte**. G4's cost estimate becomes accurate.
* `cmd` is separate from `args`, so **"an argv naming no command" is unrepresentable** and no
  new term-level guard is needed. (A `List String` argv would have needed one, and a new guard
  is a change to the vocabulary the oracle shares with `Agentic.Guards` — see P3 refusal parity
  in `bisim/Main.hs` — which is exactly the kind of cost worth designing away.)

Printed shape (JSON, the corpus's arbiter):

```json
{"toolExec": {"id": "green", "cmd": "nix", "args": ["flake", "check"]}}
```

beside the unchanged `{"tool": {"id": "apply"}}`.

### 1.2 The surface spellings

`Agentic.Workflow` (normative for authors): a modifier on a tool party, in the idiom
`servedBy` already sets.

```haskell
-- | @tool "green" `running` ("nix", ["flake","check"])@ — the command the runner
-- puts in place of asking. A model or a person is not run, and here that is a
-- kind error rather than a refusal, exactly as `servedBy` on a tool is.
running :: Party 'IsTool -> (Text, [Text]) -> Party 'IsTool
running p (cmd, args) = p {partyAddr = AddrToolExec (idOf (partyAddr p)) cmd args}
```

`Agentic.Builder` (explicit surface, used by `tier1/Cases.hs`): add
`askToolRunning :: Text -> Text -> [Text] -> Words s -> Ask s` beside `askTool`. Do **not**
change `askTool`'s type — the nineteen rebuilt cases must keep compiling untouched.

DSL text spelling, advisory for whichever authoring surface parses it:
`ask tool "green" running "nix" "flake" "check"`.

The gain, concretely: `Example.Isaac.greenGateBrief` (`example/Example/Isaac.hs:592`) is six
lines of prose begging a model to run `nix flake check` and report the exit code it *actually*
saw, under a haddock that says "**This is `agentVerify` and not `verify`.**… Nothing in this
language can spell the first". After D5 it is a `verdict` binding on
``tool "green" `running` ("nix",["flake","check"])`` with a one-line prompt, and the apology in
`greenGateBrief`'s haddock is deleted rather than reworded.

### 1.3 The World that executes

**It is a layer, not a world.** A new module `Agentic.Shell` (Exec-only; no kernel, no Raw),
sitting beside `Agentic.AgentDeck` and `Agentic.Acp` as a third thing that obtains answers:

```haskell
executingWorld :: ShellConfig -> WorldIO -> WorldIO
executingWorld cfg inner = WorldIO $ \c q -> case qAddressee q of
  AddrToolExec _ cmd args -> answerByRunning cfg c q cmd args
  _                       -> worldAskIO inner c q
```

exactly the shape `announcingWorld` (`Exec.hs:194`) already has. Three consequences fall out of
the shape alone and are the reason for it: it composes with *every* world (scripted, deck, acp)
identically; it is trivially removable; and `Agentic.Exec` keeps its stated property that "no
other declaration in this module is effectful except `runPlanIO`" (`Exec.hs:162`) — the process
spawn is not in Exec.

**The answer, per code.** The code is imposed by position or binder, as always; the executing
world answers at whatever code arrives. The rule in one sentence: *the exit status is the answer
wherever the answer type can express failure, and the run is abandoned where it cannot.*

| code | exit 0 | exit *n* ≠ 0 |
| --- | --- | --- |
| `receipt` (ack) | `()` | **abandon the run** |
| `flag` | `True` | `False` |
| `verdict` | `Approve` | `Object [first nonblank line of stderr, else of stdout, else "exited n"]` |
| `text` | stdout, verbatim | **abandon the run** |

Justification, and it is this package's own argument twice over. `El ack` has one inhabitant and
`El text` has no distinguished failure value, so any answer manufactured for a nonzero exit is
*definitionally identical in the table* to one a successful command gave — which is precisely
`askDecoding`'s reason for abandoning rather than defaulting ("A memo entry carries a code, a
question and an answer and *nothing else*, so a defaulted cell is definitionally identical to one
an addressee gave", `Exec.hs:529`) and `requiresCompletedTurn`'s reason for refusing an ack from
an interrupted turn ("Recording it would be recording an act nobody performed", `Exec.hs:446`).
`flag` and `verdict` have exactly the room a failure needs: two values, and objection lines. So
`greenGate` at `verdict` never abandons and takes the objected arm with the *command's own first
failing line* as the objection — which is what `greenGateBrief` was asking the model to produce
faithfully, and the thing the 2026-08-12 retrospective found it had not.

**Known cost, recorded.** `grep` exits 1 for "no match", which is an answer and not a failure;
under this table a `text` ask on `grep` abandons the run. The author's escape is to ask it as a
`flag`, or to name a command whose nonzero exit really is a failure. We take the conservative
side because the opposite mistake is the one with evidence behind it: `Agent.Run`'s `TurnEmpty`
exists because coercing a failed turn to `""` let a `review-lite` run "report `done` while three
of its five reviewers had produced nothing" (`Run.hs:4670`).

**The words are not decoration: they go to the child's standard input.** argv is
program-authored and interpolation-free (§1.6); the prompt is interpolated and is *data*. Writing
it to stdin gives the words a meaning at this addressee, keeps splices on the data channel where
they are harmless, and lets a check script read what it is checking. Write it from a forked
thread and close, under the whole-command timeout, the way `AgentDeck` already drains a child's
handles — a command that never reads stdin must not wedge the run.

**No shell.** `proc cmd args`, never `system` or `sh -c`. `cmd` resolves on `PATH` when it has no
directory part, the same rule `deckBinary` documents.

**Failure of the mechanism, as opposed to failure of the command,** is a named error type
(`ShellMissing`, `ShellTimedOut`, `ShellNotExecutable`) in the shape of `DeckError`, so an
operator can tell "the gate said no" from "the gate could not be run". Under D6 these classify as
gaps (§2.3); a command that ran and exited nonzero is *not* a gap — it is an answer.

`requiresCompletedTurn` needs no clause: it wildcards the addressee, so a `toolExec` ask that
somehow reaches a live agent (a caller that composed worlds by hand and omitted the layer) still
requires a completed turn at `ack`. Safe default, no change.

### 1.4 The factorization theorem, quoted, and why it survives

From `Exec.hs:58`, the equation the whole `IO` layer is held to (`@Exec.lean:647@`, with
`Plan.execPure_fst` `@:748@` and `execM_pure`'s third conclusion `@:654@`):

```
runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
```

D5 does not touch it, and the reason is structural rather than argued: `executingWorld` is a
`WorldIO -> WorldIO`, and `pureWorldIO w` is not it. Nothing in `runPlanIO`, `execIn`,
`askOrMemo`, `questionKey` or `memoLookup` changes for D5. A pure `World` answers a `toolExec`
question from its `WorldSpec` like any other question — `toWorld` dispatches on the *code*, never
on the addressee (`World.hs:286`–`:303`) — so the kernel executes nothing, ever, and the oracle's
`worldObservation` for a program full of `toolExec` asks is computed exactly as today.

(D6 *does* touch `askOrMemo`; §2.7 discharges the same obligation there.)

### 1.5 `--scripted`

**The executing layer is not installed under `--scripted`.** The table answers a `toolExec`
question like any other: `scriptedReply` keys on the prompt by prefix and never looks at the
addressee (`Exec.hs:605`). So `--scripted` keeps its defining property — it reaches nothing and
runs nothing — and G4's "`--scripted` keeps answering it from the table" is literally true.

One line is owed to the operator, in `runCmd`'s `Scripted` arm beside the existing "N canned
replies" announcement: *no command was run; every gate in this program was answered from the
table.* Without it a green `--scripted` run reads as evidence that the gate passed, which is the
same class of mistake D5 exists to fix.

### 1.6 Both engines, where the argv runs, and the security posture

**The argv runs locally, in the runner's own process, under both engines, and never reaches the
agent.** This is not a policy the two adapters implement twice; it is a consequence of the layer
sitting *above* the engine: `announcingWorld out (executingWorld cfg (worldOfAcp cfg acp))` and
`announcingWorld out (executingWorld cfg (worldOfDeck cfg))`. A `toolExec` question is answered
before either adapter is consulted, so neither `sayAcp` nor `sayDeck` ever sees one, no
`session/prompt` carries it, and ACP's `permissionByCode` — which grants tool calls at `ack`
(`Acp.hs:650`) — is not the path by which anything runs.

Composition order matters and should be fixed in `run/Main.hs`: **announcing outermost**, so the
command's ask and its answer are narrated like every other consultation; **executing next**, so
the layer is between the narration and the engine. The runner is already the only place that
composes worlds; keep it that way.

Working directory: `ShellConfig` takes one explicitly, and the runner sets it to the directory
the engine works in — `acpCwd` (the per-run scratch from `freshScratch`) under `--engine acp`,
the process cwd under `--engine deck`, with the deck case announced because the deck engine sends
into a session somebody else started and the two need not agree. A per-command timeout bounds the
child, so a hung command produces a named error rather than a hang, on the same principle
`deckTimeoutMs` already applies to a turn.

**Why this needs no Grant lattice.** Three facts, in decreasing order of importance:

1. **`cmd` and `args` are `String`, not `Prompt`.** There is no interpolation syntax at an argv,
   so there is no path from any answer to any command line. G4's note in agent-cat's favour is
   exactly this and it is worth stating as a type-level fact rather than a convention: an
   authoring surface that offered `{name}` inside an argv would reintroduce every problem `Grant`
   exists to bound, and must not be written.
2. **The argv is in the value tier1 pins.** `tier1/Main.hs` compares `toJSON` of the builder's
   `RawProgram` against the frozen `request.program` "as a whole `Value`… no field is skipped, and
   a missing or extra key is a failure". A command that changed would fail the freeze.
3. **The runner already spawns processes to answer questions.** `worldOfDeck` runs three
   `agent-deck` subprocesses per question today. D5 changes *which* process the runner spawns,
   not *whether* it spawns one. That is the honest answer to the G4 dissent that adopting this
   "puts a process spawn inside the semantics' runner": the spawn is in a transport module beside
   the two that already exist, and not in `Agentic.Exec`.

agent-functor needs `Grant` because `permitExec` matches "untrusted input" — argv the agent chose
mid-turn. We are not declining a safety mechanism; we are declining a *problem*. What we inherit
instead is the discipline of saying so in one place, which is this section.

### 1.7 Guards, plan, cost, corpus

**Guards.** `askGuard` (`Guards.hs:177`, `Check.lean:320`) needs one clause and it is the
existing one generalized: `served by` names the model that serves a **model** addressee, so a
`served by` on a `toolExec` refuses `ServedBy` exactly as on a `tool`. In Lean the wildcard
`| some _, _ =>` already covers it; in Haskell the `case adr of AddrModel _ -> Nothing; _ ->
Just (ServedBy, Nothing)` already covers it. **Zero code change, one new fixture** to pin that it
does. No other guard fires, no new guard is added, and the refusal vocabulary the oracle shares
is untouched.

**Plan and cost: nothing.** A receipt is a receipt. `level`, `size`, `askNodes`, `codes`,
`costSummary`, `blockAsks` and `fnAsks` count nodes, codes and paths; the addressee is priced
nowhere. `El`, `decodeEl`, `sayEl` and `answerSpec` are unchanged.

**Corpus: no existing entry changes.** New fixtures, all of them cheap:

| fixture | what it pins |
| --- | --- |
| a `toolExec` act at `receipt`, pure world | the addressee's JSON, and that the kernel answers it from the spec |
| the same at `flag`, `verdict`, `text` | that all four codes are reachable and priced as usual |
| `served by` on a `toolExec` | `askGuard` refuses `ServedBy` |
| **two `toolExec` asks, same id, same words, different `args`** | `billMemo == 2` — the memo-conflation test, and the reason the argv is in the addressee |
| two `toolExec` asks, same everything | `billMemo == 1` — the other side of it |

The fourth is the most important fixture in this document.

---

## Part 2 — D6: fail-over

### 2.1 The Raw delta: keep the primary spelling, grow the payload

Today `RawAsk.model : Option String` (`Syntax.lean:198`, `Raw.hs:317`). Three candidates:

* **`model : List String`** — nonempty means pinned. Rejected: destroys the none/some reading,
  makes "pinned but empty" representable, and rewrites `"model": null` in every ask of every
  entry.
* **a second field `alternates : List String` beside `model`** — rejected for the same refreeze
  reason as §1.1: Lean's derived `ToJson` writes every field, so every ask node in all 106
  programs gains `"alternates": []`.
* **Decided — `model : Option Served`**, where `Served` is a structure:

```lean
structure Served where
  /-- The model that serves this question. -/
  primary : String
  /-- The models that may answer in its place, in the order they are tried. -/
  alternates : List String
```

A structure encodes as a bare object of its fields with no tag (`Raw.hs:29`), so:

```json
"model": null                                        -- unpinned, unchanged
"model": {"primary": "deep", "alternates": []}       -- served by "deep"
"model": {"primary": "deep", "alternates": ["broad"]}-- served by "deep" or "broad"
```

Nonemptiness of the chain is structural, so again **no new guard**. And the blast radius is the
smallest available: **exactly five corpus entries carry a `served by` today** —
`battery-119-served-by-and-independent-draw-together-in-every-ask-position`,
`example-000-the-flagship-single-file`, `example-002-the-flagship-written-against-a-library`,
`example-003-a-library-runs-alone-its-priming-then-nothing`,
`vector-005-served-by-on-a-tool-hand-built` — so five `request.program` fragments change and
**no reply changes at all** (§2.6). That is not "none existing", and the design should not
pretend otherwise; it is five mechanical edits inside a wave that is regenerating anyway.

Surface, in `Agentic.Workflow`, borrowing agent-functor's own name:

```haskell
servedBy      :: Party 'IsModel -> Text -> Party 'IsModel   -- unchanged spelling; sets the chain
fallingBackTo :: Party 'IsModel -> Text -> Party 'IsModel   -- appends an alternate
```

with `fallingBackTo` on a party that has no primary *making* that name the primary — so
``model "r" `fallingBackTo` "deep"`` and ``model "r" `servedBy` "deep"`` agree, and no illegal
state is reachable without a second kind index. `Agentic.Builder` gains
`askModelFallingBack :: Text -> Text -> [Text] -> Words s -> Ask s` beside the unchanged
`askModelServed`. DSL text: `served by "deep" or "broad"` — `or` rather than agent-functor's `|`,
because this surface spells its operators in words.

### 2.2 Where the alternates live at run time — and where they deliberately do not

They do **not** go into `Q`, `Q.Shape` or `QScope`. Isaac's own sentence is the argument
(`Op.hs:196`): a fallback "is not part of that identity", and folding it into the identity would
key two things off a field neither of them knows about. At our types: `EventKey` includes
`ekScope`, so a chain in the scope would make `served by "deep"` and `served by "deep" or "broad"`
— same words, same addressee, same draw — **two questions**, splitting the memo table and the
bills on a field that says nothing about what is being asked. And a chain-valued scope axis would
change `scopeJson`'s `"model"` in every trace event that has one.

Instead: **the alternates are Raw-level program text, and the runner collects them into a chain
table before the run.**

```haskell
-- Agentic.Chains (new, ~40 lines, Exec-only, no kernel)
servedChains :: RawProgram -> Either Text (Map Text [Text])
```

One traversal of the program — the same shape as `Guards.askCounts`, descending into function
bodies, panel members, `review`/`amend` and every block arm — collecting `primary -> alternates`.
It is `Either` because two asks pinning the same primary with *different* alternates make the
table ill-defined; that is a **runner precondition, not a language refusal**. The program is
well-formed and its meaning is unchanged; what is ill-defined is the runner's chain table, and
`agentic-run` refuses to start, naming both spellings. Keeping it out of `Agentic.Guards` keeps
the guard vocabulary the oracle shares (bisim P3) untouched.

The consequence is stated plainly rather than hidden: **the chain is a property of the model, not
of the question.** A program may not say "deep or broad" here and "deep or cheap" there. That is
a restriction, it matches Isaac's reading that a chain is fleet configuration rather than
question content, and it buys us a kernel we do not touch. Recorded as reversible: if per-ask
chains are ever wanted, the field is already per-ask in the Raw, and the cost of the change is
adding it to `Q.Shape` and teaching `EventKey`, `eventJson` and `toWorld` to ignore it — three
deliberate blind spots in the kernel, which is what we are declining to pay for now.

### 2.3 When Exec fails over, and when it retries here

Wave 1 supplies the taxonomy (`TurnGap`'s three constructors), the per-gap budgets, the
`RetryHere | FailOver | Abandon` fork, and the unattended standing answer. D6 fills in `FailOver`,
which today is named and refuses because there is nowhere to go.

What D6 *requires* of wave 1's classification, and nothing more: **that the exhaustion gap be
distinguishable from the others**, because it is the only one that says something about the model
rather than about the turn.

| gap | budget (wave 1) | when spent | marks the model spent for the run? |
| --- | --- | --- | --- |
| failed (the backend reported a failure) | 2 re-asks, same addressee | fail over | no |
| empty (clean turn, nothing said) | 1 re-ask, same addressee | fail over | no |
| exhausted (this model has nothing left to spend) | 0 | fail over | **yes** |

Two additions of our own:

* **Decode exhaustion is a gap.** `askDecoding`'s `Left reply` — "no readable *flag* from *model
  r* after 2 attempts" — is exactly "this addressee produced nothing usable and asking again did
  not help", which is the failed gap after its budget. It should reach the fork rather than
  abandoning immediately. Its `ioError` text and its argument survive verbatim as the *final*
  abandonment when no candidate remains (§2.4).
* **`Agentic.Shell`'s mechanism failures are gaps** (`ShellMissing`, `ShellTimedOut`) — but a
  command that ran and exited nonzero is an *answer*, never a gap, and must never fail over. A
  red gate is not a reason to ask a different model.

`RetryHere` is in the vocabulary and unreachable from the only policy we ship, and that is
honest: agent-cat's runner is unattended by construction, the budgets already spent the retries,
and `unattendedRecovery`'s "spending more on an unattended run is spending money on a guess with
nobody watching" applies unchanged. It becomes reachable the day agent-cat grows an interactive
runner, and not before.

### 2.4 The loop, and the memo table

This is the one part of D6 that is *not* a wrapper. `WorldIO` stays exactly as it is —
`forall c. SCode c -> Q c -> IO (El c)` — because widening it to let the answerer report *which
model answered* would hand the answerer the power to forge the trace, which is strictly worse
than the forgery `Exec.hs:158` designed the type to prevent. Instead the candidate sequence is a
**pure function of the question and the chain table**, computed by Exec, so the world can only
answer or fail; it can never name who it was.

```haskell
data Chains = Chains
  { chainAlternates :: !(Map Text [Text])    -- from servedChains, fixed for the run
  , chainSpent      :: !(IORef (Set Text))   -- models that reported an exhausted allowance
  }

runPlanWith :: Chains -> WorldIO -> Plan '[] a -> IO (a, Trace)
runPlanIO = runPlanWith noChains
```

`askOrMemo` becomes, in words: *for each live candidate in order — consult the table, then the
wire.*

```haskell
askOrMemo w ch c q m = candidates ch q >>= \case
  []   -> abandonAllSpent q                    -- every model this question pins is spent
  cands -> go cands m
  where
    go (qi : rest) m' = case memoLookup c (questionKey c qi) (memoTable m') of
      Just a  -> pure (a, said (Event c qi a) m')                      -- a memo hit, at qi
      Nothing -> try qi rest m'
    try qi rest m' =
      attempt (worldAskIO w c qi) >>= \case
        Right a -> pure (a, said (Event c qi a) (insert (questionKey c qi) (Event c qi a) m'))
        Left gap -> do
          when (isExhaustion gap) (markSpent (modelOf qi))
          case (recovery gap, rest) of
            (FailOver, next) | not (null next) -> warn gap qi next >> go next m'
            _                                  -> rethrow gap        -- verbatim
```

`candidates` for a question whose scope model axis is `Just m` is `m : lookup m` minus the spent
set, deduplicated, each relabelled as `q { qScope = (qScope q) { scopeModelAxis = Just x } }` —
the mode axis untouched. For an **unpinned** question it is `[q]`, always: an unpinned question
names no model, so the runner cannot say who answered it and has nothing to fall back from.
Worth saying out loud, because it is an argument for D9: **fail-over is a service you get by
pinning.**

The four properties of `overChain`, discharged at our types:

* *Only exhaustion moves on* → generalized deliberately: every gap moves on, because ours are
  all "nothing usable came back", and none of them is a partially-completed act (an ask is one
  turn, and a gap means it produced no readable answer). A command's nonzero exit is *not* a gap,
  which is where his "don't re-run broken work on a pricier model" concern actually lands for us.
* *The whole action is retried* → trivially: the action is one question.
* *Re-run under the next connection's own recorder* → the answer is memoized under
  `questionKey c qi`, the **answerer's** key, never the primary's. Writing it under the primary's
  key would put in the table an answer attributed to a model that did not give it, and this
  package abandons runs rather than do that twice already.
* *The exhaustion never escapes* → `rethrow gap` raises exactly what the run would have raised
  with no chain declared: `askDecoding`'s `userError`, `ShellTimedOut`, `DeckNotAlive`,
  unchanged. **Acceptance criterion: with no alternates declared anywhere, every diagnostic in
  the package is byte-identical to today's.**

**The spent set is why repetition stays cheap and consistent.** Walk an ask node twice, having
lost `deep` to exhaustion on the first walk: the second walk's candidate list is `[broad]`
(`deep` is skipped without asking), the lookup at `broad`'s key **hits**, and nothing is put.
The memo invariant — "a question already answered is not put again" — survives a fail-over
intact. Without the spent set the second walk would ask `deep`, get the same exhaustion, and
only then reach `broad`'s table entry: correct but wasteful. With a *non*-exhaustion gap the
model is not marked spent, the second walk does re-ask it, and that is right — a turn that failed
once is not a model that is finished.

`abandonAllSpent` is the case where every model a question pins has already reported its
allowance spent. The run abandons *without touching the wire*, naming the models and the earlier
question at which each was lost — because asking a model known to be spent is spending a turn on
a guess, which is the one thing the unattended policy must not do.

**Bills.** `billFresh` is unchanged by construction: one event per ask node walked. `billMemo`
is unchanged in the ordinary fail-over (the dead attempts record nothing, so only the answerer's
key enters the table). It *rises* in exactly one situation — a node answered by `deep` early and
by `broad` later, after `deep` was lost to some other question — and that rise is correct: two
different models said the same words, which by `EventKey`'s own definition is two questions.

### 2.5 The trace — the hard question, answered

**The trace records the model that actually answered, and records nothing about the attempt that
failed.** Both halves are deliberate.

*Why the answerer.* The trace is the observation; `Event c q a` is a question and the answer
somebody gave to it. A fail-over means the runner put a *different question* — same words, same
addressee, same draw, **different scope** — because the pinned one could not be put. The event
whose scope says `deep` when `broad` answered is not a rounding error; it is the trace asserting
that a model produced text it never saw, and every consumer downstream (the bills, a
`--engine acp` operator reading `announcingWorld`'s lines, a future replay) would inherit that
claim. So `askOrMemo` builds `Event c qi a` from the candidate that answered, and `eventJson`
serializes its scope with no change whatsoever: `{"model": "broad", "mode": null}`.

*Why nothing about the attempt.* An `Event` carries an answer; a failed attempt has none, and
there is no `Event` we could honestly write for it. Recording one would require a fifth code or
a nullable answer, and both are worse than the alternative, which is: **the trace records the
dialogue, and `stderr` records the attempts.** The narration is loud and modelled on
agent-functor's wording —

```
agentic: deep: no readable flag after 2 attempts; falling back to broad
agentic: deep reported its allowance spent earlier in this run; not asking it again
```

— and this split is already the package's rule: `announcingWorld` prints "the sequence of
consultations the run paid for" while warnings "report what the run is *about* to do about
something it noticed" (`Exec.hs:186`, `:477`).

*What this does to the oracle, the corpus and the bisimulation — nothing.* The oracle computes
its trace from a pure `World`, and a `World` is a total function: nothing fails, so nothing ever
fails over, so the oracle always serializes the primary. `Conformance.lean`'s event
serialization, `scopeJson`, `eventJson` and the frozen replies are **untouched**. The bisim's P1
puts generated programs to the oracle and compares replies computed at pure worlds, so it never
takes this path either.

The place the two *do* differ is a live run: a program whose frozen trace says `deep` may, on a
day the allowance is spent, produce a live trace that says `broad`. That divergence is not a bug
to reconcile — **it is the observation**, and it is available to an operator precisely because we
refused to write `deep` into an event `broad` answered. Say this in `runPlanWith`'s haddock in as
many words, because a reader comparing a live transcript to a frozen one deserves to find the
explanation next to the mechanism.

### 2.6 Guards, corpus, and the Lean mirror

**`guardUnpinnedAsk` (D9, wave 1): an alternates-list counts as pinned, and needs no new
clause.** Pinned is `isJust askModel`, and that is exactly right: the chain names, exhaustively
and in the program text, every model that may answer. The guard's property — that no question
reaches whatever model the runner happens to be pointed at — is preserved by a chain, since every
alternate is itself a model name. One sentence in its haddock and one fixture (a program whose
only ask is `served by "deep" or "broad"` passes the guard); no logic changes.

**`askGuard`: no change.** It matches `a.model` as `some _ / none` against the addressee; the
payload's type is irrelevant to it. In Haskell the pattern `RawAsk (Just _) …` (`Guards.hs:178`)
already ignores the payload.

**`askShape`: keep its signature.** `Check.lean:170` takes `Option String`; pass
`a.model.map (·.primary)` at both call sites (`Check.lean:335` and `:466`). The morphism results
around it — `under_ask1`, `askShape_draw` (`Dsl.lean:762`), the `atModel` scope lemmas
(`Question.lean:426`–`:434`) — are `rfl` and stay `rfl`. **The alternates are dropped at
elaboration, and that is the formal statement that fail-over is not part of the meaning.**

**Corpus:** five `request.program` fragments rewritten mechanically (§2.1); **zero replies
change** — the scope axis still holds the primary, so every frozen trace event, every `billFresh`
and every `billMemo` comes back identical. New fixtures: an ask with a two-name chain (pins the
`Served` JSON and that the reply is identical to the same ask served by the primary alone), a
chain inside a function body, and a chain on a panel member.

**`Agentic.Gen`:** the generator's ask tally (`Gen.hs:781`: "model 6, model `served by` 2, tool 4,
person 2") gains chained asks and `toolExec` asks, or the bisim never exercises either. This is
the single easiest thing in wave 3 to forget.

### 2.7 The factorization theorem, again

D6 edits `askOrMemo`, so the obligation from §1.4 must be discharged a second time, and the
design is arranged so that it is discharged *definitionally* rather than by argument:

> With an empty chain table and an empty spent set, `candidates ch q == [q]`, the loop runs one
> iteration, the lookup and the insert are both at `questionKey c q`, and the recovery fork is
> never consulted because no gap arrives at a pure world. `runPlanWith noChains` is therefore the
> `askOrMemo` of today, clause for clause, and

```
runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
```

> holds verbatim, with `runPlanIO = runPlanWith noChains`.

Pin it: run the whole corpus through `runPlanWith noChains` at `pureWorldIO (toWorld spec)` and
require the traces to be byte-identical to `trace (toWorld spec) p`. That single test is what
keeps a future edit to the fail-over loop from quietly changing the meaning of every program.

---

## Part 3 — implementation checklist for wave 3

Marked **[LEAN]** kernel/oracle, **[RAW]** the term language and its codec on both sides,
**[EXEC]** runner-only (no kernel, no oracle, no corpus), **[SURFACE]** authoring,
**[CORPUS]** fixtures/regeneration, **[GEN]** generators and the bisimulation.

### D5

1. **[LEAN][RAW]** `Question.lean`: add `Addressee.toolExec (id) (cmd) (args : List String)`.
   Fix the resulting non-exhaustive matches — `Report.lean`, `Explain.lean`, `Exec.lean`'s
   `Addressee.render`, `Conformance.lean`'s addressee JSON is derived and needs nothing.
2. **[RAW]** `Agentic.Raw`: `AddrToolExec !Text !Text ![Text]`, plus its `ToJSON`/`FromJSON`
   clauses in the named-field object form.
3. **[EXEC]** `Agentic.Exec.addresseeWord`: one clause (`"tool " <> id <> " (" <> cmd <> ")"`).
   `requiresCompletedTurn` needs none (it wildcards).
4. **[EXEC]** `Agentic.World`: one clause in `addresseeOrd` (`World.hs:416`) — index 3, and the
   ordering key must include `cmd` and `args` so it agrees with the derived `Eq`. `eventJson`,
   `scopeJson`, `toWorld`, `billFresh`, `billMemo` are untouched.
5. **[EXEC]** New module `Agentic.Shell`: `ShellConfig`, `ShellError`, `answerByRunning`,
   `executingWorld`. Argv spawn (no shell), prompt to stdin from a forked writer, output capture,
   per-command timeout, the four-code answer table of §1.3.
6. **[EXEC]** `run/Main.hs`: compose `announcingWorld . executingWorld` for `Live` and `Adapter`;
   **not** for `Scripted`; add the "no command was run" line to the scripted announcement; add
   the working-directory announcement for the deck engine.
7. **[SURFACE]** `Agentic.Workflow.running`, `Agentic.Builder.askToolRunning`.
8. **[SURFACE]** `Example.Isaac`: rewrite `greenGateBrief` as a `toolExec` verdict and delete the
   `agentVerify` apology at `example/Example/Isaac.hs:586` and the table row at `:35`.
9. **[CORPUS]** The five fixtures of §1.7. No regeneration of existing entries.
10. **[GEN]** `Agentic.Gen`: generate `toolExec` addressees; update the tally comment at
    `Gen.hs:781`.
11. **[EXEC]** Tests: the memo-distinctness pair from §1.7 run through `runPlanIO` at a real
    `executingWorld` against two trivial commands (`true` and `false`), and one test per row of
    the answer table.

### D6-failover

12. **[LEAN][RAW]** `Syntax.lean`: `structure Served` and `RawAsk.model : Option Served`.
13. **[LEAN]** `Check.lean`: `a.model.map (·.primary)` at `:335` and `:466`. `askGuard`
    unchanged. Verify `Dsl.lean:762` and the `Explain.lean` uses still close by `rfl`.
14. **[RAW]** `Agentic.Raw`: `Served` with its codec; `askModel :: Maybe Served`.
15. **[EXEC]** `Agentic.Guards.askGuard`: pattern already payload-agnostic; confirm and pin.
    `guardUnpinnedAsk` (wave 1): one haddock sentence, one fixture.
16. **[EXEC]** New module `Agentic.Chains`: `servedChains :: RawProgram -> Either Text (Map Text
    [Text])`, full traversal including function bodies, panels, `review`/`amend`.
17. **[EXEC]** `Agentic.Exec`: `Chains`, `candidates`, `runPlanWith`, the `askOrMemo` loop of
    §2.4, `runPlanIO = runPlanWith noChains`. Fill in wave 1's `FailOver` constructor.
18. **[EXEC]** Classification: decode exhaustion and `Agentic.Shell`'s mechanism failures become
    gaps; a nonzero command exit does **not**. Deck and ACP gap mapping is wave 1's; D6 requires
    only that exhaustion be distinguishable.
19. **[EXEC]** `run/Main.hs`: build the chain table from `progRawOut`, refuse to start on an
    ill-defined table, pass it to `runPlanWith`.
20. **[SURFACE]** `Agentic.Workflow.fallingBackTo`, `Agentic.Builder.askModelFallingBack`.
    `servedBy` and `askModelServed` keep their spellings and types; the two records behind them
    widen — `Party.partyServe :: Maybe Served` (`Workflow.hs:379`) and `Ask.askServe :: Maybe
    Served` (`Builder.hs:465`) — which is invisible to every existing call site.
21. **[CORPUS]** Rewrite the `model` payload in the five entries of §2.1; confirm all five
    replies come back identical. Add the three new fixtures.
22. **[GEN]** Generate chained `served by` asks; update the tally.
23. **[EXEC]** Tests: the byte-identical-diagnostics criterion (§2.4) over the whole corpus; the
    factorization pin of §2.7; the repetition-after-exhaustion case (second walk asks nothing);
    the two-models-one-node case (`billMemo` rises by one, both events name their answerer).

**Ordering.** 1–4 before 5–11; 12–14 before 15–23. D5 and D6 are independent and can land in
either order within the wave; both want the corpus regeneration to happen once, at the end,
together with D2/D3/D4's.

---

## Part 4 — interaction points with the sibling designs

* **D1/D8 (calls and program inputs).** A `toolExec` act inside a function body is a
  `RawBodyStmt.act`, so whatever `function`/`callStmt` surface D1 exposes must accept the new
  party; and `Agentic.Chains`'s traversal must descend into function bodies for the same reason
  `Guards.askCounts` does. D8's program inputs must not become an argv source — an input is data
  and belongs on stdin, exactly as a prompt does (§1.6, fact 1).
* **D3/D4 (yielding revision, verdict forks).** The natural composition is a `revising` whose
  *review* is a `toolExec` at `verdict`: the loop amends until the command exits 0. That is
  `greenGate` and the fixer loop as one construct, and it is the strongest single argument for
  D5 and D3 landing in the same wave. `Agentic.Chains` must descend into `review` and `amend`.
* **D2/D7 (panelText, closed deciders).** A panel member may be a `toolExec` ask. More
  importantly D7's `anyPathMatches`/`diffNamesHaskell` motivation — "the model's answer cannot be
  trusted and is therefore *defeated* by becoming a question" — is the same motivation as D5, at
  a pure decider rather than at a subprocess. The two overlap and should be decided with each
  other in view: D5 covers everything D7 covers, at the price of a process spawn; D7 covers a
  narrow slice with no spawn at all.

---

## Part 5 — dissents and costs, recorded

* **The G4 dissent stands and is answered, not dismissed.** Adopting D5 does put a process spawn
  in the runner. The answer is that the runner already spawns processes to answer questions
  (`worldOfDeck` spawns three per question), that this one lives in a transport module and not in
  `Agentic.Exec`, and that the alternative — a language that can only ask an agent whether the
  tests passed — is the thing a four-hour run died of.
* **The `grep` case** (§1.3): a `text` ask on a command whose nonzero exit is an answer abandons
  the run. Known, conservative, reversible.
* **Chains are per-model, not per-ask** (§2.2). A restriction, bought deliberately to keep the
  kernel untouched, enforced by a runner precondition rather than assumed.
* **Five corpus entries change for D6** (§2.1). Not "none"; small, mechanical, reply-preserving.
* **`RetryHere` ships unreachable** (§2.3). Honest, and it is the same conclusion
  `unattendedRecovery` reached.
* **The live trace may disagree with the frozen one** after a fail-over (§2.5). That is the
  feature. It must be documented where the mechanism is, or the first operator to notice will
  file it as a bug.
