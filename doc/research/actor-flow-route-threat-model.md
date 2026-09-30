# Actor flow route resource: threat model and contract

This record begins increment 2 of the actor flow (`acat-en4g`, service
subscription). It was written on 2026-09-30 against commit `452272bf`. The
actor-flow design record (revision 4) requires, in its section 4, a written
threat model before any actor or restricted body leaves the owning account. Its
section 6.2 requires a paged and streamed `/v1` route resource. This record
decides the shape of that resource, its cursor, its served representation, its
authorization, its reader and its bounds. It then lists the assets, the
principals and the attack paths, with the mitigation or the accepted residual
risk of each.

This record is a design record. It changes no code, no schema and no current
documentation. The implementation that follows it updates `doc/api/openapi.yaml`,
`manager/README.md` and `runtime/BROKER.md` in the same change that adds the
behavior. No route is served before the operator reviews this record
(section 11).

## 1. Governing decisions

These decisions bind this record and are not reopened here.

- The amendment of 2026-09-26 (`actor-flow-amendment.md`) makes the broker
  append, carry and serve. Serving is a restriction of a log, live or replayed,
  to an authorized reader. The broker never originates, alters, reorders,
  retries, re-routes or re-delivers a record, and it enforces nothing.
- The operator decision of 2026-09-26 maps route classes onto the existing
  scopes. A principal with observe scope on a profile reads the public class of
  that profile. A principal with observe and control scope on a profile also
  reads the actor class of that profile. The restricted class (`engine-result`
  and `failure`) stays with the owning account, and no service principal reads
  it. Store schema version 12 does not change.
- The `/v1` contract is frozen with additive extensions only.
- The operator decision of 2026-09-29 on bounded Store admission applies. Each
  Store action waits within its own five-second allowance, and the lock order
  is file slot, configuration, database.

## 2. Resource shape

The resource is two new paths with new schemas. No existing path, schema,
parameter or response changes.

| Path | Log | Scope to enter |
| --- | --- | --- |
| `GET /v1/routes` | The manager log of the current Store stream identity, `flow/<stream>.ndjson` in the manager's private root | observe on at least one configured profile, as `withAuthorizedCatalogues` requires for `/v1/events` |
| `GET /v1/runs/{id}/routes` | The run log `flow.ndjson` in the runtime store of the managed run `{id}` | observe on the profile of the run, as `resolveRun` requires for the other run resources |

`{id}` is the public run identifier. The manager resolves it through
`resolveRun`, which reads `runs.profile_id`, `runs.root_identity` and
`runs.native_run_id`. The manager opens the run log in the runtime store of
that native run under the run root, and it checks the run root against
`runs.root_identity` in the manner of `withRunRoot` in
`manager/src/Agentic/Manager/Artifacts.hs`.

**Parameters.** Each route accepts these inputs, and no other query parameter:

- `after`: a cursor, at most 149 bytes, in the character set that
  `eventParameter` in `manager/src/Agentic/Manager/Application.hs` accepts.
- The `Last-Event-ID` header: a cursor with the same bounds.
- `route`: a route predicate in the grammar of `parseFlowRoute` in
  `runtime/src/Agentic/Runtime/Flow.hs`. Its percent-decoded value is UTF-8 of
  at most 1024 bytes.

A request that supplies both `after` and `Last-Event-ID` is refused with
`malformed-request` (400), even when the two values are equal, as `eventParameter`
refuses it for `/v1/events`. A request that supplies neither reads from the
retained floor of the log. Each query key occurs at most once, and the raw query
string must equal the rendering of its parameters, as `workflowParameters`
requires. A `GET` with a request body is refused, as for every `/v1` read.

The predicate is evaluated on the served projection of each record
(section 4), never on the stored record. The route field `nativeRun` is refused
with `malformed-request` (400), because the projection holds no native identifier. The
fields `from` and `to` compare against the projected actor names, and the field
`managerRun` compares against the public run identifier. A record that the
predicate does not select is a filtered gap, under the same rules as a hidden
record (section 6).

