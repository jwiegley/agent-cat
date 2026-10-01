# Workflow-manager protocol version 1

This directory specifies the manager contract established by WM-003. The
service and service-mode clients implement only part of this contract. The
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

The native-version domain amendment of 2026-09-23 admits frontend session 2
and runtime observation protocol 3, which the current manager worker already
negotiates. Session 2 retains control protocol 2. Public API, snapshot and event
versions remain 1, and the existing native version cases remain valid. A run
reports its actual native protocol version rather than a relabelled public
version. Unknown future versions still refuse. This changes the advertised
compatibility domains, not the native wire or storage formats. The same
amendment admits manager coordination schemas 1 through 12, which the existing
Store already reads or migrates. The service reports these supported schemas
instead of advertising only the original schema 1. Schema 13 remains unsupported.

## HTTP framing and limits

JSON is UTF-8 with `Content-Type: application/json`. Captures use
`application/octet-stream` and contain raw UTF-8 bytes. Content coding is not
accepted. A request with any `Content-Encoding` header, including `identity`,
receives 415 `content-coding-refused`. JSON duplicate keys, non-finite numbers,
invalid Unicode, unknown command fields, and excessive nesting refuse. A
duplicate key receives 400 `duplicate-field`. The JSON nesting limit is 64
containers, and a body nested 65 deep receives 400 `malformed-request`. Byte
limits apply before unbounded allocation and are not character counts.

| Boundary | Version 1 limit or initial policy |
|---|---|
| Request target | 8192 bytes. |
| Complete request headers | 16384 bytes and 100 fields. |
| JSON request body | 2097152 bytes. |
| Encoded native control | 1048576 bytes, including its framing. |
| Capture and aggregate inputs of one request | 67108864 bytes. |
| Verified artifact content | 67108864 bytes, with at most two downloads in progress for each manager. A third download waits up to five seconds for a download to end and then refuses with `storage-quota`. A download that lasts longer than 300 seconds stops at its next write, and the client receives a truncated body. |
| Complete SSE block | 16384 bytes. |
| JSON page | 1048576 bytes. |
| Route batch | 1048576 encoded bytes, for a run route batch and a manager route batch. A batch reads windows of at most 64 records and scans at most 1024 records. |
| Materialized page set | 67108864 bytes, two active sets per client, expiring after 60 seconds. For `/requests` and `/runs`, the byte bound applies to each window of 1024 members. |
| Live collection | 1024 items in each list of `/snapshot` and in `/decisions`. A larger list receives 413 `view-too-large`. |
| Queue | 100 queued requests. Drafts have a separately enforced, advertised positive bound. |
| Execution reservations | One by default, with a maximum of 16. Review and cleanup consume reservations. |
| Prepared review | Ten-minute expiry. Expiry does not release an uncleaned worker's reservation. |
| SSE readers | Two per client across `/events`, `/runs/{id}/routes` and `/routes`, with at most 1048576 pending transport bytes per reader. |
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

## Transport boundary

The service accepts only TLS 1.3, including on loopback. The TLS handshake of
a TLS 1.2 client fails with a protocol-version alert. Plaintext HTTP bytes on
the service port receive only the fixed refusal of warp-tls 3.4.14, and the
connection then closes. That refusal starts with the status line
`HTTP/1.1 426 Upgrade Required` and ends with the body `HTTPS required`. Its
first three header lines end with twelve spaces, a backslash and the letter
`r` before the line feed, so it is not a well-formed HTTP response. It is the
same for every plaintext request. It carries no resource state, and the
service reads no credential from a plaintext request.

The HTTP server refuses complete request headers above 16384 bytes with 400
`malformed-request` before the service reads the request. The service then
checks each request in the order below, before authentication. The first
condition that holds determines the problem response.

| Condition | Refusal |
|---|---|
| The request target is in absolute form or asterisk form, or its raw path differs from the path that its decoded segments spell. A percent-encoded dot segment is one such path. | 400 `malformed-request`. |
| The query has a parameter named `token`, `access_token` or `authorization`, in any letter case. | 400 `malformed-request`. |
| The request target is above 8192 bytes, the request has more than 100 header fields, or its header fields are above 16384 bytes. | 413 `size-limit`. |
| The request repeats `Host`, `Authorization`, `Origin`, `Content-Type`, `Content-Length`, `Transfer-Encoding`, `Idempotency-Key`, `If-Match`, `If-None-Match`, `Accept`, `Last-Event-ID`, `Access-Control-Request-Method` or `Access-Control-Request-Headers`. | 400 `malformed-request`. |
| `Host` is absent or differs from every `allowedHosts` entry, compared without letter case. A Host with another port or without its port differs. | 400 `malformed-request`. |
| The request has a `Cookie`, `Forwarded` or `X-Forwarded-*` header. | 400 `malformed-request`. |
| The request has a `Content-Encoding` header. | 415 `content-coding-refused`. |
| The request has `Transfer-Encoding` together with `Content-Length`. | 400 `malformed-request`. |
| `Origin` is present and is not an `allowedOrigins` entry. `Origin: null` is such an origin. | 403 `origin-refused`. |
| The declared `Content-Length` is above the body limit of the route. | 413 `size-limit`, before the service reads a body byte. |

A path with an empty, dot or trailing segment that is not percent-encoded
passes these checks and names no resource. With a current bearer it receives
404 `unavailable-resource`, and without one it receives 401. The service never
answers with a redirect. A `Location` header appears only on 201 and 202
responses.

Every response of the service, including each refusal above, carries
`Cache-Control: no-store`, `X-Content-Type-Options: nosniff` and
`Vary: Origin`. When the request has an `Origin` from `allowedOrigins`, the
response also carries `Access-Control-Allow-Origin` with that origin and
`Access-Control-Expose-Headers: ETag, Location, Retry-After`. Any other
response carries no CORS header.

