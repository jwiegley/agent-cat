{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}

module Harden (harden, hello) where

import Data.Text (Text)
import Quote (wf)
import qualified R
import Surface
import qualified W

spec :: Text
spec = "harden the parser"

verdictSpec :: Text
verdictSpec =
  "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."

flagSpec :: Text
flagSpec = "Reply with exactly yes or no."

harden :: Raw
harden = workflow W.do
  guide <- #guide =: ask (tool "cat")
    [wf|Write out the house style guide, at most four short lines.|]

  draft <- #draft =: ask (model "author" `servedBy` "deep") [wf|
      Draft a patch satisfying:
      {spec}
      Reply with a unified diff only.|]

  #result =: revising draft #patch (atMost 2) \patch -> R.do
    verdict <- #verdict =: panel
      [ ask (model "reviewer-correct") [wf|
          {guide}
          Is this patch correct?
          {patch}
          {verdictSpec}|]
      , ask (model "reviewer-secure") [wf|
          {guide}
          Is this patch secure?
          {patch}
          {verdictSpec}|]
      , ask (model "reviewer-simple") [wf|
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

  caseResult #patch
    (\patch -> W.do
        ok <- #ok =: confirm (person "owner") [wf|
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
          stop)
    stop

hello :: Raw
hello = workflow W.do
  subject <- #subject =: ask (tool "cat") [wf|
      Name one thing worth greeting.
      {brief}|]

  greeting <- #greeting =: ask (model "greeter") [wf|
      Write a greeting for this, and nothing else:
      {subject}
      {brief}|]

  act (tool "say") [wf|
      Say it:
      {greeting}|]
  stop
  where
    brief :: Text
    brief = "Reply in one short line."
