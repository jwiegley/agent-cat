# TUI release evidence

This record maps the production `agentic-run --tui` and downstream `wf --tui`
requirements to executable evidence. It covers the uncommitted working tree based
on `fc149f18c3407ff12f6b5c9d8b08ef2e9e306701`. The initial matrix was recorded on
2026-09-04; descriptor-root and lifecycle follow-ups were validated on 2026-09-05
as qualified below. The final independent completion audit approved goal
`mtm03s1f-737bbz` after inspecting sources, regressions, retained platform logs, and
the corrected compiler-parsed boundary gate. No paid route, commit, push, or
publication was performed.

## Requirement-to-test matrix

| Requirement | Implementation evidence | Executable evidence |
|---|---|---|
| Descriptor-v2 compatibility and descriptor-v3 negotiation | `Agentic.Runtime.Descriptor`; v1 fallback in `ext-pi/src/catalogue.ts` | `runtime-contract-test`; `ext-pi/test/catalogue-launch.test.ts`; `cli/ci/policies.sh` |
| Protocol-v1/store-v1 compatibility and strict protocol-v2/store-v2 | `Agentic.Runtime.Protocol`, `Machine`, `Snapshot`, and `Store` | Shared vectors under `test/fixtures/runtime/`; Haskell and TypeScript reducer tests; Tier 0 and Tier 1 |
| Private, confined, bounded, digest-verified state | Shared `PrivateRoot`, `PrivateFile`, `Store`, `Catalogue`; root identity handoff to children | Root/descendant replacement, closed descriptors, unowned temporaries, FIFO refusal, descriptor-relative enumeration, 1000-entry bound, and real CLI identity checks |
| Local person answering with FIFO delivery and terminal acknowledgement | `Agentic.Runtime.Control`; `Agentic.Tui.Person` | `test/person_control_probe.py`; `test/person_lineage_probe.py`; `test/tui_probe.py` |
| Persona routing, inventory provenance, opaque target kind/argv, and immutable launch preflight | `RoutingConfig.V2`, `RoutingDiscovery`, `RoutingInspect`, `RoutingSecrets`; `Tui.Types` | `cli/ci/routing-config.sh`; `RoutingV2Probe`; TUI persona/argv PTY assertions |
| Workflow browser with fuzzy filtering and descriptor facts | `Tui.Model.visibleWorkflows`, `fuzzyMatch`, and filter editor in `Tui.App` | 400 QuickCheck cases; `workflow-filter.golden`; narrow 80-column PTY filter test |
| Run browser with lineage, persona, realization, bills, result availability, and ownership | `Tui.Model.runLine`; sanitized runtime policy retained by `Runtime.Catalogue` | `run-browser.golden`; real `agentic-run` terminal-run catalogue PTY assertions |
| Routing browser with symbolic chains and concrete inventory provenance | Typed `RoutingProfileChoice`, `RoutingRungChoice`, and `RoutingInventoryChoice` | `routing-browser.golden`; narrow PTY profile/inventory assertions; routing schema gate |
| Descriptor-ordered, source-aware input collection | `Tui.Model` and `Tui.Client.writeInputs` | Multiline/stdin/model tests; PTY body-omission and exact-input preview checks |
| Exact-input plan, cost/fold, executable, target argv, persona, and realization before confirmation | `buildLaunchPreview` and `confirmView` | PTY confirms `Exact-input plan`, model/provider/backend, executable/arguments, and no run before `y` |
| Direct argv machine launch, fd 3 control, ownership, termination, and reap | Shared `Tui.ProcessGroup`, native non-reaping observation, CLI fd bootstrap, patched Linux boot library | Darwin and default-limit x86_64 Linux spawn and full PTY gates; redirected/pipe-holding descendants, TERM-resistant groups, blocked-control interruption |
| Identity-stable live occurrence/attempt monitor with bounded scrollback | `Runtime.Snapshot`, `Tui.RunModel`, separate output viewport and tail-follow state | Pure authored-reorder test; narrow/wide PTY runs; concurrent 10 MiB stress |
| Live workflow/persona/realization/run/status/elapsed/bills header | `Tui.App.liveView`, one-second typed ticks, catalogue/preview context | Real-run PTY assertions for workflow, realization, elapsed, and terminal bills |
| FIFO recovery, redirect, steering, cancellation, detach/reattach, and lineage | Runtime/TUI arrival queues; confined parent revalidation before preview, preparation, and spawn | Two simultaneous recovery producers; exact controls; restart/resume/fork refusal when a foreign heartbeat resumes after catalogue load or during confirmation |
| Typed public progress distinct from answers and private reasoning | `EngineUpdate`, `Exec.publicProgressOf`, ACP projection | `test/progress_probe.py`; ACP 19-scenario gate; shared progress vectors; answer/trace/bill equality checks |
| Bounded/redacted tool, todo, usage, message, and explicit reasoning summaries | Runtime projection plus exact selected-secret redaction | Routing secret run and progress probes; ext-pi/TUI reducer/render tests |
| Verified final result plus explicit save/copy path | Store result reference, TUI verified load, exclusive mode-0600 save prompt, ext-pi verifier | PTY save/copy assertion; Haskell artifact tests; ext-pi digest/canonical/symlink/large-integer cases |
| More than 65,536 protocol events and bounded journal state | One-entry ext-pi digest history and raw-byte prefix verification | 65,537-progress-event dual-journal terminal restore; 65,540-event reducer property |
| Plain/Markdown/status/unified-diff rendering without unjustified native grammars | `Tui.Highlight` | Pure classification/golden checks and PTY diff forms; dependency rejection in `tui/ci/tui.sh` |
| TUI/runtime import boundary and agent-cat as sole interpreter | Shared GHC header-parser gate; Runtime facade and source-owned TUI allowlist | Both CLI/TUI gates run 25 explicit syntax/TUI fixtures and 232 generated forbidden-edge fixtures; isolated executable rejects real forbidden imports |
| Opt-in frontend state sharing and runner-specific defaults | `tuiCmd` state-root selection and frontend-manifest v2 | Default-state PTY assertion; TUI/ext-pi shared manifest/restore tests |
| macOS/Linux support and terminal restoration | POSIX fd/process-group implementation; three-system flake | Darwin PTY normal/exception/signal tests; Darwin and Linux builds below |
| Downstream `wf --tui` uses its own 74-workflow registry | Public `Agentic.Tui` facade reached through `cliMain` | Downstream gates and a scripted `wf --tui` `hello-world` PTY launch |

