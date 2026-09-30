{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The run-log reader: verification of lines, claim checks and reply
-- positions, and the states of section 3.6 computed on constructed logs.
module FlowReaderTests (flowReaderTests) where

import Agentic.Runtime
import qualified Agentic.Engine as E
import qualified Agentic.Planning as P
import BucketEvidence (withCaptureBucket)
import Control.Monad (unless, void)
import Data.Aeson (Value (Null, String), object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime))
import Data.Word (Word64)
import System.Directory (getTemporaryDirectory, listDirectory)
import System.FilePath ((</>))

flowReaderTests :: IO ()
flowReaderTests = do
  temporary <- getTemporaryDirectory
  withCaptureBucket "agentic-flow-reader-" temporary $ \bucket -> do
    completeLog (bucket </> "complete")
    stateLog (bucket </> "states")
  putStrLn "flow reader checks passed: torn lines, claim checks, reply positions and every run-log state"

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

  (_, _, stopAndLate) <- withFixture stoppedDirectory (populate True)
  (stop, late) <- maybe (fail "flow reader: the stopped log has no stop") pure stopAndLate
  stopped <- readFlow FlowEnded stoppedDirectory
  check ("the stopped log verifies: " <> show (flowReportProblems stopped)) (flowVerified stopped)
  check "the stop is the cancel" (reportStop stopped == Just stop)
  check ("an ask after the stop is reported and uncertain: " <> show (reportStates stopped))
    (reportStates stopped == pending {statesUncertain = [open, late], statesAskAfterStop = [late]})

  -- Routes select records by schema, sender, address and identifiers.
  let selected route = either (fail . T.unpack) (\parsed -> pure [entryPosition entry | entry <- reportEntries stopped, Just record <- [entryRecord entry], flowRouteMatches parsed record]) (parseFlowRoute route)
  questions <- selected "schema=question,occurrence=4"
  check "a route of schema and occurrence selects one question" (questions == [open])
  controls <- selected "from=manager,command=cancel-1"
  check "a route of sender and command selects one control" (controls == statesUnacknowledged pending)
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
emptyStates = FlowStates [] [] [] [] [] [] False []

check :: String -> Bool -> IO ()
check label ok = unless ok (fail ("flow reader: " <> label))
