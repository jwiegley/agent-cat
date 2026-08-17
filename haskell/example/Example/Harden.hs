-- |
-- Module      : Example.Harden
-- Description : The walked examples, written in the monadic surface.
--
-- @agent-cat@ ships two programs under @example\/@ that are not corpus
-- fixtures but /prose/: the flagship @harden.wf@, which the language guide
-- walks line by line, and @hello.wf@, the smallest thing that is still a
-- workflow. Both are frozen in the corpus (@example-000@ and @example-001@),
-- and both are written here in "Agentic.Notation" — bare binds over
-- "Agentic.Workflow", which is itself sugar over "Agentic.Builder", whose
-- combinators these statements are.
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
-- Statement for statement. @x <- ask …@ is @x <- ask …@: the Haskell binder is
-- the name the /program/ prints, because @$('workflow' [| … |])@ reads it off
-- the binder — there is no second spelling of a name anywhere in this module,
-- and no name in the printed program that is not a binder here. A
-- @```fence```@ is a @[wf|…|]@, with the same @{name}@ holes and the same
-- layout rule — surrounding blank lines dropped, common indentation stripped,
-- line breaks kept, no trailing newline. A @define@ is a Haskell binding.
--
-- The two names that are not binds are the two /lambdas/, and they are binders
-- too: @\\patch -> …@ under 'revising' is the carrier, and @\\patch -> …@ under
-- 'caseResult' is the settled binding. The @.wf@ writes them
-- @revising draft as patch@ and @settled patch@.
--
-- @-Wno-unused-matches@ is the one cost of that: a binding read only by a
-- @{hole}@ — @guide@, @verdict@, both @patch@es — is invisible to the renamer
-- that walks the quoted block, because a hole resolves at the splice and not in
-- the bracket. "Agentic.Notation" says why in full.
--
-- == What the transcription still pins
--
--   * __A @define@ contributes its own chunk.__ @{spec}@ splices @spec@'s one
--     literal beside the surrounding text without fusing with it, so the
--     drafting prompt is three chunks and not one. Writing the prompt as a
--     single string would render the same text and print a different program.
--
--   * __The carrier and the settled binder share the name @patch@.__ They are
--     different binders in different scopes — here, two different lambda
--     binders — and both are fresh against @[draft, guide]@. It is the one
--     place in the whole corpus that leans on that.
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
{-# OPTIONS_GHC -Wno-unused-matches #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

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

import Agentic.Notation
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
hardenProgram =
  $( workflow
       [|
         do
           guide <- ask (tool "cat")
             [wf|Write out the house style guide, at most four short lines.|]

           draft <- ask (model "author" `servedBy` "deep") [wf|
               Draft a patch satisfying:
               {spec}
               Reply with a unified diff only.|]

           result <- revising draft (atMost 2) \patch -> do
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
             ( \patch -> do
                 ok <- confirm (person "owner") [wf|
                     Apply this patch?
                     {patch}
                     {flagSpec}|]

                 ifFlag ok
                   ( do
                       act (tool "apply") [wf|
                           Apply:
                           {patch}
                           Write the patched file here, then reply DONE.|]
                       stop )
                   stop )
             -- unsettled { stop }
             stop
         |]
   )

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
-- find in the ordinary lexical scope /at the splice/, exactly as they find the
-- block's own binders — so it contributes a chunk of its own to each of the
-- first two prompts, unfused with the literal beside it.
helloProgram :: Program
helloProgram =
  $( workflow
       [|
         do
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
         |]
   )
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
