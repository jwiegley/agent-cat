# engine/api

`agentic-engine` is the only interface shared by runtime and concrete engines. It
contains neutral request, result, completion, failure, steering, lane, and common
model-setting values. It names no concrete transport.

## Public API

`Agentic.Engine` is the sole exposed module. Its `Engine` typeclass has one
logical-start operation and one optional ordered lane. Runtime translates typed
Plan requests into `EngineRequest`; instances return raw `EngineResult` values.
`ModelConfig` contains only settings implemented by both current engines: model,
thinking, and maximum output. Symbolic profiles, routers, provider identity,
backend-specific options, and file loading remain CLI-owned.

## Dependencies and adjacent modules

This package imports no other agent-cat package.

```text
runtime -> engine/api
engine/acp -> engine/api
engine/agent-deck -> engine/api
```

## Build and test

```sh
nix develop path:../.. -c cabal test agentic-engine
```

The test implements a deterministic fake engine across the complete public contract.

## Conventions

Add only engine-common capabilities. Keep typed planning and runtime policy above
this API, and concrete wire/protocol details below it.
