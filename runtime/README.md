# runtime

`runtime/src` executes typed plans against any `Agentic.Engine.Engine`. It owns
scheduling, memoization, decoding and re-asking, recovery and fail-over, the
ordering and journaling of effects, generic routing, controls, the machine
protocol, persistence, and support for restart, resume, and fork. It also
executes the commands that a program authors.

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

## Neutral frontend transport

`Agentic.Runtime.Frontend.Protocol`, re-exported through `Agentic.Runtime`,
owns version-1 preparation, lineage, input-source, edit, start, discard,
prepared-reply, and capability data and codecs. Request parsing preserves the
native branches and refusal text. Initial sources remain literal text,
transport text, or a file reference, and replacement answers retain their exact
JSON values, including false and null. The codec neither reads a file nor
applies workflow-specific input capture rules.

The bounded encoders return JSON payloads without a newline. The existing
NDJSON adapter supplies framing and uses `readNdjsonFrame`. Request payloads
retain the shared two-mebibyte limit. The reply limit is 64 mebibytes plus 4096
bytes, including the terminating newline. Missing request invocation metadata
is omitted rather than encoded as null, while the prepared reply retains its
required nullable invocation field.

Prepared replies reuse descriptor, server, invocation, run-identity, and exact
plan parsing. `parseExactPlan` accepts an already decoded value without
serializing its opaque program again. Public policy remains an opaque object.
Transport validation does not prove that a reply matches the requested workflow,
trusted profile, captured input, or live worker, and stored identities and
invocations confer no execution authority. Adapters retain those checks.

Executable preparation closures, registry lookup, target selection, environment
handling, input capture, private control pipes, and the fd-3 bootstrap remain at
their existing CLI and runtime boundaries. The TUI consumes the shared
capability codec while retaining its own required-manifest and legacy-support
checks.

## Observation failures and cancellation

An exception from an event observer aborts execution without engine retry or
additional nested failure events on that exception path. The private observer
abort retains the original exception for the caller. An unsuccessful run
terminal can follow a partial nested history, but cannot repair a torn journal
write or establish that unrecorded events were delivered.

Cancellation has one sender and waits for registered worker finalization before
the runner returns. Further cancellation received during this wait does not
abandon cleanup or replace the original failure.

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

The policy gate drives the policy, control, lineage, and native frontend probes
through this runtime. It also sends real capability and prepared replies through
the shared codecs, sends encoded preparation and decision requests to live
scripted workers, and checks captured file bytes after source mutation. These
checks run with `GHCRTS=-N8`. The runtime contract suite tests codec round trips,
refusals, and byte limits. The two engine gates exercise the same runtime
through neutral engines.

## Conventions

Treat engines as opaque values and never dispatch on their identity. Keep typed
translation, rendering, decoding and retry, fail-over, memoization,
scheduling, effects, and persistence here. Preserve the protocol versions,
private storage modes, ordering guarantees, and failure behavior. Public engine
progress is optional and distinct from answer bytes. Bound it and redact both
credential-shaped fields and exact selected credential values before the machine
event sink; never project private reasoning or manufacture updates
for an engine that supplied none.
