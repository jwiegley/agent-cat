# bisim

`bisim` is the test-only boundary where the Haskell implementation is checked
against the normative Lean model. It owns the Lean conformance codec and
oracle, the frozen corpus, the corpus generator, and the Haskell generators,
guards, oracle client, and frozen-vector runner. No production component
depends on it. Lean runs as a subprocess and is never linked into an
executable.

## Layout

`bisim/lean` is the Lake package `agentic-bisim`. It requires the model by a
local path, and it imports only the cheap closure of the model. It never
imports `Agentic.Core.DslFlagship` or `Agentic.Core.HardenPatch`. It builds
the `Conformance` library and the executables `conformance-oracle` and
`corpus-gen`. `bisim/corpus` holds the frozen vectors. `bisim/haskell/src` is
the internal `bisim-support` library of the `agentic` package. It exposes
`Agentic.Bisim` over the hidden modules `Agentic.Gen`, `Agentic.Guards`, and
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

`corpus-gen` must leave every corpus byte unchanged. A diff is a change to the
specification. The script `tier1.sh` requires the prebuilt oracle and refuses
to build it, which preserves the one-build rule for the expensive model. The
chapter "Conformance Boundary" of the manual specifies the wire format and
states what the corpus pins.

## Conventions

Lean observations are authoritative, and a Haskell comparison must not weaken
them. Keep the corpus frozen byte for byte unless the specification changes.
Keep the Haskell side of this directory limited to DSL and planner
dependencies. Cost and workflow definitions belong to the private verification
library. Use deterministic local processes only. Treat a transport error as a
failure of the harness and not as a conformance divergence.
