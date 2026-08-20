-- | The frozen __yield vector__, written in the authoring surface.
--
-- One program: @semantic-008@, a bounded revision at one amendment whose
-- /unsettled/ arm splices the binder the loop handed it. It is here because
-- D3's ending carries the candidate all the way to the surface pattern
-- (@'Agentic.Workflow.Unsettled' patch@) and, until this module, __no Haskell
-- program in the repository read it__: the flagship's arm is
-- @Unsettled _ -> stop@, and so are all six of "Example.Isaac"'s, one of which
-- carries a note saying the yield is writable there and deliberately not
-- written — rewriting an existing arm moves that row's @size@, @askNodes@,
-- @costSummary@ and both bills, and a table that moved for two reasons at once
-- is unattributable.
--
-- So the reading is exercised where it costs nothing: a new entry, and this
-- one program to hold against it.
--
-- __What the pairing pins.__ Lean proves the semantics — @run_upToTwice_stubborn@
-- (@Agentic/Core/Denote.lean:933@) states that an exhausted loop hands back the
-- candidate it ran out /holding/. What no cross-implementation check exercised
-- was an arm that /reads/ that candidate at a bound above zero, where the held
-- artefact is no longer the first draft. Under the objecting world of the
-- frozen entry, both implementations must produce the same five-event trace,
-- whose last event is
--
-- > tool "log", receipt, prompt "yielded: fix draft: thin"
--
-- — the amendment the second review objected to, and not @"draft"@ (the
-- subject the loop started from) and not a sixth question answering the last
-- objection (a candidate nobody asked for). @battery-192@ makes the same
-- reading at bound @0@, where those three answers coincide; here they part.
--
-- The second world approves at the first check, and the settled arm reads the
-- binder of /its/ scope under the same printed name — which is what an
-- authoring surface always writes, both arms being built at one depth.
--
-- __A conformance fixture, not an example.__ Private to @tier1@, like
-- "CallVectors" and for the same two reasons: @agentic-run@'s registry should
-- not grow a row nobody would want to run, and @RebindableSyntax@ — which is
-- what makes an authoring module one — is module-wide, so "Cases" cannot hold
-- this program at all.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module LoopVectors (semantic008W) where

-- `RebindableSyntax` costs this module its implicit `Prelude`: `fromString` is
-- what `OverloadedStrings` reaches for by name, and `Prelude` comes back for
-- `fromInteger`, which the numeral in @atMost 1@ needs. (Unlike "CallVectors",
-- which writes no numeral and no operator and therefore needs neither.)
import Data.String (fromString)
import Prelude

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W

-- |
-- > workflow {
-- >   d <- ask model "a" "draft"
-- >   r <- revising d as c, at most 1 amendment {
-- >     v <- ask model "m" "review {c}"
-- >     amend c { ask model "a" "fix {c}: {v}" }
-- >   }
-- >   case r { settled q { ask tool "log" "settled: {q}" }
-- >            unsettled q { ask tool "log" "yielded: {q}" } }
-- > }
--
-- The subject carries no annotation — @revising@ grounds its kind, exactly as
-- the flagship's @draft@ is grounded — so the printed @ann@ is @null@ on both
-- sides.
--
-- One amendment is the smallest bound at which the candidate the loop yields
-- differs from the one it began with, and the trace is the whole of the case:
-- draft, review, amend, review, and then the arm, whose act carries what the
-- second review objected to.
semantic008W :: Program
semantic008W = workflow W.do
  draft <- ask (model "a") [wf|draft|]

  result <- revising draft (atMost 1) \patch -> W.do
    verdict <- ask (model "m") [wf|review {patch}|]
    amend (ask (model "a") [wf|fix {patch}: {verdict}|])

  case result of
    Settled patch -> ask_ (tool "log") [wf|settled: {patch}|]
    Unsettled patch -> ask_ (tool "log") [wf|yielded: {patch}|]
