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

`EngineUpdate` keeps streamed answer chunks separate from optional public message,
tool, todo, usage, and explicitly public reasoning-summary updates. An engine may
emit none. An engine may also supply exact values through
`enginePublicRedactionValues`; these are private filtering context, not updates. The
runtime alone validates, bounds, redacts, persists, or omits presentation facts;
they do not alter `EngineResult`.

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
