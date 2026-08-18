# agent-cat — a denotational design for agentic workflows

Meaning first. A workflow is given a mathematical meaning, and everything else is
derived from it: the syntax a person writes, the folds that classify and price a
program, the interpreter that runs it against a live agent, and a conformance
relation that holds a second implementation to the first. The method is Conal
Elliott's denotational design, taken literally.

The repository is now **two halves with one boundary between them**. Lean is the
verification spine: the mathematical space, the elaboration from raw syntax to a
plan that is well-typed by construction, the theorems about what that elaboration
can produce, and an oracle that emits observations. Haskell is the operational
half: the authoring surface a person actually writes, and the runner that puts
questions to real agents. The boundary is `RawProgram`-in — a first-order syntax
tree, never a string — and it is frozen, byte for byte, in `test/corpus/`.

## The Lean half — the verification spine

Lean 4.30.0 with Mathlib v4.30.0. `Agentic.lean` is the mathematical space and
imports only mathematics: the resource algebra, panels, traces and scopes, the
authoring words of `Surface`, and the rederivation kernel under `Agentic.Core` —
the question space and its worlds (`Question`, `World`, `Dlg`), the representation
(`Plan`), its meaning (`Denote`), the folds that classify and price a term
(`Level`, `Cost`), the commuting squares between the two (`Morphism`, `Alg`), and
the flagship workload (`HardenPatch`) with six theorems about its meaning.

Outside the root sit the things that are about a *program* rather than about the
space: the raw syntax and its elaboration (`Core.Dsl.Syntax`, `Core.Dsl.Check`,
`Core.Dsl`), the trusted base and the interpreter (`Exec`), the per-run
certificate (`Certify`), coverage and the bill as a number (`Report`), and the
renderings (`Explain`).

There is **no parser, no concrete syntax and no runtime here.** What Lean keeps
is what can be proved and what the port is measured against; the authoring
surface and the runner are Haskell's.

The flagship is kernel-checked. `Agentic/Core/DslFlagship.lean` holds the flagship
as a `RawProgram` — the term of record, and the very program frozen as corpus
entry `example-000` — and proves by `decide +kernel` that the checker accepts it,
that its level is `branch`, that its cost tree has nine leaves with a minimum of 5
and a maximum of 15, and that its transcript in four named worlds is the
hand-written `Harden.demo`'s. True by computation rather than by assertion.

The theorem the elaboration exists to make true is `Dsl.checkProgram_level_le`:
*every* program the checker accepts sits at or below the branch rung, so every
program has a finite cost tree, and every analysis downstream of the level fold
applies to every program there is.

## The conformance boundary

`lake exe conformance-oracle` is a line-delimited JSON process that checks and
observes `RawProgram`s and exercises the string layer. `test/corpus/` is 128 of
its request/reply pairs, committed — so Tier 0 runs with no Lean in the loop.

The corpus is **frozen**, and the requests in it are the specification.
`lake exe corpus-gen` reads each file, takes its request *verbatim*, puts it back
through the same `observe` and `stringOp` the oracle serves, and rewrites the
file with the fresh reply. (It once built the corpus from `.wf` sources; with no
parser and no `.wf` files there is nothing upstream of a request to start from,
and re-observation is both all that is possible and the whole of what mattered.)
**Regenerating is expected to be a no-op**: an empty `git status --short
test/corpus` afterwards is the statement that the elaboration, the cost algebra,
the interpreter and the trusted base still say exactly what the frozen
specification says they say. A diff is a change to the specification, reviewed as
one.

## The Haskell half — the authoring surface

`haskell/` holds the `Raw` syntax and its codec, the guards, the string layer, a
typed `Plan` with the same static folds, worlds and their two bills, the builder,
the `IO` interpreter, the ACP and `agent-deck` transports, and above them the
authoring surface a human writes. **That surface is ordinary Haskell** — no
splice, no bracket, no label, and no file format of its own. A bind is a Haskell
bind, a fenced prompt is a `[wf|…|]` with `{name}` holes and a layout rule, a
`define` is a Haskell binding, `W.do` is `QualifiedDo`, and
`result <- revising draft (atMost 2) \patch -> W.do` opens the review loop.
Both branches are Haskell's own — a `case` on the exported `Outcome`, and an `if`
reaching `ifThenElse` because an authoring module enables `RebindableSyntax`. The
end of `haskell/example/Example/Harden.hs`:

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
      Unsettled -> stop
