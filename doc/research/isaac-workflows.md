# Isaac's workflows, in agent-cat

> **Execution refinement (2026-08-26).** Read-only/effect authority follows typed
> Plan intent, not answer code: `consult` and `observe` cancel tool permission;
> `effect` grants. This is realization policy over bare-question meaning.
> Historical measurements and comparisons remain.

*The document of record for the owner's question: can `agent-cat` fully support
the workflows Isaac Shapira has built in `~/src/agent-functor` and
`~/src/incite`, and where does it improve on them. Two review passes over those
two trees (read-only), one Express phase that wrote five of his production
workflows in `Agentic.Workflow`, and the plan, cost and scripted-run numbers
those five actually produce. Gaps are ranked by the coverage they cost, each
with a concrete proposal and an honest price; dissents are recorded beside the
proposals they argue against.*

**Sources.** `doc/research/isaac-review/agent-functor.md` (window
`2026-08-11..828043c`, read against the whole 344-commit history) and
`doc/research/isaac-review/incite.md` (window `--since=2026-08-01`, 205 of 217
commits, ending `0cbddad`) — both produced from `git log`/`git show` and file
reads only; nothing in either tree was written, built or executed. Then
`haskell/example/Example/Isaac.hs` (1,702 lines, five programs) and
`haskell/example/Example/Harden.hs`, read at their git-visible state. All
numbers in §3 were produced by running the prebuilt
`dist-newstyle/…/agentic-run` — `plan`, `cost`, and `run --scripted` for each of
the seven registered programs — and every one matched the number its module
haddock claims.

**Two limits on the evidence, stated before it is used.** First, the five Isaac
programs are *not* in the frozen corpus: `tier1` pins `harden` and `hello` and
nothing pins these, by design — they are an experiment about what the language
can express. Second, their prompt bodies are faithful *summaries* of incite's
rubrics, not the rubrics (`haskellOfHouse` is thirty kilobytes there and twelve
lines here). So the leaf counts below are faithful to the *shape* of Isaac's
workflows and not to their byte.

---

## 0. The one-paragraph answer

**Yes for the shape of the work, no for five specific mechanisms, and the five
are worth naming rather than papering over.** All five of the workflows the
review named as representative now exist as `Agentic.Workflow` programs that
plan, price and run: `plan-feature` fully, with no gap named against it;
`review-lite` with three; `grind-tests` with a bound where an unbounded loop
was and a hand-written spread where a list comprehension was;
`ship-feature-lite` with four, which is why it is the most valuable of the
five; and `stack-prs` partially — and the concessions are the finding, not the
failure. What carries without argument is more than expected: a rubric plus an
artefact is a two-chunk prompt; derived rosters (`qaOfCommitOver`,
`grindSynthesisOver`) are ordinary Haskell and arrive in the brief by being
added, exactly as they do there; `GrindSpec`, which the catalog calls the best
structural idea in the repository, is *pure Haskell reuse* and this surface
supports it as well as `agent-functor` does; and "who answers" is said per
question rather than by wrapping a scope, which deletes the nine site-by-site
arguments incite has to carry about which leaves may inherit `--backend`.
What does not carry is five things: a **branch is terminal**, so a conditional
lens cannot rejoin its siblings — `review-lite`'s two arms now end by calling
one function rather than by rejoining (wave 2's D1; before it, the tail was
spelled twice);
**an answer is a handle, not a value**, so every pure decider Isaac spends
nothing on — `tripEnding`, `isRed`, `diffNamesHaskell`, `decideFactsResolved` —
becomes a paid leaf here; **a check is a question, never an exit code**, so
`greenGate` is written as `agentVerify` and labelled as such rather than
dressed as the thing it is not; **`Unsettled` carries nothing**, which is the
sharpest of the five — the whole designed trade of the `lite` tier is that
exhaustion *yields*, the tree keeps every edit the capped trips made and the
panel reads the summary that asked for one more, and here the exhausted arm has
no handle to reach that work with, so the only arm that can be written is
`stop`; and **there is no sub-flow in the authoring surface**, so incite's
central discipline — that `reviewLiteFlow` is one binding three workflows
cannot drift from — holds for the *questions* and not for a run of statements.
Those five are G1–G5, the head of the ranked list in §4; the five below them
cost convenience, reach or nothing at all, and G9 — that an unbounded loop
cannot be written — we think Isaac's own numbers vindicate. Where agent-cat
improves is narrower than a pitch would claim and sharper than a concession:
it **prices a branching program before running it**
(`ship-feature-lite` is 4..24 over 36 paths, where incite's docs quote one
fenced number for the one workflow that has one, and `4611686018427387927`
for the ones that do not); its folds are **ported from a Lean kernel and pinned
against a frozen corpus** by tier0, tier1 and a live differential, where
agent-functor's laws are HSpec bundles with no oracle behind them (the
docstrings' *line* citations are a separate matter, and 57 of them are
currently stale — see I2); **read-only is structural rather than scoped** —
permission is decided by the answer code, so a reviewer is read-only
because it does not `act`, not because someone remembered to wrap it in
`withMode Plan`; and the **terminal branch turns `completionGate` — a stage
incite had to add after a four-hour run ended badly — into an arm of a total
`case` that the author cannot forget to write** — which is the same decision
that costs us the yielding ending above, and the trade should be read in both
directions rather than banked once. The honest summary is that agent-cat can
express Isaac's workflows as *programs* today, and cannot yet express his
*runner*: the failure vocabulary of §3.1–3.3 of the agent-functor review is
knowledge we have not had to buy, and none of it is in this language or its
Exec policy.

---

## 1. The two projects, in brief, and the window reviewed

