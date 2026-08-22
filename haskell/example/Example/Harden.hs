-- |
-- Module      : Example.Harden
-- Description : The walked examples, written in the authoring surface.
--
-- Two of @agent-cat@'s frozen corpus entries are not conformance fixtures but
-- /prose/: @example-000@, the flagship, which the documentation walks line by
-- line, and @example-001@, the smallest thing that is still a workflow. This
-- module /is/ those two programs, written in "Agentic.Workflow" — ordinary
-- Haskell values, sugar over "Agentic.Builder", whose combinators these
-- statements are. (Both frozen terms were emitted from @.wf@ sources when the
-- repository still had a concrete syntax; the terms did not move when it went,
-- and this module is the text of record for them now.)
--
-- Two callers share these programs:
--
--   * @tier1@ pins them against the frozen entries — printed 'Raw' and whole
--     reply, positions zeroed on both sides;
--   * @agentic-run@ plans, prices and /runs/ them.
--
-- The first caller is what makes the second trustworthy: the program the CLI
-- executes is the same value the conformance runner has already held against
-- the oracle.
--
-- == How to read this against @example-000@
--
-- Statement for statement with the frozen term. @x <- ask …@ is a bind that
-- prints a bind; @W.do@ is @QualifiedDo@ and nothing more. A prompt is a
-- @[wf|…|]@ fence, with the @{name}@ holes and the layout rule the frozen
-- prompts were written under — surrounding blank lines dropped, common
-- indentation stripped, line breaks kept, no trailing newline. A @define@ is a
-- Haskell binding, spliced by a hole that names it.
--
-- The two names that are not binds are a /lambda/ and a /pattern/, and they
-- are bindings too: @\\patch -> …@ under 'revising' is the carrier, and the
-- @patch@ of @Settled patch@ is the settled binding. Both print as bindings of
-- the frozen program, which calls both @patch@.
--
-- The two branches are Haskell's own. @case result of@ is a regular @case@ on
-- a regular data type, its arms @W.do@ blocks; the flag's branch is written
-- @when ok $ W.do …@, which is 'Agentic.Workflow.when' — the one-armed @if@,
-- sealing its body with the implicit @stop@ an arm block ends in, and printing
-- the very same @ifFlag@ node the frozen entry has, whose else arm is empty.
-- Two arms are spelled here in one, because an author who has nothing to say
-- in the other arm should not have to write it twice.
--
-- Nothing follows a @when@: it is a terminal, like the @if@ it sugars, so it
-- ends the block exactly as the @stop@ it replaced did.
--
-- 'helloProgram' ends the other way a block can, and says it in one statement:
-- @'Agentic.Workflow.ask_' (tool \"say\") …@ is @act@ and then @stop@ — the same
-- term, so the printed program did not move when it was written this way. The
-- @act@ inside @hardenProgram@'s @when@ stays an @act@, because a @when@ body
-- is an arm block minus its terminal and @when@ supplies that.
--
-- This module still enables @RebindableSyntax@ — hence the explicit @Prelude@
-- import, and the @fromString@ beside it that @OverloadedStrings@ then needs
-- by name — because that is what an authoring module is: write @if ok then …
-- else …@ here, with two arms to say, and it reaches
-- 'Agentic.Workflow.ifThenElse' rather than @Prelude@'s @Bool@.
--
-- == The names this prints are not these names
--
-- A library cannot read a Haskell binder's spelling, and this module uses no
-- Template Haskell, so the surface generates the name each binding /prints/
-- from its depth: @b0@ is @guide@, @b1@ is @draft@, @b2@ is the carrier and
-- the settled binder, @b3@ is the review and the owner's flag, and @r2@ is the
-- revision's result. The Haskell binders here are for the reader of /this
-- module/; a @{hole}@ prints whatever its handle carries, so binder and hole
-- cannot disagree, and tier1 compares this program against @example-000@ __up
-- to alpha__ — the two examples are the only cases it compares that way.
--
-- An author who wants the printed program to read as this one does writes
-- @'Agentic.Workflow.named' "guide" (ask …)@; nothing here does, deliberately,
-- because the generated names are the default a reader of the surface will
-- meet.
--
-- == What the transcription still pins
--
--   * __A @define@ contributes its own chunk.__ @{spec}@ splices @spec@'s one
--     literal beside the surrounding text without fusing with it, so the
--     drafting prompt is three chunks and not one. Writing the prompt as a
--     single string would render the same text and print a different program.
--
--   * __The carrier and the settled binder share a name.__ They are different
--     binders in different scopes — here, two different lambda binders — and
--     both are bound at the same depth, so both print @b2@, exactly as the
--     frozen program calls both @patch@. It is the one place in the whole
--     corpus that leans on that.
--
--   * __The review is a panel__, which no other rebuilt case does, and its
--     three members fold right in the noncommutative verdict monoid.
--
--   * __@guide@ is read from inside the loop.__ Every round of the unroll
--     re-reads it through the accumulated substitutions and never re-asks
--     @cat@: 19 ask nodes, one @cat@ question.
--
--   * __@served by \"deep\"@ appears twice__, on the draft and on the
--     amendment.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Example.Harden
  ( -- * The programs
    hardenProgram,
    helloProgram,

    -- * The registry
    examplesRegistry,
    examples,
    lookupExample,
    exampleNames,
  )
where

import Agentic.Cli (Registry (..), Row (..))
import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import Data.Text (Text)
import Example.Isaac (isaacBlurb, isaacExamples, isaacHelp, isaacScript)
import Prelude

-- ---------------------------------------------------------------------------
-- The defines, once
-- ---------------------------------------------------------------------------

-- | @define spec = "harden the parser"@.
spec :: Text
spec = "harden the parser"

-- | @define verdictSpec = …@ — the format line every reviewer's prompt ends
-- with.
verdictSpec :: Text
verdictSpec =
  "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."

-- | @define flagSpec = "Reply with exactly yes or no."@ — the owner's.
flagSpec :: Text
flagSpec = "Reply with exactly yes or no."

-- ---------------------------------------------------------------------------
-- The flagship
-- ---------------------------------------------------------------------------

-- | The flagship, corpus entry @example-000@: read the house style, draft a
-- patch, review it by a three-model panel under a bounded revision, and — if
-- the owner says so — apply it.
--
-- Level @branch@, size 36, 19 ask nodes, 9 paths folding between 5 and 15.
-- @codes@ is @null@: a program that branches has no single sequence of answer
-- kinds, which is exactly what separates the flagship from 'helloProgram'.
hardenProgram :: Program
hardenProgram = workflow W.do
    guide <- ask (tool "cat") [wf|Write out the house style guide, at most four short lines.|]

    draft <- ask (model "author" `servedBy` "deep") [wf|
        Draft a patch satisfying:
        {spec}
        Reply with a unified diff only.|]

    result <- revising draft (atMost 2) \patch -> W.do
        verdict <- panel
          [ ask (model "reviewer-correct") [wf|
              {guide}
              Is this patch correct?
              {patch}
              {verdictSpec}|],
            ask (model "reviewer-secure") [wf|
              {guide}
              Is this patch secure?
              {patch}
              {verdictSpec}|],
            ask (model "reviewer-simple") [wf|
              Could this patch be simpler?
              {patch}
              {verdictSpec}|]
          ]
        amend (ask (model "author" `servedBy` "deep") [wf|
            {guide}
            Revise this patch:
            {patch}
            {verdict}
            Reply with the revised diff only.|])

    case result of
      Settled patch -> W.do
        ok <- confirm (person "owner") [wf|
            Apply this patch?
            {patch}
            {flagSpec}|]

        when ok $ W.do
          act (tool "apply") [wf|
              Apply:
              {patch}
              Write the patched file here, then reply DONE.|]
      Unsettled _ -> stop

-- ---------------------------------------------------------------------------
-- The small one
-- ---------------------------------------------------------------------------

-- | The small one, corpus entry @example-001@: two questions and an act.
--
-- Level @pipeline@, size 4, one path, @codes [text, text, receipt]@ and both
-- bills 3. It exists so that the CLI has a subject that is not the flagship:
-- no branch, no loop, and a bill the analysis knows exactly rather than
-- bounds.
--
-- @brief@ is a @define@ — here a @where@ binding, which the @[wf|…|]@ holes
-- find in the ordinary lexical scope, exactly as they find the block's own
-- binders — so it contributes a chunk of its own to each of the first two
-- prompts, unfused with the literal beside it.
helloProgram :: Program
helloProgram = workflow W.do
    subject <- ask (tool "cat") [wf|
        Name one thing worth greeting.
        {brief}|]

    greeting <- ask (model "greeter") [wf|
        Write a greeting for this, and nothing else:
        {subject}
        {brief}|]

    ask_ (tool "say") [wf|
        Say it:
        {greeting}|]
  where
    -- @define brief = "Reply in one short line."@
    brief :: Text
    brief = "Reply in one short line."

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | The named programs, in the order the CLI lists them.
--
-- The two walked examples first, because they are the ones tier1 pins against
-- the frozen corpus and the ones the documentation walks. After them,
-- "Example.Isaac"'s five — Isaac Shapira's @incite@ workflows written in this
-- surface, which are an /experiment/ about what the language can express and
-- not conformance fixtures: nothing pins them, and each carries in its haddock
-- the places where the original did not fit.
--
-- __An entry is a program or a program of its inputs__
-- ('Agentic.Workflow.Example'). These two are 'Fixed', and stay so: they are
-- the frozen corpus entries, and a program that took an input would be a
-- different text from the one tier0 replays. @review-lite@ is the one entry
-- that 'Needs' something, and what it needs is the commit it reviews.
examples :: [(Text, Example)]
examples =
  [ ("harden", Fixed hardenProgram),
    ("hello", Fixed helloProgram)
  ]
    <> isaacExamples

-- | The keys of 'examples', for a usage message or an error.
exampleNames :: [Text]
exampleNames = map fst examples

-- | 'examples' as a lookup.
lookupExample :: Text -> Maybe Example
lookupExample n = lookup n examples

-- | 'examples' as the registry @agentic-run@ is the CLI /of/.
--
-- @agentic-run@ is @'Agentic.Cli.cliMain' examplesRegistry@ and nothing else.
-- The other registry lives in the owner's separate @agent-workflows@
-- repository, and the two are deliberately not one table: this one
-- is pinned field by field by @ci\/examples.sh@ because its numbers are
-- evidence about the language, and a toolbox whose rubrics move weekly cannot
-- be held to that without the pins being loosened for both. See "Agentic.Cli".
examplesRegistry :: Registry
examplesRegistry =
  Registry
    { regBinary = "agentic-run",
      regNoun = "example",
      regBanner = "list, plan, price and run the worked examples",
      regRows = [(n, Row ex (blurbFor n) (helpFor n) (scriptFor n)) | (n, ex) <- examples]
    }

-- | The one line @list@ prints beside a name.
blurbFor :: Text -> Text
blurbFor "harden" = "the flagship: draft a patch, review it by panel under a bounded revision, apply it"
blurbFor "hello" = "the smallest thing that is still a workflow: two questions and an act"
blurbFor n = isaacBlurb n

-- ---------------------------------------------------------------------------
-- The pages
-- ---------------------------------------------------------------------------

-- | The page @agentic-run help \<name\>@ prints under the computed header
-- ('Agentic.Cli.rowHelp').
--
-- __Six sections, and the CLI supplies none of them.__ What this row is, what
-- each of its inputs /means/, which transport it wants, one command line that
-- would really run it, one rehearsal that consults nobody, and the caveats a
-- price cannot state. The header above it already carries @level@, @cost@,
-- @inputs@, @runFacts@ and @pins@, so __no text below names a number__: a
-- hand-copied price is drift with a schedule, and the one place a page may talk
-- about cost is a caveat pointing at @agentic-run cost@.
--
-- These seven are the reference implementation the seventy-two in
-- @agent-workflows@ are written against, which is why each of them says the
-- same six things in the same order even where a row could have said less.
--
-- Keyed by 'Text' and therefore not exhaustiveness-checked, exactly as
-- 'blurbFor' and 'scriptFor' are — so @ci\/examples.sh@ runs @help@ for every
-- registered name, because a missing case here is a fall-through and not a
-- build failure.
helpFor :: Text -> Text
helpFor "harden" = hardenHelp
helpFor "hello" = helloHelp
helpFor n = isaacHelp n

-- | 'hardenProgram''s page.
hardenHelp :: Text
hardenHelp =
  [wft|
    Corpus entry `example-000` as a program: read the house style guide from a
    tool, draft a patch against it, review the draft by a three-model panel
    under a bounded revision, and — if the owner says yes — apply it. It is the
    same value tier1 rebuilds and tier0 replays, so what a run of it demonstrates
    is the language rather than this executable.

    **Inputs.** none. What it hardens is a `define` written in the source
    (`Example.Harden.spec`, "harden the parser") and not a flag: the frozen
    corpus entry has no input, and a program that took one would be a different
    text from the one tier0 compares against.

    **Transport.** An adapter of the run's own, and a scratch directory you are
    willing to have written in — the last statement is an act that writes the
    patched file, and `--scratch` names the only place an act may write. The
    question before that act is put to a *person*; under `--engine acp` the
    adapter answers for them, so an unattended run applies the patch unless the
    adapter is told to refuse.

    ```sh
    agentic-run run harden --engine acp --adapter claude --scratch "$PWD" \
       --route deep=acp:claude
    ```

    **Rehearsal.** Every question answered from the row's own canned table,
    consulting nobody and running nothing:

    ```sh
    agentic-run run harden --scripted
    ```

    **Caveats.**

    * It refuses `--require-pinned`. The three panel reviewers are asked of
      `model` with no `served by`, deliberately, because the frozen entry pins
      only the author's two asks — so `deep` is the one name `--route` accepts,
      and every other question takes the default answerer.
    * The two cheapest endings never reach the act, and neither touches your
      tree: the owner answering `no` skips it, and a revision that has not
      settled after its two rounds stops instead.
    * `--adapter-arg --refuse` is how the stub adapter is told to answer *no* to
      the owner's question, which is how the skipping arm is exercised without a
      person in the loop.
  |]

-- | 'helloProgram''s page.
helloHelp :: Text
helloHelp =
  [wft|
    Corpus entry `example-001`, and the smallest thing that is still a workflow:
    ask a tool for something worth greeting, ask a model to greet it, say it.
    It exists so that the CLI has a subject that is not the flagship.

    **Inputs.** none.

    **Transport.** Fine anywhere. It asks no person and it writes no file of
    yours, so a live `agent-deck` pane you are watching answers it as well as an
    adapter of the run's own, and `--scratch` changes nothing about what it
    means.

    ```sh
    agentic-run run hello --engine acp --adapter claude
    ```

    **Rehearsal.** Three canned replies, and nobody consulted:

    ```sh
    agentic-run run hello --scripted
    ```

    **Caveats.**

    * It pins no model at all — the `pins` line above is `—`, and what that is
      telling you is that `--route` will refuse every name you could give it.
    * It has one path, so the two bounds above coincide and this program has a
      price rather than a range: a run that billed anything else is a run of a
      different program. For the same reason — nothing branches — `agentic-run
      plan hello` prints a `codes` line that is a full sequence rather than
      `null`. It shares that with `plan-feature`, the table's other pipeline;
      the five branching rows print `null`.
    * It refuses `--require-pinned`: `greeter` is asked with no `served by`.
  |]

-- ---------------------------------------------------------------------------
-- The canned answers
-- ---------------------------------------------------------------------------

-- | The scripted table for an example: the canned replies of
-- @agent-cat\/test\/stub_adapter.py@, __keyed by prefix__ rather than by
-- substring.
--
-- The stub matches substrings (@\"correct?\"@, @\"secure?\"@), which
-- 'Agentic.Exec.scriptedWorld' deliberately does not: a substring key can match
-- a prompt through an answer that was spliced into it, so a patch that
-- mentioned @correct?@ would answer the reviewers' question. Prefixes cannot do
-- that, and the flagship's prompts are already distinguishable by their first
-- line — two of the three reviews open with the guide, and their second lines
-- differ.
--
-- The answers are the stub's: a fixed guide, a fixed patch, three approvals,
-- consent, and a receipt. Under them the revision settles in its first round,
-- so the amendment prompt is never put and the run bills seven consultations —
-- @Harden.bill_apply_demo@ (@Agentic\/Core\/HardenPatch.lean:973@), restated
-- as @Dsl.bill_flagship_apply@ (@Agentic\/Core\/DslFlagship.lean:353@).
--
-- __It lives beside the programs it answers__, which is where
-- "Example.Isaac"'s already did and for the reason that module gives: a key is
-- a prefix of a rendered prompt, and a table kept in the runner is a table that
-- drifts from the prompts it keys on. Making the registry a value is what let
-- the last two rows come home.
scriptFor :: Text -> [(Text, Text)]
scriptFor "harden" =
  [ ("Write out the house style guide", guideText),
    ("Draft a patch satisfying:", patchText),
    (guideText <> "\nIs this patch correct?", "APPROVE"),
    (guideText <> "\nIs this patch secure?", "APPROVE"),
    ("Could this patch be simpler?", "APPROVE"),
    -- Unreachable while all three reviews approve, and here so that a run with
    -- an objecting table amends with a patch rather than with prose.
    (guideText <> "\nRevise this patch:", patchText),
    ("Apply this patch?", "yes"),
    ("Apply:", "DONE")
  ]
scriptFor "hello" =
  [ ("Name one thing worth greeting.", "the sunrise"),
    ("Write a greeting for this, and nothing else:", "Good morning, sunrise."),
    ("Say it:", "DONE")
  ]
-- "Example.Isaac"'s five carry their own table, in their own module, because
-- its keys /are/ the prompt defines those programs are written from: a key
-- there is a prefix by construction rather than by proofreading, which is what
-- a table living beside a program in another file cannot promise.
scriptFor name = isaacScript name

-- | @stub_adapter.py:131@'s @GUIDE@, byte for byte.
--
-- __Written on one line of source, and that is not an accident.__ These two
-- texts are documented twins of the stub adapter's @GUIDE@ and @PATCH@, and
-- @ci/acp.sh@ greps their wording, so their bytes may not move. The owner's
-- ruling of 2026-08-21 is total — every multi-line string in this tree is a
-- @[wft|…|]@ — and a fence joins its lines with @\n@, so a text that carries
-- no newline has exactly one spelling at the fence: one line, however wide.
-- The width is the price of the ruling and is paid here on purpose. The
-- adapter is Python and is outside the ruling; the sync claim holds because
-- nothing on this side moved.
--
-- 'patchText' is the same rule the other way. Its text /does/ carry the
-- newlines, so it is a block fence written with its own margin at the minimum
-- — the @---@, @+++@, @\@\@@, @-@ and @+@ columns — which is what leaves the
-- diff's two-space body indentation standing after the common strip. The
-- trailing newline is @'<>' "\\n"@, because a fence never ends in one.
guideText :: Text
guideText =
  [wft|House style: two-space indent, no tabs, every public name documented, and failures returned rather than raised.|]

-- | @stub_adapter.py:136@'s @PATCH@ — a real unified diff, because the act's
-- prompt wraps it and a run that applied it would have something to apply.
patchText :: Text
patchText =
  [wft|
    --- a/src/parse.c
    +++ b/src/parse.c
    @@
    -  char buf[64]; strcpy(buf, input);
    +  char buf[64]; snprintf(buf, sizeof buf, "%s", input);|]
    <> "\n"
