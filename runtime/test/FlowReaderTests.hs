{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The run-log reader: verification of lines, claim checks and reply
-- positions, and the states of section 3.6 computed on constructed logs.
module FlowReaderTests (flowReaderTests) where

import Agentic.Runtime
import qualified Agentic.Engine as E
import qualified Agentic.Planning as P
import BucketEvidence (withCaptureBucket)
import Control.Exception (bracket)
import Control.Monad (forM_, unless, void)
import Data.Aeson (Value (Null, String), object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime))
import Data.Word (Word64)
import System.Directory (createDirectory, doesDirectoryExist, getTemporaryDirectory, listDirectory)
import System.Posix.Files (setFileMode)
import System.FilePath ((</>))

flowReaderTests :: IO ()
flowReaderTests = do
  temporary <- getTemporaryDirectory
  withCaptureBucket "agentic-flow-reader-" temporary $ \bucket -> do
    completeLog (bucket </> "complete")
    stateLog (bucket </> "states")
    windowLog (bucket </> "windows")
  putStrLn "flow reader checks passed: torn lines, claim checks, reply positions, every run-log state and positioned windows"

run :: RunId
run = RunId "flow-reader"

manifest :: RunManifest
manifest =
  RunManifest
    run
    "review"
    "0.1.0.0"
    (object ["program" .= ("fixture" :: Text)])
    "scripted"
    (object ["kind" .= ("scripted" :: Text)])
    Nothing
    RootRun
    Nothing
    (Just PersonAnswerLocalControl)

start :: Start
start =
  Start
    { startRun = run,
      startProgramSha256 = T.replicate 64 "a",
      startPolicyDigest = "sha256:" <> T.replicate 64 "b",
      startPersonAnswering = Just PersonAnswerLocalControl,
      startTarget = "scripted",
      startLineage = RootRun,
      startParent = Nothing,
      startInputs = []
    }

workflow :: Actor
workflow = Workflow run

model :: Actor
model = Model "acp:claude"

scoped :: Word64 -> About
scoped occurrence = (runAbout run) {aboutOccurrence = Just (OccurrenceId occurrence), aboutEpoch = Just 0}

question :: P.Request c
question = P.Request (P.Q (P.AddrModel "writer") P.scopeUnit "hello" 0) P.Consult

-- | A store with its run log open, and the operations that append to both.
data Fixture = Fixture
  { fixtureWriter :: FlowWriter,
    fixtureStore :: RunStore
  }

withFixture :: FilePath -> (Fixture -> IO a) -> IO a
withFixture directory action =
  withRunStoreVersioned latestStoreVersion correlatedProtocolVersion directory manifest $ \store ->
    withRunLog store Manager start $ \writer -> action (Fixture writer store)

-- | The event record of event @n@, then its line, as the event sink appends them.
event :: Fixture -> Word64 -> RuntimeEvent -> IO Position
event fixture number runtimeEvent = do
  (position, _) <- appendTell (fixtureWriter fixture) FlowEvent workflow Public (runAbout run) (eventContent (SeqNo number))
  void (appendStoredEvent (fixtureStore fixture) (Envelope correlatedProtocolVersion run (SeqNo number) "2026-09-29T00:00:00Z" runtimeEvent))
  pure position

ask :: Fixture -> Schema -> Word64 -> Value -> IO Position
ask fixture schema occurrence body = fst <$> appendAsk (fixtureWriter fixture) schema workflow (To model) (scoped occurrence) (ContentValue body)

reply :: Fixture -> Schema -> Position -> Word64 -> Value -> IO Position
reply fixture schema asked occurrence body = fst <$> appendReply (fixtureWriter fixture) schema asked model (To workflow) (scoped occurrence) (ContentValue body)

control :: Fixture -> Text -> Maybe Word64 -> ControlCommand -> IO Position
control fixture name occurrence action = do
  body <- either (fail . T.unpack) pure (controlBody correlatedProtocolVersion (Control (ControlId name) (OccurrenceId <$> occurrence) Nothing action))
  fst <$> appendTell (fixtureWriter fixture) FlowControl Manager (To workflow) (runAbout run) {aboutCommand = Just name} (ContentValue body)