**Representations.** The `Accept` header selects one of two representations.
Any other value is refused with `unsupported-operation` (409), as for `/v1/events`.

- `application/json` returns one bounded batch:

  ```json
  {
    "version": 1,
    "cursor": "route_<64 hex>.<n>",
    "oldestCursor": "route_<64 hex>.<floor>",
    "records": [ { "id": "route_<64 hex>.<p+1>", "position": 0, "schema": "start", "class": "actor", "...": "..." } ],
    "hasMore": false
  }
  ```

  `cursor` names the next unread position after every record that the batch
  scanned, hidden records included. `hasMore` is true when complete records
  remain after `cursor` at the time of the read. The encoded batch is at most
  1 MiB, the existing `pageBytes` limit.

- `text/event-stream` returns SSE blocks under the rules of `/v1/events`. Each
  served record is one block: `id:` holds the record's cursor, `event:` holds
  `route.<schema>`, and `data:` holds the record's projection. Each block is at
  most 16 KiB, the existing `sseBlockBytes` limit. A heartbeat follows every
  15 seconds without a block. After a batch that advanced over hidden or
  filtered records only, the next heartbeat is an `id:` line with the advanced
  cursor and no `data:` line. Under the SSE processing model, that block sets
  the last event identifier of the client and dispatches no event, so a
  reconnection does not scan the same gap again.

A served record whose projection does not fit its bound is served with
`"body": {"omitted": "size", "bytes": N}` in place of its body. A JSON batch
always serves at least one record when one remains, so a record whose
projection fits 1 MiB is always retrievable through `after` with the cursor
that precedes it. A body that the log holds as a claim check is always served as
omitted, with the size and the SHA-256 that the record itself names. The
service reader never opens a claim-check file (section 7).

**No capabilities change.** The `Capabilities` object is closed
(`additionalProperties: false`). `checkVersions` in
`manager/src/Agentic/Manager/Client.hs` requires exactly 11 version fields, and
`requireCapabilities` requires exactly 8 top-level fields. This resource adds
no key to `Capabilities`, `Versions`, `Limits` or any other existing schema, and
it adds no capabilities version entry. A client finds the resource by its
presence. An earlier manager answers either path with `unavailable-resource` (404).
The batch carries its own `version`, which is 1, as the `/v1/events` batch does.

The API document gains the two paths, the schemas `RouteBatch` and
`RouteRecord`, the per-schema body forms of section 4, the `410` responses of
section 3, and a row for each path in the scope matrix. These additions land
with the implementation.

## 3. The cursor

A cursor has the form `<alias>.<position>`. The position is a decimal count of
records, and `after=<alias>.<n>` selects the records at positions `n` and later.
Position 0 is the first record of the log. A served record at position `p` has
the identifier `<alias>.<p+1>`.

**The alias.** The alias is computed in the manner of `publicStreamId` in
`manager/src/Agentic/Manager/Events.hs`, and it reuses it:

```haskell
routeAlias :: CursorBinding -> Text -> (DeviceID, FileID) -> Text
routeAlias binding logName identity =
  "route_" <> sha256Hex (encoded (1 :: Int, publicStreamId binding, logName, identity))
```

- `captureBinding` supplies the `CursorBinding` in the same read transaction
  that authorizes the batch. The binding holds the Store stream identity, the
  authority epoch and the authorization revision, which is the value of
  `authorizedCursorRevision`.
- `logName` is `manager` for `/v1/routes` and `run:<public run id>` for
  `/v1/runs/{id}/routes`.
- `identity` is the device and inode of the open log file. It fences a log file
  that was replaced under the same name.

The alias is an equality fingerprint. It is never a credential, and it
reconstructs no owner, binding, worker or file. The fields that it hashes are
never served. An ordinary manager restart keeps the stream identity, the
authority epoch, the authorization revision and the file, so an alias stays
valid across an ordinary restart.

