# Workflow-manager handoff

<!-- handoff-id: wm016-20260915; status: halted-by-user; accepted: WM-001..WM-015,G0 -->

## Status and authority

Work was halted at the user's request on 2026-09-15. The implementation loop is
paused, not complete. No further native experiment, gate, or deployment is
currently authorized. Resume only after an explicit new request.

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

Three separately authorized diagnostic invocations passed without reproducing the
original failure. Two belong to the original author, including a changed-order
natural-exit observation. The latest correction run preserved the original stop
order and completed with four Store-owned groups confirmed, empty first-failure
records, 162 Haskell records and 242 C records, and no overflow or logging failure.
It exercised the real EPERM zombie-leader guard without changing it. These are
**non-reproductions, not a resolution** of the original failure.

The latest checker and frontend hashes were respectively
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
baseline before edits. Inspect tests before running them. Only compilation and
previously permitted data-only checks are currently appropriate. Any further
native reproduction or full gate needs a fresh explicit decision covering its
inputs, original owners, budgets, first-failure capture, and stopping rule.

For a new clone, initialize/import the `obr` cache according to `AGENTS.md`.
Do not rebuild or replace an existing unrelated tracker cache. Keep WM-016 open.
Recheck the clock and perform the `refocus` check on explicit resumption.

The immediate next technical step is an independent decision on the unresolved
cleanup-proof failure and the diagnostic/retry correction. Do not repeat a whole
policy run merely to obtain green. Preserve missing, failed, and confirmed group
outcomes, the first failure, and both primary/cleanup exceptions. Then obtain
current-byte full source/raw/platform/client/doc evidence and independent
acceptance before integrating the candidate or moving to dependent WM-017.
At the end of **every downstream subtask**, run the `fess` skill, verify its
findings, and record the evidence before marking that subtask complete.

## Local identities and standing restrictions

The original local workspace was
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/controls.qzldrova`.
The original author is sealed. Correction workspace `failure-correction.suwgl8b7`
was interrupted after its authorized native run. Worker
`645433ed-c35e-4903-9928-1bf2c3bcb6bc` is paused. Neither old agent session is
required for recovery, and no worker should be revived or replaced based merely
on a lost workflow continuation. No persistent goal is set in the current API
session. This handoff is not an instruction to auto-continue.

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
