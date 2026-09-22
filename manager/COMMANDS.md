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
secure generation and rotation. Live external administration and transport
authentication remain separate integration obligations.

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
`rotate-credential`, `revoke-credential`, and `list-credentials`. Other recognized
operations receive `state-conflict` and remain with their existing owners.

The offline CLI acquires the existing configuration lease and original Store.
It refuses an already-owned installation and retains ordinary Store restart
reconciliation. Trusted embedding passes that same Store to
`administerCredentials`. A bearer proof, client ID, or stored credential ID does
not grant administrative access. There is no listener or secondary writer.
Live external administration of an already-running service remains unresolved.
These operations do not establish full WM-023 acceptance.

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
Final acknowledgement uses original fail-fast Store admission, serializing it
with SQL COMMIT and notification. A concurrent commit refuses the observation
without replay. The observation action runs outside that final admission.
Closed scopes stay invalid, and worker stop cells remain separate from revocation.
A one-second wakeup bounds quiet expiry checks, which revalidate trusted SQLite
time rather than treating the timer or view token as authority.

Future transport, page, cursor, and SSE owners must integrate current-view
revalidation before releasing protected data and observe invalidations during
streaming. Existing response scopes remain unchanged. These primitives do not
recall emitted bytes or claim completed streaming closure or page enforcement.
Full view revalidation still needs the current configuration guard and may fail
fast while a response holds it. Transport integration must compose that boundary
without treating storage contention as credential revocation.

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

`manager/ci/commands.sh` builds the actual Cabal target with warnings as errors,
runs independent N1 and N8 database checks, validates emitted receipts with the
existing frozen validator, and compiles positive and negative real-source proof
consumers. Storage, configuration, profile, and full contract gates remain separate.
No HTTP service, credential administration, provider execution, restored worker
adoption, power-loss test, or withdrawn SQLite confinement experiment is claimed.

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
