# Workflow-manager handoff

<!-- handoff-id: wm023-20260923; status: paused-unaccepted-wip; accepted: WM-001..WM-022,G0,G1; resume-branch: workflow-manager-checkpoint-20260923; fess: every-subtask -->

## Phase B part 2 of 2026-09-30

The resume workflow delivered Phase B part 2 under the operator directions
of 2026-09-29 for fast validation and of 2026-09-30 for functionality
first, as subtasks C1 to C26 after `5e8bbf9f`. Part 2 holds the ext-pi
checks on the built Pi fork, the retention and pruning of the manager log,
the functional review findings of part 1, actor-flow increment 2 (the route
resources), the remaining mutation routes and controls of WM-027,
actor-flow increment 3 (the live re-route and the asks that people answer),
and the functional failure endings of WM-028. All 26 subtasks landed, from
`7ec954f8` to `00686da1`. Subtask C26 ran the part 2 gate on `9f1ae979` with
the C26 repair of the `pages` assertion and wrote the first form of this
section. Two review lenses then reviewed `5e8bbf9f..00686da1`, and the
closeout of the run brought this section up to date. The run did not stop
early, and no authorization is pending. This section describes the current
state. Where any section below differs, this section supersedes
it, and the sections below remain as chronology. The evidence of each
subtask is under `B2/<subtask>/impl-r1` in the resume directory.

| Subtask | Commit | Result |
| --- | --- | --- |
| C1 | `7ec954f8` | The ext-pi checks pass on the built Pi fork 0.99.1. `test/owned-child-e2e.test.ts` asserts that the run log of an ext-pi launch names the owner that the ext-pi manifest declares. |
| C2 | `f8b87dbc` | The manager-log writer seals the active file into segments under `flow/sealed/<stream>/`, with global positions across segments and a reply index for retained records. |
| C3 | `a0d2065e` | A Store-owned pruner removes the oldest sealed segments below a protected floor by age or size, and it keeps every segment that names live work. |
| C4 | `5f219722` | `agentic-run flow` reports the floor and treats a reply or a consent chain that crosses it as pruned. `manager/STORAGE.md` states the layout and the rules. |
| C5 | `0b4bf489` | Two artifact downloads run at the same time. A third waits up to five seconds for a place, and each download has a total deadline of 300 seconds. |
| C6 | `fbe05a8a` | `GET /v1/requests` and `GET /v1/runs` read their members in keyset windows of at most 1024 identifiers. |
| C7 | `724f04a2` | `--manager serve --legacy-history ROOT=PROFILE` binds legacy history read-only, and `GET /v1/runs` and `GET /v1/runs/{id}` serve its entries. |
| C8 | `73a47ac6` | A bounded, positioned window reader for run logs and for the segments of a manager log. |
| C9 | `edd5da53` | `GET /v1/runs/{id}/routes` serves the run log as JSON batches. |
| C10 | `27f2f6c0` | `GET /v1/routes` serves the manager log of the current Store stream as JSON batches. |
| C11 | `e4b9e5c9` | Both route resources also serve server-sent events, with append wakeups, the shared reader quota and resumption by cursor. |
| C12 | `004eef20` | `POST /v1/captures` reaches the Drafts capture owner. |
| C13 | `14b795c0` | Preparation discard through `POST /v1/preparations/{id}` is a retained command. |
| C14 | `768de34b` | `POST /v1/runs/{id}/exports` reaches the export owner. |
| C15 | `a3a8720c` | `POST /v1/runs/{id}/lineage-requests` reaches the lineage owners, and a lineage review carries the optional field `lineage`. |
| C16 | `3f919fc8` | Cancel, steer, retry, abandon and two concurrent answers reach their runtime effects through `/v1`. No production code changed. |
| C17 | `890dec08` | A `/v1` fail-over and a `/v1` redirect inside the dispatch window each show in the run log. A runtime ordering race of steer and redirect events is repaired. |
| C18 | `7c0a9b94` | The runtime re-routes an in-flight attempt that is not an effect to a live candidate in its approved fail-over chain (difference D6). |
| C19 | `dd240c43` | The ext-pi reducer and monitor accept the event order of a live re-route. |
| C20 | `e7810632` | The manager offers and admits a live redirect through `POST /v1/runs/{id}/control`. |
| C21 | `04ef9db0` | The target option `--person-answer model:NAME` or `tool:NAME` names asks that a person answers through the person gate. The policy field `personAnswers` is part of the review. |
| C22 | `cd2198c6` | Asks answered by people work end to end through the running manager. No production code changed. |
| C23 | `76e65633` | A lost worker ends with lost supervision and no second start. `manager/ci/supervision.sh` is repaired. |
| C24 | `de22ba49` | A manager killed with SIGKILL ends its runs honestly, and a restart dispatches nothing again. No production code changed. |
| C25 | `9f1ae979` | Storage errors end honestly: the command-ledger ceiling, a missing manager log and a removed or corrupted result. No production code changed. |
| C26 | `00686da1` | The part 2 gate below, a repair of one pages-mode assertion, and the first form of this section. |

### Delivered behavior

- The manager log `flow/<stream>.ndjson` seals into segments with global
  positions, and the Store pruner removes old segments below a protected
  floor. A segment that names a request that is not terminal, a run that is
  not observed terminal, the parent run of a live request or an ask without
  a reply stays. `agentic-run flow` reports the floor and reads across it.
- The manager serves the route resources of actor-flow increment 2.
  `GET /v1/runs/{id}/routes` serves the run log of a run, and
  `GET /v1/routes` serves the manager log of the current Store stream. Each
  serves JSON batches and server-sent events, with a cursor bound to the
  stream, 410 `view-expired` after a restore and 410 `cursor-expired` below
  the floor. The existing scope checks select the records. Observe gives
  public-class records, observe with control adds actor-class records, and
  restricted records are never served. A route stream holds no Store loan
  while it writes.
- Two artifact downloads run at the same time, a third waits within the
  five-second allowance, and a total deadline of 300 seconds ends a slow
  download at its next write. The request and run collections read keyset
  windows of at most 1024 identifiers. Configured legacy history roots are
  served read-only through `/v1/runs`.
- The frozen mutation routes of WM-027 reach their existing owners:
  captures, preparation discard, exports and lineage requests (restart,
  resume and fork). Cancel, steer, retry, abandon, concurrent answers,
  fail-over and the redirect inside the dispatch window reach their runtime
  effects through `/v1`, and the run log shows the fail-over and the
  redirect.
- The runtime re-routes an in-flight attempt that is not an effect, when a
  service principal or a local controller sends a redirect to a live
  candidate in the approved fail-over chain. It stops the attempt through
  its original owner, appends a failure for the current question and asks
  the chosen candidate in a new question. A redirect of an effect or to a
  target outside the chain is rejected, and the run continues. No effect is
  re-routed in flight.
- A reviewed policy field `personAnswers` names the asks that a person
  answers through the person gate instead of the routed backend. The review
  shows the field, so exact approval covers it.
- A lost worker, a lost manager and the storage errors of WM-028 end
  honestly. A lost run shows lost supervision with no verified result, and
  it starts once. New work proceeds only when a free execution reservation
  and free resource keys remain, because the quarantined reservation of a
  lost run keeps its slot and its keys. The `failures-manager` mode uses two
  reservations and a second profile for this reason. At the command-ledger ceiling an
  ordinary command is refused with 429 `storage-quota`, and a cancel still
  ends a run through the cancel reserve.
- The `/v1` contract changes only by additions since `5e8bbf9f`: the paths
  `GET /v1/runs/{id}/routes` and `GET /v1/routes`, the schemas
  `RouteBatch`, `RouteCursor`, `RouteRecord`, `ManagerRouteBatch`,
  `ManagerRouteCursor` and `ManagerRouteRecord`, and two optional fields.
  The field `lineage` of `Review` (with the schemas `ReviewLineage` and
  `ReviewEdit`) came with C15, and the field `personAnswers` of the routed
  `PublicPolicy` came with C21. A root review and a policy without person
  answers keep their bytes. `Capabilities` keeps its bytes, and
  `DataBroker` keeps its nine fields.

### Gate of Phase B part 2

Subtask C26 ran the gate once on the tree of `9f1ae979`, in this order. Each
step has a `.log` and an `.exit` file under `B2/C26/impl-r1`. The first
failure of each step is under `B2/C26/impl-r1/failed-r0`. Every step listed
here passed, and each control failed with its literal message as intended.

1. `make -C doc check` passed (`01-doc-check`). Its contract check reported
   107 schemas, 31 operations, 341 payload cases, 20 SSE cases, 4 route SSE
   cases and 3 byte-bound downloads.
2. The incremental Werror build of all targets with `-ftui-tests` and
   `tui-model-test` passed (`02-allbuild`).
3. `make -C doc check-haskell` passed (`03-doc-check-haskell`).
4. The second incremental build after that reconfiguration passed
   (`04-allbuild-incremental`).
5. The comparison of `doc/api/openapi.yaml` with `5e8bbf9f` found no removed
   or changed path, the two route paths and eight schemas as additions, the
   two optional fields named above as the only changes to existing schemas,
   and identical `Capabilities` bytes (`05a-api-additive`). Its first run
   used the comparison of part 1, which refuses any change to an existing
   schema, and it named `PublicPolicy` and `Review`
   (`failed-r0/05a-api-additive`). The repair accepts a change that only adds
   an optional property and lists each one. `DataBroker` has nine fields
   (`05b-broker-fields`).
6. `runtime-contract-test` passed at N8 (`06-runtime-contract-N8`).
7. `test/flow_probe.py` passed (`07a-flow-probe`). `test/progress_probe.py`
   passed with the golden `test/fixtures/flow/hello-events.ndjson` and the
   reference trace. Its five cases reported storage ratios of 1.577, 1.277,
   0.959, 1.321 and 1.332, the last for the broker-injected case
   (`07b-progress-probe`).
   `test/control_probe.py` passed at N8 with the live-redirect cases
   (`07c-control-probe-N8`). `test/person_control_probe.py` passed at N8
   with the person-answer cases (`07d-person-control-probe-N8`).
8. `manager-command-check flow` passed at N8 (`08a-command-flow-N8`). It
   reported a median synchronized command-record append of 6.715 ms (maximum
   10.471 ms) and a median ordinary admission with its record of 8.604 ms
   (maximum 11.960 ms) over 60 commands. The main form with
   `command_contract.py` and `credential_cli.py` passed at N8
   (`08b-command-main-N8`).
9. `manager-artifact-check` passed its modes `response-order`,
   `response-ingestion` and `collections` at N8 (`09-artifact-*`). Its main
   form with `manager-history-check` and `artifact_contract.py` passed at N8
   (`09d-artifact-main-history-N8`).
10. The main mode of `manager-store-check` passed at N8
    (`10-store-main-N8`).
11. `manager/test/client_native.py` passed at N8 with 28 PASS lines
    (`11-client-native-N8`).
12. `manager/test/service_http.py` passed at N8 once in each mode, with a
    fresh fixture for each: base with `CLIENT_CHECK`, `mixed`, `pages`,
    `events-lifecycle`, `routes`, `mutations-captures`, `mutations-discard`,
    `mutations-exports`, `mutations-lineage`, `controls`,
    `controls-routing`, `live-redirect`, `person-answers`,
    `failures-worker`, `failures-manager` and `storage` (`12a` to `12p`).
    The first run of `pages` failed in case 8, because its ETag assertion
    expected a representation tag on the first page of
    `/v1/runs/{id}/lineage-requests`. Since C15 that page carries the parent
    run revision as its strong ETag, as `doc/api/README.md` states. The
    failure is under `failed-r0/12c-service-pages-N8`, with the fixture root
    `/Users/johnw/Products/k.M0a5ItPm/tmp/c26-pages.vdBAyX4C`. The repair
    gives the lineage collection the same expectation as the export
    collection, and the rerun passed.
13. `tui-journey` passed at N1 and then N8 with every `FLOW-ASSERT` and a
    verified consent chain (`13-journey-pair`, fixture root
    `/Users/johnw/Products/k.M0a5ItPm/tmp/c26-gate-journey.EKdYGEXp`). In
    both runs the chain was review 7, approve 8, receipt 9, start relay 10
    and run start 0. The manager logs held 26 records in 22193 and 22192
    bytes, and the run-log storage ratio was 1.408 at N1 and 1.407 at N8.
14. The control `tui-journey-broken-answer` failed with "JOURNEY-ASSERT
    typed answer is not JSON false", `tui-consent-control` failed with
    "detail-view key approved a review", and `tui-flow-approve-fault`
    failed with "FLOW-FAULT the approve append failed and the manager
    refused the approval with storage-unavailable", each at N8 (`14a` to
    `14c`).
15. In `ext-pi`, `npm run check` passed (`15a-ext-pi-check`), `npm test`
    passed with 92 tests and 5 skipped (`15b-ext-pi-test`), and
    `npm run test:integration` passed its 8 Vitest cases and
    `test/pi-remote-current.mjs` with `AGENT_CAT_E2E_RUNNER` set to the
    `-ftui-tests` build of `agentic-run` (`15c-ext-pi-integration`).
16. `bash tui/ci/tui.sh` passed (`16-tui-ci`). It covers TUI local mode,
    the source boundaries, `tui-model-test` and the TUI probes.
17. `make -C doc check` passed after this section (`17-doc-check-final`).

### Design gates of increment 1

Section 6.1 of the design record names eleven gates. The table maps each to
its current evidence. Item 2 of `acat-62j0` asked for this table.

| Gate | Evidence | Not run |
| --- | --- | --- |
| 1, the whole journey | Steps 13 and 14 of this gate. | None. |
| 2, carriage | `runtime-contract-test` and the carriage check of `test/flow_probe.py`, steps 6 and 7. | None. |
| 3, round trips | The codec checks of the seventeen schemas in `runtime-contract-test`, step 6. | None. |
| 4, public bytes and the reference trace | `test/progress_probe.py` with the golden file and the reference trace, step 7. | `cli/ci/examples.sh` did not run in part 2. It last passed in step 31 of the increment 1 gate. |
| 5, attribution | The attribution cases of `test/flow_probe.py` and the person cases of `test/person_control_probe.py`, step 7. The ext-pi launch owner from C1, run again in step 15. | The ACP permission scenario of `engine/acp/ci/acp.sh` did not run in part 2. It last passed in step 29 of the increment 1 gate. |
| 6, re-routing | C17: a `/v1` fail-over and a `/v1` redirect inside the dispatch window, each shown in the run log, step 12 (`controls-routing`). C18: the live re-route of `test/control_probe.py`, step 7, and through `/v1` in step 12 (`live-redirect`). | No check sends the redirect from a TUI key. The redirect travels through `/v1` and through the local control channel of `test/control_probe.py`. |
| 7, failures, restarts and runs that never start | C25: the `storage` mode, step 12. Also the modes `failures-worker`, `failures-manager` and `mutations-discard`, step 12, and the open refusals, recovery and ceiling of `manager-command-check flow`, step 8. | `manager-approval-check flow-review` and the modes of `manager-admission-check`, which carry withdraw, review expiry and admission refusal, did not run in part 2. They last passed in steps 15 to 17 of the increment 1 gate. |
| 8, stop and uncertainty | The uncertainty cases of `test/flow_probe.py`, step 7, the run-log states of the reader checks of `runtime-contract-test`, step 6, and the uncertain open ask of `failures-worker`, step 12. | None. |
| 9, storage and cost | The storage ratios of steps 7 and 13, the manager-log size of step 13, and the in-process append latency of step 8. | The latency of each synchronized append is not measured in the journey (item 4 of `acat-62j0`). |
| 10, bypass | The `inProcessBroker` allowlist check of `test/flow_probe.py` and its negative line, step 7. | None. |
| 11, regression | ext-pi from C1 and C19, run again in step 15. The runtime broker checks, step 6. TUI local mode, step 16. The admission, approval, control, worker and ingestion owners through the service modes of step 12. | The revalidation of `broker-api-default` (`678326b`) at N1 and N8. `cli/ci/policies.sh`, `cli/ci/routing-config.sh`, `engine/acp/ci/acp.sh`, `engine/agent-deck/ci/deck.sh` and `bisim/ci/tier0.sh`. |

### Checks not run

- The revalidation of `broker-api-default` (`678326b`) that gate 11 names,
  and the measurement of the append latency in the journey that gate 9
  names.
- `cli/ci/policies.sh`, `manager/ci/approval.sh`, `manager/ci/controls.sh`,
  the `admission_audit.py` mutation audits, mutant suites, stability samples
  of more than a few starts and `-fforce-recomp` builds. The operator
  direction of 2026-09-29 removes them from routine validation.
- `bisim/ci/tier0.sh` and every Lean or oracle check. The operator
  direction forbids them for this run.
- The N1 runs of the runtime and manager checks. Each ran once at N8, and
  only the journey ran at N1 and N8.
- The checks of the increment 1 gate that the part 2 gate list does not
  name: `engine-api-test`, `test/lineage_probe.py`,
  `manager-approval-check`, `manager-admission-check`,
  `manager-worker-check`, the store modes other than main,
  `manager-draft-check`, `engine/acp/ci/acp.sh`,
  `cli/ci/routing-config.sh`, `cli/ci/examples.sh`,
  `engine/agent-deck/ci/deck.sh`, `manager/ci/supervision.sh` (C23 ran it)
  and `manager/ci/vertical.sh`. The modes `credential-lifecycle` and
  `boundary` of `service_http.py` did not run, because they are security
  checks of part 1.
- `engine/acp/ci/route-live.sh`, which needs a paid provider.

### Deferred security items

The operator direction of 2026-09-30 defers security work to a later stage.
The existing authentication, scope checks, exact consent and bounds stay in
place, and the gate above exercised them. These items are deferred and
not done:

- The hostile-input and transport negatives of WM-024 and WM-028,
  including those of the route resources, the new mutation routes and the
  live redirect.
- The binding of a route cursor to the authorization revision, a
  per-credential projection of route records, route-class projection
  design beyond the existing scopes, and revocation-during-stream matrices.
- The redaction of run-log bodies and of the output of `agentic-run flow`.
- The G2 witness of protected observation with mutations unavailable.
- The remaining Name Constraints work, including the optional patch B18 of
  `crypton-x509-validation`, and the scenarios of item 1 of `acat-3iof`.
- Scans for synthetic secret markers beyond those of the existing modes.
- The unauthorized and forbidden negative matrices of each new route beyond
  one scope check for each route family.
- The ruling on the redaction exception for the `targetLabel`
  `acp:mixed-adapter` (`acat-b13-fess-en44`).
- The authority fencing of an older-backup restoration in WM-028.
- The items of `acat-8tzp`: the warp-tls plaintext refusal bytes, the
  refusal of a non-loopback allowed peer and a slow body with no body byte.
- A credential scope change or revocation during a retained response, for
  which no operation exists yet.
- The threat model of increment 2 stays a design reference, and no review
  of it gates serving.

### Remaining limits

- The SQLite command ledger is not pruned. `command_ledger_usage` keeps
  every admitted command charged, and `Commands.checkCapacity` bounds
  admission under `globalMutationLedgerBytes`. When the ledger reaches that
  ceiling, every ordinary command is refused with 429 `storage-quota`, and
  it stays refused after an ordinary restart. A cancel still proceeds
  through the cancel reserve. The `storage` mode shows this behavior. Only
  the manager log is pruned.
- A restart quarantines the reservation of a lost run with its execution
  slot and resource keys, and no operation releases it yet. With one
  reservation, no new run starts after a manager crash (WM-020 and WM-042).
- The manager offers a redirect target from the route names of the
  approved policy. After an automatic fail-over the offer can list a target
  that the runtime then rejects, and the stopped ACP turn of a live
  re-route is not cancelled at the adapter while the run continues.
- The pruner uses the wall clock and a fixed age of 604800 seconds, and it
  evaluates the age only at the open and after a seal. A run that a restart
  left with lost supervision, or a command whose receipt reply was never
  appended, protects its segment in every later lifetime. No operation
  clears either case, so after one such event the floor no longer moves and
  the manager log grows toward its allowance. `manager/STORAGE.md` states
  this behavior.
- For each page of `/v1/runs`, the service reads every bound legacy root in
  full, within 256 entries and 1 MiB encoded. Bound roots that hold more
  make the service refuse the whole run collection, managed runs included.
  `doc/api/README.md` states this ceiling.
- A redirect that arrives after an attempt has returned its answer, and
  before the runtime closes the attempt, drops that answer. The question
  fails as redirected, and the chosen candidate is asked again.
- A SIGKILL of the frontend proxy group alone leaves the inner worker group
  alive, so that run stays under owned supervision (WM-019 containment).
- The open fess findings of each subtask are in the tracker items that the
  commit messages of C1 to C26 name, from
  `acat-c1-ext-pi-fess-findings-ld5u` to
  `acat-c26-part2-gate-fess-findings-jvnc`.

### End-of-part review

Two lenses reviewed `5e8bbf9f..00686da1`: packages, and working behavior.
Both returned "approve with notes" with no critical or high finding, and no
fix round ran. The working lens rebuilt `agentic-run` and
`routing-fixed-point-probe` with `-ftui-tests` incrementally, and the build
was already current. It then ran `tui-journey` at N1 and then N8 on
`00686da1`, and both runs passed with every `FLOW-ASSERT` and the consent
chain review 7, approve 8, receipt 9, start relay 10 and run start 0
(fixture root `/Users/johnw/Products/k.M0a5ItPm/tmp/review-b2.kDNb9t6E`).
The open findings follow. The closeout corrected the documentation that the
first three medium findings name, and the behavior of each stays as stated.

| Severity | Finding | Location |
| --- | --- | --- |
| Medium | A lost run or a command ask with no receipt reply protects its segment in every later lifetime, so the pruner floor stops and the manager log grows toward its allowance. No operation clears either case. A possible repair answers orphaned asks at restart and treats a lost run as terminal for pruning. | `Store.hs` `pruneCandidate`, `segmentProtected`, `Commands.hs` `recordReceipt` |
| Medium | After a manager crash the quarantined reservation keeps its slot and resource keys. With the default of one execution reservation, no new run starts until WM-042 adds a quarantine release. | `manager/WORKERS.md`, `failures-manager` |
| Medium | Legacy history is not windowed. Each page of `/v1/runs` reads every bound root in full within 256 entries and 1 MiB, and a larger root refuses the whole collection. | `History.hs` `legacyRuns`, `legacyItems` |
| Medium | A live re-route stops the attempt in the runtime, but no caller sends `session/cancel` to the adapter, so the stopped ACP turn stays open until that engine shuts down. | `Exec.hs` `withPhysicalAttempt`, `Acp.hs` `cancelTurn` |
| Low | A redirect that arrives after the attempt returned its answer drops the answer and asks the chosen candidate again. | `Exec.hs` `withPhysicalAttempt` |
| Low | The pruner evaluates the age trigger only at the open and after a seal. | `Store.hs` `withManagerLogPruner` |
| Low | The fold of an in-flight redirect without a dispatch builds a dispatch with one target, so a second live redirect of the same occurrence would fail the fold. No current path reaches it, because a control runtime opens a dispatch for every question with two or more candidates. | `Snapshot.hs`, `ext-pi/src/reducer.ts` |
| Low | The general paragraph on page sets says that a set holds one revision, and the next paragraph says that each window of `/requests` and `/runs` reads its own database boundary. | `doc/api/README.md`, "Pages and live delivery" |
| Low | The part 2 openapi comparison in the stage directory accepts added optional properties, and the gate list named only the route paths. The rule is not a repository check. | `B2/C26/impl-r1/api_additive_v2.py` |
| Low | The ext-pi supervisor and the TUI do not originate a live redirect. Only `/v1` and the local control channel of `test/control_probe.py` send one. | `ext-pi/src/supervisor.ts` |
| Low | The functional low gaps of part 1 stay open: a held preflight control without an acknowledgement when a run fails before carriage, a failed failure-reply append without a gap entry, and a review record that a later pre-commit step rolls back without an ending. | `acat-phase-b1-review-followups-dk1v` |

### Package status

| Package or item | Status | Evidence | Tracker |
| --- | --- | --- | --- |
| Manager-log retention (`acat-3mgw`) | Met. The floor-stop finding above stays open. | C2, C3, C4, gate steps 8 and 12 | Closed |
| Increment 2 (`acat-en4g`) | Met for function, with its security items deferred | C8 to C11, gate steps 1 and 12 | Closed |
| Increment 3 (`acat-c18n`) | Met for function. The adapter cancel finding stays open. | C18 to C22, gate steps 7, 12 and 15 | Closed |
| WM-025 (`acat-wm-025-3utw`) | Met for function, with its security items deferred. The legacy ceiling finding stays open. | C6, C7, C9, C10, gate steps 9 and 12 | Closed |
| WM-026 (`acat-wm-026-qo1e`) | Met for function, with route SSE added | C11, gate step 12 | Closed |
| WM-027 (`acat-wm-027-gcu6`) | Met for function | C12 to C17, C20, gate step 12 | Closed |
| WM-028 (`acat-wm-028-g1n0`) | The functional failure endings are met. One lens rates it partial, because new work after a manager crash needs a second reservation. The database-full case, older-backup fencing and the security negatives are not done. | C23, C24, C25, gate step 12 | Open |
| `acat-62j0` | Gates 5, 6 and 11 ext-pi have evidence, and the table above maps gates 1 to 11. The broker-api-default revalidation, the journey latency and the `policy-probe` expectation remain. | C1, C17, C18, C19, this gate | Open |
| Part 1 review findings of C5, C6 and C7 (`acat-phase-b1-review-followups-dk1v`) | Met for the three medium findings. The part 1 precision gaps remain. | C5, C6, C7, gate steps 9 and 12 | Open |

### Next action

1. The tracker records the closeout. The open review findings above are
   in `acat-phase-b2-review-findings-x8fv`, and the deferred security items
   are in `acat-phase-b2-deferred-security-k1hl`. The packages closed for
   function name that issue in their closing comments.
2. Phase C follows under the functionality-first direction of 2026-09-30
   and the fast-validation direction of 2026-09-29: the shared client
   (WM-029) and the full TUI service mode (WM-033 to WM-035). The TUI uses
   the route resources, the new mutation routes and the live redirect
   through `/v1`. A working quarantine release (WM-042) and answers to
   orphaned command asks at restart are the functional repairs that Phase C
   most needs, because a manager crash otherwise blocks later runs.
3. A later security stage takes the deferred items above, the negatives
   of WM-024 and WM-028 and the G2 witness.

Accepted state is unchanged at WM-001 to WM-022 and G0 and G1. Part 2
closes no gate.

## Phase B part 1 of 2026-09-30

The resume workflow delivered Phase B part 1 under the operator direction of
2026-09-29 for fast validation, as subtasks B1 to B19 after `9a641dd8`. Part
1 holds the four medium repairs of the increment 1 review, the disposition
evidence of `acat-dxos` and `acat-nwrj`, the threat model of actor-flow
increment 2, the P1 findings `acat-response-ingestion-budget-zaoi` and
`acat-tls-name-forms-6gbo`, and the part 1 work of WM-023 to WM-026. Subtasks
B1 to B14 landed. Subtasks B15 to B18 did not land, because each needs an
operator review or authorization, as the section "Gated subtasks" states.
Subtask B19 ran the part 1 gate on the tree of `ddf3ed93` and wrote this
section, and the Integrator committed it as `2f0848b1`. Two review lenses
then read `9a641dd8..2f0848b1`, and the closeout stage of the run updated
this section. The run ended with no stop condition. This section describes
the current state at `2f0848b1`. Where any section below
differs, this section supersedes it, and the sections below remain as
chronology. The evidence of each subtask is under `B/<subtask>/impl-r1` or
`impl-r2` in the resume directory.

| Subtask | Commit | Result |
| --- | --- | --- |
| B1 | `a803f5f3` | A cancel whose appended record decodes to another value is committed and named in a gap notice. The manager log names its open faults `oversized`, `undecodable` and `io-failure`. `manager/STORAGE.md` states the growth limit and the recovery, and no longer says that no local path enters a body. |
| B2 | `27150239` | A control that arrives before the run log exists is held, then appended and delivered through `flowBroker` after the run log opens and before activation. |
| B3 | `452272bf` | Evidence only. The Client-facade check passed at N8 with no 503 line. Two of three `tui-approval` runs at N8 passed, and the third failed through a harness race (`acat-2ua3`), not the `acat-dxos` signature. |
| B4 | `b574255b` | The record `doc/research/actor-flow-route-threat-model.md`: the additive paths `GET /v1/routes` and `GET /v1/runs/{id}/routes`, the cursor alias, the 410 rules, the projection and visibility tables and the route-class authorization. It changes no code. |
| B5 | `45e95147` | Protected byte responses release the configuration guard, the reader charge, every SQL transaction and the file slot before the first network write, and revalidate authorization before each 16 KiB write. |
| B6 | `312fd25d` | Pages, downloads and receipts follow the same rule. A per-Store download quota of one replaces the artifact response slot, and a second concurrent download is refused with 429 `storage-quota`. |
| B7 | `052a41bf` | An event stream takes its reader charge and configuration loan for each batch read and holds no loan while it writes. This closes `acat-response-ingestion-budget-zaoi`. |
| B8 | `776be8e7` | WM-023: the mode `credential-lifecycle` of `service_http.py` shows rotation, cutoff, revocation during retained responses, the scope boundary and the absence of bearer bytes through the running HTTPS manager. No production source changed. |
| B9 | `8c4140b7` | WM-024: the HTTPS boundary returns the frozen refusal codes for origins, preflights, content codings, request targets and slow bodies, and the mode `boundary` checks every negative with raw sockets. |
| B10 | `303f655a` | The manager client refuses a chain whose Name Constraints use a form that `crypton-x509-validation` 1.9.1 does not evaluate or evaluates wrongly. No dependency changed. This closes `acat-tls-name-forms-6gbo`. |
| B11 | `bea2d57b` | WM-025: `GET /v1/requests`, `/v1/runs` and `/v1/decisions` are routed as page sets of the frozen contract. |
| B12 | `d652b37f` | WM-025: `GET /v1/runs/{id}/exports`, `/v1/runs/{id}/lineage-requests` and `/v1/exports/{id}` are routed. |
| B13 | `87b255b9` | WM-025: the mode `pages` checks multi-page sets, exact ETags, token binding and expiry, the quota, revocation, an interrupted send, the aggregate bound and redaction. |
| B14 | `ddf3ed93` | WM-026: the mode `events-lifecycle` checks snapshot attachment, filtered cursors, reconnection, restart and restore. An open event stream now ends at a block boundary on shutdown. |
| B15 | not landed | Increment 2: the run route resource. It waits for the operator review of B4. |
| B16 | not landed | Increment 2: route SSE, the manager-log route, wakeups and quota. It waits for the operator review of B4. |
| B17 | not landed | Increment 2: actor-class serving for observe-with-control principals. It waits for the operator review of B4. |
| B18 | not landed | Optional: a patch of `crypton-x509-validation` for IP Name Constraints. It waits for operator authorization. |
| B19 | `2f0848b1` | The part 1 gate below and the first form of this section. |

### Delivered behavior

- The manager serves the frozen read collections `/v1/requests`,
  `/v1/runs` and `/v1/decisions` and the export and lineage detail
  resources as page sets with exact ETags. Each page set is bound to its
  client, path, query and view, and it expires after 60 seconds.
- A protected response materializes its bytes under its loans and returns
  every Store loan before its first network write. It revalidates
  authorization before each write, so a revocation stops the next write.
  An event stream holds no Store loan while it writes or waits. Accepted
  ingestion is no longer blocked by a slow reader.
- The HTTPS boundary refuses with the frozen codes of `doc/api/README.md`.
  An ordinary shutdown ends each open event stream at a block boundary,
  and new streams are refused with 503 while the manager closes.
- The manager client refuses the Name Constraints forms that the TLS
  library misreads. It adds refusals only and never accepts a chain that
  the default validation refuses.
- The run log carries a control that arrives before activation, and a
  cancel that the manager log cannot record exactly still proceeds.
- `doc/api/openapi.yaml` and `runtime/src/Agentic/Runtime/Broker.hs` are
  unchanged since `9a641dd8`. The `/v1` contract gains no path and no
  schema in part 1, `Capabilities` keeps its bytes, and `DataBroker` keeps
  its nine fields. No route resource is served.

### Gate of Phase B part 1

Subtask B19 ran the gate once on the tree of `ddf3ed93`, in the order of the
gate list. Steps 15 and 16 ran on that tree with this handoff edit. Each step has a `.log` and an `.exit` file under
`B/B19/impl-r1`. The first failure is under `B/B19/impl-r1/failed-r0`.
Every check listed here passed, and each control failed with its literal
message as intended.

1. `make -C doc check` passed (`01-doc-check`).
2. The incremental Werror build of all targets with `-ftui-tests` and
   `tui-model-test` passed (`02-allbuild`).
3. `make -C doc check-haskell` passed within its budget
   (`03-doc-check-haskell`).
4. `bash manager/ci/contract.sh` passed with 99 schemas, 29 operations,
   333 payload cases, 20 SSE cases and 3 byte-bound downloads
   (`04-contract`). The comparison of `doc/api/openapi.yaml` with
   `9a641dd8` found no removed or changed path or component, no added path
   or schema, no route path, and identical `Capabilities` bytes
   (`04b-api-additive`). `Broker.hs` is unchanged since `9a641dd8`, and
   `DataBroker` has nine fields (`04c-broker`). The first run of the field
   count counted one field because its expression required a leading comma
   (`failed-r0/04c-broker-countdefect`). The repair counts each field name
   that begins a line.
5. `runtime-contract-test` passed at N8 (`05a-runtime-contract-N8`),
   `test/flow_probe.py` passed (`05b-flow-probe`), and
   `test/progress_probe.py` passed with the golden
   `test/fixtures/flow/hello-events.ndjson` (`05c-progress-probe`). With the
   one-byte golden `hello-events-one-byte.ndjson` the probe failed as
   intended with "broker-hello events.ndjson differs from ... at line 11"
   (`05d-golden-control`).
6. `test/control_probe.py` and `test/person_control_probe.py` passed at N8
   (`06a-control-probe-N8`, `06b-person-control-probe-N8`).
7. `manager-command-check flow` passed at N8 (`07a-command-flow-N8`), and
   the main form of `manager-command-check` with `command_contract.py` and
   `credential_cli.py` passed at N8 (`07b-command-main-N8`).
8. `manager-artifact-check` passed its modes `response-ingestion`,
   `stream-ingestion`, `response-order`, `fault-classification`,
   `ordinary-admission`, `events` and `ordinary-stream` at N8 (`08a` to
   `08g`). Its main form, `manager-history-check` and
   `artifact_contract.py` passed at N8 (`08h-artifact-main-history-N8`).
9. `manager-approval-check ingestion` and the main mode of
   `manager-store-check` passed at N8 (`09a-ingestion-N8`,
   `09b-store-main-N8`).
10. `manager/test/client_native.py` passed at N8 with 28 PASS lines and the
    fail-closed expectations of B10 (`10-client-native-N8`).
11. `manager/test/service_http.py` passed at N8 in base mode with
    `CLIENT_CHECK`, and then in the modes `mixed`, `credential-lifecycle`,
    `boundary`, `pages` and `events-lifecycle`, each with a fresh fixture
    (`11a` to `11f`). The Client facade passed against the running manager.
12. `tui-journey` passed at N1 and then N8 with every `FLOW-ASSERT` and a
    verified consent chain (`12-journey-pair`, fixture root
    `/Users/johnw/Products/k.M0a5ItPm/tmp/b19-gate-journey.nbgbC6ul`). In
    both runs the chain was review 7, approve 8, receipt 9, start relay 10
    and run start 0. The manager logs held 26 records in 22192 and 22193
    bytes.
13. The consent control changed one review byte in a copy of the N8
    manager log of step 12, and `agentic-run flow` exited 1 with "the review
    body does not decode: review body reviewSha256 does not match its review
    bytes" (`13-consent-control`).
14. The control `tui-journey-broken-answer` failed with "JOURNEY-ASSERT
    typed answer is not JSON false", `tui-consent-control` failed with
    "detail-view key approved a review", and `tui-flow-approve-fault`
    failed with "FLOW-FAULT the approve append failed and the manager
    refused the approval with storage-unavailable", each at N8 (`14a` to
    `14c`).
15. `make -C doc check` passed after this section (`15-doc-check-final`).
16. `bash tui/ci/tui.sh` passed last (`16-tui-ci`).

### Checks not run

- The route checks: the mode `routes` of `service_http.py`, the route
  contract fixtures and the additive-only comparison of route paths. B15
  did not land, so no route path exists, and the openapi comparison shows no
  change. The SSE, manager-log route and route-restore assertions did not
  run because B16 did not land. The actor-class assertions did not run
  because B17 did not land.
- A client check with IP Name Constraints evaluated by the library. B18 did
  not land, so `client_native.py` ran with the fail-closed expectations of
  B10.
- `cli/ci/policies.sh`, `manager/ci/approval.sh`, `manager/ci/controls.sh`,
  the `admission_audit.py` mutation audits, mutant suites, stability samples
  of more than a few starts and `-fforce-recomp` builds. The operator
  direction of 2026-09-29 removes them from routine validation.
- `bisim/ci/tier0.sh` and every Lean or oracle check. The operator direction
  forbids them for this run.
- The N1 runs of the runtime and manager checks. Each ran once at N8, and
  only the journey ran at N1 and N8.
- The increment 1 gate checks that the part 1 gate list does not name:
  `engine-api-test`, `test/lineage_probe.py`, the modes `flow-review` and
  `flow-relay`, `manager-admission-check`, `manager-worker-check`, the
  store modes other than main, `manager-draft-check`,
  `engine/acp/ci/acp.sh`, `cli/ci/routing-config.sh`, `cli/ci/examples.sh`
  and `engine/agent-deck/ci/deck.sh`. `bash tui/ci/tui.sh` covers the
  source boundaries, `tui-model-test` and the TUI probes.
- `engine/acp/ci/route-live.sh`, which needs a paid provider. The ext-pi
  checks did not run in this gate, because the Pi fork had no built `dist`
  directories. Subtask C1 of Phase B part 2 later ran them to a pass, as the
  paragraph after this list states.
- The Client-facade check at N1, which is the closing condition of
  `acat-nwrj`. The gate list names only N8.

