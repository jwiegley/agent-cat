# Remaining-scope roadmap for halt handoff

## Review

- **Correct:** Accepted baseline remains **WM001–WM022 and G0/G1: 22/44 packages, 2/6 gates**. Default broker and bounded TLS dependency update are already integrated. Do not rebuild these as new prerequisites. Source: `halt-20260923/brief.md:5–17`.
- **Correct:** Actual TUI submission, exact approval, and detach passed N1/N8. Full TUI observation, typed false, recovery, completion, and verified download remain unfinished. Latest observation adapters were uncompiled and unwired at cutoff. Source: `halt-20260923/brief.md:11–13`.
- **Finding — P1, carried forward:** Response-loan liveness remains unresolved. Ingestion’s five-second contention allowance can expire while response sends retain configuration across multiple five-second chunks. Ordering corrections have reported tests but lack continued independent clearance. Evidence: `service-liveness-review.md:100–120`; `broker-brief.md`, response-order and slow-response paragraphs. Smallest next step: focused held-response and ownership-boundary checks, then policy-consistent correction and independent review. Do not extend waits, weaken authorization, or replay uncertain operations.
- **Finding — P1, scoped security acceptance:** General-CA validation remains unaccepted under `acat-tls-name-forms-6gbo`. Evidence: `tls-update.md:42`, describing missing IP Name Constraints handling and unverified DNS/inheritance cases. Integrated dependency improvement remains accepted within its bounded scope. Resolve residual validation before claiming general-CA security acceptance.
- **Finding — P2, handoff scope reconciliation:** Original plan excludes a broker, sequences Emacs before TUI, and requires cross-machine/platform evidence. Current amendments instead require integrated default broker, TUI-first work, and local macOS-only validation. Evidence: `doc/research/workflow-manager-implementation-plan.md:51,78–81,192`, WM039 and WM043. Record amendments explicitly in current handoff; preserve original research plan as dated record.
- **Merge verdict: OK with notes for this roadmap.** This review does not clear application WIP for integration or accept another milestone.

Paths above outside `doc/` are relative to parent unit:
`/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/`.

## Complete end target

One locally validated macOS manager owns durable requests, captures, admission, exact approval, concurrent workers, decisions, controls, verified outputs, history, lineage, and exclusive export. Protected REST, SSE, and polling expose those same owners through the integrated default broker arrangement. TUI, Emacs, and Pi remain thin native clients with explicit service/local modes, endpoint-bound resources, honest uncertainty, and no service-mode worker ownership or duplicate interpreter.

Completion also requires bounded failure behavior, recovery and backup procedures, credential lifecycle, reproducible packages, rollback, current documentation, semantic/conformance evidence, and independent review.

**RabbitMQ and John Mark integration remain deferred follow-on work.** Neither blocks first TUI workflow nor belongs in current completion claims. Linux, external-host validation, production activation, and deployment are not current prerequisites or authorized activities.

Original G4/G5 claims that require remote/platform evidence remain qualified or open unless an explicit scope amendment changes their acceptance contract. Local results must never be labelled cross-machine evidence.

## Rules applying to every phase

1. **Halt first.** No new feature implementation during checkpoint preservation. Parent owns builds, edits, tracking, Git, publication decisions, and final report.
2. **Reuse accepted owners.** Preserve Store admission, existing budgets, cancellation authority, exact approval, registered-client idempotency, and uncertain-effect handling. No automatic mutation replay or replacement workflow interpreter.
3. **Local verification only.** Use established macOS Nix/direnv recipes, deterministic local backends, protected fixture listeners, and current source-built executables. Run relevant threaded N1/N8 checks where applicable. No paid backend, new Lean/oracle build, live configuration inspection/change, or deployment.
4. **Evidence follows source identity.** Record source/package identity, exact commands, exit results, positive and negative assertions, and limitations. Compile success is not workflow acceptance. HTTP success is not native UI acceptance.
5. **Cleanup is acceptance work.** Join original fixture handles, restore terminals, close listeners/subscriptions, and verify cleanup before resource reuse. Preserve sanitized failed-run evidence. Never copy credentials, private keys, raw databases, or arbitrary fixture trees into tracked reports.
6. **Review before closure.** Each subtask needs focused review of behavior, tests, documentation, boundary compliance, and residual risks.
7. **Mandatory downstream fess:** Run **fess at the end of every subtask**, including tests, documentation, cleanup, review, and failed or blocked attempts. Record omissions, failures, shortcuts, evidence ceilings, and remaining obligations. If skill is unavailable, record that blocker explicitly; do not fabricate execution.

