# engine

`engine` contains concrete execution transports behind the neutral API. Runtime
translates plans and owns decoding, retries, failover, memoization, and scheduling;
engines own connection, protocol, permission, completion evidence, and model-setting
application.

## Scope and public API

This container has no code API. Its implemented children expose:

- [`api`](api): `Agentic.Engine`
- [`acp`](acp): `Agentic.Acp` and Claude/Codex/Droid selector packages
- [`agent-deck`](agent-deck): `Agentic.AgentDeck`

## Dependencies and adjacent modules

```text
runtime -> engine/api
engine/acp/* -> engine/acp -> engine/api
engine/agent-deck -> engine/api
cli -> concrete engines
```

Concrete engines never import DSL, plan, runtime, CLI, workflows, bisim, or one
another.

## Build and test

```sh
nix develop path:.. -c cabal build agentic-engine agentic-acp agentic-agent-deck
./engine/acp/ci/acp.sh
./engine/agent-deck/ci/deck.sh
```

## Conventions and future boundary

Use only capabilities shared through `Agentic.Engine`; keep engine-specific details
inside their child. MCP is a documented future child, but no `engine/mcp` directory,
package, or placeholder exists until a working implementation is added.