Subtask C1 of Phase B part 2 ran the ext-pi checks against the built Pi fork
at `~/src/fork/pi` (version 0.99.1) and an `agentic-run` built with
`-ftui-tests`. `npm run check`, `npm test` (89 passed, 5 skipped) and
`npm run test:integration` (8 Vitest cases and
`test/pi-remote-current.mjs`) passed. The fake Pi host in
`test/pi-remote-current.mjs` now uses `state.change`, the form that the fork
provides. `test/owned-child-e2e.test.ts` now runs the runner verb `flow` on
the parent run and on the resumed child run, and asserts that the verified
run log holds one `start` record from the local principal whose owner is the
`ownerId` of the ext-pi manifest. This closes the ext-pi part of gate 5 of
increment 1. The evidence is under `B2/C1/impl-r1`.

### Gated subtasks

- B15, B16 and B17 serve actor-flow increment 2. Section 6.2 of the design
  record requires that the operator review the threat model before
  increment 2 serves any route, and section 4 requires that review before an
  actor or restricted body leaves the owning account. The record is
  `doc/research/actor-flow-route-threat-model.md` (B4). The operator has not
  reviewed it. B15 adds `GET /v1/runs/{id}/routes` with JSON batches of the
  public class. B16 adds its SSE form and `GET /v1/routes` over the manager
  log. B17 serves the actor class to principals with observe and control.
- B18 is a second patch to `crypton-x509-validation` 1.9.1 that adds an
  `AltNameIP` branch to `isIncludedIn`, applied through
  `nix/haskell-overrides.nix`. A new dependency patch needs operator
  authorization. It is optional, because B10 already refuses those chains.
- WM-025 and WM-026 are not complete until B15 and B16 land, because
  increment 2 lands inside them.

### Open tracker items

- `acat-dxos` stays open. The Integrator kept it open with the B3
  evidence, because three runs cannot prove that the closed-release cause
  is gone. The harness race that B3 found is `acat-2ua3`.
- `acat-nwrj` stays open. The Client-facade check passed at N8 in B3 and in
  step 11 of this gate. Its closing condition is one run at N1 with every
  503 line classified.
- `acat-1dfc` stays open. B1 and B2 repaired its medium findings 1 to 4.
  Subtask C1 of part 2 resolved finding 5 (the ext-pi checks and the ext-pi
  part of gate 5). Subtasks C2, C3 and C4 of part 2 added the retention
  that finding 2 names: the manager log is sealed into segments and pruned
  below a protected floor. The low findings remain.
- `acat-62j0`, the F16 fess findings, stays open.
- `acat-response-ingestion-budget-zaoi` is closed by B5, B6 and B7. The
  review findings are `acat-b5-response-review-findings-k96b`,
  `acat-b6-response-review-findings-gxmf` and
  `acat-b7-stream-review-findings-n6v5`.
- `acat-tls-name-forms-6gbo` is closed by B10. Its fess findings are
  `acat-3iof`.
- `acat-en4g`, increment 2, stays open. B4 wrote its threat model, and its
  serving waits for the operator review.
- The fess findings of the subtasks are `acat-76le` (B1), `acat-3mgw`
  (manager-log retention, which blocks WM-042), `acat-r4vj` (B2),
  `acat-2ua3` (B3), `acat-55qg` (B4), `acat-ec5s` (B8), `acat-8tzp` (B9),
  `acat-b11-fess-g9wh`, `acat-b12-fess-fw1z`, `acat-b13-fess-en44` and
  `acat-b14-fess-gehi`. The medium finding of B13 asks for an operator
  ruling on the redaction exception for the runtime `targetLabel`
  `acp:mixed-adapter` in run snapshots.

### End-of-part review

Two lenses read `9a641dd8..2f0848b1`, packages and safety. Both returned
"approve with notes" with no critical or high finding, and no fix round ran.
The safety lens ran an incremental Werror build of `agentic-run` and
`routing-fixed-point-probe` with `-ftui-tests` and then `tui-journey` at N1
and N8 on `2f0848b1`. Both journeys passed with every `FLOW-ASSERT` and the
same consent chain as step 12 of the gate. The packages lens ran no check.
The findings that the list below marks as not filed are now in one
follow-up item, `acat-phase-b1-review-followups-dk1v`.

- Medium, resolved by Phase B part 2 subtask C5. The download quota was one
  place, and a second concurrent download refused at once. The quota is now
  two places. A download that finds both places charged waits up to five
  seconds for a place, before the file slot and with no lock held, and then
  refuses with 429 `storage-quota`. A total deadline of 300 seconds aborts
  a response at its next write and returns its place. The `pages` mode of
  `manager/test/service_http.py` has a two-client download case.
- Medium, resolved by Phase B part 2 subtask C6. `GET /v1/requests` and
  `GET /v1/runs` now read their members in keyset windows of at most 1024
  identifiers. A page set holds only the pages of its current window, and
  the page after the last page of a window builds the next window and
  renews the set. `page.totalItems` is a count taken at set creation. The
  overview lists and the decision collection refuse with `view-too-large`
  above 1024 live items. `doc/api/README.md` states the windows. The open
  C6 audit findings are in `acat-c6-keyset-windows-fess-findings-7ufp`.
- Medium, resolved by Phase B part 2 subtask C7. The service bound no
  legacy retention root. It now binds configured roots read-only through
  the `--legacy-history ROOT=PROFILE` option of `--manager serve`.
  `/v1/runs` and `/v1/runs/{id}` serve their entries, and case 10 of the
  `pages` mode of `manager/test/service_http.py` checks them through the
  running manager.
- Medium. The Name Constraints check has no scenario for `rfc822Name`, URI
  or `directoryName` subtrees, distance fields, an undecodable extension or
  subjectAltName, or a constrained `caFile` certificate off the path. This
  is item 1 of `acat-3iof`, which stays at P2.
- Medium, status. WM-025 is partial. Route-class authorization, cursor
  binding to the authorization revision and 410 after a restore wait for
  B15 to B17.
- Low. The Name Constraints check reads the constraints of every
  certificate in the `caFile`, so an unrelated constrained CA can refuse a
  valid chain, and it checks an IPv6 host literal as a DNS name. Both fail
  closed, and `doc/api/README.md` does not state them.
- Low. The warp-tls plaintext refusal bytes are not well-formed HTTP, the
  allowed-peer refusal from a non-loopback address is not exercised, and a
  slow body with no body byte is not checked (`acat-8tzp`).
- Low, not filed. The WM-023 scope change during retained responses is
  shown only as an observe-only scope boundary, because no local operation
  changes the scopes of a credential while the manager serves.
- Low, not filed. An event stream holds no Store reader charge for its
  lifetime, so only the subscription quota and `globalConnections` bound
  the number of streams, and many streams contend for reader places during
  their batch reads.
- Low, not filed. When a run fails before it carries its held controls,
  for a reason other than a cancel, the held controls get no
  acknowledgement if the process exits first. The run never started, so
  only the honesty of the acknowledgement is affected.
- Low, not filed. Some assertions of the modes `boundary` and
  `events-lifecycle` accept two refusal codes (400 or 404, and 429 or 503).

### Package status

| Package or item | Status | Evidence |
| --- | --- | --- |
| WM-023 (`acat-wm-023-d20b`) | Met, with the scope-change item shrunk | `B/B8/impl-r1`, gate steps 7 and 11 |
| WM-024 (`acat-wm-024-28bb`) | Met, with the non-loopback peer and IP Name Constraints acceptance outside part 1 | `B/B9/impl-r1`, `B/B10/impl-r1`, gate steps 10 and 11 |
| WM-025 (`acat-wm-025-3utw`) | Partial: the frozen resources and served legacy history are met, and the route items wait for B15 to B17 | `B/B11` to `B/B13`, gate step 11 |
| WM-026 (`acat-wm-026-qo1e`) | Met for `/v1/events`, and route SSE waits for B16 | `B/B14/impl-r1`, `B/B7/impl-r1`, gate steps 8, 9 and 11 |
| Increment 2 (`acat-en4g`) | Gated by operator review | `doc/research/actor-flow-route-threat-model.md` |
| `acat-response-ingestion-budget-zaoi` | Met and closed | `B/B5/impl-r2`, `B/B6/impl-r1`, `B/B7/impl-r1`, gate step 8 |
| `acat-tls-name-forms-6gbo` | Met and closed by refusal | `B/B10/impl-r1`, gate step 10 |
| Increment 1 review findings 1 to 4 | Met | `B/B1/impl-r1`, `B/B2/impl-r1`, gate steps 5 and 7 |
| B18 | Gated by operator authorization | none |

The Integrator closed WM-023 (`acat-wm-023-d20b`), because every review
verdict for it is met. WM-024 and WM-026 stay open, because a subtask review
for each said partial. WM-025 and `acat-en4g` stay open.

### Next action

1. The operator reviews `doc/research/actor-flow-route-threat-model.md`
   (B4) and accepts or refuses public-class serving (B15 and B16) and
   actor-class serving (B17) as separate decisions, recorded in the
   governing goal. After acceptance, B15, B16 and B17 land, and the route
   checks of this gate run.
2. The operator decides on B18.
3. Phase B part 2 follows: WM-027, actor-flow increment 3 (`acat-c18n`),
   WM-028 with the negative checks of increments 2 and 3 and the
   cause-replacement sites, and G2 with its witness of protected
   observation with mutations unavailable.

Accepted state is unchanged at WM-001 to WM-022 and G0 and G1. Part 1 closes
no gate.

## Actor-flow increment 1 of 2026-09-29

The operator accepted Phase A on 2026-09-29 and kept the file-slot and
reader-capacity wait of commit `fe7a2f20`. The resume workflow then landed
actor-flow increment 1 (`acat-e6cp`, then `acat-5m60`) under the operator
direction for fast validation, as subtasks F0 to F16 after `4496dbe4`. The
run completed every subtask and did not stop early. Its last subtask commit
is `d4ec7a6d`, and the closeout commit that follows it changes only this
section. The section "Phase B part 1 of 2026-09-30" above supersedes this
section where they differ. Where any section below differs, this section
supersedes it, and the sections below remain as chronology. The
contract is `doc/research/actor-flow-amendment.md`, `runtime/BROKER.md` and
the section "Manager log" of `manager/STORAGE.md`. The evidence of each
subtask is under `F/<subtask>/impl-r1` or `impl-r2` in the resume directory.

| Subtask | Commit | Result |
| --- | --- | --- |
| F0 | `6e63a8b1` | The store, artifact and draft checks pass after the file-slot wait, and no check name claims fail-fast admission. |
| F1 | `b5da8c1c` | The golden `hello-events.ndjson`, the version-1 engine codecs, `EnginePermission` with its ACP report, and the amendment record. |
| F2 | `050f7f46` | The strict `Request` codec and the exact `El` codec beside `questionJson`. |
| F3 | `e05aeab4` | `Agentic.Runtime.Flow`: the record, the seventeen schemas, the strict line codec, the body codecs and the writer. |
| F4 | `7fa6b6dd` | The run log `flow.ndjson` at `runMachineWith`, with the `start` record and one `event` record for each line of `events.ndjson`. |
| F5 | `6abc9262` | `flowBroker` carries the scheduler operations through the run log, and the receiver acts on the decoded value. |
| F6 | `e573b68e` | The direct `inProcessBroker` paths use the run broker, and person answers name their sender. |
| F7 | `02624d0e` | The run-log reader and the verb `agentic-run flow`. |
| F8 | `585b7e63` | The reference trace, the storage ratio, the ACP permission scenario and the uncertainty of a killed run. |
| F9 | `23309b63` | The manager-log writer with its lifetime and shutdown notices. |
| F10 | `99af03b1` | Command, receipt and failure records in the admission transaction. |
| F11 | `782cea77` | Review records and local administration records. |
| F12 | `25d648af` | Start, discard and control relays. |
| F13 | `17d4c08e` | Command notices, review endings and request endings. |
| F14 | `617deabd` | The manager-log reader, its joins with run logs, and the consent check. |
| F15 | `9da234ec` | The `FLOW-ASSERT` checks of `tui-journey` and the control `tui-flow-approve-fault`. |
| F16 | `d4ec7a6d` | The gate of increment 1, a repair of `cli/test/PolicyProbe.hs`, the constructor `ReadFlow` in the manual, and this section. |

### Delivered behavior

- A machine run with a run store writes the run log `flow.ndjson` in that
  store. The first record is `start`. Each line of `events.ndjson` has one
  `event` record, written before the line, and `events.ndjson` keeps its
  bytes. Questions, engine starts, turns, engine results, answers, controls,
  steering and permission reports are records of the run log.
- `flowBroker` appends each record before delivery, and the receiver acts on
  the value that it decodes from the appended bytes. `DataBroker` keeps its
  nine operations. A failed run-log append fails the run through the
  observer-failure path. A control that arrives before the run log exists is
  held, and the run appends and delivers it through `flowBroker` after its run
  log opens and before activation forwards the acknowledgement, as the section
  "Carriage" of `runtime/BROKER.md` states.
- A serving manager writes one manager log for each Store stream identity,
  `flow/<stream>.ndjson` in its private root, outside SQLite. It records each
  command after the Store admits it and before the commit, synchronized to
  disk, and each receipt, review, start, discard and control relay, command
  notice, review ending, request ending, lifetime, shutdown and local
  administration change. A command whose record cannot be written, or whose
  appended record decodes to another value, is refused with
  `storage-unavailable`, except a cancel, which proceeds and is named in a
  later gap notice. At its ceiling the log refuses an ordinary command with
  `storage-quota` and keeps the cancel reserve.
- `agentic-run flow PATH... [--follow] [--route PREDICATE] [--from CURSOR]`
  reads run logs and manager logs as the owning account. It verifies claim
  checks, joins each `event` record to its line of `events.ndjson`, joins the
  manager log to the run logs, reports the states of section 3.6 of the design
  record, and verifies the consent chain of each start relay. It reads a
  manager log with its sealed segments, prints global positions and names the
  retained floor of each manager log. A reply or a consent chain that crosses
  the floor is reported as pruned, not as a failed verification. It exits 1 on
  a failed verification and 2 when the flow is uncertain.
- Increment 1 makes no `/v1` change. `doc/api/openapi.yaml` is unchanged since
  `4496dbe4`. It adds no service subscription, no live re-route and no
  enforcement at any writer.

The manager log grows across lifetimes. The writer seals the active file into
segments under `flow/sealed/<stream>/` at the segment size
S = max(65536, (L - R) div 16), with global positions that continue across
segments. The Store pruner removes the oldest sealed segments while their
records are older than 604800 seconds or the log holds more than
(L - R) div 2 bytes, and it stops at the first segment that names live work:
a request that is not terminal, a run that is not observed terminal, the
parent run of a live request or an ask without a reply. The newest sealed
segment and the active file stay. When live work holds the floor, the log can
still reach L minus R, and then every ordinary command and review
publication is refused with `storage-quota`. At a 64 MiB ceiling, L minus R
holds about 2929 simple journeys of 22193 bytes each. A log above the configured
`globalMutationLedgerBytes`, or one with an undecodable complete line, makes
every append of the lifetime fail, so ordinary commands are refused with
`storage-unavailable`. The manager records the reason once at open with the
fixed word `oversized`, `undecodable` or `io-failure`. To recover, the
operator stops the manager, moves `flow/<stream>.ndjson`,
`flow/sealed/<stream>/` and `flow/claims/<stream>/` out of the root or raises
`globalMutationLedgerBytes`, restarts it, and reads the archived log with
`agentic-run flow`. The pruner does not prune the SQLite command ledger:
`command_ledger_usage` keeps every command charged, and
`Commands.checkCapacity` still bounds steady-state admission under the same
`globalMutationLedgerBytes` ceiling. The section "Growth, open refusals and
recovery" of `manager/STORAGE.md` holds the details and the measured append
latency.

### Gate of increment 1

Subtask F16 ran the gate once on the tree of `9da234ec` with its repair, in
this order. Each check has a `.log` and an `.exit` file under
`F/F16/impl-r1`, and failed first runs are under `F/F16/impl-r1/failed-r0`.

1. `make -C doc check` passed (`01-doc-check`).
2. The incremental Werror build of all targets with `-ftui-tests` passed
   (`02-allbuild`). Its first run failed, because `cli/test/PolicyProbe.hs`
   still matched the single path of `ReadFlow` that F14 had changed to a
   list of paths. The repair renders the list of operands.
3. `doc/api/openapi.yaml` and `runtime/src/Agentic/Runtime/Broker.hs` are
   unchanged since `4496dbe4`, and `DataBroker` has exactly nine fields
   (`03-api-broker`). The first run of this check counted one field because
   of a defect in the counting expression of the check.
4. `bash manager/ci/contract.sh` passed (`04-contract`).
5. `tui-model-test` passed at N1 and N8 (`05-model-N1`, `06-model-N8`).
6. The source-boundary check passed (`07-source-boundaries`).
7. `runtime-contract-test` passed at N8 (`08-runtime-contract`). It holds
   the codec round trips, the carriage tests and the reader tests.
8. `engine-api-test` passed (`09-engine-api`).
9. `test/progress_probe.py` passed with the golden comparison and the
   reference trace of section 3.5 (`10-progress-probe`). The storage ratios
   were 0.959 to 1.577.
10. `test/lineage_probe.py` passed at N8 (`11-lineage-probe`).
11. `test/control_probe.py` and `test/person_control_probe.py` passed at N8
    (`12-control-probes`).
12. `test/flow_probe.py` passed (`13-flow-probe`): attribution, the three
    retry forms, carriage, and the uncertainty of a killed run. Its carriage
    check is the structural bypass check of gate 10.
13. `manager-command-check flow` passed at N8 (`14-command-flow`).
14. `manager-command-check` with `command_contract.py` and
    `credential_cli.py` passed at N8 (`15-command-check-N8`).
15. `manager-approval-check flow-review` passed at N8
    (`16-approval-flow-review`).
16. `manager-admission-check flow-relay` passed at N8
    (`17-admission-flow-relay`).
17. `manager-admission-check` passed its restart, shutdown and main modes at
    N8 (`18-admission-check-N8`).
18. `manager-worker-check` with `worker_evidence.py` passed at N8
    (`19-worker-check-N8`).
19. `manager-store-check` passed its quota, restart, main, admission-data and
    terminal-admission modes at N8 (`20-store-check-N8`).
20. `manager-approval-check ingestion` passed at N8 (`21-ingestion-N8`).
21. `manager-draft-check` with `draft_contract.py` passed at N8
    (`22-drafts-N8`).
22. `manager-artifact-check`, `manager-history-check` and
    `artifact_contract.py` passed at N8 (`23-artifacts-N8`).
23. `tui-journey` passed at N1 and then N8 with every `FLOW-ASSERT` and a
    verified consent chain (`24-journey-pair`, fixture root
    `/Users/johnw/Products/k.M0a5ItPm/tmp/af-f16-journey.1DVlMYC1`). In both
    runs the chain was review 7, approve 8, receipt 9, start relay 10 and run
    start 0. Each manager log held 26 records in 22193 bytes, and the run-log
    storage ratio was 1.407 and 1.408.
24. The control `tui-journey-broken-answer` failed with "JOURNEY-ASSERT typed
    answer is not JSON false" (`25-journey-control`).
25. The control `tui-consent-control` failed with "detail-view key approved a
    review" (`26-consent-control`).
26. The control `tui-flow-approve-fault` failed with "FLOW-FAULT the approve
    append failed and the manager refused the approval with
    storage-unavailable" (`27-approve-fault`).
27. The ext-pi checks did not run to a result (`28-ext-pi`,
    `28b-ext-pi-vitest-integration`), as the next list states.
28. `make -C doc check-haskell` passed (`29-doc-check-haskell`). Its first
    run failed with "manual does not mention compiler-exported child:
    Agentic.Cli.Command.ReadFlow". The repair names the constructor
    `ReadFlow` in the manual entry of `Command`.
29. `bash engine/acp/ci/acp.sh` passed its 23 scenarios, including the
    permission record (`30-acp`).
30. `bash cli/ci/routing-config.sh` passed (`31-routing-config`).
31. `bash cli/ci/examples.sh` passed its 10 programs (`32-examples`).
32. `bash engine/agent-deck/ci/deck.sh` passed its 10 scenarios (`33-deck`).
33. `bash tui/ci/tui.sh` passed last (`34-tui-ci`). It covers TUI local
    mode.
34. `make -C doc check` passed again after the manual repair
    (`35-doc-check-final`).

### Checks not run

- `cli/ci/policies.sh`, `manager/ci/approval.sh`, `manager/ci/controls.sh`,
  the `admission_audit.py` mutation audits, mutant suites, stability samples
  of more than a few starts and `-fforce-recomp` builds. The operator
  direction of 2026-09-29 removes them from routine validation. The gate ran
  the check binaries of the admission, command, store, ingestion, draft and
  artifact scripts directly at N8, without their audit steps.
- `bisim/ci/tier0.sh` and every Lean or oracle check. The operator direction
  forbids them for this run.
- The N1 runs of the runtime and manager checks that gate 11 of the design
  record names. The operator direction drops repeated N1 and N8 runs of
  checks other than the journey, so each ran once at N8.
- `manager/ci/supervision.sh` and `manager/ci/vertical.sh`. Gate 11 does not
  name them, and Phase A did not run them.
- `engine/acp/ci/route-live.sh`, which needs a paid provider.
- The ext-pi checks `npm run check`, `npm test` and
  `npm run test:integration`. The Pi fork at `~/src/fork/pi` that
  `ext-pi/node_modules` links has no built `dist` directories, so TypeScript,
  vitest and the integration runner cannot resolve `@earendil-works/pi-tui`,
  `@earendil-works/pi-coding-agent` and `@earendil-works/pi-client`. A build
  of the fork changes files outside the worktree, which this run may not do.
  Increment 1 changes nothing under `ext-pi` and adds only exports to
  `Agentic.Runtime.Protocol` and `Agentic.Runtime.Frontend.Protocol`.
- The added latency of each synchronized manager append (gate 9) is not
  measured. The growth of the manager log is measured above.
- Gate 6 of the design record, a `/v1` fail-over and a redirect from TUI
  local mode, each shown in the run log. `test/control_probe.py` checks these
  from events only, and the fail-over of `test/flow_probe.py` uses the
  controlled machine mode.
- The part of gate 5 that shows the owner that an ext-pi launch declares. It
  depends on the ext-pi checks above.
- The revalidation of `broker-api-default` (`678326b`) that gate 11 names.
- The negative control of check 9 (a golden file with one changed byte) and
  the consent control of the design record (the verb on a manager log with
  one changed review byte) did not run again in the F16 gate. Their evidence
  is `F/F1/impl-r1/F1-golden-control.log` and
  `F/F14/impl-r1/F14-consent-negative.log`. The golden comparison and both
  readers did not change after those runs.

### End-of-increment review

Two review lenses, conformance and safety, examined `4496dbe4..d4ec7a6d`.
Each returned "approve with notes" and reported no critical or high
finding. No fix round ran. The safety lens ran `tui-journey` at N1 and then N8 again after an
incremental build with `-ftui-tests`, and both runs passed with every
`FLOW-ASSERT` and a verified consent chain (fixture root
`/Users/johnw/Products/k.M0a5ItPm/tmp/review-flow.JmUrFfcw`).

Issue `acat-1dfc` holds these findings. The medium findings are:

1. A cancel whose appended record decodes to a value other than the admitted
   command is refused with `storage-unavailable`
   (`manager/src/Agentic/Manager/Commands.hs`, `recordAdmittedCommand`). A
   cancel is exempt only when its append fails. No check covers a cancel
   with the lossy codec.
2. The manager log `flow/<stream>.ndjson` grows across lifetimes and nothing
   prunes it before Phase G. At `L` minus `R` every ordinary command and
   review publication is refused with `storage-quota`. A log that is larger
   than a lowered ceiling, or that holds a complete line that does not
   decode, makes each append of the lifetime fail, and the service then
   refuses ordinary commands with `storage-unavailable`. `manager/STORAGE.md`
   does not state this limit or the recovery procedure. Subtasks C2 to C4
   of part 2 resolved this finding with sealed segments and pruning below a
   protected floor.
3. `manager/STORAGE.md` says that no local path enters a body. The review
   body holds the exact binding bytes, which name the frontend invocation
   path, the run-root identity and the target arguments. The sentence does
   not state current behavior.
4. A control delivered before activation of a store-backed run does not pass
   through `flowBroker`. The run log shows only its acknowledgement event,
   with no `control` record. `runtime/BROKER.md` states this limit, but it
   differs from Delta 1a of the design record.
5. The ext-pi checks and the ext-pi part of gate 5 have no result, as
   "Checks not run" states.

The low findings are these. A failed failure-reply append after a rollback
leaves no gap entry. A review record that a later pre-commit step rolls back
has no ending. Offline credential administration writes no manager-log
record. An engine ask without a scope is refused by `flowBroker`, and no
test shows that a store-backed path cannot reach it. A receipt or relay
whose decoded value differs from the ledger is carried as the ledger value
with no gap entry. The reader loads the whole log prefix before it checks
the line bound, and `--follow` accepts only one run log. Run-log bodies and
the output of the verb are not redacted, and `runtime/BROKER.md` does not
say so. A failed append of an ACP permission report fails the turn after the
grant was sent. The pending slot of a command record is set after the
append, so a deadline in that window leaves the record uncertain.

### Open tracker items

- `acat-5m60` and `acat-e6cp` are closed.
- The F16 fess findings, including the gate 6, gate 5 and gate 11 checks
  that did not run, are tracked in `acat-62j0`.
- The fess findings of each subtask stay open: `acat-c13k` (F0), `acat-thc9`
  (F1), `acat-h9oi` (F2), `acat-mkh7` (F3), `acat-14ht` (F4), `acat-actk`
  (F5), `acat-hxm7` (F6), `acat-amd8` (F7), `acat-iugd` (F8), `acat-5wa8`
  (F9), `acat-b1yt` (F10), `acat-o7ax` (F11), `acat-4pn3` (F12), `acat-64v1`
  (F13), `acat-ow77` (F14) and `acat-j11d` (F15).
- `acat-en4g`, increment 2, service route subscription, lands inside WM-025
  and WM-026. `acat-c18n`, increment 3, live re-route and asks answered by
  people, lands between WM-027 and WM-028.
- `acat-1dfc`, the findings of the end-of-increment review above.
- The open findings of the Phase A section below are unchanged, including
  `acat-response-ingestion-budget-zaoi` and `acat-tls-name-forms-6gbo`.

### Next action

1. Phase B starts at WM-023 under the fast-validation rules and continues
   through WM-028 and G2. Its first subtask repairs the four medium review
   findings of `acat-1dfc` in code or documentation: the cancel exemption
   on a decode mismatch, the growth limit and recovery of the manager log,
   the review-body sentence in `manager/STORAGE.md`, and the preflight
   control record. Increment 2 (`acat-en4g`) lands inside WM-025 and
   WM-026, and increment 3 (`acat-c18n`) lands between WM-027 and WM-028.

Accepted state is unchanged at WM-001 to WM-022 and G0 and G1. Increment 1
closes no package and no gate.

## Phase A TUI service journey of 2026-09-29

The resume workflow continued after the stopping point below under the
operator direction of 2026-09-29 for fast validation. It committed five
subtasks after `43585dd3`, ran the end-of-phase review of Phase A, and
stopped without a stop condition after its last stage. The TUI now
completes one uninterrupted service journey through a running manager. The
work branch head was `b944407eb1142cbfa69a8ef76edc6e76e0cef739`. The
section "Actor-flow increment 1 of 2026-09-29" above supersedes this
section where they differ. Where any section below differs, this section
supersedes it, and the sections below remain as chronology.

| Subtask | Commit | Result |
| --- | --- | --- |
| A5S2b | `d02b6253` | Bounded-wait Store admission, the run-control route before the first projection, and an event stream that stays open under a short Store holder. Evidence under `A/A5S2b/fast-impl-r1`. |
| A6A7 | `dad4a490` | Live service progress in the TUI, and the answer JSON `false` to the pending Bool question. Evidence under `A/A6A7/fast-impl-r1`. |
| A8A9 | `2751ffab` | The offered recovery retry, terminal recognition and verified retrieval. Evidence under `A/A8A9/fast-impl-r1`. |
| A10A11 | `fe7a2f20` | Exclusive saving of the verified bytes from the TUI, and `tui-journey` as the milestone gate. Evidence under `A/A10A11/fast-impl-r1`. |
| A13A14 | `b944407e` | The held routing documentation, the manual and TUI documentation of the journey, this section, and the final gate. Evidence under `A/A13A14/fast-impl-r1`. |

Nothing from this workflow is published, and the canonical branch `tui`
stays at `6b7c90b79b47c85d07162bb11d038349dbac9131`.

### What the TUI performs

`agentic-run --tui --service CLIENT_PROFILE` performs this journey through
the protected HTTPS manager and the public `Agentic.Manager.Client` facade:

- It browses the manager catalogue, creates one request, and submits
  literal inputs, including Unicode text with exact request bytes.
- It shows the exact manager review. Only `y` in the summary view approves,
  and every approval key press has one numbered visible outcome.
- It follows the run in the live monitor. One single-flight observation
  lane reads the request, the review, the receipt of a retained command, and
  the run snapshot, controls and pending decision, and it repeats that read
  on a one-second timer. A declared refusal keeps the last complete
  observation and marks it stale.
- It answers the pending question through the code-directed encoding of the
  person view, so the input `false` for a `flag` question is sent as the
  JSON value `false`. It supports the codes `text`, `verdict`, `flag` and
  `receipt`.
- It sends the recovery retry that the run controls offer, once, with the
  entity tag of the displayed control observation as its precondition.
- It recognizes the terminal state only from the snapshot runtime status.
- It downloads the verified result once through `Client.downloadVerified`,
  shows its size and SHA-256 digest, and saves the unchanged bytes at a new
  absolute path with mode 0600 through the exclusive save function.
- It sends every command once. An uncertain send is repeated only after the
  explicit confirmation of an exact resend. An internal fault stops every
  further mutation and automatic refresh.
- `C-c` always detaches, and `q` detaches when no answer editor has the
  keys. Detaching does not cancel manager-owned work.

The manual entry for `--service` in `doc/agent-cat.texi` and the section
"Service mode" of `tui/README.md` state the complete behavior and list the
unsupported features. The TUI offers no cancellation, steering, redirect,
failover or abandon, no structured answer editor, no captured or other
non-literal inputs, no withdrawal or discarding of a request, one run at a
time, no history, lineage or export, and no event-driven refresh. It does
not reconnect after a manager restart or a credential revocation, switch
endpoints, observe earlier runs after a TUI restart, bootstrap an Overview,
or have an accepted layout at 40x12 or 80x24.

Routing catalogue discovery supports no TLS, and the routing documentation
now states it. Subtask A13A14 applied the held diff
`A/A5G2d/impl-r2/held-doc-edits.diff` with the two `doc/tui-design.md`
corrections of `acat-nay0`. This supersedes the statements below that the
documentation edits stay held and that seven files describe TLS discovery.

### Checks and evidence

Under the operator direction of 2026-09-29, validation uses incremental
Werror builds of the needed targets, targeted checks of the changed layers,
and `tui-journey` at N1 and then N8. The stage timeouts were limits of 15
to 30 minutes for each command. The incremental all-target build took
about one minute, and `bash tui/ci/tui.sh` took about nine minutes. The
final gate ran on the final tree in this order, and
each check has a `.log` and an `.exit` file under `A/A13A14/fast-impl-r1`:

1. `make -C doc check` passed (`01-doc-check`).
2. `make -C doc check-haskell` passed (`02-doc-check-haskell`). Its first
   two runs failed, first because the manual did not name the constructor
   `TuiService` and then because the member ledger was stale. The fix names
   the constructor and regenerates `doc/haskell-member-coverage.texi`
   (`02a-update-inventory`). The failed logs are under `failed-r0`.
3. The incremental Werror build of all targets with `-ftui-tests` passed
   (`03-allbuild`).
4. `bash manager/ci/contract.sh` passed (`04-contract`).
5. `tui-model-test` passed at N1 and N8 (`05-model-N1`, `06-model-N8`).
6. The source-boundary check passed (`07-source-boundaries`).
7. `tui-journey` passed at N1 and then N8 (`08-journey-pair`, fixture root
   `/Users/johnw/Products/k.M0a5ItPm/tmp/fast-final-journey.CGeIm2cm`).
8. The control `tui-journey-broken-answer` failed with
   "JOURNEY-ASSERT typed answer is not JSON false" (`09-journey-control`,
   root `/Users/johnw/Products/k.M0a5ItPm/tmp/fast-final-journey-control.rEj6tbgN`).
9. The control `tui-consent-control` failed with "detail-view key approved a
   review" (`10-consent-control`, root
   `/Users/johnw/Products/k.M0a5ItPm/tmp/fast-final-consent-control.xik5EAi7`).
10. `bash tui/ci/tui.sh` passed last (`11-tui-ci`).

`tui-journey` is actual keyboard interaction through a PTY with the
protected HTTPS manager and deterministic native frontend processes. Its
runner is the deterministic `routing-fixed-point-probe` fixture, and no
paid provider takes part.

After the session, `tui-journey` runs `agentic-run flow` on the manager log
and the run store, and asserts each step of the consent chain and every user
command with a `FLOW-ASSERT` message. The control `tui-flow-approve-fault`
renames the manager log before the approval, and it requires the manager to
refuse the approval with `storage-unavailable` and to start no run.
`manager/STORAGE.md` describes both.

The two controls change the harness, not the TUI. `tui-consent-control`
sends `y` in the summary view at the step that expects the detail-view
refusal, so it shows that the journey assertion detects an unexpected
approval. It does not break the TUI detail-view guard. The guard itself is
covered by the model tests and by mutants M1 and M2 of subtask A4, which
Phase A did not run again. `tui-journey-broken-answer` types `true`, and the
check that maps the rendered answer "no" to JSON `false` detects it. The
harness branch that compares the answer in `answers.json` with JSON `false`
by identity has no failing control.

`tui-journey` passed in subtask A6A7 only on its eleventh attempt and in
subtask A10A11 only on its third attempt. The commit messages of those
subtasks record the failed attempts. The final gate and the end-of-phase
review each passed the journey at N1 and then N8. No stability sample of
the journey exists.

These checks were not run on the final source: `cli/ci/policies.sh`, the
approval and controls mutation audits, `manager/ci/supervision.sh`,
stability samples of more than a few starts, mutant suites,
`-fforce-recomp` builds, and `manager-store-check`,
`manager-artifact-check` and `manager-draft-check`. The final gate only
compiled the last three suites, and none of them ran after the Store change
of commit `fe7a2f20`.

### Accepted state

Accepted state is unchanged at WM-001 to WM-022 and G0 and G1, which is 22
of 44 packages and two of six gates. This milestone closes no package and no
gate. WM-023 (`acat-wm-023-d20b`) is still in progress. The journey is the
Phase A exit evidence.

The end-of-phase review of Phase A ran as two lenses over `43585dd3..b944407e`
on a clean worktree, and both returned "approve with notes". The journey
lens rebuilt `agentic-run` and `routing-fixed-point-probe` with
`-ftui-tests` and passed `tui-journey` at N1 and then N8 (evidence under
`A/phaseA-review-journey`, fixture root
`/Users/johnw/Products/k.M0a5ItPm/tmp/review-journey.HSLddj9N`). The exit
lens found that the Phase A exit criteria, as the operator direction of
2026-09-29 amends them, are met. No fix round ran. The review findings are
listed under "Open findings". Phase A is ready for the operator's acceptance,
and the file-slot extension below still needs the operator's
confirmation.

### Operator decisions

- 2026-09-28, routing discovery without TLS. Catalogue discovery builds no
  TLS manager. An https catalogue endpoint fails as `tls-not-supported`, and
  discovery never downgrades it to plain HTTP. The manager's HTTPS transport
  and client do not change. `acat-routing-discovery-tls-3m8u` records the
  restoration of TLS as later work.
- 2026-09-29, fast validation and a working system first. The working TUI
  journey comes first. Each subtask has one implementer, one short `fess`
  audit and one Integrator commit. Every command finishes within 15 minutes,
  and the long suites above are not routine validation.
- 2026-09-29, bounded wait for Store admission. Commands, protected reads,
  event-stream batches and the admission coordinator steps wait for the
  Store gate and the configuration guard within the unchanged five-second
  allowance. A genuine timeout still returns `storage-unavailable`.
- Awaiting confirmation: commit `fe7a2f20` also makes the Store file slot
  and the reader capacity wait, and the Integrator accepted this pending the
  operator's confirmation. The decision above names only the Store gate and
  the configuration guard. Each lock starts its own five-second allowance,
  and Drafts adds another timed wait inside the file slot. One request can
  therefore wait more than five seconds in total, and it can reach the
  15-second response timeout of the TUI client. The client then reports an
  uncertain outcome, which the explicit resend handles.

The verbatim decisions are in `GOAL.md` of the resume directory.

### Open findings

- `acat-response-ingestion-budget-zaoi`, P1, protected-response ingestion
  contention.
- `acat-dxos` and `acat-nwrj`, P1, stay open for the Integrator to decide
  whether bounded-wait admission resolves them.
- Review finding, medium, not filed: a failed result retrieval stays failed
  for the rest of the session (`tui/src/Agentic/Tui/App.hs` near 500 and
  786). A declared refusal such as a transient `storage-quota` or
  `storage-unavailable`, or a read that finds no verified artifact yet, is
  kept as the result of the run, and neither automatic refresh nor `g`
  retrieves it again. The operator then cannot save the bytes of that run
  from the TUI, and the journey can fail when the final snapshot polls of the
  harness overlap the first retrieval. Item 1 of
  `acat-a8a9-fess-followup-6d1e` covers the "no verified result" part.
- Review finding, medium, not filed: the stacked five-second allowances
  that "Operator decisions" describes. Items 1 and 3 of
  `acat-a10a11-fess-followup-33k1` (P3) cover it. `manager/STORAGE.md`
  says that waiting and execution share one five-second allowance and then
  adds fresh allowances for the slot, so it does not state whether the waits
  add up.
- Review finding, low, not filed: `saveExact` in `tui/src/Agentic/Tui/Save.hs`
  returns a refusal when the link succeeds and the removal of the private
  file fails, although the bytes are published. It does not synchronize the
  file or its directory to disk. Item 4 of `acat-a8a9-fess-followup-6d1e`
  covers the first part.
