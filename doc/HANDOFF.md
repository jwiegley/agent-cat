# agent-cat: research record and handoff

*Written 2026-08-14 at commit `0f65ec4`. This document exists so that the work can
be picked up on another machine, or by another agent, without the conversation
that produced it. It records what the project is for, how it arrived at its
present shape, what was decided and why, what was discovered — including the
things that turned out false — and what remains open.*

`doc/PLAN.org` and the `obr` database are the **live** tracker; this document is
the **narrative and the reasoning**, which a ticket list cannot carry. Where the
two disagree about what is open, obr is right.

---

## 0. Getting a machine ready

**Repository.** `git@github.com:jwiegley/agent-cat.git`, branch `main`, HEAD
`0f65ec4`. Self-contained apart from the two ACP adapter binaries below.

**Toolchain.** Lean 4.30.0 and Mathlib v4.30.0, supplied by nix. `flake.nix`
provides the dev shell; `direnv` wires it up. From inside the repository:

```bash
direnv allow .                       # once
direnv exec . lake build             # everything (~2115 jobs)
direnv exec . lake exe agent-cat plan example/harden.wf
```

`lean-toolchain` pins `leanprover/lean4:v4.30.0`. It is inert under nix but
required by lake's dependency check, and it must match the nix Lean exactly.

**Two operational facts that will otherwise cost an afternoon.**

1. **Never run two Lean builds at once.** `Agentic/Core/DslFlagship.lean` costs
   roughly 100 seconds and several gigabytes: it proves its theorems by running
   the checker on a real program inside the kernel. Two concurrent elaborations
   exhausted 48 GB of RAM on the development machine, and the wall clock inflated
   to ~350 seconds under the paging that resulted. A single build is fine.
2. **The binaries do not depend on that module.** Building `agent-cat` from cold
   takes 5.8 seconds. If a build of the CLI appears to hang for minutes,
   something has re-coupled the dependency and that is the bug.

**ACP adapters** (only needed for live runs). Built from the nixpkgs revision
that `agent-functor` pins:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix build --impure \
  "github:NixOS/nixpkgs/70ce234312134a463ba7728e94da2486a1d237ac#claude-agent-acp" \
  "github:NixOS/nixpkgs/70ce234312134a463ba7728e94da2486a1d237ac#codex-acp"
