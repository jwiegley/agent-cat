# Workflow manager Phase G review, October 2026

This record gives the integrated architecture, correctness and failure review
of the Phase G candidate of the workflow manager. The review ran on
2026-10-03 as subtask PG22 of WM-044. It read the source and the documents
and ran three checks. It changed no source file. It is a dated record, and
later work does not revise it.

## Scope

The candidate is the range from commit `88d999b7` (PF24, the Phase F gate
part 4) to commit `b94421c6` (PG21) on the branch
`workflow-manager-checkpoint-20260923`. The range holds the closeout record
`1bb9dba4` and these subtask commits.

| Subtask | Commit | Subject |
| --- | --- | --- |
| PG1 | `86c1e9e9` | Host load in capacity runs, and the end of every harness manager |
| PG2 | `26e84d8d` | Read-path saturation diagnosis |
| PG3 | `afd44d78` | Authorization revision apart from the reader wakeup, and the held run projections |
| PG4 | `76da0f5c` | Legacy entries of a runs window decoded in eight groups |
| PG5 | `b4b8a30d` | `reload-profiles` on the live and offline channels |
| PG6 | `2817abf5` | `drain` on the live channel |
| PG7 | `1b87a0fe` | `shutdown` on the live channel |
| PG8 | `a1c0ed86` | Offline `backup` |
| PG9 | `9cf218f7` | Offline `restore` with fencing evidence |
| PG10 | `c550335c` | Interrupted backup and restore through offline administration |
| PG11 | `5c8f38de` | Completion of a fenced restoration |
| PG12 | `3bf6e8cb` | Bounded operational facts in `status` |
| PG13 | `eca320c9` | Operator runbook `manager/OPERATIONS.md` and its exercise |
| PG14 | `5710785a` | Nix package of `agentic-run` with a filtered source |
| PG15 | `8fcb4999` | Acceptance of the packaged `agentic-run` |
| PG16 | `ab186c91` | Schema upgrade fixtures and newer-schema refusal |
| PG17 | `c901a10f` | Rollback to explicit local clients |
| PG19 | `2c56102d` | Manual, API and version matrix |
| PG20 | `5951ad37` | Client and owner documents |
| PG21 | `b94421c6` | Release evidence matrix |

PG18 has no commit. It waits for the operator authorization of the
`ext-pi/package-lock.json` change.

The review also covers the commits of the Emacs worktree
`~/src/agent-workflows-emacs-native` after `6e8eac0` on the branch
`emacs-native`. There is one such commit, `db7d212`, which adds the section
"Service-mode limits" and the stream 429 rule to the Emacs `README.md`.

The range changes no source under `runtime/`, `engine/` or `tui/`. The
product source changes are in `manager/src` and `cli/src`. The other changes
are tests, documents, `flake.nix` and `test/cabal.sh`.

## Severity and rating

| Severity | Meaning |
| --- | --- |
| Critical | A wrong answer, a lost or repeated effect, or a broken invariant of the binding rules on an ordinary path. |
| High | Such an effect on a reachable failure path, or a functional acceptance item without passing evidence. |
| Medium | A functional gap or an evidence gap that blocks a functional G5 criterion, with no wrong effect. |
| Low | A bounded delay, a fault label, a missing record or a test-harness gap, with no wrong effect and no blocked criterion. |

A security finding is listed as deferred and is not rated, as the operator
direction of 2026-09-30 requires.

## Conditions of the checks

| Check | Command | Exit | Evidence |
| --- | --- | --- | --- |
| Build | `timeout 1800 bash test/cabal.sh build -ftui-tests agentic-run routing-fixed-point-probe` with the GHC of the direnv environment and `-Werror -threaded -rtsopts` | 0 | `$S/build.log` |
| Journey sample | `timeout 900` `tui-journey` of `manager/test/service_http.py` at `-N8`, once | 0 | `$S/journey-n8.log` |
| Documentation | `timeout 900 make -C doc check` | 0 | `$S/doc-check.log` |

