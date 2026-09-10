# agent-cat

agent-cat is a system for writing and running agentic workflows. A workflow in
this system puts questions to language models, tools, and people, receives
typed answers, and uses those answers to decide what to ask next. The system
gives every workflow a mathematical meaning before it runs. The syntax that an
author writes, the analyses that classify and price a program, the interpreter
that runs it, and the tests that hold the implementation to its meaning are all
derived from that meaning. The method is the denotational design of Conal
Elliott.

The repository holds two implementations and the boundary between them. A Lean
4 model under `model/` defines the meaning, the representation, and the
theorems that connect the two. A Haskell package rooted at `agentic.cabal`
provides the authoring surface, the analyses, the runtime, the adapters for
live agents, and the `agentic-run` command. The conformance suite under `bisim/`
checks the Haskell implementation against the Lean model through a frozen corpus
of test vectors and a live oracle process. A TypeScript extension under
`ext-pi/` makes the workflows available inside the Pi coding agent. The Texinfo
manual in `doc/agent-cat.texi` is the reference for all of these parts.

## What a workflow is

A workflow is a program that asks questions and acts on the answers. Each
question names a party, which is a model, a tool, or a person. Each answer has
one of five kinds. It is text, a verdict from a reviewer, a yes-or-no flag, a
receipt that confirms an action, or a structured value that a schema describes.
A workflow can branch on a flag or a verdict. It can send one question to a
panel of reviewers and combine their verdicts. It can revise a candidate a
bounded number of times, and it can call functions that contain no branches.
The workflow has no other form of control. Every program that the authoring
surface accepts therefore has a finite set of possible paths, and the system
can compute its cost before anyone is asked anything.

An author writes a workflow in ordinary Haskell. A workflow block is a
`QualifiedDo` block, a prompt is a `[wf|...|]` quasiquotation, and a hole such
as `{patch}` inside a prompt refers to a Haskell variable in scope. A branch is a
Haskell `case` or `if`. The flagship example in `workflow/example/Harden.hs`
sends a patch to a panel of three reviewers, revises the patch at most twice,
and applies it only when the owner consents. Its final part reads as follows:

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

When Haskell evaluates this value, it produces two things. The first is a
`RawProgram`, a first-order tree of plain data that can be printed and sent
across the language boundary. The second is a typed `Plan`, which the Haskell
runtime analyses and executes. The manual teaches the authoring surface in its
chapters from "First Workflow" to "Functions, Inputs, and Schemas".

## Meaning, representation, and intent

The meaning of a workflow is defined against a world. A world is a total answer
sheet that holds one answer for every possible typed question, and it is
written `Ω = (c : Code) → Q c → El c`. A question `Q c` records four things. It
records the party that is asked, the scope of the question, the prompt, and a
draw number that distinguishes a deliberate resample from a reuse of the same
question. These four fields are the whole identity of a question. A workflow
denotes, for each world, a result together with the ordered transcript of the
questions that produced that result. Two folds over a dialogue compute this
meaning, where a dialogue is the free monad on the question signature. Two
workflows are equal when both folds agree in every world.

The representation is a `Plan`, a tree with five forms. The forms are a
return, a closed ask whose words are fixed, an open ask whose words are computed
from earlier answers, a finite case, and a dynamic form that the authoring
surface never emits. The tree is first-order and uses de Bruijn indices for its
binders, so it can be folded. The folds give the analysis level of a program,
its counts of nodes and questions, and its cost tree. At the `branch` level the
cost tree is a finite multiset that contains the bill of every world. A
denotation function maps a `Plan` to a dialogue, and
`model/Agentic/Core/Morphism.lean` proves that every operation on plans commutes
with the corresponding operation on dialogues. The interpreter runs a plan by
running its denotation, so the interpreter and the meaning agree by
definition. `doc/meaning-and-representation.md` presents this argument in full.

The representation carries one component that the meaning does not carry, and
that component is the intent of a request. A request in a `Plan` has the type
`Request c = Q c × Intent c`, and the intent is `consult`, `observe`, or
`effect`. The meaning identifies a question by its party, scope, words, and
draw, and a world only answers questions. It records nothing about how a
question is carried out. A runtime that executes a plan must make several
decisions that this identity does not record. It must decide whether an
occurrence can reuse an answer that an earlier identical question obtained. It
must decide whether an occurrence must run every time it is reached, because
it acts on the world. It must decide whether the party can receive permission
to use tools, and in what order the occurrence runs relative to other acts.
Neither the answer kind nor the party settles these decisions. A receipt-valued
question to a tool can be a harmless consultation or an act on the world. The
author therefore declares the intent, and the runtime reads it.

