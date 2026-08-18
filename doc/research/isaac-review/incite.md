# incite — a deep review, for agent-cat

**Subject.** `/Users/johnw/src/incite` (GitLab `fresheyeball/incite`), read-only.
**Window reviewed.** `git log --stat` over `--since=2026-08-01` — 205 of the
repository's 217 commits, ending at `0cbddad` (2026-08-18, "address update").
The Haskell layer is entirely inside that window: `incite-workflows.cabal` and
the first workflow appear at `a096f13` (2026-08-02), prompts move to disk at
`5b7eb46` (2026-08-05), and the four-module split (`Incite.{Prompts, Backend,
Feature, Review}`) lands at `3bda8b8`/`97afc6f` (2026-08-06). Everything below
is therefore *new work*, not archaeology. TUI is out of scope and was skipped.

**What I read.** `workflows/Main.hs`; `workflows/Incite/{Backend, Prompts,
Feature, Review}.hs` in full (5,307 lines); `incite-workflows.cabal`;
`flake.nix` inputs and the `builtins.readFile` allowlist; `docs/{architecture,
workflows}.md`; every file under `commands/` and `skills/` and `agents/`
except the two large generated engine transcripts (`grind-*-engine.md`, ~1,550
lines of retired driver prose); `test/Spec.hs` header and structure (250 test
cases). Nothing was built or run.

*Footnote on reproducibility:* the working tree carries an uncommitted edit
pinning `agent-functor.url = "path:/Users/johnw/src/agent-functor"` where the
committed value is `git+https://gitlab.com/fresheyeball/agent-functor`. Not a
finding — just the reason a `nix build` here would resolve differently than on
Isaac's machine.

---

## 1. What incite is

incite is Isaac's *prompt repository with a Haskell workflow package bolted to
it* (his `docs/architecture.md`'s own words) — one tree holding two inventories
with different lifecycles. The first is `flake.nix`'s `prompts` list: a
declarative Nix manifest that `flake-prompt` renders into `~/.claude` and
`~/.codex` as instructions, agents, slash commands and skills, some authored
locally under `agents/ commands/ skills/ prompts/`, some read verbatim out of
`flake = false` inputs (ponytail, awesome-prompts, John's `promptdeploy`, the
`alexey-review` skill, ASD-STE100 SimpleEnglish) under an explicit allowlist.
The second is `workflows/Main.hs`'s `workflows` list: fifteen typed
`Agent.Run.Workflow` values built out of `agent-functor`'s `Flow` combinators,
served as both CLI subcommands and MCP tools by `passMain`, which *read the
same markdown files* the first inventory deploys — `[promptFile|commands/fess.md|]`
is checked at compile time against the package root and read at run time against
the cwd, so the rubric a sub-agent gets deployed and the rubric a workflow leaf
sends are one file, never two copies. The whole thing is aimed at one working
loop: an agent works, `/wiggum` keeps it going, after every commit
`post-commit-audit` fires `review-lite` (six independent reviewers across three
backends) and `fess-audit` (an honesty audit of the captured session), findings
go to a `fix-all` sub-agent, and the heavier tiers — `review-heavy`,
`review-audit`, the three `grind-*` whole-tree audits, `stack-prs` — are
launched deliberately from slash commands that do nothing themselves but point
the tool at the right checkout, poll it, and report. It builds on
agent-functor and on nothing else (`build-depends: base, text, agent-functor`);
`test/Spec.hs` adds `tasty`, `directory` and agent-functor's own interpreter,
skeleton and cost folds, which it uses to *fence* claims the prose makes
(250 cases, e.g. rendered prompt bytes, `lens@backend` leaf-name tables, grants
run through the runtime's own `permitExec`, worst-case leaf counts read out of
`docs/workflows.md` and compared against `worstCaseCost . toSkeleton`).

---

## 2. The workflows catalog

Fifteen exposed (`Main.workflows`) plus one deliberately unexposed
(`plannerAudit`). Six shared pieces do most of the work, so I state those first;
each workflow below is then "the shared pieces, plus what it supplies."

### 2.0 The shared machinery (`Incite.Feature`, `Incite.Review`)

| Piece | Shape |
|---|---|
| `explorePlan` | fan-out of four read-only *stances* — `intrepid` (the path, claude-agent/opus), `skeptic` (the risks, codex/gpt-5.5-xhigh), `contemplative` (design options, opencode), `architect` (the shape of the tree, claude-agent/fable) — reduced by `hierarchical ["skeptic","architect","contemplative","intrepid"]` (an *ordered narrowing*, not a vote), then `planLeaf` (one prompt, Fable 5, read-only). |
| `editPlan` | `lensEdit` — six *sequential rewrites of one text*: ponytail (delete first), denotational, risk, verification, lookahead (reorder for irreversibility), simple-english (STE reword). Deliberately unpinned so all six run on the same backend and stay comparable. |
| `orchestrate` / `orchestrateWith fuel` | the worker loop. Each trip feeds the worker **its own previous summary**. The loop reads the summary's *last non-empty line* (`tripEnding`) and classifies it four ways: `WORK COMPLETE` → end, `WORK BLOCKED` → end (passed through verbatim), `WORK REMAINS` → another trip if the budget has one, anything else → **protocol violation**: re-prompt with `violationNudge` appended, at most `violationBudget = 2` per run, then yield under `protocolNotice`. A violation spends no trip fuel. Exhaustion **yields, never aborts** (the tree keeps its edits) with `exhaustionNotice` appended under its own `##` heading. The budget is a record (`TripBudget {tbFuel :: Maybe Fuel, tbViolations :: Fuel}`) threaded beside the text by `second''`, so the worker only ever sees its own summary. |
| `completionGate` | a pure stage that halts the run (a bare `error`) unless the loop's yield declares `WORK COMPLETE`. `ship-feature` and `ship-docs` only — a block or a spent violation budget must not buy a review panel and a PR gate. |
| `checkLoop` / `greenGate` | the harness runs argv itself (`Agent.Flow.Combinators.verify`), reads the exit code, and `isRed` decides on lines opening `✗ ` (a monoid homomorphism into `Any`, which is why each trip is fed `mempty`). Red → a `repair` leaf under the artifact rule → retry, `repairFuel = 3`, then **abort** (opposite polarity to `orchestrate`, argued for at both sites). The incoming account survives above the check log (`keeping`). |
| `remediate rule closing` | the single leaf that acts on findings, under `codeRule` / `docsRule` / `paradoxRule` / `stackRule` and one of two closing clauses (`closeWithChanges` for a fixer that runs once, `fixerContinuation` for one under `orchestrate`). Reviewers are read-only by construction (`Incite.Backend.reviewer` = `withMode Plan`), so nothing can fix what it found. |
| `Orientation` / `orient` | a pure prepend that tells a stage *where the evidence is*, because after a loop the artifact in hand is an account, not the thing. Four constructors — `AtChange`, `AtRecord`, `AtDocs`, `AtStack` — each with a preamble, plus three laws (non-empty, pairwise distinct, no trailing whitespace) written as a refutable `preambleViolations`. |

### 2.1 `plan-feature` — prompt-only
`explorePlan >>> editPlan`. Ten leaves before a line is written; no worktree,
no git, no PR. Humans: none.

### 2.2 `ship-feature` — the flagship acting workflow
```
explorePlan >>> editPlan
  >>> steer (planSteer "implementation")          -- human edits the plan
  >>> orchestrate auditedImplement                -- unbounded worker loop
  >>> completionGate                              -- halt unless WORK COMPLETE
  >>> dimap' asReviewSubject id reviewHeavyFlow   -- 43-leaf panel + synthesis
  >>> remediate codeRule closeWithChanges
  >>> greenGate codeRule codeChecks               -- harness runs `nix flake check`
  >>> retrospective                               -- retroFlow, appended under a heading
  >>> humanGate "Open a pull request for these changes?"
  >>> submitPR …
```
- **Fan-out**: the four stances; then the review panel (8 lenses × 3 backends,
  plus two regrouped views on claude-agent alone, plus synthesis = 43 leaves).
- **Loop**: `orchestrate` with `workerFuel = Nothing` — unbounded; the worker
  decides. Each trip is `implement >>> keeping auditThenSummary tripFess`: the
  worker's summary, with an honesty audit of *that trip* (`fessOfTrip`, read-only,
  pinned claude-agent) merged **above** it so the worker's status line stays
  terminal and the findings are the first thing the next trip reads.
