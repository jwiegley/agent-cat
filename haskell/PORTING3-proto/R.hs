{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The revision clauses' do-notation: @R.do@. One review, then one amend.
module R ((>>=), (>>)) where

import GHC.TypeLits (ErrorMessage (..), KnownSymbol, TypeError)
import Surface
import Prelude hiding ((>>), (>>=))

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

(>>) :: ARevisionReviewsThenAmends a => a -> b -> c
(>>) = error "unreachable: ARevisionReviewsThenAmends has no honest instance"
