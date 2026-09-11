{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Agentic.Runtime
import FrontendProtocolTests (frontendProtocolTests, frontendCodecCheck)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (IOException, SomeException, bracket, finally, throwIO, try)
import Data.Bits ((.&.))
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Handle (hDuplicateTo)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removeFile, removePathForcibly, renameDirectory)
import System.Environment (getArgs, getExecutablePath, lookupEnv, setEnv, unsetEnv)
import qualified System.Posix.Directory as PosixDirectory
import System.FilePath ((</>))
import System.Posix.Files (createNamedPipe, createSymbolicLink, fileMode, getFileStatus, setFileMode)
import System.IO (IOMode (ReadMode, WriteMode), hClose, hPutStrLn, openBinaryFile, stderr, stdin, withBinaryFile)
import System.Exit (ExitCode (..), exitWith)
import System.Process (CreateProcess (close_fds), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

main :: IO ()
main = getArgs >>= \case
  ["--frontend-io-test"] -> do
    request <- BS.hGet stdin (maxFrontendQueryBytes + 1)
    response <- runFrontendQuery request
    either (\failure -> hPutStrLn stderr (T.unpack failure) >> exitWith (ExitFailure 3)) BS.putStr response
  "--frontend-codec-test" : arguments -> do
    request <- BS.hGet stdin (fromInteger maxFrontendReplyBytes + 1)
    let response = frontendCodecCheck arguments request
    either (\failure -> hPutStrLn stderr (T.unpack failure) >> exitWith (ExitFailure 3)) BS.putStr response
  _ -> contractTests

contractTests :: IO ()
contractTests = do
  frontendProtocolTests
  privateRootContractTests
  frontendIoContractTests
  frontendExportContractTests
  recoveryFifoProbe
  durableMirrorFailureProbe
  boundedControlFrameProbe
  expect "descriptor v2 round trip" (decodeWorkflowDescriptor (encodeWorkflowDescriptor descriptorV2) == Right descriptorV2)
  expect "descriptor input order" (map workflowInputName (workflowInputs descriptorV2) == ["subject", "notes"])
  expectLeft "descriptor unknown field" (decodeWorkflowDescriptor (encoded (insertField "future" (Bool True) descriptorV2)))
  expectLeft "descriptor unknown capability" (decodeWorkflowDescriptor (encoded (mapCapabilities (KeyMap.insert "future" (Bool True)) descriptorV2)))
  expectLeft "descriptor duplicate input" (decodeWorkflowDescriptor (encodeWorkflowDescriptor descriptorV2 {workflowInputs = duplicateInputs}))
  expectLeft "descriptor duplicate stdin" (decodeWorkflowDescriptor (encodeWorkflowDescriptor descriptorV2 {workflowInputs = stdinInputs}))
  expect "descriptor v3 round trip" (decodeWorkflowDescriptor (encodeWorkflowDescriptor descriptorV3) == Right descriptorV3)
  let exactPlan = exactPlanValue descriptorV2 [object ["consults" .= (2 :: Integer), "paths" .= (1 :: Integer)]]
  expect "exact plan contract decodes post-input descriptor and fold" $
    case decodeExactPlan (encoded exactPlan) of
      Right (summary, Object _) -> exactPlanDescriptor summary == descriptorV2 && exactPlanCodes summary == Just ["text", "receipt"] && exactPlanFold summary == [PlanFold 2 1]
      _ -> False
  expectLeft "exact plan contract requires raw program" (decodeExactPlan (encoded (deleteField "program" exactPlan)))
  expectLeft "exact plan contract requires codes" (decodeExactPlan (encoded (deleteField "codes" exactPlan)))
  expectLeft "exact plan contract requires fold" (decodeExactPlan (encoded (deleteField "fold" exactPlan)))
  expectLeft "exact plan contract requires an object program" (decodeExactPlan (encoded (insertValueField "program" Null exactPlan)))
  expectLeft "exact plan contract refuses unknown fields" (decodeExactPlan (encoded (insertValueField "future" (Bool True) exactPlan)))
  expectLeft "exact plan contract refuses unknown fold fields" (decodeExactPlan (encoded (exactPlanValue descriptorV2 [object ["consults" .= (2 :: Integer), "paths" .= (1 :: Integer), "future" .= True]])))
  expectLeft "exact plan contract bounds code values" (decodeExactPlan (encoded (insertValueField "codes" (toJSON ([""] :: [Text])) exactPlan)))
  expectLeft "exact plan contract refuses descriptor version 3" (decodeExactPlan (encoded (exactPlanValue descriptorV3 [object ["consults" .= (2 :: Integer), "paths" .= (1 :: Integer)]])))
  expectLeft "exact plan contract checks fold summary" (decodeExactPlan (encoded (exactPlanValue descriptorV2 [object ["consults" .= (3 :: Integer), "paths" .= (1 :: Integer)]])))
  let duplicateFoldDescriptor = descriptorV2 {workflowPaths = 2}
  expectLeft "exact plan contract refuses duplicate fold counts" (decodeExactPlan (encoded (exactPlanValue duplicateFoldDescriptor [object ["consults" .= (2 :: Integer), "paths" .= (1 :: Integer)], object ["consults" .= (2 :: Integer), "paths" .= (1 :: Integer)]])))
  expectLeft "exact plan contract refuses nonpositive fold paths" (decodeExactPlan (encoded (exactPlanValue descriptorV2 [object ["consults" .= (2 :: Integer), "paths" .= (0 :: Integer)]])))
  expectLeft "exact plan contract bounds fold rows" (decodeExactPlan (encoded (exactPlanValue descriptorV2 (replicate 4097 (object ["consults" .= (2 :: Integer), "paths" .= (1 :: Integer)])))))
  let postInputCapabilities = capabilities {descriptorConsults = 3, descriptorObserves = 0, descriptorEffects = 1, descriptorEffectful = True, descriptorToolExecution = True}
      postInputDescriptor = descriptorV2 {workflowCapabilities = postInputCapabilities, workflowSize = 7, workflowAskNodes = 4, workflowMinFold = Just 1, workflowMaxFold = Just 3, workflowPaths = 4, workflowPins = ["input-route"], workflowRunFacts = ["input-selected"]}
      postInputPlan = exactPlanValue postInputDescriptor [object ["consults" .= (1 :: Integer), "paths" .= (1 :: Integer)], object ["consults" .= (3 :: Integer), "paths" .= (3 :: Integer)]]
  expect "exact plan contract retains input-dependent facts" $
    case decodeExactPlan (encoded postInputPlan) of
      Right (summary, _) -> exactPlanDescriptor summary == postInputDescriptor && exactPlanFold summary == [PlanFold 1 1, PlanFold 3 3]
      Left _ -> False
  expectLeft "descriptor v3 requires protocol 2" (decodeWorkflowDescriptor (encodeWorkflowDescriptor descriptorV3 {workflowProtocolVersions = [1]}))
  expectLeft "descriptor v3 person mode is exact" (decodeWorkflowDescriptor (encodeWorkflowDescriptor descriptorV3 {workflowPersonAnsweringModes = ["engine"]}))
  descriptorV2Fixture <- BS.readFile "test/fixtures/runtime/descriptor-v2/valid.json"
  descriptorV2Invalid <- BS.readFile "test/fixtures/runtime/descriptor-v2/invalid-unknown.json"
  descriptorV3Fixture <- BS.readFile "test/fixtures/runtime/descriptor-v3/valid.json"
  expect "shared descriptor v2 fixture" (decodeWorkflowDescriptor descriptorV2Fixture == Right descriptorV2)
  expectLeft "shared invalid descriptor v2 fixture" (decodeWorkflowDescriptor descriptorV2Invalid)
  expect "shared descriptor v3 fixture" (decodeWorkflowDescriptor descriptorV3Fixture == Right descriptorV3)
  successful <- requireRight "successful snapshot" (foldSnapshot successEvents)
  expect "snapshot completes" (snapshotRunStatus successful == RunSucceeded)
  expect "snapshot preserves authored order" (snapshotAuthoredOrder successful == [occurrence0])
  expect "snapshot records steered output" $
    case Map.lookup occurrence0 (snapshotOccurrences successful) >>= Map.lookup attempt0 . snapshotOccurrenceAttempts of
      Just attempt -> snapshotAttemptOutput attempt == "answer" && length (snapshotAttemptSteers attempt) == 1
      Nothing -> False
  expectError "snapshot duplicate" SnapshotSequence $ do
    started <- stepRunSnapshot (initialRunSnapshot run1) (envelope 0 (RunStarted "review" "scripted"))
    stepRunSnapshot started (envelope 0 (RunStarted "review" "scripted"))
  expectError "snapshot gap" SnapshotSequence $
    stepRunSnapshot (initialRunSnapshot run1) (envelope 1 (RunStarted "review" "scripted"))
  expectError "snapshot post terminal" SnapshotLifecycle $
    stepRunSnapshot successful (envelope 9 (RunFailed FailureRuntime "late"))
  expectError "snapshot premature trace" SnapshotLifecycle $ do
    started <- stepRunSnapshot (initialRunSnapshot run1) (envelope 0 (RunStarted "review" "scripted"))
    occurrence <- stepRunSnapshot started (envelope 1 (OccurrenceStarted occurrence0 "text" "consult" "model reviewer" "prompt"))
    stepRunSnapshot occurrence (envelope 2 (TraceOrdered [occurrence0]))
  bounded <- requireRight "bounded UTF-8 snapshot" (foldSnapshot unicodeEvents)
  let boundedOutput = do
        occurrence <- Map.lookup occurrence0 (snapshotOccurrences bounded)
        attempt <- Map.lookup attempt0 (snapshotOccurrenceAttempts occurrence)
        pure (snapshotAttemptOutput attempt)
  expect "snapshot output is UTF-8 and byte bounded" $
    case boundedOutput of
      Just output ->
        BS.length (Text.encodeUtf8 output) <= 64 * 1024
          && not (T.any (== '\xfffd') output)
          && "TAIL" `T.isSuffixOf` output
      Nothing -> False
  fixtureEvents <- readEnvelopeFixture "test/fixtures/runtime/protocol-v1/success.ndjson"
  fixtureExpected <- readValueFixture "test/fixtures/runtime/protocol-v1/success.snapshot.json"
  fixtureActual <- requireRight "shared success fixture" (foldSnapshot fixtureEvents)
  expect "shared success fixture snapshot" (runSnapshotValue fixtureActual == fixtureExpected)
  mapM_ checkSharedV1Snapshot ["cancelled", "reused", "redirected", "recovery-failed", "failover-retried"]
  checkSharedRefusal [1] "protocol-v1" "sequence-gap"
  checkSharedRefusal [1] "protocol-v1" "reuse-after-attempt"
  checkSharedRefusal [1, 2] "protocol-v2" "person-terminal-without-acceptance"
  checkSharedRefusal [1, 2] "protocol-v2" "person-queued-then-delivered"
  checkSharedRefusal [2] "protocol-v2" "control-correlation-change"
  personFixtureEvents <- readEnvelopeFixtureFor [1, 2] "test/fixtures/runtime/protocol-v2/person-result.ndjson"
  personFixtureExpected <- readValueFixture "test/fixtures/runtime/protocol-v2/person-result.snapshot.json"
  personFixtureActual <- requireRight "shared protocol-v2 person fixture" (foldSnapshot personFixtureEvents)
  expect "shared protocol-v2 person snapshot" (runSnapshotValue personFixtureActual == personFixtureExpected)
  progressEvents <- readEnvelopeFixtureFor [2] "test/fixtures/runtime/protocol-v2/progress.ndjson"
  progressExpected <- readValueFixture "test/fixtures/runtime/protocol-v2/progress.snapshot.json"
  progressSnapshot <- requireRight "shared protocol-v2 progress fixture" (foldSnapshot progressEvents)
  expect "shared protocol-v2 progress snapshot" (runSnapshotValue progressSnapshot == progressExpected)
  expect "public progress remains distinct from answer bytes" $ case Map.lookup occurrence0 (snapshotOccurrences progressSnapshot) of
    Just occurrence -> case Map.lookup attempt0 (snapshotOccurrenceAttempts occurrence) of
      Just attempt -> snapshotAttemptOutput attempt == "answer" && snapshotOccurrenceAnswer occurrence == Just "answer" && snapshotAttemptReasoningSummaries attempt == ["Checked the public constraints."]
      Nothing -> False
    Nothing -> False
  expectLeft "protocol-v1 refuses public progress"
    (encodeEnvelopeFor 1 (Envelope 1 run1 (SeqNo 0) "2026-09-03T00:00:00Z" (AttemptProgress attempt0 (ProgressMessage "status"))))
  expectLeft "protocol-v2 refuses oversized public progress"
    (encodeEnvelopeFor 2 (Envelope 2 run1 (SeqNo 0) "2026-09-03T00:00:00Z" (AttemptProgress attempt0 (ProgressMessage (T.replicate 4097 "x")))))
  expect
    "protocol-v1 envelope bytes are frozen"
    (encodeEnvelope (envelope 0 (RunStarted "review" "scripted")) == frozenV1Start)
  encodedV2 <- traverse (requireTextRight "encode protocol v2" . encodeEnvelopeFor 2) personV2Events
  expect "legacy decoder refuses protocol v2" (all (either (const True) (const False) . decodeEnvelope) encodedV2)
  decodedV2 <- traverse (requireTextRight "decode protocol v2" . decodeEnvelopeFor [1, 2]) encodedV2
  personSnapshot <- requireRight "protocol-v2 person snapshot" (foldSnapshot decodedV2)
  expect "protocol-v2 person answer has no physical attempt" $
    case Map.lookup occurrence0 (snapshotOccurrences personSnapshot) of
      Just occurrence ->
        Map.null (snapshotOccurrenceAttempts occurrence)
          && not (snapshotOccurrencePersonPending occurrence)
          && snapshotOccurrencePersonQuestion occurrence == Just questionRef
      Nothing -> False
  expect "protocol-v2 completion retains result reference" (snapshotResult personSnapshot == Just resultRef)
  personControlTests
  catalogueContractTests
  storeContractTests
  putStrLn "runtime contracts: descriptor, protocol, controls, snapshot, store, and shared fixtures passed"

expect :: String -> Bool -> IO ()
expect label condition =
  if condition then pure () else throwIO (userError ("failed: " <> label))

expectLeft :: String -> Either Text a -> IO ()
expectLeft label result = case result of
  Left _ -> pure ()
  Right _ -> throwIO (userError ("failed: " <> label <> " was accepted"))

expectError :: String -> SnapshotErrorClass -> Either SnapshotError a -> IO ()
expectError label expected result = case result of
  Left actual | snapshotErrorClass actual == expected -> pure ()
  Left actual -> throwIO (userError ("failed: " <> label <> " returned " <> show actual))
  Right _ -> throwIO (userError ("failed: " <> label <> " was accepted"))

requireRight :: String -> Either SnapshotError a -> IO a
requireRight label result = case result of
  Left failure -> throwIO (userError ("failed: " <> label <> ": " <> show failure))
  Right value -> pure value

requireTextRight :: String -> Either Text a -> IO a
requireTextRight label result = case result of
  Left failure -> throwIO (userError ("failed: " <> label <> ": " <> T.unpack failure))
  Right value -> pure value

expectStoreError :: String -> IO a -> IO ()
expectStoreError label action = do
  outcome <- try @StoreError action
  case outcome of
    Left _ -> pure ()
    Right _ -> throwIO (userError ("failed: " <> label <> " was accepted"))

personControlTests :: IO ()
personControlTests = do
  runtime <- newControlRuntime
  ready <- newEmptyMVar
  answered <- newEmptyMVar
  _ <-
    forkIO $
      waitForRuntimePersonAnswer runtime occurrence0 validAnswer (putMVar ready ())
        >>= putMVar answered
  takeMVar ready
  snapshot <- controlRuntimeSnapshot runtime
  expect "person answer gate is visible" (answerablePersonOccurrences snapshot == [occurrence0])
  let invalidControl = Control (ControlId "person-invalid") (Just occurrence0) Nothing (AnswerPerson (String "yes"))
  (invalidAccepted, invalidAction) <- decideRuntimeControl runtime invalidControl
  expect "person answer is accepted for validation" (acknowledgementState invalidAccepted == Accepted)
  invalidDelivery <- case invalidAction of
    Nothing -> throwIO (userError "failed: invalid person answer had no delivery action")
    Just action -> fst <$> deliverRuntimeActionDeferred runtime invalidControl action
  expect "invalid typed person answer fails" (acknowledgementState invalidDelivery == ControlFailed)
  let validControl = Control (ControlId "person-valid") (Just occurrence0) Nothing (AnswerPerson (Bool True))
  (validAccepted, validAction) <- decideRuntimeControl runtime validControl
  expect "valid person answer is accepted" (acknowledgementState validAccepted == Accepted)
  (validDelivery, release) <- case validAction of
    Nothing -> throwIO (userError "failed: valid person answer had no delivery action")
    Just action -> deliverRuntimeActionDeferred runtime validControl action
  expect "valid person answer reaches delivered state" (acknowledgementState validDelivery == Delivered)
  beforeAck <- tryReadMVar answered
  expect "person gate waits for terminal acknowledgement" (beforeAck == Nothing)
  release
  delivered <- takeMVar answered
  expect "person gate returns canonical JSON" (delivered == (ControlId "person-valid", Bool True))
  let encodedAnswer = encodeControlFor latestProtocolVersion validControl
  expect "protocol v2 control round trip" $
    (encodedAnswer >>= decodeControlFor latestProtocolVersion) == Right validControl
  expectLeft "protocol v1 refuses answerPerson" (encodedAnswer >>= decodeControlFor protocolVersion)
  where
    validAnswer = \case
      Bool _ -> True
      _ -> False

catalogueContractTests :: IO ()
catalogueContractTests = do
  legacyBytes <- BS.readFile "test/fixtures/runtime/frontend-manifest/legacy-ext-pi.json"
  version2Bytes <- BS.readFile "test/fixtures/runtime/frontend-manifest/v2.json"
  version3Bytes <- BS.readFile "test/fixtures/runtime/frontend-manifest/v3.json"
  legacy <- requireTextRight "legacy frontend manifest" (decodeFrontendManifest legacyBytes)
  version2 <- requireTextRight "versioned frontend manifest" (decodeFrontendManifest version2Bytes)
  version3 <- requireTextRight "invocation frontend manifest" (decodeFrontendManifest version3Bytes)
  expect "legacy frontend manifest remains unversioned when exposed" $
    frontendVersion legacy == 1
      && frontendRuntimeStore legacy == "runtime"
      && eitherDecodeStrict' @Value (encodeFrontendManifest legacy) == eitherDecodeStrict' @Value legacyBytes
  expect "versioned frontend manifest v2 round trip and shape remain unchanged" $
    frontendInvocation version2 == Nothing
      && decodeFrontendManifest (encodeFrontendManifest version2) == Right version2
      && eitherDecodeStrict' @Value (encodeFrontendManifest version2) == eitherDecodeStrict' @Value version2Bytes
  expect "versioned frontend manifest v3 round trip retains exact invocation" $
    frontendVersion version3 == frontendManifestVersionWithInvocation
      && decodeFrontendManifest (encodeFrontendManifest version3) == Right version3
  expectLeft "explicit frontend manifest version 1 is not legacy"
    (decodeFrontendManifest (encoded (insertValueField "frontendManifestVersion" (Number 1) (toJSON legacy))))
  expectLeft "null frontend manifest version cannot downgrade v3 to legacy"
    (decodeFrontendManifest (encoded (insertValueField "frontendManifestVersion" Null (toJSON version3))))
  expectLeft "frontend manifest v2 refuses invocation"
    (decodeFrontendManifest (encoded (insertValueField "invocation" (maybe Null toJSON (frontendInvocation version3)) (toJSON version2))))
  expectLeft "frontend manifest v3 requires its invocation field"
    (decodeFrontendManifest (encoded (deleteField "invocation" (toJSON version3))))
  expectLeft "frontend manifest v3 requires non-null invocation"
    (decodeFrontendManifest (encodeFrontendManifest version3 {frontendInvocation = Nothing}))
  expectLeft "frontend manifest v3 refuses unknown outer fields"
    (decodeFrontendManifest (encoded (insertValueField "future" (Bool True) (toJSON version3))))
  expectLeft "frontend manifest v3 requires every v2 field"
    (decodeFrontendManifest (encoded (deleteField "targetArgs" (toJSON version3))))
  expectLeft "frontend manifest v3 does not treat null arrays as omitted"
    (decodeFrontendManifest (encoded (insertValueField "targetArgs" Null (toJSON version3))))
  case frontendInvocation version3 of
    Nothing -> fail "v3 frontend manifest fixture has no invocation"
    Just invocation -> do
      let rejects label changed = expectLeft label (decodeFrontendManifest (encodeFrontendManifest version3 {frontendInvocation = Just changed}))
      rejects "frontend invocation rejects unsupported versions" invocation {frontendInvocationVersion = 2}
      rejects "frontend invocation rejects whitespace aliases" invocation {frontendInvocationRunnerAlias = " \t"}
      rejects "frontend invocation bounds alias UTF-8 bytes" invocation {frontendInvocationRunnerAlias = T.replicate 129 "é"}
      rejects "frontend invocation rejects whitespace executables" invocation {frontendInvocationExecutable = "\n"}
      rejects "frontend invocation bounds executable UTF-8 bytes" invocation {frontendInvocationExecutable = T.replicate 2049 "é"}
      rejects "frontend invocation rejects NUL prefix arguments" invocation {frontendInvocationPrefixArgs = ["ok", "bad\NULargument"]}
      rejects "frontend invocation bounds prefix argument count" invocation {frontendInvocationPrefixArgs = replicate 4097 ""}
      rejects "frontend invocation bounds aggregate UTF-8 bytes" invocation {frontendInvocationPrefixArgs = replicate 17 (T.replicate 2048 "é")}
      let withUnknownInvocation = mapValueField "invocation" (insertValueField "future" (Bool True)) (toJSON version3)
      expectLeft "frontend invocation refuses unknown nested fields" (decodeFrontendManifest (encoded withUnknownInvocation))
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  now <- getCurrentTime
  let root = temporary </> ("agentic-catalogue-contract-" <> show stamp)
      runs = root </> "runs"
      terminalDirectory = runs </> "run-v2"
      liveDirectory = runs </> "run-live"
      legacyDirectory = runs </> "run-legacy"
      corruptDirectory = runs </> "run-corrupt"
      terminalRun = RunId "run-v2"
      liveRun = RunId "run-live"
      terminalFrontend = version2 {frontendRunId = terminalRun, frontendOwnerId = Just "tui:terminal"}
      liveFrontend = version2 {frontendRunId = liveRun, frontendOwnerId = Just "tui:foreign"}
      heartbeat = T.pack (formatTime defaultTimeLocale "%FT%T%QZ" now)
      writePrivate path bytes = BS.writeFile path bytes >> setFileMode path 0o600
      exercise = do
        mapM_ (\path -> createDirectoryIfMissing True path >> setFileMode path 0o700) [root, runs, terminalDirectory, liveDirectory, legacyDirectory, corruptDirectory]
        writePrivate (terminalDirectory </> "supervisor-manifest.json") (encodeFrontendManifest terminalFrontend)
        writePrivate (liveDirectory </> "supervisor-manifest.json") (encodeFrontendManifest liveFrontend)
        writePrivate (legacyDirectory </> "supervisor-manifest.json") legacyBytes
        writePrivate (corruptDirectory </> "supervisor-manifest.json") "{not-json\n"
        withRunStore (terminalDirectory </> "runtime") (testManifestFor terminalRun Nothing) $ \store -> do
          _ <- appendStoredEvent store (Envelope 1 terminalRun (SeqNo 0) heartbeat (RunStarted "review" "scripted"))
          _ <- appendStoredEvent store (Envelope 1 terminalRun (SeqNo 1) heartbeat (TraceOrdered []))
          _ <- appendStoredEvent store (Envelope 1 terminalRun (SeqNo 2) heartbeat (RunCompleted 0 0))
          pure ()
        withRunStore (liveDirectory </> "runtime") (testManifestFor liveRun Nothing) $ \store -> do
          _ <- appendStoredEvent store (Envelope 1 liveRun (SeqNo 0) heartbeat (RunStarted "review" "scripted"))
          pure ()
        writePrivate
          (liveDirectory </> "owner.json")
          (BL.toStrict (encode (object ["version" .= (1 :: Int), "ownerId" .= ("tui:foreign" :: Text), "pid" .= (1 :: Int), "heartbeat" .= heartbeat])) <> "\n")
        createSymbolicLink terminalDirectory (runs </> "run-link")
        entries <- listRunCatalogue root (Just "tui:local") now
        let healthy = [record | CatalogueRun record <- entries]
            corrupt = [failure | CatalogueCorrupt _ failure <- entries]
            ownership run =
              [recordOwnership record | record <- healthy, frontendRunId (recordManifest record) == run]
            policy run =
              [recordPolicy record | record <- healthy, frontendRunId (recordManifest record) == run]
        expect "catalogue isolates corrupt and symlink entries" (length corrupt == 2 && length healthy == 3)
        expect "catalogue reconstructs terminal run" (ownership terminalRun == [RunTerminal])
        expect "catalogue retains only the non-secret runtime policy projection" (policy terminalRun == [Just (object ["kind" .= ("scripted" :: Text)])])
        expect "catalogue marks foreign live owner read-only" (ownership liveRun == [RunOwnedElsewhere])
        expect "catalogue retains prepared legacy run" (ownership (RunId "run-legacy") == [RunNotStarted])
        case [record | record <- healthy, frontendRunId (recordManifest record) == terminalRun] of
          [record] -> withPrivateRoot "catalogue input bounds" root $ \anchor -> do
            let digest = "01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b"
                expected = record {recordManifest = (recordManifest record) {frontendInputHashes = Map.fromList [("first", digest), ("second", digest)]}}
            createPrivateDirectoryAt anchor ["runs", "run-v2", "inputs"]
            writePrivateExclusiveAt anchor ["runs", "run-v2", "inputs", "0.txt"] "\n"
            writePrivateExclusiveAt anchor ["runs", "run-v2", "inputs", "1.txt"] "\n"
            withPrivateDirectoryAt anchor ["runs", "run-v2"] $ \descriptor -> do
              expectIoFailure "aggregate input bound applies before the next file is read" (readFrontendInputBytesBoundedAt 1 expected descriptor ["first", "second"])
              inputs <- readFrontendInputBytesBoundedAt 2 expected descriptor ["first", "second"]
              ordinary <- readFrontendInputBytesAt expected descriptor ["first", "second"]
              expect "bounded input capture preserves the existing ordered reader" (inputs == Map.fromList [("first", "\n"), ("second", "\n")] && inputs == ordinary)
          _ -> ioError (userError "catalogue input fixture is missing")
        let writeLease time = writePrivate (liveDirectory </> "owner.json")
              (BL.toStrict (encode (object ["version" .= (1 :: Int), "ownerId" .= ("tui:foreign" :: Text), "pid" .= (1 :: Int), "heartbeat" .= T.pack (formatTime defaultTimeLocale "%FT%T%QZ" time)])))
        writeLease (addUTCTime (-20) now)
        staleEntries <- listRunCatalogue root Nothing now
        case [record | CatalogueRun record <- staleEntries, frontendRunId (recordManifest record) == liveRun] of
          [stale] -> withPrivateRoot "catalogue test root" root $ \anchor -> do
            expect "catalogue caches a stale owner" (recordOwnership stale == RunOwnerStale)
            withPrivateDirectoryAt anchor ["runs", "run-live"] $ \descriptor -> do
              revalidateLineageParentAt stale descriptor
              getCurrentTime >>= writeLease
              expectIoFailure "fresh owner overrides cached stale ownership" (revalidateLineageParentAt stale descriptor)
              removeFile (liveDirectory </> "owner.json")
              createNamedPipe (liveDirectory </> "owner.json") 0o600
              expectIoFailure "FIFO owner lease cannot authorize lineage" (revalidateLineageParentAt stale descriptor)
              removeFile (liveDirectory </> "owner.json")
            PosixDirectory.createDirectory (legacyDirectory </> "runtime") 0o700
            missingManifest <- listRunCatalogue root Nothing now
            expect "existing runtime with absent manifest is corrupt, not prepared"
              (any (\case CatalogueCorrupt path _ -> path == legacyDirectory; _ -> False) missingManifest)
            removePathForcibly (legacyDirectory </> "runtime")
            createSymbolicLink (root </> "absent") (legacyDirectory </> "runtime")
            linkedRuntime <- listRunCatalogue root Nothing now
            expect "dangling runtime symlink is corrupt, not absent"
              (any (\case CatalogueCorrupt path _ -> path == legacyDirectory; _ -> False) linkedRuntime)
            removeFile (legacyDirectory </> "runtime")
            withPrivateDirectoryAt anchor [] $ \descriptor -> do
              let moved = root <> ".moved"
              renameDirectory root moved
              PosixDirectory.createDirectory root 0o700
              (do
                  anchored <- listRunCatalogueAt root descriptor Nothing now
                  expect "catalogue enumerates its captured root after pathname replacement" (length anchored == length entries)
                ) `finally` (removePathForcibly root >> renameDirectory moved root)
            mapM_ (\index -> PosixDirectory.createDirectory (runs </> ("overflow-" <> show index)) 0o700) [0 :: Int .. 1000]
            expectIoFailure "catalogue bounds enumeration before reading records" (listRunCatalogue root Nothing now)
          _ -> fail "missing live catalogue test record"
  exercise `finally` removePathForcibly root

frontendIoContractTests :: IO ()
frontendIoContractTests = do
  executable <- getExecutablePath
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  now <- getCurrentTime
  frontendBytes <- BS.readFile "test/fixtures/runtime/frontend-manifest/v2.json"
  frontend <- requireTextRight "frontend IO manifest" (decodeFrontendManifest frontendBytes)
  let root = temporary </> ("agentic-frontend-io-" <> show stamp)
      runDirectory = root </> "runs" </> T.unpack (runIdText run1)
      runtimeDirectory = runDirectory </> "runtime"
      resultPath = runtimeDirectory </> "result.json"
      questionPath = runtimeDirectory </> "person" </> "questions" </> "0.json"
      question = object
        [ "code" .= ("flag" :: Text),
          "addressee" .= object ["person" .= object ["id" .= ("owner" :: Text)]],
          "scope" .= object ["model" .= Null, "mode" .= Null],
          "prompt" .= ("full\nquestion" :: Text),
          "draw" .= (0 :: Int)
        ]
      result = object ["ok" .= True]
      ownerBytes = encoded (object ["version" .= (1 :: Int), "ownerId" .= ("pi:foreign" :: Text), "pid" .= (1 :: Int), "heartbeat" .= T.pack (formatTime defaultTimeLocale "%FT%T%QZ" now)])
      query operation fields = object (["version" .= (1 :: Int), "operation" .= (operation :: Text)] <> fields)
      call value = do
        outcome <- timeout 10000000 $
          readCreateProcessWithExitCode ((proc executable ["--frontend-io-test"]) {close_fds = True}) (T.unpack (Text.decodeUtf8 (encoded value)))
        case outcome of
          Nothing -> fail "frontend IO child timed out"
          Just (ExitSuccess, output, _) -> pure (Right (Text.encodeUtf8 (T.pack output)))
          Just (ExitFailure 3, _, failure) -> pure (Left (T.pack failure))
          Just (status, _, failure) -> fail ("frontend IO child failed: " <> show status <> " " <> failure)
      success :: Value -> IO Value
      success value = do
        bytes <- call value >>= requireTextRight "frontend IO response"
        either fail pure (eitherDecodeStrict' bytes)
      refused label value = call value >>= expectLeft label
      writePrivate path bytes = BS.writeFile path bytes >> setFileMode path 0o600
      exercise = do
        mapM_ (\path -> createDirectoryIfMissing True path >> setFileMode path 0o700) [root, root </> "runs", runDirectory]
        identity <- success (query "open-root" ["path" .= root]) >>= \case
          Object fields | Just (String value) <- KeyMap.lookup "rootIdentity" fields -> pure value
          _ -> fail "frontend root response has no identity"
        refused "frontend IO rejects unknown versions" (object ["version" .= (2 :: Int), "operation" .= ("open-root" :: Text), "path" .= root])
        refused "frontend IO rejects unknown fields" (query "open-root" ["path" .= root, "future" .= True])
        refused "frontend IO does not create roots" (query "open-root" ["path" .= (root </> "missing")])
        missing <- doesDirectoryExist (root </> "missing")
        expect "frontend IO missing root remains absent" (not missing)
        refused "frontend IO refuses relative roots" (query "open-root" ["path" .= ("relative" :: Text)])
        runFrontendQuery "not-json" >>= expectLeft "frontend IO refuses malformed JSON"
        runFrontendQuery (BS.replicate (maxFrontendQueryBytes + 1) 32) >>= expectLeft "frontend IO bounds request bytes"
        writePrivate (runDirectory </> "supervisor-manifest.json")
          (encodeFrontendManifest frontend {frontendRunId = run1, frontendPersonAnswering = Just PersonAnswerLocalControl, frontendOwnerId = Just "pi:foreign"})
        writePrivate (runDirectory </> "owner.json") ownerBytes
        (questionRequest, resultRequest) <-
          withRunStoreVersioned latestStoreVersion latestProtocolVersion runtimeDirectory (testManifest (Just PersonAnswerLocalControl)) $ \store -> do
            reference <- writeQuestionArtifact store run1 occurrence0 "consult" question
            _ <- appendStoredEvent store (envelopeV2 0 (RunStartedV2 "review" "scripted" PersonAnswerLocalControl))
            _ <- appendStoredEvent store (envelopeV2 1 (OccurrenceStarted occurrence0 "flag" "consult" "person owner" "approve?"))
            _ <- appendStoredEvent store (envelopeV2 2 (OccurrencePersonAnswerPending occurrence0 reference))
            let questionRequest = query "read-question"
                  [ "rootIdentity" .= identity, "runId" .= runIdText run1,
                    "occurrenceId" .= ("0" :: Text), "codeName" .= ("flag" :: Text), "reference" .= reference
                  ]
            answer <- success questionRequest
            expect "frontend IO reads a complete live human question"
              (answer == query "read-question" ["runId" .= runIdText run1, "occurrenceId" .= ("0" :: Text), "intent" .= ("consult" :: Text), "question" .= question])
            observedOwner <- BS.readFile (runDirectory </> "owner.json")
            expect "frontend IO observes a foreign owner without acquiring control" (observedOwner == ownerBytes)
            mapM_ (\operation -> refused "frontend IO refuses live controls" (query operation ["rootIdentity" .= identity, "runId" .= runIdText run1]))
              ["answerPerson", "cancelRun", "steerOccurrence", "retryOccurrence", "failoverOccurrence", "abandonOccurrence", "redirectOccurrence"]
            refused "frontend IO verifies question code" (insertValueField "codeName" (String "text") questionRequest)
            refused "frontend IO checks occurrence identity" (insertValueField "occurrenceId" (String "1") questionRequest)
            refused "frontend IO bounds occurrence identifiers" (insertValueField "occurrenceId" (String "18446744073709551616") questionRequest)
            refused "frontend IO rejects numeric occurrence identifiers" (insertValueField "occurrenceId" (Number 0) questionRequest)
            refused "frontend IO checks run identity" (insertValueField "runId" (String "another-run") questionRequest)
            refused "frontend IO rejects run path traversal" (insertValueField "runId" (String "..") questionRequest)
            refused "frontend IO verifies question digest"
              (insertValueField "reference" (toJSON reference {questionArtifactSha256 = T.replicate 64 "0"}) questionRequest)
            refused "frontend IO verifies question byte count"
              (insertValueField "reference" (toJSON reference {questionArtifactBytes = questionArtifactBytes reference + 1}) questionRequest)
            originalQuestion <- BS.readFile questionPath
            writePrivate questionPath "{bad-json\n"
            refused "frontend IO rejects changed question bytes" questionRequest
            writePrivate questionPath originalQuestion
            let personDirectory = runtimeDirectory </> "person"
                realPersonDirectory = runtimeDirectory </> "person-real"
            renameDirectory personDirectory realPersonDirectory
            createSymbolicLink realPersonDirectory personDirectory
            refused "frontend IO rejects question ancestor symlinks" questionRequest
            removeFile personDirectory
            renameDirectory realPersonDirectory personDirectory
            _ <- appendStoredEvent store (envelopeV2 3 (ControlAcknowledgedV2 "person-1" "accepted" "accepted" "answerPerson" (Just occurrence0) Nothing))
            _ <- appendStoredEvent store (envelopeV2 4 (ControlAcknowledgedV2 "person-1" "delivered" "delivered" "answerPerson" (Just occurrence0) Nothing))
            _ <- appendStoredEvent store (envelopeV2 5 (OccurrenceCompleted occurrence0 "asked:person owner" "yes"))
            _ <- appendStoredEvent store (envelopeV2 6 (TraceOrdered [occurrence0]))
            resultReference <- writeResultArtifact store run1 (String "receipt") result "done"
            _ <- appendStoredEvent store (envelopeV2 7 (RunCompletedV2 1 1 resultReference))
            pure (questionRequest, query "read-result" ["rootIdentity" .= identity, "runId" .= runIdText run1, "reference" .= resultReference])
        value <- success resultRequest
        expect "frontend IO reads the verified result"
          (value == query "read-result" ["runId" .= runIdText run1, "code" .= ("receipt" :: Text), "value" .= result])
        let journalPath = runtimeDirectory </> "events.ndjson"
        journal <- BS.readFile journalPath
        writePrivate journalPath "{incomplete"
        _ <- success questionRequest
        _ <- success resultRequest
        writePrivate journalPath journal
        originalResult <- BS.readFile resultPath
        let anotherDirectory = root </> "runs" </> "another-run" </> "runtime"
        mapM_ (\path -> createDirectoryIfMissing True path >> setFileMode path 0o700) [root </> "runs" </> "another-run", anotherDirectory]
        writePrivate (anotherDirectory </> "result.json") originalResult
        refused "frontend IO verifies the stored run identity" (insertValueField "runId" (String "another-run") resultRequest)
        let copyPath = root </> "result-copy.json"
        writePrivate copyPath originalResult
        removeFile resultPath
        createSymbolicLink copyPath resultPath
        refused "frontend IO rejects result leaf symlinks" resultRequest
        removeFile resultPath
        writePrivate resultPath originalResult
        removeFile resultPath
        createNamedPipe resultPath 0o600
        refused "frontend IO rejects nonregular artifacts without blocking" resultRequest
        removeFile resultPath
        refused "frontend IO rejects missing artifacts" resultRequest
        writePrivate resultPath originalResult
        let moved = root <> "-moved"
        renameDirectory root moved
        (do
            PosixDirectory.createDirectory root 0o700
            outcome <- call resultRequest
            expect "frontend IO refuses a replaced root identity" (either ("identity changed" `T.isInfixOf`) (const False) outcome)
          ) `finally` (removePathForcibly root >> renameDirectory moved root)
  exercise `finally` removePathForcibly root

frontendExportContractTests :: IO ()
frontendExportContractTests = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let rootPath = temporary </> ("agentic-frontend-export-" <> show stamp)
      runDirectory = rootPath </> "runs" </> T.unpack (runIdText run1)
      runtimeDirectory = runDirectory </> "runtime"
      result = object ["ok" .= True, "count" .= (3 :: Int)]
      code = object ["name" .= ("receipt" :: Text)]
      exercise = withPrivateRoot "frontend export test root" rootPath $ \root -> do
        ensurePrivateDirectoryAt root ["runs"]
        createPrivateDirectoryAt root ["runs", T.unpack (runIdText run1)]
        reference <- withAnchorEnvironment root $
          withRunStoreVersioned latestStoreVersion latestProtocolVersion runtimeDirectory (testManifest (Just PersonAnswerLocalControl)) $ \store ->
            writeResultArtifact store run1 code result "typed result"
        BS.writeFile (runtimeDirectory </> "events.ndjson") "{damaged journal"
        let request name reference' identity = object
              [ "version" .= (1 :: Int), "operation" .= ("export-result" :: Text),
                "rootIdentity" .= identity, "runId" .= runIdText run1,
                "reference" .= reference', "name" .= (name :: Text)
              ]
            expected = encoded (object ["code" .= code, "value" .= result]) <> "\n"
            expectedDigest = T.pack (show (hash expected :: Digest SHA256))
        receiptBytes <- runFrontendExport rootPath (encoded (request "typed.json" reference (privateRootIdentity root)))
          >>= requireTextRight "frontend export response"
        exported <- BS.readFile (rootPath </> "exports" </> "typed.json")
        mode <- fileMode <$> getFileStatus (rootPath </> "exports" </> "typed.json")
        receipt <- either fail pure (eitherDecodeStrict' receiptBytes)
        expect "frontend export publishes exact typed compact JSON and receipt" $
          exported == expected
            && mode .&. 0o777 == 0o600
            && receipt == object
              [ "version" .= (1 :: Int), "operation" .= ("export-result" :: Text),
                "runId" .= runIdText run1, "name" .= ("typed.json" :: Text),
                "path" .= (rootPath </> "exports" </> "typed.json"),
                "bytes" .= T.pack (show (BS.length expected)), "sha256" .= expectedDigest,
                "code" .= code
              ]
        runFrontendExport rootPath (encoded (request "typed.json" reference (privateRootIdentity root)))
          >>= expectLeft "frontend export never overwrites an existing destination"
        unchanged <- BS.readFile (rootPath </> "exports" </> "typed.json")
        expect "frontend export existing destination remains unchanged" (unchanged == expected)
        runFrontendExport rootPath (encoded (request "wrong-root.json" reference ("[]" :: String)))
          >>= expectLeft "frontend export binds the request to configured state"
        runFrontendExport rootPath (encoded (request "tampered.json" reference {resultArtifactSha256 = T.replicate 64 "0"} (privateRootIdentity root)))
          >>= expectLeft "frontend export verifies the complete artifact reference"
        runFrontendExport rootPath (encoded (insertValueField "body" (String "forbidden") (request "body.json" reference (privateRootIdentity root))))
          >>= expectLeft "frontend export has no caller-supplied body"
        runFrontendExport rootPath (encoded (mapValueField "reference" (insertValueField "future" (Bool True)) (request "nested.json" reference (privateRootIdentity root))))
          >>= expectLeft "frontend export reference schema is strict"
        mapM_ (\name -> runFrontendExport rootPath (encoded (request name reference (privateRootIdentity root))) >>= expectLeft "frontend export rejects invalid names")
          ["", ".", "..", "a/b", "a\\b", "control\DEL", T.replicate 128 "é"]
        runFrontendExport rootPath (BS.replicate (maxFrontendQueryBytes + 1) 32)
          >>= expectLeft "frontend export bounds request bytes"
  exercise `finally` removePathForcibly rootPath

storeContractTests :: IO ()
storeContractTests = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let root = temporary </> ("agentic-runtime-contract-" <> show stamp)
      store2 = root </> "store2"
      store1 = root </> "store1"
      invalid = root </> "invalid"
      localManifest = testManifest (Just PersonAnswerLocalControl)
      legacyManifest = testManifest Nothing
      code = String "receipt"
      result = object ["ok" .= True]
      questionCode = String "flag"
      question =
        object
          [ "code" .= questionCode,
            "addressee" .= object ["person" .= object ["id" .= ("owner" :: Text)]],
            "scope" .= object ["model" .= Null, "mode" .= Null],
            "prompt" .= ("full\nquestion" :: Text),
            "draw" .= (0 :: Int)
          ]
      exercise = do
        (writtenResult, writtenQuestion) <-
          withRunStoreVersioned latestStoreVersion latestProtocolVersion store2 localManifest $ \store -> do
            _ <- appendStoredEvent store (envelopeV2 0 (RunStartedV2 "review" "scripted" PersonAnswerLocalControl))
            resultReference <- writeResultArtifact store run1 code result "done\nnow"
            questionReference <- writeQuestionArtifact store run1 occurrence0 "consult" question
            pure (resultReference, questionReference)
        restoredManifest <- readManifest store2
        expect "store2 records local person provenance" (manifestPersonAnswering restoredManifest == Just PersonAnswerLocalControl)
        restoredResult <- readResultArtifact store2 run1 writtenResult
        expect "result artifact round trip" (restoredResult == result && resultArtifactPreview writtenResult == "done now")
        restoredQuestion <- readQuestionArtifact store2 run1 occurrence0 questionCode writtenQuestion
        expect "question artifact round trip" (restoredQuestion == ("consult", question))
        frontendQuestion <- readQuestionArtifactByCodeName store2 run1 occurrence0 "flag" writtenQuestion
        expect "frontend question artifact verifies public code name" (frontendQuestion == ("consult", question))
        expectStoreError
          "question artifact code/schema mismatch"
          (readQuestionArtifact store2 run1 occurrence0 (String "text") writtenQuestion)
        expectStoreError
          "frontend question artifact code-name mismatch"
          (readQuestionArtifactByCodeName store2 run1 occurrence0 "text" writtenQuestion)
        resultStatus <- getFileStatus (store2 </> "result.json")
        questionStatus <- getFileStatus (store2 </> "person" </> "questions" </> "0.json")
        expect "artifacts are mode 0600" (fileMode resultStatus .&. 0o777 == 0o600 && fileMode questionStatus .&. 0o777 == 0o600)
        resultTemp <- doesFileExist (store2 </> "result.json.tmp")
        questionTemp <- doesFileExist (store2 </> "person" </> "questions" </> "0.json.tmp")
        expect "artifact installation leaves no temporary file" (not resultTemp && not questionTemp)
        expectStoreError
          "result artifact digest mismatch"
          (readResultArtifact store2 run1 writtenResult {resultArtifactSha256 = T.replicate 64 "0"})
        (storedEvents, _) <- readEventLog store2
        expect "store2 reads protocol-v2 events" (length storedEvents == 1 && envelopeVersion (headEnvelope storedEvents) == 2)
        BS.appendFile (store2 </> "result.json") "x"
        expectStoreError "result artifact tamper" (readResultArtifact store2 run1 writtenResult)
        expectStoreError
          "result artifact path escape"
          (readResultArtifact store2 run1 writtenResult {resultArtifactPath = "../result.json"})
        expectStoreError
          "result artifact oversize reference"
          (readResultArtifact store2 run1 writtenResult {resultArtifactBytes = maxArtifactBytes + 1})
        removeFile (store2 </> "result.json")
        createSymbolicLink (store2 </> "person" </> "questions" </> "0.json") (store2 </> "result.json")
        expectStoreError "result artifact symlink" (readResultArtifact store2 run1 writtenResult)
        withRunStore store1 legacyManifest $ \store ->
          expectStoreError "store1 result artifact" (writeResultArtifact store run1 code result "done")
        expectStoreError "mixed store/protocol versions" (createRunStoreVersioned latestStoreVersion protocolVersion invalid localManifest)
  exercise `finally` removePathForcibly root

privateRootContractTests :: IO ()
privateRootContractTests = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let bucket = temporary </> ("agentic-private-root-" <> show stamp)
      path = bucket </> "state"
      moved = bucket </> "moved"
      outside = bucket </> "outside"
      exercise = withPrivateRoot "test state root" path $ \root -> do
        PosixDirectory.createDirectory outside 0o700
        BS.writeFile (outside </> "sentinel") "untouched"
        ensurePrivateDirectoryAt root ["inputs"]
        writePrivateExclusiveAt root ["inputs", "0.txt"] "input"
        input <- readPrivateFileAt root ["inputs", "0.txt"] 64
        expect "anchored input round trip" (input == "input")
        createNamedPipe (path </> "inputs" </> "fifo") 0o600
        expectIoFailure "FIFO is rejected without waiting for a writer" (readPrivateFileAt root ["inputs", "fifo"] 64)
        writePrivateAtomicAt root ["owner.json"] "first"
        writePrivateAtomicAt root ["owner.json"] "second"
        owner <- BS.readFile (path </> "owner.json")
        expect "anchored atomic replacement" (owner == "second")
        bracket (openPrivateRoot "closing root" path) closePrivateRoot $ \closing -> do
          publishPrivateFileAt closing ["closing.json"] $ \handle -> do
            closePrivateRoot closing
            BS.hPut handle "retained before close"
          expectIoFailure "late workers cannot reuse a closed root descriptor" (writePrivateExclusiveAt closing ["late"] "bad")
        closedPublication <- BS.readFile (path </> "closing.json")
        expect "in-flight publication retains its own descriptor through root close" (closedPublication == "retained before close")
        createSymbolicLink (outside </> "sentinel") (path </> "owner.json.tmp")
        writePrivateAtomicAt root ["owner.json"] "third"
        ownerAfterStaleTemporary <- BS.readFile (path </> "owner.json")
        staleTemporaryStillExists <- doesFileExist (path </> "owner.json.tmp")
        expect "a stale fixed temporary cannot reserve an atomic destination" (ownerAfterStaleTemporary == "third" && staleTemporaryStillExists)
        removeFile (path </> "owner.json.tmp")
        createSymbolicLink (outside </> "sentinel") (path </> ".agentic-tmp-stale")
        publishPrivateFileAt root ["after-stale.json"] (\handle -> BS.hPut handle "complete")
        afterStale <- BS.readFile (path </> "after-stale.json")
        staleUniqueStillExists <- doesFileExist (path </> ".agentic-tmp-stale")
        expect "a stale unique temporary cannot reserve a later publication" (afterStale == "complete" && staleUniqueStillExists)
        interruptionStarted <- newEmptyMVar
        interruptionDone <- newEmptyMVar
        interruptedThread <- forkIO $
          try @SomeException (publishPrivateFileAt root ["interrupted.json"] $ \handle -> do
            BS.hPut handle "partial"
            putMVar interruptionStarted ()
            threadDelay 60000000) >>= putMVar interruptionDone
        takeMVar interruptionStarted
        killThread interruptedThread
        interrupted <- takeMVar interruptionDone
        interruptedFinal <- doesFileExist (path </> "interrupted.json")
        expect "an interrupted publication leaves no final partial file" (either (const (not interruptedFinal)) (const False) interrupted)
        completions <- mapM (\index -> do
          done <- newEmptyMVar
          _ <- forkIO $ try @IOException (publishPrivateFileAt root ["concurrent.json"] (\handle -> BS.hPut handle (BS.replicate 32 index))) >>= putMVar done
          pure done) [1 .. 8]
        outcomes <- mapM takeMVar completions
        concurrent <- BS.readFile (path </> "concurrent.json")
        let successes = length [() | Right () <- outcomes]
        expect "concurrent exclusive publication has one complete winner" (successes == 1 && concurrent `elem` [BS.replicate 32 index | index <- [1 .. 8]])
        createSymbolicLink outside (path </> "linked")
        expectIoFailure "mkdirat refuses a symlink ancestor" (ensurePrivateDirectoryAt root ["linked", "escaped"])
        expectIoFailure "openat refuses a symlink ancestor" (writePrivateExclusiveAt root ["linked", "escaped"] "bad")
        mapM_ (\component -> expectIoFailure "invalid private component" (writePrivateExclusiveAt root [component] "bad"))
          ["", ".", "..", "a/b", "nul\NULsuffix"]
        PosixDirectory.createDirectory (path </> "public") 0o755
        expectIoFailure "public descendants are refused" (ensurePrivateDirectoryAt root ["public", "escaped"])
        publicStatus <- getFileStatus (path </> "public")
        expect "public descendant permissions are not repaired" (fileMode publicStatus .&. 0o777 == 0o755)
        withAnchorEnvironment root $ do
          let runtime = path </> "runs" </> "run" </> "runtime"
          withRunStoreVersioned 2 2 runtime (testManifest (Just PersonAnswerLocalControl)) $ \store -> do
            writeSnapshot store Null
            renameDirectory runtime (runtime <> "-moved")
            PosixDirectory.createDirectory runtime 0o700
            expectIoFailure "store detects a replaced runtime directory" (writeSnapshot store (Bool True))
            _ <- appendStoredEvent store (envelopeV2 0 (RunStartedV2 "review" "scripted" PersonAnswerLocalControl))
            replacement <- listDirectory runtime
            expect "retained store journal cannot write into its replacement" (null replacement)
          renameDirectory path moved
          PosixDirectory.createDirectory path 0o700
          expectIoFailure "child store rejects a changed parent identity"
            (withRunStoreVersioned 2 2 (path </> "escape") (testManifest Nothing) (const (pure ())))
          replacement <- listDirectory path
          expect "child rejection creates nothing in the replacement root" (null replacement)
          removePathForcibly path
          renameDirectory moved path
        publishPrivateFileAt root ["published.json"] $ \handle -> do
          renameDirectory path moved
          PosixDirectory.createDirectory path 0o700
          BS.hPut handle "anchored"
        replacement <- listDirectory path
        expect "mid-publication root replacement receives no writes" (null replacement)
        published <- BS.readFile (moved </> "published.json")
        expect "publication stays on the retained descriptor after pathname replacement" (published == "anchored")
        expectIoFailure "root identity change is detected" (assertPrivateRoot root)
        removePathForcibly path
        createSymbolicLink moved path
        expectIoFailure "trailing slash cannot bypass root no-follow" (withPrivateRoot "test state root" (path <> "/") (const (pure ())))
        sentinel <- BS.readFile (outside </> "sentinel")
        names <- listDirectory outside
        expect "no escaped writes or sentinel changes" (sentinel == "untouched" && names == ["sentinel"])
  exercise `finally` removePathForcibly bucket

withAnchorEnvironment :: PrivateRoot -> IO a -> IO a
withAnchorEnvironment root action =
  bracket
    (lookupEnv "AGENT_CAT_STATE_ANCHOR" <* setEnv "AGENT_CAT_STATE_ANCHOR" (privateRootIdentity root))
    (maybe (unsetEnv "AGENT_CAT_STATE_ANCHOR") (setEnv "AGENT_CAT_STATE_ANCHOR"))
    (const action)

expectIoFailure :: String -> IO a -> IO ()
expectIoFailure label action = do
  outcome <- try @IOException action
  expect label (either (const True) (const False) outcome)

headEnvelope :: [Envelope] -> Envelope
headEnvelope [value] = value
headEnvelope _ = error "runtime contract fixture expected exactly one envelope"

testManifest :: Maybe PersonAnswering -> RunManifest
testManifest = testManifestFor run1

testManifestFor :: RunId -> Maybe PersonAnswering -> RunManifest
testManifestFor runId personAnswering =
  RunManifest
    runId
    "review"
    "0.1.0.0"
    (object ["program" .= ("fixture" :: Text)])
    "scripted"
    (object ["kind" .= ("scripted" :: Text)])
    Nothing
    RootRun
    Nothing
    personAnswering

foldSnapshot :: [Envelope] -> Either SnapshotError RunSnapshot
foldSnapshot = foldl step (Right (initialRunSnapshot run1))
  where
    step snapshot envelope' = snapshot >>= (`stepRunSnapshot` envelope')

checkSharedV1Snapshot :: FilePath -> IO ()
checkSharedV1Snapshot name = do
  events <- readEnvelopeFixture ("test/fixtures/runtime/protocol-v1/" <> name <> ".ndjson")
  expected <- readValueFixture ("test/fixtures/runtime/protocol-v1/" <> name <> ".snapshot.json")
  actual <- requireRight ("shared " <> name <> " fixture") (foldSnapshot events)
  expect ("shared " <> name <> " fixture snapshot") (runSnapshotValue actual == expected)

checkSharedRefusal :: [Int] -> FilePath -> FilePath -> IO ()
checkSharedRefusal versions directory name = do
  let base = "test/fixtures/runtime/" <> directory <> "/" <> name
  events <- readEnvelopeFixtureFor versions (base <> ".ndjson")
  expected <- readValueFixture (base <> ".error.json")
  case foldSnapshot events of
    Left failure ->
      expect
        ("shared " <> name <> " refusal")
        (object ["errorClass" .= snapshotErrorClassText (snapshotErrorClass failure)] == expected)
    Right _ -> throwIO (userError ("failed: shared " <> name <> " refusal was accepted"))

readEnvelopeFixture :: FilePath -> IO [Envelope]
readEnvelopeFixture = readEnvelopeFixtureFor [protocolVersion]

readEnvelopeFixtureFor :: [Int] -> FilePath -> IO [Envelope]
readEnvelopeFixtureFor versions path = do
  bytes <- BS.readFile path
  traverse decodeLine (filter (not . BS.null) (BS.split 10 bytes))
  where
    decodeLine line = case decodeEnvelopeFor versions line of
      Left why -> throwIO (userError ("failed to decode " <> path <> ": " <> T.unpack why))
      Right value -> pure value

readValueFixture :: FilePath -> IO Value
readValueFixture path = do
  bytes <- BS.readFile path
  case eitherDecodeStrict' bytes of
    Left why -> throwIO (userError ("failed to decode " <> path <> ": " <> why))
    Right value -> pure value

snapshotErrorClassText :: SnapshotErrorClass -> Text
snapshotErrorClassText SnapshotVersion = "version"
snapshotErrorClassText SnapshotRun = "run"
snapshotErrorClassText SnapshotSequence = "sequence"
snapshotErrorClassText SnapshotLifecycle = "lifecycle"

envelope :: Word64 -> RuntimeEvent -> Envelope
envelope sequence' event = Envelope 1 run1 (SeqNo sequence') "2026-09-03T00:00:00Z" event

run1 :: RunId
run1 = RunId "run-1"

occurrence0 :: OccurrenceId
occurrence0 = OccurrenceId 0

attempt0 :: AttemptId
attempt0 = AttemptId occurrence0 0

successEvents :: [Envelope]
successEvents =
  [ envelope 0 (RunStarted "review" "scripted"),
    envelope 1 (OccurrenceStarted occurrence0 "text" "consult" "model reviewer" "prompt"),
    envelope 2 (AttemptStarted attempt0 "scripted"),
    envelope 3 (AttemptOutput attempt0 "answer"),
    envelope 4 (AttemptSteered attempt0 "steer-1" "interrupt-now" "focus"),
    envelope 5 (AttemptCompleted attempt0 "scripted"),
    envelope 6 (OccurrenceCompleted occurrence0 "asked:model reviewer" "answer"),
    envelope 7 (TraceOrdered [occurrence0]),
    envelope 8 (RunCompleted 1 1)
  ]

unicodeEvents :: [Envelope]
unicodeEvents =
  [ envelope 0 (RunStarted "review" "scripted"),
    envelope 1 (OccurrenceStarted occurrence0 "text" "consult" "model reviewer" "prompt"),
    envelope 2 (AttemptStarted attempt0 "scripted"),
    envelope 3 (AttemptOutput attempt0 ("prefix" <> T.replicate 20000 "😀" <> "TAIL"))
  ]

frozenV1Start :: BS.ByteString
frozenV1Start = "{\"event\":{\"target\":\"scripted\",\"type\":\"run.started\",\"workflow\":\"review\"},\"protocolVersion\":1,\"runId\":\"run-1\",\"sequence\":\"0\",\"timestamp\":\"2026-09-03T00:00:00Z\"}"

questionRef :: QuestionRef
questionRef = QuestionRef 1 "person/questions/0.json" (T.replicate 64 "a") 100

resultRef :: ResultRef
resultRef = ResultRef 1 "result.json" (T.replicate 64 "b") 120 (String "receipt") "done"

personV2Events :: [Envelope]
personV2Events =
  [ envelopeV2 0 (RunStartedV2 "review" "scripted" PersonAnswerLocalControl),
    envelopeV2 1 (OccurrenceStarted occurrence0 "flag" "consult" "person owner" "approve?"),
    envelopeV2 2 (OccurrencePersonAnswerPending occurrence0 questionRef),
    envelopeV2 3 (ControlAcknowledgedV2 "person-1" "accepted" "accepted" "answerPerson" (Just occurrence0) Nothing),
    envelopeV2 4 (ControlAcknowledgedV2 "person-1" "delivered" "delivered" "answerPerson" (Just occurrence0) Nothing),
    envelopeV2 5 (OccurrenceCompleted occurrence0 "asked:person owner" "yes"),
    envelopeV2 6 (TraceOrdered [occurrence0]),
    envelopeV2 7 (RunCompletedV2 1 1 resultRef)
  ]

envelopeV2 :: Word64 -> RuntimeEvent -> Envelope
envelopeV2 sequence' event = Envelope 2 run1 (SeqNo sequence') "2026-09-03T00:00:00Z" event

