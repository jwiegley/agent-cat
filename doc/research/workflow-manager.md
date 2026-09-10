# A remote single-user workflow manager

## 1. Status and recommendation

This is a design proposal dated 2026-09-10, not a description of an implemented
network service. It concerns one user operating agent-cat through several
simultaneous clients. The manager admits work, owns per-run supervisors, and
publishes one authoritative view through HTTP resources and server-sent events
(SSE). Agent-cat remains the workflow interpreter. The TUI, Emacs, and Pi retain
their native presentation and editing conventions.

The recommended first implementation is one Haskell manager process on the
workflow host, a local transactional database for manager records, and the
existing `frontend` subprocess interface for preparation and execution. REST
carries commands and queries. SSE carries bounded change notifications, with
ordinary snapshot queries providing reconciliation. WebSockets are not required
for these interactions. Remote access uses TLS and separately revocable client
credentials, with trusted execution profiles selected on the server.

This record specifies the design and its implementation obligations. It does not
implement endpoints, change workflow semantics, migrate clients, select a new
engine, install dependencies, or authorize a deployment. Multi-user tenancy,
browser UI implementation, and adoption work in the separate Pi lane are outside
its scope. Recommendations below are proposed requirements unless explicitly
identified as existing behavior or an unresolved implementation choice.

## 2. Evidence and existing facilities

### 2.1 Source boundary

The inventory describes working-tree source, including uncommitted additions.
Neither a commit ID alone nor the name of an installed runner establishes that
these particular source changes have been deployed.

| Source | Revision and qualification |
|---|---|
| Agent-cat, `.worktrees/tui` | HEAD `828e8cacb7ce37c0ffc01b8576562f8747a59868`, with substantial existing CLI, runtime, TUI, test, and documentation changes. |
| Pi, `.worktrees/fork-agent-cat` | The same HEAD, with separate ongoing `ext-pi` changes. The source inspected on 2026-09-10 wires `FrontendSession.prepare` into interactive launch. This is source evidence, not a production-adoption claim. |
| Emacs, `/Users/johnw/src/agent-workflows` | HEAD `60c8dcd9ffc3b4f64fbdc5dfbc7e27c5a2dc7d31`, with existing native Emacs and acceptance changes. |

The 34-file inventory has SHA-256 digest
`ad98af56200b6c4378b925857f5d730012463a6102a6aba6f9b2fd1c1aa6314c`.
Its local evidence record is
`~/Products/agent-cat-workflow-manager/research.1WItAc/source-evidence.json`.
That record contains paths, file digests, revisions, and working-tree status,
not credentials. The following source table provides the reviewable locators.
Symbols, rather than inferred module names, identify the relevant behavior.

### 2.2 Current source inventory

| ID | Source and symbols | Existing behavior and evidence limit |
|---|---|---|
| S01 | [Lean denotation](../../model/Agentic/Core/Denote.lean), `denote`, `denoteAlg`, `Plan.run`, `Plan.trace`. [Semantic execution](../../model/Agentic/Core/SemanticExec.lean), `Dlg.execM`, `execM_adequacy`. | A plan denotes a dialogue. Memoizing semantic execution has an adequacy theorem under its stated oracle/world assumptions. This does not prove a future HTTP service correct. |
| S02 | [Lean plan](../../model/Agentic/Core/Plan.lean), `ExecEvent.forget`. [Haskell question representation](../../plan/src/Agentic/World.hs), `questionJson`, `eventJsonWithIntent`. | Authored semantic questions are distinguished from execution intent and physical dispatch attribution. A manager must preserve both observations at their respective levels. |
| S03 | [Workflow authoring](../../dsl/src/Agentic/Workflow.hs), `ParameterizedOf`, `InputSpec`, `Ins`, `input`, `argsInput`, `stdinInput`, `taking`. | Initial declarations have an ordered name and preferred source. `supply` receives `[Text]`. They are not arbitrary typed form fields. |
| S04 | [Descriptor](../../runtime/src/Agentic/Runtime/Descriptor.hs), `WorkflowInputDescriptor`, `WorkflowDescriptor`, `DescriptorCapabilities`. [CLI](../../cli/src/Agentic/Cli.hs), `resolveInputs`, `withRunExample`. | Catalogue rows include workflow blurb, input source, result code, capabilities, and planning facts. Unqualified descriptor output remains v2, with v3 negotiated explicitly. Input rows do not have individual descriptions, defaults, optionality, or schemas. |
| S05 | [Schema JSON](../../dsl/src/Agentic/Schema/Json.hs), `codeJson`, `jsonSchemaDocument`, `decodeValue`. | Runtime codes include built-in names and schema-indexed structured codes. The schema library can describe null, boolean, integer, number, string, arrays, and closed objects. Its own decoder remains authoritative, including representability restrictions. |
| S06 | [CLI frontend](../../cli/src/Agentic/Cli/Frontend.hs), `runFrontendCapabilities`, `runFrontendSession`, `parseSetup`, `parseDecision`, `captureInputs`. | The isolated capability query advertises session operations and bounds. A session captures one execution and accepts `start` or `discard` against its approval ID on the same worker. It is not a durable request queue. |
| S07 | [CLI frontend](../../cli/src/Agentic/Cli/Frontend.hs), `parseInput`, `captureInputs`, lineage preparation. [Catalogue](../../runtime/src/Agentic/Runtime/Catalogue.hs), `FrontendInvocation`, `readRunRecordAt`, `readFrontendInputBytesBoundedAt`. | Literal, file, and transport inputs have distinct byte contracts. Lineage verifies immutable parent facts and captured inputs. An invocation records the configured alias, executable, and ordered prefix, without granting execution authority. |
| S08 | [Machine](../../runtime/src/Agentic/Runtime/Machine.hs), machine execution and event emission. [Control](../../runtime/src/Agentic/Runtime/Control.hs), `ControlRuntime`, `ControlSnapshot`, `ControlCommand`, `AckState`. | The per-run runtime owns attempts, dispatch, steering, recovery, human answers, cancellation, and correlated acknowledgements. It already has scheduling within a run. This is distinct from admitting separate workflow executions. |
| S09 | [Protocol](../../runtime/src/Agentic/Runtime/Protocol.hs), `Envelope`, sequence validation. [Snapshot](../../runtime/src/Agentic/Runtime/Snapshot.hs), `stepRunSnapshot`, `RunSnapshot`, `OccurrenceSnapshot`, `ControlAckSnapshot`. | Validated events project to run, occurrence, attempt, decision, output, and billing state. A run may have active attempts and pending decisions together. Completion, cancellation, and failure are not interchangeable. |
| S10 | [Store](../../runtime/src/Agentic/Runtime/Store.hs), `appendStoredEvent`, `writeQuestionArtifact`, `readQuestionArtifactByCodeNameAt`, `readResultArtifactAt`. | Event sequence and typed artifact integrity are checked. `appendStoredEvent` calls `hFlush`, not a per-event durability barrier. Journal visibility must not be advertised as a power-loss guarantee. A known artifact can verify independently of journal replay. |
| S11 | [Catalogue](../../runtime/src/Agentic/Runtime/Catalogue.hs), `listRunCatalogueAt`, `readRunRecordAt`. [Read-only frontend](../../runtime/src/Agentic/Runtime/Frontend.hs), `runFrontendQuery`, `executeQuery`. | `frontend-io` opens an existing root, reads runs, lists bounded history including corrupt entries, and verifies question/result references. Its compact history snapshot is not a full live manager snapshot. Observation does not acquire a supervisor. |
| S12 | [Export](../../runtime/src/Agentic/Runtime/Frontend.hs), `runFrontendExport`, `executeExport`. [Private root](../../runtime/src/Agentic/Runtime/PrivateRoot.hs), `publishPrivateFileAt`, `openPrivateSubroot`, `assertPrivateRoot`. | Explicit export verifies typed content and publishes exclusively beneath the configured state's `exports` directory. The retained export and state roots are rechecked before a receipt. A lost reply can leave a complete file, and a retry does not overwrite it. |
| S13 | [Process groups](../../runtime/src/Agentic/Runtime/ProcessGroup.hs). [Bootstrap](../../cli/cbits/control_bootstrap.c). | Process-group ownership and cleanup are shared facilities. The private control descriptor is reserved before the threaded RTS starts. The frontend presents ordinary private pipes to its caller rather than requiring a client-created fd-3 bridge. |
| S14 | [TUI client](../../tui/src/Agentic/Tui/Client.hs), `buildLaunchPreview`, `loadInitialData`. [TUI process](../../tui/src/Agentic/Tui/Process.hs), `prepareAndStart`, `sendMachineControl`, `heartbeatOwner`. [TUI types](../../tui/src/Agentic/Tui/Types.hs), `validateStoredInvocation`. | The inspected TUI still previews separately, stages inputs/manifests, and launches `machine` or lineage commands. Its `prepareAndStart` name does not mean that it uses the native same-worker `frontend` session. It owns substantial launch and storage machinery. |
| S15 | [TUI run model](../../tui/src/Agentic/Tui/RunModel.hs), `updateMandatoryDecisions`, `reconcileRunView`. [TUI application](../../tui/src/Agentic/Tui/App.hs). | Presentation state is distinguished from runtime snapshots. Mandatory person/recovery decisions have FIFO presentation, and existing history/observer views are reusable UI behavior. |
| S16 | Downstream `emacs/wf.el`, `wf--prepare`, `wf--review`, `wf--event`, `wf--control-send`, `wf--owned-session`, `wf--io`, `wf-history`, `wf--make-process`. | Native setup and review retain the prepared worker. Per-session process ownership, event/control ledgers, verified artifacts, histories, and lineage sit in Lisp. TRAMP currently transports private processes on the workflow host. It is not an HTTP client implementation. |
| S17 | Pi worktree `ext-pi/src/index.ts`, `launchPrepared`. `frontend-session.ts`, `FrontendSession.prepare`. `supervisor.ts`, `RunSupervisor`, `OwnedRun`, `RestoredRun`. | Pi already coordinates several owned runs, retains bounded history, restores observers, and cancels owned runs on extension shutdown. The inspected launch path uses native preparation. These are manager-like client facilities, not a client-independent durable admission service. |
| S18 | Pi worktree `ext-pi/src/frontend-io.ts`, `FrontendStore`. `launch.ts`, `resolveRunnerInvocation`. `reducer.ts` and `monitor.ts`. | Helper-backed artifacts and trusted invocation matching coexist with client-side reduction and restoration/monitoring paths. Migration must inspect those paths rather than assume helper adoption removed all local storage responsibilities. |

