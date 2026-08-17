-- | Tier 1: the rebuilt-case runner.
--
-- Where tier0 replays the frozen corpus through the codec, the guards and the
-- string layer, tier1 rebuilds nineteen of its /checked/ entries in the
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
-- Both sides of that comparison — the printed program, the position-zeroing
-- rule and the assembled reply — come from "Agentic.Observe", which the live
-- bisimulation uses too. What is left here is the driver and the diff: reading
-- the frozen entries, deciding what counts as a failure, and saying where.
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
    toJSON,
  )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

import Agentic.Builder (Program, progPlan)
import Agentic.Observe
  ( firstDiff,
    observeValue,
    printedValue,
    tshow,
    zeroPosValue,
  )
import Agentic.Plan (Level (..), level)
import Agentic.Raw (RawProgram)
import Agentic.World (WorldSpec)

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
      | Just d <- [firstDiff (zeroPosValue expected) (zeroPosValue printed)]
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
    printed = printedValue prog

-- | §4.1(2)-(4): the whole reply, assembled by 'observeValue' from the folds,
-- the guards' ask counts and one observation per world.
replyCheck :: Value -> [WorldSpec] -> Program -> [Text]
replyCheck reply ws prog
  -- `costSummary` is defined only below the dynamic rung; the builder cannot
  -- reach it, so say so plainly rather than reporting a meaningless summary.
  | level (progPlan prog) > Branch =
      ["the elaborated plan reaches the dynamic rung, which no reply describes"]
  | otherwise =
      [ "reply differs at " <> d
      | Just d <- [firstDiff reply (observeValue prog ws)]
      ]

-- ---------------------------------------------------------------------------
-- Value inspection
-- ---------------------------------------------------------------------------

field :: Text -> Value -> Maybe Value
field k (Object o) = case KM.lookup (K.fromText k) o of
  Just Null -> Nothing -- a missing key and an explicit null read alike.
  other -> other
field _ _ = Nothing

-- | One failure reason on one line, whatever whitespace it arrived with.
squash :: Text -> Text
squash = T.unwords . T.words
