# Halt fess audit

## Review

**Summary:** Safe to preserve as explicitly unaccepted WIP, subject to parent’s final build, content review and publication checks. Not safe to describe as completed service integration, full TUI workflow acceptance, general-CA security acceptance, or a new WM/G milestone.

- **Correct:** TUI retains original pending mutation before sending, requires explicit resend confirmation, and separates approval receipt uncertainty from independently observed request association (`tui/src/Agentic/Tui/App.hs:396–417,457–517,560–573`).
- **Correct:** Service/local backends remain disjoint. Service cleanup closes frontend transport without acquiring local run cancellation authority (`tui/src/Agentic/Tui/App.hs:124–134,309–339`).
- **Correct:** Recorded N1/N8 PTY success covers submission, exact approval and detach—not completion (`../tui-approval-native-detach.log:43–45,86–88`; corresponding `.exit:1` reports `0`).
- **Fixed:** None. Read-only audit.
- **Merge verdict:** **OK with notes for WIP checkpoint preservation only. BLOCK for application acceptance or release.**

Accepted baseline remains **WM001–WM022 and G0/G1: 22/44 packages, 2/6 gates**, as supplied by halt brief. Git ancestry and current canonical state were not independently inspected.

**History isolation was not independently verified.** No passing parent-history sentinel probe was supplied or performed.

## Findings

### P1 — Slow valid responses can exhaust ingestion’s contention allowance

Current source still implements previously reported liveness ceiling:

- Ingestion requires reader/configuration admission (`manager/src/Agentic/Manager/State.hs:59–60`; `manager/src/Agentic/Manager/Store.hs:682–692`).
- Service retries `StoreBusy` for five seconds, then fails. `drive` subsequently requests original preparation stop (`manager/src/Agentic/Manager/Service.hs:142–182`).
- Response ownership retains configuration through callback completion (`manager/src/Agentic/Manager/Store.hs:703–722`).
- Network writes allow five seconds **per 16 KiB chunk**, without a matching total-response ceiling (`manager/src/Agentic/Manager/Transport.hs:209–220`; `manager/src/Agentic/Manager/Application.hs:191–197,214–225`).

A response can therefore remain valid across several chunks while blocking ingestion beyond its allowance. Corrected file/configuration ordering does not remove this problem.

**Next correction:** Parent should first reproduce held-response/runtime coexistence, then resolve at existing response/ingestion owners under settled policy. Do not widen waits, release authorization prematurely, or replay opaque operations. This finding does not establish the cause of earlier preparation failures.

### P2 — Catch-all converts invariant failures into transport uncertainty

`safeService` catches every synchronous `SomeException` and returns `TransportUnavailable` (`tui/src/Agentic/Tui/App.hs:370–376`). Consequently, programming/invariant exceptions receive the same treatment as network failures. Sending failures then expose the ordinary exact-resend path (`:427–432,560–573`).

Client already handles declared client failures and HTTP exceptions (`manager/src/Agentic/Manager/Client.hs:498–501`).

**Smallest correction:** Narrow recovery to expected exceptions. Unexpected failures should terminate or produce an explicit internal-failure state while preserving pending-command uncertainty and terminal cleanup. Do not expose private exception text or classify unexpected defects as routine retryable transport failure.

### P2 — Forbidden-approval PTY assertions lack a processing barrier

Fixture sends Enter or detail-view `y`, then immediately asks manager whether a run exists (`manager/test/service_http.py:398–405`). `TuiSession.send` guarantees bytes reach PTY, not that frontend event handling or asynchronous HTTP mutation completes (`test/tui_probe.py:334–345`).

These negative assertions can check before an erroneous approval takes effect. Current source guards are present, but this test alone does not prove their effectiveness under regression.

**Smallest correction:** Establish a post-key processing/settled-operation boundary before checking absence of approval. Confirm test fails with approval guard deliberately broken. Preserve successful selector, Unicode and detach assertions.

## Unfinished and unwired work

These are disclosed WIP limits, not evidence of fabricated success.

