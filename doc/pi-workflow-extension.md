# First-class agent-cat workflows in Pi

Status: implemented; full local verification green; independent review and completion audit approved
Date: 2026-08-28

## Decision

Build the product as a **Pi extension that acts as agent-cat's control plane**. Keep workflow meaning, scheduling, memoization, routing, decoding, and ACP execution in agent-cat. Use Pi's public extension API for discovery UI, argument collection, monitoring, persistence references, and user controls.

The smallest coherent product needs one narrow addition to agent-cat: a versioned, structured runtime event stream. A bidirectional control channel can follow once whole-run cancellation has proved the monitor. Pi itself does **not** need an upstream change for the first useful release.

Do not port agent-functor's Brick TUI into Pi, reinterpret an agent-cat `Program` in TypeScript, or make Pi own a second workflow scheduler. Those approaches duplicate the abstractions this integration should expose.

The resulting division is:

- **agent-cat owns what a workflow is and how it executes**;
- **the extension owns how a Pi user discovers, starts, watches, and controls a run**;
- **Pi owns the interactive shell, current conversation, extension lifecycle, and TUI primitives**;
- **ACP adapters, Pi child sessions, or a live external session own agent turns**.

## Implementation reconciliation

The full Option B roadmap was subsequently implemented. The pre-implementation feasibility classifications below remain useful as design history, but the delivered surfaces are now:

- agent-cat protocol/store version 1 with strict bounded NDJSON events, lossless output splitting, pre-decode ACP frame limits, controls, typed answer state, effect journal, checkpoints, ownership, and immutable lineage;
- `machine`, `machine-restart`, `machine-resume`, and `machine-fork`, all using `Program -> Plan -> runPlanPersisted -> WorldIO` (the compatibility path remains `runPlanWith`);
- correlated cancel and timing-distinct steering, runner-offered retry/failover/abandon recovery, and scheduler-reserved redirect, with steering provenance and durable non-replayability;
- `ext-pi/`, providing ordered trusted multi-runner discovery, exact help/plan, private inputs, scripted/ACP/deck/current/owned/discovered-remote targets, supervision, live/status surfaces, detailed terminal references, acknowledged controls, retention, and cross-session reconstruction;
- project-trust checks and one-time scoped `/workflow-grant` tokens gate every model-initiated mutation; the generic tool can start, restart, resume, fork, inspect, and control runs;
- `lineage-check` performs runner-owned compatibility and fork-edit preflight using private preview inputs before the extension creates a child run directory; restart/fork do not require a checkpoint, resume does, and fork supports multiple answer drops/replacements plus `/workflow-diff`;
- the required Pi deltas: optional protocol `attach.mode` with cross-connection exclusive enforcement, `follow_up` as a timing-distinct operation, `RemoteSession.discover` over the authenticated client transport, and a correlated exclusive `ExtensionAPI.startTaskTurn` handle for the current session. Legacy attach remains shared; no generic workflow framework was added.

Deterministic fixture coverage lives in `cli/test/PolicyProbe.hs`, `test/{lineage,control}_probe.py`, `engine/acp/test/*_adapter.py`, `ext-pi/test/`, and the focused Pi package suites. The inspectable user-flow and executable verification matrix is `doc/tmux-option-b-verification.md`. No paid model call is required. Pause/unpause, nested workflow semantics, a generic workflow framework, and Pi-conversation fork as a workflow operation remain intentionally absent.

## Scope and evidence baseline

This report examines:

- `~/src/agent-functor` at `828043c`;
- `~/db/pi` at `4e4949299`, package version `0.84.3`;
- agent-cat at `5540d80`, which is also the starting point of this repository's `pi-ext` branch.

At the report baseline, sibling checkouts contained unrelated working-tree changes and were read only. Implementation later modified only the narrowly listed Pi APIs in `~/db/pi`; `~/src/agent-cat` and `~/src/agent-functor` remained read only. Material claims below cite source paths and symbols rather than line numbers, because symbols survive ordinary edits better.

“Dynamic workflow discovery” here means discovery from one or more currently configured agent-cat runner binaries. Agent-cat workflows are Haskell values linked into a runner; there is deliberately no runtime workflow-file format.

## Executive feasibility summary

The desired product is feasible, but not all of it is available at the same layer today.

### Available without upstream changes

Pi already supplies:

- extension commands with descriptions and dynamic argument completion;
- dynamically registered tools with TypeBox schemas and streaming updates;
- custom full-screen components, overlays, widgets, status, headers, footers, and transcript renderers;
- lifecycle, message, turn, and tool events;
- current-session steer/follow-up delivery and abort;
- user-command-driven new, fork, tree, and session-switch operations;
- extension state entries in the session;
- public SDK construction of additional `AgentSession`s;
- RPC/JSON subprocess modes suitable for extension-owned child agents.

Agent-cat already supplies:

- a reusable registry and CLI;
- stable `list --json` and `plan --json` discovery surfaces;
- names, blurbs, static folds, named text inputs, run facts, pins, costs, and raw program output;
- human help pages;
- a concurrent, memoizing interpreter;
- ACP, agent-deck, scripted, shell, route, and failover execution;
- an in-memory `ExecTrace` with authored request, dispatched target or reuse, and typed answer.

These are enough for catalogue browsing, argument collection, launch, text-log monitoring, terminal state, and whole-process abort.

### Requires a small agent-cat runtime hook

A first-class step monitor requires agent-cat to publish structured operational events while `runPlanWith` executes. Current CLI output is prose, memo hits intentionally print nothing, and the full `ExecTrace` appears only after the blocking interpreter returns.

Steering, manual redirect, graceful step cancellation, and auditable recovery require a correlated control channel into the same runtime. They should extend agent-cat's existing operational seams (`WorldIO`, `ExecSettings`, `Recovery`, `AnswerSource`) rather than alter `Plan` or its denotation.

### Requires durable agent-cat execution state

Workflow resume, semantic restart, and workflow fork require a persisted answer/memo/checkpoint store plus a program fingerprint. Pi session forking is not workflow forking, and process restart from the beginning is not resume.

### Requires a Pi service or an extension-owned bridge

The extension can own child Pi sessions today through the public SDK or RPC subprocesses. It cannot safely adopt and control arbitrary already-running Pi TUI sessions through the ordinary extension API.

Pi has experimental remote-session packages—`@earendil-works/pi-client`, `@earendil-works/pi-server`, and `@earendil-works/pi-coding-agent/client`—but `packages/server/README.md` explicitly says the server is experimental and provides no standalone coding-agent service. It is a future integration path, not an MVP dependency.

## What agent-functor currently does

Agent-functor is useful as a behavior inventory, not as the architecture to copy. Its key surfaces are concentrated in `src/Agent/Run.hs`, `src/Agent/Mcp.hs`, `src/Agent/Persist.hs`, and `src/Agent/Tui/*`.

### Catalogue, arguments, and offline inspection

`Agent.Run.Workflow` contains:

- `wfName` and `wfDescription`;
- an optional default input;
- a deny-by-default `Grant` for `Exec` leaves;
- an optional fan-out concurrency cap;
- trigger-input policy;
- a typed `Flow Text Text`.

`workflow`, `workflowG`, `workflowReq`, and `workflowGReq` distinguish defaulted from required input. The workflow list is linked into the runner passed to `passMain`; it is not loaded from configuration.

One skeleton fold feeds:

- CLI `list` summaries;
- interactive list/table views;
- `plan`;
- `cost`;
- MCP `WorkflowInfo`;
- prompt/exec/ask counts;
- worst-case cost, bounds, node count, world-acting status, input requirement, and concurrency.

The MCP catalogue in `Agent.Mcp.catalogue` exposes one sanitized tool per workflow plus `status`, `output`, `cancel`, `runs`, `plan`, and `cost`. Each workflow tool has the same generic runtime fields—input, cwd, backend, sandbox, approval policy, gate answer, concurrency, and timeout. Agent-functor does not support arbitrary workflow-specific typed arguments.

### CLI and browser

`Agent.Run.passMain` exposes:

- `list`;
- `plan`;
- `cost`;
- `backends`;
- `doctor`;
- `run`;
- `mcp`;
- `runs`;
- `resume`;
- `fork`;
- `diff`.

