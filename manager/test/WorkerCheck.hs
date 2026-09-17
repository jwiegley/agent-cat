{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Agentic.Manager.Authorization (authenticateCredential)
import Agentic.Manager.Drafts (createDraft, changeDraftInput, readDraft, assembleDraft)
import Agentic.Manager.Protocol.Draft (DraftView (..), SuppliedInput (..))
import Agentic.Manager.Configuration
import Agentic.Manager.Profile hiding (OutputOverflow)
import Agentic.Manager.Store
import Agentic.Manager.Worker
import Agentic.Runtime
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..), async, asyncThreadId, cancel, concurrently, wait, waitCatch)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, readMVar, swapMVar, tryReadMVar)
import Control.Exception (AsyncException (UserInterrupt), IOException, SomeException, bracket, finally, fromException, throwIO, throwTo, try, uninterruptibleMask_)
import Control.Monad (forM, forM_, unless, void, replicateM_)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (convert)
import qualified Database.SQLite3 as SQL
import Data.Aeson (Value (Bool), encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTimeNSec)
import Foreign.C.Types (CInt (..))
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, removeFile)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (ExitSuccess, ExitFailure))
import System.FilePath ((</>))
import System.Process (CreateProcess (std_in, std_out, std_err), StdStream (CreatePipe), proc, readProcessWithExitCode)
import System.IO (BufferMode (LineBuffering), hSetBuffering, hGetLine, hPutStrLn, hFlush, stdin, stdout, stderr)
import System.Posix.Signals (installHandler, sigTERM, Handler (Catch))
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["cleanup-evidence-data", work] -> cleanupEvidenceDataChecks work
    ["backpressure-close",work,native] -> withCase work "backpressure" native [] $ \root _ _ store revision catalogue ->
      withFrontendWorker store "profile" revision (setupFor root catalogue "person-controlled") (backpressureClose native)
    ["termination-cases",work,native] -> terminationChecks work native
    ["fixture-term-wait"] -> do
      _ <- installHandler sigTERM (Catch (putStrLn "term")) Nothing
      putStrLn "ready"
      void(BS.hGetSome stdin 1)
    ["fixture-exit"] -> pure ()
    ["fixture-wait"] -> void (BS.hGetSome stdin 1)
    ["cleanup-failure", work, native] -> cleanupFailureChild work native
    ["watchdog-survival", work, native] -> watchdogSurvivalChecks work native
    ["audit-attachment", work, native] -> attachmentCloseChecks work native
    ["audit-writer", work, source, native, python] -> wrappedChecks work source native python
    [work, source, native, python] -> do
      positiveChecks work native
      watchdogSurvivalChecks work native
      draftWorkerChecks work native
      cleanupChecks work native
      terminationChecks work native
      saturationChecks work native
      wrappedChecks work source native python
      registrationChecks work native
      attachmentCloseChecks work native
      reservedEnvironmentChecks work source native python
      putStrLn "PASS manager-owned native frontend workers"
    _ -> error "usage: manager-worker-check PRIVATE_DIRECTORY SOURCE NATIVE_RUNNER PYTHON"

check :: String -> Bool -> IO ()
check label condition = unless condition (error ("FAIL " <> label)) >> putStrLn ("PASS " <> label)
right :: Show e => Either e a -> IO a
right = either (error . show) pure
expect :: String -> WorkerFailure -> IO a -> IO ()
expect label expected action = do
  result <- try @WorkerFailure action
  check label (case result of Left failure -> failure == expected; Right _ -> False)
await :: IO a -> IO a
await action = timeout 15000000 action >>= maybe (error "fixture rendezvous timed out") pure
waitUntil :: IO Bool -> IO ()
waitUntil predicate = await loop
  where loop = predicate >>= \done -> unless done (threadDelay 1000 >> loop)

withCase :: FilePath -> String -> FilePath -> [String] -> (FilePath -> Configuration -> InstalledConfiguration -> CoordinationStore -> Text -> Discovery -> IO a) -> IO a
withCase work name executable prefix action = do
  let root = work </> name
  createDirectory root
  setFileMode root 0o700
  configuration <- writeConfiguration work name executable prefix [] >>= load
  bracket (installConfiguration configuration >>= right) closeConfiguration $ \installed ->
    withCoordinationStore installed $ \store -> do
      (_, profiles) <- configurationSnapshot installed >>= right
      revision <- case profiles of [profile] -> pure (publicRevision profile); _ -> error "missing profile"
      catalogue <- probeConfiguredProfile installed "profile" revision >>= right
      action root configuration installed store revision catalogue

