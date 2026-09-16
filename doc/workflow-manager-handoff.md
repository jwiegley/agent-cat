# Workflow-manager handoff

<!-- handoff-id: wm016-20260915; status: resumed-by-user; accepted: WM-001..WM-015,G0 -->

## Status and authority

The user explicitly resumed work and cancelled the pause on 2026-09-15.
Implementation is active, not complete. The frozen acceptance contract and
action-specific restrictions remain unchanged. Native work requires a bounded
next-step decision rather than reuse of an earlier diagnostic authorization.

Refocus completed at `2026-09-16T19:19:23.104601+00:00`. The next deadline is
`2026-09-16T20:19:23.104601+00:00`. Complete instrumented and uninstrumented
source ingestion passed with independent scoped clearance. Raw ingestion has
also passed all 14 outcomes with verified bytes/modes and independent scoped
clearance. The controls evidence analyzer correction is independently cleared.
The first source-controls gate failed with opaque `StorageUnavailable` during
control cleanup. Its preserved snapshot and partial disposition are verified
and independently reviewed, without a proved cause. Bounded private observation
corrections and the parent receiver are independently cleared. One diagnostic
failed because the parent omitted the fixture-directory prelude. A separately
authorized diagnostic with corrected setup returned native exit one and eligible
capture. It records WorkerUnexpectedExit, then StoreBusy during selection and
final action, with cleanup returned. Parent verification passed 1,126 identity
checks, and independent review supports this failed result. A separately
authorized Worker-boundary diagnostic returned native exit one with eligible
capture. It records original ExitFailure 130 before WorkerUnexpectedExit, then
selection StoreBusy. Its preserved Runtime journal records run.cancelled.
Parent verification passed 1,126 checks, and review identifies the deliberate
CLI cancellation-exit path for this invocation. Selection failed before Store
database admission. A separately authorized startup-phase contention regression
passed all 16 assertions, including explicit original-owner recovery. Parent
verification and independent review passed. The user has now approved bounded
internal pre-admission waiting for the original terminal owner's persistence
actions within their existing operation budgets, with admitted execution once.
The isolated implementation compiles and has scoped source clearance. Real Store
checks passed at N1/N8, with startup and protected publication checks passed at
N1. The N1 cancellation case failed at a private coordinator rendezvous. Its raw
failure is preserved, and a source-proved holder-supervision defect is being
corrected in a fresh private overlay. No further native execution, old-resource
recovery or acceptance is authorized.

The accepted implementation ends at `7b88f17263b32eb2e222d952ebac88fb972c4f04`.
WM-001 through WM-015 and G0 are accepted, which is 15 of 44 packages and one of
six gates. WM-016 remains unaccepted. WM-017 through WM-044 and G1 through G5
remain unfinished. The branch retains the accepted implementation as its active
source. Unaccepted work is committed as a portable recovery checkpoint rather
than installed as accepted functionality.

The architectural authority remains the frozen
[design](research/workflow-manager.md),
[implementation plan](research/workflow-manager-implementation-plan.md), and
[storage amendment](research/workflow-manager-storage-amendment.md). Current
tracking and the compact resumption record are in `doc/PLAN.org`, issue
`acat-wm-016-bsw2`. The complete earlier issue notes remain in the recovery bundle
at `halt-20260915/wm016-issue.json`.

## What is preserved

The accepted source includes trusted profiles, bounded private SQLite storage,
immutable receipts and exact retry binding, drafts and captures, original native
Worker ownership, admission/resource reservations, exact preparation and approval,
and validated native evidence ingestion/restoration. The mathematical result is
an abstract coordination/refinement model with its recorded assumptions, not a
proof of arbitrary SQLite, HTTP, operating-system containment, or provider effects.
The existing local clients remain supported. No manager HTTP service or complete
service-mode client release is claimed.

The [WM-016 checkpoint](checkpoints/wm016-20260915/README.md) preserves:

- `candidate.patch`, containing the 38-path unaccepted candidate against the
  accepted baseline. Its positive Cabal source set contains 588 files.
- `failure-correction.patch`, containing the later test-only correction to
  failure classification and diagnostic reporting.
- `recovery.tar.gz`, containing 82,790 file records deduplicated into 1,495 blobs.
  It includes current source, available historical positive audit sources,
  diagnostic helpers, reviews, command and executable identities, logs, the
  original failed fixture database with WAL/SHM, and all three diagnostic runs.
- `checkpoint.json` and `recover.py`, providing exact archive/patch identities
  and verification/restoration without executing captured content.

The archive is about 11 MB compressed and restores about 623 MB of file data.
Large compiler outputs, build/package caches, agent sessions, private homes,
unrelated repositories, and older accepted-package local evidence outside this
WM-016 workspace are not included. Historical executable hashes remain recorded,
but their large executable files must not be assumed available on another machine.
Rebuild and verify before making new execution claims. Five deliberately isolated
historical package-boundary source paths were unavailable to the packer. The
manifest records those omissions and the excluded compiled data-test executable.
The current candidate and correction sources are complete.

## WM-016 candidate and verification ceiling

