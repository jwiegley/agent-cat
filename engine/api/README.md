# engine/api

`engine/api/src` defines `Agentic.Engine`, the only interface shared by the
runtime and the concrete engines. It contains neutral request, result,
completion, failure, steering, lane, and common model-setting values, and it
names no concrete transport.

## Public module

`Agentic.Engine` exposes the `Engine` typeclass, which has one logical-start
operation and one optional ordered lane. The runtime translates typed plan
requests into `EngineRequest` values, and an instance returns raw
`EngineResult` values. `ModelConfig` carries only the settings both current
engines implement: model, thinking level, and maximum output. Symbolic
profiles, routers, provider identity, backend-specific options, and file
loading remain in the CLI.

## Dependencies

This directory imports no other agent-cat directory. The runtime, the ACP
engine, and the agent-deck engine depend on it.

## Build and test

```sh
nix develop path:. -c cabal test engine-api-test
```

The test suite drives a deterministic fake engine through the complete public
contract.

## Conventions

Add only capabilities that every supported engine shares. Typed planning and
runtime policy stay above this interface, and concrete wire detail stays below
it.
