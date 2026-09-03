# agent-cat — a denotational design for agentic workflows

Meaning first. A workflow is given a mathematical meaning, and everything else is
derived from it: the syntax a person writes, the folds that classify and price a
program, the interpreter that runs it against a live agent, and a conformance
relation that holds a second implementation to the first. The method is Conal
Elliott's denotational design, taken literally.

## Module architecture

Agent-cat is one repository and one product, built as independently checkable
modules. The root [`cabal.project`](cabal.project) is the Haskell workspace; the
packages are not versioned or published independently. Lean remains normative,
and [`bisim`](bisim) holds the only Lean–Haskell conformance boundary.

`A → B` means that A may depend on B:

```text
model
dsl
plan → dsl
cost → plan
engine/api
runtime → plan + engine/api
engine/acp/{claude,codex,droid} → engine/acp → engine/api
engine/agent-deck → engine/api
workflow/{core,example,extra} → dsl
bisim → model + dsl + plan
cli:verification → bisim + cost + dsl + plan  (private test library)
cli:tier1 → cli:verification + dsl + plan + workflow/{core,example}
cli:bisim → cli:verification + bisim + dsl + plan
cli → workflows + plan + cost + runtime + concrete engines
ext-pi → cli's versioned process protocol
```

The dependency graph is acyclic and Cabal-enforced. Workflow packages import
only [`dsl`](dsl), name models symbolically, and cannot see planning, cost,
runtime, routing, or engine implementation details. Engine-neutral facts supplied
by a host are named in the Text-only `Agentic.Runtime.Facts` API; repository
workflow packages do not import it. [`cli`](cli) alone loads model-definition
files and maps symbolic references to concrete engines/models.

Every module has a local `README.md` and `AGENTS.md` describing its purpose, API,
dependencies, adjacent edges, commands, and conventions. The single shared issue
ledger remains [`doc/PLAN.org`](doc/PLAN.org).

