# Source-aware workflow inputs

Status: **approved and implemented**
Approval: user replied “I approve this design” on 2026-09-02, before implementation began.
Goal: `mtkjiqtl-25777e`

## Objective

Let workflow authors declare where named text inputs normally come from. `/wf`
binds same-line command-tail text and a multiline body without shell parsing, while
direct `agentic-run run` accepts literal UTF-8 standard input. Machine controls remain
live on a separate channel.

This changes input acquisition only. `RawProgram`, workflow denotation, input order,
and `supply :: [Text] -> ProgramOf r` retain their meanings.

## Authoring surface

The existing `Ins`/`ParameterizedOf` model is canonical:

```haskell
taking
  ( argsInput
      :> stdinInput
      :> input "tone"
      :> noInputs
  )
  \args body tone -> ...
```

Declarations:

```haskell
input        :: Text -> In  -- ordinary prompt/file input
argsInput    :: In          -- command tail, default name "args"
argsInputAs  :: Text -> In  -- custom command-tail name
stdinInput   :: In          -- standard input, default name "input"
stdinInputAs :: Text -> In  -- custom stdin name
```

Canonical metadata:

```haskell
data InputSource = PromptInput | CommandTailInput | StandardInput
data InputSpec = InputSpec
  { inputName   :: Text
  , inputSource :: InputSource
  }
```

Invariants:

- input names are unique;
- at most one command-tail source exists;
- at most one standard-input source exists;
- `run.*` facts remain runner-owned and cannot use operator source declarations;
- invalid declarations fail during catalogue construction, before launch or spend.

## Descriptor and protocol versions

Descriptor version 2 publishes ordered input records:

```json
{
  "descriptorVersion": 2,
  "inputs": [
    {"name": "args", "source": "command-tail"},
    {"name": "input", "source": "stdin"},
    {"name": "tone", "source": "prompt"}
  ]
}
```

Source values are `prompt`, `command-tail`, and `stdin`.

Compatibility rules:

- new clients accept descriptor v1 and v2;
- v1 `inputs: string[]` is upgraded to prompt-source records;
- v2 is strict about fields, source names, duplicate names, and duplicate special
  sources;
- old clients reject v2 safely;
- runtime event/control protocol remains version 1 because frame meanings did not
  change;
- store version remains 1; old stores with inline programs remain readable, while new
  manifests reference private `program.json`;
- runners advertise `capabilities.controlFd = 3`; clients never guess support.

## `/wf` grammar

```text
/wf WORKFLOW [COMMAND-TAIL]
[leading whitespace]
[MULTILINE BODY]
```

Rules:

1. First non-whitespace token on line one is workflow name. Qualified
   `RUNNER:WORKFLOW` names remain valid.
2. Horizontal separator whitespace after workflow name is removed.
3. Remaining first-line text is one raw command-tail value. No shell splitting,
   quoting, interpolation, or tilde expansion occurs.
4. Everything after first newline is processed with `trimStart()` once.
5. Internal and trailing body whitespace is preserved.
6. Whitespace-only tail or body counts as absent.
7. Tail binds declared command-tail input; body binds declared stdin input.
8. Present tail/body without matching declaration fails before prompting,
   confirmation, run-state creation, target contact, or spend.
9. Missing source values and ordinary inputs use normal editor prompts in declaration
   order.
10. Launch target remains inherited `AGENTDECK_INSTANCE_ID`; `/wf` never scans for or
    requests another Agent Deck session.

Example:

```text
/wf review Scope of the review

  These are instructions on what I want the review to focus on
```

Bindings:

```text
args  = "Scope of the review"
input = "These are instructions on what I want the review to focus on"
```

## Direct runner stdin

For `run`, `machine*`, and `lineage-check`:

- if standard-input input remains unbound after explicit input flags, fd 0 is read to
  EOF;
- decoding is strict UTF-8 and reports invalid byte offset;
- empty piped stdin is a valid empty value;
- terminal stdin refuses immediately with piping guidance instead of hanging;
- explicit `--input`, `--input-file`, or `--input-arg` takes precedence and suppresses
  automatic stdin reading;
- duplicate explicit bindings keep existing named refusal;
- stdin and command-tail sources preserve decoded text exactly, including trailing
  newlines;