**The authorization revision.** `authorizedCursorRevision` fingerprints the
facts of `catalogueFacts` in `manager/src/Agentic/Manager/Authorization.hs`:
the authority epoch, the credential and its client, the client's
`authorization_revision`, the expiry, the rotation cutoff, every scope row of
the credential and the configured profiles that the credential may observe.
These actions advance it:

| Action | Effect on cursors |
| --- | --- |
| `revoke-credential` | The revoked credential fails authentication with `unauthenticated`. `reviseClient` gives the client a new `authorization_revision`, so every other credential of that client gets a new revision. |
| `rotate-credential` | `reviseClient` gives the client a new revision, and the predecessor gets a rotation cutoff. Both credentials get a new revision. |
| `reload-profiles` that adds or removes a configured profile on which the credential holds observe | The list of observable profiles changes. A reload that changes only the content revision of a profile with the same identifier does not change the revision, because `authorizedCursorRevision` excludes execution revisions. |
| Offline restore | The Store gets a new authority epoch and a new stream identity, and every credential is revoked (`manager/src/Agentic/Manager/Store.hs`, the restore transaction). |
| Expiry of the credential | The credential fails authentication. |

`issue-credential` creates a new client and changes the revision of no existing
credential.

**410 rules.** Each rule is checked before any record is served.

| Condition | Refusal |
| --- | --- |
| The alias does not equal the alias of the current binding, log and file. This covers a wrong alias, a cursor of another log, a cursor taken before an authorization revision change and a cursor taken before a restore. | `410 view-expired` |
| The position is ahead of the complete records of the log. | `410 cursor-expired` |
| The position is below the retained floor of the log. | `410 cursor-expired` |
| The request names a cursor, and retention has removed the runtime store of the run while the run resource still exists. | `410 cursor-expired` |

These are the two refusals that `Events.refuse` maps for `/v1/events`: a wrong
stream becomes `view-expired`, and a lost or future position becomes
`cursor-expired`. A run log that the runner has not created yet, in a runtime
store that exists, reads as an empty log. The retained floor is position 0 for
both logs today. The
manager log has no pruning until Phase G, and a run log is never pruned while
its runtime store exists. When Phase G adds pruning, the floor becomes the
first retained position, and `oldestCursor` reports it.

An open SSE stream compares the authorization revision before each write. On a
change, it ends the stream before the write. The client then reconnects with
its last cursor and receives `410 view-expired`, and it starts again without a
cursor to read from the floor under its new authorization.

## 4. Served representation and projection

A served route record is a typed projection of the decoded record. It is never
the appended line bytes. The projection has these fields:

| Field | Value |
| --- | --- |
| `id` | the cursor after the record |
| `position` | the record's position in its log |
| `schema` | `schemaName` of the schema |
| `class` | `public` or `actor`, from `schemaRouteClass` |
| `from`, `to` | the projected actor or address name (below) |
| `about` | the public identifiers: `request`, `run`, `command`, `occurrence`, `epoch` and `attempt`, each only when present |
| `replyTo` | the position of the ask, only on a reply |
| `at` | the append time of the record |
| `body` | the projected body of the schema (below) |

**Identifiers.** `aboutNativeRun` is never served. In a run log, `run` is the
public run identifier of the path. In the manager log, `run` is
`aboutManagerRun`, which is the public run identifier. `request` and `command`
are the public request and command identifiers. In service mode the native
control identifier equals the public command identifier, which admission
checks (`manager/src/Agentic/Manager/Admission.hs`, `controlId control ==
ControlId command`), so the `command` of a run-log `control` or `answer` is
public. `occurrence`, `epoch` and `attempt` are the numbers that run snapshots
already serve.

**Actors and addresses.**

