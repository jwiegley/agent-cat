-- | The observation of a checked program: the oracle's reply, assembled.
--
-- This is the reply half of @Conformance.lean:240@'s @observe@, lifted out of
-- the tier1 runner and into the library so that every consumer of the Lean
-- oracle — the rebuilt-case runner (@tier1@) and the live bisimulation
-- (@bisim@) — computes the Haskell side of the comparison in exactly one way.
-- If the two runners assembled the reply separately, a bug in one assembly
-- would read as a conformance failure in one runner and as silence in the
-- other; here there is one assembly, and a bug in it fails everywhere at once.
--
-- Three functions, and they are the whole interface:
--
--   * 'observeValue' — the reply for a checked program under a list of worlds;
--   * 'printedValue' — the program as the builder prints it;
--   * 'zeroPosValue' — the position-erasing rule that makes a printed program
--     comparable with a corpus one.
--
-- Nothing here decides anything: no comparison, no verdict, no @IO@. A caller
-- takes these 'Value's and diffs them against the oracle's (@tier1/Main.hs@,
-- @bisim/Main.hs@).
--
-- == What this module deliberately does not do
--
-- It does not check that the program stays below the dynamic rung.
-- @costSummary@ is defined only there and below (@PORTING2-core.md@ §6), so a
-- reply for a plan at 'Agentic.Plan.Dynamic' would carry a meaningless
-- summary — but the builder cannot construct such a plan at all, and a caller
-- that wants to say so plainly rather than trust that fact should test
-- @'Agentic.Plan.level' . 'Agentic.Builder.progPlan'@ itself before calling.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Agentic.Observe
  ( observeValue,
    printedValue,
    zeroPosValue,
  )
where

import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V

import Agentic.Builder (Program, progPlan, progRawOut)
import Agentic.Guards (askCounts)
import Agentic.Plan (askNodes, codes, costSummary, level, levelName, size)
import Agentic.Raw (codeName)
import Agentic.World (WorldSpec, worldObservation)

-- ---------------------------------------------------------------------------
-- The reply
-- ---------------------------------------------------------------------------

-- | The checked reply for a rebuilt program under the given worlds, in the
-- oracle's own shape: the five static folds, the two ask counts, and one
-- observation per world, in the order the worlds were given.
--
-- The folds — @level@, @size@, @askNodes@, @codes@, @costSummary@ — are read
-- off the elaborated 'Agentic.Plan.Plan'. The counts — @blockAsks@, @fnAsks@ —
-- are taken from the /printed/ 'Agentic.Raw.RawProgram' by
-- "Agentic.Guards", not from the plan: reading them off the plan would be a
-- second reading of the same term, whereas reading them off the print holds
-- week one's guards against week two's builder.
--
-- @codes@ is written with 'codeName', so the receipt kind prints as
-- @\"receipt\"@ rather than as its constructor; a plan whose paths disagree on
-- their answer kinds has no @codes@ at all and the field is @null@ — which is
-- a different thing from the empty list a question-free batch program yields.
observeValue :: Program -> [WorldSpec] -> Value
observeValue prog ws =
  object
    [ "level" .= levelName (level p),
      "size" .= size p,
      "askNodes" .= askNodes p,
      "codes" .= maybe Null (toJSON . map codeName) (codes p),
      "costSummary"
        .= object ["minFold" .= mn, "maxFold" .= mx, "paths" .= paths],
      "blockAsks" .= blockAsks,
      "fnAsks" .= fnAsks,
      "worlds" .= map (worldObservation p) ws
    ]
  where
    p = progPlan prog
    (mn, mx, paths) = costSummary p
    (blockAsks, fnAsks) = askCounts (progRawOut prog)

-- ---------------------------------------------------------------------------
-- The program, printed
-- ---------------------------------------------------------------------------

-- | The builder's program as JSON — @toJSON@ of its 'Agentic.Raw.RawProgram'.
--
-- Positions are printed as @0:0@ throughout, because the builder has no way to
-- represent one; compare this against an oracle program through
-- 'zeroPosValue' on both sides.
printedValue :: Program -> Value
printedValue = toJSON . progRawOut

-- ---------------------------------------------------------------------------
-- Positions, zeroed
-- ---------------------------------------------------------------------------

-- | Every @pos@ and @answerPos@ of a program value, set to @0:0@.
--
-- Applied to /both/ sides of a printed-program comparison: the builder has no
-- way to represent a position and prints @0:0@ everywhere, and @pos@ is
-- oracle-only for this whole program, exactly like @message@ and @excerpt@
-- (@PORTING2-elab.md@ §3). Structural and total, so it cannot mask a
-- difference in anything else — it rewrites two named fields and recurses
-- everywhere, rather than pruning or reordering.
zeroPosValue :: Value -> Value
zeroPosValue = \case
  Object o -> Object (KM.mapWithKey field' o)
  Array a -> Array (V.map zeroPosValue a)
  v -> v
  where
    field' k v
      | k == "pos" || k == "answerPos" = origin
      | otherwise = zeroPosValue v
    origin = object ["line" .= (0 :: Integer), "col" .= (0 :: Integer)]