The connection timeout of the HTTP server is 15 seconds. Request headers that
arrive in small reads for 15 seconds end with a closed connection and no
response. The service reads a JSON body for at most 15 seconds. The connection
timeout pauses after each body read, so a body that is not complete within
that bound receives 400 `malformed-request`. When no body byte arrives, the
two bounds end together, and the client receives that refusal or a closed
connection.

The service serves at most `globalConnections` connections at once. A further
connection waits in the listen queue, which holds at most 128 entries and at
most `globalConnections` entries. It receives no TLS handshake until a served
connection closes. It is then served normally.

## Mutation receipts and preconditions

Every POST requires `Idempotency-Key: <authorityEpoch>.<nonce>`. The complete
key is at most 128 ASCII bytes and its newly generated nonce contains at least
128 random bits. Authority epochs are at most 105 ASCII characters, leaving room
for the separator and a minimum 22-character nonce. Its scope is the
authenticated registered client, method,
canonical URI, and key. The ledger binds exact body bytes, content type, and
preconditions. Credential rotation retains the client identity and ledger, so
a rotated credential that repeats an exact attempt of its predecessor receives
the retained receipt.

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

Draft creation and capture creation have no existing-resource ETag. A
capture is bound to its request, selected profile, and authenticated client.
It does not supply an input until a subsequent checked `set-input` operation
binds its opaque identifier. The service answers a capture with 202, the
CaptureReceipt as the body, and a `Location` of `/v1/commands/{id}` for the
capture command, because a capture has no resource URI of its own. An exact
retry of the capture key returns the same receipt and the same `Location`.
Export and lineage collections have GET methods so their POSTs use same-URI
validators. An ETag from a snapshot, parent run, different query, or later
page is not substituted for that collection's ETag. The first page of
`/runs/{id}/exports` carries the collection revision as its strong ETag, and
its `page.revision` holds the same value. The collection revision changes
when an export of the run is accepted, and also when the supervision of the
run or the verification of its result changes. A later page of the
collection has a representation tag. The first page of
`/runs/{id}/lineage-requests` carries the revision of the parent run as its
strong ETag, and its `page.revision` holds the same value. That revision
changes when a lineage request of the run is accepted, and also when another
fact of the run changes, for example its supervision.

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

