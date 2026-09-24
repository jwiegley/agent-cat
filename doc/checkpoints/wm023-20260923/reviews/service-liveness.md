## Review

- **Correct:** New deferred outcomes distinguish an unacquired guard from entered failures. Original SQL admission remains fail-fast. Assembly and startup retain their existing deadlines.
- **Finding: P1 — Response owners reverse the established file/configuration loan order.** Concrete paths below. Correct shared owners before integration.
- **Fixed:** None. Read-only review.
- **Merge verdict: BLOCK** pending loan-order correction and focused negative checks. Latest N8 failure’s exact cause remains unproved.

### 1. Proven paths affecting preparation

#### Loan-order violation

Required order: **files → configuration → database** (`manager/STORAGE.md:28–36`).

Pending composition instead has:

| Response owner | Configuration held before file acquisition |
|---|---|
| Overview | `Overview.hs:37–38` → `readDraft` at `:70` → `Drafts.hs:504` |
| Overview / run GET | `Overview.hs:72` or `Service.hs:274–276` → `History.managedRunInView` → `History.hs:256` |
| Overview / question GET | `Overview.hs:73–74` or `State.hs:449–451` → `decisionInView` → `verifiedQuestion`, `State.hs:490` |

All paths are under `manager/src/Agentic/Manager/`.

Meanwhile, accepted assembly acquires files first (`Drafts.hs:585–588`) and can wait for configuration while retaining that loan (`Drafts.hs:834–851`).

Concrete conflicting schedule:

1. Assembly owns files.
2. Overview owns configuration.
3. Assembly postpones configuration lookup.
4. Overview attempts files and receives `StoreBusy`.

This proves **reverse-order contention and avoidable response refusal**, not deadlock: file acquisition remains fail-fast (`Store.hs:663–679`). Repeated configuration holders can exhaust assembly’s bounded wait, but source alone does not prove that happened in N8.

`Drafts.withDraft` already demonstrates correct ordering (`Drafts.hs:493–501`). Outputs use the same pattern (`Artifacts.hs:164–165`). Fix remaining owners coherently, not only Overview’s request branch.

#### Ordinary SQL contention can produce the reported cleanup shape

HTTP reads authenticate through the same fail-fast Store gate (`Authorization.hs:39–54`). Preparation can lose that gate at:

- File-loan acquisition, **before materialization callback enters**: `Store.hs:676`.
- Assembly reads: `Drafts.hs:595–597`, `:618–659`.
- Original StoreWorker resource acquisition: `Store.hs:830`.
- File-source verification: `Drafts.hs:680–684`.
- Prepared-observation publication: `Admission.hs:463–470`.

The gate uses `FailFast`, with no retry (`Store.hs:890–901`, `:1011–1016`; `Store/Admission.hs:42–47`).

Failures before prepared-observation commit enter `runEntry`’s failure cleanup, select `"worker-lost"`, then release back to draft after original cleanup is confirmed (`Admission.hs:440–505`, `:608–637`). Therefore **no admission observations, no preparations, released reservation, draft phase** is compatible with several distinct failures—including ordinary SQL contention.

That state does **not** prove failure occurred before native launch. It also does not identify Overview as culprit. Later `Approval.publishReview` failure alone would not explain absence of the earlier admission observation.

### 2. Policy judgment and native expectations

**Entered refusal must remain a surfaced preparation failure.** Do not turn it into deferred work.

Important boundary: `tryWithStoreFiles` may acquire files and then fail SQL admission before invoking its callback. That still must propagate `StoreBusy`, not become `Nothing`. Current implementation preserves this distinction.

Current postponements do not launder SQL waiting:

- `Configuration.hs:178–195`: `Nothing` only when configuration guard was not acquired.
- `Store.hs:668–679`: `Nothing` only when file guard was not acquired.
- `Drafts.hs:585–588`, `:834–851`: postponement stays inside original five-second assembly scope.
- `Worker.hs:188–203`: postponement stays inside original thirty-second preparation deadline and startup stop race.
- `Admission.hs:299–365` and `Service.hs:97–130`: only proven configuration deferral retains scheduler wake-up. Other failures are not timer-replayed.

Loan inversion is a composition defect. Independent fail-fast SQL refusal is settled policy. Correcting the former cannot guarantee absence of the latter.

