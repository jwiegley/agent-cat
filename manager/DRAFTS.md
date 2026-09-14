# Drafts, captures and readiness

`Agentic.Manager.Drafts` supplies the internal WM-011 draft, input, capture,
readiness and frontend-frame operations. It coordinates the existing Commands,
Configuration and Runtime implementations. It does not interpret workflows,
create workers, perform approval, provision credentials or expose an HTTP server.

## Catalogue and request authority

Successful installed-runner discovery retains a bounded catalogue in Profile's
existing Installed entry. There is no parallel registry. Each probe uses the
actual configured executable and native capability/descriptor codecs. Catalogue
entries have opaque workflow IDs derived from profile and native workflow name.
Every successful replacement has a new descriptor revision. The retained
Discovery records its exact profile revision and immutable selected policy.

Reload clears retained catalogues. Failed or interrupted probing clears the
attempted profile's cached catalogue before returning failure or rethrowing the
original asynchronous exception. Each catalogue remains within the existing query byte limit, with at most 256
inputs per workflow. The public 256-item workflow page bound does not limit the
whole native catalogue or prevent selecting entries beyond its first page.
The existing configuration profile ceiling bounds aggregate retention. Cached
metadata does not freeze executable contents or create future execution authority.

Creation accepts only the frozen workflow/profile IDs and revisions, not a
caller-supplied descriptor, declaration list, executable or path. Commands invokes
the source-owned builder only for a fresh intent, under the same held current
configuration snapshot. Matching completed retries precede fresh catalogue checks.
Both ordinary and catalogue-aware command entry points share one implementation.

A draft records the exact selected IDs/revisions and ordered declarations. The
initial public Request is retained in an immutable request_origins relation,
uniquely linked to its request and creating command. Its encoded size cannot
exceed the one-MiB view/result ceiling. Submit-only create retries return this
original view rather than exposing later Observe-only literal changes. Command
retirement still prevents replay. Origins are bounded request/history data, not
larger command receipts. Their count is pinned one-to-one to retained commands,
whose nonzero ledger charges bound request growth. Later collection owns their
safe release only when replay protection and retained request/declaration views
no longer require the content. Missing legacy origin metadata is not treated as
a complete authoritative declaration set.

## Literal representation and migration

Internal schema three transactionally migrates schema two. Version-one DDL and
the version-two command migration remain unchanged, and public managerStore
compatibility remains version one.

Literal storage is explicit: raw byte length, chunk count, integrity digest,
nullable derived native byte count, and ordered chunks of at most 65536 bytes.
An empty literal has zero chunks and the digest of empty bytes. Missing input has
no literal metadata. Foreign keys, ordinal/size checks, exact count/length checks
and digest verification distinguish empty input from missing, gapped, extra or
tampered chunks. Raw chunk boundaries may split UTF-8 characters. Reassembly
validates the complete UTF-8 value without replacement decoding.

Migration copies all previous literal bytes into chunks and computes their
integrity data. It batches only bounded row identifiers and lengths. Declarations
are read individually within the one-MiB result ceiling. Larger declarations
remain intact but have unknown derived transport length, with no truncated parse. Native transport length is derived only when the old declaration
and UTF-8 are understood through Runtime. Otherwise it remains null, meaning
unknown rather than zero or ready. Unknown legacy declaration or encoding does
not cause bytes to be discarded. Readiness and assembly refuse unsupported data
until validated replacement/removal or the owning recovery operation resolves it.

The pure native literal encoding operation is extracted from CLI into Runtime as
`frontendLiteralBytes`, and CLI delegates to it. Manager accounting uses that same
operation. Logical literals are still stored and assembled as Literal values,
never relabelled as transports or files to fit a frame.

Input edits require current command authority, exact same-resource revision and
current catalogue selection. Draft and queued requests are editable only when no
active reservation or live preparation exists. A queued edit clears its queue and
admission state atomically. The standalone operation refuses preparing and review
cases because it owns no Worker. The [admission owner](ADMISSION.md) uses the
guarded input-mutation seam to invalidate its live association and retain claims
until actual discard and cleanup. Historical released reservations and invalidated
preparations remain intact.

## Upload admission and publication

There is one fail-fast file/materialization slot per actual Store lifetime. Its
operation retains a Runtime private subroot and an atomic duplicate of the actual
service lease. Lock order is file slot, configuration, then database. No database
transaction remains open while awaiting upload chunks or performing file IO.
Store close rejects new operations and joins existing file work before releasing
ownership. The slot is not a publication or command success receipt.

Before consuming bytes, upload admission checks current client/profile/request
association and reserves an explicit bounded ceiling in capture_uploads. The
request must remain editable. A completed command retry instead validates and
hashes the incoming stream without reserving another capture or publishing a file.
The streamed body binding is opaque and finalized only after EOF. It is fed from
the same bounded chunks supplied to Runtime publication, not from a caller hash.
At most a two-MiB raw prefix is retained for legacy command comparison. No Generic,
JSON or public digest constructor can manufacture the binding.

