# Option B tmux verification

Date: 2026-08-28

Interface note (2026-08-30): the catalogue command was subsequently renamed from `/workflows` to `/wf` so that `pi-dynamic-workflows` retains `/workflows`. References below preserve the command observed during this verification run.

This record separates (1) flows observed through the offline Pi TUI and (2) executable protocol fixtures used where a real provider would add cost or nondeterminism. No prompt was sent to a paid/live model. Pi printed a pre-existing local `models.json` warning at startup; extension commands and deterministic fixtures remained operational.

## Environment

```sh
AGENT_CAT_RUNNER=<cabal list-bin agentic-run>
AGENT_CAT_STATE_DIR=<private mktemp directory>
DECK_STUB_STATE=<private mktemp directory>/deck-state
DECK_STUB_MODE=happy
PATH=<private mktemp directory>/bin:$PATH  # bin/agent-deck is stub-deck.sh
node ~/db/pi/packages/coding-agent/dist/cli.js \
  --no-session --no-extensions \
  --extension ~/src/agent-cat-pi-ext/pi-extension/src/index.ts
```

The terminal was a detached tmux window, initially `120x36`, later resized to `75x20`. Scripted/control observations used deterministic extension fixtures. Native ACP and deck observations used the real `agentic-run` with `test/stub_adapter.py` and `haskell/test/stub-deck.sh`; neither contacted a model or live deck pane.

## Catalogue, launch, monitor, and recovery

1. `/workflows` displayed all eight discovered workflows. Selecting `agent-cat:structured` displayed the runner's exact help, including level, cost, inputs, pins, worked command, rehearsal, and caveats.
2. `/workflow agent-cat:structured` displayed target choices and selected `scripted (offline, no commands)`.
3. Preflight displayed the absolute runner, cwd, target, containment statement, effect count, and private persistence policy. Approval started run `5024644b-…`.
4. The terminal entry rendered:

```text
Started structured as 5024644b-…
agent-cat 5024644b-…: succeeded
```

5. `/workflow-monitor 5024644b-…` displayed authored occurrence `0`, typed `structured` intent, target, prompt, attempt state, and decoded answer. At `75x20`, Enter folded the occurrence and retained focus:

```text
5024644b-…  succeeded  structured  target=scripted
› [0] ▸ completed consult/structured → model structured-producer
↑/↓ select  enter fold  esc close
```

6. `/workflow-status` listed the terminal run. Pi was exited and restarted against the same state directory; `/workflow-status` reconstructed the same run.
7. `/workflow-resume 5024644b-…` displayed immutable-lineage approval and started `c62884a9-…`. Its agent-cat journal contained zero `attempt.started` and one `occurrence.reused`; the child manifest named `parentRunId=5024644b-…` and `lineage=resume`.

## Live controls, status surface, and terminal references

A second tmux run used `pi-extension/test/fixtures/runner.mjs` with `FIXTURE_HANG=1`.

1. `/workflow agent-cat:fixture` selected scripted execution and collected `subject` exactly once.
2. While active, the persistent status surface read:

```text
running df8ef92f-… fixture
1 active workflow
```

3. `/workflow-steer df8ef92f-…` selected exact attempt `0:0`, entered `focus now`, and selected `interrupt-now`. Pi displayed the terminal runtime acknowledgement, not an optimistic echo:

```text
steer delivered (steer-f880c280-…): steer delivered
```

4. `/workflow-cancel` required confirmation. A final-code rerun (`de2fb90a-…`) verified the detailed terminal entry, failure classification, and durable store reference:

```text
agent-cat de2fb90a-…: cancelled fixture
failure cancelled: cancelled
run store: <private-state>/runs/de2fb90a-…
```

5. The active status cleared after terminal cleanup. Exiting Pi removed the private bridge token/socket.

## Real native target TUI observations

A later detached `120x36` tmux run selected `harden` through the ordinary `/workflow` wizard twice:

