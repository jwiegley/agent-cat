# Exact review and original start intent

`Agentic.Manager.Approval` implements the internal WM-014 review and approval owner.
It consumes Admission's genuine opaque LivePreparation rather than a prepared value,
row identifier or reconstructed Worker. Public preparation codecs remain independent
of Store, authorization and server implementation modules.

## Review and private binding

`publishReview` obtains the original native prepared observation and materialized
input summaries through Admission. Drafts derives those summaries using the existing
native literal encoding and verified capture receipts. Worker validates descriptor,
server, root, invocation, person mode and the retained CLI-owned prepared-target
relation. Approval checks the exact input summaries, native plan codec and result
code, and preserves program hash and policy from that same native response.

The public plan is the exact native plan value encoded as JSON text. Policy is a
fixed allowlist projection following PublicPolicy and PublicRealizationPolicy.
Private scratch, binary, adapter arguments, routing sources, provider options,
invocation and environment fields are omitted structurally. Unknown private fields
are not copied. Required unsafe or oversized facts refuse rather than being
truncated, redacted into a different consent statement or recomputed from a later
configuration.

Content-bearing plan strings, input names, semantic property names, derived policy
labels, facts and pins are screened against literal known private execution paths
and URIs and every nonempty selected operator environment value. There is no short-
value exception or public declassification setting. Already available private option
and explicitly secret values remain protected without reading new files or unrelated
ambient environment. Obvious credential key/value arguments, authorization or bearer
material and URI userinfo refuse, while ordinary token/password discussion remains
exact. Explicitly public operator labels and schema-owned IDs, revisions, digests,
enums and numeric values retain their public meaning. Coincidental content matches
can conservatively refuse. This is known-literal and structural protection, not
universal deobfuscation or sandbox noninterference.

The protected binding stores exact request/profile/descriptor, reservation, original
worker identity, native approval/run/root, process generation, expiry and private
invocation/target audit facts. It also stores hashes over the complete canonical
validated native prepared value, captured trusted context and public review. Those
hashes cover values encoded through the existing JSON facility, not original wire
whitespace. Function identity is neither serialized nor hashed. A fresh private
cryptographic nonce and domain/version separate each binding. Nonce and private
hashes never appear in public payloads or refusals.

The full original Worker and selected context stay live in memory. Hashes and stored
identifiers never reconstruct them. The complete public/private record must fit the
existing Store result and row limits. Repeated publication reuses the stored digest,
nonce and expiry rather than reminting consent. Read operations require current
Observe authorization and check stored public/private binding integrity. An old
process-generation row is unavailable as live preparation after reopen.

## Native target authority

Configuration now requires an explicit PreparedTargetValidator in addition to its
existing target grammar and credential checks. Each immutable OperatorProfile and
Selection retains that pure validator. Metadata-only callers explicitly choose exact
argument association, without an always-allow fallback. CLI composition supplies the
native parser-owned relation and performs no later routing-file IO during approval.

Exact trusted target arguments are normal. Only the native resolver's final
`--scratch` suffix may be derived for ACP when the trusted parsed request did not
configure scratch. It must preserve the entire preceding argument vector and match
the private scratch in that same bound native policy. Explicit scratch cannot be
overridden, and inconsistent prefixes, suffixes, policy or target kinds refuse.
RoutingUnloaded resolution is evidenced by the original configured native Worker and
checked by the retained CLI relation, not reinterpreted by manager code or authorized
by a free-standing policy value. Agreement does not independently prove filesystem
freshness or path authority. Derived scratch remains private and bound by the digest.

## Final acceptance guard

Worker's existing phase, stop, completion and release cells are shared through one
small internal lifecycle representation. There is no second phase state machine.
Worker mints the prepared variant of the scoped CommitDeadline using its original
StoreWorker registration and actual frontend ProcessGroup. Admission loans it only
through the protected current-review boundary.

Store performs the fixed final check after bounded acceptance work and invalidations,
immediately before COMMIT. It checks generation, lexical lifetime, monotonic deadline,
original registration/process association and current prepared lifecycle with no
known stop or failure. Runtime supplies a nonblocking liveness observation through
its original unreaped ProcessGroup token. Manager does not signal or adopt a PID and
SQL never waits for process or pipe cleanup. Detected loss before that final point
refuses and rolls back. Later process death cannot retroactively revoke accepted
intent, and physical commit-time liveness or deadline completion is not promised.

## Acceptance, delivery and lifetime