The Served column lists the methods that the foreground service of
`RUNNER --manager serve` routes. For `/preparations/{id}` it serves the
`approve` and `discard` operations. A `discard` of a live preparation whose
request is in `review` returns a 202 receipt. It invalidates the preparation
with the reason `discarded` at once and holds the reservation until the
manager has discarded the prepared worker. The release of the reservation then
records the effect `discarded` on the command and returns the request to the
`draft` phase with `released` admission and a null `preparationId`. A later
`enqueue` of that draft prepares a new review. A `discard` of a consumed or
invalidated preparation, or of a preparation whose approval is accepted,
receives 409 `state-conflict`.
A path that the service does not route receives 404 `unavailable-resource`,
and an unrouted method on a routed path receives 405. The `/decisions`
collection is a page set over one durable commit boundary. The `/requests`
and `/runs` collections are windowed page sets, as "Pages and live delivery"
states. Each item is the representation of its detail resource. `/requests` lists
every request of the authorized profiles, and `/runs` lists every managed run
of those profiles, both in identifier order. `/decisions` without `runId`
lists the pending run heads in manager observation order. With `runId`, it
lists the pending queue of that run in its opening order. A `runId` that
names no run, or a run of a profile that the credential cannot observe,
receives 403 `insufficient-scope`.
With the `--legacy-history ROOT=PROFILE` option, `RUNNER --manager serve`
binds a configured local retention root to a configured profile. `/runs` then
also lists the legacy entries of the bound roots of the authorized profiles,
in the same identifier order and windows, and `/runs/{id}` serves each one
with the same representation. A legacy entry has `observer` supervision and a
null `requestId`. Its result artifact downloads through `/artifacts/{id}`.
The other run resources refuse a legacy entry with 403 `insufficient-scope`,
because no stored record grants control, export or lineage authority. Without
the option, `/runs` lists managed runs only. Two bounds apply to legacy
entries. The retention bound is 65536 entry names for each bound root.
Before each page of `/runs`, the service lists the entry names of each bound
root within that bound and keeps one opaque identifier for each name. A
bound root with more than 65536 names refuses `/runs` with
`view-too-large`. The per-window bound is 256 legacy entries and 1 MiB
encoded. Each window of `/runs` reads only the legacy entries that it lists,
within that bound, and ends before the first legacy entry beyond it. The
next window starts at that entry, so a bound root can hold more legacy
entries than one window, and a client that follows every page receives each
legacy entry once. A legacy `/runs/{id}` reads only its own entry.
`/runs/{id}/exports` and `/runs/{id}/lineage-requests` are page sets of one
run. The first lists the export receipts of the run in identifier order, and
each item equals the `/exports/{id}` representation. The second lists the
child requests of the run in identifier order, and each item equals the
`/requests/{id}` representation. Its `eligible` field lists the operations
that a new lineage request may name now. When it lists none, `refusal` gives
the reason. The native preparation still checks the checkpoint and effect
facts of each operation after approval. A run identifier that names no run,
or a run of a profile that the credential cannot observe, receives 403
`insufficient-scope`. An unknown export receives 404 `unavailable-resource`,
and an export of such a profile receives 403 `insufficient-scope`.
A POST to `/runs/{id}/exports` with the body `{"name": NAME}` exports the
verified result of the run as `NAME`. It requires `observe` and `export` on
the profile of the run and the strong ETag of the first collection page as
`If-Match`. The service answers 202 with the CommandReceipt of the `export`
command and `Location: /v1/commands/{id}`. The manager publishes the export
once. The command then records the effect `exported` with the resource
`/v1/exports/export_{commandId}`. The receipt of the export appears in the
collection and as `/exports/{id}` with the state `published`, and its
`download` link `/artifacts/{id}` returns the exported bytes. An exact retry
of the key returns the same receipt and the same `Location` without another
publication. A stale `If-Match` receives 412 `stale-revision`, and a name that
another export of the destination holds receives 409 `state-conflict`.
A POST to `/runs/{id}/lineage-requests` with the body
`{"operation": "restart"}`, `{"operation": "resume"}` or
`{"operation": "fork", "edits": EDITS}` creates a child request of the run.
Each fork edit is `{"occurrenceId": ID, "operation": "drop"}` or
`{"occurrenceId": ID, "operation": "replace", "answer": VALUE}`. The request
requires `observe` and `submit` on the profile of the run and the strong ETag
of the first collection page as `If-Match`. The service answers 202 with the
CommandReceipt of the `restart`, `resume` or `fork` command and
`Location: /v1/commands/{id}`. The command records the effect
`lineage-created` with the resource `/v1/requests/{id}` of the child. The
child is an ordinary draft whose `parentRunId` names the run and whose
`lineage` names the operation. It appears in `/requests` and in the lineage
collection. Its inputs come from the parent, so an `enqueue` prepares it
without `set-input`. The review of its preparation has a `lineage` field with
`parentRunId`, `operation` and `edits`, where a replacement shows the
`sha256` of its answer and not the answer. The review of a root request has no
`lineage` field. An approval then starts the child run, whose `parentRunId`
and `lineage` name the parent and the operation. An exact retry of the key
returns the same receipt and the same `Location` without another child. A
stale `If-Match` receives 412 `stale-revision`. A legacy entry receives 403
`insufficient-scope`, as the other run resources refuse it.
`/runs/{id}/routes` serves the run log `flow.ndjson` of the run store of a
managed run. It requires `observe` on the profile of the run, and a run
identifier that names no managed run, or a run of a profile that the
credential cannot observe, receives 403 `insufficient-scope`. The route class
of each record decides whether the credential receives it. A credential with
`observe` receives public records, which are the `event` records. A
credential that also holds `control` on the profile receives the actor
records as well. The restricted records, `engine-result` and `failure`, are
never served. `Accept: application/json` gives one batch, and
`Accept: text/event-stream` gives a route stream. Any other `Accept` value
receives 409 `unsupported-operation`. A route read writes nothing to the
coordination database.
`/routes` serves the manager log of the current stream: its sealed segments
and its active file, as the [storage contract](../../manager/STORAGE.md#manager-log)
describes them. It requires `observe` on at least one configured profile, as
`/events` does. The profile of each record comes from the identifiers in its
`about`. A `command` record, a `receipt` record and a `command-changed` notice
belong to the profile of their command. A `review` record, a `review-ended`
notice and a `request-ended` notice belong to the profile of their request. A
`start` or `control` relay belongs to the profile of its run, and a `discard`
relay to the profile of its request. A record whose profile does not resolve
is never served. These are the administration records of the local channel,
the `lifetime`, `shutdown` and `gap` notices, and a command whose transaction
rolled back. Every other manager-log record is an actor record, and a
credential receives it only when it holds `observe` and `control` on the
profile of the record. The manager log has no public record, so a credential
with `observe` alone receives filtered gaps only. The `failure` records are
restricted and are never served. `Accept: application/json` gives one batch,
and `Accept: text/event-stream` gives a route stream. Any other `Accept` value
receives 409 `unsupported-operation`. A read of `/routes` writes nothing to the
coordination database.

| Resource | Methods | Served | Mutation scopes and guard |
|---|---|---|---|
| `/capabilities` | GET | GET | No mutation. Versions, limits, transports, and authority are view-filtered. |
| `/profiles` | GET | GET | No mutation. Only public labels, revisions, readiness, and permitted profiles appear. |
| `/workflows` | GET | GET | No mutation. `profileId` selects an authorized, bounded catalogue. |
| `/workflows/{id}` | GET | GET | No mutation. Catalogue information is not an exact input-dependent plan. |
| `/requests` | GET, POST | GET, POST | `submit` creates a draft bound to current profile and descriptor revisions without workflow execution. |
| `/requests/{id}` | GET, POST | GET, POST | `submit` permits `set-input`, `remove-input`, `enqueue`, and `withdraw` before start intent. Editing invalidates previous admission or review. |
| `/captures` | POST | POST | `submit` for the selected request and profile. Raw bounded UTF-8 only, with no source URL or pathname. The 202 response carries the CaptureReceipt and `Location` names the capture command. |
| `/preparations/{id}` | GET, POST | GET, POST | `submit` and `control` for `approve` or `discard`. Approval also requires the review digest and exact live worker association. |
| `/runs` | GET | GET | No mutation. Runtime, supervision, integrity, and verification remain distinct. |
| `/runs/{id}` | GET | GET | No mutation. Includes lineage and links, not execution authority. |
| `/runs/{id}/snapshot` | GET | GET | No mutation. Provides one consistent versioned runtime-derived view. |
| `/runs/{id}/control` | GET, POST | GET, POST | `control`, live manager ownership, current control revision, and exact addressed occurrence and attempt where required. |
| `/decisions` | GET | GET | No mutation. Pending run heads are ordered by manager observation, with each run's queue retained. |
| `/decisions/{id}` | GET, POST | GET, POST | `control` for `answer` or `choose-recovery`, with exact generation and the shared per-run FIFO reservation. |
| `/commands/{id}` | GET | GET | No mutation. A known command identifier does not bypass current operation or profile authorization. |
| `/runs/{id}/outputs` | GET | GET | No mutation. Intermediate output and diagnostics are separate from verified final content. |
| `/artifacts/{id}` | GET | GET | No mutation. The server resolves and verifies its retained internal reference before sending content. |
| `/runs/{id}/exports` | GET, POST | GET, POST | `observe` and `export`, current collection ETag, verified source, and a permitted single-component name. |
| `/exports/{id}` | GET | GET | No mutation. Returns receipt metadata and an authorized download link without a server path. |
| `/runs/{id}/lineage-requests` | GET, POST | GET, POST | `observe` and `submit`, current collection ETag, eligible parent, compatible trusted invocation, and no conflicting ownership or quarantine. |
| `/snapshot` | GET | GET | No mutation. Provides a consistent authorized overview and replay cursor. |
| `/events` | GET | GET | No mutation. SSE and bounded JSON use the same durable cursor and retention rules. |
| `/runs/{id}/routes` | GET | GET | No mutation. Serves bounded JSON batches or a route stream of the run log of the run by route class. `observe` gives public records, and `observe` with `control` also gives actor records. |
| `/routes` | GET | GET | No mutation. Serves bounded JSON batches or a route stream of the manager log of the current stream. `observe` and `control` on the profile of a record give that record. A record without a profile is never served. |

OPTIONS preflight is the sole unauthenticated HTTP operation. After the
[transport checks](#transport-boundary), it checks only an exact allowlisted
origin, an advertised method, and permitted header names. The permitted names
are `authorization`, `content-type`, `if-match`, `idempotency-key`, and
`last-event-id`. A conforming preflight returns 204 with no body. Its headers
are `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods` with the
requested method, `Access-Control-Allow-Headers` with the requested names,
`Access-Control-Expose-Headers`, the three headers that every response
carries, and the `Date` and `Server` headers of the HTTP server. It reads no
resource state and does not authorize a subsequent request. That request
still requires a bearer, and without one it receives 401. A preflight without
`Access-Control-Request-Method` receives 400 `malformed-request`. A preflight
without `Origin`, or with a forbidden origin, method, or header name, receives
403 `origin-refused`. Any request with an unexpected origin or `Origin: null`
receives 403 `origin-refused`. An absent Origin is permitted for authenticated
native clients. Cookie authentication, wildcard credentialed CORS, query-string
credentials, and a network administration scope are absent.

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

`POST /runs/{id}/control` accepts `cancel`, `steer`, `redirect`, `retry`,
`choose-recovery`, and `answer`. `POST /decisions/{id}` accepts `answer` and
`choose-recovery` for that decision. The control view offers `steer` for a
running attempt that registered steering support, `redirect` for an open
dispatch, and `answer`, `retry`, or `choose-recovery` for the pending decision
head of the run. It also offers `redirect` for an occurrence whose one attempt
runs after its dispatch window closed, when the occurrence intent is not
`effect`. The targets of that offer come from the route names of the approved
policy of the run, each written as the occurrence addressee with the route
name as its model axis, without the candidate in flight. The runtime then stops
the attempt and asks the chosen target in a new question, or rejects a target
that is not a live candidate of its fail-over chain. `cancelAllowed` is true while the manager owns the live run
and the run is running. The `If-Match` value is the control revision for
`/runs/{id}/control` and the decision revision for `/decisions/{id}`.

A control that the current runtime state does not offer receives 409
`unsupported-operation`. An answer or recovery choice for a pending decision
that is not the head of its run receives 409 `decision-not-head`, and the
queue order does not change. When two clients send a control for the same
head decision with the same revision, the first reservation changes that
revision. The other client receives 412 `stale-revision`, and only one answer
or choice reaches the run. A steer, a retry, a recovery choice, a redirect,
and a delivered answer each record their correlated runtime effect in the
command receipt. A cancel receipt records the runtime acknowledgement. The
snapshot reports the cancelled run, and the receipt records no cancel effect,
because the runtime cancellation event names no control.

Restart, resume, and fork create new requests. The lineage body supplies only
the selected operation and permitted typed fork edits. It cannot replace the
parent's workflow, inputs, target, invocation, or filesystem root. A new
preparation always requires a new exact approval. Its public review includes
the program hash, person-answering mode, allowlisted public policy and
lineage from that same native prepared response, not a later configuration
lookup.

An unreadable manifest remains a visible catalogue entry with an opaque handle,
profile, safe failure category, and only known metadata. It does not require
an invented workflow identity, manifest version, or runtime state.

## Pages and live delivery

A page set is materialized at one database boundary, then served outside the
read transaction. The first-page request reserves the set before
materialization. The set holds one revision, and a mutation that commits
after that boundary does not change a later page of the set. A fresh set shows
the mutation. Clients assemble a complete page set before installing it.

The `/requests` and `/runs` collections are windowed page sets. A window
holds at most 1024 members in identifier order, and each window is
materialized at its own database boundary. The service holds the pages of one
window at a time. The last page of a window that more members follow carries
`next` with the next index of the same set, in the same token syntax.
Following that token checks the client, authorization view, path and query as
for every continuation, then materializes the next window, replaces the held
pages and renews the set lifetime to 60 seconds from that request. Every page
of the set keeps the `revision` and `expiresAt` of the first page, and
`totalItems` counts the members at the boundary of the first window. A token
whose index belongs neither to the current window nor to the first page of
the next window receives 410 `view-expired`, as a token of an expired set
does. A client that follows every page receives each member that existed at
the first boundary exactly once. A member that is created later with an
identifier larger than the last identifier already served can also appear,
so such a set can hold more items than its `totalItems`. A collection of at
most one window is an ordinary page set of one boundary.

Opaque page tokens bind the client, authorization view, path, and query of the
first-page request. The service compares each continuation with the newly
authorized request, so token possession grants no authority. A token that
another client presents, that arrives on another path or with another query,
or that follows a change of the authorization view receives 410
`view-expired`. A credential rotation changes the view of both the
predecessor and the successor. Such a refusal does not retire the set for its
owner. A revoked or cut-off credential receives 401 for every later page.

A set expires 60 seconds after its reservation. Reads do not extend the
lifetime, except that the first page of each later window of a windowed set
renews it, and a later token receives 410 `view-expired`. A set retires when
its last page has been sent, or when the client closes the connection during a
page response. An open set counts against the limit of two sets for each
client and against the global page-set limit until it retires or expires. A
first page that exceeds either limit receives 429 `storage-quota`. A view with
one item larger than the page bound, or a view larger than the page-set bound,
receives 413 `view-too-large` and holds no capacity.

The ETag of each page is a representation tag of the request target and the
exact page bytes, except that the first page of an export collection carries
the collection revision. A first-page ETag is not interchangeable with another page's
validator. An open SSE response ends when its credential is revoked.

SSE uses UTF-8 and dispatches only complete blocks ending in a blank line.
The supported event names are `request.changed`, `preparation.changed`,
`run.changed`, `decision.changed`, `command.changed`, `artifact.changed`, and
`service.changed`. Data is a versioned resource invalidation, not a runtime
delta or a container for prompts and answers. Heartbeats are comments without
an ID. Partial blocks are discarded when the connection closes.

A client starts with `/snapshot`, then supplies its cursor in `Last-Event-ID`
to `/events`. `Accept: application/json` selects bounded polling through the
same endpoint and cursor. A client can also supply the cursor as the single
query parameter `after`. A request that supplies both `after` and
`Last-Event-ID` receives 400 `malformed-request`, even when the two values are
equal. The snapshot cursor is the durable position at which the snapshot was
captured, so the first event after it has the next durable position and no
change falls between the snapshot and the events. SSE and polling from one
cursor deliver the same events in the same order, and each event once.

Every batch atomically checks the retained floor and reads events, including
batches on an open stream. The cursor of a batch advances over every record
that the batch scanned, including records that the credential cannot see.
Event identifiers of an authorization-filtered stream therefore have numeric
gaps, and clients do not interpret these gaps as corruption. A cursor of
another stream or of a changed authorization view receives 410
`view-expired`. A cursor below the retained floor or ahead of the stream
receives 410 `cursor-expired`. Both require a new snapshot. Overview and JSON
event responses publish a view-bound `oldestCursor`, the oldest valid resume
boundary. Clients use it as supplied and never derive it by decrementing an
event identifier.

A client that loses an SSE connection reconnects with `Last-Event-ID` set to
the identifier of its last complete block. The manager then delivers every
later event, starting with a block that arrived only in part, and it does not
repeat a complete block. An ordinary restart keeps the `streamId` of
`/capabilities` and every cursor taken before the restart. At an ordinary
shutdown, an open SSE response ends after its current block or heartbeat, and
a new SSE request receives 503 `storage-unavailable`. The client reconnects
after the restart with its last complete event identifier. Offline backup
restoration rotates the stream and revokes every restored credential. A
cursor taken before the restoration then receives 410 `view-expired`, even
with a new credential, and the client takes a new snapshot.

A run route batch is `{"version":1,"cursor","oldestCursor","records","hasMore"}`.
Each record is the JSON form of the local flow reader, as `agentic-run flow`
prints it: `position`, `schema`, `from`, `to`, `about`, `replyTo`, `at` and
the body, with the fields `id` and `class` added. An inline body is `body`, a
claim check is `claim` with its digest and size and without its content, and
an `event` record is `event` with the sequence number of its line of the run
event log. A route cursor is an alias, a dot and the position of the next
record to read. The alias is `route_` and the SHA-256 of the public stream
identity of the credential and the public run identifier, so it changes when
the `streamId` of the credential changes. The record at position p has the
identifier with position p+1, so a client resumes after a record by supplying
its identifier. A request without a cursor starts at the first record. The
cursor comes from the query parameter `after` or from `Last-Event-ID`, and a
request that supplies both receives 400 `malformed-request`. The query
parameter `route` takes comma-separated `field=value` terms, as the
`--route` option of `agentic-run flow` does, and a batch serves only the
records that match every term. A route term with an unknown field receives
400 `malformed-request`. The cursor of a batch advances over every record that
the batch scanned, including the records that the route class or the route
omits, so record identifiers have gaps. A batch serves at least one record
when a served record follows within its scan bound of 1024 records. A batch
whose scanned records are all omitted serves no record, advances its cursor
and sets `hasMore`. A cursor with another alias receives 410 `view-expired`.
A cursor whose position lies after the last complete record receives 410
`cursor-expired`. The floor of a run log is position 0, so `oldestCursor`
always names position 0. Authorization is checked on every batch and again
before each write of the response.

A manager route batch has the same fields and the same cursor, parameter,
batch and gap rules as a run route batch. Its records are the `command`,
`receipt`, `review`, `relay` and `notice` records of the manager log, each
with the class `actor`. Its alias is `route_` and the SHA-256 of the public
stream identity of the credential and the name of the manager log. The alias
names no segment and no file, so a cursor stays valid when the writer seals
the active file and when the pruner removes a sealed segment. A restoration
gives a new stream identity, so a cursor taken before it receives 410
`view-expired`. `oldestCursor` names the retained floor, which is the start of
the oldest remaining sealed segment, or position 0 before the first prune. A
request without a cursor starts at the retained floor. A cursor whose
position lies below the retained floor, or after the last complete record,
receives 410 `cursor-expired`. The manager reads each batch without the
writer lock of the manager log, and it resolves the profiles of the records
of each window in one read transaction.

A route stream serves the batches of a route as server-sent events. It takes
the same cursor, from `after` or from `Last-Event-ID` and never from both, and
the same `route` parameter. A refusal of its first batch is an ordinary
problem response. Each served record is one block with the lines `id`,
`event` and `data` in that order: the identifier of the record, the event name
`route.<schema>`, and the record of the JSON batch as compact JSON. A block
holds at most `sseBlockBytes` bytes. A record whose block would be larger is
served with its body replaced by `{"omitted":"size","bytes":N}`, where N is
the encoded size of the body. A batch that serves no record and advances its
cursor over omitted records writes one block with an `id` line only, which
carries the cursor of the batch and emits no event. A comment-only heartbeat
follows every `heartbeatSeconds` without another block. A client that loses
the connection reconnects with `Last-Event-ID` set to the identifier of its
last complete block, and the stream then serves every later record without
repeating a complete block. Each batch of a stream is bound, read and
filtered as a JSON batch is, and authorization is checked again before each
block and each heartbeat. A stream of the run route reads again one second
after a batch that reached the end of the log. A stream of the manager route
reads again when the manager appends a record to the log, so a new record
reaches an open stream before the next heartbeat. A route stream counts toward
the two readers of its client, together with the streams of `/events`, and a
third stream receives 429 `storage-quota` as `/events` does. At an ordinary
shutdown an open route stream ends after its current block or heartbeat. An
ordinary restart keeps the `streamId`, so the route aliases and every cursor
taken before the restart stay valid.

The public client coordinates refreshes without I/O in
`Agentic.Manager.Client.Refresh`, which the `Agentic.Manager.Client` facade
re-exports. A `Refresh` value holds the current fetch generation and, for each
resource key, at most one fetch in flight with its generation and a dirty
flag. A key without a fetch in flight is idle. `invalidateResource` and
`completeFetch` return the next value and the actions that the caller
performs: `StartFetch`, `InstallFetch` or `DiscardFetch`, each with its key
and generation.

- `invalidateResource` starts a fetch of the current generation for an idle
  resource. For a resource with a fetch in flight, it only sets the dirty
  flag. Any number of invalidations during one fetch therefore give exactly
  one later fetch.
- `completeFetch` installs a completion only when its generation is the
  current generation and the resource has a fetch in flight of that
  generation. When the dirty flag is set, exactly one more fetch starts, and
  otherwise the resource becomes idle. Every other completion, in particular
  a late completion of an earlier generation, is discarded and changes
  nothing. An installed result is a value or a refusal.
- `advanceGeneration` applies a resnapshot, after a 410 refusal or a new
  overview, and an endpoint switch. The generation advances and every
  resource becomes idle, so the results of every fetch of an earlier
  generation, page sets included, are discarded when they complete.

`reconnectDelay` gives the delay before a reconnection and the next backoff.
The delay starts at one second (`initialBackoff`) and doubles up to
`reconnectBackoffMaxSeconds` (30 seconds). A connection that delivered an
event resets the backoff to `initialBackoff`. `jitteredMicroseconds` gives
the wait for a delay and a fraction from zero to one. The wait is between
half the delay and the whole delay, so it never passes 30 seconds.

A pending command whose send outcome is uncertain becomes an `Uncertain`
value through `uncertainPending`. That value keeps the exact pending command,
with its bytes, key and precondition, its target resource and the receipt
location that an earlier response gave. `reconcileRead` names the one read of
a reconciliation: the receipt location when one is known, or else the target
resource. `reconcile` reports the result of that read. With a receipt
location, only the receipt state decides: `effect-observed` reports the
effect, `refused` reports the refusal, and every other state stays uncertain.
Without one, the target reports the effect only when the caller sees the
effect in it and its entity tag differs from the precondition. A failed read
and an observation of the other read stay uncertain. A command that stays
uncertain comes back unchanged. No report carries a send, so reconciliation
never sends. The only resend is the explicit exact resend that the frontend
offers. Mutation receipts are not replacement snapshots. Closing every
network client never closes a manager-owned worker control pipe.

The public client decodes live delivery without I/O in
`Agentic.Manager.Client.Events`, which the `Agentic.Manager.Client` facade
re-exports. `newSseParser` starts the parser of one connection, with the
identifier that a reconnection sends in `Last-Event-ID`. `feedSse` accepts
the response bytes split at any point and returns one outcome for each block
that the bytes complete, in order. A line ends at LF or at CRLF, and a blank
line ends a block. A block with `data` dispatches an event with the `id` of
the block, its last `event` name or `message`, and its `data` lines joined
with LF. A block with an `id` and no `data` advances the last event
identifier and dispatches nothing. The route stream writes such a block when
a batch serves no record. A block of comment lines only is a heartbeat. The
parser refuses with `InvalidResponse` a block larger than `sseBlockBytes`,
counted with its terminating blank line, and an incomplete block as soon as
it passes that bound. It also refuses a block that is not UTF-8, a carriage
return that does not end a line, and an `id` that is not a canonical cursor.
`closeSse` discards an incomplete final block and returns the last complete
event identifier. The parser does not remove a repeated identifier. Each
complete block dispatches once, and the consumer compares identifiers.

`decodeEventBlock` decodes a dispatched block of `/events` as an
`InvalidationEvent` with one of the seven event names and an `Invalidation`
of `version`, `resource` and `revision`. `decodeRouteBlock` decodes a block
of a route stream as a `RouteRecord`. It checks that the record identifier
equals the block identifier and that the event name is `route.` followed by
the record schema. The decoders of `Invalidation`, `InvalidationEvent`,
`EventBatch` and `RouteRecord` refuse unknown and missing fields. Their
encoding gives back the decoded JSON value unchanged, including `false`,
`null`, large numbers in a route body and Unicode text. A number that the
protocol bounds to 64 bits refuses when it is out of range and is never
rounded. `problemFailure` maps a problem response to `Refused` with its
status and code, so a 410 `view-expired` or `cursor-expired` problem gives
`Refused 410` with that code. A body whose `status` differs from the response
status, or whose `code` is not a bounded identifier, gives `InvalidResponse`.
`validCursor` checks the cursor syntax. `validETag` checks a strong entity
tag, and the client compares entity tags only for equality.

`clientCapabilities` returns the capabilities document that the session
verified at connection, and `clientEndpoint` returns the host and port of the
endpoint that the session is bound to. `requiredScopes` gives the scopes that
the manager requires for an operation that `parseOperation` names, and
`scopeName` gives the public name of each scope. A client compares them with
the `scopes` of the capabilities to refuse an operation locally before it
sends a request.

The facade also performs live delivery through one connection at a time.
`loadOverview` assembles the page set of `/snapshot` and returns its `cursor`,
its `oldestCursor` and its members. Each member has its kind (`request`,
`preparation`, `run` or `decision`), the reference of its detail resource,
its revision and its value. The reference is the resource of the
invalidations of that member, for example `/v1/requests/{id}`. The page set
refuses with `InvalidResponse` when a page repeats a different `cursor` or
`oldestCursor`. `pollEventBatch` sends one JSON polling request after a
cursor and decodes the response as an `EventBatch`. `streamEvents` sends one
`GET /v1/events` with `Accept: text/event-stream` and the cursor in
`Last-Event-ID`. It uses the session checks of every other request: the
endpoint of the session, one credential read before the request whose
fingerprint is the session fingerprint and whose bearer the request sends,
the credential fingerprint again before each delivery, no redirect, no proxy, no cookie, no decompression and
no retry. It requires status 200, the media type `text/event-stream` and
`Cache-Control: no-store`. A refusal gives the failure of its problem
response, so an expired cursor gives `Refused 410` with its code. The stream
reads the body incrementally with the parser above and gives each complete
invalidation and each heartbeat to the caller in order. It ends when the
manager ends the response, or when `reconnectIdleSeconds` (45 seconds) pass
without a byte. It then returns the last complete event identifier, which is
the supplied cursor when no event arrived. `streamEventsWithin` takes a
shorter idle bound in milliseconds. `closeClient` ends an open stream at once
with `ClientClosed` and closes its connection. The client never reconnects by
itself. The caller reconnects with the returned identifier or takes a new
overview after a 410 refusal.

The `events` section of `test/manager_client_vectors.json` holds the vectors
of these functions. An `sse` vector describes a byte stream as `text`, `hex`
and `repeat` segments, lists split points, and states the expected outcomes
and the last event identifier at close, or a refusal. The check feeds each
stream whole, at each listed split, at every single split point of a stream
of at most 2048 bytes, and one byte at a time. An `sse` vector can also
state whether its dispatched events decode as invalidations or as route
records. The `invalidations`, `batches` and `routeRecords` vectors hold JSON
text that decodes and encodes back to the same value, or that refuses with
`InvalidResponse`. The `cursors`, `etags` and `problems` vectors cover the
cursor syntax, entity-tag equality and the mapping of problem bodies.

The `resources` section of the same file holds the vectors of the public
resource types. Each case gives the resource as JSON text in `json`, and
either the expected decoded projection as JSON text in `projection` or the
refusal in `refusal`. The JSON text keeps numbers beyond 2^53 exact for
every consumer. The cases cover `false`, `null`, numbers and decimal text
beyond 2^53, Unicode, missing fields and extra fields. A field that the
contract states as nullable must be present, and an absent field refuses.

The `drafts`, `preparations` and `receipts` sections hold the types that the
`Agentic.Manager.Client` facade decodes with `decodeObservation`. A case
names its type in `type`. The `drafts` types are `DraftView`, `Readiness`,
`InputDeclaration`, `SuppliedInput` and `InputError`. The `preparations`
types are `Preparation`, `Review`, `ReviewInput`, `ReviewLineage` and
`ReviewEdit`. The `receipts` section holds `CommandReceipt` cases for each
command state and for each effect kind. The projection of these types is the
encoding of the decoded value by the shared protocol codec, and the refusal
is `InvalidResponse`. The `vectors` mode of `manager-client-check` runs
these sections, the `events` section and the `refresh` section.

The `refresh` section holds the vectors of the refresh coordinator. A
`sequences` vector scripts invalidations, completions with their
generations, resnapshots and endpoint switches, and states the exact actions
of each step. The check also confirms in every step that an install has the
current generation, that a completion of another generation never installs,
that an invalidation of a resource in flight starts nothing, that a
completion starts at most one fetch, and that an advance leaves every
resource idle. A `backoff` vector lists failures and delivered events and
the delay of each failure. A `jitter` vector states the wait for a delay and
a fraction. A `reconciliation` vector gives an uncertain command, its
precondition and receipt location, and the result of the read, and states
the expected read and report. The check confirms that a command that stays
uncertain comes back unchanged.

The `decisions`, `answers`, `controls`, `requests` and `runs` sections hold
the cases that `tui-model-test` runs with the parsers of
`Agentic.Tui.Service`. A case of the `decisions`, `requests` and `runs`
sections names its origin in `from`. The origin `item` is the
representation of a detail resource, which is also the item of its
collection. The origin `overview` is a member of the `/snapshot` overview,
`{"kind": KIND, KIND: VALUE}`, where KIND is `request`, `preparation`,
`run` or `decision`. Its projection is `{"kind": KIND, KIND: PROJECTION}`.
The overview cases of the `requests` section include preparation members.
The projections of these sections name the decoded fields. A UInt64 or
UInt32 value is canonical decimal text, and an absent optional value is
`null`.

- A request or a preparation projects to its encoding by the shared
  protocol codec.
- A decision projects to `id`, `revision`, `runId`, `profileId`,
  `generation`, `occurrenceId`, `state`, `position`, `observedSequence` and
  `content`. The content of a question is `kind` `question`, `code` and
  `prompt`. The content of a recovery is `kind` `recovery`, `gap`,
  `message` and `choices`, each choice with `choice` and `target`.
- A control view projects to `runId`, `revision`, `supervision`,
  `cancelAllowed`, `decisionHeadId` and `offers`. Each offer projects to
  `operation`, `occurrenceId`, `attemptId`, `generation`, `timings`,
  `choices` and `targets`.
- A run projects to `id`, `revision`, `profileId` and `content`. The
  content of a known run is `kind` `known`, `workflowId`, `requestId`,
  `parentRunId`, `lineage`, `manifestVersion`, `runtime`, `supervision`,
  `integrity`, `verification` and `limitations`. `manifestVersion` is null
  for a legacy manifest, and `runtime` is null or holds `status`,
  `lastSequence` and `protocolVersion`. The content of an entry with an
  unreadable manifest is `kind` `unreadable` and `category`.

The TUI check also requires that each decision and control view that it
accepts keeps its input JSON value unchanged. A refusal in these sections is
`InvalidResponse`. An `answers` case gives a decision in `decision` and the
editor text in `input`. Its projection is the answer body that the TUI sends
for the typed value of that text, and the refusal `InvalidAnswer` states that
the TUI refuses the answer before it prepares a command.

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

`RUNNER` denotes the configured registry executable. The following forms define
the command boundary. Offline administration and a configured same-user local
channel implement credential listing, issuance, rotation and revocation, the
read-only `status`, `check-store` and `check-quarantine` operations, and
`release-quarantine`.
`check-quarantine` answers `clean` with cleanup evidence when the reservation
never launched a run or when the run log of its run holds the terminal record
of the runtime, `cleanup-required` when that run has no terminal record, and
`unverifiable` when the run store cannot be read or the identity names a
restoration claim. The evidence digest is the lowercase SHA-256 digest of the
canonical JSON facts, which include the answering process generation, and the
evidence identity is `cleanup_` followed by its first 32 hexadecimal digits.
Clean evidence expires 600 seconds after the check. An unknown identity and a
reservation that is not quarantined receive `state-conflict`.
[`manager/WORKERS.md`](../../manager/WORKERS.md#manager-loss-and-restart)
states the facts of each rule. `release-quarantine` computes the evidence
again and refuses with `cleanup-unverified` when it is not clean or its
identity or digest differs from the supplied values. An unknown identity and a
reservation that is not quarantined receive `state-conflict`. A release frees
the execution slot and resource keys of the reservation, records the release
and its receipt in the manager log, and returns `quarantineId` with `state`
`released`. The run of the reservation keeps `lost` supervision. A request
that waits for capacity on a serving manager is then prepared without another
client command. The operations `reload-profiles`, `drain`, `shutdown`,
`backup`, and `restore` receive `state-conflict`.
Existing `RUNNER --tui` and native frontend commands remain unchanged.

```text
RUNNER --manager serve --config ABSOLUTE_FILE [--legacy-history ROOT=PROFILE]...
RUNNER --manager admin --config ABSOLUTE_FILE
RUNNER --tui --service CLIENT_PROFILE
RUNNER --tui --local
```

Without `administrationRoot`, administration acquires the original Store through
local configuration and refuses an already-owned Store. With that private
directory configured, it reaches the existing owner's Unix socket without a
second writer or an offline fallback. Trusted embedding hosts this channel with
`withLocalAdministration`. Its implementation and authority limits are described
in [the command contract](../../manager/COMMANDS.md#local-credential-administration).

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

The Haskell client trusts only the certificates in the `caFile` of its
profile. It does not read a platform certificate store. It accepts only TLS
1.3. It runs the default certificate validation of crypton-x509-validation
1.9.1, including hostname validation against the endpoint host, and then an
extra Name Constraints check. The extra check only adds refusals. It examines
each certificate that the server presents and each certificate in the
`caFile`. The handshake fails, before any HTTP request, when a
`nameConstraints` extension of one of these certificates meets one of these
conditions:

- The extension cannot be decoded.
- A subtree is not a `dNSName`, for example an `iPAddress`, `rfc822Name`,
  `uniformResourceIdentifier` or `directoryName` subtree, or a subtree has a
  minimum or maximum distance. The validator does not evaluate these forms
  correctly, so the client refuses them even when the chain is otherwise valid.
- An excluded `dNSName` subtree contains a `dNSName` of the leaf
  `subjectAltName` or the endpoint host name.
- The certificate has permitted subtrees, and a `dNSName` of the leaf
  `subjectAltName`, or the endpoint host name, is outside all of them.

Before it compares two names, the extra check converts ASCII letters to lower
case and removes one trailing dot. A subtree that starts with a dot contains
only names below it. Each certificate is checked on its own, so a subordinate
CA cannot widen the subtrees of its issuer. A host that is a dotted-quad IPv4
literal is not compared with `dNSName` subtrees. The client also refuses a
chain whose leaf `subjectAltName` cannot be decoded when any of these
certificates has Name Constraints.

The default validation itself refuses some forms that other validators accept.
A permitted `dNSName` subtree must equal the leaf name, or equal the part of
the leaf name after a dot, in the same letter case and with the same trailing
dot. A permitted subtree that starts with a dot therefore matches no name. A
CA without Name Constraints below a CA that has them is refused.

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

The client check runs the client vectors. It checks the pure decoding of the
public client and opens no connection:

```sh
direnv exec . bash -c '"$(bash test/cabal.sh list-bin manager-client-check)" vectors test/manager_client_vectors.json'
```

`manager/test/client_native.py` runs the connection modes of the check
against a local TLS fixture. Its stream cases check the idle end with the
last complete event identifier, the end of an open stream at `closeClient`,
and a 410 refusal. Its overview cases check a two-page overview and the
refusal of pages that differ in their cursor. The `real` mode, which
`manager/test/service_http.py` runs when `CLIENT_CHECK` names the check, loads
the overview of the running manager and streams from its cursor. It creates
a request with `prepareCommand` and `sendCommand`, requires that a new
overview holds that request with the kind `request` and the resource
`/v1/requests/{id}`, and it requires the
`request.changed` invalidation of that request on the stream within 10
seconds and in polling from the same cursor. It then withdraws the request.