1. **Newest observation adapter is not integrated.** Snapshot/control/decision/output adapters exist in `tui/src/Agentic/Tui/Service.hs:430–887`. Read-only search across TUI Haskell source found their references only within that module. App still observes request/preparation/receipt state (`tui/src/Agentic/Tui/App.hs:378–394`). No TUI caller uses `downloadVerified`.
2. **Newest adapter has no coverage in inspected service test suite.** `tui/test/ServiceTests.hs:23–104` covers catalogue, request/review and receipt behavior, not new run/control/decision/output decoders. Parent’s concurrent compile-only corrections and subsequent fixture checks require their own final evidence.
3. **HTTP surface remains partial.** Registered methods omit collection/history, capture, export and lineage routes. Preparation discard explicitly returns `UnsupportedOperation` (`manager/src/Agentic/Manager/Application.hs:50–65,153–160`). Decision objects link to a queue endpoint not currently registered. Do not describe current application as complete frozen-API implementation.
4. **PTY journey intentionally stops after association/detach.** Fixture checks owned, cancellable RunControl and then breaks out (`manager/test/service_http.py:434–441`). It does not answer false, retry recovery, observe terminal completion, or retrieve result through TUI.
5. **Full updated-environment workflow remains unproved.** `../tls-owning-native.log:39–50` records actual-client success followed by preparation observation deadline failure. Later partial TUI success does not turn that invocation into a pass.

## Fess checks and verification gaps

### Evidence actually inspected

- Pure service tests verify DTO rejection, Unicode/false/null/count preservation, absence of fabricated native capabilities, prompt-LF review hashing, selector binding, expiry and receipt-resource matching (`tui/test/ServiceTests.hs:23–104`). These assertions are substantive, not blanket success checks.
- PTY fixture drives actual frontend keys and reads actual manager state. Its deterministic ACP adapter is fixture evidence, not paid-provider or general deployment evidence (`manager/test/service_http.py:344–441`).
- Corrected Overview/run owners acquire files before authorized catalogue context (`manager/src/Agentic/Manager/Overview.hs:34–43,69–76`; `manager/src/Agentic/Manager/Service.hs:275–278`). This supports correction direction, not complete liveness clearance.
- Prior TLS patch packaging finding is corrected in current `agentic.cabal:14–18`.
- Inspected TLS overrides retain ordinary package testing and shared validation ownership (`nix/haskell-overrides.nix:3–27`). No client trust bypass appears in profile connection setup (`manager/src/Agentic/Manager/Client.hs:93–109`).
- No `OPTIONS_GHC`, TODO/FIXME, `undefined`, or literal `error` markers found in searched TUI Haskell source. This is not a diff-wide suppression audit.

### Not verified

- No commands, tests, Git operations, edits, deployment, credential/live-configuration inspection, private fixture-store traversal, or delegation performed.
- Exact current diff, complete changed-file/test inventory, staged contents, ancestry reconciliation, commits, pushed refs, remote state and canonical cleanliness remain parent-owned checks.
- Historical logs were read, not rerun. Source/binary identity for those runs was not independently reconstructed.
- Newest adapter compilation and fixture execution remain unattested by this audit. Earlier successful builds cannot validate later edits.
- Native page lifecycle, concurrent Overview publication/revocation, real queued deferral, deadline/cancellation and prepublication failure checks remain incomplete according to `../service-liveness-review.md:99–126` and `../mixed-http-validation.md:63–67`.
- General-CA residual issue `acat-tls-name-forms-6gbo` remains open. Complete TLS review records unsupported IP Name Constraints matching plus unexercised DNS normalization/inheritance concerns (`../tls-update-review.tls-update-review.md:25–27`; `../tls-update.md:42`). Upstream dependency source was not re-inspected during this audit.
- Final tracked checkpoint bundle, canonical handoff update and `/Users/johnw/dl` remaining-scope plan were not supplied for review. Their completeness, estimates and publication safety are not attested.

## Scope and documentation drift

No unrelated change was established from inspected source. Targeted TLS family update was explicitly authorized. Without exact diff, this is not exhaustive scope clearance.

Current broker-source handoff still describes public observations as unimplemented (`doc/workflow-manager-handoff.md:84–90`). Earlier notes likewise describe TUI as unimplemented, while later broker notes document actual submission/approval. Preserve historical failures and reports, but add a clear dated supersession index. Do not overlay stale tracking/handoff files onto canonical ancestry.

