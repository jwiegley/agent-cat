{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Exact comparison of independently owned Runtime executions.
module VerticalCheck (EventOrder (..), compareNativeRuns) where

import qualified Agentic.Runtime as R
import Control.Exception (IOException, try)
import Control.Monad (foldM, forM_, unless)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (partition)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import System.FilePath ((</>))

require :: String -> Bool -> IO ()
require label ok = unless ok (ioError (userError ("vertical comparison: " <> label)))

-- Each table is injective in both directions. Occurrence and attempt addresses
-- are authored coordinates and must agree exactly, not enter these tables.
bind :: (Eq a, Show a) => String -> IORef [(a,a)] -> a -> a -> IO ()
bind label table left right = do
  pairs <- readIORef table
  require (label <> " consistent bijection")
    (all (\(a,b) -> (a == left) == (b == right)) pairs)
  unless ((left,right) `elem` pairs) $ do
    modifyIORef' table (<> [(left,right)])
    putStrLn ("CORRESPONDENCE " <> label <> " " <> show left <> " -> " <> show right)

-- The composition root supplies its authored dependency and shared-lane facts.
data EventOrder = SerialEvents | IndependentModelPerson

compareNativeRuns :: EventOrder -> IORef [(R.RunId,R.RunId)] -> FilePath -> R.RunId -> FilePath -> R.RunId -> IO ()
compareNativeRuns order identities managedRoot managedId directRoot directId = do
  require "independent physical runs" (managedId /= directId)
  bind "run" identities managedId directId
  (managed,managedEvents) <- readNative managedRoot managedId
  (direct,directEvents) <- readNative directRoot directId
  pairs <- readIORef identities
  let parent a b = case (a,b) of
        (Nothing,Nothing) -> True
        (Just x,Just y) -> (x,y) `elem` pairs
        _ -> False
      m = R.recordManifest managed
      d = R.recordManifest direct
      managedDirectory = R.recordDirectory managed </> "runtime"
      directDirectory = R.recordDirectory direct </> "runtime"
  require "frontend physical identity" (R.frontendRunId m == managedId && R.frontendRunId d == directId)
  require "frontend parent correspondence" (parent (R.frontendParentRunId m) (R.frontendParentRunId d))
  require "original owners retained in manifests" (R.frontendOwnerId m /= Nothing && R.frontendOwnerId d /= Nothing)
  putStrLn ("CORRESPONDENCE owner " <> show (R.frontendOwnerId m,R.frontendOwnerId d))
  putStrLn ("CORRESPONDENCE createdAt " <> show (R.frontendCreatedAt m,R.frontendCreatedAt d))
  -- Only named physical facts correspond. All remaining manifest fields,
  -- including invocation, inputs, program, policy and lineage edits, are exact.
  let corresponding = m { R.frontendRunId = R.frontendRunId d,
        R.frontendParentRunId = R.frontendParentRunId d,
        R.frontendOwnerId = R.frontendOwnerId d,
        R.frontendCreatedAt = R.frontendCreatedAt d }
  require "complete frontend semantics" (corresponding == d)
  require "frozen policy" (R.recordPolicy managed == R.recordPolicy direct)
  let inputs record = R.withPrivateRoot "vertical inputs" (R.recordDirectory record) $ \root ->
        R.withPrivateDirectoryAt root [] $ \fd -> R.readFrontendInputBytesAt record fd (Map.keys (R.frontendInputHashes (R.recordManifest record)))
  managedInputs <- inputs managed
  directInputs <- inputs direct
  require "complete captured input bytes" (managedInputs == directInputs && not (Map.null managedInputs))
  (mm,_,mh) <- R.readRunStore managedDirectory
  (dm,_,dh) <- R.readRunStore directDirectory
  require "healthy stores" (mh == R.StoreHealthy && dh == R.StoreHealthy)
  require "runtime identities agree with frontend" (R.manifestRunId mm == managedId && R.manifestRunId dm == directId)
  require "runtime owners agree with frontend" (R.manifestOwner mm == R.frontendOwnerId m && R.manifestOwner dm == R.frontendOwnerId d)
  require "runtime lineage agrees with frontend" (R.manifestParent mm == R.frontendParentRunId m && R.manifestParent dm == R.frontendParentRunId d)
  require "complete native program, target, policy and lineage"
    (mm { R.manifestRunId = R.manifestRunId dm, R.manifestParent = R.manifestParent dm, R.manifestOwner = R.manifestOwner dm } == dm)
  ma <- R.readAnswerRecords managedDirectory
  da <- R.readAnswerRecords directDirectory
  require "exact typed answers, questions and memo flags" (ma == da && not (null ma))
  me <- R.readEffectRecords managedDirectory
  de <- R.readEffectRecords directDirectory
  require "exact effect records" (me == de)
  mc <- R.readCheckpoint managedDirectory
  dc <- R.readCheckpoint directDirectory
  require "exact semantic checkpoint" (mc == dc)
  controls <- newIORef []
  let event = compareEvent controls managedDirectory managedId directDirectory directId
      journals left right = do
        lanes <- eventPairs order left right
        forM_ lanes $ \(a,b) -> do
          require "protocol version" (R.envelopeVersion a == R.envelopeVersion b)
          putStrLn ("CORRESPONDENCE sequence/time " <> show (R.envelopeSequence a,R.envelopeSequence b,R.envelopeTimestamp a,R.envelopeTimestamp b))
          event (R.envelopeEvent a) (R.envelopeEvent b)
  journals managedEvents directEvents
  -- A changed physical interleaving is allowed only across the two declared
  -- independent lanes. Removing, duplicating or reordering within one is not.
  let followsZero e = case R.envelopeEvent e of
        R.AttemptStarted (R.AttemptId (R.OccurrenceId 0) _) _ -> True
        R.OccurrenceReused (R.OccurrenceId 0) _ -> True
        R.OccurrenceCompleted (R.OccurrenceId 0) _ _ -> True
        _ -> False
  case [e | e <- directEvents, R.OccurrenceStarted (R.OccurrenceId 0) _ _ _ _ <- [R.envelopeEvent e]] of
    [first] -> case filter followsZero directEvents of
      second:_ -> do
        let swapped = [if R.envelopeSequence e == R.envelopeSequence first then second else if R.envelopeSequence e == R.envelopeSequence second then first else e | e <- directEvents]
        rejects (journals managedEvents swapped)
      [] -> ioError (userError "vertical comparison: missing occurrence-zero order witness")
    _ -> ioError (userError "vertical comparison: missing unique occurrence zero")
  case directEvents of
    first:rest -> do
      rejects (journals managedEvents rest)
      rejects (journals managedEvents (first:directEvents))
    [] -> ioError (userError "vertical comparison: missing journal")
  -- Mutate actual observations, not an independently invented expected model.
  forM_ [ (a,R.OccurrenceCompleted o source (answer <> " changed"))
        | envelope <- directEvents, let a = R.envelopeEvent envelope,
          R.OccurrenceCompleted o source answer <- [a] ] $ \(a,b) -> rejects (event a b)
  forM_ [ (a,R.RunCompletedV2 (fresh+1) memo reference)
        | envelope <- directEvents, let a = R.envelopeEvent envelope,
          R.RunCompletedV2 fresh memo reference <- [a] ] $ \(a,b) -> rejects (event a b)
  putStrLn "PASS exact managed/direct native semantics, bills, typed values and physical correspondence"
  where
    rejects action = do
      outcome <- try @IOException action
      require "changed observation must fail comparison" (case outcome of Left _ -> True; Right () -> False)

eventPairs :: EventOrder -> [R.Envelope] -> [R.Envelope] -> IO [(R.Envelope,R.Envelope)]
eventPairs order left right = do
  require "event count" (length left == length right && not (null left))
  case order of
    SerialEvents -> do
      require "physical sequence order" (map R.envelopeSequence left == map R.envelopeSequence right)
      pure (zip left right)
    IndependentModelPerson -> do
      a <- lanes left
      b <- lanes right
      require "all lane lengths" (map length a == map length b)
      pure (concat (zipWith zip a b))
  where
    lanes events = case events of
      start:rest | R.RunStartedV2 {} <- R.envelopeEvent start -> case reverse rest of
        terminal:trace:middle | R.RunCompletedV2 {} <- R.envelopeEvent terminal,
                               R.TraceOrdered [R.OccurrenceId 0,R.OccurrenceId 1,R.OccurrenceId 2,R.OccurrenceId 3] <- R.envelopeEvent trace -> do
          tagged <- mapM (\e -> do model <- modelLane (R.envelopeEvent e); pure (model,e)) (reverse middle)
          let (model,person) = partition fst tagged
          pure [[start],map snd model,map snd person,[trace,terminal]]
        _ -> bad
      _ -> bad
    bad = ioError (userError "vertical comparison: unexpected independent-lane boundary")
    occurrence (R.OccurrenceId n) = do
      require "declared model/person occurrence" (n <= 3)
      pure (n == 0)
    attempt (R.AttemptId o n) = do
      require "declared model attempt" (o == R.OccurrenceId 0 && n == 0)
      pure True
    modelLane e = case e of
      R.OccurrenceStarted o _ _ _ _ -> occurrence o
      R.OccurrenceReused o _ -> occurrence o
      R.OccurrenceCompleted o _ _ -> occurrence o
      R.AttemptStarted a _ -> attempt a
      R.AttemptControlAvailability a _ -> attempt a
      R.AttemptCompleted a _ -> attempt a
      R.OccurrencePersonAnswerPending o _ -> do
        model <- occurrence o
        require "person question lane" (not model)
        pure False
      R.ControlAcknowledgedV2 _ _ _ "answerPerson" (Just o) Nothing -> do
        model <- occurrence o
        require "person control lane" (not model)
        pure False
      _ -> ioError (userError ("vertical comparison: undeclared lane event " <> show e))

readNative :: FilePath -> R.RunId -> IO (R.RunRecord,[R.Envelope])
readNative root native = R.withPrivateRoot "vertical comparison" root $ \owned -> do
  now <- getCurrentTime
  pair@(record,events) <- R.withPrivateDirectoryAt owned ["runs",T.unpack (R.runIdText native)] $ \fd ->
    R.readRunRecordWithEnvelopesAt (root </> "runs" </> T.unpack (R.runIdText native)) fd Nothing now
  -- Shared decoder validates physical IDs and UTC timestamps. Shared fold checks
  -- every transition, including terminal authored trace and exact sequence.
  snapshot <- foldM (\s e -> do
    decoded <- either (ioError . userError . T.unpack) pure (R.decodeEnvelopeFor R.supportedProtocolVersions (R.encodeEnvelope e))
    require "codec preserves envelope" (decoded == e)
    either (ioError . userError . show) pure (R.stepRunSnapshot s e)) (R.initialRunSnapshot native) events
  require "record uses complete valid terminal trace" (R.recordSnapshot record == Just snapshot && R.snapshotRunStatus snapshot == R.RunSucceeded && R.snapshotTraceRecorded snapshot)
  pure pair

compareEvent :: IORef [(Text,Text)] -> FilePath -> R.RunId -> FilePath -> R.RunId -> R.RuntimeEvent -> R.RuntimeEvent -> IO ()
compareEvent controls md mi dd di left right = case (left,right) of
  (R.ControlAcknowledgedV2 a state message command occurrence attempt,
   R.ControlAcknowledgedV2 b state' message' command' occurrence' attempt') -> do
    bind "control" controls a b
    require "exact correlated control meaning" ((state,message,command,occurrence,attempt) == (state',message',command',occurrence',attempt'))
  (R.OccurrencePersonAnswerPending a ar,R.OccurrencePersonAnswerPending b br) -> do
    require "question address and reference" (a == b && R.questionArtifactVersion ar == R.questionArtifactVersion br && R.questionArtifactPath ar == R.questionArtifactPath br)
    av <- question md mi a ar
    bv <- question dd di b br
    require "verified typed question" (av == bv)
    putStrLn ("CORRESPONDENCE verified question " <> show (ar,br))
  (R.RunCompletedV2 fresh memo ar,R.RunCompletedV2 fresh' memo' br) -> do
    require "exact bills and result reference meaning" ((fresh,memo,R.resultArtifactVersion ar,R.resultArtifactPath ar,R.resultArtifactCode ar,R.resultArtifactPreview ar) == (fresh',memo',R.resultArtifactVersion br,R.resultArtifactPath br,R.resultArtifactCode br,R.resultArtifactPreview br))
    av <- R.readResultArtifact md mi ar
    bv <- R.readResultArtifact dd di br
    require "verified typed result" (av == bv)
    putStrLn ("CORRESPONDENCE verified result " <> show (ar,br))
  _ -> require ("exact event " <> show (left,right)) (left == right)
  where
    question directory run occurrence reference = R.withPrivateRoot "vertical question" directory $ \root ->
      R.withPrivateDirectoryAt root [] $ \fd -> R.readQuestionArtifactSchemaAt directory fd run occurrence reference
