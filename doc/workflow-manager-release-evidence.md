# Workflow manager release evidence

This record maps each release requirement of the workflow manager to its
evidence. It covers the eleven obligations of section 12 of the
[implementation plan](research/workflow-manager-implementation-plan.md), the
packages WM-001 to WM-044, the gates G0 to G5 and the acceptance scenarios A01
to A24. It also gives the identities of the local release artifacts, the
accepted additive fields of the `/v1` contract, the tested platform and the
checks that did not run. Every check ran on one macOS host of the system
`aarch64-darwin`, with no binary cache, no package repository and no external
host.

The matrix was written on 2026-10-03 at commit
`5951ad37bde6c5a77fba1f1959788ab3abf6031a`. It uses only the facts that the
tracker, `doc/workflow-manager-handoff.md`, the commits and the private
evidence directories state. PH1 `e454fbd7`, PH2 `4d078647` and PH3 updated
the rows that the `ext-pi` lock file, the WM-041 runs of record and the
final functional result of G5 change. Accepted state in the tracker is WM-001 to WM-022
with G0 and G1, and the Integrator closed WM-023, WM-025, WM-026, WM-027 and
WM-029 after that. Every other package and gate is open in the tracker.

## Evidence conventions

Two private directories hold the evidence. They are never committed.

- `$R` is
  `/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/resume-20260923`.
  The evidence of subtask `X` of a phase is under `$R/<phase>/X/impl-r1`, for
  example `$R/PG/PG13/impl-r1`. Each check has a `<name>.log` and a
  `<name>.exit` file, and a failed first attempt is kept as
  `<name>-attempt<n>`.
- `$I` is `/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH`.
  It holds the units of the accepted packages WM-001 to WM-022, such as
  `$I/vertical.d42c7UhQ`.

A mode is a mode of `manager/test/service_http.py`. Unless the row states
otherwise, a mode ran once at `-N8` against a real manager over local TLS with
deterministic workers. The path after a check names its latest run.

The evidence ceiling follows invariant I16. Each row names the highest kind
of evidence that it has, and the kinds are not merged.

| Ceiling | Meaning |
|---|---|
| Theorem | A Lean proof with a pinned axiom footprint. |
| Pure model test | A test of pure code or shared vectors with no process, file or network effect. |
| Deterministic native fixture | Real manager, worker and Store processes on disposable local roots, driven by a harness. |
| Actual UI interaction | Keys sent to a real TUI, Emacs or Pi process in a pseudo-terminal, with assertions on the screen and on manager facts. |
| Package build | The flake package or the source distribution built and run. |
| Operator exercise | A person who did not write the procedures follows them. No row has this ceiling yet. |

The status of a row is one of these values:

- **Met.** The tracker records acceptance after an independent review.
- **Met for function.** The functional requirement has passing evidence, and
  the security items of the row wait for the security stage.
- **Partial.** Part of the functional requirement has no passing evidence.
  The row names that part.
- **Deferred to the security stage.** The operator direction of 2026-09-30
  defers the item.
- **Pending human operator exercise.** The function is met, and the exercise
  by another person has not run.
- **Not run.** The row states the reason.

No row claims a security-stage item, a cross-machine result or an exercise
by a human operator as done.

## Release requirement matrix

These rows are the obligations of section 12 of the implementation plan.

