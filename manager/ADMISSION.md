# Admission and retained reservations

`Agentic.Manager.Admission` supplies the internal WM-013 controller over the
existing Commands, Drafts, Configuration, Store and Worker owners. Enqueue is
explicit, and admission creates a real native preparation without starting it.
The public Manager facade does not expose this controller or new HTTP routes.

## Ownership and admission

`withAdmission` claims one controller registration from the actual Store. This
registration is separate from the sixteen physical Worker registrations. The
controller retains at most sixteen constructing or cleanup jobs, sixteen active
operation continuations and sixteen unresolved acceptance contexts. Queued permits
are bounded by the one-hundred-request queue plus the sixteen retained workers.
Completed worker threads are joined or observed completed before their live
associations are removed. Store closure fences the controller and joins its
operations, timers and original workers without holding process-waiting locks.

`enqueueRequest` uses current Submit authority without reading an Observe-only
public view. Drafts verifies the original declarations, literal chunks, captured
bytes, native input accounting and shared frontend frame. Commands then checks
the exact key, body, URI, ETag, epoch and current policy before committing enqueue.
The request must still have the materialized revision and current catalogue
association. Queue capacity, queue order, request changes, command acceptance and
invalidations commit together. The queue clock uses canonical UInt64 decimal text
and is separate from Runtime and manager event sequences. Release and queue removal
do not reset it, and exhaustion refuses rather than wrapping.

`admitOldest` holds the current configuration through one bounded Store transaction.
It chooses the globally oldest structurally ready, currently enabled selection
whose entire resource footprint is free. A blocked older request does not stop
independent eligible work. The configured execution reservation limit is global,
including retained slots outside a later reduced slot range. Its default is one
and its maximum is sixteen. The transaction reserves the slot and every resource
key before any file wait or native construction, and failed insertion rolls back
all claims. Queue position and blocking reasons remain visible through Drafts.

Classified resource keys declare the complete exclusive footprint. Equal operator
keys conflict, while disjoint keys do not. An empty key list denotes one shared
unclassified cohort, distinct from every operator string. Unclassified work is
serialized with that cohort and can coexist with independently classified work.
The pure policy uses separate resource constructors, and SQLite stores a separate
resource kind in its composite key. No workflow name, executable, directory or
label is interpreted as a resource declaration.

## Accepted work and interrupted returns

Commands retains a narrow opaque `CommandAttempt` before acceptance. Submission
through that context is one-shot, and reconciliation is refused while submission
has not finished. Reconciliation can confirm absence after rollback or recover
only that invocation's accepted association. It checks the same Store lifetime,
authority epoch and exact request binding. It does not search for work to replay,
create a replacement dispatch state, or adopt rows from another lifetime.

An accepted enqueue yields an opaque materialization permit bound to its original
command, request, queue origin, input revision and exact catalogue selection.
The accepted command remains authoritative after credential expiry or revocation.
New client reads and mutations still require current authorization. Lifecycle
revision changes preserve the explicit queue/input association, while editing,
withdrawal and release invalidate it. Current profile and catalogue checks remain
required at admission and protected review use.

The controller registers each operation before it can race closure. Cancelling a
caller abandons its wait rather than cancelling the acceptance continuation.
Only positive acceptance or reconciliation of the same retained context arms
cleanup. Authorized exact retries return the immutable original receipt without
a new continuation, charge, dispatch or event. An exact receipt cannot recreate a
missing enqueue permit after reopen. Historical queued facts remain available
for WM-020 trusted startup reconciliation.

## Native preparation and review

The worker job and reservation are retained before construction can race editing,
withdrawal or shutdown. `withStartingFrontendWorker` loans the actual opaque Worker
during construction, and the ordinary Worker scope is its await-prepared wrapper.
Worker independently enforces its original thirty-second preparation deadline even
when the caller never waits for preparation.

`awaitReview` reports a genuine native prepared observation. The controller stores
its native run and root identities separately in `admission_observations`, without
manufacturing a complete public review, digest, private binding or approval row.
Structural readiness does not imply successful preparation. Failed materialization
can release only after the registered job proves that it never entered native
construction, or after the original Worker confirms joined cleanup.

