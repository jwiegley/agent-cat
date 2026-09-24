# Code Context

## Files Retrieved

1. `runtime/AGENTS.md` (1–9), `engine/api/AGENTS.md` (1–8): dependency and policy ownership constraints.
2. `engine/api/src/Agentic/Engine.hs` (41–150, 204–231): engine context, requests, results, conversations, lanes.
3. `runtime/src/Agentic/Exec.hs` (310–522, 610–839, 1188–1265): operational worlds, decoding boundary, scheduler, persistence, dispatch.
4. `runtime/src/Agentic/Runtime/Route.hs` (35–141): model-axis routing and lane selection.
5. `runtime/src/Agentic/Runtime/Control.hs` (94–238): commands, acknowledgements, live capabilities, recovery gates.
6. `runtime/src/Agentic/Runtime/Machine.hs` (72–166, 231–303): sequencing, durable-first events, control delivery.
7. `runtime/src/Agentic/Runtime/Protocol.hs` (190–279): typed public progress and bounded decoding.
8. `cli/src/Agentic/Cli.hs` (2137–2309, 2517–2539, 2701–2824): composition and persistence adapters.
9. `cli/ci/policies.sh` (125–149): existing focused probes.

## Key Code

Current decisive boundaries:

```haskell
startEngine :: Engine engine => engine -> EngineContext -> EngineRequest -> IO EngineConversation
runEngineTurn :: EngineConversation -> Text -> IO EngineResult
worldAskAttemptIO :: WorldIO -> AttemptContext -> SCode c -> Request c -> IO (El c)
```

Recommend one runtime-owned record, not an engine-api extension. Sketch of concrete field signatures, with existing types retained:

```haskell
data DataBroker = DataBroker
  { brokerDispatch :: forall c. WorldIO -> AttemptContext -> SCode c -> Request c -> IO (El c)
  , brokerStart :: EnginePort -> EngineContext -> EngineRequest -> IO EngineConversation
  , brokerTurn :: EngineConversation -> Text -> IO EngineResult
  , brokerControl :: Control -> IO ()
  , brokerEvents :: EventSink
  , brokerLog :: Text -> IO ()
  , brokerPersistence :: PersistenceHooks
  }

attachEngine :: Engine e => e -> EnginePort
inProcessBroker :: (Control -> IO ()) -> EventSink -> (Text -> IO ())
                -> PersistenceHooks -> DataBroker
runPlanBrokered :: DataBroker -> Maybe ControlRuntime -> Chains
                -> WorldIO -> Plan '[] a -> IO (a, ExecTrace)
worldOfEngineWith :: DataBroker -> ExecSettings -> EnginePort -> WorldIO
```

`EnginePort` is an opaque existential holding an existing engine, including lane/redaction capabilities. It is not a wire identifier. Keep its constructor private. Default implementations dispatch through `worldAskAttemptIO`, open through `startEngine`, and return the actual `runEngineTurn` result. `brokerControl` invokes the runtime-owned control handler, including acknowledgement ordering, rather than deciding policy itself.

Place this record and the existing `WorldIO`, `AttemptContext`, and `PersistenceHooks` declarations in `Agentic.Runtime.Broker`. Move declarations only, re-export existing names from `Exec`. Broker imports Plan, Engine, Control, Protocol, never Exec or CLI. Keep pure-world constructors, decoder, scheduler, and default persistence implementation in their current layers. This breaks the otherwise immediate Broker↔Exec cycle without adding a framework.

## Architecture

**High: observer substitution is insufficient.** `Exec.hs:432–446` directly opens engines; `1256–1257` directly dispatches worlds. Change both, and make `engineTurn` obtain its result exclusively from `brokerTurn`. The runtime still renders requests, decodes answers, retries conversations, classifies failures, and selects failover. Two broker entry points are intentional: dispatch carries addressed typed requests for shell/person/scripted paths too; start/turn carries actual neutral engine traffic before decoding.

`EngineConversation`, `EngineContext`, `WorldIO`, steerers, lanes, and validators remain process-local capabilities. Do not derive serialization for them or claim this API is RabbitMQ-ready. Deferred remote implementation would need explicit session/correlation protocol, not serialization of callbacks.

**High: controls and persistence must not bypass injection.** Extract `Machine.hs:283–300` control handling into a runtime helper, preserving cancellation owner, accepted/delivered acknowledgement ordering, and deferred release. Machine ingress calls `brokerControl` after frame decoding. Runtime control state remains runtime-owned. Scheduler fields derive their sink/hooks from the injected broker. Person answers already enter through typed controls and private question storage.

Default construction happens once per run in CLI after its durable/deferred sink and persistence hooks exist. Bind that same broker into engine worlds, execution, machine lifecycle events, and control ingress. Replace direct result-artifact writing at `Cli.hs:2771–2777` with an additional persistence hook matching its existing arguments/result. Existing hooks omit this persistence edge.

**Medium: logs have separate routes.** Route `esLog`, `chainLog` (`Exec.hs:1206`), shell logging (`Cli.hs:2254–2259`), and narration through `brokerLog`; route engine updates through runtime redaction into `brokerEvents`. Preserve machine mode's deliberate narration suppression. Public events are not raw engine replies. Preserve durable-first sequencing and failure propagation, rather than copying notifications beside direct execution.

## Start Here

Open `Exec.hs:431–446`, then `Cli.hs:2158–2244`. Change operational composition and `runPlanPersisted` callers first. Compatibility helpers (`runPlanIO`, `pureWorldIO`, `runPlanObserved`) can construct default brokers internally; semantic oracles need no engine attachment. `routedWorld` retains existing route/lane policy unchanged.

Smallest checks: policy-probe for memo/ordering, runtime-contract-test for protocol, control/person-control probes for deferred delivery, lineage/person-lineage probes for persistence. Their existing invocation sites are `cli/ci/policies.sh:130–149`. Add one injected-broker probe changing a returned engine answer and asserting downstream result changes, plus dispatch/log/control/persistence counters. Notification-only wrapping would fail that check.

Residual choice: whether diagnostic text gets durable/public retention is not specified. Preserve existing destinations by default; do not implicitly publish private prompts. No other semantic blocker found. Preserved service source was only scoped by filename/import search, not audited. No commands or tests run.

```acceptance-report
{
  "criteriaSatisfied": [{"id":"criterion-1","status":"satisfied","evidence":"Located direct dispatch, engine, control, logging and persistence seams with paths, ranges and severity; proposed typed runtime-owned API."}],
  "changedFiles": ["/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-seam.md"],
  "testsAddedOrUpdated": [],
  "commandsRun": [],
  "validationOutput": ["Read-only source inspection. Proposed signatures not compiled."],
  "residualRisks": ["Log retention/publication policy remains unspecified.","Live capability API is intentionally in-process, not a remote serialization protocol.","Preserved service/client implementation not audited."],
  "diffSummary": "Findings artifact only. No repository edits.",
  "reviewFindings": ["High: Exec.hs:432-446 and 1256-1257 retain direct execution unless replaced.","High: Machine.hs:283-300 and Cli.hs:2771-2777 need broker control/result-persistence paths.","Medium: existing log routes must converge without publishing private narration."],
  "manualNotes": "No Git inspection, execution, configuration access or tests performed. Baseline commit identity supplied by task, not independently verified."
}
```
