# Agent-cat terminal interface design

Status: implementation design; no production implementation is included here.

Last checked: 2026-09-03.

## 1. Decision

Agent-cat should acquire an explicit top-level `--tui` mode and a dedicated `tui/` source area within the existing `agentic` Cabal package. The interface should preserve the useful experience of agent-functor's terminal application—workflow and run browsing, input collection, plan preview, live progress, scrollback, controls, recovery, and final-result inspection—without importing agent-functor's execution model. Agent-cat remains the only workflow interpreter.

The terminal application should be a client of the same descriptor, machine-event, control, and store contracts used by `ext-pi`. It should invoke the current executable as a machine-mode child, rather than reaching into `Agentic.Cli` internals or introducing a second in-process execution path. This arrangement keeps the dependency graph acyclic, gives downstream registries such as `wf` the TUI automatically, and causes the TUI and Pi extension to observe the same realization facts.

Three qualifications are consequential:

1. Agent-functor's pure reducer and rendering discipline should be retained; its `Flow`, `RunGraph`, MCP nesting, permission, and persistence types should not be copied. Those types describe a different interpreter.
2. Runtime protocol version 1 is sufficient for a first live occurrence monitor, but not for the full experience. It does not carry the final program result, full reusable answers, or structured progress such as tool, usage, checklist, and public reasoning-summary updates. A negotiated protocol version 2 and a persisted result artifact are therefore part of the implementation plan.
3. Language-aware tree-sitter highlighting should follow structured tool/file progress, not precede it. The existing highlighter entails a C shim, four grammar libraries, Nix linker work, and a downstream packaging obligation; absent tool/file events, that cost has no data to render.

The existing commands keep their behavior. In particular, `run` does not silently become a full-screen application merely because stdout is a terminal. `agentic-run --tui` and `wf --tui` are explicit, while scripts and established interactive invocations remain stable.

The entry is an option rather than a new verb because registry row names occupy the verb namespace. Reserving `tui` would make a previously valid downstream workflow unreachable; a leading option introduces no new workflow-name collision. Sanitized routing inspection follows the same rule with `--routing --json`.

## 2. Baseline and method

The design was derived from the following local states:

| Repository | Revision | Working-tree qualification |
|---|---|---|
| agent-cat | `9df3cd3b6d42fa315b82b43db1749643cb45d9c4` | clean before this design work |
| agent-functor | `828043c8f4b08ecf7f93a4a0135a72ddc19d2594` | `flake.nix` has a pre-existing Darwin dylib-ID fix; `src/Agent/Tui` is clean |

The inspected agent-functor working snapshot is content-pinned as well as revision-pinned. `flake.nix` has SHA-256 `f2759bb8f051043d47ca806e33fc2f6535067d22a23305624855f2ecee514a99`; the digest of `shasum -a 256 src/Agent/Tui/*.hs` is `2682ef0747c6d2d4697c6ad936a132ea9fccfe86f711062e9bb5d30030411d22`.

Every file under `~/src/agent-functor/src/Agent/Tui` was read, together with its six TUI test modules, `Agent.Run`, `Agent.RunGraph`, `cbits/ts_shim.c`, the relevant Cabal and Nix declarations, and Part 5 of the agent-functor specification. Agent-cat's CLI routing, runtime events and controls, run store, ACP and Agent Deck adapters, and ext-pi catalogue, launch, supervisor, reducer, and monitor paths were then traced end to end.

External claims in this document rest on the source register in Section 15. Volatile package versions are recorded separately so that they can be rechecked at implementation time.

## 3. Present agent-cat boundaries

Agent-cat is one physical package whose source directories retain architectural ownership. The relevant graph is:

```text
workflow source -> DSL
plan             -> DSL
cost             -> plan
engine adapters  -> engine API
runtime          -> plan + engine API
CLI              -> every production layer + workflow registries
ext-pi           -> descriptor/machine/control processes only
```

The standing rules matter to the TUI design:

- `Agentic.Cli` is the composition root. It owns concrete backend grammar, adapter selection, routing-file I/O, model realization, commands, and exit mapping (`cli/AGENTS.md`).
- `Agentic.Runtime` owns scheduling, decode and retry policy, failover, memoization, effects, controls, and persistence. It treats engines as opaque values and imports no CLI or concrete engine (`runtime/AGENTS.md`).
- `Agentic.Engine` is identity-neutral. Concrete engines import it, while it imports no other agent-cat layer (`engine/api/AGENTS.md`).
- ext-pi does not interpret `Raw` or `Plan`; it consumes versioned process protocols and owns only discovery, approval, process supervision, UI, retention, and durable references (`ext-pi/AGENTS.md`).

### 3.1 Existing process contracts

`list --json` emits descriptor version 2. Each row carries workflow identity, static cost facts, ordered input descriptors, run facts, symbolic pins, runner version, supported protocol and store versions, and capability flags (`Agentic.Cli.factFields`). Input values are never included.

`machine`, `machine-restart`, `machine-resume`, and `machine-fork` emit protocol version 1 NDJSON envelopes. Sequence numbers are contiguous unsigned decimals; timestamps are canonical UTC; frames are bounded at 1 MiB. Events describe run lifecycle, occurrences, physical attempts, streamed attempt text, steering, recovery, dispatch redirection, authored trace order, bills, failures, and control acknowledgements (`Agentic.Runtime.Protocol`).

Controls travel on inherited file descriptor 3 when workflow stdin is needed, or on stdin for the legacy path. They carry an id and expected occurrence/attempt identity, and request cancellation, steering, recovery, or pre-dispatch redirection. Terminal acknowledgement is distinct from initial acceptance (`Agentic.Runtime.Control`).

When `AGENT_CAT_RUN_STORE` is present, the machine child writes a mode-private runtime store containing an immutable manifest and program, append-only events and effects, reusable answers, and atomic checkpoints (`Agentic.Runtime.Store`). ext-pi places that store beneath its own supervisor directory and maintains a separate launch manifest, live event mirror, redacted stderr log, owner heartbeat, and reconstructible snapshot.

### 3.2 What protocol version 1 already supports

A useful first TUI can already show:

- workflow, target, and terminal run status;
- occurrence code, intent, addressee, prompt preview, state, reuse, and answer preview;
- attempt target, state, bounded output tail, failure class, and steers;
- pending route choices, redirects, and recovery choices;
- delivered or refused controls; and
- final fresh and memo bills.

The ext-pi `MonitorModel` establishes that these data are sufficient for a compact monitor. A Brick frontend can provide a richer layout without changing their meaning.

### 3.3 Gaps which the TUI must not conceal

Protocol version 1 deliberately abbreviates occurrence prompts and answers to 500 one-line characters. `RunCompleted` carries bills but not the program's result. ACP forwards only `agent_message_chunk` text and ignores tool, usage, thought, mode, and configuration updates; Agent Deck offers still less live detail. The runtime store has no public run-catalogue projection, while ext-pi's outer supervisor schema is implemented only in TypeScript.

It follows that a TUI which claimed to show a complete artifact, tool history, token usage, checklist, or reasoning stream on version 1 would be inventing data. These are infrastructure gaps, not rendering tasks.

### 3.4 ext-pi implementation inventory

Every ext-pi source file has a distinct place in the comparison:

| File | Responsibility | TUI relationship |
|---|---|---|
| `catalogue.ts` | bounded descriptor/help/plan subprocess client and strict descriptor decoder | Same runner endpoints; Haskell uses the shared descriptor codec rather than a second local schema |
| `config.ts` | trusted runner, state-root, remote, and retention environment | Analogous local state/runner configuration; remote settings remain Pi-only |
| `launch.ts` | cwd containment, exact inputs, private files, plan fingerprint, manifest, machine argv | Behavioral template for the local launch supervisor |
| `supervisor.ts` | child ownership, event mirror/reduction, controls, cancellation, heartbeat, restore, retention | Behavioral template and shared manifest/protocol contract; no TypeScript code port |
| `reducer.ts` | fail-closed pure protocol-v1 snapshot reducer | Cross-language counterpart to `Agentic.Runtime.Snapshot` |
| `monitor.ts` | pure selected/collapsed textual monitor projection | Compact fallback and semantic comparison for the richer Brick projection |
| `monitor-ui.ts` | Pi terminal component and key handling | Remains Pi-native; shares no Brick widget code |
| `grants.ts` | one-time model mutation grants | Pi trust policy only; absent from local operator TUI |
| `index.ts` | extension registration, commands/tools, input and route collection, target selection | Pi composition root; TUI performs only its local equivalents |
| `current-bridge.ts` | exclusive current-Pi-session ACP bridge | Pi-only target |
| `pi-child-acp.mjs` | tool-free owned-child ACP bridge | Pi-only target |
| `pi-remote-acp.mjs` | authenticated/discovered remote-session ACP bridge | Pi-only target |
| `acp-proxy.mjs` | private Unix-socket proxy with token-file authentication | Pi-only transport |
| `types.ts` | descriptor, event, snapshot, target, and manifest DTOs | Cross-language protocol mirror; converges through fixtures, not imports |