The pending-review lifetime is ten minutes from the actual native prepared
observation. The deadline uses the live monotonic clock, while persisted wall-clock
fields are display and history. `withAdmissionClock` exposes only the environmental
clock boundary used by deterministic tests. Timers are never reconstructed from
SQLite, and publishing or loaning an observation does not restart its deadline.

`LivePreparation` remains opaque and retains its original worker association.
`withReviewAcceptance` revalidates its live worker, current configuration, exact
input/catalogue association, bound request/reservation revision and monotonic
deadline before a short local approval-acceptance callback. The callback receives
current review facts and a scoped opaque CommitDeadline, not an escaped Worker
or general native write capability.
A later public review publication must preserve the queue/input association and
advance the request and reservation revision together. Returning the callback or
loan does not release capacity.

The [approval owner](APPROVAL.md) constructs complete review and binds the accepted
Approve ticket to original native start delivery. Its transaction is the logical expiry boundary. A timer that
fires after a committed start intent rechecks the durable start-pending/consumed
association and retires rather than invalidating it, even if memory notification
was delayed. Once retired, the original timer stays retired. Approval binds the
original fresh ticket to the same request, reservation, native worker and generation,
retains Commands' reserve/attempt discipline, and writes outside the controller mutex.
The callback must use `submitCommandAttemptWithDeadline` for fresh acceptance.
Its final clock check runs inside Store after bounded transactional work and
invalidations and immediately before COMMIT. This is the logical guarded
acceptance point, rather than the earlier callback entry check. Exact receipt
replay does not reapply fresh eligibility. Clock time can still advance while
SQLite or operating-system commit IO completes, and uncertain commit remains
uncertain rather than permitting re-execution. No accepted-running integration
is inferred from policy assertions. The approval gate supplies actual accepted-running
retention and delayed-delivery evidence.

## Invalidation and release

`editRequestInput` and `withdrawRequest` use the existing Commands transaction and
Drafts representation checks. Queued mutations remove queue position immediately.
An accepted live mutation advances the request revision, invalidates native and
existing public preparation observations, and marks its reservation cleanup-pending.
The live phase and all claims remain until joined cleanup. Another fresh conflicting
mutation refuses during cleanup, and committed start intents cannot be retroactively
edited or withdrawn through these operations.

The same retained Worker receives discard when prepared or joined stop during
construction. Only its confirmed cleanup, or the protected job's confirmed absence
of native construction, enables final publication. Final SQL compares request
revision, reservation, generation and pending command before releasing the original
claims. The final request transition and command effect commit together, while the
original accepted receipt stays unchanged. Expiry returns to draft with an expired
observation reason and never silently enqueues or starts work.

Original terminal-owner persistence uses bounded Store admission rather than
immediate busy refusal. Selection, retained command reconciliation and its
publication, expiry checks, service cleanup transitions, ticket-backed cleanup
coordination and final publication opt in explicitly. Each Store action waits
within its own existing five-second allowance and executes once after admission.
Ordinary enqueue, approval, edit, withdrawal and control acceptance remain
fail-fast. Native outcomes, revision and generation fences are unchanged.

The controller may hold its Admission mutex while waiting for Store admission.
Production Store transaction bodies have no IO lift and do not acquire that
mutex or the configuration/file locks. Production commit clocks read monotonic
time, and prepared-worker checks use nonblocking registry and group observations.
Native dispatch and joins occur outside Store transactions. Store shutdown fences
and joins owners before taking the database cell. This preserves the existing
Admission to configuration to Store order without requiring a holder to wait for
the terminal owner. Artificial test clock barriers do not add a production lock
dependency.

Waiting grants no workflow retry or automatic cleanup recovery. An expired,
interrupted, closed or poisoned admission refuses. An admitted SQL failure or
uncertain publication retains the existing failure and cleanup-versus-release
contract. The no-SQL Worker cleanup path remains available.

`retryAdmissionCleanup` refuses while the original cleanup result is pending,
before joining its task. It can retry publication for the same retained association
without repeating an ambiguous native write or minting a ticket from a receipt.
Later credential revocation does not invalidate already accepted cleanup. Runtime
failure evidence is never cleared to manufacture physical confirmation. Unproven
cleanup keeps the original Worker registration, root, lease and Store fence.