The candidate implements shared decision/FIFO reservation, typed Runtime controls,
original-live payload retention, correlated acknowledgements/effects, current
control authorization against fixed captured Worker facts, and per-Entry control
preparation serialization. Session 2 explicitly selects observation protocol 3
while controls remain version 2 and legacy behavior remains intact. Version 3
preserves 256 ordinary control IDs plus one additional cancellation slot.
Unsupported supplementary editor schemas use the frozen nullable field rather
than weakened schemas or another value decoder.

Earlier source and raw-archive all-target warning-fatal builds and all three
suites passed for archive
`333fc94d274f55363c33a0909caeb00b5307b955de524d95bd49540dd0cca328`.
The sealed candidate archive
`afecaf6f6fe97a1f3322d31011747131da8d6a6d3680dc04edc54914d6753ecc`
contains later test changes and does not have complete final validation. The
subsequent correction is another source version. Component passes cannot be
combined into a current-byte whole-gate pass.

Full policies runs 01 through 05 and raw-controls run 01 failed at different
stages. Earlier failures included stale capability assertions, invalidation-count
scope, fixture numeric encoding, and fail-fast observation contention. The
recurring observation pattern was reassessed, not treated as three identical
blind retries. All failed logs and their changed inputs are retained.

The final material blocker is `policies-gate-05`:

- A genuine second-run answer succeeded while the first run remained pending.
- Cleanup then reported `WorkerCleanupUnproven`.
- The second native journal ends with `run.completed` at sequence 18. Its
  original external process exit and per-group failure cause were not captured.
- The first reservation released. The second run and reservation remained
  `cleanup-pending`, confirmed by the parent from a separate read-working copy
  of the preserved database and WAL. The original database was not modified.
- Later process absence and backend markers do not establish original cleanup
  proof. No stored PID was used to signal or reconstruct ownership.

Independent review `86768f3d-66ac-4078-8e98-603059bf2310` returned **BLOCK**. It
established no ProcessGroup algorithm defect or additional control-acceptance
defect in the inspected seams. It did establish that test helpers converted broad
`StorageUnavailable` into `StoreBusy` or called it publication contention, and
that one analysis note named the wrong Worker classification. A general unmatched
IOException maps to `WorkerUnexpectedExit`, not `WorkerUnavailable`.

The correction removes opaque retries, preserves directly observed StoreBusy,
and records failure provenance. Its compile-only audit captures the first failed
proof at the actual Store release/fencing boundary from that call's original
outcome cells. Normal live Missing observations do not occupy the reserved slot.
Logging catches IOException rather than swallowing interruption or timeout.
Twenty-four data assertions passed at each of N1 and N8, and the C recorder's
bounded behavior passed a data-only test.

Before the pause, three separately authorized diagnostics passed without
reproducing the original failure. Two belong to the original author, including a changed-order
natural-exit observation. The latest correction run preserved the original stop
order and completed with four Store-owned groups confirmed, empty first-failure
records, 162 Haskell records and 242 C records, and no overflow or logging failure.
It exercised the real EPERM zombie-leader guard without changing it. These are
**non-reproductions, not a resolution** of the original failure.

The last pre-pause native diagnostic used these checker and frontend hashes:
`77c92448e5bad3022281eb7137f7b63d61e990a714da55f42ecc5a31c774e577`
and `1757f0f1df301cf3666b3b6c125bfefba6cf099616c5fc75c55dedf063a80677`.
Current full source/raw owning gates, Linux, final canonical/Pi verification,
committed-work audit, and WM-016 acceptance remain outstanding.

## Resume in a fresh session

Read this document, issue `acat-wm-016-bsw2`, the three frozen records, the
checkpoint README, and the complete independent review before changing code.
The external remaining-scope report is
`~/dl/agent-cat-workflow-manager-remaining-2026-09-15.md`. It can be regenerated
from the frozen plan and this checkpoint if it is not on the new machine.

Use Python 3.11 or newer from the supported Nix environment. Verify and restore
evidence from the repository root:

```bash
python3 doc/checkpoints/wm016-20260915/recover.py \
  doc/checkpoints/wm016-20260915/recovery.tar.gz
mkdir -p "$HOME/Products/agent-cat-resume"
python3 doc/checkpoints/wm016-20260915/recover.py \
  doc/checkpoints/wm016-20260915/recovery.tar.gz \
  --destination "$HOME/Products/agent-cat-resume/wm016-evidence"
```

The destination must not already exist. Restoration creates files only. It does
not execute scripts, restore live authority, signal processes, or open databases.
Retained absolute paths identify the original machine. Map the original root in
`checkpoint.json` to the restored directory when reading evidence. Adapt helper
paths only in a new working copy, never in the preserved evidence.

Prepare a new source worktree without disturbing the accepted checkout:

```bash
repo=$(pwd)
work="$HOME/Products/agent-cat-resume/wm016-work"
git worktree add --detach "$work" 7b88f17263b32eb2e222d952ebac88fb972c4f04
git -C "$work" apply --check "$repo/doc/checkpoints/wm016-20260915/candidate.patch"
git -C "$work" apply "$repo/doc/checkpoints/wm016-20260915/candidate.patch"
git -C "$work" apply --check "$repo/doc/checkpoints/wm016-20260915/failure-correction.patch"
git -C "$work" apply "$repo/doc/checkpoints/wm016-20260915/failure-correction.patch"
```

