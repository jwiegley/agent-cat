# ext-pi

`ext-pi` is a Pi extension that makes Pi the control plane for agent-cat
workflows. agent-cat remains the only workflow interpreter. The extension reads
the trusted runner executables that its configuration names, and it gathers
inputs and launches the runner in machine mode. It reduces the event stream of
the runner into a live monitor, delivers controls, and keeps durable references
to runs. It never searches the file system or `PATH` for a runner.

## Boundary

Pi loads `src/index.ts`, which registers the `/wf` command, the
`/workflow-...` commands, and the `agent_cat_workflow` tool. The extension
imports no Haskell code and never interprets a `RawProgram` or a `Plan`. It
speaks three versioned process protocols of `agentic-run`: the descriptor that
`list --json` publishes (version 3, while versions 1 and 2 remain accepted), the
machine event stream (protocol version 2 when advertised, with version 1 retained
for older runners), and the correlated control channel. Descriptor v3 advertises
sanitized routing inspection and protocol negotiation; v2 completion carries a
verified private result reference.
The CLI and runtime own scheduling, persistence semantics, effects, and engine
behavior; the extension owns trusted
discovery, approval, supervision, the user interface, retention, and durable
run references.

## Configuration

Set the user-owned environment variables before you start Pi:

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

A remote Pi server requires a private transport in addition. The session
identifier is optional. When it is omitted, the extension uses the
authenticated discovery of Pi and asks the user to select a durable session:

```sh
export AGENT_CAT_PI_REMOTE_SOCKET=/absolute/private/pi.sock
export AGENT_CAT_PI_REMOTE_SESSION=<known-session-id>  # optional
```

The runner path and the state directory must be absolute. No project file and
no repository scan grants trust to a runner, and every mutable launch also
requires the project-trust decision of Pi for the working directory. The
extension refuses adapter arguments that contain credential-like flags or
values. Under routing version 2, credentials remain environment references that
agent-cat resolves. The extension receives neither those references nor their
values. A routing-only private manifest contains only the sanitized launch,
persona, and model-alias arguments. Lineage carries that exact target vector
forward instead of silently selecting current defaults. Explicit targets remain
explicit across lineage. Remote
transport authentication occurs before any Pi protocol bytes are exchanged.
The Unix transport relies on private socket permissions, and a remote session
is acquired exclusively across client connections.

Protocol-v2 runs retain typed public tool, complete plan/todo, and context-usage
updates separately from answer chunks. Obvious credential-bearing diagnostic
lines are redacted before persistence. ACP thought chunks are not public reasoning
summaries and are ignored. Engines that report no optional progress acquire none.

`/wf` requires Pi to run inside Agent Deck. It reads the inherited
`AGENTDECK_INSTANCE_ID`, and it never scans for another Agent Deck session or
asks the user to name one.

## Source-aware inputs

A workflow author declares where each named input normally comes from, in the
ordinary input chain:

```haskell
taking (argsInput :> stdinInput :> input "tone" :> noInputs) \args body tone -> …
```

`argsInput` declares the command-tail input under the default name `args`, and
`stdinInput` declares the standard-input value under the default name `input`.
`argsInputAs` and `stdinInputAs` choose other names. Names are unique. A
workflow can declare at most one command-tail source and at most one
standard-input source.

`/wf` takes the workflow name and the unsplit command-tail text on its first
line, and then it takes a multiline body:

```text
/wf review Scope of the review

  These are instructions on what I want the review to focus on
```

This binds `args` to `Scope of the review` and `input` to the body. The
extension removes only the leading whitespace of the body, and it preserves the
internal and trailing whitespace. A missing tail or body value falls back to
the ordinary input editor. Tail or body text without a matching declaration
fails before any confirmation and before any run state is created.

The same declaration serves a direct pipe into the runner:

```sh
cat instructions.txt | agentic-run run review --session "$AGENTDECK_INSTANCE_ID" \
  --input-arg args='Scope of the review'
```

Machine mode reserves file descriptor 0 for that payload and takes control
NDJSON on inherited file descriptor 3. Descriptor version 3 retains protocol
version 1 while advertising negotiation and routing capabilities. A runner that
publishes descriptor version 1 remains prompt-only and keeps its controls on
standard input. A multiline body requires descriptor version 2 or 3 and support
for the control descriptor.

## Commands

