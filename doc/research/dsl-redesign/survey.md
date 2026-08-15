# The ten-family survey and the comparison judge (round 7.5)

=== graph-orchestrators
The dominant representation shape in this family is a directed graph of named steps, but it splits into two camps that each buy one of our guarantees at the cost of the other. Data-as-program systems (Amazon States Language, Conductor, Google Cloud Workflows) keep the workflow as an inspectable document, so structure is extractable, diagrams are derivable, and AWS can ship a genuine pre-run validator — but their data movement is stringly-typed paths over an implicit global document (`$$.Task.Token`, `${workflow.input.status}`, a six-stage InputPath/ResultPath pipeline) with no real binding. Code-as-program systems (LangGraph, Azure Durable Functions, Temporal) get perfect binding and argument passing but lose the artifact entirely: their shape survives only as a runtime determinism contract enforced by replay, to the point where Microsoft's docs must argue in prose that their own sample is legal, and LangGraph recovers its edge set from a hand-maintained `Command[Literal[...]]` annotation. Nobody in the family has both, which is the diagonal agent-cat's elaboration occupies. The single most transferable lesson is about cost: Step Functions bills per state transition and Google Cloud Workflows bills per step executed with a compositional rule ("calling a subworkflow generates costs equal to the cost of all of the subworkflow's steps plus the cost of the step that calls the subworkflow"), and Temporal caps executions at 51,200 history events — so the industry has already agreed our cost unit is the right one, and every one of them measures it only after the fact, blocked by the same four constructs: data-dependent branch, unbounded back-edge, data-width fan-out, and an arbitrary-code escape hatch. Excluding exactly those four is what buys the static tree, and the family's own escape hatches (`graaljs` in Conductor's switch and loop conditions, LangGraph's routing functions) show how a single interpreter hole collapses the analysis. Two concrete constructs are worth stealing outright: Conductor's `HUMAN` task, whose addressee, deadline, and versioned answer-form are structured fields with only the display name as free text — the closest thing in the wild to question-shape-as-data; and Google Cloud Workflows' `shared: [total]` clause, which declares at the fan-out site exactly which binding parallel branches may contribute to, where LangGraph hides the same monoid in a distant `Annotated[list[str], operator.add]`. Google Cloud Workflows is also the readability benchmark: a non-expert reads its twenty-line parallel-fold example correctly on the first pass, because every step is named, nesting draws the structure, and `result: numComments` says where the answer lands.

=== agent-frameworks
The dominant representation shape in this family is a code-embedded graph builder over a host language (Python or TypeScript) that produces an inspectable node-and-edge data structure at build time: Google ADK 2.0's `Workflow(edges=[...])` tuple/dict literals, Microsoft Agent Framework's `WorkflowBuilder`, Mastra's `.then()/.parallel()/.branch()/.foreach()` chain, pydantic-graph's edges inferred from `run` return-type unions, and AutoGen's `DiGraphBuilder`. The two ends of the spectrum are CrewAI, which pushes agent and task descriptions out into declarative JSONC/YAML that a domain expert can edit, and smolagents, where no workflow exists until the model writes Python at runtime. Every framework that began emergent has since grown a declared-graph feature, and the stated motive is always the same — predictability of speed, cost and behaviour — so agent-cat is at the far end of a direction this whole family is already travelling. The single most transferable lesson is Microsoft Agent Framework's build-time validation contract: type compatibility across every edge, reachability of every node from the start, binding of every referenced executor, and no duplicate edges, all checked and named at `build()`. That is the most any of these systems can promise before a run, and it is worth stealing not for its power (agent-cat gets most of it by construction) but for the discipline of naming it as a contract with one diagnostic per clause — reachability of case arms is the one check agent-cat may genuinely be missing. Two further findings are decisive for agent-cat's differentiators. First, no system in the family has any static cost analysis whatsoever: every bound is a runtime abort thrown from inside a closure (`max_turns`, `max_steps`, `UsageLimits(request_limit=...)`, and Mastra's documented `if (iterationCount >= 10) throw`), and CrewAI's careful post-hoc `flow.usage_metrics` rollup — with its warning that the obvious number, `kickoff().token_usage`, silently omits earlier crews and bare LLM calls — shows that even measuring cost after the fact is hard enough to need a page of caveats. Second, implicit context broadcast has been reversed under load everywhere it shipped: OpenAI needed `input_filter` because a handed-off agent "gets to see the entire previous conversation history", AutoGen needed a whole second message graph on top of its execution graph, and Microsoft rebuilt the framework around routed typed messages instead — which is exactly agent-cat's scoping-by-binding, arrived at the hard way.

=== llm-call-dsls
The dominant representation shape in this family is a code-embedded Python eDSL that mutates one implicitly accumulating prompt — LMQL's top-level strings, Guidance's `lm +=`, SGLang's `s +=`, and PDL's background context all do this — with only BAML standing apart as a genuinely separate typed language compiled to clients. Every system spells the SHAPE of an answer well (DSPy's arrow signatures, BAML's `-> OrderInfo`, Outlines' `model(prompt, output_type)`, PDL's `spec:`) and the FLOW between steps badly, because flow is delegated to the host language's control flow or to that invisible accumulator. Not one of the six named systems ships a static cost analysis: DSPy measures usage post-hoc via `track_usage`, BAML gets a trivially exact cost model only by refusing to express orchestration at all, and Guidance's genuinely offline `grammar.match(...)`/`Mock` analysis covers the shape of an answer rather than the shape of a workflow. The single most transferable lesson comes from SGLang's tracer: it runs the program with dummy arguments to build a static graph, and it succeeds exactly when the program's shape does not depend on generated text — `tip_suggestion` with its literal `fork(2)` traces, while `tool_use` branching on `s["tool"]` makes the tracer catch `TypeError` and give up. That is our five-formers distinction, discovered empirically by an inference team and then buried as an optimizer heuristic with two silent execution modes instead of being raised into the type system. Two smaller findings corroborate specific choices: DSPy had to invent a `rollout_id` threaded into its LM cache key "so the model resamples instead of replaying a cached response," which is what a cache-based sharing story costs you when a resample-draw belongs in the question shape; and PDL's `read:` block is the family's only in-language human gate, meaning the consent-gate design space is essentially unoccupied. The clearest warning is PDL's own documentation admitting that a function call "implicitly passes the current background context," with `pdl_context: []` as the opt-out — four of six systems chose that default and every one of them later bolted on a correction rather than removing it.

=== pipeline-orchestrators
The dominant representation in this family is code-embedded: a workflow is a Python program whose *execution* (Airflow, Flyte at registration) or whose *trace* (Prefect) produces the graph, with Dagster a partial exception because definitions are loaded rather than run. Only Nextflow and Snakemake are real textual DSLs, and only Nextflow has its own grammar — which it is now actively shrinking, via a strict parser, a language specification, a language server and `nextflow lint`, in order to become analyzable. Every system has a static *structure* level and a dynamic *count* level, and none of them gets counts: Nextflow renders a process DAG with `-preview -with-dag` but never a task count, Airflow's `.expand()` exists precisely so the author need not 'know in advance how many tasks would be needed', and Flyte compiles a fully type-checked DAG yet still cannot price a `conditional`. The one exception is Snakemake's dry-run `Job stats:` table, which reports actual job counts before anything runs — and it can do so only because its fan-out former `expand(...)` ranges over a parse-time list rather than runtime data, which is exactly agent-cat's bet stated as an empirical result. The systems that earn pre-run guarantees all bought them the same way, by *removing* expressive power: Flyte forbids iterating a promise ('`Promise` object is not iterable' 'due to the inability to decide upon a static DAG'), Nextflow forbids reading a channel's contents, Snakemake makes filename patterns the only dependency mechanism; the systems that kept full host-language power have no pre-run analysis at all. Memoization is a cache everywhere and semantics nowhere — Prefect keys on inputs+code+flow-run-id but only when result persistence is enabled, Nextflow hashes about a dozen things including 'global variables referenced in the task script' and ships a troubleshooting page for when that is wrong, Dagster's staleness is explicitly 'not transitive' and defaults to a per-run code version — so each has a documented mode in which the same program means two different things, which sharing-by-binding simply does not have. The single most transferable lesson is Flyte's and Snakemake's shared architecture for dynamism: the escape hatch gets its own keyword (`@dynamic`, `checkpoint`), the static language genuinely cannot express it, the analysis is exact everywhere except downstream of it, and even the hatch is bounded ('Flyte imposes limitations on the depth of recursion'). That is agent-cat's fifth former, independently arrived at twice, and it means the right thing to invest in is not making the dynamic node more capable but making the boundary around it more visible and more clearly priced.

=== formal-workflow-calculi
The dominant representation shape in this family is a graph over a marking — BPMN and YAWL are both nets whose state is a multiset of tokens on edges (Corradini et al. make it explicit: "a state σ : E → N is a function mapping edges to numbers of tokens"), and both are authored visually with XML as machine exhaust rather than as a language. The minority shape, and the interesting one, is the small textual combinator basis: Orc's four combinators (|, >x>, <x<, ;) plus sites, Scribble's message/choice-at/rec/par/do, and λ_A's eleven formers of which five are primitive. Every one of these bases proved sufficient for its target domain — the COORDINATION 2006 slides conclude flatly that "Orc can implement all the workflow patterns," all twenty of van der Aalst's, using definitions rather than encodings. But sufficiency is not the property agent-cat needs, and the survey's sharpest finding is that only ONE system in the family obtains a quantitative pre-run bound: λ_A, whose loop former carries its bound as a syntactic index (fix_n) and whose branch former ranges over a finite label set with a typed identity exit, yielding cost(T) ≤ n × max_i c_i and pre-deployment dollar estimation. Everything else trades the count away — BPMN and YAWL because counting over a marking is reachability rather than syntax (hence YAWL's OR-join must "calculate all possible futures from the current state," and must syntactically exclude nested OR-joins just to have a fixpoint), Orc because >x> spawns one continuation per publication and publication counts are dynamic, Scribble because rec X is unbounded, and Formal-LLM because the plan shape is chosen at run time by the model walking the automaton, with termination bolted on as an external one-use-per-tool cap the paper admits "is not something the grammar states." The second lesson is that analysability and readability are independent axes: Formal-LLM is perfectly analysable and unreadable (single-letter nonterminals, Polish prefix), while Scribble's "Meta from F[1] to M;" and "choice at W[1]" are readable without a glossary precisely because the deciding party and the data movement are lexically present — the cheapest transferable idea here. The single most transferable lesson overall is that a static cost tree is bought by exactly two refusals, and agent-cat should name them as such: the loop bound must live in the term rather than in config or a counter, and no former may have non-local enablement. λ_A also supplies the empirical case for agent-cat's most distinctive choice — that the surface cannot express the dynamic node — by measuring what happens when that door is left open: 46% of 835 real production configs split semantics across YAML and Python, collapsing static lint precision from 96–100% to 54%.

