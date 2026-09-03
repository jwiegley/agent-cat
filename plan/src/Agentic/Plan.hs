{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Agentic.Plan
-- Description : Pure plan observations plus operational trace records.
--
-- The typed structural representation lives in "Agentic.DSL.Plan". This
-- downstream facade re-exports it and adds the pure folds consumed by planning
-- and cost reporting. Runtime trace records remain here until the runtime package
-- is extracted.
module Agentic.Plan
  ( module Agentic.DSL.Plan,
    AnswerSource (..),
    ExecEvent (..),
    ExecTrace,
    Level (..),
    levelName,
    level,
    size,
    askNodes,
    intentCounts,
    toolExecNodes,
    codes,
    schemaRequirements,
  )
where

import Agentic.DSL (Addressee (AddrToolExec))
import Agentic.DSL.Plan
import Agentic.Schema (Code, SomeCode, SomeSchema (..))
import Data.Text (Text)
-- | How this occurrence obtained its answer. 'AnswerAsked' may carry a
-- failover-relabelled question; 'AnswerReused' means no request was dispatched.
data AnswerSource (c :: Code)
  = AnswerReused
  | AnswerAsked !(Q c)

deriving instance Eq (AnswerSource c)
deriving instance Show (AnswerSource c)

-- | One annotated Plan occurrence. The authored request is never rewritten by
-- routing or fallback.
data ExecEvent where
  ExecEvent :: SCode c -> Request c -> AnswerSource c -> El c -> ExecEvent

type ExecTrace = [ExecEvent]

-- ---------------------------------------------------------------------------
-- The static folds: level, size, askNodes, codes
-- ---------------------------------------------------------------------------

-- | @Agentic/Core/Level.lean:53@ — the four rungs, as a chain. The 'Ord'
-- instance derived from this constructor order is Lean's @LinearOrder@, the
-- pullback of @toNat@ (batch 0, pipeline 1, branch 2, dynamic 3).
data Level
  = Batch
  | Pipeline
  | Branch
  | Dynamic
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @levelName@ (@Agentic/Core/Explain.lean:69@) — the rung as the one word a
-- report and the MCP wire both carry.
levelName :: Level -> Text
levelName = \case
  Batch -> "batch"
  Pipeline -> "pipeline"
  Branch -> "branch"
  Dynamic -> "dynamic"

-- | @level@ (@Agentic/Core/Level.lean:133@): each clause is the rung its former
-- forces, joined with what the subterms force.
--
-- Lean writes it as an algebra and takes the fold (@levelAlg@, @Level.lean:123@),
-- so the recursive positions arrive already folded — @l@ below /is/ @level k@:
--
-- > def levelAlg : PlanAlg (fun _ _ => Level) where
-- >   ret _ := .batch
-- >   askC _ _ l := l
-- >   ask _ _ _ l := max .pipeline l
-- >   case := fun _ _ arms => max .branch (Finset.univ.sup fun x => arms x)
-- >   dyn _ _ _ := .dynamic
--
-- The port keeps the direct recursion: there is one @Plan@ here and no theorem
-- to state about it, so the algebra record would buy nothing that
-- @PlanAlg.fold_unique@ buys in Lean.
--
-- __'PAskC' is @level k@, not @max Batch (level k)@__ — a closed question adds
-- nothing. The two are equal ('Batch' is @⊥@), but writing the join invites
-- writing @max Pipeline@ there too, which would make every closed-question
-- program 'Pipeline'; sixteen corpus entries are @batch@ and would all break.
--
-- The 'PCase' fold seeds with 'Branch' and joins, because @Finset.univ.sup@ over
-- an empty tag type is @⊥ = Batch@: an arm-less branch is still a branch. Both
-- tag types here are inhabited, so that is a fidelity point only.
level :: Plan g a -> Level
level = \case
  PRet _ -> Batch
  PAskC _ _ k -> level k
  PAsk _ _ _ k -> max Pipeline (level k)
  PCase t _ arms -> foldr (max . level . arms) Branch (tagValues t)
  PDyn {} -> Dynamic

-- | @Plan.size@ (@Agentic/Core/Explain.lean:152@): how many nodes the term has,
-- a 'PDyn' counting as one because the number of nodes below it is not a number.
--
-- A @case@ __counts itself__ (the @1 +@); compare 'askNodes', which does not.
-- The asymmetry is not a typo — @battery-085@'s @size 11@ against
-- @askNodes 4@ only comes out with it.
size :: Plan g a -> Integer
size = \case
  PRet _ -> 1
  PAskC _ _ k -> 1 + size k
  PAsk _ _ _ k -> 1 + size k
  PCase t _ arms -> 1 + sum (map (size . arms) (tagValues t))
  PDyn {} -> 1

-- | @Plan.askNodes@: request nodes written in term, counting both branch arms.
--
-- Not a bill: a run pays for requests on its selected path, which
-- 'Agentic.Cost.costM' counts.
-- branching (@Plan.length_trace_eq_askNodes@). A @case@ contributes only its
-- arms, and a 'PDyn' contributes nothing.
askNodes :: Plan g a -> Integer
askNodes = \case
  PRet _ -> 0
  PAskC _ _ k -> 1 + askNodes k
  PAsk _ _ _ k -> 1 + askNodes k
  PCase t _ arms -> sum (map (askNodes . arms) (tagValues t))
  PDyn {} -> 0

-- | Structural counts of @(consult, observe, effect)@ occurrences across every
-- finite branch.  Like 'askNodes', this is program metadata rather than a bill.
intentCounts :: Plan g a -> (Integer, Integer, Integer)
intentCounts = \case
  PRet _ -> (0, 0, 0)
  PAskC _ request rest -> addIntent (reqIntent request) (intentCounts rest)
  PAsk _ shape _ rest -> addIntent (rsIntent shape) (intentCounts rest)
  PCase tag _ arms -> foldr (addCounts . intentCounts . arms) (0, 0, 0) (tagValues tag)
  PDyn {} -> (0, 0, 0)
  where
    addIntent intent (consults, observes, effects) = case intent of
      Consult -> (consults + 1, observes, effects)
      Observe -> (consults, observes + 1, effects)
      Effect -> (consults, observes, effects + 1)
    addCounts (a, b, c) (x, y, z) = (a + x, b + y, c + z)

-- | Program-authored command occurrences across every finite branch.
toolExecNodes :: Plan g a -> Integer
toolExecNodes = \case
  PRet _ -> 0
  PAskC _ request rest -> at (qAddressee (reqQuestion request)) + toolExecNodes rest
  PAsk _ shape _ rest -> at (shAddressee (rsQuestion shape)) + toolExecNodes rest
  PCase tag _ arms -> sum (map (toolExecNodes . arms) (tagValues tag))
  PDyn {} -> 0
  where
    at AddrToolExec {} = 1
    at _ = 0

-- | @codes@ (@Agentic/Core/Cost.lean:329@): the sequence of answer codes the
-- term will ask for, if that sequence is fixed by the term.
--
-- 'Nothing' at a 'PCase' and at a 'PDyn' — those are the two places the
-- sequence is not fixed. A fold of the term alone: no environment, no world.
--
-- The reply serializes each existential `SomeCode`; built-ins retain their old
-- strings and schema-indexed codes carry the schema that is part of their identity.
codes :: Plan g a -> Maybe [SomeCode]
codes = \case
  PRet _ -> Just []
  PAskC c _ k -> (fromSCode c :) <$> codes k
  PAsk c _ _ k -> (fromSCode c :) <$> codes k
  PCase {} -> Nothing
  PDyn {} -> Nothing

schemaRequirements :: Plan g a -> [SomeSchema]
schemaRequirements = \case
  PRet _ -> []
  PAskC code _ rest -> at code ++ schemaRequirements rest
  PAsk code _ _ rest -> at code ++ schemaRequirements rest
  PCase tag _ arms -> concatMap (schemaRequirements . arms) (tagValues tag)
  PDyn {} -> []
  where
    at :: SCode c -> [SomeSchema]
    at (SStructured schema) = [SomeSchema schema]
    at _ = []
