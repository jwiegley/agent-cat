# agent-cat

agent-cat is a language for agentic workflows with a mathematical meaning, a
typed representation that can be inspected before it runs, and a runtime that
executes it against live agents. The design follows Conal Elliott's
denotational design. A workflow is first given a precise meaning. The syntax an
author writes, the folds that classify and price a program, the interpreter
that runs it, and the conformance relation that holds a second implementation
to the first are all derived from that meaning.

The repository holds two implementations and the boundary between them. A Lean
4 model under `model/` defines the meaning, the representation, and the
theorems that connect them. A Haskell package rooted at `agentic.cabal`
provides the authoring surface, the analyses, the runtime, the engine adapters,
and the `agentic-run` command. The conformance suite under `bisim/` holds the
Haskell implementation to the Lean model through a frozen corpus and a live
oracle. A TypeScript extension under `ext-pi/` makes workflows available inside
the Pi coding agent. The Texinfo manual in `doc/agent-cat.texi` is the
reference for all of it.

## What a workflow is

A workflow puts questions to parties, receives typed answers, and uses those
answers to decide what to ask next. A party is a model, a tool, or a person. An
answer is text, a verdict, a flag, a receipt, or a structured value described
by a schema. Control is finite: a workflow may branch on a flag or a verdict,
fan a question out to a panel of reviewers, revise a candidate a bounded number
of times, and call straight-line functions. Every program the authoring surface
accepts therefore has a finite set of possible paths, and its cost can be
computed before anyone is asked anything.

The authoring surface is ordinary Haskell. A workflow block is a `QualifiedDo`
block, a prompt is a `[wf|...|]` quasiquotation with `{name}` holes that refer
to Haskell variables in scope, and a branch is a Haskell `case` or `if`. The
end of the flagship example, `workflow/example/Harden.hs`, reviews a patch
through a three-member panel, revises it at most twice, and applies it only
with the owner's consent:

```haskell
    result <- revising draft (atMost 2) \patch -> W.do
        verdict <- panel
          [ ask (model "reviewer-correct") [wf|
              {guide}
              Is this patch correct?
              {patch}
              {verdictSpec}|],
            ask (model "reviewer-secure") [wf|
              {guide}
              Is this patch secure?
              {patch}
              {verdictSpec}|],
            ask (model "reviewer-simple") [wf|
              Could this patch be simpler?
              {patch}
              {verdictSpec}|]
          ]
        amend (ask (model "author" `servedBy` "deep") [wf|
            {guide}
            Revise this patch:
            {patch}
            {verdict}
            Reply with the revised diff only.|])

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

Building this value produces two things at once: a first-order `RawProgram`,
which is printable data that crosses the language boundary, and a typed `Plan`,
which the Haskell runtime analyses and executes. The manual's chapters "First
Workflow" through "Functions, Inputs, and Schemas" teach the surface.

## Meaning, representation, and intent

The meaning of a workflow is defined against a world. A world is a total answer
sheet, one answer for every typed question, written `Ω = (c : Code) → Q c →
El c`. A question `Q c` records its addressee, its scope, its prompt, and a
draw that distinguishes deliberate resampling from reuse; these four fields are
the whole of a question's identity. A workflow denotes, for each world, a
result together with the ordered transcript of the questions that produced it.
That meaning is computed by two folds over a dialogue, the free monad on the
question signature, and equality of workflows is agreement of both folds in
every world.

The representation is the five-form `Plan`: return, closed ask, open ask,
finite case, and a dynamic form that the authoring surface never emits. It is
first-order with de Bruijn binders, so it can be folded. The folds give the
analysis level of a program, its node and question counts, and its cost tree,
which at the `branch` level is a finite multiset containing every world's bill.
A denotation function maps a `Plan` to a dialogue, and
`model/Agentic/Core/Morphism.lean` proves that every operation on plans
commutes with the corresponding operation on dialogues. Running a plan is
defined as running its denotation, so the interpreter agrees with the meaning
by reflexivity. `doc/meaning-and-representation.md` presents this argument in
full.

The representation carries one component the meaning does not: an intent. A
request in a `Plan` is `Request c = Q c × Intent c`, and the intent is one of
`consult`, `observe`, or `effect`. The mathematics identifies a question by who
is asked, in what scope, with what words, and at which draw, and a world answers
questions and nothing else. A runtime that executes a plan has to make decisions
that identity does not record: whether an occurrence may reuse an answer
already obtained for the same question, whether it must run every time it is
reached because it acts on the world, whether the addressee may be granted
tool permission, and how it is ordered relative to other acts. Without an
author's declaration, the runtime would infer these policies from the answer
code or the addressee. An early live run showed where that leads: permission
was a property of the connection, and a model asked only to draft a patch wrote
the file during its drafting turn.

Placing intent inside the question was considered and rejected, because it
would make the answer to a question depend on the policy under which it is
asked, and two workflows that ask the same questions and hear the same answers
would then mean different things. Intent therefore refines the representation
rather than the meaning. Source position fixes it: an ordinary value question
lowers to `consult`, an executable tool in value position lowers to `observe`,
and a statement-position act lowers to `effect`, which exists only at the
receipt code. Denotation forgets the intent, and the theorems
`denote_askC_intent_irrel` and `denote_ask_intent_irrel` hold by reflexivity.
Operationally the tag is what the runtime consults. Consult and observe
occurrences share one memo table keyed by the bare question, so a repeated
question is answered once. Effect occurrences bypass that table, execute per
occurrence, are billed per occurrence, enter an ordered lane, and are the only
occurrences granted tool permission under the ACP transport. Every execution
event keeps the authored request beside its answer source, and the theorem
`Plan.execAnnotated_correct` proves that the annotated execution trace erases,
event by event, to the semantic trace. The tags state authored policy and never
physical outcome: `observe` does not prove a command read-only, and `effect`
does not prove that a change occurred.

## The Lean model

`model/` is a Lake package pinned to Lean 4.30.0 and Mathlib v4.30.0.
`model/Agentic.lean` imports the mathematical strata in order: the last-wins
scope monoid, schema-indexed values, questions, annotated requests, worlds,
dialogues, the `Plan` representation, its denotation, the level and cost folds,
the commuting theorems, the fold algebra, and the flagship workload
`HardenPatch`. Beside the root sit the modules that concern a program rather
than the space: the first-order syntax and its checker under `Core/Dsl`, the
JSON representation of structured values, the reference interpreters
`SemanticExec` and `AnnotatedExec`, the trusted base `Exec`, the per-run
certificate `Certify`, and the renderings in `Report` and `Explain`. There is no
parser, no concrete syntax, and no runtime in Lean; the authoring surface and
the runner are Haskell's.

The flagship is kernel-checked. `model/Agentic/Core/DslFlagship.lean` holds the
flagship as a `RawProgram`, the same term frozen as corpus entry
`example-000`, and proves by `decide +kernel` that the checker accepts it, that
its level is `branch`, that its cost tree has nine leaves with a minimum of 5
and a maximum of 15, and that its transcript in four named worlds equals the
hand-written dialogue's. The theorem `Dsl.checkProgram_level_le` states that
every program the checker accepts sits at or below the `branch` rung, so every
accepted program has a finite cost tree.

## The conformance boundary

`bisim/` is a second Lake package that requires the model by a local path and
deliberately excludes the expensive flagship module. Its `conformance-oracle`
executable is a line-delimited JSON process that checks and observes
`RawProgram` values, evaluates them in specified worlds, and exercises the
string layer. Program observations exist at three versions. Version 2 is
frozen bare-question semantics. Version 3 compares intent-annotated execution
events and returns their erasure as `semanticTrace`. Version 4 adds a typed
program result beside the unchanged program.

`bisim/corpus/` holds 193 frozen request and reply pairs: 95 checked replies,
54 refusals, and 44 string-layer results. Every legacy entry is version 2 and
the three typed-result entries are version 4. The corpus is the specification.
`lake exe corpus-gen` re-observes every request and rewrites the reply, and it
is expected to change nothing; an empty `git status --short bisim/corpus`
afterwards states that the elaboration, the cost algebra, the interpreter, and
the trusted base still agree with the frozen specification. A diff is a change
to the specification and is reviewed as one. The manual's "Conformance
Boundary" chapter specifies the wire format and states exactly what the corpus
pins.

Three Haskell executables sit on the boundary. `tier0` replays every frozen
vector without Lean. `tier1` rebuilds the curated checked entries in the
production authoring surface and compares the printed program and the whole
reply. `bisim` draws fresh programs and worlds and compares them with the live
oracle. Lean is normative throughout: the Haskell implementation asks to be
believed on no authority of its own.

## The Haskell implementation

The Haskell side is one Cabal package, `agentic`, whose source directories keep
separate ownership and an acyclic dependency graph. An arrow means that the
left side may depend on the right:

```text
dsl
plan -> dsl
cost -> plan
engine/api
runtime -> plan, engine/api
engine/acp/{claude,codex,droid} -> engine/acp -> engine/api
engine/agent-deck -> engine/api
workflow/{core,example,extra} -> dsl
bisim -> model, dsl, plan                          (tests only)
cli -> workflow, plan, cost, runtime, concrete engines
ext-pi -> the versioned process protocols of agentic-run
```

`dsl` owns the raw syntax, the schema vocabulary, the typed structural AST, the
builder, the prompt quasiquoters, and the `QualifiedDo` authoring surface.
`plan` and `cost` are pure interpreters over the typed AST: level, size,
question nodes, answer codes, and the cost tree. `runtime` executes a plan
against any engine and owns scheduling, memoization, decode and re-ask policy,
fail-over, effect ordering, the machine protocol, persistence, and lineage.
`engine/api` is the neutral interface; `engine/acp` speaks the Agent Client
Protocol to an adapter process, with Claude, Codex, and Factory Droid
selectors as children, and `engine/agent-deck` joins an existing agent-deck
session. `workflow` holds compiled workflow values whose only local dependency
is `dsl`; they name models symbolically and cannot see planning, cost, routing,
runtime, or engines. `cli` is the composition root: it owns the registry, the
help pages, the scripted replies, the concrete backend grammar, the routing
configuration, and the exit mapping. `cli/ci/policies.sh` enforces the import
graph. Each directory carries a `README.md` describing its purpose and a
`AGENTS.md` describing its conventions.

## The runner

`agentic-run` is one executable with five human verbs over the registered
programs, run from the repository root:

```sh
nix develop path:. -c cabal run agentic-run -- list
nix develop path:. -c cabal run agentic-run -- help harden
nix develop path:. -c cabal run agentic-run -- plan harden --raw
nix develop path:. -c cabal run agentic-run -- cost harden
nix develop path:. -c cabal run agentic-run -- run harden --scripted
nix develop path:. -c cabal run agentic-run -- run harden --engine acp --adapter stub
nix develop path:. -c cabal run agentic-run -- run harden --session <deck-id>
```

`list`, `help`, `plan`, and `cost` spend nothing and start no adapter. `plan`
and `cost` report the static folds, decided before anybody is asked anything,
and `--raw` prints the first-order program the builder emitted. `run` executes
through the memoizing interpreter against one of three answering services, and
which one is the whole of what `--engine` says. `--scripted` answers from a
table of canned replies registered beside the program. `--engine acp` starts an
adapter and owns its pipe; the adapters are `stub`, `claude`, `codex`, `droid`,
or an executable path, and `droid` launches `droid exec --output-format acp`,
authenticated locally or through an inherited `FACTORY_API_KEY`. `--session`
sends every question into a live agent-deck session that another process
started and is watching. All three end at the same typed decode loop, so a run
means the same thing on every service and fails in the same words. Exit status
0 is a completed run, 1 a usage or preflight refusal, 2 a transport failure,
and 3 a run abandoned over what arrived; a machine run cancelled through its
control channel exits 130.

A workflow names its serving model symbolically, for example `servedBy
"deep-thinker"`. A live run resolves that name through layered YAML routing
profiles: a user file at `$XDG_CONFIG_HOME/agent-cat/routing.yaml` and the
nearest project file `.agent-cat/routing.yaml`, both at schema version 1, with
an explicit `--route` as the highest backend override. A profile owns an
ordered realization chain of router, model, thinking level, and output policy,
and every declared setting is applied or verified before the first prompt.
`cli/model-definitions.example.yaml` is a complete example covering every
profile the bundled workflows name. Routing selects an answering service after
the program and its analyses already exist, so it changes neither the plan nor
its price.

The `machine` verbs execute the same program while emitting protocol version 1
NDJSON events on standard output and accepting correlated controls on an
inherited file descriptor. Runs can persist an immutable manifest, an
append-only event journal, reusable typed answers, an effect journal, and
checkpoints, and `machine-restart`, `machine-resume`, and `machine-fork` create
child runs with immutable lineage. `list --json` publishes descriptor version 2
for supervisors. The registry currently holds nine programs: `harden`, `hello`,
`structured`, `structured-result`, `plan-feature`, `review-lite`,
`ship-feature-lite`, `grind-tests`, and `stack-prs`.

## The Pi extension

`ext-pi/` is a TypeScript extension that makes Pi the control plane for
agent-cat workflows. It performs no search for a runner: the trusted
`agentic-run` executables are named, by absolute path, in `AGENT_CAT_RUNNER` or
`AGENT_CAT_RUNNERS`. The extension reads their descriptors, collects inputs,
launches machine mode, reduces the event stream into a live monitor, delivers
controls, and keeps durable run references. The `/wf`
command launches a workflow in the current Agent Deck session, and a family of
`/workflow-...` commands covers help, plan, status, monitoring, steering,
recovery, redirect, grants, lineage, and cancellation. The extension never
interprets a `RawProgram` or a `Plan`; agent-cat remains the only workflow
interpreter. `ext-pi/README.md` gives its configuration, commands, targets, and
security posture.

## Building and verifying

The Nix development shells are the only supported environments; `direnv allow
.` wires the root shell up. The Haskell workspace builds from the repository
root, and the Lean model and the conformance oracle build in the model shell:

```sh
nix develop path:. -c cabal build all
nix develop path:. -c cabal test all
nix develop path:./model -c bash -c 'cd model && lake build'
nix develop path:./model -c bash -c 'cd bisim && lake build && lake exe corpus-gen'
```

Never run two full model builds at once. `model/Agentic/Core/DslFlagship.lean`
proves its theorems by running the checker inside the kernel, which takes
minutes of wall clock and several gigabytes of memory. The conformance package
excludes that module and builds in seconds.

The deterministic gates live beside their owners and contact no paid service:

```sh
./bisim/ci/tier0.sh
N=500 SEED=1 ./bisim/ci/tier1.sh
./cli/ci/policies.sh
./cli/ci/examples.sh
nix develop path:. -c ./cli/ci/routing-config.sh
./engine/acp/ci/acp.sh
./engine/agent-deck/ci/deck.sh
```

`tier1.sh` requires a prebuilt oracle and refuses to build one.
`engine/acp/ci/route-live.sh` contacts real backends and is run only by
explicit operator choice. The manual builds and checks in the root shell:

```sh
nix develop path:. -c make -C doc check
make -C doc check-haskell
```

The first command renders GNU Info and HTML in a temporary directory and runs
the checkers that hold the manual's examples, reference coverage, prose, and
retained workflow record against the source. The second compiles the manual's
example modules, compares its command-line transcripts with fresh output, and
verifies the compiler-derived member ledger. The manual's "Building and
Verification" chapter describes every gate.

## Documentation

The manual, `doc/agent-cat.texi`, is the reference: architecture and evidence
ceilings, the mathematical and operational models, the conformance wire
format, a tutorial, the authoring and runner references, diagnostics, and a
glossary. `doc/meaning-and-representation.md` gives the denotational argument
at length. Every source directory has a `README.md` and an `AGENTS.md`.
`doc/research/` holds the design records and research dossiers, including the
re-derivation that produced the current mathematics, the connection design
that chose conformance testing over extraction, the placement decision for
request intent, the design of the Pi extension, and the results of the
superseded `Term` calculus; they are kept as records of how decisions arose.
The implementation designs for the proposed Brick interface and persona-aware
model resolution are [`doc/tui-design.md`](doc/tui-design.md) and
[`doc/model-routing-v2.md`](doc/model-routing-v2.md); both remain proposals,
not current runtime behavior.
Issue tracking is `obr` with prefix `acat`, whose tracked surface is
`doc/PLAN.org`; `AGENTS.md` describes the workflow.

## Acknowledgements

This work owes a real debt to Isaac Shapira and two projects of his,
[agent-functor](https://gitlab.com/fresheyeball/agent-functor) and
[incite](https://github.com/jwiegley/incite). agent-functor showed what a
typed, lawful account of agent interaction could look like as working Haskell.
incite's workflows, the review ladders, the rosters of deliberately partial
reviewers, and the grind loops that treat verification as a separate party,
are the direct ancestors of this repository's authoring surface and of several
of its worked examples; `workflow/extra/Isaac.hs` carries five of them, ported
and priced. More than the code, the stance carried over: that a workflow is a
value worth reasoning about before it runs, and that an intelligent reviewer is
built rather than prompted. `doc/research/isaac-workflows.md` records what was
taken, what was adapted, and where this project chose differently.