```

They drive the operator's own authenticated `claude` / `codex` CLIs. Nothing in
this repository holds credentials or provider configuration.

**Sanity battery**, each run one at a time:

```
lake exe dsl_smoke   lake exe cli_smoke   lake exe mcp_smoke
lake exe exec_smoke  lake exe acp_smoke   lake exe mcp_client_smoke
lake exe harden_demo            # and --refuse, --sloppy-apply
lake exe agent-cat plan|cost|run example/harden.wf
```

---

## 1. What this project is

The goal, stated by the owner at the outset: **devise the mathematically best
design for agentic workflows, then realize it simply and efficiently in Lean 4
or Haskell.** Two existing repositories — `~/src/incite` (a workflow inventory)
and `~/src/agent-functor` (a Haskell library of `Flow`/`Op` combinators over ACP
agents) — were the starting material and are explicitly **examples only, not
definitional**.

The method is Conal Elliott's denotational design, taken literally rather than
as a slogan. The governing text is
`~/Documents/Obsidian/conal-elliott-denotational-design.md`; its self-contained
"Kernel" is the first 200 lines and is what every agent in this project was
required to read first. The discipline in one sentence: *give every type a
simple, precise mathematical meaning, require the function from the type to that
meaning to be a homomorphism for every abstraction the type inhabits, and derive
everything else — operations, laws, correctness, and finally efficiency — from
that requirement.*

The acceptance bar, stated by the owner near the end and non-negotiable:

> "I need theorems in the mathematical space of ⟦hardenPatch⟧ or else none of
> this means anything at all. And I need a concrete representation I can use to
> talk to real models, and then I need proofs that every operation in the
> representation space commutes with its denotation into the mathematical space.
> I need the full Conal Elliott treatment, or else none of this is worth a
> single thing."

All three exist now. Sections 3–6 say what they are.

---

## 2. The intellectual history

This is the order in which understanding actually changed. It is worth reading
because several turns were corrections, and the corrections carry more
information than the constructions.

**(a) Dual-repository study.** A seventeen-agent survey read all of `incite` and
`agent-functor` and produced an architecture dossier. This is the origin of the
project's knowledge of `Flow`, `Op`, the ACP transport, and the workflow
inventory — and, as it later turned out, of a contamination.

**(b) An ontology, then a reorientation.** The owner supplied a vocabulary of
AI-workflow concepts (model, context, tool, harness, prompt, agent, sub-agent,
turn, fork, session) and asked for a categorical account. A first attempt built
syntax first. The owner rejected it outright: *"I do not want a 'syntax before
semantics' approach — exactly the other way around."* From that point the method
was fixed: meanings first, algebra derived.

**(c) Monad, restored.** An early design refused `Monad` on the grounds that
workflow shape should be static. The owner overruled it: *"the choice of which
direction to take in a later turn may directly depend on the output tokens
generated by an earlier turn."* This was correct, and it is why the final design
stratifies rather than forbids: full monadic branching exists, it is quarantined
in one syntactic node, and what changes across the strata is not what may be
written but what may be *known* about what was written.

**(d) The Lean formalization, then Mathlib.** A first library defined its own
monoids, semirings and star operations. The owner's directive — *"make use of
the Lean Standard libraries as much as possible; we shouldn't need to replicate
the definition of what a monoid is"* — drove a migration that reduced eleven
hand-rolled classes to three documented survivors and replaced four hand-built
stars with one.

**(e) Seven rounds on the worked example.** The single most instructive thread
in the project. Each round the owner rejected the example and each rejection
named a real defect:

1. *"WAY too much complexity … I can't find my workflow anywhere."*
2. *"Why `panel₃`? A panel should take a list. What does `⟫` mean? I'd prefer
   `>>>`. What do all of these combinators mean??"*
3. *"This file is still WAY too long. Why all of this text?"*
4. *"All of these definitions are generic and don't belong in the example — they
   belong in the library."* (He quoted the op inductive, the verdict monoid, the
   carrier abbreviations and the decode function.)
5. *"Why `&&& id` and `id &&&`? … WHAT DOES ALL OF THIS MEAN???"*
6. *"I don't know what the `consent` boolean means; `gate consent apply` reads
   like gibberish."*
7. *"You haven't understood the nature of this code or how it's meant to be used
   at all. Re-review Conal's work."*

The lesson, in the doctrine's own words: *a trivially simple abstraction
surrounded by machinery has relocated its complexity into its clients, which is
worse than having kept it.* Every definition an example forces on its author is
a library design gap. The end point was a twelve-line do-block using five words
beyond do-notation — `ask`, `askHuman`, `model`, `panel`, `revising` — which the
owner approved and which is preserved at `example/HardenPatch.lean`.

**(f) The contamination directive.** When told that `agent-functor`'s `Flow`
matched the specification constructor-for-constructor, the owner did not take it
as validation:

> "That should be taken as a BAD thing. If our specification maps too closely
> onto agent-functor's design, then we've allowed the representation to form our
> thinking. Revisit this entire specification, from the ground up."

This is the project's sharpest methodological moment and it is now a standing
rule: **convergence with the seed implementation is evidence of contamination,
never justification.** Implementation precedent may not be cited in support of a
specification decision.

**(g) The ground-up re-derivation.** Eight agents: three independent derivations
(one blinded from every repository until its derivation was complete), a
contamination ledger with file-and-line citations on both sides, and three
adversarial attacks (simplicity, adequacy, Lean-realizability — the last one
*compiling* its claims). Outputs are in `doc/research/`. Findings in §4.

**(h) The full treatment.** Meaning, representation, every commuting square, the
flagship theorems, then the runtime, then real execution over ACP, then the
textual language, the MCP server, and the CLI.

---

## 3. The design as it stands

### 3.1 The meaning

A **world** is a total answer sheet — a function holding a reply for every
question that could be put:

```lean
abbrev Ω : Type := (c : Code) → Q c → El c        -- Agentic/Core/World.lean:47
```

`Code` is the closed universe of answer kinds (`text`, `verdict`, `flag`,
`ack`); `El` gives each its type (`String`, `Verdict`, `Bool`, `Unit`). Because
a world is indexed by the *question*, three domain facts become consequences:
asking twice yields one answer, so sharing needs no labels; memoisation is how a
runtime *constructs* the world the semantics quantifies over; and deliberate
resampling must be a different question, which is what the `draw` index is for.

A workflow denotes, for each world, **an answer together with the transcript of
what was consulted**:

```
⟦ a workflow ⟧ : Ω → (A × Trace)
```

A bare `Ω → A` is too coarse — it identifies a workflow that asks and discards
with one that never asked — and no compositional cost analysis can exist over
it. The meaning is defined on an intermediate carrier, the **dialogue**, which
is the free monad on the question signature (Escardó's dialogue; a W-type):

```lean
inductive Dlg (A : Type) : Type
  | done : A → Dlg A
  | ask  : (c : Code) → Q c → (El c → Dlg A) → Dlg A    -- Agentic/Core/Dlg.lean:50