- The check "existing file entry remains fail-fast" in
  `manager/test/ArtifactCheck.hs` now waits five seconds on a slot that its
  own thread holds, so its name is false (item 2 of
  `acat-a10a11-fess-followup-33k1`).
- Automatic refresh pauses while a deferral outcome is shown, with no bound
  (`acat-ftw9`, item 1 of `acat-a6a7-fess-followup-1exm`).
- `acat-i9aj`, P2, the PTY journey does not assert the composite install and
  the decision head.
- This run filed the non-blocking audit findings of each subtask as
  `acat-a5s2b-fess-followup-s9rl`, `acat-a6a7-fess-followup-1exm`,
  `acat-a8a9-fess-followup-6d1e`, `acat-a10a11-fess-followup-33k1` and
  `acat-a13a14-fess-followup-xznh`, all P3. This section applies items 2
  and 3 of `xznh`.
- The commit message of `d02b6253` names the contention checks G01 to G08,
  but G05 has no evidence file. G08 reran the G05 command after the fix.
- The manual now names the constructor `TuiService` of
  `Agentic.Cli.Command`, which resolves the omission that the sections below
  list. `acat-nay0` is resolved by the documentation of commit `b944407e`.
  The control 404 before the first projection and the event stream that
  ended under contention, which the section below lists, are fixed by
  commit `d02b6253`.
- The other open findings of the sections below are unchanged.

### Next action

1. The operator accepts Phase A and confirms or rejects the file-slot and
   reader-capacity extension of the bounded wait. The Integrator files the
   unfiled review findings above.
2. Fix the retrieval that stays failed, so that a declared refusal or a
   missing verified artifact allows a later bounded retrieval. Carry one
   deadline through the file slot, the configuration guard and the gate,
   or document the stacked total below the client timeout. Correct the
   fail-fast check names, and run `manager-store-check`,
   `manager-artifact-check` and `manager-draft-check` once each under
   `timeout 900`.
3. Land actor-flow increment 1 (`acat-e6cp`, `acat-5m60`).
4. Start Phase B.

To resume, run the toolchain check of the resume procedure below in the
worktree, confirm that HEAD is `b944407e` or a later commit of the
closeout of this run and that the worktree is clean, and rebuild with the build command of the first 2026-09-27 section
before any binary runs.

## Resume workflow stopping point of 2026-09-29

The resume workflow that started from checkpoint `wm023-20260923` ran again
after the Integrator committed the 2026-09-28 closeout as `212be27b`. Its
first recorded command started at 2026-09-28T20:30:32Z, and the last command
of its last roadmap subtask, A5S2, ended at 2026-09-29T13:58:47Z
(`Z/HANDOFF/impl-r1/H33-facts.log`). The run completed A5G2d, which applied
the operator ruling of 2026-09-28 on routing discovery and carried the A5G2c
work to two commits. It then ran A5S2, the S1 diagnosis round of the refocus
note, which escalated after one implementer round for the owner decision
that the subsection "Stop reason and owner decision" states. Accepted state
is unchanged at WM-001–WM-022 and G0/G1, which is 22 of 44 packages and two
of six gates. WM-023 (`acat-wm-023-d20b`) is still in progress. Phase A of
the remaining-scope report was not met at this stopping point, because the run did not reach its
exit check, and the run made no change for Phases B to G. This section and
`~/Documents/Obsidian/agent-cat-workflow-manager-remaining-2026-09-29.md`
described the state at this stopping point. The section "Phase A TUI service
journey of 2026-09-29" above supersedes them.

After this stopping point, subtask A5S2b applied the operator decision of
2026-09-29. Commands, protected reads, event-stream batches and the
admission coordinator steps now wait for the Store gate and the
configuration guard within the unchanged five-second allowance. A genuine
timeout still returns `storage-unavailable`. A protected read that
overlaps a commit runs again under the newer authorization generation
within that allowance. The mixed workflow and `tui-approval` passed at N1
and N8, and a smoke sample of six starts passed
(`A/A5S2b/fast-impl-r1`). The commit of A5S2b states the remaining
limitations.

### Objective, worktrees and environment

The governing goal of 2026-09-23 remains the current objective, with its
actor-flow amendment of 2026-09-26 and the operator decision of 2026-09-28
on routing discovery without TLS. Its verbatim text is in
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/resume-20260923/GOAL.md`.
It replaces Pi goal `mu629ta5-11s8ax`, revision 914, and it prevails over
older records where they conflict. Its task first-frontend-broker-workflow
is Phase A of the report, remaining-frontends is Phases C, D and E, and
operational-hardening-roadmap-closure is Phases B, F and G. The completed
tasks wm016-closure-plan, wm016-functional-closure,
wm016-integrated-validation, wm016-acceptance and broker-api-default stay
complete. The former Pi ledger under `.pi/goals` is not restored, and the
workflow orchestrator tracks the goal.

The worktree `/Users/johnw/src/agent-cat/.worktrees/tui` was recreated on
2026-09-23 after an unexplained removal, and it holds the work branch
`workflow-manager-checkpoint-20260923`. The former work worktree
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source`
is still detached at `b95ce6d1` with no local change. The canonical branch
`tui` stays at `6b7c90b79b47c85d07162bb11d038349dbac9131`
(`Z/HANDOFF/impl-r1/H33-start-binding.log`).

No procedure runs `nix develop` in any form. The operator generates the
direnv environment in the worktree with `de`. Every build, test and project
tool runs through `direnv exec .` from the worktree, with
`/Users/johnw/Products/k.M0a5ItPm/environment.sh` sourced inside that shell,
and `de` runs again when `flake.nix` or `flake.lock` changes or when direnv
reports a stale or blocked environment. Git and `obr` run in a plain shell.
At the stop the environment reported GHC 9.10.3, Cabal 3.16.1.0 and
`crypton-x509-validation` 1.9.1, and `nix` resolved to
`/nix/var/nix/profiles/default/bin/nix`
(`Z/HANDOFF/impl-r1/H33-doc-check-before.log`).

### Commits and subtask results

The Integrator committed A5G2d as two commits. The branch head is
`b31a56f388a8eec4e896a66daa4d2e3c44dd1e05`, whose parent is `bab6b09a`,
whose parent is `212be27b`. As read from the remote-tracking refs without a
fetch, `origin/workflow-manager-checkpoint-20260923` is still `b95ce6d1` and
`origin/tui` is `6b7c90b7`, so nothing from this workflow is published. The
subtask tables of the sections below stay current for A0 to A5, A12W,
A5S1D, A5R, A5G1 and the escalated A5G2, A5G2b and A5G2c.

| Subtask | Commit | Result and evidence ceiling |
| --- | --- | --- |
| A5G2d | `bab6b09a`, `b31a56f3` | Done after two implementer rounds, two verifier rounds and two `fess` audits. The round-1 audit raised two blocking findings, and the round-2 audit (`fess/A-A5G2d-r2.md`) is not blocking. Evidence under `A/A5G2d`. |
| A5S2 | none | Escalated after one implementer round, with its work uncommitted. No verifier ran and no `fess` audit exists (`Z/HANDOFF/impl-r1/H33-facts.log`). Evidence under `A/A5S2/impl-r1`. |
| A6–A14 | none | Not started at this stopping point. The section above records their later results. |

These are subtask results. None of them accepts a package or a gate.

### A5G2d: routing discovery without TLS

`bab6b09a` ("Spawn Runtime process groups through posix_spawn") holds the
Runtime part of the A5G2c change: `runtime/cbits/process_spawn.c`,
`runtime/test/ProcessGroupTests.hs` and the matching changes to
`ProcessGroup.hs`, `runtime/test/Main.hs`, `runtime/ci/capture.sh`,
`test/capture_build_evidence.py` and `agentic.cabal`. The Integrator built
that tree alone with all targets and tests under `-Werror`, and
`runtime-contract-test` at N1 and N8, `engine-api-test` and
`runtime/ci/capture.sh` passed (`A/A5G2d/integrate-r1/C1-build-test`,
package build and deterministic native fixtures). `b31a56f3` ("Refuse TLS
in routing discovery and pool help queries") holds the discovery change,
the help pool in `manager/src/Agentic/Manager/Profile.hs`, the gate
fixtures and an export of `doc/PLAN.org`. Without `doc/PLAN.org`, the
tracked delta of the two commits is identical to the tree that the
round-2 verifier bound (`A/A5G2d/verify-r2/V00-diff.patch`), and the two new
Runtime files have the digests of the A5G2c round-3 source
(`Z/HANDOFF/impl-r1/H33-commit-match.log`).

Routing catalogue discovery now builds only a plain `http-client` manager
with `defaultManagerSettings`. An https catalogue endpoint receives the
classified discovery failure `tls-not-supported` before any header is built
or any connection is opened, and discovery never retries it over plain HTTP.
The plain-HTTP rule in `cli/src/Agentic/RoutingConfig/V2.hs` is unchanged.
`http-client-tls` moved from the shared stanza to the library stanza, where
only `manager/src/Agentic/Manager/Client.hs` imports it. The manager's HTTPS
transport and its client are unchanged. `manager/test/ProfileCheck.hs` now
checks that help queries in flight after a decided failure are cancelled
and reaped. These statements supersede two older statements: the statement
of the subsection "Uncommitted A5G2c work" of the 2026-09-28 section that
discovery constructs the standard TLS manager and that no recorded check
shows cleanup after a cancellation, and the same TLS statement in the
subsection "Uncommitted A5G2 work" of the first 2026-09-27 section
(`acat-nay0`). Under the operator ruling, A5G2d removed or replaced nine
probe checks of TLS and authenticated discovery, which section 3 of
`fess/A-A5G2d-r2.md` lists.
`acat-routing-discovery-tls-3m8u` records their restoration as later work.

The round-2 verifier ran on the round-2 source (`A/A5G2d/verify-r2`). The
Werror build of all targets with tests passed, and so did the final build
(`V02`, `V03`, package build). The routing probe, `routing-config.sh`, the
Runtime contract suite, `profiles.sh`, `vertical.sh`, `dependencies.sh` and
`tui/ci/tui.sh` passed (`V04` to `V09`, `V11`, deterministic native
fixtures, with `tui.sh` a PTY fixture). `cli/ci/policies.sh` printed 8509
`PASS` lines and no `FAIL` line (`V13`). The 257-row catalogue check passed
at both descriptor limits, in 6.44 and 5.61 seconds of wall time (`V12`).
Every guard-breaking copy failed as intended, among them the pre-fix
discovery, an eager TLS manager, an https downgrade, a removed refusal, the
spawn flags, the nonblocking step, the process-library spawn, sequential
help and the round-2 help pool, and the copy was restored byte for byte
(`W01` to `W13`, `W99`). In implementer round 1 the Client-facade check
passed at N1 and failed at N8 with `503 storage-unavailable` on
`GET /v1/workflows` (`A/A5G2d/impl-r1/G21-client-check`, root
`/Users/johnw/Products/k.M0a5ItPm/tmp/a5g2d-client.riA5itgK`). It was not
rerun to a pass, and `acat-nwrj` holds it.

The documentation edits stayed held under the refocus note until subtask
A13A14 applied them. The held diff was `A/A5G2d/impl-r2/held-doc-edits.diff`. It covers the four files of the
A5G2c held diff and adds `doc/agent-cat.texi`, `doc/model-routing-v2.md`
and `doc/routing-v2-verification.md`. It applies cleanly to HEAD
(`Z/HANDOFF/impl-r1/H33-start-binding.log`), and `make -C doc check` passed
on a copy with it applied (`A/A5G2d/verify-r2/V14`). It lacked the two
corrections to `doc/tui-design.md` that `acat-nay0` names, and A13A14 added
them when it applied the diff.

### Uncommitted A5S2 work

A5S2 followed the refocus note: one diagnosis round on the S1 503 and the
closed release with a fresh N8 root, a fix with a regression test, and a
stop. On the HEAD source, the mixed protected-HTTP workflow at N8 failed
with `('mutation refused or uncertain', 'enqueue', 503,
'storage-unavailable')` at the fresh root
`/Users/johnw/Products/k.M0a5ItPm/tmp/a5s2-diag.olmh651n/N8`. Its server
record shows a reader admission refused with `ConfigurationBusy`, the
enqueue receipt response refused before it started, and then a service
preparation refused with `StorageUnavailable` and released as
`WorkerClosed` (`A/A5S2/impl-r1/S03-diag-mixed-N8`, deterministic native
fixture).

The implementer states this cause of the receipt-side 503, which is S1-a.
The HTTP owner composes the enqueue receipt with `withAuthorizedResponse`,
whose reader admission takes the configuration guard fail-fast. The
committed enqueue wakes the admission poll, and that poll holds the
configuration guard through its whole selection. The new `receipt-order`
check in `manager/test/AdmissionCheck.hs` orders the two threads with a
barrier. It failed on the HEAD source at N1 and N8 (`R08`, `R09`), passed
with the fix (`G02`, `G03`), and failed again with the fix reverted (`N02`,
`N03`), all deterministic native fixtures. No verifier or audit has checked
this cause.

The fix is in `manager/src/Agentic/Manager/Admission.hs`. While an enqueue
caller of the same request composes its receipt response, the admission
notification of the accepted enqueue is owed, and the last such caller
delivers it when its response ends, also when the response fails or the
caller is cancelled. `enqueueRequest` takes the response as a continuation,
`Application.hs` and `Service.hs` pass it, and the other callers in
`AdmissionCheck.hs` and `cli/test/ManagerApprovalProbe.hs` pass `pure`. No
Store, Configuration, Authorization, Commands or Transport module changed
(`A/A5S2/impl-r1/I01-diff-inspection.log`). The Werror build of all targets
passed (`B02`, `B03`, package build).

With the fix, the mixed workflow passed at N1 and failed at N8 (`M01`,
`M08`), a failure that the implementer attributes to an event stream that
ended when its next batch met Store contention. `tui-approval` passed at
N1 and N8 (`T01`, `T08`, actual UI interaction up to approval and
detach). The implementer then declared a sample of 40
starts before it ran (`S10-stability-declaration.md`), at root
`/Users/johnw/Products/k.M0a5ItPm/tmp/a5s2-sample.0hDUg0zF`. It allowed no
S1 signature. Of the 40 starts, 27 passed (`S13-sample-classification.log`,
`Z/HANDOFF/impl-r1/H33-facts.log`):

- Mixed workflow, 11 of 20 failed. Nine failed because
  `GET /v1/runs/<id>/control` returned `404 unavailable-resource`. One
  enqueue at N8 was refused with `503 storage-unavailable` before any
  commit, and the request stayed a draft that was not queued (`S202`,
  `F10`). One failed with a read timeout at N8 (`S205`).
- `tui-approval`, 2 of 20 failed, both at N1 (`S206`, `S209`), with "TUI
  preparation deadline after at most one operator-confirmed exact resend"
  after a serving-time release of the preparation.
- No enqueue receipt returned 503 after a committed enqueue.

The zero-S1 acceptance was not met, because the declared signatures include
the pre-commit enqueue 503 and the serving-time release.

The worktree holds five modified files, no untracked file and nothing
staged: `cli/test/ManagerApprovalProbe.hs`,
`manager/src/Agentic/Manager/Admission.hs`,
`manager/src/Agentic/Manager/Application.hs`,
`manager/src/Agentic/Manager/Service.hs` and
`manager/test/AdmissionCheck.hs`. In a plain shell with the operator Git
configuration, the SHA-256 of `git diff HEAD` is
`b5dcc5bebc476c589c529e1f05c55ba4c7e553af4b10740a53ac525396752a35`, and the
SHA-256 of `git diff` without `HEAD` is
`0d810296349285805fc018020b23ba52b415f540f3533b3d1b636d4ffd97f1a3`, the
value that the A5S2 records bind (`A/A5S2/impl-r1/Z99-final-binding.log`).
The two values differ only because the operator setting
`diff.mnemonicprefix` gives the two commands different path prefixes. With
`-c diff.mnemonicPrefix=false`, `git diff HEAD` hashes to
`01a06ff0ea4acb7c27fbe8591ae1aadd3cc16ebb0e9e3bef83e7fe02bb06ed37`
(`Z/HANDOFF/impl-r1/H33-start-binding.log`).

### Stop reason and owner decision

The implementer reports that the fix removes the receipt-side 503 but not
the S1 family, which comes from fail-fast contention under the settled Store
policy. The fix moves the contention onto admission coordinator work, which
has no contention budget. In the two `tui-approval` failures, the admission
poll and the preparation construction met Store contention from the next
read of the client. In the pre-commit enqueue 503,
`Commands.configuredCatalogues` refused the command under configuration or
Store contention and recorded nothing. The owner chooses one of four
decisions:

- (A) Allow admission poll selection and preparation construction a
  bounded contention retry for a step that was proven not entered or was
  rolled back, like the existing five-second `StoreBusy` retry of the
  ingestion head. No admitted operation would repeat. This extends
  fail-fast only for coordinator work.
- (B) Change protected-read and command admission from `FailFast` to
  `WaitWithinBudget` inside the unchanged five-second operation allowance.
  This relaxes fail-fast ordinary admission.
- (C) Make the configuration guard shared among readers and exclusive only
  for reload and close. This changes the contract of the configuration
  lock.
- (D) Keep the policy, accept the pre-commit 503 and the serving-time
  release under contention as honest outcomes, and change the acceptance
  so that the fixtures use the operator-confirmed exact resend and
  re-request the review.

Options (B) and (C) change settled Store policy, and option (D) changes the
acceptance of the refocus note. The operator decided on 2026-09-29 for
bounded-wait Store admission, and subtask A5S2b implemented that decision.
A5S2b also fixed the two product defects that this record found.
`GET /v1/runs/<id>/control` now answers before the first projection
consistently with the snapshot route, and an event stream now stays open
when its next batch meets a short Store holder.

### Open findings and authorizations

- A5S2, owner decision, as above. After the decision, A5S2 still needs a
  verifier run and one `fess` audit on its source before the Integrator
  commits it. The governing goal requires an audit at the end of every
  subtask, and A5S2 has none.
- `acat-dxos`, P1, stays open. The fresh N8 root records a service
  preparation refused with `StorageUnavailable` and released as
  `WorkerClosed`, and the implementer attributes the closed release to
  admission work that meets Store contention. That attribution has no
  verifier or audit.
- `acat-nwrj`, P1. The A5S2 root shows the same reader-admission
  `ConfigurationBusy` record beside the enqueue 503. The evidence does not
  establish whether the `GET /v1/workflows` 503 of A5G2d has the same
  cause.
- The round-2 audit of A5G2d left low findings that the Integrator filed:
  `acat-nay0` (P3, documentation phrases and the handoff TLS claim, whose
  handoff part this section applies), `acat-wluh` (P3, a check label that
  can name an unrelated failure), `acat-s3dz` (P3, no process trace in the
  https refusal check), `acat-ersl` (P3, the scope of the no-absolute-path
  ruling and of the rule never to signal a stored PID) and
  `acat-routing-discovery-tls-3m8u` (P2). Its finding L7, on evidence files
  without the full convention, has no tracker item.
- `acat-drafts-processfailure-j1h0`, P2, stays open. With A5G2c committed,
  the `drafts` leg passed inside `cli/ci/policies.sh` (`A/A5G2d/verify-r2/V13`).
  The issue asks for `drafts.sh` and `policies.sh` at N1 and N8, and the
  Integrator decides whether that condition is met.
- `manager/ci/supervision.sh` failed on the A5G2c round-2 source
  (`A/A5G2c/verify-r2/G06`, `G06b`). A5G2d did not run it, and no tracker
  item holds it.
- Refocus note. A5S2 kept to one diagnosis round and stopped at the
  escalation. The journey had not started at this stopping point. This
  section was a handoff edit made before the journey passed, which the
  closeout specification required.
- The other open findings of the sections below are unchanged, including
  `acat-response-ingestion-budget-zaoi` and `acat-tls-name-forms-6gbo`
  (P1), `acat-ftw9` (P2), the omission of `Agentic.Cli.Command.TuiService`
  from the manual, and the closeout items `acat-o2ud`, `acat-xj7c`,
  `acat-6h6z`, `acat-uv2h`, `acat-871r`, `acat-rxkl` and `acat-iyvu`.
- The tracker holds 105 open and 5 in-progress issues, six more open issues
  than at the previous stop (`Z/HANDOFF/impl-r1/H33-tracker.log`).
- The audits of this closeout replace the 2026-09-28 closeout audits
  `fess/Z-HANDOFF-r1.md` to `fess/Z-HANDOFF-r3.md`. Byte-identical copies
  are at `Z/HANDOFF/impl-r1/H33-preserved-fess-Z-HANDOFF-r1-20260928.md`,
  `...-r2-20260928.md` and `...-r3-20260928.md`
  (`Z/HANDOFF/impl-r1/H33-preserve.log`).

The workflow record lists no pending authorization request. Publication of
the rewritten branch still waits for the force-push approval that the
2026-09-26 section describes, and no such approval is recorded.

### Resume procedure

The first commands run in a plain shell with the operator Git configuration.
The toolchain check runs through `direnv exec .` with the private
environment:

```bash
cd /Users/johnw/src/agent-cat/.worktrees/tui
git status --short --branch
git log -1 --format='%H %P'
git rev-parse tui
git diff HEAD -- . ':!doc/workflow-manager-handoff.md' ':!doc/PLAN.org' |
  shasum -a 256
direnv exec . bash -c 'source /Users/johnw/Products/k.M0a5ItPm/environment.sh &&
  cd /Users/johnw/src/agent-cat/.worktrees/tui &&
  ghc --numeric-version && cabal --numeric-version &&
  ghc-pkg field crypton-x509-validation version'
```

Two states are expected. Before the Integrator commits this section, HEAD is
`b31a56f388a8eec4e896a66daa4d2e3c44dd1e05`, and the worktree holds the five
modified files of the A5S2 change and this handoff change. After the
Integrator commits this section, with `doc/PLAN.org` at most, HEAD is that
commit, its parent is `b31a56f388a8eec4e896a66daa4d2e3c44dd1e05`, and the
worktree holds only the five files of the A5S2 change. In both states `tui`
is `6b7c90b79b47c85d07162bb11d038349dbac9131`, and the digest command
prints `b5dcc5bebc476c589c529e1f05c55ba4c7e553af4b10740a53ac525396752a35`.
Any other result means that the branch or the worktree changed after this
section was written, and the reader establishes that change before
continuing. If direnv reports a stale or blocked environment, run `de` in
the worktree and repeat the check. Rebuild with the build command of the
first 2026-09-27 section below, and build `runtime-contract-test` with
`--enable-tests`, before any binary runs.

The next work proceeds in this order:

1. Obtain the owner decision on the S1 family. Complete A5S2 under it with
   a verifier run and one `fess` audit, and have the Integrator commit it.
   The orchestrator decides whether the two independent defects, the control
   404 and the event-stream end, are fixed inside A5S2 or as the next
   subtask before A6.
2. Restore the parked A6 diff (`refs/wip/a6-r3-20260924-final`) without its
   draft handoff, and build the uninterrupted PTY journey at N1 and then N8
   in the existing `manager/test/service_http.py` harness (A6 to A11): exact
   Unicode submission, approval of the five selectors, observed progress,
   snapshot display, the Bool `false` answer, the offered retry, native
   completion, and a `Client.downloadVerified` exclusive save with digest
   and byte checks, with a broken-step negative control. Add no new helper
   or evidence tooling.
3. Run the mutants and the integrated code gate on the final source (A12 and
   A13). Only after the journey passes, apply the held documentation diff
   with the `acat-nay0` corrections, document the first TUI service
   workflow and reconcile the manual (A14).
4. After Phase A is accepted, land actor-flow increment 1 (`acat-e6cp`,
   `acat-5m60`) before Phase B resumes WM-025 to WM-027.

Run the `fess` audit at the end of every subtask, keep each subtask to one
audit round, preserve the first failure of any check with its fixture root,
and label every result with its evidence ceiling. The evidence of this
closeout is under `Z/HANDOFF/impl-r1`, in the files that begin with `H33-`.

## Resume workflow stopping point of 2026-09-28

The resume workflow that started from checkpoint `wm023-20260923` ran again
after the Integrator committed the second 2026-09-27 closeout as
`9e3926c1`. Its first recorded command started at 2026-09-27T23:30:08Z, and
the last command of its only roadmap subtask, A5G2c, ended at
2026-09-28T18:17:12Z (`Z/HANDOFF/impl-r1/H30-facts.log`). The closeout
stage that wrote this section ran after that time, and its commands have
their own recorded times under `Z/HANDOFF`. A5G2c applied the owner decision
on the A5G2b escalation, and it escalated after three implementer rounds,
two verifier rounds and two `fess` audits, as the subsection "Stop reason
and owner decision" states. Accepted state is
unchanged at WM-001–WM-022 and G0/G1, which is 22 of 44 packages and two of
six gates. WM-023 (`acat-wm-023-d20b`) is still in progress. Phase A of the
remaining-scope report was not met at this stopping point, because the run did not reach its exit
check, and the run made no change for Phases B to G. This section and
`~/dl/agent-cat-workflow-manager-remaining-2026-09-28.md` described the
state at this stopping point. Where they differ from the sections below, they
supersede them, and the older sections remain as chronology. `~/dl` resolves to
`~/Downloads`.

### Objective, worktrees and environment

The governing goal of 2026-09-23 remains the current objective, with its
actor-flow amendment of 2026-09-26. Its verbatim text is in
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/resume-20260923/GOAL.md`.
It replaces Pi goal `mu629ta5-11s8ax`, revision 914, and it prevails over
older records where they conflict. The subsection "Governing objective" of
the first 2026-09-27 section below states its task mapping and the actor-flow
increments, and that text remains current. The former Pi ledger under
`.pi/goals` is not restored, and the workflow orchestrator tracks the goal.

The worktree `/Users/johnw/src/agent-cat/.worktrees/tui` was recreated on
2026-09-23 after an unexplained removal, and it holds the work branch
`workflow-manager-checkpoint-20260923`. The former work worktree
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source`
is still detached at `b95ce6d1` with no local change. The canonical branch
`tui` stays at `6b7c90b79b47c85d07162bb11d038349dbac9131`
(`Z/HANDOFF/impl-r1/H30-start-binding.log`).

No procedure runs `nix develop` in any form. The operator generates the
direnv environment in the worktree with `de`. Every build, test and project
tool runs through `direnv exec .` from the worktree, with
`/Users/johnw/Products/k.M0a5ItPm/environment.sh` sourced inside that shell,
and `de` runs again when `flake.nix` or `flake.lock` changes or when direnv
reports a stale or blocked environment. Git and `obr` run in a plain shell.
At the stop the environment reported GHC 9.10.3, Cabal 3.16.1.0 and
`crypton-x509-validation` 1.9.1, and `nix` resolved to
`/nix/var/nix/profiles/default/bin/nix`
(`Z/HANDOFF/impl-r1/H30-doc-check-before.log`).

### Commits and subtask results

This run made no commit. The branch head is
`9e3926c1871e77bd220fbb744fafaff5c9753fa8`, whose parent is `72329fc9`. As
read from the remote-tracking refs without a fetch,
`origin/workflow-manager-checkpoint-20260923` is still `b95ce6d1` and
`origin/tui` is `6b7c90b7`. Nothing from this workflow is published. The
subtask table of the first 2026-09-27 section below stays current for A0 to
A5, A12W, A5S1D, A5R and A5G1, with the qualification of the A5G1 row that
the second 2026-09-27 section states. That qualification now has
verifier-level support: with only `RoutingDiscovery.hs` reverted, the
routing probe fails because `security` cannot be spawned, and the vertical
check fails with `WorkerPreparedFraming` (`A/A5G2c/verify-r2/PRE01`,
`PRE02b`). The subtask A5G2b of the second 2026-09-27 section continued as
A5G2c.

| Subtask | Commit | Result and evidence ceiling |
| --- | --- | --- |
| A5G2c | none | Escalated after three implementer rounds, two verifier rounds and two `fess` audits, with its work uncommitted. The round-3 source, which is the current worktree, has implementer evidence only, with no verifier run and no audit. The evidence is under `A/A5G2c`, and the audits are `fess/A-A5G2c-r1.md` and `fess/A-A5G2c-r2.md`. |
| A5S2, A6–A14 | none | Not started at this stopping point. |

These are subtask results. None of them accepts a package or a gate.

### Decision that A5G2c applied

The A5G2c specification chose option 1 of the five options that the second
2026-09-27 section lists. Runtime `createProcessGroup` spawns through a C
helper in `runtime/cbits` that uses `posix_spawn` with
`POSIX_SPAWN_CLOEXEC_DEFAULT`, `POSIX_SPAWN_SETSID` and
`posix_spawn_file_actions_addchdir_np`. The non-Apple path stays unchanged,
and the `process` dependency is not patched. The specification also kept
`catalogueHelp` at a concurrency of four inside the single group deadline.
Section 4 of `fess/A-A5G2c-r2.md` restates these specification items. The
workflow record is the only source of this decision. Neither the governing
goal nor the tracker nor the evidence directory holds a separate record of
it. The same holds for the decision of 2026-09-27 on four help queries,
whose only sources are the A5G2b escalation text and a comment in
`Profile.hs` (`acat-uv2h`).

### Uncommitted A5G2c work

The worktree holds 13 modified files, two untracked files and nothing
staged. In a plain shell with the operator Git configuration, the SHA-256 of
`git diff HEAD -- . ':!doc/workflow-manager-handoff.md' ':!doc/PLAN.org'` is
`a52ada5a8af77b90e5543f0aa669a0b429ae679f431d807bcc799267aca0dd6b`. The
untracked `runtime/cbits/process_spawn.c` has the SHA-256
`5e0f74634e40c8b415b01ff8581df4e593b873b249198be8e7dfe6b2768ed75c`, and the
untracked `runtime/test/ProcessGroupTests.hs` has
`ba70d23bf07192e7d5ff625baeeab40ba3e8a6fe08e458c3a5b58dd191a998f3`
(`Z/HANDOFF/impl-r1/H30-start-binding.log`). These values match the final
binding of the round-3 implementer (`A/A5G2c/impl-r3/I02-final-binding.log`).
The digest depends on the Git configuration. The operator configuration sets
`diff.mnemonicprefix` to true and `diff.algorithm` to histogram, and with
`-c diff.mnemonicPrefix=false` the same tree hashes to
`08050fde237aba8b91cb8fd059f7887167ba421f322a91212dad0ee4302fb77e`, which
the A5G2c records call the prefixed digest (`Z/HANDOFF/impl-r1/H30-facts.log`).

The change has three parts:

- Runtime. The new `runtime/cbits/process_spawn.c` spawns the child as a
  session leader through `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`, so
  that the child receives only the descriptors that it names, and it changes
  the working directory with `posix_spawn_file_actions_addchdir_np`. It
  resolves the executable with its own copies of the `find_executable` of
  `process` 1.6.26.1 and of the BSD `execvP` candidate loop. The implementer
  recorded that `posix_spawnp` with a working-directory action and a relative
  `PATH` entry misbehaves on macOS (`A/A5G2c/impl-r2/X04`, `X05`). The helper
  sets `O_NONBLOCK` on each parent pipe end, and it leaves a closed inherited
  standard descriptor closed when a pipe end takes its number.
  `runtime/src/Agentic/Runtime/ProcessGroup.hs` calls the helper on Apple
  platforms through a safe foreign call and keeps the process-library path
  on other platforms. The new `runtime/test/ProcessGroupTests.hs` runs in the
  default contract tests, and `runtime/test/Main.hs` adds the mode
  `--process-group-spawn-cost-test`. `agentic.cabal`,
  `runtime/ci/capture.sh` and `test/capture_build_evidence.py` add the new
  files to their lists.
- Manager help queries. In the round-3 source, which no verifier has run,
  `manager/src/Agentic/Manager/Profile.hs` runs the help queries of
  `catalogueHelp` in a pool of `helpConcurrency` workers, which is 4, inside
  the unchanged group deadline of `queryMicros`. Rows start in catalogue
  order, and replies are accepted in the same order. Each reply is checked
  for UTF-8 and for the bound of 262144 characters when it arrives. Replies
  that wait behind an earlier row count against `queryBytes` together with
  the accepted total, and claims stop after a rejected reply or once that
  sum crosses the ceiling. When in-order acceptance reaches a failure, the
  remaining workers are cancelled and the failure is returned. The code
  comment in `Profile.hs` states that each query in flight completes its own
  cleanup, but no recorded check shows that cleanup after a cancellation.
  `manager/test/ProfileCheck.hs` adds fixtures for the barrier of four, the
  pool, the shared deadline, invalid and oversized replies, the byte ceiling
  and a decided failure behind a hung query.
- Discovery and gate fixtures. `cli/src/Agentic/RoutingDiscovery.hs`
  constructs the standard TLS manager at most once, and only when an engine
  needs a network refresh of its catalogue. `cli/test/RoutingDiscoveryProbe.hs`
  checks an engine without a catalogue under a `PATH` that names one empty
  directory. `manager/test/DraftCheck.hs`, `manager/test/HistoryCheck.hs`,
  `manager/test/worker_evidence.py` and `manager/test/admission_audit.py`
  carry the A5G2 and A5G2b fixture changes that the second 2026-09-27
  section describes.

Four documentation edits, to `doc/tui-design.md`, `manager/README.md`,
`runtime/README.md` and `tui/README.md`, are held outside the worktree under
the refocus note as `A/A5G2c/impl-r3/held-doc-edits.diff`, which applies
cleanly to HEAD (`Z/HANDOFF/impl-r1/H30-facts.log`). The A5G2b edit of
`manager/README.md` is part of that diff and is no longer in the worktree.
Until the held edits land, those four files do not describe the new spawn
path or the help pool.

The round-2 source was verified independently under `A/A5G2c/verify-r2`.
The Werror build of all targets with tests passed, and so did a build of the
Runtime commit alone (`B01`, `B02`, `B03`, package build). The Runtime
contract tests passed at N1 and N8, and `engine-api-test` passed (`G01`).
`vertical.sh`, `tui/ci/tui.sh`, `dependencies.sh`, `routing-config.sh`,
`profiles.sh` and `cli/ci/policies.sh` passed (`G02` to `G05`, `P01`,
`P03`, deterministic native fixtures, with `tui.sh` as a PTY fixture).
`policies.sh` runs the capture, profile, configuration, store, command,
draft, worker, admission, approval, ingestion, control and artifact gates,
and it printed 8507 `PASS` lines and no `FAIL` line. The 257-row catalogue
check passed with a help phase of 5.169 seconds at the soft `RLIMIT_NOFILE`
of 1048576 and 4.872 seconds at 4096 (`D01`). The negative controls failed
as intended. Without `POSIX_SPAWN_CLOEXEC_DEFAULT` the child held extra
descriptors (`M02`), without `POSIX_SPAWN_SETSID` the session check failed
(`M03`), and the process-library spawn took 5623 milliseconds for 64 spawns
against a bound of 1000 milliseconds (`M04a`). Sequential help failed the
pool checks (`M06`). On the HEAD text, the routing probe failed because
`security` could not be spawned, the vertical check failed with
`WorkerPreparedFraming`, and the draft check failed with `ProcessFailure`
(`PRE01`, `PRE02b`, `PRE03`).

Round 3 changed `Profile.hs`, `ProfileCheck.hs`, `ProcessGroup.hs`,
`process_spawn.c` and `ProcessGroupTests.hs` to answer the round-2 audit.
The following results for the round-3 source are implementer evidence only,
under `A/A5G2c/impl-r3`. The Werror build of all targets with tests passed,
and the Runtime commit alone built (`B01`, `B02`, `B03`, package build). The
Runtime contract tests, `engine-api-test` and the process-group checks
passed at N1 and N8, with 64 spawns taking 42 to 69 milliseconds at either
limit (`G01`, `R01`). `vertical.sh`, `tui/ci/tui.sh`, `dependencies.sh`,
`routing-config.sh` and `profiles.sh` passed (`G02` to `G05`, `P05`), and
`cli/ci/policies.sh` printed 8509 `PASS` lines and no `FAIL` line (`P06`),
all deterministic native fixtures. The 257-row check passed with a help
phase of 4.829 seconds at 1048576 and 4.792 seconds at 4096 (`D01`). The
four new `ProfileCheck.hs` fixtures failed on the round-2 source (`P01` to
`P04`), sequential help failed (`M06`), and a mutant without the
`O_NONBLOCK` step failed the new nonblocking check (`M07`). The non-Apple
branches typecheck under `-Wall -Werror -fno-code` with the platform macro
renamed (`NA02`), and a control copy with one unused import fails that
check (`NA03`). That is a typecheck only, and no non-Apple executable was
built or run.

### Stop reason and owner decision

The round-1 and round-2 audits both raised finding M1. The specification
required the cause of the `approval` and `vertical` failures to be fixed at
the owner that sets the worker environment or at the fixture, with a written
justification. The fix is in `cli/src/Agentic/RoutingDiscovery.hs` instead.
The round-2 audit accepts the fix as proven at the tip (`verify-r2/PRE01`,
`PRE02b`, and `G02` with the fix in place), and it rates the owner deviation
as blocking spec drift until the orchestrator rules on it. The implementer
states in `A/A5G2c/impl-r1/J01-approval-vertical-justification.txt` why
neither named owner fits. Adding `/usr/bin` to the worker environment would
break the manager's contract to pass a worker its exact explicit
environment. Adding `/usr/bin` to the fixture `PATH` would hide a defect
that a production worker with a narrow `PATH` meets. The round-3 implementer
made no code change for M1 and returned the question as an escalation
(`A/A5G2c/impl-r3/J03-round3-findings-record.txt`).

The owner chooses one of two rulings:

1. Accept `RoutingDiscovery` as the owner. The remaining case becomes a
   separate follow-up. A worker whose explicit `PATH` lacks `/usr/bin` still
   fails to construct the TLS manager when an engine with a catalogue needs
   a refresh, because `crypton-x509-system` 1.9.0 runs the bare name
   `security` (`A/A5G2c/impl-r2/J02-open-findings-record.txt`). No check
   covers that case.
2. Send the fix back to the worker environment or to the fixture, and name
   which of the two and what change is authorized.

No code work in A5G2c depends on the ruling.

### Open findings and authorizations

- A5G2c, owner ruling, as above. After the ruling, A5G2c completes on the
  round-3 source with its verifier and one `fess` audit. The round-3
  implementer reports these dispositions of the round-2 audit, and none of
  them has been verified or audited. M2, the help pool, was changed as the
  manager part above describes. L1 was answered with the nonblocking check
  and the `M07` mutant. L2, a suspected duplicate import on non-Apple
  platforms, was disproven by the typecheck above. L3 was recorded in the
  helper's header comment: the build uses `apple-sdk-14.4`, whose `spawn.h`
  does not deprecate `posix_spawn_file_actions_addchdir_np`, and the macOS
  26 SDK deprecates it while `capture.sh` compiles the helper with
  `-optc-Werror` (`X10`). L4 corrected the haddock and the check label. L5
  is unchanged: `acceptAndDeliverControlCommand` takes the same
  `entryControlGate` as the audited `acceptControlCommand` and stays
  unaudited, a gap that predates this subtask. L6 refreshed the held
  documentation diff.
- The fixtures in `DraftCheck.hs` and `ProfileCheck.hs` test the absence of
  each recorded help process with `signalProcess nullSignal` on its recorded
  process ID, a pattern that `ProfileCheck.hs` already used at HEAD. The
  round-2 audit found that no delivered signal reaches a stored process ID.
  The A5G2c audit still weighs the pattern against two binding rules: never
  signal a stored PID, and process absence is not cleanup proof
  (`acat-871r`).
- `manager/ci/supervision.sh` failed on the round-2 source and on a copy
  with the HEAD `admission_audit.py`, each with `AssertionError: unexpected
  test-process exit for success`. The case report of the second run names
  the coordination failure "supervisor completed before
  original-handle-retained" (`A/A5G2c/verify-r2/G06-supervision`,
  `G06b-supervision-head-audit`). The gate has no `createProcessGroup`
  caller and lies outside A5G2c. No tracker item holds it.