`README.md`, `package.json`, and the test tree specify configuration, dependency, security, and integration obligations around these modules. None supplies workflow semantics.

## 4. Agent-functor TUI inventory

The source totals 5,242 lines across seven modules. The table records the entire requested tree and its disposition.

| Source module | Lines | Present responsibility | Agent-cat disposition |
|---|---:|---|---|
| `Agent.Tui.App` | 1,600 | Static and live Brick applications; bounded frame pump; viewports; modal keys; scrollback; render cache; theme map | Adapt into a thin Brick adapter. Retain bounded lossless event buffering, frame coalescing, modal queueing, spool-backed scrollback, and model-owned pane arbitration. Replace agent-functor runner callbacks with machine/control protocol operations. |
| `Agent.Tui.Flows` | 518 | Workflow and recorded-run browser; fuzzy filters; status filters; launch/fork/resume/archive actions | Adapt descriptor rows and shared run-catalogue records. Retain list/table/runs views and pure filtering. Rename “flow” to agent-cat's established “workflow” or “example” noun. |
| `Agent.Tui.Highlight` | 777 | Transcript segmentation, diff pairing, status styling, four tree-sitter grammars through FFI | Split. Reuse the pure segmentation, diff, status, and wrapping ideas against structured progress. Defer the FFI language parser until protocol events actually carry file/tool content; then port the C/Nix support deliberately. |
| `Agent.Tui.Live` | 1,714 | Pure live state and reducer; per-flow output/reasoning/checklists; navigation; modal queue; nested-run wire; render projections | Rewrite over `Envelope`/`RuntimeEvent` and occurrence/attempt ids. Retain pure reduction, identity-stable selection, replacement-versus-append semantics, bounded windows, and control modals. Omit MCP nested-run wiring: agent-cat has no such semantic object and this goal excludes MCP scaffolding. |
| `Agent.Tui.Markdown` | 210 | CommonMark block model and Brick rendering through `cmark` | Reuse after namespace and theme adaptation. Preserve raw unknown HTML rather than dropping it. Add display-width tests. |
| `Agent.Tui.Theme` | 100 | Tokyo Night true-colour palette and derived surfaces | Reuse as the initial built-in theme. Permit terminal defaults and future customization without making theme configuration a prerequisite. |
| `Agent.Tui.ViewModel` | 323 | Finished `RunGraph` projection, aggregate progress, status precedence, exact text renderer | Replace `RunGraph` with agent-cat's final `RunSnapshot`/trace projection. Reuse status precedence, textual fallback, progress bars, and the principle that headless rendering is not second-class. |

### 4.1 Direct dependency matrix

The direct imports and link obligations of each source module are as follows; transitive package dependencies are deliberately not substituted for the modules actually named in source.

| Module | Direct agent-functor imports | Direct library/GHC imports | Native or runtime obligation |
|---|---|---|---|
| `Agent.Tui.App` | `Agent.RunGraph`, `Agent.Tui.Highlight`, `Agent.Tui.Live`, `Agent.Tui.Markdown`, `Agent.Tui.Theme`, `Agent.Tui.ViewModel` | `Brick`, `Brick.BChan`, `Brick.Widgets.Border`, `Brick.Widgets.Center`, `Brick.Widgets.ProgressBar`, `Control.Concurrent`, `Control.Concurrent.Async`, `Control.Concurrent.MVar`, `Control.Concurrent.STM`, `Control.Concurrent.STM.TBQueue`, `Control.Monad`, `Control.Monad.IO.Class`, `Data.Bits`, `Data.List`, `Data.Map.Strict`, `Data.Maybe`, `Data.Text`, `Data.Time.Clock`, `Graphics.Vty`, `Graphics.Vty.CrossPlatform`, `Lens.Micro` | threaded RTS, a real terminal, Vty platform initialization |
| `Agent.Tui.Flows` | none | `Brick`, `Brick.Widgets.Border`, `Brick.Widgets.Center`, `Data.Char`, `Data.Set`, `Data.Text`, `Graphics.Vty`, `Graphics.Vty.CrossPlatform` | a real terminal for `runFlowsTui`; pure rows are offline |
| `Agent.Tui.Highlight` | none | `Control.Applicative`, `Control.Exception`, `Data.ByteString.Char8`, `Data.ByteString.Unsafe`, `Data.Char`, `Data.List`, `Data.Maybe`, `Data.Text`, `Data.Text.Encoding`, `Foreign.C.String`, `Foreign.C.Types`, `Foreign.Ptr`, `System.FilePath`, `System.IO.Unsafe` | `cbits/ts_shim.c`; `tree-sitter` plus Bash, Haskell, Nix, and JSON grammar libraries |
| `Agent.Tui.Live` | `Agent.Op`, `Agent.RunGraph`, `Agent.Tui.ViewModel` | `Control.Concurrent.MVar`, `Data.Aeson`, `Data.Aeson.Types`, `Data.Foldable`, `Data.Maybe`, `Data.Sequence`, `Data.Text`, `Data.Time.Clock` | no Brick or terminal dependency; reply `MVar`s remain process-local |
| `Agent.Tui.Markdown` | `Agent.Tui.Theme` | `Brick`, `CMark`, `Data.Char`, `Data.List`, `Data.Text`, `Graphics.Vty`, `Lens.Micro` | `cmark` bundles libcmark unless its optional pkg-config path is selected |
| `Agent.Tui.Theme` | none | `Graphics.Vty` | true-colour output degrades through Vty on lesser terminals |
| `Agent.Tui.ViewModel` | `Agent.RunGraph` | `Data.Text` | pure and terminal-independent |

The caller edge is equally material: `Agent.Run` imports `App`, `Flows`, `Live`, and `ViewModel`, then supplies TTY dispatch, ids, channels, spools, controls, stores, and final output. No TUI module imports `Agent.Run`; this inversion is one of the properties the agent-cat design preserves.

### 4.2 Supporting material outside `src/Agent/Tui`

A literal directory copy would not compile or behave correctly. The full feature also rests on:

- `Agent.RunGraph`, whose tree and statuses have no direct agent-cat counterpart;
- approximately 1,000 lines of TUI-facing integration in `Agent.Run`, including TTY dispatch, flow-id registration, event emission, steer mailboxes, nested-run watching, output spools, and browser actions;
- six test modules: `AppSpec`, `FlowsSpec`, `HighlightSpec`, `LiveSpec`, `MarkdownSpec`, and `ViewModelSpec`;
- `cbits/ts_shim.c`, because Haskell FFI cannot pass tree-sitter's `TSNode` structure by value;
- `agent-functor.cabal` declarations for Brick, Vty, vty-crossplatform, cmark, microlens, async, STM, C sources, and five native libraries;
- Nix grammar wrappers for Bash, Haskell, Nix, and JSON, including loader paths and Darwin install-name correction; and
- the frozen header oracle in `test/golden/header-before.txt` and fixed-width TTY acceptance capture in `test/golden/refactor-baseline-tty.txt`.

The local uncommitted `agent-functor/flake.nix` change rewrites each copied grammar dylib's install name on Darwin. Any eventual tree-sitter migration must include that correction; copying only the committed flake logic would reproduce a platform-specific link failure.

### 4.3 Behavioral inventory

The agent-functor interface provides four distinct surfaces:

1. **Catalogue and run browser.** It offers list, table, and recorded-run views; fuzzy and status filtering; lineage indentation; launch, resume, fork-at-leaf, and archive actions.
2. **Live dashboard.** It shows a contextual header, selectable concurrent flow rows, streamed output, optional input/reasoning/checklist panels, elapsed time, progress, modals, mouse selection, help, and final state.
3. **Finished view.** It projects the interpreted run graph and cost meter to both a static TUI and stable text.
4. **Rich transcript renderer.** It parses CommonMark, distinguishes tool/status/diff/file-preview blocks, syntax-highlights selected languages, and bounds render work with spools and cache eviction.

The controls include interrupt-now and next-boundary steering, approval gates, permission allow/deny, failure recovery, scrolling, panel cycling, and quit. Agent-cat already has direct analogues only for steering, recovery, redirection, cancellation, workflow selection, and lineage. Permission requests remain governed by intent in the ACP adapter and must not be overridden by a frontend. Person-addressed questions likewise cannot be intercepted merely for UI parity; doing so would alter runtime semantics and requires a separate design decision.

### 4.4 Invariants worth carrying over

The following rules are independent of agent-functor's algebra and should become agent-cat TUI requirements:

- State reduction and text projections are pure; Brick drawing does not decide behavior.
- Selection is keyed by stable occurrence or attempt identity, not a list index that concurrent insertion may shift.
- Blocking decisions queue in arrival order; a later modal never replaces one whose producer is awaiting a reply.
- Streams append, while complete snapshots such as a todo list replace; an empty snapshot clears.
- Output retained in memory is bounded. Older text remains available from a spool or durable event log.
- Repaint requests may coalesce; protocol events may not be dropped.
- A change of selected content explicitly re-anchors its viewport, while new text does not pull a reader who deliberately scrolled upward back to the tail.
- Rendering caches exclude growing and animated regions and are invalidated on resize and periodically.
- A final textual projection remains available for tests, pipes, inaccessible terminals, and failure reports.
- Display width is measured in terminal columns, not by `Text.length`.

## 5. Brick and Vty findings

### 5.1 Versions

| Component | agent-functor environment | agent-cat pinned nixpkgs | Latest Hackage checked 2026-09-03 |
|---|---:|---:|---:|
| Brick | 2.1.1 | 2.9 | 2.13 |
| Vty | 6.1 | 6.4 | 6.6 |
| vty-unix | 0.2.0.0 | 0.2.0.0 | 0.4.0.0 |
| vty-crossplatform | 0.4.0.0 | 0.4.0.0 | 0.5.0.0 |
| cmark | 0.6.1 | 0.6.1 | 0.6.1 |

The agent-cat column was evaluated from locked nixpkgs revision `8be7bd0c83f12e2e3bbba07c9044d6fed9e66f7f`.

Agent-cat should initially use Brick 2.9 from its locked nixpkgs rather than overlaying 2.13. The version-specific 2.9 guide and Haddocks are the API authority below. The immutable 2.13 changelog is used only to identify later changes—animation support, viewport and extent fixes, form visibility controls, and list search/wrapping. A newer package should enter through the ordinary nixpkgs update and its full test gate.

Because the runner is presently POSIX-specific, the application should import `mkVty` from vty-unix 0.2.0.0 rather than copy agent-functor's `vty-crossplatform` initializer. Brick may retain vty-crossplatform in its transitive closure, but the TUI does not thereby claim Windows support.

### 5.2 Pinned API evidence

The architectural API was checked against immutable Brick 2.9, Vty 6.4, and vty-unix 0.2.0.0 package documentation, not inferred from a mutable repository branch or from Brick 2.13. In addition, `doc/check-brick-2.9.hs` imports and typechecks the exact proposed primitives: `App`, `EventM`, `customMain`, blocking and non-blocking `BChan` operations, list, editor, and form state, viewports, cache invalidation, clickable regions, `renderWidget`, `textWidth`, and Unix `mkVty`.

The probe was compiled against locked nixpkgs revision `8be7bd0c83f12e2e3bbba07c9044d6fed9e66f7f` with GHC 9.10.3 and `-Wall -Werror -fno-code`:

```sh
nix shell --impure --expr \
  'let f = builtins.getFlake (toString ./.);
       pkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; };
   in pkgs.haskellPackages.ghcWithPackages
        (p: [ p.brick p.vty p.vty-unix p.vector ])' \
  -c ghc -Wall -Werror -fforce-recomp -fno-code doc/check-brick-2.9.hs
```

The command completed with `Compiling Main ... nothing` and exit status 0 on 2026-09-03. The first probe deliberately caught one real version detail before passing: Brick 2.9's `List` has two type parameters, whereas the older generalized-list source shape initially transcribed into the probe had three. The design and probe now use the pinned signature.

### 5.3 Application model

Brick applications provide an `App s e n`: state `s`, custom events `e`, and unique resource names `n`. Drawing is a pure description from state to widget layers; `EventM` handles Vty and application events and returns the final state when halted (Brick 2.9 User Guide, “The App Type”). This fits agent-cat's desired split directly:

```text
machine/process threads -> bounded lossless event queue -> pure reducer -> TUI state
                                                   frame clock -> Brick redraw
```

`customMain` is the correct entry point because the application receives process and timer events. It accepts an initial Vty handle, a reinitialization action, and an optional `BChan` (Brick 2.9 `Brick.Main`, compile-verified above). Brick and Vty require the threaded RTS.

### 5.4 Event pressure

A `BChan` is bounded; `writeBChan` blocks when full and `writeBChanNonBlocking` drops the write when full (Brick 2.9 `Brick.BChan`). Engine or child-process reader threads therefore should not write every protocol frame directly into Brick's channel. Blocking them can halt all transport progress, while dropping their events corrupts the monitor.

Use two queues:

- a bounded STM queue for every decoded envelope, with backpressure confined to the dedicated machine-reader thread; and
- a one-element non-blocking Brick channel carrying only `FrameReady` notifications.

At each frame the Brick thread drains a bounded batch, folds it in sequence, spools display text, and schedules another frame immediately when backlog remains. A 60 Hz display ceiling and 10 Hz animation phase are adequate; agent-functor's 144 Hz ceiling has no established requirement and should not become policy by inheritance.

### 5.5 Viewports, lists, forms, and editors

Brick viewports render their entire child and therefore should not hold an unbounded transcript. A scrollable viewport also requires a child fixed in the scrolling dimension; violation raises a runtime exception (Brick 2.9 User Guide, “Viewport Restrictions”). Agent-functor's moving in-memory window plus disk spool is the correct response.

Use `Brick.Widgets.List` for workflow, run, occurrence, and attempt selection, and `Brick.Widgets.Edit` or `Brick.Forms` for workflow inputs. These components already manage visibility, focus, cursor placement, mouse events, and wide-character editing. A dynamic input form should retain one editor per descriptor entry and preserve descriptor order; command-tail and stdin inputs remain semantically distinct even if both are edited in text widgets.

Forms perform pure field validation and retain the last valid form state. Network discovery and run preflight do not belong in a form validator; they run as background operations whose result returns as an application event (Brick 2.9 User Guide, “Input Forms”).

### 5.6 Terminal behavior

Vty supplies efficient differential rendering, resize handling, bracketed paste, mouse modes, and multi-column character support. Mouse and paste modes are off by default and must be enabled only when the output reports support (Vty 6.4 README; Brick 2.9 User Guide, “Mouse Support” and “Paste Support”). Every action remains keyboard-reachable.

Terminal column width can disagree across emulators. Brick's `textWidth` and Vty's Unicode-width machinery are authoritative; `Text.length` is not. The TUI should honor user Vty configuration and custom width tables where the selected platform package loads them. Unicode glyphs require ASCII fallbacks for terminals or test environments that cannot display them faithfully.

`customMain` restores the initial input state on ordinary and exceptional shutdown. The implementation must nevertheless test interruption and child failure, because terminal cleanup is an acceptance property rather than an assumption.

The explicit `--tui` mode requires terminal input and output. When either side is not a terminal, it should refuse before Vty initialization and direct the caller to `list`, `plan`, `run`, or machine mode as appropriate.

Although Brick and Vty provide Windows backends, agent-cat's present machine-control and cancellation paths use POSIX file descriptors, the `unix` package, and Unix process groups. The first TUI support target is therefore macOS and Linux. Windows support requires a separate control-handle and process-tree design; vty-crossplatform alone does not supply it.

### 5.7 Rendering cache

Brick's cache is explicit and does not infer when state invalidates an image. Cache settled markdown, completed diff blocks, and static help; do not cache a growing output segment, cursor-bearing editor, or animated status. Invalidate on resize and after theme change, and sweep long-lived content caches. The agent-functor failures caused by caching each growing segment are directly applicable.

For golden checks, `Brick.Main.renderWidget` can render widgets at a fixed display region without running a terminal. Brick 2.9 documents it as useful for tests but not stable; isolate it in tests rather than in production code (`Brick.Main`, compile-verified above).

## 6. Proposed source architecture

The implementation should add the following source area while retaining one package:

```text
tui/
  AGENTS.md
  README.md
  src/Agentic/Tui.hs                 public facade; no Brick types escape
  src/Agentic/Tui/Types.hs           frontend-local launch and view types
  src/Agentic/Tui/Model.hs           top-level pure screen/focus/navigation state
  src/Agentic/Tui/RunModel.hs        pure projection of runtime snapshots
  src/Agentic/Tui/App.hs             Brick/Vty adapter and event pump
  src/Agentic/Tui/Browser.hs         workflow/run/model catalogue widgets
  src/Agentic/Tui/Markdown.hs        CommonMark model and widget renderer
  src/Agentic/Tui/Highlight.hs       bounded transcript/diff presentation
  src/Agentic/Tui/Theme.hs           attributes and palette
  src/Agentic/Tui/Spool.hs           private bounded scrollback adapter
  test/...                           pure, render, protocol, and PTY tests
```