```

with `run` and `trace` as the two folds. Calling that pair "the meaning" is
three claims, each discharged: they constitute the semantic function
`⟦p⟧ ω = (run ω p, trace ω p)`; they are monad morphisms (`run_bind`,
`trace_bind`, axiom-free), so composing workflows composes meanings; and they
fix equality. **The semantic function is not injective** — dialogues differing
in structure can agree in every world, and `Dlg.not_forcing` refutes the
"Forcing Lemma" the synthesized kernel had claimed — so semantic equality is
`Obs`, the kernel of the meaning, from which congruence follows with no axioms
and no quotient type.

### 3.2 The representation

`Plan Γ A` (`Agentic/Core/Plan.lean:197`) is first-order with de Bruijn binders
and five formers: `ret`, `askC` (a closed question), `ask` (words built from
earlier answers), `case` (finite branching, every arm present), and `dyn` (a
plan computed from an unbounded answer — the quarantine).

Two decisions carry the weight:

- **Owning the binder.** A point-free arrow presentation is analysable and
  unreadable; a higher-order one is readable and unanalysable (its cost fold
  would need every answer type finite, and free text is not). The third option
  is to own the binder: contexts are lists, variables are indices, the author
  writes a binding. Sharing is a variable used twice.
- **The shape is data; only the words are computed.** `Q c ≅ Q.Shape c × String`.
  The author writes the addressee, scope and draw as a *term*; only the prompt is
  an expression of earlier answers. The cost theorem at the pipeline level
  therefore carries no hypothesis, because an answer has nowhere to flow except
  into words. (This replaced a predicate, `ShapeStatic`, which was deleted
  outright when the node was refactored — the counterexample it repaired, an
  answer selecting an *addressee*, is no longer expressible.)

`denote : Plan Γ A → Env Γ → Dlg A` is the fold, and `Plan.run ω p γ` is
*defined* as `Dlg.run ω (denote p γ)`, so agreement between interpreter and
meaning holds by reflexivity.

### 3.3 The analyses

`level : Plan Γ A → Level` is a **fold, never a type index** — Lean's dependent
elimination refuses computed indices, which killed the graded-inductive design
before a line of it was written (`doc/research/attack-realizability-lean/`
contains the compiled probe).

| Level | Reached by | What is established |
|---|---|---|
| `batch` | closed questions only | the exact question list; the bill is world-independent |
| `pipeline` | words built from answers | the shape sequence is a projection of the syntax; exact bill under `PricesByShape` |
| `branch` | `case`, hence `revising` | a finite `CostTree`; every world's bill is one of its leaves |
| `dynamic` | `dyn` | a non-existence theorem, with a witness whose bills are unbounded |

The textual language has **no syntax for `dyn`**, so every program anyone can
write in it sits at or below `branch` and always has a cost analysis. That is
the trade the surface makes, and it is proved (`parseAndCheckRaw_level_le`).

### 3.4 The commuting squares

`Agentic/Core/Morphism.lean` — 55 theorems, one per operation, each stating that
building then taking the meaning agrees with taking meanings then building.
Representative: `denote_graft` (denote is a monad morphism), `trace_graft`
(transcripts concatenate), `denote_panel` (a panel is convolution — the
applicative lifting of the verdict monoid's product), `run_under` (a scope is a
reindexing of the world), `denote_revising` (check-then-revise unrolling).

### 3.5 The runtime

Three thin modules. `Acp.lean` speaks line-delimited JSON-RPC over a child
process's stdio and makes no semantic claim. `Exec.lean` is the memoising
interpreter, factored so the whole of `IO` is one oracle; the answer table *is* a
finite world under construction, and `worldOf_cons` proves recording an answer
and pinning a cell are one operation. `Certify.lean` carries the three
correctness statements:

```lean
Plan.execWith_eq_execM_denote : execWith o p γ t = execM o (denote p γ) t
                                                     -- rfl; axioms: none