The intent lives in the representation and never in the question. Worlds stay
indexed by the bare question, so the answer to a question cannot depend on the
policy under which the question is asked. Two workflows that ask the same
questions in the same order and hear the same answers therefore have the same
meaning under every execution policy. The position of a request in the source
determines its intent. An ordinary value question is a `consult`. An
executable tool in value position is an `observe`. An act in statement
position is an `effect`, and the `effect` intent exists only for the receipt
kind. The denotation forgets the intent. The theorems
`denote_askC_intent_irrel` and `denote_ask_intent_irrel` state this fact, and
both hold by reflexivity.

During a run, the runtime reads the intent of each occurrence to choose its
policy. Consult and observe occurrences share one memo table that is keyed by
the bare question, so the runtime answers a repeated question once. Effect
occurrences bypass that table. The runtime executes and bills each effect
occurrence separately, and it places effects in an ordered lane so that a later
act cannot overtake an earlier one. Under the ACP transport, it grants tool
permission only to effects. Every execution event keeps the authored request
beside the source of its answer, and the theorem `Plan.execAnnotated_correct`
proves that the annotated execution trace erases, event by event, to the
semantic trace. The intent states the policy that the author declared and
never a physical outcome. An `observe` does not prove that a command is
read-only, and an `effect` does not prove that a change occurred.

## The Lean model

`model/` is a Lake package that is pinned to Lean 4.30.0 and Mathlib v4.30.0.
The root module `model/Agentic.lean` imports the mathematical strata in order.
It begins with the last-wins scope monoid, schema-indexed values, questions,
annotated requests, worlds, and dialogues. It continues with the `Plan`
representation, its denotation, the level and cost folds, the commuting
theorems, and the fold algebra, and it ends with the flagship workload
`HardenPatch`. Beside the root sit the modules that concern a program rather
than the space. These are the first-order syntax and its checker under
`Core/Dsl`, the JSON representation of structured values, and the reference
interpreters `SemanticExec` and `AnnotatedExec`. The trusted base `Exec`, the
per-run certificate `Certify`, and the renderings in `Report` and `Explain`
sit beside them.
Lean contains no parser, no concrete syntax, and no runtime. The authoring
surface and the runner belong to Haskell.

The module `model/Agentic/Core/DslFlagship.lean` holds the flagship as a
`RawProgram`. This term is the same term that the corpus freezes as entry
`example-000`. The module proves four facts inside the kernel by
`decide +kernel`. The checker accepts the term, and its level is `branch`. Its
cost tree has nine leaves with a minimum of 5 and a maximum of 15. Its
transcript in four named worlds equals the transcript of the hand-written
dialogue. The
theorem `Dsl.checkProgram_level_le` states that every program
that the checker accepts sits at or below the `branch` level, so every accepted
program has a finite cost tree.

## The conformance boundary

`bisim/` is a second Lake package. It requires the model by a local path and
deliberately excludes the expensive flagship module, so it builds in seconds.
Its `conformance-oracle` executable is a process that reads one JSON request
per line and writes one reply per line. The oracle checks and observes
`RawProgram` values, evaluates them in specified worlds, and exercises the
string layer that decodes answers. Program observations exist at three
versions. Version 2 records the frozen bare-question semantics. Version 3
compares intent-annotated execution events and returns their erasure as
`semanticTrace`. Version 4 adds a typed program result beside the unchanged
program.

`bisim/corpus/` holds 193 frozen pairs of a request and its reply. The
corpus contains 95 checked replies, 54 refusals, and 44 results from the string
layer. The three typed-result entries are version 4, and every other entry is
version 2. The corpus serves as the specification of the boundary. The command
`lake exe corpus-gen` re-observes every request and rewrites its reply, and this
command must change nothing. An empty `git status --short bisim/corpus` after
the command states that the elaboration, the cost algebra, the interpreter, and
the trusted base still agree with the frozen specification. A diff is a change
to the specification, and it is reviewed as one. The manual's chapter
"Conformance Boundary" specifies the wire format and states what the corpus
pins.

