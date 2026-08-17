{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The workflow block's do-notation: @W.do@.
module W ((>>=), (>>)) where

import Surface
import Prelude hiding ((>>), (>>=))

(>>=) ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st -> (a -> W j k b) -> W i k b
(>>=) = bindW @st @i @j @a

(>>) ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st -> W j k b -> W i k b
(>>) = thenW @st @i @j @a
