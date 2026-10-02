# Command acceptance and receipts

`Agentic.Manager.Commands` implements the internal WM-010 command mechanism over
`Store.runTransaction`. It does not create HTTP routes, provision credentials,
interpret workflows, or reconstruct worker authority. The public Manager facade
exposes trusted configuration, scoped storage composition, and local credential
administration. It does not expose SQL or dispatch-by-ID operations.

## Current authority

`authenticateCredential` bounds presented bearer bytes before hashing them with
SHA-256 and comparing against actual credential verifiers. The returned opaque
`CredentialProof` contains no retained bearer and has no Show, JSON, Generic, or
public constructor. Its explicit NFData instance does not expose its fields.
Length checks do not measure entropy. The local credential operations below own
secure generation and rotation. The local channel reaches the original Store,
while protected HTTP authentication remains a separate integration obligation.

Every authorization check inside a transaction verifies the actual in-memory
store generation, current credential verifier, registered client association,
credential expiry, revocation, client retirement, and requested profile scopes.
Expiry uses trusted SQLite time. A proof cannot authorize a different store or a
new lifetime, even when credential rows survive ordinary reopen. Registered
client identity keys the ledger, so a newly verified replacement credential for
that client can retrieve an existing receipt without creating another intent.

Store retains the actual InstalledConfiguration association. The hidden
configuration callback acquires the existing configuration lock without waiting,
then holds it through the store transaction. Lock order is configuration followed
by store. Reload, discovery, and close cannot interleave with admission. Command
code never receives a caller-selected replacement registry or stale quota value.
For ordinary callers, an unavailable lock or writer produces explicit
storage-unavailable refusal. A caller may retry the exact same key after such a
refusal, never substitute a new key to discover an outcome.

One submission, preflight or receipt read is one request with one five-second
admission deadline, as `STORAGE.md` describes. Its wait for the configuration
guard, its wait for the Store gate of the identity read and its wait for the
Store gate of the transaction share that deadline. A request that is not
admitted when the deadline ends is refused as `storage-unavailable`, and its
mutation never runs. The retained `CommandAttempt` and `DispatchTicket` keep
the store without that deadline, so a later reconciliation or dispatch step
starts a fresh deadline.

The original terminal owner can explicitly select bounded Store admission for
reconciliation, retained dispatch coordination and effect publication through
the corresponding `WithAdmission` functions. These retain the same opaque
CommandAttempt or DispatchTicket and the same lifetime, epoch, revision and
once-only dispatch fences. Each admitted Store action executes once within its
existing allowance, including time spent waiting. No command, SQL failure,
uncertain publication or native callback is replayed.

Receipt GET first checks current credential validity. An authorization-filtered
metadata query selects no body or receipt. The same transaction checks current
profile visibility and observe plus all scopes derived from the stored original
operation before reading the projection. Missing or unauthorized metadata is not
an existence oracle. Knowing a command ID, client ID, or old key grants no access.

## Local credential administration

`RUNNER --manager admin --config ABSOLUTE_FILE` reads one strict version-one
JSON request through stdin EOF and writes one bounded JSON result. Duplicate
fields, unknown fields, unknown operations, malformed input, and oversized input
refuse before dispatch with `operation: null`. Errors do not reflect input or
parser diagnostics. The implemented operations are `issue-credential`,
`rotate-credential`, `revoke-credential`, `list-credentials`, `status`,
`check-store`, `check-quarantine`, and `release-quarantine`. The other
recognized operations, `reload-profiles`, `drain`, `shutdown`, `backup`, and
`restore`, receive `state-conflict` before the CLI reads the configuration.

`status` and `check-store` are read-only. They change no Store row and append
nothing to the manager log. `status` returns the authority epoch and stream
identity of the Store, the process generation of the lifetime that answers, and
the count of reservations that are not released, quarantined reservations
included. Its `state` is `serving` through the live channel and `stopped` in
offline administration. `check-store` runs the SQLite quick check on the open
Store and reports `valid` or `corrupt`. It also lists, in identity order and at
most 256, the identities of the reservations in state `quarantined` and of the
claims that a restoration carried forward. A reservation identity is its
quarantine identity. When offline administration cannot open the Store,
`check-store` reports `unavailable` with no identities. A restart quarantines
each reservation that the previous lifetime held, so these operations show the
claims that wait for cleanup evidence.