**`agent-functor`** (Isaac Shapira, GitLab `fresheyeball/agent-functor`, BSD-3,
v0.2.0.0) is a workflow *runner* with an unusually principled algebra bolted to
the front of it. The algebra is `Flow i o`: a profunctor optic with
`Category`/`Strong`/`Choice`/`Traversing`, **deliberately no `arr` and no
`Monad`**, which is what makes its smart constructors normalise on the nose and
skeleton equality mean something. Three effect leaves — `Prompt`, `Exec`, `Ask`
— map almost exactly onto agent-cat's three addressees. Every dynamic construct
carries a mandatory `Bound`, which is the premise its whole cost story rests on.
The whole repository is eighteen days old (344 commits, 2026-08-01 → 2026-08-18);
the reviewed window is `2026-08-11..HEAD`, where the character of the work
changes from "add the layer" to "the layer met a real backend and lost a
twenty-leaf fan-out, so the *policy* has to change". One structural fact shapes
everything: `src/Agent/Run.hs` is 5,266 lines, 29% of the tree, and the only
module that changed in fifteen of the last twenty commits. The algebra is small
and finished; the runner is where the design pressure is. Roughly a third of the
exported API (`Heads`, `Keyed`, `Reducer`, `Expert`/`Router`, `Position`) is a
designed surface awaiting its caller, and Isaac marks every one of them "Pure
core, IO wiring pending (Mnn)" in the haddock — exemplary discipline, and it
means the concept map overstates what runs.

**`incite`** (GitLab `fresheyeball/incite`) is his prompt repository with a
Haskell workflow package bolted to it: one tree holding two inventories with
different lifecycles. The first is `flake.nix`'s `prompts` list, a declarative
Nix manifest that renders agents, skills and slash commands into `~/.claude` and
`~/.codex`. The second is `workflows/Main.hs`'s fifteen typed `Workflow` values,
served as both CLI subcommands and MCP tools by `passMain`, *which read the same
markdown files the first inventory deploys* — `[promptFile|commands/fess.md|]`
is checked at compile time against the package root and read at run time against
the cwd, so the rubric a sub-agent gets deployed and the rubric a workflow leaf
sends are one file. It depends on `base`, `text` and `agent-functor` and nothing
else; `test/Spec.hs` adds 250 cases that *fence* claims the prose makes. The
Haskell layer is entirely inside the reviewed window: it begins at `a096f13`
(2026-08-02) and the four-module split lands 2026-08-06. Everything reviewed is
new work, not archaeology. TUI was skipped in both trees, per the brief.

The two are not competing on the same axis, and this document tries not to
pretend otherwise. **agent-functor is a runner with a semantics in front of it;
agent-cat is a semantics with a runner growing out of the back.**

---

## 2. The workflow catalog, merged and deduplicated

Isaac's *concrete* workflows live in incite; agent-functor ships the shape
library they are built from plus five diagnostics. Merged, deduplicated, and
ordered by what each one is *for*:

### 2.1 Prompt-only (nothing is written, no gate, no human)

| Workflow | Home | Shape | Leaves |
|---|---|---|---:|
| `plan-feature` | incite | `explorePlan >>> editPlan` — four read-only stances (intrepid/skeptic/contemplative/architect, each pinned to its own backend) reduced by `hierarchical` into a planner, then six *sequential rewrites of one text* (ponytail, denotational, risk, verification, lookahead, simple-english), deliberately unpinned so all six stay comparable | 10 |
| `review-lite` | incite | six independent reviewers over one commit, one wave, **pure fold, no synthesis leaf**; one reviewer behind a cheap one-word router | 7 |
| `review-heavy` | incite | 8 lenses × 3 backends over the full diff, plus two *regrouped views* on claude alone, plus one synthesis | 43 |
| `review-audit` | incite | 9 lenses × 3 backends × three granularities (full / logical units / ideal commit sequence), then synthesis | 84 |
| `review-docs` | incite | 5 prose lenses × 3 backends less one forbidden pairing, then synthesis | 15 |
| `prompt-lint` | incite | one ASD-STE100 CHECK pass, scope widened to Haskell string literals | 1 |
| `review-revise`, `hetero-probe`, `plan-probe`, `race-probe`, `probe-acp` | agent-functor | the five diagnostics: a tutorial two-leaf refine/revise; a three-stance heterogeneous fan-out on three backends; a plan-mode-then-edit gate; best-of-N in real git worktrees; and an ACP wire experiment | 2–5 |

### 2.2 Acting (a worker loop, a gate, and something is written)

| Workflow | Home | Shape | Bound |
|---|---|---|---|
| `ship-feature` | incite | `explorePlan >>> editPlan >>> steer >>> orchestrate >>> completionGate >>> review-heavy >>> remediate >>> greenGate >>> retrospective >>> humanGate >>> submitPR` | worker loop **unbounded** |
| `ship-feature-lite` | incite | `planLeaf >>> steer >>> orchestrateWith (Fuel 3) >>> review-lite >>> remediate >>> greenGate` — ends on the gate, no PR, deliberately | **21 leaves, fenced** |
| `ship-docs` | incite | the same shape at prose: `docsPlanLenses`, worker `document`, `docsRule` ("correct the DOCUMENT, never edit code to make a sentence true"), no gate, no PR | unbounded |
| `grind-paradox` / `grind-tests` / `grind-live-view` | incite | one `grindFlow (GrindSpec …)`: a **spread** (14/12/11 lenses zipped against `cycle backends` — coverage, not agreement) → a synthesis that **refuses** on a short roster → a facts gate → an unbounded fixer loop; `grind-tests` alone adds `review-audit` over the fixer's own change plus a second fixer at `Fuel 12` | unbounded, then capped |
| `stack-prs` | incite | the richest: `explorePlan >>> slice >>> steer >>> humanGate >>> bootstrap >>> cut-loop >>> stackGate >>> review-heavy >>> remediate-loop >>> triage-loop >>> stackGate >>> humanGate >>> consentGate >>> promote-loop` | four loops at `Fuel 12` |

### 2.3 The shared machinery both trees rely on

`explorePlan`, `editPlan`, `orchestrate`/`orchestrateWith`, `completionGate`,
`checkLoop`/`greenGate`, `remediate`, `Orientation` (incite);
`refineWith`, `exploreWith`/`exploreFlows`, `mergeWith`, `raceWorkers`,
`lensEdit`, `partitionReview`, `reviewScales`, the reducers
(`sourceBlock`/`unionFindings`/`hierarchical`), `execStep`/`verify`/
`agentVerify`, `commit`/`submitPR`, `humanGate`, `steer`, `workLoop`
(agent-functor).