1. **Native ACP:** selected `native ACP adapter`, entered `/usr/bin/env` with adapter argv `["python3","…/test/stub_adapter.py"]`, declined optional pin routing, approved the live-target and containment prompts, and launched `8b484df8-46e2-477d-aa7e-38a9306f154e`. The real runner completed with `bill fresh=7 memo=7`.
2. **Native agent-deck:** selected `native agent-deck session`, entered session `stub`, declined optional pin routing, approved the live-target and containment prompts, and launched `19d8c85f-1ecc-4845-884b-0ad831027be5`. The PATH-resolved deterministic deck stub completed with `bill fresh=7 memo=7`.
3. `/workflow-status` displayed both run IDs as `succeeded harden`. Their private run stores contain real agent-cat machine journals, not synthetic extension events.

## Target coverage

| Target | Evidence | Observed result |
|---|---|---|
| Scripted | TUI steps above; `pi-extension/test/catalogue-launch.test.ts`; Haskell examples | Discovered, approved, launched, monitored, persisted, and reconstructed. |
| Native ACP and routed ACP | TUI run `8b484df8-…`; `pi-extension/test/native-targets-e2e.test.ts`; `haskell/ci/acp.sh` | The ordinary wizard and extension supervisor executed real `agentic-run` against the ACP stub, producing bills `7/7`; direct argv/routing and all 16 ACP scenarios passed. |
| Native agent-deck and routed deck | TUI run `19d8c85f-…`; `pi-extension/test/native-targets-e2e.test.ts`; `haskell/ci/deck.sh` | The ordinary wizard and extension supervisor executed real `agentic-run` against the PATH-resolved deck stub, producing bills `7/7`; all nine deck scenarios passed. |
| Current Pi | `pi-extension/test/current-bridge.test.ts`; Pi `agent-session-prompt.test.ts` | Authenticated ACP bridge used one exclusive `TaskTurnHandle`, returned exactly its turn, distinguished `followUp` from interrupting `steer`, rejected late steering, aborted, and blocked interleaved prompts. |
| Tool-free child Pi | `pi-extension/test/pi-child-acp.test.ts`; `pi-extension/test/owned-child-e2e.test.ts` | Real in-memory children handshake/cancel/clean up concurrently; a local OpenAI-compatible fixture then answers the real `structured` workflow, agent-cat decodes it, and resume reuses the durable answer with zero additional model requests. |
| Authenticated remote Pi | `pi-extension/test/pi-remote-acp.test.ts`; focused Pi protocol/client/server/remote-session suites | Authenticated discovery selected a durable session; exclusive cross-connection ownership conflicted before work; prompt/snapshot/reconnect/reattach/cancel passed; `next-boundary` reached `follow_up`, while `interrupt-now` reached `steer`; a live JSONL canary remained byte-identical. |

## Control and recovery coverage

| Flow | Executable observation |
|---|---|
| Interrupt-now and next-boundary steering | Current and remote adapter fixtures assert different underlying operations and terminal acknowledgements. `test/control_probe.py` drives `test/steer_adapter.py` through the real machine; the policy probe verifies in-flight provenance and non-replayability. |
| Scheduler redirect | `pi-extension/test/supervisor.test.ts` opens a reserved dispatch window, rejects unreserved/active targets, delivers the control, and records the selected target and attempt. The Haskell controlled-redirect probe verifies that authored `Q` is unchanged. |
| Retry | `test/control_probe.py` drives `test/retry_adapter.py`: automatic decoding recovery is exhausted, the runtime advertises retry/abandon, one correlated retry is delivered, and `occurrence.recovery-chosen`/`occurrence.retried` are recorded. |
| Failover | The supervisor fixture advertises failover only when offered, records the choice, starts a new physical attempt at `model@spare`, and succeeds. |
| Abandon | The same real-machine probe selects advertised abandon, receives a delivered acknowledgement, emits occurrence/run failure, exits with the documented non-success code, and never invents an answer. |
| Cancellation | TUI flow above plus supervisor process-tree fixtures verify acknowledged cancellation, idempotence, EOF cleanup, and TERM/KILL fallback with `forced-termination` classification. |