On a terminal, `list` opens `Agent.Tui.Flows.runFlowsTui`. It can switch between workflow list, workflow table, and recorded-run lineage; filter by fuzzy text and status; show archived runs; launch a workflow; resume or fork a run at a named leaf; and archive a run. Piped `list` and `runs` use stable textual output.

### Live dashboard

`Agent.Run.runLive` runs the interpreter on a background thread and feeds `Agent.Tui.Live.UiMsg` into `Agent.Tui.App.runLiveTui`. `Agent.Tui.Live.reduce` is a pure event reducer; Brick is confined to the app layer.

The dashboard provides:

- one row per dynamic leaf execution, keyed by flow ID rather than label;
- pending, running, done, failed, and cached states;
- structural order with dynamic fan-out expansion;
- per-flow backend/model labels;
- selected-flow input, streamed output, reasoning, and todo panels;
- flow list, hidden-list, and flow-tree layouts;
- elapsed time, progress, token estimate, and animated state;
- bounded in-memory windows with spool-backed output scrollback;
- generated run titles;
- nested sub-flow rows from another process;
- queued text, confirmation, permission, and recovery modals.

Its key controls are:

- `s`: interrupt the selected active ACP turn and converse on the same session;
- `b`: queue a note for the next turn boundary;
- `a` / `d`: allow or deny a permission request;
- `r` / `f` / `a`: retry, fail over, or abandon after exhausted turn recovery;
- `q`: quit and cancel the run;
- navigation and panel toggles for input, reasoning, todos, compact/tree view, help, and scrollback.

`Agent.Run.interactiveTurn` is the important steering implementation. Each active flow has its own `TChan SteerMsg`. Interrupt steering sends ACP `session/cancel`, waits for a grace period, records the operator's text, and continues on the same session. Boundary notes do not cancel the current turn. The code explicitly preserves simultaneous and queued messages in oldest-first order.

Nested flows are visible but not steerable. `Agent.Tui.Live.nestedWire`, `Agent.Run.withNestedSink`, `stepNested`, and `watchNested` transport a deliberately partial `UiMsg` stream through NDJSON files, remap child flow IDs, and attribute each child through its directory path. Modal-bearing events cannot cross this wire. Nesting is bounded at depth one.

### Inline and headless modes

The three execution presentations are intentionally unequal:

- `runLive`: Brick dashboard, per-flow events, steering, human gates, permission and recovery modals, durable CLI recording;
- `runInline`: textual transcript and final graph/artifact, stdin gates, no live steering, durable CLI recording;
- `runHeadless`: textual transcript plus limited nested UI events, unattended gates and permissions, no steering, and no durable leaf/run store.

This asymmetry matters. Agent-functor has not yet unified its rich TUI control plane with its MCP control plane.

### MCP run supervision

`Agent.Run.runMcpMain` serves JSON-RPC over stdio and redirects stray stdout to stderr. A workflow tool call validates and starts a background run, returning a process-local `run-N` immediately.

The in-memory `Registry` and `RunState` support:

- status and elapsed time;
- completed-leaf count against a static floor;
- transcript delta since the previous status poll;
- bounded transcript tail and full log path;
- final artifact or failure;
- unattended approval decisions;
- current-process run listing;
- asynchronous cancellation;
- a four-hour default timeout;
- same-directory exclusion for concurrent unsandboxed runs;
- bounded terminal history.

MCP does **not** expose steering, retry/failover choice, resume, fork, reroll, set, diff, archive, or persistent cross-server run discovery.

### Persistence, resume, and fork

CLI runs use `Agent.Persist`:

```text
.agent-functor/runs/<run-id>/
  run.json
  journal.ndjson
  leaves/<key>.json
  sessions/<key>.json
```

`RunRecord` carries configuration, status, lineage, branch, input, and final run graph. `LeafEntry` carries content key, name, kind, input, raw output, steering messages, and duration. `SessionEntry` records an in-flight ACP session.

`recordLeaf` replays prompt and ask leaves through their current decoder but always re-executes `Exec`. Content addressing discovers downstream invalidation naturally; there is no dependency-cone algorithm.

- `resume` copies the parent store unchanged and creates a new child run;
- `fork --at` and `--reroll` drop matching leaf recordings;
- `fork --set LEAF=FILE` substitutes an output;
- `diff` compares recorded leaves;
- interrupted sessions are opportunistically reloaded when the backend, key, and cwd still match.

MCP runs write transcripts under a similar directory but deliberately do not create recoverable `RunRecord` or leaf state. Their registry disappears on server restart.

### Containment and permissions

Agent-functor has two permission planes:

- workflow `Exec` is constrained by `wfGrant`, deny by default;
- ACP agent tool requests are controlled by run permission policy.

At the analyzed source revision, CLI execution edits in place by default and `--sandbox` opts a world-acting run into a git worktree. MCP can request sandboxing, and triggered sub-flows force it. This source behavior is authoritative even where older shorthand says all world-acting flows isolate automatically.

### Lessons worth carrying forward

Carry forward:

1. A pure event reducer separated from TUI rendering.
2. Run-local occurrence IDs; labels are not unique under fan-out.
3. Structured start/chunk/done events rather than terminal scraping.
4. Bounded in-memory output plus durable logs.
5. Explicit control acknowledgements and visible undeliverable steering.
6. Separate authored request from actual dispatched backend.
7. Persisted lineage and immutable parent runs.
8. Honest distinctions among replay, re-execution, and reproduction.
9. Separate workflow command grants from agent tool permissions.
10. Cleanup on every success, failure, cancellation, and shutdown path.

Do not carry forward:

1. A second TUI inside Pi.
2. CLI-only persistence paired with MCP-only async control.
3. Process-local run IDs as durable identity.
4. A control surface that varies silently by presentation mode.
5. Static-leaf totals presented as exact dynamic totals.
6. Steering that affects replay without explicit provenance.

## What agent-cat already provides

Agent-cat's operational half is split across `dsl/`, `plan/`, `cost/`, `runtime/`, `engine/`, and `cli/`. These enforced seams are a better integration foundation than an agent-functor port because semantics, execution, transport, and composition are separate packages.

### Program and registry

`Agentic.Builder.Program` pairs:

- `progRawOut :: RawProgram`, the printable/specification-facing representation;
- `progPlan :: Plan '[] ()`, the typed executable representation.

`Agentic.Workflow.workflow`, `defining`, and ordinary Haskell authoring build that one paired value. A Pi extension must not parse or reinterpret `RawProgram`; agent-cat's own `Plan` remains the executable authority.

`Agentic.Cli.Registry` is an exposed value containing named `Row`s. Each `Row` contains:

- a fixed or parameterized program;
- one-line documentation;
- a full human help page;
- scripted replies.

`cli/run/Main.hs` is only `cliMain examplesRegistry`. A downstream runner can apply the same CLI to another registry, which is how the private workflow toolbox already works.

### Discovery and argument metadata

`Agentic.Cli.listCmd` and `planCmd` expose a deliberately stable machine interface.

`list --json` supplies, per workflow:

- name and blurb;
- level;
- size and ask-node count;
- minimum/maximum fold and path count;
- ordered operator input descriptors (`name` plus `prompt`, `command-tail`, or `stdin` source);
- runner-supplied run facts;
- model pins.

`plan NAME --json` adds answer codes and the path-by-path fold. `--raw` also adds the built `RawProgram`.

`help NAME` prints authored prose explaining input meanings, useful transport choices, example invocations, rehearsal, and caveats. Help intentionally has no JSON form.

`Agentic.Workflow.Parameterized`, `taking`, and `InputSpec` keep every operator argument as required named text while recording its preferred source. `input "name"` remains ordinary prompt/file input; `argsInput`/`argsInputAs` declare one raw command-tail value; `stdinInput`/`stdinInputAs` declare one literal standard-input value. Descriptor v2 publishes these records; the extension upgrades descriptor-v1 string inputs to prompt sources. Parameterized Haskell may choose program shape from values, so the extension still obtains the final raw-program fingerprint with actual inputs before launch.

This is already enough for a Pi launch wizard:

- discover names from `list --json`;
- display help verbatim;
- prompt once for each ordered input;
- offer routes only for advertised pins;
- show plan/cost before spending.

### Interpreter and answering-service seam

`Agentic.Exec.WorldIO` is the runtime adapter boundary:

```haskell
data WorldIO = WorldIO
  { worldAskIO :: forall c. SCode c -> Request c -> IO (El c)
  , worldTurnLane :: forall c. SCode c -> RequestShape c -> Maybe TurnLane
  }
```

