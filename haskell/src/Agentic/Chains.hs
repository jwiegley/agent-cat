{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- |
-- Module      : Agentic.Chains
-- Description : The fail-over table a runner builds out of a printed program.
--
-- D6's one traversal: walk a 'RawProgram' and collect every @served by@'s
-- @primary -> alternates@ into the table @Agentic.Exec.runPlanWith@ walks.
--
-- __Exec-only.__ No kernel, no oracle, no corpus. Nothing here changes what a
-- plan /means/: @Check.askShape@ takes @primary@ alone, so two asks differing
-- only in their alternates elaborate to the same plan, ask the same question
-- and bill the same. What the alternates reach is this table and the runner,
-- and nothing below it.
--
-- __Why it is @Either@, and why the refusal is the runner's rather than the
-- language's.__ Two asks pinning the same primary with /different/ alternates
-- make the table ill-defined. The program is well-formed and its meaning is
-- unchanged; what is ill-defined is the runner's chain table, so @agentic-run@
-- refuses to start and names both spellings. Keeping it out of
-- "Agentic.Guards" keeps the guard vocabulary the oracle shares (the
-- bisimulation's refusal parity) untouched — the six guards are Lean's six, and
-- a seventh invented here would be a port of a different checker.
--
-- The consequence, stated rather than hidden: __the chain is a property of the
-- model, not of the question.__ A program may not say \"deep or broad\" here
-- and \"deep or cheap\" there. That is a restriction, it matches the reading
-- that a chain is fleet configuration rather than question content, and it buys
-- a kernel nobody has to touch. It is reversible: the field is already per-ask
-- in the 'Agentic.Raw.RawAsk', and the cost of the change would be teaching
-- @Q.Shape@, @EventKey@, @eventJson@ and @toWorld@ to carry it and then to
-- ignore it — three deliberate blind spots in the kernel, which is what this
-- declines to pay for now.
module Agentic.Chains
  ( servedChains,
  )
where

import Agentic.Raw
  ( Raw (..),
    RawAsk (..),
    RawBodyStmt (..),
    RawFn (..),
    RawProgram (..),
    RawRhs (..),
    RawSource (..),
    Served (..),
    TextMember (..),
  )
import Agentic.WF (wft)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

-- | Every @served by@ chain a program writes, keyed by the model it pins.
--
-- The traversal is @Agentic.Guards.askCounts@'s: every function body in
-- declaration order, then @main@ — descending into panel members, into a text
-- panel's members, into a bounded revision's @review@ and @amend@, and into
-- every arm of every branching. A decider names no addressee and a call's
-- arguments carry no ask, so neither contributes.
--
-- @Right table@ is the chain per primary. @Left why@ is the runner precondition
-- broken: one primary, two different spellings.
servedChains :: RawProgram -> Either Text (Map Text [Text])
servedChains prog =
  foldl add (Right Map.empty) (concatMap fnServes (progFns prog) ++ blockServes (progMain prog))
  where
    add acc (Served p as) = case acc of
      Left why -> Left why
      Right t -> case Map.lookup p t of
        Nothing -> Right (Map.insert p as t)
        Just as'
          | as' == as -> Right t
          | otherwise ->
              Left $
                "the model `"
                  <> p
                  <> "` is pinned twice with different spares — once as "
                  <> spell as'
                  <> " and once as "
                  <> spell as
                  <> [wft|. A chain is a property of the model and not of the question, so a run cannot hold both; write one spelling everywhere, or drop the spares.|]

    spell [] = "`served by \"" <> "…" <> "\"` with no spare"
    spell as = "`or " <> T.intercalate ", " as <> "`"

    fnServes f = concatMap stmtServes (fnBody f)

    stmtServes = \case
      BodyBind _ _ r _ -> rhsServes r
      BodyAct a _ -> askServes a
      BodyCallS {} -> []

    askServes a = case askModel a of
      Nothing -> []
      Just srv -> [srv]

    rhsServes = \case
      RhsAsk a -> askServes a
      RhsPanel ms _ -> concatMap askServes ms
      RhsPanelText ms _ -> concatMap (askServes . tmAsk) ms
      RhsDecide {} -> []
      RhsCall {} -> []

    srcServes = \case
      SrcRhs r -> rhsServes r
      SrcRevising _ _ _ _ _ rev am _ -> rhsServes rev ++ rhsServes am
      SrcRevisingOn _ _ _ _ _ rev am _ -> rhsServes rev ++ rhsServes am

    blockServes = \case
      RawEmpty _ -> []
      RawAnswer _ _ -> []
      RawBind _ _ src rest _ -> srcServes src ++ blockServes rest
      RawAct a rest _ -> askServes a ++ blockServes rest
      RawKnownHere _ rest _ -> blockServes rest
      RawCallStmt _ _ rest _ -> blockServes rest
      RawIfFlag _ y n _ -> blockServes y ++ blockServes n
      RawCaseVerdict _ a o d _ -> concatMap blockServes [a, o, d]
      RawCaseResult _ _ _ st un _ -> concatMap blockServes [st, un]
      RawCaseEnding _ _ _ _ st un ab _ -> concatMap blockServes [st, un, ab]