| Stored actor | Served name |
| --- | --- |
| `Manager` | `manager` |
| `Workflow` with a native run | `workflow:<public run id>` |
| `Model` | `model:<target>` |
| `ToolActor` | `tool:<name>` |
| `Adapter` | `adapter:<name>` |
| `Principal (Credential client credential)` | `credential:<client>:<credential>` |
| `Principal (LocalAccount uid owner)` | `local`, without the user identifier and the declared owner |
| address `Approvers profile` | `approvers:<profile>` |
| address `Public` | `public` |

A workflow actor whose native run does not resolve to a public run identifier
makes its record hidden (section 5). Client and credential identifiers carry no
authority, because authentication needs the bearer. They name the principal
that sent a command or approved a review, and only actor-class readers of the
same profile see them. Section 11 lists this choice as an open decision.

**Run-log bodies.**

| Schema | Class | Served body |
| --- | --- | --- |
| `start` | actor | `run` (public), `parent` (the public identifier of the parent run, omitted when the parent does not resolve or the reader may not observe it), `programSha256`, `policyDigest`, `personAnswering`, `target`, `lineage`, and `inputs` as name, bytes and SHA-256. The native run and native parent identifiers are removed. |
| `control` | actor | the control kind, the public command identifier and the typed arguments of the kind: the answer value, the steering timing and text, the redirect target, or the recovery choice and target. These are the fields that the run snapshot and the decision resource already publish (`manager/src/Agentic/Manager/Observation.hs`). The protocol number and any native identifier of the frame are removed. |
| `question` | actor | the request as `questionJson` encodes it |
| `answer` | actor | the typed value as `answerJson` encodes it |
| `engine-start` | actor | the `EngineRequest`: target, model axis, mode axis, draw, intent, answer kind, prompt and the completed-turn flag. It holds no path and no native identifier. |
| `turn` | actor | the turn text |
| `steer` | actor | the steering timing and the text |
| `done` | actor | `null` |
| `permission` | actor | the question, the tool and the answer of the adapter's report |
| `event` | public | the event sequence number only. The content of the event is served by the existing run snapshot resource under its own projection. |
| `engine-result` | restricted | never served |
| `failure` | restricted | never served |

**Manager-log bodies.**

| Schema | Class | Served body |
| --- | --- | --- |
| `command` (a `/v1` command) | actor | the operation, the profile, the method, the resource, the media type, the precondition, the strictly decoded `/v1` request body and the capture reference as identifier, SHA-256 and size. The idempotency key is absent from the record. |
| `command` (an administration request) | actor | never served |
| `receipt` of a `/v1` command | actor | the frozen `/v1` receipt |
| `receipt` of an administration request | actor | never served |
| `review` | actor | the preparation identifier, the public review text, `reviewSha256`, `bindingSha256`, the expiry and the five selectors. The private binding bytes are not served. |
| `relay` | actor | the relay kind, the public run identifier and the public command identifier. The native run identifier and the frame are not served. |
| `notice` `command-changed` | actor | the command state and the public refusal code |
| `notice` `review-ended` | actor | the preparation identifier and the reason |
| `notice` `request-ended` | actor | the public request identifier and the cause |
| `notice` `lifetime`, `shutdown` or `gap` | actor | never served |
| `failure` | restricted | never served |

**Bodies that lose meaning.** Two bodies cannot be projected without a loss of
meaning, and this record decides that they are not served.

- The review binding bytes name the frontend invocation path, the run-root
  identity and the target arguments. The projection keeps `bindingSha256` and
  the selectors. A service reader can therefore check that an approval names
  the reviewed digest and the published selectors. It cannot check that
  `bindingSha256` is the digest of the binding bytes. That check stays with the
  owning account, through the local reader `agentic-run flow`.
- The relay frame is a native start, discard or control frame, and it names the
  native run. The projection keeps the kind and the public identifiers. The
  meaning of a control relay is also in its `command` record and its run-log
  `control` record, which are served. The meaning of a start relay is the
  approval that precedes it, which is served.

Section 11 puts the alternative, exact bytes for these two schemas, to the
operator as an open decision.