Plan.adequacy : execWith o p ∅ nil = (a, t) →
    (∀ ω, Extends ω t → Plan.run ω p ∅ = a) ∧ (traces agree on extensions)
                                                     -- axioms: [propext]
certify_sound : certify p t a = true → ∃ ω, Plan.run ω p ∅ = a
                                                     -- axioms: NONE
```

Adequacy holds against an **arbitrary history-dependent answerer** — free to
drift and to contradict itself. `certify` replays a run's own log as a world and
compares; both axiom claims are pinned by `#guard_msgs`, so drift is a build
failure.

### 3.6 The surface: a textual language

`Agentic/Core/Dsl/{Syntax,Parse,Check}.lean`. The checker's *type* is its
soundness statement — it returns a well-typed `Plan` or a `CheckError`, with no
representable state between. The grammar was revised once, in response to
detailed criticism (§4.6); the flagship now reads:

```
workflow {
  let guide = ask tool "cat" for text
    "Write out the house style guide, at most four short lines."

  let draft = ask model "author" using model "deep" for text
    "Draft a patch satisfying:\n{spec}\nReply with a unified diff only."

  revising draft up to 2 revisions {
    check given patch { panel [ … three reviewers … ] }
    revise given patch, why { ask model "author" using model "deep" for text "…" }
  }

  approved given patch {
    let ok = ask person "owner" for flag "Apply this patch?\n{patch}\n{flagSpec}"
    if ok { act tool "apply" "Apply:\n{patch}\n…" } else { }
  }

  never approved { }
}
```

Braces delimit every scope; indentation means nothing. `given` *receives* and
never declares. Doing nothing is `{ }`.

### 3.7 The tools

- **`agent-cat plan|cost|run <program>`** — one front end (`withProgram`), so a
  type error reads identically from all three and exits 2;
  `parseAndCheckRaw_eq` proves it is the same front end the MCP server and the
  test suite use. `cost` reports what kind of statement each number is, and says
  when a bound is sound but unattained rather than presenting it as a price.
  `run --session ID` runs the workflow inside a session the client did not open
  (ACP `session/load`: the adapter restores the transcript, replays it, and the
  run continues in it), capability-gated and refused by name where the adapter
  never advertised the call. It **continues in place** — no lock, no attach, and
  no way for this process to see a second writer — so the operator must close the
  session's interactive owner first; `--fork-session` is the variant that reads
  the original and writes a copy.
