# Decisions and correlated controls

`Agentic.Manager.State` consumes the existing Runtime projection and verifies person
questions through `readQuestionArtifactSchemaAt` using retained manager roots.
The returned question preserves its observation code and semantic schema. Its
editor schema is supplementary. The complete rendering is retained only when it
belongs to the frozen recursive editor vocabulary. Unsupported constraints make
that entire supplementary field null, without weakening the Runtime schema.
Runtime remains the final answer decoder, including its exact rational-object
representation for structured number controls.

`submitDecisionControl` and `submitRunControl` share one reservation path. Pending
person and recovery decisions are ordered by their opening Runtime sequence within
each run. The global inbox orders those run heads by manager observation order.
A submitting head remains the head. Selecting another run does not affect either
order, and an independent run does not wait for another run's answer.

Both operations use the existing strict JSON token decoder, exact request-body
binding, strong resource ETag, registered-client idempotency ledger and current
transactional authorization. Generation identifies the opening occurrence and
recovery attempt. Output fragments do not change control availability revisions.

## Original ownership

Acceptance requires the original `AcceptedStart` and its actual Worker. A control
view also requires that association, rather than deriving live availability from a
stored supervision label. Before the first Runtime projection the run has no
validated runtime state. The control view then offers no control, allows no
cancellation and names no decision head, and the snapshot view reports a null
runtime. The existing Admission operation bound and retained
CommandAttempt path cover acceptance and lost-return reconciliation. A standard
per-entry gate covers same-run preflight and fresh preparation. Restoration and
question verification hold neither the global Admission gate nor a configuration
lock. Independent entries can prepare concurrently. Exact replay and cheap stale
or capacity refusals do not restore the complete Runtime prefix again.

Commands captures the native frame in the original ticket state before fresh
acceptance. Its successful Reserved-to-Consumed claim atomically transfers that
frame into the original dispatch invocation and clears the retained cell. Losing
claims and cleanup cannot clear a winning invocation's local bytes. Exceptions
cannot restore permission. Admission decodes those original bytes with the shared
control codec and invokes the original `writeWorkerControl`. Cleanup revokes
unattempted permission and drops its payload after the original owner is joined.

Schema seven stores only immutable command, run, decision, generation and address
metadata with frame and effect digest/length bindings. It stores no additional
answer, steering or redirect body. The common command transaction checks the
combined fixed metadata against the unchanged 16384-byte component. Command
reservation C remains 131072 bytes, cancellation reserve remains min(L, 16*C),
and non-content tombstones retain their existing policy. Existing native ingestion
prefixes independently retain unchanged Runtime evidence under their own bounds.

Each captured native frame is at most 1048576 bytes. Admission admits at most
sixteen operations, each with an original JSON request of at most 2097152 bytes.
It retains at most 256 ordinary control tickets per original run. Observation
protocol three additionally reserves one cancellation-only slot, with 257 total
tickets and no extra ordinary slot. Legacy protocols retain their 256 total bound.
Admission holds at most sixteen run reservations. Accepted commands also consume
the existing global ledger quota. Retained unattempted native frames are therefore
bounded by the lesser of 4112 tickets
and the admitted ledger command count. At most sixteen not-yet-accepted operations
can additionally retain their request and native frame. These are logical byte
bounds, not a claim about total Haskell heap usage or SQLite page allocation.

Stored rows, reopened stores, GET results and exact retries cannot recreate the
original payload or ticket. Matching retries return the original receipt without
another dispatch permission. Unresolved controls are never replayed after
supervisor loss.

## Manager log relays

A serving Store lifetime records each control frame as a synchronized `relay`
record before the worker writes it. After `reserveDispatch` commits,
`deliverControlNow` reads the original frame of the reserved ticket through
`reservedPayload`, which does not consume the ticket. It appends a control
relay that names the manager run, the native run, the command and the frame.
`attemptControlDispatch` then keeps the `control_intents` digest and length
check on the original ticket bytes. It decodes the frame from the appended
relay, requires that it keeps the command's control identifier and re-encodes
to the relayed bytes, and writes that control with `writeWorkerControl`. The
worker therefore writes the frame that the log carries, and a lossy codec
reaches the native run.