## Fresh validation record

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
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util, json, os, tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('probe','test/tui_probe.py'); p=importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
wf=Path('/nix/store/gdmiqq7b9nkys8yfnb1gvc4a2i0wdxc8-agent-workflows/bin/wf')
os.chdir('/Users/johnw/src/agent-workflows')
with tempfile.TemporaryDirectory(prefix='wf-tui-root-check-') as d:
  base=Path(d); state=base/'state'; saved=base/'result.json'; (base/'xdg').mkdir()
  with p.TuiSession(wf,state,columns=180,extra_environment={'XDG_CONFIG_HOME':str(base/'xdg')}) as session:
    cursor=session.wait_for(b'Workflows'); session.settle()
    session.send(b'/hello-world'+p.CTRL_D)
    filtered=session.wait_for(b'workflow filter applied',after=cursor)
    session.send(p.ENTER); session.wait_for(b'Ctrl-D accept',after=filtered)
    session.send(p.CTRL_D); target=session.wait_for(b'execution target',after=filtered)
    session.send(b's'); confirmed=session.wait_for(b'launch confirmation',after=target)
    session.wait_for(b'Exact-input plan',after=confirmed)
    session.send(b'y'); terminal=session.wait_for(b's save/copy result',after=confirmed)
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

## Complete changed-files report

The working tree contains the following 125 changed paths. None is staged; this scope
inventory is not an independent review. The separate downstream change is
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