Uploads accept chunks of at most 65536 bytes and validate UTF-8 incrementally,
including incomplete code points at EOF. Runtime's actual
`publishPrivateCaptureAt` provides exclusive installation, byte count, SHA-256,
file/parent synchronization and explicit unconfirmed outcomes. Destinations are
fixed server-owned captures/opaque-ID entries. Caller paths, URLs and arbitrary
destinations are not accepted.

Confirmed publication is converted to immutable capture metadata and a deferred
command_captures link inside the common command transaction. The command foreign
key is deferred only to support apply-before-command insertion. Unresolved links
still prevent commit. Capture retry retrieves the original retained capture result
rather than generating another ID. Binding checks request, profile and the
registered uploading client, so credential rotation does not lose ownership.

Known not-published outcomes can release their reservation through a successful
cleanup transaction. Unconfirmed, cancelled or lost-publication outcomes retain
charged pending/orphan state for later reconciliation. A final installed file is
never deleted as rollback for a missing database receipt. Metadata failure after
confirmed publication likewise retains the file and orphan charge. WM-021 owns
collection and reconciliation, not an opportunistic retry-time unlink.

## Bounds and materialization

Draft allowance is per registered client, independently of globalDrafts. Request
holding bytes count supplied literal UTF-8 plus each distinct capture and each
pending/orphan reservation once against 67108864 bytes. Binding does not double
charge a capture. Assembled input accounting separately counts every input use,
including exact native literal bytes. Reusing one capture for two inputs cannot
evade the native aggregate limit. globalCaptureBytes counts every published,
pending and orphan capture reservation, but not separately bounded literals.

A fixed additional holding limit of 256 captures plus pending/orphan reservations
per request prevents zero-byte interrupted uploads from accumulating unbounded
metadata. It is an internal holding limit, not an existing implication of input
cardinality or a new operator field. Conversion exchanges one reservation for one
capture. Completed retries consume no slot. Reservations require an existing
authorized durable request, whose creation is globally draft/ledger bounded.

Literal chunks are read through short bounded transactions. Request revision and
current authority are checked before and after materialization, with explicit
refusal on concurrent change. No network writer receives a live cursor. Public
views are measured against the one-MiB bound and refuse rather than truncate.
Capture verification uses retained private traversal, regular private single-link
files, exact byte count, UTF-8 and fresh digest checks. Missing or changed committed
content produces a persisted readiness error or an explicit refusal, never
reconstruction from client source data. Literal integrity failure never becomes
successful empty input.

Frontend assembly uses current retained catalogue/selection facts and the shared
setup DTO/encoder. Inputs retain declaration order. Captures use inline Transport
only when the actual encoded frame fits, otherwise they use verified server-owned
File references. A literal-heavy frame that still exceeds the native bound refuses
without changing interpretation. Reopen preserves original data and revisions,
but assembly cannot silently adopt a new catalogue or profile after restart.
Actual worker/preparation revalidation remains with later owning packages.

Upload streaming has a thirty-second cooperative budget, and local view/frame
materialization has a five-second budget. Existing Store transaction, busy and
cleanup limits remain. These are not absolute OS IO or hard total-heap guarantees.
Holding quotas are not physical SQLite/WAL/temp-disk quotas. Stable
operator-controlled private paths and the accepted Runtime durability assumptions
remain required.

## Verification boundary

`manager/ci/drafts.sh` builds actual Cabal targets with warnings as errors and runs
separate N1/N8 tests using real SQLite, installed-runner fixtures, Runtime codecs
and publication. Emitted DTOs pass the existing frozen validator, and relevant
valid/invalid corpus records test the neutral decoders. Publication uncertainty
uses a one-shot test-only fault at the existing project synchronization boundary,
with real barriers when unarmed. It does not interpose libc, SQLite or a VFS,
replace paths, or establish physical power-loss durability. Existing command,
storage, configuration, profile and protocol gates remain separate.

## Admission materialization

`assembleDraftSnapshot` supplies the admission owner with the verified shared
setup and exact request/profile revision association under Submit authority.
`assembleAcceptedDraft` instead requires Commands' opaque accepted-enqueue permit,
so accepted work does not depend on a renewed submitting credential. It checks
the exact original command, queue origin, input revision and catalogue association
before and after materialization through the same representation and file checks.
Neither entry point grants approval, arbitrary private-file access or adoption.

Batched structural readiness returns bounded request facts without copying input
contents into admission queries. It does not promise native preparation success.
Public draft reads preserve current admission blocking reasons while refreshing
the missing-input indication, and queued requests retain their global position.

DraftAssembly retains its original trusted Selection and input source/byte/hash
summaries for the exact review owner. Literal summaries use the native encoding,
and captured summaries use verified capture receipts. They do not expose private
paths or create execution authority from serialized request rows.