Three of these are load-bearing everywhere and are worth stating once:

- **`orchestrate`** feeds a worker *its own previous summary* and classifies the
  summary's last non-empty line four ways — `WORK COMPLETE` ends, `WORK BLOCKED`
  ends and is passed through verbatim, `WORK REMAINS` buys another trip, and
  anything else is a **protocol violation**: re-prompt with a nudge, at most
  twice per run, and *a violation spends no trip fuel*. Exhaustion **yields**,
  never aborts — the tree keeps its edits. The budget is a record threaded
  *beside* the carrier so the worker only ever sees its own summary.
- **`greenGate`/`verify`** is the harness running argv itself and reading the
  kernel's exit code — "the one statement in this workflow that no agent
  authors". Red buys three repair trips and then **aborts**, the opposite
  polarity to `orchestrate`, argued for at both sites. `agentVerify` is the same
  checks *asked of the agent*, and having both under two honest names is the
  point.
- **`steer`** is a checkpoint whose *answer is the revised artefact*, not a
  yes/no gate. Isaac's version asks for **the acceptance bar this change must
  clear**, not "any guidance", because an empty submit answers the second
  honestly in four seconds.

### 2.4 The two workflows that are the honest boundary

`pr-review` and `pr-address` (skills, not `Flow` values) discover their queue at
run time: `pr-address` derives the whole forest of open PRs from one `gh pr
list` by chaining `base → head` edges, orders one queue downstack-first because
a lower fix can moot an upstack comment, and walks it stopping for a verdict at
each item. Nothing in a statically priced language can hold that, and the review
recommends they stay a documented limit rather than a target. This document
agrees; see G8.

---

## 3. What agent-cat expresses today

Five programs, in `haskell/example/Example/Isaac.hs`, registered through
`Example.Harden.examples` and reachable from `agentic-run` as ordinary examples.
Every number below was produced by running the binary, not read off a comment;
each matched its haddock exactly.

| Program | level | size | askNodes | cost (min/max/paths) | `run --scripted` |
|---|---|---:|---:|---|---|
| `plan-feature` | pipeline | 14 | 13 | 13 / 13 / **1 path** | billFresh 13, billMemo 13, exit 0 |
| `review-lite` | branch | 12 | 9 | 7 / 8 / **2 paths** | billFresh 8, billMemo 8, exit 0 |
| `ship-feature-lite` | branch | 149 | 78 | 4 / 24 / **36 paths** | billFresh 12, billMemo 12, exit 0 |
| `grind-tests` | branch | 144 | 73 | 9 / 27 / **36 paths** | billFresh 15, billMemo 15, exit 0 |
| `stack-prs` | branch | 155 | 70 | 4 / 24 / **43 paths** | billFresh 16, **billMemo 15**, exit 0 |

(For reference, the two pinned examples: `harden` is branch/36/19, 5..15 over 9
paths; `hello` is pipeline/4/3, one path at 3, `codes [text, text, receipt]`.)

Every number in this table is now pinned by `haskell/ci/examples.sh`, which runs
`plan`, `cost` and `run --scripted` over all seven registered programs on every
commit and fails on any field that moves — the D10 regression pin, so this
section can no longer go quietly stale against the binary.

**Finding 3.1 — `plan-feature` is expressed fully, and it is the cleanest
result in the phase.** Four stances, four serving models named on the four
questions; a planner; six sequential lenses that carry no `servedBy`, which is
exactly what `editPlan`'s "deliberately unpinned so all six stay comparable"
asks for. It is `level pipeline`, one path, and `codes` is a full sequence —
twelve text answers and a receipt. incite's ten leaves become thirteen here, and
the three extra are honestly accounted: one tool fetches the request (G7), and
the plan is written by an `act` where incite's CLI hands back text. The one loss
is not a leaf: `hierarchical ["skeptic","architect","contemplative","intrepid"]`
is a *list* there, which a test can assert against; here the narrowing order is
the order of the holes in the planner's prompt, which is the same order, one
fewer moving part, and one fewer thing a test can read.

**Finding 3.2 — `review-lite` was expressed with its tail duplicated, and the
duplication was exact rather than approximate; wave 2's function call removed
it.** Five reviewers, then a `confirm` router pinned to the cheapest model, then
a two-armed `if` in which each arm writes the report — with the Haskell block in
one and the literal `"No Haskell edits."` in the other, which is
`routeHaskell`'s `Right` arm verbatim. That tail was written out once per arm
until D1 landed; it is now one `review-lite.report` function both arms call, and
a call costs what writing the callee's statements at the call site costs, so the
numbers did not move for it — see `ci/examples.sh`'s `review-lite` row, which
shows the arithmetic. Eight leaves against incite's published seven; the one
extra is the fold, which is a paid `act` here and a pure `hierarchical` there
(G3) — the subject fetch that used to be the second extra is now an input (D8),
and a define leaves no node behind. `costSummary` says 7..8 over 2 paths, which
is the router's two outcomes priced apart — a thing incite cannot say at all.

**Finding 3.3 — `ship-feature-lite` is the most valuable of the five, because it
is the one that forces four gaps at once.** It puts a **person in the middle**:
`bar <- ask (person "operator")` is `steer`, and its answer is live for the rest
of the run and spliced into every worker prompt — the first example in this
repository of a person in binding position rather than a `confirm` at the end.
The worker loop is `revising drafted (atMost 3)`, the panel is
`panel (reviewPanelOver account)`, and the green gate is a second `revising`
whose `Unsettled` arm is `stop` — abort-on-exhaustion, which is `checkLoop`'s
polarity exactly. `costSummary` reports **4..24 over 36 paths** against incite's
single fenced 21.

