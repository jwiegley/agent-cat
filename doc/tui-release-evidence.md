# TUI release evidence

This record maps the production `agentic-run --tui` and downstream `wf --tui`
requirements to executable evidence. The initial matrix covered the uncommitted tree
based on `fc149f18c3407ff12f6b5c9d8b08ef2e9e306701`. The current responsive and
failure-reporting follow-ups cover the uncommitted tree based on
`828e8cacb7ce37c0ffc01b8576562f8747a59868`. The initial matrix was recorded on
2026-09-04, descriptor-root and lifecycle follow-ups were validated on 2026-09-05,
and the responsive presentation and failure-reporting follow-ups were validated on
2026-09-07 as qualified below. The final independent completion audit approved goal
`mtm03s1f-737bbz` after inspecting sources, regressions, retained platform logs, and
the corrected compiler-parsed boundary gate. No paid route, commit, push, or
publication was performed.

## Requirement-to-test matrix

| Requirement | Implementation evidence | Executable evidence |
|---|---|---|
| Descriptor-v2 compatibility and descriptor-v3 negotiation | `Agentic.Runtime.Descriptor`; v1 fallback in `ext-pi/src/catalogue.ts` | `runtime-contract-test`; `ext-pi/test/catalogue-launch.test.ts`; `cli/ci/policies.sh` |
| Protocol-v1/store-v1 compatibility and strict protocol-v2/store-v2 | `Agentic.Runtime.Protocol`, `Machine`, `Snapshot`, and `Store` | Shared vectors under `test/fixtures/runtime/`; Haskell and TypeScript reducer tests; Tier 0 and Tier 1 |
| Private, confined, bounded, digest-verified state | Shared `PrivateRoot`, `PrivateFile`, `Store`, `Catalogue`; root identity handoff to children | Root/descendant replacement, closed descriptors, unowned temporaries, FIFO refusal, descriptor-relative enumeration, 1000-entry bound, and real CLI identity checks |
| Local person answering with FIFO delivery and terminal acknowledgement | `Agentic.Runtime.Control`; `Agentic.Tui.Person` | `test/person_control_probe.py`; `test/person_lineage_probe.py`; mixed-kind and retry PTY cases in `test/tui_probe.py` |
| Strict post-input plan facts and catalogue identity | `Agentic.Runtime.Plan`; `Tui.Client.validateExactPlanIdentity`; typed `LaunchPreview` | Runtime malformed/version/fold/input-dependent tests; PTY exact-fact, malformed-plan, and identity-mismatch refusals |
| Persona routing, inventory provenance, opaque target kind/argv, and immutable launch preflight | `RoutingConfig.V2`, `RoutingDiscovery`, `RoutingInspect`, `RoutingSecrets`; `Tui.Types` | `cli/ci/routing-config.sh`; `RoutingV2Probe`; TUI persona/argv PTY assertions |
| Responsive fixed shell, asynchronous loading, explicit focus/help, and terminal-default colour | `Tui.Presentation`, with worker events and modal precedence in `Tui.App` | Vty cell-raster checks at five dimensions, the ANSI current-screen PTY parser, and focus/help, loading, resize, and `NO_COLOR` assertions |
| Terminal-control neutralization for untrusted display text | The shared `Tui.Presentation` text constructors replace control characters before constructing Vty cells | Real-cell regression with embedded escape and carriage-return characters; all PTY output remains current-screen parsed |
| Workflow browser with fuzzy filtering and descriptor facts | `Tui.Model.visibleWorkflows`, `fuzzyMatch`, concise rows, and list/detail rendering in `Tui.Presentation` | 400 QuickCheck cases, `workflow-filter.golden`, and a narrow 80-column PTY filter and focus test |
| Run browser with lineage, persona, realization, bills, result availability, and ownership | `Tui.Model.runLine`; sanitized runtime policy retained by `Runtime.Catalogue` | `run-browser.golden`; real `agentic-run` terminal-run catalogue PTY assertions |
| Routing browser with symbolic chains and concrete inventory provenance | Typed `RoutingProfileChoice`, `RoutingRungChoice`, and `RoutingInventoryChoice` | `routing-browser.golden`; narrow PTY profile/inventory assertions; routing schema gate |
| Descriptor-ordered, source-aware input collection | `Tui.Model`, Brick editors, and `Tui.Client.writeInputs` | Multiline/stdin/model tests, bracketed paste containing command keys, resize and backward-draft preservation, and PTY body-omission checks |
| Compact launch review and scrollable exact details before confirmation | `buildLaunchPreview`, `confirmSummaryView`, `confirmationDetails`, typed exact-plan facts, and credential readiness | Cell-derived boundary tests prove that every fact plus launch/back/detail controls fits before consent is enabled. The normal 80×24 case permits consent, compact incomplete reviews refuse `y`, and exact argv, fold, pin membership, limits, provenance, and fingerprints are asserted. |
| Direct argv machine launch, fd 3 control, ownership, termination, and reap | Shared `Runtime.ProcessGroup`, pre-adoption activation gate, native non-reaping observation, CLI fd bootstrap, patched Linux boot library | Deterministic immediate-failure activation probe; Darwin and default-limit x86_64 Linux spawn and full PTY gates; redirected/pipe-holding descendants, TERM-resistant groups, blocked-control interruption |
| Identity-stable live occurrence/attempt monitor with bounded scrollback | `Runtime.Snapshot`, `Tui.RunModel`, line-level output tail, responsive occurrence/detail panes, and explicit follow state | Pure authored-reorder and huge-unterminated-line tests, narrow/wide PTY runs, concurrent 10 MiB stress, and bounded viewport checks |
| Human run state, frozen terminal elapsed time, and immediate complete failure disclosure | `Tui.Presentation.liveContext` and `liveFailureView`; `Tui.RunModel.runFailureLines`; one-second typed ticks | Startup and post-request failure PTY cases at 40×12, 80×24, and 140×36; complete scrollable run details; actual stored ACP failure replay; terminal bills |
| FIFO person/recovery decisions, redirect, steering, cancellation, detach/reattach, and lineage | One run/sequence/occurrence/kind-tagged mandatory FIFO; separate modal editors; confined parent revalidation before preview, preparation, and spawn | Reversed-batch sequence property, mixed-kind PTY ordering, steering-draft preemption, two simultaneous recovery producers, exact controls, and foreign-heartbeat lineage refusals |
| Typed public progress distinct from answers and private reasoning | `EngineUpdate`, `Exec.publicProgressOf`, ACP projection | `test/progress_probe.py`; ACP 20-scenario gate; shared progress vectors; answer/trace/bill equality checks |
| Bounded/redacted tool, todo, usage, message, and explicit reasoning summaries | Runtime projection plus exact selected-secret redaction | Routing secret run and progress probes; ext-pi/TUI reducer/render tests |
| Verified final result plus explicit save/copy path | Store result reference, TUI verified load, exclusive mode-0600 save prompt, ext-pi verifier | PTY save/copy assertion; Haskell artifact tests; ext-pi digest/canonical/symlink/large-integer cases |
| More than 65,536 protocol events and bounded journal state | One-entry ext-pi digest history and raw-byte prefix verification | 65,537-progress-event dual-journal terminal restore; 65,540-event reducer property |
| Plain/Markdown/status/unified-diff rendering without unjustified native grammars | `Tui.Highlight` | Pure classification/golden checks and PTY diff forms; dependency rejection in `tui/ci/tui.sh` |
| TUI/runtime import boundary and agent-cat as sole interpreter | Shared GHC header-parser gate; Runtime facade and source-owned TUI allowlist | Both CLI/TUI gates run 25 explicit syntax/TUI fixtures and 233 generated forbidden-edge fixtures; isolated executable rejects real forbidden imports |
| Opt-in frontend state sharing and runner-specific defaults | `tuiCmd` state-root selection and frontend-manifest v2 | Default-state PTY assertion; TUI/ext-pi shared manifest/restore tests |
| macOS/Linux support and terminal restoration | POSIX fd/process-group implementation; three-system flake | Darwin PTY normal/exception/signal tests; Darwin and Linux builds below |
| Downstream `wf --tui` uses its own 74-workflow registry | Public `Agentic.Tui` facade reached through `cliMain` | Downstream gates and a scripted `wf --tui` `hello-world` PTY launch |

