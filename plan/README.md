# plan

`plan/src` is the pure planner of the `agentic` package. It consumes the typed
structural representation from `dsl` and computes finite, deterministic
observations of it. It performs no IO and knows nothing about workflows by
name, runtime state, model definitions, or engines.

## Public modules

`Agentic.Plan` is the planner facade: the structural types together with the
static folds for level, size, question nodes, intents, tool executions, answer
codes, and schema requirements, and the plain-data records for operational
traces. `Agentic.Planning` is the integration facade used by the runtime and by
the conformance programs; it adds world interpretation and the exact value
codecs. `Agentic.Plan.Value`, `Agentic.World`, and `Agentic.Schema.Conformance`
are hidden implementation modules.

## Dependencies

`dsl` is the only local dependency. `cost`, `runtime`, `cli`, and the
conformance libraries depend on this directory. It never imports cost, runtime,
workflow modules, engines, the CLI, or conformance support.

## Build and test

```sh
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
./cli/ci/examples.sh
```

## Conventions

Interpret the existing typed AST and do not define a second representation.
Keep every operation total, deterministic, and free of side effects. Static
price interpretation belongs in `cost`. The fold results are pinned by the
corpus and by the examples gate, and a change to them is a specification change.
