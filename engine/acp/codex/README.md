# engine/acp/codex

`engine/acp/codex/src` owns only the selection of the Codex ACP adapter.

## Public module

`Agentic.Acp.Codex` exports `codexAdapter` and its machine-local fallback
`codexPin`. The adapter is found on `PATH` first and at the pinned path second.

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

Own only the Codex command and pin policy. Common ACP protocol behavior
belongs to the parent directory, and runtime policy belongs to the runtime.