**Finding 3.4 — `grind-tests` carries `GrindSpec` over completely, which was the
open question.** `grindLensRoster` is the table; `grindLens` derives each lens's
brief from its row; `grindSynthesisBrief` derives *the roster it will refuse on*
from the same table. A lens added to the table arrives in its own brief and in
the synthesis's roster by being added, exactly as `gsLenses` does — and this is
ordinary Haskell, needing nothing from the language. It is better in one
respect: `spread` zips the table against `cycle backends`, so *position* picks
the model and `gsPins` exists to state the one assignment that is policy; here
the serving model is named on the question, every assignment is a pin, and
reordering the table changes nothing. Expressed at six lenses instead of twelve
(G8) and with the unbounded fixer loop given `atMost 4` (G9, which is a
feature).

**Finding 3.5 — `stack-prs` is expressed partially, and the partial expression
is more useful than a total one would have been.** Both human gates land as
`confirm (person "operator")` with a two-armed `if` whose else arm is `stop` —
`humanGate`'s halt exactly, and without `humanGate`'s `error`. The consent gate
is `confirm (tool "consent")`, which reads *better* than incite's spelling: the
workflow says who is asked, and a file is not a person. Two of the four loops
are written and two are single questions; the budget gate has nowhere to stand
(G6). Its scripted run is the most interesting number in the table:
**billFresh 16, billMemo 15** — the two orchestrator questions, one in the cut
loop and one in the triage loop, are the same prompt over the same carrier when
nothing amended in between, so the second is a memo hit and costs nothing. That
is content addressing arriving at the same answer `leafKey` does, from a
different direction.

**Finding 3.6 — questions share; statements do not.** `reviewPanelOver ::
(KnownIx h s) => V h 'CodeText -> [Ask s]` is an ordinary Haskell function from
a live handle to a list of `Ask`s, applicable at any scope where the handle is
live. It is used by `ship-feature-lite` and `stack-prs` both. That is half of
incite's central discipline; the other half — *a run of statements* shared as
one binding — is G2.

---

## 4. The gaps, ranked by the coverage they cost

Ranked by how much of Isaac's inventory each one puts out of reach, not by how
hard it is to fix. Each carries a proposal and an honest price.

### G1. A branch is terminal, so a conditional stage cannot rejoin
*Bites: `review-lite`, and every panel with a router in it.*

Every arm of an `if` **is** the rest of the workflow. So a lens that runs
conditionally and then rejoins its five siblings cannot be written; what is
written is the same program with the closing act spelled twice. That is exact
for one router. It does not survive width: a workflow with three independent
routers needs eight copies of its tail, and incite's `review-heavy` has two
regrouped views on top of eight lenses.

**Proposal (cheap, recommended first).** Do not change the branch — change what
an arm can contain. `Agentic.Builder` already exports `function`, `Params`,
`callStmt` and `callV` (Builder.hs:112/116/138/751/975), the Lean checker
already prices calls through the stratified function table (Guards.hs:92–130),
and the **frozen corpus already holds three call cases** —
`module-000-an-import-a-dotted-call-a-dotted-define-in-a-hole`,
`battery-144-a-statement-call-of-a-procedure`, and
`battery-147-a-function-may-answer-a-flag-the-caller-branches`. With calls in
the authoring surface, a duplicated tail is *one line per arm* rather than a
copy of the tail, and it cannot drift between arms because it is one definition.

**Proposal (expensive, defer).** A *joining* conditional at expression position
— a branch that binds one handle whose value comes from either arm. This is a
new Raw node, a new clause in `Check.lean`'s classifier, a new clause in
`Explain.lean`'s cost fold (the path set at that point *multiplies* rather than
partitions), and a refreeze of tier0/tier1/bisim.

**Dissent, recorded.** The terminal branch is what makes `codes` a total
sequence on a non-branching program and what keeps the path enumeration finite
and printable — `stack-prs` prints all 43 of its paths. A joining conditional
buys back duplication at the price of the one report an operator actually reads
before spending money. The duplication may simply be the price of a printable
path set, and G1's cheap proposal may be the whole of the right answer.

**Honest cost.** Cheap proposal: the largest *surface-only* change on this list
— a `W`-level definition form and a `workflow` that elaborates at a non-empty
function table, with the type-level `Params`/`Args` threading as the hard half.
No oracle change, no corpus refreeze, and tier1 gains coverage of three frozen
cases the authoring surface cannot currently reach. Expensive proposal: a kernel
change plus a full refreeze.

### G2. No sub-flow in the authoring surface
*Bites: `ship-feature-lite`, and incite's central discipline.*

`reviewLiteFlow` is one binding used by `review-lite`, `ship-feature` and
`ship-feature-lite` alike, and incite's stated discipline is that workflows
cannot drift in anything they share. Here `reviewLiteProgram` binds its five
reviewers one at a time and `shipFeatureLiteProgram` panels them, and the two
spellings of one tier are held together only by the prompt library they both
read.

**Proposal.** The same one as G1's cheap half: expose `function`/`callStmt`/
`callV` through `Agentic.Workflow`. G1 and G2 are one change with two payoffs,
which is why they sit adjacent.

**Honest cost.** As G1 cheap. This is the highest value-per-line item on the
list and the only one with *zero* oracle exposure.

### G3. An answer is a handle, not a value — no pure decider
*Bites: `review-lite`, `ship-feature-lite`, `grind-tests`, `stack-prs`.*

No Haskell function may look at an answer. So every pure decider incite spends
nothing on becomes a paid leaf: `tripEnding` (the worker's last line, classified
four ways) is an orchestrator question in *every* loop; `isRed` is inside
`greenGateBrief`; `decideFactsResolved` is `factsGateBrief`; `diffNamesHaskell`
— the pure scan of diff *header* lines that **overrules a well-formed wrong
`none`** — has nowhere to stand at all and is simply dropped, which is a real
safety property lost, not a leaf.

A second casualty is the *loud default*. `routeHaskell` runs the expensive lens
on any answer that is not a clean `none`, so a chatty or malformed router reply
costs money rather than skipping a review. Here an unreadable flag is re-asked
once with a `nudge` and then **abandons the run** (`Exec.defaultRetries = 1`).
There is no vocabulary for "an answer I could not read means take the safe arm".

