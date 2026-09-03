# runtime

`runtime/src` executes typed plans against any `Agentic.Engine.Engine`. It owns
scheduling, memoization, decoding and re-asking, recovery and fail-over, effect
ordering and journaling, generic routing, controls, the machine protocol,
persistence, restart, resume, and fork support, and the execution of
program-authored commands.

## Public modules

`Agentic.Runtime` is the main facade. `Agentic.Runtime.Facts` is a narrow
Text-only facade for validating and presenting the facts a host supplies about
its run; it has no dependency on the DSL or on a concrete engine. Hosts such as
the CLI import it, while a workflow names a run fact through an ordinary
`input` and imports nothing from this directory. The seven implementation
modules, `Agentic.Exec`, `Agentic.Shell`, and the `Control`, `Machine`,
`Protocol`, `Route`, and `Store` modules under `Agentic.Runtime`, are hidden by
the Cabal file. `Agentic.Runtime.Protocol` fixes the versions of the process
protocols: descriptor version 2, machine protocol version 1, and store version 1.

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

Treat engines as opaque values and never dispatch on their identity. Keep typed
translation, rendering, decoding and retry, fail-over, memoization,
scheduling, effects, and persistence here. Preserve the protocol versions,
private storage modes, ordering guarantees, and failure behavior.