`runPlanWith` remains the scheduler and interpreter. It:

- walks the fixed plan spine;
- starts dependency-ready asks concurrently;
- waits only for the de Bruijn values each expression uses;
- reserves duplicate reusable questions atomically;
- bypasses memoization for effects;
- preserves plan-order traces through tickets;
- uses ordered lanes for effects and stateful transports;
- selects only the reached case arm;
- cancels workers when one unrecovered exception escapes.

Scripted, ACP, agent-deck, shell, routing, and failover behavior all plug in below this boundary.

### Existing operational identity

`Agentic.Plan.Request` contains the authored `Q` and an `Intent` (`Consult`, `Observe`, or `Effect`). `Agentic.Plan.ExecEvent` contains:

- the authored request;
- `AnswerReused` or `AnswerAsked dispatchedQuestion`;
- the typed answer.

This distinction is exactly what manual redirection needs. A manual target change should alter the dispatched question and operational history while preserving the authored request and denotation.

It also provides the right home for a future steering record: steering is execution provenance, not a new `Plan` constructor and not part of question identity.

### Engines and routing

`Agentic.Cli.runCmd` drives the same `Program` through:

- a scripted answer table;
- one or more ACP adapters owned by the run;
- one or more existing agent-deck sessions;
- shell execution for `toolExec` observations/effects;
- model-pin route tables and failover chains.

`Agentic.Acp` brackets process, handshake, session, prompt, permissions, cancellation on close, and adapter teardown. The default is a fresh ACP session per question. Permission follows request intent: only `Effect` grants an agent tool request.

`Agentic.AgentDeck` sends into a session owned elsewhere, polls liveness and output, checks reply freshness, and shares one conversation for the run. It cannot observe ACP-style stop reason and does not pretend otherwise.

### Current execution observation

`Agentic.Exec.announcingWorld` emits prose before and after each actual service invocation. Memo hits emit nothing. `runPlanWith` returns the complete `ExecTrace` only when it finishes. `Agentic.Cli.runCmd` prints bills, not a serialized trace.

Therefore the current CLI can support:

- process-level running/done/failed/cancelled status;
- a live combined stdout/stderr log;
- whole-process abort;
- final exit code and bill summary.

It cannot support an honest per-occurrence live view without a new event hook.

### Current lifecycle gaps

Agent-cat currently has no:

- workflow run handle or run ID;
- structured live event stream;
- status/output/cancel protocol;
- graceful public cancellation method;
- pause or resume;
- workflow fork or lineage;
- persisted memo, answer table, trace, or checkpoint;
- restart from checkpoint;
- nested workflow run model;
- per-run concurrency cap;
- stable runtime occurrence IDs;
- public way to steer or redirect an in-flight question.

Internal cleanup by asynchronous exception is not a public lifecycle API. Corpus replay and bisimulation are conformance mechanisms, not workflow-run persistence.

## What Pi already provides

The canonical supported boundary is `packages/coding-agent/src/core/extensions/types.ts`, not deep interactive-mode internals.

### Commands, tools, and discovery UI

`ExtensionAPI` supports:

- `registerCommand` with description and async argument completions;
- `registerTool` with dynamic TypeBox schema, abort signal, streaming `onUpdate`, and custom renderers;
- runtime tool activation;
- shortcuts and flags;
- command and tool inspection;
- custom message and entry renderers.

A command handler receives `ExtensionCommandContext`; a tool receives `ExtensionContext`. Commands can safely own interactive launch and session-replacement operations. Tools should expose model-callable workflow control without replacing the human browser.

Recommended MVP surface:

- `/wf [<name>]` — select or directly launch in the current Agent Deck session;
- `/workflow <name>` — compatibility launch wizard for alternate targets;
- `/workflow-status [run-id]` — open monitor;
- one generic model tool, `agent_cat_workflow`, with list/describe/start/status/output/cancel actions.

Do not initially register one tool per workflow. A generic tool avoids collisions and tool-schema churn and lets discovery stay dynamic. Per-workflow tools can be added later if model usability evidence justifies them.

### TUI surfaces

`ExtensionUIContext` already supports the desired host UI:

- `custom()` for a focused component;
- experimental overlay mode and `OverlayHandle`;
- keyed widgets above or below the editor;
- footer status and custom footer/header;
- select, confirm, input, editor, and notifications;
- raw terminal input and autocomplete extension;
- component factories that receive the TUI and can request re-rendering;
- theme and tool-expansion access.

The extension can therefore implement a live workflow monitor without touching Pi internals. Use:

- a small persistent widget/footer for active-run counts and selected status;
- a custom component for the catalogue and detailed inspector;
- a terminal custom entry on completion so the transcript retains a durable summary;
- protected log files with explicit byte caps/truncation markers, plus smaller bounded windows in memory.

Tool `onUpdate` is useful when the model starts a workflow, but the run must not be owned by the lifetime of that one tool call. The extension's run supervisor should own it; tool updates are only a view.

### Current-session control

Pi's public extension surface can:

- send a user or custom message immediately;
- queue it as steering after the current assistant turn's tool batch;
- queue it as a follow-up after the run settles;
- abort the current agent operation;
- observe message, turn, tool, and settled events;
- wait for idle in a command handler.

Pi steering is normally a turn-boundary queue, not a guaranteed immediate provider interruption. A control result must say whether a message was queued, delivered, or unsupported rather than label every request “steered.”

Using the current Pi session as an agent-cat answerer is possible only through a bridge. It should be serialized, explicit, and opt-in because it consumes and changes the user's current conversation. It is not part of the MVP.

### Child Pi sessions

`packages/coding-agent/src/core/sdk.ts` publicly exports `createAgentSession`; `AgentSession` exposes `prompt`, `steer`, `followUp`, `abort`, `waitForIdle`, and `subscribe`. An extension can therefore own additional sessions in-process.

Pi RPC mode provides a stronger isolation boundary for an early implementation: a child `pi --mode rpc` process accepts prompt, steer, follow-up, abort, state, model, and session commands while streaming JSON events. The example subagent extension demonstrates the simpler JSON-subprocess pattern and streaming custom tool rendering.

Use RPC subprocesses before embedding multiple `AgentSession`s in the extension process. They isolate crashes, extension recursion, resource loading, and shutdown ownership. Move in-process only if measured startup or process overhead warrants it.

### Existing arbitrary Pi sessions

`ExtensionCommandContext.newSession`, `fork`, `navigateTree`, and `switchSession` replace the current runtime. They do not create a detached session registry that an extension can supervise concurrently.

`SessionManager.list` and `listAll` discover files, not live owners. `ReadonlySessionManager` cannot mutate them.

The experimental remote stack can acquire sessions and expose authoritative snapshots/transcripts, prompt or steer them, abort, and change model/thinking. It is not wired into normal Pi as a service. Treat promotion of that service as a later Pi upstream option, not as a hidden dependency.

### Persistence

`pi.appendEntry` stores small extension data in the current session and `registerEntryRenderer` displays it without placing it in model context. This is suitable for:

- run references;
- terminal summaries;
- selected/default runner settings;
- the last opened run.

It is not a cross-session run database, mutable record store, artifact manager, or process lease. Durable workflow state belongs in an agent-cat/project run store, with Pi entries pointing to it.

### Security boundary

Pi extensions run with the process's full OS permissions. Project trust protects loading project resources, but there is no per-extension sandbox or capability grant. The extension must enforce its own runner allowlist, argv construction, cwd policy, and approval UX.

## Capability matrix

The classification column records the four categories used at the report baseline; the implementation reconciliation and revised rows state the delivered result:

- **Possible through supported Pi extension APIs** — public extension/SDK surfaces plus current agent-cat commands are sufficient.
- **Possible with constraints** — feasible, but only with the stated limitation or narrow agent-cat hook.
- **Requires an upstream Pi change** — ordinary extensions lack the required Pi ownership/service contract.
- **Not currently feasible** — required execution identity or durable state did not exist at the report baseline.

Agent-cat-only changes are named in the evidence column rather than creating a fifth classification.

