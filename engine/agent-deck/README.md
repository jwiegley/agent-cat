# engine/agent-deck

`agentic-agent-deck` adapts an existing agent-deck session to `Agentic.Engine`. It
owns command invocation, private message files, polling, liveness, stale-reply
protection, metadata preflight, timeout, and transport errors.

## Public API

`Agentic.AgentDeck` is the sole facade. Agent-deck cannot verify ACP-style stop
reasons and therefore reports completion as unverified. `DeckModelConfig` adds the
provider identity reported by deck to the common `ModelConfig`; CLI rejects ACP-only
profile options before invoking this adapter.

## Dependencies and adjacent modules

```text
engine/agent-deck -> engine/api
cli -> engine/agent-deck
runtime -> engine/api (never agent-deck)
```

`agentic-engine` is the sole local dependency.

## Build and test

```sh
nix develop path:../.. -c cabal build agentic-agent-deck
./engine/agent-deck/ci/deck.sh
```

## Conventions

Preserve polling, staleness, private-file, timeout, cleanup, and honest completion
limits. Return raw results; runtime owns decoding, retry, failover, and scheduling.
