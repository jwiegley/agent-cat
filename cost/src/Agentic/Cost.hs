{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Agentic.Cost
-- Description : Pure static cost interpretation of a workflow plan.
module Agentic.Cost
  ( costM,
    costSummary,
  )
where

import Agentic.Plan (Plan (..), tagValues)

-- | Every possible request-count bill, one value per finite branch path.
-- Corresponds to @Cost.costM@ in @model/Agentic/Core/Cost.lean@ at the counting
-- price. Dynamic plans have no finite static bill.
costM :: Plan g a -> [Integer]
costM = \case
  PRet _ -> [0]
  PAskC _ _ rest -> map (+ 1) (costM rest)
  PAsk _ _ _ rest -> map (+ 1) (costM rest)
  PCase tag _ arms -> concatMap (costM . arms) (tagValues tag)
  PDyn {} -> []

-- | Cheapest bill, dearest bill, and path count.
costSummary :: Plan g a -> (Maybe Integer, Maybe Integer, Integer)
costSummary plan =
  ( if null bills then Nothing else Just (minimum bills),
    if null bills then Nothing else Just (maximum bills),
    toInteger (length bills)
  )
  where
    bills = costM plan
