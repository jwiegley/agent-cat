# bisim

`bisim` is the test-only agreement boundary between the normative Lean model
and the Haskell implementation. It owns the Lean conformance codec and oracle,
the frozen corpus, the corpus generator, and the Haskell generators, guards,
oracle client, and frozen-vector runner. No production component depends on
it, and Lean is invoked as a subprocess rather than linked into any executable.

## Layout

`bisim/lean` is the Lake package `agentic-bisim`. It requires the model by a
local path, deliberately imports only the cheap closure of the model and never
`Agentic.Core.DslFlagship` or `Agentic.Core.HardenPatch`, and builds the
`Conformance` library and the executables `conformance-oracle` and
`corpus-gen`. `bisim/corpus` holds the frozen vectors. `bisim/haskell/src` is
the internal `bisim-support` library of the `agentic` package, which exposes
`Agentic.Bisim` over the hidden `Agentic.Gen`, `Agentic.Guards`, and
`Agentic.Oracle`. `bisim/haskell/tier0` is the `tier0` executable, which
replays the frozen vectors without Lean. The `tier1` and live `bisim`
executables need cost and workflow definitions, so they live under
`cli/verification` with the private `verification` library.

## Dependencies

```text
bisim/lean -> model                        (Lake path dependency, tests only)
bisim-support -> dsl, plan
cli/verification -> bisim-support, cost, dsl, plan
```

## Build and test

```sh
nix develop path:./model -c bash -c 'cd bisim && lake build && lake exe corpus-gen'
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
N=500 SEED=1 ./bisim/ci/tier1.sh
```

`corpus-gen` must leave every corpus byte unchanged; a diff is a change to the
specification. `tier1.sh` requires the prebuilt oracle and refuses to build it,
which preserves the one-build rule for the expensive model. The manual's
"Conformance Boundary" chapter specifies the wire format and states what the
corpus pins.

## Conventions

Lean observations are authoritative, and a Haskell comparison must not weaken
them. Keep the corpus byte-frozen unless the specification changes. Keep the
Haskell side of this directory limited to DSL and planner dependencies; cost
and workflow definitions belong to the private verification library. Use
deterministic local processes only, and treat transport errors as failures of
the harness rather than as conformance divergences.
