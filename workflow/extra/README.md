# workflow/extra

`agentic-workflow-extra` owns five Isaac/incite-derived workflows and their shared
authoring prompt library.

## Public API

`Workflow.Extra.Isaac` exposes the five canonical program values plus prompt text
used by CLI-owned deterministic fixtures.

## Dependencies and adjacent modules

The sole local dependency is `agentic-dsl`. CLI registers these values. No sibling
workflow, planner, cost, runtime, engine, extension, or bisim dependency is allowed.

## Build and test

```sh
nix develop path:../.. -c cabal build agentic-workflow-extra
./cli/ci/examples.sh
```

## Conventions

The serving references `balanced`, `review`, `reasoning`, and `coding` are
symbolic profile names; concrete examples live only in
[`cli/model-definitions.example.yaml`](../../cli/model-definitions.example.yaml). Keep
prompt text single-sourced. Registry, operator help, routing, and scripted
execution behavior stay in CLI.
