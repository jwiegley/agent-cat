{-# LANGUAGE OverloadedStrings #-}

module SnapshotCheckpointTests (snapshotCheckpointTests) where

import Agentic.Runtime
import Control.Monad (foldM, forM_, unless)
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft)
import Data.List (inits, isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath ((</>))

snapshotCheckpointTests :: FilePath -> IO ()
snapshotCheckpointTests root = do
  forM_ validFixtures $ \path -> do
    envelopes <- readFixture root path
    checkPrefixes path envelopes
  forM_ invalidFixtures $ \path -> do
    envelopes <- readFixture root path
    rejectHistory path envelopes
  checkPrefixes "empty" []
  checkPrefixes "escaped text and unbounded-precision bills" (zipWith (env 1) [0 ..]
    [RunStarted "界\"\n\t" "scripted", TraceOrdered [], RunCompleted (10 ^ (30 :: Int)) 7])
  person <- readFixture root "protocol-v2/person-result"
  checkPrefixes "person accepted then failed" (take 4 person <>
    [ env 2 4 (ControlAcknowledgedV2 "person-1" "failed" "invalid answer" "answerPerson" (Just occurrence) Nothing),
      env 2 5 (RunFailed FailureRuntime "answer refused")
    ])
  checkPrefixes "multibyte output and bounded progress histories" longHistory
  checkLongState
  checkRefusals
  checkBounds
  putStrLn "checkpoint tests passed: fixture prefixes, exact shared folds, suffixes, refusals, tails, and byte boundaries"

validFixtures :: [FilePath]
validFixtures =
  map ("protocol-v1/" <>) ["success", "cancelled", "reused", "redirected", "recovery-failed", "failover-retried"]
    <> map ("protocol-v2/" <>) ["person-result", "progress"]

invalidFixtures :: [FilePath]
invalidFixtures =
  map ("protocol-v1/" <>) ["sequence-gap", "reuse-after-attempt"]
    <> map ("protocol-v2/" <>) ["person-terminal-without-acceptance", "person-queued-then-delivered", "control-correlation-change"]

readFixture :: FilePath -> FilePath -> IO [Envelope]
readFixture root name = do
  bytes <- BS.readFile (root </> "test/fixtures/runtime" </> name <> ".ndjson")
  require name (traverse (decodeEnvelopeFor [1, 2]) (BSC.lines bytes))

checkPrefixes :: String -> [Envelope] -> IO ()
checkPrefixes label envelopes = do
  expectedFull <- require label (sharedFold envelopes)
  forM_ (zip [0 :: Int ..] (inits envelopes)) $ \(n, prefix) -> do
    let context = label <> " prefix " <> show n
    expected <- require context (sharedFold prefix)
    captured <- require context (captureSnapshotCheckpoint run prefix)
    bytes <- require context (encodeSnapshotCheckpoint captured)
    restored <- require context (decodeSnapshotCheckpoint bytes)
    expect (context <> " captured exact state") (checkpointSnapshot captured == expected)
    expect (context <> " restored exact state") (checkpointSnapshot restored == expected)
    expect (context <> " complete original envelopes") (checkpointEnvelopes restored == prefix)
    expect (context <> " value projection") (bytes == encoded (snapshotCheckpointValue restored))
    replayed <- require context (appendSnapshotCheckpoint restored (drop n envelopes))
    expect (context <> " suffix exact shared fold") (checkpointSnapshot replayed == expectedFull)
    expect (context <> " suffix retains prefix") (checkpointEnvelopes replayed == envelopes)
    replayBytes <- require context (encodeSnapshotCheckpoint replayed)
    replayRestored <- require context (decodeSnapshotCheckpoint replayBytes)
    expect (context <> " appended checkpoint roundtrip") (checkpointSnapshot replayRestored == expectedFull)
    expect (context <> " empty suffix") (appendSnapshotCheckpoint restored [] == Right restored)

checkRefusals :: IO ()
checkRefusals = do
  checkpoint <- require "base" (captureSnapshotCheckpoint run active)
  restored <- require "restore base" (encodeSnapshotCheckpoint checkpoint >>= decodeSnapshotCheckpoint)
  let value = snapshotCheckpointValue checkpoint
      rejects label = expectLeft label . decodeSnapshotCheckpoint . encoded
  forM_ ["checkpointVersion", "representation", "runId", "protocolVersion", "lastSequence", "envelopes"] $ \key -> do
    rejects ("missing " <> show key) (modifyObject (KeyMap.delete key) value)
    rejects ("null " <> show key) (set key Null value)
  forM_
    [ ("unknown version", "checkpointVersion", Number 2),
      ("string version", "checkpointVersion", String "1"),
      ("wrong kind", "representation", String "snapshot"),
      ("wrong run", "runId", String "other"),
      ("invalid run", "runId", String "../run"),
      ("wrong protocol", "protocolVersion", Number 2),
      ("unknown protocol", "protocolVersion", Number 3),
      ("numeric sequence", "lastSequence", Number 2),
      ("wrong boundary", "lastSequence", String "1"),
      ("noncanonical boundary", "lastSequence", String "02"),
      ("signed boundary", "lastSequence", String "+2"),
      ("huge boundary", "lastSequence", String (T.replicate 1000 "9")),
      ("unknown field", "future", Bool True),
      ("malformed envelope", "envelopes", toJSON [object []]),
      ("wrong array type", "envelopes", object [])
    ] $ \(label, key, replacement) -> rejects label (set key replacement value)
  rejects "compact presentation" (runSnapshotValue (checkpointSnapshot checkpoint))
  rejects "compact catalogue" (object ["runId" .= runIdText run, "lastSequence" .= ("2" :: Text), "status" .= ("running" :: Text)])
  rejects "not object" (toJSON ([] :: [Value]))
  expectLeft "malformed JSON" (decodeSnapshotCheckpoint "{")
  expectLeft "trailing JSON" (decodeSnapshotCheckpoint (encoded value <> "{}"))
  empty <- require "empty" (captureSnapshotCheckpoint run [])
  let emptyValue = snapshotCheckpointValue empty
  rejects "empty protocol must be null" (set "protocolVersion" (Number 1) emptyValue)
  rejects "empty sequence must be null" (set "lastSequence" (String "0") emptyValue)
  expectLeft "empty invalid run" (captureSnapshotCheckpoint (RunId "") [])
  let lastEvent = last active
      conflict = lastEvent {envelopeTimestamp = "2026-09-03T00:00:01Z"}
  expectFailure "exact duplicate after restoration" "duplicate sequence is refused" (appendSnapshotCheckpoint restored [lastEvent])
  expectFailure "conflicting duplicate after restoration" "conflicting duplicate" (appendSnapshotCheckpoint restored [conflict])
  expectFailure "direct shared duplicate" "duplicate sequence is refused" (stepRunSnapshot (checkpointSnapshot restored) lastEvent)
  expectFailure "direct shared conflict" "conflicting duplicate" (stepRunSnapshot (checkpointSnapshot restored) conflict)
  let start = env 1 0 (RunStarted "review" "scripted")
  forM_
    [ ("duplicate", active <> [lastEvent]),
      ("conflict", active <> [conflict]),
      ("gap", active <> [env 1 4 (AttemptOutput attempt "x")]),
      ("regression", active <> [env 1 1 (AttemptOutput attempt "x")]),
      ("first sequence", [env 1 1 (RunStarted "review" "scripted")]),
      ("mixed version", active <> [env 2 3 (AttemptOutput attempt "x")]),
      ("cross run", active <> [(env 1 3 (AttemptOutput attempt "x")) {envelopeRunId = RunId "other"}]),
      ("unknown version", [start {envelopeVersion = 3}]),
      ("invalid lifecycle", [env 1 0 (AttemptOutput attempt "x")]),
      ("post terminal", [start, env 1 1 (RunCancelled "stop"), env 1 2 (RunFailed FailureRuntime "late")]),
      ("bad timestamp", [start {envelopeTimestamp = "yesterday"}]),
      ("negative bill", [start, env 1 1 (TraceOrdered []), env 1 2 (RunCompleted (-1) 0)]),
      ("invalid typed ack", active <> [env 1 3 (ControlAcknowledged "bad/id" "delivered" "no")]),
      ("invalid steering", active <> [env 1 3 (AttemptSteered attempt "steer" "tomorrow" "no")]),
      ("empty dispatch", take 2 active <> [env 1 2 (OccurrenceDispatchPending occurrence [])]),
      ("duplicate trace IDs", take 2 active <> [env 1 2 (OccurrenceReused occurrence "memo"), env 1 3 (TraceOrdered [occurrence, occurrence])]),
      ("invalid result reference", [env 2 0 (RunStartedV2 "review" "scripted" PersonAnswerEngine), env 2 1 (TraceOrdered []), env 2 2 (RunCompletedV2 0 0 (ResultRef 1 "../result.json" (T.replicate 64 "a") 1 Null ""))]),
      ("v2 event cannot masquerade as v1", [env 1 0 (RunStartedV2 "review" "scripted" PersonAnswerEngine)])
    ] $ \(label, history) -> do
      -- Native decoding can intentionally erase v2-only fields under v1.
      -- Typed capture must still refuse that lossy hand-constructed value.
      expectLeft label (captureSnapshotCheckpoint run history)
      unless (label == "v2 event cannot masquerade as v1") $ rejectHistory label history
  let nestedUnknown = set "envelopes" (toJSON (map (set "future" (Bool True) . toJSON) active)) value
  nested <- require "native nested unknown-field semantics" (decodeSnapshotCheckpoint (encoded nestedUnknown))
  expect "native nested unknown fields do not alter envelopes" (checkpointEnvelopes nested == active)
  let nativeSequence = set "envelopes" (toJSON (set "sequence" (String "00") (toJSON start) : map toJSON (drop 1 active))) value
  sequenceRestored <- require "native nested decimal semantics" (decodeSnapshotCheckpoint (encoded nativeSequence))
  expect "native noncanonical nested sequence preserves Envelope equality" (checkpointEnvelopes sequenceRestored == active)

checkLongState :: IO ()
checkLongState = do
  checkpoint <- require "long history" (captureSnapshotCheckpoint run longHistory)
  let state = checkpointSnapshot checkpoint
      projected = snapshotOccurrences state Map.! occurrence
      attemptState = snapshotOccurrenceAttempts projected Map.! attempt
  expect "output tail byte bound" (BS.length (TE.encodeUtf8 (snapshotAttemptOutput attemptState)) <= 64 * 1024)
  expect "output exceeds tail in original history" (sum [BS.length (TE.encodeUtf8 t) | Envelope _ _ _ _ (AttemptOutput _ t) <- longHistory] > 64 * 1024)
  expect "UTF-8 tail retained" ("TAIL" `T.isSuffixOf` snapshotAttemptOutput attemptState && not (T.any (== '\xfffd') (snapshotAttemptOutput attemptState)))
  expect "messages bounded" (length (snapshotAttemptMessages attemptState) == 64)
  expect "reasoning bounded" (length (snapshotAttemptReasoningSummaries attemptState) == 32)
  expect "history not bounded to presentation tails" (length (checkpointEnvelopes checkpoint) == length longHistory)

checkBounds :: IO ()
checkBounds = do
  let output n text = env 1 n (AttemptOutput attempt text)
      frameOver = output 3 (T.replicate maxFrameBytes "x")
  rejectHistory "shared tool collection bound" $
    take 3 longHistory <> [env 2 n (AttemptProgress attempt (ProgressTool (PublicToolUpdate (T.pack (show n)) Nothing Nothing Nothing Nothing))) | n <- [3 .. 131]]
  expectLeft "oversized typed frame" (captureSnapshotCheckpoint run (active <> [frameOver]))
  expectLeft "oversized nested frame" (decodeSnapshotCheckpoint (encoded (wire (active <> [frameOver]))))
  let small = output 3 ""
      frameRoom = maxFrameBytes - BS.length (encodeEnvelope small)
      exactFrame = output 3 (T.replicate frameRoom "x")
  expect "exact frame length" (BS.length (encodeEnvelope exactFrame) == maxFrameBytes)
  _ <- require "exact frame accepted" (captureSnapshotCheckpoint run (active <> [exactFrame]))
  -- Keep every envelope below 1 MiB while approaching the full 64 MiB object.
  let largePrefix = active <> [output n (T.replicate 990000 "x") | n <- [3 .. 69]]
      finalSequence = 70
  large <- require "large prefix" (captureSnapshotCheckpoint run largePrefix)
  largeBytes <- require "large prefix encoding" (encodeSnapshotCheckpoint large)
  withEmpty <- require "empty final output" (appendSnapshotCheckpoint large [output finalSequence ""])
  emptyBytes <- require "empty final output encoding" (encodeSnapshotCheckpoint withEmpty)
  let room = fromInteger maxArtifactBytes - BS.length emptyBytes
      finalEvent = output finalSequence (T.replicate room "x")
      exactHistory = largePrefix <> [finalEvent]
  expect "remaining room fits one frame" (room > 0 && BS.length (encodeEnvelope finalEvent) < maxFrameBytes)
  expect "large representation exceeds output tail" (BS.length largeBytes > 64 * 1024)
  exact <- require "exact total accepted" (appendSnapshotCheckpoint large [finalEvent])
  exactBytes <- require "exact total encoding" (encodeSnapshotCheckpoint exact)
  expect "full object exactly 64 MiB" (toInteger (BS.length exactBytes) == maxArtifactBytes)
  restored <- require "exact total decoding" (decodeSnapshotCheckpoint exactBytes)
  expected <- require "large original shared fold" (sharedFold exactHistory)
  expect "large restore exact Eq" (checkpointSnapshot restored == expected)
  expect "large restore original envelopes" (checkpointEnvelopes restored == exactHistory)
  expectFailure "append total overflow" "exceeds 67108864 bytes" (appendSnapshotCheckpoint restored [output 71 ""])
  expectFailure "capture refuses before forcing lazy tail" "exceeds 67108864 bytes" $
    captureSnapshotCheckpoint run (largePrefix <> [output finalSequence (T.replicate (room + 1) "x")] <> error "capture forced source after overflow")
  expectFailure "raw decoder overflow" "exceeds 67108864 bytes" (decodeSnapshotCheckpoint (exactBytes <> " "))

longHistory :: [Envelope]
longHistory = zipWith (env 2) [0 ..] $
  [ RunStartedV2 "review" "scripted" PersonAnswerEngine,
    OccurrenceStarted occurrence "text" "consult" "model reviewer" "prompt",
    AttemptStarted attempt "scripted"
  ]
    <> replicate 3 (AttemptOutput attempt (T.replicate 9000 "界"))
    <> [AttemptOutput attempt "TAIL"]
    <> [AttemptProgress attempt (ProgressMessage (T.pack (show n))) | n <- [1 :: Int .. 70]]
    <> [AttemptProgress attempt (ProgressReasoningSummary (T.pack (show n))) | n <- [1 :: Int .. 35]]

active :: [Envelope]
active = zipWith (env 1) [0 ..]
  [ RunStarted "review" "scripted",
    OccurrenceStarted occurrence "text" "consult" "model reviewer" "prompt",
    AttemptStarted attempt "scripted"
  ]

run :: RunId
run = RunId "run-1"

occurrence :: OccurrenceId
occurrence = OccurrenceId 0

attempt :: AttemptId
attempt = AttemptId occurrence 0

env :: Int -> Word -> RuntimeEvent -> Envelope
env version sequenceNumber' = Envelope version run (SeqNo (fromIntegral sequenceNumber')) "2026-09-03T00:00:00Z"