Effort below means rough engineering person-days, including focused tests, documentation, cleanup, and review. Ranges overlap and are **not additive delivery promises**. Re-estimate after first uninterrupted TUI workflow and server safety review.

## Phase 0 — Preserve resumable checkpoint

**Coverage:** Halt preparation only. No new WM/G acceptance.

**Effort:** Approximately 1–3 days, depending on build and preservation findings.

- **Decision:** Identify exact checkpoint source and coherent dependency-ordered change groups. Keep uncleared application WIP separate from accepted canonical milestones.
- **Implementation:** Parent preserves current broker-source work on canonical ancestry without overlaying stale tracking files. Preserve original pre-broker delta separately. Compile newest adapters only enough to leave an honest, buildable checkpoint.
- **Verification:** Confirm current executables correspond to checkpoint source; record any failure. Do not substitute earlier binaries or claim adapter/App integration.
- **Documentation:** Preserve sanitized briefs, reviews, evidence summaries, exact remaining scope, and failures under tracked checkpoint documentation. Final report must distinguish accepted baseline, demonstrated WIP, and unverified additions.
- **Cleanup/review:** Inspect proposed publication content for secrets and unrelated changes. Preserve original failures. Parent alone handles separately authorized commits and explicit non-force branch publication.

## Phase 1 — Finish first actual TUI workflow

**Coverage:** Thin vertical subset of WM025–WM029 and WM033–WM035. Not whole-package closure.

**Effort:** Approximately 3–8 days if existing DTOs and owners hold.

- **Decisions:** Set minimal live observation/refresh path and existing typed-editor mapping. Keep approval receipt uncertainty separate from independently observed run authority.
- **Implementation:** Wire public RunSnapshot, RunControl, Decision, and Output observations into existing TUI presentation. Show actual progress; answer **Bool false**; invoke offered recovery retry; observe native terminal outcome; retrieve exact bytes through `Client.downloadVerified`.
- **Verification:** One uninterrupted real PTY journey through protected manager, default broker, and deterministic ACP fixture at N1/N8. Assert exact Unicode/prompt-byte review, explicit five-selector approval, displayed runtime state, typed false, correlated recovery effect, terminal evidence, and verified downloaded bytes. Retain separate detach/control-ownership checks.
- **Documentation:** State exact exercised path and remaining unsupported UI actions. Preserve receipt semantics and earlier failed runs.
- **Cleanup/review:** Restore terminal and join original fixture processes without treating frontend exit as run cancellation. Review client/server import boundary and absence of native authority fabrication.

**Exit:** First-frontend workflow milestone only. History, lineage, export, broader controls, and full hostile-input/reconnect coverage remain later obligations.

## Phase 2 — Complete protected API and server safety evidence

**Coverage:** WM023–WM028; G2 and server-side prerequisites for G3.

**Effort:** Approximately 8–20 days; liveness/security findings may expand range.