`$S` is the private stage directory
`resume-20260923/PG/PG22/impl-r1`. The one-minute load average was 23.0 at
the start of the review, 25.2 at the start of the journey and 34.2 at its
end. A Lean build of another project ran on the host during the review. The
processes 111, 9444 and 61004 that section 4 of the remaining-scope report
names were still present with parent 1. The review left them alone.

## Lens 1: architecture and correctness

| Property | Verdict | Evidence |
| --- | --- | --- |
| The runtime stays the sole workflow interpreter. | Holds. | No file under `runtime/src` or `engine/` changed. The held run projections of PG3 (`recallProjection`, `retainProjection` in `Store.hs`) cache a projection that the Runtime fold built, and each restoration compares the continued projection with the stored boundary and digest of the cut. A mismatch replays from sequence zero, and only a replay that does not match refuses with `StoreIntegrity`. The cache decides no transition. |
| The broker never originates, alters, reorders, retries, re-routes, re-delivers, answers or enforces. | Holds. | No broker source changed. `runtime/BROKER.md` gained one paragraph that states the existing order of a redirect that arrives after an answer and before `closeAttemptRoute`. A drain returns an unapproved request to the queue in Admission, which is the manager, and the next lifetime prepares it again under a new review that needs a new approval. That is admission work and is not a re-delivery by the broker. `DataBroker` keeps its nine operations, and `events.ndjson` keeps its bytes. |
| Lock order file slot, configuration, database. | Holds. | Reload, drain and shutdown take no file slot or database lock beside the configuration lock. The command record of each runs in its own Store transaction before the operation. A full revalidation of PG3 takes the configuration guard and then one SQL read. A skipped revalidation takes no lock. Backup and restore run in a copying or restoring lifetime under the configuration lease alone. The legacy decode groups of PG4 run inside the scope of their caller and take no new lock. |
| An admitted operation executes once. | Holds. | `recordedServing` in `LocalAdmin.hs` commits the command record, runs the operation once, appends the receipt and then runs the follow-up action. A lost reply is never retried. The next serving lifetime answers an orphaned reload, drain or shutdown ask with `outcome-uncertain`, because `administrationCommitted` finds no Store effect for them. A restoration completion applies the revision and claims that the marker recorded and creates no new restoration. |
| No opaque replay. | Holds. | No path sends a stored request body again. The completion of an interrupted restoration verifies the backup digest that the marker recorded and copies again from the immutable backup, which is a recorded recovery and not a replay of a client mutation. |
| Original capabilities, and no signal to a stored PID. | Holds. | `shutdown` calls the stop request of `withManagerSignals`, which interrupts the owner thread once with `throwTo`. Owned runs end through their original cleanup. `status` reads lifetime facts from the live `Service` value and Store aggregates. No new code reads or signals a stored process identity. |
| The PG3 revalidation rule cannot miss an authorization-relevant commit. | Holds. | Every product write of authorization facts calls `markAuthorizationChange`: `insertCredential` for issue and rotate, and `reviseClient` for revoke and rotate in `Credentials.hs`. No product code retires a client. The authority epoch changes only in an offline restoration, when no view is open. The revision advances before COMMIT while the transaction holds the Store gate, and every read takes the same gate on the one connection of the lifetime. Thus a full check either reads the facts before the writer begins and records the earlier revision, or reads the committed facts after the COMMIT. A skipped check cannot record a revision with stale facts. Expiry and rotation cutoff are compared with the clock on every revalidation. |
| The PG3 revalidation rule cannot miss a live reload. | Holds with a delay of at most one second. | Every reload reaches the views. The advance of the revision follows the probes of every profile instead of the install (finding R1). Between the install and the advance, a view whose last full check started less than one second earlier skips the facts read. Its next full check waits for the configuration lock that the probes hold, reads the new profile revisions and stops the response. |
| Drain ownership. | Holds. | `Service.drain` calls `beginDrain`, which closes the admission fence in one STM transaction and sets `DrainUntil maxBound` when no mode is set. Each preparation whose start has not committed stops with `StopDrain`, and `finalizeKnown` returns its request to the queue at its position with no ending notice. A started run continues with its controls. `fill` treats a refusal that the closed fence caused as no fault. |
| Shutdown ownership. | Holds. | The receipt of the shutdown is appended before the stop request runs. A second stop request or SIGTERM cannot interrupt the cleanup of the first. A Store that cannot append the command record refuses the shutdown, and the runbook directs the operator to SIGTERM. |
| Backup ownership. | Holds. | Backup runs only offline, in a copying lifetime under the configuration lease. The destination is created exclusively, and an existing one refuses with `output-conflict`. The completion binding is published last. The serving manager refuses `backup`. |
| Restore and restoration completion ownership. | Holds. | The fence is compared before anything is read from the backup or written to the Store. The marker of the current format records the pre-restoration epoch, stream and backup digest. Only the restoring lifetime opens while the marker exists. A completion takes its claims from the marker and never reads safety facts from the database that the interruption left. Captures are copied again idempotently. |
| Reload ownership. | Holds. | `reloadConfiguration` refuses a file of another path or a changed `administrationRoot` or `https` section and keeps the installed profiles on refusal. Offline `reload-profiles` validates in a registry of its own and installs nothing. |
| The two-configuration rule. | Holds. | A configuration that names `administrationRoot` always uses the live channel and never falls back to the offline path. Backup and restore need the offline file, and the configuration lease that offline administration takes refuses while a manager serves. |
| The `/v1` contract is frozen with additive extensions. | Holds. | The only additions in the range are the optional members of the `status` result of `LocalAdminResponse` (PG12). `doc/api/README.md` "Accepted additive fields" and the release evidence section "Accepted additive OpenAPI fields" list them. |

