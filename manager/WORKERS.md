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
approval decision. The approval owner binds it to exact live review and committed intent.

A start or discard has two steps. `encodeWorkerStart` and `encodeWorkerDiscard`
build the decision frame for the current preparation with
`encodeFrontendDecisionFor` and write nothing. `sendWorkerStart` and
`sendWorkerDiscard` take the frame bytes. Under the serialized writer they check
again that the worker is in the prepared phase and that the frame names the
approval identifier of the current preparation. They decode the bytes with
`decodeFrontendDecisionFor`, require that the decision re-encodes to the same
bytes, and only then write them. A frame that fails any check fails with
`WorkerConfiguration`, and nothing is written. Between the two steps the owner
records the frame in the manager log as a `relay` and passes the frame decoded
from the appended record to the send step, as the
[admission contract](ADMISSION.md#manager-log-relays) describes.
`startWorker` and `discardWorker` run both steps without a relay.
`writeWorkerControl` encodes the given control, requires that it decodes, and
writes it.

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
the callback again. This acknowledges only in-memory consumption. State owns
durable commit, duplicate identity checks and commit-then-lost-reply ambiguity.
There is no replay/outbox implementation in this adapter.

Status observers do not consume that queue and cannot close its transport.
Validated queued data can be drained through the original opaque handle even after
scope closure and physical cleanup. An empty queue waits for the original producer
completion before returning its recorded failure or end of input. Closure still
refuses every execution and control operation. Reported process exit is separate
from Runtime result evidence, and owner-requested shutdown
is not represented as a fabricated successful child exit.

Stderr is drained concurrently. At most 65536 bytes are retained privately, with
an explicit truncation flag, while draining continues. A long-running process is
not killed merely for exceeding a lifetime diagnostics byte count. Stderr is not
the lossless Runtime event channel and is not copied into public protocol DTOs.

## Worker loss after start

When the worker processes of a started run end before the run ends, for example
through SIGKILL, the reader reaches the end of the worker pipes and the worker
records its exit. Admission then ends the entry as `closed`. The run moves from
`owned` to `cleanup-pending` supervision, Admission closes the worker and
confirms its cleanup, the reservation is released, and the run moves to `lost`
supervision. Admission does not start, resume or re-dispatch the run.

`GET /v1/runs/{id}` shows `lost` supervision and the `lost-supervision`
limitation as soon as Admission no longer holds a live worker for the run. The
runtime status stays the last validated status, such as `running`, and the run
shows no verified result. The run control resource shows `lost` supervision and
no cancel. A later answer or control for the run is refused with 409
`ownership-unavailable` and nothing is delivered. The run log ends without its
stop. The flow verb reports it with `lostSupervision`, with each open ask under
`uncertain`, and with exit status 2. The released reservation lets the manager
admit, approve and complete new requests. The `failures-worker` mode of
`manager/test/service_http.py` checks these facts through the running protected
manager.

The frontend proxy and the inner frontend worker run in two process groups, and
the inner worker inherits the pipes of the manager. When only the proxy ends,
the inner worker keeps those pipes open and the run continues under `owned`
supervision. The manager does not observe the loss of the proxy alone, and the
cleanup of the proxy group does not signal the inner group. This is an instance
of the escaped-descendant limit that the
[verification section](#verification-and-remaining-owners) states.

## Run directory owner lock

When the inner frontend worker starts a run, it creates `runs/<run>/owner.lock`
in the private state root before it writes `supervisor-manifest.json` and the
first `owner.json` heartbeat. The worker creates the file exclusively as a
private regular file with mode 0600, takes an exclusive, nonblocking `flock` on
its open description, and keeps the descriptor open until the worker process
exits. The descriptor keeps `FD_CLOEXEC` in the worker. The worker names it with
the Runtime `setInheritedOwnerLock`, so on macOS each engine session that the
worker starts through the Runtime `createProcessGroup` holds the same open
description and with it the same lock. The lock does not cover the engine
processes that start through the process library: the ACP adapter starts its
agent with `createProcess` in `connectAcp`, the agent-deck adapter uses
`withCreateProcess`, and the shell steps of `Agentic.Shell` use
`readCreateProcessWithExitCode`. These processes do not receive the
descriptor. They normally end when their pipes to the ended worker close. At
present no engine of the inner worker starts through `createProcessGroup`, so
the lock covers the inner worker process only.

While the inner worker lives, another open of `owner.lock` cannot take an
exclusive lock. An exclusive lock that a later open takes therefore shows that
the original inner worker and each engine session leader that holds the same
open description have ended. It does not show that the engine processes of the
run that started through the process library have ended. The quarantine check
reads the lock, as the
[manager-loss section](#manager-loss-and-restart) states. The file stays in
the run directory after the run ends, and restoration and pruning handle it as
any other file of the run directory.

## Manager loss and restart

When the manager process ends without its orderly close, for example through
SIGKILL, the worker pipes of each started run lose their manager end. The inner
frontend worker reads the end of its control input. The runtime then cancels
the run with the message `control input closed`, the run log receives its stop,
and the worker processes exit. The manager log of the killed lifetime ends
without its shutdown notice.

A restart on the same root and configuration acquires the configuration storage
slot and the service lease again and reconciles the Store, as the
[storage contract](STORAGE.md#restart-and-offline-restoration) describes. The
manager log of the new lifetime continues with a lifetime notice whose
reconciliation counts name the changed rows. Each owned run becomes `lost`, the
reservation of each such run becomes quarantined, and each dispatch-attempted
start or control becomes `unresolved`. A start command whose run has a terminal
observation is not reclassified. It keeps its state, its revision and its
receipt, and the reconciliation publishes no `command.changed` event for it.
The manager reads no run store to recover a worker and dispatches no start
again. The catalogue of the new lifetime
publishes new profile revisions, so a client reads the catalogue again before it
creates a request. An exact replay of an earlier command returns the receipt of
its first response. The replay of an unresolved approval returns that receipt
and sends nothing.

`GET /v1/runs/{id}` shows `lost` supervision, the `lost-supervision` limitation
and the last validated runtime status, and the run control resource offers no
cancel. The quarantined reservation keeps its execution slot and its resource
keys until the operator releases it with cleanup evidence. While every
execution slot is held, a new request waits in the queue with `capacity`. A
request of a profile whose resource keys meet those keys waits with
`profile-busy`. A profile
without resource keys has the unclassified resource, which every other such
profile shares. Requests with other resource keys are admitted while an
execution slot remains.

The local administration operation `check-quarantine` reports the cleanup
evidence of one quarantined reservation. It reads the reservation, its request,
its start intent and its run, and it classifies the claim by these rules:

- No launch. No start intent and no run names the reservation, directly or
  through one of its preparations. This is the case of a request that the
  restart refused while it was preparing or in review, and of a reservation
  that never reached a start. The state is `clean`. The evidence facts are the
  reservation identity, the request identity, the current request phase, the
  states of the preparations of the reservation, the state of its admission
  observation, its resource keys and the current process generation.
- Launched and ended. The run log `flow.ndjson` of the run store of the run
  holds the terminal record that the runtime writes when the run ends, for
  example the stop that follows `control input closed` after a manager loss.
  The terminal record is the first event record whose event in
  `events.ndjson` ends the run, as the runtime readers find it. The state is
  `clean`. The evidence facts are the reservation identity, the run identity,
  the position of the record, the SHA-256 digest of the exact bytes of its
  line and the current process generation.
- Launched, with the owner released. The run store holds no terminal record,
  and the check opens `runs/<run>/owner.lock` in the recorded run root
  read-only, without following a symbolic link, finds a private regular file
  of the effective user with one link, and takes its exclusive, nonblocking
  `flock`. It releases the lock at once. The free lock shows that the inner
  frontend worker and each engine session leader that inherited its lock have
  ended. The state is `clean`. The evidence facts are the reservation
  identity, the run identity and the current process generation.
- Launched without a terminal record, with the owner not released. Another
  process holds the lock, or `owner.lock` is absent, cannot be opened or is
  not a private regular file. An absent file is no proof, because a worker
  that started before the owner lock existed created none. The state is
  `cleanup-required`.
- Unreadable. The run store cannot be read, or the identity names a claim that
  a restoration carried forward. The state is `unverifiable`.

The evidence facts of a `clean` claim form one JSON object, encoded with its
keys in order and without white space. The member `evidence` names the rule:
`no-launch`, `terminal-record` or `owner-released`. The evidence digest is the lowercase SHA-256
digest of these bytes, and the evidence identity is `cleanup_` followed by the
first 32 hexadecimal digits of the digest. Two checks in one lifetime therefore
return the same identity and digest. The process generation is a fact, so a
new lifetime gives a new digest. The evidence expires 600 seconds after the
check. The other states carry no identity, no digest and no expiry. An unknown
identity and a reservation that is not quarantined refuse with
`state-conflict`.

The check is read-only. It changes no Store row, appends nothing to the
manager log, reads or signals no stored process identity and adopts no worker.
The lock probe of the `owner-released` rule holds the lock only for the probe
and changes no run store.

The local administration operation `release-quarantine` releases one
quarantined reservation with the evidence identity and digest of a `clean`
check. It computes the evidence again under the held Store file slot and
configuration guard, and refuses with `cleanup-unverified` when the evidence
is not `clean` or differs from the supplied values. Because the process
generation is a fact, evidence from an earlier lifetime never matches. A
launched reservation without a terminal record is therefore releasable once
the inner worker of its run and the engine session leaders that hold its owner
lock have ended, and a release while the lock is held refuses with
`cleanup-unverified`. An
unknown identity and a reservation that is not quarantined refuse with
`state-conflict`. A release frees the execution slot and the resource keys of
the reservation in one transaction and records the release and its receipt in
the manager log. The run of the reservation stays `lost`, and no run store
changes. On the live channel the release then notifies the admission
controller, so a request that waits with `capacity` is prepared without
another client command, as after the release of a terminal run. The
[command contract](COMMANDS.md#local-credential-administration) states the
transaction.

The open of the new lifetime answers each command ask of the killed lifetime
that has no reply, before it serves. An ordinary command with a ledger row
receives its current receipt, an ordinary command without a row receives the
failure `lifetime-ended`, and an administration operation receives the
failure `committed-receipt-lost` or `outcome-uncertain`, as the
[storage contract](STORAGE.md#orphaned-asks) states. No command executes
again. A run with `lost` supervision counts as terminal for pruning, so the
pruning round at open removes a sealed segment that names only the lost run
and other terminal work, and the retained floor moves past it. A segment
that names an owned or cleanup-pending run stays protected. The flow verb
reports no undecided command, reports each retained earlier lifetime under
`lifetimeWithoutShutdown`, verifies the consent of each retained start relay,
decodes each release command with its one reply, and exits with status 2.
The `failures-manager` mode of `manager/test/service_http.py` checks these
facts across three lifetimes of the running protected manager with one
profile and one execution reservation. The first SIGKILL loses a run in
flight, and the second loses a request in review. While no manager runs,
the harness leaves command asks without replies in the killed log, as a
crash before a receipt or before a COMMIT leaves them. After each restart a
new request waits with `capacity`, a release with a wrong digest refuses
with `cleanup-unverified`, and the release with the evidence of
`check-quarantine` lets the request reach review without another client
command. Its approved run then completes.

When the worker processes of a lost run outlive the manager, the run log
receives no stop, and the operator first ends those processes. The operator
then runs `check-quarantine` again and releases the reservation with the
`owner-released` evidence that it returns. The `failures-launched` mode of
`manager/test/service_http.py` checks this procedure across two lifetimes with
one profile and one execution reservation. Before it kills the manager with
SIGKILL, the harness stops the worker process groups with SIGSTOP. The death of
the manager orphans the process group of the frontend proxy, and because that
group holds a stopped process the kernel sends it SIGHUP and SIGCONT, so the
proxy ends. The inner worker leads its own session and receives no signal, so
its stopped processes stay and keep the owner lock. The harness starts the
manager with the default action for SIGHUP. After the restart a new request
waits with `capacity`. While the stopped inner worker
holds the owner lock, `check-quarantine` reports `cleanup-required` and a
release refuses with `cleanup-unverified`. After the harness kills the stopped
groups with SIGKILL and no process of them remains, the run log still holds no
terminal record. `check-quarantine` then reports `clean` with the
`owner-released` evidence, the release with that evidence lets the request
reach review without another client command, and its approved run completes.

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
the [approval owner](APPROVAL.md) supplies exact approval. WM-015 owns durable
ingestion, WM-016 control semantics,
and WM-019 broader containment and safety supervision. No listener, deployment,
provider call, new workflow semantics, stored-worker adoption, SQLite confinement
experiment or release acceptance is claimed by this unit.

The watchdog survival control observes an actual prepared Worker through its
non-consuming status operation, then samples it more than thirty seconds later.
It never uses a caller preparation wait to determine the watchdog lifetime. The
same original Worker must remain prepared and then discard and join normally.
The compiled removal of successful-preparation disarm must fail the survival
assertion, with the original startup budget unchanged.

The backpressure-close regression also observes the actual native inner process
before close and rejects a live survivor afterward. Its PID is a read-only negative
witness, not reconstructed signalling authority or a replacement for original
ProcessGroup cleanup. Direct termination tests cover caller interruption during
grace, caller-thrown IO exceptions, an already uninterruptibly masked caller,
ordinary completion and repeated callers. The old termination-body mutant must
fail the caller/grace assertions. Operator cleanup of a failed fixture is separate
hygiene and never counted as successful manager cleanup.

Worker validates the retained CLI-owned prepared-target relation after native
identity validation. Its actual phase, stop, completion and release cells are shared
through Worker.State with the fixed final acceptance guard, not duplicated into a
second phase machine. The guard includes the original registration and native group,
with Runtime owning the nonblocking liveness observation. A known reader failure
invalidates prepared eligibility before joined process cleanup without replacing
its original exception. The [approval owner](APPROVAL.md) supplies exact consent and
same-worker start, while durable ingestion remains separate.