- **Gates**: `completionGate` (pure halt); `greenGate` (real exit code, 3 repair
  trips then abort); `humanGate` before the PR.
- **Humans**: two — the `steer` after planning, which asks for *the acceptance
  bar this change must clear* (not "any guidance", because an empty submit
  answers that honestly in four seconds), and the PR gate.
- **On failure**: a worker that never declares completion halts at
  `completionGate`; a red tree aborts at the gate; a "no" at the human gate
  halts the run — which is exactly why the retrospective sits *before* it.
- **Provenance worth stealing**: three of these stages are named in the haddock
  as answers to a specific dated retrospective (2026-08-12) of a run that ended
  in a "no" at this gate after four hours, because the fixer's closing test
  counts ("369/0") existed only in its summary.

### 2.3 `ship-feature-lite` — the small-change tier
```
planLeaf >>> steer >>> orchestrateWith liteFuel implement
  >>> dimap' asReviewSubject id reviewLiteFlow
  >>> remediate codeRule closeWithChanges
  >>> greenGate codeRule codeChecks
```
No stances, no `editPlan`, `liteFuel = Just (Fuel 3)`, the six-leaf per-commit
panel, and **it ends on the gate** — no human gate, no PR, deliberately: an
unattended run auto-answers gates (`gateAnswer` defaults to `"yes"`) and
`--sandbox` isolates the tree but not the network, so a PR leaf would be an
irreversible action nothing in the run could stop. Worst case is *fenced at 21
leaves* — `test/Spec.hs` reads the number out of `docs/workflows.md` and
compares it against `worstCaseCost . toSkeleton . wfFlow`. This is the only
workflow in the repository with a finite, quoted price.