- Refocus note. The note stops the classification work after A5S1D, asks
  for one diagnosis round on the S1 503 and the closed release with a fresh
  N8 root, then the uninterrupted PTY journey, and holds every handoff and
  documentation edit until the journey passes. This run again worked on the
  manager gates first, and A5G2c took two audit rounds and a third
  implementer round against the rule of one audit round for each subtask.
  A5G2c made four documentation edits in round 1, reverted them in round 2
  after the round-1 audit raised the hold, and keeps them in the held diff.
  This section is a handoff edit made before the journey passes, which the
  closeout specification requires.
- S1 family, `acat-dxos`, P1. This run made no new S1 diagnosis. The
  subsection "S1 failure family" of the 2026-09-26 section remains current.
- `acat-drafts-processfailure-j1h0`, P2, stays open. With the uncommitted
  change, neither its `ProcessFailure` nor the later `QueryTimeout` occurs in
  the `drafts` leg of `policies.sh`, in the verified round-2 run and in the
  round-3 implementer run.
- Correction to the second 2026-09-27 section (`acat-o2ud`). Its stop reason
  cites `A/A5G2b/impl-r1/D02-catalogue-fd-limit` only for the leg at a soft
  limit of 4096. The same record holds a leg at 1048576, root
  `credentials.QHYL3FHM/build/a5g2b-fdlimit-1048576.dET5xq`, that failed
  with `manager-draft-check: QueryTimeout` after a help phase of 30.200
  seconds, although `D02.exit` is 0 because the loop hid the inner status.
  `A/A5G2b/impl-r1/D01-runner-help-timing` timed 24 help spawns through
  Python at 1048576: 1.55 seconds sequential with `close_fds`, 1.43 seconds
  sequential without it, and 0.39 seconds four at a time.
- The tracker holds 99 open and 5 in-progress issues
  (`Z/HANDOFF/impl-r1/H30-tracker.log`). The Integrator closed `acat-hzs9`,
  `acat-tlhm` and `acat-6bih`. The round-1 audit of the second 2026-09-27
  closeout raised `acat-o2ud` (P3) and `acat-xj7c`, `acat-6h6z`,
  `acat-uv2h`, `acat-871r`, `acat-rxkl` and `acat-iyvu` (P4). This section
  applies the corrections of `acat-o2ud`, `acat-uv2h`, `acat-871r`,
  `acat-rxkl` and `acat-iyvu`, and the tracker items stay open for the
  Integrator. The other open findings of the first 2026-09-27 section below
  are unchanged, including `acat-response-ingestion-budget-zaoi` and
  `acat-tls-name-forms-6gbo` (P1), `acat-ftw9` (P2) and the omission of
  `Agentic.Cli.Command.TuiService` from the manual.
- The audit of this closeout replaces `fess/Z-HANDOFF-r1.md`, which is the
  round-1 audit of the second 2026-09-27 closeout and the source that the
  seven items above cite. A byte-identical copy is at
  `Z/HANDOFF/impl-r1/H30-preserved-fess-Z-HANDOFF-r1-20260927b.md`
  (`Z/HANDOFF/impl-r1/H30-preserve.log`). The round-2 audit of this
  closeout replaces `fess/Z-HANDOFF-r2.md`, which was the round-2 audit of
  the first 2026-09-27 closeout, with the SHA-256 prefix `03f0b353`. A
  byte-identical copy is at
  `Z/HANDOFF/impl-r1/H29-preserved-fess-Z-HANDOFF-r2-20260927.md`
  (`Z/HANDOFF/impl-r1/H29-preserve.log`). The round-3 audit of this
  closeout replaced `fess/Z-HANDOFF-r3.md`, which was the 2026-09-26
  round-3 audit. A byte-identical copy is at
  `Z/HANDOFF/impl-r2/H28-preserved-fess-Z-HANDOFF-r3-20260926.md`
  (`Z/HANDOFF/impl-r3/H32-preserve.log`).

The workflow record lists no pending authorization request. Publication of
the rewritten branch still waits for the force-push approval that the
2026-09-26 section describes, and no such approval is recorded.

### Resume procedure

The first commands run in a plain shell with the operator Git configuration.
The toolchain check runs through `direnv exec .` with the private
environment:

```bash
cd /Users/johnw/src/agent-cat/.worktrees/tui
git status --short --branch
git log -1 --format='%H %P'
git rev-parse tui
git diff HEAD -- . ':!doc/workflow-manager-handoff.md' ':!doc/PLAN.org' |
  shasum -a 256
shasum -a 256 runtime/cbits/process_spawn.c runtime/test/ProcessGroupTests.hs
direnv exec . bash -c 'source /Users/johnw/Products/k.M0a5ItPm/environment.sh &&
  cd /Users/johnw/src/agent-cat/.worktrees/tui &&
  ghc --numeric-version && cabal --numeric-version &&
  ghc-pkg field crypton-x509-validation version'
```

Two states are expected. Before the Integrator commits this section, HEAD is
`9e3926c1871e77bd220fbb744fafaff5c9753fa8`, and the worktree holds the 13
modified and two untracked files of the A5G2c change and this handoff
change. After the Integrator commits this section, with `doc/PLAN.org` at
most, HEAD is that commit, its parent is
`9e3926c1871e77bd220fbb744fafaff5c9753fa8`, and the worktree holds only the
15 files of the A5G2c change. In both states `tui` is
`6b7c90b79b47c85d07162bb11d038349dbac9131`, the digest command prints
`a52ada5a8af77b90e5543f0aa669a0b429ae679f431d807bcc799267aca0dd6b`, and the
two untracked files have the digests that the subsection "Uncommitted A5G2c
work" states. Any other result means that the branch or the worktree
changed after this section was written, and the reader establishes that
change before continuing. If direnv reports a stale or blocked environment,
run `de` in the worktree and repeat the check. Rebuild with the build
command of the first 2026-09-27 section below, and build
`runtime-contract-test` with `--enable-tests`, before any binary runs.

The next work proceeds in this order:

1. Obtain the owner ruling above. Run the A5G2c verifier and one `fess`
   audit on the round-3 source. The Integrator then commits A5G2c as the
   Runtime commit followed by the manager and discovery commit, which the
   specification requires to build separately. The orchestrator decides
   whether the held documentation diff lands with those commits or waits
   for the journey under the refocus note. If the ruling is delayed, the
   orchestrator decides whether A5S2 runs first on the worktree as it
   stands.
2. Run A5S2 with the scope of the refocus note: one diagnosis round on the
   S1 503 and the closed release with a fresh N8 root, a proof of the cause,
   a fix at its owner with a regression test, and a stop. Widen `acat-dxos`
   and record the S1-c candidate. The ledger title of A5S2 also names the
   manager-path baselines. This section proposes that the integrated gate of
   A13 re-establish them, and the orchestrator assigns that scope.
3. Restore the parked A6 diff (`refs/wip/a6-r3-20260924-final`) without its
   draft handoff, and build the uninterrupted PTY journey at N1 and then N8
   in the existing `manager/test/service_http.py` harness (A6 to A11): exact
   Unicode submission, approval of the five selectors, observed progress,
   snapshot display, the Bool `false` answer, the offered retry, native
   completion, and a `Client.downloadVerified` exclusive save with digest
   and byte checks, with a broken-step negative control. Add no new helper
   or evidence tooling.
4. Run the mutants and the integrated code gate on the final source (A12 and
   A13). Only after the journey passes, document the first TUI service
   workflow and reconcile the manual (A14).
5. After Phase A is accepted, land actor-flow increment 1 (`acat-e6cp`,
   `acat-5m60`) before Phase B resumes WM-025 to WM-027.

Run the `fess` audit at the end of every subtask, keep each subtask to one
audit round, preserve the first failure of any check with its fixture root,
and label every result with its evidence ceiling. The evidence of this
closeout is under `Z/HANDOFF/impl-r1`, in the files that begin with `H30-`,
under `Z/HANDOFF/impl-r2`, in the files that begin with `H31-`, and under
`Z/HANDOFF/impl-r3`, in the files that begin with `H32-`. The verifier
records are under `Z/HANDOFF/verify-r1`, in the files that begin with
`W28-`, under `Z/HANDOFF/verify-r2/w0928`, and under
`Z/HANDOFF/verify-r3`, in the files that begin with `W30-` to `W39-`.
Copies of the
round-2 report and of the round-2 handoff diff, taken before the round-3
edits, are at `Z/HANDOFF/impl-r3/H32-preserved-report-2026-09-28-rev2.md`
and `Z/HANDOFF/impl-r3/H32-handoff-r2.diff`.

## Second resume workflow stopping point of 2026-09-27

The resume workflow that started from checkpoint `wm023-20260923` ran a
second time on 2026-09-27, after the Integrator committed the first
2026-09-27 closeout as `72329fc9`. Its first recorded command ran at
16:18:28Z, and it stopped at about 19:23Z. The run executed one subtask,
A5G2b, which applied the operator decision of 2026-09-27 on
`Profile.catalogueHelp`. That subtask escalated for a second owner decision,
as the subsection "Stop reason and owner decision" states. Accepted state is
unchanged at WM-001–WM-022 and G0/G1, which is 22 of 44 packages and two of
six gates. WM-023 (`acat-wm-023-d20b`) is still in progress. Phase A of the
remaining-scope report was not met at this stopping point, because the run did not reach its exit
check, and the run made no change for Phases B to G. This section and
revision 3 of `~/dl/agent-cat-workflow-manager-remaining-2026-09-27.md`
described the state at this stopping point. Where they differ from the sections below, they
supersede them, and the older sections remain as chronology. Revision 3
replaces revision 2 of the same file, which the first 2026-09-27 section
cites. A byte-identical copy of revision 2 is at
`Z/HANDOFF/impl-r1/H29-preserved-report-2026-09-27-rev2.md`
(`Z/HANDOFF/impl-r1/H29-preserve.log`). `~/dl` resolves to `~/Downloads`.

### Objective, worktrees and environment

The governing goal of 2026-09-23 remains the current objective, with its
actor-flow amendment of 2026-09-26. Its verbatim text is in
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/resume-20260923/GOAL.md`.
It replaces Pi goal `mu629ta5-11s8ax`, revision 914, and it prevails over
older records where they conflict. The subsection "Governing objective" of
the first 2026-09-27 section below states its task mapping and the actor-flow
increments, and that text remains current. The former Pi ledger under
`.pi/goals` is not restored, and the workflow orchestrator tracks the goal.

The worktree `/Users/johnw/src/agent-cat/.worktrees/tui` was recreated on
2026-09-23 after an unexplained removal, and it holds the work branch
`workflow-manager-checkpoint-20260923`. The former work worktree
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source`
is still detached at `b95ce6d1` with no local change. The canonical branch
`tui` stays at `6b7c90b79b47c85d07162bb11d038349dbac9131`
(`Z/HANDOFF/impl-r1/H29-start-binding.log`).

No procedure runs `nix develop` in any form. The operator generates the
direnv environment in the worktree with `de`. Every build, test and project
tool runs through `direnv exec .` from the worktree, with
`/Users/johnw/Products/k.M0a5ItPm/environment.sh` sourced inside that shell,
and `de` runs again when `flake.nix` or `flake.lock` changes or when direnv
reports a stale or blocked environment. Git and `obr` run in a plain shell.
At the stop the environment reported GHC 9.10.3, Cabal 3.16.1.0 and
`crypton-x509-validation` 1.9.1, and `nix` resolved to
`/nix/var/nix/profiles/default/bin/nix`
(`Z/HANDOFF/impl-r1/H29-doc-check-before.log`).

### Commits and subtask results

This run made no commit. The branch head is
`72329fc9172801d106beee3ee5180606baff9b6f`, whose parent is the A5R commit
`84ea887b`. As read from the remote-tracking refs without a fetch,
`origin/workflow-manager-checkpoint-20260923` is still `b95ce6d1` and
`origin/tui` is `6b7c90b7`. Nothing from this workflow is published. The
subtask table of the first 2026-09-27 section below stays current for A0 to
A5, A12W, A5S1D, A5R and A5G1, with one qualification of the A5G1 row. The
reviewed A5G1 record leaves the tip cause of the `approval` and `vertical`
gates unproven. The A5G2b implementer evidence below supports the `PATH`
cause at the tip, and that evidence has no verifier run or audit. The
subtask A5G2 of the first 2026-09-27 section continues as A5G2b.

| Subtask | Commit | Result and evidence ceiling |
| --- | --- | --- |
| A5G2b | none | Escalated after one implementer round, with its work uncommitted, no verifier run and no `fess` audit. The evidence is under `A/A5G2b/impl-r1`. |
| A5S2, A6–A14 | none | Not started at this stopping point. |

These are subtask results. None of them accepts a package or a gate.

### Uncommitted A5G2b work

The worktree holds nine modified files, no untracked file, and nothing
staged. The SHA-256 of
`git diff HEAD -- . ':!doc/workflow-manager-handoff.md' ':!doc/PLAN.org'` is
`53ee2ec4c9e5f12c73ae5ff38da78c917a028c3b1338c050623d3f06b39e0757`
(`Z/HANDOFF/impl-r1/H29-start-binding.log`, which matches
`A/A5G2b/impl-r1/I02-final-binding.log`). Six of the files carry the A5G2
change that the first 2026-09-27 section describes. A5G2b left
`cli/src/Agentic/RoutingDiscovery.hs`, `cli/test/RoutingDiscoveryProbe.hs`,
`manager/test/HistoryCheck.hs`, `manager/test/admission_audit.py` and
`manager/test/worker_evidence.py` unchanged, and it changed four files:

- `manager/src/Agentic/Manager/Profile.hs` runs the help queries of
  `catalogueHelp` in consecutive batches of `helpConcurrency`, which is 4,
  inside the unchanged group deadline of `queryMicros`. Each query keeps its
  own process cleanup. At the deadline the batch in flight is cancelled, and
  each of its queries completes its cleanup before the group reports
  `QueryTimeout`. Replies are checked in catalogue order.
- `manager/test/ProfileCheck.hs` adds fixture runners that hold the first
  four help queries until four have started and that delay help replies. Its
  new check requires at most four live help queries, one help query for each
  row in any order, and cleanup at the group deadline.
- `manager/test/DraftCheck.hs` records the name and process ID of each help
  query. Its catalogue check requires one help query for each of the 257
  rows, and it requires each recorded process to be absent when discovery
  returns, by a null-signal probe of the recorded process ID. The existing
  `ProfileCheck.hs` uses the same probe.
- `manager/README.md` describes the help queries, their batches of four and
  the shared deadline.

The implementer results follow, and each is implementer evidence only. With
the previous sequential `catalogueHelp` and the new checks, `profiles.sh`
failed with `QueryTimeout` and the 257-row catalogue check failed with
`QueryTimeout` at N1 (`S03-sequential-profiles`,
`S04-sequential-catalogue-N1`). With the change, `profiles.sh` passed
(`C03-concurrent-profiles`, deterministic native fixture) after a first run
failed on a timing flaw of the new fixture, which `C02-note.txt` records. The
Werror build of all targets with tests passed twice (`B01` and `B02`, package
build). The gates `drafts`, `artifacts`, `workers`, `vertical`,
`routing-config`, `approval` and `controls` passed, and the routing discovery
probe passed at N1 and N8 (`G01` to `G06`, `G08` and `G09`, deterministic
native fixtures). `cli/ci/policies.sh` failed in its `drafts` leg with
`manager-draft-check: QueryTimeout` at `DraftCheck.hs:101`, with fixture root
`credentials.QHYL3FHM/build/manager-drafts.xSMgV2` (`G07-policies`). The
gates `admission` and `ingestion` last ran in the A5G2 round on the source
before `Profile.hs` changed. The negative controls failed as intended. The
sequential `Profile.hs` under the final checks failed the profile probe at N8
with `ProcessFailure` and the catalogue check at N1 with `QueryTimeout`
(`N02`, `N03`). A mutant with `helpConcurrency` set to 8 failed the check
that allows at most four live queries (`N04`). With
`RoutingDiscovery.hs` reverted to its HEAD text, the routing discovery probe
failed because `security` could not be spawned, and the vertical and history
policy checks failed (`P02-tip-prefix-policy-fulllog`, `P03`, `P04`). With
the change restored, the history policy check passed (`P06`). `P02` recorded
exit 0 for a failed run because of a status-capture error, which
`P02-note.txt` records.

### Stop reason and owner decision

The help phase of the 257-row catalogue check took 29.444 seconds at N1 and
29.443 seconds at N8 in the passing `drafts` gate, against a deadline of 30
seconds. It took 30.264 seconds in the failing `policies.sh` run
(`Z/HANDOFF/impl-r1/H29-facts.log`, from the file times of the fixture
roots). The soft `RLIMIT_NOFILE` of the environment is 1048576. With the
same code and a soft limit of 4096, the help phase took 6.476 seconds and
the check passed. With the sequential code and a soft limit of 4096, it took
18.477 seconds and passed (`A/A5G2b/impl-r1/D02-catalogue-fd-limit`,
`D03-sequential-fd-limit`). The implementer attributes the difference to
the descriptor-closing sweep of `createProcess` with `close_fds` in
`process` 1.6.26.1, at about 100 milliseconds for each spawn at the high
limit, with the spawns behaving as serialized. The evidence shows the
dependence on the limit, but no record isolates the sweep itself. The
decision of 2026-09-27 therefore does not make the 257-row catalogue
reliably discoverable on this host. The owner chooses one of five options:

1. Change `createProcessGroup` in Runtime to spawn without a sweep over
   every possible descriptor, for example through `posix_spawn` with
   `POSIX_SPAWN_CLOEXEC_DEFAULT` and `POSIX_SPAWN_SETSID` in `runtime/cbits`.
   This changes an accepted Runtime owner that every worker uses, and the
   gates that own it must be revalidated.
2. Have the manager service set a bounded soft `RLIMIT_NOFILE` at startup,
   derived from its configured limits. This is a new operational policy.
3. Lower the soft descriptor limit in the gate scripts only. This leaves
   production behavior on this host unchanged.
4. Patch the `process` dependency. This needs separate authorization.
5. Declare a catalogue row ceiling in `manager/DRAFTS.md` and change the
   257-row fixture.

A longer or absent group deadline stays excluded. The escalation makes no
recommendation.

### Open findings and authorizations

- A5G2b, owner decision, as above. After the decision, A5G2b completes on
  the uncommitted change with its verifier and `fess` audit. The audit also
  examines whether the null-signal probe of recorded process IDs in
  `DraftCheck.hs` and `ProfileCheck.hs` meets the rule that process absence
  is not cleanup proof.
- Refocus note. The note stops the classification work after A5S1D, asks
  for one diagnosis round on the S1 503 and the closed release with a fresh
  N8 root, then the uninterrupted PTY journey, and holds every handoff and
  documentation edit until the journey passes. This run again worked on the
  manager gates first. The source change of A5G2b is confined to
  `Profile.hs` and its tests and documentation. This section is a handoff
  edit made before the journey passes, which the closeout specification
  requires.
- S1 family, `acat-dxos`, P1. This run made no new S1 diagnosis. The
  subsection "S1 failure family" of the 2026-09-26 section remains current.
- `acat-drafts-processfailure-j1h0`, P2, stays open. Its `ProcessFailure`
  no longer occurs with the uncommitted change, and the `QueryTimeout` that
  replaces it waits on the owner decision.
- The first 2026-09-27 closeout ended at audit round 2. Its audits were
  `fess/Z-HANDOFF-r1.md` and `fess/Z-HANDOFF-r2.md`, and
  `fess/Z-HANDOFF-r3.md` was still the 2026-09-26 round-3 audit. The audits
  of this closeout replace the files of the same round number. Copies of the
  first 2026-09-27 audits are at
  `Z/HANDOFF/impl-r1/H29-preserved-fess-Z-HANDOFF-r1-20260927.md` and
  `Z/HANDOFF/impl-r1/H29-preserved-fess-Z-HANDOFF-r2-20260927.md`, and the
  copy of the 2026-09-26 round-3 audit is at
  `Z/HANDOFF/impl-r2/H28-preserved-fess-Z-HANDOFF-r3-20260926.md`. The round-2
  audit of the first 2026-09-27 closeout raised `acat-hzs9`, `acat-tlhm` and
  `acat-6bih` (P4). This section and revision 3 of the report apply their
  corrections, and the tracker items stay open for the Integrator.
- The other open findings of the first 2026-09-27 section below are
  unchanged, including `acat-response-ingestion-budget-zaoi` and
  `acat-tls-name-forms-6gbo` (P1), `acat-ftw9` (P2) and the omission of
  `Agentic.Cli.Command.TuiService` from the manual. The export in
  `doc/PLAN.org`, which the first 2026-09-27 section reports as stale, was
  refreshed in `72329fc9` and lists the actor-flow items,
  `acat-inprocess-brokerlog-test-y43j` and the three P4 items above. The
  tracker holds 95 open and 5 in-progress issues
  (`Z/HANDOFF/impl-r1/H29-tracker.log`).

The workflow record lists no pending authorization request. Option 4 of the
owner decision would need one. Publication of the rewritten branch still
waits for the force-push approval that the 2026-09-26 section describes, and
no such approval is recorded.

### Resume procedure

The first commands run in a plain shell. The toolchain check runs through
`direnv exec .` with the private environment:

```bash
cd /Users/johnw/src/agent-cat/.worktrees/tui
git status --short --branch
git log -1 --format='%H %P'
git rev-parse tui
git diff HEAD -- . ':!doc/workflow-manager-handoff.md' ':!doc/PLAN.org' |
  shasum -a 256
direnv exec . bash -c 'source /Users/johnw/Products/k.M0a5ItPm/environment.sh &&
  cd /Users/johnw/src/agent-cat/.worktrees/tui &&
  ghc --numeric-version && cabal --numeric-version &&
  ghc-pkg field crypton-x509-validation version'
```

Two states are expected. Before the Integrator commits this section, HEAD is
`72329fc9172801d106beee3ee5180606baff9b6f`, and the worktree holds the nine
files of the uncommitted A5G2b change and this handoff change. After the
Integrator commits this section, with `doc/PLAN.org` at most, HEAD is that
commit, its parent is `72329fc9172801d106beee3ee5180606baff9b6f`, and the
worktree holds only the nine files. In both states `tui` is
`6b7c90b79b47c85d07162bb11d038349dbac9131`, no file is untracked, and the
digest command prints
`53ee2ec4c9e5f12c73ae5ff38da78c917a028c3b1338c050623d3f06b39e0757`. Any
other result means that the branch or the worktree changed after this
section was written, and the reader establishes that change before
continuing. If direnv reports a stale or blocked environment, run `de` in
the worktree and repeat the check. Rebuild with the build command of the
first 2026-09-27 section below before any binary runs.

The next work proceeds in this order:

1. Obtain the owner decision above. Complete A5G2b on the uncommitted
   change, restore `drafts` and `cli/ci/policies.sh` at N1 and N8, rerun
   `admission` and `ingestion` on the final source, and run the verifier and
   the `fess` audit. The Integrator then commits A5G2b. The S1 diagnosis
   would otherwise bind to unreviewed source that includes the production
   change in `cli/src/Agentic/RoutingDiscovery.hs`. The refocus note puts
   the S1 diagnosis first, so if the decision is delayed, the orchestrator
   decides whether A5S2 runs first on the worktree as it stands.
2. Run A5S2 with the scope of the refocus note: one diagnosis round on the
   S1 503 and the closed release with a fresh N8 root, a proof of the cause,
   a fix at its owner with a regression test, and a stop. Widen `acat-dxos`
   and record the S1-c candidate. The manager-path baselines that the
   ledger title of A5S2 names are re-established by the integrated gate of
   A13.
3. Restore the parked A6 diff (`refs/wip/a6-r3-20260924-final`) without its
   draft handoff, and build the uninterrupted PTY journey at N1 and then N8
   in the existing `manager/test/service_http.py` harness (A6 to A11): exact
   Unicode submission, approval of the five selectors, observed progress,
   snapshot display, the Bool `false` answer, the offered retry, native
   completion, and a `Client.downloadVerified` exclusive save with digest
   and byte checks, with a broken-step negative control. Add no new helper
   or evidence tooling.
4. Run the mutants and the integrated code gate on the final source (A12 and
   A13). Only after the journey passes, document the first TUI service
   workflow and reconcile the manual (A14).
5. After Phase A is accepted, land actor-flow increment 1 (`acat-e6cp`,
   `acat-5m60`) before Phase B resumes WM-025 to WM-027.

Run the `fess` audit at the end of every subtask, keep each subtask to one
audit round, preserve the first failure of any check with its fixture root,
and label every result with its evidence ceiling. The evidence of this
closeout is under `Z/HANDOFF/impl-r1`, in the files that begin with `H29-`.

## Resume workflow stopping point of 2026-09-27

The resume workflow that started from checkpoint `wm023-20260923` ran again
after the 2026-09-26 closeout, from 2026-09-26 at about 19:12Z, and it stopped
on 2026-09-27 at about 14:55Z. Subtask A5G2 needs an owner decision that the
requirements do not settle, as the subsection "Open findings and decisions"
states. Accepted state is unchanged at WM-001–WM-022 and G0/G1, which is 22
of 44 packages and two of six gates. WM-023 (`acat-wm-023-d20b`) is still in
progress. Phase A of the remaining-scope report was not met at this stopping point, because the run
did not reach its exit check. The run made no implementation change for
Phases B to G. This section and the report
`~/dl/agent-cat-workflow-manager-remaining-2026-09-27.md` described the state
at this stopping point. Where they differ from the sections below, they supersede them. The
older sections remain as chronology.

`~/dl` resolves to `~/Downloads`, where the 2026-09-26 report also lies. On
2026-09-26 the operator moved the 2026-09-23 report, which the governing goal
cites, to
`~/Documents/Obsidian/agent-cat-workflow-manager-remaining-2026-09-23.md`.
The 2026-09-24 report beside it is an unaccepted draft, and its description
of the first S1 variant is wrong. The Desktop path that the 2026-09-26 section
gives for these reports is out of date.

### Governing objective

The governing goal of 2026-09-23 remains the current objective. Its verbatim
text is in the private evidence directory at
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/resume-20260923/GOAL.md`.
It replaces Pi goal `mu629ta5-11s8ax`, revision 914, and it prevails over older
records where they conflict. It keeps the completed tasks
`wm016-closure-plan`, `wm016-functional-closure`, `wm016-integrated-validation`,
`wm016-acceptance` and `broker-api-default`. Its current task,
`first-frontend-broker-workflow`, is Phase A of the remaining-scope report. The
task `remaining-frontends` is Phases C, D and E, and the task
`operational-hardening-roadmap-closure` is Phases B, F and G. The former Pi
ledger under `.pi/goals` is not restored, and the workflow orchestrator tracks
the goal.

On 2026-09-26 the operator added the actor-flow amendment to the same file.
It replaces the manager-broker amendment of 2026-09-25, which the file keeps
as a record. Users, LLMs and tools are actors that receive and send messages,
and an actor can send a message without first receiving one. The workflow of
a request receives or presents the initial inputs and routes each output until
a stop condition holds. The runtime remains the sole interpreter of the plan.
Every message is one record with a schema, a sender, an address, identifiers
and a body. The broker appends each record to the log of its writer before
delivery, and it serves any restriction of a log, live or replayed, to
authorized readers. It never originates, alters, reorders, retries, re-routes
or re-delivers a message. The operator approved the model, three increments of
26 to 31 engineering days in total, and six recorded differences in behavior.
Phase A proceeds unchanged. After Phase A is accepted, increment 1 (the run
log, the manager log, a local reader and adapter permission reports) lands
before Phase B resumes WM-025 to WM-027. Increment 2 (service subscription)
lands inside WM-025 and WM-026, and increment 3 (live re-route and asks
answered by people) lands between WM-027 and WM-028. The tracker items are
`acat-e6cp` (increment 1a, which also adds the dated record
`doc/research/actor-flow-amendment.md`), `acat-5m60` (1b), `acat-en4g` (2)
and `acat-c18n` (3). The items `acat-dz25` and `acat-7z2x` of the
manager-broker amendment are closed as superseded. The design record is
`resume-20260923/proposals/actor-flow-architecture-v2.md`, revision 4.
RabbitMQ and John Mark integrations remain deferred.

### Worktrees and environment

The worktree `/Users/johnw/src/agent-cat/.worktrees/tui` was recreated on
2026-09-23 after an unexplained removal, and it holds the work branch
`workflow-manager-checkpoint-20260923`. The governing goal attributes the
removal to the deletion of the agent-deck session `agent-cat`. The former work
worktree
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source`
is detached at `b95ce6d1` and stays unmodified. The canonical branch `tui`
stays at `6b7c90b79b47c85d07162bb11d038349dbac9131` until reviewed integration.

No procedure runs `nix develop` in any form. The operator generates the direnv
environment in the worktree with `de`, which writes `.envrc` and
`.envrc.cache`. Every build, test and project tool runs through
`direnv exec .` from the worktree, with the private environment
`/Users/johnw/Products/k.M0a5ItPm/environment.sh` sourced inside that shell.
When `flake.nix` or `flake.lock` changes, or when direnv reports a stale or
blocked environment, `de` regenerates the environment. Neither `.envrc` nor
`.envrc.cache` is edited by hand or committed. Git and `obr` run in a plain
shell outside the private environment. At the stop the environment reported
GHC 9.10.3, Cabal 3.16.1.0 and `crypton-x509-validation` 1.9.1
(`Z/HANDOFF/impl-r1/H27-doc-check-before.log`). The other environment rules
of the 2026-09-26 section below still apply, with one exception. That section
states that a gate which calls `nix develop path:. -c CMD` runs with a `nix`
shim first on `PATH`, and this statement is wrong (`acat-mu0p`). Under
`direnv exec .` with the private environment, `nix` resolves only to
`/nix/var/nix/profiles/default/bin/nix`. The shim exists only at
`resume-20260923/R/bin/nix`, which is not on `PATH`
(`Z/HANDOFF/impl-r2/H28-env-facts.log`). The only tracked file outside the
documentation that calls `nix develop` is `engine/acp/ci/route-live.sh`,
which the binding rules forbid because it uses a paid provider
(`Z/HANDOFF/impl-r2/H28-facts.log`). No permitted gate therefore depends on
the shim.

### Commits and subtask results

At the stop, the branch head is `84ea887b87ad437503bf4d6e13698654f8d1be2e`,
which is the A5R commit. The branch was not rebased again, so the commits of
the 2026-09-26 table below keep their identifiers. The private evidence for
subtask `X` is under `resume-20260923/A/X`, and its audits are under
`resume-20260923/fess`. The audits of this closeout subtask are
`fess/Z-HANDOFF-r1.md` to `fess/Z-HANDOFF-r3.md`, and the evidence of each
round `N` is under `Z/HANDOFF/impl-rN`. Each round of this closeout replaces
the 2026-09-26 closeout audit of the same name. The round-1 audit of this
closeout keeps the replaced 2026-09-26 round-1 text verbatim in its appendix.
The tracker issues `acat-syuu`, `acat-mu0p`, `acat-89kw` and `acat-uxkh` cite
the 2026-09-26 round-3 audit as their source. Copies of the 2026-09-26
round-2 and round-3 audits, taken before this closeout could replace them,
are at `Z/HANDOFF/impl-r2/H28-preserved-fess-Z-HANDOFF-r2-20260926.md` and
`Z/HANDOFF/impl-r2/H28-preserved-fess-Z-HANDOFF-r3-20260926.md`
(`Z/HANDOFF/impl-r2/H28-preserve-fess.log`). As read from the remote-tracking
refs without a fetch,
`origin/workflow-manager-checkpoint-20260923` is still `b95ce6d1` and
`origin/tui` is `6b7c90b7`. Nothing from this workflow is published.

| Subtask | Commit | Result and evidence ceiling |
| --- | --- | --- |
| A0–A5, A12W | `25709730`, `3adfbdcb`, `040a478b`, `eb109664`, `75a3c28b`, `0697de28`, `290e0232` | Unchanged from the 2026-09-26 table below. |
| A5S1D | `480240a1` | Completes the A5S1C fault classification, which this commit carries. `Agentic.Manager.Fault` classifies each converted site as a declared command refusal, a Store failure or an unexpected exception named by its type, and `Agentic.Manager.Fault.Record` writes that class to the private log without exception text. No public response changes. New fixtures reach `Service.hs:125` through an undecodable `requests.workflow_id` and `Service.hs:162` through a failed ingestion and an undecodable `runs.profile_id`, each written through a separate SQLite connection. `fault-classification` passed 83 of 83 at N1 and N8 (pure model test), `service-faults` passed 26 of 26 at N1 and N8, and the gates `configuration`, `commands`, `store`, `ingestion` and `admission` passed (deterministic native fixtures). Controls K42 and K45 now fail named checks. The round-2 audit `fess/A-A5S1D-r2.md` is not blocking. |
| A5R | `84ea887b` | Resolves the rebase audit findings M3, M4 and M5. `runtime/test/BrokerTests.hs` adds epoch-delivery and shell-log-delivery checks, and `test/frontend_session_probe.py` prepares a row with in-process tools. The broker tests and the runtime and engine-api suites passed at N1 and N8 (model tests), and the probe passed at N1 and N8 (deterministic native fixture). Five mutants each failed. `tui/ci/tui.sh` passed with the recomputed expectations (deterministic PTY fixture) after a first verifier failure under a load average of 88 to 97, whose root is kept. The round-2 audit `fess/A-A5R-r2.md` is not blocking. |
| A5G1 | none | Diagnosis only, and no tracked file changed. The record is `A/A5G1/impl-r2/A5G1-diagnosis.md`. The `drafts` and `artifacts` fixture runners lack a `help` case for `Profile.catalogueHelp`, and the `workers` evidence script refuses the `help` argv, all since `b0ae240c`. At `2b31a965` the worker `PATH` of `approval` and `vertical` lacks `security`, which `crypton-x509-system` 1.9.0 runs to read the system certificate store, and the record leaves the same cause at the tip unproven. The `controls` audit anchor no longer matches the re-indented `Machine.hs`. All legs ran at N1. The round-2 audit `fess/A-A5G1-r2.md` is not blocking. |
| A5G2 | none | Escalated after one round with its work uncommitted, as the next subsection states. It has no verifier run and no fess audit. |
| A5S2, A6–A14 | none | Not started at this stopping point. |

These are subtask results. None of them accepts a package or a gate.

### Uncommitted A5G2 work

Subtask A5G2 was to restore the six red manager gates at their owners. The
worktree holds six modified files, no untracked file, and nothing staged. The
handoff change is also uncommitted when the workflow stops, so the digest of
the A5G2 change excludes this file and `doc/PLAN.org`. The SHA-256 of
`git diff HEAD -- . ':!doc/workflow-manager-handoff.md' ':!doc/PLAN.org'` is
`879a9c21849d82c68eafffcbf3c7fb2cadd8b596d007bccbb47409d4a3a05619`
(`Z/HANDOFF/impl-r1/H27-start-binding.log`).

- `cli/src/Agentic/RoutingDiscovery.hs` constructs the standard TLS manager
  at most once, and only when an engine needs a network refresh. Offline
  mode, a fresh cache and an engine without a catalogue construct no manager
  and read no system certificate store. This is the only production change.
- `cli/test/RoutingDiscoveryProbe.hs` adds a regression check that runs
  discovery for an engine without a catalogue with `PATH` naming one empty
  directory and with `SSL_CERT_FILE` and `SSL_CERT_DIR` unset. It failed on
  the previous source (`A/A5G2/impl-r1/R03-routing-probe-prefix` and `R04`)
  and passed with the change (`R05`). Its first form, which kept the
  certificate variables, passed on the previous source (`R01`).
- `manager/test/DraftCheck.hs` and `manager/test/HistoryCheck.hs` answer a
  `help NAME` query for a row of the current catalogue and fail for any other
  name, as the actual runner does.
- `manager/test/worker_evidence.py` accepts a `help NAME` argv only for a
  row of the native catalogue.
- `manager/test/admission_audit.py` updates the `Machine.hs` anchor of
  `control-unsupported` and the `Admission.hs` anchors of
  `control-preparation`. The `Admission.hs` anchors have not matched
  `acceptControlCommand` since `b0ae240c`. The `Machine.hs` failure, which
  the gate reaches first, hid them from the A5G1 diagnosis.

