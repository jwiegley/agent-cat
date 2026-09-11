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

## Complete observations and restoration

`SnapshotCheckpoint`, exported through `Agentic.Runtime`, denotes a complete
sequence-zero envelope prefix whose encoded JSON fits 64 MiB. Its version-1
object has exactly `checkpointVersion`, `representation`, `runId`,
`protocolVersion`, `lastSequence`, and `envelopes`. The representation is
`runtime-envelope-prefix`. The protocol and last sequence are null for an empty
prefix, while a nonempty prefix supplies its protocol and canonical decimal
last sequence. An empty checkpoint restores `initialRunSnapshot` for its run.

Capture validates every envelope through the existing protocol codecs and
`stepRunSnapshot`, retaining all original envelope values and the derived
snapshot. Each encoded envelope is limited to 1 MiB. The complete object,
including metadata, array delimiters, and commas, is limited to 64 MiB.
Overflow refuses the whole capture rather than retaining a shorter tail.
Decoding checks the outer byte bound before JSON parsing, refuses unknown or
missing fields, validates the prefix, and compares its computed boundary with
the declared boundary. Envelope values survive restoration, including the
whole last envelope used to distinguish exact and conflicting duplicates.
Original whitespace and key spelling are not retained.

For accepted prefixes, `checkpointSnapshot` equals the full shared fold, and
`appendSnapshotCheckpoint` applies the same fold to a validated suffix while
retaining the prefix. These are executable regression checks, not new formal
theorems. The representation does not cover arbitrary edited snapshot records
or every long history. `runSnapshotValue` and catalogue summaries remain
presentation formats and cannot decode as checkpoints.

Frontend IO version 2 adds only `read-run-checkpoint` and
`read-question-schema`, advertised alongside version 1. The former takes
`rootIdentity` and `runId` and returns run metadata with a nullable `checkpoint`.
Missing runtime evidence and empty journals yield null rather than a running
snapshot. `readRunRecordWithEnvelopesAt` captures the record and prefix from
one verified store read, tightening the journal read to 64 MiB before allocation.
Existing store readers retain their 512 MiB journal bound. The checkpoint and
the final helper reply have separate encoded-size checks, and either can refuse.
Version-1 replies and the two-MiB request and 64-MiB-plus-4096-byte reply limits
are unchanged. Catalogue enumeration refuses child 1001, counting corrupt and
non-run children, rather than returning a successful partial catalogue.

`read-question-schema` takes `rootIdentity`, `runId`, `occurrenceId`, and the
original `QuestionRef`. It returns `intent`, the full `question`, `codeName`,
and `answerSchema` through the existing private artifact verification. The
planning API `answerSchemaForObservationCode` decodes the actual stored code
and derives `answerJsonSchema` from its witness. Observation and public Ack
names are `receipt`, while authoring syntax uses `ack`. The new observation
adapter refuses the authoring spelling. Structured person/control numbers are
exact numerator and positive-denominator objects, including within arrays and
records. Model-response number schemas remain unchanged. Verdict extras retain
their existing decoder acceptance. The schema describes JSON values, while
runtime decoding and transport resource limits remain authoritative.

Question and result verification remains independent of journal health.
Neither a checkpoint nor an editor schema grants control or execution authority.
Read and encoded byte limits are not total heap limits, and a record capture is
not a transaction across the journal, manifests, and ownership files. The
contract does not establish physical authenticity or publication durability.

## Observation failures and cancellation

An exception from an event observer aborts execution without engine retry or
additional nested failure events on that exception path. The private observer
abort retains the original exception for the caller. An unsuccessful run
terminal can follow a partial nested history, but cannot repair a torn journal
write or establish that unrecorded events were delivered.

Cancellation has one sender and waits for registered worker finalization before
the runner returns. Further cancellation received during this wait does not
abandon cleanup or replace the original failure. An accepted whole-run
cancellation terminates its control reader, so a following EOF cannot replace
the accepted cancellation reason.

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
refusals, complete checkpoint restoration, suffix equivalence, and byte limits.
The policy gate also checks native version-2 queries, the complete catalogue
refusal, and bounded JSON Schema agreement with the existing answer decoder.
The two engine gates exercise the same runtime through neutral engines.

## Conventions

Treat engines as opaque values and never dispatch on their identity. Keep typed
translation, rendering, decoding and retry, fail-over, memoization,
scheduling, effects, and persistence here. Preserve the protocol versions,
private storage modes, ordering guarantees, and failure behavior. Public engine
progress is optional and distinct from answer bytes. Bound it and redact both
credential-shaped fields and exact selected credential values before the machine
event sink; never project private reasoning or manufacture updates
for an engine that supplied none.