| Capability | Classification | Direct evidence and required work |
|---|---|---|
| Discover configured runner binaries | Possible with constraints | Extensions may use Node built-ins and `ExtensionAPI.exec` (`packages/coding-agent/docs/extensions.md`, “Available Imports”; `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionAPI.exec`). There is no runner-discovery API, so use explicit trusted configuration and bounded PATH candidates, never an arbitrary repository scan. |
| Refresh available workflows dynamically | Possible through supported Pi extension APIs | Reinvoke each configured runner's machine catalogue (`cli/src/Agentic/Cli.hs`, `Registry`, `listCmd`; `cli/run/Main.hs`, `main`) from an extension command/tool. The catalogue is compiled into the runner but dynamic from Pi's point of view. |
| Show workflow name, blurb, level, cost, inputs, run facts, pins | Possible through supported Pi extension APIs | `cli/src/Agentic/Cli.hs` documents the machine fields and derives them in `factFields`; `listCmd` emits them under `--json`. |
| Show full help | Possible through supported Pi extension APIs | Invoke the runner's `help NAME`; `cli/src/Agentic/Cli.hs`, `Row.rowHelp` and `helpCmd`, make the prose authoritative and verbatim. |
| Obtain final program/cost fingerprint for actual inputs | Possible through supported Pi extension APIs | `cli/src/Agentic/Cli.hs`, `planCmd`, emits `--json --raw`; `dsl/src/Agentic/Builder.hs`, `Program.progRawOut`, is the raw value to canonicalize before hashing. |
| Per-argument types/defaults/structured help | Possible with constraints | `dsl/src/Agentic/Workflow.hs`, `Parameterized`, `taking`, and `input`, expose ordered required text names only; descriptions remain `cli/src/Agentic/Cli.hs`, `Row.rowHelp`. Add descriptor fields if workflows need richer arguments. |
| Command argument completion | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `RegisteredCommand.getArgumentCompletions`; usage is documented in `packages/coding-agent/docs/extensions.md`, `pi.registerCommand`. |
| Rich argument wizard | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionUIContext.select`, `input`, `editor`, and `custom`. |
| Launch scripted workflow | Possible through supported Pi extension APIs | `cli/src/Agentic/Cli.hs`, `Target.Scripted` and `runCmd`, are current execution paths; process launch precedent is `packages/coding-agent/examples/extensions/subagent/index.ts`, `runSingleAgent`. |
| Launch against ACP adapters/routes | Possible through supported Pi extension APIs | Agent-cat remains the runner: `cli/src/Agentic/Cli.hs`, `runCmd`; `engine/acp/src/Agentic/Acp.hs`, `withAcps` and `engineOfAcp`; `runtime/src/Agentic/Runtime/Route.hs`, `routedWorld`. |
| Launch against agent-deck session | Possible through supported Pi extension APIs | `cli/src/Agentic/Cli.hs`, `runCmd`, accepts deck targets; `engine/agent-deck/src/Agentic/AgentDeck.hs`, `engineOfDeck` and `sayDeck`, drive the external session. |
| Use current Pi session as control plane | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionAPI.registerCommand`, `registerTool`, and `ExtensionUIContext`, provide the command/tool/TUI host. |
| Use current Pi session as workflow answerer | Possible with constraints | Implemented by the authenticated `CurrentSessionBridge`, ACP proxy, and `ExtensionAPI.startTaskTurn`. It is explicit, exclusive, handle-correlated (not prompt-text matched), visibly injects Pi turns, and is not a sandbox. |
| Use extension-owned child Pi sessions | Possible with constraints | Implemented by `ext-pi/src/pi-child-acp.mjs` through public `createAgentSession`; sessions are in-memory, one prompt at a time, concurrent across child processes, steerable/abortable, and deliberately tool-free. |
| Control arbitrary already-running Pi sessions | Possible with constraints | Implemented for sessions discovered over an explicitly configured authenticated transport or named by ID. `RemoteSession.discover` lists durable metadata after authentication; optional `attach.mode` and server enforcement make exclusive acquisition conflict before work. There is no unauthenticated global scan. |
| Process-level run status | Possible through supported Pi extension APIs | The shipped subprocess precedent tracks spawn, close, exit code, and abort in `packages/coding-agent/examples/extensions/subagent/index.ts`, `runSingleAgent`; extensions may import Node `child_process` per `packages/coding-agent/docs/extensions.md`, “Available Imports”. |
| Combined live stdout/stderr | Possible through supported Pi extension APIs | `packages/coding-agent/examples/extensions/subagent/index.ts`, `runSingleAgent`, consumes child stdout/stderr incrementally; agent-cat enables line-buffered output in `cli/src/Agentic/Cli.hs`, `cliMain`. Output remains prose without step attribution. |
| Per-step pending/running/done/reused/failed | Possible with constraints | Implemented by `Agentic.Runtime.Protocol`, `runPlanPersisted`, and the pure extension reducer. Operational occurrence identity remains below denotation. |
| Per-step backend, retry, failover, answer source | Possible with constraints | Implemented as occurrence/attempt/reuse/recovery/redirect events; authored trace order remains a separate `trace.ordered` event. |
| Stream model text/reasoning/todos per step | Possible with constraints | ACP text chunks are emitted as bounded `attempt.output`; private reasoning/todos remain unsupported rather than inferred. Agent-deck remains completion-oriented. |
| Pi full-screen monitor | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionUIContext.custom`; component/overlay usage is documented in `packages/coding-agent/docs/extensions.md`, “Custom UI”. |
| Persistent active-run widget/footer | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionUIContext.setWidget`, `setStatus`, and `setFooter`; live render precedent is `packages/coding-agent/examples/extensions/custom-footer.ts`. |
| Terminal transcript card | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionAPI.appendEntry` and `registerEntryRenderer`; durable shape is `packages/coding-agent/src/core/session-manager.ts`, `CustomEntry`. |
| Whole-run immediate abort | Possible with constraints | Implemented through a dedicated inherited control fd, ACP bracket unwinding, `run.cancelled`, idempotent supervisor cancel, and process-group TERM/KILL fallback with distinct forced-termination classification. Workflow payload remains on fd 0; legacy stdin-control mode is retained only when no automatic stdin binding is needed. |
| Current/child/remote Pi steering timing | Possible with constraints | Current turns use `TaskTurnHandle.steer` versus `followUp`; remote turns use protocol `steer` versus `follow_up`; child ACP uses the corresponding agent-session operations. `interrupt-now` and `next-boundary` are never collapsed into one call. |
| Agent-cat request steer | Possible with constraints | Implemented for capability-advertising ACP targets through exact occurrence/attempt controls and `session/steer`; provenance emits `attempt.steered`, and the answer group is excluded from in-run future memo and durable replay. |
| Manual retry/failover/abandon choice | Possible with constraints | Implemented once automatic recovery is spent. Agent-cat emits the offered choices, a correlated control selects one, and the runtime records `occurrence.recovery-chosen`; unavailable choices and stale occurrences refuse. |
| Manual redirect to another backend/session | Possible with constraints | Implemented only at a bounded scheduler dispatch boundary and only to lanes already reserved by `reserveQuestion`; active attempts and unreserved targets are rejected stale. |
| Pause/unpause | Not currently feasible | Durable checkpoints exist for immutable restart/resume lineage, but the interpreter has no suspended live continuation or pause control. Cancellation plus later compatible resume is intentionally not presented as pause. |
| Restart from beginning | Possible through supported Pi extension APIs | Implemented as `machine-restart` / `/workflow-restart`: a new run and immutable parent link, exact launch fingerprint, and no inherited answers. |
| Resume interrupted workflow | Possible with constraints | Implemented for compatible checkpoints by seeding exact bare-question typed answers. Any started/completed parent effect, program/target/policy mismatch, corrupt state, or unknown semantic version refuses before child creation. |
| Fork workflow at a step or answer | Possible with constraints | Implemented as immutable child lineage with zero or more answer drops/replacements and `/workflow-diff`. Matching full bare-question keys may replay; changed inputs/routes naturally invalidate nonmatching keys. Parents with effect journal entries are refused. Pi conversation fork remains distinct. |
| Fork current Pi conversation | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionCommandContext.fork`; lifecycle and stale-context rules are documented in `packages/coding-agent/docs/extensions.md`, `ctx.fork`. It replaces the current session and is not workflow fork. |
| Persist logs and terminal records | Possible through supported Pi extension APIs | `packages/coding-agent/src/core/extensions/types.ts`, `ExtensionAPI.appendEntry`, plus Node filesystem imports allowed by `packages/coding-agent/docs/extensions.md`, “Available Imports”; `packages/coding-agent/src/core/session-manager.ts`, `CustomEntry`, persists references. |
| Persist semantic replay state | Possible with constraints | Implemented in agent-cat-owned `answers.json`, `effects.ndjson`, and `checkpoint.json`, with full question JSON keys, schema-indexed answer decoding, semantic versioning, and fail-closed migration/corruption policy. |
| Nested workflow runs | Not currently feasible | `dsl/src/Agentic/Workflow.hs`, `function`, `call`, and `defining`, build/in-line one `Program`; there is no child-run identity or runtime nesting protocol. |
| Enforce agent-cat effect permission | Possible through supported Pi extension APIs | Existing agent-cat execution enforces it in `engine/acp/src/Agentic/Acp.hs`, `permissionByIntent`; the extension launches that runtime rather than reproducing permission logic. |
| Enforce extension/runner capability sandbox | Possible with constraints | Pi explicitly gives extensions full process authority (`packages/coding-agent/docs/security.md`, “No built-in sandbox”); agent-cat provides cwd/scratch policy through `engine/acp/src/Agentic/Acp.hs`, `AcpConfig.acpCwd`, not an OS sandbox. Use trust checks, grants, isolation, and clear labels. |