The package inventory and focused source search found no durable multi-run HTTP
manager in this checkout. Existing HTTP client dependencies are not an HTTP
server. The incomplete Haskell coverage of the Cymbal index was not used as
proof of absence. Directory dependency rules also remain significant: runtime
policy depends on planning and the neutral engine API, while the CLI is the
composition root and concrete engines stay outside the runtime.

### 2.3 Input and local protocol contracts

An initial input is authored text, not a runtime question. Its preferred source
is `prompt`, `command-tail`, or `stdin`. Every declared name must be supplied
exactly once at preparation. The frontend captures and passes inputs in
declaration order, regardless of their order in the supplied array. Missing
names are a manager readiness condition. Duplicate or unknown names are
refusals. An empty string is supplied input, not an absent value. A JSON `null`
is not an empty string.

The existing session accepts these transport forms:

- `literal` supplies logical text. For a prompt input the frontend adds one LF
  to its transport representation, which the existing input decoder consumes.
- `transport` preserves `Text.encodeUtf8` exactly. The prompt decoder removes
  one final LF when present, while command-tail and stdin preserve it.
- `file` captures bounded bytes from a regular runner-local file without
  following a leaf symlink. The frontend does not reread it after approval.

The session request is bounded at 2,097,152 encoded bytes. Runtime control
frames are bounded at 1,048,576 bytes. Aggregate captured inputs have a
67,108,864-byte bound. JSON escaping counts toward the smaller preparation
frame limit. Large transport inputs therefore cannot be made valid merely by
splitting HTTP writes while retaining one oversized frontend JSON frame.

`frontend --capabilities` is separate from workflow discovery. The current
session v1 advertises `prepare`, `prepare-lineage`, `start`, and `discard`.
After start, the worker uses runtime protocol v2 and control v2. Closing the
supervisor's input cancels the session. Preparation may establish the private
state root but does not create the run's inputs, manifest, lease, or runtime
store until start. The prepared program, input bytes, run facts, target, and
environment remain in that worker.

`frontend-io` is read-only, while `frontend-export --state ...` is explicitly
mutating. Neither is a generic remote filesystem service. Manifest decoding
distinguishes absent legacy version, explicit v2, and explicit v3. Version v3
requires non-null invocation v1. Explicit `null` does not downgrade a record.
The inspected TUI and Pi invocation-aware paths match the entire recorded
tuple against current trusted configuration and execute that configuration,
never stored argv. The inspected Emacs `wf--prepare` and `wf--lineage` do not
supply invocation metadata. Its ordinary same-worker path therefore does not
establish v3 lineage interoperability, and a v3 parent receives the frontend's
explicit missing-invocation refusal. This is a client compatibility gap, not
permission for the manager to drop that provenance.

## 3. Meaning and architectural boundary

### 3.1 The manager's object

A manager history is a finite, ordered history of coordination transitions and
observed executions, with each execution indexed by its identity. It contains
workflow executions rather than defining a new way to compose their meanings.
An implementation state denotes the coordination resources it has durably
accepted and the per-run observations justified by validated runtime evidence.

For a history `h`, let `P_r(h)` select the unchanged runtime envelopes for run
`r`, discarding manager-only events. Let `Q(h)` be the complete manager-owned
coordination fold: requests and admission, profile/authority generations,
supervision observations, preparations, command intents and receipts, decision
reservations, captures, and verification/export observations. It includes an
answer intent committed before a pipe write, even when no runtime envelope has
yet changed. Let `R` be the existing runtime snapshot fold. The proposed
observable meaning is:

```text
M(h) = (Q(h), { r ↦ R(P_r(h)) | P_r(h) ≠ [] })
P_r(h ++ k) = P_r(h) ++ P_r(k)
R(xs ++ ys) = fold(stepRunSnapshot, R(xs), ys)
```

The runtime map contains only runs with validated runtime evidence. Reserved
start identities without envelopes remain in `Q(h)`. The fold equation is
restricted to valid contiguous envelopes for the same run and protocol. Manager
IDs, timestamps, and network reconnects do not alter runtime sequence numbers.
Changes to the manager's representation must satisfy
`decode(stepStorage(s, e)) = stepManager(decode(s), e)` for an accepted event.
These are proposed specification and refinement obligations, not theorems
already proved in Lean.

The semantic preservation obligation is narrower than unconditional equality
between two physical runs. With the same captured program and inputs, inherited
facts, runtime policy, controls, and engine observations, projecting the managed
execution must give the execution of that same runtime session. Erasing intent
and attempt attribution then gives the existing authored dialogue observation
[S01, S02]. Cancelling or answering differently deliberately changes the
observed execution. Concurrent runs sharing a conversational backend, mutable
workspace, or external service do not automatically commute. No such theorem is
claimed.

The current Lean adequacy theorem remains under its existing assumptions. New
manager proofs require their own axiom reports. No theorem statement or frozen
conformance corpus is weakened to admit the service.

### 3.2 Proposed components

```text
 TUI                 Emacs                 Pi
  | native UI         | buffers/editors     | Pi UI and grants
  +-------------------+--------------------+
                      | HTTPS resources and SSE
             [ TLS and authentication boundary ]
                      |
              Single-user manager
        admission / decisions / durable receipts
        resource projections / replay / authorization
                      |
         trusted profile and worker adapter
                      | private bounded stdin/stdout
                      | separate bounded diagnostics
              RUNNER frontend
          prepare -- exact approval -- start
                      |
       agent-cat runtime / controls / store / engines
                      |
             verified questions and results

 Manager database and captures      Existing runtime stores
       local private root             private retained roots
       coordination authority         execution evidence
```

The proposed manager library depends on neutral runtime facilities, not on
`Agentic.Cli`, a workflow registry, Pi, or a concrete engine. The CLI composes the
service with trusted configuration. Its first worker adapter invokes configured
runner executables through `frontend`, without shell interpolation. Moving
neutral session codecs out of the CLI, if required for reuse, is an explicit
future shared-library change. It is not permission to copy a second parser and
interpreter into the manager.

The manager selects a configured execution profile, admits a run, forwards
validated controls, and stores observations. The runtime continues to select
and execute occurrences, validate typed answers, perform retry/failover,
interpret lineage, compute routing fingerprints and bills, and verify artifacts.
The manager must not estimate a missing bill or infer success from prose.

A remote presentation is not a remote engine. Pi's current-session bridge and
its client-owned children require a living Pi host, which the server cannot
reconstruct from a saved target label. The first service exposes only execution
profiles whose engines the manager can actually supervise independently of a
UI connection. Existing client-bound targets remain available through the
explicit legacy Pi path. A future leased engine connector needs a separately
specified engine capability, authenticated channel, and failure contract. It
must not be disguised as an SSE subscription or a generic command tunnel.