-- | A complete log: a question answered through an engine start and a turn
-- whose text is a claim check, and the stop. It verifies, and then one changed
-- claim-check byte, a torn final line and bad reply positions each fail.
completeLog :: FilePath -> IO ()
completeLog directory = do
  let big = T.replicate 70000 "x"
  withFixture directory $ \fixture -> do
    _ <- event fixture 0 (RunStartedV2 "review" "scripted" PersonAnswerLocalControl)
    _ <- event fixture 1 (OccurrenceStarted (OccurrenceId 0) "text" "consult" "model writer" "hello")
    asked <- ask fixture FlowQuestion 0 (questionBody P.SText question)
    started <- ask fixture FlowEngineStart 0 (engineStartBody (E.EngineRequest "acp:claude" (Just "opus") Nothing 0 E.Consult E.TextAnswer "hello" False))
    _ <- reply fixture FlowDone started 0 doneBody
    turn <- ask fixture FlowTurn 0 (turnBody big)
    _ <- reply fixture FlowEngineResult turn 0 (engineResultBody (E.EngineResult "hi" "" E.Completed))
    _ <- reply fixture FlowAnswer asked 0 (answerBody P.SText "hi")
    _ <- event fixture 2 (OccurrenceCompleted (OccurrenceId 0) "asked:model writer" "hi")
    void (event fixture 3 (RunFailed FailureRuntime "the fixture stops"))
  complete <- readFlow FlowEnded directory
  check ("the complete log verifies: " <> show (flowReportProblems complete)) (flowVerified complete)
  check "the complete log has eleven records" (length (reportEntries complete) == 11)
  check "the stop is the terminal event record" (reportStop complete == Just (Position 10))
  check "the complete log has no open state" (reportStates complete == emptyStates)
  check "an event record joins its line" (fmap envelopeEvent (entryEvent (reportEntries complete !! 10)) == Just (RunFailed FailureRuntime "the fixture stops"))
  claimed <- case entryRecord (reportEntries complete !! 6) of
    Just Record {recBody = ClaimCheck digest _} -> pure digest
    other -> fail ("flow reader: the turn record is not a claim check: " <> show other)
  check "a verified claim check yields its value" (entryContent (reportEntries complete !! 6) == Just (String big))

  -- One changed byte of the claim check.
  let claimFile = directory </> flowClaimDirectory </> T.unpack claimed
  original <- BS.readFile claimFile
  let index = BS.length original `div` 2
  BS.writeFile claimFile (BS.take index original <> "y" <> BS.drop (index + 1) original)
  tampered <- readFlow FlowEnded directory
  check "a changed claim-check byte fails verification" (not (flowVerified tampered))
  check "the changed claim check fails at its own record"
    (any ("does not have its recorded digest" `T.isInfixOf`) (entryProblems (reportEntries tampered !! 6)) && isNothing (entryContent (reportEntries tampered !! 6)))
  BS.writeFile claimFile original

  -- A torn final line is reported by its size and is not decoded.
  let logFile = directory </> runLogName
      torn = "{\"schema\":\"question\""
  logBytes <- BS.readFile logFile
  BS.writeFile logFile (logBytes <> torn)
  tornEnded <- readFlow FlowEnded directory
  check "a torn final line is reported by its size" (reportTornBytes tornEnded == Just (BS.length torn))
  check "a torn final line is not decoded" (length (reportEntries tornEnded) == 11)
  check "a torn final line fails an ended log" (not (flowVerified tornEnded))
  tornLive <- readFlow FlowLive directory
  check "a torn final line of a live log is the writer's append in progress" (flowVerified tornLive && reportTornBytes tornLive == Just (BS.length torn))

  -- Bad reply positions.
  let moment = UTCTime (fromGregorian 2026 9 29) 0
      answerTo position = Record FlowAnswer model (To workflow) (scoped 0) (Just (Position position)) (Inline (answerBody P.SText "again")) moment
      badReply position expected = do
        BS.writeFile logFile (logBytes <> encodeFlowLine (answerTo position) <> "\n")
        report <- readFlow FlowEnded directory
        let problems = entryProblems (last (reportEntries report))
        check ("a reply to position " <> show position <> " is refused: " <> show problems) (not (flowVerified report) && any (expected `T.isInfixOf`) problems)
  badReply 4 "cannot answer the engine-start record"
  badReply 11 "not earlier in this log"
  badReply 99 "not earlier in this log"
  badReply 3 "already has a reply"
  badReply 0 "cannot answer the start record"
  BS.writeFile logFile logBytes
  restored <- readFlow FlowEnded directory
  check "the restored log verifies" (flowVerified restored)
  -- Read as a manager log, every record of the run log has a schema of the
  -- other log.
  asManager <- bracket (openPrivateRoot "flow reader check" directory) closePrivateRoot $ \root ->
    readFlowLogAt ManagerLog root Nothing [runLogName] [flowClaimDirectory]
  check "a run log read as a manager log refuses each run-log schema"
    (all (\entry -> any ("belongs to the run log" `T.isInfixOf`) (entryProblems entry)) (let (_, entries, _) = asManager in entries))