## Lens 2: failure

| Scenario | Verdict | Owning check |
| --- | --- | --- |
| Interrupted backup | An incomplete backup has no `complete` binding. A restore from it fails before the marker is written, so the Store is unchanged. The destination stays and refuses a second backup with `output-conflict` until the operator removes it, as `manager/OPERATIONS.md` states. | `failures-backup` mode of `manager/test/service_http.py` (PG10) |
| Interrupted restore | An interruption before the marker leaves the Store unchanged. An interruption after it fences every lifetime except the restoring one, and the same `restore` command with the same backup and fencing evidence completes it. Another backup or other evidence refuses and leaves the marker. | `failures-backup` (PG10, PG11), `manager-store-check` restart cases |
| Drain with owned runs and prepared reviews | Owned runs continue and accept their controls. A prepared review that is not approved becomes invalid with `worker-lost`, and its request returns to the queue. New admission work receives 503 `storage-unavailable`. | `operations` mode (PG6), `manager-admission-check` drain cases |
| Shutdown with owned runs | Owned runs are cancelled through their original cleanup. The next lifetime reports them with `supervision` `lost` and no cancel, and it prepares the queued requests again with no client command. | `operations` and `failures-manager` modes (PG7) |
| Disk write failure | The first definite write failure stops the Store. Every later read and command, cancel and withdraw included, refuses with 503 until a restart. `manager/STORAGE.md`, `manager/CAPACITY.md` and the section "Disk write failure" of `manager/OPERATIONS.md` state this. A live `shutdown` then refuses, and the runbook directs SIGTERM. | `faults-io` mode |
| Lost replies | No client resends a mutation automatically. A lost local administration reply is reported after fifteen seconds, and the next serving lifetime answers the orphaned ask in the manager log. `manager/OPERATIONS.md` gives the reconciliation reads. | `manager-command-check` administration cases, `operations` |
| Restart reconciliation | Unchanged in the range apart from the restoring lifetime, which neither migrates nor reconciles. | `manager-store-check`, `manager-admission-check` restart cases |
| Rollback | The packaged binary is stopped and the explicit local clients read the history read-only. | `rollback` mode (PG17) |
| Schema refusal | A newer schema refuses through the packaged binary, and the supported older schemas upgrade. | `package` mode with the schema fixtures of `manager/test/StoreCheck.hs` (PG16) |

