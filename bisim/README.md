# bisim

`bisim` is the test-only agreement boundary between the normative Lean model and
the Haskell library. It owns the Lean conformance codec/oracle, frozen corpus,
corpus generator, Haskell generators, guards, oracle client, and frozen-vector
runner. Cost/workflow-dependent observation drivers are private CLI integration tests.
No production package depends on this module.

## Public test API

The Haskell package exposes one facade, `Agentic.Bisim`, over its hidden
generator, guard, and oracle modules. Its `tier0` executable replays frozen vectors without Lean.
CLI's private `verification` component assembles full observations and owns the
`tier1` and live `bisim` executables without widening this package's dependencies.

The Lean package defines `Conformance`, `conformance-oracle`, and `corpus-gen`.
It consumes [`../model`](../model) by a local Lake dependency and deliberately
does not import the expensive flagship or harden modules.

## Dependencies

```text
bisim -> model       (Lake path dependency, tests only)
bisim -> dsl + plan
cli:verification -> bisim + cost + dsl + plan  (private test library)
cli:tier1 -> cli:verification + dsl + plan + workflow/{core,example}
cli:bisim -> cli:verification + bisim + dsl + plan
```

Nothing below this test layer imports `bisim`. Lean is invoked as a subprocess,
never linked into a production executable.

## Build and test

From the repository root:

```sh
nix develop path:./model -c bash -c 'cd bisim && lake build'
nix develop path:. -c cabal build agentic-bisim
nix develop path:. -c cabal run tier0 -- bisim/corpus
nix develop path:. -c cabal run exe:bisim -- \
  --oracle bisim/.lake/build/bin/conformance-oracle --seed 1 --n 500
```

`lake exe corpus-gen` must leave all corpus bytes unchanged. Never run two full
model builds concurrently, and never replace deterministic fixtures with live or
paid engines.

## Conventions

- Lean observations are authoritative; Haskell comparisons must not weaken them.
- Keep corpus requests and replies byte-frozen unless the specification changes.
- Let CLI's private verification component consume production cost/workflow
  definitions; never add those dependencies to `agentic-bisim`.
- Transport errors are not conformance divergences.
