# agent-cat Pi extension

Pi control plane for agent-cat workflows. Agent-cat remains the only workflow interpreter; this package discovers runners, gathers inputs, launches machine mode, reduces events, supervises controls, and renders status.

## Configuration

Set user-owned environment variables before starting Pi:

```sh
export AGENT_CAT_RUNNER=/absolute/path/to/agentic-run
export AGENT_CAT_STATE_DIR=$HOME/.pi/agent/agent-cat       # optional
export AGENT_CAT_RETENTION_DAYS=30                         # 0 disables age pruning
export AGENT_CAT_MAX_RUNS=100                              # 0 disables count pruning
```

For ordered multi-runner catalogues, use `AGENT_CAT_RUNNERS` instead of `AGENT_CAT_RUNNER`:

```sh
export AGENT_CAT_RUNNERS='[{"id":"stable","executable":"/opt/agentic-run","allowedCwds":["/work"]},{"id":"next","executable":"/opt/agentic-run-next"}]'
```

Remote Pi servers additionally require a private transport. The session ID is optional; when omitted, the extension uses Pi's authenticated discovery API and asks the user to select a durable session:

```sh
export AGENT_CAT_PI_REMOTE_SOCKET=/absolute/private/pi.sock
export AGENT_CAT_PI_REMOTE_SESSION=<known-session-id>  # optional
```

The runner path and state directory must be absolute. No project file or repository scan implicitly grants runner trust, and every mutable launch additionally requires Pi's `ctx.isProjectTrusted()` decision for the cwd. Adapter argv containing credential-like flags/values is refused; credentials must remain in inherited environment/provider configuration and are never written to supervisor manifests. Remote transport authentication occurs before Pi protocol bytes; Unix transport relies on private socket permissions. The remote session is acquired exclusively across client connections.

Install dependencies for development with:

```sh
npm ci --legacy-peer-deps --ignore-scripts
npm run check
npm test
AGENT_CAT_E2E_RUNNER="$(cd ../haskell && nix develop -c cabal list-bin agentic-run)" npm run test:integration
```

Remote ownership, boundary-follow-up, and correlated current-session turns require the accompanying Pi protocol/client/server/coding-agent changes (`attach.mode`, `follow_up`, `RemoteSession.discover`, and `ExtensionAPI.startTaskTurn`). The current-session choice is hidden when `startTaskTurn` is absent; configured remote targets rely on their own Pi protocol APIs rather than an unrelated current-session capability probe. Durable manifests record an explicit target kind for lineage reconstruction. The pinned install keeps ordinary unit development reproducible. `test:integration` is deliberately non-skipping: it requires a built runner and the accompanying local Pi packages, then exercises native ACP/deck, current, owned-child, and remote targets without paid calls.

## Commands

- `/wf` — catalogue and exact runner help.
- `/workflow-help RUNNER:WORKFLOW` — exact `help` output.
- `/workflow-plan RUNNER:WORKFLOW` — actual-input `plan --json --raw`.
- `/workflow RUNNER:WORKFLOW` — approved launch wizard.
- `/workflow-status` — active and recent run summaries.
- `/workflow-monitor [RUN_ID]` — live authored-order monitor; arrows or `j`/`k`, Enter to fold, Escape to close.
- `/workflow-steer [RUN_ID]` — exact-attempt steering.
- `/workflow-retry [RUN_ID]` — retry an occurrence waiting after automatic recovery is spent.
- `/workflow-recover [RUN_ID]` — choose one runner-offered retry, failover, or abandon action for a recoverable occurrence.
- `/workflow-redirect RUN_ID OCCURRENCE_ID RESERVED_TARGET` — scheduler-bound redirect during the 30-second human decision window.
- `/workflow-grant` — issue a one-time scoped grant for model-initiated starts, lineage, or controls.
- `/workflow-restart PARENT_RUN_ID` — new run from scratch with immutable lineage.
- `/workflow-resume PARENT_RUN_ID` — compatible semantic resume.
- `/workflow-fork PARENT_RUN_ID` — immutable workflow fork with zero or more persisted-answer drops/replacements (not Pi conversation fork).
- `/workflow-diff CHILD_RUN_ID` — compare lineage, target/program identity, answer edits, and per-occurrence outcomes with the immutable parent.
- `/workflow-cancel RUN_ID` — approved cancellation of an owned live run.