## Fresh validation record

### Name-only workflow rows

The workflow list now renders one name per row, with the selected description
retained in the details pane. The visible-cell regression covers 40 by 12, 80 by
24, and 140 by 36 cells and failed against the previous two-line renderer in
`/tmp/agent-cat-name-only-regression.GAA6Cn`. The complete TUI and documentation
gates pass in `/tmp/agent-cat-name-only-gates.UtmwKy`, and rendered frames are
retained in `/tmp/agent-cat-name-only-gallery.1FPKZ2`.

The operator authorized activation of this refinement. The downstream build
`/nix/store/bjc11iwkp7kkjf40vkkdmbhcv850dnsh-agent-workflows` passed package and
installed-binary PTY checks. Generation `system-1237-link` selects
`/nix/store/3gsbj20qcrh3ngv74j0nkimjn8dizdf5-darwin-system-26.11.4cff07d`, and
the installed `wf` is byte-identical to
`/nix/store/wxkhjxa7w5vcvh817rgqkl6cgcyjs9fy-agent-workflows-0.1.0.0/bin/wf`.

Evidence is retained in `/tmp/agent-cat-name-only-package.37gFTH` and
`/tmp/agent-cat-name-only-deployment.LYweik`. The latter contains candidate and
installed smoke logs, the generation build, closure comparison, and activation
log. Checks cover adjacent name-only rows and retained descriptions at all three
sizes, filtering, consent after resize, scripted Spanish HelloWorld, verified
mode-0600 export, clean exit, and terminal restoration.

The generation preserves the concurrently activated Pi update from Nix revision
`cfd4b3d545b8d9a4ed7f41275a74d76221d01065`. Generation 1236 remains available,
and both deployment checkouts remain clean. Nonfatal zsh `zle` activation warnings
are retained in the log. Local input overrides remain necessary because no
downstream pins were changed.

### Reading-oriented presentation follow-up (2026-09-08)

The browser now shows workflow descriptions and an input/result overview, with
inline search that updates matching rows during editing. The live request rail
takes at most one quarter of a wide terminal, capped at 32 columns. The reading
pane separates answer output from protocol diagnostics. Paragraph spacing, code
fences, compact recovery controls, and an inline steering editor are covered by
the production renderer and deterministic interaction tests. Restored live targets
retain their live billing warning across restart, resume, and fork.

Fresh Darwin evidence for this follow-up is retained at:

- `/tmp/agent-cat-layout-final-source.Go8p9z`: complete TUI gate, including public
  progress, source boundaries, descriptor closure, model properties, visible-cell
  rendering, FIFO controls, stress, process ownership, and terminal restoration.
- `/tmp/agent-cat-layout-docs.341juO`: manual prose, structure, and Haskell checks.
- `/tmp/agent-cat-layout-package.XBo1Kw`: downstream package build at
  `/nix/store/qwpqxxxzyadjdad61spr08bnvb428i7z-agent-workflows`.
- `/tmp/agent-cat-layout-packaged-smoke.kqrb7H`: packaged 74-workflow catalogue,
  inline search, responsive consent refusal, scripted Spanish HelloWorld, readable
  verified result, exclusive mode-0600 export, and terminal restoration.
- `/tmp/agent-cat-layout-gallery`: HTML exports of actual Vty spans at 40 by 12,
  80 by 24, and 140 by 36 cells. Selected PNG exports were inspected through
  AppKit with a matching SDK. The export palette illustrates terminal-default
  colors and does not impose a background on the application.

The browser automation extension refused its installed version mismatch. Initial
preview exports showed HTML source rather than terminal cells and were not used
as visual evidence. The native renderer initially encountered an SDK mismatch
before the matching installed SDK was selected. Earlier failing PTY assertions
and their logs remain separate from the passing final gate.

The operator authorized Darwin activation after the candidate passed validation.
Generation `system-1235-link` selected
`/nix/store/wqcvfb2rpnlj37z4v4m0pdvm3yq70ss9-darwin-system-26.11.4cff07d`.
The installed `/etc/profiles/per-user/johnw/bin/wf` resolved to
`/nix/store/dlaf8swpc4ss3p08212h9bkn11yhmwaw-agent-workflows-0.1.0.0/bin/wf`
and was byte-identical to the tested candidate. The build used the immutable
agent-cat source at `/nix/store/65hp0pghjvscms3hvhxwdxc3dqa6jszm-source`, whose
code, tests, and Nix definitions matched the working tree at activation. Only
subsequent release evidence differed at that point.

Activation evidence is retained at:

- `/tmp/agent-cat-layout-darwin-build.osMr9v`: generation build from clean
  deployment checkouts with local input overrides and no lock-file changes.
- `/tmp/agent-cat-layout-darwin-activate.NGN8j8`: successful Darwin and Home
  Manager activation. Nonfatal root HOME and zsh `zle` warnings are retained.
- `/tmp/agent-cat-layout-installed-tui.qvcPF9`: installed binary identity, the
  74-workflow browser at all three dimensions, inline search, resize consent,
  scripted Spanish HelloWorld, readable result, exclusive mode-0600 export,
  clean exit, and terminal restoration.

Generation 1234 remains available. The deployment checkouts remain clean, and
ordinary switches can revert this local override until downstream pins change.
No live provider request, commit, or publication was performed. Fresh Linux
evidence does not yet cover this presentation change, and operator visual
acceptance remains distinct from the passing functional gates.

### Responsive presentation follow-up (2026-09-07)

The responsive follow-up adds `Agentic.Tui.Presentation` as the one Brick rendering
surface used by the application and fixed-size tests. It does not add an execution
path. The TUI still imports only the public `Agentic.Runtime` facade and TUI-owned
modules. Plan construction, route resolution, policy, workflow interpretation, store
semantics, protocol reduction, and control delivery remain with their existing
owners. `Agentic.Runtime.Plan` now owns strict decoding of the existing exact-input
plan contract. The process supervisor adds only a pre-adoption callback gate and
retains the existing process-group owner. The follow-up changes the root and TUI
documentation, `agentic.cabal`, the Runtime facade and plan decoder, Runtime contract
tests, three TUI goldens, the Python fixture and PTY probe, `Agentic.Tui`, `App`,
`Client`, `Model`, `Presentation`, `Process`, `RunModel`, `Types`, and the TUI model
test. No CLI, engine, protocol, control, store, or workflow production source changes
in this follow-up.

The fixed shell enters Vty before discovery and keeps context, status, and applicable
actions outside bounded viewports. Workflow, run, routing, occurrence, and output
surfaces use concise list/detail panes. Wide layouts show both panes and narrow layouts
show the focused pane. Confirmation has a compact review and a scrollable exact layer.
The compact size, ask count, fold, capability, and pin facts come from the strict
post-input plan rather than the catalogue row. Relevant routing chains use exact pin
membership. The exact layer labels its digest as the plan-program SHA-256, while
restored run details retain the runtime program SHA-256 label. Input bodies and the
raw program are absent from both confirmation layers.

The pure render test converts Brick pictures through Vty's `displayOpsForPic` and
checks output-cell widths at 140×36, 80×24, 40×12, 24×6, and 1×1. It includes long
paths, arguments, warnings, routing profiles, wide characters, combining characters,
and emoji. It verifies final footer placement, visible warning and consent actions,
the content-derived fit boundary, exact details, selected-row visibility, one-row
status normalization, long-token wrapping, and terminal-default monochrome attributes.