encoded :: Value -> BS.ByteString
encoded = BL.toStrict . encode

exactPlanValue :: WorkflowDescriptor -> [Value] -> Value
exactPlanValue descriptor folds = case toJSON descriptor of
  Object fields ->
    Object
      ( KeyMap.insert "program" (object ["fixture" .= True])
          (KeyMap.insert "codes" (toJSON (["text", "receipt"] :: [Text])) (KeyMap.insert "fold" (toJSON folds) fields))
      )
  other -> other

deleteField :: Text -> Value -> Value
deleteField key (Object fields) = Object (KeyMap.delete (fromText key) fields)
deleteField _ value = value

insertValueField :: Text -> Value -> Value -> Value
insertValueField key field (Object fields) = Object (KeyMap.insert (fromText key) field fields)
insertValueField _ _ value = value

mapValueField :: Text -> (Value -> Value) -> Value -> Value
mapValueField key change (Object fields) = case KeyMap.lookup (fromText key) fields of
  Just value -> Object (KeyMap.insert (fromText key) (change value) fields)
  Nothing -> Object fields
mapValueField _ _ value = value

insertField :: Text -> Value -> WorkflowDescriptor -> Value
insertField key value descriptor = case toJSON descriptor of
  Object fields -> Object (KeyMap.insert (fromText key) value fields)
  other -> other

