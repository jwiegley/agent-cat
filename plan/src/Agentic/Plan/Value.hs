-- | Pure value and codec surface required by plan interpreters.
module Agentic.Plan.Value
  ( Addressee (..),
    Code (..),
    SomeCode (..),
    sameCode,
    decode,
    render,
    renderSchema,
    decodeFlag,
    decodeVerdict,
    sayFlag,
    sayVerdict,
  )
where

import Agentic.DSL (Addressee (..), Code (..), SomeCode (..), decodeFlag, decodeVerdict, sayFlag, sayVerdict)
import Agentic.Schema (sameCode)
import Agentic.Schema.Json (decode, render, renderSchema)