Three Haskell executables work at this boundary. `tier0` replays every frozen
vector without Lean. `tier1` rebuilds the curated checked entries in the
production authoring surface and compares the printed program and the whole
reply with the frozen versions. `bisim` draws fresh programs and worlds and
compares them with the live oracle. Lean is normative throughout, and every
claim that the Haskell implementation makes about the language is checked
against it.

## The Haskell implementation

The Haskell side is one Cabal package named `agentic`. Its source directories
keep separate ownership, and their dependency graph has no cycles. In the
graph below, an arrow means that the left side can depend on the right side:

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

`dsl` owns the raw syntax, the schema vocabulary, the typed structural tree,
the builder, the prompt quasiquoters, and the `QualifiedDo` authoring surface.
`plan` and `cost` are pure interpreters over the typed tree. They compute the
level, the size, the question nodes, the answer kinds, and the cost tree.
`runtime` executes a plan against any engine. It owns scheduling, memoization,
the decode and re-ask policy, fail-over, the ordering of effects, the machine
protocol, persistence, and lineage. `engine/api` is the neutral interface to an
engine. `engine/acp` speaks the Agent Client Protocol to an adapter process,
with selectors for Claude, Codex, and Factory Droid as children, and
`engine/agent-deck` joins a session that agent-deck already owns. `workflow`
holds the compiled workflow values. Their only local dependency is `dsl`, they
name models symbolically, and they cannot see planning, cost, routing, the
runtime, or the engines. `cli` is the composition root. It owns the registry,
the help pages, the scripted replies, the concrete backend grammar, the
routing configuration, and the exit mapping. The script `cli/ci/policies.sh`
enforces the import graph between the directories. Each directory carries a
`README.md` that describes its purpose and an `AGENTS.md` that describes its
conventions.

## The runner

`agentic-run` is one executable with five verbs for human use over the
registered programs. Run it from the repository root:

```sh
nix develop path:. -c cabal run agentic-run -- list
nix develop path:. -c cabal run agentic-run -- help harden
nix develop path:. -c cabal run agentic-run -- plan harden --raw
nix develop path:. -c cabal run agentic-run -- cost harden
nix develop path:. -c cabal run agentic-run -- run harden --scripted
nix develop path:. -c cabal run agentic-run -- run harden --engine acp --adapter stub
nix develop path:. -c cabal run agentic-run -- run harden --session <deck-id>
nix develop path:. -c cabal run agentic-run -- --routing --json --offline
```

The verbs `list`, `help`, `plan`, and `cost` spend nothing and start no
adapter. `plan` and `cost` report the static folds, which are decided before
anyone is asked anything, and `--raw` prints the first-order program that the
builder emitted. `run` executes the program through the memoizing interpreter
against one of three answering services, and the `--engine` option selects
only which service answers. `--scripted` answers from a table of canned replies
that is registered beside the program. `--engine acp` starts an adapter and owns
its pipe. The adapters are `stub`, `claude`, `codex`, `droid`, or the path of
an executable, and `droid` launches `droid exec --output-format acp`, which
must be authenticated locally or through an inherited `FACTORY_API_KEY`.
`--session` sends every question into a live agent-deck session that another
process started and watches. An explicit engine or session is the complete
command-line route table, even when `--routing` is also present. All three
services end at the same typed decode loop, so a run means the same thing on
every service and fails in the same words. Exit status 0 is a completed run, 1
is a usage or preflight refusal, 2 is a transport failure, and 3 is a run
abandoned over what arrived. A machine run that is cancelled through its control
channel exits 130.

A workflow names its serving model symbolically, for example `servedBy
"deep-thinker"`. When no engine or session is named, the runner always loads
routing configuration and requires every engine-bound question to have a
configured pin. Tool and person questions require an explicit target. Version 1
remains supported. Version 2 keeps privileged engines, environment references,
catalogues, concrete model aliases, personas, and defaults in the user file
`$XDG_CONFIG_HOME/agent-cat/routing.yaml`. The nearest project file may select a
persona and replace profiles, but cannot widen engines or models. Persona
precedence is `--persona`, `AGENT_CAT_PERSONA`, project selector, then user
default. Exact and ordered-prefix selectors freeze one model id per run. Bounded
OpenAI and Anthropic discovery uses private persona and fingerprint caches.