-- | A log that holds every state of section 3.6, read live and ended, and the
-- same log with its stop and an ask that follows the stop. A reader in this
-- process opens a file only after its writer has closed it, because the
-- runtime system refuses a read handle beside a write handle of one file.
stateLog :: FilePath -> IO ()
stateLog directory = do
  let openDirectory = directory </> "open"
      stoppedDirectory = directory </> "stopped"
  (pending, open, _) <- withFixture openDirectory (populate False)
  live <- readFlow FlowLive openDirectory
  check ("the state log verifies: " <> show (flowReportProblems live)) (flowVerified live)
  check ("a live log has its open ask in flight: " <> show (reportStates live))
    (reportStates live == pending {statesInFlight = [open]})
  ended <- readFlow FlowEnded openDirectory
  -- The engine start has its reply, and the question above it stays uncertain.
  check ("an ended log without its stop has its open ask uncertain and lost supervision: " <> show (reportStates ended))
    (reportStates ended == pending {statesUncertain = [open], statesLostSupervision = True})
  check "an ended log without its stop has no stop" (isNothing (reportStop ended))
  check "an ended log without its stop is uncertain" (flowUncertain ended)
  check "a live log is not uncertain" (not (flowUncertain live))

  (_, _, stopAndLate) <- withFixture stoppedDirectory (populate True)
  (stop, late) <- maybe (fail "flow reader: the stopped log has no stop") pure stopAndLate
  stopped <- readFlow FlowEnded stoppedDirectory
  check ("the stopped log verifies: " <> show (flowReportProblems stopped)) (flowVerified stopped)
  check "the stop is the cancel" (reportStop stopped == Just stop)
  -- The log has its stop, so its asks without a reply are unanswered at the
  -- stop and not uncertain.
  check ("an ask after the stop is reported and unanswered at the stop: " <> show (reportStates stopped))
    (reportStates stopped == pending {statesUnansweredAtStop = [open, late], statesAskAfterStop = [late]})
  check "a log with its stop is not uncertain" (not (flowUncertain stopped))

  -- Routes select records by schema, sender, address and identifiers.
  let selected route = either (fail . T.unpack) (\parsed -> pure [entryPosition entry | entry <- reportEntries stopped, Just record <- [entryRecord entry], flowRouteMatches parsed record]) (parseFlowRoute route)
  questions <- selected "schema=question,occurrence=4"
  check "a route of schema and occurrence selects one question" (questions == [open])
  controls <- selected "from=manager,command=cancel-1"
  check "a route of sender and command selects one control" (controls == statesUnacknowledged pending)
  case controls of
    [cancel] ->
      check ("each control joins its first acknowledgement event: " <> show (flowAcknowledgements stopped))
        (flowAcknowledgements stopped == [(cancel, Nothing), (Position 3, Just (Position 4))])
    _ -> fail "flow reader: the stopped log has no single cancel control"
  public <- selected "to=public,schema=event"
  check "a route of address selects the event records" (length public == 8)
  check "a route with an unknown field is refused" (either (const True) (const False) (parseFlowRoute "sender=manager"))
  check "a route term without a value is refused" (either (const True) (const False) (parseFlowRoute "schema"))
  files <- listDirectory stoppedDirectory
  check "the fixture store holds its run log and effects" (all (`elem` files) [runLogName, "effects.ndjson", "events.ndjson"])
  eventLines <- BC.lines <$> BS.readFile (stoppedDirectory </> "events.ndjson")
  check "every event record has its line" (length eventLines == 8)

