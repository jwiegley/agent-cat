# agent-functor — deep review for agent-cat

Read-only review of `~/src/agent-functor` (Isaac Shapira, GitLab
`fresheyeball/agent-functor`, BSD-3, v0.2.0.0). Nothing in that tree was
written, built or executed; this is `git log`/`git show` plus file reads.

## 0. The window I chose, and why

The repository's entire history is **2026-08-01 → 2026-08-18**, 344 commits in
eighteen days. "Recent" therefore cannot mean months. The log divides cleanly:

- **08-01 → 08-10** — the algebra is laid down (`Flow` spine, no-`arr` optics,
  cyclic skeleton, dynamic-extent combinators, heads/keyed/reducers, grants,
  oracle/inbox), then the ACP runner, the run store, the MCP server, the TUI.
- **08-11 → 08-18** — the **active front**, and where I concentrated. Every
  commit the brief named is here, and the character of the work changes: it is
  no longer "add the layer", it is "the layer met a real backend and lost a
  twenty-leaf fan-out, so the *policy* has to change". Nine of the last twenty
  commits are failure-policy or nested-run semantics.

So: **window = 2026-08-11..HEAD (828043c), read against the whole-history
skeleton.** I read every non-TUI module under `src/` at HEAD, `app/Main.hs`,
`doc/{spec,architecture,guide}.md`, `AGENTS.md`, and the specs
(`InterpretSpec`, `RunSpec`, `FlowSpec`, `CostSpec`, `ConcurrencySpec`) as
usage evidence. TUI modules skipped except where a semantic decision lived in
one (`Agent.Tui.Live`'s `Recovery`/`RecoverAsk` types, which the runner owns).

One structural fact that shapes everything below: `src/Agent/Run.hs` is **5,266
lines** — 29% of the tree, and the *only* module that changed in fifteen of the
last twenty commits. The algebra is small, clean and finished; the runner is
where the design pressure now is. That is worth knowing before reading the
concept map, because half the "quality" judgments are really judgments about
whether a concept has escaped `Run.hs` yet.

---

## 1. The API concept map

### 1.1 The spine

| Abstraction | Type | Job | Honest one-line judgment |
|---|---|---|---|
| `Flow` | `data Flow i o` (GADT, 15 constructors) | The workflow value: a profunctor optic, `Category`/`Profunctor`/`Strong`/`Choice`/`Traversing`/`ProductProfunctor`, **deliberately no `arr`, no `Monad`** | The best idea in the repo, and the haddock defends the weaker honest invariant ("opacity never *hides* structure") instead of overclaiming — `purePP` is admitted as a hatch and marked `pure-adapter` in `plan`. |
| `Label` / `share` | `newtype Label = Label Text`; `share :: Label -> Flow a b -> Flow a b` | Authoritative structural sharing; once recursion exists, the back-edge marker | Correct call: authoritative beats `data-reify`'s `StableName`, so a plan's shape survives optimisation. Cost is that a knot tied *without* `share` diverges — documented, not prevented. |
| `seq'`/`dimap'`/`par'`/`fanout'`/… | normalising smart constructors | Make `Category` laws hold **on the nose** (structurally), which is only possible because there is no `arr` | Small, tested, and the payoff is real: skeleton equality is meaningful. |
| `foldLeaves` / `foldLeavesScoped` | `Monoid m => (forall a b. Scope -> Op a b -> m) -> Flow x y -> m` | Fold over leaves *with the resolved scope threaded exactly as the interpreter threads it* | The seen-set is keyed on `(Label, Scope)`, not `Label` — because one shared body under two backends is two agents' worth of demand. That is a subtle bug prevented on purpose. |

### 1.2 The three effect leaves

| Abstraction | Type | Job | Judgment |
|---|---|---|---|
| `Op` | `data Op a b where Prompt :: PromptSpec a b -> …; Exec :: ExecSpec a b -> …; Ask :: AskSpec a b -> …` | The whole effect alphabet | Three is the right number and the module says so ("if you are tempted to add a fourth `Op`, check first whether it is a `Prompt`"). Maps almost exactly onto agent-cat's three addressees model/tool/person. |
| `PromptSpec`/`ExecSpec`/`AskSpec` | each `= Spec { name, Maybe <executable payload> }` | Separate *inspectable* from *runnable*: a name-only leaf plans and prices but cannot run | Good split, but it means `isRunnable`/`isExecutableHere` must be asked of the `Op` and never of the skeleton's `OpTag` (which erases the payload). Two preflights exist because of it. Slight smell. |
| `Mode` | `Plan \| Edit \| AutoEdit \| FullAccess` | Portable session mode; runner maps it to the backend's native ACP mode | Genuinely portable, and `Plan` is load-bearing (Claude's ExitPlanMode plan *is* the leaf's artifact). |
| `AgentSpec` / `AgentChain` | `AgentSpec = BackendRef + Maybe ModelKey`; `AgentChain = AgentSpec :| [AgentSpec]` | Which backend/model a subtree runs on, and what to try when it runs dry | The `Spec` vs `Chain` split is argued *precisely*: a spec is an **identity** (keys the connection map, names a preflight requirement, labels a row); a spare is a property of the **scope**, not the identity. Folding the chain into the spec would key two identical subprocesses off two differing specs. This is careful design. |
| `ScopeDecl`/`Scope`/`applyScope` | `ModeScope Mode \| AgentScope AgentChain`; innermost-wins **per axis** | Lexical scoping of mode and agent, independently | Clean. Model is replaced wholesale, never field-merged — because a `ModelKey` only means anything against its own backend. |
| `matchModelKey` | `ModelKey -> [(Text,Text)] -> Either [Text] Text` | Resolve a key against the menu the backend actually advertises: exact id, exact name, then a **unique** substring; ambiguity is an error | The single best small function in the repo. One definition shared by session-time and preflight so they cannot disagree, and it refuses `"opus"` against a menu holding `opus-4-1` and `opus-4-5` rather than silently billing the wrong one. |
| `leafKey` | `Mode -> Text -> Maybe Text -> Op a b -> a -> CacheKey` | The content address of one leaf execution: mode, backend, model, `kind:name`, and the **full rendered brief** | Salting by backend/model/mode is load-bearing and argued (a fork onto another model would otherwise replay someone else's work as the new model's). FNV-1a, not `hashable`, because it is persisted. Right for the right reason. |
| `isCacheable` | `Op a b -> Bool` | `Exec` is **never** cacheable | One line, correct: an `Exec` reflects the filesystem, not its input, so caching a `verify` would serve a stale green build. |

### 1.3 Dynamic extent and bounds

| Abstraction | Type | Job | Judgment |
|---|---|---|---|
| `traversePositions` | `Bound -> View s a -> Flow a b -> Flow s (Positions b)` | N units, independent, parallel (the MoE sublayer) | The workhorse. |
| `foldPositions` | `Bound -> View s a -> Flow (acc,a) acc -> Flow (acc,s) acc` | N units, sequential, accumulator threaded | Justified by its own impossibility proof: `Applicative` cannot feed position *i* to *i+1*, so `wander` cannot express it. |
| `loopUntil` | `Int -> Flow a (Either a b) -> Flow a b` | Bounded revision; exhaustion **always aborts** | The refusal to offer a `Yield` policy here is principled: at `LoopUntil`'s type the loop holds only an `a` on exhaustion but owes a `b`, so a total yield needs a finaliser. "The API cannot declare a policy it cannot honour." Compare agent-cat's `revising`, which *does* carry the `Settled/Unsettled` fork — agent-cat is ahead here. |
| `unfold` | `Depth -> Flow a (Either b (Positions a)) -> Flow a (Tree a b)` | Recursive decomposition; the only source of a back-edge | `Tree`'s `TCut` carries the **already-partitioned children**, not the parent input, so a resume grows the frontier without re-running the partition. Lossless truncation, thought through. |
| `Bound`/`Depth`/`Fuel` | limit + policy: `Coarsen\|FailWidth\|Sample`, `FailStep\|Yield`, bare count | Every dynamic construct carries a declared bound; unbounded is a static error | The premise the whole cost story rests on, and it is stated as a rule rather than a convenience. |
| `boundedFocus` | `Bound -> [a] -> [a]` | Runtime enforcement of the width cap | **Honest failure**: `Coarsen` cannot merge units of an arbitrary type, so it `error`s rather than silently dropping, and `Sample`'s "journal what was dropped" is admitted as *unaudited*. Two `error` calls in a pure function is ugly; saying so in the haddock is better than hiding it. |
| `View` | `View s a = Field + (s -> [a])`; `whole`/`each`/`window n` | The receptive field a dynamic axis reads through | The lawfulness distinction is the good part — `whole` is an iso, `each` a traversal, `window n` a **Fold, not a Traversal** because overlapping windows have no coherent write-back, so you *review* overlapping windows and *edit* disjoint units. The type-level enforcement of that is admitted as not yet built. |
| `Positions` / `Tree` | ordered `[a]`; `TLeaf\|TBranch\|TCut` | The two dynamic containers | Fine. `Positions` is explicitly *ordered* because file/dependency/call-graph order give different notions of "nearby". |

### 1.4 Cost

| Abstraction | Type | Job | Judgment |
|---|---|---|---|
| `Cost` | `Finite !Integer \| Unbounded` | Worst-case leaf executions | `Integer` not `Int`, and the commit that changed it (b76abc7) names the failure: sentinel fuels near `maxBound/2` summed to a **negative** report, and five wrapped back to a positive lie. Exactness of a number an operator reads before spending is not negotiable. |
| `worstCaseCost` | `Rooted -> Cost` | Cycle-aware fold: bounds multiply, `FSeq`/`FPar` sum, a re-entered node is `Unbounded` | Correct and *honest*: `unfold` has a depth bound but no width bound, so its worst case is genuinely `Unbounded` and the report says "unbounded" rather than inventing `depth·body`. |
| `allBounds`/`dominatingBound`/`costReport` | folds over `Rooted` | "which bound is worth tuning first" + per-expert utilisation | Small, useful, cycle-aware by visited-set rather than by the crashing `foldSkeleton`. |

### 1.5 The head axis (designed, not wired)

| Abstraction | Type | Job | Judgment |
|---|---|---|---|
| `Head` / `Heads hs i o` | typed graded append `(<+>) :: Heads as i o -> Heads bs i o -> Heads (as++bs) i o` with a `Distinct` type family | A static, named set of review/edit units whose names live at the type level | Nice type-level work (duplicate head name is a compile error, constructor unexported so the index cannot lie). **But the module says outright: "Pure core, IO wiring pending (M11) — no live run executes a `Heads`."** |
| `Keyed hs a` | total map over a type-level `[Symbol]`, `tabulate`/`index` with a `Member` witness | Totality: every reducer's lookup is total, failure rides in the payload | Same status: nothing in a run constructs one. `hs` is a *set* (name order canonical, duplicates collapse) which is what makes reducers permutation-invariant. |
| `Reducer` / `PosReducer` | `Keyed hs (Either HeadFailure o) -> r`; `Positions (Either HeadFailure o) -> r` | Fold a fan-out's results deterministically | Correct property (fold over *key* order, never *arrival* order) and correctly unwired. |
| `Expert`/`Router`/`utilisation`/`detectCollapse` | top-k selection over a static expert set + collapse detection | MoE routing with hand-set priors; utilisation is the only collapse signal absent a gradient | Genuinely interesting idea (a router sending 38 of 40 units to one agent has silently serialised the layer). Also unwired: "a live run computes no utilisation, so it reports no collapse". |
| `Position`/`Unit`/`PositionCtx` | content-hash unit keys + *relative* position context | "the unit two positions upstream that changed the auth handler", not "unit 17 of 40" | The best unimplemented idea here. Also unwired (M13); `leafKey` is what real leaves are addressed by. |

**The honest summary of §1.5: roughly a third of the exported API is a designed
surface waiting for its caller.** Isaac marks every one of these in the module
haddock with "Pure core, IO wiring pending (Mnn)" and names what a live run
therefore does *not* do. That is exemplary discipline and it also means the
concept map above overstates what actually runs. What runs is: `Flow` +
`Op` + bounds + scopes + `Combinators` + `Run.hs`.

### 1.6 Policy and escalation

| Abstraction | Type | Job | Judgment |
|---|---|---|---|
| `Grant` | `Set PathGlob × Set PathGlob × Set CommandGlob × Bool`, `Monoid` by union | Deny-by-default path/command capability lattice for **our** `Exec` shell | The lattice is a genuine join (idempotent, commutative), `matchGlob` is the linear two-pointer algorithm *because it matches agent-controlled strings*, and `canonicalizePath` collapses `..` before matching. Symlink escape is admitted as an open residual. |
| `OracleT m` | `Question -> m (Maybe Answer)`, `Monoid` by first-definite-answer | The answering policy as one line: `fromPlanDoc <> askExpert skeptic <> escalateToHuman` | Beautiful and tiny. Falling off the end **is** escalation. |
| `Inbox` / `groupByNode` | `[PendingItem] -> [GroupedItem]` keyed on `(node, question, source)` | One queue for gate + approval + permission; **40 positions asking the same thing present as one row with a count** | The grouping insight is the valuable part and it follows from having a skeleton node id to group under. Unwired (M14): permission requests today go to `autoAllow`/the operator and never become inbox items. Named, not papered over. |
| `Recover` / `Recovery` | `type Recover = RecoverAsk -> IO Recovery`; `RetryHere \| FailOver \| Abandon` | Who decides what a dead turn means | New this week; see §3. This is the sharpest thing in the recent history. |

### 1.7 The runner

`Workflow` is `name × description × Maybe defaultInput × Grant × Maybe
concurrency × TriggerInput × Flow Text Text`, built by
`workflow`/`workflowG`/`workflowReq`/`workflowGReq` and modified by
`withConcurrency` / `withCapturedTranscript`. `passMain :: [Workflow] -> IO ()`
is the whole binary: CLI (`list`/`plan`/`cost`/`run`/`runs`/`resume`/`fork`/
`diff`/`doctor`/`backends`/`mcp`) *and* an MCP server derived from the same
list. `defaultConcurrency = 6`.

Judgment: `passMain` is the right shape and the "your `Main.hs` is one line"
claim in the guide is true. `Run.hs` at 5,266 lines with a 190-entry export
list is the counterweight — connection pooling, session modes, worktree
isolation, the run store, MCP, nested runs, spooling, recovery policy and CLI
parsing are one module. Several of the recent commits are explicitly about
carving testable pure functions out of it (`nextAsk`, `unattendedRecovery`,
`stepNested`, `headlessOver`, `flushDecision`, `decideModeSet`, `decidePerm`),
which is the right direction and not finished.

---

## 2. The WORKFLOW EXAMPLES catalog

Two things to say first, so nobody hunts for what is not there.

1. **agent-functor ships five concrete workflows, all in `app/Main.hs`, and
   four of them are diagnostics.** The named production flows the source keeps
   citing — `ship-feature`, `review-lite`, `fess-audit` — live **downstream in
   `~/src/incite`**, not here. What lives here instead is the *shape library*:
   `Agent.Flow.Combinators` is the catalog of workflow shapes, and each entry
   is a named, tested, composable `Flow`. Catalogued both below.
2. Every shape is `Flow Text Text` in practice — the artifact is text and each
   stage rewrites it. That is the pervasive convention.

### 2.1 The five concrete workflows (`app/Main.hs`)

| Name | Shape |
|---|---|
| `review-revise` | `refineWith "reviewer" (brief "Review this Haskell for bugs and style, terse bullets:") id >>> refineWith "reviser" (brief "Given this review, rewrite the function fixing the issues. Output ONLY the corrected code:") id`. Two prompt leaves, sequential, default input is a broken `average :: [Int] -> Int`. Cost: 2 leaves, 3 nodes, no bounds. The tutorial flow. |
| `hetero-probe` | `exploreFlows [3 stances] (hierarchical ["skeptic","contemplative","intrepid"]) >>> review`. Three-way fan-out where **each stance is wrapped in its own `withBackend`** — `claudeAgent/default`, `codex/gpt-5.4-high`, `opencode/default` — reduced by a *pure* function, then a review leaf on a fourth scope (`codex/gpt-5.4-medium`). Opens one connection per distinct `(backend, model)` and preflights all four before the first turn. |
| `plan-probe` | `withMode Plan (refineWith "design" …) >>> refineWith "implement" (brief "Implement this plan now, editing files for real:") id`. Plan-then-implement gate: the design leaf runs in the backend's native read-only plan mode and returns the plan captured at ExitPlanMode; the implement leaf runs in `Edit` and actually writes. Also the reference for a **file-backed prompt** (`[promptFile\|prompts/plan-probe.md\|]`, path checked at compile time, read at run time). |
| `race-probe` | `raceWorkers [("alpha", …), ("beta", …)] "pick" (brief "Two workers each did the task in their OWN git worktree (paths below). Inspect both, pick ONE, and create race.txt in the CURRENT directory…")`. Two isolated workers each create `race.txt` in a private `agent-functor/worker-*` worktree, concurrently; a merge prompt inspects both worktrees and applies one in place. |
| `probe-acp` | One `refineWith "probe"` leaf: "create `acp-probe.txt`, run `ls -la`, report in one sentence." Exists purely to log which agent→client ACP requests a backend actually sends (`session/request_permission`? `fs/*`? `terminal/*`?) — i.e. an experiment whose output decides where the grant gate lives. |

### 2.2 The shape library (`Agent.Flow.Combinators`) — analysis half

| Combinator | Shape, tightly |
|---|---|
| `refine name` / `normalizeWith name` | One name-only prompt leaf, `Flow a a`. **The type is the specification**: an editor may *improve* an artifact, never replace it. Appears twice in a "transformer block" because the residual appears twice. |
| `refineWith name render decode` | The executable prompt leaf: `a -> Prompt`, reply `Text -> b`. Every other analysis shape is built from this. |
| `exploreWith agents reduce` | Fan *n* named reviewers over the **same** input (built from `&&&`, so no `Monad`), reduce the `[(LeafName, Text)]` pairs with a **pure** function. Labels stay `LeafName`, not `Text`, so a reducer can pattern-match expert identity. |
| `exploreFlows` | Same, but each expert is an arbitrary sub-`Flow` — which is what makes a **heterogeneous** fan-out expressible: `withBackend` erases its phantom indices, so three experts on three different agents are still just `[(LeafName, Flow a Text)]` with no existential. |
| `mergeWith workers mergeName describe` | `exploreWith workers unionFindings >>> refineWith mergeName describe id`. Fan-out where an **agent**, not a pure function, does the reconciliation. |
| `raceWorkers workers mergeName describe` | Best-of-N with **real edits**: each worker's leaf is named `worker:<n>`, which the runner recognises and gives its own **git worktree**; each result is a summary plus its worktree path; the merge prompt reads the actual trees and applies one (or a synthesis) in place. `raceFlows` is the same over sub-flows so a worker can carry its own backend; `raceN n brief` is *n* copies of one task. |
| `lensEdit [(name, brief)]` | Refine one artifact through named lenses left-to-right — scope, then risk, then sequencing. Plan-editing as composition. Empty list = identity. |
| `partitionReview split bound name brief reduce` | Split the artifact into units, review each in a bounded `traversePositions` fan, reduce the `Positions`. `boundedSplit` **pre-coarsens** (merges adjacent units so the count is ≤ bound, dropping nothing) rather than letting the interpreter truncate. The run graph shows one aggregate "N/M done" row. |
| `reviewScales split bound brief` | Multi-scale review: the **same** brief at three receptive fields — the whole artifact, sliding joined windows of 2 units, and each unit — fanned via `&&&` and combined into one report. The three-scale idea in eight lines. |
| `sourceBlock`/`unionFindings`/`hierarchical`/`priorityOrder`/`posReport` | The reducers. `sourceBlock` fences each source in `<report source="…">…</report>` — a **tag pair, not a `## heading`**, because bodies emit their own headings and a heading marks a start with nothing marking the end. `hierarchical prio` = stable priority reorder then union. |

### 2.3 The shape library — world-acting half

| Combinator | Shape |
|---|---|
| `execStep name cmd` | Run one command **ourselves** (argv, no shell), append `✓/✗ name (exit N)` plus a 240-char excerpt to the running log. Grant-gated, never cached. |
| `verify [(name, cmd)]` | Fold of `execStep`: the **independent** verification gate. Real exit codes, so a hallucinated "PASS" cannot ship broken code. `[]` = identity. |
| `agentVerify [(name, cmd)]` | The same checks asked of the **agent** as one prompt — explicitly documented as trusting the agent's PASS/FAIL claim. Having *both*, named honestly, is the point. |
| `commit msg` / `submitPR title body` | Prompts asking the agent to commit / open a PR with **its own** tools — so the gate is the ACP `session/request_permission` modal, *not* the workflow `Grant`. Two distinct gates, and the haddock says which is which. |
| `humanGate question` | `Ask` leaf; on anything but y/yes/ok/approve it **halts by `error`ing** (because `Flow` has no short-circuit), which `runWorkflow` catches and reports as `⚠ workflow halted` rather than a crash. |
| `steer label` | An interactive planning checkpoint: an `Ask` whose *answer is the revised plan*. The runner recognises the `steer:` name prefix and drives a real multi-turn operator↔agent conversation; on empty submit the plan passes through unchanged. Never halts. Piped/CI runs skip it. `explorePlanEdit >>> steer "before implementing" >>> implement`. |
| `workLoop n step` | Unroll a work loop **in ordinary Haskell**: `step 1 >>> … >>> step n`, where `step :: Int -> Flow a a` picks work/review/verify/commit by an n-cadence. The cadence is your code. |

### 2.4 The composite shape everything cites: `ship-feature`

Not in this repo, but its two stages are the two `describe` blocks in
`InterpretSpec` ("ship-feature stage 1" = the analysis combinators, "stage 2" =
the world-acting ones), and `Run.hs` describes its runtime shape in three
places. Reconstructed shape: **explore/panel (a ~21-leaf `traversePositions`
review fan) → merge → plan → `steer` → implement (whose agent calls
`review-lite` back through the mid-run trigger endpoint, producing a *nested
run*) → `verify` → `commit`**, with `withConcurrency` capping the fan and a
`fallingBackTo` chain on the model. Every failure-policy commit in the recent
window is a post-mortem of a `ship-feature` run that died.

### 2.5 Nested runs (the sub-flow mechanism)

Not a workflow but the shape that makes composite workflows real, and four of
the recent commits are it:

- A run advertises itself to its own agent sessions as
  `mcp --capture-context FILE --parent RUNID --ui-sink DIR`, so **a leaf's
  agent can start another workflow mid-turn**.
- The sub-flow writes one `<rnToken>.ndjson` of wire-encoded UI messages into
  `<runDir>/nested/flow-<id>/`, and **that path is the attribution**:
  `cnMcpServers` is an `IO [Value]` resolved per session on the *leaf's own
  thread*, so each leaf hands out a descriptor naming itself, and the watcher
  reads the parent flow back off the path. The child is told nothing and
  **cannot misreport whose it is** (commit 4209415 — it previously guessed the
  parent from which rows happened to be running).
- The sub-flow's leaves appear **indented and streaming in the parent's flow
  list**, and they **grow the parent's progress denominator** — deliberately,
  because "4/5 with five paid turns still to come is a worse lie than a
  denominator that moves" (f313459).
- Depth stays 1 (a sub-flow passes `noTrigger`), a nested flow **cannot be
  steered** (no mailbox exists in the other process, and the operator is now
  told exactly that rather than the false "not running" — 0192f62), and
  `withCapturedTranscript` marks the workflows whose input should be *the
  worker's transcript* rather than the caller's argument.

---

## 3. Semantics worth stealing

### 3.1 The failure vocabulary — the strongest work in the repo

Read as a stack, it is four distinct decisions that most systems collapse into
one `retries: 3`:

**(a) A gap is named by what the backend *said*, not by what we will do.**

```haskell
data TurnOutcome = TurnArtifact Text | TurnNothing TurnGap Text
data TurnGap = TurnFailed      -- the backend reported a failure
             | TurnEmpty       -- clean end_turn, no plan, no text
             | TurnExhausted   -- THIS model's allowance is spent (wire-tagged rate_limit)
```

The taxonomy deliberately did **not** gain a constructor when the policy
changed: `TurnGap` describes an observation, and a "transient failure" vs
"failed on the merits" distinction would be a lie because they arrive untagged.
`TurnExhausted` is separate only because it is **wire-tagged** (`data.errorKind
== "rate_limit"`), never inferred from prose — "an untagged failure reading
exactly like a limit still halts, because an unrecognised error is not evidence
that a second model would do better."

**(b) Re-ask budgets are per-gap, pure, and small.**

```haskell
nextAsk :: Int -> Retries -> TurnOutcome -> Maybe (Retries, Text)
```

`turnRetryBudget = 2` for `TurnFailed`; **exactly 1** for `TurnEmpty` ("a
backend answering empty twice is not flaky"); **zero** for `TurnExhausted`
("re-asking a rate-limited model is the most certain way there is to get the
same answer"). Re-asks happen **on the same session**, so a turn that half-did
something is continued by an agent that can see its own work rather than
restarted against a tree it does not expect. `nextAsk` is total and pure, which
is stated as the reason: *"the whole retry rule, so the loop cannot hold a
second opinion."*

**(c) When the budget is spent, the leaf does not decide — it asks.**

```haskell
type Recover = RecoverAsk -> IO Recovery
data Recovery = RetryHere | FailOver | Abandon
```

`turnArtifact` throws `TurnUnresolved` — **a distinct exception type, so that
only a *classified* failure may open a modal** (scraping an `ErrorCall` message
would let any `error` under a leaf ask for recovery). It travels to `overChain`,
the one layer that knows whether the chain has anywhere else to go. Three
answers because there are exactly three things the operator knows that the
runner does not: *has the backend stopped misbehaving* (retry), *would a
different model do better* (fail over), *is the run worth continuing* (abandon).

Two refusals in the modal, both principled: it **does not offer fail-over at the
end of a chain** (the offer would either halt while claiming to fail over, or
fail over to nothing — and `recoveryKey` is pure so the offer is testable), and
it has **no escape answer**, because every other modal has a safe default and
this one has none. It waits.

Unattended runs get `unattendedRecovery = fail over iff the workflow declared a
`fallingBackTo` chain, else abandon` — *"the flow author's standing answer to
'what should I do instead of halting', written before the run started; honouring
it is reading an instruction, not guessing"* — and **never retry**, because
"spending more on a hunch with nobody watching is the one thing an unattended
policy must not do."

**(d) `TurnUnresolved` never escapes a leaf.** Whatever the answer, `overChain`
turns it back into another attempt, a fallback, or the same `ErrorCall` halt it
always raised. So the TUI's bookkeeping, headless halt reporting and `resume`
needed **no change**. That containment is why the change was safe to make at all.

### 3.2 Survive-one-bad-leaf vs die-whole — as a *decision*, not a mode

`parList` is `mapConcurrently`, and a throw cancels siblings. One flaky
`end_turn` in a 21-leaf review panel therefore discarded twenty in-flight paid
turns and left the operator to `resume`, **which re-executes them**. Two
`ship-feature` runs died exactly that way.

The fix is not a `failFast :: Bool` flag. `parList` is **unchanged,
deliberately**:

> The fan-out no longer halts because a leaf decided to; it halts when somebody
> answers `Abandon`, and then it should take everything with it.

So the policy lives in *who is allowed to decide*, and both halves are pinned by
test: twenty positions where one leaf comes back empty all produce artifacts;
the same fan-out under `Abandon` takes the lot. And the things that still halt a
fan-out on their own are enumerated and defended: **a rejected gate is a human
deciding to stop; an exec failure or a bottom artifact is a real error rather
than a backend having a bad minute.**

(Note: `Agent.Concurrency.mapPositionsBounded` — isolated failures, each
position's exception returned as `Left` — exists in the pure core and is tested,
but **nothing in the interpreter calls it**. The real policy is the one above.)

### 3.3 Model fail-over as a property of the *scope*

```haskell
fallingBackTo :: Model b 'Named -> Model b 'Named -> Model b 'Named
-- claudeModel "fable" `fallingBackTo` claudeModel "opus"
```

Associative, chains arbitrarily deep, both sides indexed by the **same backend
`b`** at the type level. It erases into the scope's `AgentChain`, never into the
`AgentSpec` (§1.2). **Every entry in a chain is preflighted and gets its own
connection up front**, so a fallback this install cannot serve is an error
*before anything is spent* rather than a surprise at the moment the primary runs
dry — at the cost of one extra agent process per distinct fallback model. And a
leaf that fell back is **recorded and replayed as that model's work**, because
`overChain` re-runs the action under the next connection's own recorder.

### 3.4 Costs and bounds, as handled here

- **Bounds are mandatory at the type level**: there is no unbounded
  `traversePositions`. That is what makes a cyclic skeleton foldable at all.
- **Cost is a fold over the reified skeleton**, cycle-aware, `Integer`-exact,
  and `Unbounded` is a first-class answer that gets *printed* ("unbounded
  (unfold width / recursion is not statically bounded)").
- **`dominatingBound`** — the single largest multiplier, "worth tuning first" —
  is a tiny idea with a real payoff on a cost report.
- **The width bound and the concurrency cap are different numbers**: 40 units
  may be legal while only 6 run at once. `defaultConcurrency = 6` is bounded by
  default because "a wide fan otherwise opens one live agent session per
  position, which bursts a rate-limited backend into a 429 that — fail-fast —
  aborts the whole run." `--concurrency 0` opts back into unbounded.
- **Incrementality is content addressing, and nothing else.** "Nothing computes
  a dependency cone. Perturb a leaf → the next leaf's rendered brief differs →
  its key differs → it misses; untouched leaves keep hitting." `fork --at LEAF
  \| --reroll LEAF \| --set LEAF=FILE` is the whole perturbation vocabulary,
  and `Exec` records but never replays while `Ask` *does* replay (so a fork does
  not re-ask gates the operator already answered).

### 3.5 Smaller things worth lifting

- **`verify` vs `agentVerify` as two named combinators.** Trust is a design
  choice with a name attached, not a footnote.
- **`sourceBlock`'s tag pair over a `## heading`.** A delimiter that cannot be
  confused with the markdown inside it, and nests when a fan of fans is unioned.
- **`steer` — a checkpoint whose answer is the revised artifact.** Not a
  yes/no gate: a bounded multi-turn conversation with the agent whose *output
  replaces the artifact*, skipped automatically when piped.
- **`groupByNode` — 40 identical escalations present as one row with a count.**
- **`matchModelKey` refusing ambiguity** rather than resolving by list order.
- **The commit-message discipline.** Every one of these commits names the
  concrete run that died, what it cost, what was tried first and why it was only
  half a fix. That is a design record, and it is why this review was possible
  from `git log` alone.

---

## 4. What agent-cat already has that agent-functor lacks

Stated fairly, in both directions where it matters.

**agent-cat has, agent-functor does not:**

1. **A machine-checked meaning.** agent-cat's folds are ported from a Lean
   kernel and pinned against a frozen corpus (tier0/tier1/bisim); `Agentic.Plan`
   cites `Explain.lean:552` for `costSummary` and `Agentic.Exec` cites
   `Exec.lean:654` for the factorization theorem `runPlanIO (pureWorldIO w) p ==
   pure (runPlan w p, trace w p)`. agent-functor's laws are **HSpec law bundles**
   (spec §6.1–6.2) — real, and good ones (Category laws hold *structurally*
   because there is no `arr`) — but there is no oracle and nothing is proved.
   When agent-functor's `worstCaseCost` and its interpreter disagree, only a
   test catches it.
2. **A cost *summary*, not a single worst case.** `costSummary :: Plan g a ->
   (Maybe Integer, Maybe Integer, Integer)` gives cheapest bill, dearest bill,
   and **number of paths** — over branches. agent-functor's `worstCaseCost` is
   one number, and a `Choice` node sums both arms because a static fold cannot
   know which is taken. agent-cat prices a branching program honestly; the
   flagship reports "9 paths folding between 5 and 15", which agent-functor
   simply cannot say.
3. **A level lattice** (`batch < pipeline < branch < dynamic`) — a *classifier*
   of what kind of program this is, checkable and orderable. agent-functor has
   `fsWorldActing :: Bool` and a leaf-kind count; there is no lattice.
4. **Worlds as data.** `WorldSpec`/`World`/`Trace`/`Event`, `billFresh` vs
   `billMemo`, `runPlan`/`runIn` — a pure world you can *run the whole program
   against* and get the same answer the IO runner would, with the memo table and
   the trace deliberately kept as two objects so the memo bill is falsifiable.
   agent-functor's nearest equivalent is `Agent.Flow.Normalize.runPure` plus a
   mock `LeafRunner`; there is no first-class world, no event trace as a value,
   and no bill.
5. **Static guards with a refusal vocabulary** — `PanelEmpty`, `RevisionBound`
   (≤64 amendments), `QuestionBudget` (≤4096 questions, counted through a
   stratified function table), `ServedBy`, `DupFunction` — that *refuse a
   program*, matching the oracle's classifier. agent-functor's preflight refuses
   an unrunnable leaf or an unresolvable model, which is a smaller class.
6. **A bounded revision that returns `Settled | Unsettled`.** agent-functor's
   `loopUntil` *aborts* on exhaustion and its haddock explains that it cannot do
   otherwise at that type. agent-cat's `revising … (atMost 2)` hands the author
   the fork and makes them write the `Unsettled` arm. That is strictly better,
   and agent-functor's own comment concedes the gap.
7. **Answer codes as a type.** `text/verdict/flag/receipt` with `Verdict` a
   noncommutative monoid — so a panel's fold has a *meaning*, and a decode
   failure is a typed event with a `nudge` retry. agent-functor decodes with a
   bare `Text -> b` supplied per leaf; nothing constrains or classifies what
   came back, and `unionFindings` concatenates text.

**Where agent-functor is ahead, and agent-cat should not pretend otherwise:**

- Everything in §3.1–3.3 (operator-answered recovery, per-gap re-ask budgets,
  scope-level model fail-over, fan-out survival). agent-cat's only failure
  policy is `defaultRetries = 1` in `attemptDecoding` — a *decode* retry with a
  nudge — and after that it is an error that stops the run. There is no notion
  of a transport failure, a spent allowance, a fallback model, or a decision
  that belongs to a human.
- Cross-run persistence: a content-addressed run store, `resume`, `fork --at /
  --reroll / --set`, and the "no dependency cone, content addressing *is* the
  invalidation" property.
- Real multi-backend execution: a capability matrix discovered by probing,
  preflight against what a backend *advertises now*, and one connection per
  distinct `(backend, model)`.
- Isolation as a primitive: `worker:` leaves each in their own git worktree,
  `--sandbox` runs on a throwaway branch, deny-by-default `Grant` over our own
  shell.
- Nested runs with unforgeable parentage (§2.5).
- A bounded concurrency story that has met a 429.

**Fair-minded closing note.** The two projects are not competing on the same
axis. agent-functor is a *runner* with an unusually principled algebra bolted to
the front of it; agent-cat is a *semantics* with a runner growing out of the
back. agent-functor's algebra is smaller than its export list suggests (a third
of it is unwired by its author's own admission), and its hardest-won knowledge
is entirely in `Run.hs`, in the part agent-cat has not had to build yet. That
knowledge — §3.1 and §3.2 above — is transferable as *vocabulary* even before it
is transferable as code, and it is what I would take first.
