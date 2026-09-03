-- | Five established workflows adapted from Isaac Shapira's @incite@ suite.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
-- @MonoLocalBinds@ for the reason "Agentic.WF" enables it: it is what keeps
-- 'reviewPanelOver'\'s 'KnownIx' constraint out of
-- @-Wsimplifiable-class-constraints@, which fires on any signature mentioning
-- a class that has exactly one instance standing on another.
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}

module Workflow.Extra.Isaac
  ( planFeatureProgram,
    reviewLite,
    shipFeatureLiteProgram,
    grindTestsProgram,
    stackPRsProgram,
    reviewPanelOver,
    reviewReport,
    readRequest,
    intrepidStance,
    skepticStance,
    contemplativeStance,
    architectStance,
    planBrief,
    ponytailLens,
    denotationalLens,
    riskLens,
    verificationLens,
    lookaheadLens,
    simpleEnglishLens,
    correctnessLens,
    fessLens,
    complexityLens,
    ponytailReviewLens,
    qaFence,
    haskellHouseLens,
    planSteerBrief,
    tripStatusBrief,
    implementBrief,
    remediateBrief,
    repairBrief,
    grindFactsBrief,
    grindLens,
    grindSynthesisBrief,
    grindRule,
    stackFactsBrief,
    stackSliceBrief,
    stackSteerBrief,
    stackStatusBrief,
    stackCutBrief,
    stackTriageBrief,
  )
where

-- One import, and it is the authoring surface. There used to be a second — the
-- way back from a define's pieces to its text, which every define in this
-- module was written through — and 'wft' is that way back, inside the quoter.
import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Prelude

-- ---------------------------------------------------------------------------
-- The prompt library — @Incite.Prompts@, as defines
-- ---------------------------------------------------------------------------