**Native scenario is sound as a successful-lifecycle witness, not an unconditional progress guarantee.** `manager/test/service_http.py:149–161,195–196` treats return to draft as failure while polling concurrently. Under current policy, that can expose either a real composition bug or a permitted preparation refusal. Preserve those failures and distinguish them with owner-stage evidence; do not automatically re-enqueue or weaken assertions into “eventually succeeds.”

Other inspected expectations remain sound:

- GET-only bounded fresh observations: `:118–127`.
- Explicit, identical operator-confirmed resend: `:163–178`.
- Native prompt LF hashing: `:201–206`.
- Approval remains dispatch-attempted without effect: `:278–280`.

### 3. Minimal coherent correction

At existing owners:

1. **Overview:** acquire one original `withStoreFiles` loan before `withAuthorizedCatalogueContext`. Retain both through materialization and sending.
2. **Service.withRun:** acquire files before authorized catalogue context.
3. **State.withDecision:** acquire files before authorized response.
4. Factor existing materializers to borrow that retained root:
   - Reuse `readDraftAt`, rather than calling loan-acquiring `readDraft` beneath configuration.
   - Make `managedRunInView` use the supplied retained root.
   - Make decision materialization use private `verifiedQuestionAt`.
   - Preserve standalone `verifiedQuestion` as the loan-acquiring wrapper: answer validation also calls it (`State.hs:621`).

Use narrow internal borrowing entry points, not new public capabilities or duplicated implementations. Merely wrapping Overview in `withStoreFiles` while retaining its nested loan-acquiring calls would cause self-refusal.

Keep unchanged:

- Current authorization through real sends.
- Overview’s authorized ID/cursor/floor cut, outside-SQL materialization, final equal-cursor check, five-second/64MiB bounds.
- Fail-fast SQL, original ownership and cleanup, exact approval semantics.
- Existing timeout lengths and no-replay boundaries.

### 4. Focused negative checks required

Extend existing fixtures; no new framework needed.

1. **Ordering barrier:** hold original file loan; invoke Overview, run GET and question GET. Verify refusal occurs without taking/retaining configuration or entering response callback. Then verify normal responses retain original loans through callback completion.
2. **Real queued deferral:** enqueue actual work, hold configuration/file guard, and release within existing budget. Verify one original reservation/materialization/launch—not only empty-queue deferral.
3. **Acquisition versus callback failure:** hold SQL gate during file-loan acquisition. Verify propagated failure, not `Nothing`; callback count zero. Inject entered failures and verify callback/publication counts remain one.
4. **Deadline and cancellation:** retain contended guard beyond original five/thirty-second budget; close or cancel during postponement. Verify bounded refusal and original cleanup before reservation/root reuse.
5. **Prepublication failure:** force fail-fast refusal before admission-observation commit. Assert legitimate draft/released outcome, no fabricated preparation, no automatic mutation replay, and joined cleanup.
6. **Overview consistency/security:** concurrent commit or revocation during materialization must refuse final publication. Escaped materializers/views must fail; no mixed-cut page or authorization bypass.
7. **Native N1/N8:** rerun mixed-controls with owner-stage failure evidence, retaining strict positive lifecycle assertions and separate expected-refusal checks.

`ArtifactCheck.hs:69–101` verifies deferred classification and legacy refusal semantics, but does not exercise real preparation deadlines, these response-order collisions, or contended publication.

### 5. Residual architecture limits

Correct ordering does not establish fairness or uninterrupted execution under read traffic.

A separate, source-proved ceiling exists after approval: ingestion needs configuration through `withStoreReader` (`State.hs:62`, `Store.hs:685`). `Service.ingest` stops retrying `StoreBusy` after five seconds (`Service.hs:168–182`), then `drive` requests original preparation stop (`:142–163`). Response sends retain configuration and have **five seconds per chunk**, not five seconds total (`Transport.hs:213–223`).

Thus a sufficiently long valid response can also terminate service following. This does not explain the reported prepublication N8 failure. Treat it as an explicit liveness limitation requiring a focused held-response check—not permission to extend waits or release authorization early.

No additional ownership-safety defect proved in the new guard-result helpers. No commands, tests, Git operations, writes, or private fixture reads performed.