When Store closure or storage failure prevents final SQL publication, the controller
still stops and joins its original workers and reports unresolved persistence.
Durable claims remain for their later reconciliation owner. A fresh controller
refuses unsafe admission when historical reservations belong to another generation.
Neither a process exit, a phase label nor callback success is a release proof or
workflow success.

## Evidence and limits

`manager/ci/admission.sh` builds actual Cabal targets with warnings as errors and
runs N1/N8 property and native lifecycle checks. Tests cover queue and reservation
boundaries, resource domains, independent progress, atomic rollback, reload,
captures, accepted authority, exact retries, review expiry, constructing-worker
cleanup, caller cancellation, Store closure and original-owner release. Migration
checks preserve legacy queue order and resource strings without creating authority.
A protected-entry then expired-final-check regression rolls back source-owned
writes and invalidations, with an unexpired committing control. Compiler controls
reject constructors and Generic instances for ownership tokens.

The isolated completion-failure fixture delegates to the real project-owned signal
operation after the original unreaped leader has exited, then simulates a failed
completion report. It verifies retained claims and lease fencing without skipping
real signalling. This is not a kernel permission-error test, arbitrary-descendant
containment, a power-loss test or the withdrawn SQLite pathname experiment.

The policy properties and static held-claim assertion check supplied occupancy,
not lifecycle transitions or a running state machine. Native pre-start tests are
separate evidence. Actual accepted-running retention is exercised by the WM-014
approval gate rather than by these static policy assertions. The Coordination model supplies the abstract oldest-eligible and exclusive-resource
meaning. These tests do not claim an SQL refinement theorem or infer physical cleanup
from a Lean phase label. The approval owner supplies the accepted-running integration gate,
WM-015 durable ingestion, WM-016 controls, WM-019 broader safety supervision and
WM-020 restart reconciliation. Service and G1 acceptance remain separate.

## Audit regression boundaries

Premature cleanup retry is rejected before joining an active entry. Its regression
cancels the retry caller and exits Admission scope with the controlled review clock
held below expiry. Negative-test teardown advances time only after recording the
old shutdown cycle, and is not counted as successful scope-shutdown evidence.

The deadline regressions rendezvous at the trusted clock's final read while the
bounded source-owned transaction is still active. A coordinator advances time
there, and the expired fresh command rolls back mutation, receipt and invalidations.
The unexpired transaction and exact-replay controls remain distinct.

`manager/ci/admission.sh` also runs a compiled, test-only Commands slice. Its driver
requires exact source anchors and records original hashes and the instrumentation
diff. The sole blocking rendezvous is after a real fresh successful acceptance
transaction and before Submission publication. The coordinator reads the actual
committed command, then interrupts that executing thread. Read-only identity
observations compare the original attempt and dispatch cells through reconciliation
and actual cleanup dispatch. No hook is added to production, no authority is created
from receipt rows, and no SQLite or operating-system call is interposed.

`python3 manager/test/admission_audit.py "$PWD" MODE` also runs the `retry-mutant`,
`deadline-mutant`, `watchdog-mutant`, `policy-mutant` `ticket-mutant` and `termination-mutant` compiled
negative controls. Every copy, diff, build and schedule log remains under the
configured build directory. These are specific guard/identity sensitivity checks,
not a claim that arbitrary fault schedules or WM-014 approved-running transitions
have been proved.

Audit capture uses Cabal's positive source enumeration rather than recursively
copying a checkout. Members must be regular relative paths without traversal,
duplicates or symlink components, and copied bytes are checked against their
captured hashes. The package-boundary regression excludes unlisted sentinel,
cache and symlink content while retaining declared helpers, then rejects a
declared symlink. No ignore blacklist, Git command or canonical-source fallback
supplies the private compiled slice.

## Accepted start ownership

`acceptStartCommand` shares the retained command invocation path and returns an
opaque AcceptedStart only after fresh acceptance or reconciliation of that same
original invocation. Its original ticket and Worker remain with Admission.
Delivery validates the original start association, then reserves and attempts the
same private start outside the mutex and SQL. The original timer checks committed
consumed/start-pending facts without reapplying pre-acceptance expiry to delivery.

The internal owner stop and unexpected accepted-worker exit follow existing
finalization. Claims release only after original cleanup, while accepted consent
remains consumed and lost supervision is separate from Runtime result. This does
not supply the later public control/decision surface or durable ingestion.