The PTY probe now reconstructs Vty's current screen with a bounded ANSI cell parser
instead of treating append-only terminal bytes as a screen. It exercises rapid resize
sequences through 1×1, refusal of `y` at 24×6, state restoration at 80×24, details
mode across resize, explicit list/detail focus and key help, a nonempty `NO_COLOR`, a
credential-unready engine, strict post-input fact changes, malformed and identity-
mismatched plan refusal, and asynchronous loading. A bracketed multiline paste
contains `?`, `q`, `c`, and `s` and remains editor content through resize and backward
navigation. A plain `c` remains person-answer text, while Escape reaches confirmed
cancellation. Mixed person/recovery decisions prove cross-kind FIFO order, and a
person decision preempts and then restores an unsent steering draft. Existing
lifecycle, stress, result verification, save, ownership, and terminal-restoration
assertions remain in the same suite.

The original 80×24 live confirmation consumed every available row with one large
border and left no launch or refusal action visible:

```text
agent-cat
[Workflows]  Runs  Routing
confirm launch
┌──────────────────────────────launch confirmation─────────────────────────────┐
│ Workflow: control-stress                                                     │
│ Runner executable: .../test/tui_fixture_runner.py                            │
│ Exact target arguments: ["--session", ...]                                  │
│ Target: live: fixture-engine ...                                             │
│ Program SHA-256: ffbc2dfc...                                                 │
│ Concrete realization: fixture-profile: fixture #0 -> fixture-model ...       │
│ Input bodies and secret values are intentionally omitted.                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

The same fixture and terminal size now retain the warning, concise decision facts,
and the primary actions in the final row. No run directory exists at this point:

```text
agent-cat / launch confirmation
workflow control-stress
    ┌────────────────────── CONFIRM LIVE RUN [focus] ──────────────────────┐
    │ LIVE BACKEND: PROVIDER CHARGES MAY APPLY                             │
    │ Workflow  control-stress                                             │
    │ Persona   fixture (default)                                          │
    │ Target    fixture-engine / deck / deck:fixture-session /             │
    │ fixture-provider / READY                                             │
    │ Routing   fixture-profile -> fixture-model                           │
    │ Plan      pipeline; size 1; ask nodes 1                              │
    │ Requests  1..1 occurrences / 1 paths; consult 1, observe 0, effect 0 │
    │ Effects   effectful no; tool execution no                            │
    │ Directory /Users/johnw/src/agent-cat/.worktrees/tui                  │
    │ Warnings  none                                                       │
    └──────────────────────────────────────────────────────────────────────┘