**Proposal (recommended).** A **closed vocabulary of four deciders**, named in
the kernel and held identically in Lean and Haskell:
`lastNonEmptyLineIs`, `containsLine`, `anyLineStartsWith`, `anyPathMatches`.
Those four cover `tripEnding`, `isRed`, `decideFactsResolved` and
`diffNamesHaskell` — which is every pure decider in incite. A decider yields a
flag or a verdict, so the branch structure stays exactly as static as it is now
and `costSummary` is unchanged.

**Proposal (separately, and cheap).** Make the flag decode policy a *stated
choice* rather than a silence: an unreadable flag takes the loud arm instead of
abandoning the run. That is an `Agentic.Exec` change, no kernel work.

**Dissent, recorded.** Every decider added is a second language the Lean oracle
must also hold and bisim must also check, and four will not stay four. Isaac's
own `Op` haddock states the discipline this argues for — "if you are tempted to
add a fourth `Op`, check first whether it is a `Prompt`" — and the parallel
reading is that a classification *is* a question and should be paid for. The
counter-argument is `diffNamesHaskell` specifically: it exists precisely because
the model's answer cannot be trusted, so making it a question defeats it.

**Honest cost.** Four constructors in `Raw`, four total functions in both
`Explain.lean` and `Agentic.Text`, new corpus fixtures, no refreeze of existing
entries. Medium, and it is the only item on this list that adds semantics rather
than surface.

### G4. A check is a question, never an exit code
*Bites: `ship-feature-lite`, `grind-tests`, `stack-prs`.*

`greenGate` is the load-bearing idea of Isaac's whole acting half, and the
2026-08-12 retrospective that produced it is the best single piece of evidence
in his repository: a four-hour `ship-feature` run ended in a "no" at the PR gate
because the fixer's closing test counts existed only in its own summary. `act`
returns a receipt the *answerer* authored; nothing in this language distinguishes
"the tool says it ran" from "the harness ran it and the kernel returned 0".
`Example.Isaac` writes `agentVerify` and says so in `greenGateBrief`'s haddock,
which is the right way to be wrong.

**Proposal (recommended).** Not a fifth answer code — an **Exec policy**. A
`tool` party may carry a program-authored argv, and the *World*, not the
answerer, authors its receipt. The program still reads `act (tool …)` returning
an ack; what changes is who the `WorldIO` consults. The kernel's factorization
theorem (`runPlanIO (pureWorldIO w) p == pure (runPlan w p, trace w p)`,
`Exec.lean:654`) survives untouched, because a shell world is just another
world, and `--scripted` keeps answering it from the table.

**Note in agent-cat's favour, and it is a real one.** The argv here would be
authored *in the program*, which is the value tier1 pins — not by the agent
mid-turn. agent-functor needs `Grant`, a deny-by-default path/command lattice
with an admitted symlink-escape residual, precisely because its argv can come
from somewhere else. We would not.

**Dissent, recorded.** A fair reading of this project is that agent-cat models
the *dialogue* and a shell gate is the caller's business. Adopting this puts a
process spawn inside the semantics' runner, and the review's own words apply:
whichever way it goes, **it should be a decision and not a silence**.

**Honest cost.** Moderate. `Agentic.Exec`/`Agentic.World` gain a world that
executes; `Raw` gains an argv field on a tool party, which *does* change the
printed program and therefore touches the corpus for any entry that uses it
(none today — new fixtures only). No change to `costSummary`, `level` or the
guards.

### G5. `Unsettled` carries nothing
*Bites: `ship-feature-lite` — and it is the sharpest single gap in the phase.*

The whole designed trade of the `lite` tier is that exhaustion **yields**: the
tree keeps every edit the three trips made, and the last summary — the one that
asked for a fourth trip — is what the panel reads. Here the unsettled arm has no
handle to the candidate the loop had in hand, so the only arm that can be
written is `stop`. Exhaustion is an abort and three trips' work reaches nothing.

**Proposal.** `Unsettled (V (An c ': s) c)` — the candidate in hand. agent-cat
is *already ahead* here in principle: agent-functor's `loopUntil` haddock
concedes it cannot offer a yield policy because at its type the loop holds an
`a` and owes a `b`, and our `Outcome` fork exists exactly to hand the author
both endings. It simply does not hand over the goods.

**Proposal (variant, to avoid a refreeze).** Ship it as a second combinator —
`revisingYielding` — leaving `revising` and every frozen entry that uses it
byte-identical, at the price of two combinators where one would do.

**Dissent, recorded.** The current shape's forced `Unsettled -> stop` **is**
`completionGate` for free, and incite had to *add* `completionGate` after a run
died — "a block or a spent violation budget must not buy a review panel and a
pull request gate". A yielding arm re-opens exactly that. The answer is that the
author still writes the arm, because the `case` is still total; only the data is
added. That is a good answer and it is not a free one.

**Honest cost.** Small and local, but it is *kernel*: the unsettled arm gains a
binder, which changes the printed program of every corpus entry with a
`revising` — a refreeze — unless taken as the variant.

### G6. A bounded revision has one bound, one clause pair, and only `approve` settles
*Bites: `ship-feature-lite`, `grind-tests`, `stack-prs`.*

Three distinct losses, and the near-miss is exact. `caseVerdict`'s three arms —
approved / objected / **no answer** — are `WORK COMPLETE` / `WORK REMAINS` /
protocol violation, precisely. But the review clause's verdict is consumed by
the loop, so inside a revision they cannot be told apart: `WORK BLOCKED` buys
another trip where it should end the run, and a missing status line spends fuel
where it should spend none. `TripBudget` threads *two* budgets beside the
carrier; a revision carries one artefact and one bound. And `budgetGate >>>
stackWorker "promote"` re-runs `./ci-budget.sh --wait` before **every trip** —
"a clearance read once and reused is a clearance about a queue that has changed"
— where a revision's body is exactly one review and one amendment, and the
grammar refuses a third statement and says so.

**Proposal.** Let the loop's fork read the review's verdict: a `revisingOn` in
which the three verdict tags map to *settle / amend / abandon*, and a fourth
ending (`BLOCKED`) is one more tag on the same mechanism. The per-trip gate is
then the review clause's first statement, which the grammar would have to admit.