The implementer ran each gate script at its owning layer. The legs and the RTS
settings are those that each script chooses. The Werror build of the affected
targets passed (package build). The gates `artifacts`, `workers`, `approval`,
`vertical`, `routing-config`, `admission` and `ingestion` passed
(deterministic native fixtures). The first `controls` run failed on the
`Admission.hs` anchor (`G06-controls`), and the run after the anchor fix
passed (`G07-controls`). The `drafts` gate failed with `manager-draft-check:
QueryTimeout` (`G01-drafts`), and `cli/ci/policies.sh` stopped at the same
failure (`G09-policies`). The steps of `policies.sh` after its manager gates
passed when run on their own (`G10-policies-tail`). The negative controls
behaved as expected. With the runner `help` cases reverted, the draft check
and the history check each fail with `ProcessFailure`
(`N02-N03-runner-help-revert`). The evidence script refuses a `help` name
outside the catalogue (`N04-worker-evidence`). The audit script of `84ea887b`
fails on both anchors (`N05-audit-head-controls`), and the old mutant anchor
makes the compiled mutant miss its intended assertion
(`N06-old-mutant-anchor`). These results are implementer evidence only.

### Open findings and decisions

- A5G2, owner decision. `Profile.catalogueHelp`, added in `b0ae240c`, launches
  one `help NAME` runner process per catalogue row. The launches are
  sequential and share one group deadline of `queryMicros`, which is 30
  seconds, the configured maximum. Each launch costs about 75 to 80
  milliseconds on average on this host with the real runners and with the
  fixture runner (`X02-draft-help-timing`, `X03-real-help-timing`). The draft
  contract in `manager/DRAFTS.md` states that the public 256-item workflow
  page bound does not limit the native catalogue, and `cataloguePageChecks`
  has required a 257-row catalogue to be discoverable since `a0828d40`. That
  discovery now times out after about 31 seconds (`G01-drafts`,
  `X04-review-catalogue-N1`, `G09-policies`). The decision is one of three
  options. The first runs the help queries with a fixed, bounded concurrency
  inside the same deadline, each with its own `ProcessGroup` cleanup, and
  updates the ordered-argv expectations of `ProfileCheck`. The second extends
  the runner query contract with one bulk query that returns every help page,
  which changes the descriptor and runner protocol. The third declares a
  catalogue row ceiling that the 30-second deadline supports, amends
  `manager/DRAFTS.md` and changes the 257-row fixture with that justification.
  A longer or absent group deadline would weaken a wait bound, so it is
  excluded. The implementer recommends the first option with a small fixed
  bound such as 4.
- Refocus note. The latest refocus note stops the classification work after
  A5S1D and asks for one diagnosis round on the S1 503 and the closed release
  with a fresh N8 root, then the uninterrupted PTY journey in the existing
  `manager/test/service_http.py` harness, with every handoff and
  documentation edit held until the journey passes. The workflow ran A5R,
  A5G1 and A5G2 first. The A5G1 round-2 audit records this as scope drift at
  the orchestration level (finding O1). The A5R round-2 audit records that
  A5R committed documentation edits that its specification required
  (finding M1). A5S1D, A5R and A5G1 each took two audit rounds, although the
  note asks for one audit round per subtask, and audit O1 records this for
  A5G1. This section is itself a handoff edit made before the journey
  passes. The note grants no exception for it. The closeout specification
  requires the stopping record despite the hold.
- S1 family, `acat-dxos`, P1. This run made no new S1 diagnosis, and the
  subsection "S1 failure family" of the 2026-09-26 section remains current.
  The title of `acat-dxos` still names only the A5 round-1 `tui-approval` N8
  failure, and the tracker holds no S1-c candidate.
- The accepted gap at `Approval.hs:96` is recorded as
  `acat-approval-publish-loan-gap-isjw` (P3). The A5S1D audit findings are
  `acat-20yy`, `acat-bagg`, `acat-qcpi`, `acat-3ker` and `acat-q8fk` (P4).
  The A5R audit added `acat-inprocess-brokerlog-test-y43j` (P3). The
  2026-09-26 closeout audit findings are `acat-syuu`, `acat-mu0p`,
  `acat-89kw` and `acat-uxkh` (P4).
- `acat-drafts-processfailure-j1h0`, P2, stays open. Its title names the
  `ProcessFailure` that the uncommitted fixture change removes, and the
  `QueryTimeout` behind it waits on the owner decision above.
- `make -C doc check-haskell` fails because the manual omits
  `Agentic.Cli.Command.TuiService`, as last recorded by A1. A14 owns that
  reconciliation. `make -C doc check` passes.
- `acat-response-ingestion-budget-zaoi` and `acat-tls-name-forms-6gbo`, P1,
  are open. `acat-tls-name-constraints-0h7q` stays in progress.
- `acat-ftw9`, P2, still needs a recorded decision on refresh while a
  mutation key is deferred before A7. `acat-lzlp`, `acat-5k82`, `acat-47ax`
  and `acat-i9aj`, P2, remain open.
- The tracked `doc/PLAN.org` at `84ea887b` does not list the four actor-flow
  items or `acat-inprocess-brokerlog-test-y43j`, which the tracker holds
  (`Z/HANDOFF/impl-r1/H27-plan-export.log`).

The workflow record lists no pending authorization request. Publication of
the rewritten branch still waits for the force-push approval that the
2026-09-26 section describes, and no such approval is recorded. The standing
restrictions of the halt section remain in force.

### Resume procedure

The first commands run in a plain shell. The toolchain check runs through
`direnv exec .` with the private environment:

```bash
cd /Users/johnw/src/agent-cat/.worktrees/tui
git status --short --branch
git log -1 --format='%H %P'
git rev-parse tui
git diff HEAD -- . ':!doc/workflow-manager-handoff.md' ':!doc/PLAN.org' |
  shasum -a 256
direnv exec . bash -c 'source /Users/johnw/Products/k.M0a5ItPm/environment.sh &&
  cd /Users/johnw/src/agent-cat/.worktrees/tui &&
  ghc --numeric-version && cabal --numeric-version &&
  ghc-pkg field crypton-x509-validation version'
```

Two states are expected. Before the Integrator commits this section, HEAD is
`84ea887b87ad437503bf4d6e13698654f8d1be2e`, and the worktree holds the
uncommitted A5G2 change and this handoff change. After the Integrator commits
this section, with `doc/PLAN.org` at most, HEAD is that commit, its parent is
`84ea887b87ad437503bf4d6e13698654f8d1be2e`, and the worktree holds only the
six files of the A5G2 change. In both states `tui` is
`6b7c90b79b47c85d07162bb11d038349dbac9131`, no file is untracked, and the
digest command prints
`879a9c21849d82c68eafffcbf3c7fb2cadd8b596d007bccbb47409d4a3a05619`. Any
other result means that the branch or the worktree changed after this
section was written, and the reader establishes that change before
continuing. If direnv reports a stale or blocked environment, run `de` in the
worktree and repeat the check. Rebuild before any binary runs:

```bash
direnv exec . bash -c 'source /Users/johnw/Products/k.M0a5ItPm/environment.sh &&
  cd /Users/johnw/src/agent-cat/.worktrees/tui &&
  bash test/cabal.sh build lib:agentic agentic-run routing-fixed-point-probe \
    routing-discovery-probe manager-client-check manager-profile-probe \
    manager-root-probe manager-configuration-probe manager-store-check \
    manager-command-check manager-draft-check manager-worker-check \
    manager-admission-check manager-approval-check manager-vertical-check \
    manager-artifact-check manager-history-check tui-model-test \
    --with-compiler="$(command -v ghc)" --with-hc-pkg="$(command -v ghc-pkg)" \
    --ghc-options="-Werror -threaded -rtsopts"'
```

The next work proceeds in the order below. This order departs from the
refocus note, which puts the S1 diagnosis next, and audit O1 repeats that
request. A5G2 comes first for two reasons. The worktree carries the
uncommitted A5G2 change, which includes the production change in
`cli/src/Agentic/RoutingDiscovery.hs`, so an S1 diagnosis started now would
bind to unreviewed source. A5S2 must also re-establish the manager-path
baselines after its fix, and the `drafts` gate and `cli/ci/policies.sh` stay
red until the `catalogueHelp` decision. If that decision is delayed, the
orchestrator decides whether A5S2 runs first on the worktree as it stands.

1. Obtain the owner decision on `Profile.catalogueHelp`. Complete A5G2 on
   the uncommitted change, restore `drafts` and `cli/ci/policies.sh`, and run
   its verifier and `fess` audit. The Integrator then commits A5G2.
2. Run one diagnosis round on the S1 503 and the closed release with a fresh
   N8 root (A5S2). Prove the cause, fix it at its owner with a regression
   test, and stop there. Widen `acat-dxos` and record the S1-c candidate.
3. Restore the parked A6 diff (`refs/wip/a6-r3-20260924-final`) without its
   draft handoff, and build the uninterrupted PTY journey at N1 and then N8
   in the existing `manager/test/service_http.py` harness (A6 to A11): exact
   Unicode submission, approval of the five selectors, observed progress,
   snapshot display, the Bool `false` answer, the offered retry, native
   completion, and a `Client.downloadVerified` exclusive save with digest and
   byte checks, with a broken-step negative control. Add no new helper or
   evidence tooling.
4. Run the mutants and the integrated code gate on the final source (A12 and
   A13). Only after the journey passes, document the first TUI service
   workflow and reconcile the manual (A14).
5. After Phase A is accepted, land actor-flow increment 1 (`acat-e6cp`,
   `acat-5m60`) before Phase B resumes WM-025 to WM-027.

Run the `fess` audit at the end of every subtask, keep each subtask to one
audit round, preserve the first failure of any check with its fixture root,
and label every result with its evidence ceiling.

## Resume workflow stopping point of 2026-09-26

The resume workflow that started from checkpoint `wm023-20260923` stopped on
2026-09-26 at about 13:24Z. Subtask A5S1C did not reach a clean state after
three rounds, and its uncommitted work remains in the worktree for inspection.
Accepted state is unchanged at WM-001–WM-022 and G0/G1, which is 22 of 44
packages and two of six gates. WM-023 (`acat-wm-023-d20b`) is still in
progress. Phase A of the remaining-scope report was not met at this stopping point. The run made no
implementation change for Phases B to G. The evidence directory also holds
the proposal `resume-20260923/proposals/manager-broker-design.md`, dated
2026-09-26 at about 02:55Z, for the operator amendment of 2026-09-25. It is a
proposal for operator decision on source baseline `290e0232`, and it changes
no code. This section and the report
`~/dl/agent-cat-workflow-manager-remaining-2026-09-26.md` described the state
at this stopping point. Where they differ from the halt section below, they supersede it. The
older sections remain as chronology.

Since 2026-09-25, `~/dl` resolves to `~/Downloads` through a home-manager
link. The 2026-09-23 report that the governing goal cites is therefore at
`~/Desktop/agent-cat-workflow-manager-remaining-2026-09-23.md`. The 2026-09-24
report beside it is an unaccepted draft from a failed closeout, and its
description of the first S1 variant is wrong.

### Governing objective

The operator set a new governing goal on 2026-09-23 at about 23:50 PDT. Its
verbatim text is in the private evidence directory at
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/resume-20260923/GOAL.md`.
It replaces Pi goal `mu629ta5-11s8ax`, revision 914, and it prevails over older
records where they conflict. The goal keeps the completed tasks
`wm016-closure-plan`, `wm016-functional-closure`, `wm016-integrated-validation`,
`wm016-acceptance` and `broker-api-default`. Its current task,
`first-frontend-broker-workflow`, is Phase A of the remaining-scope report. The
task `remaining-frontends` is Phases C, D and E, and the task
`operational-hardening-roadmap-closure` is Phases B, F and G. The former Pi
ledger under `.pi/goals` was destroyed with the former worktree. It is not
restored, and the workflow orchestrator tracks the goal.

The same file holds an operator amendment of 2026-09-25 on a manager broker.
It adds an injected `ManagerBroker` in `Agentic.Manager.Broker` that carries
each native worker frame byte-exact to the original private-pipe writer or
receiver, with the default `directBroker`. It changes no behavioral guarantee.
Commands and observer notices keep their frozen `/v1` forms. The reviewed seam
(stage M1, `acat-7z2x`) lands after Phase A is accepted and before the Phase B
gate WM-028. It depends on the dated record
`doc/research/workflow-manager-broker-amendment.md` (stage M0, `acat-dz25`).
RabbitMQ and John Mark integrations remain deferred.

### Worktrees and environment

The worktree `/Users/johnw/src/agent-cat/.worktrees/tui` was removed on
2026-09-23 at 23:00:10 PDT. The goal attributes the removal to the deletion of
the agent-deck session `agent-cat`, which force-removed the worktree. The
worktree was recreated on 2026-09-23, and it now holds the work branch
`workflow-manager-checkpoint-20260923`. The goal states that no committed work
was lost. The former work worktree
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source`
is detached at `b95ce6d1` and stays unmodified. The canonical branch `tui`
stays at `6b7c90b79b47c85d07162bb11d038349dbac9131` until reviewed integration.

No procedure runs `nix develop` in any form. The operator generates the direnv
environment in the worktree with `de`, which writes `.envrc` and
`.envrc.cache`. Every build, test and project tool runs through
`direnv exec .` from the worktree, with the private environment
`/Users/johnw/Products/k.M0a5ItPm/environment.sh` sourced inside that shell.
When `flake.nix` or `flake.lock` changes, or when direnv reports a stale or
blocked environment, `de` regenerates the environment. Neither `.envrc` nor
`.envrc.cache` is edited by hand or committed. The private environment sets
`HOME`, `TMPDIR`, the XDG directories and the shared serialized
`CABAL_BUILDDIR`. The expected toolchain is GHC 9.10.3,
`crypton-x509-validation` 1.9.1 and Cabal 3.16.1.0, which the stages read as
the cabal-install version (`acat-cabal-version-reading-0fnq`). Git and `obr` run
in a plain shell outside the private environment, because the private `HOME`
lacks the operator Git configuration. A gate that calls
`nix develop path:. -c CMD` internally runs with a `nix` shim first on `PATH`
inside direnv, which runs `CMD` directly. This rule supersedes the
`nix develop` commands and the `broker-source` worktree path in the
[checkpoint README](checkpoints/wm023-20260923/README.md).

### Branch history and publication

On 2026-09-25 the work branch was rebased onto `main` at `0427fe27`, as an
operator brief of 2026-09-24 directed. The brief is preserved as
`resume-20260923/REBASE-BRIEF-0427fe27.md`. The rebase log
`resume-20260923/R/rebase/conflicts.md` records which replayed commits
changed. Steps 1, 5, 17, 19, 34, 36 and 186 needed a conflict resolution.
Steps 2, 26, 38, 123 and 175 changed only in their diff context. Step 16 went
through the merge driver for `doc/PLAN.org` and keeps the branch's historical
copy of that file.

A history fix then changed the replayed commits again, and
`resume-20260923/R/history/adaptations.md` records each change. It folded a
frontend-preparation call-site correction into step 1. At step 2 it renamed
the local binding `execute` to `executeRun` in `cli/src/Agentic/Cli.hs`,
because the binding shadowed a top-level name and failed `-Werror`. Step 4
made the same rename, so its own copy of that change became empty. At step
123 only one line of diff context changed. A later pass squashed old steps
116, 117 and 118 into one commit, which is now step 116. The final tree is
the same as before the history fix.

The rewrite changed every commit identifier after the merge base. The halt
checkpoint `b95ce6d1` is now `7769b08e`, and the checkpoint code commits
`12fc3228`, `910db084`, `073508ff` and `d8c0609a` are now `3f82b883`,
`b0ae240c`, `1c4a1f02` and `8b8e9e9c`. The command
`git range-diff main..fb7ff091 main..0697de28` marks these five mappings, the
mapping of `bf516dba` to `95f144e3`, and the A0 to A5 mappings in the table
below as patch-identical. It does not mark every rewritten commit that way.
It marks old steps 1, 2, 4, 5, 17, 19, 26, 34, 36 and 38 as modified, and also
old steps 118, 123, 175 and 186, which it pairs with steps 116, 121, 173 and
184. It shows old steps 116 and 117 without a counterpart, and it does not pair
old step 16 with new step 16. The commit identifiers in the older sections
below refer to the history before the rebase.

Three tip commits adapt the branch to the new `main`. Commit `59af2476` states
act-scoped reuse and in-process tools in `runtime/BROKER.md`. Commit `c9c86eee`
recomputes the ACP and TUI probe expectations against the new examples.
Commit `fb292465` takes the tracker export of `doc/PLAN.org`. The rebase audit
(`resume-20260923/R/fess-rebase.md`) found no critical or high finding. It
recorded that the edited `test/tui_probe.py` expectations were never run
(M3), that the epoch obligation of the broker contract has no conformance
test (M4), and that frontend preparation of a row with in-process tools is
untested (M5). The audit of the rewritten history
(`resume-20260923/R/history/fess-every-commit.md`) supports this statement
under the definition in its section 2: every commit builds `lib:agentic` with
`-Werror` and every default-flag component without `-Werror`, with the
recorded package sets on macOS. For 64 of the 203 commits, the tree is
identical to a tree with recorded passing builds. The audit covers the other
139 commits by inference, because each differs from such a tree only in paths
that no component compiles. A warnings-fatal build of all components fails at
steps 190 to 203. A12W fixes that failure at the current head.

Nothing from this run is published. As read from the remote-tracking refs
without a fetch, `origin/workflow-manager-checkpoint-20260923` is still
`b95ce6d1` and `origin/tui` is `6b7c90b7`. Because the history is rewritten,
publication of the branch needs a force-push. The rebase brief reserves that
step for John's approval, and no such approval is recorded.

### Commits and subtask results

At the stop, the branch head is `290e02323bc1aa091c3547f7197ef48e4209c635`,
which is the A12W commit. The table gives each subtask's current commit and
the identifier that the workflow ledger recorded before the rebase. Each row
states its strongest evidence and that evidence's ceiling. The private
evidence for subtask `X` is under `resume-20260923/A/X`, and its audits are
under `resume-20260923/fess`. The audits of this closeout subtask are
`fess/Z-HANDOFF-r1.md` to `fess/Z-HANDOFF-r3.md`. Rounds 1 and 2 replaced the
2026-09-24 closeout audits of the same names. A copy of the 2026-09-24 round-3
audit is kept at `Z/HANDOFF/impl-r3/H3-preserved-fess-Z-HANDOFF-r3-20260924.md`.

| Subtask | Commit (ledger) | Result and evidence ceiling |
| --- | --- | --- |
| A0 | `25709730` (`32c72f80`) | The checkpoint rebuilt on unchanged source. The forced Werror build, the contract probe, `tui-model-test` at N1 and N8, and `tui-approval` at N1 then N8 (actual UI interaction) passed. This baseline ends at approval and detach. |
| A1 | `3adfbdcb` (`9d437202`) | Independent baselines on unchanged source. The read-only service TUI, the 18 public-client scenarios, `tui/ci/tui.sh` and `make -C doc check` passed. The protected-HTTP mixed workflow (S1) failed at N1 in three of three runs. The all-target Werror build (S4) failed in `manager-store-check`, `manager-command-check` and `policy-probe`, and `make -C doc check-haskell` failed on the omitted `Agentic.Cli.Command.TuiService`. |
| A2 | `040a478b` (`1c391627`) | `Agentic.Tui.ServiceLane` classifies unexpected synchronous exceptions as an internal fault, and `acat-tui-internal-faults-jj13` is closed. The evidence is pure model tests, fixed-size renders and eleven negative controls. No PTY run injected a fault. |
| A3 | `eb109664` (`ac4c43b8`) | Approval-key admissibility is the compiled predicate `Agentic.Tui.Approval`, with numbered visible refusals. The evidence is pure model tests over 25200 cases, 26 guard-breaking controls and `tui-approval` at N1 then N8. Most refusal notices were not observed in the actual UI. |
| A4 | `75a3c28b` (`495c3eda`) | `tui-approval` waits for the numbered refusal notice before it reads manager state. The guard-breaking mutants M1 and M2 of `Approval.hs` each failed `tui-approval` at N1 with their consent message, and `acat-tui-consent-barrier-wby2` is closed. |
| A5 | `0697de28` (`fb7ff091`) | Run snapshot, control and decision reads install through the single-flight lane as one composite, with stale rejection, refusal retention and the mutation-key policy `ServiceLane.mutationAdmission`. The evidence is 387 model checks at N1 and N8, 27 guard-breaking overlays and `tui-approval` at N1 then N8. An earlier N8 run failed with the S1 class (`acat-dxos`). |
| A12W | `290e0232` (`290e0232`) | The three pre-existing Werror gaps are fixed at their owners: two manager check executables declare their home modules, and the policy probe classifies `TuiService`. The full `-ftui-tests all tui-model-test` build with `-Werror -fforce-recomp` passed in the shared and in a fresh build directory (package build). `manager/ci/store.sh` and `manager/ci/commands.sh` pass. The audit has no blocking finding. |
| A6 | none | Failed on 2026-09-24 after three rounds. The verifier's `tui-journey` run at N8 hit the S1 class before any step that A6 changed. The round-3 diff is parked, with the unaccepted draft handoff, at `refs/wip/a6-r3-20260924-final` (`3ed13d96`). The current plan lists A6 as not started. |
| A5S1 | none | Two audited rounds, both blocking. Round 3 escalated for an owner decision on `Approval.hs:96` and is parked at `refs/wip/a5s1-r3-20260925-final` (`090477d2`). A5S1C superseded it. |
| A5S1C | none | Failed after three rounds, as the next subsection states. |
| A5R, A5G1, A5G2, A5S2, A7–A14 | none | Not started at this stopping point. |

These are subtask results. None of them accepts a package or a gate. The
refocus note asked for confirmation that the `wby2` consent test includes a
guard-breaking control. The A4 mutants M1 and M2 broke the approval guard, but
they ran at N1 only and are not a repeatable mode in the tree. The committed
mode `tui-consent-control` performs a real approval where a refusal is
expected. It shows that the assertion detects an approval, and it does not
break a guard.

### Uncommitted A5S1C work

Subtask A5S1C was to complete the A5S1 fault classification on the rebased
branch. It failed after three rounds, and its work is not committed. The
worktree holds 13 modified files and 3 untracked files, and nothing is
staged. The modified files are `agentic.cabal`, ten modules under
`manager/src/Agentic/Manager` (`Admission`, `Approval`, `Authorization`,
`Drafts`, `Events`, `Overview`, `Pages`, `Service`, `Store` and `Transport`),
and `manager/test/AdmissionCheck.hs` and `manager/test/ArtifactCheck.hs`. The
untracked files are `manager/src/Agentic/Manager/Fault.hs`,
`manager/src/Agentic/Manager/Fault/Record.hs` and
`manager/test/Agentic/Manager/Test/PrivateLog.hs`. The handoff change is also
uncommitted when the workflow stops, so the digest of the A5S1C change
excludes this file. The SHA-256 of
`git diff HEAD -- . ':!doc/workflow-manager-handoff.md'` is
`b7bbe942216ea165d114ada63d6be630f4e186e076b96c7010ee1b3812ad3d66`. The
untracked files do not appear in `git diff`, and their SHA-256 digests are as
follows:

```text
4ca08c1fdd27d7ad78f004dca22ead05379ae91d690e7e93bc2a65de38a452c6  manager/src/Agentic/Manager/Fault.hs
fb588a8d2dc7e220e3187ad07f796d2c0e75810f6cf33ac73f8431a760d85c46  manager/src/Agentic/Manager/Fault/Record.hs
e54755e2ff758a40ff52bdc2fdc5fc5cfc46b73cb396e40801e7e4c3dd34eb45  manager/test/Agentic/Manager/Test/PrivateLog.hs
```

The diff adds the fault classification `Agentic.Manager.Fault`. The diagnosis
record `A/A5S1C/impl-r3/A5S1C3-diagnosis.md` states that at each site that
A5S1 and A5S1C converted, a refusal that replaces its cause also writes a
private line with the class of that cause. The conversion is partial. Section
5 of that record lists the sites that still replace a cause without a record.
Section 6 states that each converted site has a check and a control, except
`Approval.hs:96`, which is the accepted gap below. The blocking audit below
shows that this statement is untrue for the classification at two further
sites. The fault-classification model tests check that a declared refusal
keeps its own public problem, that Store contention, Store I/O failures and
the other classes keep the public storage-unavailable problem, and that no
public problem, private record or erasure record holds exception text. No
check covers the public status of every path.

On this source the round-3 verifier passed the Werror build of every manager
target and `tui-model-test` (package build), the 83 fault-classification
model tests at N1 and N8, and the eight `service-faults` checks at N1 and N8
(deterministic native fixture). The owning gates `configuration`, `commands`,
`store`, `ingestion` and `admission` passed at N1 then N8 with 16, 753, 518,
1064 and 622 checks. The six red manager gates kept their baseline signatures
and counts. Of 39 carried guard-breaking controls, 38 made at least one
checker fail, and K19 passed, as the operator-accepted gap requires. The
policy and privacy scans passed. The evidence is under
`resume-20260923/A/A5S1C/verify-r3`.

The audit `fess/A-A5S1C-r3.md` is blocking. Two converted classification sites
have no check. The verifier's control K42 restores a constant
`StorageUnavailable` at `Service.hs:125` (an uncaught failure of the admission
poll) and passes the `service-faults`, full admission and fault-classification
checks. Control K45 does the same at `Service.hs:162` (`Service.drive`) and
passes the `service-faults` and fault-classification checks. It was not run
against the full admission check. Both controls pass because both service
fixtures feed only that value. The diagnosis record
`A/A5S1C/impl-r3/A5S1C3-diagnosis.md` claims coverage for these sites in its
sections 3 and 6 and omits them from its section 7.

### S1 failure family

The diagnosis of the S1 family rests on 16 valid capture starts from A5S1
round 1 and its verifier. The declared budget of 20 starts is spent, and the
operator did not extend it. What follows is from `A5S1C3-diagnosis.md` and
the A5S1 round-3 record it carries forward
(`A/A5S1/impl-r3/A5S1r3-diagnosis.md`).

- S1-a is proven at its owning layer. In 16 of 16 valid starts the receipt
  response `Application.receipt`, which is
  `Authorization.withAuthorizedResponse`, failed fast with a raw `StoreBusy`
  before the response started. The enqueue had committed once inside
  `Admission.operation`. The client treated the outcome as uncertain, and no
  operation was replayed. Which of five candidate steps raised the `StoreBusy`
  is unproven, and so is the holder of the gate or guard. The admission poll
  that the enqueue notified is the likely holder, by inference only.
- S1-b, a request that stays queued with admission waiting, was not captured.
- S1-c, a refusal of the first profile read, was not captured. In a related
  in-process observation, a draft creation and an enqueue issued at once
  inside `Service.withService` were refused in four of four N1 attempts with
  no private line. That reproduction exists only as prose and preserved
  roots.
- In the captured roots, the closed releases timed with teardown are proven
  to be the manager shutdown after the fixture's SIGTERM. The serving-time
  release in root `tui-A5v1.HiOeMcH7/tui-approval-N8` remains unproven
  (`acat-dxos`).
- `acat-response-ingestion-budget-zaoi` is a sibling of the same contention
  family. It is not the S1-a mechanism, because no run and no ingestion
  existed at any captured S1-a refusal.
- The earlier roots from A1, A5 round 1 and A6 hold no private fault line,
  so whether they failed through the S1-a step is unproven. In their Store,
  the A6 round-2 implementer `tui-journey` N1 root and the A6 round-3
  verifier `tui-journey` N8 root each hold one preparation row that is
  invalidated with the reason `worker-lost`. The three A1 roots and the A5
  round-1 root hold no preparation row. The A6 round-1 and round-2
  `tui-approval` N1 roots, whose request stays queued with admission waiting,
  hold no preparation row either. The 2026-09-24 closeout verifier
  queried copies of these databases (`Z/HANDOFF/verify-r3/HV3-s1-db-counts.log`,
  `HV3-s1-variant1.log` and `HV3-s1-preparations.log`).

The fixture roots are under `/Users/johnw/Products/k.M0a5ItPm/tmp`.

### Open findings and decisions

- A5S1C, blocking: give `Service.hs:125` and `Service.hs:162` a deterministic
  non-storage input class so that K42 and K45 fail, or escalate a site that
  cannot be reached without a production hook as a recorded gap with its
  control and a tracker issue. Correct sections 3, 6 and 7 of the diagnosis
  record in the same change.
- Operator decisions of 2026-09-25, recorded in section 2 of the A5S1C
  diagnosis: the configuration loan of `Approval.publishReview`
  (`Approval.hs:96`) is an accepted gap that control K19 demonstrates, and the
  capture budget is not extended. The tracker issue for the accepted gap and a
  tracker candidate for the S1-c reproduction do not exist yet. The Integrator
  creates them.
- `acat-dxos`, P1: its title still names only the A5 round-1 `tui-approval`
  N8 failure. The planned subtask A5S2 is to fix the proven S1 cause at its
  owner and to re-establish the manager-path baselines.
- Six manager gates are red with unchanged signatures: `approval` (history
  policy), `artifacts` (`manager-history-check: ProcessFailure`), `drafts`
  (`manager-draft-check: ProcessFailure`), `vertical`
  (`WorkerPreparedFraming`), `workers` (configured ordered prefix) and
  `controls` (the `Machine.hs` boundary anchor). The rebase audit classifies
  them as red before the rebase. The planned subtasks A5G1 and A5G2 diagnose
  and restore them. `cli/ci/policies.sh` stops at the `drafts` failure
  (`acat-drafts-processfailure-j1h0`, P2).
- `make -C doc check-haskell` fails because the manual omits
  `Agentic.Cli.Command.TuiService` (`R/verify-docs-r1/doc-check-haskell.log`).
  A14 owns that reconciliation. `make -C doc check` passes.
- The rebase audit findings M3, M4 and M5 belong to the planned subtask A5R.
- `acat-response-ingestion-budget-zaoi` and `acat-tls-name-forms-6gbo`, P1,
  are unchanged and open. `acat-tls-name-constraints-0h7q` stays in progress.
- `acat-ftw9`, P2: a recorded decision on refresh while a mutation key is
  deferred is required before A7. `acat-lzlp`, `acat-5k82`, `acat-47ax` and
  `acat-i9aj`, P2: App wiring for refusals, key outcomes, approval and the
  composite install is covered by inspection only, and the post-boundary
  reads of `tui-approval` have no control that reaches them.
- The Integrator recorded the A0 to A5 audit follow-ups as tracker issues. Of
  those, 27 at P3 and 3 at P4 remain open. The A12W audit added
  `acat-tui-service-isabsolute-mutant-mt3d` at P3 and
  `acat-cabal-version-reading-0fnq`, `acat-a12w-evidence-convention-9cet` and
  `acat-tui-service-relative-pin-l7ny` at P4.

The workflow record lists no pending authorization request. Publication of
the rewritten branch waits for the force-push approval described above. The
standing restrictions of the halt section remain in force.

### Resume procedure

The first commands run in a plain shell. The toolchain check runs through
`direnv exec .` with the private environment:

```bash
cd /Users/johnw/src/agent-cat/.worktrees/tui
git status --short --branch
git log -1 --format='%H %P'
git rev-parse tui
git diff HEAD -- . ':!doc/workflow-manager-handoff.md' | shasum -a 256
shasum -a 256 manager/src/Agentic/Manager/Fault.hs \
  manager/src/Agentic/Manager/Fault/Record.hs \
  manager/test/Agentic/Manager/Test/PrivateLog.hs
direnv exec . bash -c 'source /Users/johnw/Products/k.M0a5ItPm/environment.sh &&
  cd /Users/johnw/src/agent-cat/.worktrees/tui &&
  ghc --numeric-version && cabal --numeric-version &&
  ghc-pkg field crypton-x509-validation version'
```

Two states are expected. Before the Integrator commits this section, HEAD is
`290e02323bc1aa091c3547f7197ef48e4209c635`, and the worktree holds the
uncommitted A5S1C change and this handoff change. After the Integrator
commits this section and nothing else, HEAD is that commit, its parent is
`290e02323bc1aa091c3547f7197ef48e4209c635`, and the worktree holds only the
uncommitted A5S1C change. In both states `tui` is
`6b7c90b79b47c85d07162bb11d038349dbac9131`, the digest command prints
`b7bbe942216ea165d114ada63d6be630f4e186e076b96c7010ee1b3812ad3d66`, and the
three untracked files have the digests that the previous subsection gives.
Any other result means that the branch or the worktree changed after this
section was written, and the reader establishes that change before
continuing. If direnv reports a stale or blocked environment, run `de` in the
worktree and repeat the check. Rebuild before any binary runs, with the build
set that A5S1C used:

```bash
direnv exec . bash -c 'source /Users/johnw/Products/k.M0a5ItPm/environment.sh &&
  cd /Users/johnw/src/agent-cat/.worktrees/tui &&
  bash test/cabal.sh build lib:agentic agentic-run routing-fixed-point-probe \
    manager-client-check manager-profile-probe manager-root-probe \
    manager-configuration-probe manager-store-check manager-command-check \
    manager-draft-check manager-worker-check manager-admission-check \
    manager-approval-check manager-vertical-check manager-artifact-check \
    manager-history-check tui-model-test \
    --with-compiler="$(command -v ghc)" --with-hc-pkg="$(command -v ghc-pkg)" \
    --ghc-options="-Werror -threaded -rtsopts"'
```

The next work proceeds in this order:

1. Resolve the blocking A5S1C finding and correct the diagnosis record. The
   Integrator then commits A5S1C and creates the two tracker issues named
   above.
2. Resolve the rebase audit follow-ups (A5R).
3. Diagnose and restore the six red manager gates at their owners (A5G1 and
   A5G2).
4. Fix the proven S1 cause at its owner with a regression test, and
   re-establish the manager-path baselines at N1 and then N8 (A5S2).
5. Restore the parked A6 diff without its draft handoff, and continue with A6
   to A14: live progress, the Bool `false` answer, the offered retry, native
   completion, `Client.downloadVerified` with an exclusive save, and one
   uninterrupted PTY journey at N1 and then N8 with a broken-step negative
   control. Documentation follows only after the journey passes.
6. Record the manager broker amendment (M0). After Phase A is accepted, land
   its seam (M1) before WM-028.

Run the `fess` audit at the end of every subtask, preserve the first failure of
any check with its fixture root, and label every result with its evidence
ceiling.

## Halt checkpoint of 2026-09-23

The operator requested a clean stopping point, commits, publication and a
complete remaining-scope report. Resume from
**`origin/workflow-manager-checkpoint-20260923`**, not the archived pre-broker
prototype. The [portable checkpoint](checkpoints/wm023-20260923/README.md) contains
the exact source sequence, verification scope, preserved non-secret evidence,
known findings and commands for this machine or a fresh clone.

The checkpoint contains four logical code commits: compatibility domains
(`12fc322`), the protected service (`910db084`), the public client (`073508ff`),
and TUI request/approval support (`d8c0609a`). Each committed source boundary has
its own recorded validation. The older prototype is preserved separately as
`archive/service-tui-pre-broker-20260923` at `74ad50e9`. It is not the resume target.

The actual TUI reaches Unicode submission, complete five-selector review,
explicit approval, association and detach through the manager and default broker.
N1/N8 PTY checks confirm that the manager-owned run remains controllable after
frontend exit. The newest run/control/decision/output adapters compile and pass
focused public-fixture tests, but are not wired into App. Live display, typed
`False`, offered retry, genuine terminal completion and verified result retrieval
through one uninterrupted TUI session remain unfinished.

Accepted state remains **WM001–WM022 and G0/G1**, or **22/44 packages and 2/6
gates**. The halt fess audit permits WIP preservation only and blocks application
acceptance. Its history isolation was not independently verified. The response
liveness issue (`acat-response-ingestion-budget-zaoi`), general-CA validation
(`acat-tls-name-forms-6gbo`), internal-exception classification
(`acat-tui-internal-faults-jj13`) and approval-test synchronization
(`acat-tui-consent-barrier-wby2`) remain open.

The full remaining-scope report is
`~/dl/agent-cat-workflow-manager-remaining-2026-09-23.md`. Its complete target
retains WM023–WM044 and G2–G5 under the broker, TUI-first and local-only amendments.
The corresponding requirements also remain in the tracked plan and checkpoint
so source recovery does not depend on the report's local file.

Run the **`fess` skill at the end of every downstream subtask**, including failed
attempts, tests, documentation, cleanup and review. Record findings and verification
ceilings before moving to the next subtask. Do not silently waive the audit when
the skill is unavailable.

The shared build directory was last used for the historical prototype. Rebuild
the chosen current source before running binaries. Preserve exact command objects,
original resource handles, Store policy and all recorded failures. Never treat
an old PID, path, cursor, receipt or process absence as execution or cleanup
authority. No paid provider, deployment, external-host execution, live configuration
change or new Lean/oracle build is authorized by this halt.

The following sections retain the development chronology. This halt section and
the portable checkpoint supersede their earlier current-state descriptions,
without altering historical evidence or completed task states.

## Delivery direction of 2026-09-22

WM-022 and G1 are accepted on 2026-09-22 under the local-only validation
amendment below. The vertical slice was integrated at `ea0fc12c`, and current
application evidence includes the response correction at `72c2abf`. The accepted
baseline is WM-001–WM-022 and G0/G1, which is 22 of 44 packages and two of six
gates. The next product milestone is one frontend completing a full workflow
through a running manager and the default data broker. The confirmed goal selects
the existing TUI first, followed by the other frontends and operational hardening.
G2–G5 remain open.

The user's 2026-09-17 refocus continues to govern delivery. Do not reopen the
verification-machinery micro-fix loop, paused L08 review or historical recovery
as a substitute for the next product milestone. The completed
[closure plan](workflow-manager-closure-plan.md) and implementation plan remain
the references for their respective scopes, subject to the user's corrections
below.

## TLS update and isolated progress of 2026-09-23