A cancel relay is a `Reserved` record. When its append fails, the cancel is
dispatched with its original frame and the writer keeps a gap entry, so a user
can always stop spending. Every other control relay is a `Refusing` record. When
its append fails, nothing is dispatched, `recordRefusal` refuses the command
with `storage-unavailable`, `discardControlPayload` clears the ticket, and the
operation returns `storage-unavailable`. The
[admission contract](ADMISSION.md#manager-log-relays) describes the start and
discard relays and the check that covers them.

## Native evidence

Manager acceptance, attempted write, Runtime acknowledgement, effect and terminal
state are separate facts. Accepted, queued, delivered, rejected-stale, unsupported
and failed acknowledgements keep their native identities. Timeout and a lost reply
do not release a decision. A matching native refusal or failed delivery releases
only an uneffected reservation, and the current pending state is checked again.

An exact person-answer Delivered acknowledgement proves typed answer acceptance,
not later occurrence or workflow completion. Retry and failover effects correlate
with `occurrence.retried`. Steering checks the exact attempt and hashes the native
timing/text effect against its original binding. Redirect checks its target binding.
Abandon checks the correlated recovery choice.

## Fail-over and redirect

A fail-over is a `choose-recovery` decision with the choice `failover`. The
Runtime offers that choice only when a later candidate of the question is still
available. The chosen fail-over ends the walk at the current candidate. The run
log then holds a `failure` reply to the `question` of that candidate, and a new
`question` to the next candidate. The effect `recovery-chosen` of the command
correlates with `occurrence.recovery-chosen` and `occurrence.retried`.

A redirect is a run control with the operation `redirect`. Before the first
attempt of a question with more than one candidate target, the Runtime reserves
a dispatch window of at most 30 seconds. While the window is open, the
run-control resource offers `redirect` for the occurrence with its targets. A
redirect inside the window closes it and puts the chosen target first, and the
run log holds a `question` to that target. The effect `redirected` correlates
with `occurrence.redirected` in `events.ndjson`. When the window ends without a
redirect, the Runtime asks the candidates in their authored order.

After the window, the Runtime also accepts a redirect of the attempt in flight
when the question is not an effect and the target is a live candidate that
remains after the current candidate in its approved chain. It stops the attempt
as a run cancel stops it, and the stopped attempt ends with `attempt.failed`
after `occurrence.redirected`. The run log holds a `failure` reply for the
question that names the control, and a new `question` with a new attempt to the
chosen target. The stopped candidate counts against the chain. The Runtime
rejects a redirect of an effect in flight and a redirect to any other target,
and the run continues. The manager offers `redirect` only while the dispatch
window is open. A redirect of an attempt in flight therefore reaches the
Runtime only through the machine control descriptor that `AGENT_CAT_CONTROL_FD`
names.

`RunCancelled` has no causal ControlId in the existing protocol. The manager keeps
its terminal observation and any correlated cancellation acknowledgement, but does
not manufacture a cancelled command effect from temporal proximity, EOF, text or
a previous command. No generic pause, shell command or engine prompt API exists.

## Negotiated steering observations

Frontend session version one retains Runtime protocol two and control protocol two.
Session version two explicitly opts into Runtime observation protocol three, while
controls remain version two. Capability discovery advertises both session versions.
Legacy request, prepared and decision encodings remain unchanged and cannot be
silently upgraded or downgraded within a session.

Runtime protocol three adds `attempt.control-availability` with the exact attempt
address and registered steering-support boolean. Runtime reads the same registration
used by `decideRuntimeControl` and emits the observation after `attempt.started`,
outside the control-state lock. Its version-aware acknowledgement budget permits
256 ordinary IDs and one additional cancel-only ID. The same shared budget is
used for original Manager tickets, including unresolved tickets. Native refusal,
timeout and duplicate acknowledgement do not recycle that additional ID.
Missing legacy evidence is unknown, not support.
The shared snapshot clears live support when the attempt or run finishes. Shared
checkpoint restoration retains the new evidence. A later Accepted-to-Unsupported
race remains legitimate and is resolved by the actual native acknowledgement.

`manager/ci/controls.sh` owns the native N1/N8 checks and compiled mutation controls.
The `controls` mode of `manager/test/service_http.py` sends the same controls
through the running HTTPS manager with the ACP retry and steering fixtures. It
checks that a cancel is acknowledged and ends the run cancelled, that a steer
reaches the effect `steered` and a run-log `steer` record, that a retry through
`/runs/{id}/control` and a `choose-recovery` abandon through `/decisions/{id}`
reach their effects, and that an answer reaches `answer-accepted`. It also
checks the `decision-not-head` and `unsupported-operation` refusals, the
per-run FIFO order, and that two credentials that answer one head decision at
the same time give one delivered answer and one `stale-revision` refusal.
The `controls-routing` mode configures one more profile, whose question has the
ACP retry fixture as its first candidate and the ACP stub fixture as its spare
candidate. It checks that a `choose-recovery` fail-over through
`/decisions/{id}` asks the spare candidate, and that a redirect through
`/runs/{id}/control` inside the dispatch window asks the chosen target. For each
run it reads the run store with `agentic-run flow` and checks the relayed
`control` from the manager, its acknowledgement event and the `question` records
that [Fail-over and redirect](#fail-over-and-redirect) describes. For the redirect it also checks
`occurrence.redirected` in `events.ndjson`.
Fixture barriers delay original work or original control delivery, never invent
successful Runtime envelopes. The steering fixture completes its original prompt
through its normal event loop, including when no steer is delivered. Every fixture
releases barriers and joins its original process owners on exit.