Exact and ordered-prefix selectors freeze an exact model identifier before an
engine starts. `--realize AXIS=MODEL-ALIAS` safely replaces a managed version-2
axis. Raw `--route` entries refine only an explicit command-line target.
`--routing --json` emits the sanitized frontend contract, and
`--migrate-routing SOURCE --output DESTINATION` creates an equivalent offline
version-2 file without overwriting the source. The example in
`cli/model-definitions.example.yaml` covers every profile that the bundled
workflows name. Routing remains operational policy after the program and its
analyses exist, so persona changes neither the plan nor its price.

The `machine` verbs execute the same program while emitting versioned NDJSON
events on standard output and accepting correlated controls on an inherited file
descriptor. Omission preserves protocol version 1. An explicit version 2 uses
store format 2 and adds private result/question artifacts, local person answering,
and bounded public progress without changing answers, traces, or bills. Runs
persist an immutable manifest, append-only events, reusable typed answers, an
effect journal, and checkpoints; lineage verbs create immutable child runs.
`list --json` preserves descriptor version 2. `--descriptor-version 3` selects
the routing and protocol-negotiation capabilities of the current frontend.
The registry currently holds nine programs: `harden`, `hello`,
`structured`, `structured-result`, `plan-feature`, `review-lite`,
`ship-feature-lite`, `grind-tests`, and `stack-prs`.

## The terminal interface

`agentic-run --tui` opens the Brick/Vty frontend for the current executable's
registry. Downstream binaries using `cliMain`, including `wf`, inherit the same mode.
The interface enters a fixed shell before asynchronous discovery and keeps context,
status, and applicable actions visible. Its Workflows, Runs, and Routing sections use
concise non-wrapping list rows with selected-row details, explicit pane focus, and
contextual key help. Narrow terminals show one focused pane at a time. A nonempty
`NO_COLOR` keeps terminal defaults and textual selection cues without semantic
foreground colors.

The launch path collects declared inputs in paste-safe multiline editors and preserves
them during backward navigation within workflow configuration and during resize. It
strictly decodes the post-input plan and checks its workflow identity against the
catalogue row. The compact review shows the workflow, request range, effects,
relevant profile chains, target, persona, directory, warning count, and live billing
risk. A separate scrollable layer contains every warning, the level, size, ask count,
pins, complete fold histogram, direct argv, paths, provenance, and fingerprints.
Input bodies and the raw program
remain hidden. Confirmation requires `Enter` or `y`. It is enabled only when every
review row and the launch, back, and exact-detail controls fit the current terminal.
Live launch requires full model-pin coverage, repeats offline routing-only resolution,
and refuses a changed routing fingerprint or a credential-unready engine.

The responsive live monitor includes workflow, persona, realization, run identity,
status, elapsed time, follow state, and bills. Concise occurrence rows and a bounded
detail/output pane preserve occurrence identity under concurrent updates. The
frontend uses protocol 2, a private store, fd-3 controls, and local person answering.
It supports detach and reattach, steering, recovery, redirect, confirmed cancellation,
and restart, resume, and fork. Person and recovery decisions share one protocol-sequence
FIFO, and modal-specific editor drafts survive mandatory preemption. Verified final results are displayed on demand and can
be copied through an explicit exclusive path prompt. Public tool, todo, usage,
message, and explicit reasoning-summary updates remain distinct from answer output.
Private ACP thought updates are discarded.

Terminal runs default to the runner-specific
`$XDG_STATE_HOME/agent-cat/tui/<runner-id>` directory (or
`~/.local/state/agent-cat/tui/<runner-id>`) unless `AGENT_CAT_STATE_DIR` is
explicitly set to an absolute path. Giving the same state root to the TUI and ext-pi enables read-only
cross-frontend discovery; no default is shared. macOS and
Linux are supported. The renderer provides bounded plain text, lightweight Markdown
line cues, status styling, and unified-diff styling without a tree-sitter dependency.
The requirement matrix and release results are recorded in
[`doc/tui-release-evidence.md`](doc/tui-release-evidence.md).

## The Pi extension

