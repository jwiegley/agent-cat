# engine/acp/codex

`agentic-acp-codex` owns Codex ACP adapter selection.

## Public API

`Agentic.Acp.Codex` exports `codexAdapter` and its PATH-fallback `codexPin`.

## Dependencies and adjacent modules

Its sole local dependency is `agentic-acp`; CLI selects the returned `AdapterSpec`.
No DSL, plan, runtime, workflow, bisim, deck, or other selector dependency is allowed.

## Build and test

```sh
nix develop path:../../.. -c cabal build agentic-acp-codex
./engine/acp/ci/acp.sh
```

## Conventions

Own only Codex command/pin policy and preserve PATH-first, pin-second resolution.