| Requirement | Implementation evidence | Executable evidence | Evidence ceiling | Status |
|---|---|---|---|---|
| Source-grounded reuse and correct boundaries (sections 2 and 3) | WM-001 to WM-008 accepted in the tracker. One `agentic` package with `manager/src`. `Agentic.Manager.Client` is the only manager module that the TUI imports (PC13 `50ec050b`). `ext-pi` names its host and selects service mode only by profile (PE10 `91e85a43`). | The compiler-parsed import gate of `bash tui/ci/tui.sh` (`$R/PF/PF24/impl-r1/tui-ci.log`). `manager/ci/contract.sh` through `make -C doc check` (`$R/PG/PG21/impl-r1/doc-check.log`). `manager-client-check vectors` (`$R/PE/PE28/impl-r1/05a-client-vectors.log`). Every `tui-journey` checks the run log and the manager log and the consent chain of each start with its `FLOW-ASSERT` lines (`$R/PF/PF21/impl-r1/journey-pair.log`). | Deterministic native fixture | Met for function |
| Mathematical meaning and unchanged workflow semantics (sections 3 and 10) | WM-004 model under `model/Agentic/Manager`. WM-040 library `bisim/manager/ManagerConformance`, `manager-oracle` and `manager-conformance-check` (PF9 to PF15, `7d57a9b0` to `5cda60da`). WM-022 `manager-vertical-check`. | `bisim/ci/manager.sh`: nine steps, 45 cases with no mismatch, and the controls `control-oracle`, `control-model` and `control-case` failed as required (`$R/PF/PF22/impl-r1`). The direct and managed comparison of answers, traces, bills, policies and lineage at WM-022 acceptance (`$I/vertical.d42c7UhQ`) and in the `vertical` step of PF22. | Theorem | Met for function. `bisim/ci/tier0.sh`, `tier1.sh` and the full default model build did not run (operator direction of 2026-09-29). The conformance of the authorization transitions is deferred to the security stage. |
| Selection, missing inputs, readiness, capture, admission and concurrent lifecycle (section 4) | WM-008 and WM-011 to WM-016 accepted. WM-027 routes (C12 to C17, `004eef20` to `890dec08`). | Rows A01 to A08. The journey pair at N1 and N8 (`$R/PF/PF21/impl-r1/journey-pair.log`). `tui-inputs` and `tui-controls` (`$R/PC/PC34/impl-r1`). `capacity-admission` (`$R/PG/PG1/impl-r1/capacity-admission.log`). | Actual UI interaction | Met for function |
| Exact preparation and approval and control ownership (sections 4 and 5) | WM-012, WM-014, WM-016, WM-019 and WM-020 accepted. The quarantine release of PC1 to PC3, PE2 to PE4 and PD4. | Rows A04 to A10 and A20. `manager-approval-check` (`$R/PF/PF21/impl-r1/approval-check-N8.log`). The controls `tui-consent-control` and `tui-flow-approve-fault` failed with their literal messages (`$R/PF/PF21/impl-r1`). `cross-client-lifecycle` shows that a client disconnect sends no control (`$R/PF/PF23/impl-r1/cross-client-lifecycle.log`). | Actual UI interaction | Partial. Containment of escaped descendants and Linux containment did not run (row A20). |
| Durability, uncertain effects, restart, retention and restore (section 5) | WM-007, WM-009, WM-010 and WM-019 to WM-021 accepted. Offline `backup` and `restore` (PG8 `a1c0ed86`, PG9 `9cf218f7`) and the completion of a fenced restoration (PG11 `5c8f38de`). | Rows A05, A12 to A17, A19, A20 and A24. `failures-backup` (`$R/PG/PG11/impl-r1/failures-backup.log`). `manager-admission-check restart-native` (`$R/PG/PG11/impl-r1/admission-restart-native-N8.log`). `faults-io` (`$R/PG/PG1/impl-r1/faults-io.log`). | Deterministic native fixture | Partial. The crash matrix of every durable boundary did not run: the `admission_audit.py` audits are removed by the operator direction of 2026-09-29, and the per-route crash boundaries were dropped in Phase B part 2. The A16 and A17 matrices are deferred to the security stage. |
| Complete REST resources, values, validation and errors (section 6) | WM-003 accepted. WM-023 to WM-028 in `Agentic.Manager.Application`, `Transport`, `Pages`, `Events`, `Routes` and the owners of each route. | `manager/ci/contract.sh` through `make -C doc check` (`$R/PG/PG21/impl-r1/doc-check.log`). The base mode with `CLIENT_CHECK` (`$R/PC/PC34/impl-r1/04c-service-base-client-N8.log`). The route modes of rows WM-025 to WM-027. The `/v1` diff is additive only (section [Accepted additive OpenAPI fields](#accepted-additive-openapi-fields)). | Deterministic native fixture | Met for function. WM-024 and WM-028 are open in the tracker. The hostile-input negatives are deferred to the security stage. |
| Replay, snapshot consistency, duplicates, backpressure and reconnect (section 7) | WM-015 and WM-021 accepted. WM-025, WM-026 and WM-029. PG3 `afd44d78` separates the authorization revision from the reader wakeup. | Rows A14 to A16 and A19. `events-lifecycle` and `capacity-streams` (`$R/PG/PG3/impl-r2`). `client_native.py` (`$R/PE/PE28/impl-r1/05b-client-native-N8.log`). | Deterministic native fixture | Met for function. The run of record of `capacity-streams` is in `$R/PH/PH2/impl-r1` (row WM-041). Revocation during a stream is deferred to the security stage. |
| Remote authentication, authorization, TLS, browser and model boundaries and redaction (section 8) | WM-008 accepted. `Agentic.Manager.Credentials` and `Authorization` (WM-023), the HTTPS boundary (WM-024), the exact model consent of `ext-pi` (PE21 `69a7e2de`, PE22 `c8dca6a2`). | `credential-lifecycle` (`$R/PG/PG3/impl-r2/credential-lifecycle-N8.log`). `boundary` (`$R/B/B19/impl-r1/11d-service-boundary-N8.log`). `pi-host-model` and its control `pi-host-model-decline` (`$R/PE/PE28/impl-r1`). | Actual UI interaction | Partial. Authentication, scopes, credential rotation and revocation and exact consent are met for function. The CORS, Host, Origin and proxy negatives, the secret-marker scans, the redaction projections and the hostile input are deferred to the security stage. |
| Verified outputs, history, lineage and exclusive export (sections 4 to 6 and 8) | WM-017 and WM-018 accepted. WM-025 and WM-027 routes for exports and lineage requests (C14 `768de34b`, C15 `a3a8720c`). | Rows A11 to A13. `mutations-exports` and `mutations-lineage` (`$R/PE/PE28/impl-r1`). `manager-artifact-check` and `manager-history-check` (`$R/PG/PG3/impl-r2/artifact-history-N8.log`, `$R/PG/PG4/impl-r1/history-check-N8.log`). `cross-client-lineage` (`$R/PF/PF23/impl-r1`). | Actual UI interaction | Met for function |
| Thin native clients, coexistence, compatibility and rollback (section 9) | WM-029 to WM-039 and WM-043. | The client rows WM-029 to WM-038. The three `cross-client` modes (`$R/PF/PF23/impl-r1`). `rollback` (`$R/PG/PG28/impl-r1/07-rollback.log`). | Actual UI interaction | Partial. Every client is met for function on one machine. Cross-machine TLS did not run, because the governing goal limits validation to local macOS. No check runs Emacs 29.1. |
| Operational evidence and supportable release (sections 10 and 11) | WM-039 to WM-044. `manager/OPERATIONS.md`, `manager/CAPACITY.md`, the flake package and this record. | `operations` with case 7 (`$R/PG/PG28/impl-r1/03-operations.log`). `package` (`$R/PG/PG28/impl-r1/06-package.log`). The capacity modes of row WM-041. `make -C doc check` (`$R/PG/PG21/impl-r1/doc-check.log`). | Package build | Partial. The gate of Phase G passed (`$R/PG/PG30/impl-r1/g5-summary.md`). The capacity runs of record are in `$R/PH/PH2/impl-r1`. The exercise by another person and the independent closure review are pending. Linux containment did not run. The security review is deferred to the security stage. |

## Package matrix

The accepted packages WM-001 to WM-022 keep the evidence of their acceptance.
The tracker item of each one records the close date, and its unit under `$I`
holds the review, the source and the first failures. Accepted packages were
revalidated only where their owners changed, as the governing goal directs.

| Requirement | Implementation evidence | Executable evidence | Evidence ceiling | Status |
|---|---|---|---|---|
| WM-001 Implementation baseline and verification environment | `flake.nix`, the direnv environment and the recorded baseline. `acat-wm-001-b3k7`. | The baseline gates of `$I/baseline.jyVC2U`. | Deterministic native fixture | Met (2026-09-10) |
| WM-002 Package boundaries and dependency feasibility | One `agentic` package with `manager/src`, `agentic.cabal`. `acat-wm-002-9xwf`. | `manager/ci/dependencies.sh` and the regressions under `$I/dependencies`. | Deterministic native fixture | Met (2026-09-10) |
| WM-003 Manager protocol and compatibility fixtures | `doc/api/openapi.yaml`, `test/fixtures/manager/`. `acat-wm-003-dji4`, unit `$I/protocol.vfAWuo`. | `manager/ci/contract.sh` through `make -C doc check` (`$R/PG/PG21/impl-r1/doc-check.log`). | Pure model test | Met (2026-09-11) |
| WM-004 Abstract coordination model and laws | `model/Agentic/Manager`, `model/test/ManagerChecks.lean`. `acat-wm-004-yo05`, unit `$I/model.JttDpW`. | The model build and `model/ci/check-manager.py` at acceptance. `bisim/ci/manager.sh` step `lean` (`$R/PF/PF22/impl-r1/lean.log`). | Theorem | Met (2026-09-11) |
| WM-005 Neutral frontend transport contract | `runtime/src/Agentic/Runtime/Frontend` through the Runtime facade. `acat-wm-005-g2i0`, unit `$I/frontend-contract.RMtvkb`. | `runtime-contract-test` (`$R/PE/PE28/impl-r1/04-runtime-contract-N8.log`). | Deterministic native fixture | Met (2026-09-11) |
| WM-006 Observation and restoration contract | `Agentic.Runtime.Snapshot`, `Frontend` and `Catalogue`. `acat-wm-006-bdxu`, unit `$I/restoration.NRqKwa`. | `runtime-contract-test` (`$R/PE/PE28/impl-r1/04-runtime-contract-N8.log`). | Deterministic native fixture | Met (2026-09-11) |
| WM-007 Durable private publication | `Agentic.Runtime.PrivateRoot`, `PrivateFile`. `acat-wm-007-lfcg`, unit `$I/durability.1upgl3zs`. | The publication regressions at acceptance. The SQLite directory-replacement experiment was withdrawn by the operator and is not verified. | Deterministic native fixture | Met (2026-09-12) |
| WM-008 Trusted profiles and composition-root configuration | `Agentic.Manager.Profile`, `Configuration`, `Root`. `acat-wm-008-rr0q`, unit `$I/profiles.EgYE9JIT`. | `manager/ci/profiles.sh` and `configuration.sh` at acceptance. Offline `reload-profiles` of the reference configuration (`$R/PG/PG20/impl-r1/reference-reload.log`). | Deterministic native fixture | Met (2026-09-12) |
| WM-009 Private coordination database and service lock | `Agentic.Manager.Store`, `Schema`, `Lease`. `acat-wm-009-kmzw`, unit `$I/state.0wnll6Qx`. | `manager-store-check` (`$R/PG/PG28/impl-r1/08-store-main.log`). | Deterministic native fixture | Met (2026-09-12) |
| WM-010 Command receipts, revisions and idempotency | `Agentic.Manager.Commands`. `acat-wm-010-hbip`, unit `$I/commands.i0YEDgvB`. | `manager-command-check` (`$R/PG/PG28/impl-r1/09-command-check.log`). | Deterministic native fixture | Met (2026-09-12) |
| WM-011 Drafts, immutable captures and readiness | `Agentic.Manager.Drafts`, accepted commit `7fed36ce`. `acat-wm-011-fqny`, unit `$I/drafts.Ex2O7B5k`. | `manager-draft-check` (`$R/PG/PG3/impl-r2/draft-check-N8.log`). | Deterministic native fixture | Met (2026-09-13) |
| WM-012 Manager-owned frontend worker adapter | `Agentic.Manager.Worker`, accepted commit `3a8340ee`. `acat-wm-012-ma5g`, unit `$I/workers.CM5pvfEh`. | `manager-worker-check` (`$R/PE/PE28/impl-r1/06g-worker-N8.log`). | Deterministic native fixture | Met (2026-09-13) |
| WM-013 Admission and resource reservations | `Agentic.Manager.Admission`. `acat-wm-013-8oah`, unit `$I/admission.Y7LCRq4c`. | `manager-admission-check` (`$R/PG/PG28/impl-r1/10-admission-main.log`). | Deterministic native fixture | Met (2026-09-13) |
| WM-014 Exact review, approval and start intent | `Agentic.Manager.Approval`. `acat-wm-014-5sv9`, unit `$I/approval.YHFzgIkt`. | `manager-approval-check` (`$R/PF/PF21/impl-r1/approval-check-N8.log`). | Deterministic native fixture | Met (2026-09-14) |
| WM-015 Validated runtime ingestion and durable projections | `Agentic.Manager.State`, `Observation`, accepted commit `546d61b`. `acat-wm-015-wzl9`, unit `$I/ingestion.zid51qsu`. PG3 continues a stored projection from its next sequence. | The ingestion check (`$R/B/B19/impl-r1/09a-ingestion-N8.log`). `capacity-streams` (`$R/PG/PG3/impl-r2/capacity-streams.log`). | Deterministic native fixture | Met (2026-09-15) |
| WM-016 Decisions and correlated runtime controls | The control owners that `manager/CONTROLS.md` names, accepted commit `430b411a`. `acat-wm-016-bsw2`, unit `$I/controls.qzldrova`. | `test/control_probe.py` and `controls` (`$R/PE/PE28/impl-r1/07-control-probe-N8.log`, `0807-controls-N8.log`). | Deterministic native fixture | Met (2026-09-19) |
| WM-017 Outputs, verified artifacts and exclusive export | `Agentic.Manager.Artifacts`, accepted commit `5ef7612e`. `acat-wm-017-1hda`, unit `$I/artifacts.Rdk65Wyh`. | `manager-artifact-check` (`$R/PG/PG3/impl-r2/artifact-history-N8.log`). | Deterministic native fixture | Met (2026-09-19) |
| WM-018 History, lineage requests and legacy observation | `Agentic.Manager.History`, `Lineage`, accepted commit `4ad20a43`. `acat-wm-018-9huh`, unit `$I/history.t5kx5b6A`. | `manager-history-check` (`$R/PG/PG4/impl-r1/history-check-N8.log`). | Deterministic native fixture | Met (2026-09-19) |
| WM-019 Shutdown, containment and storage-failure supervision | Admission, Store and Worker owners, accepted commit `489a1a4`. `acat-wm-019-9eye`, unit `$I/shutdown.327OnbQj`. | `failures-manager` (`$R/PG/PG7/impl-r1/failures-manager.log`). | Deterministic native fixture | Met (2026-09-20) under the operator exclusion of OS containment |
| WM-020 Restart reconciliation and fenced backup restoration | Store and Admission owners, accepted commit `626981a7`. `acat-wm-020-5x61`, unit `$I/restart.gQ3o7Iag`. | `manager-admission-check restart-native` (`$R/PG/PG11/impl-r1/admission-restart-native-N8.log`). | Deterministic native fixture | Met (2026-09-20) |
| WM-021 Quotas, retention and bounded collection | Store owners at schema 11, accepted commit `248e772e`. `acat-wm-021-ez37`, unit `$I/quotas.N3qrqDWt`. | The quota lane of `manager-store-check` (`$R/PG/PG3/impl-r2/quotas-after-N8.log`). | Deterministic native fixture | Met (2026-09-21) |
| WM-022 Complete non-network vertical slice | `manager-vertical-check` and `manager/ci/vertical.sh`, base `c6698af4`. `acat-wm-022-j655`, unit `$I/vertical.d42c7UhQ`. | The owning gate at N1 and N8 on 2026-09-21. The `vertical` step of `bisim/ci/manager.sh` (`$R/PF/PF22/impl-r1/vertical.log`). | Deterministic native fixture | Met (2026-09-22), local only |
| WM-023 Local credential administration and authorization | `Agentic.Manager.Credentials`, `Authorization`, `LocalAdmin`. B8 `776be8e7`. | `credential-lifecycle` (`$R/PG/PG28/impl-r1/04-credential-lifecycle.log`). `credential_cli.py` (`$R/PG/PG28/impl-r1/09-command-check.log`). | Deterministic native fixture | Met (tracker closed 2026-09-30). A scope change during a retained response is deferred to the security stage. |
| WM-024 Protected HTTP boundary | `Agentic.Manager.Transport`, `Application`. B9 `8c4140b7`. | `boundary` (`$R/B/B19/impl-r1/11d-service-boundary-N8.log`). | Deterministic native fixture | Met for function. The remaining negatives are deferred to the security stage. The tracker item is open. |
| WM-025 Catalogue, history, snapshot and artifact queries | `Agentic.Manager.Pages`, `History`, `Overview`. B11 to B13 (`bea2d57b`, `d652b37f`, `87b255b9`), C5 to C7, PC5, PC6, PG4 `76da0f5c`. | `pages` and `capacity-inputs` (`$R/PG/PG4/impl-r1/pages-N8.log`, `capacity-inputs-after.log`, 43 keys inside their ceilings). | Deterministic native fixture | Met for function (tracker closed 2026-10-01) |
| WM-026 SSE and bounded event polling | `Agentic.Manager.Events`, `Routes`. B14 `ddf3ed93`, C8 to C11 (`73a47ac6` to `e4b9e5c9`), PF19 `9e329971`, PG3 `afd44d78`. | `events-lifecycle`, `routes` and `capacity-streams` (`$R/PG/PG3/impl-r2`, 14 keys inside their ceilings). | Deterministic native fixture | Met for function (tracker closed 2026-10-01) |
| WM-027 Request, approval, control, export and lineage routes | C12 to C17 (`004eef20` to `890dec08`), C20 `e7810632`, C21 `04ef9db0`. | `mutations-captures`, `mutations-discard`, `mutations-exports`, `mutations-lineage`, `controls` and `controls-routing` (`$R/PE/PE28/impl-r1`). `live-redirect` and `person-answers` (`$R/PC/PC34/impl-r1`). | Deterministic native fixture | Met for function (tracker closed 2026-10-01) |
| WM-028 HTTP, security and failure-boundary gate | C23 to C25 (`76e65633`, `de22ba49`, `9f1ae979`), PE1 to PE4, PD4 `fe8053ff`, PF20 `537f1795`. | `failures-worker`, `failures-manager`, `failures-launched`, `storage` and `faults-io` (`$R/PG/PG1/impl-r1`). | Deterministic native fixture | Partial. The functional failure endings are met. A database-full case did not run, and a file-size limit stands for it. The hostile-input and transport gate and the authority fencing of an older backup as a security matrix are deferred to the security stage. |
| WM-029 Shared client contract and Haskell client facade | `Agentic.Manager.Client`, `Client/Events`. PC9 to PC12 (`19a4a001` to `e9ac2ac1`). | `manager-client-check vectors` with 271 cases and `client_native.py` (`$R/PE/PE28/impl-r1/05a-client-vectors.log`, `05b-client-native-N8.log`). | Pure model test | Met for function (tracker closed 2026-10-01) |
| WM-030 Emacs HTTP, credential and live-delivery support | `emacs/wf-manager.el` on `emacs-native`. PD8 to PD18 (`4ceff269` to `682439d1`, with `0b5c3e9` to `5de5f83`). | `ci/emacs.sh`, 97 of 97 (`$R/PF/PF23/impl-r1/emacs-gate.log`). `emacs-client` (`$R/PD/PD29/impl-r1/emacs-client.log`). | Deterministic native fixture | Met for function. No check runs the declared minimum Emacs 29.1. |
| WM-031 Emacs lifecycle presentation | `emacs/wf-service.el`. PD19 to PD24 (`db9b9c75` to `a6f54044`, with `70fecf9` to `59f27ed`). | `emacs-service` (`$R/PF/PF23/impl-r1/emacs-service.log`). | Actual UI interaction | Met for function |
| WM-032 Real Emacs service-mode acceptance | PD25 to PD27 (`75ce6752` to `832ea3d3`, with `2477a47` to `6745f4b`), PF1 `214f3ff0` with `f9be31a`, PF2 `2d02134f` with `281c5d6`. | `emacs-service-lifecycle`, `emacs-service-controls` and the control `emacs-service-broken-answer`, and the local cases of `ci/emacs-ui.py` at three sizes (`$R/PF/PF23/impl-r1`). | Actual UI interaction | Met for function |
| WM-033 TUI explicit manager transport backend | `Agentic.Tui.Service`, `ServiceLane`, `tui/AGENTS.md`. PC13 `50ec050b`, PC14 `b405854a`. | `tui-endpoints` (`$R/PE/PE28/impl-r1/1002-tui-endpoints-N8.log`). The import gate of `bash tui/ci/tui.sh` (`$R/PG/PG30/impl-r1/06-tui-sh.log`). | Actual UI interaction | Met for function |
| WM-034 TUI setup, run views and controls | `Tui.App`, `Tui.Service`, `Tui.Presentation`. PC15 to PC30 (`7d00c5eb` to `d3a2cc66`). | `tui-inputs`, `tui-controls`, `tui-redirect` and `tui-decisions` (`$R/PC/PC34/impl-r1`). `tui-overview` and `tui-history` (`$R/PE/PE28/impl-r1`). The journey pair (`$R/PF/PF21/impl-r1/journey-pair.log`). | Actual UI interaction | Met for function |
| WM-035 TUI service-mode rendering and PTY acceptance | PC31 to PC33 (`b393be5e`, `540d3ee2`, `b698073e`), PE6 `f71a4a05`, PE7 `c8ee3200`. | `tui-sizes` and its control `tui-sizes-broken-draft`, and the control `tui-failures-broken-stale` (`$R/PE/PE28/impl-r1`). `tui-failures` (`$R/PG/PG1/impl-r1/tui-failures.log`). | Actual UI interaction | Met for function. The terminal-escape suites are deferred to the security stage. |
| WM-036 Pi manager session and transport adapter | `ext-pi` client and `ManagerSession`. PE10 to PE16 (`91e85a43` to `3421036c`). | `npm run check` and `npm test`, 220 passed (`$R/PG/PG30/impl-r1/03-ext-pi-test.log`). `pi-client` (`$R/PD/PD29/impl-r1/pi-client.log`). | Deterministic native fixture | Met for function |
| WM-037 Pi native UI and tool-mediated controls | PE17 to PE22 (`ee40d84d` to `c8dca6a2`). | `pi-client-controls` (`$R/PD/PD29/impl-r1/pi-client-controls.log`). `pi-host` (`$R/PG/PG30/impl-r1/05-pi-host.log`). | Actual UI interaction | Met for function |
| WM-038 Pi real-host service-mode acceptance | PE23 to PE26 (`95b8714d` to `3a35f60d`). | `pi-host-smoke`, `pi-host-model` and the controls `pi-host-broken-answer` and `pi-host-model-decline` (`$R/PE/PE28/impl-r1`). `pi-host` and `npm run test:integration`, 9 of 9 (`$R/PG/PG30/impl-r1`). | Actual UI interaction | Met for function |
| WM-039 Cross-client and cross-machine operation | PF4 to PF8 (`2ccc38fd` to `2a89ef55`, with `360adc1`, `6656266`, `613d70e`, `4f0f5a4`, `cc56b94`), PF23 `870c7b8b`. | `cross-client`, `cross-client-lifecycle`, `cross-client-lineage` and the control `cross-client-broken-answer` (`$R/PF/PF23/impl-r1`). | Actual UI interaction | Met for function on one machine. Cross-machine operation did not run, because the governing goal limits validation to local macOS. The A16 and A17 matrices are deferred to the security stage. |
| WM-040 Formal-to-implementation conformance bridge | PF9 to PF15 (`7d57a9b0` to `5cda60da`). | `bisim/ci/manager.sh` with its three controls (`$R/PF/PF22/impl-r1`). | Theorem | Met for function. The authorization transitions are deferred to the security stage. |
| WM-041 Capacity, security and fault-injection evidence | `manager/CAPACITY.md`, `manager/test/capacity-ceilings.json`. PF16 to PF20 (`2808c7ac` to `537f1795`), PF24 `88d999b7`, PG1 `86c1e9e9`, PG2 `26e84d8d`, PG3 `afd44d78`, PG4 `76da0f5c`, PG10 `c550335c`. | The runs of record of the six capacity modes and the five failure modes at N8 on `e454fbd7` (`$R/PH/PH2/impl-r1`): every workload started at a one-minute load of at most 16 with no other manager, and `capacity_summary.py` reports 129 keys pass, none fails and none is missing (`$R/PH/PH2/impl-r1/13-summary.log`). | Deterministic native fixture | Met for function on local macOS. `manager/CAPACITY.md` records the runs of record. Root replacement and the security part are deferred to the security stage. Linux containment did not run. |
| WM-042 Operator controls, observability and recovery procedures | `Agentic.Manager.LocalAdmin`, `Quarantine`, `Store`, `manager/OPERATIONS.md`. PG5 to PG13 (`b4b8a30d` to `eca320c9`). | `operations` with case 7, which runs the procedures of the runbook in order (`$R/PG/PG28/impl-r1/03-operations.log`). `failures-backup` (`$R/PG/PG11/impl-r1/failures-backup.log`). | Deterministic native fixture | Pending human operator exercise |
| WM-043 Reproducible packages and rollback | `flake.nix` outputs `packages.<system>.agentic-run` and `default`. PG14 to PG17 (`5710785a`, `8fcb4999`, `ab186c91`, `c901a10f`). | `nix build .#agentic-run` and `test/cabal.sh sdist` (`$R/PG/PG14/impl-r1`, latest `$R/PG/PG28/impl-r1/02-nix-build.log` and `12-sdist.log`). `package` (`$R/PG/PG28/impl-r1/06-package.log`). `rollback` (`$R/PG/PG28/impl-r1/07-rollback.log`). | Package build | Met for function. Only `aarch64-darwin` was built. |
| WM-044 Documentation, independent review and release handoff | `doc/agent-cat.texi`, `doc/api/README.md`, the client and owner documents and this record. PG19 `2c56102d`, PG20 `5951ad37`, PG21 (this record). | `make -C doc check` (`$R/PG/PG30/impl-r1/08-doc-check.log`). The integrated review `doc/research/reviews/workflow-manager-phase-g-review-2026-10.md` (PG22 `9f40bd9e`) with no critical or high finding. The gate summary `$R/PG/PG30/impl-r1/g5-summary.md`. | Pure model test | Met for function. The independent closure review is pending. The security review is deferred to the security stage. |

## Gate matrix

| Requirement | Implementation evidence | Executable evidence | Evidence ceiling | Status |
|---|---|---|---|---|
| G0 Implementation baseline | WM-001 to WM-007. `acat-g0-r3r7`. | The baseline acceptance under the storage amendment. | Deterministic native fixture | Met (2026-09-12) |
| G1 Isolated manager core | WM-008 to WM-022. `acat-g1-h1wc`. | The real-worker lifecycle of WM-022 at N1 and N8 (`$I/vertical.d42c7UhQ`). | Deterministic native fixture | Met (2026-09-22) under the local-only amendment |
| G2 Authenticated observation | WM-023 to WM-026. `acat-g2-la77`. | The rows WM-023 to WM-026. | Deterministic native fixture | Partial. Observation works with authentication and revocable credentials. The observation-only witness with mutations unavailable and the negative matrices are deferred to the security stage. |
| G3 Remote mutation candidate | G2, WM-027, WM-028, WM-040 and WM-041. `acat-g3-v1iz`. | The rows of those packages. | Theorem | Partial. The hostile-input, replay and containment gates are deferred to the security stage. WM-028 is partial. Test exposure is not deployment. |
| G4 Three-client acceptance | WM-029 to WM-039. `acat-g4-pech`. | The client rows and the three `cross-client` modes (`$R/PF/PF23/impl-r1`). Local modes: `ci/emacs-ui.py` local cases (`$R/PF/PF23/impl-r1/emacs-ui.log`) and `agentic-run --tui --local` in `rollback` (`$R/PG/PG28/impl-r1/07-rollback.log`). | Actual UI interaction | Partial. Met for function on one machine. Cross-machine acceptance did not run, because the governing goal limits validation to local macOS. |
| G5 Release candidate | G3, G4 and WM-041 to WM-044. `acat-g5-u0w2`. PH1 `e454fbd7` rewrites the `@earendil-works` entries of `ext-pi/package-lock.json` as links to the Pi fork (PG18). | The rows of WM-041 to WM-044 and the identities below. The gate of Phase G, PG24 to PG30, in which every step and every control gave its expected result (`$R/PG/PG30/impl-r1/g5-summary.md`). The WM-041 runs of record at N8 on `e454fbd7`, with 129 ceiling keys passed, none failed and none missing (`$R/PH/PH2/impl-r1/13-summary.log`). `npm run check` and `npm test`, with 220 tests passed, on the rewritten lock (`$R/PH/PH1/impl-r1/npm-test.log`). The journey at N8 on `4d078647` (`$R/PH/PH3/impl-r1/journey-N8.log`). | Package build | Met for function on local macOS. Every functional item of the gate has passing evidence. G5 stays open for these items: the security stage, which the operator direction of 2026-09-30 defers, the exercise of `manager/OPERATIONS.md` by another person (WM-042), cross-machine evidence, which did not run, and the independent closure review. Production activation is not authorized. |

## Acceptance scenario matrix

| Requirement | Implementation evidence | Executable evidence | Evidence ceiling | Status |
|---|---|---|---|---|
| A01 Missing inputs and readiness | WM-011 Drafts. WM-027 captures. | `manager-draft-check` (`$R/PG/PG3/impl-r2/draft-check-N8.log`). `tui-inputs` (`$R/PC/PC34/impl-r1/09b-tui-inputs-N8.log`). `emacs-service` and `pi-host` (`$R/PF/PF23/impl-r1`). | Actual UI interaction | Met for function |
| A02 Exact captured bytes | WM-005 codecs, WM-011 captures, C12 `004eef20`. | Every `tui-journey` submits the exact Unicode input (`$R/PF/PF21/impl-r1/journey-pair.log`). `mutations-captures` (`$R/PE/PE28/impl-r1/0803-mutations-captures-N8.log`). The capture workload of `capacity-inputs` (`$R/PG/PG4/impl-r1`). | Actual UI interaction | Partial. The records name no check that changes the original file after capture or uses the server-owned large-file path. |
| A03 Competing reservations | WM-013 Admission. | `capacity-admission`, with the `reservations.r1` and `reservations.r16` workloads (`$R/PG/PG1/impl-r1/capacity-admission.log`). `manager-admission-check` (`$R/PG/PG28/impl-r1/10-admission-main.log`). | Deterministic native fixture | Met for function |
| A04 Changed or expired preparation | WM-014 Approval, WM-020 restart. | `manager-approval-check` (`$R/PF/PF21/impl-r1/approval-check-N8.log`). The control `tui-consent-control` (`$R/PF/PF21/impl-r1`). | Deterministic native fixture | Met for function |
| A05 Lost reply around start intent | WM-010 Commands, WM-014, WM-020. C24 `de22ba49`. | `manager-command-check` (`$R/PG/PG28/impl-r1/09-command-check.log`). `failures-manager` and `failures-launched` (`$R/PG/PG1/impl-r1`). | Deterministic native fixture | Partial. The per-route crash boundaries were dropped in Phase B part 2, and the `admission_audit.py` audits are removed by the operator direction of 2026-09-29. |
| A06 Concurrent runs with decisions | WM-015, WM-016. PC24 `525c4cfa`. | `mixed` (`$R/PE/PE28/impl-r1/0801-mixed-N8.log`). `tui-decisions` (`$R/PC/PC34/impl-r1/09e-tui-decisions-N8.log`). | Actual UI interaction | Met for function |
| A07 Answer race across clients | WM-016 FIFO reservation. PF5 `d889f241`. | Leg 2 of `cross-client`: 412 `stale-revision` for the later send and a concurrent HTTP answer race (`$R/PF/PF23/impl-r1/cross-client.log`). | Actual UI interaction | Met for function. Two truly simultaneous UI answers were dropped by the Phase F plan, and each race outcome was seen once at N8. |
| A08 Retry, fail-over, abandon, redirect, steer and cancel | WM-016, C16 to C20, PC22, PC23. | `controls`, `controls-routing` (`$R/PE/PE28/impl-r1`). `live-redirect` and `tui-controls` with its control `tui-controls-broken-cancel` (`$R/PC/PC34/impl-r1`). `emacs-service-controls` (`$R/PF/PF23/impl-r1`). `pi-client-controls` (`$R/PD/PD29/impl-r1`). | Actual UI interaction | Met for function |
| A09 Network clients closed during work | WM-012 Worker, WM-026. PC30 `d3a2cc66`. | `cross-client-lifecycle` (`$R/PF/PF23/impl-r1/cross-client-lifecycle.log`). `pi-host` quits with the run still owned (`$R/PF/PF23/impl-r1/pi-host.log`). | Actual UI interaction | Met for function |
| A10 Invalid envelopes | WM-006, WM-015 ingestion. PF12 to PF14. | The `refusals` lane of `manager-conformance-check` (`$R/PF/PF22/impl-r1/refusals.log`). The ingestion check (`$R/B/B19/impl-r1/09a-ingestion-N8.log`). | Deterministic native fixture | Met for function. The refusals that need a live worker were dropped by the Phase F plan. |
| A11 Missing or corrupt result | WM-017 Artifacts. | `manager-artifact-check` (`$R/PG/PG3/impl-r2/artifact-history-N8.log`). The WM-017 acceptance of its A11 part (`$I/artifacts.Rdk65Wyh`). | Deterministic native fixture | Met for function |
| A12 Exclusive export under races | WM-007, WM-017. C14 `768de34b`. | `mutations-exports` (`$R/PE/PE28/impl-r1/0805-mutations-exports-N8.log`). The WM-017 acceptance of its A12 part. | Deterministic native fixture | Partial. Export exclusivity is met for function. Root replacement under a running manager is deferred to the security stage. |
| A13 Restart, resume and fork of parents | WM-018 History and Lineage. C15 `a3a8720c`, PC28 `2bc437ef`. | `mutations-lineage` (`$R/PE/PE28/impl-r1/0806-mutations-lineage-N8.log`). `cross-client-lineage` (`$R/PF/PF23/impl-r1`). `manager-history-check` (`$R/PG/PG4/impl-r1/history-check-N8.log`). | Actual UI interaction | Met for function |
| A14 SSE at a snapshot boundary | WM-025, WM-026. B14, PC17 `174d7f5b`. | `events-lifecycle` and `capacity-streams` (`$R/PG/PG3/impl-r2`). `client_native.py` stream cases (`$R/PE/PE28/impl-r1/05b-client-native-N8.log`). | Deterministic native fixture | Met for function |
| A15 Delayed responses and endpoint switch | WM-029 refresh coordinator, WM-033, WM-036. PE5 `e8ca40b0`, PD1 `86556364`. | `tui-failures` with the delayed-response endpoint switch (`$R/PG/PG1/impl-r1/tui-failures.log`). `manager-client-check vectors` (`$R/PE/PE28/impl-r1/05a-client-vectors.log`). | Actual UI interaction | Met for function |
| A16 Revocation and rotation during operations | WM-023. PF7 `da32a966`. | The rotation with cutoff and the single revocation of `cross-client-lifecycle` (`$R/PF/PF23/impl-r1`) and `credential-lifecycle` (`$R/PG/PG28/impl-r1/04-credential-lifecycle.log`). | Actual UI interaction | Deferred to the security stage. Only the functional rotation and revocation have evidence. |
| A17 Restore of an older backup | WM-020, PG9 `9cf218f7`, PG11 `5c8f38de`. A restoration rotates the authority epoch and the stream and revokes every restored credential. | `failures-backup` case 3 (`$R/PG/PG11/impl-r1/failures-backup.log`). `operations` (`$R/PG/PG28/impl-r1/03-operations.log`). | Deterministic native fixture | Partial. The functional fencing is met. The negative matrix of old credentials, cursors and authority keys is deferred to the security stage. |
| A18 CORS, Host, Origin and proxy headers | WM-024 Transport. B9 `8c4140b7`. | The frozen refusal codes of `boundary` (`$R/B/B19/impl-r1/11d-service-boundary-N8.log`). | Deterministic native fixture | Deferred to the security stage |
| A19 Saturation and a full disk | WM-019, WM-021, PF17 to PF20. | `capacity-admission`, `faults-io` and `storage` (`$R/PG/PG1/impl-r1`). `capacity-inputs` (`$R/PG/PG4/impl-r1`). `capacity-streams` (`$R/PG/PG3/impl-r2`). | Deterministic native fixture | Partial. A file-size limit stands for a full disk, and no check produces a true `ENOSPC`. After the first write failure the Store refuses every request, the safety path included, until a restart, as `manager/STORAGE.md` states. |
| A20 Death of a manager, worker or group leader | WM-019, WM-020. C23 `76e65633`, C24 `de22ba49`, PE2 `06c0c0db`. | `failures-worker`, `failures-manager` and `failures-launched` (`$R/PG/PG1/impl-r1`). | Deterministic native fixture | Partial. Worker and manager death are met for function on macOS. Escaped descendants and Linux did not run: OS containment is excluded by the scope correction of 2026-09-20, and validation is local macOS only. |
| A21 Injected secrets and escapes in failure paths | WM-008, WM-017, WM-023. | The WM-017 acceptance of its A21 part (`$I/artifacts.Rdk65Wyh`). | Deterministic native fixture | Deferred to the security stage |
| A22 Keyboard interaction at three sizes | WM-032, WM-035, WM-038. | `tui-sizes` and `tui-sizes-broken-draft` (`$R/PE/PE28/impl-r1`). `emacs-service-lifecycle` at 40x12, 80x24 and 140x36 (`$R/PF/PF23/impl-r1`). `pi-host` (`$R/PF/PF23/impl-r1/pi-host.log`). | Actual UI interaction | Met for function |
| A23 Three clients across a machine boundary | WM-039. | The single-machine witness of the three `cross-client` modes (`$R/PF/PF23/impl-r1`). | Actual UI interaction | Not run. The governing goal limits validation to local macOS, and no second machine took part. |
| A24 Upgrade and rollback | WM-020, WM-042, WM-043. PG16 `ab186c91`, PG17 `c901a10f`. | `package` with the schema 1 to 11 roots and the refused schema 13 root (`$R/PG/PG28/impl-r1/06-package.log`). `rollback`, which keeps the file stats of the manager root unchanged through the local run (`$R/PG/PG17/impl-r1/rollback.log`). | Package build | Met for function |

## Package identities

The flake package `agentic-run` was built with the flake reference
`.#agentic-run` from the Git worktree at commit
`e898b8b9de4fb71bfdddc2b52a90863feffb75a3`, with a clean working copy, in
part 5 of the G5 gate (PG28). The `package` and `rollback` modes of that part
ran against this output path. The derivation path depends only on
`flake.nix`, `flake.lock` and the filtered source, so a commit that changes
no file of the filtered source keeps it.

| Item | Identity |
|---|---|
| Derivation path | `/nix/store/6ir4xzj5ivfj215vkikx8vg2bwj3dnhd-agentic-run-0.1.0.0.drv` |
| Output path | `/nix/store/yc3zvavs19s6d1ywixzhchiszhiqy2vh-agentic-run-0.1.0.0` |
| Filtered source | `/nix/store/vqskigd3cvd184r2qf1y996nrhl0qya0-source` |
| SHA-256 of `bin/agentic-run` | `dcc773bd56488695ac1dc0fe7cce48590cd8818501041908f2dbb72fba009991` |
| Source distribution | `agentic-0.1.0.0.tar.gz`, 1902882 bytes |
| SHA-256 of the source distribution | `7b0031bec8c686b34c364133b1a64d33f04e8c969ad7e116ee8850028f60be76` |
| Compiler | GHC 9.10.3 from the GHC environment of the root shell |
| Build tool | cabal-install 3.16.1.0 |
| Nix | Nix 2.34.8 (Determinate Nix 3.21.7) |

The build ran with `--no-update-lock-file` and `--option substitute false`.
Nix built one derivation, the package itself, and found every other input in
the local store. The build took 490 seconds of wall clock. The one-minute load
average was 8.2 at the start and 15.9 at the end
(`$R/PG/PG28/impl-r1/02-nix-build.log`). The source distribution came from
`test/cabal.sh sdist` at the same commit (`$R/PG/PG28/impl-r1/12-sdist.log`).

The first package build (PG14) used the base revision
`eca320c9ef1ce6838527acfcf051f5b56e73f910`. Its output path was
`/nix/store/lc8qfj9nwxrlm4582wswn9vk3h48zigv-agentic-run-0.1.0.0`, and the
SHA-256 of its `bin/agentic-run` was
`6ad55c59c69d57923b2ec929d3cd937405ada1fe430f36ef0f056dbfa995e4fc`. PG15,
PG16 and PG17 used that output. The only change to the filtered source after
it is commit `1ac80da9`, which adds the missing manager modules to the module
lists of the check executables `manager-admission-check` and
`manager-artifact-check` in `agentic.cabal`. That change gives the new
derivation path of the table.

For the PG14 build, the built `bin/agentic-run list` printed the ten
registered programs, and `bin/agentic-run run hello --scripted` printed the
documented trace with `billFresh 3` and `billMemo 3`.
`doc/check-manual-cli.py` passed against the built executable. The derivation
path was the same in three evaluations: from the worktree, from a copy of its
tracked files in a temporary directory with the reference
`path:<copy>#agentic-run`, and from the worktree after an edit of `README.md`
only. The flake fingerprint changed with that edit, so the edit reached the
flake source. The edit was then reverted. For the PG28 build,
`bin/agentic-run list` reported ten registered programs.

The listing of the source distribution from `test/cabal.sh sdist` includes
`nix/haskell-overrides.nix`, `nix/crypton-x509-validation-san.patch` and
`nix/process-close-fds-linux.patch`.

## Acceptance of the packaged artifact

The `package` mode of `manager/test/service_http.py` accepts the packaged
executable through a running manager. It reads the path of `bin/agentic-run`
from `PACKAGE_RUNNER` and uses that file in place of the runner argument of
the harness. The file is the manager process and the runner of the one
profile of the fixture, whose target arguments are `--scripted`. The mode
issues a credential with `observe`, `submit` and `control`, creates a request
of the `hello` workflow, which needs no provider and no input, enqueues it and
approves the exact review. It waits for the terminal run, downloads the
verified result and compares the SHA-256 of the downloaded bytes with the
published digest. It requires that the supervisor manifest of the worker run
names the packaged executable. It then reads `status` through the live
channel, stops the manager through `shutdown` and requires exit status 0.

```sh
out=$(nix build .#agentic-run --no-update-lock-file --option substitute false --print-out-paths --no-link)
schemas=$(mktemp -d)
direnv exec . bash -c "\$(bash test/cabal.sh list-bin manager-store-check) schema-fixtures $schemas"
fixture=$(mktemp -d)
mkdir "$fixture/N8"
SCHEMA_FIXTURES="$schemas" PACKAGE_RUNNER="$out/bin/agentic-run" direnv exec . python3 -B manager/test/service_http.py \
  "$PWD" "$fixture/N8" "$out/bin/agentic-run" 8 package
```

The mode needs both `PACKAGE_RUNNER` and `SCHEMA_FIXTURES`. The schema step
follows the `hello` run and is described under
[schema upgrade and refusal](#schema-upgrade-and-refusal).

The latest run passed at `-N8` on 2026-10-03 in part 5 of the G5 gate
(PG28), at commit `e898b8b9de4fb71bfdddc2b52a90863feffb75a3` with a clean
working copy, against the output path of
[Package identities](#package-identities)
(`$R/PG/PG28/impl-r1/06-package.log`). The one-minute load average was 12.3
at the start and 13.5 at the end. The first run of record (PG15) passed on
the PG14 output path at the base revision
`5710785a3de642c166929c3dff7204a76af62fa0`
(`$R/PG/PG15/impl-r1/package.log`).

| Item | Identity |
|---|---|
| Derivation path | `/nix/store/6ir4xzj5ivfj215vkikx8vg2bwj3dnhd-agentic-run-0.1.0.0.drv` |
| Output path | `/nix/store/yc3zvavs19s6d1ywixzhchiszhiqy2vh-agentic-run-0.1.0.0` |
| SHA-256 of `bin/agentic-run` | `dcc773bd56488695ac1dc0fe7cce48590cd8818501041908f2dbb72fba009991` |
| Runner version in the catalogue and the supervisor manifest | `0.1.0.0` |
| Workflow | `hello`, `workflow_117d409316e9bd8244415684a88f2d8327304e414da4a7ca078e905906abce16` |
| Program hash in the supervisor manifest | `785260762a2848e71d20e3e522a8e477d76b13142cc18e3fe7fcdfebaf085cbb` |
| Run | `run_5e5997c09eb4b6cedc7859a0762ad0c5a20d98d7ab2757b4`, worker run `native-77200-1552535248083000` |
| Verified result | `artifact_7bc6d9e8421182e9db798bf9d327980700013e7bd16e0191631e33c64967dcff`, 103 bytes |
| SHA-256 of the downloaded result | `f4f615616e7ab1ea8c7e59ece54ebacf2ca4162468792f24d6bc3e2dc2992607`, equal to the published digest |

The live `status` answered `state` `serving`, `live` and `ready` `true`, with
0 active reservations and 0 owned workers after the run. `shutdown` answered
`{"state": "stopped"}`, and the serve process exited with status 0. The result
holds the identifier of the worker run, so its digest differs from one run to
the next.

## Schema upgrade and refusal

The `schema-fixtures DIR` lane of `manager-store-check` writes the manager
roots `schema-1` to `schema-11` and `schema-13` in `DIR`. Each root holds its
manager role marker and a coordination database. The database of `schema-N`
holds the tables of schema version N, which are the version-one statements and
the migrations of `Agentic.Manager.Schema` up to that version. The database of
`schema-13` holds the tables of version 12 with `user_version` 13. Each
database has one service metadata row with an authority epoch derived from its
version.

After the `hello` run, the `package` mode copies each root of
`SCHEMA_FIXTURES` and gives the copy a serve configuration and an offline
configuration. For each older root, the packaged executable runs offline
`status`, which reports the authority epoch of the fixture. `PRAGMA
user_version` then reads 12, and offline `check-store` reports `valid`. The
mode issues a credential offline, starts `RUNNER --manager serve`, requires
200 on `GET /v1/capabilities` with the authority epoch of the fixture, stops
the manager through `shutdown` and requires exit status 0. For `schema-13`,
offline `status` refuses with `storage-unavailable`, `RUNNER --manager serve`
exits with status 2, and `user_version` stays 13.

The latest run of the schema step passed at `-N8` on 2026-10-03 in the
`package` run of PG28, with the output path of the table above and the roots
that the `schema-fixtures` lane of `manager-store-check` wrote at the same
commit (`$R/PG/PG28/impl-r1/05-schema-fixtures.log`). All eleven older roots
upgraded to version 12, passed `check-store` and served, and the version 13
root was refused by offline administration and by serve. The first run of
record (PG16) passed on the PG14 output path at the base revision
`8fcb49991c9b49ac0095275572f49dcf81818fc0`
(`$R/PG/PG16/impl-r1/package.log`).

## Rollback to explicit local clients

The `rollback` mode of `manager/test/service_http.py` exercises the rollback
of scenario A24 with the packaged executable. It reads `PACKAGE_RUNNER` as
the `package` mode does, and the file is the manager process, the runner of
the one profile with `--scripted`, the local TUI and the flow verb. The
manager has one execution reservation.

```sh
out=$(nix build .#agentic-run --no-update-lock-file --option substitute false --print-out-paths --no-link)
fixture=$(mktemp -d)
mkdir "$fixture/N8"
PACKAGE_RUNNER="$out/bin/agentic-run" direnv exec . python3 -B manager/test/service_http.py \
  "$PWD" "$fixture/N8" "$out/bin/agentic-run" 8 rollback
```

In the first lifetime a request of `hello` completes and its verified result
is saved, a request of `harden` waits at its person question, and a second
request of `hello` waits for capacity. A drain refuses a new enqueue with 503
`storage-unavailable` while the queued request stays queued. The waiting run
is cancelled through its HTTP control, and `status` then reports no active
reservation and no owned worker. `shutdown` stops the serve process with exit
status 0, and an offline backup goes through the offline configuration.

The mode then records the type, size and modification time of every path of
the manager root. It requires that no process names the configuration files
or the manager root and that nothing listens on the manager port. It runs
`agentic-run --tui --local` in a pseudo-terminal with its own
`XDG_CONFIG_HOME` and `XDG_STATE_HOME`, selects `harden` with the scripted
target, answers the person question and waits for the result. It reads the
manager log and the two run logs with `agentic-run flow` and reads the saved
verified result again. The record must be unchanged after the local run and
the reads, and the cancelled run log must end with `run.cancelled`. Offline
`status` follows only then, and the record must detect its writes. A second
lifetime on the same root prepares the review of the queued request before
any command of the lifetime, and its run succeeds after the exact approval.
The flow verb then shows one enqueue command of that request, one receipt for
each command and one start relay for each of the three runs.

The latest run passed at `-N8` on 2026-10-03 in PG28, at commit
`e898b8b9de4fb71bfdddc2b52a90863feffb75a3` with a clean working copy, against
the output path of [Package identities](#package-identities)
(`$R/PG/PG28/impl-r1/07-rollback.log`). The one-minute load average was 13.5
at the start and 13.1 at the end. The first run of record (PG17) passed on
the PG14 output path at the base revision
`ab186c91f4691ac826504c57509b05f997e57372`
(`$R/PG/PG17/impl-r1/rollback.log`).

| Item | Identity |
|---|---|
| SHA-256 of `bin/agentic-run` | `dcc773bd56488695ac1dc0fe7cce48590cd8818501041908f2dbb72fba009991` |
| Completed run and its verified result | `run_32adb1425a409b79ec40f795b3608e636599d3bec7510bcc`, `artifact_9ff0827ae29aae89cda3b78e958b3797f48fed8a4a03943537f8457d2f335945`, 103 bytes, SHA-256 `dfc14fc8d4921b6061e307d893bfa0c8f9a0e13ad0205bffb59bcaaacf345a34` |
| Cancelled run and its cancel command | `run_d51b7aacbe7b8cbf4f663df75e61616bd486cf69dc35ea2c`, `command_b57a84d21206378d8c910ac10f4275b6163a3809fa0f01b7` |
| Offline backup | `backup_95b29a10dc995a5d006ea31952306362919938eb78753369dee08f9b2927077c` |
| Recorded paths of the manager root | 37, with `coordination.sqlite3` and no write-ahead log after the checkpoint, one manager-log file and two run stores |
| Local TUI run | `tui-77906-1552554432376000` under the private `XDG_STATE_HOME` |
| Queued request, its new review and its run | `request_3a5204307f8493c372f331eaae73064ea8843ad90236fb74`, `preparation_768f71b9274f18d2728ac6e9f45e3a4ff953be1eae35a0b1`, `run_b883bb0e336aabd87d713c3b42cebfe3c4fba94b2f5bdf13` |

Offline `status` after the comparison changed the modification time of the
manager root directory. The manager log of the two lifetimes held 14 commands
with one receipt each. The local modes of the Emacs client and of the Pi
extension are covered by their existing local suites, `ci/emacs.sh` of
agent-workflows-emacs-native and `npm test` and `npm run test:integration` of
`ext-pi`, which the gate runs. This mode does not run them.

## Source identities

Each packaging subtask ran on an uncommitted working copy, and the Integrator
then committed it. The table gives the base of each run and the commit that
holds its change.

| Subtask | Base revision of the run | Commit of the change | Content |
|---|---|---|---|
| PG14 | `eca320c9ef1ce6838527acfcf051f5b56e73f910` | `5710785a3de642c166929c3dff7204a76af62fa0` | The flake package and the source distribution. |
| PG15 | `5710785a3de642c166929c3dff7204a76af62fa0` | `8fcb49991c9b49ac0095275572f49dcf81818fc0` | The `package` mode. |
| PG16 | `8fcb49991c9b49ac0095275572f49dcf81818fc0` | `ab186c91f4691ac826504c57509b05f997e57372` | The schema fixtures and the upgrade and refusal step of `package`. |
| PG17 | `ab186c91f4691ac826504c57509b05f997e57372` | `c901a10f95a33ebece0a3a212af71fb12417931b` | The `rollback` mode. |
| PG28 | `e898b8b9de4fb71bfdddc2b52a90863feffb75a3` | None. The run used a clean working copy. | The rebuild of the package and the latest `package` and `rollback` runs. |

Between `5710785a` and `e898b8b9`, the only change to the filtered source is
the change to `agentic.cabal` in `1ac80da9`. No commit in that range changes
a `.hs`, `.c` or `.h` file under the source directories of the package, or a
Nix or flake file. The PG28 build therefore has a new derivation path, which
[Package identities](#package-identities) gives.

The Emacs client of the checks is commit
`6e8eac0bc0fc9a235f9eab66bfec0f3f9cda1c15` of the `emacs-native` branch of
agent-workflows. PG20 changed only its README, for a local commit by the
Integrator. No commit of that branch is pushed.

## Accepted additive OpenAPI fields

Version 1 of the `/v1` contract is frozen, and every change since commit
`5e8bbf9f` adds paths, schemas or optional properties only. The section
[Accepted additive fields](api/README.md#accepted-additive-fields) of the API
README is the authoritative list.

| Since | Addition |
|---|---|
| `88d999b7` (PG12 `3bf6e8cb`) | The optional members of the `status` result of `LocalAdminResponse`: `live`, `ready`, `queuedRequests`, `oldestQueuedAgeSeconds`, `reservations`, `ownedWorkers`, `lostRuns`, `unresolvedCommands` and `serviceFault`. |
| `5e8bbf9f` (C9 to C11, C15, C21) | The paths `GET /runs/{id}/routes` and `GET /routes`. The schemas `RouteCursor`, `RouteRecord`, `RouteBatch`, `ManagerRouteCursor`, `ManagerRouteRecord`, `ManagerRouteBatch`, `ReviewLineage` and `ReviewEdit`. The optional properties `Review.lineage` and `PublicPolicy.personAnswers`. |

`Capabilities` keeps its bytes, and `DataBroker` keeps its nine operations
(`$R/PF/PF22/impl-r1/broker-check.log`). The diff of `doc/api/openapi.yaml`
for PG12 is `$R/PG/PG12/impl-r1/openapi-diff.log`.

## Tested platform

| Component | Version |
|---|---|
| Operating system | macOS 27.0 on arm64, Nix system `aarch64-darwin`. It is the only tested platform. |
| Compiler and build tool | GHC 9.10.3 and cabal-install 3.16.1.0 from the direnv environment of the worktree. |
| TLS library | `crypton-x509-validation` 1.9.1 with the subject alternative name patch of `nix/`. |
| Nix | Nix 2.34.8 (Determinate Nix 3.21.7). |
| Lean | The toolchains that `model/lean-toolchain` and `bisim/lean-toolchain` pin, built locally under the operator decision of 2026-10-02 for WM-040 only. |
| Emacs | GNU Emacs 30.2 from the direnv environment of the Emacs worktree. |
| Pi host | The Pi fork at `~/src/fork/pi`, commit `7857926ee`, with the linked `@earendil-works` packages at 0.99.1, Node 22.23.3, TypeScript 5.9.3 and vitest 4.1.9. |

The [version and compatibility matrix](api/README.md#version-and-compatibility-matrix)
of the API README gives the version domains that the manager accepts.

## Conditional and unavailable checks

These checks run only when their condition holds:

- `package` needs `PACKAGE_RUNNER` and `SCHEMA_FIXTURES`, and `rollback` needs
  `PACKAGE_RUNNER`. Each mode stops with a fixed message when its variable is
  unset (`$R/PG/PG15/impl-r1/package-unset-control.log`,
  `$R/PG/PG16/impl-r1/control-unset.log`).
- The Emacs modes need `EMACS`, `WF_EMACS_DIR` and, for the `emacs-service`
  modes, `WF_EMACS_UI`, with the matching pair of commits that
  `doc/workflow-manager-handoff.md` lists.
- The `ext-pi` checks need `ext-pi/node_modules` linked to the built Pi fork,
  and `npm run test:integration` needs `AGENT_CAT_E2E_RUNNER`. The live-gated
  tests of `npm test` are skipped without a live provider.
- The capacity modes give a run of record only under the host rule of
  `manager/CAPACITY.md`, which PG1 added.
- Lean and oracle builds run only under the operator decision of 2026-10-02,
  one at a time and never beside a cabal build.

These checks did not run, each for the reason stated:

- Linux builds, Linux tests and Linux containment: the governing goal limits
  validation to local macOS.
- Cross-machine operation (A23 and the cross-machine part of WM-039 and G4):
  no second machine took part.
- The exercise of `manager/OPERATIONS.md` by another person (WM-042): it is
  pending. Case 7 of `operations` is an automated exercise and does not stand
  for it.
- The independent closure review of G5: it follows this record.
- `cli/ci/policies.sh`, `manager/ci/approval.sh`, `manager/ci/controls.sh`,
  the `admission_audit.py` mutation audits, `bisim/ci/tier0.sh`,
  `bisim/ci/tier1.sh`, mutant suites, `-fforce-recomp` builds and stability
  samples: the operator direction of 2026-09-29 removes them from routine
  validation.
- `engine/acp/ci/route-live.sh`: it uses a paid provider.
- The Emacs 29.1 minimum-version check: no Emacs 29.1 is available locally.
- `npm ci` in `ext-pi`: `ext-pi/package-lock.json` is not an install
  source. Its `@earendil-works` entries link the Pi fork by paths relative
  to the main checkout, and it keeps registry entries that no linked
  package uses.
- A true `ENOSPC`, a Store that the quick check reports `corrupt`, root
  replacement under a running manager and a proxy on another host: no mode
  produces them, and root replacement is deferred to the security stage.
- A fixture that truncates a GET body and confirms that each client reads
  again (`acat-gbh8`), and the measured worst case of a POST route
  (`acat-pd3-fess-followup-uo4y`): the rules come from the source.
- Every item of the security stage that section 8 of the remaining-scope
  report and the handoff list: the operator direction of 2026-09-30 defers
  them.

## Production activation

Production activation is not authorized. No check of this record deployed
the manager, exposed it beyond the local host, used a paid provider or
changed a live client or infrastructure configuration. Deployment and
production activation remain separate explicit operator actions, and the
security stage precedes them.
