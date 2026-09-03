# engine/agent-deck

`engine/agent-deck/src` adapts an existing agent-deck session to
`Agentic.Engine`. It owns the agent-deck command invocation, private message
files, polling, liveness, protection against stale replies, metadata
preflight, timeouts, and transport errors.

## Public module

`Agentic.AgentDeck` is the sole facade. Before each question the engine records
the timestamp of the output already present, sends the rendered question
through a mode-0600 message file, polls the session until it is idle, and
accepts a reply only when newer output has appeared. agent-deck reports no
ACP-style stop reason, so the engine reports completion as unverified rather
than inferring it. `DeckModelConfig` adds the provider identity that agent-deck
reports to the common `ModelConfig`; the CLI rejects ACP-only profile options
before this adapter is invoked.

## Dependencies

`engine/api` is the sole local dependency. The CLI depends on this directory,
and the runtime never imports it.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/agent-deck/ci/deck.sh
```

The gate drives `test/stub-deck.sh`, a deterministic agent-deck double, and
requires no live session.

## Conventions

Preserve the polling, staleness, private-file, timeout, and cleanup guarantees
and the honest completion limits. Return raw results; the runtime owns
decoding, retry, fail-over, and scheduling.
