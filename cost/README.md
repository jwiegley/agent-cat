# cost

`agentic-cost` is the pure static cost interpreter. It consumes an
`Agentic.Plan.Plan` and computes the request-count bag and its minimum, maximum,
and path count before execution. It performs no IO and does not inspect model
definitions, engines, runtime state, or answers.

## Public API

`Agentic.Cost` exports:

- `costM` — one possible request-count bill per finite branch path
- `costSummary` — minimum, maximum, and number of paths

Dollar or token pricing may be added only when it remains a pure interpretation
of public plan data; it must not discover runtime or engine state.

## Dependencies

```text
cost -> plan -> dsl
bisim -> cost
cli -> cost
```

`agentic-plan` is the only local dependency.

## Build

```sh
nix develop path:.. -c cabal build agentic-cost
```

## Conventions

- Interpret the existing plan; never copy its AST.
- Keep results deterministic and independent of runtime realization.
- Preserve values pinned by Lean conformance and the example gate.
