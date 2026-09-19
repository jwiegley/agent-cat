# Verified artifacts and exports

`Agentic.Manager.Artifacts` is an internal library adapter. It does not implement
HTTP transport, page sets, history retention, restart scanning or client displays.
The frozen public schemas remain in `doc/api/openapi.yaml`.

## References and content

State assigns source handles from its trusted run-bound Runtime references.
Artifact IDs are lookup keys, not authority. Every content operation checks the
current credential, observe scope, configured profile and stored run association.
The retained Store file loan and profile lock cover the response callback.
Credential revocation is checked before delivery. A credential can be revoked in
SQLite during a callback, and this library does not cancel ongoing delivery.
WM-023/A16 owns ongoing transport revocation. Callbacks finish sending before returning and must not retain content or queue a
response for later delivery. Questions continue through State's shared verified
question reader and its decision projection.

`withArtifactDownload` supplies metadata and exact captured bytes to its callback.
The source reader returns the same native envelope bytes that Runtime captured
and verified for canonical format, version, run, reference code, length and digest.
The adapter does not reopen the file or re-encode its content. A known source
reference does not require a readable journal. Source-result and export handles
are distinct because native stored envelopes and compact code/value documents
followed by LF are distinct byte sequences. Metadata hashes and lengths describe
the bytes supplied to the callback. No receipt contains a server pathname.

The public document shape check rejects incompatible primitive values and verdicts
before content or publication succeeds. It follows the frozen `ExportDocument`
schema, including its arbitrary-JSON structured branch. This check is not a
semantic-schema decoder. Native structured rational objects and the frozen decimal
fixture remain distinct valid representations without conversion. Runtime's
existing result verifier retains its previous semantics. A stronger all-code
stored-value decoder would require a separate representation decision.

## Outputs and verification

`withRunOutputs` supplies bounded `OutputItem` values. Attempt output retains its
occurrence and attempt address and at most 65536 characters of transport tail.
Explicit diagnostics are separate observe-authorized items with at most 8192
characters. These strings are untrusted content, not logging instructions or
rendered HTML. JSON encoding escapes terminal control characters. Presentation
escaping remains the responsibility of the eventual client.

The result item contains independent verification and artifact metadata. A corrupt
result changes result availability without changing Runtime terminal success.
Verification is an observation rather than a promise that a file cannot later
change. Every download verifies again. Read failures expose fixed categories, not
private paths, stored values or provider diagnostics. Actual verification
transitions receive fresh revisions, including a return to a previous status.
Unchanged observations do not rewrite revisions or emit invalidations.

The adapter refuses more than 256 items or an encoded item array above 1 MiB.
`withRunExports` supplies receipt items under the same bounds and checks that the
collection revision did not change while reading them. It does not invent page tokens or claim a complete paginated service. Store retains
its existing transaction, projection and ingestion bounds.

## File and memory ownership

Each Store has one fail-fast file loan. The loan spans capture, verification,
authorization checks before delivery and the actual response callback. Concurrent content reads
cannot accumulate independent response buffers outside that loan. Each source or
export capture is limited to 64 MiB before a response. A source download retains
one captured byte sequence. Publication may retain one prepared export and one
verification reread, each bounded by 64 MiB, while completing its receipt.

Runtime's bounded parsing and canonical-byte comparison also allocate decoded
values and temporary encodings. The captured-byte ceiling is not a total Haskell
heap quota. This library does not implement connection queues or service-wide
quotas across independent Store instances. A future transport must preserve the
callback lifetime instead of returning a lazy or queued response after releasing
the loan.

## Exclusive publication and reconciliation

`submitExport` accepts only the frozen name mutation and exact collection
precondition. Commands owns immutable acceptance, idempotency and the original
one-shot dispatch ticket. Runtime prepares the verified compact document and its
identity before the adapter records an export intent. The fixed destination is
`exports` beneath the managed Runtime state root, which is the Store's `runs`
subroot. Both state and export root identities remain checked. The request cannot
supply a path, executable, root or Runtime reference.

The intent binds command, run, distinct export artifact, destination root, name,
expected length and digest. The export artifact's immutable private reference also
records the accepted name and exact incoming request-body digest and byte count.
It stores neither a generic request body nor a canonicalized-body identity. Schema eight makes only the export-to-command foreign
key deferred so acceptance and intent commit together under Commands' existing
transaction order. Existing names are never overwritten or removed. A successful
shared Runtime publisher produces a private durable receipt witness. The adapter
then verifies the current destination and observes export and command completion
atomically. Known destination conflicts are command refusals and unresolved export
receipts rather than successful publication claims.

`reconcileExport` checks current observe and export authority and verifies a recorded
successful publisher witness against the full intended destination identity.
Commands binds its row and decoded immutable acceptance profile, operation and
resource to the owning run and export collection. It checks the intended name and
raw-body identity against the private acceptance binding. Missing older bindings
are refused rather than inferred or backfilled. It can complete that observation after Store reopen without reconstructing a dispatch
ticket. A missing witness remains unresolved even when matching bytes exist.
Therefore a crash between filesystem publication and durable witness recording
cannot be repaired by adopting the destination. A durable witness followed by a
lost completion or client reply can be reconciled. Conflicts, changed authority,
substituted roots and changed bytes cannot become published receipts. Neither
reconciliation nor idempotency replay repeats publication. Actual completion
receives a fresh revision. Reconciliation of an already completed observation
still checks authority, provenance and bytes without rewriting resource revisions
or emitting duplicate invalidations.

## Evidence

`manager/ci/artifacts.sh` builds with warnings fatal and runs bounded deterministic
pure, SQLite and filesystem checks at N1 and N8. Each checker has a 512 MiB heap
ceiling and a 120-second deadline. It uses Runtime's real artifact writer, verifier
and exclusive publisher, plus the unchanged frozen fixtures. It validates actual
metadata, output items and export receipts against the frozen schemas.

The gate covers independent runtime/result status, damaged journals, reference
identity, root and leaf substitution, credential revocation before a call,
captured-read admission, exclusive name races and both lost-receipt windows.
It also covers collection revision ABA, already-published reconciliation,
whitespace-distinct raw-body identity and tampered acceptance with transactional
rollback. It does not demonstrate credential cancellation during a callback. Populated schema
seven upgrades preserve published and unresolved records, roll back migration
failure and reject an absent command at commit. These checks are not native
workflow-process evidence or proof of power-loss durability. Native frontend
export, control, storage, process-fault and client owning gates remain separate.
