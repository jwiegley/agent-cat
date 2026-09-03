# ext-pi

`ext-pi` is a Pi extension that makes Pi the control plane for agent-cat
workflows. agent-cat remains the only workflow interpreter. The extension reads
the trusted runner executables named in its configuration, gathers inputs,
launches the runner in machine mode, reduces its event stream into a live
monitor, delivers controls, and keeps durable references to runs. It never
searches the file system or `PATH` for a runner.

## Boundary

Pi loads `src/index.ts`, which registers the `/wf` command, the
`/workflow-...` commands, and the `agent_cat_workflow` tool. The extension
imports no Haskell code and never interprets a `RawProgram` or a `Plan`. It
speaks three versioned process protocols of `agentic-run`: the descriptor that
`list --json` publishes (version 2), the machine event stream (protocol version
1), and the correlated control channel. The CLI and the runtime own scheduling,
persistence semantics, effects, and engine behavior; the extension owns trusted
discovery, approval, supervision, the user interface, retention, and durable
run references.

## Configuration

Set the user-owned environment variables before starting Pi:

```sh
export AGENT_CAT_RUNNER=/absolute/path/to/agentic-run
export AGENT_CAT_STATE_DIR=$HOME/.pi/agent/agent-cat       # optional
export AGENT_CAT_RETENTION_DAYS=30                         # 0 disables age pruning
export AGENT_CAT_MAX_RUNS=100                              # 0 disables count pruning
```

For an ordered catalogue over several runners, set `AGENT_CAT_RUNNERS` instead
of `AGENT_CAT_RUNNER`:

```sh
export AGENT_CAT_RUNNERS='[{"id":"stable","executable":"/opt/agentic-run","allowedCwds":["/work"]},{"id":"next","executable":"/opt/agentic-run-next"}]'
```

A remote Pi server additionally requires a private transport. The session
identifier is optional; when it is omitted, the extension uses Pi's
authenticated discovery and asks the user to select a durable session:

```sh
export AGENT_CAT_PI_REMOTE_SOCKET=/absolute/private/pi.sock
export AGENT_CAT_PI_REMOTE_SESSION=<known-session-id>  # optional
```

The runner path and the state directory must be absolute. No project file and
no repository scan grants runner trust, and every mutable launch additionally
requires Pi's project-trust decision for the working directory. Adapter
arguments that contain credential-like flags or values are refused; credentials
stay in the inherited environment or provider configuration and are never
written to a manifest. Remote transport authentication occurs before any Pi
protocol bytes, the Unix transport relies on private socket permissions, and a
remote session is acquired exclusively across client connections.

`/wf` requires Pi to be running inside Agent Deck. It reads the inherited
`AGENTDECK_INSTANCE_ID` and never scans for, or asks the user to name, another
Agent Deck session.

## Source-aware inputs

A workflow author declares where each named input normally comes from, in the
ordinary input chain:

```haskell
taking (argsInput :> stdinInput :> input "tone" :> noInputs) \args body tone -> …
```

`argsInput` declares the command-tail input under the default name `args`, and
`stdinInput` declares the standard-input value under the default name `input`;
`argsInputAs` and `stdinInputAs` choose other names. Names are unique, and at
most one command-tail source and one standard-input source may be declared.

`/wf` takes the workflow name and the unsplit command-tail text on its first
line, then a multiline body:

```text
/wf review Scope of the review

  These are instructions on what I want the review to focus on
```

This binds `args` to `Scope of the review` and `input` to the body. Only
leading whitespace of the body is removed; internal and trailing whitespace is
preserved. A missing tail or body value falls back to the ordinary input
editor. Tail or body text without a matching declaration fails before any
confirmation or run state is created.

The same declaration serves a direct pipe into the runner:

```sh
cat instructions.txt | agentic-run run review --session "$AGENTDECK_INSTANCE_ID" \
  --input-arg args='Scope of the review'
```

Machine mode reserves file descriptor 0 for that payload and takes control
NDJSON on the inherited descriptor 3. A runner that publishes descriptor
version 1 remains prompt-only and keeps stdin controls; multiline bodies
require descriptor version 2 and control-descriptor support.

## Commands

| Command | Purpose |
|---|---|
| `/wf [RUNNER:WORKFLOW]` | Launch in the current Agent Deck session; omit the name to select from the catalogue. |
| `/workflow-help RUNNER:WORKFLOW` | Show the runner's exact `help` output. |
| `/workflow-plan RUNNER:WORKFLOW` | Show `plan --json --raw` with the actual inputs. |
| `/workflow RUNNER:WORKFLOW` | Compatibility launch wizard for alternate targets. |
| `/workflow-status` | Summaries of active and recent runs. |
| `/workflow-monitor [RUN_ID]` | Live monitor in authored order; arrows or `j` and `k` move, Enter folds, Escape closes. |
| `/workflow-steer [RUN_ID]` | Steer one exact attempt. |
| `/workflow-retry [RUN_ID]` | Retry an occurrence that is waiting after automatic recovery is spent. |
| `/workflow-recover [RUN_ID]` | Choose one runner-offered retry, fail-over, or abandon action. |
| `/workflow-redirect RUN_ID OCCURRENCE_ID RESERVED_TARGET` | Redirect a scheduler-reserved occurrence during the thirty-second decision window. |
| `/workflow-grant` | Issue a one-time scoped grant for model-initiated starts, lineage, or controls. |
| `/workflow-restart PARENT_RUN_ID` | New run from scratch with immutable lineage. |
| `/workflow-resume PARENT_RUN_ID` | Compatible semantic resume. |
| `/workflow-fork PARENT_RUN_ID` | Immutable workflow fork with persisted-answer drops or replacements; distinct from a Pi conversation fork. |
| `/workflow-diff CHILD_RUN_ID` | Compare lineage, identity, answer edits, and outcomes with the immutable parent. |
| `/workflow-cancel RUN_ID` | Approved cancellation of an owned live run. |