-- | Append the state log: the states that every reading shares, the open
-- question, and with the flag the stop and a later question.
populate :: Bool -> Fixture -> IO (FlowStates, Position, Maybe (Position, Position))
populate stopping fixture = do
  _ <- event fixture 0 (RunStartedV2 "review" "scripted" PersonAnswerLocalControl)
  unacknowledged <- control fixture "cancel-1" Nothing CancelRun
  _ <- control fixture "retry-1" (Just 1) RetryOccurrence
  _ <- event fixture 1 (ControlAcknowledgedV2 "retry-1" "accepted" "accepted" "retryOccurrence" (Just (OccurrenceId 1)) Nothing)
  let options = [RecoveryOption "retry" Nothing, RecoveryOption "abandon" Nothing]
  pendingRecovery <- event fixture 2 (OccurrenceRecoveryPending (OccurrenceId 0) "transport" "gap" options)
  _ <- event fixture 3 (OccurrenceRecoveryPending (OccurrenceId 1) "transport" "gap" options)
  _ <- event fixture 4 (OccurrenceRecoveryChosen (OccurrenceId 1) "retry-1" "retry" Nothing)
  let reference = QuestionRef 1 "person/questions/0.json" (T.replicate 64 "c") 100
  pendingPerson <- event fixture 5 (OccurrencePersonAnswerPending (OccurrenceId 2) reference)
  _ <- event fixture 6 (OccurrencePersonAnswerPending (OccurrenceId 3) reference)
  answered <- ask fixture FlowQuestion 3 (questionBody P.SText question)
  _ <- reply fixture FlowAnswer answered 3 (answerBody P.SText "person")
  open <- ask fixture FlowQuestion 4 (questionBody P.SText question)
  started <- ask fixture FlowEngineStart 4 (engineStartBody (E.EngineRequest "acp:claude" Nothing Nothing 0 E.Consult E.TextAnswer "hello" False))
  _ <- reply fixture FlowDone started 4 doneBody
  let effect occurrence phase = appendEffectRecord (fixtureStore fixture) (EffectRecord (String ("effect " <> T.pack (show occurrence))) (if phase == EffectCompleted then Just Null else Nothing) (OccurrenceId occurrence) phase)
  effect (5 :: Word64) EffectStarted
  effect 6 EffectStarted
  effect 6 EffectCompleted
  stopAndLate <-
    if stopping
      then do
        stop <- event fixture 7 (RunCancelled "cancelled")
        late <- ask fixture FlowQuestion 5 (questionBody P.SText question)
        pure (Just (stop, late))
      else pure Nothing
  let pending =
        emptyStates
          { statesUnacknowledged = [unacknowledged],
            statesPendingRecovery = [pendingRecovery],
            statesPendingPersonAnswer = [pendingPerson],
            statesPotentiallyExecuted = [PendingEffect 0 (OccurrenceId 5)]
          }
  pure (pending, open, stopAndLate)

emptyStates :: FlowStates
emptyStates = FlowStates [] [] [] [] [] [] [] False []

