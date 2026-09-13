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

`PRAGMA user_version` holds internal schema version 3. Startup accepts versions
zero through three, and rejects other versions before changing journaling or
schema. Fresh initialization, command-ledger additions, and the explicit literal
chunk/upload migration execute DDL, metadata and version publication in one
immediate transaction. Version-one DDL and the version-two migration remain unchanged. The frozen public managerStore compatibility stays at one.
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
| Reservations | Unique execution slots and exclusive resource keys support WM-013 and cleanup quarantine. |
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
reuse capacity without deleting preparation history. Choosing when cleanup
makes release safe remains WM-013's responsibility.

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

Operations use the pinned public `SQL.interruptibly` facility and require the
threaded RTS. Cancellation interrupts SQLite and joins its operation thread.
Cleanup cannot abandon a connection that SQLite still uses. Final close is
shielded against further asynchronous exceptions. Cooperative budgets do not
promise an absolute OS IO deadline or a hard total SQLite heap bound. A stalled
filesystem can extend joining and cleanup beyond the nominal budget.

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
