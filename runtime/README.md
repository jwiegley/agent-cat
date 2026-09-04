# runtime

`runtime/src` executes typed plans against any `Agentic.Engine.Engine`. It owns
scheduling, memoization, decoding and re-asking, recovery and fail-over, the
ordering and journaling of effects, generic routing, controls, the machine
protocol, persistence, and support for restart, resume, and fork. It also
executes the commands that a program authors.

## Public modules

`Agentic.Runtime` is the main facade. `Agentic.Runtime.Facts` is a narrow
Text-only facade that validates and presents the facts a host supplies about
its run, and it has no dependency on the DSL or on a concrete engine. Hosts such
as the CLI import it. A workflow names a run fact through an ordinary `input`
and imports nothing from this directory. The Cabal file hides the seven
implementation modules, which are `Agentic.Exec`, `Agentic.Shell`, and the
`Control`, `Machine`, `Protocol`, `Route`, and `Store` modules under
`Agentic.Runtime`. `Agentic.Runtime.Protocol` fixes the versions of the process
protocols. The descriptor is version 3, the machine protocol is version 1, and
the store format is version 1. Descriptor version 3 adds routing and negotiation
capabilities without changing the version-1 machine stream.

## Dependencies

The runtime imports `plan` and `engine/api` only, and `plan` brings `dsl`. No
concrete engine, workflow module, CLI module, or conformance module is imported
here. The CLI depends on this directory.

## Build and test

```sh
nix develop path:. -c cabal build all
./cli/ci/policies.sh
./engine/acp/ci/acp.sh
./engine/agent-deck/ci/deck.sh
```

The policy gate drives the policy, control, and lineage probes through this
runtime. The two engine gates exercise the same runtime through neutral engines.

## Conventions

Treat engines as opaque values, and never dispatch on their identity. Keep
typed translation, rendering, decoding and retry, fail-over, memoization,
scheduling, effects, and persistence here. Preserve the protocol versions, the
private storage modes, the ordering guarantees, and the failure behavior.