-- | Positioned windows over a log of 1500 records, which spans many reads of
-- the reader: every record once in bounded windows, a claim check summarized
-- without its file, a torn tail that no window returns, the refusals of a
-- position ahead of the log and below its base, and a line that does not
-- decode, which a window skips without decoding it.
windowLog :: FilePath -> IO ()
windowLog directory = do
  createDirectory directory
  setFileMode directory 0o700
  let moment = UTCTime (fromGregorian 2026 9 29) 0
      digest = T.replicate 64 "d"
      recordAt :: Int -> Record
      recordAt index
        | index == 5 = Record FlowTurn model (To workflow) (scoped 5) Nothing (ClaimCheck digest 70000) moment
        | index == 6 = Record FlowEvent workflow Public (runAbout run) Nothing (EventNumber (SeqNo 3)) moment
        | otherwise = Record FlowTurn model (To workflow) (scoped (fromIntegral index)) Nothing (Inline (turnBody ("turn " <> T.pack (show index)))) moment
      records = map recordAt [0 .. 1499]
      lineBytes = map encodeFlowLine records
      torn = "{\"schema\":\"turn\""
  BS.writeFile (directory </> "log.ndjson") (BS.concat [line <> "\n" | line <- lineBytes] <> torn)
  check "the window log spans several reads" (sum (map BS.length lineBytes) > 4 * 64 * 1024)
  bracket (openPrivateRoot "flow window check" directory) closePrivateRoot $ \root -> do
    let window base from limits = readFlowWindow root ["log.ndjson"] (Position base) (Position from) limits
        walk base from limits = do
          outcome <- window base from limits
          case outcome of
            Left refusal -> fail ("flow reader: the window at " <> show from <> " is refused: " <> show refusal)
            Right found
              | windowMore found -> ((from, found) :) <$> walk base (positionIndex (windowNext found)) limits
              | otherwise -> pure [(from, found)]
    windows <- walk 0 0 flowWindowLimits
    let entries = concatMap (windowEntries . snd) windows
    check ("bounded windows return every record once, in order: " <> show (length entries)) $
      map windowPosition entries == map Position [0 .. 1499] && map windowRecord entries == records
    check "each window holds at most 64 records, and each but the last holds 64" $
      all ((== 64) . length . windowEntries . snd) (init windows) && all ((<= 64) . length . windowEntries . snd) windows
    check "each window ends at the position after its last record" $
      and [windowNext found == Position (from + fromIntegral (length (windowEntries found))) | (from, found) <- windows]
    check "the last window reaches the last complete record and leaves the torn tail" $
      case last windows of
        (_, found) -> windowNext found == Position 1500 && not (windowMore found)
    check "the line bytes of each window are those of its records" $
      and [windowBytes found == sum [BS.length (encodeFlowLine (windowRecord entry)) | entry <- windowEntries found] | (_, found) <- windows]
    claimsPresent <- doesDirectoryExist (directory </> flowClaimDirectory)
    check "a claim check is summarized by its digest and size without its file" $
      not claimsPresent
        && windowBody (entries !! 5) == Just (object ["omitted" .= ("claim" :: Text), "sha256" .= digest, "bytes" .= (70000 :: Int)])
    check "an event record carries no body in a window" (isNothing (windowBody (entries !! 6)))
    check "an inline body is returned as it is" (windowBody (entries !! 7) == Just (turnBody "turn 7"))
    -- Windows bounded by bytes hold whole records within the bound.
    let byteLimit = 3 * BS.length (lineBytes !! 100)
    byteWindows <- walk 0 0 (FlowWindowLimits 64 byteLimit)
    check "byte-bounded windows return every record once within their bound" $
      map windowPosition (concatMap (windowEntries . snd) byteWindows) == map Position [0 .. 1499]
        && all (\(_, found) -> windowBytes found <= byteLimit && not (null (windowEntries found))) byteWindows
    -- A window deep in the log skips across reads without decoding.
    deep <- window 0 1400 (FlowWindowLimits 10 maxFrameBytes)
    check ("a window deep in the log starts at its position: " <> show (fmap windowNext deep)) $
      fmap (map windowPosition . windowEntries) deep == Right (map Position [1400 .. 1409]) && fmap windowMore deep == Right True
    atEnd <- window 0 1500 flowWindowLimits
    check ("the position after the last complete record gives an empty window: " <> show atEnd) (atEnd == Right (FlowWindow [] (Position 1500) False 0))
    ahead <- window 0 1501 flowWindowLimits
    check ("a position ahead of the complete records is refused with the end: " <> show ahead) (ahead == Left (FlowWindowAhead (Position 1500)))
    counted <- window 0 1499 (FlowWindowLimits 0 maxFrameBytes)
    check ("a window of no records reports that a record remains: " <> show counted) (counted == Right (FlowWindow [] (Position 1499) True 0))
    below <- window 100 99 flowWindowLimits
    check ("a position below the base is refused with the base: " <> show below) (below == Left (FlowWindowBelowFloor (Position 100)))
    based <- window 100 100 (FlowWindowLimits 2 maxFrameBytes)
    check "a file with a base gives its records positions from the base" $
      fmap (map windowPosition . windowEntries) based == Right [Position 100, Position 101]
        && fmap (map windowRecord . windowEntries) based == Right (take 2 records)
    -- A line that does not decode is skipped undecoded, and refused where a
    -- window reaches it.
    BS.writeFile (directory </> "broken.ndjson") (BS.concat [line <> "\n" | line <- take 2 lineBytes] <> "not a record\n" <> BS.concat [line <> "\n" | line <- take 3 (drop 3 lineBytes)])
    let brokenWindow from = readFlowWindow root ["broken.ndjson"] (Position 0) (Position from) flowWindowLimits
    skipped <- brokenWindow 3
    check ("a window after a line that does not decode skips it: " <> show (fmap windowNext skipped)) $
      fmap (map windowPosition . windowEntries) skipped == Right (map Position [3, 4, 5]) && fmap windowMore skipped == Right False
    before <- brokenWindow 0
    check ("a window ends before a line that does not decode: " <> show (fmap windowNext before)) $
      fmap (map windowPosition . windowEntries) before == Right [Position 0, Position 1] && fmap windowMore before == Right True
    refusedAt <- brokenWindow 2
    check ("a window at a line that does not decode is refused there: " <> show refusedAt) $
      case refusedAt of
        Left (FlowWindowUndecodable (Position 2) _) -> True
        _ -> False
    forM_ [(1, 1), (0, 2)] $ \(from, count) -> do
      found <- brokenWindow from
      check ("a window of " <> show count <> " records before the broken line decodes them") (fmap (length . windowEntries) found == Right count)

check :: String -> Bool -> IO ()
check label ok = unless ok (fail ("flow reader: " <> label))
