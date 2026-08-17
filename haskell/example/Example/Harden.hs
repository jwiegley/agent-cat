-- |
-- Module      : Example.Harden
-- Description : The walked examples, written in the authoring surface.
--
-- @agent-cat@ ships two programs under @example\/@ that are not corpus
-- fixtures but /prose/: the flagship @harden.wf@, which the language guide
-- walks line by line, and @hello.wf@, the smallest thing that is still a
-- workflow. Both are frozen in the corpus (@example-000@ and @example-001@),
-- and both are written here in "Agentic.Workflow" — ordinary Haskell values,
-- sugar over "Agentic.Builder", whose combinators these statements are.
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
-- == How to read this against @harden.wf@
--
-- Statement for statement. @x <- ask …@ is @x <- ask …@, a bind that is a
-- Haskell bind; @W.do@ is @QualifiedDo@ and nothing more. A @```fence```@ is a
-- @[wf|…|]@, with the same @{name}@ holes and the same layout rule —
-- surrounding blank lines dropped, common indentation stripped, line breaks
-- kept, no trailing newline. A @define@ is a Haskell binding, spliced by a
-- hole that names it.
--
-- The two names that are not binds are the two /lambdas/, and they are
-- bindings too: @\\patch -> …@ under 'revising' is the carrier, and
-- @\\patch -> …@ under 'caseResult' is the settled binding. The @.wf@ writes
-- them @revising draft as patch@ and @settled patch@.
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

module Example.Harden
  ( -- * The programs
    hardenProgram,
    helloProgram,

    -- * The registry
    examples,
    lookupExample,
    exampleNames,
  )
where

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.Text (Text)

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

-- | @example\/harden.wf@: read the house style, draft a patch, review it by a
-- three-model panel under a bounded revision, and — if the owner says so —
-- apply it.
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

    caseResult result
      -- settled patch { … }
      ( \patch -> W.do
          ok <- confirm (person "owner") [wf|
              Apply this patch?
              {patch}
              {flagSpec}|]

          ifFlag ok
            ( W.do
                act (tool "apply") [wf|
                    Apply:
                    {patch}
                    Write the patched file here, then reply DONE.|]
                stop )
            stop )
      -- unsettled { stop }
      stop

-- ---------------------------------------------------------------------------
-- The small one
-- ---------------------------------------------------------------------------

-- | @example\/hello.wf@: two questions and an act.
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

    act (tool "say") [wf|
        Say it:
        {greeting}|]
    stop
  where
    -- @define brief = "Reply in one short line."@
    brief :: Text
    brief = "Reply in one short line."

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | The named programs, in the order the CLI lists them.
examples :: [(Text, Program)]
examples =
  [ ("harden", hardenProgram),
    ("hello", helloProgram)
  ]

-- | The keys of 'examples', for a usage message or an error.
exampleNames :: [Text]
exampleNames = map fst examples

-- | 'examples' as a lookup.
lookupExample :: Text -> Maybe Program
lookupExample n = lookup n examples