[`ext-pi`](ext-pi) discovers and supervises `agentic-run` through the versioned
machine protocol; it does not interpret `RawProgram` or `Plan`. Future
`engine/mcp` and `tui` boundaries are documented but deliberately have no source
tree or placeholder package. A future TUI is to be drawn from
[agent-functor](https://gitlab.com/fresheyeball/agent-functor), use its own local
flake, and be invoked by CLI only when fully implemented.

## The Lean half — the verification spine

Lean 4.30.0 with Mathlib v4.30.0. `model/Agentic.lean` is the mathematical space and
imports only mathematics: the resource algebra, panels, traces and scopes, the
authoring words of `Surface`, and the rederivation kernel under `Agentic.Core` —
the schema-indexed values (`Schema`), principal question identity (`Question`),
annotated executable requests (`Request`), bare-question worlds/dialogues, the
five-form representation (`Plan`), its intent-erasing denotation (`Denote`),
static semantic folds (`Level`, `Cost`), operational reference layers
(`SemanticExec`, `AnnotatedExec`, `ExecCost`), commuting squares (`Morphism`,
`Alg`), and flagship (`HardenPatch`).

Outside the root sit the things that are about a *program* rather than about the
space: the raw syntax and its elaboration (`Core.Dsl.Syntax`, `Core.Dsl.Check`,
`Core.Dsl`), the JSON representation of structured values (`Core.Schema.Json`),
the trusted base and interpreter (`Exec`), the per-run certificate (`Certify`),
coverage and the bill as a number (`Report`), and the renderings (`Explain`).

There is **no parser, no concrete syntax and no runtime here.** What Lean keeps
is what can be proved and what the port is measured against; the authoring
surface and the runner are Haskell's.

The flagship is kernel-checked. `model/Agentic/Core/DslFlagship.lean` holds the flagship
as a `RawProgram` — the term of record, and the very program frozen as corpus
entry `example-000` — and proves by `decide +kernel` that the checker accepts it,
that its level is `branch`, that its cost tree has nine leaves with a minimum of 5
and a maximum of 15, and that its transcript in four named worlds is the
hand-written `Harden.demo`'s. True by computation rather than by assertion.

The theorem the elaboration exists to make true is `Dsl.checkProgram_level_le`:
*every* program the checker accepts sits at or below the branch rung, so every
program has a finite cost tree, and every analysis downstream of the level fold
applies to every program there is.

## Intent annotates execution; questions determine meaning

A question says who, scope, words and draw; this is semantic answer identity.
The executable `Plan` additionally records how one occurrence is to run:

```lean
inductive Intent : Code → Type
  | consult : Intent c
  | observe : Intent c
  | effect  : Intent .ack

structure Request (c : Code) where
  question : Q c
  intent   : Intent c
```

Thus `Ω = (c : Code) → Q c → El c`; semantic dialogue, event, table, key, and
price erase intent. The same five-form `Plan` retains `Request = Q × Intent` as
an intermediate annotation. Source lowering is fixed: ordinary value asks
consult, value-position `running` observes, and statement-position `act` effects.

At execution, consult and observe share answers by bare `Q`; effects neither read
nor populate reusable memo, reserve the effect lane, and remain billable per
occurrence. Permission follows
intent. These are realization policies, not principal meaning. Annotated events
forget to semantic events by a proved trace square. Tags state authored policy,
not physical outcome; `observe` cannot prove an argv read-only.

## The conformance boundary

`cd bisim && lake exe conformance-oracle` is a line-delimited JSON process that
checks and observes `RawProgram`s and exercises the string layer. `bisim/corpus/` holds 190
legacy version-2 request/reply pairs plus three additive version-4 typed-result
vectors. Version 2 remains byte-identical semantic observation. Live differential
requests version 3 compare annotated Plan events while also returning
`semanticTrace`, their bare-question erasure; version 4 carries a result code
beside the unchanged `RawProgram` and returns that value per world.

The corpus is **frozen**, and the requests in it are the specification.
`lake exe corpus-gen` reads each file, takes its request *verbatim*, puts it back
through the same `observe` and `stringOp` the oracle serves, and rewrites the
file with the fresh reply. (It once built the corpus from `.wf` sources; with no
parser and no `.wf` files there is nothing upstream of a request to start from,
and re-observation is both all that is possible and the whole of what mattered.)
**Regenerating is expected to be a no-op**: an empty `git status --short
bisim/corpus` afterwards is the statement that the elaboration, the cost algebra,
the interpreter and the trusted base still say exactly what the frozen
specification says they say. A diff is a change to the specification, reviewed as
one.

## The Haskell half — the authoring surface

[`dsl`](dsl) holds raw syntax, schemas, the typed structural AST, Builder, and
the ordinary-Haskell authoring surface. [`plan`](plan) and [`cost`](cost) provide
separate pure interpreters; [`runtime`](runtime) executes through
[`engine/api`](engine/api). **The authoring surface is ordinary Haskell** — no
splice, no bracket, no label, and no file format of its own. A bind is a Haskell
bind, a fenced prompt is a `[wf|…|]` with `{name}` holes and a layout rule, a
`define` is a Haskell binding, `W.do` is `QualifiedDo`, and
`result <- revising draft (atMost 2) \patch -> W.do` opens the review loop.
Both branches are Haskell's own — a `case` on the exported `Outcome`, and an `if`
reaching `ifThenElse` because an authoring module enables `RebindableSyntax`. The
end of `workflow/core/src/Workflow/Core/Harden.hs`:

```haskell
    case result of
      Settled patch -> W.do
        ok <- confirm (person "owner") [wf|
            Apply this patch?
            {patch}
            {flagSpec}|]

        when ok $ W.do
          act (tool "apply") [wf|
              Apply:
              {patch}
              Write the patched file here, then reply DONE.|]
      Unsettled _ -> stop
```

`when` is the one-armed `if`: terminal, sealed by a `stop`, and printing the
identical `ifFlag` node. Two programs are written this way today — `harden`, the
flagship, and `hello` — and they are the values everything downstream reads.

Five further forms the surface carries, each an ordinary Haskell value:

* **`revisingOn`** — the same bounded revision, reading the review's *verdict
  tag* three ways rather than one predicate two ways: approval settles, an
  objection amends, **a refusal abandons**. Its `case` is on `Ending`, whose
  three constructors are `SettledOn` / `UnsettledOn` / `AbandonedOn` — suffixed
  because Haskell has one constructor namespace per module and `Outcome` already
  spells the first two. It is not free: the tail is built three times and the
  plan replicates it `2n+1` times against `revising`'s `n+1`, so a wide tail
  reaches the question budget at roughly half the bound.
* **`panelText`** — `panel`'s twin at `text`: the same fan-out, folded into
  fenced blocks in member order rather than into the verdict monoid. Each
  member's answer is wrapped `<name>`…`</name>`, verbatim and untrimmed, with
  one escape — a body that contains this fence's own `</name>` has it rewritten
  to `<\/name>`, so a member cannot forge the end of its own block. A sibling's
  tag passes through untouched, which is what makes the blocks nest.
* **Schema-indexed answers** — `Schema.El` in Lean and `SchemaEl` in Haskell
  interpret a schema as ordinary algebraic structure: lists and nested products
  over unit, booleans, integers, exact rationals and strings. The semantic code
  is `Code.structured schema` / `CodeStructured schema`; an author writes
  ``ask … `annotated` Structured schema``. Static schemas provide `KnownSchema`,
  so the existing `one`, `function`, `revising` and `amend` vocabulary remains
  the only authoring path. For Haskell records, `$(deriveSchema ''T)` derives
  `SchemaOf T`, its witness, and total conversion automatically. JSON is not the
  answer's meaning:
  `Schema.Json` / `Agentic.Schema.Json` are one representation layer, responsible
  for parsing, finite-decimal encoding and the standard JSON Schema instruction.
  `workflow/example/src/Workflow/Example/Structured.hs` is the runnable worked example: its
  record declaration and one splice are all the schema author writes.
* **`decide`** — a closed vocabulary of four pure classifications
  (`LastNonEmptyLineIs`, `ContainsLine`, `AnyLineStartsWith`, `AnyPathMatches`)
  over text already in hand, answering a flag. It asks nobody, so writing one
  where an asked flag stood is **one fewer question on every path, the same
  number of paths, and the same rung**. Its needles are literal program text and
  never holes: a needle a model could author is a test a model chooses.
* **`servedBy` / `fallingBackTo`** — a `served by` pin and the models that may
  answer in its place. The fail-over is Exec policy and changes no plan, no
  price and no fold; only a *gap* moves on, and the trace records **the model
  that actually answered**, with the attempt that failed narrated on stderr
  instead. With no alternates declared, every diagnostic is byte-identical to
  what it always was.

``tool "gate" `running` ("nix", ["flake", "check"])`` in value position is an
observation whose answer comes from that argv. In statement position the same
`running` form is an occurrence-sensitive effect. The exit status is the answer
wherever the answer type can express failure — `flag` takes `True`/`False`,
`verdict` takes the command's first failing line — and the run is abandoned where
it cannot. The argv is program text with no interpolation syntax.

## Typed closed-program results

The mathematical space already had results: `Plan Γ A`, `Dlg A`, and
`runPlanWith :: Plan '[] a -> IO (a, ExecTrace)`. The closed authoring surface
now exposes that existing parameter. Legacy `Program` remains the receipt-valued
alias and still ends in `stop`; `ProgramOf c` and `ParameterizedOf c` retain an
existing `Code`/`Schema` witness, and a result program ends in `answer`:

```haskell
translated :: ParameterizedOf 'CodeText
translated = taking (input "language" :> noInputs) \language -> workflow W.do
  source <- ask (model "greeter") [wf|Hello, world!|]
  result <- ask (model "translator") [wf|Translate into {language}: {source}|]
  answer result
```

`answer` remains the function-body return too; the stage index distinguishes
returning to a caller from returning from the whole program. Every branch is
built at one result code, so inconsistent arms fail in Haskell and the Lean
checker imposes the same code on every raw terminal. Returning is a pure `ret`:
it adds no question, path, effect, rung or cost.

The frozen `RawProgram` record is still exactly `{fns, main}`. Typed programs add
only the `answer` terminal constructor; conformance version 4 supplies the
expected result code as an envelope field. Existing program JSON and all legacy
corpus bytes therefore remain unchanged. `structured-result` is the runnable
schema-valued example.

## The runner — `agentic-run`

One executable, five verbs over those programs, from the repository root:

```sh
nix develop path:. -c cabal run agentic-run -- list
nix develop path:. -c cabal run agentic-run -- help harden
nix develop path:. -c cabal run agentic-run -- plan harden --raw
nix develop path:. -c cabal run agentic-run -- cost harden
nix develop path:. -c cabal run agentic-run -- run harden --scripted
nix develop path:. -c cabal run agentic-run -- run harden --engine acp --adapter stub
nix develop path:. -c cabal run agentic-run -- run harden --session <deck-id>
```

Factory Droid is built in as `--adapter droid`, which launches `droid exec
--output-format acp`; the Python SDK is not required. The executable must be on
`PATH` and authenticated locally or through an inherited `FACTORY_API_KEY`. Use
`acp:droid` in routes. A plain Droid backend uses its configured default model;
a routing profile with `max-output: unconstrained` selects and verifies Droid's
advertised model and reasoning controls before prompting. Unsupported declared
settings fail preflight rather than silently falling back.

The exact commands, temporary source/profile, authorization, and non-secret live
outcomes are retained in [`doc/droid-live-verification.md`](doc/droid-live-verification.md).

`help` prints one program's page — what it is for, what each of its inputs means,
which transport it wants, one worked command line and one rehearsal — under a
header computed from the same folds `list --json` publishes, so the numbers on a
page and the numbers a gate pins cannot come to disagree. It spends nothing, asks
nobody, and starts no adapter. `<name> --help` is the same page.

`plan` and `cost` say nothing a run could contradict: they are the *static* folds
— level, size, ask nodes, answer codes, and the cost summary — decided before
anybody is asked anything, with `--raw` printing the program itself as the
builder prints it. `run` executes through the memoizing interpreter against one
of three answering services, and **which one is the whole of what `--engine`
says**: `--scripted` answers from a table of canned replies and asks nobody;
`--engine acp` starts an adapter of its own and owns the pipe; `--engine deck`
(which a bare `--session <id>` selects) sends into a live `agent-deck` session
somebody else started and is watching. All three end at the same decode loop, so
a run means the same thing either way and fails in the same words. `--timeout`
and `--verbose` are common; the flags that belong to one engine are refused for
the other by name. Exit codes are `0` a completed run, `1` a usage error, `2` a
transport failure, `3` a run abandoned over what arrived.

Live runs may resolve symbolic workflow pins through layered YAML routing
profiles. A profile such as `deep-thinker` owns an ordered ACP/deck realization
chain — router, provider, model, thinking level and explicit output policy — while Haskell
source retains only the capability name. User and project files load
automatically; explicit `--route` entries remain the highest backend override;
and every declared setting is applied or verified before a prompt. The
versioned schema, precedence rules, migration example and transport limitations
are specified in
[`cli/README.md`](cli/README.md#model-definitions).

Nothing here rebuilds, adapts or trims a program for execution: `agentic-run run
harden` runs the exact `Program` that `tier1` has already held against the frozen
corpus entry, print and reply alike, which is what makes a live run evidence
about the language rather than about this executable.

## The gates

Lean is normative, and the Haskell asks to be believed on no authority of its
own. `tier0` replays every frozen vector, `tier1` rebuilds the curated checked
entries in the production surface and compares the whole reply — printed
program, folds, ask counts, one trace and two bills per world — and `bisim`
draws fresh programs and worlds against the live oracle.

The deterministic gates live with their owners:

- `bisim/ci/tier0.sh` replays frozen vectors and rebuilt programs without Lean.
- `bisim/ci/tier1.sh` runs the live differential against a prebuilt oracle.
- `cli/ci/examples.sh`, `policies.sh`, and `routing-config.sh` pin CLI,
  scheduler, persistence, control, and model-definition behavior.
- `engine/acp/ci/acp.sh` and `engine/agent-deck/ci/deck.sh` drive all transport
  scenarios against module-local doubles. `engine/acp/ci/route-live.sh` is
  manual and paid; no automatic gate invokes it.

Tier 1 refuses to build or silently skip its oracle. This preserves the
one-build rule for the expensive Lean flagship.

## Building

The nix devShell is the only environment; `direnv allow .` wires it up.

# Haskell workspace
nix develop path:. -c cabal build all
nix develop path:. -c cabal run agentic-run -- run harden --scripted

# Normative Lean model
nix develop path:./model -c bash -c 'cd model && lake build'

# Lean conformance oracle and byte-frozen corpus
nix develop path:./model -c bash -c 'cd bisim && lake build && lake exe corpus-gen'

The Texinfo manual builds and checks in the same shell:

```sh
nix develop -c make -C doc check
```

The command renders GNU Info and single-page HTML in a temporary directory,
treats diagnostics as failures, and leaves no generated file in the working tree.
Use `make -C doc all` to retain both formats under the ignored `doc/build/`
directory. Run `make -C doc check-haskell` for the compiler-derived constructor
and instance inventory, complete manual examples, and deterministic CLI transcript.
The exact workflow and repository verification outcomes are recorded in
`doc/verification.md`.

**Never run two full model builds at once.**
`model/Agentic/Core/DslFlagship.lean` dominates the build — minutes of wall
clock and several gigabytes. The bisim oracle deliberately excludes that module.
The Haskell workspace is independent and runs from the repository root:

```sh
nix develop path:. -c cabal build all
nix develop path:. -c cabal run agentic-run -- run harden --scripted
./bisim/ci/tier0.sh
./cli/ci/policies.sh; ./cli/ci/examples.sh
./engine/acp/ci/acp.sh; ./engine/agent-deck/ci/deck.sh
N=500 SEED=1 ./bisim/ci/tier1.sh
```

## What was retired

This repository once carried a `.wf` language of its own — a concrete syntax, a
parser, a command line that planned, priced and ran a file, transports to ACP and
to `agent-deck`, and an MCP server that stepped a run by tool call. On
2026-08-18 the owner retired all of it in favour of the Haskell authoring
surface, and it was removed rather than deprecated. What the language leaves
behind is its contract, and the contract is the point: the frozen corpus under
`bisim/corpus/` still pins, byte for byte, exactly what the elaboration, the cost
algebra, the interpreter and the trusted base compute, and the flagship's
kernel theorems still hold — re-anchored to the `RawProgram` term, which is now
where the program is written down rather than a thing a parser produced. Git
history holds the rest.

On 2026-08-20 the **pre-re-derivation stratum** went the same way, under obr
`acat-q1i`. Every `Agentic/*.lean` outside `Core/` except `Agentic/Scope.lean` —
`Term`, `Frag`, `Meaning`, `Surface`, `Panel`, `Semiring`, `Instances`, `Matrix`,
`Star`, `Keys`, `Trace`, `Gate`, `Pareto`, `Env`, `Context`, `Monoid`, roughly
9,900 lines — was excised. It was the project's first attempt at the whole
problem (a graded syntax of workflows, two meaning functions over it, the `WEqR`
quotient, the resource algebra underneath), it was superseded by `Agentic/Core/**`
in the 2026-08 re-derivation, and by the end it had **no consumer anywhere**: the
last one died with `example/HardenPatch.lean`, and the certified spine read
exactly one line of it (`Agentic/Core/Question.lean:1`, `import Agentic.Scope`,
which is why that one file stays). What it *established* is not lost and is not
in git: it is written down as `doc/research/term-algebra-results.md`, which
transcribes the theorems — mostly negative results, the expensive kind — from the
live sources before they went. Cite that page rather than the module names.

## The documents

* `doc/request-intent-representation.md` — foundational K1–K6 placement: bare-Q
  meaning, annotated Plan, erasing denotation, runtime policies and evidence ceilings.
* `doc/HANDOFF.md` — the research record: what the project is for, how it reached
  its shape, what was decided, and what turned out false. It is a record and not
  a description of the present; its banner says which parts the retirement
  overtook. The papers beside it are `doc/meaning-and-representation.html` (what
  the two layers are and how the proofs bind them) and, for history only,
  `doc/design.html` and `doc/walkthrough.html`, which describe the superseded
  `Term` calculus.
* `doc/conformance-schema.md` — the wire format, and what the corpus pins on each
  of its three surfaces. The module-local READMEs describe the current Haskell implementation.
* `doc/verification.md` — current deterministic build/test and boundary-audit evidence.
* `doc/workflows/` — Pi workflow used only to author and validate the manual; it is
  documentation tooling, not an agent-cat workflow/runtime module.
* `doc/research/connection.md` — the design of record for the connection between
  the two implementations: why reimplementation-plus-conformance rather than
  extraction, FFI or a subprocess oracle, and, in §3, the boundary, the request
  schema and the corpus that are live today. The rest of `doc/research/` is the
  re-derivation and the dossiers that condemned the first calculus.
* `doc/research/term-algebra-results.md` — the permanent record of what the
  condemned stratum proved, written from the live sources before the 2026-08-20
  excision removed them. Read it instead of `git show` when you want to know
  whether a question about the `Term` calculus has already been answered: §2 is
  the results, §3 the six theory threads nobody closed, §4 the tracker items that
  closed with the code, and §5 where the mathematics went that earned its place.

Issue tracking is `obr` (prefix `acat`; see `AGENTS.md` and `doc/PLAN.org`).

## Acknowledgements

This work owes a real debt to **Isaac Shapira** and two projects of his:
[agent-functor](https://gitlab.com/fresheyeball/agent-functor) and
[incite](https://github.com/jwiegley/incite). agent-functor showed what a
typed, lawful account of agent interaction could look like as working
Haskell, and incite's workflows — the review ladders, the rosters of
deliberately-partial reviewers, the grind loops that treat verification as
a separate party — are the direct ancestors of this repository's authoring
surface and of several of its worked examples (`Example.Isaac` carries five
of them, ported and priced). More than the code, the *stance* carried over:
that a workflow is a value worth reasoning about before it runs, and that
an intelligent reviewer is built, not prompted. The design conversations
recorded in `doc/research/isaac-workflows.md` trace what was taken, what
was adapted, and where this project chose differently.