mapCapabilities :: (KeyMap.KeyMap Value -> KeyMap.KeyMap Value) -> WorkflowDescriptor -> Value
mapCapabilities f descriptor = case toJSON descriptor of
  Object fields -> case KeyMap.lookup "capabilities" fields of
    Just (Object capabilityFields) -> Object (KeyMap.insert "capabilities" (Object (f capabilityFields)) fields)
    _ -> Object fields
  other -> other

fromText :: Text -> Key.Key
fromText = Key.fromText

descriptorV2 :: WorkflowDescriptor
descriptorV2 =
  WorkflowDescriptor
    { workflowDescriptorVersion = 2,
      workflowRunnerVersion = "0.1.0.0",
      workflowProtocolVersions = [1],
      workflowStoreVersions = [1],
      workflowCapabilities = capabilities,
      workflowName = "review",
      workflowBlurb = "Review one subject",
      workflowResultCode = String "receipt",
      workflowLevel = "pipeline",
      workflowSize = 3,
      workflowAskNodes = 2,
      workflowMinFold = Just 2,
      workflowMaxFold = Just 2,
      workflowPaths = 1,
      workflowInputs =
        [ WorkflowInputDescriptor "subject" DescriptorCommandTail,
          WorkflowInputDescriptor "notes" DescriptorPrompt
        ],
      workflowRunFacts = ["run.engine"],
      workflowPins = ["deep"],
      workflowPersonAnsweringModes = []
    }

