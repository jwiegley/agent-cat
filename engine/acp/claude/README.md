# engine/acp/claude

`engine/acp/claude/src` owns only the selection of the Claude ACP adapter.

## Public module

`Agentic.Acp.Claude` exports `claudeAdapter` and its machine-local fallback
`claudePin`. The adapter is found on `PATH` first and at the pinned path second.

## Dependencies

`engine/acp` is the sole local dependency, and the CLI selects the returned
`AdapterSpec`. This directory never imports the DSL, the planner, the runtime,
workflow modules, conformance support, the deck engine, or another selector.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/acp/ci/acp.sh
```

## Conventions

Own only the Claude command and pin policy. Common ACP protocol behavior
belongs to the parent directory, and runtime policy belongs to the runtime.
