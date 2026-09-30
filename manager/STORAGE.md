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
`StoreDeadline` and never runs. An admitted action executes once. A protected
read whose authorization observation meets a concurrent commit reads again under
the newer generation, as `COMMANDS.md` describes. A new attempt starts only
while one five-second allowance lasts, and the Store actions of each attempt
keep their own allowances. The gate admits waiters in order, and each holder
is bounded by its own earlier allowance. The configured positive reader
allowance is an upper bound, not a promise of parallel readers. An escaped
store handle refuses after its callback scope. The scoped owner waits for
in-flight database and file operations and their joined cleanup before
closing SQLite and releasing the lease. File operations
use one separate slot and retain a private root plus lease duplicate. An
ordinary file operation waits for the slot within a fresh five-second
allowance, and a slot that stays held for the whole allowance is `StoreBusy`.
A coordinator probe does not wait. When the slot is held, it returns at once
and proves that its callback did not enter.
Their lock order is file slot, configuration, then database.

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

Operations require the threaded RTS. Cancellation repeatedly interrupts the
original SQLite operation until its thread joins. A single interrupt can precede
statement execution and have no effect. The interrupter also joins before rollback,
connection reuse or close. Cleanup cannot abandon a connection that SQLite still uses. Final close is
shielded against further asynchronous exceptions. Cooperative budgets do not
promise an absolute OS IO deadline or a hard total SQLite heap bound. A stalled
filesystem can extend joining and cleanup beyond the nominal budget.

## Restart and offline restoration

An ordinary Store open acquires the existing configuration storage slot and
service lease, validates the private files, migrates the schema, and creates a
fresh process generation. Epoch and stream identity survive. Old live
preparations become invalidated, unresolved reservations remain quarantined,
and owned runs become lost supervision without changing their Runtime evidence.
Uncertain starts and controls remain unresolved with their original request and
receipt bytes. No stored identifier becomes a dispatch or cleanup handle.
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
with `withServingStore`. The log is the private file `flow/<stream>.ndjson` in
the manager root, and its claim-check files are the private files
`flow/claims/<stream>/<sha256>`. Each stream has its own claim directory, so
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
It reads the existing log, which must be at most the configured
`globalMutationLedgerBytes`, and decodes every complete line with the strict
codec. The positions of a new lifetime continue those of the earlier
lifetimes, so a reply can name an ask that an earlier lifetime appended. A final
line without its newline denotes no record, because its append never
completed, and the writer truncates it. A log that cannot be opened gives a
writer whose every append fails.

The writer lock is a leaf lock. The manager takes no other lock while it holds
it. Before each append the writer checks that the path still names the file
that it opened, by device and inode. A mismatch, or a check that fails with an
I/O error, breaks the writer: it refuses every later append of the lifetime and
never reopens the path. The writer synchronizes each
`command`, `review` and `relay` record: it flushes the line and then
synchronizes the descriptor through `agentic_sync_private_descriptor`. It
flushes every other record.

The ceiling of the log is the configured `globalMutationLedgerBytes`, and the
claim-check files count toward it. The log keeps the reserve of the command
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
  credential of a rotation, and the label, scopes, profiles and expiry.
- A `receipt` body is the frozen `CommandReceipt` JSON. The `receipt` body of a
  credential operation is the frozen local administration response.
- A `review` body is the preparation identifier, the public review bytes and
  their SHA-256, the private binding bytes and their digest, the expiry and the
  five approval selectors. The decoder verifies both digests against their
  bytes.
- A `relay` body is the kind, start or control, the manager run identifier, the
  native run identifier, the command identifier and the exact frame bytes,
  which are UTF-8 and at most `maxFrameBytes`.
- A `notice` body is a command change with its state and refusal, a review
  ending with its preparation and reason, a request ending with its request and
  cause, a lifetime notice, a shutdown notice or a gap notice. The causes of a
  request ending are `withdrawn`, `discarded`, `refused`, `invalidated`,
  `review-expired` and `preparation-failed`.

No bearer token, credential verifier, idempotency key, page token or local path
enters a body.

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
as `UserInterrupt`, which is how a serving manager stops. A lifetime whose
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
and of a credential operation of the local administration channel. The
[approval contract](APPROVAL.md#review-record) describes the `review` record.
The relay append point is not connected.

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
waits for a place within a fresh five-second allowance, outside the
configuration guard and the Store gate, and a capacity that stays full for the
whole allowance is `StoreLimit`. Reloaded limits apply to
new readers even while older readers finish. Acquisition releases configuration and
SQL ownership before the callback, and completion or an exception returns capacity.
State uses this scope for complete prefix replay and ingestion. Its profile projection
scope acquires reader capacity before entering the current configuration guard,
validates profile and client authority before replay, and retains both reader capacity
and configuration through the response callback. File responses retain
the existing single Store file slot, while SQL still has its single admission
slot, which waits within each action's allowance. Neither reader pressure nor
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
tickets. There is no background scheduler or remote prune endpoint. Logical quotas do
not bound arbitrary operator-created files, SQLite journal overhead or total process
heap usage, and uncertainty may retain charges until new work must refuse.

The Store quotas mode covers current-limit reader admission, a reader that
waits for a returned place, a full capacity that refuses after the whole
allowance, actual default event-byte saturation, exact accounting, retained
batches, domain/history separation and atomic floor rollback. Existing draft
and command gate entries include receipt/collection and preflight-pressure
checks. Existing native ingestion and control entries check terminal evidence
separately from physical cleanup and unresolved cancellation.