`acceptApproval` validates current credential scopes, exact preparation ETag, digest
and all submitted revision/generation selectors through existing Commands. Fresh
acceptance rechecks the current catalogue under its actual lock and requires the
complete original resource footprint. Review publication rechecks current catalogue,
request and reservation under those same real owners. Fresh acceptance commits approving client, immutable original receipt, start intent,
preparation consumption, run/native identity, reservation association and
invalidations together. Schema five adds the immutable start_intents relation
without rewriting existing rows or adopting historical ownership.

Admission retains the original CommandAttempt and one-shot DispatchTicket across
commit/return gaps. Fresh acceptance or reconciliation of that same retained invocation
can return an opaque AcceptedStart. Exact authorized replay returns the original
receipt and may return only the already-retained association. Neither a receipt nor
an ID lookup creates a new ticket or Worker.

`deliverAcceptedStart` uses that original ticket's reserve/attempt semantics and
writes the existing start frame to the same Worker outside the mutex and SQL.
`approve` composes acceptance and first delivery. Delivery does not reapply the
review deadline. A timer firing after accepted intent checks the matching durable
consumed/start-pending association and retires rather than expiring the work.
`acceptedTimerRetired` is a read-only observation of that check, not authority.

Acceptance and successful pipe writing do not create a running projection, native
acknowledgement, effect or successful result. Worker observations can show actual
validated running transport state without consuming its queue. WM-015 retains durable
ingestion and public Runtime projection ownership. Ambiguous delivery stays unresolved,
and exact retries do not repeat it.

Admission keeps the complete reservation through actual running and original cleanup.
The internal `stopAcceptedStart` operation is an owner lifecycle stop, not a public
cancel endpoint or synthetic cancellation receipt. Input edits, stale review selectors,
changed profile/catalogue, expiry, worker loss and reopen cannot start a replacement.
Unapproved invalidation stops the original worker before releasing claims. Accepted
worker exit or scope closure may release only after original cleanup confirmation,
while preserving consent and recording lost supervision separately from Runtime result.
WM-016 retains the full public control-intent/decision surface.

## Evidence

`manager/ci/approval.sh` runs warning-fatal actual package targets at N1/N8 and checks
public preparations and receipts against frozen schemas. Real native cases cover
stable review publication, selector/ETag refusals, privacy and bounds, profile/input/
descriptor changes, revoke/reopen, deadline crossing inside acceptance, worker loss
after preliminary entry, delayed delivery after timer retirement, actual running
exclusion, unexpected exit, native backpressure and original-owner cleanup. Actual
ACP derived/explicit scratch and RoutingUnloaded cases use deterministic private
adapter wrappers, with forged target/policy negatives.

Approved test-only Commands instrumentation pauses after genuine fresh commit and
after the original native start callback returns. Tests interrupt the original
executing thread, preserve its exception and ticket identity, inspect actual native
history and verify one start with immutable receipt replay. The compiled removal of
the final prepared-worker rejection fails the worker-loss acceptance assertion.
Additional checked one-shot rendezvous after actual currentReview prove separate
publication and fresh acceptance catalogue races through real reprobes. Unchanged
catalogue controls and already-accepted replay remain valid. Removal of either final
catalogue check or complete-footprint check fails its corresponding assertion.
Package capture uses the accepted positive Cabal source boundary, never recursive
checkout copying. No production fault hook, fake approval, new interpreter or generic
Transaction IO lift is introduced. Source/runtime/observer repairs from WM-013 remain
in force. Service/G1, full containment and restart reconciliation remain later gates.

## Pre-integration corrections

Credential syntax screening treats ordinary quote and punctuation boundaries as
delimiters, including quoted headers and separated credential assignments. Genuine
native authored-input regressions exercise public publication rather than only
modified metadata projection. Unsafe content is refused without a public record.

Manager supervision transitions to cleanup-pending and lost allocate fresh run
revisions and append matching run.changed invalidations in their existing atomic
transactions. No run invalidation is emitted when no run changes. Native stop and
worker-loss tests refuse each publication through fixture-owned SQL triggers,
verify rollback and retained claims, inspect the committed intermediate revision,
and retry through original cleanup ownership without rewriting accepted consent.

Capture-backed native approval checks the original capture receipt, UTF-8/newline
bytes, native and public input summaries, invocation binding, replay and cleanup.
Live target-corruption fixtures alter one field of an actual prepared response and
retain the original child and pipes. Worker rejection, absent review/start records
and original child cleanup are checked separately from pure validator negatives.

Colon and equal delimiters are tokenized uniformly before matching the existing
finite credential vocabulary. Whitespace on neither, either or both sides does not
change recognition, and there is no named-header exception. Native matrix tests use
one credential per authored input, preserve exact plan codec bytes and keep benign
discussion controls. Separate compiled quote and delimiter removals fail their
intended native refusal assertions.