descriptorV3 :: WorkflowDescriptor
descriptorV3 =
  descriptorV2
    { workflowDescriptorVersion = 3,
      workflowProtocolVersions = [1, 2],
      workflowStoreVersions = [1, 2],
      workflowPersonAnsweringModes = ["local-control"]
    }

capabilities :: DescriptorCapabilities
capabilities =
  DescriptorCapabilities
    { descriptorStructuredRun = True,
      descriptorWholeRunCancel = True,
      descriptorControlFd = Just 3,
      descriptorRequestControls = True,
      descriptorSteering = True,
      descriptorInteractiveRetry = True,
      descriptorSchedulerRedirect = True,
      descriptorSemanticResume = True,
      descriptorImmutableFork = True,
      descriptorRestartFromScratch = True,
      descriptorProtocolNegotiation = False,
      descriptorRoutingInspection = False,
      descriptorRoutingJsonVersion = Nothing,
      descriptorPersonaRouting = False,
      descriptorModelAliasRouting = False,
      descriptorConsults = 1,
      descriptorObserves = 1,
      descriptorEffects = 0,
      descriptorEffectful = False,
      descriptorToolExecution = False
    }

boundedControlFrameProbe :: IO ()
boundedControlFrameProbe = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let path = temporary </> ("agentic-control-bound-" <> show stamp)
  BS.writeFile path (BS.replicate (maxFrameBytes + 1) 120)
  ( do
      runtime <- newControlRuntime
      observed <- newIORef []
      result <- withBinaryFile path ReadMode $ \handle ->
        try @MachineCancelled
          (withControlInputFor 2 handle (\event -> modifyIORef' observed (<> [event])) runtime (threadDelay 5000000))
      events <- readIORef observed
      expect "control reader refuses an over-bound frame before decoding" $
        case (result, events) of
          (Left _, [ControlAcknowledgedV2 _ "failed" message _ _ _]) -> "exceeds" `T.isInfixOf` message
          _ -> False
      BS.writeFile path ""
      withBinaryFile path ReadMode $ \handle -> do
        frame <- readNdjsonFrame 3 "frontend request" handle "abc\nnext"
        expect "framing retains following transport bytes" (frame == Right (Just ("abc", "next")))
        oversized <- readNdjsonFrame 3 "frontend request" handle "abcd\n"
        expect "framing rejects a complete oversized frame" (oversized == Left "frontend request frame exceeds 3 bytes")
        truncated <- readNdjsonFrame 3 "frontend request" handle "abc"
        expect "framing refuses an incomplete final frame" (truncated == Left "frontend request stream ended without a terminating newline")
        ended <- readNdjsonFrame 3 "frontend request" handle ""
        expect "framing distinguishes clean EOF" (ended == Right Nothing)
      cancellation <- either (ioError . userError . T.unpack) pure (encodeControlFor 2 (Control (ControlId "buffered") Nothing Nothing CancelRun))
      bufferedRuntime <- newControlRuntime
      bufferedEvents <- newIORef []
      cancelled <- withBinaryFile path ReadMode $ \handle ->
        try @MachineCancelled
          (withBufferedControlInputFor 2 handle (cancellation <> "\n") (\event -> modifyIORef' bufferedEvents (<> [event])) bufferedRuntime (threadDelay 5000000))
      delivered <- readIORef bufferedEvents
      expect "retained controls are consumed before EOF without losing correlation" $
        case (cancelled, delivered) of
          (Left failure, [ControlAcknowledgedV2 "buffered" "accepted" _ _ _ _]) -> machineCancellationReason failure == "cancelled by control"
          _ -> False
    )
    `finally` removeFile path

durableMirrorFailureProbe :: IO ()
durableMirrorFailureProbe = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let root = temporary </> ("agentic-mirror-contract-" <> show stamp)
      durablePath = root </> "events.ndjson"
      mirrorPath = root </> "closed-mirror"
      run = RunId "mirror-failure"
  createDirectoryIfMissing True root
  ( do
      BS.writeFile mirrorPath ""
      mirror <- openBinaryFile mirrorPath WriteMode
      hClose mirror
      first <- withBinaryFile durablePath WriteMode $ \durable -> do
        sink <- handlesEventSinkFor 2 [durable, mirror] run
        deferred <- newDeferredEventSink
        failure <- try @IOError (activateEventSink deferred sink (RunStartedV2 "fixture" "scripted" PersonAnswerEngine))
        deferredEventSink deferred (RunFailed FailureProtocol "stdout mirror failed")
        pure failure
      bytes <- BS.readFile durablePath
      events <-
        traverse
          (\line -> either (throwIO . userError . T.unpack) pure (decodeEnvelopeFor [2] line))
          (filter (not . BS.null) (BS.split 10 bytes))
      expect "durable journal advances before a failed stdout mirror and remains terminal" $
        case (first, events) of
          (Left _, [Envelope _ _ (SeqNo 0) _ RunStartedV2 {}, Envelope _ _ (SeqNo 1) _ RunFailed {}]) -> True
          _ -> False
      let repairedPath = root </> "repaired-primary"
      failures <- withBinaryFile durablePath ReadMode $ \primary ->
        withBinaryFile repairedPath WriteMode $ \replacement -> do
          sink <- handlesEventSinkFor 2 [primary] run
          failed <- try @IOException (sink (RunStartedV2 "fixture" "scripted" PersonAnswerEngine))
          hDuplicateTo replacement primary
          hPutStrLn primary "handle repaired"
          repeated <- try @IOException (sink (RunCancelled "must not append after an uncertain primary write"))
          pure (failed, repeated)
      repairedBytes <- BS.readFile repairedPath
      expect "a failed primary write poisons the sink even if the handle becomes writable" $
        case failures of
          (Left _, Left _) -> repairedBytes == "handle repaired\n"
          _ -> False
    )
    `finally` removePathForcibly root

recoveryFifoProbe :: IO ()
recoveryFifoProbe = do
  runtime <- newControlRuntime
  let first = OccurrenceId 10
      second = OccurrenceId 11
      control name occurrence = Control (ControlId name) (Just occurrence) Nothing RetryOccurrence
  readyFirst <- newEmptyMVar
  readySecond <- newEmptyMVar
  resultFirst <- newEmptyMVar
  resultSecond <- newEmptyMVar
  _ <- forkIO (waitForRuntimeRecovery runtime first [RecoveryRetry] (putMVar readyFirst ()) >>= putMVar resultFirst)
  takeMVar readyFirst
  _ <- forkIO (waitForRuntimeRecovery runtime second [RecoveryRetry] (putMVar readySecond ()) >>= putMVar resultSecond)
  takeMVar readySecond
  (laterAck, laterAction) <- decideRuntimeControl runtime (control "later-early" second)
  expect "later concurrent recovery cannot overtake FIFO head" (acknowledgementState laterAck == RejectedStale && laterAction == Nothing)
  (_, firstAction) <- decideRuntimeControl runtime (control "first" first)
  case firstAction of
    Nothing -> throwIO (userError "FIFO head recovery was not actionable")
    Just action -> do
      _ <- deliverRuntimeAction runtime (control "first" first) action
      pure ()
  _ <- takeMVar resultFirst
  let awaitSecond = do
        snapshot <- controlRuntimeSnapshot runtime
        case recoverableOccurrences snapshot of
          occurrence : _ | occurrence == second -> pure ()
          _ -> threadDelay 1000 >> awaitSecond
  awaitSecond
  (_, secondAction) <- decideRuntimeControl runtime (control "second" second)
  case secondAction of
    Nothing -> throwIO (userError "second FIFO recovery did not become actionable")
    Just action -> do
      _ <- deliverRuntimeAction runtime (control "second" second) action
      pure ()
  _ <- takeMVar resultSecond
  pure ()

duplicateInputs :: [WorkflowInputDescriptor]
duplicateInputs =
  [ WorkflowInputDescriptor "subject" DescriptorPrompt,
    WorkflowInputDescriptor "subject" DescriptorPrompt
  ]

stdinInputs :: [WorkflowInputDescriptor]
stdinInputs =
  [ WorkflowInputDescriptor "left" DescriptorStdin,
    WorkflowInputDescriptor "right" DescriptorStdin
  ]