### 2.4 `ship-docs` — the same shape at prose
`explorePlan >>> lensEdit docsPlanLenses >>> steer >>> orchestrate document >>>
completionGate >>> reviewDocsFlow (via asDocsSubject) >>> remediate docsRule`.
`docsPlanLenses` is `docs-strategy` then `simple-english` (cut first, reword
what survives). The worker is `document`, which gets `wiggum` and
`ponytailLadder` but **not** `agenticCoder` (a brief about writing code), and
stands under `docsRule` — "the document is the artifact and the code is the
record; correct the DOCUMENT, never edit code to make a sentence true" — the
same rule its fixer stands under, one binding, because the drift has a name: a
fixer closing "this sentence is false" by changing the code. No gate, no PR.

### 2.5 The three grinds — `grind-paradox`, `grind-tests`, `grind-live-view`
One shared prefix, `grindFlow (GrindSpec {gsName, gsFacts, gsLenses,
gsSynthesisSuffix, gsPins})`:
```
dimap' (facts <> steer) id (spreadPinned gsPins backends gsLenses)  -- one backend per lens
  >>> refineWith "synthesis" (derived brief)                        -- ranks + writes docs/audits/<name>-<date>.md
  >>> loopUntil 1 (dimap' id decideFactsResolved Id)                -- STOP on FACTS PATHS UNRESOLVED
  >>> orchestrate (remediate (grindRule gsFacts) fixerContinuation) -- unbounded fixer loop
```
- **Fan-out is a `spread`, not a `panel`**: 14/12/11 lenses zipped against
  `cycle backends` — coverage rather than agreement, because "three models
  agreeing about a tree nobody changed is worth less than three more questions
  asked of it." Lens *order is semantic* (position picks the model), so
  `gsPins` exists to state the one assignment that is policy (`("auth",
  "claude-agent")` in the LiveView grind, whose severity words the ranking
  clause matches on).
- **The synthesis refuses**: it is told its own roster by name, and stops if any
  lens's block is missing or empty — because an unauthenticated backend returns
  nothing and nothing folded into a ranked list reads exactly like a clean tree.
  It also refuses on `FACTS PATHS UNRESOLVED`, the line every facts file's
  path-probe emits outside the target checkout; `decideFactsResolved` behind a
  fuel-1 `loopUntil` turns that prose refusal into a *run failure* before any
  fixer acts.
- **Gates**: `grind-paradox` on `nix develop -c bash -c 'cabal build'` and the
  test suite; `grind-live-view` on `mix compile --warnings-as-errors`, `mix
  test`, and `cd assets && npx vitest run`; `grind-tests` on `nix flake check`
  alone, because it is the only project-agnostic one. Grants are **derived from
  the check list** (`grindGrantFor` takes each argv's head plus `date*`,
  `mkdir*` for the report write) so a check added without a permission is a
  build-time fact rather than a run-time denial nobody reads.
- **`grind-tests` alone adds a second segment**: the full 84-leaf
  `reviewAuditFlow` over the *fixer's own change* (reframed with
  `asReviewSubjectIgnoring` at this run's own report prefix, so the run's dated
  audit file is not read as the fixer's delta), then a second fixer capped at
  `grindTestsReviewFuel = Just (Fuel 12)`. The argument is exact: a test-suite
  remediation's cheapest failure is a weakened assertion, which a green gate
  cannot see and a review panel reads diffs for.
- **Humans**: none inside the flow. The human is in the *launcher* — `pwd` check,
  `sandbox=false`, poll, then read the dated report and hand the dirty tree to
  `/commit`.

### 2.6 `stack-prs` — the richest shape
```
explorePlan (facts prepended) >>> lensEdit [slice, simple-english]
  >>> steer >>> humanGate "Build the stack from this plan?"
  >>> stackWorker "bootstrap" stackTooling
  >>> orchestrateWith stackFuel (stackWorker "cut" stackSlice …)
  >>> stackGate                                   -- ./verify-stack.sh, real exit code
  >>> asStackSubject >>> reviewHeavyFlow
  >>> orchestrateWith stackFuel (stackPin (remediate stackRule …))
  >>> orchestrateWith stackFuel (stackWorker "triage" stackTriage …)
  >>> stackGate
  >>> humanGate "Promote this stack out of draft? …"
  >>> consentGate                                 -- test -f .stack-promote-approved
  >>> orchestrateWith stackFuel (budgetGate >>> stackWorker "promote" stackPromote …)
```
Four capped loops (`stackFuel = Just (Fuel 12)` each — capped precisely so the
worst case is a number an operator can read), three exec gates, two human gates,
and one gate that exists *because a human gate is not real when unattended*:
`consentGate` runs `test -f .stack-promote-approved` with a fuel of one, so a
missing approval file ends the run before any branch leaves draft, and
`prompts/stack/rule.md` forbids the agent from creating that file. `budgetGate`
re-runs `./ci-budget.sh --wait` *before every trip* of the promotion loop —
a clearance read once and reused is a clearance about a queue that has changed —
with `Id` as its repair (there is nothing to fix; somebody else is queued) and
`budgetFuel = 2` waits before the run fails. Every acting leaf, fixers and the
repair leaf included, is pinned through `stackPin` (claude-agent default model),
because these leaves rewrite git history. `WORK BLOCKED` exists for this
workflow: a third ending for a design disagreement, an approved branch that must
not be rewritten, or a starved runner pool.

### 2.7 The review tiers (all prompt-only, all read-only)