| Package | Remaining implementation and meaningful local verification |
|---|---|
| **WM023 — Credentials and authorization** | Audit complete local administration, expiry, rotation overlap, revocation, profile scopes, retained receipts, pages, streams, and downloads. Test rotation preserves registered-client idempotency; revocation fences later intents and reads without cancelling owned work. Verify worker environments and incidental diagnostics exclude synthetic secret markers. |
| **WM024 — Protected HTTP boundary** | Complete limits and refusal coverage over real verified TLS: Host, Origin, preflight, forwarded authority, cookies/query tokens, duplicate JSON fields, depth/body/header limits, redirects, slow input, and decompression where supported. Resolve general-CA acceptance scope explicitly. No plaintext bearer or hostname-verification bypass. |
| **WM025 — Read resources** | Finish complete catalogue/help, request/history/detail/Overview, snapshot/control/decision/output, artifact and export observations against frozen API. Verify consistent cuts during concurrent commits, actual page lifecycle, expired/scoped tokens, aggregate bounds, private-field redaction, and verified bytes through actual send callbacks. |
| **WM026 — SSE and polling** | Verify snapshot attachment races, partial blocks, filtered cursors, retained-floor eviction during open streams, ordinary restart alias stability, restore invalidation, subscriber limits, revocation, and slow-reader coexistence with workers. Exercise polling against same cursor rules. |
| **WM027 — Mutation routes** | Audit every frozen operation, not only successful mixed-controls path: draft edits, captures, enqueue/withdraw, preparation approval/discard, all supported controls, exports, and lineage. Test scope, same-resource ETag, exact retained command, stale/conflicting input, FIFO races, lost replies, and crash boundaries. Reject arbitrary roots, argv, and environments. |
| **WM028 — Security/failure gate** | Assemble real TLS adversarial matrix covering every enabled route. Include two-client races, synthetic redaction markers, capture/export boundaries, disk/storage failure, worker death, ordinary restart, and older-backup authority fencing. Preserve unknown failure causes rather than attributing them to later fixes. |

**Open decisions**

- Resolve response-loan liveness within settled policy. Required checks include held-response ingestion, real queued deferral, acquisition versus callback failure, deadline/cancellation, prepublication refusal, concurrent-cut invalidation, and escaped views.
- Establish how to demonstrate **G2 with mutations unavailable**, despite controlled mutation fixtures already existing. Do not claim historical gate order from current endpoint presence.
- Confirm page retirement and public cursor-alias choices as documented implementation choices, not retroactive frozen requirements.
- Review explicit version-domain amendments with integration; do not relabel supported native observations into older schemas.

**Documentation:** Update current API/version/scope matrix, bounds, page/cursor choices, refusal behavior, and liveness/security limitations.

**Cleanup/review:** Preserve original Store/file/configuration owners through sends, without retaining SQL transactions over network waits. Obtain independent continued review of corrected loan ordering and unresolved liveness/security cases.

**Exit:** G2 only after protected observation contract passes with mutation routes unavailable. G3 additionally needs WM040 and applicable WM041 evidence.

## Phase 3 — Finish shared client contract and full TUI service mode

**Coverage:** WM029, WM033–WM035. TUI precedes Emacs.

**Effort:** Approximately 6–14 days beyond first-workflow slice.

| Package | Remaining implementation and meaningful local verification |
|---|---|
| **WM029 — Shared client facade** | Complete endpoint-bound references, capabilities, strict DTOs, complete bounded pages, event/poll parsing, private pending commands, refresh serialization, dirty coalescing, generation fencing, and reconciliation. Shared language-neutral vectors must cover false/null, precision, Unicode, partial SSE, expiry, revocation, delayed responses, endpoint changes, and no credential forwarding across origins. |
| **WM033 — Explicit TUI backend** | Finish narrow public-facade integration and capability/refusal states. Verify service mode never starts local workers, opens manager files, falls back to local launch, or retargets old references after endpoint changes. Preserve local backend and import fixtures. |
| **WM034 — Full TUI lifecycle** | Complete captures, queue/blocking state, concurrent runs, decisions, supported controls, outputs, history, lineage, and export. Reuse existing editors/renderers. Preserve drafts/focus across refresh; distinguish accepted cancellation, terminal state, cleanup, verification, and uncertainty. |
| **WM035 — Native acceptance** | Real keyboard journeys at **40×12, 80×24, and 140×36**, including resize, reconnect, expired pages, stale answer, manager restart, revoked credentials, delayed responses, terminal escapes, and endpoint switching. Include local-mode regressions and a negative check proving broken service interaction fails acceptance. |

