# Native frontend worker ownership

`Agentic.Manager.Worker` owns one configured native frontend session. It uses the
existing Runtime ProcessGroup, setup, prepared, envelope and control facilities.
It does not interpret workflows or grant request admission, review approval,
command acceptance, worker adoption, or permission to signal a stored PID.
The module remains internal to the manager server boundary.

## Construction and current policy

`withStartingFrontendWorker` takes the actual Store, current profile ID/revision
and a shared FrontendSetupRequest, and loans the actual opaque handle during
construction. `withFrontendWorker` uses this same scope and waits for native
preparation before its callback. It selects the current retained catalogue and typed
Selection through the associated Configuration. Setup invocation, target arguments,
person mode and workflow selection must agree with that trusted policy. The
native state root must be the Store-owned runs root. File inputs are checked
through Drafts' actual retained capture records and byte-verification operation,
not accepted merely because a pathname has a matching prefix.

A fresh capability query reuses Profile's existing process/query/validation owner.
It does not regenerate the catalogue revision. Configuration is checked again
across the actual process launch and association, but is not locked throughout
preparation, human review or execution. The selected immutable policy stays with
that worker. Later approval owners must compare the live worker and exact captured
context with their committed intent, rather than treating Selection or a prepared
ID as approval.

The manager invokes the configured executable with its ordered prefix followed
by `frontend`, an explicit cwd/environment and private stdin/stdout/stderr pipes.
It does not create fd3 in the running Haskell process. The real CLI proxy starts
its inner worker, and the existing pre-RTS bootstrap reserves fd3 before the RTS.
The shared Runtime frontend-owned environment list is unchanged. Profile validation
rejects those exact configured names, including empty values, before discovery or
launch. Other configured environment values remain unchanged.

## Store and process lifetime

Worker lifetime is separate from the short file-operation slot. Each registration
retains a Runtime private subroot and duplicate service lease. The absolute ceiling
is sixteen registrations across the Store, counting construction, preparation,
running and cleanup. This is not WM-013 admission and does not multiply per
profile or replace a smaller configured execution-reservation limit. No request,
reservation, preparation or runtime row is manufactured to satisfy this adapter.

A registration may construct only its two startup processes: the fresh capability
query and the frontend proxy. Their actual Runtime ProcessGroup tokens are attached
under protected construction before their pipes escape. A released registration
cannot construct another process. Store close atomically fences new registrations,
then stops and joins existing work outside registry/configuration/database locks.
The user callback and status observers do not have to finish before owned worker
shutdown can proceed.

The proxy retains its existing two-second inner cleanup grace. The outer worker
owner uses five seconds before final native KILL/reap. Final cleanup remains joined,
not an absolute OS IO deadline. ProcessGroup's completion is the authority for
cleanup, not a PID file or a copied exit code. The narrow Runtime correction now
propagates a stored Left completion instead of discarding it. An earlier TERM IO
error followed by positively confirmed final cleanup is recovered, while original
asynchronous exceptions remain distinguishable.

Primary action failure and cleanup evidence remain separate. A nonzero child exit
or callback exception does not imply unproven ownership when Runtime positively
confirms cleanup. If completion is absent or a published failure, the registration,
root, lease and configuration storage slot remain retained and new work is fenced.
A failed Store close cannot accidentally free them through an outer bracket.
The internal retry operation may recheck or terminate only the original retained
Runtime tokens. Published Left completion is never cleared to release the fence.
Some failures therefore require operator intervention or process exit. This is
fail-closed resource ownership, not the WM-019 recovery or graceful-drain service.

## Protocol phases and writes

The whole startup sequence has one thirty-second budget, including fresh capability
checking, launch and prepared-frame reception. A dedicated deadline remains active
even when the early owner never awaits preparation and retires on actual native
preparation. Profile keeps its existing bounded
capability-query contract. Prepared replies use maxFrontendReplyBytes with the
native terminating newline accounted for. Runtime envelopes use maxFrameBytes.
Setup and decision/control writes use their actual shared codecs and bounds.
These domains are not page sizes or interchangeable frame limits.

Preparation retains the native run/preparation identity without adding a synthetic
started event. Start and discard derive the decision ID only from the same opaque
live worker's prepared response. Phase checks reject repeated or out-of-order
consumption. No constructor, Generic or JSON operation recreates FrontendWorker.
A closed handle cannot write or signal. The low-level start operation is not an
approval decision. WM-014 must bind it to exact live review and committed intent.

One fail-fast writer serializes setup/decision/control bytes. A contending caller
receives WorkerWriterBusy without an attempted write or waiting queue. An actual
write has a five-second budget. Partial, failed or cancelled writes stop the owned
worker and never retry automatically. Writing a start or control frame does not
manufacture native acknowledgement, effect or terminal success.

## Event ingestion and observers

A dedicated reader validates UTF-8, shared native envelope shape, bound run identity
and contiguous native sequence. It preserves original newline-framed bytes. The
queue holds at most thirty-two frames and eight MiB of retained wire bytes. This
is not a hard decoded-heap bound. Full queues apply backpressure rather than drop
Runtime input. Producer cancellation, diagnostics draining and shutdown remain
independent of queue capacity.

Exactly one ingestion callback can hold the queue head. It is removed only after
that callback returns successfully. Exceptions or cancellation preserve the head
and propagate to that caller without closing worker pipes or automatically invoking
the callback again. This acknowledges only in-memory consumption. WM-015 still owns
durable commit, duplicate identity checks and commit-then-lost-reply ambiguity.
There is no replay/outbox implementation in this adapter.

Status observers do not consume that queue and cannot close its transport.
Validated queued data can be drained after native process completion while its
owner scope remains active. Scope closure refuses further consumption. Reported
process exit is separate from Runtime result evidence, and owner-requested shutdown
is not represented as a fabricated successful child exit.

Stderr is drained concurrently. At most 65536 bytes are retained privately, with
an explicit truncation flag, while draining continues. A long-running process is
not killed merely for exceeding a lifetime diagnostics byte count. Stderr is not
the lossless Runtime event channel and is not copied into public protocol DTOs.

## Verification and remaining owners

`manager/ci/workers.sh` builds actual Cabal targets with warnings as errors and runs
separate N1/N8 checks. Positive execution uses the real routing-fixed-point native
CLI fixture, including person controls and a real WM-011 assembled draft. Controlled
wrappers alter individual phase frames or pipe behavior around that same native
frontend. They are not alternate interpreters or providers.

Tests cover phase limits, malformed/truncated/invalid UTF-8 frames, exact correlated
controls, full-queue delivery and shutdown, observer/consumer cancellation, writer
contention/failure/timeout, diagnostics flooding, startup failure/cancellation,
registration capacity and Store-close ownership. Compiler controls use actual
Cabal package metadata and unrestricted constructor imports. The cleanup-failure
lane uses project-owned signal/completion seams with real native positive controls,
not libc, SQLite or VFS interposition. Published-failure retention is isolated in
an owned test process so its intentional retained descriptors end with that process.

The native proxy, stdin EOF and original ProcessGroup ownership establish only
the tested cleanup boundary. They do not contain arbitrary descendants that escape
supported process ownership or prove external provider cancellation. The
[admission owner](ADMISSION.md) retains these workers and reservations, while
WM-014 owns exact approval, WM-015 durable ingestion, WM-016 control semantics,
and WM-019 broader containment and safety supervision. No listener, deployment,
provider call, new workflow semantics, stored-worker adoption, SQLite confinement
experiment or release acceptance is claimed by this unit.
