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
-- @costSummary@ is defined only there and below (see
-- 'Agentic.Plan.costSummary'), so a
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

    -- * Naming a divergence
    -- | Shared by the two runners, so a mismatch reads the same everywhere
    -- (and so the plumbing that catches it exists exactly once).
    firstDiff,
    firstDiffWith,
    render,
    renderString,
    clip,
    tshow,
  )
where

import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (ord)
import Data.List (sort, sortOn)
import Data.Maybe (catMaybes)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
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
-- oracle-only for this whole program, exactly like the @message@ and
-- @excerpt@ of a refusal: all three are functions of written characters, which
-- this side never has. Structural and total, so it cannot mask a
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

-- ---------------------------------------------------------------------------
-- Naming a divergence
-- ---------------------------------------------------------------------------

-- | @firstDiff expected actual@ names the first divergence as a JSON path plus
-- the two offending fragments, so a mismatch points at its own field —
-- @$.worlds[1].trace[3].prompt@ — rather than dumping a whole reply.
firstDiff :: Value -> Value -> Maybe Text
firstDiff = firstDiffWith "expected" "actual"

-- | 'firstDiff' with the two sides named by the caller — the bisimulation
-- labels them @oracle@ and @haskell@, the rebuilt-case runner @expected@ and
-- @actual@. Same walk, same paths, different vocabulary.
firstDiffWith :: Text -> Text -> Value -> Value -> Maybe Text
firstDiffWith lhs rhs = go "$"
  where
    go path expected actual = case (expected, actual) of
      (Object a, Object b)
        | not (null missing) -> Just (path <> ": missing key(s) " <> keyList missing)
        | not (null extra) -> Just (path <> ": unexpected key(s) " <> keyList extra)
        | otherwise ->
            firstJust
              [ go (path <> "." <> K.toText k) va vb
              | k <- sort (KM.keys a)
              , Just va <- [KM.lookup k a]
              , Just vb <- [KM.lookup k b]
              ]
        where
          missing = sort [k | k <- KM.keys a, not (KM.member k b)]
          extra = sort [k | k <- KM.keys b, not (KM.member k a)]
      (Array a, Array b)
        | V.length a /= V.length b ->
            Just $
              path
                <> ": array length: "
                <> lhs
                <> " "
                <> tshow (V.length a)
                <> ", "
                <> rhs
                <> " "
                <> tshow (V.length b)
        | otherwise ->
            firstJust
              [ go (path <> "[" <> tshow i <> "]") x y
              | (i, (x, y)) <- zip [(0 :: Int) ..] (zip (V.toList a) (V.toList b))
              ]
      _
        | expected == actual -> Nothing
        | otherwise ->
            Just $
              path
                <> ": "
                <> lhs
                <> " "
                <> clip (render expected)
                <> ", "
                <> rhs
                <> " "
                <> clip (render actual)

    keyList ks = T.intercalate ", " (map (render . String . K.toText) ks)

    firstJust xs = case catMaybes xs of
      (x : _) -> Just x
      [] -> Nothing

-- | Keys sorted so two renderings are comparable by eye, and every
-- non-printable or non-ASCII character escaped — a prompt that differs by an
-- invisible character must not read as identical. The corpus turns on
-- differences a terminal hides (U+00A0 against a space, @İ@ against @i@, a
-- stripped @\r@), and a diagnostic that hides them would be worse than none.
render :: Value -> Text
render = \case
  Null -> "null"
  Bool True -> "true"
  Bool False -> "false"
  Number n -> case floatingOrInteger n :: Either Double Integer of
    Right i -> tshow i
    Left d -> tshow d
  String s -> renderString s
  Array xs -> "[" <> T.intercalate "," (map render (V.toList xs)) <> "]"
  Object o ->
    "{"
      <> T.intercalate
        ","
        [ renderString (K.toText k) <> ":" <> render v
        | (k, v) <- sortOn fst (KM.toList o)
        ]
      <> "}"

renderString :: Text -> Text
renderString t = "\"" <> T.concatMap esc t <> "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _
        | ord c < 0x20 || ord c > 0x7e -> uni (ord c)
        | otherwise -> T.singleton c
    uni n =
      let hex = T.pack (pad (showHexN n))
       in "\\u" <> hex
    pad s = replicate (4 - length s) '0' <> s
    showHexN n = go n ""
      where
        go 0 acc = if null acc then "0" else acc
        go k acc = go (k `div` 16) (digit (k `mod` 16) : acc)
        digit d
          | d < 10 = toEnum (fromEnum '0' + d)
          | otherwise = toEnum (fromEnum 'a' + d - 10)

-- | A fragment short enough to read in a failure line.
clip :: Text -> Text
clip t
  | T.length t <= 160 = t
  | otherwise = T.take 157 t <> "..."

tshow :: (Show a) => a -> Text
tshow = T.pack . show
