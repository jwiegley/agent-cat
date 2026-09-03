{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Agentic.Workflow.Do
-- Description : The workflow block's @do@-notation: @W.do@.
--
-- Imported qualified — @import qualified Agentic.Workflow.Do as W@ — so that
-- @W.do@ is a workflow block and ordinary @do@ is still ordinary @do@ in the
-- same module. @QualifiedDo@ rebinds nothing beyond the block it is written
-- on, which is why the surface uses it rather than @RebindableSyntax@.
--
-- There is no @return@, no @pure@ and no @fail@ here, deliberately: a block of
-- this shape never needs them — no failable pattern, no trailing @return@ —
-- and their absence is what makes /a block ends in a terminal/ checkable.
module Agentic.Workflow.Do ((>>=), (>>)) where

import Agentic.Workflow (NoFollow, Step, W, bindW, thenW)
import Prelude hiding ((>>), (>>=))

-- | @x <- statement@.
(>>=) ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st ->
  (a -> W j k b) ->
  W i k b
(>>=) = bindW @st @i @j @a

-- | @statement@, on its own line.
(>>) ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st ->
  W j k b ->
  W i k b
(>>) = thenW @st @i @j @a