writeConfiguration :: FilePath -> String -> FilePath -> [String] -> [(String,String)] -> IO FilePath
writeConfiguration work name executable prefix extra = do
  let path = work </> (name <> ".json")
      environment = [("XDG_CONFIG_HOME", work </> "config"), ("TMPDIR", work),
        ("WORKER_EXPLICIT", "configured only"), ("LC_ALL", "C"), ("PYTHONCOERCECLOCALE", "0"), ("PYTHONUTF8", "1")] <> extra
  BL.writeFile path (encode (object
    ["version" .= (1::Int), "managerRoot" .= (work </> name), "localRetentionRoots" .= ([]::[String]),
     "runners" .= [object ["alias" .= ("native"::Text), "executable" .= executable, "prefix" .= prefix]],
     "profiles" .= [object ["id" .= ("profile"::Text), "runner" .= ("native"::Text), "workspace" .= work,
       "workspaceLabel" .= ("fixture"::Text), "targetLabel" .= ("scripted"::Text), "targetArguments" .= ["--scripted"::Text],
       "environment" .= [object ["name" .= key,"value" .= value] | (key,value) <- environment],
       "ownership" .= ("service-owned"::Text), "quarantined" .= False, "personAnswering" .= ("local-control"::Text), "resourceKeys" .= ([]::[Text])]],
     "limits" .= object ["drafts" .= (10::Int),"globalDrafts" .= (20::Int),"globalCaptureBytes" .= (67108864::Int),
       "globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),
       "globalMutationLedgerBytes" .= (8388608::Int),"safetyControlsPerMinute" .= (20::Int),"executionReservations" .= (1::Int)]]))
  setFileMode path 0o600
  pure path
load :: FilePath -> IO Configuration
load path = loadConfiguration (\arguments -> if arguments == ["--scripted"] then Right () else Left InvalidConfiguration)  exactPreparedTarget (const False) path >>= right

setupFor :: FilePath -> Discovery -> Text -> FrontendSetupRequest
setupFor root catalogue workflow =
  let selected = discoverySelection catalogue
      context = selectionContext selected
   in RootSetup (FrontendSetup workflow (root </> "runs") (operatorTargetArguments context) Nothing
        (operatorPersonAnswering context) [("input", Literal "fixture\r\n雪")]
        (Just (selectionInvocation selected)))

