# cost

`cost/src` is the pure static cost interpreter of the `agentic` package. It
consumes an `Agentic.Plan.Plan` and computes the bag of request-count bills,
with one bill for each finite branch path. It also computes the minimum, the
maximum, and the number of paths, and it does all of this before execution. It
performs no IO, and it does not inspect model definitions, engines, runtime
state, or answers.

## Public module

`Agentic.Cost` exports two functions. `costM` gives one possible request-count
bill for each syntactic path. `costSummary` gives the minimum fold, the maximum
fold, and the number of paths. A dollar or token price can be added later only
as a further pure interpretation of public plan data.

## Dependencies

`plan` is the only local dependency, and `plan` depends on `dsl`. The CLI and
the private verification library depend on this directory.

## Build and test

```sh
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
./cli/ci/examples.sh
```

## Conventions

Interpret the existing plan rather than copy its tree. Keep results
deterministic and independent of any runtime realization. The Lean conformance
corpus and the examples gate pin the values.
