# plan

`agentic-plan` is the pure planner for agent-cat workflows. It consumes the
typed structural representation from `agentic-dsl` and computes finite,
deterministic observations of that representation. It performs no IO and knows
nothing about workflows by name, runtime state, model definitions, or engines.

## Public API

`Agentic.Plan` is the planner facade: structural types plus static folds for
level, size, question nodes, intents, tool executions, answer codes, and schema
requirements. `Agentic.Planning` is the pure integration facade used by runtime
and conformance; it exposes world interpretation and exact value codecs.

`Agentic.Plan.Value`, `Agentic.World`, and `Agentic.Schema.Conformance` are hidden
implementation modules. Operational trace records remain plain data, not execution
behavior.

## Dependencies

```text
plan -> dsl
cost -> plan
runtime -> plan
bisim -> plan
cli -> plan
```

`agentic-dsl` is the only local dependency. `plan` must never import cost,
runtime, workflow packages, engines, CLI, extensions, or bisimulation support.

## Build

```sh
nix develop path:.. -c cabal build agentic-plan
```

## Conventions

- Interpret the existing typed AST; do not define a second representation.
- Keep every operation total, deterministic, and side-effect free.
- Put static price interpretation in `cost`, not here.
- Preserve fold results pinned by the corpus and example gates.