## Architecture options

### Option A — extension-only CLI wrapper

The extension calls `list --json`, `help`, `plan --json`, and `run`, captures output, and supervises the process.

**Provides:** catalogue, help, named inputs, plan/cost, ACP/deck/scripted launch, process state, log, whole-process abort, Pi TUI.

**Cannot honestly provide:** per-step state, memo hits, current dispatched backend, request steering, redirect, workflow resume/fork.

**Use:** bootstrap and fixture harness. Do not market it as the final first-class execution model.

### Option B — extension plus a small agent-cat event/control boundary

Agent-cat remains the interpreter. It adds a versioned operational event stream and, in a later slice, a correlated control stream. The Pi extension reduces those events into a view model and persists them.

**Provides:** all of Option A; honest per-occurrence monitoring; graceful cancellation; backend/reuse/failover attribution; later steering and redirect; a stable basis for persistence.

**Pi changes:** none for the original current/owned-child MVP; the selected full scope ultimately required the constrained ownership, discovery, follow-up, and correlated-current-turn APIs listed below.

**Recommendation:** choose this option.

### Option C — generalized Pi workflow and remote-session core

Pi promotes a stable multi-session service, background-run registry, artifact store, and lifecycle controls. Agent-cat becomes one workflow provider among many.

**Provides:** adoption of arbitrary existing Pi sessions, shared cross-session ownership, native run UI conventions, remote reattachment.

**Cost:** broad upstream product and API design before the agent-cat integration has proved what must be general.

**Use:** only after Option B demonstrates concrete gaps. The experimental Pi server is prior art, not a release foundation.

### Rejected — TypeScript interpreter or embedded agent-functor runtime

Parsing `RawProgram`, recreating `Plan` scheduling, or porting agent-functor's runner/TUI would create a parallel implementation beside agent-cat's existing abstractions. It would weaken conformance, duplicate failure policy, and make the extension—not agent-cat—the authority on workflow meaning.

## Recommended user experience

### Catalogue

`/wf` with no argument opens a searchable selector with one row per `(runner, workflow)`. `/wf <runner>:<workflow>` skips it. Text after the workflow name on line one binds the declared command-tail input as one unsplit value; text after the first newline is stripped of leading whitespace once and binds the declared stdin input. Selecting or naming a row launches it through the current Agent Deck session after one charge, containment, and persistence confirmation.

The command reads inherited `AGENTDECK_INSTANCE_ID`; it neither scans for sessions nor asks for a session ID. Missing source declarations fail before prompts, confirmation, state creation, or target contact. Missing source values return to ordinary input prompting. Exact runner prose remains available through `/workflow-help`.

### Launch paths

The primary `/wf` path:

1. Resolve the current Agent Deck session from inherited `AGENTDECK_INSTANCE_ID`.
2. Resolve the named workflow, or ask the user to select one.
3. Bind raw first-line tail and leading-trimmed multiline body only to matching declared sources; reject unsupported text.
4. Prompt once for every still-unbound input, writing values to user-only temporary files.
5. Show runner, cwd, current session, containment, effects, source byte counts, cost possibility, and persistence; require one confirmation.
6. Plan with every actual input, stream the stdin-designated private file over fd 0, and launch agent-cat with `--session <current-id>` while controls use fd 3.

The compatibility `/workflow` wizard retains scripted, ACP, manually selected Agent Deck, current Pi, owned child, and authenticated remote targets. Both paths leave agent-cat authoritative for interpretation, routing, permissions, and persistence.

### Active monitor

The normal editor remains available. A widget shows active/failed/waiting counts. `/workflow-status` opens the detailed component:

- left/tree pane: runs and occurrences;
- main pane: selected occurrence output and attempts;
- details pane: authored request, intent, source/reuse, backend/session, timing, input provenance;
- footer: available controls and their exact delivery semantics.

A run row must distinguish:

- queued;
- starting;
- running;
- waiting for user/control;
- cancelling;
- succeeded;
- failed;
- cancelled;
- orphaned after lost ownership.

An occurrence row must distinguish:

- pending dependency;
- running attempt;
- reused;
- succeeded;
- failed;
- cancelled;
- skipped because its branch was not selected.

Unknown is preferable to a guessed state.

### Controls

Controls appear only when supported by the selected run/occurrence.

- **Steer:** send guidance with a declared timing (`interrupt-now` or `next-boundary`). Return and display `delivered`, `queued`, `unsupported`, or `failed`.
- **Abort:** mark cancelling, request graceful cancellation, wait a bounded cleanup interval, then terminate if needed. Never report cancelled before ownership or process state confirms it.
- **Retry:** repeat the same dispatched request under the existing recovery policy.
- **Redirect:** initially retarget only an undispatched occurrence to a lane agent-cat already reserved. A later scheduler-owned form may cancel or settle an active attempt and reserve another target. The extension must never retarget a running attempt by itself; every attempt remains in the audit log.
- **Restart:** new run from the beginning with copied configuration.
- **Resume:** continue from a persisted safe checkpoint; unavailable until the runtime has one.
- **Fork:** create a child run from immutable parent state, with an explicit dropped/replaced answer or changed input/route. Never reuse the word for Pi conversation fork without qualification.

## Target architecture

```text
Pi TUI / command / tool
          |
          v
agent-cat Pi extension
  catalogue | launch wizard | run supervisor | event reducer | persistence refs
          |
          +---------------- current Pi session control (public ExtensionAPI)
          |
          +---------------- owned Pi worker (RPC first; SDK later)
          |
          v
versioned local runner protocol
          |
          v
agent-cat Registry -> Program -> runPlanWith -> WorldIO
                                   |
                        scripted / ACP / deck / Pi bridge
```

### Extension components

1. **Runner catalogue**
   - explicit configured runner IDs and argv;
   - discovery cache with provenance and errors;
   - `list --json`, `help`, `plan --json --raw` adapters;
   - duplicate `(runner, name)` handling without silent overwrite.

2. **Launch compiler**
   - validates input names and route pins against descriptor;
   - builds argv without shell parsing;
   - canonicalizes actual-input raw program for a fingerprint;
   - produces an immutable launch manifest.

3. **Run supervisor**
   - mints durable run IDs before spawn;
   - owns process/AgentSession/RPC handles;
   - enforces one owner and cleanup leases;
   - writes stdout, stderr, events, and control acknowledgements;
   - reduces event stream into snapshots;
   - survives UI open/close independently.

4. **Pure run reducer**
   - consumes monotone sequenced events;
   - is transport- and TUI-independent;
   - rejects duplicate or gapped sequences as corruption;
   - never infers success from silence.

5. **Pi views**
   - catalogue/launch component;
   - active widget/footer;
   - detailed monitor;
   - terminal custom-entry renderer;
   - tool call/result renderer as a secondary view.

6. **Project run store**
   - immutable manifest;
   - append-only event/control log;
   - separate stdout/stderr/full-output files;
   - atomic current snapshot;
   - parent/child lineage;
   - lock/owner metadata.

### Ownership rule

