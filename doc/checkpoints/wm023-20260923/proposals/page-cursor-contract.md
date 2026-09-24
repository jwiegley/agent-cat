# Code Context

## Files Retrieved

All source paths relative to `broker-source/`.

1. `doc/research/workflow-manager.md:554-560,710-719,743-805`: consistent materialization, durable identity, view binding, replay and bounds.
2. `doc/research/workflow-manager-implementation-plan.md:780-790,817-863`: WM-025/026 obligations.
3. `doc/api/openapi.yaml:1971-1978,2234-2269,5331-5357,5404-5437,7340-7363`: cursor, page, snapshot, batch and request contracts.
4. `manager/src/Agentic/Manager/Authorization.hs:24-75,77-202`: possession proof, authorized observations and stable facts.
5. `manager/src/Agentic/Manager/Store.hs:76-87,671-764`: separate identities, reader/configuration/watch loans and fail-fast acknowledgement.
6. `manager/src/Agentic/Manager/Credentials.hs:54-64,157-161`: durable authorization revision updates and current administration invalidation.

## Key Code

Existing `StoreIdentity` separates `storeAuthorityEpoch`, `storeStreamId`, and `storeProcessGeneration`. `AuthorizedView` privately retains watch, observation action and bound facts. `revalidateAuthorizedView` compares newly observed facts with that binding. Global catalogue facts include generation, epoch, credential/client IDs, authorization revision, expiry/cutoff, ordered scope rows and selected profile revisions (`Authorization.hs:137-149,174-198`).

## Architecture

### 1. Cursor binding

**High: raw durable-stream-plus-sequence alone cannot satisfy view binding.** The same database position can exist before and after a permission change. Checking only current permissions does not prove which view issued an incoming cursor. Event notification is neither sufficient nor necessary for that distinction.

Frozen requirements demand the result, not a particular encoding mechanism: opaque stream/sequence, view authorization version, epoch checks, restart-stable stream identity (`workflow-manager.md:712-719,776-781`; `openapi.yaml:1971-1978`). No binding registry or prescribed extra cursor field appears in these contracts. Existing observation owners provide binding facts and live revalidation, **not yet a public cursor binding**. Current credential revocation happens to emit `service.changed` (`Credentials.hs:54-64,157-161`), but do not depend on that event to encode authorization history.

**Recommendation: a view-specific public stream alias conforms as an opaque encoding of the durable stream within that authorized view.** Keep durable stream ID unchanged. Derive the public prefix deterministically from a versioned, unambiguous encoding of durable stream ID, authority epoch and stable authorization facts. Use existing SHA-256 support for a fixed-width identifier fingerprint, not an authentication claim. Never expose the raw fact vector. Keep prefix within 128 permitted ASCII characters. Apply the same alias to snapshot cursor, oldestCursor and every event/batch cursor.

Exclude process generation and transient watch counters. They fence in-process proofs, not restart-stable public identity. Retain credential/client, durable authorization revision, grant facts and relevant configuration revisions plus expiry/cutoff where those define the view. A new durable authorization revision must distinguish revoke/regrant even when effective grant sets return to their prior values.

Minimal representation: private `CursorBinding` with distinct durable-stream, epoch, stable-view and public-prefix fields, plus `EventCursor PublicStreamAlias Word64`. Add a narrow Authorization accessor for the stable binding from the **already acknowledged observation**, rather than exporting or later resampling `[Text]`. Do not create the binding by dropping a positional list head outside Authorization.

Authenticate first. In each bounded batch read, compare supplied prefix with current binding and atomically check floor/high-water with event selection. An authenticated view mismatch requires 410/resnapshot. Independently revalidate before protected delivery and during streaming. Alias possession confers no authority. Snapshot contents and both cursors must share one authorized database boundary (`openapi.yaml:5428-5437`).

### 2. Page-set lifecycle

**Medium: terminal-delivery retirement is genuinely unspecified.** Contracts define two *active* sets/client, 60-second lifetime, global bound, consistent pages and expired-token 410. They do not define consumption, acknowledgements, repeat-page guarantees, or when completed sets cease being active (`workflow-manager.md:554-560,795-801`; WM-025:827-838; `openapi.yaml:2234-2269,7340-7350`). Nothing requires every successful one-page poll to occupy a slot for 60 seconds.

**Recommended minimal policy, explicitly an implementation choice:** reserve client/global capacity before materialization. Hold immutable materialization and byte charge while continuation or delivery remains active. Release a single-page set after its response writer completes. Release a multipage set after sequential final-page delivery completes. Do not release merely because a terminal page was selected: already-running responses must retain their byte charge until their sends finish. No additional acknowledgement endpoint is needed.

For nonterminal success, retain the same revision, bytes, cursors and absolute expiry for subsequent pages. Never rebuild later pages from current state. On construction refusal, release reservations and return explicit failure. On authorization failure, expiry or transport abort, invalidate the set and release resources once outstanding sends unwind. Retired continuations require 410/fresh snapshot, never replacement content under an old token. Successful server write cannot prove client receipt: terminal-response loss therefore resnapshots. Repeat-token guarantees are not specified, so document this choice rather than claim it is frozen behavior.

Minimal owner: bounded page-set table plus exception-safe reservation/release and scoped send references. Preserve existing fail-fast Store admission and one reader/configuration/watch response loan (`Store.hs:671-741`). Retained immutable sets must not retain SQL transactions or live response watches between requests. Each continuation gets explicit current authorization validation. No widened waits, action replay, hidden truncation or new interpreter.

## Start Here

`manager/src/Agentic/Manager/Authorization.hs:106-149,174-198`: expose stable binding from the same observation that materializes the public response. Then implement the bounded response/page owner using the retirement policy above.

```acceptance-report
{
  "criteriaSatisfied": [{"id":"criterion-1","status":"satisfied","evidence":"Source-cited findings distinguish mandatory cursor binding from unspecified page retirement and give concrete minimal representations."}],
  "changedFiles": ["/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/page-cursor-contract.md"],
  "testsAddedOrUpdated": [],
  "commandsRun": [],
  "validationOutput": ["Read-only source/spec inspection completed. No commands, tests, Git operations, credential-file reads or source edits performed."],
  "residualRisks": ["Early page retirement and abort-to-resnapshot semantics are implementation choices, not stated lifecycle requirements.","Binding encoding must exclude process generation while retaining durable authorization revisions and using the same snapshot boundary."],
  "noStagedFiles": true,
  "diffSummary": "Findings artifact only. No source changes.",
  "reviewFindings": ["High: doc/api/openapi.yaml:1971-1978 requires view/epoch checks that raw durable-stream plus sequence cannot encode alone.","Medium: doc/api/openapi.yaml:2234-2269 leaves terminal page retirement and repeat-token guarantees unspecified."],
  "manualNotes": "noStagedFiles means this scout staged nothing. Repository staging state was not inspected, as instructed. No runtime verification claimed."
}
```