**No further redaction.** Bodies are not redacted beyond this projection. The
projection removes structured native identifiers, paths, root identities and
invocation fields. It does not scan free text. A question, an answer, a turn, a
steering text, a permission question, a `/v1` request body or a review text can
carry a secret, a path or a personal value that an input, a prompt, a model, a
tool or an adapter supplied. An actor-class reader receives that content as
the actor wrote it. This is the residual risk of actor-class serving, and the
operator accepts or refuses it through the decision of section 11.

## 5. Authorization by route class

Each record's class comes from `schemaRouteClass`. The manager decides each
record's visibility with the grants that `captureBinding` returned in the same
read transaction as the batch.

| Class | Visible to |
| --- | --- |
| public | a principal with observe on the record's profile |
| actor | a principal with observe and control on the record's profile |
| restricted | no service principal |

For a command record and its receipt and command notices, the principal must
also hold the scopes that the command's operation requires, as
`visibleResources` requires for `/v1/commands/{id}` invalidations. An export
command therefore needs export scope as well.

**The profile of a record.** A run-log record has the profile of its run,
`runs.profile_id`. A manager-log record has the profile that read-only SQL
lookups find through the public identifiers in its `About`, in the manner of
`visibleResources`:

| Manager-log record | Lookup |
| --- | --- |
| `command`, `receipt`, `notice` `command-changed` | `commands.profile_id` and `commands.operation` by the command identifier |
| `review`, `notice` `review-ended`, `notice` `request-ended` | `requests.profile_id` by the request identifier |
| `relay` of kind start or control | `runs.profile_id` by the public run identifier |
| `relay` of kind discard | `requests.profile_id` by the request identifier |

The lookups for one batch run in one read transaction, with at most one query
for each identifier kind, as `visibleResources` batches them. A lookup never
trusts a body field. The `profile` field of a command body is not used for
authorization.

**Records that no service principal sees.**

- Administration commands and their receipts. They come from the local account
  and name clients, credentials, scopes and profiles of every principal.
- Lifetime notices, which list every credential of the Store. Shutdown notices,
  which name the process generation. Gap notices, which name missing records of
  every profile.
- Every restricted record.
- Every record whose profile cannot be resolved. This includes the `command`
  record of a transaction that rolled back, because its ledger row does not
  exist, and a record whose public identifier no longer resolves.
- Every record of a profile that is not configured at the time of the read.

**The manager log under public-only serving.** Every manager-log schema is in
the actor class or the restricted class. If the operator accepts public-class
serving and refuses actor-class serving, `GET /v1/routes` serves no record. It
returns only filtered gaps, and its cursor advances over them. The run-log
route then serves only `event` records.

## 6. Hidden records and filtered gaps

A record that the reader may not see is omitted. The response carries no body,
no digest, no schema and no identifier of it. The cursor advances over it as a
filtered gap, as `readBatch` advances over filtered invalidations of
`/v1/events`. A record that the route predicate does not select is omitted in
the same way. A reader cannot tell a hidden record from an unselected one.

Positions are dense. A reader therefore learns the number of omitted records
between two served records, and in a live stream it learns when they were
appended. In the manager log this reveals the rate of activity of other
profiles and of administration. This inference is an accepted residual risk.
It is the same inference that the sequence numbers of `/v1/events` already
permit.

## 7. Bounded positioned reading

`readFlowLogAt` reads the whole log prefix, up to `maxFlowLogBytes` (512 MiB),
before it checks any line bound. This is low finding 11 of `acat-1dfc`. The
resource does not reuse `readFlowLogAt` or `readFlowLines` unchanged. The
runtime reader owner, `Agentic.Runtime.Flow`, gains a positioned reader.

**Positions and byte offsets.** A position counts records. A strict line never
contains a raw newline byte, because the encoder escapes every control
character. Each newline byte in the complete prefix of a log therefore ends
exactly one record. The manager keeps, in memory, a sparse offset index for
each log that it serves: one checkpoint of position and byte offset at the
first record boundary after each 64 KiB of log bytes. The index is keyed by the
route alias, so a file replacement or a restore makes it unreachable. It is
never written to SQLite or to any file.

