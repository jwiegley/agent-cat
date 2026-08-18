# agent-cat — a denotational design for agentic workflows

Meaning first. A workflow is given a mathematical meaning, and everything else is
derived from it: the language a person writes, the folds that classify and price a
program, the interpreter that runs it against a live agent, and a second
implementation in another language held to the first by conformance. The method is
Conal Elliott's denotational design, taken literally.

The formalization is Lean 4.30.0 with Mathlib v4.30.0. `Agentic.lean` is the
mathematical space and imports only mathematics: the resource algebra, panels,
traces and scopes, and the rederivation kernel under `Agentic.Core` — the question
space and its worlds (`Question`, `World`, `Dlg`), the representation (`Plan`), its
meaning (`Denote`), the folds that classify and price a term (`Level`, `Cost`), the
commuting squares between the two (`Morphism`, `Alg`). The runtime stratum — the
checked language (`Core.Dsl.*`), the interpreter and its per-run certificate
(`Exec`, `Certify`), two transports (`Acp`, `Deck`), the renderings (`Explain`), the
MCP server (`Mcp`) — is outside the root, because a transport is not semantics.

The flagship is kernel-checked. `Agentic/Core/DslFlagship.lean` includes
`example/harden.wf` from the file rather than copying it and proves by
`decide +kernel` that the checker accepts it, that its level is `branch`, that its
cost tree has nine leaves with a minimum of 5 and a maximum of 15, and that its
transcript in four named worlds is the hand-written `Harden.demo`'s — true by
computation rather than by assertion.

## The language

A `.wf` program binds answers from addressees — `model`, `tool`, `person` — under a
checker that refuses more than it accepts. A fenced prompt splices earlier answers
by `{name}`, `define` names a literal, `panel` puts one question to several models
and folds their verdicts, `revising … at most n amendments` is a bounded review loop
that settles or does not, and `case`, `if` and `stop` are terminal, each arm being
the rest of the workflow. The level fold (`batch ≤ pipeline ≤ branch ≤ dynamic`)
says which analyses apply; the cost fold prices every path before a question goes
out. From `example/harden.wf`:

````
workflow {

  guide <- ask tool "cat"
      "Write out the house style guide, at most four short lines."

  draft <- ask model "author" served by "deep" ```
      Draft a patch satisfying:
      {spec}
      Reply with a unified diff only.
  ```

  result <- revising draft as patch, at most 2 amendments {
````

`doc/dsl-guide.html` walks that program line by line; `example/` also holds
`hello.wf`, an imported-module pair, and one deliberately ill-typed program.

## The command line

One front end, so no subcommand can diagnose a program differently from another,
and none computes anything of its own: `plan` and `cost` are `Explain`'s two
renderings and `run` is `Certify`'s `execCertifiedIO`.

```sh
lake exe agent-cat plan example/harden.wf
lake exe agent-cat cost example/harden.wf
lake exe agent-cat run  example/harden.wf --adapter-arg --refuse
printf 'yes\n' | lake exe agent-cat run example/harden.wf --adapter claude
lake exe agent-cat run  example/harden.wf --engine deck --session <id|title>
```

`--engine acp` (the default) starts an ACP adapter of its own — `stub`, `claude`,
`codex` or a path — and speaks the protocol to it; `--engine deck` sends to a live
`agent-deck` session somebody else started and is watching. `--session ID` is the
existing session a run happens in, and what an ID names is the engine's business:
under `acp` the transcript is continued **in place**, with no lock, so close its
interactive owner first — `--fork-session` reads it and never writes. Every run is
certified against its own logged table and its bill checked to be a leaf of the tree
`cost` printed. `lake exe workflow_mcp` is the same stack behind four MCP tools.

## The Haskell implementation

`haskell/` is the operational half: the `Raw` syntax and its codec, the guards, the
string layer, a typed `Plan` with the same static folds, worlds and their two bills,
the builder, the `IO` interpreter, an `agent-deck` transport, and above them the
authoring surface a human writes. That surface is ordinary Haskell — no splice, no
bracket, no label. A bind is a Haskell bind, a fenced prompt is a `[wf|…|]` with the
same `{name}` holes and layout rule, a `define` is a Haskell binding, `W.do` is
`QualifiedDo`, and `result <- revising draft (atMost 2) \patch -> W.do` opens the
review loop. Both branches are Haskell's own — a `case` on the exported `Outcome`,
and an `if` reaching `ifThenElse` because an authoring module enables
`RebindableSyntax`. The end of `haskell/example/Example/Harden.hs`:

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

`when` is the one-armed `if`: terminal, sealed by the `stop` a `.wf` arm block's
closing brace is, and printing the identical `ifFlag` node.

**Conformance.** Lean is normative, and the Haskell asks to be believed on no
authority of its own. `lake exe conformance-oracle` emitted 128 request/reply
vectors, frozen under `test/corpus/`; `tier0` replays every one with no Lean in the
loop, `tier1` rebuilds twenty-one checked entries from their surface source and
compares the whole reply — printed program, folds, ask counts, one trace and two
bills per world — and `bisim` draws fresh programs and worlds against the live
oracle. Regenerating the corpus is an explicit, reviewed act: the diff is a change to
the specification. The gates run no Lean at all, which is the one-build rule
(`connection.md` §3.9 — one Lean build at a time, machine-wide).

## Building

The nix devShell is the only environment; `direnv allow .` wires it up.

```sh
nix develop                 # or: direnv exec . <command>
lake exe cache get          # Mathlib's objects — a cold miss is hours of elaboration
lake build                  # everything in defaultTargets
lake exe dsl_smoke          # and cli_smoke, mcp_smoke, exec_smoke, acp_smoke, deck_smoke
```

**Never run two Lean builds at once.** `Agentic/Core/DslFlagship.lean` dominates the
build — minutes of wall clock and several gigabytes, the kernel running the checker,
the cost algebra and the interpreter on a real program — and two at once have
exhausted 48 GB. Nothing else costs that: no executable imports the flagship, so
`lake exe agent-cat` builds from cold in seconds, and a CLI build that hangs for
minutes is the bug. The Haskell side is independent, from `haskell/`:

```sh
nix develop -c cabal build all
nix develop -c cabal run tier0   # and tier1; ./ci/tier0.sh and ./ci/deck.sh are the gates
nix develop -c cabal run agentic-run -- run harden --scripted
```

## The documents

* `doc/HANDOFF.md` — the research record: what the project is for, how it reached its
  shape, what was decided, and what turned out false. The papers are `design.html`,
  `meaning-and-representation.html`, `walkthrough.html` and `dsl-guide.html` beside
  it; the MCP server is `doc/mcp.md`.
* `doc/conformance-schema.md` — the wire format, and what the corpus pins on each of
  its three surfaces. `haskell/README.md` and `haskell/PORTING*.md` are the port.
* `doc/research/` — the design records, the dossiers that condemned the first
  calculus included; `doc/research/dsl-redesign/connection.md` is the design of
  record for the connection between the two implementations.

Issue tracking is `obr` (prefix `acat`; see `AGENTS.md` and `doc/PLAN.org`).