=== typed-effects-build-systems
The dominant representation shape in this family is not a workflow file at all: it is a HOST-LANGUAGE TERM POLYMORPHIC IN ITS INTERPRETATION, whose type carries the analysis rung. Build Systems à la Carte states it most explicitly with `newtype Task c k v = Task { run :: forall f. c f => (k -> f v) -> f v }`, where the constraint `c` — Functor, Applicative, Selective, Monad — names exactly how much you can know before running, and the same program text is priced by folding with `Const [k]` and executed by folding with a real effect. Selective functors are the rung agent-cat proves, and the literature's lesson about surfacing it is dual approximation: run the program in `Over` to get everything that may happen, in `Under` to get everything that must happen, and show both — the ceiling provisions resources up front while the floor is the set that can be dispatched in parallel immediately. The family is also unusually honest about its cliff: the selective paper concedes that any effect whose CONTENT is computed from an earlier answer can only be encoded by enumerating the index type, which reports 'reads of all memory cells' and destroys the analysis — which is precisely the gap agent-cat's computed-words/static-shape question fills, and Dune independently reached the same fixed point with 'in Dune, targets must always be known statically' while still allowing `%{...}` expansion into an action's arguments. The algebraic-effect systems occupy a different axis: Unison abilities give a superb SCOPE and permission discipline (`I ->{A} O`, `handle e with h`, requirements propagate by union) but no cost bound at all, since a handler 'is free to invoke k zero, one, or many times'; Koka goes further than anyone by making `total` a machine-checked termination claim via an inductive-descent analysis, and by spelling the resumption discipline as a declaration keyword (`effect fun` = exactly once, `effect ctl` = general). The single most transferable lesson, though, is a syntactic one confirmed by both a positive and a negative case: PUT THE RUNG IN THE BINDER. OCaml's `let+ ... and+` (applicative, independent, fannable) versus `let*` (monadic, dependent, sequential) makes the static/dynamic boundary visible at the point of use with no glossary, and Dune's build engine uses it in earnest; GHC's ApplicativeDo took the opposite route of recovering the rung by heuristic, and its own manual admits it 'might miss an opportunity', that the optimal algorithm is O(n^3), and that a strict pattern match silently blocks the transformation — which means a Haxl program's round count is not readable from its text. For a surface whose central promise is that every program can be priced by reading it, that is the one thing not to build.

=== human-in-the-loop
The dominant representation in this family is code-embedded: a gate is a function call, a decorator, or a blocked predicate inside an ordinary host language running under a durable/replay runtime (LangGraph, Temporal, Durable Functions, OpenAI Agents SDK). The two systems that are not programs at all — MCP elicitation and AG-UI — are the ones with the cleanest models, precisely because they had to write down the question and the answer as data rather than as control flow. Not one system in the family can statically bound how many times a human will be asked; GitHub Actions comes closest, and only because its YAML has no loop construct, so the job DAG is finite and drawable, and because every gate carries a hard 30-day expiry. Everywhere the pending state converges on the same triple — a stable identifier, human-readable prompt words, and a schema or enum for the legal answers — which is agent-cat's question shape under six different names. Re-entry splits into two camps: mutate-and-continue (patch durable state, resume execution) versus replay-with-an-answer-sheet, and the protocol designers who had to survive stateless load balancing all landed in the second camp. The single most transferable lesson is MCP's Multi Round-Trip Requests, a 2026 breaking change that abolished server-initiated requests in favour of 'answer the original call with an input-required result carrying a name-keyed map of questions, then let the caller retry the same call with a name-keyed map of answers' — which is agent-cat's total-answer-sheet semantics rediscovered as a wire protocol, complete with the insistence on named rather than positional binding that LangGraph's index-based resume matching shows the cost of getting wrong. Full notes: /private/tmp/claude-501/-Users-johnw-src-agent-cat/b2c08087-6acb-43d8-8ba4-e7c90b1ca4b5/scratchpad/wg-dslsurvey/human-in-the-loop/notes.md

=== cost-and-budgets
The dominant representation in this family is not a workflow language at all — it is a *scalar attached to something else*. FrugalGPT's program is a learned pair (ordered API list, threshold vector); RouteLLM's is a float smuggled inside a model-name string; LiteLLM's is a YAML `max_budget` on a key that has no idea what workflow it serves; LangGraph's and the OpenAI Agents SDK's are a step or turn counter on an otherwise arbitrary Python graph; only the token-budgets Rust crate makes the budget a first-class term, and even there the dollar cap is runtime arithmetic while the type system contributes bookkeeping integrity alone. To the survey's central question — does any production system offer a pre-run bill enumeration? — the answer from primary sources is no, and the negative is well documented rather than merely unfound: the token-budgets catalog collects 63 confirmed overrun incidents across 21 frameworks and reports LangGraph, CrewAI, AutoGen, AgentGuard-style callbacks and LiteLLM proxy budgets overshooting 30/30 in a discriminating-cap head-to-head. Everything shipped is one of four weaker things — a per-request input-token count (Anthropic `count_tokens`, exact but for one call), a scalar reservation debited pre-flight (LiteLLM, token-budgets, at 4–6× over-reservation), a structural cap on steps or turns that does not translate to a bound on model calls, or a distributional expected-cost constraint learned offline (FrugalGPT's E[cost] ≤ b, RouteLLM's calibrated strong-model percentage). The single cause is uniform: in every one of these the workflow's shape is decided at run time by a judge score, a router, a Python `if`, or a `Send` fan-out, so there is nothing finite to enumerate. The most transferable lesson is therefore a warning about denomination rather than a technique: the only system in the family that reaches a real cost bound pays for it with 4–6× conservatism and five named assumptions (estimator soundness, output-cap honoring, charge-truthfulness, rate stability), which is exactly what we would inherit the moment we multiply our question counts by a price table. Keep the bill denominated in questions — where the count is exact and assumption-free — and expose tokens and dollars only as a separately-labelled overlay carrying its assumptions with it. Then borrow the one piece of interface the industry already understands: BigQuery's free, explicitly-upper-bound `--dry_run`, which Google ships for bytes and pointedly declines to extend to `AI.GENERATE` tokens, gating those with submission-time quotas instead.

=== config-workflow-specs
The dominant representation shape in this family is a flat, named node set plus a separate edge/dependency set, serialized as YAML or JSON, with data movement expressed as string interpolation over a producer's namespace (`${{ steps.x.outputs.y }}`, `{{steps.x.outputs.parameters.y}}`, `{{#node_id.var#}}`, `$('Node Name').item.json.x`). The consequence is uniform across the family: the reference language is untyped and unchecked, so every system that interpolates has grown an external checker to retrofit what it declined to specify — actionlint for GitHub Actions, which recovers the type of `needs` merely 'by looking at each job's outputs: section and needs: section', and difyctl for Dify, built to catch 'broken variable references that silently kill runtime flows'. The information was always present; the language simply exported its own type checker. The systems that escape are exactly the ones that stopped interpolating: Haystack connects declared typed sockets (`sender: converter.documents` / `receiver: cleaner.documents`) validated at connect time, LlamaIndex Workflows carries data in typed events so the entire possible-path graph is recoverable statically from the same annotations the runtime validates against, and Amazon States Language gives a JSON dialect real lexical scope — inner scopes may read outer ones, shadowing is prohibited, Parallel/Map variables go out of scope at completion, and illegal references are 'caught at creation, update, or validation of the state machine'. Static cost is a separate and mostly unmet goal: only Haystack states a bound in the program text (`max_runs_per_component`), and every system offers a runtime-width fan-out (`fromJSON` matrices, `withParam`, `Map` with `ItemsPath`, Dify `iteration`) sitting confusingly close to a static sibling that would have stayed countable (literal `matrix`, `withItems`, `Parallel.Branches`). The single most transferable lesson is n8n's, because it is the negative result run to completion: n8n replaced binding with runtime provenance resolution, and its own docs enumerate both failure modes — the correspondence thread breaks, or it 'points to more than one item in the previous node' — with the official remedy being to give up and index by position. Interpolation-by-convention is not a lighter alternative to binding; it is binding with the checking deferred to the user, and every system here eventually paid for it in a linter, a redesign, or a documented class of unfixable errors.