## Findings of this review

| ID | Severity | Owner | Finding and failure scenario | Owning check |
| --- | --- | --- | --- | --- |
| R1 | Low | `reloadServing` in `manager/src/Agentic/Manager/LocalAdmin.hs`, and the reload hook of `serveManager` in `manager/src/Agentic/Manager.hs` | The comment of `advanceAuthorizationRevision` requires an owner to advance the revision when it installs a change of authorization facts. The reload installs the new profile revisions, then probes every profile under the configuration lock, and advances the revision only after the probes. A page set or an event stream of profile P has a full check at time t. A live reload at t + 0.1 s installs a configuration without P and probes the other profiles for several seconds. The revalidations before t + 1 s find the revision unchanged and skip the facts read, so writes under P continue until t + 1 s. The next full check waits for the configuration lock, reads the new facts and stops the response. The fix advances the revision as soon as `reloadConfiguration` returns success, before the probes. | `manager-artifact-check` revalidation cases, with a case that revalidates within one second after a reload, and the `operations` mode cases 1a and 1b |
| R2 | Low | `retainProjection` in `manager/src/Agentic/Manager/Store.hs`, and the section "Validated ingestion projections" of `manager/STORAGE.md` | The held projections are bounded by 64 MiB of original record bytes. The decoded `SnapshotCheckpoint` values occupy more resident memory than their record bytes, and the held projections stay for the lifetime of the Store. No check measures the resident size. A manager with many long runs can therefore hold a multiple of 64 MiB for its lifetime. The fix states the bound as record bytes in the capacity evidence, or measures the resident size once. | `capacity-streams` mode |
| R3 | Medium | The operator or the Integrator, then `manager/CAPACITY.md` | WM-041 has no capacity run of record. The PF17 manager, PID 61004, and the stopped frontends, PIDs 111 and 9444, still run with parent 1, so the PG1 host rule excludes every run on this host. The load average was also above 16 during this review. This evidence gap blocks the G5 release requirement on operational evidence and the WM-041 row of G3. No source change is needed. | `capacity-streams` and `capacity-inputs` modes at `-N8`, once each, after the three processes end and the load is within the rule of `manager/CAPACITY.md` |
| R4 | Low | `withLocalAdministration` and `reloadServing` in `manager/src/Agentic/Manager/LocalAdmin.hs` | The channel serves one connection at a time, and a live reload probes every profile before its reply. When the probes take longer than the fifteen-second client deadline, the operator receives `storage-unavailable` for a reload that completed and appended its receipt, and a `status` sent meanwhile waits behind the reload. The runbook reads that follow a lost reply resolve it, so no wrong effect follows. | `operations` mode, with a reload of several profiles |

## Triage of the open functional lows of section 4

Section 4 is section 4 of the remaining-scope report of 2026-10-03. No Phase
G subtask took these items. The column "Blocks G5" states whether the item
blocks a functional G5 criterion.