The user authorized the targeted Nix dependency update on 2026-09-23.
`crypton-x509` and `crypton-x509-validation` are now pinned to `1.9.1`, with
compatible crypto/TLS dependencies and unchanged GHC 9.10.3 and flake lock.
The upstream release addresses the exercised DNS Name Constraints failure in
[CVE-2026-9648](https://haskell.github.io/security-advisories/advisory/HSEC-2026-0008.html).
A one-line shared-validator patch also fixes IP-only SAN precedence over common
names. Normal certificate, signature and hostname checks remain enabled.

The canonical change is limited to Nix overrides, that patch, its source-archive
entry, the `memory`-to-`ram` dependency change and the existing TLS probe fixture.
Reviewer `63fdf53f-c03b-463a-9c3d-bbdfdb66a43f` approved bounded integration with a
packaging note. Parent added the missing archive entry and confirmed its exact
bytes in the source distribution. Service/client application code was then isolated
in `implementation.9tGzKH/service-tui.purvEwEv/broker-source`.

After actual relinking, all 18 public-client cases passed at N1 and N8.
They include permitted and excluded DNS constraints, IP-only SAN success,
matching-CN rejection, credential changes, bounded pages and original request
cancellation. The public Haskell Client also passed real protected-manager
observation at N1 and N8, including actual pages, polling and session binding.
Earlier certificate failures and the stale-executable run remain preserved.

General-CA service acceptance remains open. Issue `acat-tls-name-forms-6gbo`
records unsupported IP Name Constraints and further upstream validation concerns.
The passing cases are not complete PKIX assurance. The original update issue
`acat-tls-name-constraints-0h7q` retains that qualification rather than claiming
all certificate-validation obligations are complete.

The earlier protected HTTP `mixed-controls` journey passed at N1 and N8 at
09:17:56–09:19:14Z. A later retest with the updated environment failed at N1
because its request stayed queued without preparation until the observation
deadline. The cause is not established, and the request was not replayed.
Neither run is actual TUI interaction, and no new WM package or gate is accepted.

Canonical dependency checks passed at N1 and N8. The first combined check timed
out while compiling the Haskell documentation workspace, after its native checks,
archive check and prose gate completed. The separate resumed Haskell documentation
gate passed at 19:43:35–19:45:39Z. Its success does not certify the earlier timeout
or its cleanup. Exact scopes and failures are in the service unit's `tls-update.md`.

The service-liveness review still needs continued clearance after the loan-order
correction, and its separate slow-response limit remains unresolved. The TUI
service implementation is unfinished. Continue that product path and its required
security work without a trust bypass, opaque replay or historical-recovery detour.

## First frontend through the running manager

The user's 2026-09-22 direction makes an integrated frontend run the next
meaningful milestone. It must submit, explicitly approve, observe live progress,
answer a decision and exercise a supported control, finish, and retrieve verified
results through an actual running manager. Additional isolated helper deliveries
are not substitutes for that result.

The confirmed goal selects the TUI first. Reuse its existing presentation and
the public client facade. Runtime remains the sole workflow interpreter, while
the manager retains admission, original worker ownership, FIFO and artifact
authority. Service mode must neither launch a local frontend
nor read manager filesystem paths, and local mode remains intact. The acceptance
run uses actual keyboard/PTY interaction, protected HTTP and deterministic real
frontend processes, not mocked manager success.

Backend, client and acceptance work were then reconciled as one delivery path.
The confirmed delivery order does not require completed Emacs work before this
first TUI milestone. Emacs remains unfinished rather than implicitly accepted.
Other frontend work and broader hardening follow the first integrated run.
Required authentication, exact approval, boundedness, truthful outcomes, cleanup
and non-replay remain prerequisites for the enabled path. A successful first run
does not by itself close the remaining packages or release gates.

## Data-broker architecture amendment of 2026-09-22

The user requires an injected data broker API and a working default Haskell
implementation, without new workflow semantics. Runtime offers addressed requests
through that broker, connected engine adapters return responses through it, and
runtime consumes those responses to advance the existing plan. Control ingress,
events, logs and persistence edges also use the broker boundary. A passive copy
of messages beside unchanged direct execution does not satisfy the requirement.

Runtime retains decoding, retry, failover, memoization, scheduling, policy and
authored interpretation. The broker routes and distributes data without becoming
another interpreter or execution authority. Existing bounds, exact consent,
typed values, original owners, failure distinctions and non-replay remain in
force. Preserve current protocol/storage behavior and existing private/public
log destinations rather than silently exposing private diagnostics.

The current scope includes only the API and default in-process implementation.
RabbitMQ and possible integrations with John Mark's tools are deferred follow-ons,
not acceptance blockers. The extension contract must distinguish message data
from local live capabilities, which cannot be serialized or reconstructed from IDs.
The default broker is a prerequisite inside the first full frontend delivery.

The default broker implementation is integrated after independent review. The
reviewed delta is `implementation.9tGzKH/broker.V0Omy9B2/broker-corrected.patch`,
with 17 files, 684 insertions and 156 deletions. Canonical application bytes and
Git executable modes match that candidate. `DataBroker`, `runPlanBrokered` and
`cliMainWithBroker` carry actual execution traffic through the shared owners,
with the operation and extension contract in `runtime/BROKER.md`.

Reviewer `e0d3c715-755c-48bb-80b2-21103d455dcf` found no remaining issues and
supported this bounded integration. The original candidate was blocked because
steering swallowed asynchronous scope cancellation. The correction at the shared
control-delivery owner preserves synchronous failure acknowledgements and allows
the original reader to terminate and join. The deterministic red and corrected
N1/N8 results remain in the unit alongside the prior failures.

Local evidence includes actual ACP replies and final publication through an
injected broker, Hello World, exact bills and authored traces, controls and typed
person answers, prepared frontend execution, lineage, and the deterministic deck
gate. `validation.md`, `correction.md` and both review reports retain the exact
scopes. Canonical boundary and documentation checks passed on 2026-09-23.
This does not accept WM-023, a protected manager service or the TUI journey.

The original eight-file service/client work remains preserved in
`service-tui.purvEwEv/source` and `pre-broker-work-in-progress.patch`, with 986
insertions and 74 deletions. Its continuation is in `broker-source` on the
integrated broker base. The isolated service then executed real protected
HTTP traffic, with explicit native-version domain corrections and both polling
and SSE. Neither source has been overlaid onto canonical without review.

## Local-only validation amendment of 2026-09-22

The user removed Linux, remote-host and cross-platform validation requirements
and confirmed the revised persistent goal. Required builds, tests, compatibility
checks and acceptance validation run only on this macOS machine in the existing
Nix/direnv environment. This amendment overrides conflicting platform clauses
in the frozen requirements and task verification contracts, including WM-022/G1.
No Linux validation or associated remote approval remains a prerequisite.

Functional requirements, negative assertions, independent review and existing
safety limits remain unchanged. Existing local evidence retains its actual
scope. Historical platform results and failures remain records rather than
requirements to repeat, and untested platforms are not represented as passing.
Accepted WM-001–WM-021/G0 remain closed. WM-022/G1 are now accepted against
local evidence and independent review, with unfinished WM-023 as the next work.

## Scope correction of 2026-09-20

The user's clarification of 2026-09-22 supersedes the earlier broad wording
of this section. No sandbox implementation is requested or planned. The existing
process-group probe is not a sandbox and is not an authorization violation.
Do not infer an excluded-test requirement from the earlier summary.

The full WM-001–WM-044 and G0–G5 delivery remains the objective. Historical
research remains a record and does not create an additional sandbox deliverable.
Before running an aggregate validation gate, inspect its actual invocations
and relevant nested drivers. Escalate only a concrete owner decision.

Ordinary ownership, cancellation and cleanup of application-owned processes
remain in scope. Retain original handles, join outcomes, uncertain-cleanup
quarantine, storage-safety behavior and the prohibition on signalling stored
PIDs. Do not claim that these mechanisms contain arbitrary descendants or undo
provider effects. The clarification does not close other package criteria.

## WM-022 and G1 acceptance

Issues `acat-wm-022-j655` and `acat-g1-h1wc` are closed. All nine recorded WM-022
dependencies were already accepted. The isolated unit is
`implementation.9tGzKH/vertical.d42c7UhQ`, with
source branch `wm022-vertical.d42c7UhQ` based on acceptance commit `c6698af4`.
Private runtime paths are under `/Users/johnw/Products/v.OSGikI2D`, with a
serialized sibling builddir and supplied offline environment.

The reviewed six-file implementation adds `manager-vertical-check`, its owning gate, a strict
typed Runtime comparator, CLI fixture/comparison hooks and documentation.
It retains existing frontend, Runtime and manager owners without production
changes. Actual direct/managed answers, authored traces, exact bills, policies,
typed values and lineage are compared under explicit physical correspondence.
The literal-prompt lineage fixture declares its independent model and shared
person lane, preserving all events and within-lane order without global sorting.
A02, A10 and A13 remain explicit obligations.

Tracker comments 286–288 and the unit's `brief.md`, `start-note.md` and
`parent-result.md` record the grant and current evidence. The complete local
owning gate passed at N1 then N8 on 2026-09-21, 21:54:55–22:09:39Z, including
the existing instrumented history-corrections and control-write audits.
Compiler-parsed boundaries and both documentation gates passed afterward.
`proposal.patch` contains 431 insertions and 5 deletions against `c6698af4`.

Five failed build/gate invocations remain preserved. They exposed nested-case
syntax, an overly strict total event order, partial list access and two audit-only
helpers called without their existing instrumentation. No semantic assertion
was removed. Author `ff060536-6859-422c-8722-da9fe8ecebd2` reached its default
agent deadline after the third failed build, between commands. Parent inspected
original returns and partial source, took sole writing ownership and ran
subsequent gates directly.
The timeout is not test success, and runtime budgets were unchanged.
The initial incorrect compiler-error/time report was corrected from raw output.

Independent reviewer `7e8ef36b-3588-40fc-a8fa-9fc53f4a639b` found no issues,
classified the architecture as aligned and cleared integration. Parent applied
the exact six-file proposal, verified both its full delta and file-byte equality,
and passed canonical source boundaries and documentation. Current-byte isolated
native, audit and Haskell-documentation evidence is reused at its stated scope.
`review.md` and `integration-note.md` retain the verdict and integration facts.

Continued milestone reviewer `53ee90a0-49e3-48f4-a005-cb64521f9980` found no
issues and gave separate SUPPORTED verdicts for WM-022 and G1 under the local-only
amendment. Parent accepts both at the isolated-core boundary. The current
application passed the complete vertical gate at N1 then N8 on 2026-09-22,
08:48:34Z–09:00:58Z, after the WM-023 response correction. Its original audits
and subsequent boundary/documentation results are retained in
`credentials.QHYL3FHM/response-result.md`. The only vertical fixture changes
are ignored response-view callback parameters, with comparisons and assertions
unchanged. Both audit results retain original-child joins and their actual
outcomes. No Linux run is required or claimed.

G1 combines this real-worker demonstration with accepted WM-008–WM-021/G0
foundations at their recorded scope. It is not inferred from dependency closure
alone. `review-local-closure.md` and `acceptance-note.md` record the two decisions.
Original failures remain failed, composed Store evidence remains composed, and
no physical-power-loss, arbitrary-descendant containment, cross-process ABA or
total-service resource claim follows.

Parent retains Git, tracker, integration and acceptance decisions. Existing
source-valid evidence is reused at its actual scope. No new interpreter,
recorder, inventory, retention helper, per-leaf review or old-root recovery
work was needed for closure.

## Active WM-023 local implementation

Issue `acat-wm-023-d20b` is in progress with its four dependencies closed.
This work remains separate from the accepted isolated core. The unit is
`implementation.9tGzKH/credentials.QHYL3FHM`, with source
branch `wm023-credentials.QHYL3FHM` based on `a54b310b`. Private roots are under
`/Users/johnw/Products/k.M0a5ItPm`, with a serialized sibling builddir.

The bounded interface check is complete in `seams.md`. Tracker comments 289–294,
the unit briefs and the parent/correction/integration reports describe the
implementation. It extends the original Store/Authorization owners with embeddable credential operations
and the frozen offline CLI. An already-owned Store must refuse a second writer.
Live external administration remains an unresolved integration obligation,
rather than being silently treated as satisfied.

Rotation uses a fixed documented 60-second positive overlap, preserves the
registered client/label/scopes, never extends old authority and retains at most
the current/immediate predecessor pair. Legacy labels use non-secret credential
IDs. Lists over the frozen bound refuse whole. Durable private secret publication
precedes activation, preserving inert-file and uncertain-COMMIT outcomes without
retry or cleanup inference. Authorization views and wakeups do not become
Worker cancellation or an unimplemented transport claim.

Code-only author workflow `9701c7dc-7e30-484a-b36f-86a71f1297b0` timed out
after leaving its handback and patch. Parent inspected the original returns,
took sole writing ownership and ran compiler/native validation directly.
The failed author invocation remains failed. Its original report and patch
are historical snapshots, not current validation or review conclusions.

Parent corrected three compiler errors, one pre-link synchronization-fault
expectation and a genuine authorization-view defect. An ordinary request
mutation no longer invalidates unchanged authority. Coalesced Store signals
prompt one current-fact observation, acknowledged only across a stable
generation. A concurrent commit refuses that observation without replay or
consuming the invalidation. Worker stop cells remain separate.

Before independent review, Commands, Artifact/History and Store passed at N1
then N8 on 2026-09-22 from 00:42:09Z through 00:56:41Z. Configuration, Dependency, Worker,
compiler-boundary and documentation checks passed afterward through 01:10:53Z.
The dependency gate includes local TLS and process-group probes. Their results
remain ordinary evidence at the recorded scope, without a new sandbox claim.
All original failures and raw command records remain in the unit.

The first coherent review found a COMMIT-to-notification acknowledgement gap
and two valid-input defects. Parent corrected final acknowledgement through
original fail-fast Store admission, NUL-safe label storage with the unchanged
Unicode grammar, and RFC3339 case normalization before comparison and persistence.
A deterministic existing-auditor regression reached the actual COMMIT gap before
the correction and passed at N1/N8 afterward. The failed red command and an
unsuccessful first NUL correction remain preserved.

The first integrated partial application is `proposal-review-corrected.patch`,
with 20 files, 1125 insertions and 40 deletions, committed at `ca9a39d`. Continued reviewer
`7c9d4569-1caa-4ce3-8265-526f2c599581` found all three findings resolved,
no new implementation defects and architecture aligned.

Corrected Commands passed from 04:50:41Z to 04:55:19Z on 2026-09-22.
Artifact/History passed from 04:57:56Z to 05:01:10Z. The Store wrapper ran
from 05:01:10Z to 05:12:10Z and remains exit 1. Its native sections and first
three audits passed. Its final expiry-mutant stopped during compilation and
configuration because the pinned `ghc-pkg` path was unavailable. Neither native
expiry case ran then, and setup failure is not an intended negative assertion.

The user arranged environment regeneration and requested resumption after
thirty minutes. Parent checked the regenerated environment at 07:46:06Z–07:46:08Z.
The original wrapper path, GHC9.10.3, ghc-pkg9.10.3 and Cabal3.16.1.0 are
available again. Tracked recipes are unchanged, and parent performed no
regeneration or compiler substitution. The earlier absence cause is not established.

The final expiry-mutant passed at N1/N8 from 07:49:24Z to 07:51:58Z.
Corrected-byte boundaries and both documentation gates passed from 07:52:53Z
through 07:56:01Z. Store evidence is composed from the successful current-source
sections of the failed wrapper and the successful resumed tail. No whole-wrapper
pass is claimed, and successful Commands/Artifact evidence was not repeated.

Continued reviewer `9adad443-b927-4346-b7bf-ced660b88bb6` explicitly cleared
partial integration after inspecting these results. Parent applied only the
reviewed application patch to canonical and verified identical bytes and Git
executable modes. An initial comparison of all filesystem permission bits failed
because the four new files retain private umask0600 rather than isolated0644.
No source correction or permission widening followed that verification mistake.

Canonical boundaries passed at 08:04:27Z–08:04:28Z, and canonical documentation
passed at 08:04:28Z–08:04:31Z. `validation-resumed.md`,
`review-partial-integration.md` and `integration-note.md` retain the evidence
and qualifications. The application is integrated as partial, unaccepted work.

The response/configuration composition gap is now corrected through the existing
owners. The nine-file `response.patch`, 171 insertions and 105 deletions, was
developed on `wm023-response-composition` in `response-source` based on `ca9a39d`.
Store composes one reader charge, the configuration loan and an original watch,
closing the watch before releasing configuration. Ordinary views retain their
independent configuration checks. Existing artifact, output, export-collection
and history-result callbacks receive a response-scoped view.

The original valid-response regression failed at 08:21:34Z–08:21:57Z.
Artifact/History, Commands and the real non-network vertical gate passed at
N1 then N8 from 08:35:52Z through 09:00:58Z, including existing audits.
Boundaries, both documentation gates and final composition passed through
09:08:01Z. Tests cover single-slot quotas, escaped views, unchanged authority,
unrelated-client changes, actual quiet expiry and revocation. Watch/guard release
ordering is supported by source structure, not a separately instrumented test.

Continued reviewer `accc4446-513a-4e8c-8c9a-a7ca1a48426e` found no issues and
cleared integration. Parent verified the exact patch, bytes and Git modes at
09:21:11Z. Canonical boundaries and documentation passed at 09:21:42Z–09:21:46Z.
`response-result.md`, `review-response.md` and `response-integration-note.md`
retain results, qualifications and the original failures.

The next local-administration layer is integrated from `live-source`, branch
`wm023-live-administration`, based on `834afeed`. Its corrected fourteen-file
patch contains 570 insertions and 77 deletions. The frozen stdin CLI can reach
the original running Store through an explicitly configured same-user Unix
socket. The optional private `administrationRoot` is separately leased, and the
original installation lease remains retained without holding configuration or
file guards across the listener lifetime. Configured channel failure never
falls back to another Store or replays a request.

Current native Commands and real offline/live CLI checks passed N1 then N8 at
19:13:32Z–19:14:13Z on 2026-09-22. They cover held-response revocation, unchanged
worker-registration signals, real dropped replies and endpoint ownership.
Configuration, Artifact/History, boundaries and both documentation gates passed
at their recorded scope. Unchanged opacity/COMMIT-gap evidence is reused rather
than represented as another whole-wrapper pass. The registration test does not
claim a separate physical frontend launch.

Continued reviewer `3eafb77d-1d6b-4bf4-b4cd-c1de8c97e127` cleared integration
with no remaining findings. The timeout-envelope defect was reproduced against
the frozen schema before correction, and its original failure remains preserved.
All five failed native/build invocations, earlier failures and private roots
retain their original outcomes. Parent matched every reviewed byte and Git
executable mode at 19:21:52Z before recording this integration.
`live-result.md`, `live-correction-result.md`, `review-live-corrected.md` and
`live-integration-note.md` retain the evidence and qualifications.

Foreground service startup, public page/cursor binding and SSE/protected
transport enforcement remain unfinished. WM-023 is not accepted, and G1 closure
does not satisfy those protected-service requirements.

## WM-021 acceptance

Issue `acat-wm-021-ez37` is closed. Continued independent milestone reviewer
`cfb203a1-1751-4bd8-97e6-ffb460b6a128` found no issues and explicitly supported
closure for `248e772e999d483f7017e6d956dc42daf5626400`. Tracker comment 285
records parent acceptance. The complete seventeen-file application delta was
integrated after exact proposal and file-byte comparison, without replacing
stale tracking or frozen records.

Source, reports and original failures remain under
`implementation.9tGzKH/quotas.N3qrqDWt`. Principal reports are
`composition-result.md`, `review-composition.md`, `linux-realized/result.md`,
`review-closure.md` and `acceptance-note.md`. The isolated source and private
macOS roots remain preserved.

Schema 11 implements current-scope quotas, bounded reader admission and atomic
event retention through existing owners. Seven-day or 256 MiB event retention
preserves a consistent retained floor, high water and complete batches, without
deleting native history, lineage or referenced artifacts. Protected receipts
require proven inactivity and at least 30 further days before content retirement.
Non-content tombstones remain charged for the registered client's lifetime,
and quota pressure refuses rather than evicting replay protection.

Capture collection requires manager-recorded provenance, all reference and
safety checks, and 24 hours from durable eligibility. Changed protection resets
eligibility. Unknown or uncertain entries remain retained. Accepted local
create/capture effects count as completed for retention only through exact
original associations, preserving cross-client capture authorization and
unchanged receipts. Historical terminal observation requires bounded shared-codec
replay and same-boundary transactional revalidation. Stored terminal labels
and history never recreate execution authority.

Retained-parent unlink synchronizes the directory even for an absent name.
Synchronization or identity uncertainty preserves the original charge/error.
The reader/profile correction acquires current reader capacity before the
profile/configuration guard and retains both through response within the original
file owner. Current lower-limit reload, authorization, response failure/cancellation
and subsequent sole-slot reuse are exercised. Store/SQLite limits, fail-fast
ordinary admission, bounded terminal-owner waiting and non-replay remain unchanged.

Fresh Linux workspace `/home/johnw/Products/w21r.SHNUXI` used the exact current
archive and unchanged required patched environment. Setup passed separately at
19:54:44–19:54:49Z on 2026-09-21. Each subsequent original SSH, gate and log-copy
operation returned zero.

| Linux gate | UTC start–end |
|---|---|
| API contract | 19:55:02–19:55:03 |
| Compiler-parsed boundaries | 19:55:14–19:55:15 |
| Runtime capture | 19:55:25–19:55:58 |
| Store | 19:56:12–20:08:10 |
| Commands | 20:08:25–20:09:24 |
| Drafts | 20:09:46–20:10:31 |
| Artifacts/History | 20:10:43–20:13:42 |
| Ingestion | 20:13:52–20:33:25 |
| Haskell documentation | 20:33:35–20:35:43 |

Native N1/N8 and intended-negative audit returns remain distinct from build
success. Both-platform WM-021 Store wrappers and the Linux Ingestion wrapper
passed. The earlier macOS Ingestion wrapper remains exit 1, with explicitly
source-valid completed constituents and four later corrected audit phases.
Earlier unchanged macOS owning evidence remains reused at its actual scope.
Linux full Texinfo rendering remains NOT RUN, with current-byte canonical
macOS documentation evidence reused rather than represented as a Linux pass.

All earlier build, predicate-depth, callback, migration, native-retention
expectation, reader/configuration composition and audit-anchor failures remain
in their original reports and roots. The initial review clearance was superseded
after the actual composition defect. The corrected source review and final
closure review support the accepted implementation.

The old `/home/johnw/Products/w21.g0thhv` bootstrap remains untouched and
unclaimed. Its original SSH/Nix terminal and join evidence is still missing.
The fresh lane neither adopts that operation nor proves its cleanup. Explicit
realization and fresh validation were approved without version, lock, profile
or host-security changes. The new lane's post-run tar comparison remains exit 1
for recorded Mode/Uid/Gid differences only, with no content/error diagnostic,
correction or retry. Store stderr retains offline-package and bootstrap
diagnostic-write compiler warnings, so no blanket warning-free claim is made.

Acceptance does not establish total-service heap/disk bounds, physical-power-loss
durability, real elapsed retention from aged fixtures, cross-process ABA
protection or deterministic historical-terminal-observation post-replay/pre-COMMIT
coverage. Later HTTP/client obligations and G1 remain open. OS containment
remains excluded throughout the roadmap.

## WM-020 acceptance

Issue `acat-wm-020-5x61` is closed. Continued independent milestone reviewer
`ea813971-e4a9-41cb-9abc-e7ba6cce0d1f` found no issues and explicitly granted
closure for `626981a72eceb9b4e5400bf188ab60901311243f`. Tracker comment 272
records parent acceptance and the approved same-root, readable-current-safety
restoration boundary. Source, corrections, raw failures and final
`review-closure.md` remain in `implementation.9tGzKH/restart.gQ3o7Iag`.

The unit supplies ordinary startup reconciliation and coherent offline
database/capture restoration through existing owners. Its corrected opacity
boundary and affected consumers passed current validation. The reviewer
accepted source-valid reuse and composed Store coverage without relabeling
failed wrappers or inferring historical cleanup. No containment work is included.

Tracker comments 263–266 and the unit's `brief.md` and `decision-note.md` retain
the authority decisions. The approved restore interface is same-root and
requires validated current safety facts. Its temporary in-progress fence must
not become permanent global admission disablement after successful restoration.
A minimal reservation-owner quarantine extension may preserve newer claims
without fabricating request graphs or live handles. Missing/corrupt current
safety state refuses before publication, and backup-only disaster recovery is
not claimed. The source reviewer accepted this declared supported boundary.

Continued reviewer `3f507dab-91b4-47f5-852e-1b31471b20f3` found no issues
and granted source integration clearance for the corrected thirteen-file
proposal. Unavailable historical selections remain inert without suppressing
real storage/configuration failures or preventing usable unrelated work.
Only successfully validated requests provide restored queue associations.
Restart changes now publish matching bounded resource/revision invalidations
atomically, with unchanged-resource, rollback and multi-page cases tested.

The private declared-configuration/descriptor binding permits fresh revision
tokens only after exact current validation. FIFO and original receipts remain,
and no worker, dispatch or previous approval authority is reconstructed. Store
N1, corrected native N1 and then N8 passed on their recorded current owners.
The AdmissionCheck-only fixture repair did not invalidate Store N1, so that
valid result was reused. The current captured interruption audit is
`audit-restore-interruption.v33gvina`. Original reports, failed logs and roots
remain separate from `correction-result.md` and `review-corrected.md`.

The reviewed patch equals the application delta byte-for-byte when Git uses
the same a/b path prefixes. Original-HOME i/w mnemonic prefixes explain the
initial different diff-text hash, not a source change. Parent applied no stale
PLAN or handoff copy.

Both platforms passed documentation `check-haskell` and Profiles once, then
stopped at the original normal Store N1 reopen assertion. The fixture contains
an owned run, so required reconciliation adds matching run/control invalidations
after the original four-event prefix. The corrected test checks the transition
and exact retained history rather than treating that reopen as a no-op.

A subsequent fresh normal N1 exposed a legacy migration expectation of `held`
where startup requires `quarantined`. The authorized same-file correction checks
the exact held claim before migration, retained reservation/request/resource and
metadata facts afterward, NULL input/enqueue authority, zero invalidations and
a no-op reopen. Existing rollback and occupancy assertions remain.

The affected Werror rebuild passed at 12:09:42–12:09:54Z on 2026-09-20. Fresh
normal N1 passed at 12:10:26–12:10:38Z, followed by N8 at 12:10:59–12:11:10Z.
Evidence is `/Users/johnw/Products/w20m.Pt9TPL` and the unit's
`migration-correction-result.md`. Tracker comment 267 records the correction.
Original failed logs and roots remain, including the diagnostic query's
stripped-label failure, and none is relabeled passing.

The user resumed broader delivery after these scoped checks. Both revised
platform Store gates passed restart, normal, admission-data and terminal-admission
N1/N8, followed by restore-interruption and store-cancel-gap N1/N8. They then
failed before building the next mutant because its unused-import removal
assumed `catch` ended the import list. Store now also imports `fromException`.
The correction targets the comma-delimited `onException` token and preserves
the existing exact-one-occurrence guard, mutation bodies and negative assertions.

The initial anchor failure remains in `validation-revised/{mac,linux}` and
tracker comment 268. Both subsequent tails passed `store-cancel-mutant` N1/N8,
then stopped before expiry-mutant build because its generic expiry-loop anchor
matched both shutdown and Store probes. The correction scopes the transformation
to `storeCancellationChecks`, leaving the shutdown probe and mask order unchanged.
Its intended first failure is the `(masked,expiry)` case `(False,True)`.

Tail evidence and the original failure remain in `validation-tail/{mac,linux}`
and tracker comment 269. Both subsequent completion lanes passed expiry-mutant
N1/N8 with the exact `(False,True)` pair, completing composed Store coverage.
Their Commands gates then found a production opacity regression: the WM-020
`Generic AcceptedEnqueue` instance exposed an intentionally opaque representation.

The correction removes that instance while retaining full `NFData` evaluation
through the complete four-field tuple and the existing private association
instance. The opacity tests and constructor boundary are unchanged. The full
macOS Commands gate passed at 18:55:27–18:57:50Z, including actual N1/N8 receipt
behavior and all source compiler opacity checks. Haskell documentation passed
at 18:58:40–19:02:40Z. Current evidence and the exact source patch are in
`/Users/johnw/Products/o20.eDcoMR` and `opacity-correction-result.md`, with
tracker comment 270. Original failed Commands results remain untouched.

Current Commands and Drafts subsequently passed on both platforms. Admission
then stopped at an older fixture that rejected every durable queue after reopen,
including the now-supported fully validated case. The test-only correction
retains an unbound historical queue as the negative control and requires an
actual fresh native review for valid bound intent. Both cases preserve the
original receipt and queue clock, create no start intent, and never fabricate
a missing binding.

The complete macOS Admission gate passed at 19:21:12–19:25:24Z, including
restart, shutdown and normal N1/N8, source opacity, package boundary and real
interruption checks. Evidence is `o20.eDcoMR/admission-reopen.*`, with fresh
`manager-admission.MXiUi5`, `audit-package-boundary.g85pifwo` and
`audit-interruption.y9_eueli`. The unit's `reopen-correction-result.md` and
tracker comment 271 retain the exact scope and all original failures.

Current Linux Admission passed at 19:32:23–19:37:22Z. Final macOS Approval
passed at 19:32:43–20:08:04Z and Linux Approval at 19:37:44–20:07:43Z. Final
reports are `validation-approval/{mac,linux}/result.md`, with the Linux source
and original fixtures retained in `/home/johnw/Products/w20a.lZsGk3`.

Independent review accepts the complete owning coverage at its actual source
bindings, including the explicitly composed Store constituents. Original
failed wrapper, compiler, fixture and orchestration outcomes remain unchanged.
The initial review launcher failed before any child ran, and the corrected
workflow completed the same retained reviewer without changing validation.

Seeded crash prefixes, native preparation and captured interruption retain
their distinct evidence limits. Acceptance does not claim a complete physical
crash matrix, approved-running recovery, hardware durability, unsupported
backup-only recovery or later HTTP/client behavior. Collection, transport,
cursor/client reconciliation and deployment integration remain with their
later named owners. G1 remains open.

## WM-019 acceptance

Issue `acat-wm-019-9eye` is closed. Continued independent milestone reviewer
`1815eb21-b06d-49fe-b1ba-04f249e66216` found no issues and explicitly cleared
WM-019 under the user's scope correction. Tracker comment 262 records parent
acceptance. The implementation is `489a1a4`, and subsequent changes through
`1ef2ec88` affect only five documentation/tracking files.

The unit provides explicit drain deadlines and cancellation through existing
Admission, Store and Worker owners. New admissions and approvals are fenced
while healthy original live-run interaction may finish. Emergency notification
precedes ordinary operation/SQL joins. Original registration batches, immutable
outcomes and scoped construction fences preserve cleanup uncertainty, permanent
quarantine and healthy Store reuse without granting authority to old metadata.

Healthy drain retains committed start delivery, genuine person answers and owned
History. Committed start publication retires the preparation timer. Shutdown
callers only publish mode and await their retained result, while broadcasts
remain within the retained supervisor/watchdog lifetime. A delayed caller cannot
affect a later Store scope.

Existing poison and exact writable SQLite FULL/I/O failures notify original
safety cells without blocking callbacks or SQL/cleanup joins. Confirmed rollback
and writable unavailability remain distinct from poison. Read-only I/O with
confirmed rollback, ordinary Busy and opaque failure do not become global
poison. No public consent, receipt or Runtime cancellation is manufactured.

Both owning gates passed once per platform with actual N1/N8 native execution.
On macOS, Admission ran 2026-09-19 21:43:36–21:49:20Z and Approval ran
21:49:38–22:26:29Z. On Linux, Admission ran 2026-09-20 07:49:40–07:54:58Z
and Approval ran 07:54:58–08:24:44Z. All four exits were zero. The scripts owned
shutdown modes, acceptance/lifetime races and existing integrated checks/audits,
without duplicated local gates or separate constituent launches.

Source, successive reviews and original failures remain under
`implementation.9tGzKH/shutdown.327OnbQj`. The final disposition is
`review-closure-scope.md`, and `acceptance-note.md` binds both reports under
`validation/`. Linux used fresh `/home/johnw/Products/w19.iH0jwt` with current
archived source. Decisive integrated race audits are local
`audit-shutdown-races.1ci5q6ur` and Linux `audit-shutdown-races.s6dmzagw`.

Pager-quota FULL is not host-disk exhaustion, and injected I/O is not a physical
device/VFS failure. Broader A19 scenarios remain with their assigned future
quota, HTTP/event, retention and capacity owners. Logical pre-COMMIT fencing is
not atomic STM/SQLite COMMIT. Nonfatal Linux C diagnostics and earlier failures
retain their meaning. No warning-free or historical-cleanup claim follows.
OS containment is excluded, not a remaining milestone or permission request.

## WM-018 acceptance

Issue `acat-wm-018-9huh` is closed. Final continued milestone reviewer
`cf967881-af85-4a1f-8ca9-4a631988b15f` found no issues and explicitly approved
frozen WM-018 closure and adoption of the reconciled selected client test
snapshot. Tracker comment 255 records the combined disposition. Source, reviews,
raw evidence and first failures remain under
`implementation.9tGzKH/history.t5kx5b6A`. The accepted implementation is
`4ad20a43`, with no later application changes during validation.

The unit supplies bounded complete history, opaque handles, read-only legacy
roots with explicit local profile bindings and lineage through existing
Commands, Drafts, Admission, Approval, Worker and Runtime owners. Unknown
manager-root children refuse whole materialization, without a fallback profile.
Historical workflow identity reuses Profile, while current trusted configuration
alone supplies execution selection. Schema nine retains immutable observation
and lineage facts without rebuilding accepted tables.

Coherent review resolved seven findings at those owners: parent binding,
original ownership observation, resource revisions, response-entry root
authorization, original query-child cleanup, result failure reasons and
descriptor-independent invocation comparison. Final review confirms that the
complete implementation and combined execution satisfy WM-018 at the recorded
scope, without closing later packages.

Actual native correction tests passed at N1/N8 through approval, start and
ingestion, including legacy/v2/v3 frontend formats, nonempty inputs, typed
false/null/structured/drop edits, direct semantic comparison, genuine owned
versus foreign workers and parent-substitution refusals. The final result
comparison requires populated nested code/value and typed answer records.
Earlier native6 comparison evidence was withdrawn, not relabeled passing.

An additional pinned routing-v2 comparison exposed native prefixed digests
being copied into frozen bare-hex public fields. The shared policy projector
now converts only strictly valid digest spellings, preserving native/private
values and strict public validation. Final policy-native5 passes eight actual
managed/direct parent and lineage runs per capability with non-null policy and
execution fingerprints. Scripted native7 supplies the separate four-fact
typed/drop dimension. All earlier framing, rate-limit and projection failures
remain recorded, with no unchanged retry or historical recovery.

The existing no-wire parent checks detect persistent substitution at assembly,
preparation, review, approval and native start boundaries. They do not attest
exact bytes consumed by another process under adversarial substitution and
restoration. The reviewer accepted that explicit existing-protocol ceiling
without adding a stronger claim or changing frozen wire formats.

All eight integrated owning gates passed once: actual engine/runtime Werror
suites, Haskell documentation, full TUI and full policies on macOS arm64 and
Linux aarch64. Policies include all new history modes at N1/N8 and their
existing manager/native prerequisites through both final run-fact refusals.
Mac policies passed 15:57:01–17:41:25Z and Linux 15:48:27–17:26:28Z. Evidence
is under `history.t5kx5b6A/validation/{mac,linux}`.

Parent adopts the exact client snapshot in `validation/clients/result-fixed.md`,
including the reviewed isolated `wf-smoke.el` test correction. Fixture mocks
are installed before the unchanged process guards surround real setup. Fresh
Emacs31 compilation/checkdoc, 38 ERT tests and 32 smoke facts pass. Actual
production-client v3 invocation omission receives the native refusal without
approval/start, with unchanged parent and catalogue. Local PTY/TRAMP, Pi
typecheck, 189 tests, 21 integration tests plus remote contract, and complete
actual Pi UI pass with normal exit and terminal restoration.

Original owner checkouts and client production files remain untouched. Earlier
failed Emacs fixture, premature driver assertion and omitted Pi fixture runs
remain failures. The private-HOME cleanliness assertion also remains failed,
with read-only evidence of different Git ignore classification and no tracked
or staged changes. No unexpected path was removed or adopted.

The accepted ceiling remains the existing parent-read attestation limit,
current-journal frontend formats, one local pinned provider and selected local
or loopback clients. Active revocation, atomic HTTP pages, service-mode clients,
later recovery/conformance/deployment and G1 remain separate. No further helper
or rerun programme is required for this WM-018 disposition.

## WM-017 acceptance

Issue `acat-wm-017-1hda` is closed. Continued milestone review
`a5d1a0cc-fd1e-4b0d-9948-e75f6279f935` found no issues and explicitly approved
closure under frozen WM-017, I02/I09, its A11/A12/A21 portions and section 9.3.
The reviewed source, final review, initial failures and raw platform evidence
remain under `implementation.9tGzKH/artifacts.Rdk65Wyh`. Tracker comment 251
records the combined disposition. Parent verified unchanged clean source and
frozen records after execution, without importing stale tracking.

The implementation reuses State references, Commands acceptance/dispatch, Store
file/transaction ownership and shared Runtime verification/publication. Captured
native source envelopes and export documents retain distinct bytes and handles.
Schema eight defers only the export-command FK until commit. Lost completion
can reconcile a durably witnessed publication after current verification, but
matching bytes without witness do not authorize adoption or republication.

Initial review found revision ABA and incomplete durable acceptance binding.
Both are corrected with fresh transition revisions, idempotent completed
observation and private exact request/name provenance. Review
`f4175cee-bc67-49bc-9505-c5b7eedc9651` found no issues and cleared owning gates.
Focused real filesystem/SQLite checks pass 147 assertions at each N1/N8, plus
frozen representation validation, source boundaries, docs and checker builds.
These are not native workflow-process or complete platform/client results.

Both complete owning matrices passed on the accepted implementation. Each
platform executed the actual Runtime/engine Werror suites, Haskell documentation
checks and full direct policies exactly once, sequentially. Policies included
the manager and artifact gates, audits, native frontend IO/session/export/codecs
and both final run-fact refusals. No prefix or suffix was skipped or duplicated.

| Platform | Full policies UTC on 2026-09-19 | Exit | Evidence |
| --- | --- | --- | --- |
| macOS arm64 | 09:59:00–11:33:01 | 0 | `artifacts.Rdk65Wyh/validation/mac` |
| Linux aarch64 | 09:58:13–11:28:51 | 0 | `artifacts.Rdk65Wyh/validation/linux` |

All six top-level exits are zero. Exact canonical direnv entry preceded private
overrides, with clean inherited controls and unchanged offline Cabal settings.
Original foreground owners and gate budgets remained intact, without replay,
manual process intervention, paid execution, deployment or a new Lean build.
Nonfatal Linux C unused-result diagnostics remain recorded, without a
warning-free C-build claim. Native process probes and deterministic artifact
primitives provide distinct evidence, not an end-to-end manager lifecycle claim.

The file loan bounds raw captures/reads through callback return, not total heap.
Callback consumers may not retain bytes afterward. Atomic output-page/revision
snapshots belong to WM025, and active callback credential revocation to WM023/A16.
Full-size stress is unrun. Structured public-shape validation is not complete
semantic-schema validation, as recorded in `acat-4978`.

## Accepted WM-016 baseline

Final milestone review `8bb51054-e179-4ade-8c3e-28e80b6eae48` found no issues
and explicitly approved closure under frozen WM-016 and sections 9.1–9.3.
The full direct Linux policies gate passed from 05:40:38Z to 07:10:58Z with
exit zero, including all controls/audits, preparation and mutant N1/N8, and
the entire policy/schema/lineage/person/frontend tail through both run-fact
refusals. Those negative commands retain exit one, not success.

Combine that result with the scoped macOS core matrix, actual Linux suites/TUI,
independent Linux examples/routing/ACP/deck, existing conformance/prebuilt oracle
and documentation gates, and the adopted Pi/Emacs acceptance baseline. Client
source is the reconciled snapshot recorded by `6022ee4`, including canonical
loader prerequisite `22678d1b` and the reviewed three-test-file correction.
Untouched owner checkouts are not labeled passing. Actual client UI/restoration
outcomes and all source/runner qualifications remain in the records below.

The final review is `controls.qzldrova/wm016-milestone-review.zs1HY3rS/result.md`.
Final Linux output is under
`controls.qzldrova/wm016-compatibility.BECaF4KE/linux/final-preparation-logs`.
Issue `acat-wm-016-bsw2` is closed with the combined acceptance record. Parent
verified unchanged canonical execution bytes and all three frozen documents.

Linux and selected Pi/Emacs compatibility execution was explicitly authorized.
Paid providers, deployment, dependency changes, historical recovery and new
Lean/oracle builds remain excluded absent their own authorization. Earlier
failures, unknown holders and failed UI cleanup/restoration qualifications remain
unresolved historical evidence rather than new closure prerequisites.

The latest clock-backed refocus for this checkpoint is
`2026-09-23T19:47:05Z`, with the next active-work deadline at `20:47:05Z`.
The authorized dependency update and public-client observation now have local
evidence. The TUI journey, full workflow retest and remaining certificate-validation
work remain unfinished. WM-022/G1 stay accepted, RabbitMQ remains deferred, and
validation remains local-only. No historical closure or verification-machinery
detour is required.

## Historical WM-016 closure record

The following chronological notes retain the scope and outcomes recorded at
each stage. Earlier open-status and next-action statements do not supersede the
accepted status above, and later passes do not rewrite earlier failures.

**Application integration milestone:** the WM-016 application changes composed
with the later canonical repairs, including the Cabal test-component boundary.
The policies merge required its existing inert refusal fixture to provide a
Bash wrapper, and the storage documentation named schema seven. The bounded
Store admission policy and all runtime budgets remained unchanged.

The whole-workspace warning-fatal build passed. Its first invocation wrongly
specified `jobs: 1` in private configuration. That setting was removed, and the
same build command passed without a job override. The existing refusal regression
and documentation gate passed on the corrected integration.

Fresh `controls-saturation` and `ingestion-concurrent` execution passed at both
N1 and N8. The latter covers success and caller interruption with original-worker
joins, preserved transport outcomes and release of both reservations only after
cleanup. Saturation retains the ordinary limit and cancellation-only extra slot.
These fresh results do not recover or explain historical `policies-gate-05`.

Application integration is committed on `tui` as `5b283978`. Source, build output
and ordinary native results are under `controls.qzldrova/wm016-delivery.LdWQA6B3`,
in `source`, `build.22UhyK` and `functional.toRJdNVE`. The earlier native decision
covered only its fresh local scenarios with offline adapters, original owners
and existing budgets.

Canonical execution now also passes the engine, runtime-contract and TUI-model
Cabal suites, examples, tier0, tier1, deterministic ACP/deck, routing configuration,
Haskell documentation and manager-contract gates. The runtime suite genuinely
executed capture and root-role bodies. The manager contract remains data-only,
not a service execution. Tier1 used the existing oracle with seed `91797864` and
500 inputs, including 412 checked P3 cases and 88 existing other-case skips.
No Lean or oracle build occurred.

Two concrete validation fixes preserve their original assertions. The private-root
refusal fixture now explicitly sets mode 0755 rather than depending on the umask.
The native capability-discovery expectation now includes session versions one
and two, while requests still default to version one. The original runtime and
capability failures remain recorded. The corrected runtime/TUI suites and targeted
discovery check passed, but the latter is not a complete frontend-session pass.

Results are in `canonical-suites.2wyjVH56`, `canonical-suites-fixed.qx9rq4WY`,
`canonical-gates.ZhA7cmOX`, `canonical-transport.OUxLX9W2`,
`session-capabilities-red.9YF2Pxoh` and `session-capabilities-green.L2GralIM`
under the same delivery directory. These earlier results retain their original
scope and qualifications. The final corrected-source matrix and review disposition
below govern current local completion. Authorized external compatibility remains
pending, so WM-016 is not accepted.

The consolidated correction from `controls.qzldrova/wm016-owner-closure.uw37fnwn`
fixes the selected Session/export/contract/lineage/TUI test owners. It removes
process-enumeration signalling, registers exporter children immediately, resumes
the original stopped publisher in finally, and joins before resource disposal.
The TUI spawn Driver retains the existing Runtime ProcessGroup and its existing
two-second grace. No production owner or budget changed.

The unchanged boundary guard first rejected StoreAdmissionCheck. Its move into
the existing `Agentic.Manager.Test` namespace changes only the module declaration,
import and Cabal registration, not the helper behavior or boundary policy.

Parent review refused an initial revision that still allowed teardown after a
failed join. The completed revision retains the same child through deferred-
interruption joining and preserves the expired deadline as a failure. Direct
temporary-directory allocation and explicit post-owner disposal leave resources
intact if an unexpected OS join error prevents proof. No such OS error occurred
in validation, and that branch was not artificially induced.

The initial full TUI stages passed through a sourced invocation with an ephemeral
Bash wrapper function, not a relabeled direct script invocation. Final-source
frontend/session/export/contract/person-lineage probes and affected native TUI
signal, spawn, helper and machine-group cases passed after the residual fix.
Timeout regressions inject deadline exceptions into observations of real original
children and finish with original communicate/wait calls. They do not establish
naturally elapsed ten/eight-second timeouts. The selected owners defer real
pending SIGINT through cleanup, without making a universal claim about every
other subprocess helper's interruption path.

The ordinary `logs` under the owner-closure directory retain the initial boundary
failure, successful native gates and final owner results. Canonical Cabal builds
of the Driver and Store checker passed with warnings fatal. The parent then ran
`bash tui/ci/tui.sh` directly. Its first run failed because another public-mode
fixture was actually 0700 under umask 077. Explicit chmod to 0755 preserves the
unchanged refusal and non-repair assertions. The retained failed directory
confirmed that diagnosis. A fresh full direct canonical gate then passed, with
output in `canonical-fixed.OKcf8hGw` and the failure in `canonical.doaAgBqX`.

The unchanged canonical `bash cli/ci/policies.sh` ran once from 00:42:13Z to
02:20:48Z on 2026-09-18, at `6fde4d395b48e52f9dd737fa67ab32426bd1ae49`, and
returned top-level exit zero. It completed native Manager, schema, lineage,
control, person and frontend checks through both final run-fact refusals.
Ordinary output and original times/status are under
`controls.qzldrova/wm016-canonical-policies.fLG7K1Ew`. No ownership/wait failure
was observed, and the parent removed only generated Python cache files afterward.

The worker's requested outer environment filtering failed because `compgen` was
unavailable inside a command substitution. The shell continued into the gate.
The empty names file is not isolation proof. Later names-only inspection found
`AGENT_CAT_RUNNER` and `AGENT_CAT_STATE_DIR`, but no `GHCRTS`. That is not a
gate-start snapshot. Source places the two observed names in unselected Pi/TUI
consumers, and every Manager owning gate and runtime capture clears `GHCRTS`
itself. This supports the functional result, not a blanket isolation claim.
The qualification remains for milestone review rather than an automatic rerun.

The milestone review `499b9e48-712a-43cc-ad50-71ef28155222` blocked closure on
one local P1: two control-race probes silently retried opaque
`StorageUnavailable`. The parent removed those branches and used the existing
diagnostic owner to return and report the first public refusal. Injected
first-failure/would-succeed-next regressions exercise both actual probe loops.
They passed at N1 without claiming naturally occurring native storage failures.
The review and ordinary product diff are under
`controls.qzldrova/wm016-milestone-review.zs1HY3rS`.

The affected controls gate failed in N1 `ingestion-concurrent` after the second
run answered while the first remained pending. It reported opaque
`StorageUnavailable` at cleanup. The preceding `StoreBusy` did not establish its
cause. Its original logs and failed fixture remain under
`controls.qzldrova/wm016-controls-no-replay.E0xzEq0N` and
`wm016-delivery.LdWQA6B3/build.22UhyK/dist/controls.4THI1R/N1-ingestion-concurrent/native-pair`.

Focused original-owner diagnosis is retained in
`controls.qzldrova/wm016-cleanup-diagnosis.yyYkyjPm`. Instrumented failures
captured native signal permission refusal with an unpublished original native
outcome, followed by `WorkerCleanupUnproven`. They do not prove a StoreBusy
cause, an ACP defect, kernel partial delivery or historical equivalence. A
standalone non-reproduction used a wrong Nix entry, and later batches used the
required canonical direnv. Initial diagnostic-build and test-barrier failures
are preserved, as are all failed roots. No historical recovery was attempted.

The coherent correction keeps existing ProcessGroup ownership and failure
precedence. TERM IO refusal no longer skips the same bounded grace observation.
After final signal refusal, only existing publication or positive protected
original-leader exit permits joining the original monitor. The refusal remains
failure, and live/unknown ownership is not granted an unbounded wait. Store
release requirements, C errno predicate, signal count and all budgets remain.

Existing owner regressions fail against the old sequencing and pass after the
correction. Final diagnostics-free builds and focused grace, interruption,
masking, final-refusal and published-Left checks passed. The normal N1 prefix
and twenty fresh concurrent samples also passed from 05:00:38Z to 05:02:49Z.
This is bounded current-byte evidence, not proof of historical causality or
zero races. No diagnostic-only patch enters production.

Continued milestone review cleared the coherent correction for integration.
The final canonical matrix then ran once on
`26e35af927ca96f0c0deb0f902d5c84ec49bb679` and passed all five commands:
engine, runtime-contract and TUI-model Cabal suites with warnings fatal, direct
complete native TUI, and direct complete policies. Policies included workers
and controls N1/N8, the new N2 refusal-publication regression and audit suffix.
It ran from 05:36:19Z to 07:25:37Z without a rerun.

Every gate has a successful prelaunch assertion that inherited `GHCRTS` and
`AGENT_CAT_*` variables are absent. Ordinary output and matrix exit zero are in
`controls.qzldrova/wm016-final-canonical.o6ITDVN2`. Parent verified unchanged
HEAD, clean status and empty tracked/staged diffs after execution. This fresh
compliant result does not relabel the earlier setup deviation or failed batches.

Final local disposition `455bb12a-8481-437e-ad59-ed261e5aa3e0` found no issues
and cleared local implementation and validation. No further local correction
or rerun was requested. The result remains in
`controls.qzldrova/wm016-milestone-review.zs1HY3rS/result.md`.

**Adopted client acceptance baseline:** parent explicitly designates
`controls.qzldrova/wm016-compatibility.BECaF4KE/clients` as the reconciled selected
baseline under frozen sections 9.2–9.3. The Pi host is `10998453`, selected Emacs
is `f37e007f` with preserved owner edits, and selected extension is `828e8cac`
with preserved owner edits. Extension production adds only the existing canonical
loader prerequisite `22678d1b`. Its reviewed `lifecycle-correction.patch` changes
`ext-pi/test/fixtures/runner.mjs`, `ext-pi/test/extension.test.ts` and
`ext-pi/test/pi-input-ui.py`, against retained `lifecycle-preimages`. Untouched
owner checkouts are not labeled passing, and no wholesale fork merge is implied.

This baseline passes Emacs native checks, local PTY UI and native batch plus
interactive TRAMP. Pi passes its selected offline host build, source/module
binding, typecheck, 189 tests, integration contract plus 21 tests, and complete
actual-host UI at all three supported sizes. The final UI ran from 21:58:19Z to
22:00:40Z with exit zero and terminal restoration. Current application binaries
come from the immutable `21da33c6` snapshot, whose application bytes are `26e35af9`,
plus selected sibling `wf`. Short real binary copies were compared with those
outputs. No dependency installation, lock change or paid provider was used.

Continued milestone review `29428902-3d74-465e-91fc-83221a39f30d` found no issues
and cleared this client patch/evidence with its explicit source qualifications.
`clients/result-products.md` links complete history, patch and ordinary logs.
The initial `/tmp` HOME deviation, SSH refusal, command-length refusal, obsolete
fixtures and failed UI cases remain distinct failures. Earlier failed UI roots
retain unproven normal shutdown/restoration/cleanup and are not recovered by the
fresh passing invocation.

**Linux receipt correction:** the first Nix sandbox passed compilation and three
actual suites, then lacked `/usr/bin/env` for direct TUI. A fresh ordinary-user
workspace with the same pinned dependencies passed full direct TUI. Policies
then failed from 21:16:08Z to 22:11:58Z in `N1-controls-live` on an opaque receipt
`StorageUnavailable`. Its failed root and original stdout/stderr remain preserved.

One fresh diagnostic case passed without reproducing. A fixed maximum twenty-case
batch stopped at case one with `configuredCatalogues StoreFailure=StoreBusy`
during `storeIdentity` admission, before receipt SQL. Cases two through twenty
were not invoked. This directly diagnoses that fresh failure, not the uncaptured
earlier one. Production fail-fast admission, health checks and error mapping are
correct and unchanged.

Continued milestone review identified a test-owner mismatch: public receipt reads
cannot be assumed to succeed while another operation owns admission. The coherent
correction changes only `cli/test/ManagerApprovalProbe.hs`. Active ingestion uses
existing typed Store observation for the exact command effect, requiring one row.
It retains acceptance identities, occurrences and expected effects, then performs
unchanged one-shot public receipt checks after terminal evidence, drain and
successful original cleanup. Assertions preserve and strengthen correlation,
acceptance, dispatch, refusal, effect and outcome checks without moving unrelated
intermediate timing requirements.

The existing controls owner includes a held-Store regression for opaque public
refusal once, typed busy before successful observation, missing-row integrity,
non-busy failures once, actual SQL failure once and no opaque replay. The first
new-regression build failed on `NFData SQL.SQLData`, and a type-only discard
inside the transaction corrected it. That failed build remains recorded. Corrected
Linux build, focused regression and controls-live N1/N8 passed once. Evidence and
exact proposal are under `linux/receipt-correction2-logs` and
`linux/receipt-correction.patch` in the compatibility root.

Review `18ba6f17-a204-4dc1-80f7-da40b35201ca` cleared receipt correction, integrated
as `a2c8b63`. Its regression passed in the next Linux policies invocation, which
then failed on the distinct unresolved-reservation assertion. The actual result
was not printed. A bounded diagnostic stopped at fresh case one, capturing
`Left StorageUnavailable` mapped from `Admission.operation StoreBusy`. Cases two
through twenty never ran. No accepted submission or reservation release was shown,
and the inner Store step/holder is unproved. This Busy is not automatically
pre-admission because preparation may refuse a changed projection after a read.

Review `71b586d3-152d-405b-8fa8-688e44a20471` identified the separate lifetime gap:
the seventh typed answer immediately finished the native fixture while its
intermediate unresolved/duplicate/acknowledgement assertions were still running.
Not consuming Manager evidence does not keep the original native process alive.

The two-test-file correction appends a real final person confirmation and leaves
it unanswered through all seven generations and their unchanged negative checks.
It additionally binds reservations to exact commands/generations and rejects extra
accepted commands. Only afterward does it observe the hold, verify native Runtime
and original Worker remain running, answer normally, drain and join cleanup, and
check all eight answer records and exact native acknowledgement IDs. No answer is
filtered away, and no Store policy, timeout, retry or production behavior changes.
The affected build and controls N1/N8 passed once on Linux. Other authored fixture
programs remain unchanged, though the rebuilt binary is not byte-identical.

Review `5a65e592-c774-4f40-8a53-a4c1b4950803` found the lifetime design sound but
caught a renamed assertion that would break the existing control-body mutant gate.
Parent restored exactly the original label, leaving the stronger count/equality
predicate unchanged. Static comparison and audit-marker match passed. Final patch
is `typed-lifetime/final.patch`, and the earlier proposal, pre-label source and
Linux focused results remain preserved. Integration follows the review's precise
label correction. The next full Linux invocation confirmed the intended
control-body-mutant failure marker in both N1 and N8.

Independent Linux examples, routing-config, deterministic ACP and deck passed on
`a2c8b63`, with ordinary evidence in `linux/independent-linux-logs`. Their results
and unchanged macOS/client workflows, Linux suites and Linux direct TUI remain
credited.

Full policies on `2debfe0` completed all ordinary controls N1/N8 and the first
seven control audits in both arms. It stopped at control-write after successful
unpaused maximum-frame delivery, when public receipt polling returned opaque
`StorageUnavailable`. Exact inner cause remains uncaptured. The first audit log
is retained as `linux/control-write-first-N1.log`, and prior failed roots remain
untouched.

Review `a236cb70-4881-42b3-9d0a-81ae1740e484` identified the same observation gap
in three related effect-only polls: write, interruption and reload. The single
test-file correction reuses typed Store progress observation, then checks one-shot
public receipts after existing successful original cleanup. Public checks retain
acceptance, dispatch, refusal, delivered acknowledgement and effect correlations.
The genuine maximum-frame/partial-write/deadline checks remain, and paused receipt
still requires Unresolved with no acknowledgement or effect. Interruption duplicate
refusal stays before cleanup, and reload authorization/digest phases are unchanged.
Other live-phase assertions and exact audit markers are not moved or weakened.

The first author segment failed on provider fetch before editing or execution.
The same owner resumed safely. Affected build, receipt regression, ordinary reload
N1/N8 and four owning audits passed once on Linux, including genuine partial-write
timeout and intended ticket-mutant failures. Exact patch and raw child logs are in
`linux/effect-observation.patch` and `linux/effect-observation-logs`. Review
`07894eab-f249-46fe-9363-897ec53a2111` found no issues and cleared integration.

Full policies on `fb6214eb` passed ordinary controls N1/N8 and eleven audits
through reload-race, then failed the preparation audit after independent progress.
One scoped private diagnostic captured original delivery returning opaque
`StorageUnavailable` after Admission caught `StoreBusy`. Original acceptance had
returned, and receipt polling was not reached. The exact inner Store check/holder
and ticket/write progress remain unproved, so no replay safety is inferred.

Review `0faa0592-703c-4b6a-be5b-e85275773d8d` identified a test-owner gap: cancelling
the queued caller stops its wait but leaves Admission's retained acceptance job
alive. After the original preparation releases, queued Store work may therefore
overlap original delivery. The small correction changes only the non-interrupt
branch: release preparation, await both original results, require original fresh
acceptance with its matching ticket and queued exactly `Left StaleRevision`, then
deliver. The interrupt branch, blocking/progress proof, engine barrier, original
handles, mapping, budgets, cleanup and exact mutant marker remain unchanged.

Both existing preparation audits passed once on Linux, with Werror builds and
N1/N8 arms. Real checks preserve exception identity, physical joins, evidence drains,
reservation release and backend cleanup. Mutants fail the exact intended marker,
and audit metadata records all six children joined without deadline/signal/wait
failure or join interruption. Evidence and exact patch are
`linux/preparation-owner-logs` and `linux/preparation-owner.patch`. Review
`1ca8c7bb-e935-4a95-a760-9ccb8bc02366` found no issues and cleared integration.

The final full direct Linux policies gate completed on `430b411a`, including
preparation audits and the entire final policy/schema/lineage/person/frontend
tail. Review `8bb51054-e179-4ade-8c3e-28e80b6eae48` approved WM-016 closure.
Temporary diagnostics and historical resources remain separate and unrecovered.
The current accepted baseline is WM-001–WM-016 and G0.

The authority-only tracker issues `acat-lijk`, `acat-3ajx`, `acat-3sq1` and
`acat-jg00` are outside this worktree projection. Export encountered duplicate
serialized copies of the latter two records. Only those byte-identical duplicate
copies were removed from the shared projection, leaving their original issue
records and database fields unchanged. Normal export then succeeded.

The following verification history retains its original scope. The paused L08
review and earlier next-helper instructions do not govern current work.

Complete instrumented and uninstrumented
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
The isolated implementation compiles and has scoped source clearance. Production
Store cases and final-private startup, publication and cancellation cases passed
at N1/N8. The earlier private cancellation failure remains preserved and does not
establish its hidden cause. Independent review cleared the focused results, and
a fresh default-target build/package passed. A reviewed wrapper-probe portability
fix is packaged and data-checked without changing source/raw modes. The complete
source Store gate passed with parent verification and independent scoped
clearance. The complete source Commands gate also passed parent verification
and independent scoped review. The complete source Admission gate now also
passes scoped review using a separately authorized faithful new capture.
Its first preservation copied two link modes incorrectly, and that old snapshot
and failed disposition remain unchanged. The complete current source ingestion
gate also passed parent verification and independent scoped review. Controls
now has scoped clearance after its original successful run, explicit
acknowledgement, faithful capture, review and full parent verification. All five
current source owning gates pass. Exact raw Store now has scoped clearance
after its successful original invocation, explicit acknowledgement, faithful
capture, review and full parent verification. Exact raw Commands also has
scoped clearance after its original run and full verification. Exact raw
Admission also has scoped clearance, including faithful first capture of both
mode0700 package links. Exact raw ingestion also has scoped clearance after
its original run, explicit acknowledgement, capture and full verification.
Exact raw Controls also has scoped clearance after its original run, explicit
acknowledgement, faithful capture, review and full parent verification. All ten
current macOS SOURCE/RAW owning lanes pass. Reconciliation identified remaining
changed-layer compatibility and integration evidence. The complete policies
preparation remains blocked. The isolated Worker child-output retention remedy
has independent scoped clearance and full parent verification. A separate
test-helper-only canonical integration passed a warning-fatal build and compiled
data-only N1/N8 checks, followed by a clear committed fess audit. The L21
merged refusal-byte remedy also has independent source/data clearance and
parent verification. Its separate canonical test-producer integration passed
syntax and the default inert regression entrypoint, followed by a clear
committed fess audit. The L01 schema-vector lifetime remedy now has independent
source/data clearance and full parent verification. Its exact canonical
test-producer integration passed syntax and the default inert entrypoint.
Committed L01 fess is clear. L02 outer capture-build retention has independent
source/data clearance and parent verification. Its exact canonical producer
integration passed syntax and the default inert entrypoint. Committed L02
fess is clear. L03 outer CaptureTests bucket hygiene has independent
source/data clearance and full parent verification. Exact canonical integration
passed warning-fatal compilation and filesystem-only N1/N8. Its committed
fess is clear. L04 outer root-role bucket hygiene has independent source/data
clearance and parent verification. Exact canonical reuse passed both
warning-fatal data-main builds and all four filesystem N1/N8 runs. Committed
L04 fess is clear. L05's direct-GHC data/link results remain valid in their
scope, but committed fess found a P1 hidden-module import regression in the
Cabal test component. Parent adopted that narrowing without a component build.
The earlier recommendation/clearance is superseded, not rewritten. The neutral
test-module repair has independent isolated support and full parent integrity,
with actual Cabal red/green and a fresh canonical build-only pass. Its committed
P1 fess is now clear. Native fixtures and preimages remain unverified.
No native fixture, full gate, WM-016 application integration, platform/client
work, old-resource recovery or WM-016 acceptance is authorized.

At the earlier recovery checkpoint, accepted implementation ended at
`7b88f17263b32eb2e222d952ebac88fb972c4f04`: WM-001–WM-015 and G0, or 15 of
44 packages and one of six gates. WM-016 was then unaccepted, and its work was
committed as a portable recovery checkpoint rather than accepted functionality.
This historical boundary is superseded by the current acceptance above.

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
hidden failure or exact timeout stage. Correction
`386a6b68-efb0-4571-a177-89f9268351f9` completed in
`terminal-holder-fix.i_kyd3cy/corrected-source-v3`. It observes original holder
completion alongside its milestone, makes barrier releases idempotent, and uses
one budgeted private loan with distinct timeout stages. Its Werror build and 31
no-Store assertions per N1/N8 passed, including the existing real 21-second tests.
The first type-related build failure and superseded v2 release source finding
remain retained. Parent verified 4,117 identities and the exact two-path delta.
Review `1533b5a4-e11f-47ca-a49e-eff7e0d8ad59` found no issues at preparation scope.

Separate fresh v3 cancellation cases passed at N1 and N8 after 38.451752 and
51.208204 seconds. Each completed all 21 assertions, including original exit130
and positive release/association-generation checks. Final-private startup and
publication cases also passed at both capabilities on this same private version.
All original checker/launcher handles joined without outer failure/interruption.
Raw preservation and identity checks preceded interpretation without database API
access or controls receivers. Prior failures and superseded successes remain
distinct records.

`resume-parent.zTEX65dI/terminal-focused-final-results.json` binds eight focused
cases with 96 assertion outcomes and 8,645 parent identity comparisons. Two are
production Store cases and six use the final explicit private overlay. This is
not a full uninstrumented owning-gate result or an exhaustive fence matrix.
All native permissions are consumed, and old-resource recovery is unauthorized.

Read-only result review `988942c4-d63f-4d10-b5e1-59c2399f8b70` cleared the eight
focused cases at their stated scopes. Build/package run
`5de42cb2-13ab-4250-a458-ce38d317fd42` completed under
`terminal-owning-build.j93qps0a`. Its 26 default-enabled components and 22 binaries
built with tests enabled and warnings fatal in 314.268021 seconds. The existing
manual flag `tui-tests=False` was retained by explicit parent decision. Optional
TUI-driver verification remains outstanding. The source package has 594 regular
files and 664 entries, with 12 unnormalized mode differences and 427 source-only
files. Parent verified 2,673 identities. No raw build or owning gate ran.

The raw Cabal environment probe attempted to execute a mode0644 wrapper and failed
before reaching its assertions. Parent reproduced that failure in fresh data
copies, then changed only two invocation prefixes to use Bash. The wrapper bytes,
source/raw modes and all assertions remain unchanged. Corrected source/raw and
canonical fake-Cabal tests passed. Review
`4efd216d-0068-419c-ab77-f62c655d5654` found no issues. The two-line probe fix is
integrated canonically, without activating the WM-016 application candidate.

Committed fess `43efed89-0285-48ed-8841-f255b318274d` cleared the exact wrapper
probe commit `6392fcb` with stated limits. Repackaging
`3dc43cde-2094-4d58-8647-6b6e627f8c20` completed under
`terminal-owning-ready.j5g2ki94`, whose 1,021-file source differs only in that probe
from the successful build. Haskell, C and Cabal inputs remain unchanged. The new
archive contains 594 files and 664 entries, with 12 unchanged mode differences.
Parent verified 2,682 identities, including source/raw fake-Cabal results and the
compiled-input reference. Archive SHA256 is
`45de8b3a53ed96e931bab49f51acf9fb6065b56922fe35672fd66440caf34209`.

Preparation run `8754b14a-85b1-4b5e-b516-b2fbd92345dc` completed in
`terminal-source-store.OxhV3gKM`. Parent verified 1,335 identities and the 14
inert preservation checks, with 52 prior resource footprints excluded. Review
`b77aa38a-2514-4e88-8a05-266e0e9dbefa` found no issues at preparation scope.

After refreshed zero-native preflight, the parent authorized one complete source
Store gate at `2026-09-16T22:08:57.207271+00:00`. Execution run
`8e67da30-7ff8-4ba1-b324-98a05ad6d11b` returned exit zero after 686.929832 seconds.
Original gate/launcher handles joined without outer failure or interruption.
The immediate exit notice preceded raw preservation. All six top-level and six
helper cases passed their exact predicates, including four intended negative
exits. Three Werror helper builds passed with unchanged 120/1200-second budgets.
The disposable lease-death fixture was narrowly acknowledged through its newly
created original ProcessHandle and join, not as generic PID/kill authority.

Parent verified 6,772 identities over 2,348 preserved entries, 1,958 regular files,
28 databases and seven actual gate-built executable copies. Six compiler paths
remain explicitly retained in place. Helper source captures and sequential
mutation hashes match their final 595-file variants. The initial parent verifier
used the wrong mode for a newly created audit file. Source requires mode0600
under umask077, and correcting that expectation preserved the failure record
without normalizing artifacts. The 1,156 PASS lines are repeated observations,
not unique obligations. Independent result review
`bb363bad-7853-4955-aac7-7b1ac77bcba6` found no issues for complete SOURCE Store.

Commands preparation `721b4881-666f-4f5e-8e6f-6cff5401a5c1` completed under
`terminal-source-commands.utkqghes`. Parent verified 1,388 identities and 13 inert
preservation checks, with 53 prior footprints excluded. Review
`51c05afc-23a9-43eb-8752-834acfe71334` found no issues. Scope preserves both N1/N8
checkers, seven receipts per capability, both frozen contract validations and
all 36 opacity consumers, with 12 positive and 24 diagnostic-specific refusals.

The parent authorized one complete source Commands gate at
`2026-09-16T23:19:47.503182+00:00`. Run
`71099adf-c99f-47b2-8afc-93fd73a2c352` returned exit zero after 277.387010 seconds.
Original gate/launcher handles joined without outer failure or interruption.
The immediate exit notice preceded raw preservation. Both 196-PASS checker logs,
all 14 frozen receipt validations and all 36 opacity consumers are retained,
with 12 positive controls and 24 exact diagnostic refusals. Compiler-only limits
remain 120 seconds. Numeric invocation exits not separately persisted are
labelled as checked-flow conclusions, not direct records.

Parent verified 1,457 identities over 274 entries, 198 regular files, 30 databases
and the actual gate-built checker, with three compiler paths retained in place.
Consumer bodies and ordered predicate labels match source. No compiler, validator
or database API was rerun post-return. Review
`bc2c3b2b-67ec-4d8f-a4f6-83920982fe41` found no issues for complete SOURCE Commands.
The 442 PASS lines are observations, not unique obligations. Authority is consumed.

Admission preparation `1479eb5f-e0d1-4d20-909e-084e3af6b39f` completed in
`terminal-source-admission.KiEgo5Jc`. Parent verified 1,530 identities and 16 inert
preservation checks, with 54 prior footprints excluded. Review
`ec4e9c41-4b14-4fc1-a8f9-231696d12958` found no issues. Scope retains all 19
default families per N1/N8, 36 opacity consumers, the distinct package-boundary
branch and compiled interruption audit.

At `2026-09-17T00:09:39.321793+00:00`, the parent separately authorized one complete
source Admission gate. Run `3cf17b57-5ffb-40e7-ae2d-a0010150ba4c` returned zero
after 351.602617 seconds, with original gate/launcher joins and no outer failure
or interruption. Immediate notice preceded raw preservation. The completion-report
fault scope used its original fresh Runtime group, with real signalling before
one synthetic EIO report. It grants no kernel-error or historical recovery claim.

Read-only validation supports available default, opacity, package-boundary and
interruption predicates. However, two package-boundary links were recorded and
remain mode0700 while their copied links are mode0755. Target text and recorded
original mtimes agree. The preserver checks targets but omits link-mode fidelity,
so its exit zero does not establish complete preservation. No pre-copy link
inode record exists, and historical inode continuity is not claimed.

Parent verified 5,761 identities over available evidence and both mismatches.
The snapshot has 2,525 entries, including 2,048 regular files, 475 directories
and two symlinks. Forty databases and four quarantine WAL/SHM files remain raw,
without post-return database access. Originals, old snapshot, discrepancy report
and partial disposition remain untouched. Complete preservation, accepted gate
success and permission to advance remain false.

Review `845e9b53-10f9-4c53-ac65-def4687b4fe1` confirmed this copy defect. A new
separately authorized capture can close it only if retained originals match the
available earlier fields, with no-follow destination metadata and before/after
checks. This does not justify a native rerun or an atomic snapshot claim.
Preparation run `d87bb2c8-8a18-4066-83fa-a08d4e16a9c5` completed the corrected
no-follow copier and 32 inert checks under `terminal-admission-capture-fix.l8ioyj5u`.
Review `44d902a4-b2f5-4870-9979-acee676cbb15` cleared this preparation. Parent
verified 3,309 identities and repeated agreement checks on 2,525 original
artifacts and 1,021 source files before authorizing one exclusive capture at
`2026-09-17T01:10:36.019015+00:00`. This permission excluded native rerun, retry,
original or old-copy changes and gate acceptance.

The capture returned zero and recorded fidelity at the new capture time,
`2026-09-17T01:10:44.114714+00:00`. Both new links preserve mode0700, type, target
and mtime. Old mode0755 copies and failed-preservation flags remain unchanged.
The new capture is at `terminal-admission-capture-fix.l8ioyj5u/capture`.
Its `completeGateClaim` remains false, and capture authority is consumed.

Parent result verification passed 9,268 checks across originals, new and old
copies, source, archive and actual executable identities. It also checked
19 default families per capability, 93 PASS lines and 2,000 QuickCheck cases
each, nine completion-child PASS lines each, 36 exact opacity consumers and
the package/interruption predicates. The four quarantine sidecars remain raw.
No database API or native/compiler/helper rerun occurred.

Independent disposition `b257493b-115c-484d-8096-932e33ad4575` found no issues and
cleared the complete source Admission gate for the same bound candidate and
original invocation. Parent accepted that scoped result at
`2026-09-17T01:33:07.817091+00:00`. The faithful new capture closes the concrete
copying gap without native repetition or old snapshot repair. No historical
pre-first-copy inode continuity, atomic database state, resource recovery or
WM-016 acceptance is claimed.

Preparation run `5722a5d1-ffa3-423c-a9ce-09699997628f` completed under
`terminal-source-ingestion.e8c2q8d7`. It binds fourteen N1/N8 outcomes, the top
build and six helper builds, four positive cases and ten specifically diagnosed
negatives. Parent verification passed 1,641 comparisons and the 22 inert checks
were retained. Review `13e86850-2fee-49c5-85ba-b63f51debb9c` cleared preparation.

Two parent verifier-schema assumptions were corrected without changing prepared
artifacts. A parent preflight caller then correctly failed for an omitted
private CABAL_BUILDDIR override. No authority or native invocation existed at
that failure. The corrected caller supplied the unchanged planned environment
and fresh preflight verified 1,021 source files, 594 package files, twelve mode
differences and 63 excluded footprints. The failed records remain visible.

At `2026-09-17T02:05:44.721648+00:00`, parent authorized one complete source
ingestion gate. Run `088525dc-be1e-4852-ab58-fd5c0a3ead69` returned zero after
1,280.779244 seconds with original gate and launcher joins. No primary, outer or
wait failure or interruption was recorded. Selected fresh original-owned faults
and retries remained within that authorization, which is consumed.

Raw preservation and separate validation returned zero. Parent verification
passed 17,046 comparisons over 5,008 entries, 28 databases with no sidecars,
fourteen actual executable paths, nine retained compiler directories and exact
source/archive/raw bindings. All fourteen outcomes have four positives and ten
diagnostic-specific negatives. Top numeric statuses remain checked-flow
inferences, while the eighteen helper build/case records directly retain exits
and original joins. Each top capability has 511 ordered PASS lines, including
385 corpus lines. These are output counts, not unique obligations.

The reviewer identified a parent timestamp-label error. The standalone notice
used `receivedAt` for its later persistence time rather than runtime receipt.
That record remains unchanged. A bounded exact parent-runtime delivery event
records receipt at 02:29:33.161 UTC, which precedes preservation start by
20.443313 seconds. The event and timestamp clarification resolve the ordering
question without treating a child queued acknowledgement as receipt evidence.

The first read-only result review timed out while reading a large manifest and
produced no verdict. It resumed with bounded derived views and the full parent
verification report, without changing original evidence. Review
`5e371486-b856-45c3-8da8-f622bc471776` cleared complete current source ingestion.
Parent accepted this scoped result at `2026-09-17T02:58:50.319331+00:00`.
An optional host-Python metadata-display failure remains recorded separately,
with no artifact change or native, preservation or validator rerun.

Preparation run `2098e18d-dae4-4c43-99cc-20c4122f4f09` completed under
`terminal-source-controls.kjrqc6s8`, binding 38 checker outcomes, six contracts
and 40 resources. It retained 21 preservation and 43 analyzer inert checks.
No native, compiler, contract-validator or database invocation occurred.

Review `c1dd4f81-6d06-44a8-afe8-0cc129a7274b` blocked preparation on one P1.
The analyzer never reads original launcher completion, so its existing synthetic
positive reports complete success with no launcher record. The real launcher
can retain an outer interruption after child exit zero, which must not become
complete accepted evidence. Parent confirmed this false positive read-only.
Earlier preparation and false-positive evidence remain unchanged.

Correction run `865be8e7-672f-411e-8a19-4d7ecc3a7c85` completed under
`terminal-controls-owner-fix.qqacwmy6`. The existing analyzer now requires
present successful original gate and launcher records, with joined handles and
no failure or interruption. Its 67 checks retain the original 43 and add
23 independent ownership refusals plus restored completeness. The 21
preservation checks remain passing. Old K and its false-positive evidence are
unchanged and blocked.

Review `43f7fc19-b01f-456c-a3da-ddcf3a848bea` closed the P1 for preparation.
Parent verification passed 20,728 comparisons, including all 18,856 old K
entries and unchanged source, matrix, producers and preservation logic. A
parent verifier summary-field assumption failed once, then the corrected
verifier counted actual expected resources. No prepared artifact changed.

At `2026-09-17T03:56:14.247476+00:00`, fresh private-environment preflight passed
and parent authorized one complete current source Controls gate. Run
`fc010197-817d-4444-a3b8-010f64567763` returned zero after 1,927.334266 seconds,
with both original owners joined and no errors or interruptions. The worker
sent the original facts through `need_decision` and waited. Parent checked
those records and the absent snapshot, then issued explicit one-copy
permission. The ACK was persisted at 04:31:53.502119 UTC, and preservation
began at 04:32:34.424495. Neither permission remains reusable.

Preservation and both validators returned zero. Parent verification passed
53,594 comparisons over 11,320 entries, 58 databases with no sidecars, 28 actual
executable paths and sixteen retained compiler directories. All 38 checker
outcomes, six contracts and forty resources are supported. The sixteen negative
cases retain their exact diagnostics, with original helper joins and budgets.
Top numeric outcomes remain checked-flow inferences.

Three `control observation: StoreBusy` notes remain in stderr. The unchanged
observer retries only StoreBusy under a fifteen-second await, without resending
controls. The notes cannot be assigned to individual cases. Native cancellation
130 remains non-success, and terminal events alone are not cleanup proof.

Review `a1f3487b-9c51-4019-848d-a6be804f877d` found no issues, conditional on full
parent verification. Parent subsequently completed the 53,594 checks and
accepted scoped source Controls at `2026-09-17T04:51:47.736831+00:00`. The
reviewer did not rehash or inspect that subsequently completed report. Old
evidence remains unchanged, and no native, preservation or validator rerun
occurred.

Raw Store preparation under `terminal-raw-store.3o4iwgga` passed review
`2c1f5a78-c5c0-47b2-a2a0-b87134c70652` and 2,066 parent comparisons. It targets
the exact 594-file raw package, preserving all twelve source/raw mode
differences and excluding 427 source-only files. The 54 analyzer and nineteen
preservation inert checks remain separate from native evidence.

At `2026-09-17T05:25:12.130996+00:00`, fresh private preflight passed and parent
authorized one complete raw Store gate. Run
`7ceef218-cddf-4cd4-9cb5-dd36eb7fa1a0` returned zero after 601.702225 seconds,
with both original owners joined and no errors or interruptions. The worker
reported through `need_decision` and waited. Parent checked the records and
absent capture, then issued copy-only permission at 05:37:57.813672 UTC.
Preservation began at 05:38:43.689400 after the blocking reply.

Preservation and both validators returned zero. Parent verification passed
7,385 comparisons over 2,348 entries, 28 databases without sidecars, seven
own-built binary paths and six retained compiler directories. Exact raw modes,
archive bindings and all twelve source/raw differences remain unchanged. All
twelve outcomes have eight positives and four exact pair-specific negatives.
No source result or earlier binary was substituted, and admission-data has no
fabricated Store fixture.

The new lease-death permission remained limited to the selected fresh original
handles. Both default logs contain the lease-release assertion. This does not
grant historical signalling or general containment proof. Top status classes
remain checked-flow inferences, while nine helper records directly retain
their outcomes, budgets and original joins.

Review `9c530f20-90df-4b89-a090-9786692fca65` found no issues, conditional on full
parent verification. Parent subsequently completed the 7,385 checks and accepted
the exact raw Store scope at `2026-09-17T05:55:11.650028+00:00`. The reviewer
did not inspect that subsequently completed report. No rerun, repair or
normalization occurred, and the gate and copy permissions are consumed.

Raw Commands preparation under `terminal-raw-commands.jrxqxna6` passed review
`9359f468-c497-4f66-bf72-4e7adf36ba63` and 2,010 parent comparisons. Its two
checkers, two contracts, fourteen receipts and 36 exact opacity consumers remain
bound to raw source and modes. The 274 analyzer and 22 preservation inert checks
do not substitute for those future gate outcomes.

At `2026-09-17T06:26:10.853887+00:00`, fresh private preflight passed and parent
authorized one complete raw Commands gate. Run
`7cc019d0-318d-4e36-9f29-b86ee175b4d4` returned zero after 142.169725 seconds,
with both original owners joined and no errors or interruptions. Parent
checked the original return records and absent capture, then issued copy-only
ACK at 06:31:29.434742 UTC. Preservation began at 06:32:17.566466 after the
blocking reply. Gate and copy permissions are consumed.

Capture and both validators returned zero. Parent verification passed 2,104
comparisons over 274 entries, thirty databases without sidecars, the actual
own-built checker and three retained compiler directories. Raw modes, archive
and source bindings remain unchanged. Both 196-PASS checkers cover sixteen
families, the exact receipt corpus, fourteen emitted receipts and all 36
source-reconstructed opacity consumers. Individual status classes remain
checked-flow inferences.

Review `d4aaad06-81bc-475a-8680-13c00d607281` found no issues with full parent
verification as a condition. The completed 2,104-check report satisfies it,
and parent accepted scoped raw Commands at `2026-09-17T06:51:17.212223+00:00`.
The reviewer did not independently rerun hashes or tests. No backend launch,
rerun, repair, normalization or historical permission transfer occurred.

Raw Admission preparation under `terminal-raw-admission.6_9pd_li` passed review
`f98b5c6f-4fb9-4e54-9057-eed925afc45f` and 2,165 parent comparisons. It binds
nineteen default families per capability, completion children, 36 opacity
consumers and distinct package-boundary/interruption branches. The 155 analyzer
and 26 corrected preserver inert checks passed. The initial fixture omission
of source.log/source.list remains recorded, with requirements unchanged.

At `2026-09-17T07:30:51.266846+00:00`, fresh private preflight passed and parent
authorized one exact raw Admission gate. Run
`78c103d3-6fc4-470a-8ce2-ac7518468ebb` returned zero after 375.760611 seconds,
with both original owners joined and no errors or interruptions. The child
waited on need_decision, and parent checked return records and absent capture
before granting one copy. ACK persisted at 07:40:33.842239 UTC, followed by
preservation at 07:41:27.681915. The permissions are consumed.

Capture and both validators returned zero. Parent verification passed 7,608
comparisons over 2,525 entries, forty databases, four actual WAL/SHM sidecars,
four own-built executables and four retained compiler directories. Both real
package links preserve type, mode0700, target and mtime on the first capture.
Their current source identities and target bytes also agree. No repair or
recopy occurred, and old failed SOURCE copies remain separate evidence.

Default, completion-child, opacity, package-boundary and interruption outcomes
are complete. Cabal links the C fixture into the selected checker, with no
standalone library. Two actual C objects remain in their original build
directories. The pre-signal exit probe, real signal call and simulated EIO
report remain distinct from kernel error, release authority and historical
cleanup. Per-file fidelity is not an atomic database snapshot.

Review `27a3c24e-0b86-4842-8867-f652f4c7e967` found no issues, conditional on
full parent verification. The completed 7,608-check report satisfies it, and
parent accepted exact raw Admission at `2026-09-17T08:02:05.726338+00:00`.
The reviewer did not independently rerun hashes or tests.

Raw ingestion preparation under `terminal-raw-ingestion.midhqa44` passed review
`2a4385a2-d4ae-48b4-8044-1ce849db21ae` and 2,235 parent comparisons. The 91
analyzer and 22 preservation inert checks cover complete cases, source-derived
family/corpus output, owner failures and raw-mode boundaries. They remain
separate from native evidence, and the earlier 89-check version is retained.

At `2026-09-17T08:34:34.735400+00:00`, fresh private preflight verified 147
exclusions and parent authorized one exact raw ingestion gate. Run
`9c3e2b1a-f44f-4f8f-aee5-4aef22e1d96c` returned zero after 2,701.238048 seconds,
with both original owners joined and no errors or interruptions. Actual elapsed
time changed no budget. Parent checked both return records and absent capture,
then issued copy-only ACK at 09:23:17.632768 UTC. Preservation began at
09:24:01.294145 after the blocking reply.

Capture and both validators returned zero. Parent verification passed 13,478
comparisons over 5,010 entries, 28 databases without sidecars, fourteen actual
executable paths and nine retained compiler directories. All fourteen outcomes
have four positives and ten exact negatives. Both top capabilities retain all
source-derived family/corpus output, and helper records retain original joins,
errors, budgets and argv. Exact raw modes and source/archive bindings remain
unchanged.

The inherited preserver banner still says source ingestion. It was not repaired
after execution. Bound raw cwd, manifest, modes and original records establish
the lane independently of that cosmetic text. No rerun, retry, repair or
database API occurred.

Review `87ed6bec-11b3-49c6-8c84-9acbd29529c8` found no issues, conditional on
full parent verification. The completed 13,478-check report satisfies it, and
parent accepted exact raw ingestion at `2026-09-17T09:39:19.922743+00:00`.
The reviewer did not independently rerun hashes or tests. Permissions are
consumed, and historical limits remain unchanged.

Raw Controls preparation under `terminal-raw-controls.ybq6ts2k` passed review
`2be88c00-1034-42e2-9f63-fff444db9862` and 2,643 parent comparisons. The 141
analyzer and 21 preserver inert checks retain complete cases, ownership, raw
membership/modes and failure boundaries. No native result follows from them.

At `2026-09-17T10:13:17.547401+00:00`, renewed private preflight checked 165
exclusions and parent authorized one exact raw Controls gate. Run
`f6219f0d-179b-4d58-aa88-e84f08566487` returned zero after 2,331.468938 seconds,
with both original owners joined and no errors or interruptions. Parent checked
return records and absent capture, then issued copy-only ACK at 10:55:25.609190
UTC. Capture began at 10:56:12.625984 after the blocking reply.

Capture and both validators returned zero. Parent verification passed 27,803
comparisons over 11,320 entries, 58 databases without sidecars, 28 own-built
paths and sixteen retained compiler directories. All 38 outcomes and six
contracts remain complete, with exact raw membership/modes and original
helper joins, errors, budgets and argv. The two observed StoreBusy notes remain
unattributed and are not a prescribed note or retry count. Native130 remains
non-success.

Review `36d4c4e6-bd41-4c39-956e-7afb5948f82d` found no issues, conditional on
full parent verification. The completed 27,803-check report satisfies it.
Parent accepted exact raw Controls at `2026-09-17T11:13:02.677424+00:00`.
The reviewer did not independently rerun hashes or tests. Permissions are
consumed, and all ten current macOS source/raw owning lanes have scoped
clearance. That is not canonical integration, Linux/client evidence, historical
cleanup, G1 completion or WM-016 acceptance.

Parent read-only comparison found 975 of 1,021 candidate files identical to
canonical source, with 46 differences or additions. Two are stale PLAN/handoff
snapshots that must not be overlaid. The other 44 paths, including five new
files, form the candidate integration surface. Frozen document hashes match.
No source was integrated.

Reconciliation `8b238e8c-8702-45b2-9491-8ab5b13fa7b4` confirms core WM-016
behavior on the candidate but identifies a package-closure evidence gap.
The 44 implementation paths change shared Runtime, CLI, storage and protocol
behavior. Section9.2 therefore still requires broader compatibility checks,
including relevant Cabal suite execution, complete policies, retained CLI and
engine gates, workflow conformance, changed candidate documentation and affected
local-client/platform evidence. New service-client implementations and manager
refinement remain later packages, not work to invent inside WM-016.

Canonical integration requires fresh parent baseline checks, an exact reviewed
44-path delta excluding stale tracking, and aggregate compatibility review of
negotiation, legacy defaults, migration and cancellation-only capacity. The
approved waiting policy is settled. No candidate pass may be relabeled as
canonical execution, installation or deployment.

At `2026-09-17T11:28:40.361345+00:00`, parent authorized data-only preparation
under `terminal-source-policies.fddhjig5`. Worker
`e6c09e88-7490-4905-92a1-0f1e09504265` finished a blocked source/data inventory
covering 29 logical stages, 34 helper selections, 78 definition files, 24
artifact-lifetime rows and fifteen authority rows. Parent verification passed
1,806 comparisons and the 46 inert boundary checks remain explicitly non-native.
No complete policies preserver/analyzer or execution authorization exists.

Preparation is blocked on source-defined artifact retention. Policies deletes
answer-schema vectors through an EXIT trap, and runtime capture deletes its
whole temporary root, including three built executables and compiler outputs,
before returning. Parent confirmed the blocker without executing anything.
The source inventory also reports memory-only child output, more temporary-root
deletion, unbounded reads before bounded waits, export handles outside shared
cleanup and person-control/lineage failure paths without guaranteed joins.
Selected crash and export-race signals need exact original-owner analysis,
rather than blanket kill permission. These remain prospective source findings,
not a diagnosis of historical policies05.

Review `c0b35d7c-afed-43d4-b0cb-9a620f1db61f` confirms the blockers and selects
one minimal remedy. It corrects A15: Python KeyboardInterrupt paths can leave
the original child without an observed completed join, unlike a returned normal
timeout wait. The pinned source was checked without modification or experiment.
It also narrows B05: observed RUNNER/STATE_DIR names have unselected consumers,
while actual machine/query environment handling requires separate review.
No values were exposed and no environment was rewritten.

The failed worker -j1 assertion remains retained after clarification that Cabal
invocations are serialized, not forced to one compile job. A parent verifier
regular-file assumption also failed on an immutable Nix source symlink, then
was corrected to bind its resolved bytes without changing capture rules.
Neither correction changed candidate source.

The first remedy, L19 at `manager/test/WorkerCheck.hs`, is implemented and
independently cleared as a source/data unit. The isolated overlay under
`terminal-worker-child-evidence.jmsmsy30` retains exact bounded child output
before the existing predicate. Empty stderr produces an empty file, and
non-text bytes and trailing newlines remain unchanged. Child refusal stays
primary if writing also fails, successful children cannot pass failed evidence
writes, and incomplete observation emits no invented output.

Review `d8380fee-f89e-4367-995a-07966c5d06be` found no issues, conditional on
parent integrity verification. That verification passed 2,712 identity
comparisons, including the unchanged original wait, read bounds/order, bracket,
termination grace and pipe cleanup. Compiled inert N1/N8 checks each exercise
12 scenarios with 32 PASS observations. Source-exact old producers pass the
old predicate, then fail the required retention assertion. All seven original
isolated command handles joined. These are data tests, not native cleanup proof.

At `2026-09-17T13:28:39.317993+00:00`, parent separately authorized integration
of this one test-helper file into canonical source, preserving reviewed SHA256
`a015e6d076d0bf36cbcdca964c2804da6f253515e5032c2f0de2e06919c09bd0`.
Fresh canonical-Nix private offline compilation of `manager-worker-check` with
`-Werror` passed in 114.206744209 seconds. Explicit compiled data-only N1/N8
checks also passed, with three original handles joined, null failures and zero
interruptions. All 1,016 bound canonical inputs remained unchanged during these
checks, and 14 retained data files per capability match the isolated bytes.
The evidence root is `terminal-worker-evidence-canonical.5zutr_9v`.

The first parent verifier failed because it compared a completion record with
an augmented summary. The corrected verifier binds both the original command
and completion records, and its first failed log remains retained. The
secondary stderr-reporting failure branch was inspected, not executed. Writes
are sequential and may leave partial failed evidence. No atomic publication,
durability or full-stream drainage claim follows.

No Worker, ProcessGroup, Store, Runtime/backend, signal or native cleanup fixture
ran. The canonical change is only the test producer, not the WM-016 application
candidate. Immutable Z/source and the raw archive retain the old WorkerCheck
bytes, so their earlier scoped gate results are not relabeled. Committed fess
review `4e4f8445-5be2-4259-9a31-26faf09dd46b` found no issues in commit
`6878f5e9ad94dcdbfdfe91f03a5751cac64278d1`, with the same source/data limits.

That reviewer cited `R/doc-check.log`, which predates L19 and cannot establish
this unit's documentation verification. Parent had run the current check before
commit in tool output, then separately persisted a fresh post-commit check under
`terminal-worker-evidence-canonical.5zutr_9v/doc-check.log`, with exit zero. The
older log and review remain unchanged, and a separate citation clarification
records the chronology. The L21 reviewer has now read the fresh post-commit
log and explicitly corrected the earlier citation, limited to that invocation.

L21 retains the original merged stream in the existing `refuses_fact` helper
rather than reconstructing its shell variable. The isolated
`terminal-refusal-evidence.gbvuv2fm` overlay changed only this helper and
adjacent focused-test invocation, added `test/policy_refusal_evidence.py`, and
added its one explicit package membership in `agentic.cabal`. Review
`04558e67-e21c-422e-b592-d28f666ffc22` found no issues, conditional on parent
integrity verification. That verification passed 1,812 comparisons, including
178 result identities, all 13 actual-path cases and 17 original Popen joins.
The exact old helper passes its original predicate, then fails the new raw
retention assertion. Surrounding policies/Cabal programs, existing modes and
the earlier Z/source/raw/archive inputs remain unchanged.

Each invocation creates a private case directory and retains the original
merged bytes, including invalid UTF-8 and trailing newlines. Command and writer
statuses remain separate, failed retention cannot pass, and primary command
or wording refusal survives secondary evidence failure. Separate predicate
input remains available when the raw destination fails. The emitted status
file is diagnostic output, not a reconstructed status channel.

At `2026-09-17T14:36:43.517400+00:00`, parent separately authorized and applied
only these three reviewed test-producer paths to canonical source. Bash syntax
and the default no-argument inert regression entrypoint passed, with 13 cases
and 15 original Popen joins, null recorded failures and zero interruptions.
Raw case bytes and exits match the isolated run. Evidence is retained under
`terminal-refusal-canonical.zm2vaben`. The real Cabal/compiler/runner, native
fixtures, package construction and full policies were not invoked.

The preliminary canonical identity manifest bound its still-open verification
log before the final PASS line. All other entries matched, and the prefix was
verified against the completed log. The original manifest remains unchanged,
with a separate post-return manifest binding 162 completed files and a
chronology clarification. This correction did not repeat or replace any test.
Writes remain sequential, without atomicity or fsync durability claims.
Directory obstructions do not prove disk-exhaustion or arbitrary partial-write
behavior, and the existing command-substitution semantics remain unchanged.
Committed fess review `1a52be53-1cf5-47cf-a4e7-ddd88c4bbea3` found no issues
in `59c5aa15507dc2f0967afe212da399c9e61bd067`, limited to the test-producer
remedy. It confirms the default inert entrypoint and disclosed identity
correction, not native or full-policies completion.

L01 removes the schema-vector EXIT hygiene trap, retaining the original JSON
that the validator consumes. The isolated `terminal-schema-evidence.rpn23nrr`
overlay changes only that deletion and adjacent focused-test invocation, adds
`test/answer_schema_evidence.py`, and adds its single package membership.
Allocation, generator argv/redirection, validator invocation and surrounding
program remain unchanged. The actual validator and existing Popen test helper
are reused without modification.

Review `00b5cb46-b107-4c34-afa4-5b0c1b905d40` found no issues, conditional on
parent integrity verification. That verification passed 1,771 comparisons,
including 120 completed-file identities, seven cases and eleven original
Popen joins. Five original files remain, including partial generation bytes
and rejected JSON. Seven sandbox validator copies, including the old-red
fixture, match the unchanged real probe. The source-exact old block validates
and exits zero before its real EXIT trap removes the original file. The
separate retention assertion then fails for that precise absence.

At `2026-09-17T15:22:07.509230+00:00`, parent separately authorized and applied
the exact three reviewed paths to canonical source. Syntax and the default
no-argument inert regression passed, with seven cases and nine original Popen
joins, null failures and zero interruptions. Supplied inputs, outcomes and
five retained original byte streams match the isolated run. Six canonical
sandbox validator copies match the unchanged source. The 93 completed-file
identities were collected after the verifier returned. Evidence is retained
under `terminal-schema-canonical.kwcme8vh`.

The tests execute an inert generator and the real JSON Schema validator.
Supplied acceptance flags and the validator's schema/decoder wording do not
prove Haskell decoder agreement. No compiled schema runner, real workflow
runner, native fixture, package construction or full policies gate ran. The
separate documentation check includes its standard static Haskell probe.
Retention is not atomic publication or fsync durability. Committed fess review
`7476813c-3718-488a-a8e3-6f127bf98afb` found no issues in
`e9dd5afd98b2b8c9915a05b7339e4495d5f3ef79`, limited to the test-producer remedy.

L02 removes only the outer capture-build EXIT hygiene trap in
`runtime/ci/capture.sh`. The isolated
`terminal-capture-build-evidence.6b34_ers` overlay adds adjacent regression
wiring, `test/capture_build_evidence.py`, and its one Cabal membership entry.
The existing Popen helper is reused unchanged. Review
`7da50c35-106c-4026-904b-18c65be5bfb5` found no issues, conditional on parent
integrity verification. That verification passed 1,776 comparisons, including
114 completed-file identities, five cases, nine original Popen joins and
21 retained synthetic artifacts. The actual old trap deletes the original
fresh tree after successful inert builds/checks, producing the meaningful
post-return retention red.

The owner retains allocation, mode0644, directories, TMPDIR/GHCRTS handling,
compiler/checker arguments, order, six capability invocations and its real
Python check/60-second-timeout runner. Python and Bash both assert inert GHC
selection. A public dummy GHCRTS tests the original unset operation only in
inert cases. Build failure remains seven, while checker failure nine becomes
the original Python CalledProcessError and outer exit one. Neither is replaced
by an arbitrary nonzero result or a native success claim.

At `2026-09-17T16:01:31.981584+00:00`, parent separately authorized exact
canonical integration of the three reviewed test-producer paths. The first
byte check detected six nested newline-escape transfer errors. Their diff was
retained, and reviewed hashes were restored before any syntax/data execution.
Canonical syntax and the default no-argument regression then passed five
cases with seven original Popen joins, null failures and zero interruptions.
All 21 synthetic artifact bytes/modes, normalized argv/order and fixture
identities match the isolated run. The 90 completed-file identities were
collected after the verifier returned. Evidence is retained under
`terminal-capture-build-canonical.7rn8j8cs`.

No real capture GHC/native checker, timeout/signal injection, inner Haskell
cleanup/assertion change, Python/A15 repair, package construction or full
policies gate ran. The separate documentation gate includes its standard
static Haskell probe. These are outer-lifetime data results, not native
capture, durability or complete preservation. Committed fess review
`3ddcda4a-73c6-4146-9537-cc9734adb32d` found no issues in
`62c73ead8798942fb007d130d347da57fd546d38`, limited to the test-producer remedy.

L03 outer bucket hygiene is implemented in `runtime/test/CaptureTests.hs`.
The actual allocation/action seam retains its fresh0700 bucket whether the
action succeeds or raises, and native captureTests and permanent filesystem
checks share that seam. The separately exported data entrypoint uses ordinary
files only. Indexed navigation was unavailable for this module, so direct
source references and comparison were used without claiming indexed absence.

The isolated `terminal-capture-bucket-evidence.18qe63n3` copy binds 1,017 files,
excluding mutable tracker/handoff documents. Only CaptureTests.hs differs.
Review `24057d14-8f1c-4bdd-8d41-7a94e6a3adf2` found no issues, conditional on
parent integrity verification. That verification passed 3,708 comparisons,
including native-body equivalence modulo scope indentation/grouping, unchanged
helpers/PrivateRoot implementation, exact compiler entrypoint provenance,
seven original Popen joins and six retained buckets. Both source-bound old
allocation/finalizer witnesses produce the expected retention red.

Native worker cleanup, closing-root bracket, replacement deletion/restoration,
owned-temporary assertion and five-second bounds remain unchanged. The body
exception test compares the supplied IOException display, not object identity.
Direct action invocation without catch or transformation separately supports
exception pass-through by construction. No descriptor-closure execution or
native capture proof follows from this comparison.

At `2026-09-17T16:50:25.740905+00:00`, parent separately authorized and applied
the exact reviewed one-file canonical change. A fresh complete-module build
with the existing three C sources passed warning-fatal in 56.429099875 seconds,
explicitly selecting `CaptureTests.captureBucketEvidenceData`. Filesystem-only
N1/N8 passed, with three original Popen joins, null failures and zero
interruptions. All 1,017 bound nontracking inputs remained unchanged during
verification, and six bucket trees match isolated bytes/modes. The 27 completed
non-build identities were collected after return. The own binary is separately
identified, and compiler intermediates remain retained in place. Evidence is
under `terminal-capture-bucket-canonical.53r754ng`.

No native captureTests, Runtime PrivateRoot/publication, Worker/Store/group/
backend/signal fixture, runtime-contract/full policies or package operation
ran. The separate documentation gate includes its static Haskell probe. Only
outer hygiene is remedied. L03 pre-mutation evidence, L04/L05 and all other
blockers remain unresolved. Committed fess review
`3b50d15d-0bef-46d8-8c95-26baff8b7d57` found no issues in
`ca86b29ceddac4548c4d5af28c858dbaf3a19963`, limited to outer hygiene. The 27
non-build identities do not imply exhaustive compiler-intermediate hashing.

L04 outer root-role bucket hygiene reuses the existing allocator and filesystem
assertions through explicit prefixes. The isolated
`terminal-role-bucket-evidence.b7796fr5` copy binds 1,017 files and changes only
CaptureTests.hs and RootRoleTests.hs. RootRoleTests imports the shared owner
and checks in one direction. Existing L03 payloads, entrypoint and summary are
preserved, with an added observed-prefix assertion. Both native actions, role
bindings, descriptor brackets, replacement deletion/restoration, marker/
absence/FIFO/symlink refusals and capture finalizers/bounds remain unchanged.

Review `c26db081-a7b3-4d2c-9f04-5e00a998703b` found no issues, conditional on
parent integrity verification. That verification passed 3,736 comparisons,
including 67 completed-file identities, all source bindings, shared assertion
reuse, three warning-fatal builds, four data outcomes, ten original Popen
joins, twelve retained buckets and two source-bound old root-role reds.
The exact old finalizer deletes the fresh inert tree, not a recreated output.

At `2026-09-17T17:36:46.288554+00:00`, parent separately authorized and applied
the exact two-file canonical change. Fresh complete-module/C data-main builds
passed in 29.934385459 seconds for capture and 28.932322333 seconds for role,
with empty stderr. All four filesystem N1/N8 runs passed in separate private
temporary roots, with six original Popen joins, null failures and zero
interruptions. All 1,017 bound nontracking inputs remained unchanged during
verification. Twelve canonical trees match isolated prefixes/bytes/modes, and
existing canonical L03 data remains unchanged. The 47 completed non-build
identities were collected after return. Own binaries are separately bound,
and compiler intermediates remain in place. Evidence is retained under
`terminal-role-bucket-canonical.pprwk3v3`.

No native capture/rootRoleTests, Runtime PrivateRoot/state-role/publication,
FIFO/symlink/Worker/Store/group/backend/signal fixture, descriptor-closure
execution, runtime-contract/full policies or package operation ran. Separate
documentation checking includes its standard static Haskell probe. Only outer
disposal is addressed. L03/L04 preimages, L05/A15 and all other blockers remain.
Committed fess review `4a0c3999-6d68-4255-af27-7c51f5b12b8f` found no issues
in `3e79af18b93d29d32751b4d981b72cc322970570`, limited to shared-owner outer
hygiene. Native fixtures, interrupted paths, durability and preimages remain
unverified, and non-build identities do not imply complete compiler hashing.

L05 outer fault-bucket hygiene reuses the existing owner and assertions in
CaptureFaultTests. CaptureTests changes only its import from the broad Runtime
facade to PrivateRoot. All other shared code and the native fault action and
helpers remain unchanged modulo necessary scope syntax, including release/
worker finalizers, behavioral removals, role fault checks, pipe closure and
five-second bounds. The isolated `terminal-fault-bucket-evidence.6za6qkjr`
copy binds 1,017 source files and changes only these two Haskell files.

Review `cf4da514-0e04-4afd-8de3-7d7507a3c940` found no issues, conditional on
parent integrity verification. That verification passed 3,780 comparisons,
including 87 completed-file identities, four own binaries, eight C objects,
four warning-fatal builds, six filesystem outcomes, thirteen original Popen
joins, eighteen retained trees and two source-bound old finalizer reds.
The actual fault link pair remains private_directory.c and capture_sync_fault.c.
The unchanged shim includes and renames the real synchronization implementation.
No separate normal-sync or process-group object exists in the fault output.

At `2026-09-17T18:17:48.357184+00:00`, parent separately authorized and applied
the exact two-file canonical change. Capture/role/fault complete-module
data-main builds passed warning-fatal in 5.440832084, 45.781017583 and
7.144227875 seconds respectively, with empty stderr. Six filesystem N1/N8 runs
passed with nine original Popen joins, null errors and zero interruptions.
All 1,017 nontracking inputs remained unchanged during verification. Eighteen
canonical trees match isolated prefixes/bytes/modes and previous canonical
capture/role data. Eight own C-object bindings match isolated provenance.
The 67 completed non-build identities were collected after return, with own
binaries/C objects separately bound and other intermediates retained in place.
Evidence is retained under `terminal-fault-bucket-canonical.p0ra7g8j`.

No fault configuration, publication, barriers, pauses, cancellation, native
Main/capture/rootRole fixture, runtime-contract/full policies or package
operation ran. Separate documentation checking includes its static Haskell
probe. Linking and object identity do not prove shim execution. Only outer
hygiene has scoped data evidence. The import narrowing is now blocked by the
following package-boundary finding, and L03/L04/L05 preimages, A15 and other
full-policies obligations remain unresolved.

Committed fess `1069c368-7ef7-489f-a1ae-0eb5b4ffd544` found P1: CaptureTests
imports Agentic.Runtime.PrivateRoot, but that module is hidden in the library.
The runtime-contract-test component has only runtime/test home sources and
depends on agentic. Its public facade import had respected the boundary.
Direct GHC builds with runtime/src on the search path made the hidden module
a home module and did not verify Cabal visibility. Parent checked the component
declarations and accepts responsibility for integrating the narrowing without
that build. The initial finding was source-based. The subsequently authorized
baseline build reproduced it. The reviewer corrects its earlier recommendation and
clearance. Earlier records remain intact and limited to their actual scope.

The isolated `terminal-bucket-package-repair.ubb62xm5` correction moves the
existing allocator and filesystem assertions verbatim into neutral test-only
BucketEvidence. CaptureTests restores its public Runtime import and reexports
the helpers. CaptureFaultTests imports them directly, and Cabal adds only the
test other-modules entry. PrivateRoot remains hidden, test home sources remain
runtime/test, and native bodies, assertions, C sources and gate recipes stay
unchanged. No dependency or source-directory bypass is introduced.

Independent fresh baseline and corrected Cabal build-only commands use the
same explicit test:runtime-contract-test target, enabled tests and warnings
fatal. Baseline exits one in 136.371888 seconds with CaptureTests.hs:7:1,
GHC-87110 and the hidden-PrivateRoot diagnostic. Corrected build exits zero in
128.621121 seconds and links its own test executable without running it.
Review `6e970035-8ecc-45f1-94d2-030d36716d4f` supports this P1 correction,
conditional on parent integrity. That verification passed 4,792 comparisons,
including all source bindings, exact moves/declarations, real package-boundary
red/green, standalone regressions and unchanged previous inputs.

Raw plans exceeded the review tool's single-line limit. Parent supplied
hash-bound pretty views retaining complete local library/test entries and
metadata without changing or rerunning the plans. The first parent verifier
also encountered a record-shape mismatch because summaries now include cwd.
The corrected verifier binds both the original command and completion fields,
and its initial failed log remains unchanged. No test predicate was weakened.

At `2026-09-17T19:19:05.705975+00:00`, parent separately authorized and applied
the exact four-path canonical repair. Fresh private offline/repository-free
Cabal build-only verification passed in 190.601771792 seconds. Its own plan and
63,112,232-byte native test executable are bound, with executable SHA256
`cfe37f332f7b7bd0476ab2478d927d3ea293ec418c2b7bec823e1d56bb50bda8`.
That binary was never executed. Three direct warning-fatal data-main builds
and all six filesystem N1/N8 runs also passed, with ten original Popen joins,
null errors and zero interruptions. All 1,018 bound nontracking inputs remained
unchanged. Eighteen trees match isolated and earlier canonical data, and eight
own C objects preserve the frozen fault pair. The 75 completed non-build
identities were collected after return, with binaries/objects/plans separately
bound and other compiler intermediates retained. Evidence is under
`terminal-bucket-package-canonical.uqx8wghe`.

The staged whitespace gate then rejected a trailing empty line in the new
BucketEvidence module. A shell sequence without fail-fast control nevertheless
created local commit `b9f48bea080ebe58438e6c905c95a8affe64ed8b`, and the gated
staged-byte snapshot did not run. Parent disclosed the mistake, removed only
that EOF empty line and preserved the final newline. A separate decision
authorized fresh verification and amendment of this own unpublished commit.
The final helper is 4,059 bytes, SHA256
`86d1a5035203101b2ffa1e72f57edae9b82a69747cd52b9994dfccc00392ba05`,
equal to the reviewed source apart from that trailing empty line.

Fresh final-byte Cabal build-only verification passed in 99.872889625 seconds.
Three fresh data-main builds and six filesystem runs passed, with ten original
joins, null errors and zero interruptions. All 1,018 current inputs remained
unchanged. Eighteen bucket trees preserve prior bytes/modes/prefixes, and the
native package executable remains unexecuted. Its own plan/build provenance
is retained rather than inferred from equal hashes. The 75 completed non-build
identities were collected after return under
`terminal-bucket-package-final.cozkowds`. Full staged-diff whitespace and
exact-byte checks are required under fail-fast shell control before finalizing
the amendment. Earlier evidence and the initial failure remain unchanged.

Committed P1 review `b1c1e0d5-0426-475e-a871-f19b120e241d` explicitly clears
`7763a87973c1e73cac30fff8d3a8b09e73764d9b` for the hidden-module correction.
The initial whitespace gate failure, missing staged-byte snapshot and mistaken
local commit are not retroactively passed. Fresh final-byte verification and
the recorded fail-fast full-commit gates support the amendment. This closes
only P1. Earlier mistaken clearance remains superseded, and native execution,
full policies, preimages/A15 and WM-016 acceptance remain open.

L07 changes only the existing TemporaryDirectory deletion policy and adds a
post-context assertion in test/cabal_env_probe.py. The body, generated inert
Cabal producer, real wrapper, argv/status/diagnostic predicates, Unicode/empty
arguments, Bash calls, summary and two ten-second budgets remain unchanged.
Pinned Python3.14.7 respects delete=False at both context exit and implicit
finalization. Explicit cleanup still deletes but is not called.

The isolated `terminal-cabal-temp-evidence.ts7m6u8p` unit has scoped clearance
from review `799c4bfb-4af4-47d2-9c77-94a2fb19e6df`, conditional on parent
integrity. That verification passed 1,680 comparisons, including 43 completed
identities and five original outer Popen joins. The complete old probe returns
normally through runpy and prints its original summary, then the driver fails
because the real owner deleted the directory. No separate old-probe process
exit zero is invented. Corrected and exception cases retain exact generated
fixtures after context and process return.

At `2026-09-17T20:37:23.789782+00:00`, parent separately authorized and applied
the exact canonical two-line change. Two direct canonical probe invocations
exited zero, preserving the summary and original fixtures after process exit.
A bound one-raise variant preserves and propagates its specific RuntimeError
at exit one without printing success. Three original outer joins have null
errors and zero interruptions. Three mode0700 roots retain exact 139-byte
mode0755 fake executables, with earlier bytes/inode/mode/times unchanged.
The 24 completed identities were collected after return under
`terminal-cabal-temp-canonical.ast0rhl4`. These invocations execute the inert
producer, not real Cabal commands or native builds.

Earlier L07 wording incorrectly grouped memory-only replies with L06. The
sealed inventory names L06-profile-root-probe, the directory disposal in
manager/test/RootProbe.hs. That disposal and memory-only replies are separate
open concerns, as the retained clarification records. L07 fixes neither.
Inner seven-call flow remains source-derived checks rather than new persisted
per-child joins/replies. A15, preimages and complete preservation remain open.
Separate documentation checking includes its static Haskell probe. Committed
fess `fb92dfd9-f5e6-43ca-9fa6-d026d3745ff2` found no issues in
`560a000890a840a32a5aae12daa20d121d4ed477`, limited to L07 disposal.

The next reviewed unit is L08 source-discovery directory hygiene. Parent
inspected the Python probe and actual GHC header-parser/Cabal-root checker.
At `2026-09-17T21:10:43.782653+00:00`, parent authorized only isolated
`terminal-source-roots-evidence.gxvf54vu`. Worker
`f111ed04-0d8e-4711-aeb8-f66ce2fe6779` may edit source_roots_probe.py to use the
existing owner's delete=False policy and a post-context survivor assertion.
The body, libdir query, checker argv, original positive and diagnostic-specific
negative predicates, summary, owners and 30-second budget remain unchanged.
Required source.unlink() stays, removing each deliberate Escape.hs violation
before the next case. Its deleted preimages are not silently counted retained.

Pinned GHC libdir discovery and the unchanged real runghc static checker are
explicitly permitted for this unit. Fixture modules are parsed, not executed.
Required evidence includes the full old-probe deletion red, post-process
surviving bytes/modes, distinct repeated roots and a specific exception only
after all original checks and unlinks. Checker and Popen-helper support copies
remain exact. No mocked checker, relaxed namespace rule, cleanup interception,
A15/reply/preimage repair, workflow/native/runtime fixture, real Cabal gate,
package/dependency/oracle action, canonical edit or further source change is
authorized. L06, A15, memory replies, preimages and full preservation remain
open, without full-policies or WM-016 acceptance.

Other deletion/retention, frontend ownership/read boundaries, ACP cleanup,
A15 interruption handling, environment and complete-capture gaps remain blocked.
Root deletion is not join proof. Producer-owned evidence emission is distinct
from external post-return capture after ACK, not a waiver. Historical limits
and all prior scoped lane results remain unchanged, with WM-016 open.
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

The focused persistent goal is `mu629ta5-11s8ax`, created from the user's
explicit 2026-09-17 refocus. Its five milestones cover the closure plan,
substantive WM-016 work, integration/validation, milestone acceptance and the
remaining frozen roadmap. The user's direction remains the authority.

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