The extension may supervise and render a workflow, but it must never decide which `Plan` node runs next, whether an answer memoizes, how a branch is selected, what a reply decodes to, or which automatic failover candidate is valid. Those remain agent-cat decisions.

## Proposed agent-cat operational protocol

Use a dedicated structured mode rather than parsing prose. Preserve human CLI output unchanged.

### Envelope

Every message should carry:

- protocol version;
- durable run ID;
- monotone sequence or correlated request ID;
- event/control type;
- timestamp;
- payload.

Stdout in structured mode must contain only protocol records. Human narration should be an explicit log event or a separate stderr/log stream.

### Minimum event set

MVP:

- `run.started` — workflow, fingerprint, inputs, target, cwd, routes;
- `occurrence.started` — run-local occurrence ID, bounded request summary, and intent;
- `attempt.started` — attempt number, dispatched target, and timing;
- `attempt.output` — optional transport text chunk, explicitly transport-level;
- `attempt.completed` — stop/source metadata and duration;
- `attempt.failed` — typed gap/failure and recovery disposition;
- `occurrence.reused` — answer key/source metadata without pretending a service was called;
- `occurrence.completed` — answer summary, dispatched source, duration, and authored trace ordinal when known;
- `occurrence.failed` — terminal occurrence failure after recovery is exhausted;
- `run.completed` — unit-valued workflow terminal summary, final trace/bills, and referenced logs/artifacts; do not invent a generic result value;
- `run.failed` — failure and partial accounting;
- `run.cancelled` — cancellation source and cleanup result.

Later:

- permission request/decision;
- recovery request/decision;
- steer accepted/queued/delivered;
- redirect attempt;
- checkpoint persisted;
- child run attached.

### Occurrence identity

Do not add labels, sites, or keys to semantic `Q` or `Plan`. Mint a run-local operational occurrence ID as `execIn` schedules each reached ask. The event payload can carry bounded display fields while full prompts remain in protected logs. This preserves the denotational design while giving concurrent identical questions distinct rows.

Event sequence records chronology, not authored trace order. Carry an authored ordinal when it becomes known, or publish the final mapping at run completion; the UI must not infer dependencies or `Plan` topology from timestamps.

### Observer placement

Add an operational observer around the existing scheduler and transport boundaries:

- scheduler events around `execIn` and ticket completion;
- memo/reuse/source events around `askOrMemo` and `consult`;
- retry/failover events around `withTransportGaps` and `Recovery`;
- optional chunk events inside ACP/deck transports.

The observer must not be able to forge answers or alter scheduling. Control decisions should enter through explicit control mailboxes or a recovery adapter, not through the observer callback.

### Control channel

Start with whole-run cancel. Add request controls only after each has an acknowledgement state and audit event.

Suggested commands:

- `cancelRun`;
- `steerOccurrence` with timing;
- `retryOccurrence`;
- `redirectOccurrence` with target;
- later `checkpoint`, `resume`, and `fork` as run-level operations.

Control replies must be correlated and state whether the request was accepted, queued, rejected as stale, unsupported by the backend, or failed during delivery.

## Pi-session execution strategy

### MVP

Use Pi as the control plane and agent-cat's current scripted/ACP/deck engines as answerers. This reaches useful behavior with the fewest new contracts.

### Owned child Pi sessions

Add a Pi answerer bridge after event monitoring is stable.

Preferred first implementation:

1. extension starts isolated Pi RPC child sessions;
2. bridge maps one agent-cat request to one child prompt;
3. child events become transport output events;
4. `steer`/`abort` map to RPC controls;
5. completed assistant text returns to agent-cat for its existing decoder;
6. agent-cat remains responsible for memoization, retries, branches, and trace.

An ACP adapter that connects back to the extension is another valid bridge: agent-cat already knows how to drive ACP, while the adapter maps ACP sessions onto Pi sessions. This minimizes agent-cat transport changes but still needs agent-cat's run event stream for complete monitoring and provenance.

### Current Pi session

Treat current-session execution as an explicit special target, never a silent default.

Constraints:

- serialize requests through one lane;
- reserve the current session for one workflow run at a time;
- label every injected question and answer visibly;
- use conditional `before_agent_start` hooks for workflow-specific context;
- correlate assistant completions before returning bytes to agent-cat;
- define how ordinary user prompts and workflow steering interleave;
- record that one conversation was shared for the run;
- restore normal extension state on every exit.

The monitor may need to be a widget rather than a focused full-screen component while the same session is answering.

### Arbitrary existing Pi sessions

Defer. Revisit when Pi's experimental server becomes a stable coding-agent service or when a concrete external owner supplies authenticated session leases. Do not coordinate by editing another live session's JSONL file.

## Persistence, recovery, fork, and restart

### Phase-one store

Use a project-scoped untracked run store, preferably `.agent-cat/runs/<run-id>/`, containing:

- `manifest.json` — immutable launch descriptor, hashes, and private-program reference;
- `program.json` — mode-0600 actual-input program used for exact compatibility;
- `events.ndjson` — append-only structured events and controls;
- `stdout.log` / `stderr.log` or structured log equivalents;
- `snapshot.json` — atomically replaced reduced state;
- `owner.json` — process/session lease and heartbeat;
- `answers/` and checkpoints owned by agent-cat.

Run directories and sensitive files must be user-only, with configurable retention; full prompts, answers, and input values are opt-in rather than assumed. A user-level private store keyed by project is an acceptable deployment alternative.

Pi session entries store only run references and terminal summaries. This makes runs visible from another Pi session without coupling their lifetime to one conversation.

### Fingerprint

At minimum include:

- runner identity and version;
- workflow name;
- canonical actual-input `RawProgram` from `plan --json --raw`, stored outside manifests in private `program.json`;
- ordered input content hashes and provenance in the manifest; raw values remain only in private input/program/event state;
- routes, engine, and relevant runtime policy;
- agent-cat protocol version.

A binary path or workflow name alone is not enough for safe replay. Run-local occurrence IDs are not cross-run fork addresses; true workflow fork needs an agent-cat-owned stable checkpoint or site identity.

### Recovery levels

1. **Record recovery:** rebuild UI from manifest/events/logs.
2. **Process reattachment:** reconnect to a still-live supervised process/control socket.
3. **Restart from scratch:** new run, same launch descriptor, new identity.
4. **Semantic resume:** seed persisted safe answers/memo and continue incomplete occurrences.
5. **Fork:** copy immutable parent state, apply an explicit input/answer/route edit, and continue under new lineage.

Only claim the highest level actually implemented.

### Persisted answers

This is agent-cat work, not extension inference. The runtime must decide:

- representation of schema-indexed typed answers;
- whether raw bytes or decoded values are authoritative;
- which intents may replay;
- how steering affects reuse;
- when incomplete effects may be credited;
- how program fingerprint mismatch refuses resume;
- how changed inputs/routes invalidate inherited state.

Agent-functor's content-addressed leaves are useful prior art, but agent-cat's bare-question memo and intent policy must determine its own store.

## Steering and denotational integrity

Steering is not semantically free. If an operator changes an answer while the authored `Q` remains unchanged, a later memo hit could serve an answer produced under hidden guidance.

Required policy:

1. steering is recorded as operational provenance;
2. the affected attempt is never presented as an unsteered reproduction;
3. persisted replay either includes the steering transcript in its key/provenance or marks the answer non-reusable;
4. hard interrupt and boundary guidance are distinct;
5. unsupported steering is visible and leaves no false UI echo.

Manual redirect fits agent-cat more cleanly: `ExecEvent` already separates authored request from `AnswerAsked dispatchedQuestion`. The runtime still must record the cancelled/failed prior attempt; the final `AnswerSource` alone is insufficient for a complete audit. Because `reserveQuestion` reserves possible transport lanes before dependencies resolve, redirect to an unreserved target can violate ordering and must remain scheduler-owned.

## Security and failure policy

