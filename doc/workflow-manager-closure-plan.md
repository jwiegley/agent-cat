# WM-016 closure plan

This plan implements the user-directed refocus of 2026-09-17. It supersedes
previous next-helper instructions, not the frozen implementation requirements.
The immediate deliverable is accepted, integrated WM-016 functionality. The
remaining WM-017–WM-044 and G1–G5 roadmap follows that milestone.

## Starting position at the 2026-09-17 refocus

WM-001–WM-015 and G0 are accepted. WM-016 is not accepted. Its application
implementation remains isolated, while ten focused macOS SOURCE/RAW owning
lanes support its core decision and control behavior. The existing reconciliation
found a shared-layer compatibility and integration gap, not a demonstrated need
to rewrite those core features.

The Cabal hidden-module regression introduced during supporting work is repaired
and independently cleared. Later fixture-retention work is not the next product
milestone. The L08 leaf review is paused, its isolated work is preserved, and no
further hygiene unit is scheduled.

Authority remains the frozen [implementation plan](research/workflow-manager-implementation-plan.md),
WM-016 and sections 9.1–9.3. Those sections require meaningful behavioral evidence
and existing owning gates. They do not require an independent preparation,
manifest, preservation and review project for every helper.

## Blockers identified at the refocus

| Blocker | Required resolution |
|---|---|
| There is no current integrated WM-016 application baseline. | Reconcile the previously reviewed application delta with current canonical source. Preserve subsequent valid fixes, package boundaries and current tracking rather than overlaying the old source tree. |
| Failure-path ownership and cleanup are not established in the full composition. | Establish whether the corrected candidate still fails a fresh cancellation/cleanup/reservation-release path. Repair actual ownership or terminal-persistence defects together at the existing Worker, ProcessGroup, Store and engine owners. Keep runtime termination, process exit, group cleanup and manager release distinct. |
| Shared protocol, storage and client compatibility are incomplete. | Verify session2/observation3 negotiation, unchanged legacy control behavior, schema7 migration and the cancellation-only extra slot on the integrated implementation. Run the relevant existing runtime, engine and local-client checks. |
| Required end-to-end validation and final integration review are incomplete. | Complete the existing owning matrix on the integrated bytes and obtain one coherent milestone review before closing WM-016. |

The historical `policies-gate-05` failure and quarantined resources remain
unresolved historical evidence. A fresh result must not be relabeled as their
recovery. Historical causal equivalence is not an additional feature to invent
or a reason to signal saved PIDs.

## Consolidated work sequence

### 1. Establish one application integration baseline

Refresh the application delta once against current canonical source. The earlier
review identified 44 application, test and documentation paths, excluding stale
PLAN/handoff snapshots. Merge their intended changes with the subsequent fixes,
including the corrected test-component boundary. Resolve protocol and schema
compatibility as one review concern rather than reopening the settled Store
waiting design.

**Exit:** the exact application changes and their remaining conflicts are known,
with no stale tracking overlay or unrelated source replacement.

### 2. Close the real failure-path work

Use a fresh owned cancellation/cleanup scenario to test the unresolved full-path
question. Retain the original process and worker handles, prove joins where
release depends on them, and preserve ambiguous outcomes without replay. Keep
pre-admission Store waiting within the existing allowance and execute admitted
actions once.

Consolidate any necessary process-owner repairs in the selected Session/export,
worker or ACP paths. Unregistered child handles, unbounded reads before a wait,
and finalizers that replace a primary failure are concrete execution concerns.
Repair them only where they obstruct safe, reliable execution of the required
scenario or gate. Do not convert their surrounding artifact-lifetime inventory
into another sequence of helper projects.

**Exit:** the fresh real path either passes with meaningful failure coverage or
produces a specific product defect and a bounded corrective change. Existing
FIFO, generation, typed-answer and control-correlation requirements remain intact.

### 3. Integrate and run the existing acceptance checks

Land the coherent application delta, then perform the relevant integrated-source
matrix required by section 9.2:

- Execute the runtime, engine and affected TUI Cabal suites, not merely builds.
- Run full policies, examples, routing configuration and deterministic ACP/deck
  checks, including their existing source-boundary and frontend/control probes.
- Retain workflow tier0 and tier1 conformance with the compatible prebuilt oracle,
  plus changed documentation and API checks.
- Obtain current Linux and affected existing local-client/UI compatibility
  evidence using the selected checkouts and authorized environments.

Use the existing gates and ordinary retained command output. Fix the first
meaningful failure at its owner, then rerun its targeted regression and affected
owning gate. Do not restart the full evidence ceremony after each edit. Prior
scoped passes remain useful only for the inputs and behavior they actually cover.

**Exit:** required current-byte checks pass. Any unavailable platform, client or
oracle requirement is reported as a concrete sign-off blocker, not replaced by
more local verification infrastructure.

### 4. Review and accept the milestone

Obtain one independent review of the integrated WM-016 implementation, its actual
results and residual risks. Demonstrate the frozen completion clauses: one answer
per generation, mandatory FIFO across internal submission routes, progress of
another run, unchanged false/null/structured values, exact control correlation,
and delayed/stale/unsupported/failed/unresolved outcomes without unauthorized
replay. Update the issue only when its criteria are met.

**Exit:** WM-016 is accepted on canonical source. This does not automatically
close G1 or implement the later HTTP/service-client, containment or release work.

## Operating limits

No new retention helper, recorder, hash inventory or per-leaf review cycle is
scheduled. A harness change requires a concrete defect that blocks necessary
product validation. Preserve committed useful work and existing failure records
without extending them into new projects.

Fresh native/process-fault runs require their bounded resource and ownership
decisions. Remote/client execution, paid providers, deployment and new Lean/oracle
builds retain their existing authorization limits. No test or frozen criterion
is weakened to obtain completion.

Current progress and the next decisive action are recorded in the
[handoff](workflow-manager-handoff.md). Report product progress, remaining
blockers and the next action rather than artifact comparison counts.