## 4. Lifecycle, concurrency, and decisions

### 4.1 Distinct resources and state dimensions

A **request** is a durable intention to execute one selected workflow under a
trusted profile. It may lack inputs and need not ever run. A **preparation** is
one live worker's exact reviewable execution. A **run** records a start attempt
and its runtime observations. Restart, resume, and fork create new requests and
new runs with a parent link, never reset an existing run's identity.

Public run handles are manager-local opaque IDs. Internally they map to a
trusted profile, retained root identity, and the worker's native run ID. Native
IDs and envelopes are preserved without renaming, even where two profiles use
the same native run ID. Preparation and approval IDs are not bearer credentials.

| Dimension | Proposed values or representation |
|---|---|
| Request phase | `draft`, `queued`, `preparing`, `review`, `start-pending`, `associated`, `withdrawn`, `refused`. |
| Input readiness | Declared names, supplied representations, missing names, validation errors, and immutable capture references. |
| Admission | Queue ordinal, blocking reason, profile revision, and resource reservation. |
| Preparation | Absent, live with expiry and review digest, consumed, or invalidated with reason. |
| Runtime | The validated existing run snapshot, with its occurrence and attempt states. Before runtime evidence exists this component is absent. |
| Supervision | `owned`, `cleanup-pending`, `lost`, or `observer`. A last reported running state can coexist with lost supervision. |
| Decisions | Ordered pending person/recovery decisions, including exact occurrence, generation, and control status. |
| Result | Absent, referenced, verified, or unavailable/corrupt. This is separate from the runtime's reported terminal outcome. |

A run that is waiting for an answer can still have other active attempts. The
UI shows both. It does not replace the run state with a global `waiting` flag.
Likewise, an accepted cancellation command does not make a run cancelled before
the runtime reports its outcome and cleanup has completed.

### 4.2 Request path

```text
create draft --> supply missing inputs --> enqueue --> preparing
     ^                                     |             |
     |                        resource wait remains queued|
     |                                                   v
     +-- edit / expiry / lost preparation <----------- review
                                                         |
                                               explicit approval
                                                         v
                                                   start-pending
                                                         |
                                             runtime evidence arrives
                                                         v
                                                    associated
                                                         |
                                    run execution and retained history

Before start: withdrawal discards the worker and releases its reservation.
After start intent: cancellation is a run command, not deletion of the request.
```

Draft creation selects a workflow descriptor revision and an operator-installed
profile revision. The service reports missing inputs without launching an
engine. Submission preserves the distinction between a logical literal and an
immutable captured transport. Readiness means the declared representations are
present and structurally valid, not that semantic preparation has succeeded.

Enqueueing is explicit. Editing a queued request removes it from the queue.
Editing a live preparation discards that worker and requires a new preparation
and approval. An expired or invalidated preparation returns the request to a
draft with a reason. It does not automatically take another queue position.

The first implementation uses FIFO queue ordinals assigned transactionally.
It selects the oldest eligible request. A blocked profile does not prevent work
for a different independent profile. Within a shared resource, later work does
not overtake earlier eligible work. The default concurrency limit is one, with
an operator-configured higher limit for suitable workloads. There is no promise
of a start time when earlier runs or human decisions have no bounded duration.

A reservation covers preparing, review, starting, running, and cancellation
cleanup. It includes the global slot and configured exclusive resource keys,
such as a workspace or conversational engine session. A worker awaiting approval
therefore consumes capacity. The proposed review timeout is ten minutes. This
limits abandoned reviews without approving them automatically. Slot release
requires confirmed worker/process-group cleanup, not merely expiry of a UI timer.
Concurrent use of an unclassified shared backend defaults to serialization.
Resource keys come from trusted profiles, not labels guessed from workflow names.

### 4.3 Exact approval

The worker's prepared response is the source of the review. The manager checks
its advertised contract, identities, descriptor, program hash, captured input
summaries, resolved public policy, person-answering mode, and configured target.
The review identifies the workspace/profile and configuration revision, exposes
the non-secret facts needed for informed consent, and never dumps the process
environment. Private invocation details remain in the protected audit record.

The manager binds a review digest to that exact prepared response, request
revision, trusted profile revision, live worker association, and manager process
generation. Approval requires the current preparation ETag and review digest.
The manager records the approving client and a start intent durably before
writing the existing `start` frame to that same worker. A successful HTTP
receipt acknowledges the intent, not a completed run.

Loss of the worker, expiry, profile revocation/change, input editing, or manager
restart invalidates the preparation. A new worker can prepare the retained
request, but it requires a new review and approval. A stored plan, invocation,
input hash, or old approval ID cannot reconstruct the lost environment or
transfer approval. The existing frontend performs its own post-approval checks,
including the parent checks for lineage.

### 4.4 Human decisions and controls

Runtime person questions are fetched through verified question references. Their
code, prompt, and semantic schema are runtime data [S02, S05, S10]. The service
may expose a JSON Schema rendering from the shared schema library for editors,
while the runtime decoder remains the final authority. Per-input descriptions
for initial forms require new authored metadata and descriptor negotiation.
Until then the API returns `description: null` and `type: string` for initial
inputs, without inventing descriptions or optional values.

Pending mandatory decisions retain FIFO order within a run, based on the
runtime event that opened them. The global inbox orders run heads by manager
observation order. Selecting another run does not change that run's FIFO.
Answering a non-head mandatory decision refuses explicitly. Every endpoint
that can submit that control uses the same decision reservation and FIFO
checks, including the run control surface. Independent runs
continue, and the service does not impose one global modal dialog.

The manager owns the actual control pipe. Any authenticated client with control
scope for that profile can act on a manager-owned run. There is no exclusive
lease tied to a foreground window. Competing clients are arbitrated by resource
revisions and exact occurrence/attempt identity. The first valid answer reserves
the decision. Another answer is stale, including one submitted from an editor
that was opened before a retry.

A decision remains visible as submitting until runtime evidence resolves it.
`Accepted`, `Queued`, `Delivered`, `RejectedStale`, `Unsupported`, and
`ControlFailed` remain distinct [S08]. A rejection or failed delivery releases
only a reservation that has not taken effect and re-evaluates current runtime
state. A delivery timeout is not proof of failure and does not permit a second
answer. Existing control IDs and effect correlation are retained, including
failover's correlation with `occurrence.retried`.

Whole-run cancellation, steering with timing, retry, recovery choice, redirect,
and person answers are the existing controls. Unsupported operations refuse.
There is no new generic pause operation, shell command, or engine prompt API.
A workflow-authored confirmation uses its typed person question. Preparation
approval, an initial input, and a runtime boolean answer are three different
operations. Cancellation does not undo completed external effects or establish
that a provider has stopped all work. Cleanup claims cover only the processes
and engine resources for which the supervisor has actual evidence.

Lineage requests require a parent that the existing runtime permits for the
selected operation and whose former ownership cannot conflict with new work.
An unresolved cleanup quarantine prevents preparation on its affected resources.
The service passes only the parent identity, lineage operation, trusted
invocation, person-answering mode, and typed fork edits to `prepare-lineage`.
It does not accept workflow, input, or target overrides for this path.

## 5. Persistence, restart, and ownership

### 5.1 Durable records and boundaries

The recommended coordination store is SQLite on a local filesystem, with one
manager writer, WAL journaling, explicit `synchronous=FULL`, bounded
transactions, and monitored checkpointing [W07]. Transactions commit request
revisions, queue reservations, command receipts, projection changes, and their
outgoing event records together. An HTTP mutation receipt is sent only after
that commit. Streams do not hold database read transactions while waiting on
network clients.

This is a new dependency and a future implementation choice, not a capability
of the current package. A transactional database is justified by the need to
commit admission, deduplication, and observations together. A bespoke second
append-file transaction/recovery protocol would recreate those obligations.
WAL files belong with the database. Backups use a coherent database snapshot.
SQLite's durability still depends on the filesystem, VFS, and hardware honoring
sync operations. Network filesystem storage is not supported for the manager DB.

Restoration to an older backup is an offline operator recovery, not an ordinary
restart. Before reopening the network boundary, fence old workers, rotate both
the event-stream identity and the database authority epoch, and invalidate all
restored credentials, including observation credentials. Provision fresh
credentials locally and require fresh client reconciliation. Mutations carry
the authority epoch in their idempotency keys, so a pre-restore key refuses
even under replacement credentials. Clients must not regenerate keys or replay
unresolved operations automatically after restoration. Effects in the lost
interval remain potentially executed until independent evidence resolves them.
Idempotency across ordinary restarts is preserved, but it cannot recover facts
that an older backup does not contain. Arbitrary replacement of database files
while the service is running is not a supported restore procedure.