| Command | Purpose |
|---|---|
| `/wf [RUNNER:WORKFLOW]` | Launch in the current Agent Deck session. Omit the name to select from the catalogue. |
| `/workflow-help RUNNER:WORKFLOW` | Show the exact `help` output of the runner. |
| `/workflow-plan RUNNER:WORKFLOW` | Show `plan --json --raw` with the actual inputs. |
| `/workflow RUNNER:WORKFLOW` | Compatibility launch wizard for alternate targets. |
| `/workflow-status` | Summaries of active and recent runs. |
| `/workflow-monitor [RUN_ID]` | Live monitor in authored order. The arrow keys or `j` and `k` move, Enter folds, and Escape closes. |
| `/workflow-steer [RUN_ID]` | Steer one exact attempt. |
| `/workflow-retry [RUN_ID]` | Retry an occurrence that waits after automatic recovery is spent. |
| `/workflow-recover [RUN_ID]` | Choose one runner-offered retry, fail-over, or abandon action. |
| `/workflow-redirect RUN_ID OCCURRENCE_ID RESERVED_TARGET` | Redirect a scheduler-reserved occurrence during the thirty-second decision window. |
| `/workflow-grant` | Issue a one-time scoped grant for model-initiated starts, lineage, or controls. |
| `/workflow-restart PARENT_RUN_ID` | Start a new run from scratch with immutable lineage. |
| `/workflow-resume PARENT_RUN_ID` | Resume a compatible run semantically. |
| `/workflow-fork PARENT_RUN_ID` | Fork a workflow immutably, with drops or replacements of persisted answers. This is distinct from a Pi conversation fork. |
| `/workflow-diff CHILD_RUN_ID` | Compare lineage, identity, answer edits, and outcomes with the immutable parent. |
| `/workflow-cancel RUN_ID` | Cancel an owned live run after approval. |

The `agent_cat_workflow` tool lets a model discover, start, inspect, control,
restart, resume, or fork runs. Starts from the tool are limited to the
scripted, tool-free child, and known remote targets. Every mutation requires an
unused matching grant from `/workflow-grant`, and an unresolved or expired grant
refuses before anything is spent. Controls wait for the terminal acknowledgement
of agent-cat, and they report `delivered`, `rejected-stale`, `unsupported`, or
`failed` verbatim. A request is never presented as a success.

## Routing selection

`/wf` always uses the current Agent Deck session and does not inspect or load
routing configuration. `/workflow` offers routing configuration as a distinct
live target when a trusted descriptor-version-3 runner advertises inspection.
For that target, Pi invokes `agentic-run --routing --json`, offers the configured
persona or another user-owned persona, and offers optional concrete model aliases
for the workflow's managed profile axes. It passes the CLI-owned routing-only
launch arguments and fingerprint plus explicit persona and realization choices.
The runner requires full pin coverage. Explicit ACP, Agent Deck, current-session,
owned-child, and remote targets do not load routing configuration. Raw `--route`
remains available for explicit native ACP and Agent Deck targets.

The extension validates the sanitized version-2 projection and rejects fields
for secrets, environment bindings, headers, authorization, or endpoint URLs. It
never opens `routing.yaml`, resolves a selector, reads a cache, or interprets an
engine. Descriptor-version-1 and version-2 runners, and a version-3 runner that
uses version-1 routing, retain the previous route wizard. Supervisor manifests
have mode 0600 and store only the selected non-secret argument vector.

## Targets and containment

| Target | What answers | Containment |
|---|---|---|
| Scripted | The registered canned table. | Offline. No command runs. |
| Routing configuration | Configured profile engines. Every engine-bound question must have a configured pin. | Containment depends on every selected engine. |
| Native ACP | One explicit adapter plus optional raw pin routes. The built-in adapters are `stub`, `claude`, `codex`, and `droid`, and `droid` launches `droid exec --output-format acp`. | The scratch directory of agent-cat, which is not an operating-system sandbox. |
| Native agent-deck | The Agent Deck session that `/wf` inherits, or a session chosen in `/workflow`, plus optional raw pin routes. | The workspace of that session. |
| Current Pi session | Visible, exclusive injected turns in the current project. | Not a sandbox. |
| Owned Pi child | An in-memory Pi session with tools disabled. | The scratch directory of agent-cat. |
| Remote Pi session | A known or discovered session under an exclusive lease. | Its remote workspace, which is not a sandbox. |

For Droid, install and authenticate the `droid` executable before you start Pi,
or inherit `FACTORY_API_KEY` into the environment of Pi. Never enter a key in
the editor for adapter arguments. Select a Factory model and a reasoning level
through the symbolic routing profile of agent-cat, and not through adapter
arguments. The `servedBy` name of the workflow must match the profile, and a
Droid router uses `backend: acp:droid`. Droid exposes no output-limit control,
so the output policy must be stated explicitly:

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