**Honest cost.** Highest on this list. A three-way exit gives every round of the
unroll an extra exit edge, which changes the path count and therefore
`costSummary` on **every existing corpus entry that has a `revising`** —
including `harden`, the flagship. A refreeze of tier0/tier1/bisim, and a
re-derivation of the fold in `Explain.lean`. Ship it as a variant combinator if
it ships at all.

### G7. A program has no input
*Bites: all five.*

Every one of these opens by asking a tool for its subject, where incite's
`workflowReq` demands one at the CLI. It costs a leaf in each program, and it
changes the meaning: the operator's text reaches incite's first leaf as *data*
and reaches this one as an *answer*.

**Proposal.** `main` is a function of its arguments — the same `Params`
machinery as G1/G2, plus `agentic-run run X --input FILE`.

**Honest cost.** Low *if* G1/G2 land; it is the same mechanism. Standalone it is
not worth doing.

### G8. A fan-out is a static list of statements
*Bites: `grind-tests`, and every review tier above `lite`.*

`panel` takes a list, but it folds in the verdict monoid: its members' answers
are not individually spliceable, and a grind's synthesis needs them one block at
a time. So a *spread* is written out by hand — six statements where incite
writes one list comprehension over `(lens, backend)` pairs. Its `review-audit`
tier is 84 leaves, which is 84 statements here. Each bind's scope index is one
entry longer than the last, so a list-driven fold of binds is not directly
typeable.

**Proposal.** `panelText :: [Ask s] -> Rhs s 'CodeText` — a fan-out whose fold
is a *document*: each member's answer fenced under its own name. Use Isaac's own
answer for the fence, and for his reason: a **tag pair, not a `## heading`**,
because bodies emit their own headings and a heading marks a start with nothing
marking the end, and a tag pair nests when a fan of fans is unioned. The monoid
is the free monoid over fenced blocks in member order — associative,
non-commutative, which matches the verdict monoid's own shape. Cost per member
is one question, identical to `panel`, so `costSummary` is unchanged in form.

**Honest cost.** Medium: one new `Rhs` shape, one new fold clause in
`Explain.lean`, one in `Check.lean`'s `rhsPlan`/`rhsAsks`, new fixtures, no
refreeze. This is the highest expressiveness-per-cost item after G1/G2.

### G9. Unbounded is not expressible — and this one is a feature
*Bites: `grind-tests`, `ship-feature`, `ship-docs`.*

`Dynamic` is a rung `Agentic.Builder` cannot construct, so `orchestrate` with
`workerFuel = Nothing` becomes `atMost 4` and the workflow is honestly a
different one. **Isaac's own numbers are the evidence that this is the right
refusal.** `agent-functor` compiles an unbounded loop to
`loopUntil (maxBound \`div\` 2)`, and the recorded price of `cost grind-paradox`
is `4611686018427387927` worst-case leaf executions — a nineteen-digit sentinel
the repository's own documentation calls a number "no operator can read anything
from". `stackFuel`, `liteFuel`, `grindTestsReviewFuel`, `repairFuel` and
`budgetFuel` were every one of them introduced afterwards as named finite
constants and fenced as such. That is the same lesson arrived at from the other
side, and this paragraph — his number included — is where agent-cat's
documentation records it.

**Adopted (D10, second half).** No language change, now or later: refusing the
unbounded case is the language's position and not a gap awaiting a fix, and
`4611686018427387927` is the evidence on the record for it. What a bounded
program costs is a number an operator can read, and `ci/examples.sh` pins
`grind-tests`'s 9..27 over 36 paths on every commit — the bound is checked, not
merely asserted.

### G10. Runner-side gaps, listed and not proposed
*Bites: everything, eventually.*

Four things agent-functor has that agent-cat has never had to build, recorded so
that nobody rediscovers them the expensive way:

- **A failure vocabulary.** `TurnGap` = `TurnFailed | TurnEmpty | TurnExhausted`
  — named by what the backend *said*, never by what we will do, and
  `TurnExhausted` is separate only because it is **wire-tagged**
  (`data.errorKind == "rate_limit"`), never inferred from prose. Per-gap re-ask
  budgets are pure and small: 2 for a failure, **exactly 1** for empty ("a
  backend answering empty twice is not flaky"), **zero** for exhausted. Then
  `Recover = RecoverAsk -> IO Recovery` with `RetryHere | FailOver | Abandon`,
  because there are exactly three things the operator knows that the runner does
  not. Unattended runs get a *standing answer* the flow author wrote before the
  run started, and **never retry**. agent-cat's entire failure policy today is
  `defaultRetries = 1` and then an error that stops the run.
- **Survive-one-bad-leaf as a decision, not a mode.** One flaky `end_turn` in a
  21-leaf review panel discarded twenty in-flight paid turns, twice. The fix was
  not a `failFast` flag: `parList` is unchanged, and the policy moved to *who is
  allowed to decide*.
- **Model fail-over as a property of the scope.** `fallingBackTo` — every entry
  preflighted and given its own connection up front, so a fallback this install
  cannot serve is an error before anything is spent.
- **Cross-run persistence.** A content-addressed run store, `resume`, and
  `fork --at / --reroll / --set`, with "no dependency cone; content addressing
  *is* the invalidation" as the stated property. Our memo table is the same
  idea, one run wide.

Two smaller ones, for completeness: there is no `withCapturedTranscript`
analogue (a workflow whose input is the *calling* session — `fess-audit` and
`retro` need it), and no scope wrapper in which to place a `stackPin`, so a
leaf added later without `servedBy` is a leaf nothing catches. The second wants
agent-cat's own idiom rather than agent-functor's: a program-level **guard** that
refuses a program in which any ask under it fails to name a serving model, in the
family of `PanelEmpty`, `RevisionBound` and `ServedBy` that `Agentic.Guards`
already holds.

---

## 5. Where agent-cat improves on the originals

Stated fairly. Three of these are large, three are small, and one is a tie that
should not be claimed as a win.

**I1. It prices a branching program before running it.** `costSummary` returns
cheapest bill, dearest bill, and **number of paths**. `ship-feature-lite` is
**4..24 over 36 paths**; `stack-prs` is 4..24 over 43; `review-lite` is 7..8
over 2, which is the router's two outcomes priced apart. `worstCaseCost` is one
number, and a `Choice` node sums both arms because a static fold cannot know
which is taken. incite's `docs/workflows.md` quotes *one* finite number for
*one* workflow — `ship-feature-lite`'s 21 leaves — and `test/Spec.hs` reads it
out of the prose and checks it, which is excellent practice on a number that
exists for exactly one tier. Every other workflow in that repository is priced
at a sentinel. This is the clearest improvement and it is the one an operator
feels first.

**I2. The folds are kernel-checked, and the two walked examples are pinned.**
`Agentic.Guards` carries `Check.lean:519` and `:874` for the revision and
question bounds — `maxRevisions := 64` and `maxQuestions := 4096`, both exact
at those lines today. tier0/tier1/bisim hold the printed program and the whole
reply against a frozen corpus, and that — not the citations — is what makes the
folds checked: 128/128, 21/21, and a live differential against the oracle.
agent-functor's laws are HSpec bundles — real ones, and `Category` holding
*structurally* because there is no `arr` is a genuinely good property — but
there is no oracle, and when `worstCaseCost` and the interpreter disagree only a
test catches it. **The honest qualification: the five programs in §3 are not
pinned.** They are an experiment, and the numbers in this document are evidence
about the language, not conformance results.

**A second qualification, and it is a live defect rather than a limit of the
experiment.** The line citations themselves have drifted. The retirement
commit (`75c277c`, "The language retires; the spine remains") deleted
`Agentic/Core/Acp.lean`, `Agentic/Core/Rpc.lean` and `test/AcpSmoke.lean`
outright and cut 584 lines from `Exec.lean` and 132 from `Explain.lean`,
without re-deriving the citations the Haskell docstrings carry. Of the 220
Lean citations in `haskell/`, **57 now name a file that does not exist or a
line past its end** — 46 in `Agentic.Acp`, 6 in `Agentic.Exec`, 4 in
`Agentic.AgentDeck`, 1 in `Agentic.Plan` — and the surviving 163 are not all
sound either: `Exec.hs` cites `Exec.lean:626`/`:654` for `pureOracle` and the
factorization theorem, which now sit at `:619`/`:647`, and `Acp.hs` cites
`Exec.lean:925` for `permissionByCode`, a definition that no longer exists in
that file at all while `:925` still resolves — to an unrelated retry loop.
`costSummary` is at `Explain.lean:452`, not the `:552` this document quoted in
an earlier draft.
The claim that the folds are kernel-checked survives, because tier0/tier1/bisim
are what check them; the claim that they are *cited* does not, and the
citations should be re-derived or dropped before this document is used as
evidence for either.

**I3. Read-only is structural, not scoped.** Permission is decided by the answer
code — `permissionByCode CodeAck _ = Grant; permissionByCode _ _ = Cancel`
(`Acp.hs:629`; its `Exec.lean:925` citation is one of the stale ones I2
records) — so a reviewer is read-only *because it does
not `act`*, and a draft turn cannot write with the same authority as a consented
one. incite gets there by a scope: `Incite.Backend.reviewer` is
`withMode Plan`, applied by a smart constructor so that no reviewer can acquire
write access. That works and it is one forgotten wrapper away from not working;
here there is no wrapper to forget. The haddock is explicit that a
connection-wide grant is the defect this replaces, with
`test/stub_adapter.py --write-on-ask` as its negative control.

**I4. The terminal branch makes `completionGate` an arm nobody can forget.**
incite had to *add* `completionGate` — a pure `error` that halts the run unless
the loop's yield declares `WORK COMPLETE` — after a run in which a block bought
a review panel and a pull-request gate it should not have. Here that gate is the
`Unsettled -> stop` arm of a total `case`, and the author cannot omit it because
the compiler will not let them. This is the terminal-branching discipline
earning its keep on a real workflow rather than on an example. It is also, note,
the same discipline that costs us G1 and G5; the trade is visible in both
directions and the same design decision pays and charges.

**I5. Who answers is a property of the question.** incite carries nine leaves
with a pin and a paragraph defending it, and `editPlan` carries a paragraph
defending the *absence* of one, because a scope wrapper means every leaf under
it inherits and the argument is site by site. Here the pin is
`` `servedBy` "fable" `` on the question and the deliberate absence of a pin is
the absence of the words. `plan-feature`'s six lenses carry none, which is the
whole of what `editPlan`'s paragraph asks for, written by not writing it.
**Fairly: this is a trade, not a rout.** The scope wrapper is what gives
`stackPin` its guarantee over a whole subtree, and we have no equivalent (G10).

**I6. The addressee is in the program, so a gate says who is asked.** The
consent gate — `test -f .stack-promote-approved`, which exists because a human
gate is not real when unattended — is `confirm (tool "consent")` here. incite
spells it as an exec leaf and argues in prose that it is a person's consent
mediated by a file. Ours says it in the term. Small, and it reads better.

**I7. The memo bill is falsifiable.** `stack-prs` runs at billFresh 16, billMemo
15: sixteen consultations reached, fifteen questions put, because two
orchestrator questions in two different loops are the same prompt over the same
carrier. The memo table and the trace are deliberately two objects, so the
saving is a number that can be wrong and checked. agent-functor's `leafKey` is
the same insight — content-addressed, FNV-1a because it is persisted, salted by
backend/model/mode because a fork onto another model would otherwise replay
someone else's work — and it is *ahead* of us in reaching across runs. The
improvement here is only that the bill is a value.

**I8. A tie, recorded as a tie.** Derived rosters — `qaOfCommitOver`,
`grindSynthesisOver`, `liveViewSeverityVocabulary`; a count and a name table
computed from the very list the panel is built from — carry over exactly, in
ordinary Haskell (`qaFence`, `grindSynthesisBrief`). So does the rubric+
adjustment pattern, and `[wf|…|]`'s layout rule is `[__i|…|]`'s, arrived at
independently for the same reason. `Says` is *stricter* — a hole has exactly
three meanings and a define never fuses with the literal beside it, where incite
has to spell empty-clause branches by hand to avoid byte drift — but the
capability is the same one, and it should be described as such.

---

## 6. Recommended next steps, as decisions

Ten decisions. Each is stated so it can be answered yes or no.

**D1 — Expose `function`, `callStmt` and `callV` through `Agentic.Workflow`.**
*Recommended: yes, first, before anything else on this list.* It is the only
proposal here with zero oracle exposure: the kernel already prices calls, the
guards already stratify the function table, and the frozen corpus already holds
three call cases the authoring surface cannot currently reach. It mitigates G1
(a duplicated tail becomes one line per arm), closes G2 outright (incite's
central discipline — one binding three workflows cannot drift from), and makes
D8 nearly free. Cost: the largest surface-only change on the list, the
type-level `Params`/`Args` threading being the hard half.

**D2 — Ship `panelText`, a fan-out whose fold is a fenced document.** *Recommended:
yes, second.* It is what every incite review tier above `lite` actually does, and
it is the difference between writing 84 statements and writing a list. Use a tag
pair rather than a heading for the fence, for Isaac's stated reason. Cost:
medium — one `Rhs` shape, two kernel fold clauses, new fixtures, no refreeze.

**D3 — Give the unsettled ending its candidate.** *Recommended: yes, as a second
combinator (`revisingYielding`) rather than as a change to `revising`.* This is
the sharpest single gap: `ship-feature-lite`'s whole designed trade is that
exhaustion yields, and today three trips' work reaches nothing. As a variant it
costs no refreeze. Decide explicitly whether the dissent in G5 — that the forced
abort *is* `completionGate` for free — outweighs it; the author still writes the
arm either way.

**D4 — Decide whether a revision's fork may read its review's verdict.**
*Recommended: not now.* The near-miss is exact (`caseVerdict`'s three arms are
Isaac's three endings) and the price is the highest on the list: an extra exit
edge per round changes `costSummary` on every frozen entry with a `revising`,
the flagship included. Record it as understood and deferred, and revisit after
D1 and D2 have changed how much of the inventory is actually out of reach.

**D5 — Answer the exit-code question, either way, in writing.** *Recommended: adopt
the runner-authored receipt as an Exec policy — a `tool` party carrying a
program-authored argv, whose receipt the World writes.* The factorization
theorem survives, `--scripted` is unaffected, and because the argv lives in the
value tier1 pins, we do not inherit agent-functor's `Grant` lattice or its
admitted symlink residual. The alternative — declaring that agent-cat models the
dialogue and a shell gate is the caller's business — is a defensible answer and
should be written down as one. What is not acceptable is leaving it silent while
`greenGateBrief` carries the apology.

**D6 — Adopt agent-functor's failure vocabulary as Exec policy, before we need
it.** *Recommended: yes, the taxonomy and budgets now, fail-over later.*
`TurnGap`'s three constructors, the per-gap re-ask budgets (2 / 1 / 0), the
`RetryHere | FailOver | Abandon` fork, and the unattended standing answer are
pure, small, testable and need no language change. He bought this knowledge with
two dead `ship-feature` runs and a twenty-leaf fan-out; it transfers as
vocabulary before it transfers as code. Fail-over is separate and costlier,
because a fallback list on `servedBy` changes the printed program.

**D7 — Decide on a closed decider vocabulary.** *Recommended: yes, at exactly
four constructors — `lastNonEmptyLineIs`, `containsLine`, `anyLineStartsWith`,
`anyPathMatches` — or no, cleanly.* Those four cover every pure decider in
incite. The strongest argument for is `diffNamesHaskell`, which exists precisely
because the model's answer cannot be trusted and is therefore *defeated* by
becoming a question. The strongest argument against is Isaac's own discipline
about not adding a fourth `Op`. Whichever way it goes, take the cheap half
regardless: make an unreadable flag take the loud arm rather than abandon the
run (`Agentic.Exec`, no kernel work).

**D8 — Give a program inputs.** *Recommended: yes, folded into D1.* Five leaves
across five programs exist only to fetch a subject the CLI already had, and the
operator's text should arrive as data rather than as an answer. Not worth doing
standalone.

**D9 — Add a `ServedBy`-family guard that refuses a program with an unpinned
ask, opt-in per program.** *Recommended: yes, cheap.* It is our idiom's answer to
`stackPin`: agent-functor guarantees by wrapping a subtree, we guarantee by
refusing a program, and `Agentic.Guards` is already the place. It closes the one
respect in which the per-question pin is weaker than the scope wrapper.

**D10 — Decide what these five example programs are for.** *Recommended: keep
them out of the frozen corpus, and pin their numbers anyway.* They are an
experiment about expressiveness and freezing them would make the corpus a
record of incite rather than of the language. But every number in §3 lives in a
haddock today and nothing stops it going stale — a `cost`/`plan` regression pin
over the five, separate from tier0/tier1, costs almost nothing and keeps this
document honest. Second half of the same decision: write G9 into the
documentation with Isaac's `4611686018427387927` attached. Our refusal to
express the unbounded case is the same lesson he arrived at from the other side,
and his number is the best evidence for it that exists.

**D11 — Re-derive or drop the Lean line citations, and gate them.**
*Recommended: yes, and it is the only item on this list that is a defect rather
than a design question.* The retirement commit deleted the Lean runtime and
resized `Exec.lean` and `Explain.lean` without touching the docstrings that
cite them: 57 of 220 citations in `haskell/` name a vanished file or a line
past the end, and at least two of the survivors resolve to the wrong text
(I2 has the accounting). Citations are the mechanism by which this
implementation claims to be a port rather than a rewrite, so a stale one is
worse than none — `Exec.lean:925` still resolves, and to something unrelated.
Either re-derive them against the spine that remains and add a CI check that
every `*.lean:N` in `haskell/` resolves to a file with at least `N` lines, or
drop the line numbers and cite by symbol name, which does not rot. The check
is a dozen lines and would have caught this at the landing.