Only the parent/integrator runs Git. Read source inventories and compare the
materialized files and modes. The current correction differs from the sealed
candidate only in `cli/test/ManagerApprovalProbe.hs`. The compile-only diagnostic
sources are under restored `failure-correction.suwgl8b7/audit-source` and must not
be installed as production code.

Use the canonical Nix shell, private build/home/tmp/config directories under
Products, and unchanged `test/cabal.sh`. Create a repository-free Cabal config
with `active-repositories: :none`. Reconfirm tool versions and compile the fresh
baseline before edits. Inspect tests before running them. Compilation and
previously permitted data-only checks form the initial resumed baseline. Any
further native reproduction or full gate needs a fresh explicit decision covering
its inputs, original owners, budgets, first-failure capture, and stopping rule.

For a new clone, initialize/import the `obr` cache according to `AGENTS.md`.
Do not rebuild or replace an existing unrelated tracker cache. Keep WM-016 open.
Recheck the clock and perform the `refocus` check on explicit resumption.

The next technical step is to finish and review the private prefix diagnostic
described below, then make a separate bounded execution decision. Do not repeat
a whole policy run merely to obtain green. Preserve missing, failed, and
confirmed group outcomes, the first failure, and primary/cleanup exceptions.
Current-byte full source/raw/platform/client/doc evidence and independent
acceptance remain necessary before integration or dependent WM-017 work.
At the end of **every downstream subtask**, run the `fess` skill, verify its
findings, and record the evidence before marking that subtask complete.

## Local identities and standing restrictions

