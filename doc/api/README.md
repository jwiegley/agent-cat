# Workflow-manager protocol version 1

This directory specifies the manager contract established by WM-003. The
manager service and service-mode clients are not yet implemented. The
[approved design](../research/workflow-manager.md) and
[implementation plan](../research/workflow-manager-implementation-plan.md)
remain authoritative for execution meaning, ownership, and release gates.
The OpenAPI description uses [OpenAPI 3.1.1](https://spec.openapis.org/oas/v3.1.1.html)
and its JSON Schema 2020-12 foundation. A validated description is not evidence
that an endpoint has been implemented.

## Authority and identities

All application resources are beneath `/v1`. Every application request
requires a current bearer credential, its required scopes, and access to the
resource's execution profile. An identifier, revision, cursor, stored path,
or historical invocation grants no authority. Registered client identity is
derived from the credential and is never accepted in a mutation body.

Manager resource identifiers are opaque URL-safe strings. Runtime occurrence
numbers and attempt numbers are canonical unsigned decimal strings. An attempt
address consists of its run, occurrence number, and attempt number, not a
JavaScript number or a pathname. Manager commit order and native runtime event
order are independent. Revisions and ETags are opaque equality tokens.

API version, snapshot version, and event version are separate from descriptor,
frontend session, control, runtime protocol, manifest, and store versions.
Unsupported versions refuse rather than selecting a guessed downgrade.
Unversioned legacy manifests are distinct from a manifest whose version is
null, one, or unsupported. Existing native fixtures remain unchanged.

## HTTP framing and limits

JSON is UTF-8 with `Content-Type: application/json`. Captures use
`application/octet-stream` and contain raw UTF-8 bytes. Content coding is not
accepted. JSON duplicate keys, non-finite numbers, invalid Unicode, unknown
command fields, and excessive nesting refuse. The initial JSON nesting limit
is 64. Byte limits apply before unbounded allocation and are not character
counts.

| Boundary | Version 1 limit or initial policy |
|---|---|
| Request target | 8192 bytes. |
| Complete request headers | 16384 bytes and 100 fields. |
| JSON request body | 2097152 bytes. |
| Encoded native control | 1048576 bytes, including its framing. |
| Capture and aggregate inputs of one request | 67108864 bytes. |
| Verified artifact content | 67108864 bytes. |
| Complete SSE block | 16384 bytes. |
| JSON page | 1048576 bytes. |
| Materialized page set | 67108864 bytes, two active sets per client, expiring after 60 seconds. |
| Queue | 100 queued requests. Drafts have a separately enforced, advertised positive bound. |
| Execution reservations | One by default, with a maximum of 16. Review and cleanup consume reservations. |
| Prepared review | Ten-minute expiry. Expiry does not release an uncleaned worker's reservation. |
| SSE readers | Two per client, with at most 1048576 pending transport bytes per reader. |
| Replay | Seven days or 268435456 bytes, whichever limit is reached first. |
| Client liveness | Heartbeat every 15 seconds, reconnect after 45 seconds without bytes, jittered backoff capped at 30 seconds. |

Capabilities report effective limits, including global draft, capture, page-set,
connection, database-reader, and mutation-ledger bounds. These global limits
are mandatory positive configuration values, not permission for unbounded
storage. Ordinary mutation admission initially allows 30 operations per minute
per credential and retains separate safety-control capacity. A resource that
cannot be represented within its advertised bounds receives an explicit
refusal rather than an incomplete successful representation.

No response containing protected resources is cacheable by an intermediary.
Successful JSON resource responses include `Cache-Control: no-store`. Verified
downloads use `application/octet-stream`, `Content-Disposition: attachment`,
and `X-Content-Type-Options: nosniff`. They return exact verified bytes, not a
manager wrapper. Metadata belongs to the output or export representation, and
its digest and length cover those exact bytes. Source-result envelopes and
export documents have distinct handles because their byte sequences differ.
Verification precedes a successful content response. Redirects do not transfer
credentials or resource identity to another endpoint.

## Mutation receipts and preconditions

Every POST requires `Idempotency-Key: <authorityEpoch>.<nonce>`. The complete
key is at most 128 ASCII bytes and its newly generated nonce contains at least
128 random bits. Authority epochs are at most 105 ASCII characters, leaving room
for the separator and a minimum 22-character nonce. Its scope is the
authenticated registered client, method,
canonical URI, and key. The ledger binds exact body bytes, content type, and
preconditions. Credential rotation retains the client identity and ledger.

Authentication and current authorization precede receipt lookup. A key for a
wrong authority epoch receives `authority-changed` before ledger lookup.
Matching retries return the original durable receipt without another effect.
Conflicting reuse refuses. Receipts remain while the resource is active and
for at least 30 days afterward, followed by a non-content tombstone for the
client identity's lifetime. An expired receipt is not permission to execute
again. Offline backup restoration changes authority and stream identity,
invalidates every restored credential, and requires client reconciliation.

A POST that changes an existing resource requires one strong `If-Match` value
obtained from GET on that exact URI. Wildcards and weak validators are not
accepted. Missing and stale preconditions produce 428 and 412 respectively.
A matching completed idempotent retry is recognized before evaluating a new
transition. Receipt lookup never permits an ordinary competing mutation to
ignore its precondition.

Draft creation and capture creation have no existing-resource ETag. A capture
is bound to its request, selected profile, and authenticated client. It does
not supply an input until a subsequent checked `set-input` operation binds
its opaque identifier. Export and lineage collections have GET methods so
their POSTs use same-URI validators. An ETag from a snapshot, parent run,
different query, or later page is not substituted for that collection's ETag.

A 201 response creates a draft. A 202 response records accepted coordination
intent. Neither response asserts runtime delivery, terminal success,
artifact verification, or reversal of external effects. Command resources
keep acceptance, attempted dispatch, native acknowledgement, correlated
effect, refusal, and unresolved outcome distinct.

## Resource and scope ledger

The scopes below are cumulative within each cell. Every operation also checks
profile access and current authority. GET methods require `observe`, except
that command receipt access additionally requires current access to the
operation represented by that receipt.

| Resource | Methods | Mutation scopes and guard |
|---|---|---|
| `/capabilities` | GET | No mutation. Versions, limits, transports, and authority are view-filtered. |
| `/profiles` | GET | No mutation. Only public labels, revisions, readiness, and permitted profiles appear. |
| `/workflows` | GET | No mutation. `profileId` selects an authorized, bounded catalogue. |
| `/workflows/{id}` | GET | No mutation. Catalogue information is not an exact input-dependent plan. |
| `/requests` | GET, POST | `submit` creates a draft bound to current profile and descriptor revisions without workflow execution. |
| `/requests/{id}` | GET, POST | `submit` permits `set-input`, `remove-input`, `enqueue`, and `withdraw` before start intent. Editing invalidates previous admission or review. |
| `/captures` | POST | `submit` for the selected request and profile. Raw bounded UTF-8 only, with no source URL or pathname. |
| `/preparations/{id}` | GET, POST | `submit` and `control` for `approve` or `discard`. Approval also requires the review digest and exact live worker association. |
| `/runs` | GET | No mutation. Runtime, supervision, integrity, and verification remain distinct. |
| `/runs/{id}` | GET | No mutation. Includes lineage and links, not execution authority. |
| `/runs/{id}/snapshot` | GET | No mutation. Provides one consistent versioned runtime-derived view. |
| `/runs/{id}/control` | GET, POST | `control`, live manager ownership, current control revision, and exact addressed occurrence and attempt where required. |
| `/decisions` | GET | No mutation. Pending run heads are ordered by manager observation, with each run's queue retained. |
| `/decisions/{id}` | GET, POST | `control` for `answer` or `choose-recovery`, with exact generation and the shared per-run FIFO reservation. |
| `/commands/{id}` | GET | No mutation. A known command identifier does not bypass current operation or profile authorization. |
| `/runs/{id}/outputs` | GET | No mutation. Intermediate output and diagnostics are separate from verified final content. |
| `/artifacts/{id}` | GET | No mutation. The server resolves and verifies its retained internal reference before sending content. |
| `/runs/{id}/exports` | GET, POST | `observe` and `export`, current collection ETag, verified source, and a permitted single-component name. |
| `/exports/{id}` | GET | No mutation. Returns receipt metadata and an authorized download link without a server path. |
| `/runs/{id}/lineage-requests` | GET, POST | `observe` and `submit`, current collection ETag, eligible parent, compatible trusted invocation, and no conflicting ownership or quarantine. |
| `/snapshot` | GET | No mutation. Provides a consistent authorized overview and replay cursor. |
| `/events` | GET | No mutation. SSE and bounded JSON use the same durable cursor and retention rules. |

OPTIONS preflight is the sole unauthenticated HTTP operation. It checks only
an exact allowlisted origin, advertised method, and permitted header names.
It reads no resource state and does not authorize a subsequent request.
Unexpected origins and `Origin: null` refuse. An absent Origin is permitted
for authenticated native clients. Cookie authentication, wildcard credentialed
CORS, query-string credentials, and a network administration scope are absent.

## State and value contracts

| Dimension | Values and meaning |
|---|---|
| Request phase | `draft`, `queued`, `preparing`, `review`, `start-pending`, `associated`, `withdrawn`, or `refused`. |
| Readiness | Declared inputs, supplied representations, missing names, and validation errors. It does not claim semantic preparation succeeded. |
| Preparation | `live`, `consumed`, or `invalidated`, with expiry, review digest, and reason where applicable. Absence is represented separately. |
| Runtime | Absent before native evidence, then the validated existing runtime status and nested observations. |
| Supervision | `owned`, `cleanup-pending`, `lost`, or `observer`. A historically running state can coexist with lost ownership. |
| Decision | `pending`, `submitting`, `resolved`, or `invalidated`, with runtime generation and ordered position. Timeout does not release an uncertain reservation. |
| Verification | `absent`, `referenced`, `verified`, or `unavailable`, independently of reported runtime outcome. |

Every initial input is required text with `description: null`. Empty text is
supplied, while null is not text. Declarations retain their authoring order.
Logical literal text and captured transport bytes remain distinct until the
existing frontend applies their established meaning. No optionality, default,
or description is inferred from a name.

Runtime questions carry their actual observation-wire code and semantic
schema. An editor rendering is supplementary, and the runtime decoder remains
authoritative. Snapshot occurrences retain the separate native code words,
including `ack` and `structured`. These are not replaced with `receipt` or an
invented structured schema when no verified question or result supplies one.
False, null, arrays, structured values, Unicode, and decimal representations
are not coerced into display strings. Every route that answers a mandatory
decision uses the same per-run FIFO transaction. There is no generic pause,
remote shell, or arbitrary engine-prompt operation.

Restart, resume, and fork create new requests. The lineage body supplies only
the selected operation and permitted typed fork edits. It cannot replace the
parent's workflow, inputs, target, invocation, or filesystem root. A new
preparation always requires a new exact approval. Its public review includes
the program hash, person-answering mode, and allowlisted public policy from
that same native prepared response, not a later configuration lookup.

An unreadable manifest remains a visible catalogue entry with an opaque handle,
profile, safe failure category, and only known metadata. It does not require
an invented workflow identity, manifest version, or runtime state.

## Pages and live delivery

A page set is materialized at one database boundary, then served outside the
read transaction. Opaque page tokens bind its client, authorization view,
query, revision, and expiry. Clients assemble a complete page set before
installing it. Expiry or revocation requires a fresh view. A first-page ETag
is not interchangeable with another page's validator.

SSE uses UTF-8 and dispatches only complete blocks ending in a blank line.
The supported event names are `request.changed`, `preparation.changed`,
`run.changed`, `decision.changed`, `command.changed`, `artifact.changed`, and
`service.changed`. Data is a versioned resource invalidation, not a runtime
delta or a container for prompts and answers. Heartbeats are comments without
an ID. Partial blocks are discarded when the connection closes.

A client starts with `/snapshot`, then supplies its cursor in `Last-Event-ID`
to `/events`. `Accept: application/json` selects bounded polling through the
same endpoint and cursor. Every batch atomically checks the retained floor
and reads events, including batches on an open stream. Wrong-stream,
view-invalid, expired, and future cursors require a new snapshot. Clients do
not interpret numeric gaps in an authorization-filtered stream as corruption.
Overview and JSON event responses publish a view-bound `oldestCursor`, the
oldest valid resume boundary. Clients use it as supplied and never derive it
by decrementing an event identifier.

Refreshes are serialized per resource. An invalidation received during a
refresh sets a dirty flag, and the resource is fetched again afterward. A
resnapshot or endpoint change invalidates older fetch generations and page
sets. Mutation receipts are not replacement snapshots. Closing every network
client never closes a manager-owned worker control pipe.

## Refusals

Problems use `application/problem+json`, with a bounded stable `code`, status,
title, instance, and applicable same-origin links. Type identifiers use
`urn:agent-cat:manager:problem:<code>` and are not network fetch instructions.
They contain no credentials, captured values, argv, server paths, stack traces,
or raw provider errors.

| HTTP status | Stable categories |
|---|---|
| 400 | `malformed-request`, `duplicate-field`, `unknown-field`, `unsupported-version`, `invalid-precondition`. |
| 401 | `unauthenticated`. |
| 403 | `insufficient-scope`, `origin-refused`. |
| 404 | `unavailable-resource`. |
| 409 | `state-conflict`, `authority-changed`, `idempotency-conflict`, `decision-not-head`, `unsupported-operation`, `ownership-unavailable`, `quarantined`, `export-conflict`, `incompatible-parent`. |
| 410 | `receipt-expired`, `cursor-expired`, `view-expired`. |
| 412 | `stale-revision`. |
| 413 | `size-limit`, `view-too-large`. |
| 415 | `unsupported-media-type`, `content-coding-refused`. |
| 422 | `invalid-input`, `invalid-answer`, `invalid-lineage-edit`. |
| 428 | `precondition-required`. |
| 429 | `rate-limit`, `admission-limit`, `storage-quota`. |
| 503 | `storage-unavailable`, `supervision-unavailable`. |

Authentication precedes resource-existence disclosure. A malformed transport
or size refusal may occur before a resource is resolved. Safe admission and
storage failures are not converted into successful receipts.

## Command-line boundary

`RUNNER` denotes the configured registry executable. These new command forms
are specified here and are not yet implemented. Existing `RUNNER --tui` and
native frontend commands remain unchanged.

```text
RUNNER --manager serve --config ABSOLUTE_FILE
RUNNER --manager admin --config ABSOLUTE_FILE
RUNNER --tui --service CLIENT_PROFILE
RUNNER --tui --local
```

Service startup is foreground and takes trust, TLS, profiles, and storage
configuration only from the selected local file. Administration consumes one
versioned JSON request through stdin EOF and returns one bounded JSON result.
Its operation set is `status`, `reload-profiles`, `list-credentials`,
`issue-credential`, `rotate-credential`, `revoke-credential`, `drain`,
`shutdown`, `check-store`, `backup`, `restore`, `check-quarantine`, and
`release-quarantine`. Local administration has no HTTP equivalent. A malformed
request, missing operation, or unknown operation returns a strict pre-dispatch
error with `operation: null` rather than guessing a recognized operation.

Credential issuance writes generated secret material exclusively to a selected
private output file, never stdout, argv, or diagnostics. Backup restoration
is offline and requires worker fencing, fresh authority, and explicit local
credential reprovisioning. Quarantine release requires verified cleanup
evidence, not an acknowledgement used as a substitute for that evidence.

A service client profile is selected from trusted local configuration. It
contains an HTTPS endpoint and an OS credential-store or private-file
reference, not a credential supplied by the model or inferred from history.
Exactly one local or service mode is active. Mode or endpoint changes advance
the client's fetch generation and do not transfer live worker ownership.

## Verification

Run the contract gate in the configured Nix environment:

```sh
direnv exec . bash manager/ci/contract.sh
direnv exec . make -C doc check-api
```

The gate checks the standard OpenAPI and JSON Schema descriptions, the
independent resource/scope ledger, strict payloads, SSE boundaries, and receipt
bindings for exact download bytes. It does not establish that a manager,
credential operation, worker, network transport, or service client exists.