The exact number of hidden modules may contract during implementation; no module should exist merely to reserve a future seam. Two separations are load-bearing: the pure reducer remains outside Brick, and process/protocol supervision remains outside drawing.

`Agentic.Tui` should expose only an entry configuration and entry point, approximately:

```haskell
data TuiConfig = TuiConfig
  { tuiRunner      :: FilePath
  , tuiRunnerArgs  :: [String]
  , tuiWorkingDir  :: FilePath
  , tuiStateDir    :: FilePath
  }

runTui :: TuiConfig -> IO ()
```

The current executable path is the runner. A downstream binary using `Agentic.Cli.cliMain` therefore lists and launches its own registry without a callback interface, source import, or second registry representation.

### 6.1 Intended import graph

```text
Agentic.Runtime.Descriptor ----------------------+
                                                 |
Agentic.Runtime.Protocol ----> Agentic.Runtime.Snapshot ----> Agentic.Tui.* ----> Brick/Vty
                                                                           ^
                                                                           |
Agentic.Cli ---------------- concrete runner/config -------------------------+

ext-pi ---- descriptor/machine/control/store JSON only
```

More completely:

```text
DSL -> plan -> cost
engine implementations -> engine API
plan + engine API + protocol -> runtime
descriptor + protocol + snapshot -> tui
DSL + plan + cost + runtime + engines + tui -> CLI
workflow source -> DSL
ext-pi -> executable protocols
```

`tui` imports no DSL authoring types, plans, costs, workflow modules, concrete engines, or CLI implementation. `Agentic.Runtime.Descriptor` supplies the one Haskell descriptor type and JSON codec used by the CLI encoder and TUI decoder; `Agentic.Runtime.Protocol` and `Agentic.Runtime.Snapshot` supply operational state. CLI remains the sole module which knows how a symbolic model becomes a concrete engine invocation.

Add deterministic policy checks for these restrictions. A source-directory convention without a gate is not a boundary.

### 6.2 Why the TUI launches machine mode

Three alternatives were considered:

| Approach | Benefit | Consequence | Ruling |
|---|---|---|---|
| Import `Agentic.Cli` internals and run in-process | No child protocol | Introduces a CLI↔TUI cycle or a broad runner extraction; terminal stdout and cancellation share one process; ext-pi follows another path | Reject |
| Add a daemon or shared supervisor service | One owner for multiple frontends | New lifecycle, authentication, deployment, protocol, and recovery system before one local TUI needs it | Reject |
| Launch the same executable in machine mode | Reuses descriptor, event, control, persistence, preflight, and exit contracts; isolates terminal output | Requires a small Haskell process supervisor and protocol-v2 work for richer data | Adopt |

The Haskell supervisor should remain smaller than ext-pi's. It does not need remote Pi targets, model-grant tools, cross-process extension attachment, or Pi transcript integration. It does need direct argv spawning, process-group cancellation, bounded/redacted diagnostics, exact sequence validation, private stores, control acknowledgement, and restart reconstruction.

## 7. User experience

### 7.1 Top-level browser

The initial screen has three views reached by one tab cycle:

- **Workflows:** descriptor rows, fuzzy filter, static level/path/cost facts, input requirements, symbolic pins, and help/plan actions.
- **Runs:** terminal and live stores, lineage, owner state, persona, resolved engines/models, bills, and final-result availability.
- **Routing:** selected persona, available engines, concrete inventory provenance, and symbolic profile chains, obtained from a new sanitized CLI inspection command described in `model-routing-v2.md`.

The browser never parses Haskell, plans, or routing YAML. It invokes the runner's machine-readable commands.

### 7.2 Launch path

A launch proceeds through explicit states:

1. Select a workflow.
2. Collect each declared input in descriptor order. Prompt inputs use an editor, command-tail inputs remain one logical value, and stdin inputs preserve multiline text.
3. Select scripted or live execution. Live execution selects a persona first; advanced raw route overrides remain separate and visibly exceptional.
4. Request exact-input `plan --json --raw` and sanitized routing resolution in background threads.
5. Show a confirmation containing workflow, cwd, effectfulness, static bill bounds, persona, symbolic-to-concrete chain, target, and store location. No secret or input body appears in the summary.
6. Create the private supervisor directory and spawn `machine` with input files, a runtime store, and control fd 3.
7. Enter the live monitor only after the first valid `run.started` envelope. Setup failures return to the launch screen with stderr redacted and bounded.

No live run begins from a bare selection key. Confirmation is the TUI's local safety boundary; engine permission policy remains the runtime's.

### 7.3 Live monitor

The live screen adapts agent-functor's layout to agent-cat's semantics:

- header: workflow, persona, selected concrete realization, run id, status, elapsed time, and exact request bills when known;
- left pane: occurrence rows, grouped by stable occurrence id and showing intent, code, addressee, state, reuse, and active target;
- right pane: selected occurrence prompt preview, attempt stream, recovery/redirect history, answer preview, and control acknowledgements;
- optional full panes: prompt, attempt output, and final result;
- footer: navigation, help, steer, next-boundary note, recovery, redirect, detach, and cancel.

Before `trace.ordered`, rows retain occurrence-id order and are labeled as live activity. When authored order arrives, the list may reorder, but the selection remains attached to its occurrence id. No index is treated as identity.

`Escape` detaches to the run browser within the same TUI process while the machine child continues. Cancellation is a separate, confirmed action. This differs deliberately from agent-functor's `q`, which cancels the async runner by leaving its enclosing scope; a persistent run catalogue makes accidental cancellation the wrong default.

There is no background daemon. A request to quit the top-level TUI while it owns live children therefore offers only return to the browser or confirmed cancellation of those children; it never claims that supervision can survive normal process exit. Exception cleanup cancels owned process groups. An uncatchable process death may leave a heartbeat-stale orphan, which later readers present as read-only rather than live.

### 7.4 Controls

Controls use only the existing command protocol:

- interrupt-now and next-boundary steering target the exact active attempt;
- retry, failover, and abandon appear only when offered by `occurrence.recovery-pending`;
- redirection appears only during the scheduler's bounded pre-dispatch window and only for reserved targets;
- cancellation first sends `cancelRun`, waits for the terminal event, and then uses process-group TERM/KILL with the same bounded fallback as ext-pi; and
- the UI reports `delivered`, `rejected-stale`, `unsupported`, or `failed` from the terminal acknowledgement. “Requested” is not success.

Concurrent recovery decisions queue. No modal overwrites another decision which the runtime is awaiting.

### 7.5 Final result and history

Protocol version 2 should provide the private result artifact specified in Section 8.3. The TUI reads it only from the validated run directory, verifies its size and digest, renders it according to its code/schema, and offers a plain save/copy action through an explicit path prompt.

Run history should use a versioned frontend manifest compatible in shape with ext-pi's supervisor manifest: runner identity, workflow, cwd, target kind, input hashes, program hash, persona, resolved-policy digest, creation time, lineage, and owner. It contains references and hashes, never input bodies, prompts, answers, endpoint credentials, or secret values.

A live run owned by another process is read-only. A stale owner becomes orphaned rather than controllable. Restart, resume, and fork remain runner commands and retain their existing fingerprint and effect-journal checks.

## 8. Protocol and runtime infrastructure

### 8.1 Shared descriptor and snapshot projections

Extract descriptor versioning, DTOs, strict JSON decoding, and encoding from `Agentic.Cli.factFields` into a Text/Aeson-only `Agentic.Runtime.Descriptor`. CLI constructs the DTO after its existing plan/cost folds; TUI decodes that same type from `list --json`. The extraction preserves every descriptor-v2 key, value type, and array-order guarantee; JSON object-key order remains explicitly unspecified. ext-pi remains a cross-language decoder and consumes shared valid/invalid descriptor fixtures.

Add `Agentic.Runtime.Snapshot`, a pure state machine from validated envelopes to a `RunSnapshot`. It should enforce the lifecycle rules now implemented by ext-pi's TypeScript reducer: sequence continuity, one run id, no post-terminal event, valid occurrence and attempt transitions, exact control-ack transitions, complete authored trace before successful completion, and bounded text windows.

The TUI uses this Haskell reducer. ext-pi retains a TypeScript implementation because it is a protocol client in another language, but both reducers consume a shared corpus of NDJSON transition vectors and expected snapshots. This is semantic duplication under a wire contract, not a second workflow interpreter.

### 8.2 Negotiated protocol version 2

Do not add new event kinds silently to version 1. ext-pi rejects unknown event types and any version other than 1, correctly. Descriptor version 3 should advertise `[1, 2]`, and machine commands should accept an explicit `--protocol-version N`; omission continues to mean version 1 until every established client has migrated.

