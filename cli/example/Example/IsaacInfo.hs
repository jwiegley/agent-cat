{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Example.IsaacInfo
  ( isaacExamples,
    isaacBlurb,
    isaacHelp,
    isaacScript,
  )
where

import Agentic.Workflow (Example (..), wft)
import Data.Text (Text)
import Workflow.Extra.Isaac

-- ---------------------------------------------------------------------------
-- The registry, and the canned answers
-- ---------------------------------------------------------------------------

-- | The five, in the order they were written.
--
-- Four are whole programs; @review-lite@ is a program of its subject, which is
-- what @agentic-run … --input@ supplies. The distinction is the registry's and
-- not the language's: a 'Parameterized' is an ordinary Haskell function to a
-- 'Program', and every fold the CLI prints is the same for every input.
isaacExamples :: [(Text, Example)]
isaacExamples =
  [ ("plan-feature", Fixed planFeatureProgram),
    ("review-lite", Needs reviewLite),
    ("ship-feature-lite", Fixed shipFeatureLiteProgram),
    ("grind-tests", Fixed grindTestsProgram),
    ("stack-prs", Fixed stackPRsProgram)
  ]

-- | The one line @agentic-run list@ prints beside each of the five.
--
-- Beside the programs rather than in the runner, for 'isaacScript'\'s own
-- reason one step weaker: a blurb that lived in the CLI would describe a
-- program it cannot see, and would go stale the first time one of these was
-- reshaped. The fall-through is a name and not an @error@ so that a registry
-- row added upstream lists rather than crashes.
isaacBlurb :: Text -> Text
isaacBlurb = \case
  "plan-feature" -> "four exploration stances, a planner, six sequential plan lenses"
  "review-lite" -> "the per-commit panel, with its Haskell lens behind a cheap router (takes the commit)"
  "ship-feature-lite" -> "plan, steer, a capped worker loop, the panel, remediation, a green gate"
  "grind-tests" -> "a lens per serving model, a synthesis that refuses, a facts gate, a fixer loop"
  "stack-prs" -> "four capped loops, three exec gates, two human gates, a consent file"
  n -> n

-- | The page @agentic-run help \<name\>@ prints under the computed header
-- ('Agentic.Cli.rowHelp'), for each of the five.
--
-- Beside the programs for 'isaacBlurb'\'s reason, one step stronger: a page
-- states which transport a program wants and which of its endings never reach
-- an act, and both are facts about the /program/ — a page kept in the runner
-- would describe a shape it cannot see. The fall-through is the name and not an
-- @error@, so a row added upstream shows a thin page rather than crashing the
-- binary; @ci\/examples.sh@ runs @help@ for every registered name, which is
-- what turns that fall-through into a caught mistake.
--
-- __No page below names a number.__ The header carries @level@, @cost@,
-- @inputs@, @runFacts@ and @pins@ off the same 'Agentic.Plan.Facts' @list@
-- publishes, so a hand-copied price could only ever disagree with it.
--
-- __Four of the five refuse @--require-pinned@, and each says so.__ The
-- unpinned leaves are deliberate — @editPlan@'s paragraph defending the absence
-- of a pin is the whole of 'planFeatureProgram''s six plan lenses — so the
-- refusal is the language reporting a design decision, and a page that let an
-- operator discover it from a failed invocation would be hiding the decision.
isaacHelp :: Text -> Text
isaacHelp = \case
  "plan-feature" ->
    [wft|
    @incite@'s @plan-feature@ as a program: the request read from a tool, four
    exploration stances taken independently, a planner over them, and six plan
    lenses run in sequence — each one holing the answer before it, so the plan
    is narrowed rather than re-written six times.

    **Inputs.** none. The request is asked of a tool, which is what the original
    does; giving it an input would be a conversion rather than a translation,
    and this module is an experiment in faithfulness.

    **Transport.** Fine anywhere. It asks nobody's permission and writes no file
    of yours — every statement is a question — so a watched pane answers it as
    well as an adapter of the run's own, and `--scratch` changes nothing about
    what it means.

    ```sh
    agentic-run run plan-feature --engine acp --adapter claude
    ```

    **Rehearsal.** Every question answered from the row's own canned table,
    consulting nobody:

    ```sh
    agentic-run run plan-feature --scripted
    ```

    **Caveats.**

    * **It refuses `--require-pinned`.** The four stances and the planner each
      name the model that serves them; the six plan lenses deliberately do not,
      which is exactly what the original's own paragraph defending the absence
      of a pin asks for. So those six take the default answerer and `--route`
      accepts only the pinned names.
    * The six lenses are sequential and that is the point: each reads the last
      one's answer, so they cannot be reordered without changing what the plan
      says.
    * It produces a plan. Nothing here implements it.
    |]
  "review-lite" ->
    [wft|
    @incite@'s @review-lite@ as a program: the per-commit panel — correctness,
    unsupported claims, complexity, tests — with the Haskell lens behind a cheap
    router, and one report function both arms of that router call. The
    conditional lens is a branch, and a branch is terminal here, which is why
    the tail is a `function` rather than a rejoin.

    **Inputs.**

    * `subject` — the commit under review: the diff itself, spliced into every
      prompt as a `define`. It is declared with `stdinInputAs "subject"`, so a
      direct run reads strict UTF-8 from standard input when no explicit input
      flag supplies it. Empty stdin is a review of nothing.

    **Transport.** An adapter of the run's own, and a scratch directory you are
    willing to have written in — the report function ends in an act that writes
    the six blocks down, and `--scratch` names the only place an act may write.
    It asks no person, so nothing waits on you.

    ```sh
    agentic-run run review-lite --engine acp --adapter claude --scratch "$PWD" \
       --input-file subject=./commit.diff
    ```

    **Rehearsal.** The one input named empty, every question answered from the
    row's own canned table, consulting nobody:

    ```sh
    agentic-run run review-lite --scripted --input-arg subject=
    ```

    **Caveats.**

    * **It refuses `--require-pinned`**: the complexity lens is asked with no
      `served by`, deliberately, so the rest of the panel is routable by name
      and that one is not.
    * The router's default is loud. Only a clean *no* skips the Haskell lens, so
      a malformed answer buys the review rather than skipping it — which is the
      safe direction for a gate whose false arm removes a reviewer.
    * The report reconciles nothing. It writes the blocks down in the narrowing
      order, which is the artefact the original produces and not a summary of
      it.
    |]
  "ship-feature-lite" ->
    [wft|
    @incite@'s @ship-feature-lite@ as a program: the request read from a tool, a
    plan, a steering question, a capped worker loop, the review panel,
    remediation, and a green gate at the end. It is the one of the five that
    carries the most of the original's failure policy, and the place that policy
    does not fit is named in the caveats rather than papered over.

    **Inputs.** none. The request is asked of a tool, as the original does.

    **Transport.** Fine anywhere. There is no act in this program and no person
    to ask, so it writes no file of yours and nothing waits on you; an adapter
    of the run's own is the usual shape and `--scratch` changes nothing about
    what it means.

    ```sh
    agentic-run run ship-feature-lite --engine acp --adapter claude
    ```

    **Rehearsal.** Every question answered from the row's own canned table,
    consulting nobody:

    ```sh
    agentic-run run ship-feature-lite --scripted
    ```

    **Caveats.**

    * **It refuses `--require-pinned`**: the implementing, remediating and
      repairing asks carry no `served by`, which is where the original puts its
      worker on whatever backend the invocation gives it.
    * **The green gate is a question and not an exit code.** The original ships
      two combinators named apart on purpose — one runs argv and reads the
      kernel's answer, one asks an agent — and only the second is spellable
      here. So "the tree is green" is somebody's answer, and a run that says so
      has not compiled anything.
    * Both capped loops end either settled or exhausted, and an exhausted loop
      stops rather than shipping. That is the cheap ending, and it changes
      nothing.
    |]
  "grind-tests" ->
    [wft|
    @incite@'s @grind-tests@ as a program: the facts read from a tool, a spread
    of six lenses — vacuity, coverage, properties, mutation, stubbing, sleeps —
    one per serving model, a synthesis that is allowed to *refuse*, a facts gate,
    and a bounded fixer loop with an audit inside it.

    **Inputs.** none. The facts are asked of a tool, as the original does.

    **Transport.** Fine anywhere: every statement is a question, there is no act
    and no person, so it writes no file of yours. An adapter of the run's own is
    the usual shape, and its fresh session per question is worth something here
    — six lenses spread across serving models is the shape this program is
    about.

    ```sh
    agentic-run run grind-tests --engine acp --adapter claude
    ```

    **Rehearsal.** Every question answered from the row's own canned table,
    consulting nobody:

    ```sh
    agentic-run run grind-tests --scripted
    ```

    **Caveats.**

    * **It refuses `--require-pinned`**: the fixer and the audit's fixer carry
      no `served by`. Every lens does, which is the point of the row — the
      spread is *one per serving model*, so a route table can put six readings
      on six providers.
    * **The synthesis may refuse, and the facts gate reads it.** That is an
      ending in which nothing is fixed because nothing was established, and it
      is a result rather than a failure.
    * The original's fixer loop is unbounded; here it has a bound. That is a
      departure and it is deliberate: an unbounded loop has no price, and this
      registry's whole discipline is that a program is priced before it is run.
    * The fan-out is a static list, so the six lenses are the six in the source
      and not a roster computed from the tree.
    |]
  "stack-prs" ->
    [wft|
    @incite@'s @stack-prs@ as a program: the stack's facts read from `git`, a
    slice, a person's go-ahead, a bootstrap act, a capped cutting loop, a real
    exec gate over `verify-stack.sh`, a capped triage loop, a second person's
    go-ahead, a consent file, and the promotion act behind it.

    **Inputs.** none. The facts are asked of `git`, as the original does.

    **Transport.** A watched pane, and a scratch directory you are willing to
    have written in. Two of its gates are `confirm (person …)` — an unattended
    run answers them from the adapter rather than from you — and two of its
    statements are acts, which may write only where `--scratch` points.

    ```sh
    agentic-run run stack-prs --engine acp --adapter claude --scratch "$PWD" \
       --require-pinned
    ```

    **Rehearsal.** Every question answered from the row's own canned table,
    consulting nobody and running nothing:

    ```sh
    agentic-run run stack-prs --scripted
    ```

    **Caveats.**

    * **It is the one of the five that accepts `--require-pinned`**: every model
      ask in it names the model that serves it.
    * **The consent gate is a file the run may not create.** `test -f
      .stack-promote-approved` is asked as a question, and a run that wrote its
      own consent would have none — so the promotion act is unreachable until
      you put that file there yourself.
    * A rehearsal answers both person gates *yes* from the canned table, which
      exercises the loop and tells you nothing about what you would have said.
      That is what makes the pane a requirement here rather than advice.
    * Expressed **partially**: two of the original's four capped loops, and no
      per-trip budget gate. The two that landed are the ones the failure policy
      turns on, and the omission is recorded here rather than left for a reader
      to discover from the price.
    |]
  n -> n

-- | The canned replies a @--scripted@ run of one of these answers from, keyed
-- by prefix — @Agentic.Exec.scriptedReply@ takes the first entry whose key is a
-- prefix of the rendered prompt.
--
-- __The keys are the prompt defines themselves__, never a copy of their first
-- line. Every leaf below is written as @[wf|{someLens}\\n{someHandle}|]@, so
-- the define /is/ the prompt's first chunk and a key that is the define is a
-- prefix by construction rather than by proofreading.
--
-- __Only the text questions need entries.__ 'Agentic.Exec.scriptedDefault'
-- answers a flag @yes@, a verdict @APPROVE@ and a receipt @DONE@, and those
-- three defaults settle every loop and take every @if@'s first arm — which is
-- what a scripted run is for. A /text/ default, though, is the prompt echoed
-- back, and these workflows splice each answer into the next prompt: six
-- sequential plan lenses would echo a prompt that had already swallowed the
-- five before it. So every text question is answered here, shortly.
isaacScript :: Text -> [(Text, Text)]
isaacScript = \case
  "plan-feature" ->
    [ (readRequest, "Add a --dry-run flag to the exporter."),
      (intrepidStance, "Path: add the flag in Cli.hs, thread it to Export.run, short-circuit the write."),
      (skepticStance, "Risk: Export.run is called by two other entry points; both pattern-match its result."),
      (contemplativeStance, "Options: a flag threaded, or a Writer of intended effects. The second is testable."),
      (architectStance, "Shape: the flag belongs in Cli.Options; Export must not learn about the CLI."),
      (planBrief, "1. Add DryRun to Cli.Options. 2. Thread it into Export.run. 3. Test both arms."),
      (ponytailLens, "1. Add DryRun to Cli.Options. 2. Thread it. 3. Test both arms."),
      (denotationalLens, "1. DryRun means: every effect is computed and none is performed. 2. Thread it. 3. Test."),
      (riskLens, "1. Test the two other callers first. 2. DryRun means no effect performed. 3. Thread it."),
      (verificationLens, "1. Test the two callers (cabal test). 2. DryRun: no effect performed (golden). 3. Thread it."),
      (lookaheadLens, "1. Test the two callers. 2. Thread the flag. 3. Ship the golden test last."),
      (simpleEnglishLens, "1. Test the two callers. 2. Add the flag. 3. Add the golden test.")
    ]
  -- The subject is an @--input@ now and not an answer, so the entry that
  -- answered the tool leaf which fetched it is gone: the text it returned is
  -- what @ci\/examples.sh@ passes as @--input-arg subject=…@.
  "review-lite" ->
    [ (correctnessLens, "src/Export.hs:12 -- writeFile is not atomic; a crash truncates the file."),
      (fessLens, "The message claims the write is atomic. The diff shows writeFile. Verification gap."),
      (complexityLens, "No braids: one concern, one file."),
      (ponytailReviewLens, "Nothing to cut."),
      (qaFence, "Partial write on a full disk leaves a half file that the reader accepts."),
      (haskellHouseLens, "Totality: `head paths` at line 9 is partial on an empty export set.")
    ]
  "ship-feature-lite" ->
    [ (readRequest, "Make the exporter atomic."),
      (planBrief, "1. Write to a temp file. 2. Rename into place. 3. Test the crash window."),
      (planSteerBrief, "The bar: a kill -9 mid-write must leave the old file intact."),
      (tripStatusBrief, "APPROVE"),
      (implementBrief, "Wrote to Export.hs: temp file plus rename. Tests pass, 41/0.\nWORK COMPLETE"),
      (remediateBrief, "Closed the fsync finding; rejected the lock-file finding as out of scope."),
      (repairBrief, "Nothing to repair.")
    ]
  "grind-tests" ->
    [ ( grindFactsBrief,
        "Target: /src/exporter. Suite: cabal test. Runner: nix flake check."
      ),
      (grindLens "vacuous" "assertions that cannot fail", "test/ExportSpec.hs:20 -- asserts True after the call."),
      (grindLens "coverage" "the code paths no test reaches", "Export.hs error branch is unreached."),
      (grindLens "property" "the invariants that want a property test", "round-trip encode/decode wants a property."),
      (grindLens "mutation" "the mutations the suite survives", "flipping the retry bound leaves the suite green."),
      (grindLens "stubs" "the stubs, the skips and the xfails", "test/SlowSpec.hs is entirely @skip."),
      (grindLens "sleeps" "the sleeps and the magic timeouts", "threadDelay 200000 in test/RaceSpec.hs."),
      (grindSynthesisBrief, "1 critical (vacuous), 2 high (mutation, stubs), 3 medium."),
      (tripStatusBrief, "APPROVE"),
      (grindRule, "Closed the vacuous assertion and the skip. Rejected the sleep: it is a real timeout.\nWORK COMPLETE")
    ]
  "stack-prs" ->
    [ (stackFactsBrief, "trunk: main. remote: origin. verify: ./verify-stack.sh. diff: 1,840 lines."),
      (stackSliceBrief, "1. types (280). 2. decoder (520). 3. runner (490). 4. cli (550)."),
      (stackSteerBrief, "Keep the decoder branch under 500 lines; split it if it grows."),
      (stackStatusBrief, "APPROVE"),
      (stackCutBrief, "Cut all four branches; every one builds alone.\nWORK COMPLETE"),
      (stackTriageBrief, "Addressed six comments downstack-first; restacked after each.\nWORK COMPLETE")
    ]
  _ -> []