| Tier | Leaves (opencode blocked) | Shape |
|---|---:|---|
| `review-lite` | 7 (7) | six reviewers, one wave, **pure fold** (`hierarchical`), no synthesis leaf: `correctness`@claude/fable, `fess`@claude/opus, `complexity`@codex, `ponytail`@codex, `qa`@opencode, and `haskell` behind a **router**. |
| `review-heavy` | 43 (35) | 8 lenses × 3 backends over the full diff, plus two *regrouped views* (`units`, `sequence`) each answered by a claude-only panel, then one `synthesis` leaf. |
| `review-audit` | 84 (57) | 9 lenses (adds `architecture`) × 3 backends × three granularities (full, logical units, ideal commit sequence), then synthesis. |
| `review-docs` | 15 (10) | 5 prose lenses × 3 backends *except* `accuracy@codex`, then synthesis. |
| `prompt-lint` | 1 (1) | one STE CHECK-mode pass over procedural prompt text, including the prompt prose written as Haskell string literals under `workflows/`. |

Three mechanisms here are worth naming individually.

- **The conditional lens.** `haskellIfEdited` is *one* member of the fan-out
  containing two leaves: a one-word triage (`haskell` / `none`, told to read
  only path headers, never the diff) and, behind `routeHaskell`, the ~30 KB
  `haskellOfHouse` lens. The default is loud — only a clean `none` skips — and
  even a clean `none` is overruled by a pure scan (`diffNamesHaskell`) of diff
  *header* lines for `.hs/.lhs/.hs-boot/.hsc/.cabal`, so a well-formed wrong
  answer cannot silently skip a Haskell review. `reviewLiteRouters` names the
  triage as *not a reviewer*, so the `qa` fence and the prose tests subtract it.
- **The forbidden pairing.** `admits :: LeafName -> Prompt -> Bool` is `False`
  in exactly one case — the `fess` rubric never runs on codex — and it is keyed
  on the lens **body** (`promptText fess \`T.isInfixOf\` promptText lens`), not
  its name, so `docsAccuracy` (which is `fess` re-pointed at prose and named
  `accuracy`) is caught without anyone remembering to add it.
  `forbiddenPairings` is the refutable form, and the test asserts *both*
  directions: that it names `accuracy@codex`, and that no such leaf survives
  into a built flow.
