-- |
-- Module      : Agentic.Plan.Decision
-- Description : The decision vocabulary that runtime and conformance consumers read.
--
-- A planning facade over "Agentic.DSL.Decision", as "Agentic.Plan" is for
-- "Agentic.DSL.Plan". It denotes the same objects: the prompt codec of a
-- decision question, and regions of the simplex Δ(T) read on records of ℚ^T.
module Agentic.Plan.Decision (module Agentic.DSL.Decision) where

import Agentic.DSL.Decision
