{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Agentic.Workflow.Revision
-- Description : The revision clauses' @do@-notation: @R.do@.
--
-- A bounded revision reviews once and amends once — @SrcRevising@ has no other
-- shape — so its clauses get their own grammar rather than the workflow
-- block's: a bind whose continuation must be the amendment, and __no__ @>>@ at
-- all. @R.do@ therefore accepts exactly
--
-- > verdict <- #verdict =: <review>
-- > amend <question>
--
-- and a second bind, a missing review, or a statement between the two is a
-- type error that names the rule.
--
-- The @-Wno-simplifiable-class-constraints@ is the local cost of that message:
-- the refusal has to live in an /instance context/, because in a signature GHC
-- reports it at the definition rather than at the offending block.
module Agentic.Workflow.Revision ((>>=), (>>)) where

import Agentic.Workflow
  ( Amendment,
    Clauses,
    Code (..),
    Fresh,
    Named,
    ReviewSrc,
    V,
    bindR,
  )
import GHC.TypeLits (ErrorMessage (..), KnownSymbol, TypeError)
import Prelude hiding ((>>), (>>=))

-- | @verdict <- #verdict =: panel […]@, and then the amendment.
(>>=) ::
  (KnownSymbol nr, Fresh nr ('(nc, c) ': s), ReviewSrc src ('(nc, c) ': s)) =>
  Named nr src ->
  (V nr 'CodeVerdict -> Amendment nc nr c s) ->
  Clauses nc c s
(>>=) = bindR

-- | There is no second statement in a revision: the class has no instance but
-- the one that names the rule.
class ARevisionReviewsThenAmends a

instance
  TypeError
    ( 'Text "a bounded revision reviews first — `verdict <- #verdict =: …` — \
            \and then amends, and has no other statement"
    ) =>
  ARevisionReviewsThenAmends a

-- | Any second statement at all, which is the refusal above.
(>>) :: ARevisionReviewsThenAmends a => a -> b -> c
(>>) =
  error
    "Agentic.Workflow.Revision.>>: unreachable — ARevisionReviewsThenAmends \
    \has no honest instance"
