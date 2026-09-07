# engine

`engine` holds the concrete execution transports behind one neutral interface.
The runtime translates plans and owns decoding, retries, fail-over,
memoization, and scheduling. An engine owns its connection, its protocol,
permission, completion evidence, and the application of model settings.

## Layout

This directory has no code of its own. `api` defines `Agentic.Engine`, the
interface that the runtime and every transport share. `acp` implements the
Agent Client Protocol as `Agentic.Acp`, and its children hold the selector
modules for Claude, Codex, and Factory Droid. `agent-deck` implements
`Agentic.AgentDeck`, which joins a session that agent-deck already owns.

## Dependencies

```text
runtime -> engine/api
engine/acp/{claude,codex,droid} -> engine/acp -> engine/api
engine/agent-deck -> engine/api
cli -> concrete engines
```

Concrete engines never import the DSL, the planner, the runtime, the CLI,
workflow modules, conformance support, or one another.

## Build and test

```sh
nix develop path:. -c cabal build all
nix develop path:. -c cabal test engine-api-test
./engine/acp/ci/acp.sh
./engine/agent-deck/ci/deck.sh
```

## Conventions

Use only the capabilities that `Agentic.Engine` shares, and keep
engine-specific detail inside the child that owns it. An MCP transport is a
documented future child of this directory. No `engine/mcp` directory, package,
or placeholder exists until a working implementation is added.
