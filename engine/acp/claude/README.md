# engine/acp/claude

`agentic-acp-claude` owns Claude ACP adapter selection.

## Public API

`Agentic.Acp.Claude` exports `claudeAdapter` and its PATH-fallback `claudePin`.

## Dependencies and adjacent modules

Its sole local dependency is `agentic-acp`; CLI selects the returned `AdapterSpec`.
No DSL, plan, runtime, workflow, bisim, deck, or other selector dependency is allowed.

## Build and test

```sh
nix develop path:../../.. -c cabal build agentic-acp-claude
./engine/acp/ci/acp.sh
```

## Conventions

Own only Claude command/pin policy and preserve PATH-first, pin-second resolution.