- **The reorientations.** Nine lens bodies are not files but compositions:
  an upstream rubric plus one adjustment that voids its output format and
  restates the panel's own. `reporting` (the four-field output contract every
  grind lens stands under), `toTree` (a diff rubric pointed at a whole tree),
  `ofTree = reporting . toTree`, `architectureOfChange` (the mirror),
  `haskellOfHouse` (upstream + house addendum), `disciplineOfPanel` (the
  `alexey-review` skill with the two reference files it demands spliced inline
  and its GitHub verdict removed — "never approve by saying nothing, because an
  empty answer here is indistinguishable from a backend that failed to run"),
  `qaOfCommit` (fenced off its siblings by a *table*, `qaSiblings`, with the
  counts derived rather than spelled, because `review-lite` has no synthesis to
  de-duplicate), `docsAccuracy`, `fessOfTrip`, `slopOfDocs`, `ponytailOfDocs`,
  `ponytailOfTree`.

### 2.8 `fess-audit` and `retro` — the captured-transcript pair
Both are `withCapturedTranscript`: called through a run's trigger endpoint,
their input is *the calling worker's own conversation*, not the caller's text.
`fess-audit` is one read-only leaf pinned to claude-agent (pinned so the rubric
cannot reach codex by inheritance, which `admits` forbids inside a fan-out).
`retro` is three read-only columns in a wave (`sentiment`, `went-well`,
`went-wrong` — a wave and not a chain "for the reason a facilitator has people
write cards before anyone speaks") reduced by a `retro` report leaf that is
*not* read-only: it runs `date` (hence `retroGrant = execGrant ["date*"]`) and
writes `RETRO-<date>.md` at the repository root, appending under a `---` rule if
the file exists. The haddock records why: two earlier retrospectives lived only
in the gitignored run store and their "next time" changes were never seen.

### 2.9 The prompt-library workflows (the slash commands / skills)
These are not `Flow` values; they are the deployed prompts, and several are
*driven by* the workflows above. They are the real-world specimens.

| Name | Shape |
|---|---|
| `wiggum` | the duration brief: continue autonomously to parity with a named target or to plan completion; maintain **one handoff document**; after **every commit** run `post-commit-audit` (one step, one commit, one audit — explicitly *not* collected to the end); hand real findings to **one** `fix-all` subagent with the findings verbatim, the commit SHA, and a boundary; wait, read its diff, run the build yourself, commit its work; **do not audit the fix commit** (the loop must terminate); before any summary, run every suite and write the counts *into the tree*, naming anything gitignored the green depends on. |
| `post-commit-audit` | the single description of the beat: call `review-lite` (with the diff, *the task*, and **your own claim in your own words** — without (3) the `fess` lens degrades to a style opinion), plus `fess-audit` inside a run; poll `status` until done; fix every finding; **do not** spawn a subagent to run a check, assemble a context snapshot, or coordinate through the filesystem. |
| `fess` | the honesty rubric. Four shapes — verification gap (most important), spec drift, scope creep, quiet downgrades — with the hardest rule stated twice: a claim that a *mechanism fired* is proved by the log line showing it fire and by nothing else; the eventual outcome is not the mechanism. Ends with a severity-ranked list of gaps the author did **not** report. |
| `fix-all` | one TODO per finding (X findings → X items, then re-read every finding and check the plan covers each, twice); parallel subagents in `wg-<id>/<task>/` worktrees inheriting every rule verbatim; no reward hacking (weakening assertions, skipping, mocking the SUT, tautologies); **fix upstream, always**, forking if upstream is dead; a Definition of Done that includes worktrees cleanly removed. |
| `find-bugs` | one paragraph, and the shape is interesting: audit until exhausted, write `BUGS.md`, and for **each** bug emit *the prompt that would fix it*, with the context it needs. A workflow that outputs workflows. |
| `fix-build` / `fix-everything` / `trust-nix` / `use-nix` | short standing rules: run `nix flake check -L`, `nix fmt` for formatting; there are no "pre-existing issues" (you branched from a passing build); an explicit UNACCEPTABLE list (`@skip`, `xfail`, `-Wno-*`, "follow-up PR", lowering strictness); never blame the cache, the builder, or nix; prefer `nix flake check`/`nix build` over `nix develop` because the remote builder is 105 cores and the laptop is 16. |
| `code-review` | one-diff review against `$1` with merge-base hygiene (`git diff "$1"...HEAD`, remote-tracking ref, stack parent not trunk for a stacked PR), and a *review ladder* pointing at the agent-functor tiers for anything wider. |
| `commit` | atomic, logically sequenced commits; `--no-gpg-sign` always; **no assistant branding or `Co-Authored-By`**; hunk-level staging; a six-item quality checklist per commit. |
| `address-findings` | `fix-all` verbatim plus project rules for a generated-code repo: never commit generated code, fix the `.dox` source not the output, and a language hierarchy (Paradox `.dox` → F* with proofs → Elixir/TS/Rust direct, dropping a level only with a stated justification). |
| `pr-review` (skill) | **the richest human-in-the-loop specimen.** Read-only by constitution. Step 1 resolves the PR, its CI, *both* comment sources (top-level and inline — `gh pr view` does not return inline), and its Graphite stack position, then fetches into a sibling worktree and saves `gh pr diff` as the stable index. Step 2 partitions hunks into ordered **groups of 1–5** (one logical change; mechanical hunks never stand alone) and shows the plan. Step 3 walks them: show, explain, flag by category, **stop and wait**, draft comments labelled `D1…` — navigation is `next/back/go to k/skip` and it never advances on its own. Step 4 re-reads the whole saved diff in one pass and reviews adversarially. Step 5 spawns a **background babysitter subagent** per PR that polls checks and comments until merge, fixing CI and unambiguous review comments in its own worktree, append-only, never merging. Step 6 optionally posts (default: do not) and advances upstack. |
| `pr-address` (skill, newest — `d01aab5`/`0cbddad`, 2026-08-18) | the mirror: I am the author. **The unit of work is the stack, never a PR** — it derives the whole forest of open PRs from one `gh pr list` by chaining `base → head` edges, picks the stack by a five-step precedence, and takes it root to tip in both directions. Then it gathers every unresolved thread (GraphQL `reviewThreads`, deliberately without `diffHunk`), builds **one queue ordered downstack-first** (a lower fix can moot an upstack comment), cross-links duplicate threads into clusters, and persists the queue and per-item decisions to a scratch file outside every worktree. Then it walks: thread verbatim, **the code as it stands now** (not the comment's stale hunk), "already fixed?", a one-line verdict from a closed set (`agree` / `agree-but-downstack` / `disagree` / `needs your call` / `out of scope`), **stop and wait**; on `fix` it does one fix in one worktree through a subagent and pushes immediately; replies and resolves are drafted and **posted only on explicit approval**; a downstack fix then offers a Graphite restack (the one place force-push is allowed, and only by permission). Step 6 sweeps: re-fetch threads, print leftovers ("a fix with no reply is how a reviewer concludes they were ignored"), and one holistic pass over the feedback *as a whole*. |
| `pr-fix`, `pr-comment` | the two write companions: one applies exactly one described change through a subagent in its own worktree and pushes immediately, never force; the other adds a comment to a **pending** review (GraphQL `addPullRequestReviewThread`) so nothing is public until one submission. |
| `user-test` | a Krug-style think-aloud usability run: persona rules ("if you catch yourself thinking *I know from the code that this button does X* — stop"), a per-action loop (state intent → look → screenshot before → act → reflect → screenshot after → append to `notes.md`), a bug/usability split, and a final `REPORT.md` with a task-completion table. |

---

## 3. Prompt engineering: how it is stored, and what `[wf|…|]`/`Says` would need

**Three provenances, one copy each.** `Incite.Prompts` is *data, not logic* — 90
top-level `Prompt` CAFs and nothing else — and every body is either
`[promptFile|path/to.md|]` or a composition. The three sources are
`prompts/**` (authored for the workflows, live-editable), `agents|skills|commands/**`
(the very files flake-prompt deploys, read a *second* time here rather than
paraphrased), and `prompts/upstream/**` (from `flake = false` inputs, a
`/nix/store` path at both compile and run time, so update = `nix flake update
<input>` + rebuild).

**`promptFile` is compile-time-checked and run-time-read.** The path is checked
against the cabal package root when the module compiles and resolved against the
working directory when the leaf runs. That is why the package is rooted at the
repo root though its only sources are under `workflows/`, and why the cabal file
carries a long `extra-source-files` list with a comment explaining that a missing
glob is a package that builds nowhere but a git checkout — with `test/Spec.hs`
asserting the cover, because nothing else in the repo can see the gap.

**Assembly is by interpolation quasiquoters, and the seams are argued.**
`[__i|…|]` keeps linebreaks and unindents only the literal (so an interpolated
markdown document keeps its own indentation); `[iii|…|]` collapses to one line
(used for every workflow description); `[i|…|]` is verbatim (the `Orientation`
preambles). A `Prompt` hole splices the *document*, not a `Show` of it. Three
patterns recur:

1. **Rubric + adjustment.** `#{upstream}\n\n---\n\nONE ADJUSTMENT …` — the
   upstream rubric verbatim, then a block that voids its output format, its
   deliverable, or its verdict and states the panel's own. Nine of these.
2. **Derived rosters.** Counts and name lists are *computed from the list they
   describe* — `qaOfCommitOver siblings` splices `#{count (length siblings + 1)}`
   and the table; `grindSynthesisOver name lensNames` splices the roster it will
   refuse on; `liveViewSeverityVocabulary` renders `critical, high or medium`
   from one `NonEmpty Text` that *both* the auth lens's demand and the grind's
   ranking clause read. A lens added to a table arrives in its brief by being
   added.
3. **Empty-clause branches, not `mempty` splices.** `remediate`, `stackWorker`
   and `grindFlow` each have an explicit branch for the absent optional clause,
   because `"\n\n" <> mempty` leaves a colon pointing at nothing or two blank
   lines — "byte drift in a prompt, which no check outside this module's own pin
   can see."

**What agent-cat's surface already covers.** `[wf|…|]` with `{name}` holes is
the same idea and a stricter one: `Says` gives a hole exactly three meanings —
a live binding (one `interp` chunk under the name the binding prints), a `Text`
define (one literal chunk, *never fused* with the literals beside it), and a
nested prompt. Isaac's `#{...}` is untyped string interpolation; ours is a
typed splice where binder and hole cannot disagree because the hole *is* the
Haskell value. The rubric+adjustment pattern is `Says Text` — `[wf|{rubric}
--- ONE ADJUSTMENT…|]` where `rubric :: Text` — and it composes exactly as his
does, with the chunk boundary preserved (which is the property `Example.Harden`
already leans on for `{spec}`). Derived rosters are ordinary Haskell producing
`Text`. So pattern (1), (2) and (3) are all expressible today.

**What it would need.**

| Need | Status | Cost |
|---|---|---|
| A prompt body read from a markdown file | **missing.** Isaac's whole library is markdown on disk with one copy shared between deployment and workflow. | Cheap: a `[promptFileWF|path|]` TH quasiquoter producing `Text`, which is already a `Says` instance. **Compile-time embedding only** — a run-time read would break the property that the `Program` `agentic-run` executes is the value tier1 pinned. Say so out loud in its haddock: incite's live-editability is *bought* by having no conformance corpus. |
| A layout rule that survives an embedded document | **have it.** `[wf|…|]`'s rule (CRLF→LF, surrounding blank lines dropped, common indentation stripped, no trailing newline) is `[__i|…|]`'s, which is what incite settled on for the same reason. |
| Deliberate control of chunk boundaries | **have it, better.** `normalize` drops empty literals and a define never fuses; incite has to spell empty-clause branches by hand to avoid byte drift. |
| A hole that is not a `Text` or a handle (a list rendered as a table) | works by evaluating to `Text` in Haskell first. No change. |
| Prompt-level linting of prose written as Haskell literals | incite has `prompt-lint`, which explicitly widens its scope to `workflows/` because a growing share of its prompt prose is string literals no `.md` linter reaches. If agent-cat ever ships more than the example programs, the same hole opens on day one. |

---

## 4. Backends and adapters vs. agent-cat's engines

**incite's model.** `Incite.Backend` is 287 lines, most of it argument. Three
backends as **erased scope functions** — `(LeafName, Flow Text Text -> Flow Text
Text)` — because `Backend b` / `Model b m` are type-indexed and cannot sit in a
list together, and that erasure is what makes a lens × backend cross-product a
list comprehension instead of three hand-written copies. `NonEmpty` rather than
a list, so `spread`'s zip against `cycle` needs no guard and `claudeAgentBackend`
being first is a fact of the definition. The roster is a *pure function* of one
`Bool` (`backendsFor blocked`), with `blockOpencode` an `unsafePerformIO`/`NOINLINE`
CAF reading `BLOCK_OPENCODE` once — justified because a workflow is a top-level
CAF and threading a reader through every signature to carry one process constant
buys nothing, and everything downstream is a pure function of it.

Four decisions in that file are the substance:

- **Model pins are named, never inherited.** `gpt55 = codexModel "gpt-5.5/xhigh"`,
  because leaving it `defaultModel` means "whatever `~/.codex/config.toml`
  happens to say", and a global default of `gpt-5.6-sol` — which `codex-acp`
  *advertises* but cannot drive — silently killed three of `review-lite`'s five
  lenses while the tier went on describing itself as five independent reviewers.
  The effort suffix is part of the id because the backend splits one model into
  four entries and a bare key is ambiguous, which preflight refuses.
- **A pin can fall back.** `fable5 = claudeModel "fable" \`fallingBackTo\`
  claudeModel "opus"` — the Fable allowance is metered separately, `doctor` still
  lists it, `set_config_option` still succeeds, and the refusal arrives at the
  first `session/prompt` as `rate_limit`. Before the fallback, that killed a
  twelve-lens panel because a throw cancels its siblings. The cost is stated:
  a second `claude-agent-acp` process preflighted for the whole run.
- **Blocked drops the slot, it does not alias it.** Under `BLOCK_OPENCODE` the
  roster is two, not three-with-codex-twice, because `panelAcross` keys blocks
  `lens@backend` and a duplicate means one opinion paid for twice and ranked as
  two findings. "Two honest backends beat three slots holding two models."
- **The name moves with the scope.** `admits` reads the *backend's name*, so
  substituting codex's scope under the label `opencode` would keep the `fess`
  rubric admitted and run it on codex anyway. The substitution is therefore of
  the whole entry.

**agent-cat's model, compared.**

| Concern | incite / agent-functor | agent-cat |
|---|---|---|
| Who answers | a *scope wrapper* around a sub-flow: `withBackend claudeAgent fable5 (…)`, applied to whole panels or single leaves | a property of **the question**: `ask (model "reviewer" \`servedBy\` "deep") […]`, plus `tool`/`person` addressees |
| Read-only | a *scope*: `withMode Plan`, applied by the `reviewer` smart constructor so no reviewer can acquire write access | **structural**: permission is decided by the answer code (`permissionByCode`: only an ack/receipt — i.e. an `act` — may write; every `ask` is Cancel), so a read-only reviewer is one that does not `act` |
| Exec permission | `Grant` = `execGrant ["nix*"]`, an argv head-glob allowlist gating the `Exec` leaves the harness runs itself, *derived* from the check list | no argv, so no allowlist; the tool's own side is the adapter's |
| Multiple opinions | `panelAcross` (lens × backend cross-product, blocks headed `lens@backend`, reduced by `unionFindings` into **text**) and `spread` (one backend per lens, positional) | `panel [ask…]` — a fold in the **noncommutative verdict monoid**; `drawing n` for independent draws of one prompt |
| Engines | one ACP path, backend selected per scope; a `--backend` default a caller can override, which is exactly what several pins exist to defeat | `--scripted` (canned table), `--engine acp` (we own the adapter process), `--session deck-pane` (someone else owns it); the addressee/`servedBy` in the program says who answers |
| Price | `worstCaseCost . toSkeleton`, and the unbounded loops make it a sentinel: the recorded `cost grind-paradox` baseline is `4611686018427387927` worst-case leaf executions | `costSummary` min/max/**paths** + `level`/`size`/`askNodes`/`codes`, all finite because `Dynamic` is unreachable |

The engine story is *better* on our side in one specific way and thinner in
another. Better: an addressee is part of the question, so a program says who it
asks and the transport is a run-time choice, where incite has to argue site by
site about which leaves may inherit `--backend` and which must not — nine of
them (`implement`, `planLeaf`, `tripFess`, `fessAudit`, `stackPin`, the four
explore stances) carry a pin with a paragraph defending it, and `editPlan` and
the panels carry a paragraph defending the *absence* of one. Thinner: incite's `servedBy` analogue carries a *fallback* and a
preflight, and it has learned two production failures we have never seen —
an advertised model that cannot complete a turn, and a metered model that
refuses mid-run and cancels its siblings. If agent-cat's ACP engine ever fans
out, both are ours to meet.

---

## 5. Where agent-cat is short, precisely

Not a wish list — the four things that stopped me from writing an incite
workflow in `Agentic.Workflow` on paper.

1. **A fan-out that reduces to text.** `panel :: [Ask s] -> Rhs s 'CodeVerdict`.
   Every incite review tier fans out *prose* reviewers and reduces with
   `unionFindings` into blocks headed `lens@backend`, which a synthesis `ask`
   then ranks. Today the only way to write that here is `n` separate binds and a
   synthesis prompt with `n` holes — correct, static, and priced exactly, but
   written out by hand, because the scope index grows with every bind and a
   *list-driven* fold of binds is not directly typeable. incite builds all of
   its panels from list comprehensions over `(lens, backend)` pairs. **This is
   the single most valuable thing the Express phase can prove out**: either a
   `panelText`-style combinator whose members' answers stay individually
   spliceable, or an existential/`Live`-threading helper that folds a list of
   `Ask s` into a run of binds.
2. **A check with a real exit code.** `greenGate`/`verify` is the load-bearing
   idea of Isaac's whole acting half — "the one statement in this workflow that
   no agent authors" — and the 2026-08-12 retrospective that produced it is the
   best single piece of evidence in the repository. Our `act (tool "apply")`
   returns a *receipt the adapter authored*; nothing in the language distinguishes
   "the tool says it ran" from "the harness ran it and the kernel returned 0".
   Options: a fifth answer code for an exit status; or a `tool` party whose
   receipt is produced by the runner rather than by the adapter; or an explicit
   statement that agent-cat models the *dialogue* and a gate is the caller's
   business. Whichever — it should be a decision, not a silence.
3. **A loop whose decision is pure.** `revising c (atMost n) \x -> {review;
   amend}` is very close to `orchestrateWith` — bounded, unrolled, priced — but
   the review must be a *question*, so classifying a worker's own last line
   costs a leaf where incite spends nothing (`tripEnding`). Note the near-miss:
   `caseVerdict`'s three arms (approved / objected / **no answer**) are exactly
   `EndComplete` / `EndContinue` / `EndViolation`; the fourth ending
   (`WORK BLOCKED`) and the two budgets threaded beside the carrier
   (`TripBudget`) are what a bounded revision cannot carry. Worth asking whether
   the review clause should admit a *pure* verdict source over the carrier.
4. **Unbounded is not expressible, and that is mostly a feature.** `Dynamic` is
   a rung `Agentic.Builder` cannot construct. incite's default `workerFuel =
   Nothing` compiles to `loopUntil (maxBound \`div\` 2)` and its recorded price
   is a 19-digit sentinel — a number the repo's own docs call one "no operator
   can read anything from", which is why `stackFuel`, `liteFuel`,
   `grindTestsReviewFuel`, `repairFuel` and `budgetFuel` were all introduced as
   named finite constants and fenced as such. Our refusal to express the
   unbounded case is the same lesson arrived at from the other side, and it is
   worth saying so in the docs with his numbers as evidence.

Two smaller ones: there is no `withCapturedTranscript` analogue (a workflow
whose input is the *calling* session — `fess-audit` and `retro` need it), and no
place to hang the equivalent of `Orientation`, the pure preamble that tells a
stage where the evidence is after a loop has left an account in its hand. The
second is just a `Text` define and needs nothing; the first is a runner concern.

---

## 6. Recommendation — the two to implement first

### First: `review-lite` (with `post-commit-audit` as its driver)
The per-commit panel, and the workflow incite runs most. Concretely:
six reviewers over one artifact, each addressed to a *named model on a named
backend*; one of them behind a **cheap router** whose one-word answer decides
whether the expensive lens runs; a pure fold with no synthesis leaf.

Why it is the right first target:
- It is small (7 leaves), so it can be written out by hand today and still be
  honest about the fan-out gap — and writing it out is how we learn exactly how
  bad §5.1 is.
- The router is *already* agent-cat's shape: a cheap `ask` for a flag, then
  Haskell's own `if`/`when` on it. This is `Example.Harden`'s `confirm`+`when`
  pattern doing real work, and it exercises the flag code and the `ifFlag` node
  on something other than a person.
- It exercises three of the four answer codes (text reviewers, a flag router,
  and — if the synthesis writes a file — a receipt) and two of the three
  addressees, with `servedBy` doing what it was designed for: five reviewers,
  three serving models, stated per question rather than by wrapping scopes.
- It has a *published price* in incite's own docs (7 leaves either way, because
  it is pinned leaf by leaf), so our `cost` output has something external to
  agree with.
- Its failure modes are documented and testable: the loud default on a waffling
  router; `diffNamesHaskell` overruling a well-formed wrong `none`; the
  `fess`-never-on-codex pairing.

### Second: `ship-feature-lite`
The smallest *complete* acting workflow, and the only one in the repository
whose worst case is a finite fenced number (21 leaves).
`planLeaf >>> steer >>> orchestrateWith (Fuel 3) implement >>> reviewLiteFlow
>>> remediate >>> greenGate (repairFuel 3)`.

Why it is the right second target:
- **Everything in it is bounded.** Three worker trips, three repair trips. It is
  the one acting workflow that maps onto `revising … (atMost n)` without asking
  us to invent an unbounded loop, and its two loops give `costSummary`'s
  min/max/paths a real subject.
- It puts a **person in the middle, not at the end**: `steer` is a person
  question whose answer becomes part of the artifact the worker implements from,
  which is a use of `ask (person …)` we have no example of (`Harden` only
  `confirm`s at the end).
- It forces the §5.2 decision. The whole *point* of the tier, argued at length
  in its haddock and in `docs/workflows.md`, is that it ends on a check the
  harness ran rather than on the fixer's word. We cannot express it faithfully
  today, and implementing it is how the exit-code question gets answered rather
  than deferred.
- It reuses the first target verbatim (`reviewLiteFlow` is a shared binding), so
  the second implementation tests whether our surface supports incite's central
  discipline: *the workflows cannot drift in anything they share.*

**Third, if the phase has room:** `grind-tests`, for the `GrindSpec` shape —
a record of everything one audit supplies for itself, with the synthesis brief
and the fixer's rule *derived* from it, so no grind can audit under one set of
facts and repair under another. It is the best structural idea in the repository
and it is pure Haskell reuse, which our surface should support as well as his
does. **Not first:** `stack-prs` (four loops, three exec gates, a consent file),
and `pr-review`/`pr-address`, whose queues are discovered at run time — those
are the honest boundary of a statically-priced language, and are more useful as
a documented limit than as a target.
