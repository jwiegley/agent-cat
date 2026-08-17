-- | Tier 1: the rebuilt-case runner.
--
-- Where tier0 replays the frozen corpus through the codec, the guards and the
-- string layer, tier1 rebuilds twelve of its /checked/ entries in the
-- production surface ("Agentic.Builder", see "Cases") and holds the rebuilt
-- program against the oracle on two fronts (@PORTING2-elab.md@ §4.1):
--
-- 1. the __printed Raw__ — @toJSON@ of the builder's 'RawProgram' against the
--    entry's @request.program@, with every position zeroed on /both/ sides,
--    because positions are not representable in the builder and are
--    oracle-only throughout this program (§3). The printed program is also
--    decoded back and re-encoded, so a print that no reader accepts fails here
--    rather than silently.
--
-- 2. the __whole reply__ — @level@, @size@, @askNodes@, @codes@ and
--    @costSummary@ folded from the elaborated 'Agentic.Plan.Plan';
--    @blockAsks@ and @fnAsks@ counted by "Agentic.Guards" on the /printed/
--    Raw (week-one code, cross-checking the builder against the corpus's own
--    program); and, per world of @request.worlds@ in order, the world's
--    re-serialization, its trace event by event and its two bills
--    (@Agentic.World.worldObservation@). Everything is compared as
--    'Data.Aeson.Value's, whole: no field is skipped, and a missing or extra
--    key is a failure, so a runner cannot go quietly green when the corpus
--    moves under it.
--
-- A divergence is reported as the JSON path where the two values first part
-- company, with both fragments.
--
-- Usage: @tier1 [corpusDir]@, defaulting to
-- @\/Users\/johnw\/src\/agent-cat\/test\/corpus@. Exit status is 0 iff nothing
-- failed.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception
  ( SomeAsyncException,
    SomeException,
    evaluate,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (forM, unless)
import Data.Aeson
  ( Result (..),
    Value (..),
    eitherDecodeStrict',
    fromJSON,
    object,
    toJSON,
    (.=),
  )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.List (sort, sortOn)
import Data.Maybe (catMaybes)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import Numeric (showHex)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

import Agentic.Builder (Program, progPlan, progRawOut)
import Agentic.Guards (askCounts)
import Agentic.Plan
  ( Level (..),
    askNodes,
    codes,
    costSummary,
    level,
    levelName,
    size,
  )
import Agentic.Raw (RawProgram, codeName)
import Agentic.World (WorldSpec, worldObservation)

import Cases (cases)

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------

defaultCorpus :: FilePath
defaultCorpus = "/Users/johnw/src/agent-cat/test/corpus"

main :: IO ()
main = do
  args <- getArgs
  let dir = case args of
        (d : _) -> d
        [] -> defaultCorpus
  present <- doesDirectoryExist dir
  unless present $ do
    TIO.putStrLn ("tier1: no such corpus directory: " <> T.pack dir)
    exitFailure
  results <- forM cases $ \(name, prog) -> (,) name <$> runCase (dir </> name) prog
  mapM_ report results
  let total = length results
      failed = length [() | (_, fs) <- results, not (null fs)]
      passed = total - failed
  TIO.putStrLn $
    "tier1: "
      <> tshow passed
      <> " passed, "
      <> tshow failed
      <> " failed, of "
      <> tshow total
      <> " cases"
  if failed == 0 then exitSuccess else exitFailure
  where
    report (name, fs) =
      mapM_ (\f -> TIO.putStrLn ("FAIL " <> T.pack name <> ": " <> f)) fs

-- | Check one rebuilt case against its frozen entry. A bottom anywhere in the
-- builder, the folds or the trace is caught and reported as that case's
-- failure rather than killing the run.
runCase :: FilePath -> Program -> IO [Text]
runCase path prog = do
  there <- doesFileExist path
  if not there
    then pure ["no such corpus entry: " <> T.pack path]
    else do
      bytes <- BS.readFile path
      case eitherDecodeStrict' bytes of
        Left err -> pure ["not valid JSON: " <> squash (T.pack err)]
        Right v -> forced (checkCase v prog)

-- | Force a failure list to normal form inside 'try', so an @error@ raised by
-- the implementation becomes a reported failure.
forced :: [Text] -> IO [Text]
forced fs = do
  caught <- try (evaluate (sum (map T.length fs) `seq` fs))
  case caught :: Either SomeException [Text] of
    Right fs' -> pure fs'
    Left e
      -- An interrupt is the user talking, not a conformance failure.
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> pure ["implementation raised: " <> squash (tshow e)]

-- ---------------------------------------------------------------------------
-- The comparison rules (PORTING2-elab.md §4.1)
-- ---------------------------------------------------------------------------

checkCase :: Value -> Program -> [Text]
checkCase entry prog = case (field "request" entry, field "reply" entry) of
  (Just req, Just reply)
    | Just _ <- field "refused" reply ->
        -- Only checked entries are rebuildable; a refusal here means the
        -- corpus moved and the case list must be revisited, not skipped.
        ["the entry is a refusal, and only checked entries are rebuildable"]
    | Nothing <- field "level" reply ->
        ["the reply is neither a refusal nor a checked result (no `level`)"]
    | otherwise -> case field "program" req of
        Nothing -> ["the request has no program"]
        Just pv -> case worldsOf req of
          Left err -> [err]
          Right ws -> programCheck pv prog ++ replyCheck reply ws prog
  _ -> ["the entry lacks a request or a reply"]

-- | The worlds of the request, in order. Absent reads as none.
worldsOf :: Value -> Either Text [WorldSpec]
worldsOf req = case field "worlds" req of
  Nothing -> Right []
  Just wv -> case fromJSON wv :: Result [WorldSpec] of
    Error err -> Left ("request.worlds does not decode: " <> squash (T.pack err))
    Success ws -> Right ws

-- | §4.1(1): the printed program, positions zeroed on both sides — and a
-- round-trip of the print, since the builder is the only writer of Raw that
-- the codec has not already been proved against.
programCheck :: Value -> Program -> [Text]
programCheck expected prog =
  concat
    [ [ "printed program differs at " <> d
      | Just d <- [firstDiff (zeroPos expected) (zeroPos printed)]
      ],
      case fromJSON printed :: Result RawProgram of
        Error err ->
          ["the printed program does not decode back: " <> squash (T.pack err)]
        Success back ->
          [ "the printed program does not round-trip at " <> d
          | Just d <- [firstDiff printed (toJSON back)]
          ]
    ]
  where
    printed = toJSON (progRawOut prog)

-- | §4.1(2)-(4): the whole reply, assembled from the folds, the guards' ask
-- counts and one observation per world.
replyCheck :: Value -> [WorldSpec] -> Program -> [Text]
replyCheck reply ws prog
  -- `costSummary` is defined only below the dynamic rung; the builder cannot
  -- reach it, so say so plainly rather than reporting a meaningless summary.
  | level (progPlan prog) > Branch =
      ["the elaborated plan reaches the dynamic rung, which no reply describes"]
  | otherwise =
      ["reply differs at " <> d | Just d <- [firstDiff reply (observe prog ws)]]

-- | The checked reply of @Conformance.lean:240@'s @observe@, over a rebuilt
-- program: the five static folds, the two ask counts, and one observation per
-- world.
observe :: Program -> [WorldSpec] -> Value
observe prog ws =
  object
    [ "level" .= levelName (level p),
      "size" .= size p,
      "askNodes" .= askNodes p,
      -- `codes` is written with `codeName`, so the fourth code is "receipt".
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
    -- The counts are taken from the PRINTED program, not from the plan: that
    -- is what makes them a cross-check of the builder rather than a second
    -- reading of the same term.
    (blockAsks, fnAsks) = askCounts (progRawOut prog)

-- ---------------------------------------------------------------------------
-- Positions, zeroed
-- ---------------------------------------------------------------------------

-- | Every @pos@ and @answerPos@ of a program value, set to @0:0@.
--
-- Applied to both sides of the printed-program comparison: the builder has no
-- way to represent a position and prints @0:0@ everywhere, and @pos@ is
-- oracle-only for this whole program, exactly like @message@ and @excerpt@.
-- Structural and total, so it cannot mask a difference in anything else.
zeroPos :: Value -> Value
zeroPos = \case
  Object o -> Object (KM.mapWithKey field' o)
  Array a -> Array (V.map zeroPos a)
  v -> v
  where
    field' k v
      | k == "pos" || k == "answerPos" = origin
      | otherwise = zeroPos v
    origin = object ["line" .= (0 :: Integer), "col" .= (0 :: Integer)]

-- ---------------------------------------------------------------------------
-- Value inspection
-- ---------------------------------------------------------------------------

field :: Text -> Value -> Maybe Value
field k (Object o) = case KM.lookup (K.fromText k) o of
  Just Null -> Nothing -- a missing key and an explicit null read alike.
  other -> other
field _ _ = Nothing

-- ---------------------------------------------------------------------------
-- Structural diffing: the first place two values part company
-- ---------------------------------------------------------------------------

-- | @firstDiff expected actual@ names the first divergence as a JSON path plus
-- the two offending fragments, so a mismatch points at its own field —
-- @$.worlds[1].trace[3].prompt@ — rather than dumping a whole reply.
firstDiff :: Value -> Value -> Maybe Text
firstDiff = go "$"
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
                <> ": array length: expected "
                <> tshow (V.length a)
                <> ", actual "
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
                <> ": expected "
                <> clip (render expected)
                <> ", actual "
                <> clip (render actual)

    keyList ks = T.intercalate ", " (map (render . String . K.toText) ks)

firstJust :: [Maybe a] -> Maybe a
firstJust xs = case catMaybes xs of
  (x : _) -> Just x
  [] -> Nothing

-- ---------------------------------------------------------------------------
-- Rendering: canonical, one line, and ASCII-safe
-- ---------------------------------------------------------------------------

-- | Keys sorted so two renderings are comparable by eye, and every
-- non-printable or non-ASCII character escaped — a prompt that differs by an
-- invisible character must not read as identical.
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
    uni n
      | n <= 0xffff = hex4 n
      | otherwise =
          let n' = n - 0x10000
           in hex4 (0xd800 + (n' `shiftR` 10)) <> hex4 (0xdc00 + (n' .&. 0x3ff))
    hex4 n = "\\u" <> T.justifyRight 4 '0' (T.pack (showHex n ""))

-- | Keep every failure to one line, however large the offending value.
clip :: Text -> Text
clip t
  | T.length t > 400 = T.take 400 t <> "..."
  | otherwise = t

squash :: Text -> Text
squash = T.unwords . T.words

tshow :: (Show a) => a -> Text
tshow = T.pack . show
