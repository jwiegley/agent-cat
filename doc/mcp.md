# `workflow_mcp`: the workflow server, for a running agent

An MCP server over the closed-plan DSL of `Agentic/Core/Dsl.lean`. It offers
four tools — check a program, start a run, answer its questions, read it back —
and it exists so that an agent can be *driven by* a workflow instead of being
trusted to remember one. The program says which questions get asked, in what
order, of whom; the interpreter decides when a question has been answered; the
report at the end is computed from the log, not from anything the agent said
about it.

The server is `mcp/WorkflowMcp.lean`; the tools are `Agentic/Core/Mcp.lean`; the
framing is `Agentic/Core/Rpc.lean`. It speaks line-delimited JSON-RPC 2.0 on
stdin and stdout, revision `2025-11-25`, and advertises tools and nothing else.
stdout is the protocol and stderr is the diagnostics.

## Registering it

Build first — the binary is not in the repository:

```
lake build            # from the repository root
```

The repository carries a project-scoped `.mcp.json`:

```json
{ "mcpServers": { "workflows": { "type": "stdio",
    "command": "./.lake/build/bin/workflow_mcp", "args": [], "env": {} } } }
```

which any client that reads project-scoped MCP configuration will pick up when
it is started in this directory. The command is relative, so it resolves against
the directory the client was launched in; if yours launches servers elsewhere,
register it by hand with an absolute path instead:

```
claude mcp add --scope local workflows -- /absolute/path/to/.lake/build/bin/workflow_mcp
```

Nothing here touches a global configuration. One option is worth knowing:

```
workflow_mcp --no-elicitation    # never open a dialog; relay every person's question
```

## The DSL

A program is a preamble of textual macros and one `workflow` block:

```
define spec = "harden the parser"

workflow {
  let guide = ask text tool "cat" "Write out the house style guide."
  let draft = @model "deep" ask text model "author"
      "Draft a patch satisfying:\n{spec}\nReply with a unified diff only."
  revising draft upto 2
    check (patch) { panel [ ask verdict model "reviewer" "{guide}\nIs {patch} correct?" ] }
    with (patch, why) { @model "deep" ask text model "author" "Revise:\n{patch}\n{why}" }
    accepted (patch) {
      let ok = ask flag person "owner" "Apply this patch?\n{patch}"
      case ok { yes -> { act tool "apply" "Apply:\n{patch}" }
                no  -> { done } }
    }
    exhausted { done }
}
```

The pieces, in the grammar's own words:

* `ask <code> <addressee> "<id>" "<prompt>"` — one question. The **code** is the
  kind of answer: `text`, `verdict` (approve, or object with a reason), `flag`
  (yes or no), `ack` (an act was done). The **addressee** is `model`, `tool` or
  `person`, with an identifier; `draw n` asks for the *n*-th sample.
* `@model "name"` before an `ask` requests a model for that question.
* `panel [ ask …, ask … ]` — several verdicts at once, combined as a monoid: one
  objection is an objection.
* `revising x upto n check (p) {…} with (p, why) {…} accepted (p) {…} exhausted {…}`
  — a bounded revision loop. `upto n` is a numeral, and it is what keeps every
  program in this language finite.
* `case x { yes -> {…} no -> {…} }` — branching on a `flag`; every arm must be
  written out.
* `act <addressee> "<id>" "<prompt>"` — an `ask` of code `ack`: a request that
  something be *done*.
* `{name}` in a prompt splices a `define` or a bound variable.
* `done` ends a block.

Every program the checker accepts is a closed plan at or below the *branch*
rung (`Dsl.parseAndCheck_level_le`), which is exactly the condition under which
a cost tree exists — so every accepted program can be priced before it is run.

## The four tools

| tool | what it does |
| --- | --- |
| `workflow_check` | `{source}` → does it type-check, at what rung, and what will it cost: `minBill`, `maxBill`, `paths`, and the question `shapes` where the program does not branch. |
| `workflow_start` | `{source}` → a `runId`, and either the first `question` or, for a program with no questions, the `report`. |
| `workflow_answer` | `{runId, answer}` → the next `question`, or the `report`. |
| `workflow_transcript` | `{runId}` → the source, the quoted cost, everything heard so far, the bill so far, and the pending question or the report. |

Only `ok` is required in every output schema, so a failure conforms to the same
schema as a success: `ok: false` with `error.kind` one of `check-error`,
`no-such-run`, `undecodable-answer`, `run-finished`, `run-failed`. Every result
carries `structuredContent` and the same lines as text, for a reader.

## How an agent uses them

1. **Check**, if the program came from a person just now: `workflow_check`
   reports the fault with a line, a column and an excerpt, and quotes the price
   before anything is spent.
2. **Start**, then loop: `workflow_start`, and `workflow_answer` once per
   question until `status` is `done`. There is no other loop; the run holds its
   own continuation, so nothing is replayed and no question is asked twice —
   `bill.memo` equal to `bill.fresh` is that fact, checked.
3. **Answer in the words the question asks for.** Each question carries
   `answerSpec`, verbatim from the interpreter's own trusted base, and
   `answerSchema` beside it. An answer the base cannot read is refused with
   `undecodable-answer` and `retriesLeft`, and **nothing is recorded**: the run
   is still asking the same question at the same `seq`. Spend the budget and the
   run fails rather than guessing.
4. **A question marked `relay: true` is addressed to a person.** Put it to the
   human in the session, in the words of `rendered`, and return the reply
   verbatim. An agent that answers it is an agent that consents on that person's
   behalf. Where the client supports elicitation the server never asks: it opens
   the dialog itself, and a declined dialog is not a `no` — the question comes
   back to be relayed, unanswered and unrecorded.
5. **Recover with `workflow_transcript`.** A run is addressed by its identifier
   and outlives any one tool call, so a lost result is re-read rather than
   re-run.

## What the report says, and what the certificate means

The report is computed from the log by the plan's own meaning, not remembered:
`transcript` is what the server heard, `replay` is what the plan says that log
denotes, and `heardMatchesReplay` compares them. The `bill` is a fold of the
replay — `fresh` is consultations, `memo` is distinct questions — and it lands
inside the `[minBill, maxBill]` the program was quoted before it ran.

`certificate` has three fields and they say different things:

* **`covered`** is the one with content: every event of the replayed transcript
  is in the log with the answer the replay reads. Under it,
  `Plan.certify_sound_of_covered` says the certificate cannot be a lie — the
  claim strengthens from *some world agrees with this run* to *every world
  agreeing with this log agrees*.
* **`certified`** is `certify p t ()`, and on a closed workflow — which is all
  this language builds — it is true for every table, the empty one included.
* **`vacuous`** says so, in the report, rather than letting `certified: true`
  read as more than it is.

`caveats` is never omitted, because empty is a claim too. Two can appear: that a
person's question was answered through the calling agent (relay cannot prove a
human was asked), and that the run put an act (what it asked for is in the
transcript; what was actually done happened in the client's process, and no
theorem here covers the difference).

## Testing it

```
lake exe mcp_smoke          # the dispatcher, over a scripted stream
lake exe mcp_client_smoke   # the built binary, over a real pipe, five modes
```

`test/mcp_client.py` is the second of these: a minimal MCP client that starts
the server, runs the flagship workflow with canned answers, and asserts what a
finished run must satisfy — the bill is a leaf of the cost tree, the guide is
consulted exactly once, consent implies an act and refusal implies none, the
certificate holds. It can be run directly:

```
python3 test/mcp_client.py --mode consent --verbose
```