Version 2 should add only data with a demonstrated frontend consumer:

- a terminal result-artifact event/reference;
- full-content references for prompts and reusable answers whose v1 fields remain bounded previews;
- an optional typed attempt-progress event for public message text, transport narration, tool status, todo snapshots, usage, and public reasoning summaries; and
- non-secret realization metadata sufficient to show persona, engine alias, provider, concrete model, settings, and discovery provenance.

The engine-neutral update type should be optional: an engine which cannot report a checklist or usage emits nothing. Private chain-of-thought is not an interface. If an ACP adapter supplies user-visible reasoning summaries, they may occupy a distinct bounded channel; raw private reasoning is neither persisted nor promised.

The encoded envelope's frame-byte bound applies before JSON decoding. Field lengths, collection counts, lifecycle rules, and stream-specific bounds apply after decoding but before reducer mutation or persistence.

Descriptor version 3 advertises protocol versions `[1, 2]` and store versions `[1, 2]`. A protocol-v1 machine continues to create store format 1. A protocol-v2 machine requires and creates store format 2, whose only semantic addition in the first phase is the result artifact/reference; answer/effect/checkpoint semantics retain semantic-store version 1. Readers accept both formats and never infer one from file presence.

### 8.3 Result artifact contract

Protocol version 2 requires `AGENT_CAT_RUN_STORE`; a v2 machine invocation without it refuses before program construction or engine startup. The machine writes `<store>/result.json` as UTF-8 compact JSON followed by one newline, with this versioned envelope:

```json
{
  "artifactVersion": 1,
  "runId": "RUN_ID",
  "result": {
    "code": "receipt",
    "value": null
  }
}
```

`code` is the existing `codeJson` representation of the program result code, including a structured schema where applicable. `value` is `answerJson code result`; text is a JSON string, flags are booleans, acknowledgements are null, verdicts retain their tagged object, and structured results retain their exact schema encoding.

`maxResultBytes` is 67,108,864 bytes, measured over the exact stored bytes including the final newline. The file is created as a mode-0600 temporary beneath the already validated store, checked against the bound while its lazy encoding is consumed, flushed, and atomically renamed to the fixed basename `result.json`. Its SHA-256 is computed over those exact bytes. The path in an event is always the literal relative name `result.json`, never a caller-supplied path.

After runtime has emitted `trace.ordered`, the machine performs these terminal steps in order:

1. encode and validate the artifact;
2. atomically install `result.json`;
3. append the v2 `run.completed` envelope to the runtime event store;
4. emit that same envelope to the supervising stdout stream; and
5. exit successfully.

The v2 `run.completed` event retains `billFresh` and `billMemo` and adds:

```json
{
  "result": {
    "artifactVersion": 1,
    "path": "result.json",
    "sha256": "LOWERCASE_64_HEX_DIGITS",
    "bytes": "UNSIGNED_DECIMAL",
    "code": "receipt",
    "preview": "AT_MOST_500_ONE_LINE_CHARACTERS"
  }
}
```

The reducer accepts successful completion only after every occurrence and `trace.ordered`, and only when the result reference is syntactically valid. A frontend resolves the fixed path beneath the known store, refuses symlinks or path escape, rechecks the byte bound and digest, decodes artifact version 1, and verifies run id and `code` against the event before exposing the value.

Oversize output, encoding failure, write/flush/rename failure, or digest failure removes any temporary file, emits `run.failed` with `FailureRuntime` when the event sink remains usable, and exits nonzero. It never emits `run.completed`; paid work without a durable result is not reported as success. A failure while copying the already-installed completion event to stdout leaves the stored event authoritative for reconstruction.

The result artifact may contain private workflow output. It is never included in a supervisor manifest, routing inspection, diagnostic log, or terminal title.

### 8.4 ACP and Agent Deck

ACP currently discards all session updates except `agent_message_chunk`. Once protocol v2 progress has a consumer, the ACP adapter may parse a conservative common projection of `tool_call`, `tool_call_update`, `plan`, `usage_update`, and explicitly public reasoning-summary events. Raw vendor objects do not enter runtime state. Every text and collection is bounded, sensitive values are redacted before persistence, and answer bytes remain separate from narration and telemetry.

Agent Deck should emit only the facts its CLI actually reports. The TUI must not manufacture live streaming or model usage for a polling transport. A spinner and eventual answer are honest.

### 8.5 No semantic-layer changes

The TUI requires no import or type change in DSL, workflow source, planning, or cost. Static plans and costs remain runner output. The runtime's denotation and `ExecTrace` remain unchanged; presentation events describe realization only, as current machine events do.

Intercepting `AddrPerson` in the TUI is explicitly undecided. It would correct an acknowledged limitation in the current ACP path, but it changes who answers a workflow question and is not an incidental interface feature. Implementation should stop for a product decision before taking that step.

## 9. ext-pi overlap and synergy

The two interfaces should share facts and protocols, not rendering code. Brick and Pi's TypeScript TUI have different event loops, widget models, lifecycles, and trust contexts.

| Capability | Agent-cat TUI | ext-pi | Shared authority |
|---|---|---|---|
| Workflow discovery | runner `list --json` | runner `list --json` | descriptor protocol |
| Help and plan | runner subprocess | runner subprocess | CLI output/JSON |
| Input collection | Brick editors/forms | Pi input UI and `/wf` source binding | descriptor input order/source |
| Persona/model display | local routing pane | Pi picker/status text | new sanitized routing-inspection JSON |
| Launch approval | local explicit confirmation | Pi trust, UI approval, and grants | neither overrides runtime policy |
| Execution | machine child | machine child | agent-cat runtime |
| Monitoring | Brick snapshot projection | Pi `MonitorModel` | machine protocol + shared vectors |
| Steering/recovery/redirect | local controls | Pi commands/tools | control protocol and terminal ack |
| Cancellation | local process owner | Pi supervisor owner | control plus process ownership |
| Persistence | local frontend manifest + runtime store | Pi supervisor manifest + runtime store | versioned manifest/store schemas |
| Restart/resume/fork | runner lineage commands | runner lineage commands | runner preflight and store |
| Final result | result artifact pane | durable result reference | protocol-v2 artifact contract |
| Remote/current/child Pi targets | not offered | owned by ext-pi | ext-pi only |
| Terminal rendering | Brick/Vty | `@earendil-works/pi-tui` | no shared code |

### 9.1 Recommended convergence

1. Publish the Haskell snapshot reducer and shared protocol-transition corpus before adding v2 events.
2. Add sanitized `--routing --json` inspection so neither frontend parses routing YAML.
3. Version the frontend manifest and result reference, allowing both frontends to read terminal runs and show foreign live runs as read-only when configured to share a state root.
4. Migrate ext-pi to protocol v2 only after its reducer and supervisor pass the shared corpus; it continues requesting v1 until then.
5. Keep Pi-specific grants, project trust, remote targets, current-session turns, and transcript references in ext-pi. Keep terminal keymaps, viewports, and themes in `tui`.

A shared daemon is not warranted. The process protocol already supplies the needed boundary.

## 10. Packaging and dependency impact

### 10.1 Cabal

The public `agentic` library should add `tui/src` and expose `Agentic.Tui`; implementation modules remain under `other-modules`. Because `Agentic.Cli.cliMain` gains `--tui` for every downstream registry, Brick belongs in the same public library dependency closure. A private sublibrary would keep dependencies narrower but would deny `wf --tui` to external users; a second package would violate the one-package constraint.

Initial direct dependencies are:

- `brick`, `vty`, `vty-unix`;
- `async` for process and frame workers;
- `cmark` for CommonMark rendering;
- `microlens` only where Brick viewport/render accessors require it;
- `http-client`, `http-client-tls`, and `http-types` for bounded model discovery; and
- `crypton` for SHA-256 result and routing-cache fingerprints.

`stm`, `aeson`, `text`, `bytestring`, `containers`, `directory`, `filepath`, `process`, `time`, and `unix` already exist in the package.

The `agentic-run` and downstream `wf` executables remain `-threaded`. The dependency version should come from the pinned Nix package set: Brick 2.9, Vty 6.4, and vty-unix 0.2.0.0 at the checked revision.

### 10.2 Nix

`flake.nix` should add the direct Haskell dependencies to `ghcWithPackages`. Ordinary `callCabal2nix` consumers, including agent-workflows, then receive them through the one `agentic` package.

Tree-sitter is a later, explicit packaging phase. If accepted, port the runtime and four grammar wrappers, the C shim, compiler and loader paths, Darwin install-name rewrite, and package-set overrides as one change. Export a Nix overlay or helper from agent-cat so downstream flakes do not reproduce those arguments. Until then, render unsupported languages plainly; inaccurate syntax colour is worse than no syntax colour.

### 10.3 Downstream impact