1. Load runner paths only from trusted user configuration or trusted project configuration.
2. Gate project-local configuration with `ctx.isProjectTrusted()`.
3. Spawn argv directly; never construct a shell command string.
4. Carry raw input through mode-`0600` temporary files; stream the declared stdin file over fd 0, keep controls on fd 3, and delete launch inputs at terminal cleanup. Persist input-expanded programs only in private `program.json`, never manifests or diagnostics.
5. Display runner, cwd, engine, route table, scratch/isolation, source byte counts, and permission implications before launch; never echo source values.
6. Add an agent-cat-provided effect/tool-execution capability summary to machine metadata; do not infer it by parsing `RawProgram` or help prose.
7. Require an explicit saved grant or interactive confirmation for model-initiated mutable runs; refuse in noninteractive mode when approval is unresolved.
8. Default ACP/world-acting runs to an isolated scratch/worktree policy in the extension, while stating honestly that current agent-cat owns a scratch directory rather than a general sandbox.
9. Keep adapter credentials in inherited runtime configuration; never copy them into manifests/events.
10. Bound in-memory/rendered output and durable diagnostics; mark truncation explicitly rather than exhausting disk or hiding loss.
11. Validate every structured record and treat malformed/truncated records as an explicit protocol failure.
12. Use monotone sequence numbers and idempotent reduction.
13. Hold one ownership lease per run; refuse competing controllers unless shared ownership is designed.
14. On shutdown, either cancel and await cleanup or detach with a durable reattachment contract. Never simply forget a child.
15. Distinguish graceful cancellation, forced termination, transport failure, workflow abandonment, and lost ownership.
16. Do not let a Pi extension confirmation broaden agent-cat's intent-based ACP permission policy.
17. Do not expose private reasoning unless the selected backend and user policy explicitly provide it.

## Minimal MVP

The recommended MVP is Option B with a one-way event protocol and whole-run cancellation.

### Included

- explicit configuration of one or more agent-cat runner binaries;
- refreshable `list --json` catalogue;
- help and actual-input `plan --json --raw`;
- dynamic command completion;
- Pi catalogue and launch wizard;
- named text inputs and pin-aware route selection;
- scripted, ACP, and deck launches;
- versioned agent-cat event stream;
- per-occurrence start/reuse/complete/fail status;
- combined and selected-occurrence output;
- active widget and detailed Pi monitor;
- durable manifest, event log, stdout/stderr, and terminal summary;
- whole-run graceful cancel with forced-termination fallback;
- honest restart-from-scratch;
- fixture-driven tests with no paid model calls.

### Original MVP exclusions and final scope

- current Pi session as answerer — **implemented, explicit and exclusive**;
- arbitrary existing Pi sessions — **constrained to authenticated, configured known sessions**;
- request steering — **implemented for capability-advertising ACP targets**;
- manual redirect — **implemented only at scheduler-owned reserved boundaries**;
- pause — **still excluded**;
- semantic resume — **implemented for compatible effect-free checkpoints**;
- workflow fork — **implemented as immutable lineage, distinct from Pi conversation fork**;
- nested workflows — **still excluded**;
- a generalized Pi workflow framework;
- per-workflow dynamically registered model tools.

The original exclusion was deliberate for MVP sequencing. The user selected the full Option B roadmap; the implemented items above were added only after the catalogue, launch, event, persistence, and TUI seams were established.

## Phased implementation roadmap

### Phase 0 — protocol and fixtures

Agent-cat:

- specify descriptor/event versioning;
- add structured run mode without changing human output;
- mint run-local occurrence IDs;
- emit start/reuse/complete/fail/terminal events;
- expose whole-run cancellation and final cleanup result;
- drive the protocol against scripted and stub ACP fixtures;
- preserve all existing conformance/runtime gates.

Acceptance:

- the same `Program` and `runPlanWith` path execute;
- event reduction reaches the same final bills/trace facts;
- memo hits appear as reuse without a fake transport call;
- concurrent identical labels remain distinct;
- malformed/torn protocol input fails by name;
- cancellation leaves no adapter process or owned scratch behind.

### Phase 1 — Pi extension MVP

- runner configuration and provenance;
- discovery cache and duplicate handling;
- command completion and catalogue UI;
- input/route launch wizard;
- supervisor, run store, event reducer;
- widget, monitor, output paging, terminal entry;
- generic model tool;
- whole-run cancel and restart-from-scratch.

Acceptance:

- a user discovers and starts a fixture workflow without leaving Pi;
- every required input is collected exactly once;
- UI state follows fixture events in real time;
- durable diagnostics remain available up to the documented cap, with explicit truncation markers; machine events retain structured output records;
- another Pi session can reconstruct terminal run state from the project store;
- shutdown produces cancelled, detached, or terminal state—never an unexplained running record.

### Phase 2 — extension-owned Pi workers

- RPC child-session pool;
- agent-cat answerer/ACP bridge;
- backend/session attribution;
- turn-boundary steer and abort for owned Pi workers;
- isolation and tool allowlists;
- optional current-session target behind explicit confirmation.

Acceptance:

- agent-cat remains the only workflow interpreter;
- a Pi child answer is decoded and memoized by agent-cat;
- parallel workflow asks use distinct owned sessions when configured;
- current-session mode serializes and visibly labels every injected turn;
- abort/steer acknowledgements match observed child events.

### Phase 3 — interactive recovery and redirect

- bidirectional control protocol;
- request-level handles;
- interactive `Recovery` adapter;
- retry/failover/abandon UI;
- manual redirect with attempt history;
- steering provenance and reuse policy.

Acceptance:

- stale controls are rejected rather than applied to a new attempt;
- redirect preserves authored request and records all dispatched attempts;
- steering never appears as unsteered replay;
- unsupported backend controls are visible and non-destructive.

### Phase 4 — durable resume and workflow fork

- agent-cat-owned persisted memo/answers;
- safe checkpoints and partial trace;
- fingerprint compatibility checks;
- resume, fork, answer drop/replace, route/input changes;
- immutable lineage and diff.

Acceptance:

- a killed fixture resumes without redoing reusable completed work;
- effects are not silently replayed as observations;
- changed program/input/route state invalidates or refuses honestly;
- fork never mutates parent state;
- UI distinguishes reused, rerun, redirected, and replaced answers.

### Phase 5 — stable remote Pi sessions, only if needed

- evaluate promotion of Pi's experimental server/client into a coding-agent service;
- authenticated session discovery and leases;
- shared/read-only versus exclusive ownership;
- remote transcript/event reattachment;
- cross-session controls and artifact references.

Acceptance:

- no JSONL file mutation behind a live owner;
- exclusive control conflicts fail before sending work;
- reconnect restores authoritative session snapshot;
- transport authentication and frame limits are explicit.

### Delivered phase status

| Phase | Result | Primary verification |
|---|---|---|
| 0 — protocol and fixtures | Delivered | tier0/tier1, bounded-emission/oversized-ACP/protocol/control/store probes, ACP/deck gates |
| 1 — extension MVP | Delivered | extension catalogue/launch/reducer/supervisor/widget/monitor tests plus real runner ACP/deck integration and tmux runs |
| 2 — Pi workers | Delivered with explicit constraints | correlated current bridge; real tool-free child structured-answer/decode/resume-reuse fixture; authenticated remote prompt/lease fixture; no paid calls |
| 3 — recovery and redirect | Delivered | real machine steer/retry/abandon probes; extension failover and scheduler-reserved redirect fixtures |
| 4 — resume and fork | Delivered with effect-safety refusal | `test/lineage_probe.py` covers restart/resume/fork/drop/replace and parent immutability; extension covers edit manifests and diff |
| 5 — remote Pi | Delivered for authenticated known or discovered sessions | Pi lease/discovery/follow-up tests and extension remote reconnect/ownership/JSONL-canary test |

## Required API changes

### Agent-cat, MVP

1. Versioned structured run/event mode that leaves human CLI output unchanged.
2. Run-local occurrence and attempt IDs below `Plan` denotation.
3. Observer events around scheduler, memo, recovery, attempts, and terminal paths.
4. Whole-run cancellation with terminal event and cleanup outcome, including EOF/signal containment.
5. Public descriptor version and runner version in machine output.
6. Additive intent/effect/tool-execution capability summary for safe launch preflight.

### Agent-cat, delivered follow-on
1. Correlated controls over a dedicated inherited fd, leaving process stdin available for workflow text.
2. Source-aware named inputs, descriptor-v2 metadata, raw command-tail binding, and literal UTF-8 stdin.
3. Runner-offered retry/failover/abandon recovery and scheduler-reserved redirect.
4. Steering provenance and replay policy.
5. Persisted answer/memo/checkpoint store with input-expanded program content outside manifests in a private file.
6. Restart/resume/fork lineage with answer drop/replace and immutable parent state.
7. Optional Pi/stdio/ACP bridges for current, child, and remote Pi answerers.