- To serve from position `n`, the reader takes the last checkpoint at or below
  `n`, reads forward from its offset, and counts newline bytes until it reaches
  position `n`. The forward count reads less than 64 KiB plus one window.
- When `n` lies beyond the indexed prefix, the reader extends the index by
  reading windows forward from the last checkpoint. One request extends it by
  at most 8 MiB. If the reader reaches the end of the complete prefix before
  position `n`, the request is refused with `410 cursor-expired`. If the budget
  ends first, a JSON request returns an empty batch whose `cursor` is the
  requested cursor and whose `hasMore` is true, and an SSE stream continues the
  extension in its next iteration and sends heartbeats meanwhile.
- The index holds at most 8192 checkpoints for a 512 MiB log. The manager keeps
  the indexes of at most 64 logs and evicts the least recently used one.
  Eviction costs a later rebuild and no correctness.
- A manager restart discards every index. The first read after a restart
  rebuilds the index of its log under the same budget.

**One read.** Each read is one window of at most `maxFrameBytes + 1` bytes
(1 MiB and one byte) from a checkpoint or record boundary:

1. The reader opens the log through the private-file facility, measures the
   complete prefix at open as `readPrivatePrefixAt` does, and reads at most one
   window of it.
2. It splits the window at newline bytes. A line longer than `maxFrameBytes` is
   an integrity failure, reported as `storage-unavailable` with a private fault
   record. This check happens before any decoding.
3. A final line without its newline is not decoded. At the end of the complete
   prefix it is the torn tail of a live or crashed writer and is not served. A
   window that holds no newline and is full is an integrity failure.
4. It decodes each complete line with `decodeFlowLine`, which checks the frame
   bound again before it allocates.
5. It never opens a claim-check file. A claim-check body is served as omitted.
6. It stops after 64 records or at the end of the window, whichever comes
   first.

**Store slots.** The reader takes the Store file slot for the window read
only, under the ordinary bounded wait, and it releases the slot before any
projection, lookup or write. It never takes the manager log's writer lock,
which is a leaf lock of the writer. A read never treats a partial line of a
live writer as a record, because only a line that ends with its newline byte
is complete.

## 8. Streaming, revalidation, quotas and deadlines

Each batch of either representation follows the same four steps, and each step
releases what it takes before the next step starts.

1. **Bind.** One read transaction authenticates the proof with
   `currentClient`, takes the catalogue authorization, runs `captureBinding`,
   and computes the alias. For a run route it also resolves the run.
2. **Read.** The positioned reader reads one window under the file slot.
3. **Project.** One read transaction runs the profile lookups of section 5,
   resolves public identifiers, and recomputes the authorization revision. A
   revision that differs from step 1 refuses the batch with `410 view-expired`.
   The manager then builds the projection and applies the route predicate with
   `flowRouteMatches` to the projected record.
4. **Write.** Before each write, a separate bounded Store read recomputes the
   authorization revision and compares it with step 1. A write is one SSE block
   or one 16 KiB chunk of a JSON response, as `respondBytes` in
   `manager/src/Agentic/Manager/Transport.hs` chunks it. A difference ends the
   response before the write. Each write has the existing five-second deadline,
   and a write that misses it ends the response with the private fault
   `ResponseWriteTimeout`.

**Ownership.** No configuration guard, SQL transaction, Store reader charge or
file slot is held across a network write. This is the ownership rule of the
Phase B response work. The route resource does not use the authorization
watch that `Events.withStream` holds for the whole of a `/v1/events` stream, so
a slow route reader holds no Store capacity while its socket drains. Waiting
for new records holds nothing either.

**Live waiting.** An SSE stream that has reached the end of its log waits for a
wake-up and then runs the four steps again.