**Decisions:** Document approved TUI-first ordering instead of retaining WM033’s original Emacs-acceptance scheduling dependency. Preserve shared semantic/client-contract dependencies.

**Documentation:** Explicit service profile, supported transports/actions, uncertainty/recovery behavior, endpoint identity, local coexistence, and keyboard paths.

**Cleanup/review:** Cancel/join frontend transport jobs only; prove service work survives UI closure. Review absence of a duplicated runtime model and complete keyboard accessibility.

## Phase 4 — Emacs service mode

**Coverage:** WM030–WM032.

**Effort:** Approximately 7–15 days, contingent on supported local Emacs environment.

- **WM030:** Add endpoint-bound asynchronous HTTP, private credential lookup, bounded typed decoding, generation-fenced refresh, and safe cleanup. Decide supported SSE transport using actual environment evidence; use explicit bounded polling if SSE cannot meet requirements.
- **WM031:** Wire existing catalogue/setup/review/run/decision/control/result/history/lineage/export interfaces to manager resources. Preserve editor contents, independent windows, local mode, and endpoint-bound historical references.
- **WM032:** Run ERT, warning-free byte compilation, checkdoc, and actual keys/buffers/windows at three terminal sizes against local protected manager and deterministic workers. Exercise reconnect, stale editors, resize, multiple runs, typed values, recovery, verified results, and terminal restoration.

**Documentation:** Minimum tested versions, selected transport, credentials, mode selection, and local/TRAMP compatibility.

**Cleanup/review:** Closing buffers or Emacs must not cancel service runs. Verify no token exposure or manager filesystem access. External-host TRAMP evidence remains unavailable, not a prerequisite silently imposed on local work.

## Phase 5 — Pi service mode

**Coverage:** WM036–WM038.

**Effort:** Approximately 7–16 days, contingent on owner and local host availability.

- **WM036:** Coordinate source ownership. Add endpoint-bound session/transport using shared vectors. Keep credential retrieval in trusted extension code; exclude remote resources from local worker, restore, and pruning ownership. Current-session and client-owned-child engines remain explicit local-only targets.
- **WM037:** Wire native lifecycle UI and tool-mediated controls. Preserve project-trust, user-grant, and tool-authorization checks independently of server authorization. Never trust a grant field supplied by model/tool input.
- **WM038:** Run TypeScript/unit/integration checks and actual local host UI against protected deterministic fixtures. Test human/model paths separately, denied and consumed grants, reconnect/reload, credential changes, complete lifecycle, and local-mode compatibility.

**Decisions:** Supported host/package versions and owner-approved integration surface. No remote engine connector.

**Documentation:** Service capabilities, local-only engine exclusions, grant rules, and tested host versions.

**Cleanup/review:** Distinct local/manager roots, including partial directories without manifests. Prove startup/pruning cannot alter manager entries. No production extension activation or John Mark integration.

## Phase 6 — Cross-client, conformance, capacity, and fault closure

**Coverage:** WM039–WM041; remaining G3/G4 obligations.

**Effort:** Approximately 8–20 days for locally executable matrix. Formal completion remains separately constrained.

- **WM039 — Cross-client:** On same macOS host, use actual TUI, Emacs, and Pi processes with distinct fixture credentials. Create in one, approve/answer in another, observe in third; race decisions, disconnect all presentations, reconnect, rotate/revoke credentials, restart/restore, and verify outputs/history/lineage over TLS. Exercise SSE and polling. This establishes local cross-client evidence, **not original second-machine acceptance**.
- **WM040 — Conformance:** Complete representation mapping, pinned manager-history encoding, valid/refused transition comparisons, retained counterexamples, and direct-versus-managed semantic checks. Preserve frozen workflow corpus. Record exact theorem statements, axiom footprints, assumptions, and physical-boundary exclusions. Use only compatible prebuilt artifacts if available; no new Lean/oracle build under current constraints. Missing fresh proof/oracle evidence remains explicit and prevents unqualified G3 closure.
- **WM041 — Capacity/faults:** Publish local workloads and memory/latency ceilings before measuring. Cover reservations, drafts, uploads/captures, readers, page memory, events, ledger growth, SQLite checkpoints, slow consumers, disk-full/busy/I/O errors, root replacement, pipes, worker/manager death, delayed refresh, backup interruption, and safety-path availability. Start deterministic barriers first; retain seeds for later schedule tests.