```

`when` is the one-armed `if`: terminal, sealed by a `stop`, and printing the
identical `ifFlag` node. Two programs are written this way today — `harden`, the
flagship, and `hello` — and they are the values everything downstream reads.

## The runner — `agentic-run`

One executable, three verbs over those programs, from `haskell/`:

```sh
cabal run agentic-run -- plan harden [--raw]
cabal run agentic-run -- cost harden
cabal run agentic-run -- run  harden --scripted
cabal run agentic-run -- run  harden --engine acp [--adapter stub|claude|codex|PATH]
cabal run agentic-run -- run  harden --session <deck-id> [--binary PATH] [--poll MS]
```

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

Four scripts in `haskell/ci/` are the gates. `ci/tier0.sh` is the PR gate: it
runs the first two executables against the corpus as committed data, with **no
Lean in the loop at all**. `ci/acp.sh` and `ci/deck.sh` drive `agentic-run` end
to end against the two fixture doubles, `test/stub_adapter.py` and
`haskell/test/stub-deck.sh` — no Lean, no network, and what they pin is the part
of the runtime the corpus cannot reach: the poll loop, the staleness guard, the
named transport failures, the re-ask and the memo table observed from outside
the process. `ci/tier1.sh` is the nightly differential and the only gate that
wants Lean — as a **prebuilt** `conformance-oracle` binary, which it refuses to
build itself and refuses to skip over. That refusal is the one-build rule
(`connection.md` §3.9 — one Lean build at a time, machine-wide), and a Tier 1
that quietly degraded to Tier 0 is the failure the conformance program exists to
avoid.

## Building

The nix devShell is the only environment; `direnv allow .` wires it up.

```sh
nix develop                 # or: direnv exec . <command>
lake exe cache get          # Mathlib's objects — a cold miss is hours of elaboration
lake build                  # everything in defaultTargets
lake exe corpus-gen         # re-observe the frozen corpus; expect no diff
lake exe conformance-oracle # the oracle, on stdin/stdout
```

**Never run two Lean builds at once.** `Agentic/Core/DslFlagship.lean` dominates
the build — minutes of wall clock and several gigabytes, the kernel running the
checker, the cost algebra and the interpreter on a real program — and two at once
have exhausted 48 GB. Nothing else costs that: neither the oracle nor the corpus
generator imports the flagship, so `lake exe conformance-oracle` builds in
seconds, and an oracle build that hangs for minutes is the bug. The Haskell side
is independent, from `haskell/`:

```sh
nix develop -c cabal build all
nix develop -c cabal run agentic-run -- run harden --scripted
./ci/tier0.sh          # the PR gate: tier0 and tier1 over the frozen corpus
./ci/acp.sh; ./ci/deck.sh   # the runner against the two fixture doubles
./ci/tier1.sh          # nightly; wants ../.lake/build/bin/conformance-oracle built
```

## What was retired

This repository once carried a `.wf` language of its own — a concrete syntax, a
parser, a command line that planned, priced and ran a file, transports to ACP and
to `agent-deck`, and an MCP server that stepped a run by tool call. On
2026-08-18 the owner retired all of it in favour of the Haskell authoring
surface, and it was removed rather than deprecated. What the language leaves
behind is its contract, and the contract is the point: the frozen corpus under
`test/corpus/` still pins, byte for byte, exactly what the elaboration, the cost
algebra, the interpreter and the trusted base compute, and the flagship's
kernel theorems still hold — re-anchored to the `RawProgram` term, which is now
where the program is written down rather than a thing a parser produced. Git
history holds the rest.

## The documents

* `doc/HANDOFF.md` — the research record: what the project is for, how it reached
  its shape, what was decided, and what turned out false. It is a record and not
  a description of the present; its banner says which parts the retirement
  overtook. The papers beside it are `doc/meaning-and-representation.html` (what
  the two layers are and how the proofs bind them) and, for history only,
  `doc/design.html` and `doc/walkthrough.html`, which describe the superseded
  `Term` calculus.
* `doc/conformance-schema.md` — the wire format, and what the corpus pins on each
  of its three surfaces. `haskell/README.md` and `haskell/PORTING*.md` are the
  port.
* `doc/research/connection.md` — the design of record for the connection between
  the two implementations: why reimplementation-plus-conformance rather than
  extraction, FFI or a subprocess oracle, and, in §3, the boundary, the request
  schema and the corpus that are live today. The rest of `doc/research/` is the
  re-derivation and the dossiers that condemned the first calculus.

Issue tracking is `obr` (prefix `acat`; see `AGENTS.md` and `doc/PLAN.org`).