## Restart, resume, fork, edit, and diff

`test/lineage_probe.py` invokes the real runner and verifies:

- restart inherits no answers;
- crash-resume reuses compatible completed answers without redoing their attempts;
- resume/fork refuse any started or completed effect journal;
- fork replacement (`--set-answer`) reuses the replacement and marks it replaced;
- fork drop (`--drop-answer`) reruns that occurrence;
- invalid edits and incompatible fingerprints fail before a child manifest exists;
- every parent store remains byte-identical.

`pi-extension/test/extension.test.ts` additionally launches a grant-gated fork with an answer drop, verifies the private supervisor manifest records the edit, and exercises `/workflow-diff` against the immutable parent. The interactive fork collector permits multiple distinct drops/replacements in one child.

## Fail-closed protocol and degradation

The reducer/store suites explicitly reject canonical-timestamp violations, identical and conflicting duplicate sequence numbers, gaps, torn or divergent journals, duplicate occurrences/attempts/traces, unknown references, invalid acknowledgement transitions, active-attempt terminal transitions, and post-terminal events. Machine emission splits large attempt chunks losslessly, checks every encoded envelope against the 1 MiB limit, refuses oversized non-output events, and bounds incoming ACP lines before JSON decoding. `test/oversize_adapter.py` proves an oversized adapter chunk yields a bounded named machine failure rather than an oversized stdout record.

The extension's print/JSON/RPC characterization uses `hasUI=false` in each mode. Catalogue and status remain bounded textual/structured output; launch and lineage mutation refuse with `requires interactive approval` instead of attempting a hidden prompt. Non-TUI monitor rendering is bounded. Machine stdout contains protocol envelopes only; diagnostics remain on stderr.

## Fresh verification commands

```sh
cd haskell
./ci/tier0.sh
nix develop -c cabal run -v0 tier1
./ci/policies.sh
./ci/examples.sh
./ci/acp.sh
./ci/deck.sh

cd ../pi-extension
npm run check
npm test
AGENT_CAT_E2E_RUNNER="$(cd ../haskell && nix develop -c cabal list-bin agentic-run)" npm run test:integration

cd ~/db/pi
npm run check
npx vitest run packages/protocol/test/protocol.test.ts
npx vitest run packages/client/test/sessions.test.ts
npx vitest run packages/server/test/sessions.test.ts packages/server/test/unix.test.ts
npx vitest run packages/coding-agent/test/client/remote-session.test.ts \
  packages/coding-agent/test/client/remote-session-lifecycle.test.ts \
  packages/coding-agent/test/client/remote-session-ownership.test.ts \
  packages/coding-agent/test/suite/agent-session-prompt.test.ts
```

The latest full/focused results were: agent-cat tier0 `193/193`, tier1 `30/30`, all policy/lineage/control/example gates, ACP `16/16`, deck `9/9`; extension TypeScript clean with a built runner and accompanying Pi `59/59`, explicit non-skipping target integration `8/8`, and a clean pinned install `54` passed plus `5` integration tests skipped because their runner/local-Pi prerequisites are absent; Pi protocol `50`, client `7`, server `18`, and coding-agent focused `37`, all passing. `git diff --check` was clean.

## Result

Every selected target and control has either an observed representative TUI flow or a deterministic executable target fixture; this record does not claim unobserved current/child/remote TUI model turns. No paid call is part of acceptance. The deliberate constraints remain: child Pi is tool-free; current Pi is exclusive and visible, not sandboxed; remote Pi requires an authenticated operator-configured transport and exclusive lease; native ACP/deck are process/session boundaries, not OS sandboxes; pause/unpause and nested workflows are absent rather than simulated. The final focused read-only review and independent completion audit both found no blocking issues and `APPROVED`.