Pi passes the selected routes to agent-cat, and agent-cat preflights the
advertised model and reasoning setters before any prompt. If `max-output` is
omitted, or if any declared setting is unsupported, the run is refused. An
effectful workflow cannot use the tool-free child target. The current and
remote live targets require an explicit confirmation of charge and ownership.
The intent-based permission policy of agent-cat under ACP remains
authoritative.

## Persistence and recovery

Supervisor state is private under `STATE/runs/<run-id>/`, and agent-cat's own
store is the `runtime/` child of that directory. New runs use frontend manifest
version 2, shared with the terminal frontend; legacy extension manifests remain
readable. Pi transcript entries hold references and terminal status, never copied
prompts or credentials. A mode-0600 owner heartbeat lets another Pi or TUI process
attach read-only to a live run's event stream while controls stay with the original
exclusive supervisor; a dead owner leaves the run `orphaned`. State sharing occurs
only when those frontends are explicitly given the same `AGENT_CAT_STATE_DIR`.

agent-cat persists six kinds of state. These are an immutable manifest with a
fixed reference to a private `program.json`, an append-only event journal, and
schema-indexed reusable answers that are keyed by the complete bare question.
The other three are a journal of started and completed effects, atomic
checkpoints, and ownership and lineage. Resume reuses only exact compatible
answers. A changed program, target, or policy refuses before a child is
created. A corrupt or unknown store version, a mismatched checkpoint count, an
invalid stored-answer schema, or any started or completed parent effect also
refuses. Restart is always a new run.
Fork inherits only matching bare-question answers. It can drop or replace
selected answers after the schema-validating preflight of the runner, and it
never mutates its parent. `/workflow-diff` reports the durable edit hashes and
the resulting occurrence differences. Steered answer groups are marked as not
replayable.

When the extension restarts, it reconstructs terminal records from snapshots or
from agent-cat events. A malformed manifested run is isolated as
`corrupt-store`. A fresh directory without a manifest is ignored, so that it
cannot hide valid history, and stale incomplete directories follow retention
cleanup. A run that is not terminal and has no owned control channel is shown
as `orphaned`, and it is never presented as live or controllable. Restart,
resume, or fork such a run instead.

## Security and limits

Processes are spawned with a direct argument vector and never through a shell.
Input and program files are mode 0600, and transient launch inputs are deleted
after terminal cleanup; Agent Deck message files are mode 0600 and deleted
after each send, and prompt text never enters an argument vector or a machine
diagnostic. Run and store directories are private to the user. Protocol frames
are bounded at 1 MiB with canonical UTC timestamps and fail-closed sequence and
lifecycle reduction; in-memory attempt-output tails are bounded at 64 KiB, and
redacted standard-error logs at 10 MiB. Public progress text, collections, event
counts, and tool histories are bounded; stored event identities use fixed-size
digests. Environment values with credential-like
names or common token syntax are redacted. Cancellation is graceful first and
falls back to a process-group TERM and KILL. Retention never prunes an orphaned
run or an immutable parent that retained lineage references.

Unsupported or stale controls produce explicit acknowledgements. Modes without a
terminal user interface can list runs and show bounded textual monitors, but
launch and lineage approval refuse when interactive approval is unavailable.

## Build and test

```sh
npm ci --legacy-peer-deps --ignore-scripts
npm run check
npm test
AGENT_CAT_E2E_RUNNER="$(cd .. && nix develop path:. -c cabal list-bin agentic-run)" npm run test:integration
```

Remote discovery and control use Pi's Chord `SessionDirectory`,
`SessionManagement`, `AgentController`, and `Transcript` services. Boundary
follow-up uses `AgentController.followUp`. Correlated current-session turns
require `ExtensionAPI.startTaskTurn`, and the current-session choice is hidden
when that method is absent.

Set `PI_PACKAGE_DIR` to the coding-agent package directory of a built Pi
checkout to use it for the adapters and integration fixtures. For
`~/src/fork/pi`, this is `~/src/fork/pi/packages/coding-agent`. Its matching
client, server, and Chord packages resolve through Node's package resolution.
The integration gate requires a built runner and these Pi packages. It checks
that every named test exists and exercises native ACP, native deck, current,
owned-child, and remote targets without a paid call. Remote follow-up support
is checked through an actual control exchange rather than a class-name probe.

## Conventions

Keep this package a strict protocol client. Preserve project trust, explicit
grants, private files, bounded logs and events, fail-closed reduction, and
process cleanup. Add runner capability through versioned protocol fields, and
not through source imports or inference from prose.
