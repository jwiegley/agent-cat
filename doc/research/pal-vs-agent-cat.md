# PAL MCP versus agent-cat: what would be lost, and what would not

*2026-08-19. Written against PAL MCP 1.4.0 as installed and live on this
machine (three providers configured — Gemini, OpenAI, Anthropic — 127 models;
verified by `version` and `listmodels` on the day of writing), and against
agent-cat at `0687922`. The owner's question: can agent-cat completely avoid
all use of PAL MCP, or does PAL offer anything workflows cannot also express?*

## The verdict

**The assumption is correct at the level of meaning and one engine feature
short at the level of execution.** Everything PAL offers is expressible as an
agent-cat workflow plus engine configuration, and almost all of it comes out
strictly stronger — priced before a token moves, traced after, held to a
verified semantics. The one thing PAL can *do* that agent-cat's runner cannot
yet do is reach two different model backends inside a single run. That is not
a language gap — the Plan already distinguishes parties, and the trace already
records who answered — it is a routing table the engines don't have yet. Filed
as `acat-engine-party-routing-hcx`; once landed, PAL is fully subsumed.

## What PAL is, read from its own tool surface

PAL MCP is fourteen tools in four families:

1. **Model access** — `chat` (one question to one named model, with files,
   images, temperature, and a thinking-effort knob) and `listmodels`/`version`
   (introspection over the configured API keys).
2. **Multi-model debate** — `consensus`: the caller consults a roster of
   models one at a time, each optionally assigned a stance (for / against /
   neutral) and a stance prompt, then synthesizes.
3. **Guided investigations** — `thinkdeep`, `debug`, `codereview`, `analyze`,
   `planner`, `precommit`, `refactor`: step-numbered forms the *calling agent*
   fills in as it investigates with its own tools, ending in one validation
   call to an "expert" model. The structure lives in parameter names —
   `step_number`, `findings`, `confidence`, `next_step_required` — and is
   enforced by nothing but the caller's honesty.
4. **Conveniences** — `clink` (forward a prompt to a claude/codex/gemini CLI
   with a role preset), `apilookup` (web search for current API docs),
   `challenge` (a wrapper prompt that says *critically evaluate rather than
   agree*), and a `continuation_id` thread that carries context between calls.

## The correspondence, feature by feature

**`chat` → an ask.** One question to one model is the atom of agent-cat. What
PAL adds is *which* model, per call, with temperature and effort knobs. In
agent-cat, model identity is engine configuration — the codex adapter runs
whatever model the CLI session is configured for; a deck pane is whatever it
is — and the program text names *parties*, not SKUs. That separation is
deliberate: the program's cost is counted in questions, and the same program
prices identically whoever answers. The knobs PAL exposes per call live one
level down, in adapter and session configuration, where they belong.

**`consensus` → a panel, structurally stronger.** Stances are prompts;
a roster is a list of parties; the synthesis step is a fold. agent-cat's
panels do all of this with a verdict monoid instead of caller bookkeeping,
`panelText` for document-shaped folds, `servedBy` alternates for fail-over
PAL entirely lacks, and — the real difference — a price *before* the run and
a trace and bill *after* it. What `consensus` has today that the runner does
not: its roster spans providers in one call. That is the routing gap, and it
is the whole of it.

**`continuation_id` → session policy.** The ACP engine runs one session for
the whole run or a fresh session per question (`acpFreshPerQuestion`); a deck
pane is durable across runs. Multi-turn context with the same model is an
engine setting, not a server-side thread — and unlike PAL's thread, what was
said is in the trace.

**The seven guided investigations → workflows, which is the point.** PAL's
`debug`/`codereview`/`planner` family is prompt-template scaffolding: the
caller self-reports `findings` and `confidence` into typed slots, and one
expert call reviews the result. agent-cat expresses the same shapes as
programs — a `revisingOn` loop whose settle/amend/abandon comes from a
verdict, deciders that read a gate for zero questions, receipts the world
authors by actually running the build — and the workflows/ rebuild now in
flight is producing exactly these from the owner's own command corpus. The
structural difference is trust: PAL's step discipline is an honor system over
parameter names; a workflow's discipline is the term itself, and the fess
lesson of this repository is precisely not to grade one's own homework.

**`clink` → the engine layer.** Forwarding a prompt to a claude or codex CLI
with a role preset is what `--engine acp --adapter claude|codex` *is*, minus
types, pricing, and traces. Role presets are parties with rubric prompts.
The gemini CLI is absent on this machine (so `clink gemini` fails here too);
a gemini adapter or pane covers it the day it exists.

**`apilookup` → an ask to a web-capable party.** Doc lookup is not a language
concern; a claude adapter session can search the web, and the question is an
ordinary ask. Local searxng covers the same need outside any workflow.

**`challenge` → one rubric define.** A `[wf|…|]` constant of a dozen words.
The transplant is so small it is barely a line item.

**`listmodels`/`version` → nothing to replace.** They introspect API keys.
agent-cat's equivalent facts live in engine configuration and the run header,
which prints who is answering and under what policy.

## What does not carry over, honestly

Three residuals, in descending order of substance:

1. **Cross-backend fan-out in one run** — the routing gap above. Real,
   actionable, filed. Until it lands, a two-provider panel is two runs or a
   PAL `consensus` call.
2. **Inline images.** PAL's `chat` takes screenshots as base64; asks are
   text. The working answer is that adapter sessions have a working
   directory and read image files from it (the claude CLI reads images
   natively), so "look at ./screenshot.png" expresses it — but it is a
   convention, not a surface feature.
3. **Auto model selection.** PAL ships a scored catalog and picks a model
   per task. agent-cat pins parties on purpose — a program that does not
   know who answers cannot honestly price or attribute — so this is a
   feature declined rather than a feature missing. The fail-over ladder
   (`servedBy` alternates) is the principled fragment of it.

Per-call temperature and thinking-effort knobs are configuration, not
capability, and are reachable through adapter arguments today.

## What replacing PAL buys

The direction of the trade is not symmetric. PAL calls are unpriced (the
first sight of cost is after spending it), untraced (the transcript lives in
a server-side thread, not an artifact), unreceipted (nothing verifies a
claimed build or test actually ran), and unverified (the step discipline is
self-reported). Every workflow that replaces a PAL habit gains `plan`/`cost`
as a pre-spend contract, a trace as evidence, world-authored receipts at the
gates, and a semantics held to the Lean kernel by the frozen corpus. The
`wiggum` and `heavy` skills' "confer via PAL for real decisions" clause
should, after the workflows/ rebuild, read "run the confer workflow" — same
models, plus a bill and a record.

## Disposition

- `acat-slj` (PAL keys broken) — **closed**: both providers verified live.
- `acat-engine-party-routing-hcx` — **opened**: party→backend routing;
  the one item between "expressible" and "executable".
- The workflows/ rebuild (design of record in progress at
  `doc/research/ai-config-workflows.md`) should include a **confer**
  workflow — roster-of-parties, stance rubrics, verdict fold — as the
  designated PAL-consensus replacement, single-backend until routing lands.
- One caution for future sessions: PAL's `version` tool reports its
  *client's* working directory as its installation path and suggests
  `git pull` there — on this machine that pointed at agent-cat itself. Do
  not follow that suggestion.