No agent-workflows source change should be required: its `wf` binary already calls `Agentic.Cli.cliMain`. Its Nix and CI gates must nevertheless be run because the `agentic` closure grows and terminal help changes. Descriptor and legacy command output remain unchanged unless the new `--tui` or `--routing` modes are explicitly requested.

### 10.4 Required changes outside `tui`

This ledger is the complete non-`tui` change surface. “No change” rows are included where an adjacent owner might otherwise acquire presentation policy by accident.

| Owner / files | Exact API or contract change | Compatibility impact | Required verification |
|---|---|---|---|
| `runtime/src/Agentic/Runtime/Descriptor.hs`; `Runtime.hs` | Introduce Text/Aeson-only `WorkflowDescriptor`, `WorkflowInputDescriptor`, strict v2/v3 codecs, and descriptor capability fields; CLI encodes and TUI decodes this one type. | Descriptor-v2 keys, value types, and array order remain compatible; JSON object-key order remains unspecified; v3 is additive and explicitly advertised. | Frozen descriptor-v2 semantic fixtures; valid/invalid v3 vectors consumed by Haskell and ext-pi. |
| `runtime/src/Agentic/Runtime/Protocol.hs`; `Machine.hs` | Add explicit protocol selection, `ResultRef`, v2 realization/progress fields, and version-directed envelope codecs; split large allowed streams before framing. | Omitted `--protocol-version` remains v1; v1 event kinds and bytes remain frozen; unknown v2 kinds never enter a v1 stream. | Existing protocol/control probes plus cross-version, frame-bound, sequence, lifecycle, and negotiation vectors. |
| `runtime/src/Agentic/Runtime/Snapshot.hs`; `Runtime.hs` | Add `initialRunSnapshot` and pure `stepRunSnapshot :: RunSnapshot -> Envelope -> Either SnapshotError RunSnapshot`. | New projection only; it changes no scheduler or denotation. | Haskell/TypeScript normalized-snapshot corpus, including every refusal transition. |
| `runtime/src/Agentic/Runtime/Store.hs` | Add store-format 2 readers/writers and generic `writeResultArtifact :: RunStore -> Value -> IO ResultRef` / `readResultArtifact`; semantic answer-store version remains 1. | Protocol-v1 runs continue writing store 1; readers accept store 1 and 2; v2 requires store 2. Cross-version lineage is permitted only after the existing program/policy/effect checks. | Store permission, atomicity, digest, size, torn-write, corrupt-version, result-order, and v1 lineage regressions. |
| `runtime/src/Agentic/Runtime/Catalogue.hs`; `Runtime.hs` | Define versioned `FrontendManifest`, `OwnerLease`, `RunRecord`, confined readers, and lenient listing which isolates corrupt entries. | Existing ext-pi manifests decode as legacy records; new fields are non-secret and additive; foreign live owners are read-only. | Legacy/new manifest goldens, owner expiry, path escape/symlink, corruption isolation, retention-parent tests. |
| `cli/src/Agentic/Cli.hs` execution core | Change `runCmdControlled` to return `IO (El r, ExecTrace)` for its `ProgramOf r`; human callers report then discard the value, while machine v2 encodes `{code,value}` and installs the artifact before terminal success. Add `--tui`, `--routing`, `--migrate-routing`, `--persona`, `--realize`, `--offline`, `--refresh-models`, and `--protocol-version` modes/options without reserving registry nouns. | Existing human run text/exits and machine-v1 output remain unchanged; v2/store2 are opt-in until clients migrate. | CLI surface/refusal probes, help/manual checks, result-code variants, no-store v2 refusal, and downstream registry-name tests. |
| `cli/src/Agentic/RoutingConfig.hs` | Add strict privileged user-v2 and restricted project-v2 decoders, persona engine/model allowlists, concrete selectors, resolved provenance, v1 normalization, and mixed-version refusal. | All-v1 files retain existing merge/route semantics; v2 managed axes use model-alias `--realize` rather than unsafe raw backend substitution. | Existing routing probe unchanged plus `doc/check-model-routing-v2.hs`, duplicate-key, precedence, migration, and property tests. |
| `cli/src/Agentic/RoutingDiscovery.hs` (new) | Add bounded `http-client`/TLS catalogue fetch, dialect normalization, private atomic cache, and offline/fresh/stale policy. | Static commands remain offline; exact ids can remain `static-unverified`; no provider response order becomes policy. | Deterministic local HTTP/TLS servers covering redirects, limits, pagination, malformed data, cache separation, and order permutation. |
| `cli/src/Agentic/RoutingInspect.hs` (new) | Render sanitized human/JSON persona, engine, model, profile, readiness, and provenance projections. | No endpoint/header/environment/secret value appears in machine JSON; ext-pi/TUI no longer need YAML knowledge. | Golden JSON, secret sentinel scan, 4 MiB output bound, and parity with resolved run policy. |
| `engine/acp/src/Agentic/Acp.hs` | Add an opaque/redacted `ChildEnvironment` to `AcpConfig`; set `CreateProcess.env` after declared-variable scrubbing. In the later rich-progress phase, project measured ACP updates to engine-neutral events. | Default config inherits today's environment when no v2 engine environment is selected; answer chunks and permission-by-intent remain authoritative. | Spawn-env sentinels, no `Show`/log disclosure, adapter argv byte tests, ACP 18-scenario gate, progress/answer separation. |
| `engine/api/src/Agentic/Engine.hs`; `runtime/src/Agentic/Exec.hs` | Phase 6 only: replace the text-only attempt callback with an optional bounded `EngineUpdateSink` carrying public answer/narration/tool/todo/usage/reasoning-summary variants; runtime maps them to v2 presentation events. | Engines may emit no optional updates; `EngineResult`, answer decode, trace, bills, memo, and scheduling remain unchanged. | Identity-neutral API test, answer-byte equality, no-progress engine fixture, bounded/redacted update tests. |
| `engine/agent-deck/src/Agentic/AgentDeck.hs` | No configuration or synthetic telemetry API is required; continue verifying persona-resolved provider/model/thinking/output against session metadata and emit only observed text. | Existing deck behavior remains exact. | Existing 10-scenario deck gate plus persona-resolved metadata mismatch cases. |
| `agentic.cabal`; root `flake.nix` | Add `tui/src`, expose only `Agentic.Tui`, hide implementation modules, and add Brick, Vty, vty-unix, async, cmark, microlens, http-client, http-client-tls, http-types, and crypton. Tree-sitter native libraries enter only in Phase 6 after its decision gate. | One physical/public package remains; downstream closure grows but dependency name stays `agentic`. | Cabal build/test, Nix flake checks, Haddock, Darwin/Linux builds, and agent-workflows' pinned Nix build. |
| `cli/ci/policies.sh` and protocol/routing gates | Add import bans for `tui` and frozen descriptor/protocol/store compatibility assertions. | Boundaries become stricter without changing runtime behavior. | Deliberate negative fixtures for every forbidden import edge and old-client fixture playback. |
| `ext-pi/src/{catalogue,types,launch,reducer,supervisor,index,monitor,monitor-ui}.ts` | Consume descriptor v3, request protocol v2 only when supported, pass persona/model-alias selections through launch, validate result/store/frontend-manifest contracts, consume sanitized routing inspection, and retain v1/legacy restore. | Pi-specific trust, grants, targets, retention, and v1 runners remain supported. | Typecheck, unit suite, shared vectors, native-target integration, restore/retention/security tests. |
| README, CLI/runtime/ext-pi guides, manual, protocol/schema documents | Publish commands, keymap, stores, schema, precedence, security, compatibility, migration, rollback, and platform limits from one canonical section each. | Existing commands remain documented as before; proposals become normative only with their implementation phase. | `make -C doc check`, manual Haskell check, help/JSON comparison, link/source coverage. |
| `~/src/agent-workflows` | No Haskell source adaptation expected; consume the enlarged `agentic` closure and inherit `wf --tui`. | Package dependency remains `agentic`; help grows only by explicit top-level options. | Cabal/Nix builds and workflows, Taskmaster, Emacs, and cookbook gates. |
| DSL, plan, cost, workflow source, Lean model/bisimulation | No TUI, persona, endpoint, secret, discovery, or presentation type enters these owners. | Denotation, authored programs, corpus, hashes, and cost folds remain unchanged. | Frozen corpus/manual hashes, Tier 0/1, bisimulation, examples, and source-import policy gates. |

## 11. Security and operational posture

The TUI is a display and control client, not a sandbox. It should preserve the following boundaries:

- Spawn with direct argv and `shell = False`; keep workflow input in mode-0600 files or stdin, never argv.
- Resolve the executable to an absolute path and constrain stores and artifact references beneath the configured state root.
- Keep supervisor and runtime directories mode 0700 and files mode 0600; use exclusive creation and atomic rename.
- Bound protocol frames, buffered stderr, output tails, in-memory scrollback, cache entries, and control text.
- Bound `list`, help, plan, and routing-inspection subprocess output to 4 MiB and 15 seconds, matching ext-pi's established catalogue boundary.
- Redact credential-shaped diagnostics and exact secret values known to the launcher before writing stderr logs.
- Record hashes and secret reference names where necessary, never secret values.
- Treat discovered model inventories, machine events, markdown, filenames, and tool output as untrusted data. They may be rendered as text but never executed or interpreted as terminal escape sequences.
- Use Vty/Brick text constructors rather than writing raw ANSI received from an engine.
- Confirm live and effectful launches with cwd, persona, and concrete realization visible. Project routing files cannot introduce credentials or endpoints; `model-routing-v2.md` owns that rule.
- A TUI crash must not leave the terminal altered. A detached run remains supervised; an attached process-owner crash leaves an orphaned store, not a falsely live record.

Markdown rendering should show raw HTML as text, as the source implementation does. Hyperlinks remain disabled unless a later design defines safe URI handling and terminal support.

## 12. Verification plan

### 12.1 Pure model and renderer

Port the behavioral claims, not test-framework shape. Unit and property tests should establish:

- every valid event transition and every invalid lifecycle transition;
- sequence, run-id, duplicate, gap, post-terminal, and frame refusals;
- selection stability under concurrent insertion and final authored reordering;
- modal FIFO ordering and no lost blocked control;
- append versus replace behavior;
- viewport re-anchoring decisions;
- bounded output, spool slices, cache age, and progress counts;
- deterministic text projections and width-aware wrapping;
- markdown block/inline parsing and diff pairing; and
- exact control payloads and terminal acknowledgements.

Use `Brick.Main.renderWidget` at fixed dimensions for selected layout goldens, while keeping the pure text projection as the principal oracle. Test narrow and wide terminals, empty catalogues, long unbroken tokens, combining characters, emoji, and unsupported colour.

### 12.2 Cross-language protocol

Create shared NDJSON fixtures containing successful, failed, cancelled, reused, retried, failed-over, redirected, steered, malformed, and v2-result runs. The Haskell and TypeScript reducers must produce the same normalized JSON snapshot or the same refusal class.

Protocol-v1 fixtures remain frozen. v2 negotiation tests prove that old clients receive v1 by default and that new clients request v2 explicitly.

### 12.3 Process and terminal integration

Use deterministic stub ACP and deck fixtures only. PTY tests should cover:

- `--tui` catalogue startup and clean exit;
- workflow input editing, bracketed paste, preview, and cancellation;
- live concurrent occurrences with scrollback larger than memory windows;
- steer, retry/failover/abandon, redirect, detach, and reattach;
- child crash, malformed frame, torn frame, oversized output, and forced process-group termination;
- final result artifact and run reconstruction; and
- terminal restoration after normal exit, exception, and interrupt.

A stress fixture should deliver at least 10 MiB in small chunks across concurrent attempts while measuring bounded resident growth and responsive controls. Performance assertions should target established failures—quadratic partial-line concatenation, unbounded viewport contents, and ever-growing render caches—rather than arbitrary frame-rate numbers.

### 12.4 Repository gates

The implementation phases should run, as applicable:

- `nix develop path:. -c cabal build all -v0` and `cabal test all -v0`;
- CLI policy, examples, routing-config, ACP, deck, lineage, and control gates;
- documentation checks;
- ext-pi type, unit, and integration suites with a freshly built runner; and
- agent-workflows Cabal/Nix builds and workflow, Taskmaster, Emacs, and cookbook gates.

No paid or live route is part of acceptance.

## 13. Phased implementation roadmap

Each phase is independently reviewable and leaves existing non-TUI behavior green.

### Phase 1 — Shared descriptor, snapshot, result, and run-catalogue contracts

**Prerequisites and dependencies:** the frozen descriptor-v2, protocol-v1, control, and store-v1 fixtures are the baseline; `aeson`, `stm`, and `crypton` provide the implementation substrate; ext-pi's current reducer and restore tests are available as the cross-language oracle.

**Affected areas:** `runtime/src/Agentic/Runtime/{Descriptor,Protocol,Snapshot,Store,Catalogue}.hs`, runtime tests, ext-pi fixture corpus and manifest reader, CLI descriptor/machine encoding.

**Work:** extract the neutral descriptor codec; add the pure Haskell snapshot reducer; create cross-language descriptor/protocol vectors; implement the negotiated protocol-v2 result contract from Section 8.3; define a versioned frontend manifest, owner record, and read-only run-catalogue projection compatible with existing ext-pi stores; preserve descriptor v2, protocol v1, and legacy manifests.

**Risks:** accidental v1 byte drift; a store-version transition that makes lineage unreadable; Haskell/TypeScript lifecycle divergence; and terminal success emitted before the durable result. Each is gated in this phase before UI work begins.

**Acceptance:** descriptor-v2 keys/types/array order and protocol-v1 bytes remain accepted and unchanged; Haskell and TypeScript projections agree over the corpus; result files are private, bounded, hashed, schema-checked, ordered, and path-confined; legacy and versioned manifests reconstruct deterministically; all runtime/ext-pi tests pass.

### Phase 2 — Persona-aware routing v2

**Prerequisites and dependencies:** Phase 1's descriptor, store, and manifest contracts are complete; version-1 routing probes remain frozen; `http-client`, `http-client-tls`, `http-types`, and `crypton` are available in the pinned package set; the user/project trust split is accepted.

**Affected areas:** `Agentic.RoutingConfig`, CLI grammar and preflight, ACP process environment, target policy/manifest, new discovery module, tests, examples, and documentation.

**Work:** implement `model-routing-v2.md`; keep v1 compatibility; add sanitized `--routing --json`, persona selection, discovery/cache, secret indirection, and model-alias overrides; freeze non-secret provenance before launch.

**Risks:** credential disclosure, project-layer privilege escalation, nondeterministic inventory ordering, stale cross-account caches, and v2 overrides detached from their engine. The executable design oracle, secret sentinels, and local HTTP fixtures cover these before a live adapter is admitted.

**Acceptance:** all worked persona/discovery/failure examples resolve exactly as specified; no secret reaches argv, JSON, logs, stores, diagnostics, or an unselected child environment; v1 routing tests remain unchanged.

### Phase 3 — TUI catalogue and launch shell

**Prerequisites and dependencies:** Phases 1 and 2 are complete; Brick 2.9, Vty 6.4, vty-unix 0.2.0.0, async, cmark, and microlens build in the pinned shell; `--routing --json` and protocol-v2 machine mode are stable.

**Affected areas:** `tui/src`, `agentic.cabal`, `flake.nix`, `Agentic.Cli` command grammar, source-boundary CI.

**Work:** add Brick/Vty dependencies and `Agentic.Tui`; implement explicit `--tui`; discover the current executable's descriptor; browse workflows, versioned run records, and sanitized routing; collect source-aware inputs; preview plan/cost and concrete realization; confirm; spawn protocol-v2 machine mode with a private store and fd-3 controls.

**Risks:** terminal state left altered, catalogue subprocess deadlock or overflow, a new frontend path bypassing CLI policy, and a dependency closure that breaks downstream `wf`. PTY cleanup, strict output bounds, process-only integration, and agent-workflows builds are release gates.

**Acceptance:** `agentic-run --tui` and downstream `wf --tui` browse their own registries and run catalogues; persona and concrete model are visible before live launch; existing commands retain byte/exit behavior; invalid input or setup creates no run; PTY exit restores the terminal.

### Phase 4 — Live monitor, controls, persistence, and final view

**Prerequisites and dependencies:** Phase 3 supplies the application shell and owned machine process; Phase 1 supplies snapshots/results/catalogues; existing runtime control acknowledgements and private store semantics are unchanged.

**Affected areas:** remaining TUI model/app/spool modules, process supervision, protocol/store readers.

**Work:** implement occurrence/attempt dashboard, bounded scrollback, detach/reattach, exact controls, process-group cancellation, owner heartbeat, history/lineage actions, and verified final-result rendering.

**Risks:** stale controls presented as delivered, a concurrent modal orphaning its waiter, unbounded stream/cache growth, selection moving under concurrency, and children surviving owner exit. Lifecycle fixtures, identity-keyed state, bounded spools, stress tests, and process-group cleanup address these.

**Acceptance:** deterministic fixtures exercise every control and terminal state; foreign live owners are read-only; restart reconstruction is fail-closed; result verification follows Section 8.3; memory remains bounded under the stress stream.

### Phase 5 — ext-pi convergence