`check-quarantine` takes one `quarantineId` from `check-store` and reports the
cleanup evidence of that claim with the frozen result `quarantineId`, `state`,
`cleanupEvidenceId`, `cleanupEvidenceDigest`, `processGeneration`, and
`expiresAt`. The state is `clean` when the reservation never launched a run
(evidence `no-launch`), when the run store of its run holds the terminal record
of the runtime (evidence `terminal-record`), or when its run has no terminal
record and the check can take the exclusive lock of the `owner.lock` file of
the run (evidence `owner-released`). It is also `clean` when the run directory
of its run is absent, or holds no `owner.lock`, no `supervisor-manifest.json`
and no run store, because the inner frontend worker ended before it locked the
run (evidence `owner-never-locked`). The state is `cleanup-required` when its
run has no terminal record and that lock is held or not a private regular
file, or when `owner.lock` is absent while the supervisor manifest or the run
store is present. It is `unverifiable` when the run store exists but cannot
be read or the identity names a claim that a restoration carried forward. A `clean` answer carries the evidence identity, the lowercase
SHA-256 digest of the canonical JSON facts, and an expiry 600 seconds after the
check. The other states carry `null` in these three members. The facts include
the process generation of the answering lifetime, so two checks in one
lifetime return the same identity and digest, and a new lifetime gives a new
digest. An unknown identity and a reservation that is not quarantined refuse
with `state-conflict`. The check is read-only like `status`, and it reads or
signals no stored process identity. The
[manager-loss section of WORKERS.md](WORKERS.md#manager-loss-and-restart)
states the evidence rules and the facts of each rule.

`release-quarantine` takes a `quarantineId` and the `cleanupEvidenceId` and
`cleanupEvidenceDigest` that `check-quarantine` returned for it, and releases
the reservation for reuse. It takes the Store file slot, the configuration
guard and the database in that lock order, within one five-second admission
deadline for the three waits. Under the held file slot and configuration guard it computes the
cleanup evidence again with the current process generation, as
`check-quarantine` does. An unknown identity and a reservation that is not
quarantined, a reservation that a release already released included, refuse
with `state-conflict`. Evidence that is not `clean`, or whose identity or
digest differs from the supplied values, refuses with `cleanup-unverified`. A
claim that a restoration carried forward is `unverifiable`, so its release
refuses with `cleanup-unverified`. A launched claim without a terminal record
whose `owner.lock` is held is `cleanup-required`, so its release also refuses
with `cleanup-unverified`. A release with `owner-never-locked` evidence fences
the run under the held file slot before its transaction: it ensures the
private run directory `runs/<run>` in the recorded run root and creates
`runs/<run>/owner.lock` exclusively, then closes the lock, so a late inner
frontend worker fails its own exclusive create and never starts the run. When
a late worker created `owner.lock` first, the release classifies the claim
again and refuses with `cleanup-unverified` unless the claim is `clean` with
the supplied evidence. A refusal changes no Store row and appends
nothing to the manager log. A fence stays after a refusal, and the next check
of the claim gives `owner-released` evidence. Otherwise one transaction deletes the resource
keys of the reservation, sets the reservation `released` with no slot,
advances the revision of its request, sets a `reserved` request admission to
`released` and appends the `request.changed` invalidation of the request, as
the release of a terminal run does. The result is the frozen `quarantineId`
with `state` `released`. The run of the reservation keeps its `lost`
supervision, and no run store changes. After COMMIT on the live channel, the
manager notifies its admission controller, so a request that waits for
capacity is prepared without another client command. Offline administration
has no running controller to notify.

When `administrationRoot` is omitted from the trusted operator configuration,
the CLI acquires the existing configuration lease and original Store. It refuses
an already-owned installation and retains ordinary Store restart reconciliation.
When that directory is configured, the CLI sends the same request to its private
Unix socket and never opens a second Store or falls back after a channel failure.

Trusted embedding uses `withLocalAdministration store action` to retain a local
channel during the action. The original Store supplies its installed directory
binding and retains the configuration lease. A separate exclusive directory
lease prevents duplicate listeners and authorizes removal of a stale socket name.
Regular files and symbolic links are not removed. A scoped listener removes only
its own observed socket entry, and its original socket and Async owners finish
before the directory loan ends. No configuration or Store admission lock spans
the listener lifetime.

The directory is private, the socket is mode 0600, and both endpoints check the
peer's operating-system UID. Processes in that account share this local
administrative authority. Bearer proofs, client IDs and stored credential IDs
do not provide it, and there is no HTTP administration route.

One request is processed at a time through stdin-equivalent EOF framing. Frames
are limited to 2 MiB and replies to the frozen 1 MiB ceiling, including the CLI
newline. Server reads and reply writes each have a five-second connection IO
deadline, and the client exchange has a fifteen-second deadline. Native mutation
bounds remain unchanged, without an outer timer interrupting or replaying an
admitted action. A lost reply remains uncertain.

Live revocation uses the existing SQL operation and authorization notification
while response configuration/file scopes remain held. It does not signal the
original worker registrations. The section "Credential lifecycle through the
serving manager" states what an HTTPS client of a serving manager observes.

Issuance creates a registered client and a credential using 32 cryptographically
random bytes encoded as 64 lowercase hexadecimal ASCII bytes without a newline.
Only the SHA-256 verifier of those exact bearer bytes enters SQLite. The one-time
secret is published exclusively in an existing private parent directory through
the Runtime durable capture publisher. A confirmed file and confirmed database
commit are both required for success. Responses contain only non-secret metadata.
No secret, verifier, publication receipt, or selected path enters diagnostics.

Publication precedes activation and no SQL transaction contains file IO. An
uncertain publication causes no activation attempt. Confirmed publication followed
by a definite SQL refusal leaves an inert private file. Uncertain COMMIT preserves
the file and original Store poison. No failure permits automatic replay, removal,
overwrite, or an inference that the credential is absent. The operator must retain
and investigate the selected file after any uncertain outcome. Provisioning the
private parent and its ancestors remains the operator's responsibility.

Rotation preserves the registered client, label, and scopes. Its fixed positive
overlap is 60 seconds, bounded further by the old declared expiry and any earlier
cutoff. A superseded credential cannot rotate again. Rotation atomically revokes
older predecessors, so only the current credential and its immediate predecessor
can remain active. Trusted SQLite time is checked in the committing transaction.
Declared expiry remains separate from the effective rotation cutoff. Metadata
reports `revoked` when the cutoff takes effect. Accepted RFC3339 letter case is
normalized for SQLite comparison and stored expiry without changing its meaning.

Schema 12 adds retained label, rotation, and profile metadata without altering
credential identities, verifiers, client-keyed ledgers, scopes, or declared expiry.
Labels preserve Unicode scalar values, including NUL, within the frozen length
bound. Legacy labels equal credential IDs. List returns the complete retained set within
256 records and existing result budgets, or refuses the whole materialization
with `size-limit`. There is no lifetime issuance cap or pagination. Profile and
scope operations use set-oriented SQL within unchanged Store budgets.

`AuthorizedView` binds the scoped current process and authority, client,
credential, authorization revision, profile revision, scopes, and effective
deadline. Registration precedes validation so concurrent invalidation is not
lost. Store commit, poison, and close signal a bounded payload-free reader cell
without callbacks or file/configuration lock acquisition. The coalesced signal
wakes observers but does not itself revoke authorization. Revalidation checks
current facts once across a stable Store generation before acknowledging the
signal, so an ordinary request mutation does not invalidate unchanged authority.
Final acknowledgement waits for the Store gate within the allowance of the
observation, so it follows the whole interval between SQL COMMIT and its
notification. The first observation of a view, which materializes it, uses
the rest of the admission deadline of the request that registered the view.
Each later revalidation starts a fresh allowance. The
observation action runs outside that final admission. For a view, its
materialization, a revalidation and an event stream liveness check, the action
is a read. A concurrent commit is then ordinary contention: the read runs again
under the newer generation. A new attempt starts only while one five-second
allowance lasts. The reads of every attempt and the final acknowledgement wait
for their locks within the rest of that one allowance, and each read runs once
for its own generation. A read that meets a new commit for the whole
allowance keeps the `StoreBusy` refusal, which is public `storage-unavailable`.
Any other observation action runs once, and a concurrent commit refuses it
without replay.
Closed scopes stay invalid, and worker stop cells remain separate from revocation.
A one-second wakeup bounds quiet expiry checks, which revalidate trusted SQLite
time rather than treating the timer or view token as authority.

`withAuthorizedView` observes configuration afresh between independently acquired
scopes. `withAuthorizedResponse` keeps one reader charge and the current
configuration loan through its callback. Its view rechecks transactional
authorization using that retained configuration, and its watch closes before
the configuration loan ends. An escaped view remains invalid.

Artifact downloads, projected outputs, export collections, and retained history
result callbacks receive this response-scoped view. Valid revalidation, unrelated
client changes, quiet expiry, and revocation therefore compose with the original
file and configuration owners without a second reader charge or reentrant guard.
Storage contention remains distinct from credential revocation.

Transport, page, cursor, and SSE owners check the supplied view before they
release protected data. An SSE response revalidates its view before each write
and ends when the check fails. No owner recalls bytes that it has already sent.

## Credential lifecycle through the serving manager

A serving manager applies credential administration to live HTTPS traffic as
follows. The `credential-lifecycle` mode of `manager/test/service_http.py`
checks each statement through the administration socket and the real HTTPS
listener, with a live mixed-controls run.

- Rotation keeps the registered client, label, scopes, and profiles. During
  the overlap the predecessor and the new credential both authenticate. From
  the rotation cutoff, sixty seconds after the rotation or earlier when the
  declared expiry of the predecessor comes first, the predecessor receives
  401 `unauthenticated` on every route, including the event stream, receipt
  reads, downloads, and POST, even though its declared expiry is still in the
  future. `list-credentials` then reports it as
  `revoked` with its declared expiry unchanged. The listing does not report the
  cutoff time.
- The idempotency ledger belongs to the registered client. When the new
  credential repeats an exact earlier attempt of the predecessor, with the
  same method, URI, key, body, media type, and precondition, the manager
  returns the retained receipt and executes nothing again.
- Revocation takes effect at the next authorization check. After a
  revocation, the credential receives 401 for the continuation of a page set
  that it has already started, for a command receipt, for a run outputs page,
  for an artifact download, and for a new POST. Its open SSE response ends.
  Revocation does not cancel accepted work. The worker of a live run stays
  owned, and another credential with `control` on the profile can answer its
  pending question and observe terminal success.
- A page token binds the client and the authorization view. Another client
  that presents the token receives 410 `view-expired`, and the page set stays
  available to its own client.
- Scopes limit each operation. A credential with only `observe` reads runs,
  controls, and outputs, and receives 403 `insufficient-scope` for a POST and
  for the receipt of a command whose operation needs another scope. No local
  operation changes the scopes or profiles of an existing credential. The
  administration command refuses `reload-profiles` with `state-conflict`
  before it reaches any manager, offline or serving.
- The manager does not write a bearer to its output, its manager log, a run
  store, or the database. The database keeps only the SHA-256 verifier. A
  worker receives only the explicit environment of its profile, not the
  ambient environment of the manager process.

## Mutation transaction

The owning route supplies exact method, canonical resource target including query,
media type, precondition, and body bytes after its strict transport and operation
parsing. The common layer checks bounds and the frozen operation/resource family.
Capture uses `/v1/captures?requestId=ID`. It does not trim, reserialize, or normalize body, media type, target, or
precondition bindings. The streamed capture entry point uses an opaque binding
computed from bounded actual chunks and finalized only at EOF. Both byte and
streamed entry points use the same command implementation. Catalogue-aware
builders receive only the current immutable configuration facts and fresh
correlation ID, and run only after completed-retry recognition.

Current authentication and required profile authorization precede ledger lookup.
The authority epoch is checked before lookup. For an existing key, operation,
profile, exact media type, precondition, and body binding must match. The original
durable receipt is returned without a new revision, invalidation, charge, rate
permit, or dispatch ticket. Profile or resource revision changes do not erase
that recognition for an otherwise currently authorized exact retry. Conflicting
bindings return idempotency-conflict, and retained tombstones return receipt-expired.

For a fresh intent, the current profile revision, strong same-URI resource
validator, and source-owned lifecycle validation must pass. `mutationVersion`
returns the actual resource URI, profile, and revision from the owning query.
Create and capture omit the existing-resource validator. Other mutations require
one strong If-Match value from that exact URI and query. Weak, wildcard, or list
validators refuse. Missing and stale validators remain distinct refusals.

`mutationValidate` has no default. It supplies a deferred owning-module mutation
and relational references only after checking its lifecycle. The common mechanism
does not supply a replacement draft, admission, preparation, or control state
machine. The owning worker or approval adapter must additionally retain and
validate its exact live worker capability before any physical callback.

The deferred mutation returns invalidations and optionally an explicitly proven
local coordination effect. Local input, enqueue, withdrawal, and lineage-request
effects must use their matching frozen kind and bound resource references, with
null runtime sequence and address. They cannot simultaneously request future
dispatch. No effect is inferred from SQL completion. Such an effect, its resource
changes, the original effect-observed receipt, and its invalidations commit
together without a fabricated delivery timestamp or dispatch ticket.

Current credential expiry and scopes are rechecked after the deferred mutation
and before intent publication. Fixed CommandFailure exceptions abort through the
existing Store rollback mechanism, including post-write refusals. They remain
distinct from storage errors and asynchronous cancellation. A failed SQL write,
invalid effect, or failed invalidation produces no successful durable receipt.

## Schema and exact bindings

The internal version-two migration extends the accepted version-one database in
a single transaction. Version three adds the [draft representations](DRAFTS.md)
without changing this command compatibility domain. Version-one DDL remains unchanged. The migration adds body
digest and length fields, a fixed refusal field, logical ledger reservations,
usage accounting, and rate counters. Existing raw body rows and original receipt
bytes remain intact. Partial migration rolls back columns, tables, data changes,
and version publication together. Internal schema version is not the frozen
public managerStore compatibility domain, which remains version 1.

New commands store SHA-256 of the exact body and its exact byte length. JSON
bodies retain the 2097152-byte ceiling and raw capture bodies the 67108864-byte
ceiling. This avoids exceeding the accepted SQLite row and result ceilings.
Empty bytes have a present digest and zero length. Legacy raw-body equality is
checked inside SQLite without returning that body as a result. A legacy row
without a recognizable binding is never treated as permission to execute again.

A native-limit regression fills a valid version-one command row to its actual
SQLite LIMIT_LENGTH boundary, then checks migration failure rollback, successful
migration, exact SQL comparison, original receipt preservation, and retirement.
The tested fixed metadata permits 2096575 body bytes, while one additional byte
gets SQLITE_TOOBIG. The body cannot be copied through the one-MiB result budget,
but its exact retry still succeeds through SQLite comparison.

Legacy retry and GET do not mint dispatch tickets. WM-010 observation updates
require such a live ticket. WM-016 additionally records validated Runtime evidence
only for a matching bounded non-content control binding created by fresh
acceptance. Neither path enlarges a migrated legacy raw-body row with new
acknowledgement or effect content. Permitted
retirement removes its large body and shrinks the row. A future owner introducing
historical observation updates must check the native row limit or provide a
compatible representation before enlarging these rows. A logical reservation is
not a promise that a near-limit legacy row has physical room to grow.

The original encoded CommandReceipt is immutable. It describes facts established
by the first commit. Later GET projections use separate state, attempted-delivery,
acknowledgement, effect, and refusal columns. Exact retries return the original
receipt rather than silently replacing it with later observations.

## Logical ledger reservation and rates

The common admission policy reserves C = 131072 bytes for each new command:
65536 bytes for the original receipt, 32768 for acknowledgement, 16384 for effect,
and 16384 for fixed, binding, and dispatch metadata. Frozen maximum-length and
worst-case escaping checks fit these component ceilings without truncating fields.
Legacy raw body bytes are charged in addition to C. SQL triggers maintain usage
atomically with inserts and retirement, and reject deletion of replay protection.

Let L be current globalMutationLedgerBytes and R = min(L, 16 * C). Ordinary
admission requires total charged usage plus C to be at most L minus R. Only
whole-run cancel, with current control authority and the owning lifecycle check,
can use capacity up to L. There is no caller-supplied safety flag. The sixteen
slots follow the frozen maximum execution reservations. Small positive L can
leave no ordinary capacity. Existing over-budget records survive migration and
reload, while new admissions refuse rather than evicting replay protection.

Ordinary rate is thirty fresh intents per credential per fixed UTC-minute window.
Cancellation uses one separate global counter capped by the current configured
safetyControlsPerMinute. Multiple credentials do not multiply that safety cap.
A counter resets only when trusted SQLite time advances to a later window, so
clock rollback cannot replenish permits. This is not a rolling-window guarantee.
Counters, reservations, commands, and invalidations share one transaction. Refusal,
rollback, and exact retries consume no new permit or reservation.

For new digest-bound rows with live tickets, precharging permits later bounded
acknowledgement and effect recording even when ordinary admission is saturated. Cancellation reserve is finite, and real storage
failure still refuses a durable receipt. These are conservative logical ledger
charges, not physical database, WAL, temporary-disk, or total-heap quotas. WM-019
retains independent physical safety supervision when durable storage is unavailable.

## Manager log records

A serving Store lifetime records each fresh command in its manager log, which
[the storage contract](STORAGE.md#manager-log) describes. A lifetime that
`withCoordinationStore` opens has no manager log and records nothing.

The admission transaction of `submitBoundCommand` checks the log ceiling
beside `checkCapacity`. When the log and its claim checks have reached L minus
R, an ordinary command is refused with `storage-quota`. A cancel may use the
reserve and is never refused by this check.

After every check, the INSERT and the charge of the rate, and immediately
before the commit-deadline check and COMMIT, the transaction appends the
`command` record. Its sender is `Principal (Credential client credential)`,
with the client that `authorizeRequest` returned and the credential identifier
of `credentialRateKey`. Its receiver is the manager, and it names the command,
the request and the manager run of the command references. Its body is the
admitted request without its idempotency key. A JSON request body is its
strictly decoded value, and a capture is named by the identifier that the
capture mutation recorded in `command_captures`, the SHA-256 of the body
binding and its size. A JSON request body that does not decode strictly
refuses the command with `invalid-request`. The writer synchronizes the record
to disk. The writer lock is taken last, inside the held file slot,
configuration and database locks, and the append counts against the
five-second operation allowance.

The transaction decodes the appended bytes, including a claim-check file, and
compares the decoded body, sender, receiver and identifiers with the admitted
command. Any difference refuses an ordinary command with
`storage-unavailable`. When the append fails, an ordinary command is refused
with `storage-quota` for a quota failure and with `storage-unavailable` for
every other failure, and the transaction rolls back. A cancel commits and is
dispatched in both cases, without a record that the log carries. The writer
keeps a gap entry that names the missing command record and a second entry
that names the missing receipt. The next appended record follows the gap
notice that names both. A refused admission appends nothing,
because every check precedes the append, and an exact replay appends nothing.

When the transaction rolls back after the `command` record was appended, for
example because the commit-deadline check, an invalidation or the comparison
failed, the Store appends a `failure` record as the reply to the command
position. Its class is `refused` and its message is the refusal code of the
command. When the COMMIT outcome is uncertain and the Store is poisoned, the
command record keeps no reply, which denotes the uncertainty.

After COMMIT, the manager appends the `receipt` record as the reply to the
command position, from the manager to the principal. The `/v1` response
carries the receipt decoded from the appended bytes, which has the bytes of
the ledger receipt. When the receipt append fails, or its decoding differs from
the ledger receipt, the response carries the ledger receipt, and a failed
append leaves a gap entry that names the receipt. The receipt append is not
part of the admission transaction, and its failure never refuses the command.

Each later commit of command state queues a command notice that follows the
COMMIT. The notice is from the manager to the manager, names the command, the
request and the manager run of the command references, and states the new
state and refusal. `attemptTicket` queues the notice of `dispatch-attempted`.
`observeWithAdmission`, which `recordAcknowledgement`, `recordEffectWith`,
`recordUnresolved` and `recordRefusal` use, queues a notice when the receipt
changes, before the final transition of the owning module queues its own
notices. `recordRuntimeObservation` and `recordExportObservation` queue a
notice when the acknowledgement or effect changes the receipt.
`reconcileCommandAttemptWithAdmission` queues a notice of the current state of
a command whose acceptance it recovers, because the interrupted invocation may
have appended no receipt. The notice of a cancel is a `Reserved` record, and
every other command notice is a `Following` record. A failed append leaves a
gap entry.

The admission transaction takes the notices that its mutation queued, such as
a request ending or a review ending, and `recordReceipt` appends them after the
receipt or after the gap entry of a failed receipt. A replay appends none.

The local administration channel of a serving manager records its credential
operations and its quarantine releases in the same log, through the shared
helper `Agentic.Manager.Administration`. `administerCredentials` appends the
`command` record of `issue-credential`, `rotate-credential` and
`revoke-credential`, and `releaseQuarantine` appends the `command` record of
`release-quarantine`, as the last step of the operation transaction, after its
final checks and before COMMIT. The sender is `Principal (LocalAccount uid Nothing)`, with the
effective user identifier of the manager, which the channel requires of its
peer. The channel declares no owner. The receiver is the manager. The body
names the operation, the client, the credential that the operation issues,
rotates to or revokes, the credential that a rotation supersedes, and the label,
scopes, profiles and expiry of that credential. The bearer, its verifier and the
output file never enter a record. The body of a release names the
reservation, its request, and the cleanup evidence identity and digest that
the release verified. The appends use the ceiling with which the
lifetime opened its log, so a revocation still takes no configuration lock. The
writer synchronizes the record. A failed append, or a decoded record that
differs from the operation, refuses the operation with `storage-unavailable`,
and a rollback after the append adds a `failure` reply as it does for a
command. After COMMIT, the manager appends the response that the operator
receives as the `receipt` reply, from the manager to the local account, and
returns the response decoded from the appended bytes when it equals the
original. A failed receipt append leaves a gap entry. `list-credentials`, the
read-only operations, a refused operation and every operation of an offline
administration lifetime append nothing.

## Dispatch and observations

Only a fresh committed intent requesting dispatch can mint an opaque
DispatchTicket. The ticket retains the actual store, command references, live
generation, and one-shot memory state. Receipt lookup, retry, stored generation,
and reopen cannot mint a replacement. Reservation records dispatch_generation
separately from attempted delivery. Attempt consumes the memory permission
irreversibly, then commits its attempted marker before invoking the owning
adapter callback. A known refusal invokes no callback. Uncertain storage or
callback outcomes never restore reusable dispatch permission.

Callback return is neither a native acknowledgement nor effect evidence. Callback
exceptions preserve their original identity while unresolved recording is best
effort. Later explicit observations use the same live ticket without restoring
its consumed dispatch permission. Correlation, operation kind, bound resource
references, and legal monotone observation changes are checked. Repeated equal
observations append no invalidation, and known effects cannot be downgraded to
unresolved. WM-016 still validates actual native occurrence, attempt, and runtime
sequence evidence before supplying these public facts.

The acknowledgement and effect codecs use the exact frozen public shapes, not
native protocol substitutes. Receipt parsing checks date-time syntax, required
scopes, state constraints, unknown fields, and bounds. The shared neutral JSON
reader rejects duplicate keys and excessive nesting before Aeson object maps.
The same reader preserves Configuration's existing strict-token behavior.

## Retirement and acceptance ceiling

`retireReceipt` is an internal retention operation requiring a source-owned
transactional inactivity check for the original URI. It also checks a valid
timestamp and at least thirty days of inactivity against trusted time. There is
no public retire-by-ID shortcut or default inactivity assertion. Retirement
clears original receipt content, raw body, digest, length, media type, precondition,
acknowledgement, and effect. The non-content key record remains charged at 16384
bytes and permanently prevents replay.

`retainReceipts` observes at most sixteen original commands per page within the
existing transaction. At most thirteen statements per record plus the page query
fit the 256-statement Store budget. Unique request/run associations bound linked
execution checks, and missing or contradictory links remain protected. Active
requests, live preparations, unreleased reservations, pending decisions, uncertain
exports and unresolved commands prevent inactivity. A linked run also requires a
State-owned validated terminal observation, not process exit or a released slot.

Only committed local create/capture operations with matching original request,
client and profile associations can be locally complete while their receipt remains
accepted. Missing associations, dispatch facts or contradictory start/control facts
keep them pending. This classification never rewrites original receipt state or
manufactures Runtime evidence. Records with no provable resource association retain
content rather than acquiring an inferred inactivity date.

The first proven inactive observation starts the thirty-day interval. Resource and
reference activity resets that observation, and retirement rechecks all conditions in
the committing transaction. Eligibility clocks use trusted SQLite time, not accepted_at.
After retirement, registered-client key tombstones remain charged and cannot be deleted.
Client and credential identities cannot be recycled to evade this protection.

Preflight retains current authorization and authority-epoch precedence. It checks
profile/operation conflicts before returning receipt-expired for a matching tombstone,
without invoking the pre-body callback or consuming an upload stream. Unretired retries
continue through the existing exact byte, media-type and precondition checks.

`manager/ci/commands.sh` builds the actual Cabal targets with warnings as errors,
runs independent N1 and N8 database and offline/live CLI checks, validates emitted
responses with the frozen validator, and compiles real-source proof consumers.
The live fixture checks held-response revocation, unchanged worker-registration
signals, exclusive endpoint ownership, framing and absence of offline fallback.
It does not launch a physical workflow through that new fixture. Storage,
configuration, profile and full contract gates remain separate. No HTTP service,
paid provider execution, restored worker adoption, power-loss test or withdrawn
SQLite confinement experiment is claimed.

## Admission continuations

The admission owner retains an opaque `CommandAttempt` before submitting a fresh
local operation. Submission through that context is one-shot. Reconciliation is
available only after it finishes and is bound to the same Store generation,
authority epoch, candidate command and exact original request bytes. It can prove
that a rolled-back candidate is absent or recover that invocation's retained
enqueue, cleanup or committed start association. It never creates a context from a receipt or
reconstructs physical authority from SQL.

Accepted enqueue permits retain the exact command, queue origin, input revision
and catalogue selection. Current credential changes do not revoke accepted work,
while new client operations retain the ordinary current authorization checks.
The owning controller preserves known associations across lifecycle revisions
and invalidates them on input changes, withdrawal and release.

`recordEffectWith` allows the owning release transition and the existing command
effect to commit in one Store transaction after actual cleanup confirmation.
An exact repeated effect does not rerun that transition or append an event.
Runtime acknowledgement and successful workflow completion remain separate facts.

`submitCommandAttemptWithDeadline` shares the ordinary acceptance implementation
and arms the live owner's final Store check only for fresh acceptance. Completed
exact replay remains an authorization-checked receipt lookup without a new deadline
check, charge or effect. An expired final check rolls back the source-owned mutation,
command receipt and invalidations. The WM-014 approval owner must use this seam with
the guard loaned by Admission, rather than a clock value captured before its other
acceptance checks.

The approval owner records start_intents in the same original acceptance transaction.
Known-attempt reconciliation checks that association while reusing its original
mutable ticket state. A receipt lookup alone still returns no new dispatch authority.
The prepared variant of CommitDeadline checks original Worker registration, phase,
known failure/stop and Runtime-owned liveness at the final fresh acceptance point.