| Item | State at `b94421c6` | Blocks G5 | Severity | Owner and tracker | Owning check |
| --- | --- | --- | --- | --- | --- |
| `readDraftAt` holds the file slot | Open. `repeatChangedRead` pauses 10 ms between attempts with the file slot held. The attempts share the admission deadline of the request scope that the read receives, so the repeat ends within that deadline. Another request that needs the file slot waits within its own allowance and can receive 503. | No | Low | `manager/src/Agentic/Manager/Drafts.hs`, `acat-pf17-fess-followup-3xb3` | `manager-draft-check`, `capacity-drafts` |
| Overview-cursor 503 under churn | Open. `Overview.hs` refuses at once at the site `overview-cursor` when the event cursor moved while the members were read. PG2 counted 15 such records in one `capacity-streams` run. The clients read again after a 503. Repeating the read through `repeatChangedRead`, as PF17 did for drafts, would remove the refusal. | No | Low | `manager/src/Agentic/Manager/Overview.hs`, `acat-pf17-fess-followup-3xb3` | `capacity-streams`, `tui-overview` |
| Snapshot 503 `unexpected InvalidRequest` | Open. `classifyFault` in `manager/src/Agentic/Manager/Fault.hs` is unchanged, so a peer that closes its connection after the response started is still labeled as an unexpected fault. Only the private label is wrong. The client reads again. | No | Low | `Fault.hs`, `acat-phase-d-review-findings-raxi` | `emacs-client` mode with the fault log |
| SSE subscription after a dropped write | Open in the code. A dropped stream keeps its subscription until a write fails. PG20 documents the transient 429 `storage-quota` and the rule to poll from the cursor in `doc/api/README.md` "Stream reconnection after a 429 refusal", `tui/README.md` and `ext-pi/README.md`, and `db7d212` documents it in the Emacs `README.md`. | No | Low | `manager/src/Agentic/Manager/Events.hs`, `acat-phase-f-review-findings-4e23` | `capacity-streams` |
| Emacs service-mode limits | Recorded. `db7d212` lists the uncertain sends without reconciliation, the foreground wait of at most 120 seconds, the first-page snapshot read and the missing service equivalents. Each limit has a manual recovery. | No | Low | `emacs/wf-service.el` of the Emacs worktree, `acat-phase-d-review-findings-raxi` | `emacs-service-lifecycle` and `emacs-service-controls` modes |
| Emacs witness search without `regexp-quote` | Open. `6e8eac0` anchors the search with `^` and does not quote the run id. Manager identifiers hold only letters, digits, `_` and `-`, which have no special meaning there. A Runtime run id can hold `.`, which matches any character. Only the test harness is affected. | No | Low | `service_history_open` in `ci/emacs-ui.py` of the Emacs worktree, `acat-pf23-fess-followup-d1ok` | `cross-client-lineage` mode |
| Remaining 80x24 limits | Open. A fork review with more than one replacement and a lineage review with a long profile identifier do not fit 80x24. `tui/README.md` states that a review that does not fit is refused, so nothing is approved unseen. | No | Low | `tui/src`, `acat-pe7-fess-followup-uqv7` | `tui-sizes` mode |
| Snapshot supervision label | Open. The snapshot view reports the stored label, so a finished run with no live worker reads `owned` there while the run and control views read `lost`. `manager/CONTROLS.md` states the rule for the control and run views and does not state the snapshot exception. Controls follow the control view, so no wrong control is offered. | No | Low | The snapshot projection in `manager/src/Agentic/Manager/State.hs`, and `manager/CONTROLS.md`, `acat-phase-e-review-findings-0l73` | `tui-history` and `emacs-service-lifecycle` modes |
| `ext-pi` edges | Open. `assertLocalStateRoot` runs only in the restore path, reads queued before an endpoint switch are discarded by the generation check, one failed catalogue read stops `/wfm` for every profile, and a malformed profile setting skips the local restore and the bridge start. | No | Low | `ext-pi/src`, `acat-phase-e-review-findings-0l73` | The `ext-pi` integration suite, `pi-host` mode |
| Synthetic dispatch fold of a second live redirect | Open. No current path reaches a second live redirect of one occurrence. | No | Low | The redirect fold of the Runtime, not filed | `live-redirect` case of `test/control_probe.py` |
| Part 1 precision gaps, functional part | Open. Each gap is a missing acknowledgement, gap entry or ending on a failure path. No effect is lost or repeated. | No | Low | `manager/src/Agentic/Manager/Commands.hs` and the manager log owners, `acat-phase-b1-review-followups-dk1v` | `manager-command-check` |
| Reader and engine gaps | Open. `--follow` accepts one run log, no test shows that no Store-backed path reaches the unscoped ask refusal of `flowBroker`, and `engine/acp/README.md` does not describe the failed append of a permission report. | No | Low | `cli/src` flow reader, `flowBroker`, `engine/acp`, not filed | `engine/acp/ci/acp.sh` (not run in Phase G) |
| Pruner age trigger | Open and documented. `manager/STORAGE.md` states that a prune round runs at the open and after each seal, so a quiet manager keeps old segments. | No | Low | The manager-log pruner in `manager/src/Agentic/Manager/Store.hs`, `acat-phase-c-review-findings-hwxy` | `manager-store-check` prune cases |
| Untracked include of `runtime/cbits/private_sync.c` | Open. `manager/test/draft_sync_fault.c` includes the file, which `agentic.cabal` does not list for the two test executables, so an edit of the file does not rebuild their object. The product build lists the file in its own `c-sources`. | No | Low | `agentic.cabal`, `acat-phase-e-review-findings-0l73` | A build of `manager-command-check` after an edit of `private_sync.c` |
| Inherited SIGHUP disposition of the frontend proxy | Open. Whether the proxy survives a manager crash depends on the disposition that it inherits. The product code does not set it. | No | Low | The frontend proxy in `cli/src`, `acat-phase-e-review-findings-0l73` | `failures-manager` mode |
| Additive comparison rule | Resolved. The accepted fields are now listed in `doc/api/README.md` "Accepted additive fields" (PG19) and in the release evidence section "Accepted additive OpenAPI fields" (PG21). | No | None | `doc/api/README.md` | `make -C doc check` |