### Pi, MVP

None. Use only public exports and extension APIs.

### Pi, delivered minimal delta and deferred generalization

1. Added optional protocol `attach.mode: shared | exclusive`; omission remains legacy shared.
2. Added timing-distinct `follow_up`; `steer` interrupts now, while follow-up queues at the next boundary.
3. `PiClient.acquireSession` transmits exclusive mode, and `PiServer` enforces it across connections until detach/disconnect.
4. Added `RemoteSession.discover` over authenticated `PiClient.listSessions`, plus `RemoteSession.followUp`.
5. Added `ExtensionAPI.startTaskTurn`, which refuses a busy current session, excludes unrelated prompts, returns exactly correlated turn messages, and exposes steer/follow-up/abort on one handle.
6. Network listener deployment remains an operator responsibility. The extension requires an explicit authenticated transport, then discovers/selects sessions or accepts a configured session ID.
These deltas are deliberately constrained to session ownership, authenticated discovery, timing-correct control, and one correlated current-session turn. The extension supervisor meets the workflow ownership, persistence, and artifact requirements, so no generic Pi workflow or background-run abstraction was introduced.

## Verification plan

### Source-level contract tests

Agent-cat:

- event codec round trips;
- monotone sequence and fail-closed duplicate/conflict/gap/torn-journal handling;
- one occurrence ID per reached request;
- memo hit, effect bypass, retry, failover, branch, and concurrent scheduling sequences;
- cancellation and process cleanup;
- human CLI byte stability outside structured mode.

Extension:

- descriptor decoding and unknown-field/version behavior;
- argv construction without shell interpretation;
- actual-input fingerprint canonicalization;
- pure run reducer transition table;
- bounded output window and disk paging;
- duplicate/gap/torn event behavior;
- ownership lease and stale-run recovery;
- command completion and duplicate workflow names.

### End-to-end fixtures

Use current project fixtures only:

- scripted workflows for deterministic path/reuse behavior;
- `engine/acp/test/stub_adapter.py` and the ACP gate for live protocol behavior;
- `engine/agent-deck/test/stub-deck.sh` for external-session behavior;
- a fake event runner for extension error injection;
- Pi tmux interactive mode for catalogue, launch, monitor, resize, key controls, and cancellation.

No paid model call is required for MVP acceptance.

### Final requirement audit

The implementation evidence records each capability as one of:

- supported and observed;
- supported with named constraint;
- deliberately deferred to a named phase;
- blocked by a named upstream contract.

A green build alone is insufficient. `doc/tmux-option-b-verification.md` separates TUI-observed flows from deterministic executable counterparts for controls and targets that would otherwise require a paid provider. Independent completion audit remains the final gate.

## Risks and decisions

| Risk | Decision |
|---|---|
| Extension becomes a second interpreter | Forbid RawProgram execution or branch scheduling in TypeScript. |
| Prose parsing drifts | Structured mode before per-step UI. |
| Current Pi conversation is silently consumed | Current-session answerer is opt-in and post-MVP. |
| “Steer” means different things | Every control names timing and reports acknowledgement state. |
| Pi fork and workflow fork are conflated | Use qualified labels in UI and records. |
| Dynamic catalogue changes under a run | Manifest pins descriptor and actual-input program fingerprint. |
| Workflow inputs grow richer than text | Add descriptor schema in agent-cat; do not infer from help prose. |
| Child survives extension shutdown without owner | Durable lease/reattach or bounded cancel; no orphan-by-forgetting. |
| Full logs exhaust TUI/context | Disk logs plus bounded reducer windows. |
| Extension trust implies silent world access | Explicit runner allowlist, project trust, launch summary, isolation default. |
| Experimental Pi server changes | Keep it out of MVP dependency graph. |
| Agent-functor semantics leak into agent-cat | Reuse behavioral lessons only; derive persistence/control from agent-cat `Request`, `AnswerSource`, and intent policy. |

## Source index

### agent-functor

- `src/Agent/Run.hs`: `Workflow`, `passMain`, `commandP`, `runWorkflow`, `runWithOpts`, `runLive`, `runInline`, `runHeadless`, `interactiveTurn`, `Registry`, `RunState`, `mcpStartRun`, `mcpControl`, `FlowRegistry`.
- `src/Agent/Mcp.hs`: `WorkflowInfo`, `catalogue`, `runInputSchema`, `controlTools`, `RunStatus`, `RunReport`.
- `src/Agent/Persist.hs`: `RunRecord`, `LeafEntry`, `SessionEntry`, `ForkEdit`, `forkStore`.
- `src/Agent/Tui/Live.hs`: `UiMsg`, `Stage`, `LiveState`, `reduce`, `nestedWire`.
- `src/Agent/Tui/App.hs`: `runLiveTui`, `sendToSelected`, steering/recovery/permission key paths.
- `src/Agent/Tui/Flows.hs`: `FlowSummary`, `RunSummary`, `BrowserAction`, `runFlowsTui`.
- `test/Agent/RunSpec.hs`, `test/Agent/McpSpec.hs`, `test/Agent/PersistSpec.hs`, `test/Agent/Tui/LiveSpec.hs`, `test/Agent/Tui/AppSpec.hs`.

### agent-cat

- `dsl/src/Agentic/Builder.hs`: `Program`, `program`.
- `dsl/src/Agentic/Workflow.hs`: pure `workflow`, `Parameterized`, `taking`, `input`, `Example`.
- `runtime/src/Agentic/Runtime/Facts.hs`: engine-neutral run fact names and readers.
- `cli/src/Agentic/Cli.hs`: `Registry`, `Row`, `listCmd`, `helpCmd`, `planCmd`, `runCmd`, discovery JSON contract.
- `plan/src/Agentic/Plan.hs`: `Plan`, `Request`, `Intent`, `AnswerSource`, `ExecEvent`, `ExecTrace`.
- `runtime/src/Agentic/Exec.hs`: `WorldIO`, `runPlanWith`, `announcingWorld`, `askOrMemo`, `TurnGap`, `Recovery`, `ExecSettings`.
- `engine/acp/src/Agentic/Acp.hs`: `AcpConfig`, `withAcp`, `withAcps`, `engineOfAcp`, `promptTurn`, permission and stop-reason policy.
- `engine/agent-deck/src/Agentic/AgentDeck.hs`: engine adapter, session liveness/poll/output behavior.
- `cli/run/Main.hs` and the packages under `workflow/`.
- `README.md`, module-local READMEs, and `doc/request-intent-representation.md`.

### Pi

- `packages/coding-agent/src/core/extensions/types.ts`: `ExtensionAPI`, `TaskTurnHandle`, `ExtensionContext`, `ExtensionCommandContext`, `ExtensionUIContext`, `ToolDefinition`, `RegisteredCommand`.
- `packages/coding-agent/src/core/agent-session.ts`: `prompt`, `startTaskTurn`, `steer`, `followUp`, `abort`, `waitForIdle`, `subscribe`.
- `packages/coding-agent/src/core/session-manager.ts`: session tree, `CustomEntry`, `ReadonlySessionManager`, `list`, `listAll`, `forkFrom`.
- `packages/coding-agent/src/core/sdk.ts`: `createAgentSession`.
- `packages/coding-agent/src/client/remote-session.ts`: authenticated discovery, exclusive lease, prompt, steer, follow-up, abort, snapshot, and reconnect wrapper.
- `packages/coding-agent/docs/extensions.md`, `packages/coding-agent/docs/rpc.md`, `packages/coding-agent/docs/security.md`.
- `packages/coding-agent/examples/extensions/subagent/index.ts`, `packages/coding-agent/examples/extensions/subagent/README.md`.
- `packages/client/README.md`, `packages/server/README.md`, `packages/protocol/README.md`.

## Conclusion

The integration adds no workflow language, scheduler, or second interpreter. Agent-cat remains the semantic and execution core; Pi remains the interaction and display core. The delivered seam is operational: agent-cat publishes strict persisted execution facts and accepts correlated controls, while narrowly scoped Pi APIs provide exclusive, timing-correct current/remote session turns.

Build that seam first. It yields a credible first-class Pi experience while preserving both projects' abstractions, and it makes the expensive features—Pi worker sessions, steering, redirect, resume, and fork—incremental rather than architectural rewrites.