- **`agent-cat run --engine deck --session <deck-id>`** — the answer to the
  negative half of that verdict. ACP cannot attach to a live session; `agent-deck`
  can, because it is the control plane that owns the pane. `Agentic/Core/Deck.lean`
  drives the `agent-deck` command line — `session send`, then `session show`
  polled until the session is idle, then `session output` — with a **staleness
  guard** (`send` returns before the agent starts, so the reply's timestamp must
  differ from the one taken before the send, or the previous turn's text is read
  as this question's answer), a per-turn budget, and five named failures. It is
  not an adapter: `Acp.Adapter.ofName` still knows only `stub`, `claude` and
  `codex`, because a deck session is a conversation to join and not a program to
  spawn. Decoding, the re-ask and the abandonment are `Exec.askDecoding`, shared
  with the ACP engine, so the two fail in the same words.
  **The two `--session`s are opposites and one flag carries both**: `--engine acp
  --session` must never be aimed at a thread whose TUI is live, and `--engine deck
  --session` is precisely how such a thread is reached safely. The flag's help
  text and the run header say so where the operator is looking. `person` questions
  go to this terminal by default — the operator watching the pane *is* the person
  — and `--all-to-session` sends them into the pane instead; `--poll-ms` and
  `--turn-timeout-ms` are the engine's clocks. `test/DeckSmoke.lean` drives it
  against `haskell/test/stub-deck.sh`, the same fixture `haskell/ci/deck.sh` runs
  against the Haskell implementation of the same transport.
- **`workflow_mcp`** — an MCP server. A dialogue is already ask-and-continue, so
  the server holds `(Dlg, Table)` per run and steps it by tool call: the calling
  agent is the oracle.
- **`harden_demo`** — retained beside `agent-cat run` because its assertions are
  about *that workload* and each names the theorem it shadows.

---

## 4. What was discovered

### 4.1 The contamination, located exactly

The specification's world had been indexed by **syntactic positions** — the seed
implementation's interpreter node-ids promoted into the meaning. Every
unresolved problem in the old library descended from it: the label/site/key
apparatus, a quotient that could not finish its congruence obligations, two
meaning functions that contradicted each other at three constructors, and the
library's own proof (`peak_not_le_grade`) that its grade index failed to bound
the width it existed for. A second contamination: the point-free spine was kept
after the justification for it (Flow has no `arr`) had been discarded — the new
library added `pureT`, which *is* `arr`.

The repair was not to solve those problems but to index worlds by **questions**,
after which they do not exist.

### 4.2 Where the re-derivations were wrong

All four derivations then reached for `Applicative ⊂ Selective ⊂ Monad` over
question *values*. The adequacy attack showed those lower rungs are **empty in
this domain**: a free applicative's question list is closed before any answer
exists, while every prompt after the first interpolates an earlier answer — so
all six stress workloads, including the owner's own style-guide sharing example,
landed at full monad, where each kernel's own theorems say no static cost
exists. The level the domain inhabits is the arrow/pipeline level: shape fixed,
content flowing. This is why the representation is what it is.

### 4.3 Compiled negative results

Each of these is a *fact*, established by a probe that compiles
(`doc/research/attack-realizability-lean/`):

- Mathlib has no `FreeMonad`, no `FreeApplicative`, no `FreeSelective`, and no
  `Selective` class at all.
- A graded inductive whose index is computed from its own constructors **cannot
  be eliminated** — dependent elimination fails. Grade must be a fold.
- A quotiented-free monad's `bind` depends on `Classical.choice`, so the
  semantic type would be noncomputable and the interpreter could not run on it.
- Cost on a higher-order dialogue requires `Fintype` on every answer type, which
  free text does not have.
- The free *selective* functor is an open problem in the literature (only the
  rigid one is known), which is why `case` is written directly.

### 4.4 Failed morphisms kept as diagnostics

Nine are recorded beside their repairs. The three that changed the design: the
Forcing Lemma is false, so equality is `Obs`; C2 (pipeline cost) was false while
`ask` carried an arbitrary question expression, and was repaired *in the
representation* rather than by a side condition; C3's attainment claim was false,
and the flagship's own minimum of 5 is proved unattained rather than quietly
reported as a price.

### 4.5 What live execution taught that no stub could

- **Answering a permission request with a JSON-RPC error does not end the turn.**
  The model retries, apologises in prose, and the turn completes normally at
  ~97k tokens with no protocol-level signal distinguishing it from an answer.
- **The consent gate was decorative.** Permission was a property of the
  *connection*, so an `ask` and an `act` were the same event to the layer that
  authorises writing. In a refusing run — no apply question, bill 6 — the author
  model wrote the hardened file *during its draft turn*. Fixed: permission is now
  a function of the question (act grants, every ask denies), and the workspace is
  fingerprinted before and after, so a run that performed no act yet changed
  files fails and names them.
- **The two mechanisms do not overlap, and both are needed.** In the live
  re-test the author tried to compile its patch in `/tmp` — outside the
  workspace, where the fingerprint is structurally blind. Only the permission
  layer could see it.
- **Adapters talk over the model.** `claude-agent-acp` injects narration
  (*"claude-fable-5 declined this request (cyber); retried with
  claude-opus-4-8"*) into the answer stream as ordinary text. In one run it was
  concatenated onto a reviewer's `APPROVE`; because approval must be the whole
  reply under the fail-closed rule, the verdict decoded as an objection and
  bought a revision round. The substituted model is not in the adapter's
  advertised catalogue.
- **Claude Code 2.1.226 as an MCP client** (protocol `2025-11-25`) advertises
  `elicitation` in form mode only and answers `sampling/createMessage` with
  `-32601`. Elicitation returns `cancel` headless. Hence relay is the default
  and `decline`/`cancel` never decode into a two-valued answer.
- **A run with nothing to act on still passes every check.** The first live run
  of `agent-cat run` used an empty directory; the author correctly refused to
  invent a diff, the reviewers approved the refusal, the owner was asked to
  consent to it, and the act reported completion having written nothing. Every
  check passed, because every check is about the *shape* of a run. This is the
  sharpest available demonstration of what the theorems do and do not say.

### 4.6 On the surface, and why it was revised twice

The first textual grammar scoped a revision by indentation, introduced one
artefact three times in what looked like argument lists, and turned on two words
(`exhausted`, `done`) a reader had to be taught. The revision made scope
syntactic, made receiving distinct from declaring (`given`), replaced the two
opaque words with `approved` / `never approved` and `{ }`, and made a question
read as one sentence. **The elaborated plan did not move**: every theorem block
in `DslFlagship.lean` is byte-identical, statement and proof, and
`check_flagshipRaw` still closes by kernel evaluation, so the new text is
*proved* to elaborate to the plan the old text did.

---

## 5. Standing decisions and house rules

These are working agreements the owner has stated. They are binding on future
sessions.

**Method.**
1. Meanings before syntax, always. Every type's docstring opens with
   `[[T]] = <one-line mathematical object>`.
2. Every operation carrying a semantic claim has its morphism equation in the
   docstring and the proved theorem adjacent. An equation that will not close is
   recorded with a diagnosis, never weakened and never skipped.
3. Recognise standard structure; delete bespoke vocabulary. Laws are inherited
   through morphisms, not asserted.
4. Convergence with `agent-functor` is contamination evidence, not
   justification.
5. Report progress as **theorem statements with axiom footprints**, not as
   process or tracking updates.

**Examples and surfaces.**
6. An example file contains exactly what a user would write. No vocabulary
   tables, no read-outs, no runner machinery. Teaching material lives elsewhere.
7. Any definition an example forces on its author is a library gap.
8. A surface must be readable without a glossary; a keyword either says what it
   means or does not exist.

**Process.**
9. `obr` is the live tracker: record every issue, observation or note the moment
   it appears (prefix `acat`, surface `doc/PLAN.org`, protocol in `AGENTS.md`,
   flush with `obr sync --flush-only`).
10. Run Lean via `direnv exec .` from inside the repository. One build at a time.
11. Do not weaken a flagship theorem statement to make something else pass.

---

## 6. Repository map

```
Agentic/Core/
  Question.lean   478   Code, El, Q, Q.Shape, Verdict (WithZero (FreeMonoid Objection))
  World.lean      242   Ω, Table, Extends, worldOf, pin (= Function.update)
  Dlg.lean        455   the dialogue carrier; run/trace; LawfulMonad; Obs
  Plan.lean       627   the representation: five formers, de Bruijn contexts
  Denote.lean     709   denote, the fold; Plan.run / Plan.trace
  Level.lean      334   the rung fold
  Cost.lean      1036   CostTree, bills, PricesByShape, C0–C5
  Morphism.lean   711   the 55 commuting squares
  HardenPatch.lean 991  the flagship as a Plan, and its theorems
  Dsl/Syntax.lean 274   Raw, Prompt, CheckError
  Dsl/Parse.lean  555   lexer + recursive descent, no dependencies
  Dsl/Check.lean  575   check : … → Except CheckError (Plan Γ Unit)
  Dsl.lean        369   level theorems about the checker (cheap; binaries need this)
  DslFlagship.lean 427  the flagship program's decide-proofs (~100 s; binaries do NOT)
  Rpc.lean        155   shared JSON-RPC framing
  Acp.lean       1115   the ACP transport, model catalogue resolution, permissions
  Exec.lean      1390   the memoising interpreter; decoders; the one oracle
  Certify.lean    269   adequacy and the certificate
  Report.lean     701   RunReport, transcript rendering, coverage
  Artifact.lean   673   scratch dirs, workspace seeding, fingerprints
  Explain.lean    527   the folds `plan` and `cost` print
  Mcp.lean       1649   the MCP server: a dialogue stepped by tool call
cli/AgentCat.lean       agent-cat plan|cost|run
mcp/WorkflowMcp.lean    workflow_mcp
demo/Main.lean          harden_demo, with the workload-specific assertions
example/                harden.wf, hello.wf, ill-typed.wf, harden.d/parse.c,
                        HardenPatch.lean (the approved Lean surface, pre-Core)
test/                   six smoke targets + stub_adapter.py + mcp_client.py
doc/                    this file; the two HTML artifacts; mcp.md; PLAN.org; research/
```

Roughly 14,300 lines and 540 theorems in `Agentic/Core`, zero `sorry`, zero
declared axioms. Every result lies within `{propext, Classical.choice,
Quot.sound}`, and `certify_sound` within none of them.

**Documents.** `doc/meaning-and-representation.html` (what the two layers are
and how the proofs bind them), `doc/dsl-guide.html` (the language, taught),
`doc/mcp.md` (the server), `doc/research/` (the re-derivation: three blind
derivations, the contamination ledger, three adversarial attacks, the compiled
Lean probes, and the three DSL grammar proposals). `doc/design.html` and
`doc/walkthrough.html` predate the re-derivation and describe the **superseded**
`Term` calculus — keep for history, do not follow.

**The superseded stratum.** `Agentic/*.lean` outside `Core/` (Term, Frag,
Meaning, the WEqR quotient, Surface) is the pre-re-derivation library. It still
builds and `example/HardenPatch.lean` still uses it. Retiring it is obr
`acat-q1i`; roughly 4,700 lines die, and the mathematics worth keeping
(semirings, matrices, Kleene star, the scope monoid, convolution) has largely
been re-derived in `Core` already.

---

## 7. Where the work stands, and what to do next

**Done and verified:** the meaning space; the representation; 55 commuting
squares; the flagship theorems (consent, the guide asked exactly once, ≤ 3
drafts, level = branch, the nine-leaf cost tree with its extremes and the
reachable-bill set, the unattained minimum proved unattained); the runtime with
adequacy and a zero-axiom certificate; live execution against Claude Code over
ACP, in which a real patch was drafted, reviewed, consented to and applied, and
in which a refused run now leaves the workspace byte-identical; the textual
language with its checker; the MCP server; the `agent-cat` CLI.

**Immediately next, in the order I would take them:**

1. **`acat-owa`** — the adapter's narration corrupts answers, and the runtime
   discards the usage data that would let it report real token cost. Decide
   deliberately: strip a recognised narration block before decoding, or annotate
   the turn and leave decoding strict. Capturing `usage` also settles the
   unmeasured claim about what denial costs.
2. **`acat-q1i`** — retire the superseded `Term` stratum and re-point
   `Agentic/Surface.lean` at `Plan`, keeping `example/HardenPatch.lean`
   byte-identical (two elaboration constraints are recorded on `acat-nx8`).
3. **`acat-fuk`, `acat-zbx`, `acat-qzl`** — the accumulated medium and low
   findings from three adversarial passes, each with its reproduction.
4. **Reachability** — the cost tree over-approximates because a `case` prices its
   arms independently while a world correlates them. A reachability analysis
   would name the bills that are actually attainable; nothing in the package does
   this yet, and the CLI says so where it matters.

**Larger open questions** (obr has them all): the `dyn` rung has no analysis by
construction and that is a theorem, not a gap; per-token pricing does not factor
through question shape and wants an interval keyed to a token bound carried in
the answer type; and the MCP server's elicitation path is untested against a
client that answers rather than cancelling.

---

## 8. Moving the session

Everything needed is in the repository except three things.

1. **The doctrine document** —
   `~/Documents/Obsidian/conal-elliott-denotational-design.md`. Copy it; the
   first 200 lines are the operative part and every agent should read them
   before touching the design.
2. **The obr database** — and this one is a trap. `.obr/` is **gitignored**, so
   the issue database does *not* travel with a clone. What travels is
   `doc/PLAN.org`, which is tracked and holds all 48 issues in readable form.
   Two ways to land on the new machine:

   - copy `.obr/` across directly, alongside the clone (simplest, keeps
     history); or
   - `obr init --prefix acat` on the new machine, then
     `obr sync --import-only` to rehydrate the database from the tracked
     `doc/PLAN.org` (`obr sync --status` first, to see what it would do).

   Check `obr count` afterwards: 48 issues, of which 31 are open.
3. **Credentials for live runs** — the operator's own `claude` / `codex` CLIs,
   authenticated on the new machine. Nothing here stores them.

The two HTML artifacts also exist in `~/Documents/` as
`agent-cat-meaning-and-representation.html` and `agent-cat-dsl-guide.html`;
`doc/` holds the same files, so the repository copies are authoritative.

A useful first command on the new machine, after `direnv allow .` and one full
build:

```bash
direnv exec . lake exe agent-cat cost example/harden.wf
```

If it prints nine leaves, a cheapest of 5, a dearest of 15, and the paragraph
explaining that the cheapest may be unattained, the port is good.