## Working-lens sample

The `tui-journey` of `manager/test/service_http.py` ran once at `-N8` on the
build of this review and passed with exit 0. Its fixture root was
`$TMPDIR/pg22.VqoFywfF`, and the log is `$S/journey-n8.log`. It covered the
startup refusals, the exact Unicode literal, the refusals of the summary and
detail keys, exact approval, the running snapshot, the typed answer, the
control, the verified result, and the manager-log and run-log assertions with
consent verified. The load average was 25.2 at its start and 34.2 at its end,
which is above the rule for capacity runs and does not affect the journey.

## Deferred security findings

These findings are recorded for the security stage and are not rated.

- The fencing evidence of `restore` is an operator-saved `status` answer. Its
  integrity is not authenticated, so a forged file with the right identities
  passes the fence.
- R1 also has a security aspect: a reload that removes a profile stops an
  open response of that profile up to one second late.
- An issued credential file whose issue was uncertain can be active or inert
  until the listing shows its state.
- The CORS, Host, Origin and proxy negatives, the secret-marker scans, the
  redaction projections, the hostile-input negatives and the revocation
  during a stream stay deferred, as the release evidence states.

## List for the Integrator

The fix list of critical, high and medium functional findings has one item.
The review found no critical or high finding.

| ID | Severity | Action | Owning check |
| --- | --- | --- | --- |
| R3 | Medium | End PIDs 111, 9444 and 61004 (`kill -CONT`, then `kill -KILL`), then run `capacity-streams` and `capacity-inputs` once at `-N8` on an idle host, and record the runs of record in `manager/CAPACITY.md` and the release evidence. | `capacity-streams`, `capacity-inputs` |

The Integrator files these new low findings in the tracker.

| ID | Title | Owning check |
| --- | --- | --- |
| R1 | Advance the authorization revision at the install of a live reload, before the probes. | `manager-artifact-check`, `operations` |
| R2 | State or measure the resident size of the held run projections. | `capacity-streams` |
| R4 | A live reload with slow probes can exceed the fifteen-second local administration deadline. | `operations` |
| Triage | The synthetic dispatch fold of a second live redirect, which is not filed. | `test/control_probe.py` |
| Triage | The reader and engine gaps, which are not filed. | `engine/acp/ci/acp.sh` |
| Triage | The snapshot supervision label is not stated in `manager/CONTROLS.md`, as a comment on `acat-phase-e-review-findings-0l73`. | `tui-history` |

The other open lows keep their existing tracker items, as the triage table
names them. PG18 still waits for the operator authorization of the
`ext-pi/package-lock.json` change. The exercise of the procedures by another
person, the gate of Phase G and the independent closure review remain the
open G5 conditions that the release evidence names.