Large inputs and results do not become database event payloads. Captures are
immutable private files. A capture is acknowledged only after bounded upload,
UTF-8 validation, digest calculation, durable exclusive publication, and the
metadata transaction. File publication and the database transaction are not
atomic together. Unreferenced files after a crash are collected only after a
grace period and proof that no request, preparation, or pending command uses
them. A database reference to missing or changed bytes is a refusal, not a
reason to reread an original source. Durable capture publication needs an
explicit shared storage contract and platform tests. Exclusive publication
alone is not evidence of power-loss durability.

The runtime store remains the execution evidence and lineage input. The
manager records validated ingestion identities `(profile, nativeRunId,
sequence, envelopeDigest)` and durable observation/projection data so that its
own stream has a replayable prefix. Matching duplicate runtime envelopes do
not create duplicate effects or notifications. A different payload at the same
native sequence is an integrity failure.

No distributed transaction spans SQLite, the worker pipe, the runtime journal,
and an engine. The service does not promise exactly-once engine effects. In
particular, it does not repair a damaged runtime journal by manufacturing it
from a manager projection. A durable manager observation can survive a power
loss that removes a merely flushed runtime artifact or journal entry. The view
then distinguishes previously observed outcome from presently verifiable
content, and semantic resume still uses the runtime's authenticated store.

### 5.2 Failure matrix

| Failure point | Proposed recovery |
|---|---|
| Upload disconnect before publication | No capture receipt or input binding exists. Remove only the manager's unreferenced partial file. |
| Capture published, DB commit absent | It is an unreferenced private file. A bounded sweep can collect it after the grace period. |
| Draft or queued request after restart | Restore immutable submissions and queue order, revalidate the trusted profile and bytes, then prepare normally. No previous approval exists to reuse. |
| Prepared worker lost or manager restarted | Invalidate the preparation and its approval. Discard/clean up any old worker through verified containment. Require fresh preparation and approval. |
| Start intent committed, write or reply uncertain | Retain the reserved native run identity and mark the start outcome unresolved. Inspect genuine runtime evidence. Never automatically resend start or create another run. |
| Client loses an HTTP mutation reply | Retry the exact request with the same idempotency key, or query its command resource. Do not issue a new semantic operation merely to discover what happened. |
| Control intent persisted, runtime acknowledgement uncertain | Preserve an unresolved command. Correlate later live or stored evidence. Do not automatically replay it across a supervisor loss. |
| Manager dies while a run is active | Loss of its private control pipe invokes existing cancellation behavior. After restart, inspect history as an observer and mark missing terminal evidence as interrupted/lost supervision. Do not claim a clean cancellation. |
| Worker exits without a valid terminal sequence | Retain the last validated snapshot, diagnostics, and supervisor failure. Do not infer success from exit code or text alone. |
| Runtime terminal event exists but artifact verification fails | Show the reported terminal outcome and the separate unavailable/corrupt result. Do not offer an unverified download. |
| HTTP or SSE client disconnects | Continue owned work and preserve decisions. Only that client's transport and bounded buffers are released. |
| Database/storage unavailable or full | Refuse new admissions, approvals, and ordinary mutations. Existing safety supervision remains active, drains or cancels workers as necessary, and records degraded supervision when storage returns. Do not acknowledge uncommitted commands. |

A single local service lock prevents two managers from owning the same store.
Startup acquires exclusive service ownership and revalidates the configured
private root. Process generation changes fence old preparation associations.
A PID file, owner heartbeat, root identity, or stored run ID is not a live
control capability. Existing foreign-owned stores are observations only.

Clean shutdown first stops admissions, invalidates unapproved preparations,
and either drains active runs or explicitly cancels them under an operator
policy. The proposed default is drain, with an operator-controlled deadline.
Hard death requires OS process containment in addition to the control-EOF
contract, because process groups alone do not establish that every descendant
has stopped when the manager is killed. A supported service runner must prove
cleanup of its own process tree on Linux and macOS. It must never signal a
recycled PID recovered from a manifest. If old descendants cannot be proved
stopped, affected resource reservations remain quarantined for operator action.
The first implementation does not adopt surviving workers.

## 6. Proposed HTTP resources

### 6.1 Common contract

All paths in this section are proposed beneath `/v1`. Every application request
is independently authenticated and authorized. Valid CORS preflight OPTIONS
requests have the narrow non-resource exception in Section 8.2. Persistent
workflow resources do not require a transport session. Responses provide links
to applicable next operations, while the server checks the lifecycle regardless
of which links a
client follows. Capability discovery advertises manager API, snapshot, and
event versions separately from runner descriptor, session, control, protocol,
manifest, and store versions.

JSON requests use strict schemas, reject duplicate and unknown command fields,
and preserve arrays, booleans, nulls, numeric values, and Unicode accurately.
Runtime numeric schemas retain their existing encoding/decoding restrictions.
A generic browser number coercion is not an acceptable decoder for every code.
Unsupported versions refuse rather than guessing a downgrade. HTTP content
negotiation and problem responses follow HTTP semantics and RFC 9457 [W01, W02].

The proposed mutation contract requires `Idempotency-Key` on POST, scoped by
registered client identity, method, canonical resource URI, and key. The server
derives that client identity from the credential, not from a request field.
Credential rotation preserves this registered identity and its ledger. Keys
use `<authorityEpoch>.<nonce>`, at most 128 ASCII bytes, where the nonce has at
least 128 random bits. Capabilities advertise the database authority epoch,
which persists across ordinary restarts and credential rotation. A wrong epoch
returns 409 `authority-changed` before ledger lookup. This is an
application-defined contract, not a claim that HTTP makes every POST idempotent.

The key binds exact body bytes, media type, and relevant preconditions. A
conflicting reuse returns 409. Matching retries return the original durable
receipt and command link without another effect. Authentication and current
authorization are checked before returning a receipt and again in the state
transaction that accepts a new intent. A revocation fences intents ordered
after it. Already committed start intents are approved work and require an
explicit cancellation rather than retroactive reinterpretation.

Retain receipts while the resource is active and for at least 30 days afterward.
Thereafter retain a non-content key tombstone for the lifetime of its registered
client identity, returning 410 rather than executing an expired retry. Retired
client and credential identities are never reused. A newly registered client
must reconcile rather than automatically replay another identity's unresolved
operations. A configured ledger quota refuses new ordinary mutations before
space is exhausted, rather than evicting protective tombstones. Reserved
safety-control capacity remains available. Backup restoration additionally
requires the authority fence in Section 5.1.

Edits and state-changing POSTs on an existing request, preparation, decision,
or control surface require that resource's strong `If-Match` ETag. The ETag
comes from GET on the same URI, not from a parent or unrelated snapshot.
A missing precondition gives 428 and a mismatch gives 412. An exact completed
idempotent retry is recognized before attempting a fresh transition, consistent
with RFC 9110's already-applied provision. Ordinary competing updates never
bypass the precondition. A control surface changes revision when available
controls or their addressed occurrences change, not for each output fragment.

### 6.2 Resource table

| Resource | Methods and purpose |
|---|---|
| `/capabilities` | GET manager limits, versions, authentication method, and supported operations. It does not expose provider credentials or raw invocation arguments. |
| `/profiles` | GET allowed profile IDs, public workspace/target labels, configuration revisions, and readiness/refusal categories. |
| `/workflows?profileId=...` | GET bounded catalogue pages with the source descriptor revision and links. Query values here are non-secret identifiers only. |
| `/workflows/{id}` | GET one catalogue representation, descriptions available from source, input declarations, help/plan links, and result code. Exact input-dependent planning belongs to preparation. |
| `/requests` | POST create a draft. GET paginated request summaries. Creation does not execute a workflow. |
| `/requests/{id}` | GET request and readiness. POST `set-input`, `remove-input`, `enqueue`, or `withdraw` against its current ETag. An edit invalidates queue/preparation as described in Section 4. |
| `/captures` | POST a bounded `application/octet-stream` UTF-8 transport, returning an opaque immutable capture ID and byte/digest receipt. No source URL or server path is accepted. |
| `/preparations/{id}` | GET exact public review, expiry, and ETag. POST `approve` with review digest or `discard`. The existing worker approval ID remains server-side. |
| `/runs` | GET paginated history and current runs with independent execution, supervision, and result states. Foreign or corrupt entries remain visible with explicit limitations. |
| `/runs/{id}` | GET stable run metadata, lineage, and links to snapshots, decisions, controls, and results. |
| `/runs/{id}/snapshot` | GET the full versioned runtime-derived view, with bounded materialized pages for large occurrence/attempt collections. |
| `/runs/{id}/control` | GET capabilities and current control revision. POST an existing runtime control, with exact occurrence/attempt fields where applicable. Returns a command receipt. |
| `/decisions` | GET ordered pending run heads and links to their queues. |
| `/decisions/{id}` | GET a verified question or recovery choice and its generation/ETag. POST `answer` or `choose-recovery`. Values are never placed in a URL. |
| `/commands/{id}` | GET durable intent, runtime acknowledgement, effect evidence, or unresolved/refused outcome. An HTTP receipt is not runtime `Delivered`. |
| `/runs/{id}/outputs` | GET bounded intermediate-output summaries and verified result links, with attempts and diagnostics distinguished from final content. |
| `/artifacts/{id}` | GET verified typed artifact content. The server resolves an internal trusted reference, never a client pathname or invented digest. |
| `/runs/{id}/exports` | POST explicit result export, with only an allowed single-component name. Returns a command and then a receipt without the server filesystem path. |
| `/exports/{id}` | GET receipt metadata and verified download link. Existing conflicting names are not overwritten. |
| `/runs/{id}/lineage-requests` | POST a new `restart`, `resume`, or `fork` request. Fork edits use the existing typed replacement/drop contract. No stored invocation is executed directly. |
| `/snapshot` | GET one consistent live-overview snapshot and its stream cursor. Retained history is paginated separately. |
| `/events` | GET SSE changes after `Last-Event-ID`, or bounded JSON event pages with `Accept: application/json`. Both use the same cursor and retention rules. |