- For `/v1/routes`, the manager-log writer increments an in-memory append
  counter after each append, and a waiter wakes on a change of that counter.
- For `/v1/runs/{id}/routes`, a waiter wakes when the manager ingests an
  observation of that run, or after one second, whichever comes first.
- Every waiter also wakes at each heartbeat deadline of 15 seconds.

A wake-up is not authority. The next batch binds and revalidates again. An
authorization change during a wait therefore ends the stream before its next
write, within one second for a run route and at the next append or heartbeat
for the manager route.

**Quotas.** A route stream counts against the same per-client limit of two SSE
readers as `/v1/events` (`sseReadersPerClient`), through the same
`StreamReaders` value of the application. A shared quota keeps the published
limit true and needs no new `Limits` key. The existing global connection limit
bounds the number of streams in total. A JSON batch is an ordinary protected
read and needs no stream slot. Each Store read of a batch charges one Store
reader for its own duration only.

## 9. Storage and reuse

The resource adds no SQLite write, no Store table, no column, no migration and
no file. Store schema version 12 does not change. The resource writes nothing
to either log. Its only state is the in-memory offset index of section 7, the
in-memory append counter of section 8 and the existing `StreamReaders` counts.

It reuses these functions unchanged:

- `schemaRouteClass`, `parseFlowRoute`, `flowRouteMatches` and `decodeFlowLine`
  in `runtime/src/Agentic/Runtime/Flow.hs`.
- `captureBinding` and `publicStreamId` in
  `manager/src/Agentic/Manager/Events.hs`, together with the lookup pattern of
  `visibleResources` and the refusal mapping of `refuse`.
- `resolveRun` and `authorizeObservation` in
  `manager/src/Agentic/Manager/State.hs`, and the run-root check of
  `withRunRoot`.
- The parameter rules of `eventParameter` and the block bound of `eventBlock`
  in `manager/src/Agentic/Manager/Application.hs`.

It does not reuse `readFlowLogAt`, `readFlowLines` or `readFlowContentAt`.

## 10. Threats

**Assets.**

- The bodies of actor records: prompts, questions, answers, turn texts,
  steering texts, permission reports, `/v1` request bodies and review texts.
- The bodies of restricted records: engine results with their narration, and
  failure messages, which can carry paths and values.
- Private facts: native run identifiers, the frontend invocation path, the
  run-root identity, target arguments, native frames, the Store stream
  identity and process generations.
- The identity and scope list of every principal of the Store.
- The availability of the manager: Store gate time, file slot time, reader
  capacity, memory and connections.

**Principals.**

- The owning account. It reads every log locally through `agentic-run flow`
  and is outside this resource.
- A service principal with observe on a profile.
- A service principal with observe and control on a profile.
- A service principal of another profile, or of another client.
- An unauthenticated network peer.

**Attack paths.**

