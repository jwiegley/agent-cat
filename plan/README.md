# plan

`plan/src` is the pure planner of the `agentic` package. It consumes the typed
structural representation from `dsl` and computes finite, deterministic
observations of that representation. It performs no IO. It knows nothing about
workflows by name, runtime state, model definitions, or engines.

## Public modules

`Agentic.Plan` is the planner facade. It exposes the structural types and the
static folds for level, size, question nodes, intents, tool executions, answer
kinds, and schema requirements. It also exposes the plain-data records for
operational traces. `Agentic.Planning` is the integration facade that the
runtime and the conformance programs use, and it adds world interpretation and
the exact value codecs. The modules `Agentic.Plan.Value`, `Agentic.World`, and
`Agentic.Schema.Conformance` are hidden implementation modules.

## Dependencies

`dsl` is the only local dependency. The directories `cost`, `runtime`, `cli`,
and the conformance libraries depend on this directory. This directory never
imports cost, runtime, workflow modules, engines, the CLI, or conformance
support.

## Build and test

```sh
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
./cli/ci/examples.sh
```

## Conventions

Interpret the existing typed tree, and do not define a second representation.
Keep every operation total, deterministic, and free of side effects. Static
price interpretation belongs in `cost`. The corpus and the examples gate pin
the fold results, so a change to them is a specification change.