**Decisions:** Separate applicable pre-G3 safety/bounds evidence from final integrated-client matrix. Decide whether formal-build authorization or gate-scope amendment will be sought later; do not silently waive it.

**Documentation:** Requirement/evidence matrix with source identities, local platform limits, unavailable checks, and counterexamples.

**Cleanup/review:** Reuse existing fault harnesses. Verify containment or quarantine before reuse. Independent review must reject throughput results that conceal ownership/security failures.

## Phase 7 — Operations, packaging, rollback, and final handoff

**Coverage:** WM042–WM044; G5 readiness.

**Effort:** Approximately 6–14 days after integrated candidate stabilizes.

- **WM042 — Operations:** Complete documented local profile validation/reload, provisioning/rotation/revocation, drain/cancel, offline backup/restore, and quarantine inspection/release. Require current cleanup evidence for release. Add bounded protected operational diagnostics, distinguishing readiness/liveness, ingestion, unresolved commands, verification, retention, quotas, and checkpoint pressure. Have another operator exercise fixture procedures, including failure paths.
- **WM043 — Packaging/rollback:** Reproduce macOS artifacts through established project packaging; record source/package identities and dependency patch inclusion. Test supported schema upgrades and newer-schema refusal. Exercise drain/cancel rollback to explicit local clients with compatible read-only history. Never transfer live ownership, downgrade databases silently, or rewrite native manifests. Reference service/TLS configuration remains documentation or package assets, not installed infrastructure.
- **WM044 — Documentation/review:** Update manual, public inventories, API/version matrix, client docs, runbooks, and handoff. Preserve design/research records. Assemble every package and scenario against fresh appropriate evidence. Complete independent architecture/correctness and security/failure review; fix findings and rerun owning checks.

**Documentation gates:** Applicable prose, link, schema/example, public inventory, and Haskell documentation checks through approved environment recipes. Report unavailable checks.

**Cleanup/review:** No placeholder routes, mock production paths, disabled checks, unexplained schema changes, secret artifacts, or unrecorded evidence gaps. Deployment remains separately authorized operator action.

## Gate accounting and unresolved coverage

| Gate | Required disposition |
|---|---|
| **G2** | WM023–WM026 accepted against protected observation with mutations unavailable. Existing partial HTTP successes are evidence inputs, not closure. |
| **G3** | G2 + WM027/WM028 + WM040 + applicable WM041 safety/capacity evidence. Liveness, security, and unavailable conformance evidence remain explicit blockers to unqualified acceptance. |
| **G4** | Complete native TUI, Emacs, Pi and local cross-client acceptance. Original cross-machine requirement remains unverified unless explicitly amended; do not call loopback equivalent. |
| **G5** | Operational/failure evidence, reproducible local packages, rollback, documentation, independent review, and upstream gates. No unqualified original G5 claim while required proof/platform/remote evidence is missing. |

**Coverage inventory:** All remaining **WM023–WM044** and **G2–G5** addressed. No package or gate closed by this proposal.

**Unverified or deferred:** Full post-cutoff TUI lifecycle; newest adapter compilation; application integration clearance; complete endpoint/negative-test matrix; response liveness; general-CA validation; downstream native clients; formal bridge execution; full local capacity/fault matrix; operations/rollback; original remote/Linux claims; RabbitMQ and John Mark integration.

Only supplied plans and reports were inspected. No source-diff audit, raw-log verification, commands, tests, Git operations, edits, private-store inspection, or deployment performed. Earlier reports contain superseded status paragraphs; latest halt brief governs cutoff state.