| Attack | Mitigation | Residual risk |
| --- | --- | --- |
| Cross-profile leakage: a reader of profile A reads records of profile B from the manager log. | Visibility is decided per record from read-only SQL lookups of public identifiers and the reader's grants from the same transaction. Unresolvable records are hidden. Records of every profile, such as lifetime notices, are never served. | The inference from filtered gaps that a later row of this table states. |
| Native identifier and path disclosure. | The served record is a typed projection of the decoded record. Native run identifiers, binding bytes, relay frames, local user identifiers and declared owners are removed. The route field `nativeRun` is refused. Claim-check files are never opened. | Free text in actor bodies can carry a path or a native value that an actor wrote (section 4). |
| Secret disclosure in actor bodies. | Actor records are served only to principals with observe and control on the profile, who can already act on its runs. Restricted records are never served. A credential for a model's use should hold observe only, which limits it to the public class. | An actor-class reader receives any secret that an input, prompt, model, tool or adapter put into an actor body. |
| Scope downgrade during a stream: a revocation, rotation or profile removal while a stream is open. | The authorization revision is recomputed before each write and in each batch. A change ends the stream before the next write, and the next request receives `410 view-expired`. | A write that started before the change completes. The exposure is at most one SSE block of 16 KiB or one JSON chunk of 16 KiB, within the five-second write deadline. |
| Cursor forgery. | The alias hashes the private stream identity, the authority epoch, the reader's authorization revision, the log and the file identity. A forged alias fails with `410 view-expired`. A forged position under a genuine alias only selects another starting point in a log that the reader may already read, and a position ahead of the log fails with `410 cursor-expired`. | A reader can scan its authorized log from any position. This is intended. |
| Replay after restore. | A restore rotates the stream identity and the authority epoch and revokes every credential. Every earlier alias fails with `410 view-expired`, and `/v1/routes` then reads the log of the new stream. | None identified. |
| Resource exhaustion by slow readers. | No lock, transaction, reader charge or file slot is held across a write. Each write has a five-second deadline. Each client has at most two SSE readers across `/v1/events` and routes, and the global connection limit applies. | A slow reader keeps its connection until its deadline expires. |
| Resource exhaustion by large-log reads. | Each read is one window of at most 1 MiB and one byte under a file slot. Index extension is at most 8 MiB for each request. Indexes are bounded in size and number. Claim-check files are never read. Each batch holds at most 64 records and at most 1 MiB of encoded output. | An authorized reader can make the manager index one log once in each manager lifetime, up to the log's size limit. |
| Inference from filtered gaps. | Hidden records carry no body, digest, schema or identifier. | Dense positions reveal the number and the timing of hidden records. This matches the inference that `/v1/events` sequence numbers permit. |
| Inference from low-entropy digests. | A reader who may not read a record sees none of its digests. | An actor-class reader can confirm a guess of a low-entropy input or review through a served SHA-256. That reader may already read the same values through the request and preparation resources. |
| Unauthenticated access. | Both paths sit behind `Transport.authenticated`, and every batch rechecks the proof with `currentClient`. | None identified. |

## 11. Operator review and open decisions

Every route surface waits for the operator's review of this record, the public
class included. No path of section 2 is served before that review. The
operator may accept public-class serving separately from actor-class serving.
Under public-class serving alone, the run route serves `event` records, and
the manager route serves only filtered gaps.

The open decisions are these:

1. **Public-class serving.** Accept the run route for `event` records, served as
   sequence numbers under the cursor and bounds of this record. Recommended:
   accept.
2. **Actor-class serving.** Accept the actor class for principals with observe
   and control on the profile, with the projection of section 4 and the
   residual risk that an actor body carries a secret or a path that an actor
   wrote. Recommended: accept, because these principals can already act on the
   runs of the profile.
3. **Principal identifiers.** Serve `credential:<client>:<credential>` to
   actor-class readers of the same profile, or serve every principal other than
   the reader as one opaque name. Recommended: serve the identifiers, because
   they carry no authority and name who approved.
4. **Binding bytes and relay frames.** Keep both unserved as section 4 decides,
   or serve their exact bytes to actor-class readers. Exact bytes would let a
   service reader verify `bindingSha256` and the relayed frame, and would
   disclose the invocation path, the run-root identity, the target arguments
   and the native run identifier. Recommended: keep both unserved.
5. **Event content.** Serve event records as sequence numbers only, as this
   record decides, or serve a public projection of each event line in a later
   increment. Recommended: sequence numbers only in increment 2.
6. **Gap and shutdown notices.** Keep them unserved, or serve a gap notice
   projected to the missing records that the reader may see, without the count
   of the others. Recommended: keep them unserved in increment 2.
7. **Large bodies.** Serve bodies above the representation bound and
   claim-check bodies as omitted, as this record decides, or add a body
   resource in a later increment. Recommended: omitted in increment 2.
8. **Shared SSE quota.** Count route streams against the existing limit of two
   SSE readers for each client, as this record decides. Recommended: accept,
   because a separate quota needs a new `Limits` key.