A snapshot page set is materialized from one database read transaction and then
served outside that transaction. It has a revision, byte bound, expiry, and
opaque page tokens bound to the authenticated client and query. Expired pages
return 410 and require a fresh snapshot. A live overview includes all admitted
requests and active run summaries within the advertised admission bound. Large
per-run detail uses the separately versioned snapshot pages. History pagination
uses the same consistent page-set rule, not mutable filesystem offsets.

### 6.3 Representative payloads

The following examples are proposed manager representations, not existing
frontend frames. IDs are illustrative and confer no authority. A workflow's
initial field can presently be described as follows:

```json
{
  "id": "wf_hello",
  "name": "hello-world",
  "profileId": "profile_main",
  "descriptorVersion": 3,
  "inputs": [
    {
      "name": "language",
      "source": "prompt",
      "description": null,
      "required": true,
      "schema": {"type": "string"}
    }
  ]
}
```

Creating `/requests` returns 201 with `Location` and the request representation.
The input initially remains missing:

```json
{
  "workflowId": "wf_hello",
  "descriptorRevision": "catalogue_17",
  "profileId": "profile_main",
  "profileRevision": "profile_rev_4"
}
```

GET `/requests/req_8` yields its ETag. A POST to that same URI, carrying the
ETag and an idempotency key, supplies a logical literal:

```json
{
  "operation": "set-input",
  "input": {"name": "language", "source": "literal", "value": "Spanish"}
}
```

An uploaded transport instead uses
`{"name":"language","source":"capture","captureId":"capture_6"}`.
The server binds the capture to the request and profile. For a small transport
it can use the existing `transport` source. For a large one it supplies the
existing `file` source from its own immutable private capture storage, not from
a path supplied by the client. The worker's returned byte count and digest must
match that capture. Logical literals retain their representation until the
existing frontend performs descriptor-specific encoding and capture. The
manager does not duplicate newline or prompt decoding rules.

Enqueueing is another POST on the current request revision. The response is 202
with a command link, and later exposes a live preparation. Approval is POST on
`/preparations/prep_9` with its current ETag:

```json
{"operation":"approve","reviewDigest":"review_9"}
```

The start-intent receipt can be:

```json
{
  "commandId": "cmd_11",
  "state": "accepted",
  "requestId": "req_8",
  "runId": "run_21",
  "links": {"self":"/v1/commands/cmd_11","run":"/v1/runs/run_21"}
}
```

A runtime question might expose `code: "flag"` with an editor schema of
`{"type":"boolean"}` derived through the shared code interpretation. Answering
its decision resource uses the exact typed value, not its display string:

```json
{"operation":"answer","value":false}
```

A steering request on the current run control surface can be:

```json
{
  "operation": "steer",
  "occurrenceId": "0",
  "attemptId": "1",
  "timing": "next-boundary",
  "text": "Summarize the established evidence before continuing."
}
```

This is translated to the existing control codec with a correlated control ID.
The adapter does not treat HTTP acceptance as delivery. A stale decision returns
412 with `Content-Type: application/problem+json`, for example:

```json
{
  "type": "https://manager.example/problems/stale-revision",
  "title": "The decision has changed",
  "status": 412,
  "instance": "/v1/decisions/decision_3",
  "code": "stale-revision",
  "links": {"current":"/v1/decisions/decision_3"}
}
```

The service returns 400 for malformed framing/schema, 401 for absent or invalid
authentication, 403 for insufficient scope, 404 for an unavailable resource,
409 for lifecycle/idempotency conflicts, 410 for expired replay/page state,
413 for size limits, 415 for unsupported content type, 422 for invalid typed
values, 429 for rate/admission limits, and 503 for unavailable safe supervision
or storage. Missing authentication is checked before revealing resource
existence. Problem details contain bounded stable categories, not captured
values, argv, paths, stack traces, or raw provider errors. The example problem
origin is illustrative, not a deployed endpoint.

## 7. Live delivery and reconciliation

### 7.1 Transport decision

The workload has many observations and comparatively infrequent discrete
commands. Those commands already need durable receipts, preconditions, and
queryable outcomes. A bidirectional socket does not remove that requirement.

| Transport | Fit and cost |
|---|---|
| SSE plus HTTP commands | Recommended. SSE defines UTF-8 event framing, event IDs, reconnection behavior, and `Last-Event-ID`. Native clients can send Authorization headers. Durable replay and backpressure policy remain application responsibilities [W03]. |
| WebSocket | Standard bidirectional text/binary messages and ping/pong are useful for interactive engine traffic, but this UI interface does not require them. Replay, acknowledgements, authorization per action, and stale-command handling still need an application protocol. The browser `WebSocket` API has no receive-side backpressure mechanism [W04, W05]. |
| Bounded polling | Required fallback through the same snapshot/event resources. Easier to diagnose and available in all clients, at the cost of latency and extra requests. It does not change execution semantics. |
| Long polling | A possible later optimization of bounded polling. It adds timeout/connection handling without eliminating replay logic, so it is not required for the first contract. |
| NDJSON over HTTP | A reasonable native transport, but lacks SSE's standardized reconnect field conventions and browser EventSource interface. Existing worker NDJSON remains internal and is not exposed as a competing public event protocol. |
| HTTP streaming through Fetch | A way to consume the selected SSE format with explicit headers and readable-stream control, not a different server protocol. It needs a conforming parser and explicit reconnect logic. |

Browser `EventSource` accepts a URL and `withCredentials`, not arbitrary
Authorization headers [W03]. A future browser client for this bearer-auth API
therefore consumes SSE through Fetch with an Authorization header. It keeps a
short-lived credential in memory, not a query parameter or local storage. A
cookie-based browser session is not part of v1. Adding one requires the
separate CSRF and session provisions in Section 8, rather than weakening the
API to fit EventSource's constructor. Emacs, terminal, and Pi adapters require
HTTP/SSE acceptance testing in their actual supported runtimes. Existing pipe
and TRAMP tests do not establish that new transport support.

### 7.2 Event identity and content

A durable manager event has a stream identity, monotonically increasing decimal
sequence, resource ID/revision, and change kind. The stream identity persists
across ordinary manager restarts and changes after database restoration or a
history reset that could reuse sequences. The manager's process generation is
separate and changes on every restart. A public cursor is a bounded opaque
encoding of stream identity and sequence. It is not a runtime sequence or a
credential.

The global order is manager commit order, not physical simultaneity between
engines. Per-run runtime order is validated independently. Sequence numbers
are strings at the JSON boundary to avoid loss through JavaScript numbers.
The initial event set is `request.changed`, `preparation.changed`,
`run.changed`, `decision.changed`, `command.changed`, `artifact.changed`, and
`service.changed`. Resource invalidations avoid sending full prompts, tool
arguments, or arbitrarily large output in the event queue.

```text
id: stream_A.1042
event: run.changed
data: {"version":1,"resource":"/v1/runs/run_21/snapshot","revision":"runrev_18"}

: heartbeat

```