`ext-pi/` is a TypeScript extension that makes Pi the control plane for
agent-cat workflows. It performs no search for a runner. The trusted
`agentic-run` executables are named by absolute path in `AGENT_CAT_RUNNER` or
`AGENT_CAT_RUNNERS`. The extension reads their descriptors, collects inputs,
launches machine mode, reduces the event stream into a live monitor, delivers
controls, and keeps durable run references. Descriptor-v3 runners expose a
sanitized routing inspection. The extension offers a distinct routing-only target
with persona and concrete-alias choices, while explicit targets bypass routing.
It never parses YAML or receives secret values. Descriptor-v3 runners negotiate
protocol v2, shared frontend manifests, terminal result references, and public
progress. Descriptor-v1 and descriptor-v2 protocol-v1 runners retain their
existing launch flow. The `/wf`
command launches a workflow in the current Agent Deck session, and a family of
`/workflow-...` commands covers help, plan, status, monitoring, steering,
recovery, redirect, grants, lineage, and cancellation. The extension never
interprets a `RawProgram` or a `Plan`; agent-cat remains the only workflow
interpreter. `ext-pi/README.md` gives its configuration, commands, targets, and
security posture.

## Building and verifying

The Nix development shells are the only supported environments. Configure
direnv for the root, model, and conformance directories before running their
tools. The root environment supplies `CABAL_BUILDDIR` beneath `~/Products`.
The shared `test/cabal.sh` entry point passes that directory explicitly, uses
an isolated Cabal store, and disables package repositories. It builds against
the supplied dependencies without entering another shell or fetching packages:

```sh
direnv exec . test/cabal.sh build all
direnv exec . test/cabal.sh test all
(cd model && direnv exec . lake build)
(cd bisim && direnv exec . bash -c 'lake build && lake exe corpus-gen')
```

Never run two full model builds at once. The module
`model/Agentic/Core/DslFlagship.lean` proves its theorems by running the
checker inside the kernel, which takes minutes and several gigabytes of memory.
The conformance package excludes that module and builds in seconds.

The deterministic gates live beside the code that they check, and none of them
contacts a paid service:

```sh
direnv exec . ./bisim/ci/tier0.sh
direnv exec . env N=500 SEED=1 ./bisim/ci/tier1.sh
direnv exec . ./cli/ci/policies.sh
direnv exec . ./cli/ci/examples.sh
direnv exec . ./cli/ci/routing-config.sh
direnv exec . ./engine/acp/ci/acp.sh
direnv exec . ./engine/agent-deck/ci/deck.sh
direnv exec . ./tui/ci/tui.sh
```

The script `tier1.sh` requires a prebuilt oracle and refuses to build one. The
script `engine/acp/ci/route-live.sh` contacts real backends, and an operator
runs it only by explicit choice. The manual builds and checks in the root
shell:

```sh
direnv exec . make -C doc check
direnv exec . make -C doc check-haskell
```

The first command renders GNU Info and HTML in a temporary directory. It then
runs the checkers that hold the manual's examples, its reference coverage, its
prose, and the retained workflow record against the source. The second command
compiles the manual's example modules, compares its command-line transcripts
with fresh output, and verifies the compiler-derived member ledger. The
manual's chapter "Building and Verification" describes every gate.

## Documentation

The manual, `doc/agent-cat.texi`, is the reference: architecture and evidence
ceilings, the mathematical and operational models, the conformance wire
format, a tutorial, the authoring and runner references, diagnostics, and a
glossary. `doc/meaning-and-representation.md` gives the denotational argument
at length. Every source directory has a `README.md` and an `AGENTS.md`.
`doc/research/` holds the design records and research dossiers, indexed by its
own `README.md`. The persona-aware model-routing implementation and its contract
are documented in [`doc/model-routing-v2.md`](doc/model-routing-v2.md). The Brick
terminal interface and its implemented contracts are documented in
[`doc/tui-design.md`](doc/tui-design.md). Its routing pane consumes the sanitized
inspection contract.
Issue tracking is `obr` with prefix `acat`, whose tracked surface is
`doc/PLAN.org`; `AGENTS.md` describes the workflow.

## Acknowledgements

This work owes a real debt to Isaac Shapira and to two projects of his,
[agent-functor](https://gitlab.com/fresheyeball/agent-functor) and
[incite](https://github.com/jwiegley/incite). agent-functor showed what a
typed, lawful account of agent interaction can look like as working Haskell.
The workflows of incite are the direct ancestors of the authoring surface of
this repository and of several of its worked examples. Their review ladders,
their rosters of deliberately partial reviewers, and their grind loops treat
verification as a separate party. `workflow/extra/Isaac.hs` carries five of
them, ported and priced. More than the code, the stance
carried over. A workflow is a value worth reasoning about before it runs, and
an intelligent reviewer is built rather than prompted.
`doc/research/isaac-workflows.md` records what was taken, what was adapted, and
where this project chose differently.
