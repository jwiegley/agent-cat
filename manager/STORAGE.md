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

One connection serves reads and writes. Admission is fail-fast, with one active
operation and no waiting queue. The configured positive reader allowance is an
upper bound, not a promise of parallel readers. An escaped store handle refuses
after its callback scope. The scoped owner waits for in-flight database and file operations and their
joined cleanup before closing SQLite and releasing the lease. File operations
use one separate fail-fast slot and retain a private root plus lease duplicate.
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

`PRAGMA user_version` holds internal schema version 6. Startup accepts versions
zero through six, and rejects other versions before changing journaling or
schema. Fresh initialization, command-ledger additions, and the explicit literal
chunk/upload migration and admission additions execute DDL, metadata and version
publication in one immediate transaction. Version-one DDL and the version-two
and version-three migrations remain unchanged. The frozen public managerStore compatibility stays at one.
Failure rolls that transaction back and never publishes a connection. The
metadata row separately stores authority epoch, stream identity, stream sequence,
retained floor, and service revision. Epoch and stream are random 256-bit
identifiers that survive ordinary reopen. A fresh random process-generation
identifier exists only in the new store lifetime.

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

Operations require the threaded RTS. Cancellation repeatedly interrupts the
original SQLite operation until its thread joins. A single interrupt can precede
statement execution and have no effect. The interrupter also joins before rollback,
connection reuse or close. Cleanup cannot abandon a connection that SQLite still uses. Final close is
shielded against further asynchronous exceptions. Cooperative budgets do not
promise an absolute OS IO deadline or a hard total SQLite heap bound. A stalled
filesystem can extend joining and cleanup beyond the nominal budget.

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
Worker authority, recovery fencing, safe reservation release, retention floors,
wider total-storage quotas, collection, and checkpoint scheduling remain with
their owning packages. There is no
backup or restore operation in this unit. WM-020 must use SQLite's coherent
snapshot facility rather than copying a live database file. WAL and FULL are
verified settings, not power-loss, filesystem, or hardware test evidence.

`manager/ci/store.sh` builds the real Cabal executable and runs separate N1 and N8
checks against SQLite and native service leases. The tests include the installed
public facade, relational constraints, migration rollback, commit failure,
strict bounds, cancellation, busy refusal, and pinned-reader checkpoint progress.
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
consumption or invented Runtime success. Later owners supply supervision policy,
control endpoints, artifact verification, retention and restart orchestration.