An SSE block is dispatched only after its terminating blank line. Partial
blocks are discarded on disconnect [W03]. A heartbeat has no ID and advances
no cursor. Events carry committed invalidations, while GET retrieves bounded
current state and verified content. A GET can return a revision newer than the
notification that triggered it. ETags are opaque equality tokens, not sortable
version numbers [W01]. Clients serialize refreshes per resource, with at most
one in-flight GET or materialized page set. Notifications received meanwhile
set a dirty flag. After the response is installed, a dirty resource is fetched
again, so an older response cannot arrive after a newer refresh and replace it.
Mutation receipts are not replacement snapshots. A full resnapshot or endpoint
change advances a local fetch generation, invalidating older pending responses
and page sets. Clients discard those responses rather than installing them.

### 7.3 Snapshot and replay algorithm

1. Fetch `/snapshot`. Its materialized overview and cursor `c` describe one
   manager transaction boundary. Fetch additional page sets through the
   supplied links when detailed views are required.
2. Open `/events` with `Last-Event-ID: c`. The server reads committed events
   strictly after `c` from the same database stream and then follows new
   commits. Every batch read atomically checks the retained floor and reads
   events in the same database transaction, including reads on an already-open
   stream. If eviction has overtaken the cursor, close the stream before
   emitting a later cursor. Its reconnect receives 410 and a snapshot link.
   JSON event pages use the same check. There is no gap between a subscription
   registration and a separate in-memory broadcast. A wakeup only tells the
   reader to query the durable log.
3. Validate complete blocks and advance the locally applied cursor only after
   applying each notification. Duplicates at or below the applied cursor are
   harmless. Applying an invalidation records pending refresh work as described
   in Section 7.2. Coalesce that work without advancing past an unapplied event.
   After a client process restart, obtain a new overview snapshot rather than
   trusting a saved cursor whose pending refresh state was lost. Runtime deltas
   are never fabricated from missing events.
4. Reconnect using the last applied cursor. A cursor for the wrong stream,
   before retention, or beyond the committed high-water mark returns 410 with
   a snapshot link before opening SSE. The client obtains a fresh snapshot,
   rather than quietly attaching at the present and losing changes.
5. For a single resource whose page set expires or whose version cannot be
   understood, refresh that resource or the whole overview. Disable mutations
   when the necessary current decision/control revision is unavailable.

The stream is global within the client's authorized profile view. A cursor is
bound to that view's authorization version. Credential/profile permissions
changing requires a new snapshot. The server can omit inaccessible records,
so clients treat cursors as opaque and do not infer corruption from numeric
gaps. Authorization is rechecked during long-lived connections, including
revocation. No subscription grants continuing authority after revocation.

Replay is at least once within retention, not exactly once and not unlimited.
The proposed default retains seven days or 256 MiB of invalidation events,
whichever bound is reached first. It publishes the oldest available cursor.
Event eviction does not delete runtime histories, captured inputs, decisions,
command records, or artifacts. Those have separate retention dependencies.

### 7.4 Bounds and slow clients

Proposed initial limits, all advertised through capabilities, are 100 queued
requests, 16 maximum execution reservations with a default of one, 2 MiB JSON
requests, the existing 1 MiB control-frame bound, 64 MiB total captured input
per request, 64 MiB verified artifacts, 16 KiB event blocks, 1 MiB snapshot
pages, and 64 MiB per materialized page set. Limit simultaneous page sets to two
per client and expire them after 60 seconds. Enforce a global page-set budget
as well. A bound reached while constructing a view returns an explicit refusal,
not a silently incomplete snapshot.

Each authenticated client has at most two SSE streams and a 1 MiB pending
transport buffer. The service also applies a global connection limit and
bounded database readers. A slow client's connection is closed when its bound
or write timeout is reached, after which it replays or resnapshots. One client
must not backpressure the worker's private event pipe through the network
writer. A stalled durable event/projection writer, in contrast, is a service
storage failure governed by Section 5 rather than an excuse to drop events.

Heartbeat comments are proposed every 15 seconds, with a client reconnect after
45 seconds without a byte and exponential reconnect backoff with jitter up to
30 seconds. These are tuning defaults, not guarantees supplied by SSE. Proxies
must flush event blocks, disable response buffering/caching and compression
that prevents timely delivery, and set suitable idle timeouts. Prefer one
multiplexed UI event stream and HTTP/2 where supported. HTTP/1.1 remains valid.
Polling backs off on 429/503 and respects `Retry-After` when present.

## 8. Remote single-user security

### 8.1 Principal, credentials, and TLS

Single-user operation still has untrusted network traffic, multiple clients,
and model-authored tool requests. The manager authenticates each client with
its own randomly generated opaque bearer credential, at least 256 bits of
entropy. Store only a token verifier and non-secret credential ID on the
server. Provision and rotate credentials through a local administrative
channel, not an unauthenticated remote setup endpoint. Tokens never appear in
URLs, process arguments, workflow inputs, shell history, or diagnostics.

Native clients retrieve credentials from an OS credential store or an explicitly
selected private credential file. Emacs may use its existing secret-storage
facilities, but must not print credentials into buffers, minibuffer history,
TRAMP commands, or process diagnostics. Pi keeps the credential in trusted
extension configuration, outside model-visible tool arguments. Workflow and
engine subprocesses receive only their required environment, not the manager's
client credentials or administrative keys.

Credentials have expiry and independently revocable scopes: `observe`,
`submit`, `control`, and `export`, restricted to allowed execution profiles.
Local administration is not a network scope. Observation includes potentially
sensitive output, so it is not anonymous access. Cancellation and answers
require control scope and genuine manager ownership, while creating a draft
requires submit scope. Approval requires both submit and control scope.
Each credential belongs to a registered client identity. Rotation preserves
that identity's idempotency ledger, permits a brief explicit credential overlap,
then revokes the old credential and closes its streams. Credential expiry or
revocation does not cancel already-owned work, but no new command is accepted
under that credential. Offline database restoration has the stricter authority
fence specified in Section 5.1.

Non-loopback access requires HTTPS with certificate and hostname validation.
Prefer TLS 1.3, allowing TLS 1.2 only for documented compatibility [W08]. An
operator-managed reverse proxy may terminate TLS and forward to a protected
local socket. The manager still authenticates requests. The proxy is inside
the confidentiality boundary and must not log Authorization or bodies. Trust
forwarded identity/host headers only from the explicitly configured proxy,
reject unexpected Host values, and never expose its backend socket on the
network. Plaintext bearer access is not an automatic loopback development
exception. An SSH tunnel may carry HTTPS or a separately authorized local
socket connection, but transport choice does not waive ownership checks.

Bearer credentials are possession-based, not phishing-resistant user presence
[W06]. For Internet-facing deployments, network access restriction or mutually
authenticated transport is an additional required boundary, consistent with
OWASP's warning against relying on API keys alone for high-value controls
[W09]. The specific proxy/VPN/certificate arrangement remains an operator
choice before deployment. No deployment is performed by this design.

### 8.2 Browser and model boundaries

V1 uses no ambient authentication cookies, accepts no credentials in query
strings, and permits no cross-origin access by default. A future browser origin
must be explicitly allowlisted by exact scheme, host, and port. A valid CORS
preflight OPTIONS request does not require a bearer credential, since browsers
do not send one in that request [W11]. It checks only the exact allowed origin,
method, and requested headers, including Authorization and preconditions.
It neither reads protected resource state nor performs a mutation. Rate-limit
this unauthenticated policy check independently. Actual requests still require
authentication and resource authorization.

Use explicit CORS allowlists, expose required response headers such as ETag,
Location, and Retry-After, and send `Vary: Origin` for origin-dependent replies.
There is no wildcard credentialed CORS response. Authentication of application
requests remains mandatory regardless of Origin, since native callers can forge
it. Unexpected browser Origins and `Origin: null` refuse. A missing Origin is
permitted for authenticated native clients, not treated as authentication.

With non-ambient Authorization headers and strict JSON/octet-stream content
types, a third-party site cannot rely on browser cookies to submit authenticated
commands. This does not protect against XSS or stolen tokens. If cookies are
introduced later, use Secure, HttpOnly, appropriate SameSite restrictions,
server-side expiry, exact Origin validation, and CSRF tokens for every unsafe
operation. Ordinary EventSource compatibility is not a reason to omit those
requirements. A future WebSocket endpoint would additionally require handshake
Origin validation, message-level authorization, bounded frames, and session
revocation, not just a successful upgrade [W10].

A machine client credential authorizes an application, not every instruction
that an LLM reads. Pi retains its user-grant and project-trust gates for model
initiated mutations. Those gates are not asserted to the server by a forgeable
`approved: true` field. The trusted Pi extension sends the actual authorized
request. The manager independently enforces profile scope, current revision,
and exact preparation approval. Other clients retain their explicit consent UI.

