# Coordination storage

`Agentic.Manager` provides a scoped private SQLite store beneath an installed
operator configuration. The CLI remains the composition root. A caller brackets
`installConfiguration` with `closeConfiguration`, then calls
`withCoordinationStore installed action`. This does not create workers, a
listener, credentials, or approval authority.

## Ownership and lifetime

Installation acquires a nonblocking native `flock` on a separately opened
retained root-directory descriptor before establishing the manager role. No lock
entry interferes with the existing empty-root check. Different processes and
distinct opens in one process exclude each other. Process exit releases the
lease. The descriptor is close-on-exec at creation.

Storage claims one slot under the configuration lock, retains a Runtime
`openPrivateSubroot root []`, and atomically duplicates the lease with
`F_DUPFD_CLOEXEC`. A second store from the same installation refuses. Reload
remains available while the store exists. Closing the configuration prevents
further configuration operations but cannot release the store's duplicate lease.
The configuration is retired before its descriptors are closed, so a cleanup
exception cannot republish a consumed descriptor for a later close.
The slot is released after storage cleanup, including callback exceptions and
cancellation. A stored PID, generation, root identity, or native run identity
cannot construct either lease or worker authority.

One connection serves reads and writes, with one active operation. Every Store
action, including each command, protected read, event stream batch and admission
coordinator step, waits for the Store gate through `WaitWithinBudget`. Waiting
and execution share that Store action's existing five-second allowance. A
waiter that is not admitted within the allowance is refused with
`StoreDeadline` and never runs. An admitted action executes once.

One request of the owners below has one admission deadline. A request that
takes more than one lock in turn, such as the file slot, then the configuration guard, then the
Store gate, waits for all of them within one five-second allowance. The
allowance starts when the request starts. Each wait uses only the rest of it,
so the sum of the admission waits of one request is at most five seconds. A
lock that is free is taken at once, also after the allowance ends. A wait that
the allowance ends keeps the refusal of its lock: `StoreBusy` for the file
slot, `SupervisionUnavailable` for the configuration guard, which its owner
refuses as `StoreBusy` or as public `storage-unavailable`, `StoreLimit` for a
reader place and `StoreDeadline` for the Store gate. The refused action never
runs. `withStoreRequest` gives such a request a store value that carries its
deadline. The reader admission, the configuration loan of a response, the
administration loan and the file operation that opens its retained root use
one deadline for their own waits. The owners that take the file slot and then
the configuration guard or the database for one bounded operation run under
`withStoreRequest`: draft reads, draft assembly, lineage draft creation, the
frontend file check, export submission and reconciliation, quarantine
inspection and release, managed history and the approval preparation read.
Command submission and command preflight also run under one deadline: the
configuration guard, the Store gate of the identity read and the Store gate
of the acceptance transaction share it. So the submission of an answer, a
decision or any other command waits at most five seconds for these locks
before it is admitted or refused as `storage-unavailable`. A protected view also has one deadline for its
credential read, its reader place, its configuration loan and its first
authorization observation, which `withAuthorizationRequestReadObservation`
runs. A scope inside a scope of the same store value keeps the outer
deadline.

Each non-streaming GET route of the HTTP service is one request with one
admission deadline. The dispatcher runs the route under `withStoreRequest`
through `Service.withServiceRequest`, and the owners of the route receive the
request store. The deadline starts before the first lock wait of the route.
A GET request has no body, and the dispatcher refuses a GET request with a
body before that wait. The protected view of the route, every owner read
inside the view, every nested scope of the request store and every attempt
of `repeatChangedRead` wait within that one deadline. So the sum of the
admission waits of one route is at most five seconds before the route is
refused with `StoreBusy`, `StoreDeadline` or `StoreLimit`, which the public
problem reports as `storage-unavailable`. Under no contention a route
deadline changes no representation, status or entity tag, because a
deadline bounds only waits.

The following owners keep a deadline of their own. A value that is kept
after the request, such as a command attempt, a dispatch ticket or the store
of a later revalidation, starts a fresh deadline for each later wait. Each
revalidation of a response view runs through
`withAuthorizationReadObservation` with a fresh deadline. The event stream of
`/v1/events` and the route streams start no route deadline, so no deadline
spans a stream, and each batch of a stream starts its own deadlines. An
artifact download keeps the deadlines of its owner, including its total
deadline of 300 seconds. A POST route starts no route deadline, because its
owners read the request body first. Its resolve read, its command
submission and its receipt view each have one deadline of their own, which
starts after the body read. The owners that write a file or produce an
outside effect before their Store record, such as a capture upload, start a
fresh allowance for each lock. So a capture whose file is written is never
refused by an allowance that the body read used up, and its file is never
left without its record because of a route deadline.

Operation bounds stay separate. The operation allowance of an admitted SQL
action starts when its wait for the gate starts, as before. The 100 ms busy
timeout, the rollback bound and the five-second bound of a draft operation do
not change, and none of them is part of the admission deadline. A protected
read whose authorization observation meets a concurrent commit reads again under
the newer generation, as `COMMANDS.md` describes. A new attempt starts only
while one five-second allowance lasts, and the waits of every attempt and of
the final acknowledgement use the rest of that allowance. The gate admits waiters in order, and each holder
is bounded by its own earlier allowance. The configured positive reader
allowance is an upper bound, not a promise of parallel readers. An escaped
store handle refuses after its callback scope. The scoped owner waits for
in-flight database and file operations and their joined cleanup before
closing SQLite and releasing the lease. File operations
use one separate slot and retain a private root plus lease duplicate. An
ordinary file operation waits for the slot within the admission deadline of
its request, and a slot that stays held until that deadline ends is
`StoreBusy`.
A coordinator probe does not wait. When the slot is held, it returns at once
and proves that its callback did not enter.
Their lock order is file slot, configuration, then database. An artifact
download also charges one of the two artifact response places of the Store
before the file slot, as `manager/ARTIFACTS.md` describes. When both places
are charged, a download waits for a place for at most five seconds, with no
lock held, and then refuses with `storage-quota`. No other operation waits for
a place.

## Database and schema

`coordination.sqlite3` is created exclusively through Runtime with private mode.
Existing database and named companion entries are opened relative to retained
Runtime directories with no-follow and nonblocking flags. They must be regular,
single-link, effective-user-owned files with mode 0600. SQLite opens the fixed
database path with NOFOLLOW and a private connection cache. The operator must
keep the private root and its ancestor namespace stable while storage is active.
No directory-replacement confinement guarantee is made.

The connection sets and verifies WAL, synchronous FULL, foreign keys, a 100 ms
busy timeout, and disabled automatic checkpointing. Native temporary storage is
set to FILE. Main and temporary cache settings are each negative 2048 KiB.
These settings are read back, and a linked build forcing `TEMP_STORE=3` refuses.
SQLite manages private temporary files through its native facilities. Those
files can reside outside the manager root. Cache settings are not hard total
heap or temporary-disk quotas. The pinned Unix SQLite source specifies mode
0600 for DELETEONCLOSE temporary files. That source evidence is not an exhaustive
platform or forced-spill test.

