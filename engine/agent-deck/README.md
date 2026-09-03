# engine/agent-deck

`engine/agent-deck/src` adapts an existing agent-deck session to
`Agentic.Engine`. It owns the invocation of the agent-deck command, private
message files, polling, liveness, protection against stale replies, metadata
preflight, timeouts, and transport errors.

## Public module

`Agentic.AgentDeck` is the sole facade of this directory. Before each question,
the engine records the timestamp of the output that is already present. It
sends the rendered question through a message file with mode 0600, polls the
session until the session is idle, and accepts a reply only when newer output
has appeared. agent-deck reports no ACP-style stop reason, so the engine
reports completion as unverified rather than infer it. `DeckModelConfig` adds
the provider identity that agent-deck reports to the common `ModelConfig`. The
CLI rejects ACP-only profile options before it invokes this adapter.

## Dependencies

`engine/api` is the sole local dependency. The CLI depends on this directory,
and the runtime never imports it.

## Build and test

```sh
nix develop path:. -c cabal build all
./engine/agent-deck/ci/deck.sh
```

The gate drives `test/stub-deck.sh`, a deterministic double of agent-deck, and
it requires no live session.

## Conventions

Preserve the guarantees about polling, staleness, private files, timeouts, and
cleanup, and preserve the honest completion limits. Return raw results, because
the runtime owns decoding, retry, fail-over, and scheduling.
