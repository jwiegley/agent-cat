# cost

`cost/src` is the pure static cost interpreter of the `agentic` package. It
consumes an `Agentic.Plan.Plan` and computes the bag of request-count bills,
one per finite branch path, together with their minimum, maximum, and path
count, before execution. It performs no IO and does not inspect model
definitions, engines, runtime state, or answers.

## Public module

`Agentic.Cost` exports `costM`, which gives one possible request-count bill per
syntactic path, and `costSummary`, which gives the minimum fold, the maximum
fold, and the number of paths. Dollar or token pricing may be added only as a
further pure interpretation of public plan data.

## Dependencies

`plan` is the only local dependency, and `plan` depends on `dsl`. The CLI and the
private verification library depend on this directory.

## Build and test

```sh
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
./cli/ci/examples.sh
```

## Conventions

Interpret the existing plan rather than copying its AST. Keep results
deterministic and independent of any runtime realization. The values are pinned
by the Lean conformance corpus and by the examples gate.
