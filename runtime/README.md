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
`input` and imports nothing from this directory. The implementation modules are
hidden by the Cabal file. `Agentic.Runtime.Protocol` fixes the process contracts:
descriptor versions 2 and 3, machine protocols 1 and 2, control protocols 1 and
2, and store formats 1 and 2. Version 2 adds private result and question
artifacts, local person answering, and typed public attempt progress.

`Agentic.Runtime.PrivateRoot` supplies the retained, effective-user-owned, private
directory contract used by both the runtime store and terminal frontend. File
publication uses descriptor-relative exclusive creation and rename or link operations;
no pathname-based permission repair or temporary-file overwrite is permitted.
When `AGENT_CAT_STATE_ANCHOR` is present, it contains a JSON array of the absolute
root path, device number, and inode number captured by the parent. The child reopens
and validates that identity before confined input, lineage, or store access. The
identity is not an authorization token and does not relax ownership or mode checks.

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
private storage modes, ordering guarantees, and failure behavior. Public engine
progress is optional and distinct from answer bytes. Bound it and redact both
credential-shaped fields and exact selected credential values before the machine
event sink; never project private reasoning or manufacture updates
for an engine that supplied none.