- ordinary file inputs retain legacy removal of one final LF;
- `plan` and `cost` never auto-read stdin; explicit flags remain available for an
  actual-input plan.

Input is read wholly before program construction because Haskell input values may
select program shape. This is not streaming workflow semantics.

## Machine control transport

Machine file descriptors:

```text
fd 0  workflow stdin payload
fd 1  runtime event NDJSON
fd 2  setup/transport diagnostics
fd 3  control NDJSON
```

The Pi supervisor creates anonymous fd 3 and sets `AGENT_CAT_CONTROL_FD=3`. The
runner starts its control reader before stdin and route-dependent program construction.
Control events queue until `run.started` and the durable event sink exist, then flush
in sequence. Cancellation therefore interrupts a blocked stdin read.

Control protocol still supports:

- whole-run cancellation;
- interrupt-now and next-boundary steering;
- retry, failover, and abandon;
- scheduler-reserved pre-dispatch redirect;
- accepted/delivered/rejected/unsupported/failed acknowledgements;
- control EOF as owner-loss cancellation.

Legacy `AGENT_CAT_CONTROL_STDIN=1` remains valid when stdin-designated workflow data
was supplied explicitly. Selecting both control channels fails. Automatic workflow
stdin plus legacy stdin controls fails clearly.

Rejected alternatives:

- multiplexing payload and controls on fd 0: incompatible with literal pipes and
  ambiguous around EOF;
- Unix socket: unnecessary authentication, naming, and cleanup surface for a
  parent-owned anonymous pipe;
- temporary-file-only workflow input: does not satisfy literal OS stdin.

## Security and persistence

- `/wf` values use mode-0600 files under mode-0700 run directories.
- Standard-input value is planned from private file, then streamed over fd 0; its path
  and value are omitted from machine argv.
- Supervisor manifest stores input hashes, never values.
- Runtime `manifest.json` references mode-0600 `program.json`; input-expanded program
  text is absent from manifest.
- Agent Deck prompts use mode-0600 `--message-file`, never positional argv.
- Machine mode does not duplicate input-expanded human narration into stderr.
- Payload never enters control frames.
- Agent Deck message files are deleted after each send, including failure/timeout.
- Launch input files are deleted after terminal cleanup.
- Malformed run records are isolated as `corrupt-store`; fresh pre-manifest directories
  cannot hide valid history, and stale incomplete directories follow retention cleanup.
- Pi editor history may retain text typed into `/wf`; this local host behavior is
  documented rather than hidden.

Private event, answer, checkpoint, and `program.json` state may contain prompts and
answers. It remains owner-only and subject to configured retention.

## Failure behavior

Fail before side effects for:

- unknown workflow;
- missing Agent Deck context;
- body/tail without matching source declaration;
- malformed descriptor metadata;
- duplicate input/source declarations;
- invalid UTF-8;
- terminal stdin with missing value;
- simultaneous legacy and fd control selection;
- stdin workflow on runner lacking fd-control capability;
- malformed or unsupported control frames.

No failure path may echo source text in argv, manifests, diagnostics, or control
frames.

## Verification matrix

| Area | Required regression evidence |
|---|---|
| Authoring | default/custom names, ordering, duplicate names, multiple command-tail/stdin sources, `run.*` refusal |
| Descriptor | exact v2 JSON, v1 upgrade, malformed source/name/cardinality refusal |
| `/wf` | selector and named paths, unsplit tail, leading-only body trim, trailing preservation, remaining prompts, pre-side-effect errors, current deck target |
| CLI stdin | UTF-8, invalid bytes, empty EOF, terminal refusal, exact byte count, explicit override |
| Machine controls | literal stdin plus cancel, control EOF, steer, retry, failover, abandon, and redirect through real Haskell machine transport |
| Privacy | no payload in argv, supervisor/runtime manifests, Agent Deck failure diagnostics, or control frames; private file modes and deletion |
| Recovery | malformed manifests isolated; incomplete pre-manifest directory cannot block valid restoration |
| Integration | Haskell build/policy/examples/deck/lineage/control gates, TypeScript typecheck/full suite, real ACP/Agent Deck E2E, downstream descriptor-v1/v2 catalogue gate, local-source managed Nix package build |

No paid model call is required.