**Prerequisites and dependencies:** Phases 1, 2, and 4 are complete; ext-pi passes its descriptor-v2/protocol-v1 restore and native-target suites; shared state-root behavior has an explicit configuration rather than an implicit default.

**Affected areas:** ext-pi catalogue/index/types/reducer/supervisor and the shared protocol fixtures.

**Work:** consume sanitized routing inspection; expose persona/profile choices; migrate ext-pi to negotiated v2 and the versioned frontend manifest/result reference; retain descriptor-v2/protocol-v1 compatibility.

**Risks:** old runners being asked for v2, mixed manifest/store versions misclassified as corrupt, foreign owners becoming controllable, and Pi trust/grant/remote behavior regressing. Negotiation, legacy fixtures, owner tests, and the full ext-pi integration suite gate release.

**Acceptance:** both interfaces report the same selected persona, concrete realization, provenance, controls, terminal result, and failures for one fixture run; Pi-only trust/grant/remote behavior remains unchanged.

### Phase 6 — Rich progress and rendering

**Prerequisites and dependencies:** Phase 4's bounded renderer and Phase 5's shared v2 projection are complete; product decisions on public-progress retention and tree-sitter distribution are resolved; measured ACP update shapes and native grammar packages are pinned.

**Affected areas:** engine-neutral optional progress types, ACP update parsing, protocol v2, TUI markdown/highlight, ext-pi projection; optionally Cabal/Nix tree-sitter support.

**Work:** surface only demonstrated public progress; add tool/checklist/usage panels; port markdown and pure diff/status highlighting; then add tree-sitter grammars if structured file/tool events justify them.

**Risks:** transport narration contaminating answers, tool output leaking credentials, private reasoning being exposed, unbounded vendor payloads, native grammar ABI/link failures, and synthetic detail on Agent Deck. Typed channels, redaction/bounds, explicit omission, and cross-platform package builds are mandatory.

**Acceptance:** answer bytes and semantic traces remain unchanged; unsupported engines remain honest; progress is bounded and redacted; tree-sitter builds on Darwin and Linux and through agent-workflows' Nix consumer before language highlighting becomes default.

### Phase 7 — Documentation and release hardening

**Prerequisites and dependencies:** Phases 1–6 and their decision gates are complete; final command/schema/protocol names are stable; all canonical documentation owners are identified.

**Affected areas:** README, module guides, manual, protocol documents, CI.

**Work:** document commands, keys, stores, routing, accessibility, compatibility, and operational limits; run the entire non-paid agent-cat and agent-workflows suites.

**Risks:** prose or help drifting from executable contracts, a portability claim outrunning macOS/Linux evidence, and unresolved review findings being hidden by broad green tests. Source-derived checks, PTY tests on supported systems, and a final independent review close the phase.

**Acceptance:** every source/API boundary is gated; docs and help agree; no open high-severity review finding remains; migration and rollback procedures are explicit.

## 14. Settled and open decisions

### Settled by this design

- one physical/public `agentic` package;
- `tui/` source ownership with one public facade and hidden implementation modules;
- explicit `--tui` mode rather than a new name-colliding verb or TTY-sensitive mutation of `run`;
- machine-process boundary shared with ext-pi;
- pure reducer and stable textual projection;
- no routing YAML parsing in either frontend;
- no permission-policy override in the TUI;
- no MCP nested-run port;
- no invented token accounting or private reasoning stream;
- Brick from pinned nixpkgs rather than a one-off overlay; and
- tree-sitter only after structured progress supplies a consumer.

### Product decisions required before their implementation phase

1. **Person-addressed questions:** should a local TUI become an authoritative human answerer, replacing the current ACP limitation? This changes semantics and cannot be inferred from the UI request.
2. **Shared state root:** should TUI and ext-pi share one default catalogue, or merely support an explicitly shared `AGENT_CAT_STATE_DIR`? The latter is the conservative default.
3. **Public progress retention:** which tool/checklist/usage fields may be persisted, and which remain ephemeral? Private reasoning is excluded either way.
4. **Tree-sitter distribution:** is full language-aware highlighting worth making native grammar libraries part of every downstream `agentic` build? The implementation can deliver all workflow behavior before this choice.

None of these decisions blocks Phases 1 and 2.

### Residual risk register

| Residual risk | Present posture | Gate or mitigation |
|---|---|---|
| Human addressee remains routed through the selected engine | The TUI does not intercept it or imply a person answered | Separate owner decision and semantic tests before any change |
| Persona is not credential isolation | Selected adapter environment is scrubbed only for declared variables; adapter config files remain ambient | Explicit documentation, secret sentinels, and OS/profile isolation where required |
| Authenticated inventory can disagree with ACP or adapter fallback | Catalogue is advisory selection evidence; adapter preflight is final, and actual attempt target remains recorded | Preflight before spend and provenance in every run |
| SIGKILL can strand an owned child | No daemon is introduced; heartbeat expiry marks the record orphaned and read-only | Process groups, normal exception cleanup, owner-lease tests, documented manual cleanup |
| Initial TUI is macOS/Linux only | Current fd-control and cancellation contracts are POSIX-specific | No Windows claim; separate control-handle/process-tree design before support |
| The 64 MiB result ceiling may reject an unusually large successful computation | Oversize cannot be called successful without a durable value | Stress fixtures and an explicit future store-version decision if real results approach the bound |
| Brick/Vty/provider APIs continue to change | Versions and checked dates are recorded, but are not promises | Revalidate external sources and run platform/package gates at phase start |
| Rich tool/usage/checklist availability differs by engine | Optional progress is never synthesized; Agent Deck may remain text-only | Phase 6 decision gate and no-progress fixtures |
| A shared TUI/ext-pi state root can expose private run metadata to another local frontend process | Sharing is opt-in; files remain owner-private and foreign live owners are read-only | Explicit `AGENT_CAT_STATE_DIR`, mode checks, path confinement, owner tests |

## 15. Source register

### 15.1 Local source

- agent-functor `src/Agent/Tui/{App,Flows,Highlight,Live,Markdown,Theme,ViewModel}.hs`, tests, `Agent.Run`, `Agent.RunGraph`, `cbits/ts_shim.c`, `agent-functor.cabal`, `flake.nix`, `doc/spec.md` Part 5, and `doc/architecture.md`, revision `828043c8f4b08ecf7f93a4a0135a72ddc19d2594` plus the recorded local `flake.nix` Darwin change.
- agent-cat `agentic.cabal`; `Agentic.Cli`; `Agentic.RoutingConfig`; `Agentic.Engine`; `Agentic.Runtime.{Protocol,Control,Store,Machine}`; `Agentic.Exec`; ACP and Agent Deck adapters; ext-pi source and README, revision `9df3cd3b6d42fa315b82b43db1749643cb45d9c4`.

### 15.2 External sources

- Brick 2.9 package metadata: <https://hackage.haskell.org/package/brick-2.9>
- Brick 2.9 User Guide, including `App`, custom events, forms, viewports, cache, mouse, paste, and Unicode width: <https://hackage-content.haskell.org/package/brick-2.9/src/docs/guide.rst>
- Brick 2.9 `Brick.Main` API: <https://hackage-content.haskell.org/package/brick-2.9/docs/Brick-Main.html>
- Brick 2.9 `Brick.BChan` API: <https://hackage-content.haskell.org/package/brick-2.9/docs/Brick-BChan.html>
- Brick 2.13 release history, used only for comparison beyond the pinned version: <https://hackage.haskell.org/package/brick-2.13/changelog>
- Vty 6.4 architecture, terminal features, width tables, and threaded-runtime requirement: <https://hackage-content.haskell.org/package/vty-6.4/src/README.md>
- Vty 6.4 release history: <https://hackage-content.haskell.org/package/vty-6.4/src/CHANGELOG.md>
- Vty 6.6 release history, used only for current-version comparison: <https://hackage-content.haskell.org/package/vty-6.6/src/CHANGELOG.md>
- vty-unix 0.2.0.0 pinned package and platform scope: <https://hackage.haskell.org/package/vty-unix-0.2.0.0>
- vty-unix 0.4.0.0 package, used only for current-version comparison: <https://hackage.haskell.org/package/vty-unix-0.4.0.0>
- vty-crossplatform 0.4.0.0 pinned package: <https://hackage.haskell.org/package/vty-crossplatform-0.4.0.0>
- vty-crossplatform 0.5.0.0 security change, used for comparison: <https://hackage.haskell.org/package/vty-crossplatform-0.5.0.0/changelog>
- cmark 0.6.1 package and bundled libcmark description: <https://hackage.haskell.org/package/cmark-0.6.1>
- brick-skylighting 1.0 licensing and syntax-definition choices: <https://hackage.haskell.org/package/brick-skylighting-1.0>

Volatile versions and APIs should be rechecked when their implementation phase begins.