### 8.3 Files, executables, data, and resource exhaustion

Execution profiles are installed by the operator and contain the trusted
runner alias, executable, ordered prefix, permitted workspaces, target policy,
engine configuration, and resource restrictions. Network callers select their
IDs and revisions. They cannot submit executable paths, prefix/target argv,
arbitrary environment overrides, shell fragments, filesystem roots, source
URLs, or routing secret values. Remote catalogue lookup executes only these
trusted runners and is bounded by timeout and output size.

The service keeps current configuration authority separate from historical
invocation provenance. An exact historical tuple mismatch refuses lineage or
requires a deliberate trusted configuration selection where the legacy
contract permits it. It never rewrites a parent's invocation or launches an
executable copied from a stored manifest. A change in configured credentials or
target policy invalidates an unstarted preparation according to its profile
revision. This is revocation of a preparation, not a silent new environment.

Uploads are raw bounded UTF-8 bytes rather than archives, filenames, or fetch
instructions. Invalid UTF-8, decompression expansion, excessive JSON depth,
duplicate fields, oversized headers/frames, and unbounded streams refuse before
large allocations. Client cancellation only abandons an incomplete upload.
Private capture IDs map to retained server-owned files. No global content hash
lookup reveals whether another request contains guessed content.

Verified artifacts resolve from runtime-issued references kept by the server.
Raw runtime events, question references, root identities, and export receipts
can contain host paths. The network projection exposes opaque handles instead,
without changing the internal references used for verification. Downloads
verify before responding and return the verified captured bytes with fixed
content type, `Content-Disposition: attachment`, `Cache-Control: no-store`, and
`X-Content-Type-Options: nosniff`. No success body streams from a file that has
not yet passed verification. A requested export filename obeys the existing
single-component rules and is never an arbitrary destination path.

An export whose publication succeeded but receipt was lost may leave a complete
file. Recovery can confirm a recorded exclusive destination against the
verified expected bytes before reporting a receipt. Otherwise it reports an
unresolved/conflicting export and never deletes or overwrites the destination
in order to retry. The manager wrapper does not weaken `frontend-export`'s
existing exclusive publication contract.

All manager directories, captures, databases, and diagnostics use private
permissions and retained-root validation. This protects against pathname
replacement within the existing trust model. It is not a sandbox against
arbitrary trusted runner code or another fully compromised process with the
same OS authority. Workspace and engine tools may execute real effects.
Operator profiles and any OS sandbox/container policy must account for that
authority rather than calling uploaded prompts harmless data.

Request, upload, event, history, worker, and storage budgets are enforced both
per credential and globally. A proposed default mutation rate is 30 per minute
per credential with a small burst allowance. Control traffic has reserved
capacity so a saturated submission queue cannot prevent cancellation. Logs
contain operation IDs, timing, categories, sizes, queue depth, and state
transitions, not prompts, answers, reasoning text, hashes of low-entropy secrets,
raw provider responses, or credentials. Content-bearing diagnostics are
separate authorized resources with bounded retention. Terminal output escapes
control sequences, and browser content never treats model output as HTML.

## 9. Client responsibilities and migration

### 9.1 Current and proposed responsibility matrix

| Responsibility | Current TUI | Current Emacs | Inspected Pi source | Proposed service mode |
|---|---|---|---|---|
| Catalogue and setup | Runner discovery and input wizard. | Descriptor completion and native editors. | Catalogue and native setup components. | Manager supplies descriptors/readiness. Clients retain selection, editing, and help presentation. |
| Exact preparation | Separate preview and machine launch. | Same-worker frontend review. | `launchPrepared` uses `FrontendSession.prepare`. | Manager owns the prepared worker. Every client renders the same review and submits explicit approval. |
| Capture and staging | Writes input files and manifests. | Captures transport and invokes shared frontend. | Captures inputs and invokes shared frontend. | Manager receives immutable submissions/captures. Clients choose local source files and upload bytes without exposing local paths as server paths. |
| Processes and ownership | Process groups, control pipe, lease heartbeat. | Session process, TRAMP transport, ownership checks. | `RunSupervisor` and owned children. | Manager owns all service workers. Client disconnection is observation loss only. |
| Runtime projection | Shared Haskell snapshot plus TUI view state. | Lisp event/control ledger. | TypeScript reducer and supervisor state. | Manager uses the shared runtime fold. Clients maintain bounded presentation caches and API revision checks, not a second runtime semantics. |
| Decisions and controls | Mandatory FIFO and controls. | Answer/control editors and correlation. | Decision coordinator and grants. | Manager owns pending state, FIFO, capability checks, and correlation. Clients retain typed editors, consent, and model/user grant boundaries. |
| History, lineage, artifacts | Catalogue/store/observer paths. | Shared IO, history, lineage, verified result views. | Shared helpers plus existing restoration and monitoring. | Manager owns verification and lineage preparation. Clients request links, downloads, and new lineage requests. |
| Native presentation | Brick layout, keyboard focus, output selection. | Buffers, windows, modes, completion, local drafts. | Pi components, widgets, tools, project trust. | These remain client responsibilities. No common renderer or browser UI is required. |

Clients may keep unsubmitted drafts locally, with their own private-storage
policy. Once submitted, they retain only the manager endpoint identity,
resource IDs, revisions, cursor, and presentation state needed to reconnect.
Changing the selected manager endpoint does not retarget old run references.
A manager resource ID from one endpoint is not looked up against another.

### 9.2 Phases, prerequisites, and rollback

1. **Freeze the neutral contracts and fixtures.** Specify the HTTP/OpenAPI
   schema, event format, limits, error categories, and state transitions from
   this record. Identify neutral session codecs that need shared placement,
   full snapshot/query support beyond compact history, and durable capture
   publication. Preserve every existing descriptor/session/protocol/control/
   manifest/store branch. Make invocation-aware v3 lineage an explicit client
   compatibility case, including the inspected Emacs refusal. Service mode
   supplies the trusted invocation centrally rather than copying that omission.
   Add authored input descriptions only through an explicit descriptor extension.
   Arbitrary typed initial inputs require a separate authoring/semantic design
   rather than inferred parsing of text.
2. **Implement manager coordination without exposing a network listener.**
   Build the bounded admission core, database transactions, trusted profile
   adapter, exact prepared worker handling, verified artifacts, and process
   containment. Use deterministic workers and injected failures. This future
   phase is not permission to implement during this research task.
3. **Add the authenticated network boundary.** Verify TLS, token lifecycle,
   resource authorization, strict HTTP parsing, idempotency, replay, and storage
   exhaustion before enabling remote access. Catalogue and observe-only use
   can precede mutation access, but must never imply ownership of local runs.
4. **Migrate one native client at a time.** A proposed sequence is Emacs,
   TUI, then Pi, since Emacs already has native same-worker review and Pi has
   additional host-bound engine targets. This is a sequencing recommendation,
   not an instruction to take over the current Pi lane. Retain each native UI
   while replacing its service-mode process/storage logic with the API adapter.
5. **Prove cross-client operation and coexistence.** Start in one client,
   observe or answer in another, disconnect both, reconnect, and verify output
   and history. Keep explicit local and manager modes until their acceptance
   criteria are met. Remove duplicated service-mode runtime reduction only
   after the new path passes those tests.

Each manager discovers the actual configured runner's capabilities. API version
v1 does not imply frontend v1, protocol v1, or manifest v1. Unsupported native
preparation is a mutation refusal, not a fallback to a different launch with
the old approval. A client that cannot decode the API version fails clearly or
uses an explicitly selected compatible read-only surface.

Existing CLI users and stores remain valid. The recommended initial manager
uses its own private root. An explicitly configured legacy root is exposed
read-only, including foreign live owners and corrupt history entries. There is
no remote `open-root(path)` operation. A future import/copy procedure requires
local authorization, retained descriptors, and lineage validation. Existing
client pruning code must not operate on manager-owned roots. Runtime histories
referenced by lineage are not evicted merely because an event or UI cache aged
out. The first manager has no remote destructive history-pruning endpoint.

Rollback disables new manager admissions and drains or explicitly cancels owned
runs. It restores clients to their explicit local mode without moving ownership
of live workers, rewriting stores, or silently downgrading manifests. Retain
read-only access to manager history and results. Database schema upgrades need
backup/restore and compatibility tests before deployment. Rolling back a binary
is not permission to open an incompatible database with older code.

## 10. Verification obligations

### 10.1 Formal and conformance obligations

The following are prerequisites for a future implementation, not passing tests
of this design document.