The original local workspace was
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/controls.qzldrova`.
The original author is sealed. Correction workspace `failure-correction.suwgl8b7`
was interrupted after its authorized native run. The prior worker remains
stopped and is not being revived. The fresh resumed workspace is
`resume-20260915.ZHiqa0SO` under the original local workspace. Its `source/` was
reconstructed from the accepted baseline and both checkpoint patches, with all
588 positive source files verified by digest, size, and mode. Old evidence is
read-only.

Workflow `ea331f14-b7bf-4e91-bc75-a4a09e1cf606` completed fresh compilation with
tests enabled and GHC warnings treated as errors, plus the offline contract
probe. The build exited zero after 470.116116 seconds. The probe checked 99
schemas, 29 operations, 327 payload cases, 20 SSE cases, and three byte-bound
downloads. Its 22 compiled executables were not run. All 1,005 source files
remained unchanged. The parent verified the 588 checkpoint source records and
the other 417 files against the accepted Git tree, then checked 1,198 artifact
records covering 1,176 unique paths. This does not establish native acceptance.

Fresh reviewer isolation probe `9fd10854-1df7-48a7-8f03-a246cb627a21` passed.
Review `f6a3052a-84d8-4bf2-ae6a-348f21829909` cleared the diagnostic/retry
correction and recommended testing the untested same-process ingestion prefix.
Its full report and parent verification are under `resume-parent.zTEX65dI`.
No retained reviewer was available, so the review used a verified fresh fallback.

The new preparation namespace is `prefix-diagnostic.fpfRbnrI`. It must preserve
the existing observer, framed maximum/overflow, native ingestion/reopen,
association cleanup, and native decision fixtures before the first
non-interrupted pair, with whole-prefix post-unwind capture. Existing fixture
assertions, owners, order, cleanup, capacities, and deadlines remain unchanged.
Preparation and data checks are authorized, not native execution.

Preparation worker `d861d8e7-101a-44c3-98ae-414d39ccb7ae` detached for supervisor
questions and later reached the harness 30-minute timeout. After inspecting
partial files, the parent revived the same author as
`f684c7c8-02fa-456f-b609-058da3d72eb4`. Revival completed the handback without
changing source/binaries or repeating successful checks. No active writer remains.
The timeout was an orchestration failure, not an application test result.

Current generated source is `prefix-diagnostic.fpfRbnrI/audit-source-v4`. The
unversioned `audit-source` is preserved v1 evidence. The parent verified 2,104
artifact comparisons, including 588 immutable production inputs, 592 generated
files and their deterministic replica, 321 evidence files, and three binaries.
Current data checks passed 24 original assertions and 34 synthetic prefix
assertions at each of N1 and N8, with two meaningful failing negative controls.
Source inspection found the capture gaps before those regressions were added.

Private capture now checks between the framed scenarios, flushes after the
complete diagnostic tail, and requires one publication event per tracked group.
Normal dispatch, original fixture bodies, and production inputs remain unchanged.
Earlier rejected boundary captures cannot be validated by a later complete file.
The successful source path requires seven of 16 owners and 28 of 64 tracked
groups. Dynamic event-slot sufficiency is not promised, and overflow is inconclusive.

Independent preparation review `01df0736-4702-4528-af56-f4ceb4b7e15e` completed
with **OK with notes**, without execution authorization. One P2 finding requires
a file/memory count-and-tail comparison after the combined primary failure and
checked-flush refusal. The existing test checked only exception precedence.
The same author completed that one-assertion correction in
`prefix-tail-fix.HbgBun4G`. The parent verified 1,885 artifact comparisons, exact
one-line helper/generated-code delta, deterministic regeneration, 24 original
and 35 prefix data assertions at each of N1 and N8, and two failing negative
controls. No new independent re-review is claimed for this review-only fix.
The reviewed v4 namespace remains read-only.

The current handback is `resume-parent.zTEX65dI/prefix-workflow-result.prefix-prepare.md`.
Its preceding handback remains in `prefix-tail-fix.HbgBun4G/artifacts/handback-before-tail-fix.md`.
Prepared manifests remain explicitly not-executed records and are not authority.
The parent separately authorized one invocation at
`2026-09-16T00:45:25.542815+00:00`, recorded in
`resume-parent.zTEX65dI/native-prefix-authorization.json`.

Run `8947b749-9f31-4aaf-9cd5-f2a55775a810` completed its one authorized N1
invocation from `00:49:11.239659` to `00:49:18.854329` UTC, with exit zero.
All 16 boundary captures and the final capture were complete and prefixes of
the final history. They contain 1,571 Haskell and 489 C records, 28 original
tracked groups, seven owners, and no failed confirmation or capture overflow.
All groups published confirmed outcomes, including four nonzero exits. The 28
raw KILL/EPERM returns each have matching evidence for the unchanged Darwin guard.
These are this run's original-token observations, not historical cleanup proof.

The parent verified 879 identities and all 17 captures, including 121 preserved
run files and five command/log records. Six databases and 14 Runtime journals
were copied as raw bytes. WAL/SHM sidecars were absent after return and no database
was opened during preservation or analysis. Evidence is under
`prefix-tail-fix.HbgBun4G/artifacts/native-prefix-01*`, with the parent's
`resume-parent.zTEX65dI/native-prefix-parent-verification.json`.

This is a fourth diagnostic non-reproduction. The original failed fixture and
its quarantined reservation remain untouched. The authorization is consumed,
and a saved decision record cannot authorize another launch. Independent review
`366c030c-a80c-4826-9dae-0d043418927a` accepted the result interpretation with
stated limits and found no new execution defects. It distinguishes historical
quarantine disposition from prospective verification on independent resources.
Operator action is required to reuse affected quarantine, not merely to collect
evidence on actually disjoint resources. Package acceptance remains blocked by
the incomplete current-byte verification matrix.

The next gate target is complete `manager/ci/ingestion.sh`, including N1, N8,
interrupted and later cases, vectors, and all six existing helper modes.
Preparation in `ingestion-gate-prep.jhjMS3l4` is complete. Current candidates are
`audit-source-v3` and `candidate-source`, with evidence under `artifacts/final-v3`.
Only the owning Python helper differs in the 1,005-file source candidate.
The parent verified 5,190 identities and the 589 instrumented versus 588 source
Cabal list-only members. This is not raw-archive or full-gate execution.

Independent review `7f9d50b2-bb19-4bf5-8ce5-f63a13f22a2c` found no issues and
cleared preparation with stated limits. It supports the source/configuration
resource separation, preserved 14 checker invocations and fixed capture bounds.
The parent separately checked seven old mutable paths and five new roots.
Both lanes share outer home/tmp/config and must be sequential. Unresolved work
prohibits their reuse without disposition. Only the instrumented lane is now
authorized by the separate decision recorded below.

Source inspection found an owning CI-helper defect: `admission_audit.py` uses
`subprocess.run` with 120-second checker and 1,200-second build timeouts. Installed
CPython kills the child on timeout or interruption before propagating the error.
The reviewed candidate corrects that owning helper while retaining execution
deadlines and original Popen ownership. It accounts for status-I/O time, defers
secondary interruption only with a primary, preserves separate failure facts,
and stops without signalling when wait ownership is uncertain. Twelve synthetic
supervision cases pass. These do not prove real signal delivery or joining.

The three authorized controlled live-supervision cases in
`live-supervision.evIZ0aBc` passed once from 04:15:34 to 04:15:36 UTC. Original
handles and fixture-owned descendants were joined. Success returned zero,
timeout retained its first exception despite child exit zero, and interruption
retained its first exception while a second was deferred during held cleanup.
The parent verified 67 manifested files and the status/event/object-identity
evidence. These are disposable-child mechanics, not manager-gate or historical
cleanup proof.

The parent integrated the exact reviewed `run()` function and its imports into
canonical `manager/test/admission_audit.py`, without importing WM-016-specific
modes. The portable regression is `manager/ci/supervision.sh`, with three scripts
under `manager/test/supervision/` and explicit Cabal source entries. Independent
source review `5e521030-c061-4e2c-897f-e0ac39284f84` found no issues. The portable
command then passed its three cases from 04:49:00 to 04:49:02 UTC, with all six
source hashes unchanged and parent-verified results. Evidence is under
`helper-integration.qC6vWWdV`. Existing ingestion gate bytes remain unchanged.
Commit `fa186851dc76f4253bf460ea0de9ef04820cd7c8` preserves that fix and regression.
Committed-work fess `5144160a-bd65-4e90-b55d-d071f5d60fb3` found no issues.

The first gate recorder, `gate-instrumented-01`, failed before spawn because it
required an old configured XDG path to exist. It launched zero checkers. That
failure is preserved, and no historical path was created or changed. The parent
corrected only preflight in `gate-instrumented-02`, retaining resolved potential
footprints even when absent. Six data checks cover absent paths, overlap, aliases
and permission errors. This does not treat absence as cleanup proof.

Run `002e93ce-83c2-4e5d-a6c5-1cf9bdcb26bc` completed its one actual gate invocation
from 05:29:30.620758 to 05:46:51.856574 UTC, with exit zero and original outer
handle joined. All 14 checker invocations passed their required predicates,
including ten intended negative exits. All 86 captures were verified, with 116
confirmed original group publications and no capture faults. The parent performed
15,386 identity comparisons, checked every history prefix and outcome, and
verified six variant hash chains. Raw preservation includes 4,092 entries, 28
databases and 52 Runtime journals plus two wrapper logs. No database API was used.

Independent result review `42856e78-1b40-488d-bba1-046e1f85bf1e` found no issues
and accepted this scoped instrumented result. It is not uninstrumented, raw,
platform or package acceptance. Two parent-verifier data-shape assumptions were
corrected with failure records retained, and were not application failures.
The 06:21 refocus missed its previous deadline during gate/post-return work.
Subsequent execution authorizations reset the clock explicitly and require an
immediate gate-exit progress event before lengthy preservation analysis.

For later uninstrumented verification, `current-source.jJwlsNm8` combines the
corrected 38-path WM-016 candidate with canonical commit `fa186851` and the four
portable regression files. Pure packaging verified 592 source/raw member bytes.
Archive SHA256 is
`79bede955e86e7759c4201a54a7b1fe5c3e22dc8e3f0bf34b1b03a181f6d7651`.
Its 12 source/raw mode differences remain unchanged. Source and raw verification
have separate private build/home/tmp/config roots. Source attempt-01 failed
before spawn because its recorder equated the complete checkout with the
positive package list. The parent verified all 1,019 files against canonical
Git origin plus the approved overlay, including 427 legitimate non-package
files. No source was removed or changed. Corrected attempt-02 checks the full
tree and the 592 package members separately. Its entire read-only preflight
was executed successfully before any record or spawn.

Run `7c640c36-c26e-41e5-a4ba-0d6724753a82` completed its one actual source gate
from 07:01:19.385939 to 07:29:53.159673 UTC, with exit zero, original gate handle
joined, and no outer primary/wait failure. The parent read that completion on
the immediate exit notice before preservation/analysis. Parent verification
checked 17,407 identities, all 14 outcomes and markers, six mutation chains,
4,026 preserved entries, 28 databases and public lifecycle assertions. No private
recorder telemetry was present or borrowed. Independent result review
`93479663-030f-4efe-8c46-ee7e1f0ec4e4` found no issues and supports a separate
raw decision, not raw or package acceptance.

The parent prepared `raw-verification/attempt-01` and successfully evaluated
its complete read-only preflight before any record or spawn. It checks exact
592-member raw bytes/modes, the immutable archive and actual resource separation.
Run `22c838ca-6b3d-4036-ac76-7b7f355965cb` completed its one raw gate from
07:56:26.099419 to 08:17:31.728822 UTC, with exit zero, original gate joined, and
no outer primary/wait failure or deferred interruption. The parent read completion
on the immediate exit notice, before preservation. The parent verified 17,408
identities, 4,026 preserved entries, all 14 outcomes/markers, six variant chains,
28 databases, 592 raw modes and the immutable archive. All 12 mode differences
remain unchanged. Independent result review
`9b697149-e2f5-44f5-a6b2-d446ea754806` found no issues, with stated evidence limits.
No private telemetry or historical cleanup proof is claimed.

The next source-controls prerequisite is preservation/analysis for its distinct
layout: 38 checkers, 22 positive and 16 intended-negative outcomes, six public
contract validations and 13 helper builds. Preparation run
`38fdd173-c848-4fa7-9a86-e27e77940ca7` completed data-only checks under
`current-source.jJwlsNm8/controls-source-verification/preparation`. The parent
verified 1,667 identities. Independent reviewer
`fa14e0dc-2fc0-477e-b57d-aedecbc89f1f` blocked the preparation because its analyzer
could claim complete evidence without a preserved helper N1 or N8 directory.
The original synthetic checks covered root selection rather than this analyzer
refusal. No controls gate had run.

Correction run `6520bec3-427a-4872-b9c4-69e8ab94d0fc` added one assertion in
`current-source.jJwlsNm8/controls-source-verification/preparation-v2`. Actual
analyzer regressions demonstrated both old false acceptances and corrected
refusals, with a complete-data positive check. Parent verification passed 1,690
identity comparisons. Reviewer `4eafa11b-3dbe-477e-b067-0694c8981b66` found no issues
and cleared the preparation correction only. The original preparation, blocked
review, application sources, archive and parent launchers remain unchanged.

Fresh checks compared 17 old resource footprints against five new roots, with
an empty controls build directory and absent cache. The exact read-only launcher
preflight passed before any native spawn. The parent then authorized run
`e1f5b003-07a5-4c39-8c2c-8905cbd05f49` for one complete source-controls gate through
the existing `controls-source-verification/attempt-01/execute.py`. Its only
post-return work is the reviewed raw preservation and partial analysis. This
first gate failed with exit one from 09:50:26.259136 to 09:53:19.374411 UTC, after
173.115 seconds. The original outer gate handle joined without outer failure or
interruption. The first available public refusal was
`control cleanup (no retry) public refusal (cause opaque): StorageUnavailable`,
followed by `manager-approval-check: StorageUnavailable`. It followed saturation
assertions in stdout. No contention or relationship to the historical incident
is inferred. Only `controls.eqILIg` was created, with no helper variant roots.

The parent inspected the original exit record before preservation. All further
execution stopped, and the failed resources cannot be reused. The exact reviewed
preservation and partial analysis completed. Parent verification passed 2,549
identity comparisons over 159 raw entries, nine databases, 18 Runtime journals,
two executables, source/raw members, archive and modes. No WAL/SHM was present
and no SQLite API was used. Three N1 checkers completed, saturation failed, and
two contract calls produced 14 and four resource outputs. No N8 or helper run
is claimed.

Read-only review `2c1beee8-9a23-4a70-8569-447a5d9b1a0c` supports this disposition
and found no preservation defect. It identifies information lost before the
public cleanup refusal, but the records do not establish whether those hidden
branches occurred. Same-key submission replay supplies no new dispatch authority
and is not a cleanup retry. The preserved Runtime journal records accepted
cancellation and `run.cancelled` at sequence 779. Neither that event nor outer
gate exit proves Manager finalization or native cleanup.

Preparation run `4945d86e-e986-4480-b872-0eedff520cd0` owns only
`controls-failure-prep.oTZCvtjN`. It may instrument a fresh source copy, compile
the needed targets offline and run data-only checks. Bounded private records
must distinguish first submission refusal, drain outcome, stop guard/action/result
and original entry selection, cleanup and finalization outcomes while preserving
public opacity, original failure precedence, ownership and budgets. No new
capture framework or speculative deeper hooks are authorized. Build one failed
under Werror because the private module lacked a checker other-modules entry.
That preparation failure is retained.

The proposed digest receipt is supplementary. Publication can create the entire
receipt and then throw, leaving external files insufficient to establish the
publication return when the native primary exception takes precedence. The
parent requested a bounded blocked handback with an explicit red data control
for this case, not another completion channel or an expanded publication
protocol. That preparation completed with 22 boundary assertions per N1/N8,
six passing current data runs and two expected publication reds. Parent
verification passed 4,683 identity comparisons across the exact four-path patch,
baseline, deterministic generated replicas, binaries and raw/archive inputs.

Reviewer `5d1bde98-8690-4bfd-9e69-0a1fcdade7df` found a separate P1: the fixture's
two bare async submission callers can outlive an exceptional wait, and Admission
shutdown does not join those enclosing threads. Capture completeness must not
assume they are settled. This is not a diagnosed cause of the native failure.
The review also distinguished preceding validated capture facts from publication
return and rejected a universal requirement to prove every reporting write.

Preparation-only run `d53b9d93-d18d-474d-8d64-f8971dc1eada` completed under
`controls-observation-fix.R4JRrPtF`. Its current `audit-source-v2` has conservative
caller-settlement eligibility and a bounded settled-flush report. Parent
verification passed 6,736 identities, with 41 positive assertions per N1/N8 and
two retained file-only reds. A report-schema rejection was corrected without
code changes or test reruns. Independent correction review
`55ef50b5-e718-4b0a-90b3-8b95d9d52c71` found no issues. The actual Python parent
receiver passed 30 data checks and review
`a1c52cda-c18a-44f3-9cf9-f46f7db73959`. Received status is not native cleanup proof.

The first one-shot diagnostic, `d04b7ef9-2d7d-4427-8dbf-dc8145c3c743`, ran under
`controls-boundary-native.nxDtUJw9` and failed in 0.170422 seconds because the
parent omitted the original gate's fixture-directory creation. It failed before
runner setup and produced no capture. The attempt remains consumed and retained
with 1,079 parent integrity checks. This setup failure does not explain the
original StorageUnavailable refusal.

Review `fb9cb0b3-4d5f-4661-9782-bc01dd05922b` cleared the minimal correction: a
fresh exclusive empty work directory checked before launch. Separately authorized
run `7cd600da-edf7-435e-8db8-8a4843ee9c4b` used
`controls-boundary-native-02.GkjxSMoY` without source, fixture or budget changes.
It returned native exit one after 41.555732 seconds, with both original handles
joined. Raw preservation retained 47 entries and 29 regular files. The reviewed
receiver returned exit zero with exact fresh scope and three input hash matches.

The eligible 26-record capture observes WorkerUnexpectedExit before entry
classification and in the discarded drain, then StoreBusy at original selection
and final-action result. Original cleanup returned, classification produced
StorageUnavailable, and stop observed that entry result. Both original callers
settled, with no capture fault or recorded first submission refusal. These facts
do not establish deeper worker cause, release or equivalence with prior failures.
Parent verification passed 1,126 identity comparisons. Read-only review
`0aa6accf-5f1e-4949-9f19-3dc56b1bb3fe` supports the failed result and locates this
public refusal at retained selection StoreBusy. Finalization was not reached.
Given this established Worker, returned original closeWorker entails passing the
retained group-outcome cleanup check. It does not establish reservation release,
lease/root closure, escaped-descendant containment or reuse authority.

WorkerUnexpectedExit was ambiguous between non-success original exit, premature
EOF and otherwise-unclassified exception. Preparation run
`7e0acf63-fd0d-455a-acb2-53cd2d9a9373` under `worker-boundary-prep.16u1FQxm` added
only bounded observations at those existing reductions, including first failed
send before its separate classify call. Parent verification passed 6,731
identities and 57 data assertions per N1/N8. The initial wrong test expectation
for UserInterrupt rendering remains retained. Independent review
`3a1b5069-9ee4-4b67-b1f8-1bcf4f664f35` cleared the preparation.

Fresh `worker-boundary-native.Nj49DR3k` passed exact preflight with 30 old resource
exclusions and the original empty fixture-directory prelude. Separately authorized
run `6307d3f1-38d1-4535-92e7-0d6c0dc5149c` returned exit one after 43.625212 seconds.
Both original handles joined, raw preservation preceded interpretation, and the
reviewed receiver returned eligible-capture with exact bindings. Parent verified
1,126 identities over 47 entries, 29 regular files and all bound records.

The 28-event capture observes original ExitFailure 130, then supervisor
WorkerUnexpectedExit, followed by selection/final-action StoreBusy and stop's
entry-result StorageUnavailable. No EOF or first-send failure marker appears.
The journal ends with run.cancelled at sequence 779. The CLI has explicit
MachineCancelled handlers that emit RunCancelled then throw ExitFailure 130.
Read-only review `6bb9c3b3-1f63-43bd-b47b-9a9404622673` identifies this selected
prepared-frontend cancellation path without inferring an OS signal or relabelling
cancellation as success. Further broad Worker-cause diagnostics are unnecessary.
The remaining StoreBusy is pre-transaction in-process gate refusal, not a proved
SQLite/OS failure. Selection failure skips finalization and reservation release.
Existing publication-failure tests require explicit original-owner recovery,
rather than automatically retrying opaque failures.

Preparation run `8a2f4110-f7b2-4668-bb80-b2d2606c44bc` completed under
`selection-contention-prep.VByl47hE`. Parent verification passed 4,682 identities,
with protected Store admission, selection/finalization, explicit recovery and
publication-failure test bodies unchanged. Six pure barrier assertions passed
per N1/N8. A first NFData SQLData test-typing failure remains retained. Review
`ab8d7aee-8635-49d7-aad1-d2963145f9b2` cleared the standalone regression preparation.

Separately authorized run `896c90fc-9bbe-4a1a-92d0-f3024fcefe18` used fresh
`selection-contention-native.iepK6AJg` and returned exit zero after 1.733511 seconds
at N1, with both original handles joined. Raw preservation retained 23 entries
and 15 regular files before interpretation. Parent verification passed 1,089
identities and all 16 exact source-bound assertion matches. The test established
pre-transaction StoreBusy, retained failure/claims without fabricated effects or
release, then explicit recovery on its fresh original LivePreparation. It does
not cover post-start cancellation 130, N8 or the publication comparison.

Review `45737ef0-195b-4188-8dc5-48fd9b2da0c4` found no issues with that scoped result.
The user subsequently approved bounded internal waiting only before admission of
the original terminal owner's identified Store actions, charged against their
existing execution allowances. Admitted actions execute once, with lock-order
safety, original authority/fences/native outcomes, unchanged rollback and SQLite
busy bounds, and explicit failure on timeout, shutdown, poisoning or admitted
and uncertain persistence failure. No opaque-result, whole-workflow, command or
cleanup retry is implied. Ordinary callers retain immediate refusal.

Workflow `75dbb5d8-baf1-4bf5-a100-4b52fda16a30` produced the policy implementation
under `terminal-admission-wait.NYcHOsPx`. Production and private targets compiled
with warnings fatal, and 17 no-Store assertions passed per N1/N8. Parent verified
5,124 identities and exact diffs. The production documentation gate passed.

Review `2f12639e-e4ac-4c66-999c-688756a93045` found an unintended private aggregate
timeout. Correction `a474d6c7-e7a8-4294-a81b-df38e72733c6` under
`terminal-wait-coordinator-fix.595o0yuv` removed it, preserving original outcomes
and refusing missing coverage. Its 16 no-Store assertions per N1/N8 used two real
21-second delays each. Parent verified 4,113 identities. The two initial parent
verifier failures concerned patch-header and output-trailer assumptions, not the
application. The corrected report and failed logs remain retained.

Parent corrected owning-gate wiring and SQL-audit anchors under
`terminal-wait-gate-fix.7har15_7`. Three old rewrite refusals and three corrected
data transformations were verified. Review
`0c85c4cc-83d0-4c19-b63a-dddd35942050` found no issues. Composed source
`terminal-wait-current.fc0w2qn4` has 1,021 files and unchanged compiled Haskell
and Cabal inputs. Only the two gate scripts changed after compilation.

The following cases ran once under separate decisions. Each original checker and
launcher joined, and raw preservation preceded interpretation without database
API access. Store N1 and N8 passed 14 assertions each, with 1,070 and 1,072 parent
identity checks. Startup N1 passed six assertions with 1,075 checks. The unchanged
publication comparison N1 passed seven assertions with 1,074 checks, preserving
failure/claims until explicit recovery by that fresh original owner. Their roots
are `terminal-store-native.0k5p9541`, `terminal-store-N8.hz22rtev`,
`terminal-startup-N1.0kb28xxr` and `terminal-publication-N1.vzbq_6bp`. Review
`7f119323-ebd5-4718-95b8-76237af624c3` cleared the first Store result and private
correction at their stated scopes. The timeout handoff argument is supported by
matching upstream GHC 9.10.3 uninterruptible timer cleanup, not an exhaustive
schedule proof or comparison of every compiler patch.

The subsequent N1 cancellation case `terminal-cancel-N1.hxyg6l2u` failed with
exit one after 55.408605 seconds. Original handles joined without outer failure
or interruption. Parent reported failure before preservation and verified 1,101
identities over 44 entries and 27 regular files. Eleven assertions passed, ending
at the original terminal-category check. The shared local rendezvous timed out
before held-gate, release/fence and final exit130 assertions. Journal sequence
779 records run.cancelled, not original process exit or Manager release.

Review `40a9ad22-8b5b-457b-be72-9b29cb445763` proved that a private holder failure
can be hidden by its notification-only wait. It did not identify this invocation's
hidden failure or exact timeout stage. Preparation-only correction
`386a6b68-efb0-4571-a177-89f9268351f9` owns `terminal-holder-fix.i_kyd3cy`. It must
observe the same holder completion with its milestone, preserve failures and
joins, use one budgeted private loan and distinguish local timeout stages.
Production, previous overlays and failed resources remain read-only. No native
retry, budget increase or opaque retry is authorized.

Startup, publication and cancellation N8 remain unexecuted. The failed N1
cancellation and all composed owning/source/raw/Linux/client gates remain
outstanding. No focused result constitutes WM-016 acceptance.
At 04:10 UTC, the original worker remained active without case reports in the
expected paths. The parent required essential preflight and execution of the
scoped cases or a concrete blocker, rather than further harness generalization.
Unnecessary full-environment logging in the prepared harness was identified and
removed before any case. The earlier unexecuted revision remains retained. No
sensitive values were inspected or reported as logged. Explicit private overrides,
environment names and fingerprints replace inherited-value dumps. Wait-subscription
expiry is not worker timeout and cannot justify replacement or repeating a case.

The author disclosed a stopped filename-only search that listed forbidden
artifact/session/sentinel filenames, with no reported content reads. The
scope deviation remains in the handback and review. The supplied `fess` rubric
was `/Users/johnw/.agents/skills/command-fess/SKILL.md`.

No persistent goal is set in the current API session. The explicit user request,
not this handoff alone, authorizes resumed work.

The latest observed environment was macOS 26.6.2, Darwin 25.6.0
`xnu-12377.161.14~5`, GHC 9.10.3, Cabal 3.16.1.0, SQLite 3.53.3 and Python 3.14.7.
Use the selected Pi checkout at `~/src/fork/pi` for later verification. Earlier
Pi verification used 0.85.1 on Node 22.23.2, not Linux Pi. Confirm current bytes
and versions rather than reusing those claims.

The existing local workflow oracle is
`bisim/.lake/build/bin/conformance-oracle`, SHA256
`9ef464b26473485888be582bf09f2195e833151a6d7a0fbc81e552eaff436696`,
101,614,704 bytes. It is not in the recovery archive. If it is unavailable on the
new machine, record that blocker and obtain the compatible artifact or a separate
build decision. Do not call a missing oracle a pass or silently run a new Lean
build. Never run two full Lean builds at once.

Only SQLite directory-replacement confinement was withdrawn. It remains
restricted and unrun, not passed. Other path/publication/worker protections and
all remaining requirements still apply. Preserve the configured budgets, frozen
corpus, exact bytes, original capabilities, current authorization and separate
fact dimensions. No paid route-live gate, dependency installation, lockfile
change, production activation, PID signalling, or unrelated-worktree mutation is
authorized by this checkpoint. Compiler caches and local evidence outside the
portable checkpoint should be retained locally where available, not mistaken
for new-machine verification.