Newest adapter is display-only source, not completed frontend capability. Keep that distinction explicit in checkpoint manifest.

## Remaining-scope resume ledger

All following packages remain **unaccepted**. Table is scope inventory, not effort estimate or completion attestation. Original package definitions are in `doc/research/workflow-manager-implementation-plan.md:770–1300`.

Apply existing amendments: TUI first, default broker retained, Runtime sole interpreter, local macOS Nix/direnv validation only. Emacs is not a prerequisite for first TUI journey. RabbitMQ remains deferred. No Linux, external-host or sandbox prerequisite is reinstated (`doc/workflow-manager-handoff.md:23–64,92–127`).

| Package | Resume obligation |
|---|---|
| WM023 | Finish credential/authorization evidence, especially scoped retained responses, rotation, revocation and worker-secret exclusion. |
| WM024 | Complete protected transport negatives and resolve enabled-path security/liveness limits. |
| WM025 | Finish read/history surface, immutable page lifecycle, consistent cuts and artifact-response checks. |
| WM026 | Finish snapshot/event attachment, retention/reconnect and slow-reader coexistence evidence. |
| WM027 | Complete missing mutations and route-specific stale, conflicting, lost-reply and crash-boundary checks. |
| WM028 | Complete integrated real-TLS hostile-input/security/failure gate. |
| WM029 | Complete client refresh/reconciliation and shared DTO/event conformance vectors. |
| WM030 | Implement downstream Emacs manager transport and credential lifecycle. |
| WM031 | Wire existing Emacs lifecycle presentation to manager resources. |
| WM032 | Run real Emacs interaction and local-mode regression acceptance. |
| WM033 | Independently clear explicit TUI backend, import boundary and endpoint isolation. |
| WM034 | Wire run display, typed decisions, controls and verified results, then remaining history/capture/lineage/export UI. |
| WM035 | Complete uninterrupted PTY workflow and three-size, stale, reconnect, revocation and terminal-safety negatives. |
| WM036 | Add Pi endpoint-bound session/transport without local ownership or manager-root pruning. |
| WM037 | Wire Pi native UI and trusted tool-grant mutation paths. |
| WM038 | Complete actual Pi-host service interaction and local-mode/root-isolation regressions. |
| WM039 | Complete amended local-host cross-client concurrency, detach/reconnect and authority-change matrix. |
| WM040 | Finish separate manager formal/implementation conformance bridge when authorized. No new Lean/oracle build during halt. |
| WM041 | Complete capacity, security and fault injection, including held-response ingestion behavior. |
| WM042 | Finish operator controls, health distinctions and exercised recovery procedures. |
| WM043 | Prove reproducible local packages, upgrade/rollback and compatible recovery without activation. |
| WM044 | Assemble requirement evidence matrix, current docs and integrated independent review. |

**G2–G5 remain open** (`doc/research/workflow-manager-implementation-plan.md:78–81`):

- **G2:** Complete authenticated observation evidence. Current mutation-enabled fixture is not the original observation-only gate witness.
- **G3:** Complete mutation/security/conformance and applicable capacity evidence.
- **G4:** Complete all three native clients and amended cross-client matrix.
- **G5:** Complete operational, packaging, rollback, documentation and independent-review evidence.

## Severity-ranked next actions

1. **Before checkpoint publication:** Parent verifies final buildable bytes, exact staged content and ancestry. Preserve failures and original pre-broker delta. Publish only allowlisted non-secret source/reports—no keys, credentials, raw databases or arbitrary fixture trees.
2. **P1 before application acceptance:** Resolve response-loan ingestion ceiling with focused evidence. Keep unresolved general-CA security issue outside acceptance claims.
3. **P2 before trusting frontend negative evidence:** Narrow exception swallowing and strengthen forbidden-approval synchronization.
4. **Next feature turn:** Test newest adapters against public fixtures, then wire existing presentation for live observation, typed false, offered recovery and exact verified download. Complete one uninterrupted N1/N8 PTY journey.
5. **Before milestone closure:** Finish remaining native negatives and continued independent review. Update full WM023–WM044/G2–G5 evidence ledger without reopening accepted work.

A pushed checkpoint records recoverable work. It does **not** accept that work, authorize deployment, or establish a completed goal.