`PRAGMA user_version` holds internal schema version 12. Startup accepts versions
zero through twelve, and rejects other versions before changing journaling or
schema. Fresh initialization, command-ledger additions, the explicit literal
chunk/upload migration, and admission and control-state additions execute DDL,
metadata and version publication in one immediate transaction. Version-one DDL
and the version-two and version-three migrations remain unchanged. The frozen
public managerStore compatibility stays at one. Version eight rebuilds only the
exports table to defer its command foreign key until commit. Every existing
column, constraint, unique index and stored value is retained. The change permits
Commands to record an export intent before inserting its owning command in the
same transaction, without changing command acceptance order. The
[artifact gate](ARTIFACTS.md#evidence) checks populated version-seven upgrade,
migration rollback and rejection of missing command references at commit.
Failure rolls that transaction back and never publishes a connection. The
metadata row separately stores authority epoch, stream identity, stream sequence,
retained floor, and service revision. Epoch and stream are random 256-bit
identifiers that survive ordinary reopen. A fresh random process-generation
identifier exists only in the new store lifetime. Version twelve adds credential
labels, effective rotation cutoffs, successor relationships, and explicit profile
membership without changing the original credential table or ledgers. Legacy
labels equal credential IDs. [Local administration](COMMANDS.md#local-credential-administration)
uses the same writer and unchanged transaction budgets.

The schema contains relational records rather than a generic object store:

| Records | Representation and owning consumers |
| --- | --- |
| Clients and credentials | Registered client keys, independent verifier identities, expiry, revocation, and credential/profile scopes support WM-010 and WM-023. |
| Requests and inputs | Workflow/profile revisions, request phase, admission, queue ordinal, ordered declarations, validation data, and exclusive literal/capture bindings support WM-011 and WM-013. |
| Captures | Request, client, profile, immutable private reference, byte count, and digest remain separate from content. |
| Reservations | Unique execution slots, separate operator/unclassified resource domains, exact cleanup-command association and captured revisions support WM-013. |
| Admission observations and queue clock | Genuine native preparation metadata remains separate from complete public review, and a persistent unsigned queue clock survives release. These rows are not reconstructed timers or worker capabilities. |
| Preparations | Request/reservation references, exact revisions, worker/native/root identities, expiry, review, and private binding support WM-012 and WM-014. Stored associations are not live capabilities. |
| Runs and ingestion | Unique profile/root/native-run tuples, separate control revision, optional versioned runtime snapshot, supervision, result verification, and unique run/sequence ingestion support WM-015. |
| Commands and decisions | Registered-client ledger uniqueness, request bytes, media type, preconditions, retirement, intent, dispatch association, attempted delivery, acknowledgements, effects, and exact decision identity support WM-010 and WM-016. |
| Artifacts and exports | Trusted private references, run association, verification, command association, exclusive destination/name, and receipt data support WM-017 and WM-018. |
| Replay | Stream/sequence keys, resource URI, revision, change kind, and retained floor support WM-021 and later event transport. |

Foreign keys protect references, including request-bound captures,
request/reservation/preparation association, and run-bound artifact references.
Released reservations retain their historical identity with a null slot. A
partial index permits only one active reservation per request, and non-null
slots remain exclusive. Triggers refuse release while resource claims remain
and refuse attaching claims to a released reservation. A later reservation can
reuse capacity without deleting preparation history. The [admission owner](ADMISSION.md)
chooses release only after confirmation from its original live Worker or a
protected construction that never requested a native worker.

Separate link tables retain capture dependencies for preparations and commands.
Optional runtime snapshots remain absent before runtime evidence exists.
Canonical decimal text stores the complete UInt64 stream and ingestion range
without signed SQLite integer overflow. Replay ordering uses decimal length and
then lexicographic order. Sequence exhaustion refuses instead of wrapping.
Resource revisions are opaque equality tokens, not sortable numbers.

## Internal transactions and bounds

Only internal manager modules can import `Transaction`, `execute`, `query`,
`runTransaction`, and `runRead`. A transaction program has ordinary Functor,
Applicative, and Monad composition but no IO lift or connection accessor. Its
SQL is source-owned, single-statement SQL. Parameters carry private input bytes.
Mutations accept INSERT, UPDATE, or DELETE. Queries accept SELECT or WITH and
also require SQLite's statement-readonly check. Programs cannot issue PRAGMA,
transaction control, schema changes, or arbitrary SQL obtained from a network
request. No statement or live cursor escapes.

| Bound | Ceiling |
| --- | --- |
| Source SQL | 65536 UTF-8 bytes per statement. |
| Binding count and transaction statements | 256 each. |
| SQLite value or row length | 2097152 bytes through SQLite's native length limit. |
| Bound parameters plus source SQL | 8388608 aggregate bytes per operation. |
| Copied query results | 1000 rows and 1048576 bytes shared across all queries in an operation. |
| Invalidation batch | 256 entries, each with frozen bounded ASCII URI and revision syntax. |
| SQLite columns, expression depth, compound terms | 64, 64, and 32 respectively. Attached databases are disabled. |
| Migration | 30 seconds of cooperative operation budget. |
| Read, transaction, checkpoint, rollback | 5 seconds each of cooperative operation budget. |

Binding limits are checked before SQLite binding. Result byte accounting checks
SQLite-owned columns before copying them into Haskell. Result construction is
strict and the decoded operation result must satisfy NFData before commit.
Owning codecs consume SQL values inside the transaction and return bounded
application records. Large projections need separately bounded chunks or pages
under their owning codec, not a raised global limit or a live streaming cursor.

A write program returns its result together with its invalidations. This allows
a conditional duplicate branch to return the original result with an empty event
list from the same transaction snapshot. The event list is bounded before it is
appended, without deep-forcing an unbounded list. A mutation that executed SQL
cannot commit without an invalidation. Invalidations and sequence allocation are
inside the same transaction as resource changes.
An exception, explicit refusal, failed event insertion, constraint failure, or
cancellation rolls back without returning a receipt. Commit-path failure or
uncertain rollback poisons the connection, so it cannot return another success.
The original asynchronous exception remains distinguishable from storage errors.
Public diagnostics do not expose SQLite errors, SQL text, paths, or private data.

Waiting uses monotonic time and the admission cell only. It does not invoke SQL
or interrupt the current holder. Masked acquisition installs token release before
restoring the caller's action. Closure, poisoning, root identity and remaining
budget are checked after acquisition. Exhaustion refuses before the transaction
body or BEGIN. The SQL action and its deadline monitor both use the remaining
allowance, without resetting it. Rollback retains its separate five-second bound.
Admitted failures are not retried, including uncertain publication.

A protected response materializes its representation under the loans of its
owner: one reader charge, the configuration guard and, for an owner that reads
files, the file slot. `Transport.respondBytes` checks the view once under those
loans. It then returns them with `releaseResponseLoans` before the first
network write, the configuration guard and the reader charge first and the file
slot after them. No configuration guard, reader charge, file slot or SQL
transaction is held across a network write. The authorization watch of the
view stays registered until the owner callback returns. It spans every write
as an authorization token only.

Before each 16 KiB write, `revalidateAuthorizedView` reads the bound
authorization facts again. It acquires one reader charge, the configuration
guard and one SQL read for that check alone, in the lock order configuration,
then database, and returns them before the write. The cost is one brief reader
and guard acquisition for each write. It contends with ingestion and other Store
work only for the duration of the check. A revocation, a scope change or a
configuration change between two writes makes the check refuse, and the
response stops before the next write. A write that does not complete within
five seconds is the internal `ResponseWriteTimeout` cause. Ingestion therefore
waits for a response only during such a brief check and never during a send.

One check is one request with one five-second admission deadline. The
observation starts it. Every attempt of the check waits for a reader place,
for the configuration guard and for the Store gate within the rest of that
deadline, and so does the final acknowledgement. The observation retries
after a concurrent commit only while the deadline lasts. The sum of the
admission waits before one write is therefore at most five seconds.

A check whose allowance expires refuses with its Store failure, which is
recorded like any other Store refusal. The response then stops before its next
write. After the status and headers are sent, the client receives a truncated
body. The manager does not resend the response or any part of it.

An artifact download holds its captured bytes across its writes under an
artifact response place, not under the file slot. The two places limit the
Store to two such downloads of at most 64 MiB each. A third download waits for
a place for at most five seconds and then refuses, and no other operation
waits for a place. A download has a total deadline of 300 seconds from the
charge of its place. Its view checks the deadline before each write, so a
download past the deadline stops at its next write boundary and returns its
place. A page response holds its page-set reservation across
its writes, and a command receipt holds nothing but its authorization watch.

A server-sent event stream holds no Store loan between its batch reads. Each
batch read acquires one reader charge and the configuration guard, in the lock
order configuration, then database, within one five-second admission deadline
for the batch read.
It reads and encodes the batch under these loans and then returns both with
`releaseResponseLoans`. The stream revalidates its view immediately before
each block and each heartbeat. A block or heartbeat write therefore holds no
configuration guard, reader charge, file slot or SQL transaction. A stream
with nothing more to read waits on the authorization watch of its last batch
view. The watch is an authorization token only, so the wait holds no loan.
Each write completes within five seconds, the heartbeat interval is 15
seconds, and a revocation ends the stream before its next block. Streams that
stall in a write, up to the Store reader capacity, therefore leave the
reader places and the configuration guard free for ingestion. The limit of two
subscriptions for each client is a separate count and not a Store reader
charge. A stream whose client closed the connection keeps its subscription
until its next write fails, which is at the latest its next heartbeat. When
the listener stops, it closes its socket and runs `closeStreams` before it
joins its connection workers. A new stream then refuses with
storage-unavailable. An open stream ends its response after its current
write and before its next batch read. A waiting stream observes the flag at
its next authorization wakeup, which comes within one second. The
`events-lifecycle` mode of `manager/test/service_http.py` checks these facts
through the running protected manager: SSE and polling attached at a snapshot
cursor, cursor advancement over records of another profile, reconnection
after a partial block, the end of an open stream at an ordinary shutdown, and
the stream alias and cursors across the restart.

The route streams of `GET /v1/runs/{id}/routes` and `GET /v1/routes` follow
the same rules. Each batch of a route stream is a new JSON batch read: it
takes the file slot, the configuration guard and one reader charge in the
lock order file slot, configuration, database, reads and filters one batch,
and returns every loan with `releaseResponseLoans` before its first write.
No block, heartbeat or wait holds a configuration guard, SQL transaction,
reader charge or file slot. A route stream holds one subscription of its
client in the same count as the event streams, through `withStreamReader` of
`Agentic.Manager.Events`. A wakeup only requests a durable read. The writer of
the manager log keeps an append count in memory, which it increments after
each synchronized append and which `managerFlowAppends` exposes through
`storeManagerFlow`. A stream of the manager route reads the count before each
batch and, when it has nothing more to read, waits for a change of the count,
for `closeStreams` or for its heartbeat deadline. A stream of the run route
waits one second, or until `closeStreams` or its heartbeat deadline when
either comes first. After `closeStreams` a route stream ends before its next
batch read. The `routes` mode of `manager/test/service_http.py` checks the
route streams through the running protected manager: the same records as the
JSON batches on both routes, attachment at a JSON cursor, reconnection after a
partial block, cursor blocks for an observe-only credential, a manager-log
record that reaches an open stream before the next heartbeat, the shared
reader quota, the end of open route streams at an ordinary shutdown, and
route cursors across the restart.

Operations require the threaded RTS. Cancellation repeatedly interrupts the
original SQLite operation until its thread joins. A single interrupt can precede
statement execution and have no effect. The interrupter also joins before rollback,
connection reuse or close. Cleanup cannot abandon a connection that SQLite still uses. Final close is
shielded against further asynchronous exceptions. Cooperative budgets do not
promise an absolute OS IO deadline or a hard total SQLite heap bound. A stalled
filesystem can extend joining and cleanup beyond the nominal budget.

### Busy refusals and their records

Each site that refuses with `StoreBusy` on a command path or a read path
first writes one private fault line. The line names the site, the elapsed wait
of that site and the remaining allowance of its deadline:
`manager-fault <time> busy site=<site> class=store StoreBusy elapsed=<n>ms remaining=<n>ms`.
A site that does not wait writes `elapsed=0ms remaining=none`. A site inside
a transaction measures from the start of the allowance of that transaction.
The record adds no public field, and the refusal that follows it is unchanged.
The command layer and the transport then record their own lines, such as
`admission operation class=store StoreBusy` and the response line.

| Site | Refusal |
| --- | --- |
| `store-file-slot` | The file slot stayed held until the admission deadline of an ordinary file operation ended. |
| `store-reader-admission` | The configuration guard was not acquired during reader admission. |
| `configuration-guard`, `configuration-administration` | The configuration guard stayed held until the admission deadline of its request ended. These lines carry `class=configuration SupervisionUnavailable`, which the Store owner then refuses as `StoreBusy`. |
| `store-gate` | A `FailFast` Store action found the Store gate held. A `WaitWithinBudget` action that is not admitted is `StoreDeadline`. |
| `store-authorization-observation`, `store-authorization-read-observation` | A concurrent commit changed the authorization generation of an observation. |
| `store-admission`, `store-worker-registry` | A second Store admission, or a seventeenth Store worker. |
| `store-manager-log-prune` | The configuration guard was not acquired for a prune round. |
| `state-*`, `drafts-*`, `history-*`, `artifacts-*`, `overview-*` | A concurrent commit changed a revision that the owner read before. |
| `state-control-surface`, `state-decision`, `state-control-availability` | Concurrent commits kept changing a repeated read for its whole allowance. |
| `service-ingestion-head` | Ingestion of the retained head met contention for its whole allowance. |

SQLite reports busy after its 100 ms busy timeout. That refusal is
`StoreUnavailable`, not `StoreBusy`. Its line names the site
`store-sqlite-transaction` or `store-sqlite-read` with
`class=sqlite ErrorBusy` and the elapsed time of the transaction.

The control-surface read of `GET /v1/runs/{id}/control` has three parts: the
control revision and supervision, the run projection, and a second read of the
revision, the supervision and the projection boundary. The decision read of
`GET /v1/decisions/{id}` reads the pending queue, the projection and the
question, and then reads the queue again. Before a control or an answer
reserves anything, the availability read takes the projection and then the
projection boundary and the control revision. An ingestion commit can fall
between the parts of each of these reads. Each of them is safe to repeat and
changes no state, so `repeatChangedRead` starts it again after a pause of
10 ms. The read uses the admission deadline of the request of its store
value: the deadline of the route for the control and decision reads of a GET
route, and a fresh deadline for the availability read of a command
submission. A new attempt starts only while that deadline lasts, and the
Store actions of every attempt wait within it. When commits keep arriving
until the deadline ends, the read refuses with `StoreBusy` and one line for
its site.

Inside the command transaction of a control or an answer, the validation
checks that the control revision is still the revision of the availability
read. A change refuses that transaction with `StoreBusy` at the site
`state-control-validation`, and the transaction rolls back. The command is not
repeated, because the command transaction is an admitted operation.

## Restart and offline restoration

An ordinary Store open acquires the existing configuration storage slot and
service lease, validates the private files, migrates the schema, and creates a
fresh process generation. Epoch and stream identity survive. Old live
preparations become invalidated, unresolved reservations remain quarantined,
and owned runs become lost supervision without changing their Runtime evidence.
Uncertain starts and controls remain unresolved with their original request and
receipt bytes. A start command is uncertain when it is accepted or
dispatch-attempted and its run has no terminal observation
(`runs.terminal_observed`). A start command whose run has a terminal
observation is not reclassified, and it acquires no new revision and no
`command.changed` event. A control command that is accepted or
dispatch-attempted is always uncertain. No stored identifier becomes a dispatch or cleanup handle.
A quarantined reservation keeps its execution slot and its resource keys until
the operator releases it with cleanup evidence, as the
[worker contract](WORKERS.md#manager-loss-and-restart) describes.
Reconciliation pages at most 100 changed resources per transaction and publishes
their matching preparation, request, run, control and command invalidations in
that transaction. Each page has at most 200 events within the existing limit of
256, with the existing five-second operation and thirty-second startup bounds.
A failed page rolls back its resource changes and events and refuses startup.
Completed pages retain coherent replay facts. Unchanged resources and no-op
reopening acquire neither new revisions nor extra events, and ordinary restart
preserves the stream identity and retained floor.

The composition root probes the current installed profiles before entering
Admission. `withAdmission` reconciles draft and queue intent
through Drafts before publishing its controller. Schema ten stores a private,
versioned digest of the complete declared profile configuration and native
workflow descriptor at request creation. This includes invocation, working
directory, arguments, environment, ownership, quarantine, resources, person
policy and configuration limits. Declared equality is not workflow semantic
identity and does not certify the prepared-target validator function. Fresh
native preparation still invokes the current validator and requires fresh
approval.

Reconciliation verifies stored inputs and captures using Drafts, then updates
current revision tokens and restores enqueue associations in the same transaction
against unchanged request facts. Removed, quarantined or unsuccessfully discovered
historical selections remain inert without blocking unrelated usable profiles.
Store, private-root and configuration-access failures still propagate. FIFO ordinals and
original enqueue bodies, preconditions and receipts remain unchanged. Only
enqueue materialization associations can be retained again. No CommandAttempt,
DispatchTicket, accepted start or control payload is reconstructed. Requests
without historical bindings are not backfilled from current configuration and
remain inert across a new configuration lifetime. Explicit new requests remain
available. Changed declarations or unavailable bytes do not become eligible.

`backupCoordinationStore installed destination` and
`restoreCoordinationStore installed source` are local offline operations exposed
through `Agentic.Manager`. Their directory argument is an existing private root
outside manager storage. First finish Admission using its explicit shutdown
policy and close its Store through the original owner. A live or quarantined
Store retains its slot and lease and refuses the offline operation. No listener
or network boundary exists at this layer. Future service composition must close
exposure before releasing its Store and invoking these operations.

Backup requires an initialized current-schema target and a fresh destination.
It uses SQLite backup, copies all referenced immutable captures with bounded
streaming and verification, and publishes its durable completion binding last.
The binding names the original private root identity. Native history remains in
that root as observational evidence and is not a source of recovered control
handles. The snapshot does not relocate native history or support cross-root
migration.

Restore requires that same root and a readable current safety state. Missing,
corrupt, incomplete or over-budget current safety facts refuse before database
publication. Backup-only recovery of an unreadable target is not supported.
Validated pre-restore and backup claims feed the existing admission occupancy
path. Identical original claims deduplicate only after their complete slot and
resource facts agree. Slot collisions retain separate capacity pressure. No
claim is discarded to make capacity available, and no clearing API is supplied
without original cleanup evidence. Eligible disjoint new work can proceed.

Before publication, restore durably records `restore-in-progress`, including
the bounded original safety claims. It verifies source captures, refuses
replacement of different immutable target bytes, restores through SQLite backup,
rotates authority and stream identities, revokes every restored credential and
records uncertainty about effects newer than the backup. Completion removes the
startup fence only after these commits. An exception or interruption leaves
normal Store opening refused. Do not delete that marker to assert completion.
Automated repair of an interrupted restoration is not provided by this API.

Local reprovisioning must use the existing registered client identity. Fresh
credentials do not validate an old mutation key because Commands checks its
epoch before ledger lookup. A completed restore does not imply that lost-interval
effects were absent or undone. Clients must reconcile rather than inventing
replacement keys or replaying uncertain work. Ordinary credential rotation is
not restoration and does not reset that client's ledger.

Schema ten adds only request declaration bindings, bounded restoration quarantine
facts and restoration uncertainty records. Prior migrations and relational
constraints remain intact. The Store and Admission gates register focused
SQLite/private-file and ordinary native restart modes at N1 and N8. Store also
runs the existing captured-source audit once for restoration interruption. Its
single phase barrier follows durable marker publication, and its N1 and N8
checks cancel and join the original Async before asserting startup refusal.
These are not HTTP, client transport, hardware durability or full failure-matrix
evidence.
OS containment is excluded from this project and is not a pending capability.

## Manager log

The Store lifetime of a serving manager writes the manager log of its stream
identity through `Agentic.Manager.Flow`. `serveManager` opens that lifetime
with `withServingStore`. The log is its sealed segments, the private files
`flow/sealed/<stream>/<start>.ndjson` in start order, followed by the active
private file `flow/<stream>.ndjson` in the manager root, and its claim-check
files are the private files `flow/claims/<stream>/<sha256>`. Each stream has its own claim directory, so
the claim checks of a log count toward the ceiling of that log only. The
record, the strict line codec and the writer are those of
`Agentic.Runtime.Flow`, which the [broker contract](../runtime/BROKER.md)
describes. A lifetime that `withCoordinationStore` opens, such as a local
administration command that runs while no manager serves, reconciles a restart
but writes no manager log. The credential list of the next serving lifetime
shows the credentials that such a command changed. The reconciliation counts of
a serving lifetime name only the rows that its own reconciliation changed, so
the rows that an administration lifetime reconciled first do not appear in any
manager log. Offline backup and restoration
write no manager log. A restoration rotates the stream identity, so the next
serving lifetime writes a new file.

`openManagerFlow` opens the log for appending and creates it when it is absent.
It reads the sealed segments and the active file, which together must be at
most the configured `globalMutationLedgerBytes`, and decodes every complete
line with the strict codec. Positions are global across the segments, and the
positions of a new lifetime continue those of the earlier lifetimes, so a
reply can name an ask that an earlier lifetime appended, in a sealed segment
or in the active file. A final line of the active file without its newline
denotes no record, because its append never completed, and the writer
truncates it.

The segment size is S = max(65536, (L - R) div 16), which
`managerFlowSegmentBytes` computes from L, the configured
`globalMutationLedgerBytes`, and R, the reserve below. When an append would take
a non-empty active file above S, the writer, under its leaf lock and before
that append, renames the active file to `flow/sealed/<stream>/<start>.ndjson`,
where `<start>` is the global position of its first record as a zero-padded
20-digit decimal. It synchronizes the file and both directories, creates a new
active file and checks the new file by device and inode from then on. The
first record of the new active file has the position after the last sealed
record. A receipt, a credential receipt or a failure reply whose own append
seals the segment of its command is accepted. When a crash falls between the
rename and the creation of the new active file, the next open creates the
active file at the position after the last sealed record. The retained floor
is the start of the oldest sealed segment that remains, or 0 before the first
seal, and the writer refuses a reply that names a position below it. At open
the writer removes each file of `flow/claims/<stream>/` that no record of the
log names. A log that cannot be opened gives a writer whose every append
fails. The section
[Growth, open refusals and recovery](#growth-open-refusals-and-recovery)
states the reasons and the recovery.

### Orphaned asks

The open of a serving lifetime answers each command ask of an earlier
lifetime that has no reply. `Store.openStore` does so after
`reconcileRestart` and the lifetime notice, and before the pruning round at
open. The command is the only ask schema of the manager log, and no ask of
the new lifetime exists before it serves, so every unanswered ask of the
retained log is orphaned. `managerFlowUnanswered` lists the asks from the
reply-check index of the writer and reads each record from the log. Each reply
goes from the manager to the sender of the ask, carries the identifiers of
the ask and names the position of the ask:

| Ask | Reply |
| --- | --- |
| An ordinary command whose ledger row exists. | A `receipt` reply with the current receipt of the command, which `GET /v1/commands/{id}` returns after the reconciliation. A start or control that was dispatch-attempted reads `unresolved`, except a start whose run has a terminal observation, which keeps its state. |
| An ordinary command whose ledger row exists with a retired receipt. | A `failure` reply with the reason `receipt-expired`. |
| An ordinary command without a ledger row. Its transaction never committed. | A `failure` reply with the reason `lifetime-ended`. |
| A credential administration or a release of a quarantined reservation whose committed effect the Store holds. | A `failure` reply with the reason `committed-receipt-lost`. |
| Any other administration operation, whose command record precedes the COMMIT and whose receipt follows it. | A `failure` reply with the reason `outcome-uncertain`. |

The committed effect of an issue is the `credential_administration` row of
the issued credential, of a rotation that row and the row of the superseded
credential that names it in `superseded_by`, of a revocation the revoked
credential, and of a release the reservation in state `released`. A failure
reply carries the class `refused` and the reason as its message. A reply has
the class of the receipt of its ask: the reply to a cancel may use the
reserve, and every other reply stays within L - R. A reply that cannot be
appended leaves a gap entry and the ask without a reply, and a later
lifetime answers it. A log whose asks cannot be read is recorded once in the
private fault log as `manager-log reconciliation` with `stopped unreadable`.
The reconciliation never executes, admits or delivers a command again, and it
changes no ledger row.

### Pruning

The Store of a serving lifetime owns the pruner of its manager log.
`withServingStore` runs one pruning round after the open and before the
serving action, and the pruner runs one more round after each seal of the
writer, until the action ends. `pruneManagerLog` is one round. It takes the
oldest sealed segment as its candidate, removes it when a trigger holds and
nothing protects it, and continues with the next oldest segment. The round
stops at the first segment that it keeps, so the retained floor is
contiguous. The newest sealed segment and the active file are never
candidates, so the positions and the floor survive every prune and every
reopen.

A trigger holds when one of these is true:

- The newest record of the segment is more than 604800 seconds old. This age
  is the retention of the invalidation events, and it equals the fixed
  `replaySeconds` limit that the service reports.
- The log and its claim checks hold more than (L - R) div 2 bytes.

A segment is protected when one of these is true:

- A request that it names is not terminal. A request is terminal when it is
  withdrawn or refused, or when it is associated and each run of it has
  `terminal_observed=1` or `lost` supervision.
- A run that it names has `terminal_observed=0` and supervision other than
  `lost`. An owned, cleanup-pending or observer run that has not been
  observed terminal is protected. A run with `lost` supervision counts as
  terminal for pruning, because no worker of this manager serves it and no
  later lifetime adopts it.
- A run that it names is the parent run of a request that is not terminal.
- An ask in it has no reply in the retained log.

A command that a segment names counts as its request and its run. The writer
keeps, for each sealed segment, the request, run and command identifiers and
the claim checks that its records name, and the latest time of its records. It
collects them as it appends and reads them once at open.

Each candidate takes one Store admission in the lock order file slot,
configuration, database, runs one read-only query over the identifiers of the
segment and then takes the leaf writer lock. Under that lock the writer
unlinks the segment file, moves the floor to the start of the next sealed
segment, synchronizes the segment directory, removes each claim-check file
that no retained record names and synchronizes the claim directory. The
bytes of the log drop by the segment and by those claim checks. A failure
after the unlink leaves the segment removed and its claim checks counted, and
the next open removes those files. A round runs outside every admission
transaction of a command, and each step stays within the five-second
allowance of its admission.

A round that does not obtain its admission within the allowance waits for
the next seal. Any other failure of a round is recorded once in the private
fault log as `manager-log prune` with `stopped` and the fixed name of the
failure, and the pruner stops for the lifetime. The log then grows as it did
without pruning. Only the log of the current stream is pruned. The logs of
earlier streams, which remain after a restoration, are not.

With no live work, a steady stream of appends keeps the log at most
(L - R) div 2 plus one segment. A long-lived run, a pending review or a request that
waits in the queue holds the floor, so the log can still reach L - R, and
the refusals of the next section apply. A crash does not hold the floor in
later lifetimes. A run that a restart left with lost supervision keeps
`terminal_observed=0`, because the manager reads no run store after a
restart, but its supervision makes it terminal for pruning. A command whose
receipt reply was never appended, after a crash between the commit and the
append or after a failed append, keeps an ask without a reply until the next
open of a serving lifetime answers it, as the section
[Orphaned asks](#orphaned-asks) states. A same-key replay appends no record.
The age trigger is evaluated only at the open and after a seal, so a manager
that does not seal keeps old segments until its next seal or restart.

The age trigger ties the floor to `replaySeconds`: while the log stays below
(L - R) div 2 bytes, the pruner removes no record that is younger than 604800
seconds. The byte trigger can move the floor above younger records, but only
above the records of terminal work. The reader reports the floor, and a
reply or a consent chain that crosses it is pruned and is not a failed
verification, as the
[broker contract](../runtime/BROKER.md#manager-log-reader) states.

The writer lock is a leaf lock. The manager takes no other lock while it holds
it. Before each append the writer checks that the path still names the file
that it opened, by device and inode. A mismatch, or a check that fails with an
I/O error, breaks the writer: it refuses every later append of the lifetime and
never reopens the path. The writer synchronizes each
`command`, `review` and `relay` record: it flushes the line and then
synchronizes the descriptor through `agentic_sync_private_descriptor`. It
flushes every other record.

The ceiling of the log is the configured `globalMutationLedgerBytes`, and the
sealed segments and the claim-check files count toward it. The log keeps the reserve of the command
ledger, R = min(L, 16 * C), which `mutationLedgerReserve` computes. Each record
has one of three classes. A `Refusing` record belongs to an ordinary command
that needs the record before a commit or a dispatch, and a failed append
refuses that operation. A `Following` record belongs to an ordinary command
after a commit. Records of these two classes stay within L minus R. A
`Reserved` record belongs to a cancel or to the manager itself, and it may use
the whole ceiling. An append that would pass its limit fails with a quota
failure, and the writer stays usable.

A failed append of a `Following` or `Reserved` record becomes a gap entry that
names the missing record by schema and identifiers. The writer keeps at most
256 named entries and counts the others. Before the next record that it can
append, it appends one gap notice that names those entries and the count. When
the gap notice cannot be appended, the writer does not attempt the record, and
that record fails as well. Gap notices are lost while every append fails, and
the entries that no notice names leave no trace when the lifetime ends. A
failed `Refusing` append leaves no gap entry. A test mode can construct the
writer with a fault that fails the appends that it selects, and
`withServingStoreWith` opens a serving lifetime with a given line codec and
fault. Production never passes a fault and always uses the strict codec.

The five manager bodies have strict codecs. Each decoder refuses an unknown or
a missing field and any value that its encoder does not write.

- A `command` body is the admitted request without its idempotency key: the
  operation, the profile, the method, the resource, the media type, the
  precondition, the JSON request body as its strictly decoded value, and a
  capture by identifier, SHA-256 and size. The capture bytes are not copied.
  The `command` body of a credential operation of the local administration
  channel is the operation, the client, the credential, the superseded
  credential of a rotation, and the label, scopes, profiles and expiry. The
  `command` body of a quarantine release is the operation
  `release-quarantine`, the quarantine identity, the request, and the cleanup
  evidence identity and digest.
- A `receipt` body is the frozen `CommandReceipt` JSON. The `receipt` body of a
  local administration operation is the frozen local administration response.
- A `review` body is the preparation identifier, the public review bytes and
  their SHA-256, the private binding bytes and their digest, the expiry and the
  five approval selectors. The decoder verifies both digests against their
  bytes.
- A `relay` body is the kind, start, discard or control, the manager run
  identifier, the native run identifier, the command identifier and the exact
  frame bytes, which are UTF-8 and at most `maxFrameBytes`. A start and a
  control name a manager run and a command. A discard names no manager run,
  and it names no command when the manager discards on its own.
- A `notice` body is a command change with its state and refusal, a review
  ending with its preparation and reason, a request ending with its request and
  cause, a lifetime notice, a shutdown notice or a gap notice. The causes of a
  request ending are `withdrawn`, `discarded`, `refused`, `invalidated`,
  `review-expired` and `preparation-failed`.

A `review` body holds the exact binding bytes, which name the frontend
invocation path, the run-root identity and the target arguments. No bearer
token, credential verifier, idempotency key or page token enters a record.

A transaction queues a notice that follows its COMMIT with
`noticeAfterCommit`. When the COMMIT succeeds, the Store appends the queued
notices in queue order, after the transaction outcome is final and while it
still holds the database lock, so a failed notice cannot make the committed
transaction uncertain. A rolled back transaction appends none, and a lifetime
without a manager log queues none. A transaction whose notices must follow a
later record takes them with `takePostCommit` and returns them as an opaque
`PostCommit` value, and its caller appends them with `appendPostCommit`. The
admission transaction of a command takes them, so they follow its receipt.
Each notice is a flushed record from the manager, never a `Refusing` record,
and a failed append leaves a gap entry.

A serving lifetime reads the configured `globalMutationLedgerBytes` before it
opens the database, and a configuration that cannot give its limits fails the
open. The lifetime notice follows the restart reconciliation at Store open. It
names the process generation, the number of rows that the reconciliation
changed in each category, and at most 1000 credentials with their client,
identifier, status, scopes and profiles, together with the number of
credentials that the list omits. A credential list that cannot be read, for
example because a row is malformed, fails the open.

The Store ends an orderly close with a shutdown notice that names the process
generation. A close is orderly when the Store is not poisoned and the action of
the lifetime returned or the operator stopped it. The command line delivers the
termination and keyboard signals of `--manager serve` to the owner thread
as `UserInterrupt`, which is how a serving manager stops. After the cleanup
of a stop by the termination signal, the process exits with status 0. A stop
by the keyboard signal propagates the interrupt, so the process ends as an
interrupted command. A lifetime whose
action failed in any other way, a poisoned Store, a
close that cannot prove worker cleanup and a later retry of that close write no
shutdown notice, so the log of such a lifetime ends without its stop. The
notice follows the release of every worker, and the close takes the file slot,
then the configuration and then the leaf writer lock. When the configuration
cannot give its limits at that point, the close completes without the notice
and then reports the configuration failure. Both notices are reserved records
from the manager to the manager, and a failed append of either becomes a gap
entry. The [command acceptance contract](COMMANDS.md#manager-log-records)
describes the `command`, `receipt` and `failure` records of a fresh command
and of a credential operation or a quarantine release of the local
administration channel, and its command notices. The [approval contract](APPROVAL.md#review-record) describes
the `review` record. The [admission contract](ADMISSION.md#manager-log-relays)
and the [controls contract](CONTROLS.md#manager-log-relays) describe the
`relay` records. The [admission contract](ADMISSION.md#manager-log-endings)
describes the review endings and the request endings.

`readManagerLog` reads the manager log of one stream, named by its active
file, as the account that owns its flow directory. It reads the sealed
segments in start order and then the active file, gives each entry its global
position and reports the retained floor. A reply whose ask lies below the
floor is marked pruned and is not checked against its ask. `joinFlows` joins
manager logs with run logs from the retained records. A join whose
counterpart lies below the floor has none and fails nothing, and the consent
of a start relay whose review or approve command lies below the floor is
pruned: it is neither verified nor failed. The pruner keeps the records of
live work, so this happens only for terminal work. The
[broker contract](../runtime/BROKER.md#manager-log-reader) states what the
reader verifies, and the `agentic-run flow` verb prints each entry with its
global position and a summary that names the floor of each manager log. The
reader writes nothing, and the Store ledger remains the authority on
commands, reviews and requests.

`readManagerWindow` reads one positioned window of the manager log of a
stream. It starts in the sealed segment or the active file that holds the
position, continues across segments within the window limits, and reports the
retained floor. It never takes the writer lock. The protected resource
`GET /v1/routes` serves windows of the manager log of the current stream in
this way, as JSON batches and as a route stream, under a Store file loan that
each batch returns before its first network write. The [protocol document](../doc/api/README.md) states which records each
credential receives.

In the mode `routes`, the service fixture checks `GET /v1/routes` after one
mixed run. A control credential of the profile receives the enqueue command
and its receipt, the review, the approve command and its receipt and the start
relay, and every served record equals the entry that `agentic-run flow` reads
at the same position. The lifetime notice and the administration records are
gaps. An observe-only credential and a control credential of another profile
receive no record, and their cursors advance. The fixture then stops the
manager, moves the active file to its segment name as the writer seals it,
and starts the manager again. A cursor of the first lifetime resumes across
the sealed segment. It seals the second lifetime too and removes the oldest
segment as the pruner removes it. `oldestCursor` then names the new floor,
and a cursor below it receives 410 `cursor-expired`.

The service fixture `manager/test/service_http.py` checks the manager log of
the TUI service journey. In the mode `tui-journey`, after the TUI session and
after the manager process exits, it runs `agentic-run flow` on the flow
directory and on the run store of the journey. The verb must verify both logs
and the consent of the start relay. The fixture then asserts each fact with
its own `FLOW-ASSERT` message: the journey credential and client send every
command, and the manager log holds the enqueue command and its receipt, the
review, the approve command with its five review selectors and the start
relay. The run log holds the person question. The manager log holds the
answer command with the JSON value `false`, the retry command, and one
relayed control for each of the two commands. Each relayed control arrives as
a run-log control from the manager with its acknowledgement event. The run-log
answer names the manager and the answer command, and the reader joins it to
that command. The run log has its terminal record, and no ask follows it. Each
lifetime in the manager log has its shutdown notice. The fixture prints the size of the
manager log and the storage ratio of the run log, which must be at most 2.5.

The control mode `tui-flow-approve-fault` follows the journey until the
approval. Just before the TUI sends `y`, the fixture renames the manager log
into another private directory, so the identity check of the writer fails the
append of the approve command. The manager must refuse the approval with
`storage-unavailable`, and the TUI must show that refusal. The control then
checks that the manager recorded that response in its private fault record,
that the request stays in review, that the ledger holds no accepted
approval, that the renamed log holds no approve command and no relay, that
the writer creates no new log, and that no run store exists. It fails with the
message "FLOW-FAULT the approve append failed and the manager refused the
approval with storage-unavailable". The control adds no production hook and no
environment variable.

### Growth, open refusals and recovery

The manager log of a stream is its sealed segments in
`flow/sealed/<stream>/`, in start order, followed by the active file
`flow/<stream>.ndjson`, with its claim-check files in `flow/claims/<stream>/`.
Positions are global across the segments and across Store lifetimes. The
writer seals the active file when an append would take it above
S = max(65536, (L - R) div 16), where L is the configured
`globalMutationLedgerBytes` and R the reserve of the command ledger.

The pruner of the section [Pruning](#pruning) removes the oldest sealed
segments while a trigger holds and no live work needs them. The age trigger
holds when the newest record of the segment is more than 604800 seconds old,
the value of `replaySeconds`. The byte trigger holds when the log and its
claim checks hold more than (L - R) div 2 bytes. A segment is protected when it
names a request that is not terminal, a run with `terminal_observed=0` whose
supervision is not `lost`, the parent run of a request that is not terminal,
or an ask without a reply. The open of a serving lifetime answers each
orphaned ask of an earlier lifetime first. The
newest sealed segment and the active file are never removed. The retained
floor is the start of the oldest remaining sealed segment, or 0 before the
first seal, and the writer refuses a reply that names a position below it.

When live work holds the floor and the log and its claim checks reach L minus
R, every ordinary command and every review publication is refused with
`storage-quota`. The cancel reserve is unchanged: a cancel and the records of
the manager itself can still use the reserve R. The F16 gate measured 22193
bytes of manager log for one simple TUI journey. At a ceiling of 64 MiB
(L = 67108864, the value of the sample configuration), R is 2097152 and L
minus R is 65011712 bytes, which holds about 2929 such journeys when live work
holds the floor at 0.

Only the log of the current stream is pruned. A restoration rotates the
stream identity, and the logs of earlier streams stay in `flow/` as they
were. They do not count toward the ceiling of the current log, and the
operator archives or removes them.

The pruner does not prune the SQLite command ledger. The table
`command_ledger_usage` holds the charge of every row of `commands`. The
triggers `command_charge_insert` and `command_charge_update` keep it current,
and retirement shrinks a row to its tombstone charge, which stays charged.
`Commands.checkCapacity` refuses an ordinary command with `storage-quota` when
the charge exceeds L minus R minus one command capacity, and a cancel when it
exceeds L minus one command capacity. So the ledger, and not the manager log,
still bounds steady-state admission, under the same `globalMutationLedgerBytes`
ceiling. No serving lifetime runs `retainReceipts`, so the charge does not
fall, and an ordinary restart does not change it. When the charge reaches the
ceiling, ordinary commands therefore stay refused with `storage-quota` across
restarts, while a cancel can still use the reserve R. The operator raises
`globalMutationLedgerBytes` to admit ordinary commands again.

A crash leaves a log that the next open accepts:

- A crash between the rename of a seal and the creation of the new active
  file leaves no active file. The next open creates it at the position after
  the last sealed record.
- A crash in a prune before the unlink leaves the segment in place. A crash
  after the unlink and before the removal of its claim-check files leaves
  those files. The next open removes each claim-check file that no retained
  record names. The floor after the open is the start of the oldest remaining
  sealed segment.
- A final line of the active file without its newline denotes no record, and
  the open truncates it.

`openManagerFlow` refuses to open a log in two cases:

- The sealed segments and the active file hold more bytes than the
  configured `globalMutationLedgerBytes`,
  for example after the operator lowers that limit.
- A complete line of the log fails strict decoding, a sealed segment does not
  end with a newline, the segment directory holds a name that is not a
  segment name, or a sealed segment does not start at the position after the
  last record of the segment before it.

In both cases, and after any other failure of the open, the writer of the
lifetime refuses every append. A writer that breaks during a lifetime, because
the path no longer names the file that it opened, refuses every later append
of that lifetime in the same way. Each ordinary command and each review
publication is then refused with `storage-unavailable`, because its
`Refusing` record cannot be appended, and the command leaves no row in the
ledger. A cancel still commits, it still stops the run, and it has no record
in the log. The shutdown notice of such a lifetime is not appended either, so
its log ends without its stop. The next lifetime appends no gap notice for
the entries of the broken lifetime. The serving lifetime records the reason once in the private
fault log at open, as one of three fixed words: `oversized`, `undecodable` or
`io-failure`. The line has the form
`manager-fault <time> manager-log open class=flow <word>`. It holds no path,
no stream identity, no exception text and no record content. The text of the
exception is dropped, and every failed append of the lifetime carries only the
same word.

The operator recovers as follows:

1. Stop the manager.
2. Move `flow/<stream>.ndjson` and the directories `flow/sealed/<stream>/`
   and `flow/claims/<stream>/` out of the manager root into a private archive
   directory, keeping their relative layout. For an oversized log,
   the operator can instead raise `globalMutationLedgerBytes`.
3. Start the manager. The next serving lifetime creates a new log, which begins
   with its lifetime notice, and admits commands again.
4. Read the archived log with `agentic-run flow`.

The positions of the new log start again at 0, and a reply in it never names
a record of the archived log. When the active file was moved away during a
lifetime, step 2 moves the remaining directories. While sealed segments of the
stream remain in `flow/sealed/<stream>/`, the next lifetime instead creates
the active file at the position after the last sealed record.

The `manager-command-check flow` mode checks both refusals and the recovery.
It also measures the synchronized `command` record. On 2026-09-29, on the local
macOS development machine at `-N8`, 60 synchronized appends of admitted
command records took a median of 5.511 ms and a maximum of 7.523 ms. The
admission of an ordinary command with its synchronized record took a median of
7.817 ms and a maximum of 235.933 ms over 60 commands. The mode prints both
series on each run and asserts no threshold.

The `storage` mode of `manager/test/service_http.py` checks these endings
through four lifetimes of the running manager with the mixed fixture:

1. With `globalMutationLedgerBytes` set to R plus four command capacities,
   the smallest value that admits the four commands of one run, a run waits
   at its person question. The next ordinary command is refused with
   `storage-quota` and leaves no ledger row. A cancel of the run is accepted
   and ends the run cancelled.
2. After an ordinary restart, an ordinary command is still refused with
   `storage-quota`, and the ledger keeps its charge. The flow verb verifies
   both lifetimes, the second lifetime notice follows the shutdown notice of
   the first, and the verb reports the floor.
3. With the ceiling raised, the fixture renames the active manager log away
   while a run waits at its person question. An ordinary command is refused
   with `storage-unavailable` and leaves no ledger row, a cancel ends the run
   cancelled, and the writer creates no new log.
4. After the operator moves the rest of the log out, the flow verb verifies
   the archived log, whose last lifetime has no shutdown notice and no record
   of the cancel. The next lifetime begins a new log at position 0 with its
   lifetime notice and no gap notice.

The same mode checks a removed and a corrupted result, as the
[artifact contract](ARTIFACTS.md#outputs-and-verification) describes.

## Worker cleanup ownership

Worker lifetimes use a separate bounded registration, not the file-operation
slot. The Store retains their actual Runtime ProcessGroup tokens, private roots
and duplicated leases. Closing fences new work and stops/joins outside registry,
configuration and database locks. Only owner-published Right completion proves
cleanup. Unproven entries retain the configuration storage slot and leases even
when close raises, so an outer bracket cannot accidentally admit another Store.
The narrow retry path revisits only original tokens and never clears published
failure or reconstructs a PID. See [the worker contract](WORKERS.md).

## Checkpoints and integration ceiling

`checkpointStore` performs a bounded passive checkpoint and returns SQLite's
busy flag, log pages, and checkpointed pages. A pinned reader can prevent full
progress. No truncation or durability success is inferred from partial progress.
The later service coordinator must schedule and monitor this operation. Automatic
checkpointing is disabled so it cannot hide checkpoint work inside a mutation.

WM-009 supplies storage representation and transaction mechanisms. The
[command layer](COMMANDS.md) supplies WM-010 current credential/profile checks,
receipt replay, logical ledger reservations, and one-shot dispatch permission.
Worker authority, recovery fencing and safe reservation release remain with their
existing owners. The retention operations below use this Store, while service
checkpoint scheduling remains with the later coordinator. The offline backup and restoration operations above use
SQLite's coherent snapshot facility rather than copying a live database file.
WAL and FULL are verified settings, not power-loss, filesystem, or hardware test
evidence.

`manager/ci/store.sh` builds the real Cabal executable and runs separate N1 and N8
checks against SQLite and native service leases. The tests include the installed
public facade, relational constraints, migration rollback, commit failure,
strict bounds, cancellation, bounded admission waits, and pinned-reader checkpoint
progress.
Configuration and discovery regression gates remain separate. These checks do
not certify G1, worker containment, a deployed service, or the withdrawn SQLite
directory-replacement obligation.

## Admission lifetime registration

Store retains one admission stop-and-join registration independently of its
sixteen physical Worker slots. Closure fences new registration, signals the
controller, and joins it outside database and registry locks. The controller
retains its own bounded jobs and original Worker handles rather than deriving
physical ownership from reservation rows.

The version-four migration preserves old resource strings as operator-domain
keys and initializes the queue clock from existing unsigned ordinal history.
It adds nullable queue/input association fields without rewriting old request
payloads or creating accepted-enqueue authority. Partial migration rolls back
both the resource-key rebuild and the new columns. Old reservations retain
their slots and generation, and a new controller cannot adopt them.

When Store closure prevents the admission owner's final SQL transaction, physical
workers are still stopped and joined. The controller reports unresolved persistence
and leaves durable claims in place. This is separate from uncertain physical cleanup,
which retains the original Worker registration, root, lease and configuration slot
under the existing quarantine rule.

## Final monotonic acceptance check

The admission owner can loan a scoped opaque `CommitDeadline` carrying its actual
monotonic clock and deadline. `enforceCommitDeadline` arms one fixed check in a
writable transaction from the same Store generation. Store checks its active scope
and current monotonic time after bounded work and invalidations, immediately before
COMMIT. Expiry raises StoreDeadline and rolls back the transaction. This facility
adds no general IO lift, client clock or caller-supplied acceptance predicate.

The check is a logical acceptance point, not a promise that time cannot advance
during commit IO. A confirmed matching start intent is not revoked afterward,
while uncertain commit retains the existing poisoned-connection discipline.

## Exact approval association

Version five adds immutable start_intents linking original command, approving client,
request, preparation, run, reservation, process generation and worker identity.
It preserves existing records and creates no live capability during migration.
The public managerStore compatibility remains version one.

CommitDeadline has a fixed prepared-worker variant. It retains the original
registration, Runtime ProcessGroup and shared actual Worker lifecycle cells.
Final validation is nonblocking and checks the original registration/process
association, current prepared phase and absence of known stop/failure alongside
the scoped clock guard. Detected loss refuses before commit, without waiting for
process/pipe cleanup inside SQL. A later process death is not retroactive revocation
or a physical commit-time liveness guarantee.

## Validated ingestion projections

Version six makes ingestion rows immutable and retains the complete original-wire
prefix. State binds each input to its trusted profile, root and native run, checks
its original SHA256 and sequence, and uses the Runtime checkpoint append operation
and its shared stepRunSnapshot fold. The run projection is a versioned manifest of
that immutable sequence-zero prefix, with its boundary and shared snapshot digest.
It is not an independently editable snapshot JSON object.

Each appended envelope, manifest, decision observation, reference-only artifact and
bounded invalidation set commits together. First committed Runtime evidence also
advances a bound managed request from start-pending to associated, with its request
revision, reservation revision and request invalidation in that transaction.
Observer-only runs have no request transition. Original approval facts remain
immutable. Matching original-byte duplicates change
nothing. Conflicting duplicates, gaps, wrong associations and invalid terminal
histories refuse without replacing the valid prefix. Output tails, authored traces,
bills and attribution remain those of Runtime. Referenced content is not verified
content, and a decision observation is not a control effect or answer reservation.

Restoration captures a fixed prefix boundary in one bounded read, then reads each
immutable original record in at most three 512KiB slices and restores through Runtime.
The shared decoder bounds the payload to 1MiB, excluding its final LF. Evidence
retains and hashes the complete original record, including that LF. Unframed
Runtime differential fixtures remain supported without normalizing other whitespace.
The resulting digest and boundary must match. Both the canonical Runtime checkpoint
and original-wire evidence have a 64MiB bound per run. Store statement, input, row,
result and time limits remain unchanged. Exceeding a bound refuses without truncating
the prefix. The initial implementation replays the full prefix per append and has
quadratic total replay cost. No mutable projection cache can acknowledge an input
that failed to commit. A later cache must preserve this reconciliation boundary.

Admission loans the original AcceptedStart association and Worker queue head to
State. Physical cleanup need not wait for the database, and buffered evidence remains
readable after cleanup through that original opaque object. Callback failures retain
the head, including the commit-before-return window that becomes a matching duplicate
on retry. Association can commit while original cleanup publication remains pending.
Original finalization recognizes only the exact post-start association revision as
a successor to its retained revision fence, with unchanged reservation, generation,
command and cleanup-kind checks. Pre-start stale guards remain unchanged.
Storage failures propagate explicitly, with no automatic retry, subscriber
consumption or invented Runtime success. Supervision, control, artifact verification
and restart operations use their existing owners.

## Core quotas and retention

Schema eleven adds event accounting, eligibility observations and validated terminal
facts. Registered client identities and credential identities cannot be deleted or
reassigned, and retired clients cannot be revived. These constraints preserve replay
and credential identity independently of content collection.

`withStoreReader` reserves materialization capacity against the current installed
`globalDatabaseReaders` limit before invoking a callback. When every place is taken, it
waits for a place within the admission deadline of its request, outside the
configuration guard and the Store gate, and a capacity that stays full until
that deadline ends is `StoreLimit`. The waits of reader admission for the
configuration guard, the Store gate and a place share that deadline. Reloaded limits apply to
new readers even while older readers finish. Acquisition releases configuration and
SQL ownership before the callback, and completion or an exception returns capacity.
State uses this scope for complete prefix replay and ingestion. Its profile projection
scope acquires reader capacity before entering the current configuration guard,
validates profile and client authority before replay, and retains both reader capacity
and configuration while it materializes. A response returns both, and the file
slot of its owner, before its first network write, as "Internal transactions
and bounds" describes. SQL still has its single admission slot, which waits
within each action's allowance. Neither reader pressure nor
retention consumes the separate
original-worker stop cells or the cancellation ledger reserve.

The existing owners continue to enforce per-client and global drafts, per-request
input holdings, global capture holdings, the hundred-request queue, current global
execution reservations and command ledger/rate limits. ConfigurationLimits is one
current global configuration, not an allocation multiplied by profile count.
Runtime frames, diagnostics, artifact reads, one-MiB views and sixty-four-MiB
checkpoints retain their existing bounds. The core does not allocate transport
connections or materialized page sets. Their later owners must enforce the frozen
global connection/page-set caps, two sets per client and sixty-second expiry.
No HTTP, SSE or page-token implementation is provided here.

`retainEvents` advances at most 256 expired records per call. Appending an invalidation
also advances a bounded prefix, and refuses rather than committing above 268435456
charged bytes. The charge includes the ASCII event fields and 256 bytes of framing
allowance per record. The age limit is 604800 seconds using SQLite time. A large age
backlog can require several bounded maintenance calls, without retaining a transaction
between them. Old schema-ten events start their age interval at migration rather
than acquiring an invented historical timestamp.

Deletion, byte accounting and the last-removed sequence in retained_floor commit
atomically. `readRetainedEvents` maintains that boundary and returns at most 64 complete
events under one transaction. Wrong stream, cursor before the retained floor and
cursor beyond the high-water mark are distinct results. Expired records still awaiting
a later maintenance page cause retention loss rather than a successful expired batch.
A missing sequence within a retained batch is an integrity refusal. No database
transaction or cursor escapes to a consumer, and no history, snapshot, command,
decision, capture or artifact is deleted by event retention.

State records terminal_observed only from the shared validated Runtime terminal fold.
Physical cleanup, supervision loss and reservation release cannot substitute for that
fact. Historical schema-ten runs initially lack it. `observeRetainedTerminal` explicitly
replays their original immutable prefix under the reader cap, then rechecks the same
association and projection boundary before recording a terminal observation. Ordinary
projection reads remain observational. Missing or nonterminal evidence records nothing,
while corrupt, changed or over-budget evidence refuses. A new historical proof resets
linked receipt eligibility rather than inventing an old inactivity date.

The coordinator can call the bounded event, receipt and capture operations between
ordinary work. Their continuation keys are scan positions, not permissions or replay
tickets. These operations have no background scheduler and no remote prune endpoint,
and the manager-log pruner of the section [Pruning](#pruning) is separate from them. Logical quotas do
not bound arbitrary operator-created files, SQLite journal overhead or total process
heap usage, and uncertainty may retain charges until new work must refuse.

The Store quotas mode covers current-limit reader admission, a reader that
waits for a returned place, a full capacity that refuses after the whole
allowance, actual default event-byte saturation, exact accounting, retained
batches, domain/history separation and atomic floor rollback. Existing draft
and command gate entries include receipt/collection and preflight-pressure
checks. Existing native ingestion and control entries check terminal evidence
separately from physical cleanup and unresolved cancellation.
