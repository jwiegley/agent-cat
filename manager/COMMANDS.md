# Command acceptance and receipts

`Agentic.Manager.Commands` implements the internal WM-010 command mechanism over
`Store.runTransaction`. It does not create HTTP routes, provision credentials,
interpret workflows, or reconstruct worker authority. The public Manager facade
continues to expose trusted configuration and scoped storage composition, not
credential construction, SQL, or dispatch-by-ID operations.

## Current authority

`authenticateCredential` bounds presented bearer bytes before hashing them with
SHA-256 and comparing against actual credential verifiers. The returned opaque
`CredentialProof` contains no retained bearer and has no Show, JSON, Generic, or
public constructor. Its explicit NFData instance does not expose its fields.
Length checks do not measure entropy. WM-023 owns secure credential generation,
provisioning, rotation administration, and transport authentication.

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
An unavailable lock or writer produces explicit storage-unavailable refusal.
There is no internal retry loop or waiting queue. A caller may retry the exact
same key after such a refusal, never substitute a new key to discover an outcome.

Receipt GET first checks current credential validity. An authorization-filtered
metadata query selects no body or receipt. The same transaction checks current
profile visibility and observe plus all scopes derived from the stored original
operation before reading the projection. Missing or unauthorized metadata is not
an existence oracle. Knowing a command ID, client ID, or old key grants no access.

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

Legacy retry and GET do not mint dispatch tickets. Every WM-010 observation
update requires such a live ticket, so no current command API can enlarge a
migrated legacy row with new acknowledgement or effect content. Permitted
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
bytes and permanently prevents replay. WM-021 owns determining actual inactivity,
retention scheduling, and wider collection obligations.

`manager/ci/commands.sh` builds the actual Cabal target with warnings as errors,
runs independent N1 and N8 database checks, validates emitted receipts with the
existing frozen validator, and compiles positive and negative real-source proof
consumers. Storage, configuration, profile, and full contract gates remain separate.
No HTTP service, credential administration, provider execution, restored worker
adoption, power-loss test, or withdrawn SQLite confinement experiment is claimed.
