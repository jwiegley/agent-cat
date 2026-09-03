# engine/acp/claude

`engine/acp/claude/src` owns the selection of the Claude ACP adapter and
nothing else.

## Public module

`Agentic.Acp.Claude` exports `claudeAdapter` and its machine-local fallback `claudePin`. The adapter is found on `PATH` first and at the pinned path second.

## Dependencies

`engine/acp` is the sole local dependency, and the CLI selects the returned
`AdapterSpec`. The DSL, the planner, the runtime, workflow modules,
conformance support, the deck engine, and the other selectors are never
imported.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/acp/ci/acp.sh
```

## Conventions

Own only the Claude command and pin policy. Common ACP protocol behavior and
runtime policy belong to the parent directory and the runtime.