sharedFold :: [Envelope] -> Either SnapshotError RunSnapshot
sharedFold = foldM stepRunSnapshot (initialRunSnapshot run)

wire :: [Envelope] -> Value
wire envelopes = object
  [ "checkpointVersion" .= (1 :: Int),
    "representation" .= ("runtime-envelope-prefix" :: Text),
    "runId" .= runIdText run,
    "protocolVersion" .= fmap envelopeVersion boundary,
    "lastSequence" .= fmap (T.pack . show . sequenceNumber . envelopeSequence) boundary,
    "envelopes" .= envelopes
  ]
  where
    boundary = case reverse envelopes of
      [] -> Nothing
      value : _ -> Just value

rejectHistory :: String -> [Envelope] -> IO ()
rejectHistory label envelopes = do
  expectLeft (label <> " capture") (captureSnapshotCheckpoint run envelopes)
  expectLeft (label <> " decode") (decodeSnapshotCheckpoint (encoded (wire envelopes)))

encoded :: Value -> BS.ByteString
encoded = BL.toStrict . encode

modifyObject :: (KeyMap.KeyMap Value -> KeyMap.KeyMap Value) -> Value -> Value
modifyObject f (Object o) = Object (f o)
modifyObject _ _ = error "test expected object"

set :: KeyMap.Key -> Value -> Value -> Value
set key value = modifyObject (KeyMap.insert key value)

expect :: String -> Bool -> IO ()
expect label condition = unless condition (fail ("failed: " <> label))

expectLeft :: String -> Either e a -> IO ()
expectLeft label = expect (label <> " was accepted") . isLeft

expectFailure :: Show e => String -> String -> Either e a -> IO ()
expectFailure label detail result = case result of
  Left failure -> expect (label <> ": " <> show failure) (detail `isInfixOf` show failure)
  Right _ -> fail ("failed: " <> label <> " was accepted")

require :: Show e => String -> Either e a -> IO a
require label = either (fail . ((label <> ": ") <>) . show) pure