The `agent_cat_workflow` model tool can discover, start (scripted/tool-free-child/known-remote), inspect, control, restart, resume, or fork runs. Every mutation requires an unused matching `grantId` issued explicitly by `/workflow-grant`; unresolved or expired grants refuse before spend. Controls await agent-cat's terminal acknowledgement and report `delivered`, `rejected-stale`, `unsupported`, or `failed` verbatim—"requested" is never presented as success.

## Targets and containment

- **Scripted:** offline table; no commands.
- **Native ACP:** configured adapter plus validated descriptor-pin routes, in agent-cat's scratch cwd. Built-ins are `stub`, `claude`, `codex`, and `droid`; Droid launches `droid exec --output-format acp`. Not an OS sandbox.
- **Native agent-deck:** configured external session plus validated descriptor-pin routes.
- **Current Pi session:** visible exclusive injected turns in the current project. This is not a sandbox.
- **Owned Pi child:** agent-cat scratch cwd, in-memory Pi session, tools disabled.
- **Known or authenticated-discovered remote Pi session:** its remote workspace under an exclusive lease. This is not a sandbox.
- **ACP/deck routes:** still launched and interpreted by agent-cat.

For Droid, install and authenticate the `droid` executable before starting Pi, or inherit `FACTORY_API_KEY` into Pi's environment. Never enter a key in the adapter argv editor; credentials are rejected from argv and omitted from manifests.

Select a Factory model and reasoning level through agent-cat's normal symbolic routing profile, not adapter arguments. The workflow's `servedBy` name must match the profile; a Droid router uses `backend: acp:droid`, and because Droid exposes no output-limit control the required policy is explicit:

```yaml
version: 1
routers:
  - name: factory-droid
    backend: acp:droid
    provider: factory
profiles:
  - name: deep
    chain:
      - router: factory-droid
        model: gpt-5.6-luna
        thinking: low
        max-output: unconstrained
```

Pi passes the selected routes to agent-cat; agent-cat preflights the advertised model/reasoning setters before any prompt. Omitting `max-output` or declaring any unsupported setting refuses the run.

Effectful workflows cannot use the tool-free child target. Current/remote live targets require an explicit charge/ownership confirmation. Agent-cat's intent-based ACP permission policy remains authoritative.

## Persistence and recovery

Supervisor state is private under `STATE/runs/<run-id>/`; the agent-cat store is the `runtime/` child. Pi transcript entries contain references and terminal status, not copied prompts or credentials. A mode-0600 owner heartbeat lets another Pi process attach read-only to a live run's mirrored event stream; controls remain with the original exclusive supervisor. Dead owners become `orphaned`.

Agent-cat persists:

- immutable manifest and full actual-program compatibility value;
- append-only protocol events;
- schema-indexed reusable answers keyed by complete bare-question JSON;
- started/completed effect journal;
- atomic checkpoints and ownership/lineage.

Resume reuses only exact compatible reusable answers. A changed program/target/policy, corrupt or unknown store version, mismatched checkpoint counts, invalid stored-answer schema, or any started/completed parent effect refuses before child creation. Restart is always a new run. Fork inherits only matching bare-question answers, may drop or replace selected persisted answers after runner-owned schema-validating preflight, and never mutates its parent. `/workflow-diff` reports durable edit hashes and resulting occurrence differences. Steered answer groups are marked non-replayable.

On extension restart, terminal records are reconstructed from snapshots or agent-cat events. A nonterminal run with no owned control channel is shown as `orphaned`; it is never presented as live or controllable. Use restart, resume, or fork.

## Security and limits

- direct argv spawning; no shell command construction;
- mode-0600 input files, deleted after terminal cleanup;
- user-private run/store directories;
- 1 MiB protocol frames, canonical UTC timestamps, and fail-closed sequence/lifecycle reduction;
- 64 KiB in-memory attempt-output tails;
- 10 MiB redacted stderr logs;
- environment values with credential-like names and common token syntax are redacted;
- graceful control cancellation, then process-group TERM/KILL fallback;
- retention never prunes orphaned runs or an immutable parent referenced by retained lineage.

Unsupported or stale controls produce explicit acknowledgements. Non-TUI modes can list/status and receive bounded textual monitors, but launch and lineage approval refuse when interactive UI is unavailable.