-- $prompts
--
-- @Incite.Prompts@ is ninety top-level @Prompt@ CAFs and nothing else: data,
-- not logic. These are the same thing at the scale this module can carry —
-- Isaac's own words where a rubric is short, a faithful summary where it is a
-- page, and in every case the /first chunk/ of the leaf that uses it, which is
-- what lets 'isaacScript' key on it.
--
-- Every define below that runs to more than one line is written at the fence,
-- so that the text a leaf sends is read in the source at the width it is sent
-- at, under the same layout rule as the prompts that hole it — and so that the
-- one place a prompt's shape is decided is the quoter.
--
-- __Why these are 'Text' and not the 'Words' a prompt is.__ A hole-free fence
-- /is/ a 'Words', and 'Says' splices one into a prompt as happily as it splices
-- a 'Text' — that instance exists for exactly this, and it is the shape a
-- @define@ has in the language. Two things ask for the 'Text' anyway, and both
-- are about not moving a byte:
--
--   * 'isaacScript' keys its canned replies on the defines themselves, and a
--     key is a 'Text' matched as a prefix of a /rendered/ prompt. Defines typed
--     as 'Words' would be rendered at every one of those rows instead — one
--     conversion, written out once per row, in the one place the module argues
--     should read as \"the key is the define\".
--   * __Chunking is normative.__ @plan --raw@ prints the chunk list, so a
--     define that splices as /two/ chunks where it spliced as one is a visible
--     change even when the prompt's bytes are identical. 'qaFence', 'grindLens'
--     and 'grindSynthesisBrief' hole a computed count or a derived table; as
--     'Words' each of those holes would carry a chunk boundary into every
--     prompt that splices them, and as 'Text' they carry the one @lit@ they
--     always did.
--
-- So both fences are here, each spelled in its own brackets: @[wft|…|]@ for a
-- define, whose value is the text, and @[wf|…|]@ for a leaf's prompt, whose
-- value is the chunks. This module used to write the first as @wfText [wf|…|]@
-- — in front of every define below, with a local function and an import of
-- @wordsClosed@ to carry it — and that repetition is what 'wft' exists to end.
-- Not one byte moved when they were swapped. The sharing argument says none
-- could — the two quoters share the parser, the layout rule and the
-- empty-literal drop, and differ only in what they stage a fragment as — and
-- because that equality is the whole safety argument for the sweep,
-- @ci\/policies.sh@ checks it as two expressions rather than trusting the
-- argument (the probe row that keeps the tree's last @wfText@).

-- | A number as prompt text, for the two briefs that tell a leaf how many
-- blocks it is one of. @Incite.Review.count@.
tshow :: Int -> Text
tshow = T.pack . show

-- | A roster as the bullet table the two derived briefs hole, one row per
-- entry. @qaOfCommitOver@ and @grindSynthesisOver@ derive theirs from the very
-- list the panel is built from, and so do 'qaFence' and 'grindSynthesisBrief'.
bullets :: [(Text, Text)] -> Text
bullets rows = T.intercalate "\n" ["- " <> n <> " -- " <> owns | (n, owns) <- rows]

-- The four exploration stances (@prompts\/explore\/*.md@, summarised) --------

-- | @prompts\/explore\/intrepid.md@, summarised. The path, not the risks.
intrepidStance :: Text
intrepidStance = [wft|
  You are bold and ambitious. Your job is the shortest path from here to
  working code in a user's hands. Three other stances cover the risks, the
  design alternatives, and the shape of the tree. Do not repeat their work.

  Read the code first and find the seams the codebase already establishes.
  Then sketch the implementation as a concrete, ordered sequence. For each
  move: name the actual identifier, say what changes and what done looks
  like, point at existing code showing the pattern, and order the moves so
  that each works without a later one. Separate what is net-new from what
  follows an existing trail: net-new is where the risk concentrates, so
  flag it for the skeptic.

  If the direct path carries a cost, say the cost plainly. Routing around a
  real cost is fine; capitulating to an imagined one is not.|]

-- | @prompts\/explore\/skeptic.md@, summarised. Its two best sentences are
-- quoted rather than paraphrased.
skepticStance :: Text
skepticStance = [wft|
  You are the skeptic. Your job is to find what will go wrong, not to
  confirm the idea sounds reasonable. You are reading code, not writing it.

  Trace the blast radius before you list a single risk. A risk that you did
  not trace to a concrete mechanism is not a risk -- it is anxiety, and the
  planner will rightly ignore it.

  Enumerate: what breaks (name the caller, the format, the version); the
  edge cases this codebase actually hits; and silent failures, your
  highest-value catch -- a wrong answer with a green checkmark is the
  disaster.

  Three real risks beat ten plausible-sounding ones.|]

-- | @prompts\/explore\/contemplative.md@, summarised. The design options.
contemplativeStance :: Text
contemplativeStance = [wft|
  You are the contemplative stance. Your job is the design space, not the
  path and not the risks. Name two or three shapes this change could take,
  and for each: what it makes easy, what it makes hard, and what it commits
  the tree to that a later change would have to undo.

  Prefer the option that makes an illegal state unrepresentable over the
  option that checks for it. Say which option you would take, and why the
  others lose.|]

-- | @prompts\/explore\/architect.md@, summarised. Reads the tree, not the
-- request.
architectStance :: Text
architectStance = [wft|
  You are the architect. The other three stances argue about the change;
  none of them was asked what shape it has to land in. Read the tree.

  Say where this work belongs: which module owns it, which boundary it
  must not cross, which existing abstraction it extends rather than
  parallels. Name the file that should hold each piece. A change that lands
  beside the abstraction it should have extended is the failure you exist
  to prevent.|]

-- | @prompts\/plan.md@, summarised: the reduction the four stances narrow into.
--
-- The narrowing order — skeptic, architect, contemplative, intrepid — is
-- @hierarchical@'s, and here it is the order of the holes. @incite@ reduces the
-- fan-out with a /pure/ function and hands the reduced text to this leaf; the
-- reduction has no combinator here, so the order lives in the prompt instead,
-- which is the same order and one fewer moving part.
planBrief :: Text
planBrief = [wft|
  Write the implementation plan. Four stances were asked first, and their
  reports follow in narrowing order: what breaks, then the shape it must
  land in, then which design, then the moves. The last block is the request
  itself.

  Produce numbered steps. Each step names the file it touches, what changes,
  and how a reader would know it is done. No step may depend on a later one.|]

-- The six plan lenses (@editPlan@) -----------------------------------------

-- | @ponytailLadder@, as a plan lens: delete first.
ponytailLens :: Text
ponytailLens = [wft|
  Ponytail lens. Rewrite the plan below, deleting first.

  For each step ask, in order: does this need to exist at all; can the
  standard library do it; can an existing abstraction in this tree do it;
  can it be one line instead of fifty. Delete the steps that answer yes.
  Output the plan, not a critique of it.|]

-- | @prompts\/plan-denotational.md@, summarised.
denotationalLens :: Text
denotationalLens = [wft|
  Denotational lens. Rewrite the plan below so that each step says what the
  thing it builds MEANS before it says how it is built. Where a step
  introduces a type, state its denotation in one line. Where two steps
  introduce two spellings of one meaning, merge them.
  Output the plan.|]

-- | @prompts\/plan-risk.md@, summarised.
riskLens :: Text
riskLens = [wft|
  Risk lens. Rewrite the plan below so that the step whose failure costs
  the most is the step that is verified first. Add the check each risky
  step needs; delete a check that guards nothing.
  Output the plan.|]

-- | @prompts\/plan-verification.md@, summarised.
verificationLens :: Text
verificationLens = [wft|
  Verification lens. Rewrite the plan below so that every step names the
  command or the test that decides whether it worked. A step whose done
  condition is a person's opinion is a step that is not planned yet.
  Output the plan.|]

-- | @lookaheadLens@, summarised: reorder for irreversibility.
lookaheadLens :: Text
lookaheadLens = [wft|
  Lookahead lens. Reorder the plan below so that the irreversible steps
  come last and the steps that teach you something come first. A migration,
  a published artefact, a deleted file: each is a step that cannot be
  walked back, and each should stand behind everything that could still
  change the design.
  Output the plan.|]

-- | @simpleEnglishLens@, summarised: an ASD-STE100 reword.
simpleEnglishLens :: Text
simpleEnglishLens = [wft|
  Simple English lens. Reword the plan below in Simple Technical English:
  one instruction per sentence, active voice, present tense, no word used
  in two senses. Change no step and drop no step -- only the words.
  Output the plan.|]

-- The review lenses (@review-lite@) ----------------------------------------

-- | The correctness lens from @incite@, summarised.
correctnessLens :: Text
correctnessLens = [wft|
  Correctness lens. Read the change below and report only defects that are
  wrong on inputs this code will actually see. For each: the location, the
  input that reaches it, and what it produces instead of the right answer.
  Quote the line you are pointing at.

  One line per finding, with a severity. If the change is correct, say so
  in one line rather than manufacturing a critique.|]

-- | The @fess@ honesty rubric, summarised — and the one rule it states twice.
--
-- @admits@ is 'False' in exactly one case in @incite@: this rubric never runs
-- on one backend, keyed on the /body/ rather than the name so that @docsAccuracy@
-- (which is this text re-pointed at prose) is caught without anyone
-- remembering to add it. There is nothing to key here: a serving model is
-- named per question, so the pairing that must not exist is a pairing nobody
-- wrote.
fessLens :: Text
fessLens = [wft|
  Fess lens. Audit the claims made about this change against the change
  itself. Four shapes, most important first:

  - a verification gap: a claim that something was checked, where nothing
    in the record shows the check running;
  - spec drift: the change does something other than what was asked;
  - scope creep: the change does more than what was asked;
  - a quiet downgrade: a bar that was lowered without saying so.

  A claim that a mechanism FIRED is proved by the log line showing it fire
  and by nothing else. The eventual outcome is not the mechanism.

  End with a severity-ranked list of the gaps the author did not report.|]

-- | The complexity lens from @incite@, summarised.
complexityLens :: Text
complexityLens = [wft|
  Complexity lens. What is braided together in this change that should be
  separate? Name each braid: the two concerns, the line where they meet,
  and the seam a reader would cut on. Do not report defects and do not
  report things that should not exist -- other lenses own both.|]

-- | The ponytail lens over a commit, summarised.
ponytailReviewLens :: Text
ponytailReviewLens = [wft|
  Ponytail lens. What in this change should not exist at all? Reinvented
  standard library, a dependency that buys one function, an abstraction
  with one caller, flexibility nothing asked for. One line per cut: what
  to delete, and what replaces it.|]

-- | The lenses @review-lite@ runs BESIDE its qa leaf, each with the question it
-- owns — @Incite.Review.qaSiblings@.
--
-- A table, not a sentence: drop a lens and the qa leaf would otherwise go on
-- declining findings to an owner that no longer exists.
qaSiblings :: [(Text, Text)]
qaSiblings =
  [ ("correctness", "whether the change is correct on the inputs it will see"),
    ("fess", "whether its claims match the diff"),
    ("complexity", "what is braided together"),
    ("ponytail", "what should not exist"),
    ("haskell", "the Haskell: types, totality, strictness and instances")
  ]

-- | The qa lens with its roster written out — @qaOfCommitOver qaSiblings@.
--
-- Both counts are /derived/ from 'qaSiblings' rather than spelled, which is
-- @incite@'s reason: a lens added to the tier would otherwise leave this leaf
-- telling its reader a stale reviewer count, which is prose that nothing goes
-- red on.
qaFence :: Text
qaFence = [wft|
  Adversarial QA lens. Yours is the question none of the others asks:
  how does this fail?

  You are one of {reviewers} independent reviewers and there is no synthesis
  step behind you, so anything you repeat ships twice. The other {siblings} own
  the following, under the name each one's block carries:

  {roster}

  Do not report any of those. Look for: a trust boundary this change
  moves or crosses; failure under conditions the happy path never sees;
  an error path that loses what a debugger would need; a contract with
  something outside this change that it alters on one side only.

  One line per finding -- location, how it fails, what the failure costs.|]
  where
    reviewers = tshow (length qaSiblings + 1)
    siblings = tshow (length qaSiblings)
    roster = bullets qaSiblings

-- | The router's whole brief — @Incite.Review.haskellTriage@, adapted to a
-- yes\/no question.
--
-- @incite@ asks for one word and reads it with a substring-free equality;
-- 'confirm' asks the same question at the flag code, which is the same brief
-- with the answer format changed. What does /not/ carry over is the policy
-- around the word: see 'reviewLite'.
haskellTriageBrief :: Text
haskellTriageBrief = [wft|
  You are a router, not a reviewer. The input below either shows the diff
  or names the change. If it shows the diff, read only the paths its
  headers touch. If it only names a ref, run `git show --name-only` on it
  and read only the path list -- never the full diff.

  Answer yes if any touched path ends in `.hs`, `.lhs`, `.hs-boot`, `.hsc`
  or `.cabal`; answer no otherwise.

  Do not review the change. Do not report findings. One word.|]

-- | @haskellOfHouse@ — the upstream Haskell rubric plus the house addendum,
-- summarised. Thirty kilobytes in @incite@, which is why it stands behind a
-- router.
haskellHouseLens :: Text
haskellHouseLens = [wft|
  Haskell lens. Types, totality, strictness and instances, in that order.

  - Types: does a type admit a state the code then has to check for?
  - Totality: a partial function, an incomplete pattern, a `head`, a
    `fromJust`, a `read` -- name it and say what reaches it.
  - Strictness: a lazy accumulator, a lazy field in a record that is folded
    over, a space leak with a name.
  - Instances: an orphan, an instance whose laws do not hold, a `Semigroup`
    that is not associative on the values it will see.

  One line per finding, with a severity, quoting the line.|]

-- | What the fold prints in place of the Haskell block when the router says no
-- — @routeHaskell@'s @Right@ arm, verbatim.
noHaskellEdits :: Text
noHaskellEdits = "No Haskell edits."

-- | The report the six blocks are folded into.
--
-- @review-lite@ has no synthesis leaf: its fold is @hierarchical@, a /pure/
-- reorder-then-union, chosen because six independent opinions are worth more
-- unreconciled than one reconciled one. There is no pure combinator over
-- answers here, so the fold is a tool that writes the blocks down in the
-- narrowing order — which is a leaf @incite@ does not pay for.
reviewReportBrief :: Text
reviewReportBrief = [wft|
  Write the review below to `review-lite.md` in the current directory,
  one block per reviewer, under the heading each reviewer's name gives it,
  in the order the blocks arrive -- correctness, haskell, fess, qa,
  complexity, ponytail. Reconcile nothing and rank nothing: six
  independent opinions are the artefact. Then reply DONE.|]

-- The acting half ----------------------------------------------------------

-- | The subject every one of these workflows opens by fetching.
--
-- @incite@'s workflows are @Flow Text Text@ and @workflowReq@ /demands/ an
-- input at the CLI. A 'Program' has no input, so the subject is asked of a
-- tool. This is a real difference and not a paraphrase: the operator's text
-- reaches @incite@'s first leaf as data, and reaches this one as an answer.
readRequest :: Text
readRequest = [wft|
  Read the change request for this run and reply with it verbatim,
  and with nothing else.|]

-- | @planSteer "implementation"@, verbatim.
--
-- It asks for the acceptance bar, not for \"any guidance\", because
-- @agent-functor@'s @steer@ passes the plan through unchanged on an empty
-- submit: a question that asks for guidance in general is one an operator can
-- honestly answer in four seconds by pressing enter, and then nothing in the
-- run states what the change has to clear.
planSteerBrief :: Text
planSteerBrief = [wft|
  Review the plan -- state the acceptance bar this change must clear, and
  any other guidance, before implementation begins.|]

-- | The worker's brief — @Incite.Feature.implementLeaf@, with its two rules of
-- the record quoted, and a run was lost to each.
implementBrief :: Text
implementBrief = [wft|
  Implement this plan fully in the current repository -- edit the files
  directly.

  You are running under an orchestrator that will call you again with your
  own summary as its input, so write the summary for your successor: what
  you changed, what is left, and what it needs to know to continue.

  Two rules of the record, and a run was lost to each:

  - A claim that a mechanism fired -- terminated, killed, scrubbed, cleaned
    up -- quotes the log line that shows the firing. The eventual outcome is
    not the mechanism.
  - Before you claim the last step, run the suites and write the closing
    counts into the final commit body, and only then write the summary. A
    green that lives only in a summary is a green nobody can check.

  End with a status line, alone on the last line: WORK COMPLETE, WORK
  REMAINS, or WORK BLOCKED.|]

-- | The orchestrator's own reading of the worker's last line — @tripEnding@ as
-- a /question/, because it cannot be a function here.
--
-- @incite@ spends nothing on this: @tripEnding@ is a pure fold over the
-- summary's last non-empty line, classifying it four ways. An answer here is a
-- handle and not a value, so the classification is a leaf. Two of the four
-- endings survive the translation; see 'shipFeatureLiteProgram'.
tripStatusBrief :: Text
tripStatusBrief = [wft|
  You are the orchestrator, not a reviewer. Read ONLY the last non-empty
  line of the summary below.

  - If it is WORK COMPLETE, reply with exactly APPROVE.
  - If it is WORK REMAINS, reply OBJECTION: work remains.
  - If it is WORK BLOCKED, reply OBJECTION: blocked, followed by the reason.
  - If it is none of those, reply OBJECTION: status line missing.

  Do not judge the work. Read the line.|]

-- | @codeRule@: the artefact rule every code fixer stands under.
codeRule :: Text
codeRule = [wft|
  The code is the artefact and the review is the record. Correct the CODE.
  Never edit the review to make a finding go away, and never weaken a test
  to make a check pass: a weakened assertion is the cheapest way there is
  to turn a real failure into a green one.|]

-- | @closeWithChanges@, verbatim.
closeWithChanges :: Text
closeWithChanges = [wft|
  Close with what you changed and what you rejected, in one paragraph.
  This leaf runs once and nothing calls it again, so a finding you leave
  open leaves the run with it open.|]

-- | The green gate's question.
--
-- __This is @agentVerify@ and not @verify@.__ @agent-functor@ has both, named
-- apart on purpose: @verify@ runs argv itself and reads the kernel's exit code,
-- and @agentVerify@ asks the agent and is documented as trusting its PASS.
-- Nothing in this language can spell the first — an act returns a receipt the
-- /answerer/ authored — so this is the second, and it is labelled as such
-- rather than dressed as the first.
greenGateBrief :: Text
greenGateBrief = [wft|
  Run `nix flake check` in the current repository and read its exit code.

  - Exit 0: reply with exactly APPROVE.
  - Anything else: reply OBJECTION: followed by the first failing line.

  Report the exit code you saw. Do not report the code you expected.|]

-- | The repair leaf under the gate.
repairBrief :: Text
repairBrief = [wft|
  The gate below is red. Fix the tree so that `nix flake check` passes.

  Do not silence the check, do not lower a warning level, and do not mark a
  test skipped. There are no pre-existing issues: you branched from a
  passing build.|]

-- | The remediation leaf's brief.
remediateBrief :: Text
remediateBrief = [wft|
  Below is a panel's verdict on the work, and then the work itself. Close
  every finding the panel raised, in the code.|]

-- The grind ----------------------------------------------------------------

-- | The facts probe every grind's facts file ends with, and the line it emits
-- outside the target checkout.
grindFactsBrief :: Text
grindFactsBrief = [wft|
  Read the target checkout's facts file and reply with it verbatim.

  Then probe every path it names. If any named path does not exist here,
  reply with the single line FACTS PATHS UNRESOLVED and nothing else: this
  is not the checkout the facts describe.|]

-- | The lens table @grind-tests@ spreads one per serving model, with the
-- question each one owns.
--
-- __The order is semantic.__ In @incite@ the table is zipped against
-- @cycle backends@, so position picks the model, and @gsPins@ exists to state
-- the one assignment that is policy rather than position. Here the serving
-- model is named on the question itself, so every assignment is a pin and the
-- distinction does not arise — the table's order is free to stay thematic.
grindLensRoster :: [(Text, Text)]
grindLensRoster =
  [ ("vacuous", "assertions that cannot fail"),
    ("coverage", "the code paths no test reaches"),
    ("property", "the invariants that want a property test"),
    ("mutation", "the mutations the suite survives"),
    ("stubs", "the stubs, the skips and the xfails"),
    ("sleeps", "the sleeps and the magic timeouts")
  ]

-- | One grind lens's brief, derived from its row of 'grindLensRoster'.
grindLens :: Text -> Text -> Text
grindLens name owns = [wft|
  Test-suite audit, `{name}` lens. You own {owns}.

  Read the tree named in the facts below. Report only findings of your own
  kind: five other lenses are reading the same tree and anything you repeat
  is ranked twice. For each finding: the file and the test, what is wrong,
  and what it would cost to leave it.

  One line per finding, with a severity of critical, high, medium or low.|]

-- | The synthesis brief, with its roster derived from the table it will refuse
-- on — @grindSynthesisOver@.
--
-- The refusal is the point: an unauthenticated backend returns nothing, and
-- nothing folded into a ranked list reads exactly like a clean tree.
grindSynthesisBrief :: Text
grindSynthesisBrief = [wft|
  Synthesise one ranked report from the lens blocks below and write it to
  `docs/audits/grind-tests-<date>.md`.

  You were served by exactly {lenses} lenses, and they are:

  {roster}

  If any block above is missing or empty, STOP and say which one. An
  unauthenticated backend returns nothing, and nothing folded into a
  ranked list reads exactly like a clean tree.

  If any block carries the line FACTS PATHS UNRESOLVED, repeat that line
  and stop.

  Otherwise: de-duplicate, rank by severity, and say for each finding
  which lens raised it.|]
  where
    lenses = tshow (length grindLensRoster)
    roster = bullets grindLensRoster

-- | The facts gate — @decideFactsResolved@ behind a fuel-1 @loopUntil@, as a
-- question.
--
-- In @incite@ this is a pure scan of the synthesis output for one line, wrapped
-- in a loop whose exhaustion aborts the run before any fixer acts. Here the
-- scan is a leaf and the abort is the empty else arm of an @if@.
factsGateBrief :: Text
factsGateBrief = [wft|
  Read the report below. Answer no if it contains the line FACTS PATHS
  UNRESOLVED, or if it says a lens block was missing or empty. Answer yes
  otherwise.

  One word. Do not summarise the report.|]

-- | The grind's artefact rule, spliced with the same facts the audit ran under
-- — @grindRule gsFacts@ — so no grind can audit under one set of facts and
-- repair under another.
grindRule :: Text
grindRule = [wft|
  The suite is the artefact and the report is the record. Close the
  findings in the TESTS. Never delete a failing test to close a finding,
  and never weaken an assertion: the cheapest failure a test-suite
  remediation has is a weakened assertion, which a green gate cannot see.|]

-- | @fixerContinuation@, summarised: the closing clause a fixer under an
-- orchestrator stands under.
fixerContinuation :: Text
fixerContinuation = [wft|
  You are running under an orchestrator that will call you again with your
  own summary as its input, so write the summary for your successor: which
  findings you closed, which you rejected and why, and which are left.

  End with a status line, alone on the last line: WORK COMPLETE if every
  finding is closed or rejected with a reason, WORK REMAINS otherwise.|]

-- | The audit panel's brief over the fixer's own change — @asReviewSubject@
-- pointed at the delta rather than at the report.
auditOfFixBrief :: Text
auditOfFixBrief = [wft|
  Review the fixer's own change, not the report it was working from.
  A test-suite remediation's cheapest failure is a weakened assertion,
  which a green gate cannot see and only a diff shows.

  Reply with exactly APPROVE if the change closes its findings honestly, or
  OBJECTION: followed by one line for each place it does not.|]

-- The stack ----------------------------------------------------------------

-- | @stackFacts@, summarised: what the slicing worker is told about the tree.
stackFactsBrief :: Text
stackFactsBrief = [wft|
  Read the repository's stack facts -- the trunk branch, the remote, the
  Graphite configuration and the verification script -- and reply with them
  verbatim. Then reply with `git diff` against trunk.|]

-- | The slice plan's brief.
stackSliceBrief :: Text
stackSliceBrief = [wft|
  Cut the diff below into a stack of branches of roughly five hundred lines
  each, on compile-time dependency boundaries: every branch must build on
  its own, with its parent applied and nothing above it.

  Write the plan as an ordered list, bottom first. For each branch: what it
  holds, what it defers to a branch above it, and the one sentence its pull
  request body opens with.|]

-- | The steer at the slice plan.
stackSteerBrief :: Text
stackSteerBrief = [wft|
  Review the slice plan -- every branch, what it holds, and what it defers.|]

-- | The first human gate.
stackBuildGate :: Text
stackBuildGate = "Build the stack from this plan? Reply yes or no."

-- | The bootstrap worker, which writes the stack's three scripts.
stackBootstrapBrief :: Text
stackBootstrapBrief = [wft|
  Write the stack's tooling to disk before any branch is cut:
  `verify-stack.sh`, which builds every branch in order and exits non-zero
  on the first failure; `ci-budget.sh`, which reports whether the shared
  runner pool has room; and the slice script the plan names. Then reply
  DONE.|]

-- | The cut worker.
stackCutBrief :: Text
stackCutBrief = [wft|
  Cut the next branch of the stack, bottom first, exactly as the plan
  below describes it. One branch per trip. Rewrite no branch that is
  already approved.

  End with a status line, alone on the last line: WORK COMPLETE when the
  last branch in the plan exists, WORK REMAINS otherwise, WORK BLOCKED if
  a branch cannot be cut without rewriting approved history.|]

-- | The orchestrator's reading of the cut worker's line, at the stack's three
-- endings.
stackStatusBrief :: Text
stackStatusBrief = [wft|
  You are the orchestrator. Read ONLY the last non-empty line below.

  - WORK COMPLETE: reply with exactly APPROVE.
  - WORK REMAINS: reply OBJECTION: branches remain.
  - WORK BLOCKED: reply OBJECTION: blocked, and repeat the reason verbatim.
  - anything else: reply OBJECTION: status line missing.|]

-- | The stack's exec gate.
stackGateBrief :: Text
stackGateBrief = [wft|
  Run `./verify-stack.sh` and read its exit code. Exit 0: reply yes.
  Anything else: reply no.

  Report the exit code you saw.|]

-- | The triage worker, over the review bot's findings.
stackTriageBrief :: Text
stackTriageBrief = [wft|
  Address the panel's findings below, branch by branch, downstack first: a
  fix on a lower branch can moot a finding on a higher one. Restack after
  each fix.

  End with a status line, alone on the last line: WORK COMPLETE, WORK
  REMAINS, or WORK BLOCKED.|]

-- | The second human gate.
stackPromoteGate :: Text
stackPromoteGate = [wft|
  Promote this stack out of draft? Each branch spends a CI run on a shared
  runner. Reply yes or no.|]

-- | The consent gate — @test -f .stack-promote-approved@, as a question.
--
-- It exists because a human gate is not real when unattended: an unattended run
-- auto-answers its gates, so the last thing between a draft stack and a public
-- one is a file the agent is forbidden to create.
stackConsentBrief :: Text
stackConsentBrief = [wft|
  Run `test -f .stack-promote-approved` and reply yes if it exits 0, no
  otherwise.

  You may not create this file. It is a person's consent, and a run that
  writes its own consent has none.|]

-- | The promotion worker.
stackPromoteBrief :: Text
stackPromoteBrief = [wft|
  Promote the stack out of draft, bottom first, one branch at a time. Before
  each branch, re-run `./ci-budget.sh --wait`: a clearance read once and
  reused is a clearance about a queue that has changed.

  Then reply DONE.|]

-- | The panel's answer format, for every question that answers a verdict.
verdictSpec :: Text
verdictSpec =
  "Reply with exactly APPROVE if you find nothing, or OBJECTION: <one line> for each finding."

-- ---------------------------------------------------------------------------
-- The one piece of shared machinery
-- ---------------------------------------------------------------------------

-- | @reviewLiteFlow@'s five unconditional reviewers, as a panel over whatever
-- handle is under review.
--
-- __This is the answer to \"can a workflow's parts be shared?\", and it is
-- half yes.__ @incite@'s central discipline is that @reviewLiteFlow@ is one
-- binding used by three workflows, so they cannot drift in anything they share.
-- A /question/ shares here exactly as well: this is an ordinary Haskell
-- function from a live handle to a list of 'Ask's, and it can be applied at any
-- scope where the handle is live, which is what @KnownIx h s@ says. What does
-- not share is a run of /statements/ — see the gap on 'shipFeatureLiteProgram'.
--
-- The sixth reviewer is missing on purpose: it stands behind a router, and a
-- router cannot stand inside a panel. See 'reviewLite'.
reviewPanelOver :: (KnownIx h s) => V h 'CodeText -> [Ask s]
reviewPanelOver subject =
  [ ask (model "correctness" `servedBy` "balanced") [wf|
      {correctnessLens}
      {subject}
      {verdictSpec}|],
    ask (model "fess" `servedBy` "review") [wf|
      {fessLens}
      {subject}
      {verdictSpec}|],
    ask (model "complexity" `servedBy` "reasoning") [wf|
      {complexityLens}
      {subject}
      {verdictSpec}|],
    ask (model "ponytail" `servedBy` "reasoning") [wf|
      {ponytailReviewLens}
      {subject}
      {verdictSpec}|],
    ask (model "qa" `servedBy` "coding") [wf|
      {qaFence}
      {subject}
      {verdictSpec}|]
  ]

-- ---------------------------------------------------------------------------
-- 1. plan-feature
-- ---------------------------------------------------------------------------

-- | @incite@'s @plan-feature@: @explorePlan >>> editPlan@. Ten leaves before a
-- line is written; no worktree, no git, no pull request; no human.
--
-- __Expressed fully.__ Every part of this workflow has a shape here:
--
--   * the four stances are four questions, each with its own serving model,
--     which is what @withBackend@ around each stance buys in @incite@ — and it
--     is said on the question rather than as a scope wrapper, so there is no
--     inheritance to argue about;
--   * @hierarchical ["skeptic","architect","contemplative","intrepid"]@ is a
--     /pure/ reduce there, and here it is the order of the holes in the
--     planner's prompt. Same order, one fewer moving part, and — this is the
--     honest half — one fewer thing a test can read: @incite@ can assert the
--     narrowing order against a list, and here it is prose;
--   * @editPlan@'s six lenses are six sequential rewrites of one text, which is
--     six binds each holing the one before it. They carry no @\`servedBy\`@,
--     deliberately, which is exactly @editPlan@'s \"deliberately unpinned so
--     all six run on the same backend and stay comparable\".
--
-- Level @pipeline@: no branch, no loop, one path, and @codes@ is a full
-- sequence — twelve text answers and a receipt.
--
-- > level pipeline, size 14, askNodes 13
-- > codes text ×12, receipt
-- > cost  minFold 13, maxFold 13, over 1 path
-- > run --scripted: billFresh 13, billMemo 13
planFeatureProgram :: Program
planFeatureProgram = workflow W.do
    request <- ask (tool "cat") [wf|{readRequest}|]

    intrepid <- ask (model "intrepid" `servedBy` "review") [wf|
        {intrepidStance}
        {request}|]

    skeptic <- ask (model "skeptic" `servedBy` "reasoning") [wf|
        {skepticStance}
        {request}|]

    contemplative <- ask (model "contemplative" `servedBy` "coding") [wf|
        {contemplativeStance}
        {request}|]

    architect <- ask (model "architect" `servedBy` "balanced") [wf|
        {architectStance}
        {request}|]

    drafted <- ask (model "plan" `servedBy` "balanced") [wf|
        {planBrief}
        {skeptic}
        {architect}
        {contemplative}
        {intrepid}
        {request}|]

    cut <- ask (model "ponytail") [wf|
        {ponytailLens}
        {drafted}|]

    meant <- ask (model "denotational") [wf|
        {denotationalLens}
        {cut}|]

    risked <- ask (model "risk") [wf|
        {riskLens}
        {meant}|]

    checked <- ask (model "verification") [wf|
        {verificationLens}
        {risked}|]

    ordered <- ask (model "lookahead") [wf|
        {lookaheadLens}
        {checked}|]

    worded <- ask (model "simple-english") [wf|
        {simpleEnglishLens}
        {ordered}|]

    ask_ (tool "write-plan") [wf|
        Write this plan to `docs/plans/` under a dated name, then reply DONE.
        {worded}|]

-- ---------------------------------------------------------------------------
-- 2. review-lite
-- ---------------------------------------------------------------------------

-- | @review-lite@'s fold, as a procedure both arms of the router call.
--
-- The six blocks are parameters, so the two arms differ in one argument and can
-- no longer differ in anything else: the report's order, its brief and its tool
-- are one text now, where they were two. The second argument is the whole of
-- the difference — a binding in the arm that ran the Haskell lens, and the
-- 'noHaskellEdits' define in the arm that did not, which reaches a @text@
-- parameter as an @ArgLit@.
--
-- A call inlines the callee's existing nodes at the call site; it adds no
-- separate call node.
reviewReport ::
  Fn '[ 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText] 'CodeAck
reviewReport =
  function
    "review-lite.report"
    ( takes @"correctness" Text
        . takes @"haskell" Text
        . takes @"claims" Text
        . takes @"failures" Text
        . takes @"braids" Text
        . takes @"cuts" Text
        $ noParams
    )
    \correctness haskell claims failures braids cuts -> W.do
      act (tool "write-report") [wf|
          {reviewReportBrief}
          {correctness}
          {haskell}
          {claims}
          {failures}
          {braids}
          {cuts}|]
      done

-- | @incite@'s @review-lite@: six independent reviewers over one commit, one of
-- them behind a cheap router, folded by a pure narrowing with no synthesis
-- leaf. The workflow @incite@ runs most — after every commit, driven by
-- @post-commit-audit@.
--
-- __Expressed, with the tail a function both arms call.__ Three things had to
-- move, and each names a gap — one of which the language has since closed.
--
-- === The conditional lens
--
-- @haskellIfEdited@ is /one member/ of a six-member fan-out that contains two
-- leaves: a one-word triage, and — behind it — a thirty-kilobyte lens. The
-- other five reviewers never wait on the triage, and the fold still sees six
-- blocks.
--
-- __Gap: a branch is terminal, so a conditional stage cannot rejoin the main
-- line.__ Every arm of an @if@ /is/ the rest of the workflow, so a lens that
-- runs conditionally and then rejoins its five siblings still cannot be
-- written. What /has/ changed is the cost of that: the tail the two arms share
-- is 'reviewReport', one function called from both, so the arms now differ in
-- exactly one argument and can no longer differ in anything else. The shape
-- still does not survive a fan-out of any width — a workflow with three
-- independent routers needs eight arms — but each of the eight is one line.
--
-- === The loud default, and the overrule
--
-- @routeHaskell@'s default is loud: only a clean @none@ skips the lens, and any
-- other answer — chatty, empty, malformed — runs it. And even a clean @none@ is
-- overruled by @diffNamesHaskell@, a pure scan of the diff's /header/ lines for
-- a Haskell path, so that a well-formed wrong answer cannot silently skip a
-- Haskell review.
--
-- __Gap: an answer is a handle, not a value.__ No Haskell function may look at
-- one, so @diffNamesHaskell@ has nowhere to stand: the subject is a binding,
-- not a 'Data.Text.Text'. And the loud default is not expressible either — a
-- reply that 'Agentic.Text.decodeFlag' cannot read is re-asked once with a
-- nudge and then /abandons the run/, where @incite@ treats an unreadable
-- router answer as a reason to spend the expensive lens. There is no vocabulary
-- here for \"an answer I could not read means take the safe arm\".
--
-- === The pure fold
--
-- @review-lite@'s fold is @hierarchical@ — reorder, then union — and it has no
-- synthesis leaf on purpose, because six independent opinions are worth more
-- unreconciled than one reconciled one.
--
-- __Gap: there is no pure combinator over answers.__ A fold is either a
-- question or a hole in a later prompt. Below it is an 'act' — inside
-- 'reviewReport' now, but an act — and the tool writes the six blocks down in
-- the narrowing order and reconciles nothing, which is the same artefact for
-- one leaf more than @incite@ pays.
--
-- === The subject, which is now an input
--
-- This is the one gap of the five that is __closed__. @incite@'s workflows are
-- @Flow Text Text@ and @workflowReq@ demands an input at the CLI; this program
-- used to open by asking a tool for the commit, which made the operator's text
-- an /answer/ where there it is /data/. It is now
-- @'Agentic.Workflow.taking' ('Agentic.Workflow.input' \"subject\" :> …)@, and the
-- subject is a @define@ supplied at run time — @agentic-run … --input
-- .\/commit.diff@ — spliced into every prompt exactly as a define written in
-- the source is, including inside the @if@ arms.
--
-- Level @branch@, two paths — and its published price in @incite@'s own
-- @docs\/workflows.md@ is 7 leaves, which is these 8 less the one this
-- language has to pay for and that one does not: the tool that folds the six
-- blocks.
--
-- > level branch, size 12, askNodes 9
-- > cost  minFold 7, maxFold 8, over 2 paths
-- > run --scripted: billFresh 8, billMemo 8 (the router said yes)
reviewLite :: Parameterized
reviewLite = taking (stdinInputAs "subject" :> noInputs) \subject ->
  defining [SomeFn reviewReport] W.do
    correctness <- ask (model "correctness" `servedBy` "balanced") [wf|
        {correctnessLens}
        {subject}|]

    claims <- ask (model "fess" `servedBy` "review") [wf|
        {fessLens}
        {subject}|]

    braids <- ask (model "complexity" `servedBy` "reasoning") [wf|
        {complexityLens}
        {subject}|]

    cuts <- ask (model "ponytail") [wf|
        {ponytailReviewLens}
        {subject}|]

    failures <- ask (model "qa" `servedBy` "coding") [wf|
        {qaFence}
        {subject}|]

    -- The router. One word in @incite@, read by a substring-free equality; a
    -- flag here, read by `decodeFlag`. It is pinned to the cheapest model any
    -- the tier's least expensive symbolic profile, exactly as `haskellIfEdited` pins
    -- its triage: the real cost control is the brief above it, which asks for a
    -- path list and never for a diff.
    touchesHaskell <- confirm (model "haskell-triage" `servedBy` "balanced") [wf|
        {haskellTriageBrief}
        {subject}|]

    if touchesHaskell
      then W.do
        haskell <- ask (model "haskell" `servedBy` "balanced") [wf|
            {haskellHouseLens}
            {subject}|]

        call_
          reviewReport
          ( arg correctness
              :> arg haskell
              :> arg claims
              :> arg failures
              :> arg braids
              :> arg cuts
              :> noArgs
          )
        stop
      else W.do
        call_
          reviewReport
          ( arg correctness
              :> arg noHaskellEdits
              :> arg claims
              :> arg failures
              :> arg braids
              :> arg cuts
              :> noArgs
          )
        stop

-- ---------------------------------------------------------------------------
-- 3. ship-feature-lite
-- ---------------------------------------------------------------------------

-- | @incite@'s @ship-feature-lite@: the smallest /complete/ acting workflow,
-- and the only one in that repository whose worst case is a finite fenced
-- number (21 leaves).
--
-- > planLeaf >>> steer >>> orchestrateWith (Fuel 3) implement
-- >   >>> reviewLiteFlow >>> remediate codeRule >>> greenGate codeRule
--
-- __Expressed, and the four gaps it forces are the most valuable findings in
-- this module.__
--
-- === The person in the middle
--
-- @steer@ is an interactive checkpoint whose /answer is the revised artefact/,
-- not a yes\/no gate. That is @ask (person …)@ in binding position, and it is
-- the first example of one: the flagship only 'confirm's, at the end. Its
-- answer is live from there on, and the worker implements against it.
--
-- === The worker loop
--
-- @orchestrateWith (Fuel 3) implement@ feeds the worker its own previous
-- summary and classifies the summary's last line four ways: @WORK COMPLETE@
-- ends, @WORK BLOCKED@ ends and is passed through verbatim, @WORK REMAINS@
-- buys another trip if the budget has one, and anything else is a /protocol
-- violation/ — re-prompt with a nudge, at most twice per run, and a violation
-- spends no trip fuel.
--
-- 'revising' is the shape, and three things do not survive it.
--
--   * __Gap: a bounded revision has two endings, and its review has three tags
--     but only one of them settles.__ @Plan.revising@ settles on @approve@ and
--     amends on everything else, so @WORK BLOCKED@ and a missing status line
--     both become \"another trip\" — the first should have ended the run and
--     the second should have cost no fuel. 'caseVerdict' /can/ tell the three
--     tags apart, but not inside a revision: the review clause's verdict is
--     consumed by the loop.
--   * __Gap: there is no second budget.__ @TripBudget@ threads fuel and a
--     violation count /beside/ the carrier, so the worker only ever sees its
--     own summary. A revision carries one artefact and one bound.
--   * __Closed (D3): @Unsettled@ carried nothing, and now carries the
--     candidate.__ This was the sharpest gap. The whole designed trade of the
--     @lite@ tier is that exhaustion __yields__: the tree keeps every edit the
--     three trips made, and the last summary — the one that asked for a fourth
--     trip — is what the panel reads. The unsettled arm had no handle to the
--     candidate the loop had in hand, so the only arm that could be written was
--     @stop@; it now binds that candidate, and the yield is writable.
--     __This program has not been rewritten to take it__, deliberately: the
--     mechanism and the program move in separate commits, because a
--     @ci\/examples.sh@ row that moved for two reasons at once is a row nobody
--     can attribute. The arm below is still @stop@ and the numbers below are
--     still the ones this file has always published.
--
-- Where the language is /ahead/: @completionGate@ is a stage @incite@ had to
-- add, a pure @error@ that halts the run unless the yield declares completion,
-- because a block or a spent violation budget must not buy a review panel and a
-- pull request gate. Here that gate is the @Unsettled _ -> stop@ arm, which the
-- author cannot forget to write, because the @case@ is total — and which is now
-- a /choice/ of arm rather than the only arm writable.
--
-- === The green gate
--
-- @greenGate@ is the load-bearing idea of Isaac's whole acting half: the
-- harness runs @nix flake check@ itself and reads the kernel's exit code — \"the
-- one statement in this workflow that no agent authors\" — and a red tree buys
-- three repair trips and then __aborts__, the opposite polarity to the worker
-- loop, argued for at both sites.
--
-- __Gap: a check is a question, never an exit code.__ 'act' returns a receipt
-- the /answerer/ authored, and nothing in the language distinguishes \"the tool
-- says it ran\" from \"the harness ran it and the kernel returned 0\".
-- @agent-functor@ ships @verify@ and @agentVerify@ as two combinators with two
-- names for exactly this reason. What is written below is @agentVerify@, and
-- 'greenGateBrief' says so. The /polarity/, at least, carries over exactly: the
-- gate is a second 'revising' whose @Unsettled@ arm is @stop@, which is
-- abort-on-exhaustion, and the repair budget is its bound. (D5 closes the
-- other half: @tool \"green\" \`running\` (\"nix\", [\"flake\",\"check\"])@ is a
-- check the runner performs and whose exit code /is/ the answer. This program
-- is not rewritten to take it, for the reason above.)
--
-- === What could not be shared
--
-- @reviewLiteFlow@ is one binding, used by @review-lite@, @ship-feature@ and
-- @ship-feature-lite@ alike, and @incite@'s central discipline is that
-- workflows cannot drift in anything they share.
--
-- __Gap: a sub-flow is a straight line.__ The /questions/ share —
-- 'reviewPanelOver' is used below and is the same list of 'Ask's 'reviewLite'
-- spells out — and a straight run of statements now shares too: @function@,
-- @call_@ and @defining@ are in "Agentic.Workflow", and 'reviewReport' is a
-- function both arms of @review-lite@'s router call. What still does not share
-- is a run that /branches/: a body is a straight line
-- ('Agentic.Raw.RawBodyStmt' has three constructors and no branching), and
-- @reviewLiteFlow@'s tier is a router with two arms. That is why 'reviewLite'
-- binds its five reviewers one at a time and this program panels them: the two
-- spellings of one tier are still held together by the prompt library they
-- both read, and not by the language.
--
-- Level @branch@. Two loops, so @costSummary@ has a real range to report —
-- and the range is the answer to the one number @incite@ quotes for this tier
-- (\"worst case is fenced at 21 leaves\"): a single worst case, where this
-- says what the cheapest run costs too, and over how many paths.
--
-- > level branch, size 149, askNodes 78
-- > cost  minFold 4, maxFold 24, over 36 paths
-- > run --scripted: billFresh 12, billMemo 12 (settled on the first check,
-- >   green on the first gate)
shipFeatureLiteProgram :: Program
shipFeatureLiteProgram = workflow W.do
    request <- ask (tool "cat") [wf|{readRequest}|]

    drafted <- ask (model "plan" `servedBy` "balanced") [wf|
        {planBrief}
        {request}|]

    -- `steer`: a person, in the middle of the run, whose answer is live from
    -- here on. It asks for the acceptance bar and not for guidance in general,
    -- because an empty submit answers the second honestly in four seconds.
    bar <- ask (person "operator") [wf|
        {planSteerBrief}
        {drafted}|]

    worked <- revising drafted (atMost 3) \account -> W.do
        status <- ask (model "orchestrator" `servedBy` "balanced") [wf|
            {tripStatusBrief}
            {account}|]
        amend (ask (model "implement") [wf|
            {implementBrief}
            {bar}
            {account}
            {status}|])

    case worked of
      Settled account -> W.do
        verdict <- panel (reviewPanelOver account)

        remedied <- ask (model "remediate") [wf|
            {remediateBrief}
            {codeRule}
            {verdict}
            {account}
            {closeWithChanges}|]

        gated <- revising remedied (atMost 3) \tree -> W.do
            green <- ask (tool "flake-check") [wf|{greenGateBrief}|]
            amend (ask (model "repair") [wf|
                {repairBrief}
                {codeRule}
                {tree}
                {green}|])

        case gated of
          Settled tree -> W.do
            ask_ (tool "write-report") [wf|
                Write the run's account to `ship-feature-lite.md`, then reply DONE.
                {tree}|]
          -- Abort. Three repair trips did not make the tree green, and the
          -- opposite polarity to the worker loop is the whole argument:
          -- a worker declares its own ending, and a tree is asked whether it
          -- still fails.
          Unsettled _ -> stop
      -- `orchestrateWith` YIELDS here, and the panel reads the summary that
      -- asked for a fourth trip. Since D3 the binder this arm ignores IS that
      -- summary, so the yield is writable — and is deliberately not written in
      -- the commit that landed the mechanism: rewriting it moves `size`,
      -- `askNodes`, `costSummary` and both bills on this row, and a table that
      -- moved for two reasons at once is unattributable.
      Unsettled _ -> stop

-- ---------------------------------------------------------------------------
-- 4. grind-tests
-- ---------------------------------------------------------------------------

-- | @incite@'s @grind-tests@: a whole-tree audit of a test suite by twelve
-- lenses spread one per backend, a synthesis that refuses on a short roster, a
-- facts gate that turns a prose refusal into a run failure, an unbounded fixer
-- loop, and then a second segment — the 84-leaf audit panel over the /fixer's
-- own change/, a capped second fixer, and a green gate.
--
-- The catalog calls @GrindSpec@ the best structural idea in the repository: a
-- record of everything one audit supplies for itself, with the synthesis brief
-- and the fixer's rule /derived/ from it, so no grind can audit under one set of
-- facts and repair under another.
--
-- __Expressed, at six lenses instead of twelve, with the unbounded loop given a
-- bound.__ Four observations.
--
-- === The structural idea carries over completely
--
-- 'grindLensRoster' is the table; 'grindLens' derives each lens's brief from its
-- row; 'grindSynthesisBrief' derives the roster it will /refuse on/ from the
-- same table. A lens added to the table arrives in its own brief and in the
-- synthesis's roster by being added, exactly as @gsLenses@ does. This is
-- ordinary Haskell reuse and the surface supports it as well as @agent-functor@
-- does — better, in one respect: @spread@ zips the table against
-- @cycle backends@, so /position/ picks the model and @gsPins@ exists to state
-- the one assignment that is policy. Here the serving model is named on the
-- question, so every assignment is a pin and reordering the table changes
-- nothing.
--
-- === The fan-out is a static list, and that is the limit
--
-- __Gap: there is no fan-out over a dynamically sized list.__ 'reviewPanelOver' can build
-- its members from a Haskell list because the list is known when the module is
-- compiled. The six binds below cannot: each bind's scope index is one entry
-- longer than the last, so a /list-driven/ fold of binds is not directly
-- typeable and the six statements are written out by hand. @incite@ builds
-- every one of its panels from a list comprehension over @(lens, backend)@
-- pairs, and its @review-audit@ tier is 84 leaves — which is 84 statements
-- here. The panel combinator escapes this (its members are a list), but a panel
-- folds in the verdict monoid: its members' answers are not individually
-- spliceable, and a grind's synthesis needs them one block at a time.
--
-- === The facts gate
--
-- @decideFactsResolved@ behind a fuel-1 @loopUntil@ turns the synthesis's prose
-- refusal into a run failure /before any fixer acts/. Here it is a question and
-- an @if@ whose else arm is empty — which stops the run in the right place and
-- says nothing about why. There is no failure vocabulary: a run that stops
-- because the facts did not resolve and a run that stops because it finished
-- are the same trace shape.
--
-- === Unbounded, and why not having it is right
--
-- The fixer loop is @orchestrate@ with @workerFuel = Nothing@: unbounded, the
-- worker decides. @agent-functor@ compiles that to
-- @loopUntil (maxBound \`div\` 2)@ and the recorded price of @cost grind-paradox@
-- is @4611686018427387927@ worst-case leaf executions — a nineteen-digit
-- sentinel the repository's own documentation calls a number \"no operator can
-- read anything from\", which is why @stackFuel@, @liteFuel@,
-- @grindTestsReviewFuel@, @repairFuel@ and @budgetFuel@ were every one of them
-- introduced afterwards as named finite constants.
--
-- @Dynamic@ is a rung "Agentic.Builder" cannot construct, so the loop below is
-- @atMost 4@ and the workflow is honestly a different one. This is the only
-- gap in this module that is a __feature__, and Isaac's own numbers are the
-- evidence for it.
--
-- > level branch, size 144, askNodes 73
-- > cost  minFold 9, maxFold 27, over 36 paths
-- > run --scripted: billFresh 15, billMemo 15
grindTestsProgram :: Program
grindTestsProgram = workflow W.do
    facts <- ask (tool "cat") [wf|{grindFactsBrief}|]

    -- The spread. Six statements where `incite` writes one list comprehension:
    -- the serving models cycle by hand, because the fan-out is not a list here.
    vacuous <- ask (model "vacuous" `servedBy` "review") [wf|
        {vacuousLens}
        {facts}|]

    coverage <- ask (model "coverage" `servedBy` "reasoning") [wf|
        {coverageLens}
        {facts}|]

    property <- ask (model "property" `servedBy` "coding") [wf|
        {propertyLens}
        {facts}|]

    mutation <- ask (model "mutation" `servedBy` "review") [wf|
        {mutationLens}
        {facts}|]

    stubs <- ask (model "stubs" `servedBy` "reasoning") [wf|
        {stubsLens}
        {facts}|]

    sleeps <- ask (model "sleeps" `servedBy` "coding") [wf|
        {sleepsLens}
        {facts}|]

    report <- ask (model "synthesis" `servedBy` "balanced") [wf|
        {grindSynthesisBrief}
        {vacuous}
        {coverage}
        {property}
        {mutation}
        {stubs}
        {sleeps}|]

    resolved <- confirm (model "facts-gate" `servedBy` "balanced") [wf|
        {factsGateBrief}
        {report}|]

    if resolved
      then W.do
        fixed <- revising report (atMost 4) \account -> W.do
            status <- ask (model "orchestrator" `servedBy` "balanced") [wf|
                {tripStatusBrief}
                {account}|]
            amend (ask (model "fixer") [wf|
                {grindRule}
                {account}
                {status}
                {fixerContinuation}|])

        case fixed of
          Settled account -> W.do
            -- The second segment: the audit panel over the fixer's OWN change,
            -- because a test-suite remediation's cheapest failure is a
            -- weakened assertion, which a green gate cannot see.
            audit <- panel
              [ ask (model "audit-correctness" `servedBy` "balanced") [wf|
                  {auditOfFixBrief}
                  {account}|],
                ask (model "audit-fess" `servedBy` "review") [wf|
                  {fessLens}
                  {account}
                  {verdictSpec}|],
                ask (model "audit-architecture" `servedBy` "reasoning") [wf|
                  {complexityLens}
                  {account}
                  {verdictSpec}|]
              ]

            -- `grindTestsReviewFuel = Just (Fuel 12)` there; two here, for a
            -- price a reader of this module can hold in their head.
            closed <- revising account (atMost 2) \delta -> W.do
                green <- ask (tool "flake-check") [wf|{greenGateBrief}|]
                amend (ask (model "audit-fixer") [wf|
                    {grindRule}
                    {audit}
                    {delta}
                    {green}|])

            case closed of
              Settled delta -> W.do
                ask_ (tool "write-audit") [wf|
                    Write the closing account under `docs/audits/`, then reply DONE.
                    {delta}|]
              Unsettled _ -> stop
          Unsettled _ -> stop
      -- `FACTS PATHS UNRESOLVED`: the run ends before any fixer acts. There is
      -- no way to say WHY it ended.
      else stop
  where
    vacuousLens = grindLens "vacuous" "assertions that cannot fail"
    coverageLens = grindLens "coverage" "the code paths no test reaches"
    propertyLens = grindLens "property" "the invariants that want a property test"
    mutationLens = grindLens "mutation" "the mutations the suite survives"
    stubsLens = grindLens "stubs" "the stubs, the skips and the xfails"
    sleepsLens = grindLens "sleeps" "the sleeps and the magic timeouts"

-- ---------------------------------------------------------------------------
-- 5. stack-prs
-- ---------------------------------------------------------------------------

-- | @incite@'s @stack-prs@, the richest shape in that repository and the one
-- the catalog names as the honest boundary of a statically priced language:
-- four capped loops at @Fuel 12@ each, three exec gates, two human gates, one
-- consent file, and a budget gate re-run before /every trip/ of the promotion
-- loop.
--
-- __Expressed partially: two of the four loops, both human gates, the consent
-- gate, and no budget gate.__ What is here is faithful; what is missing is
-- listed, because this is where the language runs out.
--
-- === What carried
--
--   * __Two human gates, in the two places they belong.__ @confirm (person …)@
--     before the stack is built and again before it leaves draft. Both are
--     'confirm's, and both branch with a two-armed @if@ whose else arm is
--     @stop@ — which is @humanGate@'s halt exactly, and without @humanGate@'s
--     @error@.
--   * __The consent gate.__ @test -f .stack-promote-approved@, with a fuel of
--     one, exists because a human gate is not real when unattended: an
--     unattended run auto-answers its gates, so the last thing between a draft
--     stack and a public one is a file the agent is forbidden to create. Here
--     it is a 'confirm' put to a /tool/ rather than to a person, which is the
--     right addressee for it and reads better than @incite@'s spelling: the
--     workflow says who is asked.
--   * __@WORK BLOCKED@ as a third ending.__ 'stackStatusBrief' asks for it and
--     repeats the reason verbatim, so the reason survives into the amendment's
--     prompt. What it cannot do is /end the run/ — see below.
--
-- === What did not
--
--   * __Gap: a per-trip gate has nowhere to stand.__ @budgetGate >>>
--     stackWorker "promote"@ re-runs @./ci-budget.sh --wait@ before every trip,
--     with @Id@ as its repair (there is nothing to fix; somebody else is
--     queued) and two waits before the run fails, because a clearance read once
--     and reused is a clearance about a queue that has changed. A bounded
--     revision's body is exactly one review and one amendment — the grammar
--     refuses a third statement, and says so — so a gate that must run before
--     each amendment cannot be placed. The promotion loop below is a single
--     act, and its budget re-read is a sentence in 'stackPromoteBrief' that
--     nothing enforces.
--   * __Gap: @WORK BLOCKED@ still cannot end a loop.__ As in
--     'shipFeatureLiteProgram': the review clause's verdict is consumed by the
--     revision, so a blocked ending buys another trip instead of stopping.
--     @stack-prs@ is the workflow @WORK BLOCKED@ was invented for — a design
--     disagreement, an approved branch that must not be rewritten, a starved
--     runner pool — and it is the ending this language cannot spell.
--   * __Two of the four loops are dropped.__ @incite@ runs @cut@, @remediate@,
--     @triage@ and @promote@ each under its own capped loop. Two are written
--     below and two are single questions, because four nested revisions inside
--     four nested branches is a program whose cost fold says more about this
--     module than about the workflow.
--   * __No pinning of the acting leaves as a scope.__ Every acting leaf in
--     @stack-prs@, fixers and the repair leaf included, is wrapped by
--     @stackPin@ because these leaves rewrite git history, and one wrapper
--     around a subtree is what guarantees no leaf inside it inherits something
--     else. Here the pin is per question, so the guarantee is per question:
--     there is no scope to wrap, and a leaf added later without
--     @\`servedBy\` "balanced"@ is a leaf nothing catches.
--
-- Level @branch@.
--
-- > level branch, size 155, askNodes 70
-- > cost  minFold 4, maxFold 24, over 43 paths
-- > run --scripted: billFresh 16, billMemo 15
--
-- __That last pair is worth reading.__ Sixteen consultations were reached and
-- fifteen questions were put: the two orchestrator questions — one in the cut
-- loop, one in the triage loop — are the same prompt over the same carrier
-- when nothing amended in between, so the second is a memo hit and costs
-- nothing. The equivalent in @incite@ is @leafKey@, and it is content
-- addressing there too.
stackPRsProgram :: Program
stackPRsProgram = workflow W.do
    facts <- ask (tool "git") [wf|{stackFactsBrief}|]

    sliced <- ask (model "slice" `servedBy` "balanced") [wf|
        {stackSliceBrief}
        {facts}|]

    -- The steer, again a person whose answer is the artefact.
    guidance <- ask (person "operator") [wf|
        {stackSteerBrief}
        {sliced}|]

    build <- confirm (person "operator") [wf|
        {stackBuildGate}
        {sliced}|]

    if build
      then W.do
        act (tool "bootstrap") [wf|
            {stackBootstrapBrief}
            {sliced}|]

        cutting <- revising sliced (atMost 2) \progress -> W.do
            status <- ask (model "orchestrator" `servedBy` "balanced") [wf|
                {stackStatusBrief}
                {progress}|]
            amend (ask (model "cut" `servedBy` "balanced") [wf|
                {stackCutBrief}
                {guidance}
                {progress}
                {status}|])

        case cutting of
          Settled progress -> W.do
            -- The first exec gate. `./verify-stack.sh`, and a real exit code
            -- in `incite`; a question here, for `greenGateBrief`'s reason.
            green <- confirm (tool "verify-stack") [wf|{stackGateBrief}|]

            if green
              then W.do
                found <- panel (reviewPanelOver progress)

                triaged <- revising progress (atMost 2) \state -> W.do
                    closedAll <- ask (model "orchestrator" `servedBy` "balanced") [wf|
                        {stackStatusBrief}
                        {state}|]
                    amend (ask (model "triage" `servedBy` "balanced") [wf|
                        {stackTriageBrief}
                        {found}
                        {state}
                        {closedAll}|])

                case triaged of
                  Settled state -> W.do
                    promote <- confirm (person "operator") [wf|
                        {stackPromoteGate}
                        {state}|]

                    if promote
                      then W.do
                        -- The gate that exists BECAUSE a human gate is not real
                        -- when unattended. A tool, because a file is not a
                        -- person -- and the workflow says which is asked.
                        consented <- confirm (tool "consent") [wf|{stackConsentBrief}|]

                        when consented $ W.do
                          act (tool "promote") [wf|
                              {stackPromoteBrief}
                              {state}|]
                      else stop
                  Unsettled _ -> stop
              else stop
          Unsettled _ -> stop
      else stop