confirm launch
Enter/y LAUNCH   n/Esc BACK   d DETAILS   ? KEYS
```

Fresh local verification used only deterministic fixtures and the supported root Nix
shell:

```console
$ nix develop path:. -c cabal build all -v0
$ nix develop path:. -c cabal test -v0 runtime-contract-test
runtime contracts: descriptor, protocol, controls, snapshot, store, and shared fixtures passed
$ nix develop path:. -c cli/ci/policies.sh
policy imports: compiler-parsed module boundaries verified; 25 syntax/TUI fixtures and 233 forbidden-edge fixtures passed
policy probe: all checks passed
lineage probe: all checks passed
control probe: stdin, EOF, cancel, steer, retry/failover/abandon, redirect, and frame refusal passed
person control probe: setup refusal, typed validation, FIFO, private prompt artifacts, ack ordering, persistence, and no-attempt invariant passed
person lineage probe: legacy filtering, local resume, restart, explicit fork replacement, and blocked cancellation passed
$ PYTHONDONTWRITEBYTECODE=1 nix develop path:. -c tui/ci/tui.sh
policy imports: compiler-parsed module boundaries verified; 25 syntax/TUI fixtures and 233 forbidden-edge fixtures passed
+++ OK, passed 200 tests.
+++ OK, passed 200 tests.
tui model/property/golden/render tests: all checks passed
progress probe: bounded public progress is persisted, redacted, optional, and answer-neutral
spawn probe: nofile=1048576, inherited FD closure, stdio, session, and exec failure passed
tui probe: all checks passed
```

The double-signal helper-shutdown case also passed ten consecutive focused runs. The
case now synchronizes normal quit against an active initial-discovery worker and
signal shutdown against an active help worker. The application ignores later
termination signals only after the first signal or normal shutdown has begun. It also
uses Vty's idempotent shutdown inside the protected cleanup region. This closes the
interval in which another signal could interrupt alternate-screen restoration.

```console
$ nix develop path:. -c make -C doc check
manual coverage: 243 source items accounted for, classified, and indexed
manual prose: prohibited patterns absent; no three-sentence staccato run
tui release evidence: requirement matrix, platforms, and unavailable checks recorded
$ nix develop path:. -c make -C doc check-haskell
manual CLI: registry, help, plan, cost, scripted run, exits, and defaults verified
manual members: 130 compiler-exported children and 112 exported-class instances verified
```

The current `aarch64-darwin` package and downstream workflow surface were checked from
an isolated clone with an empty XDG configuration root. The first setup invocation
stopped before compilation because the clone's required `../agent-cat` sibling was
absent. The corrected invocation below links that sibling to this worktree, and the
package build overrides its `agent-cat` flake input with the same path:

```sh
root=$(mktemp -d)
git clone -q --no-local /Users/johnw/src/agent-workflows "$root/agent-workflows"
ln -s /Users/johnw/src/agent-cat/.worktrees/tui "$root/agent-cat"
mkdir "$root/xdg"
cd "$root/agent-workflows"
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" nix develop path:/Users/johnw/src/agent-cat/.worktrees/tui -c bash ci/workflows.sh
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" nix develop path:/Users/johnw/src/agent-cat/.worktrees/tui -c bash ci/cookbook.sh
wf_out=$(env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" nix build path:.#agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-link --print-out-paths)
nix-store --verify-path "$wf_out"
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" "$wf_out/bin/wf" run hello-world --scripted --input-arg language=
```

The workflow gate reported `74 workflow(s) pinned, 0 failed`, the cookbook gate
reported `74 row(s) documented, 0 failed`, and the final downstream package built with
exit status zero and passed Nix store-path verification. The packaged CLI returned
`¡Hola, mundo!`. A packaged `wf --tui` PTY smoke at 80×24 then
filtered the 74-row catalogue to `hello-world`, accepted the empty `language` input,
showed `CONFIRM SCRIPTED RUN` and its final-row launch action, completed the scripted
run, displayed the verified result on demand, copied `¡Hola, mundo!` to a new
mode-0600 file, returned to the Runs browser, and restored the terminal on exit.

No paid backend, remote host, downstream publication, commit, or push was used for
this follow-up. Earlier Linux results remain historical evidence for their recorded
revisions. They do not validate the presentation, exact-plan decoding, or activation
changes introduced here on Linux.

### Handoff validation: routing-warning disclosure

The coordinator exercised the first reviewed package with the actual Claude-only
project override and the user-owned routing inventory. Although the launch action
was visible at 80×24, eight warnings for the whole persona still filled the review.
The compact view now reports the warning count, and the complete warnings appear
first in exact details. No warning is classified or discarded by matching its text.
The visible target, exact-plan facts, working directory, effects, and billing warning
remain prerequisites for launch consent.

A new cell-render regression with twelve inventory warnings and a long macOS-style
working directory failed before this correction and passed afterward. The existing
overflow fixture now makes the required directory, rather than expandable diagnostics,
exceed the viewport. The full `tui/ci/tui.sh` gate passed again, including model,
property, render, source-boundary, public-progress, spawn, lifecycle, and PTY checks.
Its log is `/tmp/agent-cat-ui-handoff-gates.f73Alb` (`HANDOFF_TUI_GATE_EXIT=0`).

The final handoff package was rebuilt with:

```sh
nix build path:/Users/johnw/src/agent-workflows#packages.aarch64-darwin.agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-write-lock-file --no-link --print-out-paths --max-jobs 2 --cores 4
nix-store --verify-path /nix/store/3149q1n00rmp5np44yvwb6wiai16d7dq-agent-workflows
```

The build log `/tmp/agent-cat-ui-handoff-package.5Sfgeu` ends
`HANDOFF_PACKAGE_EXIT=0`. The delivered executable is
`/nix/store/3149q1n00rmp5np44yvwb6wiai16d7dq-agent-workflows/bin/wf`.

A fresh packaged PTY smoke used `NO_COLOR=1`, an 80×24 screen, a long physical macOS
temporary working directory, and the real offline Claude-only routing override.
Current cells showed the complete directory, Claude realization, billing warning,
warning count, and launch/back/details actions. Exact details opened at the full
warning text. Shrinking to 40×12 refused consent without creating a run; returning
to 80×24 restored the review. Live execution was declined before scripted HelloWorld
ran with `language=Spanish`, displayed `¡Hola, mundo!`, copied the verified JSON value
to a new mode-0600 file, and restored terminal modes. The passing log is
`/tmp/agent-cat-ui-handoff-smoke.qS4BL0` (`HANDOFF_SMOKE_EXIT=0`).

The first ad hoc smoke assertion incorrectly expected the wrapped directory suffix
to occupy one row. Its corrected assertion reconstructs the complete directory from
the visible cells; no production change or relaxed truncation check was required.
That failed invocation remains in `/tmp/agent-cat-ui-handoff-smoke.y5eOJN`. These
handoff checks ran on aarch64 Darwin without any paid workflow-backend request.

### Failure disclosure and compact-monitor handoff (2026-09-07)

A real failed `wf --tui` run in `/Users/johnw/Downloads/demo` persisted a transport
failure, but the delivered TUI displayed the internal `RunFailedStatus` constructor
and no diagnostic. The runtime record showed that the Claude ACP adapter rejected
`claude-opus-5` and offered `default`, `opus[1m]`, `claude-fable-5-1[1m]`, `sonnet`,
and `haiku`. The repair renders the recorded failure above the occurrence panes,
including startup failures with no occurrence, and gives `d` an exclusive scrollable
run-details layer containing the complete diagnostic and run identity. Internal run,
occurrence, and attempt constructors now have human labels. Terminal elapsed time ends
at the final envelope. Input editors and launch review use compact content-derived
heights, while routing readiness is explicitly `READY (offline)`.

The full TUI gate passed with source-boundary, model, property, golden, cell-render,
progress, spawn, lifecycle, failure, stress, and terminal-restoration checks. Its TUI
marker is in `/tmp/agent-cat-failure-ui-final-gates.kISlc6`
(`FAILURE_UI_GATE_EXIT=0`). The command then exceeded its aggregate time limit while
running the subsequent ACP gate, so ACP was rerun separately. The final ACP log
`/tmp/agent-cat-failure-acp-final.XDCcGQ` ends `20 scenarios passed, 0 failed` and
`FAILURE_ACP_GATE_EXIT=0`. Its regression verifies that generic exception rendering
uses the human `AcpError` diagnostic rather than its Haskell constructor.

The downstream package was rebuilt without modifying its lock file:

```sh
nix build path:/Users/johnw/src/agent-workflows#packages.aarch64-darwin.agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-write-lock-file --no-link --print-out-paths --max-jobs 2 --cores 4
```

The build log `/tmp/agent-cat-failure-package.IoScPE` ends
`FAILURE_PACKAGE_EXIT=0`. The resulting executable is
`/nix/store/4apfa2n85cldysapzibgd6x4clwvfc0k-agent-workflows/bin/wf`.

A read-only copy of the actual failed run demonstrated that the preceding package hid
the error and the new package shows it immediately. The new Details layer retained the
complete adapter diagnostic. The source run record remained byte-for-byte unchanged.
The same packaged session then ran scripted Spanish HelloWorld, displayed
`¡Hola, mundo!`, copied the verified JSON to a mode-0600 file, and restored terminal
modes. `/tmp/agent-cat-failure-packaged-smoke.zvneuM` ends
`FAILURE_PACKAGED_SMOKE_EXIT=0`. A resize pass at 40×12, 140×36, and 80×24 showed the
failure reason and human state at every size; line scrolling reached the final offered
model at 40×12. `/tmp/agent-cat-failure-packaged-sizes.9E2hkp` ends
`FAILURE_PACKAGED_SIZES_EXIT=0`. Earlier ad hoc size checks expected an unwrapped phrase
and then assumed End stopped at the failure rather than the later stderr tail; their
failed logs remain under `/tmp/agent-cat-failure-packaged-sizes.*`. No live backend
request, configuration change, commit, push, or publication occurred. These fresh
execution results are aarch64 Darwin evidence; earlier Linux results do not validate
this presentation and failure-reporting diff.

### Source-boundary audit follow-up (2026-09-05)

The completion audit rejected the earlier boundary gate: its regex missed
`Agentic.Exec`, `Agentic.RoutingConfig.V2`, and registry names outside the `Agentic`
namespace. The first two bypasses were independently reproduced against the actual
pattern. This was an ineffective verification gate, not evidence that the production
TUI imported those implementations.

Both `cli/ci/policies.sh` and `tui/ci/tui.sh` now invoke `test/source-boundaries.hs`.
It uses the pinned GHC header parser for ordinary and `SOURCE` imports, discovers
project modules from their declarations, and permits the TUI to use only the shared
`Agentic.Runtime` facade and modules owned by `tui/src`. Namespace lookalikes and
undeclared Agentic implementations are not allowed. Foundational-layer checks cover
execution/routing implementations, TUI back-edges, and forbidden submodules.

`test/fixtures/tui/import-boundaries.json` supplies 25 compiler-parsed positive and
negative fixtures: qualified/postqualified, safe/package-qualified, indented and
multiline imports, nested comments, explicit layout, each forbidden TUI category,
and allowed comments/string literals. Another 232 fixtures exercise the declared
forbidden edges and discovered non-TUI project modules. Parse failures stop the gate.

The checker was also compiled with `-Wall -package ghc` and exercised in an isolated
tree sharing the repository's foundation directories and copying `tui/src`. A real
`Agentic.Tui.BoundaryProbe` importing `Agentic.Exec`, `Agentic.RoutingConfig.V2`, and
`Example.Registry` exited 1 and named all three imports. Declaring that test file as
`Agentic.Exec` also exited 1; removing it restored exit 0. No production source was
modified for these negative executable checks.

```sh
nix develop path:. -c bash -c 'runghc -Wall -package=ghc test/source-boundaries.hs "$(ghc --print-libdir)"'
nix develop path:. -c bash -c 'export XDG_CONFIG_HOME=$(mktemp -d); unset AGENT_CAT_PERSONA; bash cli/ci/policies.sh'
PYTHONDONTWRITEBYTECODE=1 tui/ci/tui.sh
nix develop path:. -c cabal sdist all -v0
```

The full policy and TUI gates passed; `/tmp/agent-cat-boundary-gates.mTPdKo` ended
with `BOUNDARY_GATE_EXIT=0`. The packaged checker/fixtures also passed from unpacked
source in `/tmp/nix-shell.HZEhlt/tmp.9XYCSqGmDz/agentic-0.1.0.0`. Independent read-only
review `a85df8a9-c362-4853-a744-04b5c3465418` returned scoped **GO** for the checker,
fixtures, integrations, and source-distribution registration; it did not rerun commands.
Production library/executable sources did not change in this follow-up, so the native
platform/package results below still describe their code.

### Lifecycle and ownership follow-up (2026-09-05)

The independent root and spawn reviews completed with **BLOCK**, identifying FIFO
opens before type validation, cached lineage ownership, premature machine-leader
reaping, successful helpers leaving redirected descendants, and swallowed asynchronous
exceptions during control writes. These were source reviews, not executed test runs.

The corresponding changes use nonblocking candidate-file opens, descriptor-relative
directory enumeration bounded during traversal, strict owner-lease reads, fresh confined
lineage checks, and a shared process-group owner. `waitid` observes exit with `WNOWAIT`;
one lock serializes signalling, the sole reap, and completion publication. Helper
success and partial startup use the same ownership operations as machine termination.
Control writes propagate asynchronous cancellation instead of converting it to a UI error.

On Darwin, signalling a group containing only its zombie leader returns `EPERM`. The
native wrapper suppresses that error only when non-reaping observation and an atomic
two-slot `proc_listpids` query prove that the retained leader is the sole member.
Additional unreaped zombies remain a conservative error. Process groups provide
lifecycle ownership, not containment for programs that change credentials or leave
their session. An observation error is reported rather than authorizing signals
against a PID whose ownership is no longer established.

The Linux correction patches GHC's bundled `process-1.6.26.1`, retaining
`close_fds=True`, the exec-error pipe, direct argv, and inherited limits. A separate
`process` override was rejected because compiler plugins would use two boot-library
instances. The first bundled-compiler override also failed: `buildHaskellPackages`
still selected the stock compiler. Aligning that native package set with the final
set produced GHC 9.10.3 and `process-1.6.26.1-11bf`; `ghc-pkg check` returned success
with documentation/include-path warnings, not a warning-free result.

Fresh Darwin commands and results:

```sh
nix develop path:. -c cabal build -v0 -ftui-tests agentic-run tui-test-driver runtime-contract-test
nix develop path:. -c cabal test runtime-contract-test -v0 --test-show-details=direct
PYTHONDONTWRITEBYTECODE=1 tui/ci/tui.sh
make -C doc check
```

The runtime contracts, both 200-case properties, goldens, progress, descriptor spawn
probe, and full PTY suite passed. The spawn probe reported `nofile=1048575`. Focused
PTY runs separately passed FIFO startup with a healthy sibling, all six fresh-owner
refusals, successful helper descendants with inherited or redirected pipes, machine
leader exit, TERM with surviving descendants, and a control frame exceeding pipe capacity.
A refinement observes buffered control bytes with `FIONREAD` without consuming them;
the lease check reads the clock after parent-store reconstruction. Both refinements
passed the subsequent Darwin and default-limit Linux gates.

Root review `202f61e7-c35d-427c-92e0-5db801a3f508` returned scoped **GO**. Lifecycle
review found one further P1: a second signal could interrupt worker cancellation
before group cleanup completed. A synchronized TERM marker reproduced the orphan
with the old driver. Protecting all shutdown IO then exposed a second masking defect:
the machine grace timeout could not fire. The corrected boundary protects worker
joins, guarantees machine cleanup separately, and retains interruptible grace followed
by protected KILL/reap. Both interrupted-helper cases and the complete Darwin TUI
gate now pass, including the TERM-resistant machine. Lifecycle re-review
`4dfe4f83-a77e-4cb8-a7a1-cb0b99057323` returned scoped **GO**. Neither reviewer executed
tests or certified packages.

One intervening full TUI run timed out awaiting the initial list helper; focused
repetition and the subsequent full gate passed. The assertion now includes exit and
PTY diagnostics, and its deadline was not extended. This observation is retained
rather than characterized as a diagnosed code failure or omitted.

Fresh broad checks also passed: Cabal build/tests/Haddock, policy/examples/routing,
ACP/Deck, documentation Haskell checks, Tier 0 (193/193), Tier 1 (P1 500/500, P2
12000/12000, P3 419/500 with 81 specified skips), ext-pi (87 passed, 7 skipped) and
eight direct integrations, and runtime/TUI tests from the expanded source distribution.
`/tmp/agent-cat-final-doc-bisim.a7j77x` records the documentation/oracle gate with
`GATE_EXIT=0`; the unpacked distribution was tested offline in
`/tmp/nix-shell.2nRV4Y/tmp.hUzrsrE9C5/agentic-0.1.0.0`.

The trusted x86_64 Linux host `andoria-08` ran the transferred source in
`/tmp/agent-cat-lifecycle.oHHxJE` with this command inside `nix develop path:.`:

```sh
set -e
export XDG_CONFIG_HOME=$(mktemp -d)
unset AGENT_CAT_PERSONA
printf "RLIMIT_NOFILE="; ulimit -n
cabal build all -v0
cabal test all -v0 --test-show-details=direct
PYTHONDONTWRITEBYTECODE=1 tui/ci/tui.sh
```

It reported `RLIMIT_NOFILE=1073741816`, passed build/tests and the complete TUI suite,
and ended with `LINUX_EXIT=0`. The spawn probe independently reported the same limit
and verified inherited-descriptor closure, stdio, session identity, and exec failure.
No limit was lowered for that gate. Exact local logs are
`/tmp/agent-cat-linux-aligned.BLCuqd`, `/tmp/agent-cat-linux-default.IM3Yao`, and
`/tmp/agent-cat-linux-refined.UyCD43`, all with successful terminal markers. The final
shutdown-mask correction also passed the complete default-limit Linux gate in
`/tmp/agent-cat-linux-shutdown.pKcsKk`, ending with `LINUX_EXIT=0`.

The current downstream flake imports the shared native override conditionally, because
its existing source pin predates the override file. The final package refreshes passed:
Darwin `/nix/store/rwwxlc7q3p5izar02j7jznkk2hqrq3gp-agent-workflows` and aarch64-Linux
`/nix/store/698fw4jfp3yr2w6p7ss3c3zcgg60nrmb-agent-workflows`. Exact commands were:

```sh
nix build path:/Users/johnw/src/agent-workflows#packages.aarch64-darwin.agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-link --print-out-paths --max-jobs 2 --cores 4
nix build path:/Users/johnw/src/agent-workflows#packages.aarch64-linux.agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-link --print-out-paths --max-jobs 2 --cores 4
```

Logs `/tmp/agent-cat-final-package-aarch64-darwin.9Vh683` and
`/tmp/agent-cat-final-package-aarch64-linux.LepDDH` both ended with `PACKAGE_EXIT=0`.
The downstream 74-workflow, cookbook, and Emacs gates passed against this tree in
`/tmp/agent-cat-downstream-gates.k49Hkg/agent-workflows`, with an empty XDG root.
`/tmp/agent-cat-downstream-gates-log.3vnCTB` ended with `DOWNSTREAM_GATES_EXIT=0`.
The retained downstream PTY program below was rerun against the final Darwin output
with `os.environ.pop('AGENT_CAT_PERSONA', None)` and an empty XDG configuration root.
It selected `hello-world`, accepted empty `language`, displayed the exact plan, launched
scripted mode, compared the exported JSON to `runtime/result.json`'s `result.value`,
checked mode 0600, and restored the terminal. Its summary was:

```text
current packaged wf --tui: empty language, exact plan, scripted launch, verified mode-0600 result copy, terminal restoration passed
```

The final independent completion audit approved the implementation and evidence.
The explicit environmental exclusions below are not reported as passing tests.

### Descriptor-root follow-up (2026-09-05)

The follow-up moved directory mutation into `Agentic.Runtime.PrivateRoot`, shared by
the frontend and runtime store. Operations capture an independent descriptor before
root closure can occur; callbacks from late workers cannot reuse a closed descriptor.
Child input and store access validates `AGENT_CAT_STATE_ANCHOR` before descriptor-relative
IO. New regressions cover root replacement between opening a temporary and publishing
it, replaced runtime directories, foreign owners, trailing-slash symlinks, public
descendants, unowned temporary files, and real plan/machine child identity mismatches.

Fresh checks passed: Cabal build, all Cabal tests, Haddock generation, policy, examples,
routing, ACP (19 scenarios), Deck (10 scenarios), TUI model/property/golden/progress/PTY
tests, Tier 0 and Tier 1, ext-pi (87 passed, 7 skipped) and its eight direct integrations,
both documentation gates, and runtime/TUI tests from an unpacked source distribution.
Haddock completed with its existing unresolved-link and coverage warnings; this is not
a warning-free documentation claim. The downstream `wf --tui` scripted launch, verified
result copy, mode check, and terminal restoration also passed with the exact invocation
below. Darwin and aarch64-Linux downstream package builds were refreshed.

On x86_64 Linux the build and runtime tests passed, and the full PTY suite passed with
`ulimit -n 4096` in the verification subshell. Without that limit, the Nix shell supplied
`RLIMIT_NOFILE=1073741816` and startup stalled before drawing. That historical failure
was not accepted as a passing default-environment test; the later native correction
and default-limit pass are recorded above. Review launchers were unavailable at this
earlier stage, but subsequently returned the five blocking findings.

### Earlier complete matrix (2026-09-04)

The following entries retain the earlier full matrix. Current workflow, cookbook,
and Emacs repetitions are recorded above. The Taskmaster historical-evidence gate
remains its earlier recorded-revision result rather than a current-tree claim.

- `nix develop path:. -c cabal build all`
- `nix develop path:. -c cabal test all --test-show-details=direct`
- `nix develop path:. -c cabal haddock all`
- `nix develop path:. -c bash cli/ci/policies.sh`
- `nix develop path:. -c bash cli/ci/examples.sh`
- `nix develop path:. -c bash cli/ci/routing-config.sh`
- `nix develop path:. -c bash engine/acp/ci/acp.sh` — 19 scenarios
- `nix develop path:. -c bash engine/agent-deck/ci/deck.sh` — 10 scenarios
- `tui/ci/tui.sh` — model/property/golden, progress, PTY, signal, save, and stress checks
- `BISIM_QUICK=1 bisim/ci/tier0.sh` — 193 of 193 classified cases
- `N=500 SEED=1 bisim/ci/tier1.sh` — P1 500/500, P2 12000/12000, P3 419/500 with 81 specified `other` skips, zero failures
- `make -C doc check` and `make -C doc check-haskell` — 243 CLI source items and 242 Haskell members accounted for
- `cd ext-pi && npm test -- --run && npm run check` — 87 passed, 7 environment-gated skips
- Sequential native ext-pi targets (`native-targets-e2e`, `owned-child-e2e`, `current-bridge`, and `pi-child-acp`) — 8 passed
- `cabal sdist all`, followed by unpacking the tarball and running `runtime-contract-test` and `tui-model-test` — passed with shared fixtures and goldens present
- Downstream `agent-workflows`: 74-workflow gate, cookbook no-op gate, and Emacs 30.2 byte-compile/checkdoc/smoke (37 facts) — passed in an isolated Git checkout with an empty `XDG_CONFIG_HOME` against this tree
- Downstream `wf --tui`: selected `hello-world`, collected its input, displayed exact plan/argv, launched scripted mode, verified and copied the result, and restored the terminal — passed
- `git diff --check`, generated-cache cleanup, and credential/private-key pattern scan — clean

## Platform and packaging evidence

- **aarch64-darwin:** current build/tests/Haddock, full TUI, downstream package, and
  packaged `wf --tui` launch/result-copy checks passed.
- **aarch64-linux:** the final downstream package build passed on `vulcan`, including
  the patched native compiler package set and native lifecycle sources.
- **x86_64-linux:** patched-toolchain build, all Cabal tests, and the full TUI suite
  passed on `andoria-08` at the default limit of 1073741816. Earlier limited-shell
  passes and transport failures remain historical evidence, not substitutes for it.
- The expanded source distribution contains both native C files, `ProcessGroup.hs`,
  and the shared Nix override/patch. Its offline unpacked runtime/TUI tests passed.

## Conditional and unavailable checks

- Independent review is operational. Runs `36a289a4-0a1c-439a-8c69-7c251bc41e4a` and
  `caee84c0-5ac6-43bc-a610-aadb0c8255ef` returned **BLOCK** on the five findings above.
  Their corrections received a scoped root GO and, after two shutdown-mask iterations,
  a scoped lifecycle GO as recorded above. These source reviews did not execute tests
  or certify downstream packaging. Earlier launcher failures remain historical only.
- `cymbal changed` returned no changed symbols and reported 46 changed files without
  parseable symbols. Source and diff inspection were performed directly; the empty
  symbol result is not evidence of zero impact or an independent review.
- `acat-tbn` was closed after current packaging and independent audit acceptance. Its
  startup defect is corrected in the bundled boot library; the native x86_64 gate
  passed without lowering resource limits. Earlier failed overrides remain recorded
  above, and no package check or descriptor-isolation setting was disabled.

- `engine/acp/ci/route-live.sh` was not run because it contacts paid backends and is
  explicitly outside acceptance.
- The aggregate `npm run test:integration` wrapper was unavailable because the installed
  Pi package lacks `RemoteSession.followUp`. All eight applicable non-paid native/current/
  child integration cases were run directly and passed.
- Windows is outside scope; the implementation and documentation make no Windows claim.
- The current-checkout Taskmaster evidence gate assumes an older agent-cat source layout.
  Its isolated recorded-revision gate passed; the current failure is not used as release
  evidence.
- Tree-sitter was not added: emitted events contain no language/file AST identity. Typed
  bounded plain text, lightweight Markdown cues, status lines, and all unified-diff forms
  have direct consumers and tests.

## Reproducible command transcript

The following blocks retain the exact commands and terminal summary output used for
release decisions. Commands run from the agent-cat root unless a `cd` is shown.

The fresh Linux runtime/PTY command retained the descriptor limit explicitly:

```sh
git ls-files -co --exclude-standard -z | tar --null -T - -cf - | ssh -o BatchMode=yes andoria-08 'set -e; d=$(mktemp -d); trap '\''rm -rf "$d"'\'' EXIT; tar -xf - -C "$d"; cd "$d"; nix develop path:. -c bash -c '\''set -e; ulimit -n 4096; cabal build all -v0; cabal test -v0 runtime-contract-test; PYTHONDONTWRITEBYTECODE=1 bash tui/ci/tui.sh'\'' > /tmp/agent-cat-root-linux-bounded.log 2>&1 || { tail -n 100 /tmp/agent-cat-root-linux-bounded.log; exit 1; }; tail -n 8 /tmp/agent-cat-root-linux-bounded.log'
```

```text
runtime contracts: descriptor, protocol, controls, snapshot, store, and shared fixtures passed
+++ OK, passed 200 tests.
+++ OK, passed 200 tests.
tui model/property/golden tests: all checks passed
progress probe: bounded public progress is persisted, redacted, optional, and answer-neutral
tui probe: all checks passed
```

The preceding attempt without `ulimit -n 4096` failed with
`TUI did not render b'Workflows'; exit=None; tail=''`. The bounded-limit run also
exposed a wrapped-header assertion: the memo bill moved to the following terminal
row with a longer Linux process identifier. The corrected probe checks the exact
fresh and memo bill counts without requiring both labels on one physical row.

The fresh downstream launch used the Darwin output from the package build below.
The verification invoked the packaged executable directly as `wf --tui`:

```sh
WF="$wf_out/bin/wf" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util, json, os, tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('probe','test/tui_probe.py'); p=importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
wf=Path(os.environ['WF'])
os.chdir('/Users/johnw/src/agent-workflows')
with tempfile.TemporaryDirectory(prefix='wf-tui-root-check-') as d:
  base=Path(d); state=base/'state'; saved=base/'result.json'; (base/'xdg').mkdir()
  with p.TuiSession(wf,state,rows=24,columns=80,extra_environment={'XDG_CONFIG_HOME':str(base/'xdg')}) as session:
    cursor=session.wait_for(b'Workflows'); session.settle()
    session.send(b'/hello-world'+p.CTRL_D)
    filtered=session.wait_for(b'filter /hello-world/',after=cursor)
    session.send(p.ENTER); session.wait_for(b'Ctrl-D CONTINUE',after=filtered)
    session.send(p.CTRL_D); target=session.wait_for(b'Execution target',after=filtered)
    session.send(b's'); confirmed=session.wait_for(b'CONFIRM SCRIPTED RUN',after=target)
    session.wait_for(b'Enter/y LAUNCH',after=confirmed)
    session.send(b'y'); terminal=session.wait_for(b'RESULT AVAILABLE',after=confirmed)
    session.send(b'r'); session.wait_for(b'RESULT [focus]',after=terminal)
    session.send(b's'); session.wait_for(b'Copy the verified final JSON result',after=terminal)
    session.send(str(saved).encode()+p.CTRL_D)
    copied=session.wait_for(b'saved verified final result',after=terminal)
    stores=p.runs(state); assert len(stores)==1
    artifact=json.loads((stores[0]/'runtime'/'result.json').read_text())
    assert json.loads(saved.read_text())==artifact['result']['value']
    assert p.mode(saved)==0o600
    p.quit_completed_run(session,copied); session.assert_restored()
print('wf --tui hello-world with empty language, verified result copy, mode 0600, terminal restoration: passed')
PY
```

```text
wf --tui hello-world with empty language, verified result copy, mode 0600, terminal restoration: passed
```

The refreshed source-distribution check was:

```sh
nix develop path:. -c bash -c 'set -e; cabal sdist all -v0; d=$(mktemp -d); trap '\''rm -rf "$d"'\'' EXIT; tar -xzf dist-newstyle/sdist/agentic-0.1.0.0.tar.gz -C "$d"; cd "$d/agentic-0.1.0.0"; cabal test --offline -v0 runtime-contract-test tui-model-test; echo "unpacked sdist runtime and TUI tests: passed"'
```

```text
runtime contracts: descriptor, protocol, controls, snapshot, store, and shared fixtures passed
+++ OK, passed 200 tests.
+++ OK, passed 200 tests.
tui model/property/golden tests: all checks passed
unpacked sdist runtime and TUI tests: passed
```

```console
$ nix develop path:. -c bash -c 'cabal build all -v0; cabal test all -v0 --test-show-details=direct; cabal haddock all -v0'
runtime contracts: descriptor, protocol, controls, snapshot, store, and shared fixtures passed
+++ OK, passed 200 tests.
+++ OK, passed 200 tests.
tui model/property/golden tests: all checks passed
```

```console
$ tui/ci/tui.sh
+++ OK, passed 200 tests.
+++ OK, passed 200 tests.
tui model/property/golden tests: all checks passed
progress probe: bounded public progress is persisted, redacted, optional, and answer-neutral
tui probe: all checks passed
```

```console
$ nix develop path:. -c bash engine/acp/ci/acp.sh
ci/acp: 19 scenarios passed, 0 failed
$ nix develop path:. -c bash engine/agent-deck/ci/deck.sh
ci/deck: 10 scenarios passed, 0 failed
$ BISIM_QUICK=1 bisim/ci/tier0.sh
tier0: 193 passed, 0 failed, 45 other-refusals (codec-only), of 193 files
$ N=500 SEED=1 bisim/ci/tier1.sh
bisim: P1R 1/1, P1 500/500, P2 12000/12000, P3 419/500 (81-other skipped), 0 failures
```

```console
$ cd ext-pi && npm test -- --run && npm run check
Test Files  10 passed | 3 skipped (13)
Tests  87 passed | 7 skipped (94)
$ for test in native-targets-e2e owned-child-e2e current-bridge pi-child-acp; do AGENT_CAT_E2E_RUNNER="$runner" npx vitest run "test/$test.test.ts"; done
Test Files  4 passed; Tests  8 passed
```

```console
$ make -C doc check
manual coverage: 243 source items accounted for, classified, and indexed
manual prose: prohibited patterns absent; no three-sentence staccato run
tui release evidence: requirement matrix, platforms, and unavailable checks recorded
$ make -C doc check-haskell
manual CLI: registry, help, plan, cost, scripted run, exits, and defaults verified
manual members: 130 compiler-exported children and 112 exported-class instances verified
```

The downstream gates were isolated from personal routing policy by an empty XDG root:

```sh
root=$(mktemp -d)
git clone -q --no-local /Users/johnw/src/agent-workflows "$root/agent-workflows"
ln -s /Users/johnw/src/agent-cat/.worktrees/tui "$root/agent-cat"
mkdir "$root/xdg"
cd "$root/agent-workflows"
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" nix develop path:/Users/johnw/src/agent-cat/.worktrees/tui -c bash ci/workflows.sh
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" nix develop path:/Users/johnw/src/agent-cat/.worktrees/tui -c bash ci/cookbook.sh
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" nix shell nixpkgs#emacs-nox -c bash ci/emacs.sh
wf_out=$(nix build path:/Users/johnw/src/agent-workflows#agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-link --print-out-paths)
env -u AGENT_CAT_PERSONA XDG_CONFIG_HOME="$root/xdg" AGENT_CAT_STATE_DIR="$root/tui-state" "$wf_out/bin/wf" --tui
```

Their retained terminal summaries were:

```text
ci/workflows: 74 workflow(s) pinned, 0 failed
ci/cookbook: 74 row(s) documented, 0 failed
wf-smoke: 37 facts, 0 failed
ci/emacs: 3 pass(es) over 2 file(s), 0 failed
wf --tui downstream scripted launch and result copy: passed
```

The exact packaging and platform commands were:

```sh
nix build path:/Users/johnw/src/agent-workflows#agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-link
nix build path:/Users/johnw/src/agent-workflows#packages.aarch64-linux.agent-workflows --override-input agent-cat path:/Users/johnw/src/agent-cat/.worktrees/tui --no-link
git ls-files -co --exclude-standard -z | tar --null -T - -cf - | ssh -o BatchMode=yes andoria-08 'set -e; d=$(mktemp -d); trap '\''rm -rf "$d"'\'' EXIT; tar -xf - -C "$d"; cd "$d"; nix develop path:. -c cabal build all -v0'
nix develop path:. -c cabal sdist all -v0
```

The observed platform summaries were `aarch64-darwin downstream Nix build: passed`,
`aarch64-linux downstream Nix build: passed`, `x86_64-linux cabal build: passed`, and
`unpacked source-distribution runtime/TUI tests: passed`.

## Retained 2026-09-05 changed-files report

At the 2026-09-05 completion audit, the working tree contained the following 125
changed paths. This retained scope inventory is historical and is not an independent
review of the responsive follow-up. None was staged at that audit. The separate
downstream change was
`/Users/johnw/src/agent-workflows/flake.nix`. Obr uses the shared repository tracker
at `/Users/johnw/src/agent-cat/doc/PLAN.org`; that file contains the exported TUI epic,
milestones, and closed startup blocker rather than a second tracker in this worktree.

```text
README.md
agentic.cabal
cli/README.md
cli/ci/examples.sh
cli/ci/policies.sh
cli/ci/routing-config.sh
cli/model-definitions.example.yaml
cli/src/Agentic/Cli.hs
cli/src/Agentic/RoutingConfig.hs
cli/src/Agentic/RoutingConfig/V2.hs
cli/src/Agentic/RoutingDiscovery.hs
cli/src/Agentic/RoutingInspect.hs
cli/src/Agentic/RoutingSecrets.hs
cli/test/PolicyProbe.hs
cli/test/RoutingDiscoveryProbe.hs
cli/test/RoutingFixedPointProbe.hs
cli/test/RoutingV2Probe.hs
cli/test/model_catalogue_server.py
doc/Makefile
doc/agent-cat.texi
doc/check-brick-2.9.hs
doc/check-model-routing-v2.hs
doc/haskell-member-coverage.texi
doc/model-routing-v2.md
doc/runner-index.texi
doc/tui-design.md
doc/tui-release-evidence.md
engine/acp/README.md
engine/acp/ci/acp.sh
engine/acp/src/Agentic/Acp.hs
engine/acp/test/stub_adapter.py
engine/api/README.md
engine/api/src/Agentic/Engine.hs
engine/api/test/Main.hs
ext-pi/README.md
ext-pi/src/catalogue.ts
ext-pi/src/index.ts
ext-pi/src/launch.ts
ext-pi/src/monitor.ts
ext-pi/src/reducer.ts
ext-pi/src/supervisor.ts
ext-pi/src/types.ts
ext-pi/test/catalogue-launch.test.ts
ext-pi/test/extension.test.ts
ext-pi/test/fixtures/runner.mjs
ext-pi/test/monitor.test.ts
ext-pi/test/native-targets-e2e.test.ts
ext-pi/test/owned-child-e2e.test.ts
ext-pi/test/reducer.test.ts
ext-pi/test/supervisor.test.ts
flake.nix
nix/haskell-overrides.nix
nix/process-close-fds-linux.patch
runtime/README.md
runtime/cbits/private_directory.c
runtime/src/Agentic/Exec.hs
runtime/src/Agentic/Runtime.hs
runtime/src/Agentic/Runtime/Catalogue.hs
runtime/src/Agentic/Runtime/Control.hs
runtime/src/Agentic/Runtime/Descriptor.hs
runtime/src/Agentic/Runtime/Machine.hs
runtime/src/Agentic/Runtime/PrivateFile.hs
runtime/src/Agentic/Runtime/PrivateRoot.hs
runtime/src/Agentic/Runtime/Protocol.hs
runtime/src/Agentic/Runtime/Snapshot.hs
runtime/src/Agentic/Runtime/Store.hs
runtime/test/Main.hs
test/fixtures/runtime/descriptor-v2/invalid-unknown.json
test/fixtures/runtime/descriptor-v2/valid.json
test/fixtures/runtime/descriptor-v3/valid.json
test/fixtures/runtime/frontend-manifest/legacy-ext-pi.json
test/fixtures/runtime/frontend-manifest/v2.json
test/fixtures/runtime/protocol-v1/cancelled.ndjson
test/fixtures/runtime/protocol-v1/cancelled.snapshot.json
test/fixtures/runtime/protocol-v1/failover-retried.ndjson
test/fixtures/runtime/protocol-v1/failover-retried.snapshot.json
test/fixtures/runtime/protocol-v1/recovery-failed.ndjson
test/fixtures/runtime/protocol-v1/recovery-failed.snapshot.json
test/fixtures/runtime/protocol-v1/redirected.ndjson
test/fixtures/runtime/protocol-v1/redirected.snapshot.json
test/fixtures/runtime/protocol-v1/reuse-after-attempt.error.json
test/fixtures/runtime/protocol-v1/reuse-after-attempt.ndjson
test/fixtures/runtime/protocol-v1/reused.ndjson
test/fixtures/runtime/protocol-v1/reused.snapshot.json
test/fixtures/runtime/protocol-v1/sequence-gap.error.json
test/fixtures/runtime/protocol-v1/sequence-gap.ndjson
test/fixtures/runtime/protocol-v1/success.ndjson
test/fixtures/runtime/protocol-v1/success.snapshot.json
test/fixtures/runtime/protocol-v2/control-correlation-change.error.json
test/fixtures/runtime/protocol-v2/control-correlation-change.ndjson
test/fixtures/runtime/protocol-v2/person-queued-then-delivered.error.json
test/fixtures/runtime/protocol-v2/person-queued-then-delivered.ndjson
test/fixtures/runtime/protocol-v2/person-result.ndjson
test/fixtures/runtime/protocol-v2/person-result.snapshot.json
test/fixtures/runtime/protocol-v2/person-terminal-without-acceptance.error.json
test/fixtures/runtime/protocol-v2/person-terminal-without-acceptance.ndjson
test/fixtures/runtime/protocol-v2/progress.ndjson
test/fixtures/runtime/protocol-v2/progress.snapshot.json
test/fixtures/tui/import-boundaries.json
test/fixtures/tui/routing-browser.golden
test/fixtures/tui/run-browser.golden
test/fixtures/tui/workflow-filter.golden
test/person_control_probe.py
test/person_lineage_probe.py
test/progress_probe.py
test/source-boundaries.hs
test/tui_fixture_runner.py
test/tui_probe.py
tui/AGENTS.md
tui/README.md
tui/cbits/process_group.c
tui/ci/tui.sh
tui/src/Agentic/Tui.hs
tui/src/Agentic/Tui/App.hs
tui/src/Agentic/Tui/Client.hs
tui/src/Agentic/Tui/Highlight.hs
tui/src/Agentic/Tui/Model.hs
tui/src/Agentic/Tui/Person.hs
tui/src/Agentic/Tui/Presentation.hs
tui/src/Agentic/Tui/Process.hs
tui/src/Agentic/Tui/ProcessGroup.hs
tui/src/Agentic/Tui/Root.hs
tui/src/Agentic/Tui/RunModel.hs
tui/src/Agentic/Tui/Types.hs
tui/test/Driver.hs
tui/test/Main.hs
```

## Review and residual risk

Independent review initially blocked release on journal failure ordering, preallocation
bounds, routing ownership, callback correlation, FIFO control, artifact verification,
event-count compatibility, exact-secret redaction, lifecycle reaping, and stress coverage.
Those findings received focused regressions. Two subsequent reviews found and verified
additional target-kind, arbitrary-precision JSON, ancestor-symlink, raw-byte journal,
post-KILL reap, and canonical-metadata fixes. That code-focused review returned
**GO** with no unresolved high-severity finding.

The first independent completion audit nevertheless rejected the release because the
browser lacked fuzzy filtering and complete run/routing facts, the live header omitted
required context, result copy was absent, and verification evidence was not retained in
the tree. Those product-level gaps produced the model/property/golden/PTY cases and
the requirement matrix recorded above. A post-remediation independent review verified
each rejected item and the new routing-policy projection, found no P0/P1 issue, and
returned **GO**. Its two documentation/test notes were corrected by naming
`run-browser.golden` accurately and asserting terminal bills in the routed live PTY.

A second completion audit then required descriptor-anchored state mutation, an explicit
TUI recovery-arrival queue, foreign-owner and two-producer PTY cases, exact downstream
commands, a complete changed-files report, and removal of stale future-tense design
claims. The shared `Agentic.Runtime.PrivateRoot`, its terminal facade, descriptor-relative
runtime store and artifact readers, FIFO recovery modal, and updated transcript are
the corresponding remediations. Later independent root and spawn reviews found the
five lifecycle/authorization defects recorded above. The fixes, subsequent shutdown
corrections, current platform gates, and two scoped independent GO reviews are recorded
in the lifecycle follow-up. No P0/P1 finding remains in those reviewed source scopes.

A completion audit required effective import enforcement and executable negative
fixtures. After the compiler-parsed correction, the final auditor inspected the
implementation, regression sources, and retained platform/downstream logs, independently
reran all 25 syntax and 232 forbidden-edge fixtures, and checked diff whitespace.
It approved the goal with no blocking gap. `acat-tbn`, `acat-tui-production-d9e.9`,
and the epic were then closed and the shared tracker exported without committing.
The explicit
exclusions also remain: no paid-backend acceptance, no Windows process-tree design,
and no aggregate Pi wrapper until its required local package API is available.