positiveChecks :: FilePath -> FilePath -> IO ()
positiveChecks work native = withCase work "native" native [] $ \root _ _ store revision catalogue -> do
  let person = setupFor root catalogue "person-controlled"
  escaped <- withFrontendWorker store "profile" revision person $ \worker -> do
    prepared <- workerPrepared worker
    before <- observeWorker worker
    check "preparation has a real native identity without synthetic started event"
      (observedWorkerPhase before == WorkerPrepared && observedQueuedFrames before == 0 && observedWorkerSequence before == Nothing)
    let runDirectory = root </> "runs" </> "runs" </> T.unpack (runIdText (preparedRunId prepared))
    doesDirectoryExist runDirectory >>= check "preparation has not created runtime execution state" . not
    discardWorker worker
    waitWorker worker >>= check "real native discard exits normally" . (== ExitSuccess)
    consumeWorkerEvent worker (const (error "discard produced an envelope")) >>= check "discard fabricates no runtime events" . not
    doesDirectoryExist runDirectory >>= check "discard retains no started run directory" . not
    pure worker
  expect "escaped closed worker cannot start" WorkerClosed (startWorker escaped)
  expect "stale profile cannot create a worker" WorkerConfiguration (withFrontendWorker store "profile" "stale" person (const (pure ())))
  let badFile = case person of RootSetup request -> RootSetup request {setupInputs=[("input",File (root </> "captures" </> "unregistered"))]}; _ -> person
  expect "lexical capture path alone grants no worker input authority" WorkerConfiguration (withFrontendWorker store "profile" revision badFile (const (pure ())))
  withFrontendWorker store "profile" revision person $ \worker -> do
    startWorker worker
    expect "repeated start cannot consume the live preparation twice" WorkerPhaseViolation (startWorker worker)
    claimed <- newEmptyMVar
    blocked <- newEmptyMVar
    observer <- async (consumeWorkerEvent worker $ \event -> putMVar claimed (workerEventBytes event) >> takeMVar blocked)
    first <- await (takeMVar claimed)
    cancel observer
    outcome <- waitCatch observer
    check "ingestion callback cancellation preserves its original exception" (case outcome of
      Left failure -> case fromException failure of Just AsyncCancelled -> True; Nothing -> False
      Right _ -> False)
    retained <- newIORef BS.empty
    consumeWorkerEvent worker (\event -> modifyIORef' retained (const (workerEventBytes event))) >>= check "cancelled callback retained the head for explicit consumption"
    readIORef retained >>= check "retained head bytes were not rewritten or dropped" . (== first)
    failedObserver <- try @AsyncException (observeWorker worker >> throwIO UserInterrupt :: IO ())
    check "status observer failure is not worker control EOF" (case failedObserver of Left UserInterrupt -> True; _ -> False)
    events <- collectPerson worker
    check "real correlated person controls reach native runtime" (length [() | Envelope {envelopeEvent=ControlAcknowledgedV2 _ "delivered" _ _ _ _} <- events] == 2)
    check "native terminal result is observed rather than inferred" (any (\event -> case envelopeEvent event of RunCompletedV2 {} -> True; _ -> False) events)
    waitWorker worker >>= check "native started worker joins normally" . (== ExitSuccess)
  withFrontendWorker store "profile" revision person $ \worker -> do
    startWorker worker
    forM_ [1..80::Int] $ \index -> writeWorkerControl worker (Control (ControlId ("backpressure_" <> T.pack(show index))) (Just (OccurrenceId 999)) Nothing (Steer NextBoundary "queued fixture"))
    waitUntil ((==32) . observedQueuedFrames <$> observeWorker worker)
    status <- observeWorker worker
    check "event queue applies bounded lossless backpressure" (observedQueuedFrames status == 32 && observedQueuedBytes status <= 8388608)
    events <- collectPerson worker
    check "backpressured native acknowledgements are delivered without loss" (length [() | Envelope {envelopeEvent=ControlAcknowledgedV2 ident _ _ _ _ _} <- events, "backpressure_" `T.isPrefixOf` ident] == 80)
    waitWorker worker >>= check "backpressure release preserves normal worker completion" . (== ExitSuccess)
  withFrontendWorker store "profile" revision person (backpressureClose native)
  withFrontendWorker store "profile" revision person $ \worker -> do
    startWorker worker
    let send ident = writeWorkerControl worker (Control (ControlId ident) (Just (OccurrenceId 999)) Nothing (Steer NextBoundary "serialized"))
    (first, second) <- concurrently (try @WorkerFailure (send "writer_one")) (try @WorkerFailure (send "writer_two"))
    forM_ [(first,"writer_one"),(second,"writer_two")] $ \(result,ident) -> case result of
      Left WorkerWriterBusy -> send ident
      Left failure -> throwIO failure
      Right () -> pure ()
    events <- collectPerson worker
    check "concurrent writer calls preserve complete correlated frames" (length [() | Envelope {envelopeEvent=ControlAcknowledgedV2 ident _ _ _ _ _} <- events, ident `elem` ["writer_one","writer_two"]] == 2)
  ownerFailure <- try @AsyncException (withFrontendWorker store "profile" revision person (const (throwIO UserInterrupt)) :: IO ())
  check "owner failure preserves identity after joined cleanup" (case ownerFailure of Left UserInterrupt -> True; _ -> False)
  withFrontendWorker store "profile" revision person $ \worker -> discardWorker worker >> void (waitWorker worker)
  check "ownership remains usable after callback failure" True

collectPerson :: FrontendWorker -> IO [Envelope]
collectPerson worker = do
  result <- newIORef []
  let loop = do
        more <- consumeWorkerEvent worker $ \event -> do
          let envelope = workerEventEnvelope event
          check "retained native bytes decode through shared codec" (decodeEnvelopeFor [latestProtocolVersion] (BS.init (workerEventBytes event)) == Right envelope)
          modifyIORef' result (envelope :)
          case envelopeEvent envelope of
            OccurrencePersonAnswerPending occurrence _ -> writeWorkerControl worker
              (Control (ControlId ("answer_" <> T.pack (show (occurrenceNumber occurrence)))) (Just occurrence) Nothing (AnswerPerson (Bool False)))
            _ -> pure ()
        whenMore more loop
  await loop
  reverse <$> readIORef result
  where whenMore more action = if more then action else pure ()

wrappedChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
wrappedChecks work source native python = do
  let wrapper = source </> "manager/test/worker_fixture.py"
      scenarios = [("prepared-malformed",WorkerPreparedDecode),("prepared-utf8",WorkerPreparedDecode),
        ("prepared-truncated",WorkerPreparedFraming),("prepared-oversized",WorkerPreparedFraming),
        ("startup-exit",WorkerPreparedFraming),("runtime-malformed",WorkerRuntimeDecode),
        ("runtime-utf8",WorkerRuntimeDecode),("runtime-truncated",WorkerRuntimeFraming),
        ("runtime-oversized",WorkerRuntimeFraming),("runtime-wrong-run",WorkerWrongIdentity),
        ("runtime-gap",WorkerSequenceViolation)]
  forM_ scenarios $ \(mode,expected) -> do
    let evidence = work </> (mode <> ".ndjson")
    withCase work mode python [wrapper,native,mode,evidence] $ \root _ _ store revision catalogue -> do
      result <- try @WorkerFailure $ withFrontendWorker store "profile" revision (setupFor root catalogue "prompt-source") $ \worker -> do
        startWorker worker
        let drain = consumeWorkerEvent worker (const (pure ())) >>= \more -> if more then drain else pure ()
        drain
        void (waitWorker worker)
      check (mode <> " reaches its intended worker guard") (case result of Left failure -> failure == expected; Right _ -> False)
  let evidence = work </> "failed-write.ndjson"
  withCase work "failed-write" python [wrapper,native,"failed-write",evidence] $ \root _ _ store revision catalogue ->
    withFrontendWorker store "profile" revision (setupFor root catalogue "person-controlled") $ \worker -> do
      waitUntil (doesFileExist (work </> "failed-write.ready"))
      expect "failed private write closes and joins actual worker" WorkerWriteFailed (startWorker worker)
      status <- observeWorker worker
      check "failed write leaves a completed failure observation" (observedWorkerExit status == Just (Left WorkerWriteFailed))
  let blockedEvidence = work </> "blocked-write.ndjson"
  withCase work "blocked-write" python [wrapper,native,"blocked-write",blockedEvidence] $ \root _ _ store revision catalogue ->
    withFrontendWorker store "profile" revision (setupFor root catalogue "person-controlled") $ \worker -> do
      waitUntil (doesFileExist (work </> "blocked-write.ready"))
      startWorker worker
      let blocked = writeWorkerControl worker (Control (ControlId "blocked") (Just (OccurrenceId 0)) Nothing (Steer NextBoundary (T.replicate 524288 "x")))
      bracket (async (try @WorkerFailure blocked)) cancel $ \inFlight -> do
        waitUntil (doesFileExist (work </> "blocked-write.write-started"))
        BS.readFile (work </> "blocked-write.write-started") >>= check "fixture observed the first in-flight control byte" . (== "{")
        expect "concurrent writer refuses while an earlier frame is in flight" WorkerWriterBusy
          (writeWorkerControl worker (Control (ControlId "contending") (Just (OccurrenceId 0)) Nothing (Steer NextBoundary "must not write")))
        await (wait inFlight) >>= check "blocked private write obeys its actual five-second attempt budget" . (== Left WorkerWriteTimeout)
      state <- observeWorker worker
      check "ambiguous timed-out write stops with confirmed cleanup" (observedWorkerExit state == Just (Left WorkerWriteTimeout) && not (observedCleanupUnproven state))
  let floodEvidence = work </> "stderr-flood.ndjson"
  withCase work "stderr-flood" python [wrapper,native,"stderr-flood",floodEvidence] $ \root _ _ store revision catalogue ->
    withFrontendWorker store "profile" revision (setupFor root catalogue "person-controlled") $ \worker -> do
      waitUntil (observedDiagnosticsTruncated <$> observeWorker worker)
      messages <- workerDiagnostics worker
      check "stderr flood retains a bounded prefix with explicit truncation" (BS.length messages == 65536)
      startWorker worker
      events <- collectPerson worker
      check "stderr draining does not replace or block native runtime events" (any (\event -> case envelopeEvent event of RunCompletedV2 {} -> True; _ -> False) events)
  let hangEvidence = work </> "startup-hang.ndjson"
  withCase work "startup-hang" python [wrapper,native,"startup-hang",hangEvidence] $ \root _ _ store revision catalogue -> do
    expect "whole startup deadline runs even when early owner never awaits preparation" WorkerStartupTimeout
      (withStartingFrontendWorker store "profile" revision (setupFor root catalogue "prompt-source") waitWorker)
    removeFile (work </> "startup-hang.ready")
    pending <- async (withFrontendWorker store "profile" revision (setupFor root catalogue "prompt-source") (const (pure ())))
    waitUntil (doesFileExist (work </> "startup-hang.ready"))
    cancel pending
    outcome <- waitCatch pending
    check "startup cancellation preserves caller identity after joined process cleanup" (case outcome of
      Left failure -> case fromException failure of Just AsyncCancelled -> True; Nothing -> False
      Right _ -> False)
  let capEvidence = work </> "bad-capabilities.ndjson"
  withCase work "bad-capabilities" python [wrapper,native,"bad-capabilities",capEvidence] $ \root _ _ store revision catalogue -> do
    BS.writeFile (work </> "bad-capabilities.armed") BS.empty
    expect "fresh capability query refuses before native session launch" WorkerCapabilityRejected
      (withFrontendWorker store "profile" revision (setupFor root catalogue "prompt-source") (const (pure ())))

registrationChecks :: FilePath -> FilePath -> IO ()
registrationChecks work native = do
  release <- newEmptyMVar
  associated <- newEmptyMVar
  ownerReady <- newEmptyMVar
  owner <- async $ withCase work "store-close" native [] $ \root configuration installed store revision catalogue -> do
    workerOwner <- async $ withFrontendWorker store "profile" revision (setupFor root catalogue "person-controlled") $ \worker -> do
      putMVar associated (configuration, installed, worker)
      takeMVar release
    await (takeMVar ownerReady)
    pure workerOwner
  (configuration, installed, worker) <- await (takeMVar associated)
  putMVar ownerReady ()
  threadDelay 100000
  closeConfiguration installed
  -- Store close stops the process independently of the owner's still-blocked callback.
  waitUntil ((/=Nothing) . observedWorkerExit <$> observeWorker worker)
  expect "store closure fences a retained live worker handle" WorkerClosed (startWorker worker)
  workerOwner <- await (wait owner)
  bracket (installConfiguration configuration >>= right) closeConfiguration (const (check "store released lease only after joined worker cleanup" True))
  putMVar release ()
  void (await (wait workerOwner))

attachmentCloseChecks :: FilePath -> FilePath -> IO ()
attachmentCloseChecks work native = do
  executable <- getExecutablePath
  let command = privateProcess executable ["fixture-wait"]
      cleanup group = terminateProcessGroup 5000000 group `finally` closeGroupPipes group
  withCase work "close-before-attachment" native [] $ \_ _ installed store _ _ -> do
    ready <- newEmptyMVar
    hold <- newEmptyMVar @()
    refused <- newEmptyMVar
    let construct = try @StoreFailure $ withStoreWorker store $ \owner _ _ ->
          (putMVar ready () >> takeMVar hold) `finally` do
            result <- try @StoreFailure (createStoreWorkerGroup owner command)
            case result of
              Left StoreClosed -> putMVar refused True
              Left _ -> putMVar refused False
              Right group -> cleanup group >> putMVar refused False
    bracket (async construct) cancel $ \constructing -> do
      await (takeMVar ready)
      retryStoreCleanup store
      await (takeMVar refused) >>= check "Store close fences attachment during startup cleanup"
      await (wait constructing) >>= check "pre-attachment construction is joined as StoreClosed" . (== Left StoreClosed)
    withCoordinationStore installed $ \fresh -> void (storeIdentity fresh)
    check "pre-attachment close releases the storage slot after joining" True
  withCase work "close-after-attachment" native [] $ \_ _ installed store _ _ -> do
    attached <- newEmptyMVar
    hold <- newEmptyMVar @()
    let construct = try @StoreFailure $ withStoreWorker store $ \owner _ _ -> do
          group <- createStoreWorkerGroup owner command
          putMVar attached (owner, group)
          takeMVar hold
    bracket (async construct) cancel $ \constructing -> do
      (owner, group) <- await (takeMVar attached)
      bracket (pure group) cleanup $ \actual -> do
        before <- tryReadMVar (groupOutcome actual)
        check "attachment race begins with an actual live unprepared group" (case before of Nothing -> True; _ -> False)
        retryStoreCleanup store
        after <- tryReadMVar (groupOutcome actual)
        check "Store close joins the actual startup attachment before release" (case after of Just (Right _) -> True; _ -> False)
        await (wait constructing) >>= check "attached startup construction is joined as StoreClosed" . (== Left StoreClosed)
        late <- try @StoreFailure (createStoreWorkerGroup owner command)
        check "closed startup attachment cannot create a replacement process" (case late of Left StoreClosed -> True; _ -> False)
    withCoordinationStore installed $ \fresh -> void (storeIdentity fresh)
    check "post-attachment close releases the storage slot after native completion" True

draftWorkerChecks :: FilePath -> FilePath -> IO ()
draftWorkerChecks work native = withCase work "draft-worker" native [] $ \_ _ _ store revision catalogue -> do
  let bearer = BS.replicate 32 120
  runTransaction store $ do
    execute "INSERT INTO clients VALUES ('worker-client','r','a',0)" []
    execute "INSERT INTO credentials VALUES ('worker-credential','worker-client',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob (convert (hash bearer :: Digest SHA256))]
    execute "INSERT INTO credential_scopes VALUES ('worker-credential','profile','submit'),('worker-credential','profile','observe')" []
    pure ((), [Invalidation "service.changed" "/v1/capabilities" "fixture"])
  proof <- authenticateCredential store bearer >>= right
  identity <- storeIdentity store
  workflow <- case [ident | (ident, descriptor) <- discoveryEntries catalogue, workflowName descriptor == "prompt-source"] of
    [ident] -> pure ident
    _ -> error "native workflow not discovered"
  let key suffix = storeAuthorityEpoch identity <> "." <> T.replicate 22 "n" <> suffix
      json = BL.toStrict . encode
  view <- createDraft store proof (key "create") (json (object ["workflowId" .= workflow, "descriptorRevision" .= discoveryRevision catalogue,
    "profileId" .= ("profile"::Text), "profileRevision" .= revision])) >>= right
  _ <- changeDraftInput store proof (draftId view) (key "input") (Just ("\"" <> draftRevision view <> "\""))
    (json (object ["operation" .= ("set-input"::Text), "input" .= LiteralValue "input" "real draft\r\n雪"])) >>= right
  current <- readDraft store proof (draftId view) >>= right
  (setup, bytes) <- assembleDraft store proof (draftId current) >>= right
  check "worker consumes actual WM-011 shared setup/frame" (decodeFrontendSetupRequest bytes == Right setup)
  withFrontendWorker store "profile" revision setup $ \worker -> do
    prepared <- workerPrepared worker
    check "real prepared input evidence matches native literal contract" (preparedInputs prepared == [FrontendPreparedInput "input"
      (toInteger (BS.length (frontendLiteralBytes DescriptorPrompt "real draft\r\n雪")))
      (T.pack (show (hash (frontendLiteralBytes DescriptorPrompt "real draft\r\n雪") :: Digest SHA256)))])
    startWorker worker
    events <- collectPerson worker
    check "real draft worker completes with native terminal evidence" (any (\event -> case envelopeEvent event of RunCompletedV2 {} -> True; _ -> False) events)

saturationChecks :: FilePath -> FilePath -> IO ()
saturationChecks work native = withCase work "worker-capacity" native [] $ \root _ _ store revision catalogue -> do
  release <- newEmptyMVar
  ready <- newEmptyMVar
  let setup = setupFor root catalogue "person-controlled"
  owners <- forM [1..16::Int] $ \_ -> do
    thread <- async (withFrontendWorker store "profile" revision setup (\worker -> putMVar ready worker >> readMVar release))
    worker <- await (takeMVar ready)
    pure (thread, worker)
  expect "seventeenth live registration refuses without fake admission rows" WorkerUnavailable (withFrontendWorker store "profile" revision setup (const (pure ())))
  case owners of
    (_, worker) : _ -> closeWorker worker
    [] -> error "worker capacity fixture empty"
  withFrontendWorker store "profile" revision setup $ \worker -> discardWorker worker >> void (waitWorker worker)
  check "confirmed cleanup releases registration capacity" True
  forM_ owners (closeWorker . snd)
  putMVar release ()
  mapM_ (await . wait . fst) owners

cleanupChecks :: FilePath -> FilePath -> IO ()
cleanupChecks work native = do
  executable <- getExecutablePath
  bracket (createProcessGroup (privateProcess executable ["fixture-wait"])) closeGroupPipes $ \group -> do
    armTermFailure
    terminateProcessGroup 1000 group
    termFailureFired >>= check "project-owned TERM failure was actually injected" . (== 1)
    outcome <- tryReadMVar (groupOutcome group)
    check "confirmed final cleanup recovers an earlier TERM error" (case outcome of Just (Right _) -> True; _ -> False)
  withCase work "cleanup-resolution" native [] $ \_ _ installed store _ _ -> do
    retired <- withStoreWorker store (\owner _ _ -> pure owner)
    stale <- try @StoreFailure (createStoreWorkerGroup retired (privateProcess executable ["fixture-exit"]))
    check "released registration token cannot create a process" (case stale of Left StoreClosed -> True; _ -> False)
    original <- newEmptyMVar
    unresolved <- try @StoreFailure $ withStoreWorker store $ \owner _ _ -> do
      group <- createStoreWorkerGroup owner (privateProcess executable ["fixture-wait"])
      putMVar original group
      -- Returning without completed cleanup must retain the actual group, never its PID.
      pure ()
    check "unpublished native completion retains worker ownership" (case unresolved of Left StoreCleanupUnproven -> True; _ -> False)
    group <- takeMVar original
    before <- tryReadMVar (groupOutcome group)
    check "unresolved fixture has actual outstanding Runtime completion" (case before of Nothing -> True; _ -> False)
    refused <- try @StoreFailure (withStoreWorker store (\_ _ _ -> pure ()))
    check "unproven cleanup fences new worker registrations" (case refused of Left _ -> True; _ -> False)
    retryStoreCleanup store
    waitProcessGroup group >>= check "retry resolves only the retained original process owner" . (/= ExitSuccess)
    withCoordinationStore installed $ \fresh -> void (storeIdentity fresh)
    check "confirmed original-token resolution releases the storage slot" True
  let directory = work </> "cleanup-failure-child"
  createDirectory directory
  bracket (createProcessGroup (privateProcess executable ["cleanup-failure",directory,native]))
    (\group -> terminateProcessGroup 5000000 group >> closeGroupPipes group) $ \group -> do
      output <- maybe (error "child stdout unavailable") pure (groupOutput group)
      errors <- maybe (error "child stderr unavailable") pure (groupErrors group)
      retainCleanupChildOutput directory $ do
        result <- await (waitProcessGroup group)
        bytes <- BS.hGetSome output 65536
        diagnostic <- BS.hGetSome errors 65536
        pure (result, bytes, diagnostic)

retainCleanupChildOutput :: FilePath -> IO (ExitCode, BS.ByteString, BS.ByteString) -> IO ()
retainCleanupChildOutput directory observe = do
  (result, bytes, diagnostic) <- observe
  written <- try @SomeException $ do
    BS.writeFile (directory </> "stdout.log") bytes
    BS.writeFile (directory </> "stderr.log") diagnostic
  let label = "isolated published-failure fixture completed its checks"
  asserted <- try @SomeException $
    unless (result == ExitSuccess && "PASS retained published cleanup failure" `BS.isInfixOf` bytes && BS.null diagnostic) (check label False)
  case (asserted, written) of
    (Left primary, Left secondary) -> do
      -- Reporting an evidence error must not replace the original child refusal.
      void (try @SomeException (hPutStrLn stderr ("worker child evidence write failed: " <> show secondary)))
      throwIO primary
    (Left primary, Right ()) -> throwIO primary
    (Right (), Left failure) -> throwIO failure
    (Right (), Right ()) -> check label True

cleanupEvidenceDataChecks :: FilePath -> IO ()
cleanupEvidenceDataChecks work = do
  createDirectory work
  let marker = "PASS retained published cleanup failure\n"
      refusal failure = "FAIL isolated published-failure fixture completed its checks" `T.isPrefixOf` T.pack (show failure)
      exact directory bytes diagnostic = do
        actual <- BS.readFile (directory </> "stdout.log")
        errors <- BS.readFile (directory </> "stderr.log")
        check "child evidence retains exact stdout and stderr bytes" (actual == bytes && errors == diagnostic)
  forM_ [("positive", ExitSuccess, marker, BS.empty, True),
         ("nonzero", ExitFailure 1, marker, BS.empty, False),
         ("missing-marker", ExitSuccess, "not completed\n", BS.empty, False),
         ("nonempty-stderr", ExitSuccess, marker, BS.pack [255,0,10,10], False),
         ("nontext-newlines", ExitSuccess, BS.pack [255,0] <> marker <> "\n\n", BS.empty, True),
         ("bounded-buffer", ExitSuccess, BS.replicate (65536 - BS.length marker) 255 <> marker, BS.empty, True)] $
    \(name, result, bytes, diagnostic, success) -> do
      let directory = work </> name
      createDirectory directory
      outcome <- try @SomeException (retainCleanupChildOutput directory (pure (result, bytes, diagnostic)))
      exact directory bytes diagnostic
      check ("child evidence outcome: " <> name) (case outcome of Right () -> success; Left failure -> not success && refusal failure)
  forM_ ["stdout.log", "stderr.log"] $ \blocked -> forM_ [True, False] $ \success -> do
    let directory = work </> (blocked <> if success then "-success" else "-refusal")
    createDirectory directory
    createDirectory (directory </> blocked)
    outcome <- try @SomeException (retainCleanupChildOutput directory (pure (if success then ExitSuccess else ExitFailure 1, marker, BS.empty)))
    check ("evidence-write failure cannot pass or erase refusal: " <> blocked) (case outcome of
      Left failure -> if success
        then case fromException failure :: Maybe IOException of Just _ -> True; Nothing -> False
        else refusal failure
      Right () -> False)
    stdoutWritten <- doesFileExist (directory </> "stdout.log")
    if blocked == "stderr.log" then do
      check "stdout survives subsequent stderr write failure" stdoutWritten
      BS.readFile (directory </> "stdout.log") >>= check "partial retained stdout remains exact" . (== marker)
    else doesFileExist (directory </> "stderr.log") >>= check "failed first write does not invent stderr evidence" . not
  forM_ ["wait-incomplete", "read-incomplete"] $ \name -> do
    let directory = work </> name
    createDirectory directory
    outcome <- try @IOException (retainCleanupChildOutput directory (throwIO (userError name)))
    check "uncompleted observation propagates unchanged" (case outcome of Left failure -> T.pack name `T.isInfixOf` T.pack (show failure); Right () -> False)
    forM_ ["stdout.log", "stderr.log"] $ \file ->
      doesFileExist (directory </> file) >>= check "uncompleted observation emits no invented bytes" . not
  putStrLn "PASS cleanup child evidence data-only checks"

cleanupFailureChild :: FilePath -> FilePath -> IO ()
cleanupFailureChild work native = do
  executable <- getExecutablePath
  let root = work </> "quarantine"
  createDirectory root
  setFileMode root 0o700
  config <- writeConfiguration work "quarantine" native [] [] >>= load
  bracket (installConfiguration config >>= right) closeConfiguration $ \installed -> do
    ended <- try @StoreFailure $ withCoordinationStore installed $ \store -> do
      failed <- try @IOException $ withStoreWorker store $ \owner _ _ -> do
        group <- createStoreWorkerGroup owner (privateProcess executable ["fixture-exit"])
        waitProcessGroup group >>= check "cleanup-fault positive control reaped actual child" . (== ExitSuccess)
        _ <- swapMVar (groupOutcome group) (Left (userError "synthetic owner completion failure"))
        propagated <- try @IOException (terminateProcessGroup 1000 group)
        check "Runtime propagates published cleanup failure" (case propagated of Left _ -> True; _ -> False)
        throwIO (userError "primary callback failure")
      check "primary callback failure survives unproven cleanup" (case failed of Left errorValue -> "primary callback failure" `T.isInfixOf` T.pack (show errorValue); _ -> False)
      retry <- try @StoreFailure (retryStoreCleanup store)
      check "published Left cannot be cleared to release ownership" (case retry of Left StoreCleanupUnproven -> True; _ -> False)
    check "Store close does not claim successful unproven completion" (case ended of Left StoreCleanupUnproven -> True; _ -> False)
    same <- try @Diagnostic (withCoordinationStore installed (const (pure ())))
    check "outer bracket retains the occupied configuration storage slot" (case same of Left InvalidConfiguration -> True; _ -> False)
    second <- installConfiguration config
    check "outer bracket retains the exclusive lease after failed close" (case second of Left InvalidConfiguration -> True; _ -> False)
    putStrLn "PASS retained published cleanup failure"

privateProcess :: FilePath -> [String] -> CreateProcess
privateProcess executable arguments = (proc executable arguments) {std_in=CreatePipe,std_out=CreatePipe,std_err=CreatePipe}

reservedEnvironmentChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
reservedEnvironmentChecks work source native python = do
  let evidence = work </> "reserved-environment.ndjson"
      prefix = [source </> "manager/test/worker_fixture.py",native,"normal",evidence]
  forM_ (zip [0..] frontendOwnedEnvironment) $ \(index,name) -> forM_ ["", "1"] $ \value -> do
    let label = "reserved-" <> show (index::Int) <> if null value then "-empty" else "-set"
    path <- writeConfiguration work label python prefix [(name,value)]
    result <- loadConfiguration (const (Right ()))  exactPreparedTarget (const False) path
    check ("reserved environment refuses before launch: " <> name) (case result of Left InvalidConfiguration -> True; _ -> False)
  doesFileExist evidence >>= check "reserved environment negatives launched no capability process" . not

foreign import ccall unsafe "worker_arm_term_failure"
  armTermFailure :: IO ()
foreign import ccall unsafe "worker_term_failure_fired"
  termFailureFired :: IO CInt

watchdogSurvivalChecks :: FilePath -> FilePath -> IO ()
watchdogSurvivalChecks work native = withCase work "watchdog-survival" native [] $ \root _ _ store revision catalogue ->
  withStartingFrontendWorker store "profile" revision (setupFor root catalogue "prompt-source") $ \worker -> do
    waitUntil ((==WorkerPrepared) . observedWorkerPhase <$> observeWorker worker)
    observed <- getMonotonicTimeNSec
    -- Starting after actual preparation makes this strictly later than the startup budget.
    threadDelay 31000000
    checked <- getMonotonicTimeNSec
    status <- observeWorker worker
    check "survival sample is more than thirty seconds after actual prepared observation" (checked-observed>=31000000000)
    check "successful preparation disarms startup watchdog independently of caller await"
      (observedWorkerPhase status==WorkerPrepared && observedWorkerExit status==Nothing && not(observedCleanupUnproven status))
    discardWorker worker
    waitWorker worker >>= check "surviving original prepared worker discards and joins normally" . (==ExitSuccess)

-- Native PID is a read-only negative witness, never signalling or replacement ownership.
backpressureClose :: FilePath -> FrontendWorker -> IO ()
backpressureClose native worker = do
  prepared <- workerPrepared worker
  let pieces=T.splitOn "-" (runIdText(preparedRunId prepared))
  pid <- case pieces of ["native",number,_] | T.all(\c->c>='0' && c<='9')number -> pure(T.unpack number);_->error "native fixture identity"
  let observation :: (ExitCode,String,String) -> Either (ExitCode,String,String) Bool
      observation result@(code,output,diagnostic)
        | not(null diagnostic) = Left result
        | code==ExitSuccess && not(null(words output)) = Right(T.pack native `T.isInfixOf` T.pack output)
        | code==ExitFailure 1 && null(words output) = Right False
        | otherwise = Left result
      present=do
        result<-readProcessWithExitCode "ps" ["-p",pid,"-o","pid=,command="] ""
        either (error . ("process observation failed: "<>) . show) pure (observation result)
  check "process observer distinguishes successful presence from clean no-match"
    (observation(ExitSuccess,native,"")==Right True && observation(ExitFailure 1,"","")==Right False)
  forM_ [("unexpected exit",(ExitFailure 2,"","")),
         ("failed no-match",(ExitFailure 1,"","observer error")),
         ("empty success",(ExitSuccess,"","")),
         ("success diagnostics",(ExitSuccess,native,"observer warning"))] $ \(label,result)->
    check ("process observer refuses "<>label) (case observation result of Left _->True;_->False)
  present >>= check "original inner worker is observable before backpressure close"
  startWorker worker
  replicateM_ 80 $ writeWorkerControl worker (Control (ControlId "shutdown-backpressure") (Just (OccurrenceId 999)) Nothing (Steer NextBoundary "queued fixture"))
  waitUntil ((==32) . observedQueuedFrames <$> observeWorker worker)
  closeWorker worker
  status <- observeWorker worker
  check "shutdown does not deadlock behind a full event queue"
    (observedWorkerPhase status==WorkerReleased && observedWorkerExit status==Just(Left WorkerClosed) && not(observedCleanupUnproven status))
  present >>= check "confirmed outer cleanup leaves no live native inner worker" . not

terminationChecks :: FilePath -> FilePath -> IO ()
terminationChecks _ _ = do
  executable<-getExecutablePath
  let fixture action=bracket (createProcessGroup(privateProcess executable ["fixture-term-wait"]))
        (\group->terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group->do
          output<-maybe(error "termination stdout")pure(groupOutput group)
          input<-maybe(error "termination stdin")pure(groupInput group)
          await(hGetLine output)>>=check "termination fixture ready" . (=="ready")
          action group output input
      release input=hPutStrLn input "release" >> hFlush input
  forM_ [False,True] $ \ioFailure -> fixture $ \group output input -> do
    caller<-async(terminateProcessGroup 2000000 group)
    await(hGetLine output)>>=check "original TERM reaches child before caller interruption" . (=="term")
    if ioFailure then throwTo(asyncThreadId caller)(userError "original caller IO interruption")
      else throwTo(asyncThreadId caller) UserInterrupt
    sent<-try @IOException(release input)
    case sent of Left _->putStrLn "controlled release pipe already closed";Right()->pure()
    outcome<-await(waitCatch caller)
    check "caller exception is preserved after joined offered grace" (case outcome of
      Left failure | ioFailure -> case fromException failure of Just value->"original caller IO interruption" `T.isInfixOf` T.pack(show(value::IOException));Nothing->False
      Left failure -> case fromException failure of Just UserInterrupt->True;_->False
      Right()->False)
    waitProcessGroup group >>=check "caller interruption does not prematurely KILL cooperative child" . (==ExitSuccess)
  fixture $ \group output input -> do
    caller<-async(uninterruptibleMask_(terminateProcessGroup 100000 group))
    await(hGetLine output)>>=check "uninterruptibly masked caller still sends TERM" . (=="term")
    completed<-timeout 2000000(waitCatch caller)
    case completed of
      Nothing->do
        putStrLn "FAIL inherited masking suppressed native termination deadline"
        putStrLn "NEGATIVE TEARDOWN ONLY: releasing original child pipe"
        release input
        void(await(waitCatch caller))
        error "uninterruptible termination deadline regression"
      Just result->either throwIO pure result
    waitProcessGroup group >>=check "genuine unmask preserves final KILL deadline" . (/=ExitSuccess)
  fixture $ \group output input -> do
    first<-async(terminateProcessGroup 2000000 group)
    second<-async(terminateProcessGroup 2000000 group)
    void(await(hGetLine output))
    release input
    await(wait first)
    await(wait second)
    terminateProcessGroup 2000000 group
    waitProcessGroup group >>=check "ordinary completion and repeated callers join original group" . (==ExitSuccess)