=== critique-loops
The dominant representation in this family is a code pattern, not a notation: the canonical evaluator-optimizer is three Python functions around a `while True:` with no round cap at all, and Reflexion/Self-Refine live as paper pseudocode that every framework re-spells with a different parameter name for the same integer (N, max_refinements, max_messages, MAX_ITERATIONS). Where a surface does exist it is one of three shapes — a decorator-declarative registry keyed by agent names (fast-agent/mcp-agent), inert YAML with a closed assertion vocabulary (promptfoo), or a declarative record with string-named combinators (Inspect AI) — and analyzability tracks that shape almost perfectly: promptfoo and Inspect can price a run exactly because nothing a model emits changes the call tree, while LangGraph and AutoGen cannot because the bound is a Python predicate or a grep for "APPROVE". The single most transferable lesson is that a critique loop only becomes analyzable when the VERDICT is a closed, ordinal, typed set and the accept test is a comparison against a named level (mcp-agent's `QualityRating` with `rating >= min_rating`), because that turns the revise decision from a string match into finite case-branching with a known arity, which in turn lets `max_refinements=3` be unrolled into a finite cost tree of 1 + 2n questions rather than executed as a loop. The second lesson, from Inspect and promptfoo, is that the panel combiner should be a NAME in the program (`reducer="mode"`, `assert-set threshold: 0.66`) rather than an agent or a closure — PoLL's evidence that the right combiner depends on the answer type (max voting for binary judgments, averaging for 1-5 scales) argues for a named verdict monoid rather than a fixed one, and the combiner never touches the cost since the panel costs len(judges) either way. Inspect's `Epochs(5, ["at_least_2", "at_least_5"])` shows the payoff of separating the draw count from the reduction: several verdicts over one paid-for draw set, which is exactly our resample-draw-as-term-level-data guarantee already vindicated in a shipping system, as is DSPy's `rollout_id` threaded into the cache key to distinguish deliberate resampling from memoized sharing. Two things must be rejected outright as dynamic shape: a loop bound extracted from the model's own feedback (Self-Refine explicitly offers this as an option) and an accept test that greps prose. Nobody bounds the loop in the type; the best surfaces merely put the integer at the declaration site — which means an unrolled, statically-costed `revise n times` former over a closed verdict set would be genuinely novel in this family rather than a re-spelling of it.


## comparison

COMPARISON — the proposed surface against the strongest surveyed alternatives. Every external quote below was re-verified against a primary source this session.

=== 1. BIND / SEQUENCE ===
Ours: `guide : text <- ask tool "cat" "..."`; statements in a block; `stop` for a path that does nothing.
Rivals: Google Cloud Workflows (`call: ... / result: numComments`), Haystack (`connections: [{sender: converter.documents, receiver: cleaner.documents}]`), Azure Durable Functions (host locals), Airflow TaskFlow, Dagster (parameter name = dependency).

OURS CLEARER:
(a) The kind travels with the name in one column. GCW names the landing site but not the shape — a reader of `result: numComments` cannot tell what came back. Haystack has types, but attached to sockets in a flat edge list, not to the binder. Ours puts name+kind where the reader first meets the name, which is exactly where example/HardenPatch.lean:10,18 puts it (`let guide : String <-`, `let ok : Bool <-`).
(b) An honest discard. `_ : receipt` says in one shape both that something was done and that nothing came back. Nobody else has this. GHA instead produces a value nothing consumes and a missing property "will evaluate to an empty string" (https://docs.github.com/en/actions/reference/workflows-and-actions/contexts). Argo redesigned specifically to make absent "not the same as an empty string" (https://argo-workflows.readthedocs.io/en/latest/variables/).
(c) One time level. Airflow is the counter-case: `order_data = extract()` looks like a call and is a graph-building placeholder; `order_summary["total_order_value"]` builds an XComArg projection, not a lookup (https://airflow.apache.org/docs/apache-airflow/stable/tutorial/taskflow.html).

THEIRS CLEARER:
(a) Declared ports on BOTH sides — Haystack validates connection type compatibility at connect time; Nextflow `take:`/`emit:` and Argo `inputs.parameters` give a named block a signature. Ours is consumer-side only. Not a defect today (no reusable sub-program former exists) but it is the shape to use if one is added; `review -> verdict` and `amend (why : verdict) -> patch` already are that pattern at the one place clause boundaries exist.
(b) An ordering-only edge. Dagster spells `deps=[daily_sales]` (order, no value) differently from `def combined_data(people, birds)` (value). We cannot say "must happen first, answer never read" except as `_ : receipt` — arguably better (a real question with a real cost node) but a genuinely different distinction.

=== 2. PROMPT DATAFLOW ===
Ours: `{x}` in a prompt; `{x.reasons}` for verdicts; `define` for literals; `plainstring` (no holes) for addressee/model names; exactly two consumption sites and no third (rule 3).
Rivals: BAML (`prompt #"...{{ email.subject }}..."#` with `-> OrderInfo` three lines away), LMQL (`{value}` in vs `[HOLE]` out), Pydantic AI AgentSpec ("template variable names are validated at construction time"), PDL (`${ N }`), n8n (the anti-case).

OURS CLEARER, DECISIVELY:
(a) The exhaustive consumption rule. No expression language at all. BAML has Jinja `{% if %}`/`{% for %}` inside the prompt — untyped computation inside a typed language. Four of six llm-call DSLs grow one invisible accumulating prompt, and PDL's own docs concede "when we call a function, we implicitly pass the current background context" (https://ibm.github.io/prompt-declaration-language/tutorial/). Ours has no accumulator: a question sees exactly the words written.
(b) `{x.reasons}` writes the renderer where it is used. Nobody else does this; everyone else stringifies silently (`${some_ref.output.field}`, `${{ steps.x.outputs.y }}`) or has no structured verdict.
(c) Rendering a receipt is REFUSED (El .ack = Unit). Argo's post-hoc redesign, obtained by construction.
(d) The rung is decided in the prompt: all-defines => Plan.askC (batch); any binder => Plan.ask (pipeline). No surveyed system has any rung distinction in prompt text.

THEIRS CLEARER — THE ONE REAL DEFECT FOUND:
LMQL's two bracket kinds make direction legible "at a glance, inside the prompt text itself" (https://lmql.ai/docs/language/overview.html). In our proposal, `"{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}"` gives a reader THREE HOLES OF TWO DIFFERENT KINDS WITH ONE SPELLING, and the difference decides the elaboration target and the rung. Rule 5 offers "decidable by eye" — but the eye must travel to the define list at the top of the file and check each name. That is a glossary lookup, which house rule 8 forbids, and it is the only place in the language where a token's meaning depends on a declaration elsewhere in the file. The project's own review recorded exactly this (design-digest.md §3: "{name} MEANS TWO THINGS ... Which one it is DECIDES THE RUNG ... Reviewers demand: visibly distinct syntax for macro vs answer"). Corroborating negative witness: GHC ApplicativeDo, where the rung is recovered by inference and the manual concedes it "usually finds the best solution, but in rare complex cases it might miss an opportunity", that `-foptimal-applicative-do` "is expensive: O(n^3)", and that "a strict pattern match in a bind statement prevents ApplicativeDo from transforming that statement" (https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/applicative_do.html). Our recovery is exact, not heuristic — but it is still recovery. Amendment 1 fixes it.

=== 3. BRANCHING ===
Ours: `branch on x { yes {...} no {...} }` / `{ approved {...} objected {...} no answer {...} }`. Total, ordered, no default, one brace pair, scrutinee at the head, arm bindings die with the arm, following statements rejoin through every arm (rule 9).
Rivals: AWS Step Functions `Choice`; Flyte `conditional`; Google ADK 2.0 route tables; pydantic-graph return-type unions; Argo `when:` (anti-case).

OURS CLEARER:
(a) The scrutinee is a BOUND NAME, not a predicate. ASL's condition is a JSONata expression; Flyte's a restricted binary operator over primitives; ADK's router arbitrary Python returning a string. Ours is `branch on ok` where `ok : flag`. There is no predicate at all, so the arm set is DERIVED FROM THE KIND rather than written and checked — strictly stronger than Flyte's totality check, because the arms cannot be miswritten in the first place.
(b) The tags are the kind's inhabitants, in English. No label vocabulary to learn; ASL/ADK/Conductor all need author-invented case labels.
(c) Rejoin after a branch. ASL forbids it outright — "states in a branch's 'States' field can transition only to each other" (https://states-language.net/spec.html). Ours pushes following statements structurally through every arm (graft, Plan.lean:425-426) with no rung change: more expressive at the same level, and it is what lets the flagship read as one column.

THEIRS CLEARER:
(a) Per-arm bindings that escape. ASL allows each Choice rule its own `Assign`. Ours cannot — arm bindings die with the arm. A real expressiveness gap, and the right one: a value exported from an arm would have a sum type and Ctx holds Codes, so there is no code for it. Same reason `never settled` cannot hide the `none`. State it as a principled refusal rather than glossing it.
(b) NO-SHADOWING is stated in ASL and is NOT stated here. Verified verbatim: "To help avoid common errors, a variable assigned in an inner scope cannot have the same name as one assigned in an outer scope. For example, if the top-level scope assigns a value to a variable called `myVariable`, then no other scope (inside a `Map`, `Parallel`) can assign to `myVariable` as well" (https://docs.aws.amazon.com/step-functions/latest/dg/workflow-variables.html). We have the containment half, not the shadowing half. Amendment 2.

=== 4. BOUNDED REVISION ===
Ours: `revising draft as patch, at most 2 revisions { review -> verdict {...} amend (why : verdict) -> patch {...} } giving { settled (patch : text) {...} never settled {...} }`
Rivals: lambda_A `fix_n` (arXiv:2604.11767); fast-agent/mcp-agent `evaluator_optimizer`; DSPy `Refine(N=3, threshold=1.0)`; Durable Functions `for (int retryCount = 0; retryCount <= 3; retryCount++)`; the Anthropic cookbook's `while True:`.

OURS CLEARER — the design's strongest single position:
(a) The exit is a MANDATORY TWO-ARM CASE, not a best-so-far. Verified in mcp-agent's source: `best_rating` starts at QualityRating.POOR, `if evaluation_result.rating.value > best_rating.value: best_rating = ...; best_response = response`, and the method returns `best_response` rather than the last generated one — so the caller cannot tell whether the loop settled (https://github.com/lastmile-ai/mcp-agent/blob/main/src/mcp_agent/workflows/evaluator_optimizer/evaluator_optimizer.py). DSPy returns argmax. Ours: Plan.revising answers `Option (El c)`, so `giving { settled ... never settled ... }` is unwritable to omit. Nobody in the survey makes "it never came to rest" a program path.
(b) The back-edge is WRITTEN. `amend (why : verdict) -> patch` — the arrow points at the name it rebinds. lambda_A's `fix_n e` passes `lambda x. fix_{n-1} e x` in the operational semantics; mcp-agent's next candidate is a Python local. Ours is the only surface in the survey where the loop's assignment is on the page.
(c) The bound is the depth of the elaboration. lambda_A is the only rival with a proved pre-run bound, verified: Theorem 5.4 — evaluating `fix_n e v` "terminates in at most n unfoldings, assuming each oracle call (lam and tool) terminates"; Theorem 5.6 bounds cost(T) by n x max_i c_i; the author's gloss is that this "enables pre-deployment cost estimation" and is "not possible in frameworks without formal termination bounds" (https://arxiv.org/html/2604.11767v2). Theirs is a SCALAR; ours is a TREE — four case nodes, nine leaves, eight questions for the flagship. State that precisely: lambda_A gets a number, agent-cat gets a tree at level <= branch.
(d) The base case exists by construction. lambda_A's Observation 1 makes it case-exhaustiveness by typing `terminate` as the identity ("the *only* tool in a ReAct agent that does not change the state, making it the base case of the bounded fixpoint"), and its lint rule for a missing base case is the largest defect class it found in the wild. Ours cannot fail: `review` answers a total three-tag verdict and `approved` is an inhabitant.

THEIRS CLEARER:
(a) VERBOSITY — the honest gap to the owner's bar. The approved Lean is six lines; fast-agent is one decorator; ours is ~20 lines. No cut was found that preserves a guarantee: `review -> verdict` and `amend (...) -> patch` each need a head line naming what they answer, and `giving` needs both arms because the kernel's Option forces both. The header already carries three of the four wires. The cost is real and is the price of the Option.
(b) A threshold. mcp-agent's `min_rating='EXCELLENT'` with `rating.value >= min_rating.value` is legible and flexible. Adding one needs an ordering and a comparison, i.e. an expression language. Refuse — but note mcp-agent's convergence on a CLOSED ORDINAL VERDICT SET (`QualityRating(int, Enum): POOR = 0 ... EXCELLENT = 3`) validates the half we do have.
(c) Per-round binding names (Conductor's `__i` suffix). Ours has one `patch` for all rounds. The unrolling (Nat.rec, Plan.lean:607-608) already makes each round a distinct question, so round 2 is not memoized onto round 1 — but a reader might expect otherwise. One reference sentence; not a grammar change, because `__i` names would destroy "one name, one meaning", the design's answer to the owner.

=== 5. PANEL ===
Ours: `panel, all must approve [ ask ..., ask ..., ask ... ]`.
Rivals: GCW `parallel: { shared: [total], for: ... }`; Inspect AI `multi_scorer(scorers=[...], reducer="mode")`; promptfoo `assert-set` + `threshold: 0.66`; SGLang `fork(2)`; LangGraph `Annotated[list[str], operator.add]` (anti-case).

OURS CLEARER:
(a) The combiner is on the page, in English, AT THE FAN-OUT SITE — GCW's lesson and Inspect's at once. GCW verified: "`shared`: a list of writable variables with parent scope that allow assignments within the parallel step. Variables not listed in `shared` are read-only copies within each branch" (https://docs.cloud.google.com/workflows/docs/reference/syntax/parallel/parallel-steps). Inspect verified: a reducer "determines how a list of scores will be turned into a single score"; `"mode"` "returns the score that appeared most frequently in the answers (i.e. a majority vote)" (https://inspect.aisi.org.uk/multiple-scorers.html). LangGraph puts the identical monoid in a distant state schema. Agentic/Surface.lean:124-129 gives our rule only in a docstring; the surface now puts it on the page.
(b) Static arity by syntax. GCW caps at 10 branches because it must bound concurrency; ours needs no cap because the list IS syntax. Every dynamic-width sibling (Send, withParam, Map/ItemsPath, iteration, `parallel: for`) is unwritable.
(c) Judges cannot read each other — ASL states the equivalent rule normatively; ours gets it because each member is an `ask` with no sibling binder in scope.

THEIRS CLEARER:
(a) A named reducer from a SET of several — Inspect ships mean, median, mode, max, pass_at_k, at_least_k, collect. Ours has one, because the kernel installs exactly one monoid, at .verdict (Plan.lean:562). So `all must approve` is not a selection among alternatives but the statement of the only rule. Keep the comma slot anyway: PoLL's finding that the right combiner depends on answer type ("For QA datasets, we use max voting, as all judgements are binary"; averaging for 1-5 scores — https://arxiv.org/html/2404.18796v2) is strong evidence a second one will be wanted, and reserving the slot costs nothing. Reject promptfoo's bare-float form explicitly — verified "`0.66` means at least 66% (2 of 3)" (https://www.promptfoo.dev/docs/guides/llm-as-a-judge/) — a bare number silently depends on panel size and fails house rule 8.
(b) Preserving individual verdicts. Inspect's `"collect"` "preserves the individual values as a list". Ours ANNIHILATES: a panel with any `declined` member zeroes all objections, so `{why.reasons}` is empty and the reviser is told it failed but not why (design-digest.md §6). This is "absent silently becomes empty string" reappearing at the semantic level. A Verdict monoid question, not a grammar question — but the reference must name it as a hazard.

=== 6. HUMAN GATE ===
Ours: `ok : flag <- ask person "owner" "..."`, then `branch on ok { yes {...} no { stop } }`.
Rivals: Conductor HUMAN task; MCP elicitation; Airflow HITLOperator/HITLBranchOperator; Google ADK RequestInput; GHA `environment: production`; LangGraph `interrupt()` (anti-case).

OURS CLEARER:
(a) The human gate is NOT A SPECIAL FORMER. It is `ask person`, the same three-part shape as `ask model` and `ask tool`. Seven surveyed systems have seven distinct node types (HUMAN, suspend, interrupt, RequestInput, read:, .waitForTaskToken, environment:). Consequence: one cost rule, one branch rule, one memoization rule, and no second arm-list shape in the language.
(b) The addressee is written at every ask. The approved Lean has `ask` and `askHuman` — two words, no tool. Ours: one word, three addressee kinds. Strictly more information, fewer keywords.
(c) Nothing floats between the question and its answer. LangGraph's hazards, all verified from its own docs: "the runtime restarts the entire node from the beginning—it does not resume from the exact line where `interrupt` was called"; "Matching is **strictly index-based**, so the order of interrupt calls within the node is important"; "**Avoid `while True` + `interrupt()` loops inside a single node.** ... The result is exponential re-execution of any code inside the loop body"; "Side effects called before `interrupt` must be idempotent" (https://docs.langchain.com/oss/python/langgraph/interrupts). In ours the gate is a binding, the answer is one entry in a total sheet, and re-running is memoized by binding rather than by discipline.

THEIRS CLEARER:
(a) A structured, VERSIONED answer form. Conductor verified: `assignee: { user: "<ENGINEERS>", userType: "CONDUCTOR_GROUP" }`, `slaMinutes`, `displayName`, `userFormTemplate: { name: "Approval", version: 1 }` (https://orkes.io/content/reference-docs/operators/human). MCP's `requestedSchema` is a deliberately restricted JSON Schema subset so clients can validate without a general engine. Ours puts the answer SHAPE in the binder's kind (`flag` = Bool, which the elaborator turns into the adapter-facing shape) but the WORDS that elicit it in a hand-written `define flagSpec = "Reply with exactly yes or no."`. The split is correct and is exactly the shape-as-data guarantee — but the flagship READS as though the shape were carried by prose, and the two can drift. PDL derives it automatically. No grammar change (prompt fidelity pins it); record as an adapter-layer opportunity and say plainly in the reference that the kind is the shape and the spec define is a courtesy to the addressee.
(b) Deadlines and defaults (Airflow `defaults=`/`response_timeout=`, GHA's 30-day expiry, Durable Functions' timer race). We have neither, deliberately — see refusals.

=== 7. TOOL ACT ===
Ours: `_ : receipt <- ask tool "apply" "..."`.
Rivals: lambda_A `tool[f] : tau1 -> tau2` (a PRIMITIVE former distinct from `lam p theta`, verified); BAML `client "..."`; OpenAI Agents SDK `@tool(needs_approval=True)`; ASL `Resource: arn:...`; Argo `container:`/`script:` templates.

OURS CLEARER:
(a) A tool act IS an ask. lambda_A keeps `tool[f]` as one of its five primitives; ASL/Argo/GHA make it a different node type entirely. Ours makes the addressee a KIND, so the cost rule is uniform (one act = one question in the same tree) and there is one fewer former. The synthesis's own justification is right and belongs in the reference: `act` "invited the belief that a doing differs from an asking — Harden.applyQ is an ordinary .ack question and the owner's own Lean writes it as `ask`."
(b) `receipt` names the Unit answer. lambda_A types every tool Str -> Str and cannot say "nothing came back."
(c) Permission is at the CALL SITE. OpenAI's `@tool(needs_approval=True)` is the anti-case: because the gate is on the tool DEFINITION, reading the workflow tells you nothing about where the human is consulted. Ours puts the gate in the flow.

THEIRS CLEARER: nothing significant. One residual defect of ours: `using model "m"` is accepted on `tool` and `person` addressees, where it is inert (design-digest.md §5). BAML attaches `client` only to model functions; Conductor's HUMAN task has no model field. Amendment 3.

=== GUARANTEE A — PRE-RUN COST TREE ===
Ranked field: (1) lambda_A — the only rival with a proved pre-run bound, and it is a SCALAR (n x max_i c_i), conditional on "assuming each oracle call ... terminates". (2) Snakemake `--dry-run` — the only shipping QUANTITY report ("Snakemake will only show the execution plan instead of actually performing the steps", https://snakemake.readthedocs.io/en/stable/tutorial/basics.html; the `Job stats:` job/count table confirmed at https://github.com/snakemake/snakemake/issues/2667) — counts jobs over a filename-unification DAG and stops at a `checkpoint`. (3) BigQuery `--dry_run` — a real pre-run bill for bytes; Google explicitly routes generative-AI cost control to token quotas instead (https://docs.cloud.google.com/bigquery/docs/control-genai-costs). (4) AWS ValidateStateMachineDefinition — verified "You can validate that a state machine definition is correct without creating a state machine resource"; result `OK|FAIL`; diagnostics carry code/message/severity/location; "Run validation from a Git pre-commit hook"; "Your automated processes should only rely on the value of the **result** field value (OK, FAIL)" — structure only, no counts. (5) Haystack `max_runs_per_component: 100` — the only bound stated in the serialized program, but a runtime tripwire raising on the (N+1)th attempt. (6) Everyone else: runtime aborts — max_turns, recursion_limit (default 1000 SUPER-STEPS, not model calls), UsageLimits(request_limit=50), max_steps=10, message_limit, Temporal's 51,200-event history cap.
VERDICT: agent-cat is the only design producing a TREE of question counts, PER BRANCH, BEFORE the run, for a language in which EVERY WRITABLE PROGRAM is in scope — no fragment, no side condition, no escape hatch.

=== GUARANTEE B — SHAPE AS DATA ===
BAML is closest and genuinely good (`client`, `prompt`, `-> OrderInfo` in one declaration) but its prompt is Jinja, so control flow lives inside the typed language, and `{{ ctx.output_format }}` renders an invisible schema. Conductor puts addressee, deadline and a VERSIONED answer form in structured fields with only `displayName` free text; ours obtains the same stability differently — there are only four codes, so a shape needs no version. PDL derives structured decoding from a declared `spec:` but checks it dynamically at run time with a line number; ours refuses before anything runs. DSPy is the counter-case for the resample draw: `rollout_id` threaded into the LM CACHE KEY with a forced temperature=1.0 the author never asked for. Ours makes two draws two bindings.

=== GUARANTEE C — MEMOIZATION AS SEMANTICS ===
Every surveyed sharing story is a CACHE with a documented mode in which the same program means two different things: Prefect ("Caching requires result persistence, which is off by default"); Dagster ("'Unsynced' status is *not* transitive"; without an explicit code_version "Dagster assumes a different code version on every run"); Nextflow (a hash over ~a dozen things including "Global variables referenced in the task script", plus a troubleshooting page for when it is wrong); LangGraph (CachePolicy(ttl=...), key = "a `hash` of the input with pickle"); DSPy (a knob whose whole purpose is to DEFEAT the cache). Haxl is closest to a stated law — `do x <- N; M ==> do x <- N; M[return x/N]` — but conditions it on "provided dataFetch is the only way to do I/O in our framework, and all dataFetch requests are cached", and breaks `<*> = ap` to get it. Ours has NO such mode: sharing is by binding, meaning is a function of a total answer sheet. This is the cleanest differentiator in the entire survey.

## adoptedIdeas

Deduplicated across ten families. Each judged against: elaborates to the five formers; level <= branch; no dynamic shape; house rule 8; the owner's dataflow-visibility demand.

--- ADOPTED AS GRAMMAR (3) ---

[D] VISIBLY DISTINGUISH DEFINE-EXPANSION FROM ANSWER-SPLICE. Source: LMQL's two bracket kinds — `"Review: {review}"` (a value flowing IN) vs `"A:[ANALYSIS]"` (a hole the model FILLS), which makes "the direction of every piece of data legible at a glance, inside the prompt text itself" (https://lmql.ai/docs/language/overview.html). Third and fourth witnesses: Flowise's `{{ $flow.state.yourKey }}` prefix marking membership in a DECLARED, CLOSED namespace (https://docs.flowiseai.com/using-flowise/agentflowv2), and PDL/Conductor's `${ N }` / `${workflow.input.status}` sigil for "this came from a declaration elsewhere". HOW IT LANDS: a define hole becomes `{$name}`; an answer hole stays `{name}`. Nothing else moves. Fits every non-negotiable — expansion, elaboration, prompt fidelity and parse determinism are unchanged; the incumbent lexer keeps its single interpolation trigger (`{`) because the mark goes INSIDE the brace. Value: it converts the batch/pipeline rung from a fact recovered by cross-reference into a fact readable at the question, which is the owner's dataflow-visibility demand applied to the one remaining unmarked movement in the language.

[N] NO SHADOWING. Source: AWS Step Functions, verified verbatim — "To help avoid common errors, a variable assigned in an inner scope cannot have the same name as one assigned in an outer scope. For example, if the top-level scope assigns a value to a variable called `myVariable`, then no other scope (inside a `Map`, `Parallel`) can assign to `myVariable` as well" (https://docs.aws.amazon.com/step-functions/latest/dg/workflow-variables.html). HOW IT LANDS: a tenth rule refusing re-introduction of a live name, with `_` exempt and dead names reusable (so `settled (patch : text)` stays legal — that is exactly the reuse the design wants). Fits at zero cost: a check on Bindings, no Plan node, no level change. Value: the incumbent's worst reported pathology was three different binders spelled `patch` (design-digest.md §2); the final design fixes the specific case at the loop head, and this closes the general one. It also makes `known here:` a list in which each name denotes exactly one binder, and refuses `revising draft as draft, ...`.

[U] `using model` ONLY WHERE IT MEANS SOMETHING. Source: BAML attaches `client "openai/gpt-5-mini"` only to a `function` whose answerer is a model (https://docs.boundaryml.com/ref/baml/function.md); Conductor's HUMAN task carries assignee/slaMinutes/userFormTemplate and NO model field (verified). HOW IT LANDS: `who` is deleted and each addressee kind gets its own production listing its own options. Doctrine anti-pattern 9 — an invariant maintained by "callers must ensure" belongs in the type. Value: removes the one way left to write a program whose text says something its meaning does not (design-digest.md §5).

--- ADOPTED AS TOOLING / DOCS (7) ---

[A+B+O] ONE PRE-RUN COMMAND THAT PRINTS A FLOOR, A CEILING, A REASON, AND A PICTURE.
- Floor/ceiling from selective functors' Over/Under, verified: over-approximation serves installing every possible dependency "before the build", under-approximation is aimed at "maximising parallelism *during the build*"; `dependenciesOver ("exe") = ["src.ml","config","lib.c","lib.ml"]` vs `dependenciesUnder = ["src.ml","config"]` (https://github.com/snowleopard/selective/blob/main/paper/3-static.tex). For us this is a SECOND FOLD over the finite cost tree we already build — no former, no shape change. The floor is the set of questions asked in every world, i.e. exactly the panel that can be dispatched immediately.
- Presentation from Snakemake's dry-run job/count table and BigQuery's free, explicitly-upper-bound `--dry_run`.
- Diagnostics shape from AWS ValidateStateMachineDefinition, verified: a single `result` of `OK|FAIL`, diagnostics carrying `code`, `message`, `severity` and a `location` such as `/States/HelloWorld/Parameters`, pitched for CI and "a Git pre-commit hook", with the stability discipline "Your automated processes should only rely on the value of the **result** field value (OK, FAIL). Do **not** rely on the exact order, count, or wording of diagnostic messages."
- A `--why` column naming the binding that forced each question, from Snakemake's `-r` reason output.
- The drawing from LlamaIndex, whose framing is the pitch: the same declarations serve "two different moments: before a run, to see every possible path, and after a run, to see what actually happened" (https://developers.llamaindex.ai/python/llamaagents/workflows/drawing/index.md). For us the cost tree IS the picture and the transcript is a sub-tree of it — Explain.lean already renders `plan` and `cost`.

[C] NAME THE ELABORATION-TIME CHECK SET AS A CONTRACT, ONE DIAGNOSTIC PER CLAUSE. Source: Microsoft Agent Framework, verified verbatim — "The framework performs comprehensive validation when building workflows: **Type Compatibility**: Ensures message types are compatible between connected executors; **Graph Connectivity**: Verifies all executors are reachable from the start executor; **Executor Binding**: Confirms all executors are properly bound and instantiated; **Edge Validation**: Checks for duplicate edges and invalid connections." Our five clauses: (1) every hole names a live binder or an earlier define, of the right kind; (2) every `branch on` scrutinee is a flag or verdict and all arms are written in order; (3) every binder's kind matches its source; (4) no live name is introduced twice and no binder spells a define; (5) `known here` matches Gamma. MAF's reachability clause does NOT apply — both tags of a flag are inhabited, so no arm is dead. Presentation, not new power; MAF earned real adoption by advertising it.

[Q] PROHIBITION: NEVER RECOVER THE RUNG BY A HEURISTIC DESUGARER. Source: GHC ApplicativeDo (the shipped form of the transformation Haxl's ICFP'14 paper proposed) — "usually finds the best solution, but in rare complex cases it might miss an opportunity"; `-foptimal-applicative-do` "always finds the optimal solution, but it is expensive: O(n^3)"; "a strict pattern match in a bind statement prevents ApplicativeDo from transforming that statement to use Applicative". This is the strongest argument FOR amendment D and it comes from the family where the mistake was actually made. Write the prohibition into the reference beside D.

[V] A COST-COVERAGE PAGE. Source: CrewAI needed a page of caveats to describe a number it measured AFTER the run — `flow.usage_metrics` counts "every LLM call made during the run — including calls from every Crew the Flow orchestrated, calls inside Agent tools, and bare `LLM.call(...)` invocations", and the docs warn the obvious number `kickoff().token_usage` "only reflects the final Crew and ignores prior Crews and bare `LLM.call(...)` invocations entirely" (https://docs.crewai.com/en/concepts/flows). Plus promptfoo's blunt callout, verified: "For 3 judges, you pay 3x the grading cost per test case." USE IT AS A CHECKLIST: for each CrewAI leak category say "counted" or "impossible in this language". Spell out `independent draw n` most carefully — it is the one place one syntactic question is n model calls.

[AC] DETERMINISM AS A STATED LAW. Source: Microsoft Agent Framework justifies its BSP/superstep model with "**Deterministic execution**: Given the same input, the workflow always executes in the same order" and "**Reliable checkpointing**" (verified). Free for us (meaning is a function from total answer-sheets); MAF needs a Pregel scheduler and a synchronization barrier to approximate it. Worth saying out loud because this family has taught users to expect nondeterminism.

[AD] TWO REVIEW CRITERIA, WRITTEN DOWN. Source: YAWL's OR-join — "The semantics adopted by YAWL is that an OR-join waits until no more inputs can arrive at the join. To make sure that the semantics are well defined, i.e., have a fix-point, we exclude other OR-joins"; and "From a performance point of view, the OR-join is quite expensive (the system needs to calculate all possible futures from the current state)" — one construct forcing a state-space exploration per firing AND a syntactic exclusion of nested occurrences of itself, spelled `<join code="or"/>`, four characters hiding the most expensive decision in the language. THE RULES: (1) no former's enablement may depend on state outside its own subterm; (2) if a construct's cost is not readable from its own syntax, the notation must show it. Both hold today; naming them blocks a future `panel, whichever answers first`.

[AE] NAME WHICH EDITS PRESERVE WHAT — IN ITS HONEST FORM. Source: Temporal enumerates history-compatible changes by hand (safe: input parameters, timer durations, activity options; unsafe: reordering or adding/removing command-producing calls). For us this is a theorem shape, not a list — but the honest version is weaker than the survey's fit note claimed: editing a question's WORDS changes the question and therefore its index into Omega, so the answer sheet is NOT preserved. What IS preserved is the SHAPE SEQUENCE and the COST TREE. State exactly that; it is the user-visible payoff of shape-as-data, and it is what `define` buys (editing `verdictSpec` moves no binding and no cost node).

--- ADOPTED AS "ALREADY SATISFIED", RECORDED AS EXTERNAL VALIDATION (9) ---
[F] GCW `shared: [total]` — the combiner declared at the fan-out site. `panel, all must approve [...]` already is this; LangGraph's `Annotated[list[str], operator.add]` in a distant TypedDict is the anti-case.
[H] lambda_A `fix_n` — the loop bound as a syntactic index. Independent, Coq-mechanised (1,519 lines, 42 theorems, 0 Admitted) validation of `at most n revisions`.
[I] lambda_A Observation 1 — base-case existence as case-exhaustiveness. Ours is stronger: the failure is unwritable, whereas lambda_A needs a lint rule that 57.8% of 835 real GitHub configs fail.
[M] Pydantic AI AgentSpec — "template variable names are validated at construction time". One clause of contract C.
[R] MCP's accept/decline/cancel and AG-UI's resolved/cancelled — already satisfied for verdicts (`approved`/`objected`/`no answer`). A flag genuinely has two inhabitants. Note the difference: MCP's third case is PROCEDURAL (the human walked away); ours is SEMANTIC, and the sheet is total.
[S] MCP MRTR — the single best external confirmation in the survey. See differentiators.
[W] Argo's "absent is not the same as an empty string" — already satisfied by rules 3/4. One residual: the panel-annihilation trap; name it as a hazard in the reference.
[X] lambda_A's entanglement measurement — the empirical case for the unwritable `dyn`.
[AA] Haystack's `max_runs_per_component` — ours is better: a meaning, not a tripwire.

--- ADOPTED AS DOCS SENTENCES (2) ---
[J] Conductor's per-iteration `__i` renaming — as ONE SENTENCE only: the unrolling already makes round 2's question distinct from round 1's, so memoization does not collapse them. No syntax.
[E-defence] Inspect's named reducer — record that `all must approve` is the named-reducer pattern at set size one, that the comma slot is deliberately reserved, and that PoLL's answer-type-dependent combiners are why.

## rejectedIdeas

Every significant rejection, with the reason. The bar was "significant value that fits the architecture"; novelty was never sufficient.

[G] CAP PANEL ARITY IN THE GRAMMAR (Google Cloud Workflows: "Up to 10 branches per parallel step", verified). REJECTED. GCW caps because its branches are runtime-scheduled and it must bound concurrency; ours are syntax, and a twelve-judge panel costs twelve leaves with the tree saying so. An arbitrary numeral would be a fact about a scheduler migrating into the model — the doctrine kernel's standing instruction is to "Suspect every part of the model that exists because computers are finite, discrete, or sequential." The literal member list (the half that matters) is already adopted.

[K] A SEPARATE SPELLING FOR AN ORDERING-ONLY EDGE (Dagster's `deps=[daily_sales]` vs a parameter). REJECTED. `_ : receipt <- ask tool "apply"` already says "this happened and nothing came back", and unlike an ordering edge it is a real question with a real cost node and a real transcript entry. Adding a second spelling gives two constructs for one idea — precisely the `if`/`else`-beside-`case` and `act`-beside-`ask` deletions the synthesis already made.

[P] PUT THE RUNG IN THE BINDER — `let+ ... and+` FOR THE PANEL (OCaml binding operators, verified, including "we strongly recommend APIs where let-operators and and-operators working together use the same symbol"). REJECTED for the panel. A panel is ONE binding of a combined verdict, not n independent bindings: `Plan.panel` is `foldr (zipWith (·*·))` and the monoid is installed only at .verdict. Giving each judge a name would require n binders plus a combine expression, i.e. an expression language, which is the thing rule 3 exists to forbid. The bracketed member list already reads as a fan-out and puts the combiner at the head. The valuable half of the OCaml lesson survives as the prohibition [Q].

[T] CONSENT-GATE DEADLINES AND DEFAULTS AS TERM-LEVEL FIELDS (Airflow's `defaults=` and `response_timeout=`; GitHub Actions' "If a job is not approved within 30 days, it will automatically fail"; Conductor's `slaMinutes`; Durable Functions' `Task.WhenAny(waitForEvent, createTimer(deadline))`). REJECTED, and the refusal is a consequence of the meaning function rather than a preference. A deadline is wall-clock — it would make meaning depend on something outside Omega, so a program would stop being a function from answer-sheets. A default is "the answer when the sheet is silent", and the sheet is TOTAL, so there is no silent entry to default. Both refusals are differentiators: agent-cat's totality is precisely why it needs no defaults.

[Y] FUSE THE CONSENT GATE WITH THE BRANCH (Airflow's `HITLBranchOperator(options=["task_1","task_2","task_3"])`, where the option set IS the downstream task-id set). REJECTED. Fusing creates a SECOND case-spelling, which is exactly the defect the whole redesign exists to remove (design-digest.md §1: "Plan.case wears three unrelated spellings"). `ask person "owner"` followed by `branch on ok` is two constructs the reader already knows, on adjacent lines, and it keeps exactly one arm-list shape in the language.

[Z] A VALIDATOR PREDICATE ON AN ANSWER DOMAIN (Temporal update validators — "In an Update validator you raise any exception to reject the Update", with `WorkflowExecutionUpdateAccepted` written only after it passes). REJECTED. A predicate is an expression, and rule 3 admits no expression language. Prefect supplies the corroborating failure: its `model_validator` on a human-gate answer shape "happens *after the flow resumes*", because it is code rather than data — the exact failure that term-level shapes exist to avoid.

[AB] A CLOSED DECLARED MUTABLE STORE (Flowise Flow State — "All state keys that will be used throughout the workflow must be initialized ... using the Flow State parameter within the Start node. This step effectively declares the schema", and "New keys cannot be created by operational nodes; only pre-defined keys can be updated", verified). STORE REJECTED, closure half kept. Flowise's own stated motivation is to pass data "across branches or non-adjacent steps" — a description of routing around binding. A mutable store would break sharing-by-binding and make meaning-as-a-function-of-answer-sheets untrue. The declaration-closes-the-namespace half is what `define` already is, and Flowise's `$flow.state.` prefix is the third witness for amendment 1.

[AF] REFINEMENT / GUARD TYPES ON ANSWERS (lambda_A's `guard e P` and `{x:tau | P(x)}`). REJECTED. A decidable predicate is still an expression language, and it is lambda_A's ONLY source of stuckness by its own account ("The only source of stuckness is E-Guard-Fail, which is a checked runtime error"). Our four codes are the answer domains, checked at read time.

[AG] AN ESCALATION-CHAIN FORMER (Inspect AI's five approval decisions including `escalate`, meaning "the tool call should be escalated to the next approver in the chain"). REJECTED as a former; noted as derivable. A chain of n approvers is n `ask person` bindings and n nested `branch on`, already writable, with an exact cost tree. A keyword for something the language spells is the definition of novelty for its own sake. Also rejected: Inspect's ambient policy matched by tool-name glob (`ApprovalPolicy(human_approver(), ["web_browser_click", "web_browser_type*"])`) — matching at a distance defeats "data movement and scope syntactically evident".

[AH] AN ORDINAL VERDICT PLUS A THRESHOLD (mcp-agent's `min_rating='EXCELLENT'` with `evaluation_result.rating.value >= self.min_rating.value`, verified). THRESHOLD REJECTED, convergence noted. A threshold needs an ordering on verdicts and a comparison — an expression language again. Our three-tag verdict is closed and total and the monoid decides. mcp-agent's independent arrival at a CLOSED ORDINAL VERDICT SET validates the half we have.

[E, float form] A NUMERIC PANEL THRESHOLD (promptfoo's `threshold: 0.66 # 2 of 3 judges must pass`, verified, with the FAQ repeating "For 2-of-3 majority, set `threshold: 0.66`"). REJECTED. A bare fraction silently depends on panel size — change three judges to four and 0.66 quietly means three-of-four — and it fails house rule 8 outright: a number does not say what it means. If a second monoid is ever installed it must be a NAME in the comma slot, following Inspect.

[J, syntax form] PER-ROUND BINDING NAMES (Conductor's DO_WHILE, where "each contained task's reference name gets a `__i` suffix appended"). SYNTAX REJECTED, observation kept as a docs sentence. Machine-generated per-round names would destroy "one name, one meaning", which is the design's direct answer to the owner's complaint about three different binders spelled `patch`.

[L] DECLARED SIGNATURES FOR REUSABLE SUB-PROGRAMS (Nextflow `take:`/`emit:`; Argo `inputs.parameters`; Haystack's typed sockets). NOT REJECTED — NOT APPLICABLE. There is no reusable named sub-program former. Recorded as the shape to use if one is ever added; `review -> verdict` and `amend (why : verdict) -> patch` are already that pattern at the one place clause boundaries exist.

[unnumbered] MANDATORY `known here`. REJECTED. It is the one piece of documentation in the language that cannot rot, but requiring it at every block adds noise to a surface whose diagnosed problem was confusion. Keep optional.

[unnumbered] RENAMING `giving`. REJECTED after search. The synthesis flagged it as the word its author was least sure of; no single token was found that carries "the loop is over and produced one of two things" better. It is doing real work — naming the loop's unnamed `Option` result and casing on it in one word, where there is no scrutinee to write because the result has no name and no code. Keep; do not churn.

[unnumbered] AUTO-DERIVING ANSWER-SHAPE PROSE FROM THE CODE (PDL: "The fields `guided_json` and `response_format` are added automatically by the interpreter ... with the JSON Schema value obtained from the type"; BAML's `{{ ctx.output_format }}`). REJECTED AS A GRAMMAR CHANGE, recorded as an adapter-layer opportunity. The flagship's hand-written `verdictSpec`/`flagSpec` do duplicate what the elaborator already knows from the code. But the fix belongs in the adapter, and the DSL's prompt-fidelity constraint (every prompt character-for-character identical to Core/HardenPatch.lean) pins the surface today.

## refinedGrammarDelta

THREE AMENDMENTS. Everything else in syn-finalGrammar.txt stands, argued idea by idea above.

=== AMENDMENT 1 — a define hole is marked (adopts [D], enforces [Q]) ===

BEFORE:
  prompt      ::= '"' { plain | escape | hole } '"'
  defstring   ::= '"' { plain | escape | hole } '"'
  hole        ::= "{" name [ "." "reasons" ] "}"

AFTER:
  prompt      ::= '"' { plain | escape | hole } '"'
  defstring   ::= '"' { plain | escape | defhole } '"'
  plainstring ::= '"' { plain | escape } '"'                 -- unchanged
  hole        ::= "{" name [ "." "reasons" ] "}"   -- an ANSWER: spliced when the program runs
                | defhole                           -- a DEFINE: expanded where you see it
  defhole     ::= "{" "$" name "}"

RULE 4, amended (answers only; one clause shorter than before):
  "`{x}` interpolates an ANSWER, and only text. Where x is a verdict, write `{x.reasons}` —
  the objections joined by '; ', which is Verdict.render (Core/HardenPatch.lean:91) written
  where it is used. Where x is a flag or a receipt there is no rendering and the program is
  refused; a receipt carries no information (El .ack = Unit). `_` may not be interpolated and
  may not be branched on."

RULE 5, amended:
  "`{$x}` interpolates a DEFINE — literal text, expanded by `expand` (Parse.lean:254-260)
  before any Raw exists. Inside a defstring only `{$x}` is legal and must name an EARLIER
  define; anything else is refused at parse time. So expansion always yields literals and no
  define can be cyclic. `{x}` is refused if x names a define; `{$x}` is refused if x does not.
  A question is closed — and therefore in the batch rung — exactly when every hole in it is a
  `{$…}`, which is now readable AT THE QUESTION rather than by cross-reference to the top of
  the file. A binder may not spell a define (see rule 10)."

WHY THE MARK GOES INSIDE THE BRACE, not `$spec` in open text: the incumbent lexer's rule —
an unescaped `{` ALWAYS opens an interpolation, `\{`/`\}` escape, empty and unterminated holes
diagnosed (Parse.lean:88-127) — was deliberately restored by the synthesis to close a grammar
ambiguity all three candidate designs left open and three separate attackers filed. A second
interpolation trigger would reopen it. Inside the brace we keep one trigger, one lookahead
character (`$` or a letter), and no new escape.

COST: two characters per define hole; three occurrences in the flagship. No new KEYWORD, so
house rule 8 is not even engaged — `$` is a mark, and "substituted from a declaration
elsewhere" is its most conventional use in the entire surveyed world (`${...}` in Conductor,
PDL, Google Cloud Workflows, GitHub Actions, Flowise). Parse determinism, elaboration,
prompt fidelity and the level theorem are all untouched.

=== AMENDMENT 2 — no shadowing (adopts [N]) ===

NEW RULE 10 (the nine rules become ten):
  "A name that is LIVE may not be introduced again. A binder left of `<-`, a `settled` binder,
  an `amend` binder, or a loop carrier introduced by `as` is refused if a binding of that name
  is still in scope at that point; the `define` namespace counts as always live, so rule 5's
  'a binder may not spell a define' is this same rule one clause wider. A name whose scope has
  ENDED may be reused — this is exactly what lets `settled (patch : text)` name the artefact
  the loop was revising, since the loop carrier's scope closes at the loop's brace. `_` is
  exempt: it introduces nothing, so a workflow may contain any number of `_ : receipt`
  bindings."

WHAT IT REFUSES that the nine rules permitted: a `guide : text <- …` inside a `yes {}` arm
while an outer `guide` is live; a `patch : text` inside `review`'s block; and
`revising draft as draft, at most 2 revisions` — the remaining confusing case.

COST: one refusal an author might not expect, mitigated by a diagnostic naming the outer
binding's line. No Plan node, no level change, no elaboration change: it is a check on
Bindings, the identity on the continuation, exactly like `known here`.

=== AMENDMENT 3 — `using model` only where it means something (adopts [U]) ===

BEFORE:
  ask         ::= "ask" who [ "using" "model" plainstring ]
                             [ "independent" "draw" number ] prompt
  who         ::= ( "model" | "tool" | "person" ) plainstring

AFTER (`who` is deleted; each addressee kind lists its own options):
  ask         ::= "ask" "model"  plainstring [ "using" "model" plainstring ]
                                             [ "independent" "draw" number ] prompt
                | "ask" "tool"   plainstring [ "independent" "draw" number ] prompt
                | "ask" "person" plainstring [ "independent" "draw" number ] prompt

`independent draw` stays on all three deliberately: the draw is a field of the question SHAPE
(Q.Shape.draw, Question.lean:294), and asking one addressee the same question n independent
times is meaningful for a person (blind re-review) and a tool (a flaky command) as much as for
a model. Only `using model` is bound to the model addressee, because only there does it name
anything (askShape writes `atModel m` into the shape, Check.lean:159-163).

PARSE DETERMINISM is preserved and in fact sharpened: `ask` is followed by exactly one of three
addressee words, and that word decides the option set — the same "positions decide" discipline
the rest of the grammar uses.

=== NOT CHANGED, AND WHY ===
- `giving`: keep. No better single token found for "the loop is over and produced one of two
  things"; it names an `Option` result that has no name and no code, so there is no scrutinee
  to write. Do not churn a word the synthesis already defended.
- `panel, all must approve`: keep, comma and all. The comma reads oddly for a rule with no
  alternatives today, but it is the slot a second monoid would occupy, and PoLL's evidence
  (different combiners for different answer types) says one will eventually be wanted.
  Reserving it costs nothing.
- `known here`: keep optional.
- The verbosity of `revising`: accept. Every line is forced by the kernel's `Option` or by
  naming what a clause answers. No cut was found that preserves a guarantee.

=== THREE HAZARDS TO NAME IN THE REFERENCE (no grammar change) ===
1. PANEL ANNIHILATION: a panel with any `declined` member zeroes all objections, so
   `{why.reasons}` is legitimately empty and the reviser is told it failed but not why
   (design-digest.md §6). This is "absent silently becomes empty string" reappearing at the
   semantic level. A Verdict monoid question, out of scope for a surface redesign — but the
   reader must be told, not left to discover it. Inspect AI's `"collect"` reducer, which
   "preserves the individual values as a list", is the shape of the eventual fix.
2. ARMS EXPORT NOTHING: unlike ASL's per-arm `Assign`, a binding made inside a branch arm
   cannot reach the join. State it as a PRINCIPLED refusal — a value exported from an arm has
   a sum type, and Ctx holds Codes, so there is no code for it; this is the same reason
   `never settled` cannot hide the `none`.
3. THE KIND IS THE SHAPE; THE SPEC DEFINE IS A COURTESY. `flag` is what the adapter must
   satisfy; `define flagSpec = "Reply with exactly yes or no."` is words that help the
   addressee produce it. They can drift. PDL derives the constraint from the declared type
   automatically; that is the adapter-layer fix, not a surface one.

## refinedFlagship

CHANGED — but only by Amendment 1, and only in three holes. Amendments 2 and 3 leave the page byte-identical (no shadowing occurs; no `using model` appears on a tool or person).

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

workflow {

  guide : text <- ask tool "cat"
      "Write out the house style guide, at most four short lines."

  draft : text <- ask model "author" using model "deep"
      "Draft a patch satisfying:\n{$spec}\nReply with a unified diff only."

  revising draft as patch, at most 2 revisions {

    review -> verdict {
      panel, all must approve [
        ask model "reviewer-correct"
            "{guide}\nIs this patch correct?\n{patch}\n{$verdictSpec}",
        ask model "reviewer-secure"
            "{guide}\nIs this patch secure?\n{patch}\n{$verdictSpec}",
        ask model "reviewer-simple"
            "Could this patch be simpler?\n{patch}\n{$verdictSpec}"
      ]
    }

    amend (why : verdict) -> patch {
      ask model "author" using model "deep"
          "{guide}\nRevise this patch:\n{patch}\n{why.reasons}\nReply with the revised diff only."
    }

  } giving {

    settled (patch : text) {
      known here: patch, draft, guide

      ok : flag <- ask person "owner"
          "Apply this patch?\n{patch}\n{$flagSpec}"

      branch on ok {
        yes {
          _ : receipt <- ask tool "apply"
              "Apply:\n{patch}\nWrite the patched file here, then reply DONE."
        }
        no { stop }
      }
    }

    never settled { stop }
  }
}

WHAT THE AMENDMENT BUYS ON THIS PAGE.
(1) The `draft` question now visibly has one hole and it is a CONSTANT, so a reader sees
without leaving the line that it is a closed question in the batch rung — the fact the
incumbent needed a footnote for ("Without `define` the flagship's draft node is Plan.ask
instead of Plan.askC"; DslFlagship.lean:129-130 records three literals).
(2) Each reviewer prompt now shows, in one glance, two answers flowing IN (`{guide}`,
`{patch}`) and one constant (`{$verdictSpec}`) — where before the reader saw three
identical-looking holes.
(3) The consent question shows one answer and one constant, so `{patch}` still stands out as
the thing the owner is being shown.
(4) `{guide}` remains searchable and countable: four prompts, and the simplicity reviewer's
absence from the list is still visible in the same scan — the surface half of what guide_once
proves. The `$` mark does not interfere, because a define is never a binder (rule 10).

PROMPT FIDELITY IS UNAFFECTED. Expansion is unchanged, adjacent literals are still not fused
(Prompt.normalize, Syntax.lean:142-159), and Prompt.exprFrom still left-associates
(Check.lean:125-139), so the elaborated prompts remain the same ++-chains Core/HardenPatch.lean
writes by hand. The structure check is unchanged: four case nodes, nine cost-tree leaves, eight
questions, seven addressees, `guide` bound once and read in three prompts.

## differentiators

What the surveyed world does NOT have that this design does. Each with the survey's evidence.

1. A PER-BRANCH COST TREE, COMPUTED BEFORE THE RUN, FOR A LANGUAGE IN WHICH EVERY WRITABLE PROGRAM IS IN SCOPE.
Only one rival has a PROVED pre-run bound: lambda_A (arXiv:2604.11767), and it is a SCALAR — Theorem 5.6 bounds cost(T) by n x max_i c_i, conditional on Theorem 5.4's "assuming each oracle call (lam and tool) terminates". Its own gloss is that this "enables pre-deployment cost estimation ... not possible in frameworks without formal termination bounds." Ours is a TREE: four case nodes, nine leaves, eight questions for the flagship, at level <= branch, proved (parseAndCheck_level_le, Dsl.lean:361-367). Everything else shipping is one of four weaker things: a job-count table over a filename DAG that stops at a `checkpoint` (Snakemake `--dry-run`, the only other pre-run QUANTITY report); a bytes bill that Google explicitly declines to extend to AI.GENERATE tokens (BigQuery `--dry_run` + https://docs.cloud.google.com/bigquery/docs/control-genai-costs); a structure-only validator (AWS ValidateStateMachineDefinition, "You can validate that a state machine definition is correct without creating a state machine resource" — result OK|FAIL, no counts); or a runtime abort. Every framework bound in ten families is the last kind: `max_turns`, `recursion_limit` (which bounds SUPER-STEPS, not model calls — a node body is arbitrary Python), `UsageLimits(request_limit=50)`, `max_steps=10`, `message_limit`, Haystack's `max_runs_per_component` raising on the (N+1)th attempt, Temporal's 51,200-event history cap.

2. MEMOIZATION AS MEANING, NOT AS CACHE — the cleanest differentiator in the survey.
Every surveyed sharing story is a cache with a documented mode in which the same program means two different things. Prefect: "Caching requires result persistence, which is off by default." Dagster: "'Unsynced' status is *not* transitive", and without an explicit `code_version` "Dagster assumes a different code version on every run". Nextflow: a hash over roughly a dozen things including "Global variables referenced in the task script", plus a troubleshooting page for when it is wrong. LangGraph: `CachePolicy(ttl=...)`, key = "a `hash` of the input with pickle". Haxl comes closest to a stated law (`do x <- N; M ==> do x <- N; M[return x/N]`) but conditions it on "provided dataFetch is the only way to do I/O in our framework, and all dataFetch requests are cached", and breaks `<*> = ap` to get it. Ours has no such mode: sharing is by binding, and meaning is a function from TOTAL answer-sheets to answer-plus-transcript.

3. A RESAMPLE DRAW THAT IS A FIELD OF THE QUESTION, NOT A CACHE DEFEAT.
DSPy is the direct counter-evidence: `Refine`/`BestOfN` deep-copy the module and inject `rollout_id = start + i` with a forced `temperature=1.0`, threaded into the LM cache key "so the model resamples instead of replaying a cached response" (https://dspy.ai/api/modules/Refine/). A system whose sharing is a cache is forced to bolt on a hatch keyed on the cache, and the hatch leaks into module semantics as a temperature the author never asked for. Ours: `independent draw n` is in Q.Shape (Question.lean:294); two draws are two bindings; one binding is one answer.

4. A REVISION LOOP WHOSE NON-SETTLING PATH IS A PROGRAM PATH THE AUTHOR MUST WRITE.
mcp-agent returns `best_response` "even if the target isn't reached" (verified in source), so the caller cannot tell whether the loop settled. DSPy returns argmax. The canonical Anthropic reference implementation is `while True:` with no bound at all. Self-Refine's stop rule may be "a scalar stop score" extracted from the model's own feedback. Ours: `Plan.revising` answers `Option (El c)` (Plan.lean:611-614) and Ctx holds Codes, so there is no code for "maybe a text" and the surface CANNOT hide the `none` — `giving { settled (...) ... never settled ... }` is unwritable to omit. Nobody in the survey makes "it never came to rest" a program path.

5. THE LOOP'S BACK-EDGE IS WRITTEN, NOT PERFORMED.
`amend (why : verdict) -> patch` — the arrow points at the name it rebinds. lambda_A's `fix_n e` does the rebinding in the operational semantics (`lambda x. fix_{n-1} e x`); mcp-agent's next candidate is a Python local; Conductor's is a `__i`-suffixed reference name. Ours is the only surface in the survey where the only assignment in the language is on the page.

6. A HUMAN GATE THAT IS NOT A SPECIAL FORMER.
Seven surveyed systems, seven distinct node types: Conductor's HUMAN, Argo's `suspend`, LangGraph's `interrupt()`, ADK's `RequestInput`, PDL's `read:`, ASL's `.waitForTaskToken` URI suffix, GitHub Actions' `environment:`. Ours is `ask person "owner"` — the same shape as `ask model` and `ask tool`. One cost rule, one branch rule, one memoization rule, and no second arm-list shape. The addressee is written at every ask, which even the approved Lean cannot do (it has `ask` and `askHuman`, two words, and no tool at all, while seven distinct addressees live in Core/HardenPatch.lean).

7. A TOOL ACT THAT IS AN ASK.
lambda_A keeps `tool[f]` as one of its five primitives; ASL, Argo and GHA make it a different node type entirely. Ours makes the addressee a KIND, so a tool act costs one question in the same tree, and `_ : receipt` names the Unit answer — which lambda_A, typing every tool `Str -> Str`, cannot say.

8. NO IMPLICIT ACCUMULATING CONTEXT, ANYWHERE, EVER.
Four of six llm-call DSLs grow one invisible prompt (LMQL top-level strings, Guidance `lm +=`, SGLang `s +=`, PDL background context), and PDL's docs concede the default outright: "when we call a function, we implicitly pass the current background context." Every one of them later bolted on a corrective knob (`contribute:`, `pdl_context: []`, nested queries) rather than removing the default. The agent-framework family reversed the same decision under load: OpenAI added `input_filter` because a handed-off agent "gets to see the entire previous conversation history"; AutoGen needed a whole second message graph on top of its execution graph ("By default, all messages are sent to all agents in the graph"); Microsoft rebuilt the framework around routed typed messages. Ours never had an accumulator: a question sees exactly the words written, and rule 3 gives an answer exactly two destinations.

9. THE RUNG OF A QUESTION IS READABLE AT THE QUESTION (after Amendment 1).
GHC recovers the applicative/monadic rung by heuristic and its manual admits it "might miss an opportunity". SGLang's tracer discovers the same distinction empirically and buries it: it runs the program with dummy arguments and, when a branch touches generated text, "catches `except (StopTracing, TypeError, AttributeError)` and gives up" — two silent execution modes where the static one covers only the static-shape subset. Nobody raised it into the surface. `{$x}` vs `{x}` does exactly that.

10. THE REPLAY PROTOCOL IS DERIVED, NOT DESIGNED.
MCP's 2026-07-28 Multi Round-Trip Requests is our semantics rediscovered as a wire protocol: the server answers the original call with an `InputRequiredResult` carrying a NAME-KEYED `inputRequests` map, and "the client gathers the requested information ... then retries the original request including the additional requested information". The design goal is stated as working "without requiring a shared storage layer across server instances or requiring stateful load balancing", and the key sentence is verbatim: "the server processing the retry does not need any information beyond what is directly present in the retry request." MCP needed an AEAD-protected opaque `requestState` blob to achieve that, with replay-window mitigations, a TTL, and a principal check, because state round-trips through an untrusted client. agent-cat needs none of it: the program plus the answer sheet IS the state, and running against a fuller sheet is the same function. Also note MCP's insistence on NAME-keyed rather than positional answers, whose cost LangGraph demonstrates: "Matching is **strictly index-based**", so conditionally skipping a gate silently mispairs answers.

11. THE ESCAPE HATCH IS NOT REACHABLE FROM THE SURFACE AT ALL.
ADK ships "dynamic workflows: programmatic orchestration in your own code (loops, conditionals, recursion) — best when the control flow is too complex or iterative for a static graph" beside its graph. smolagents IS the hatch. Flyte and Snakemake do it right by giving the hatch its own keyword (`@dynamic`, `checkpoint`). lambda_A measured what happens when the door is merely narrow: of 835 real GitHub agent configurations, lint precision on YAML alone is 54%, rising to "96--100% under joint YAML+Python AST analysis", quantifying "the degree of semantic entanglement between declarative configuration and imperative code". Our surface has NO syntax for `dyn` at all, so there is not even a hole to show in the cost tree — the four reasons the whole surveyed world cannot price a program (data-dependent branch, unbounded back-edge, data-width fan-out, arbitrary-code escape) are each individually unwritable.

12. TOTAL BRANCHING WITH NO PREDICATE.
ASL's Choice conditions are JSONata expressions; Flyte's are "restricted to specific binary and logical operators ... applicable only to primitive values"; ADK's router is arbitrary Python returning a string. Ours: `branch on ok` where `ok : flag`. There is no predicate, so the arm set is DERIVED FROM THE KIND — stronger than Flyte's totality check, because the arms cannot be miswritten. And the tags are English words for the kind's inhabitants (`yes`/`no`, `approved`/`objected`/`no answer`), so there is no case-label vocabulary to learn.

## refusals

What the surveyed world has that this design deliberately refuses, with the reason for each refusal. Reasons are consequences of the meaning function wherever possible, never taste.

1. DATA-DEPENDENT FAN-OUT WIDTH.
Refused: LangGraph `Send`, Argo `withParam`, ASL `Map` with `ItemsPath`, GitHub Actions `strategy: matrix: ${{ fromJSON(needs.job1.outputs.matrix) }}`, Dify `iteration`, Mastra `.foreach`, Google Cloud Workflows `parallel: for`, Conductor `DYNAMIC_FORK`, Airflow `.expand()`.
REASON: LangGraph's own motivation is the exact negation of our guarantee — `Send` exists because "The number of objects may be unknown ahead of time (meaning the number of edges may not be known)". Airflow's is the same sentence: `.expand()` exists so the author need not "know in advance how many tasks would be needed". Each of these languages keeps BOTH forms side by side under confusingly similar names (`withItems` vs `withParam` differ by four characters and by decidability; literal `matrix` vs `fromJSON` matrix; `Parallel.Branches` vs `Map`). Our panel's member list is literal syntax and there is no computed-collection sibling to slip into by a one-word mistake.

2. UNBOUNDED BACK-EDGES AND MODEL-DECIDED LOOP BOUNDS.
Refused: Scribble `rec X { … continue X; }`, Conductor `DO_WHILE` with a `graaljs` condition, ASL's Choice-with-a-back-edge, Nextflow/Snakemake cycles, LangGraph's `while True: interrupt()`, and Self-Refine's option to "extract a stopping indicator (e.g. a scalar stop score) from the feedback".
REASON: a bound the model chooses is dynamic shape, so the cost tree stops being finite. `at most n revisions` is a literal numeral capped at 64 (maxRevisions, Dsl/Check.lean:353) BECAUSE IT IS THE DEPTH OF THE ELABORATION, not a runtime counter. Formal-LLM is the cautionary case: its termination comes from a one-use-per-tool cap the paper admits "is an external restriction, not something the grammar states".

3. AN EXPRESSION LANGUAGE — no test, comparison, arithmetic, transformation, or name-passing.
Forfeits: ASL's per-arm `Assign` and JSONata conditions, Flyte's `conditional` predicates, Temporal's update validators, lambda_A's `guard e P`, DSPy's `reward_fn`, Inspect's reducer closures, mcp-agent's `min_rating` comparison, Mastra's branch predicates.
REASON: rule 3 (an answer has exactly two destinations, `{x}` in a prompt and `branch on x`) is precisely what makes `dyn` unwritable — `Q c ≅ Q.Shape c × String` with the shape written in the term, so an answer can reach a question's WORDS but never its SHAPE, and `branch on` can reach only a FinEnum with every arm written. It is also what makes "who can see the style guide" a one-line search. lambda_A supplies the corroboration: its `guard` is the ONLY source of stuckness in an otherwise total calculus.

4. A MUTABLE SHARED STORE.
Refused: Flowise `$flow.state`, LangGraph's `State` TypedDict with reducers, CrewAI `self.state`, pydantic-graph `ctx.state`, Mastra `stateSchema`, SGLang's `s`, PDL's background context, Temporal's instance fields, Conductor's global `${ref.output.field}` namespace.
REASON: Flowise states the motive out loud — the store exists to pass data "across branches or non-adjacent steps", i.e. to route around binding. A store breaks sharing-by-binding and makes meaning-as-a-function-of-answer-sheets untrue. n8n is the negative result run to completion: it replaced binding with runtime provenance resolution and its own docs enumerate both failure modes — the thread breaks, or "the thread points to more than one item in the previous node (as it's unclear which one to use)" — with the official remedy being to abandon correspondence and index by position.

5. A MODEL-CHOSEN ADDRESSEE OR ROUTE.
Refused: OpenAI's handoffs-as-tools ("Handoffs are represented as tools to the LLM"), fast-agent's `@fast.router`, LangGraph's `Command(goto=...)`, CrewAI's hierarchical delegation, fast-agent's `@fast.orchestrator(plan_type="full")`, RouteLLM's threshold-in-a-model-name.
REASON: the addressee is part of the question shape and must be term-level data. BAML — the most commercially adopted system in the llm-call family — never lets the model be chosen by a model, which is evidence that authors do not resent a static addressee.

6. WALL-CLOCK DEADLINES AND ANSWER DEFAULTS ON THE CONSENT GATE.
Refused: Airflow's `defaults=` and `response_timeout=`, GitHub Actions' "If a job is not approved within 30 days, it will automatically fail", Conductor's `slaMinutes`, Durable Functions' `Task.WhenAny(waitForEvent, createTimer(deadline))`, AG-UI's `expiresAt`, Google Cloud Workflows' 43200-second callback default.
REASON: both refusals are consequences of the meaning function. A deadline is wall-clock, so it would make meaning depend on something outside Omega and a program would stop being a function from answer-sheets. A default is "the answer when the sheet is silent", and the sheet is TOTAL, so there is no silent entry to default. Where a timeout is genuinely wanted it belongs in the question SHAPE as data the adapter honours, with the lapse arriving as an ANSWER — which is what the verdict's third tag `no answer` already is.

7. A REMAINING-BUDGET COUNTER VISIBLE TO THE PROGRAM.
Refused: LangGraph's `RemainingSteps` ("if remaining <= 2: return {...}"), Pydantic AI's `UsageLimits` inspection.
REASON: exposing the budget makes the program's own SHAPE depend on its COST, which inverts the analysis. LangGraph's docs frame the user's choice as monitoring mid-flight versus catching `GraphRecursionError` — the cleanest available statement of the problem a static cost tree removes.

8. A HEURISTIC RUNG-INFERRING DESUGARER.
Refused: GHC's ApplicativeDo, which "might miss an opportunity", whose optimal algorithm "is expensive: O(n^3)", and where "a strict pattern match in a bind statement prevents ApplicativeDo from transforming that statement".
REASON: a program whose cost is recovered by inference is a program whose cost is not readable from its text, and a syntactically innocuous edit can silently change it. Haxl accepted that trade because its promise was "you never think about performance"; ours is the opposite promise. Amendment 1 is the alternative: the author writes the rung, cheaply.

9. A CAP ON PANEL ARITY.
Refused: Google Cloud Workflows' "Up to 10 branches per parallel step" and "Nesting depth is limited to 2".
REASON: a fact about a scheduler, not about meaning. The doctrine kernel's standing instruction is to suspect every part of the model that exists because computers are finite.

10. A SECOND SPELLING FOR A CASE.
Refused: Airflow's `HITLBranchOperator` fusing consent with branching; Argo's `when:` guards as sibling parallel steps with nothing relating them; `if`/`else` beside `case`; `act` beside `ask`; `revise` beside `revising`.
REASON: this is the defect the entire redesign exists to remove — the incumbent's `Plan.case` wore three unrelated spellings and the owner read the third as replies to the preceding ask, which was the layout's own suggestion (design-digest.md §1). One arm-list shape, met in both places.

11. AMBIENT POLICY MATCHED AT A DISTANCE.
Refused: Inspect AI's `ApprovalPolicy(human_approver(), ["web_browser_click", "web_browser_type*"])`, OpenAI's `@tool(needs_approval=True)`, LangChain's `interrupt_on={...}` middleware table as the ONLY place a gate appears, GitHub Actions' `environment: production` naming a reviewer set configured in repository settings.
REASON: permission belongs to the question, not to the connection or to a settings page. GitHub is the sharpest case: `environment: production` is the most readable gate in the whole survey and it reads well BECAUSE IT SAYS ALMOST NOTHING — you cannot tell from the file whether the job blocks, for how long, or on whom. OpenAI's is worse: because the gate is on the tool DEFINITION, reading the workflow tells you nothing about where the human is consulted.

12. AN UNQUARANTINED ESCAPE HATCH.
Refused: ADK's "dynamic workflows", smolagents' code-as-action, Conductor's `graaljs` in switch and loop conditions, Airflow's arbitrary parse-time Python, LangGraph's arbitrary routing functions.
REASON: Conductor demonstrates that a data representation buys real static structure right up to the first embedded interpreter, and lambda_A measured the consequence at scale. Ours is stronger than a quarantine: the surface has no syntax for `dyn` at all.

13. NON-LOCAL ENABLEMENT.
Refused pre-emptively: anything shaped like YAWL's OR-join — "the system needs to calculate all possible futures from the current state", plus a syntactic exclusion of nested OR-joins just to make the definition well-founded, all hidden behind four characters (`<join code="or"/>`). Concretely this forbids a future `panel, whichever answers first` or `panel, any may approve, then stop asking`.
REASON: once enablement depends on state outside a construct's own subterm, "how many times does this run" stops being a syntactic fold and becomes reachability, and the cost tree stops being computable by structural recursion. This is the same reason BPMN's marking `sigma : E -> N` makes safeness something you must PROVE rather than read off.