| Obligation | Required evidence |
|---|---|
| Per-run preservation | For fixed captured facts, controls, and deterministic engine observations, managed and direct frontend runs have identical authored trace, answers, result code/value, bills, routing/policy fingerprints, and lineage evidence. Compare existing runtime envelopes without manager decoration. |
| Projection refinement | Prove the equations in Section 3 for manager state/history and valid per-run projection. Report exact Lean theorem statements and axiom footprints. Keep physical process/DB correctness outside that proof claim. |
| Admission invariants | Property/state-machine tests establish queue order, reservation bounds, release only after cleanup, and no start without live exact approval. Include several profiles sharing resource keys. |
| Control identity | Test retry, failover, abandon, redirect, both steering timings, typed false/null/structured answers, duplicate IDs, rejected-stale and accepted-to-unsupported transitions, and FIFO reservation release. |
| Existing compatibility | Reuse descriptor, protocol, control, store, input-source, manifest, lineage, and export fixtures. Preserve unknown/null-version refusals and exact invocation matching. Any corpus change requires separate specification review. |
| Input fidelity | Compare literal/transport/file forms, Unicode and CRLF, empty strings, one/multiple final LFs, post-capture source mutation, malformed UTF-8, and JSON/frame bounds. The frontend remains the semantic decoder. |
| Artifact integrity | Test changed roots, symlink/directory substitution, missing/changed bytes, wrong run/type/reference, corrupt journals with valid known artifacts, exclusive export races, and publication with a lost reply. |

### 10.2 Failure, security, and client acceptance

Kill the manager or worker at every boundary between capture publication,
metadata commit, reservation, prepared response, start intent, pipe write,
runtime acknowledgement, event ingestion, terminal artifact creation, export,
and HTTP response. Restart and establish that no approval, command, or effect
is silently recreated. Test a merely flushed runtime journal against a durable
manager receipt and report the different evidence levels honestly.

Exercise duplicate, reordered, partial, malformed, oversized, and wrong-run
frames. Test stream reconnect after a committed event but before network
publication, during snapshot pagination, after retention eviction, and after a
database restore. Slow readers must not block independent runs or exhaust
memory. Disk-full tests must preserve cancellation/cleanup ability without
false durable acknowledgements. Database backup/restore and bounded checkpoint
behavior need operational tests, not just unit tests of a SQL wrapper.

Include the specific interleavings that constrain this design: an answer intent
committed before its pipe write, a lost mutation reply followed by credential
rotation or restoration of an older backup, eviction between two reads of an
open SSE stream, delayed resource responses during a full resnapshot, and a
cross-origin preflight without Authorization followed by an authenticated
request. Verify that Emacs v3 lineage refusal is not mistaken for successful
invocation-aware restoration. These cases must become regression tests of the
future implementation rather than remain prose assertions.

Security tests cover missing/expired/revoked credentials, scope and profile
violations, competing clients, stale preparation/decision generations,
credential rotation, unexpected Host/Origin, CORS preflight, CSRF attempts,
redirects that might forward Authorization to another origin, arbitrary path/
argv/environment injection, upload SSRF/archive attempts, traversal,
compression/depth limits, secret-bearing diagnostics, and terminal/HTML
injection. Clients do not automatically follow cross-origin redirects with
credentials. The proxy/backend trust boundary is tested explicitly.

Run real terminal acceptance at 40×12, 80×24, and 140×36 for the TUI and Emacs,
plus the supported Pi host UI. Cover workflow discovery, all declared inputs,
editing and approval, multiple admitted runs, intermediate output, outstanding
decisions, cancellation, verified results, history, and lineage. Preserve drafts
across resize and reconnect, and verify terminal/window restoration. Add a real
cross-machine TLS test with at least two clients, rather than treating the
existing loopback TRAMP test as remote HTTP acceptance. Verify Linux and macOS
process containment separately. No paid backend is required for these gates.

### 10.3 Operational evidence and completion gates

Observe admission depth/age, preparing and review reservations, active workers,
pending decisions, unresolved commands, cleanup latency, worker-event ingestion
lag, subscriber backlog/disconnects, replay misses, materialized snapshot bytes,
DB commit/checkpoint latency, storage quotas, and artifact verification failures.
Audit records identify credential IDs and transitions without content. Alerts
must distinguish a lost subscriber from a lost supervisor and a pending answer
from an unhealthy process.

Future completion requires the layer-owned deterministic runtime/frontend gates,
new manager contract/security/failure tests, cross-client acceptance, and
documentation checks. The unchanged implementation suites are not a gate for
writing this record. No latency, throughput, cross-machine, or deployment claim
is established by its examples or diagrams.

## 11. Recommendations, costs, and open decisions

The selected design centralizes coordination and trusted supervision while
retaining the runtime's semantic authority. Its principal cost is a new durable
service and HTTP client adapters. Exact approval consumes a reservation while a
human reviews it, and client-independent execution makes the manager host and
its storage a common failure point. SSE reduces transport variation but does
not supply durable replay by itself. SQLite supplies local transactions but
cannot make engine effects transactional.

The following decisions are intentionally left for implementation or deployment
review, with recommended defaults that do not change the semantic boundary:

- Select supported Haskell HTTP/TLS and SQLite bindings from the project's Nix
  environment after compatibility and maintenance review. Do not add an engine
  framework, message broker, or second workflow interpreter.
- Select and test Linux/macOS service containment before allowing unattended
  execution. Do not claim surviving-worker adoption as a first-version feature.
- Confirm operational quotas, review expiry, and content retention with actual
  workloads. The limits in this record are initial proposals, not measured
  capacity. Existing lineage references constrain deletion independently.
- Choose the deployment's certificate, protected network, and credential
  provisioning arrangement before remote enablement. Internet exposure cannot
  rely on a single copied token without the additional boundary in Section 8.
- Decide whether richer authored initial-input metadata is worth a descriptor
  revision now. The first manager can represent all current inputs faithfully
  as required text without delaying typed runtime questions.
- Keep client-bound Pi engines in explicit local mode until an engine connector
  has its own ownership and failure specification. The manager UI API is not
  that connector.

These are not unresolved questions about whether stored paths grant authority,
whether approval survives worker loss, or whether SSE disconnection cancels a
run. Those matters are fixed by this design.

## 12. External sources

Sources W01–W11 were retrieved or rechecked on 2026-09-10. Standards define wire
semantics. OWASP and MDN provide security and client guidance. Queue policy,
quotas, SQLite use, credential scope, and retention are this design's choices,
not requirements attributed to those sources.

| ID | Source and relevant locator |
|---|---|
| W01 | [RFC 9110, HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html), Sections 8.8.3, 9.2.2, 13.1.1, and 15.3.3. Opaque entity tags, idempotent methods, strong If-Match preconditions, and the noncommittal meaning of 202. The [plain-text RFC](https://www.rfc-editor.org/rfc/rfc9110.txt) was used to verify these sections. |
| W02 | [RFC 9457, Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html), Sections 3–5. `application/problem+json`, problem type identity, extension fields, and disclosure considerations. |
| W03 | [WHATWG HTML, Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html), Sections 9.2.2–9.2.7. EventSource constructor, credentials, Last-Event-ID, UTF-8 framing, incomplete events, reconnection, and heartbeat authoring notes. |
| W04 | [RFC 6455, The WebSocket Protocol](https://www.rfc-editor.org/rfc/rfc6455.txt), Sections 1.2 and 5.5.2. Bidirectional message framing and ping/pong. RFC 6455's HTTP/1.1 handshake example is not a claim that every later HTTP version uses the same upgrade mechanism. |
| W05 | [MDN, WebSocket](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket). The browser API's lack of receive-side backpressure is distinct from network TCP flow control. |
| W06 | [RFC 6750, OAuth 2.0 Bearer Token Usage](https://www.rfc-editor.org/rfc/rfc6750.txt), Sections 2.1, 2.3, and 5.3. Authorization-header transport, URL token risks, and TLS/token disclosure considerations. Using bearer syntax here does not imply implementation of an OAuth authorization server. |
| W07 | [SQLite, Write-Ahead Logging](https://sqlite.org/wal.html), Sections 1, 2.2, 2.3, 4, and 6. Local-filesystem requirement, single writer, synchronous FULL versus NORMAL, WAL backup consistency, and checkpoint starvation. |
| W08 | [OWASP, Transport Layer Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html), protocol selection and certificate validation. |
| W09 | [OWASP, REST Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html), HTTPS, per-endpoint authorization, out-of-order workflow execution, input limits, API keys, management endpoints, and safe logging. |
| W10 | [OWASP, WebSocket Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html), Origin validation, authorization, expiry/revocation, limits, and content-safe logging. |
| W11 | [MDN, Cross-Origin Resource Sharing](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS), preflight requests and credentials, exposed response headers, and origin-dependent responses. |