The `agent_cat_workflow` tool lets a model discover, start, inspect, control,
restart, resume, or fork runs; starts are limited to scripted, tool-free child,
and known remote targets. Every mutation requires an unused matching grant
issued by `/workflow-grant`, and an unresolved or expired grant refuses before
anything is spent. Controls wait for agent-cat's terminal acknowledgement and
report `delivered`, `rejected-stale`, `unsupported`, or `failed` verbatim; a
request is never presented as a success.

## Targets and containment

| Target | What answers | Containment |
|---|---|---|
| Scripted | The registered canned table. | Offline; no commands run. |
| Native ACP | A configured adapter plus validated descriptor-pin routes. Built-ins are `stub`, `claude`, `codex`, and `droid`; `droid` launches `droid exec --output-format acp`. | agent-cat's scratch directory, which is not an operating-system sandbox. |
| Native agent-deck | The Agent Deck session inherited by `/wf`, or one chosen in the compatibility wizard, plus validated routes. | The session's own workspace. |
| Current Pi session | Visible, exclusive injected turns in the current project. | Not a sandbox. |
| Owned Pi child | An in-memory Pi session with tools disabled. | agent-cat's scratch directory. |
| Remote Pi session | A known or authenticated-discovered session under an exclusive lease. | Its remote workspace; not a sandbox. |

For Droid, install and authenticate the `droid` executable before starting Pi,
or inherit `FACTORY_API_KEY` into Pi's environment. Never enter a key in the
adapter argument editor. A Factory model and reasoning level are selected
through agent-cat's symbolic routing profile rather than through adapter
arguments. The workflow's `servedBy` name must match the profile, a Droid
router uses `backend: acp:droid`, and because Droid exposes no output-limit
control the output policy is stated explicitly:

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

Pi passes the selected routes to agent-cat, which preflights the advertised
model and reasoning setters before any prompt. Omitting `max-output` or
declaring an unsupported setting refuses the run. Effectful workflows cannot
use the tool-free child target, and the current and remote live targets
require an explicit charge and ownership confirmation. agent-cat's intent-based
permission policy under ACP remains authoritative.

## Persistence and recovery

Supervisor state is private under `STATE/runs/<run-id>/`, and agent-cat's own
store is the `runtime/` child of that directory. Pi transcript entries hold
references and terminal status, never copied prompts or credentials. A
mode-0600 owner heartbeat lets another Pi process attach read-only to a live
run's mirrored event stream while controls stay with the original exclusive
supervisor; a dead owner leaves the run `orphaned`.

agent-cat persists an immutable manifest with a fixed reference to a private
`program.json`, an append-only event journal, schema-indexed reusable answers
keyed by the complete bare question, a journal of started and completed
effects, atomic checkpoints, and ownership and lineage. Resume reuses only
exact compatible answers; a changed program, target, or policy, a corrupt or
unknown store version, mismatched checkpoint counts, an invalid stored-answer
schema, or any started or completed parent effect refuses before a child is
created. Restart is always a new run. Fork inherits only matching bare-question
answers, may drop or replace selected answers after the runner's
schema-validating preflight, and never mutates its parent. `/workflow-diff`
reports the durable edit hashes and the resulting occurrence differences.
Steered answer groups are marked non-replayable.

On extension restart, terminal records are reconstructed from snapshots or
from agent-cat events. A malformed manifested run is isolated as
`corrupt-store`; a fresh pre-manifest directory is ignored so that it cannot
hide valid history; and stale incomplete directories follow retention cleanup.
A nonterminal run with no owned control channel is shown as `orphaned` and is
never presented as live or controllable; restart, resume, or fork it instead.

## Security and limits

Processes are spawned with a direct argument vector and never through a shell.
Input and program files are mode 0600, and transient launch inputs are deleted
after terminal cleanup; Agent Deck message files are mode 0600 and deleted
after each send, and prompt text never enters an argument vector or a machine
diagnostic. Run and store directories are private to the user. Protocol frames
are bounded at 1 MiB with canonical UTC timestamps and fail-closed sequence and
lifecycle reduction; in-memory attempt-output tails are bounded at 64 KiB, and
redacted standard-error logs at 10 MiB. Environment values with credential-like
names or common token syntax are redacted. Cancellation is graceful first and
falls back to a process-group TERM and KILL. Retention never prunes an orphaned
run or an immutable parent that retained lineage references.

Unsupported or stale controls produce explicit acknowledgements. Modes without
a terminal user interface can list runs and show bounded textual monitors,
while launch and lineage approval refuse when interactive approval is
unavailable.

## Build and test

```sh
npm ci --legacy-peer-deps --ignore-scripts
npm run check
npm test
AGENT_CAT_E2E_RUNNER="$(cd .. && nix develop path:. -c cabal list-bin agentic-run)" npm run test:integration
```

The pinned install keeps unit development reproducible. Remote ownership,
boundary follow-up, and correlated current-session turns depend on the
accompanying Pi protocol, client, server, and coding-agent changes
(`attach.mode`, `follow_up`, `RemoteSession.discover`, and
`ExtensionAPI.startTaskTurn`); the current-session choice is hidden when
`startTaskTurn` is absent. The integration tests do not skip: they require a
built runner and the accompanying local Pi packages, and they exercise the
native ACP, native deck, current, owned-child, and remote targets without a
paid call.

## Conventions

Keep this package a strict protocol client. Preserve project trust, explicit
grants, private files, bounded logs and events, fail-closed reduction, and
process cleanup. Add runner capability through versioned protocol fields rather
than through source imports or inference from prose.
