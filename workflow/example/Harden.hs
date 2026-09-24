-- | The canonical flagship workflow, frozen as corpus entry @example-000@.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Harden (hardenProgram, guide) where

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import Data.Text (Text)
import Prelude

-- ---------------------------------------------------------------------------
-- The defines, once
-- ---------------------------------------------------------------------------

-- | @define spec = "harden the parser"@.
spec :: Text
spec = "harden the parser"

-- | @define guide = …@ — the house style guide that two reviewers and every
-- revision quote.
guide :: Text
guide =
  "House style: two-space indent, no tabs, every public name documented, and failures returned rather than raised."

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

-- | The flagship, corpus entry @example-000@: draft a patch, review it against
-- the house style by a three-model panel under a bounded revision, and — if
-- the owner says so — apply it.
--
-- Level @branch@, size 35, 18 ask nodes, 9 paths folding between 4 and 14.
-- @codes@ is @null@: a program that branches has no single sequence of answer
-- kinds, which is exactly what separates the flagship from 'helloProgram'.
hardenProgram :: Program
hardenProgram = workflow W.do
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
