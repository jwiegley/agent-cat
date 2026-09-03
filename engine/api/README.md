# engine/api

`engine/api/src` defines `Agentic.Engine`, the only interface that the runtime
and the concrete engines share. It contains neutral values for requests,
results, completion, failures, steering, lanes, and common model settings, and
it names no concrete transport.

## Public module

`Agentic.Engine` exposes the `Engine` type class. The class has one operation
that starts a logical conversation and one optional ordered lane. The runtime
translates typed plan requests into `EngineRequest` values, and an instance
returns raw `EngineResult` values. `ModelConfig` carries only the settings that
both current engines implement, which are the model, the thinking level, and
the maximum output. Symbolic profiles, routers, provider identity,
backend-specific options, and file loading remain in the CLI.

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
