{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified Agentic.Manager.Test.AcceptanceAudit as Audit
import Control.Concurrent (throwTo)
import Control.Exception (AsyncException (UserInterrupt))
import Agentic.Manager.Admission
import Agentic.Manager.Admission.Policy
import Agentic.Manager.Authorization
import Agentic.Manager.Commands (readCommand)
import Agentic.Manager.Configuration
import Agentic.Manager.Drafts
import Agentic.Manager.Profile hiding (StaleRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Draft
import Agentic.Manager.Store
import qualified Agentic.Manager.Worker as Worker
import Agentic.Runtime (WorkflowDescriptor (..), FrontendPrepared (..), RunId (..), createProcessGroup, terminateProcessGroup, closeGroupPipes, groupOutput, groupErrors, waitProcessGroup)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..), async, asyncThreadId, cancel, waitCatch, wait, poll)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, readMVar, tryReadMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar, check)
import Control.DeepSeq (NFData)
import Control.Exception (SomeException, bracket, try, fromException, finally, throwIO, uninterruptibleMask_)
import Control.Monad (forM, forM_, unless, void, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), eitherDecodeStrict', object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (convert)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.List (find, sortOn)
import Data.Foldable (toList)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, removeFile)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (proc, CreateProcess (cwd, env, std_in, std_out, std_err), StdStream (NoStream, CreatePipe))
import GHC.Conc (getNumCapabilities, threadStatus, ThreadStatus (..), BlockReason (..))
import Foreign.C.Types (CInt (..))
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Test.QuickCheck hiding (label, output)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["policy-only"] -> policyChecks
    ["shutdown-only",work] -> shutdownChecks work
    ["shutdown-native",work,native] -> shutdownNativeChecks work native
    ["restart-native",work,native] -> restartNativeChecks work native
    ["restart-interruption",work,native] -> restartInterruptionChecks work native
    ["static-occupancy"] -> staticOccupancyCheck
    ["interrupted-acceptance",work,native] -> interruptedAcceptanceChecks work native
    ["active-retry",work,native] -> activeRetryChecks work native
    ["completion-failure",work,native] -> completionFailureChild work native
    [work,native,source,python] -> do
      policyChecks
      activeRetryChecks work native
      lifecycleChecks work native
      expiryChecks work native
      rollbackChecks work native
      ordinalChecks work native
      invalidationRollbackChecks work native
      reloadChecks work native
      captureChecks work native
      acceptedAuthorityChecks work native
      cleanupPublicationChecks work native
      reopenChecks work native
      reservationBoundaryChecks work native
      saturationChecks work native
      completionFailureChecks work native
      preparingChecks work native source python
      loanCancellationChecks work native
      commitDeadlineChecks work native
      storeClosureChecks work native
      putStrLn "PASS manager admission and native reservation lifetimes"
    _ -> error "usage: manager-admission-check PRIVATE_DIRECTORY NATIVE_RUNNER SOURCE PYTHON"

assertion :: String -> Bool -> IO ()
assertion name valid=unless valid(error("FAIL "<>name))>>putStrLn("PASS "<>name)
right :: Show e => Either e a -> IO a
right=either(error.show)pure
await :: IO a -> IO a
await action=timeout 20000000 action >>= maybe(error "admission rendezvous timed out")pure
mutate :: NFData a => CoordinationStore -> Transaction a -> IO a
mutate owner action=runTransaction owner $ do value<-action;pure(value,[Invalidation "service.changed" "/v1/capabilities" "fixture"])
number :: CoordinationStore -> Text -> IO Int64
number owner sql=runRead owner $ do rows<-query sql [];case rows of [[SQL.SQLInteger value]]->pure value;_->refuseTransaction StoreIntegrity
scalarText :: CoordinationStore -> Text -> IO Text
scalarText owner sql=runRead owner $ do rows<-query sql [];case rows of [[SQL.SQLText value]]->pure value;_->refuseTransaction StoreIntegrity
key :: CoordinationStore -> Text -> IO Text
key owner suffix=do identity<-storeIdentity owner;pure(storeAuthorityEpoch identity<>"."<>T.replicate 22 "n"<>suffix)
etag :: DraftView -> Maybe Text
etag view=Just("\""<>draftRevision view<>"\"")
body :: Text -> BS.ByteString
body operationName'=encoded(object["operation" .= operationName'])

restartInterruptionChecks :: FilePath -> FilePath -> IO ()
restartInterruptionChecks work native = do
  withFixture work native "restore-interruption" 1 [] (const(pure()))
  let root=work </> "restore-interruption"
      backup=work </> "interrupted-backup"
  createDirectory backup
  setFileMode backup 0o700
  config <- loadConfiguration (const(Right())) exactPreparedTarget (const False) (work </> "restore-interruption.json") >>= right
  bracket (installConfiguration config >>= right) closeConfiguration $ \installed -> do
    backupCoordinationStore installed backup
    Audit.withReviewAudit "restore-marker" $ \audit -> do
      original <- async(restoreCoordinationStore installed backup)
      (do
        originalThread <- Audit.waitReviewed audit
        assertion "restore marker belongs to original retained Async" (originalThread==asyncThreadId original)
        doesFileExist(root </> "restore-in-progress") >>= assertion "restore interruption barrier follows durable marker publication"
        cancel original
        outcome <- waitCatch original
        assertion "restore preserves original AsyncCancelled after original join" (case outcome of Left failure -> fromException failure==Just AsyncCancelled; _ -> False)
        doesFileExist(root </> "restore-in-progress") >>= assertion "cancelled restore retains durable in-progress fence"
        refused <- try @StoreFailure(withCoordinationStore installed (const(pure())))
        assertion "interrupted restore refuses ordinary startup without fabricated success" (refused==Left StoreUnavailable)) `finally` cancel original

restartNativeChecks :: FilePath -> FilePath -> IO ()
restartNativeChecks work native = do
  (originalIdentity,queuedA,queuedB,oldKey,oldReceipt) <- withFixture work native "restart" 2 [("a",["a"]),("b",["b"])] $ \fixture@(Fixture _ _ owner _ _) -> withAdmission owner $ \controller -> do
    draftA <- newDraft fixture 0 "a" "restart_a"
    draftB <- newDraft fixture 0 "b" "restart_b"
    (nonce,receipt) <- enqueue controller fixture 0 draftA "restart_a"
    void(enqueue controller fixture 0 draftB "restart_b")
    identity <- storeIdentity owner
    pure(identity,draftA,draftB,nonce,receipt)
  let root=work </> "restart"
      backup=work </> "backup"
  createDirectory backup
  setFileMode backup 0o700
  config <- loadConfiguration (const(Right())) exactPreparedTarget (const False) (work </> "restart.json") >>= right
  bracket (installConfiguration config >>= right) closeConfiguration $ \installed -> do
    -- Discovery belongs to the newly installed registry, never the previous lifetime.
    (_,public) <- configurationSnapshot installed >>= right
    catalogues <- forM public $ \profile -> do
      discovered <- probeConfiguredProfile installed(publicId profile)(publicRevision profile) >>= right
      pure(publicId profile,discovered)
    backupCoordinationStore installed backup
    withCoordinationStore installed $ \owner -> do
      currentIdentity <- storeIdentity owner
      assertion "ordinary restart preserves epoch/stream and changes process generation" (storeAuthorityEpoch currentIdentity==storeAuthorityEpoch originalIdentity && storeStreamId currentIdentity==storeStreamId originalIdentity && storeProcessGeneration currentIdentity/=storeProcessGeneration originalIdentity)
      proof <- authenticateCredential owner (BS.replicate 32 1) >>= right
      restoredA <- readDraft owner proof(draftId queuedA) >>= right
      restoredB <- readDraft owner proof(draftId queuedB) >>= right
      assertion "durable FIFO queue order survives without recreating start consent" (draftPosition restoredA==Just 1 && draftPosition restoredB==Just 2)
      beforeReconcile <- number owner "SELECT count(*) FROM invalidations"
      withAdmission owner $ \controller -> do
        number owner "SELECT count(*) FROM requests r JOIN invalidations i ON i.kind='request.changed' AND i.resource_uri='/v1/requests/'||r.id AND i.revision=r.revision" >>= assertion "reconciled queue revisions have matching request invalidations" . (==2)
        afterReconcile <- number owner "SELECT count(*) FROM invalidations"
        assertion "queue reconciliation emits exactly its changed request events" (afterReconcile==beforeReconcile+2)
        void(reconcileDrafts owner)
        number owner "SELECT count(*) FROM invalidations" >>= assertion "unchanged validated associations emit no extra events or revisions" . (==afterReconcile)
        replayed <- enqueueRequest controller proof(draftId queuedA)oldKey(etag queuedA)(body "enqueue") >>= right
        assertion "ordinary restart retains exact enqueue receipt without a new command" (replayed==oldReceipt)
        liveA <- admit controller
        reviewA <- await(awaitReview liveA) >>= right
        liveB <- admit controller
        reviewB <- await(awaitReview liveB) >>= right
        assertion "revalidated durable queue prepares fresh native workers in FIFO order" (reviewRequest reviewA==draftId queuedA && reviewRequest reviewB==draftId queuedB)
      number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>= assertion "original newly prepared owners join before offline restore" . (==0)
      mutate owner(execute "INSERT INTO restoration_quarantine VALUES ('lost_after_backup',0,'[[\"operator\",\"b\"]]')" [])
    restoreCoordinationStore installed backup
    withCoordinationStore installed $ \owner -> do
      restoredIdentity <- storeIdentity owner
      assertion "offline restoration rotates epoch and stream" (storeAuthorityEpoch restoredIdentity/=storeAuthorityEpoch originalIdentity && storeStreamId restoredIdentity/=storeStreamId originalIdentity)
      staleCredential <- authenticateCredential owner (BS.replicate 32 1)
      assertion "all restored credential authority is revoked" (case staleCredential of Left Unauthenticated -> True; _ -> False)
      mutate owner $ do
        execute "INSERT INTO credentials VALUES ('replacement','client_1',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob(convert(hash(BS.replicate 32 33)::Digest SHA256))]
        forM_ ["a","b"::Text] $ \profile -> forM_ ["submit","observe","control"::Text] $ \scope -> execute "INSERT INTO credential_scopes VALUES ('replacement',?,?)" [SQL.SQLText profile,SQL.SQLText scope]
      proof <- authenticateCredential owner (BS.replicate 32 33) >>= right
      let fixture=Fixture root installed owner catalogues [proof]
      withAdmission owner $ \controller -> do
        refused <- enqueueRequest controller proof(draftId queuedA)oldKey(etag queuedA)(body "enqueue")
        assertion "old mutation key refuses even with replacement credentials" (refused==Left AuthorityChanged)
        blocked <- newDraft fixture 0 "b" "blocked_after_restore"
        void(enqueue controller fixture 0 blocked "blocked_after_restore")
        admitOldest controller >>= right >>= assertion "affected restored resource stays quarantined" . maybe True (const False)
        eligible <- newDraft fixture 0 "a" "eligible_after_restore"
        void(enqueue controller fixture 0 eligible "eligible_after_restore")
        live <- admit controller
        review <- await(awaitReview live) >>= right
        assertion "genuinely new consented disjoint work can prepare after restoration" (reviewRequest review==draftId eligible)
        number owner "SELECT count(*) FROM start_intents" >>= assertion "restart and restoration fabricate no approval or native start" . (==0)
    restoreCoordinationStore installed backup
    withCoordinationStore installed $ \owner -> do
      occupancy <- runRead owner reservationOccupancy
      assertion "repeated restore retains original affected-resource and slot facts" (occupancy==[("lost_after_backup",0,[("operator","b")])])
  restartBindingChecks work native
  restartUnavailableChecks work native
  putStrLn "PASS ordinary native restart and fenced offline restoration"

restartBindingChecks :: FilePath -> FilePath -> IO ()
restartBindingChecks work native = do
  original <- withFixture work native "restart-changed" 1 [("a",["a"])] $ \fixture@(Fixture _ _ _ catalogues _) -> do
    let catalogue=case lookup "a" catalogues of Just value->value;Nothing->error "missing catalogue"
    case discoveryEntries catalogue of
      (_,descriptor):_ -> assertion "full native descriptor changes invalidate declared restart equality"
        (restartBinding catalogue descriptor/=restartBinding catalogue (descriptor {workflowResultCode=String "different"}))
      [] -> error "missing descriptor"
    withAdmission (case fixture of Fixture _ _ owner _ _->owner) $ \controller -> do
      draft <- newDraft fixture 0 "a" "changed"
      void(enqueue controller fixture 0 draft "changed")
      pure draft
  let path=work </> "restart-changed.json"
  bytes <- BS.readFile path
  let changed=T.replace "\"resourceKeys\":[\"a\"]" "\"resourceKeys\":[\"changed\"]" (TE.decodeUtf8 bytes)
  assertion "changed-configuration fixture changes actual declared resources" (TE.encodeUtf8 changed/=bytes)
  BS.writeFile path(TE.encodeUtf8 changed)
  config <- loadConfiguration (const(Right())) exactPreparedTarget (const False) path >>= right
  bracket (installConfiguration config >>= right) closeConfiguration $ \installed -> do
    (_,public) <- configurationSnapshot installed >>= right
    forM_ public $ \profile -> void(probeConfiguredProfile installed(publicId profile)(publicRevision profile) >>= right)
    withCoordinationStore installed $ \owner -> withAdmission owner $ \controller -> do
      admitOldest controller >>= right >>= assertion "changed declared configuration cannot restore queue eligibility" . maybe True (const False)
      scalarText owner "SELECT profile_revision FROM requests" >>= assertion "failed equality never rotates historical request authority" . (==draftProfileRevision original)
      number owner "SELECT count(*) FROM reservations" >>= assertion "changed restart creates no worker reservation" . (==0)

restartUnavailableChecks :: FilePath -> FilePath -> IO ()
restartUnavailableChecks work native = forM_ ["removed","quarantined","failed-discovery"] $ \mode -> do
  let name="restart-"<>mode
      path=work </> name<>".json"
      root=work </> name
      retained owner = runRead owner $ do
        rows <- query "SELECT id,revision,profile_revision,descriptor_revision,phase,coalesce(queue_generation,'') FROM requests WHERE profile_id='a' ORDER BY id" []
        forM rows $ \row -> forM row $ \value -> case value of SQL.SQLText textValue -> pure textValue; _ -> refuseTransaction StoreIntegrity
  original <- withFixture work native name 1 [("a",["a"]),("b",["b"])] $ \fixture@(Fixture _ _ owner _ _) -> withAdmission owner $ \controller -> do
    void(newDraft fixture 0 "a" "inert_draft")
    draft <- newDraft fixture 0 "a" "inert_queue"
    void(enqueue controller fixture 0 draft "inert_queue")
    retained owner
  checker <- getExecutablePath
  document <- BS.readFile path >>= either(error . show)pure . eitherDecodeStrict'
  revised <- case document of
    Object fields -> case (KM.lookup "profiles" fields,KM.lookup "runners" fields) of
      (Just (Array profiles),Just (Array runners)) -> do
        let changed (Object profile) | KM.lookup "id" profile==Just(String "a") = case mode of
              "removed" -> []
              "quarantined" -> [Object(KM.insert "quarantined" (Bool True) profile)]
              _ -> [Object(KM.insert "runner" (String "unavailable") profile)]
            changed value=[value]
            unavailable=[object["alias" .= ("unavailable"::Text),"executable" .= checker,"prefix" .= ([]::[Text])] | mode=="failed-discovery"]
        pure(Object(KM.insert "runners" (toJSON(toList runners<>unavailable))(KM.insert "profiles" (toJSON(concatMap changed(toList profiles))) fields)))
      _ -> error "missing fixture profiles"
    _ -> error "invalid fixture configuration"
  BS.writeFile path(encoded revised)
  config <- loadConfiguration (const(Right())) exactPreparedTarget (const False) path >>= right
  bracket (installConfiguration config >>= right) closeConfiguration $ \installed -> do
    (_,public) <- configurationSnapshot installed >>= right
    catalogues <- fmap concat $ forM public $ \profile -> do
      discovered <- probeConfiguredProfile installed(publicId profile)(publicRevision profile)
      case discovered of
        Right catalogue -> pure[(publicId profile,catalogue)]
        Left failure -> assertion (mode<>" has unavailable A discovery") (publicId profile=="a" && failure==(if mode=="quarantined" then Quarantined else ProcessFailure)) >> pure[]
    assertion (mode<>" retains usable B only") (map fst catalogues==["b"])
    escaped <- withCoordinationStore installed $ \owner -> do
      proof <- authenticateCredential owner(BS.replicate 32 1) >>= right
      when(mode=="removed") $ do
        entered <- newEmptyMVar
        release <- newEmptyMVar
        withCommitDeadline owner (putMVar entered () >> readMVar release >> pure 0) 1 $ \guard ->
          bracket (async(runTransaction owner(enforceCommitDeadline guard >> pure((),[])))) (\task -> putMVar release () >> await(wait task)) $ \_ -> do
            await(takeMVar entered)
            busy <- try @StoreFailure(reconcileDrafts owner)
            assertion "restart reconciliation preserves fail-fast StoreBusy" (case busy of Left StoreBusy -> True; _ -> False)
      before <- number owner "SELECT count(*) FROM invalidations"
      withAdmission owner $ \controller -> do
        retained owner >>= assertion (mode<>" leaves historical A revisions and queue association inert") . (==original)
        number owner "SELECT count(*) FROM invalidations" >>= assertion (mode<>" adds no events for unavailable historical selections") . (==before)
        let fixture=Fixture root installed owner catalogues [proof]
        draft <- newDraft fixture 0 "b" "usable_b"
        void(enqueue controller fixture 0 draft "usable_b")
        live <- admit controller
        review <- await(awaitReview live) >>= right
        assertion (mode<>" permits actual fresh B native preparation") (reviewRequest review==draftId draft)
      number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>= assertion (mode<>" joins original B owner without releasing historical authority") . (==0)
      closeConfiguration installed
      unavailable <- try @CommandFailure(withAdmission owner(const(pure())))
      assertion (mode<>" still propagates genuine configuration-access failure") (unavailable==Left StorageUnavailable)
      pure owner
    closed <- try @StoreFailure(reconcileDrafts escaped)
    assertion (mode<>" still propagates original StoreClosed") (case closed of Left StoreClosed -> True; _ -> False)

-- These fixtures retain actual Store registrations but never construct a process.
shutdownChecks :: FilePath -> IO ()
shutdownChecks work = do
  native <- getExecutablePath
  let fixture name action = withFixture work native name 1 [] $ \(Fixture _ _ owner _ _) -> action owner
      clock = MonotonicClock (pure 10) (\_ -> atomically(check False))
  fixture "shutdown-empty" $ \owner -> do
    withAdmissionClock clock owner $ \controller -> do
      result <- await(closeAdmission controller 20)
      assertion "empty healthy drain completes without invented cancellation" (result==ShutdownResult False(Right()))
      refusal <- admitOldest controller
      assertion "drain fences new admission" (case refusal of Left StorageUnavailable -> True; _ -> False)
      repeated <- shutdownAdmission controller CancelNow
      assertion "completed shutdown result is immutable" (repeated==result)
    withAdmissionClock clock owner $ \controller -> do
      withStoreWorker owner(\_ _ _ -> pure())
      result <- await(closeAdmission controller 20)
      assertion "healthy sequential Admission scopes reuse the same open Store" (result==ShutdownResult False(Right()))
  fixture "shutdown-expired" $ \owner -> withAdmissionClock clock owner $ \controller -> do
    result <- await(closeAdmission controller 10)
    assertion "expired drain remains separate from confirmed cleanup" (result==ShutdownResult True(Right()))
    repeated <- closeAdmission controller 100
    assertion "later drain cannot erase original deadline expiry" (repeated==result)
  fixture "shutdown-busy" $ \owner -> withAdmission owner $ \controller -> do
    ready <- forM [1..16::Int] $ \_ -> do
      entered <- newEmptyMVar
      stopped <- newEmptyMVar
      release <- newEmptyMVar
      task <- async $ try @StoreFailure $ withStoreWorker owner $ \_ _ _ ->
        (putMVar entered () >> atomically(check False)) `finally`
          uninterruptibleMask_ (putMVar stopped () >> readMVar release)
      await(takeMVar entered)
      pure(task,stopped,release)
    held <- newEmptyMVar
    releaseSQL <- newEmptyMVar
    let holderClock = putMVar held () >> readMVar releaseSQL >> pure 0
        releaseAll = do
          void(tryPutMVar releaseSQL ())
          forM_ ready $ \(_,_,release) -> void(tryPutMVar release ())
    (withCommitDeadline owner holderClock 1 $ \guard -> do
      holder <- async(runTransaction owner(enforceCommitDeadline guard >> pure((),[])))
      await(takeMVar held)
      busy <- try @StoreFailure(runRead owner(pure()))
      assertion "ordinary SQL remains fail-fast while safety is requested" (busy==Left StoreBusy)
      shutdownTask <- async(shutdownAdmission controller CancelNow)
      forM_ ready $ \(_,stopped,_) -> await(takeMVar stopped)
      stillJoining <- poll shutdownTask
      assertion "all sixteen original registrations notified before the first join" (case stillJoining of Nothing -> True; _ -> False)
      let (retiring,_,releaseOne)=case ready of first:_->first;[]->error "missing original registrations"
      putMVar releaseOne ()
      await(wait retiring) >>= assertion "one original registration retires during shutdown" . (==Left StoreClosed)
      retained <- requestStoreWorkersStop owner
      assertion "repeat broadcast retains all original handles after retirement" (length retained==16)
      joined <- async(awaitStoreWorkersStop retained)
      poll joined >>= assertion "original batch join still waits for unpublished cleanup" . maybe True (const False)
      releaseAll
      await(wait joined)
      await(wait holder)
      result <- await(wait shutdownTask)
      assertion "SQL saturation cannot block emergency original-owner cleanup" (result==ShutdownResult False(Right()))
      forM_ ready $ \(task,_,_) -> do
        original <- await(wait task)
        assertion "owner stop preserves original StoreClosed outcome" (original==Left StoreClosed)
      number owner "SELECT count(*) FROM commands" >>= assertion "physical cleanup creates no committed receipt" . (==0)
      number owner "SELECT count(*) FROM runs" >>= assertion "physical cleanup fabricates no Runtime cancellation" . (==0)
      late <- admitOldest controller
      assertion "closed controller refuses later admission after joined cleanup" (case late of Left StorageUnavailable -> True; _ -> False)) `finally` releaseAll
  fixture "shutdown-poisoned" $ \owner -> withAdmission owner $ \controller -> do
    entered <- newEmptyMVar
    stopped <- newEmptyMVar
    task <- async $ try @StoreFailure $ withStoreWorker owner $ \_ _ _ ->
      (putMVar entered () >> atomically(check False)) `finally` putMVar stopped ()
    await(takeMVar entered)
    mutate owner $ execute "INSERT INTO requests(id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('poison-request','revision','client_1','workflow','descriptor','profile','policy','draft','not-queued',?,?)" [SQL.SQLBlob "[]",SQL.SQLBlob "[]"]
    failed <- try @StoreFailure $ runTransaction owner $ do
      execute "UPDATE requests SET enqueue_command='missing-command' WHERE id='poison-request'" []
      pure((),[Invalidation "request.changed" "/v1/requests/poison-request" "revision"])
    assertion "deferred commit failure is preserved" (failed==Left StoreUnavailable)
    refused <- try @StoreFailure(runRead owner(pure()))
    assertion "uncertain commit preserves original poison fence" (refused==Left StorePoisoned)
    await(takeMVar stopped)
    await(wait task) >>= assertion "definite poison automatically stops original worker before explicit shutdown" . (==Left StoreClosed)
    result <- await(shutdownAdmission controller CancelNow)
    assertion "explicit safety completion is not a durable receipt" (result==ShutdownResult False(Right()))
  fixture "shutdown-exception" $ \owner -> do
    result <- try @SomeException $ withAdmission owner $ \_ -> throwIO UserInterrupt
    assertion "bracket cancellation preserves original body exception" (case result of Left failure -> fromException failure==Just UserInterrupt; _ -> False)
  fixture "shutdown-commit-fence" $ \owner -> do
    fence <- newTVarIO False
    entered <- newEmptyMVar
    release <- newEmptyMVar
    let clockAtCommit = putMVar entered () >> readMVar release >> pure 0
    withCommitDeadline owner clockAtCommit 1 $ \guard -> do
      task <- async $ try @StoreFailure $ runTransaction owner $ do
        enforceAdmissionFence fence
        enforceCommitDeadline guard
        execute "UPDATE clients SET revision='must-rollback' WHERE id='client_1'" []
        pure((),[Invalidation "service.changed" "/v1/capabilities" "must-rollback"])
      await(takeMVar entered)
      atomically(writeTVar fence True)
      putMVar release ()
      await(wait task) >>= assertion "shutdown fence rejects in-flight acceptance at final validation" . (==Left StoreClosed)
    scalarText owner "SELECT revision FROM clients WHERE id='client_1'" >>= assertion "fenced transaction preserves original durable revision" . (=="revision")
    number owner "SELECT count(*) FROM invalidations WHERE revision='must-rollback'" >>= assertion "fenced acceptance rolls back its invalidation too" . (==0)
    atomically(writeTVar fence False)
    runTransaction owner $ do
      enforceAdmissionFence fence
      execute "UPDATE clients SET revision='accepted' WHERE id='client_1'" []
      pure((),[Invalidation "service.changed" "/v1/capabilities" "accepted"])
    scalarText owner "SELECT revision FROM clients WHERE id='client_1'" >>= assertion "open final fence permits original acceptance once" . (=="accepted")
  putStrLn "PASS in-memory shutdown and Store safety without native process construction"

shutdownNativeChecks :: FilePath -> FilePath -> IO ()
shutdownNativeChecks work native = do
  withFixture work native "shutdown-reuse" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ _) -> do
    withAdmission owner (const(pure()))
    forM_ ["first","second"] $ \suffix -> withAdmission owner $ \controller -> do
      draft <- newDraft fixture 0 "a" suffix
      void(enqueue controller fixture 0 draft suffix)
      live <- admit controller
      void(await(awaitReview live) >>= right)
      assertion "healthy same-Store reuse constructs an actual native preparation" True
  forM_ [False,True] $ \expiry -> withFixture work native (if expiry then "shutdown-deadline" else "shutdown-cancel") 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ _) -> do
    time <- newTVarIO 0
    watching <- newEmptyMVar
    let timer = MonotonicClock (atomically(readTVar time)) $ \deadline -> do
          when(deadline==100)(void(tryPutMVar watching ()))
          atomically(readTVar time >>= check . (>=deadline))
    withAdmissionClock timer owner $ \controller -> do
      draft <- newDraft fixture 0 "a" "urgent"
      void(enqueue controller fixture 0 draft "urgent")
      live <- admit controller
      void(await(awaitReview live) >>= right)
      entered <- newEmptyMVar
      release <- newEmptyMVar
      held <- newEmptyMVar
      releaseSQL <- newEmptyMVar
      let releaseAll = void(tryPutMVar releaseSQL ()) >> void(tryPutMVar release ())
      (do
        first <- async(withReviewAcceptance live(\_ _ -> putMVar entered () >> readMVar release))
        await(takeMVar entered)
        callers <- forM [1..15::Int] $ \_ -> do
          task <- async(withReviewAcceptance live(\_ _ -> pure()))
          let waiting = do
                status <- threadStatus(asyncThreadId task)
                case status of
                  ThreadBlocked BlockedOnSTM -> pure()
                  ThreadFinished -> error "Admission caller unexpectedly finished before saturation"
                  ThreadDied -> error "Admission caller died before saturation"
                  _ -> threadDelay 1000 >> waiting
          await waiting
          pure task
        refused <- withReviewAcceptance live(\_ _ -> error "seventeenth operation entered")
        assertion "sixteen actual Admission operation slots are occupied" (case refused of Left StorageUnavailable -> True; _ -> False)
        cancel first
        withCommitDeadline owner (putMVar held () >> readMVar releaseSQL >> pure 0) 1 $ \guard -> do
          holder <- async(runTransaction owner(enforceCommitDeadline guard >> pure((),[])))
          await(takeMVar held)
          ending <- async(shutdownAdmission controller(if expiry then DrainUntil 100 else CancelNow))
          when expiry $ await(takeMVar watching) >> atomically(writeTVar time 100)
          awaitNativeStop live
          poll ending >>= assertion "native stop precedes SQL and retained-operation joins" . maybe True (const False)
          cancel ending
          repeated <- async(closeAdmission controller 200)
          releaseAll
          await(wait holder)
          forM_ callers $ \task -> await(wait task) >>= assertion "fenced retained callers do not enter new acceptance" . (==Left StorageUnavailable)
          result <- await(wait repeated)
          assertion "interrupted shutdown waiter cannot erase original expiry or cleanup" (result==ShutdownResult expiry(Right()))
          await(awaitAdmissionCleanup live) >>= right) `finally` releaseAll
  forM_ ["poison","full","io"] $ \fault -> withFixture work native ("shutdown-"<>fault) 1 [("a",[])] $ \fixture@(Fixture root _ owner _ _) -> do
    outcome <- try @CommandFailure $ withAdmission owner $ \controller -> do
      draft <- newDraft fixture 0 "a" (T.pack fault)
      void(enqueue controller fixture 0 draft (T.pack fault))
      live <- admit controller
      void(await(awaitReview live) >>= right)
      entered <- newEmptyMVar
      release <- newEmptyMVar
      (withCommitDeadline owner (putMVar entered () >> readMVar release >> pure 0) 1 $ \guard -> do
        holder <- async(runTransaction owner(enforceCommitDeadline guard >> pure((),[])))
        await(takeMVar entered)
        busy <- try @StoreFailure(runTransaction owner(pure((),[])))
        assertion "transient Busy does not request native safety" (busy==Left StoreBusy)
        observeLivePreparation live >>= assertion "native preparation stays live under Busy" . maybe False ((==Worker.WorkerPrepared) . Worker.observedWorkerPhase)
        putMVar release ()
        await(wait holder)) `finally` void(tryPutMVar release ())
      rollbackResult <- try @StoreFailure $ mutate owner(execute "INSERT INTO clients VALUES ('client_1','duplicate','fixture',0)" [])
      assertion "confirmed constraint rollback retains original refusal" (rollbackResult==Left StoreUnavailable)
      runRead owner(pure())
      observeLivePreparation live >>= assertion "confirmed rollback does not stop original native worker" . maybe False ((==Worker.WorkerPrepared) . Worker.observedWorkerPhase)
      when(fault=="io") $ do
        readFailure <- try @StoreFailure(runRead owner(void(query "SELECT admission_io_failure()" [])))
        assertion "read-only injected IO retains original error without widening writable fault policy" (readFailure==Left StoreUnavailable)
        runRead owner(pure())
        observeLivePreparation live >>= assertion "read-only IO with confirmed rollback does not set writable availability latch" . maybe False ((==Worker.WorkerPrepared) . Worker.observedWorkerPhase)
      when(fault=="full") $ do
        quota <- number owner "SELECT admission_page_quota()"
        assertion "test-only original connection page quota applied" (quota>0)
      failed <- try @StoreFailure $ mutate owner $ case fault of
        "poison" -> execute "UPDATE requests SET enqueue_command='missing-command' WHERE id=?" [SQL.SQLText(draftId draft)]
        "full" -> execute "INSERT INTO clients VALUES ('full','revision',CAST(zeroblob(1048576) AS TEXT),0)" []
        _ -> execute "INSERT INTO clients VALUES ('io','revision',admission_io_failure(),0)" []
      assertion (fault<>" preserves original opaque SQL error") (failed==Left StoreUnavailable)
      unavailable <- try @StoreFailure(runRead owner(pure()))
      assertion (fault<>" keeps poison distinct from definite writable unavailability") (unavailable==Left(if fault=="poison" then StorePoisoned else StoreUnavailable))
      awaitNativeStop live
      await(awaitAdmissionCleanup live) >>= assertion "automatic native cleanup does not fabricate durable release" . (==Left StorageUnavailable)
      rawNumber root "SELECT count(*) FROM reservations WHERE state!='released'" >>= assertion "unpublished release retains original reservation" . (==1)
      rawNumber root "SELECT count(*) FROM commands WHERE operation='cancel'" >>= assertion "automatic physical stop creates no cancellation receipt" . (==0)
      rawNumber root "SELECT count(*) FROM runs" >>= assertion "unapproved native stop creates no Runtime terminal result" . (==0)
    assertion (fault<>" preserves failed cleanup publication at scope exit") (outcome==Left StorageUnavailable)
    reused <- try @CommandFailure(withAdmission owner(\_ -> error "unhealthy Store admitted a fresh controller"))
    assertion "original joined cleanup never clears permanent storage unavailability" (case reused of Left StorageUnavailable -> True; _ -> False)
  putStrLn "PASS local native shutdown, saturation, reuse and automatic storage safety"

awaitNativeStop :: LivePreparation -> IO ()
awaitNativeStop live = await loop
  where
    loop = do
      value <- observeLivePreparation live
      case value of
        Just observation | maybe False (const True) (Worker.observedWorkerExit observation) ->
          assertion "original native Worker joins with confirmed physical cleanup" (not(Worker.observedCleanupUnproven observation))
        _ -> threadDelay 1000 >> loop

policyChecks :: IO ()
policyChecks = do
  let unclassified=effectiveResources []
      named=effectiveResources ["unclassified"]
      a=Candidate "a" 1 True True unclassified
      b=Candidate "b" 2 True True named
  assertion "unclassified domain cannot collide with an operator string" (Set.disjoint unclassified named)
  assertion "old blocked unclassified work permits independent classified progress"
    (oldestEligible 2 [Held 0 unclassified] [a,b]==Just(b,1))
  assertion "capacity shrink counts retained out-of-range slots" (oldestEligible 1 [Held 15 named] [a]==Nothing)
  result <- quickCheckWithResult stdArgs {maxSuccess=2000} $ forAll scenario $ \(limit,held,candidates) ->
    let selected=oldestEligible limit held candidates
        keys=Set.unions[footprint|Held _ footprint<-held]
        eligible c=candidateEnabled c && candidateReady c && Set.disjoint keys(candidateResources c)
        available=[slot|slot<-[0..limit-1],slot `notElem` [n|Held n _<-held]]
        reference=case available of
          slot:_ | length held<limit -> (\candidate->(candidate,slot)) <$> find eligible(sortOn candidateOrdinal candidates)
          _ -> Nothing
     in counterexample(show(limit,held,candidates,selected)) $ selected==reference && case selected of
       Nothing -> True
       Just(candidate,slot) -> length held+1<=limit && slot `notElem` [n|Held n _<-held]
         && Set.disjoint keys(candidateResources candidate)
         && all (\earlier->candidateOrdinal earlier>=candidateOrdinal candidate || not(eligible earlier)) candidates
  assertion "generated production policy preserves bounds, exclusivity, FIFO and independent progress" (isSuccess result)
  staticOccupancyCheck
  where
    resources=effectiveResources <$> sublistOf ["x","y","z","unclassified","operator","resource_0"]
    scenario=do
      limit<-chooseInt(0,16)
      slots<-sublistOf[0..15]
      held<-mapM (\slot->Held slot <$> resources)slots
      count<-chooseInt(0,100)
      candidates<-forM [1..count] $ \ordinal->Candidate(T.pack(show ordinal))(fromIntegral ordinal) <$> arbitrary <*> arbitrary <*> resources
      shuffled<-shuffle candidates
      pure(limit,held,shuffled)

staticOccupancyCheck :: IO ()
staticOccupancyCheck = do
  let footprint=effectiveResources["x","y"]
      blocked=Candidate "blocked" 1 True True (effectiveResources["y","z"])
      independent=Candidate "free" 2 True True (effectiveResources["q"])
  assertion "supplied held claims exclude conflicts and consume global capacity"
    (oldestEligible 2 [Held 0 footprint] [blocked,independent]==Just(independent,1)
      && oldestEligible 1 [Held 0 footprint] [independent]==Nothing)

data Fixture = Fixture FilePath InstalledConfiguration CoordinationStore [(Text,Discovery)] [CredentialProof]
withFixture :: FilePath -> FilePath -> String -> Int -> [(Text,[Text])] -> (Fixture -> IO a) -> IO a
withFixture work native name slots profiles = withFixtureUsing work native [] name slots profiles

withFixtureUsing :: FilePath -> FilePath -> [String] -> String -> Int -> [(Text,[Text])] -> (Fixture -> IO a) -> IO a
withFixtureUsing work native prefix name slots profiles action = do
  let root=work </> name;path=work </> (name<>".json")
  createDirectory root
  setFileMode root 0o700
  BS.writeFile path(encoded(object["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= ([]::[String]),
    "runners" .= [object["alias" .= ("native"::Text),"executable" .= native,"prefix" .= prefix]],
    "profiles" .= [object["id" .= ident,"runner" .= ("native"::Text),"workspace" .= work,"workspaceLabel" .= ("fixture"::Text),
      "targetLabel" .= ("scripted"::Text),"targetArguments" .= ["--scripted"::Text],
      "environment" .= [object["name" .= ("TMPDIR"::Text),"value" .= work],object["name" .= ("XDG_CONFIG_HOME"::Text),"value" .= (work </> "config")]],
      "ownership" .= ("service-owned"::Text),"quarantined" .= False,"personAnswering" .= ("local-control"::Text),"resourceKeys" .= keys]|(ident,keys)<-profiles],
    "limits" .= object["drafts" .= (110::Int),"globalDrafts" .= (110::Int),"globalCaptureBytes" .= (134217728::Int),
      "globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),
      "globalMutationLedgerBytes" .= (134217728::Int),"safetyControlsPerMinute" .= (20::Int),"executionReservations" .= slots]]))
  setFileMode path 0o600
  configuration<-loadConfiguration (\arguments->if arguments==["--scripted"] then Right() else Left InvalidConfiguration)  exactPreparedTarget (const False) path >>= right
  bracket (installConfiguration configuration >>= right) closeConfiguration $ \installed -> withCoordinationStore installed $ \owner -> do
    (_,public)<-configurationSnapshot installed >>=right
    catalogues<-forM public $ \profile->do value<-probeConfiguredProfile installed(publicId profile)(publicRevision profile)>>=right;pure(publicId profile,value)
    proofs<-forM [1..12::Int] $ \index->do
      let client="client_"<>T.pack(show index);credential="credential_"<>T.pack(show index);secret=BS.replicate 32(fromIntegral index)
      mutate owner $ do
        execute "INSERT INTO clients VALUES (?,'revision','fixture',0)" [SQL.SQLText client]
        execute "INSERT INTO credentials VALUES (?,?,?,'2999-01-01T00:00:00Z',0)" [SQL.SQLText credential,SQL.SQLText client,SQL.SQLBlob(convert(hash secret::Digest SHA256))]
        forM_ profiles $ \(profile,_) -> forM_ ["submit","observe","control"::Text] $ \scope->execute "INSERT INTO credential_scopes VALUES (?,?,?)" [SQL.SQLText credential,SQL.SQLText profile,SQL.SQLText scope]
      authenticateCredential owner secret >>=right
    action(Fixture root installed owner catalogues proofs)

newDraft :: Fixture -> Int -> Text -> Text -> IO DraftView
newDraft (Fixture _ _ owner catalogues proofs) credential profile suffix=do
  catalogue<-maybe(error "missing catalogue")pure(lookup profile catalogues)
  workflow<-case [ident|(ident,descriptor)<-discoveryEntries catalogue,workflowName descriptor=="person-controlled"]of [ident]->pure ident;_->error "missing native workflow"
  nonce<-key owner("create_"<>suffix)
  initial<-createDraft owner (proofs!!credential) nonce (encoded(object["profileId" .= profile,"profileRevision" .= discoveryProfileRevision catalogue,"workflowId" .= workflow,"descriptorRevision" .= discoveryRevision catalogue])) >>=right
  editKey<-key owner("input_"<>suffix)
  _<-changeDraftInput owner(proofs!!credential)(draftId initial)editKey(etag initial)(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "native admission\r\n雪"])) >>=right
  readDraft owner(proofs!!credential)(draftId initial)>>=right

enqueue :: Admission -> Fixture -> Int -> DraftView -> Text -> IO (Text,CommandReceipt)
enqueue controller (Fixture _ _ owner _ proofs) credential view suffix=do
  nonce<-key owner("enqueue_"<>suffix)
  receipt<-enqueueRequest controller(proofs!!credential)(draftId view)nonce(etag view)(body "enqueue")>>=right
  pure(nonce,receipt)
admit :: Admission -> IO LivePreparation
admit controller=admitOldest controller >>=right >>=maybe(error "expected admission")pure
viewNow :: Fixture -> Int -> Text -> IO DraftView
viewNow (Fixture _ _ owner _ proofs) credential ident=readDraft owner(proofs!!credential)ident>>=right

lifecycleChecks :: FilePath -> FilePath -> IO ()
lifecycleChecks work native=withFixture work native "lifecycle" 2 [("a",[]),("b",[]),("c",["unclassified"])] $ \fixture@(Fixture root _ owner _ proofs)->
  withAdmission owner $ \controller->do
    duplicateOwner<-try @CommandFailure(withAdmission owner(const(error "duplicate admission callback")))
    assertion "one actual Store permits only one scoped admission owner" (case duplicateOwner of Left StorageUnavailable->True;_->False)
    a<-newDraft fixture 0 "a" "a"
    b<-newDraft fixture 1 "b" "b"
    c<-newDraft fixture 2 "c" "c"
    (enqueueKey,original)<-enqueue controller fixture 0 a "a"
    _<-enqueue controller fixture 1 b "b"
    _<-enqueue controller fixture 2 c "c"
    queuedView<-viewNow fixture 1(draftId b)
    assertion "queue position is visible before preparation" (draftPosition queuedView==Just 2)
    first<-admit controller
    preparedA<-await(awaitReview first)>>=right
    second<-admit controller
    preparedC<-await(awaitReview second)>>=right
    assertion "native oldest eligible bypasses blocked shared cohort" (reviewRequest preparedA==draftId a && reviewRequest preparedC==draftId c)
    blocked<-viewNow fixture 1(draftId b)
    assertion "blocked reasons remain visible" ("profile-busy" `elem` draftReasons blocked)
    number owner "SELECT count(*) FROM reservations WHERE state='held'" >>=assertion "review occupies both global slots" . (==2)
    number owner "SELECT count(*) FROM preparations" >>=assertion "native observation is not a fabricated public review" . (==0)
    forM_ [preparedA,preparedC] $ \review->doesDirectoryExist(root </> "runs" </> "runs" </> T.unpack(runIdText(preparedRunId(reviewNative review)))) >>=assertion "review has no started native run directory" . not
    withReviewAcceptance first (\review _->pure(reviewReservation review)) >>=right >>=assertion "guarded handoff loans original association" . (==reservationIdentity first)
    number owner "SELECT count(*) FROM reservations WHERE state='held'" >>=assertion "returning handoff retains occupancy" . (==2)
    retry<-enqueueRequest controller(proofs!!0)(draftId a)enqueueKey(etag a)(body "enqueue")>>=right
    assertion "exact admitted enqueue retry returns immutable original receipt" (retry==original)
    currentA<-viewNow fixture 0(draftId a)
    editKey<-key owner "live_edit"
    let editBody=encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "edited"])
    accepted<-editRequestInput controller(proofs!!0)(draftId a)editKey(etag currentA)editBody>>=right
    assertion "accepted live edit is not completed-effect evidence" (receiptState accepted==Accepted && receiptEffect accepted==Nothing)
    await(awaitAdmissionCleanup first)>>=right
    edited<-viewNow fixture 0(draftId a)
    assertion "real edit joins cleanup before draft transition" (draftPhase edited=="draft" && draftPosition edited==Nothing)
    observed<-readCommand owner(proofs!!0)(receiptId accepted)>>=right
    assertion "cleanup and input effect publish together" (receiptState observed==EffectObserved)
    retryEdit<-editRequestInput controller(proofs!!0)(draftId a)editKey(etag currentA)editBody>>=right
    assertion "live edit exact retry never redispatches" (retryEdit==accepted)
    rejectedLoan<-withReviewAcceptance first(\_ _->pure())
    assertion "escaped invalidated loan cannot be reused" (case rejectedLoan of Left _->True;_->False)
    currentC<-viewNow fixture 2(draftId c)
    withdrawKey<-key owner "live_withdraw"
    withdrawal<-withdrawRequest controller(proofs!!2)(draftId c)withdrawKey(etag currentC)(body "withdraw")>>=right
    await(awaitAdmissionCleanup second)>>=right
    retryWithdrawal<-withdrawRequest controller(proofs!!2)(draftId c)withdrawKey(etag currentC)(body "withdraw")>>=right
    assertion "exact withdraw returns original accepted receipt" (withdrawal==retryWithdrawal)
    withdrawn<-viewNow fixture 2(draftId c)
    assertion "native withdrawal releases only after cleanup" (draftPhase withdrawn=="withdrawn")
    next<-admit controller
    reviewB<-await(awaitReview next)>>=right
    assertion "formerly blocked oldest request advances after physical release" (reviewRequest reviewB==draftId b)

expiryChecks :: FilePath -> FilePath -> IO ()
expiryChecks work native=withFixture work native "expiry" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ proofs)->do
  time<-newTVarIO 1000000000
  let clock'=MonotonicClock (atomically(readTVar time)) (\deadline->atomically(readTVar time>>=check.(>=deadline)))
  withAdmissionClock clock' owner $ \controller->do
    draft<-newDraft fixture 0 "a" "expiry"
    _<-enqueue controller fixture 0 draft "expiry"
    live<-admit controller
    review<-await(awaitReview live)>>=right
    assertion "ten minutes measured from actual native preparation observation" (reviewDeadlineNanos review==601000000000)
    mutate owner(execute "UPDATE admission_observations SET review_expires_at='1900-01-01T00:00:00Z'" [])
    atomically(writeTVar time(reviewDeadlineNanos review-1))
    withReviewAcceptance live(\_ _->pure())>>=right
    atomically(writeTVar time(reviewDeadlineNanos review))
    await(awaitAdmissionCleanup live)>>=right
    expired<-viewNow fixture 0(draftId draft)
    assertion "expiry returns to draft without silent enqueue" (draftPhase expired=="draft" && draftPosition expired==Nothing)
    scalarText owner "SELECT reason FROM admission_observations" >>=assertion "expiry reason retained with real native observation" . (=="expired")
    number owner "SELECT count(*) FROM reservation_resources" >>=assertion "monotonic expiry joined physical cleanup" . (==0)
    escaped<-withReviewAcceptance live(\_ _->pure())
    assertion "expired loan cannot approve" (case escaped of Left _->True;_->False)
    void(pure proofs)

rollbackChecks :: FilePath -> FilePath -> IO ()
rollbackChecks work native=withFixture work native "rollback" 1 [("a",["x","y"])] $ \fixture@(Fixture root _ owner _ _)->withAdmission owner $ \controller->do
  draft<-newDraft fixture 0 "a" "rollback"
  _<-enqueue controller fixture 0 draft "rollback"
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database ->
    SQL.exec database "CREATE TRIGGER fail_claim BEFORE INSERT ON reservation_resources WHEN NEW.resource_key='y' BEGIN SELECT RAISE(ABORT,'controlled claim failure'); END"
  attempted<-admitOldest controller
  assertion "atomic claim insertion failure refuses admission" (case attempted of Left _->True;_->False)
  number owner "SELECT count(*) FROM reservations" >>=assertion "failed all-key acquisition retains no slot" . (==0)
  number owner "SELECT count(*) FROM reservation_resources" >>=assertion "failed all-key acquisition retains no partial key" . (==0)
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database -> SQL.exec database "DROP TRIGGER fail_claim"
  live<-admit controller
  void(await(awaitReview live)>>=right)

saturationChecks :: FilePath -> FilePath -> IO ()
saturationChecks work native=withFixture work native "saturation" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ proofs)->withAdmission owner $ \controller->do
  drafts<-forM [0..100::Int] $ \index->do
    let credential=index `div` 9
    draft<-newDraft fixture credential "a" (T.pack(show index))
    pure(credential,draft)
  forM_ (take 100(zip[0..]drafts)) $ \(index,(credential,draft))->void(enqueue controller fixture credential draft(T.pack(show(index::Int))))
  number owner "SELECT count(*) FROM requests WHERE phase='queued'" >>=assertion "exact global queue ceiling is 100" . (==100)
  let (credential,extra)=last drafts
  nonce<-key owner "queue_over"
  over<-enqueueRequest controller(proofs!!credential)(draftId extra)nonce(etag extra)(body "enqueue")
  assertion "one over queue ceiling refuses without partial intent" (case over of Left StateConflict->True;_->False)
  live<-admit controller
  void(await(awaitReview live)>>=right)
  noMore<-admitOldest controller>>=right
  assertion "multiple queued jobs share one configured global slot" (case noMore of Nothing->True;_->False)
  let (firstCredential,firstDraft)=case drafts of value:_->value;[]->error "missing drafts"
  current<-viewNow fixture firstCredential(draftId firstDraft)
  cancelKey<-key owner "saturated_withdraw"
  _<-withdrawRequest controller(proofs!!firstCredential)(draftId firstDraft)cancelKey(etag current)(body "withdraw")>>=right
  await(awaitAdmissionCleanup live)>>=right
  number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "queue saturation does not block native pre-start cancellation cleanup" . (==0)
  -- The durable queue ordinal clock survives removal from queue and release.
  scalarText owner "SELECT last_ordinal FROM admission_queue_clock" >>=assertion "queue history does not reset its ordering clock" . (=="100")

reloadChecks :: FilePath -> FilePath -> IO ()
reloadChecks work native=withFixture work native "reload" 2 [("a",["x","y"]),("b",["z"]),("c",["free"])] $ \fixture@(Fixture root installed owner _ proofs)->withAdmission owner $ \controller->do
  firstDraft<-newDraft fixture 0 "a" "reload_a"
  secondDraft<-newDraft fixture 1 "b" "reload_b"
  _<-enqueue controller fixture 0 firstDraft "reload_a"
  _<-enqueue controller fixture 1 secondDraft "reload_b"
  first<-admit controller
  void(await(awaitReview first)>>=right)
  second<-admit controller
  void(await(awaitReview second)>>=right)
  original<-BS.readFile(work </> "reload.json") >>=right.eitherDecodeStrict'
  let changed=case original of
        Object fields -> case (KM.lookup "limits" fields,KM.lookup "profiles" fields) of
          (Just(Object limits),Just(Array profiles)) -> Object(KM.insert "limits" (Object(KM.insert "executionReservations" (Number 1) limits))
            (KM.insert "profiles" (toJSON [case profile of Object fields'->Object(KM.insert "resourceKeys" (toJSON(["changed"]::[Text]))fields');_->error "fixture profile"|profile<-foldr(:)[]profiles]) fields))
          _ -> error "fixture limits/profiles"
        _->error "fixture configuration"
      path=work </> "reloaded.json"
  BS.writeFile path(encoded changed)
  setFileMode path 0o600
  configuration<-loadConfiguration (\arguments->if arguments==["--scripted"] then Right() else Left InvalidConfiguration)  exactPreparedTarget (const False) path >>=right
  void(reloadConfiguration installed configuration >>=right)
  (_,public)<-configurationSnapshot installed >>=right
  catalogues<-forM public $ \profile->do discovery<-probeConfiguredProfile installed(publicId profile)(publicRevision profile)>>=right;pure(publicId profile,discovery)
  let currentFixture=Fixture root installed owner catalogues proofs
  freshDraft<-newDraft currentFixture 2 "c" "current"
  _<-enqueue controller currentFixture 2 freshDraft "current"
  stale<-withReviewAcceptance first(\_ _->pure())
  assertion "reload cannot make an old native review current" (case stale of Left StaleRevision->True;_->False)
  number owner "SELECT count(*) FROM reservation_resources WHERE resource_key IN ('x','y','z')" >>=assertion "reload retains actual original resource footprint" . (==3)
  noRoom<-admitOldest controller>>=right
  assertion "shrunk global limit does not reinterpret two held reservations" (case noRoom of Nothing->True;_->False)
  forM_ [(0,firstDraft,first),(1,secondDraft,second)] $ \(credential,draft,live)->do
    current<-viewNow currentFixture credential(draftId draft)
    nonce<-key owner("reload_withdraw_"<>T.pack(show credential))
    _<-withdrawRequest controller(proofs!!credential)(draftId draft)nonce(etag current)(body "withdraw")>>=right
    await(awaitAdmissionCleanup live)>>=right
  next<-admit controller
  review<-await(awaitReview next)>>=right
  assertion "current profile admits after exact old owners finish cleanup" (reviewRequest review==draftId freshDraft)

captureChecks :: FilePath -> FilePath -> IO ()
captureChecks work native=withFixture work native "captures" 1 [("a",[])] $ \fixture@(Fixture root _ owner _ proofs)->withAdmission owner $ \controller->do
  draft<-newDraft fixture 0 "a" "capture"
  nonce<-key owner "missing_input"
  _<-editRequestInput controller(proofs!!0)(draftId draft)nonce(etag draft)(encoded(object["operation" .= ("remove-input"::Text),"name" .= ("input"::Text)]))>>=right
  missing<-viewNow fixture 0(draftId draft)
  enqueueKey<-key owner "missing_enqueue"
  refused<-enqueueRequest controller(proofs!!0)(draftId draft)enqueueKey(etag missing)(body "enqueue")
  assertion "missing structural input cannot enqueue" (case refused of Left InvalidInput->True;_->False)
  chunks<-newTVarIO["captured input"::BS.ByteString]
  let next=atomically $ do parts<-readTVar chunks;case parts of []->pure BS.empty;value:rest->writeTVar chunks rest>>pure value
  captureKey<-key owner "capture_upload"
  capture<-uploadCapture owner(proofs!!0)(draftId draft)captureKey 1024 next>>=right
  bindingKey<-key owner "capture_bind"
  _<-editRequestInput controller(proofs!!0)(draftId draft)bindingKey(etag missing)(encoded(object["operation" .= ("set-input"::Text),"input" .= CapturedValue "input" (captureId capture)]))>>=right
  ready<-viewNow fixture 0(draftId draft)
  _<-enqueue controller fixture 0 ready "captured"
  removeFile(root </> "captures" </> T.unpack(captureId capture))
  live<-admit controller
  observation<-await(awaitReview live)
  assertion "stored structural readiness is not native preparation success" (case observation of Left _->True;_->False)
  await(awaitAdmissionCleanup live)>>=right
  number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "failed captured materialization releases only known no-launch construction" . (==0)
  current<-viewNow fixture 0(draftId draft)
  assertion "invalid capture remains visible and is not silently re-enqueued" (draftPhase current=="draft" && case draftReadiness current of Readiness _ _ _ errors->not(null errors))

reopenChecks :: FilePath -> FilePath -> IO ()
reopenChecks work native=forM_ [False,True] $ \hasBinding->withFixture work native ("reopen-"<>show hasBinding) 1 [("a",[])] $ \fixture@(Fixture _ installed owner _ _)->do
  (draft,nonce,original)<-withAdmission owner $ \controller->do
    draft<-newDraft fixture 0 "a" "reopen"
    (nonce,receipt)<-enqueue controller fixture 0 draft "reopen"
    -- Model a historical queue that predates the immutable restart binding.
    unless hasBinding $ mutate owner(execute "DELETE FROM request_restart_bindings WHERE request_id=?" [SQL.SQLText(draftId draft)])
    pure(draft,nonce,receipt)
  oldGeneration<-storeProcessGeneration <$> storeIdentity owner
  retryStoreCleanup owner
  withCoordinationStore installed $ \fresh->withAdmission fresh $ \controller->do
    identity<-storeIdentity fresh
    assertion "actual Store reopen changes ownership generation" (storeProcessGeneration identity/=oldGeneration)
    proof<-authenticateCredential fresh(BS.replicate 32 1)>>=right
    reply<-enqueueRequest controller proof(draftId draft)nonce(etag draft)(body "enqueue")>>=right
    assertion "reopen exact enqueue retry preserves the original receipt" (reply==original)
    selected<-admitOldest controller>>=right
    if hasBinding then do
      live<-case selected of Just value->pure value;Nothing->error "validated restart did not admit"
      review<-await(awaitReview live)>>=right
      assertion "validated durable queue materializes a fresh native preparation" (reviewRequest review==draftId draft)
    else do
      assertion "unbound durable queued facts cannot recreate admission authority" (case selected of Nothing->True;_->False)
      number fresh "SELECT count(*) FROM reservations" >>=assertion "unbound historical queue creates no worker reservation" . (==0)
    bindings<-number fresh "SELECT count(*) FROM request_restart_bindings"
    assertion "restart preserves existing bindings without fabricating missing ones" (bindings==(if hasBinding then 1 else 0))
    number fresh "SELECT count(*) FROM start_intents" >>=assertion "reopened queue and exact retry fabricate no approval or start" . (==0)
    scalarText fresh "SELECT last_ordinal FROM admission_queue_clock" >>=assertion "durable queue clock survives actual reopen" . (=="1")

reservationBoundaryChecks :: FilePath -> FilePath -> IO ()
reservationBoundaryChecks work native=withFixture work native "reservation_boundary" 16 [("p"<>T.pack(show index),["key"<>T.pack(show index)])|index<-[0..16::Int]] $ \fixture@(Fixture _ _ owner _ _)->withAdmission owner $ \controller->do
  forM_ [0..16::Int] $ \index->do
    draft<-newDraft fixture (index `div` 9) ("p"<>T.pack(show index)) ("reservation_"<>T.pack(show index))
    void(enqueue controller fixture (index `div` 9) draft("reservation_"<>T.pack(show index)))
  forM_ [1..16::Int] $ \_ -> admit controller >>= \live->void(await(awaitReview live)>>=right)
  number owner "SELECT count(*) FROM reservations WHERE state='held'" >>=assertion "sixteen actual native reviews occupy sixteen slots" . (==16)
  seventeenth<-admitOldest controller>>=right
  assertion "seventeenth independent native preparation cannot over-admit" (case seventeenth of Nothing->True;_->False)

rawNumber :: FilePath -> Text -> IO Int64
rawNumber root statement=bracket (SQL.open2(T.pack(root </> "coordination.sqlite3"))[SQL.SQLOpenReadOnly,SQL.SQLOpenFullMutex,SQL.SQLOpenNoFollow]SQL.SQLVFSDefault) SQL.close $ \database ->
  bracket (SQL.prepare database statement) SQL.finalize $ \query'->do
    step<-SQL.step query'
    unless(step==SQL.Row)(error "fixture scalar")
    values<-SQL.columns query'
    case values of [SQL.SQLInteger number']->pure number';_->error "fixture number"

completionFailureChecks :: FilePath -> FilePath -> IO ()
completionFailureChecks work native=do
  executable<-getExecutablePath
  capabilities<-getNumCapabilities
  let private=work </> "completion-failure"
  createDirectory private
  let command=(proc executable ["completion-failure",private,native,"+RTS","-N"<>show capabilities,"-RTS"]) {cwd=Just private,env=Just[("TMPDIR",private),("XDG_CONFIG_HOME",private)],std_in=NoStream,std_out=CreatePipe,std_err=CreatePipe}
  bracket (createProcessGroup command) (\group->terminateProcessGroup 5000000 group >> closeGroupPipes group) $ \group->do
    status<-await(waitProcessGroup group)
    output<-maybe(error "child stdout")pure(groupOutput group)
    errors<-maybe(error "child stderr")pure(groupErrors group)
    bytes<-BS.hGetSome output 65536
    diagnostic<-BS.hGetSome errors 65536
    BS.writeFile(private </> "stdout.log") bytes
    BS.writeFile(private </> "stderr.log") diagnostic
    assertion "owned child verifies failed completion report and retained lease" (status==ExitSuccess && "PASS completion-report quarantine" `BS.isInfixOf` bytes && BS.null diagnostic)

completionFailureChild :: FilePath -> FilePath -> IO ()
completionFailureChild work native=do
  outcome<-try @SomeException $ withFixture work native "quarantine" 1 [("a",["shared"])] $ \fixture@(Fixture root installed owner _ proofs)->do
    ended<-try @CommandFailure $ withAdmission owner $ \controller->do
      draft<-newDraft fixture 0 "a" "quarantine"
      _<-enqueue controller fixture 0 draft "quarantine"
      live<-admit controller
      void(await(awaitReview live)>>=right)
      current<-viewNow fixture 0(draftId draft)
      nonce<-key owner "fault_withdraw"
      armCompletionFailure
      _<-withdrawRequest controller(proofs!!0)(draftId draft)nonce(etag current)(body "withdraw")>>=right
      cleanup<-await(awaitAdmissionCleanup live)
      assertion "Admission does not report release after failed physical evidence" (cleanup==Left StorageUnavailable)
      completionFailureFired >>=assertion "one-shot failed report followed exited leader and successful real signalling" . (==1)
    assertion "Admission scope reports unresolved cleanup" (case ended of Left StorageUnavailable->True;_->False)
    rawNumber root "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "durable reservation remains held after simulated report failure" . (==1)
    rawNumber root "SELECT count(*) FROM reservation_resources" >>=assertion "resource claims remain retained after simulated report failure" . (==1)
    retry<-try @StoreFailure(retryStoreCleanup owner)
    assertion "published Runtime failure keeps original Store fence" (case retry of Left StoreCleanupUnproven->True;_->False)
    fresh<-try @Diagnostic(withCoordinationStore installed(const(pure())))
    assertion "original configuration storage slot cannot be adopted" (case fresh of Left InvalidConfiguration->True;_->False)
  assertion "Store scope never claims successful uncertain cleanup" (case outcome of
    Left failure -> case fromException failure of Just StoreCleanupUnproven->True;_->False
    Right () -> False)
  putStrLn "PASS completion-report quarantine"

foreign import ccall unsafe "admission_arm_completion_failure"
  armCompletionFailure :: IO ()
foreign import ccall unsafe "admission_completion_failure_fired"
  completionFailureFired :: IO CInt

acceptedAuthorityChecks :: FilePath -> FilePath -> IO ()
acceptedAuthorityChecks work native=withFixture work native "accepted-authority" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ proofs)->do
  withAdmission owner $ \controller->do
    draft<-newDraft fixture 0 "a" "authority"
    mutate owner(execute "DELETE FROM credential_scopes WHERE credential_id='credential_1' AND scope='observe'" [])
    _<-enqueue controller fixture 0 draft "submit_only"
    mutate owner(execute "UPDATE credentials SET revoked=1 WHERE id='credential_1'" [])
    live<-admit controller
    review<-await(awaitReview live)>>=right
    assertion "accepted submit-only enqueue remains eligible after credential revocation" (reviewRequest review==draftId draft)
    nonce<-key owner "revoked_withdraw"
    refused<-withdrawRequest controller(proofs!!0)(draftId draft)nonce(Just("\""<>reviewRequestRevision review<>"\""))(body "withdraw")
    assertion "new mutation still requires current credential authorization" (refused==Left Unauthenticated)
  number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "scoped native safety cleanup does not require renewed client credentials" . (==0)

cleanupPublicationChecks :: FilePath -> FilePath -> IO ()
cleanupPublicationChecks work native=withFixture work native "cleanup-publication" 1 [("a",["shared"])] $ \fixture@(Fixture root _ owner _ proofs)->withAdmission owner $ \controller->do
  draft<-newDraft fixture 0 "a" "publication"
  _<-enqueue controller fixture 0 draft "publication"
  live<-admit controller
  void(await(awaitReview live)>>=right)
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database ->
    SQL.exec database "CREATE TRIGGER fail_release BEFORE UPDATE OF state ON reservations WHEN NEW.state='released' BEGIN SELECT RAISE(ABORT,'controlled release failure'); END"
  current<-viewNow fixture 0(draftId draft)
  nonce<-key owner "publication_withdraw"
  accepted<-withdrawRequest controller(proofs!!0)(draftId draft)nonce(etag current)(body "withdraw")>>=right
  unresolved<-await(awaitAdmissionCleanup live)
  assertion "failed cleanup publication is not reported as completed release" (unresolved==Left StorageUnavailable)
  number owner "SELECT count(*) FROM reservation_resources" >>=assertion "SQL release failure preserves all resource claims" . (==1)
  number owner "SELECT count(*) FROM requests WHERE phase='review' AND queue_origin_revision IS NULL AND queue_generation IS NULL" >>=assertion "accepted withdrawal invalidates enqueue materialization while retaining live phase" . (==1)
  number owner "SELECT count(*) FROM commands WHERE effect_evidence IS NOT NULL AND operation='withdraw'" >>=assertion "SQL release failure rolls back effect evidence too" . (==0)
  mutate owner(execute "UPDATE credentials SET revoked=1 WHERE id='credential_1'" [])
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database ->SQL.exec database "DROP TRIGGER fail_release"
  retryAdmissionCleanup live>>=right
  number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "explicit retry publishes only original owner's confirmed cleanup" . (==0)
  number owner "SELECT count(*) FROM commands WHERE state='effect-observed' AND operation='withdraw'" >>=assertion "accepted cleanup survives later credential revocation" . (==1)
  assertion "original accepted receipt remains unchanged" (receiptState accepted==Accepted && receiptEffect accepted==Nothing)

preparingChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
preparingChecks work native source python=do
  let evidence=work </> "preparing.ndjson"
      ready=work </> "preparing.ready"
  withFixtureUsing work python [source </> "manager/test/worker_fixture.py",native,"startup-hang",evidence] "preparing" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ proofs)->withAdmission owner $ \controller->do
    draft<-newDraft fixture 0 "a" "preparing"
    _<-enqueue controller fixture 0 draft "preparing"
    live<-admit controller
    let rendezvous=doesFileExist ready >>= \present->unless present(threadDelay 1000>>rendezvous)
    await rendezvous
    current<-viewNow fixture 0(draftId draft)
    assertion "constructing job owns reservation before native preparation" (draftPhase current=="preparing")
    nonce<-key owner "preparing_edit"
    _<-editRequestInput controller(proofs!!0)(draftId draft)nonce(etag current)(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "changed during preparation"]))>>=right
    await(awaitAdmissionCleanup live)>>=right
    number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "edit interrupts and joins actual constructing process" . (==0)
    observation<-await(awaitReview live)
    assertion "cancelled construction never fabricates native preparation" (case observation of Left _->True;_->False)

loanCancellationChecks :: FilePath -> FilePath -> IO ()
loanCancellationChecks work native=withFixture work native "loan-cancellation" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ _)->do
  now<-newTVarIO 0
  let clock'=MonotonicClock(atomically(readTVar now))(\deadline->atomically(readTVar now>>=check.(>=deadline)))
  withAdmissionClock clock' owner $ \controller->do
    draft<-newDraft fixture 0 "a" "loan_cancel"
    _<-enqueue controller fixture 0 draft "loan_cancel"
    live<-admit controller
    review<-await(awaitReview live)>>=right
    entered<-newEmptyMVar
    release<-newEmptyMVar
    waiter<-async $ withReviewAcceptance live $ \_ _ ->putMVar entered()>>takeMVar release
    await(takeMVar entered)
    cancel waiter
    outcome<-waitCatch waiter
    assertion "caller cancellation abandons only protected loan wait" (case outcome of
      Left failure -> case fromException failure of Just AsyncCancelled->True;_->False
      Right _ -> False)
    atomically(writeTVar now(reviewDeadlineNanos review))
    number owner "SELECT count(*) FROM reservations WHERE state='held'" >>=assertion "expired callback in flight cannot release reservation early" . (==1)
    putMVar release()
    await(awaitAdmissionCleanup live)>>=right
    number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "expiry rechecks after callback and joins original worker" . (==0)

storeClosureChecks :: FilePath -> FilePath -> IO ()
storeClosureChecks work native=withFixture work native "store-closure" 1 [("a",[])] $ \fixture@(Fixture root installed owner catalogues _)->do
  ended<-try @CommandFailure $ withAdmission owner $ \controller->do
    draft<-newDraft fixture 0 "a" "store_close"
    _<-enqueue controller fixture 0 draft "store_close"
    live<-admit controller
    void(await(awaitReview live)>>=right)
    await(retryStoreCleanup owner)
    outcome<-await(awaitAdmissionCleanup live)
    assertion "Store closure joins worker but reports blocked SQL finalization" (outcome==Left StorageUnavailable)
  assertion "Admission closure retains unresolved persistence evidence" (case ended of Left StorageUnavailable->True;_->False)
  withCoordinationStore installed $ \fresh->withAdmission fresh $ \controller->do
    number fresh "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "Store closure does not invent persisted release" . (==1)
    proof<-authenticateCredential fresh(BS.replicate 32 1)>>=right
    let currentFixture=Fixture root installed fresh catalogues [proof]
    draft<-newDraft currentFixture 0 "a" "fresh_blocked"
    _<-enqueue controller currentFixture 0 draft "fresh_blocked"
    selected<-admitOldest controller>>=right
    assertion "fresh controller cannot adopt historical physical ownership" (case selected of Nothing->True;_->False)

ordinalChecks :: FilePath -> FilePath -> IO ()
ordinalChecks work native=withFixture work native "ordinals" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ proofs)->withAdmission owner $ \controller->do
  a<-newDraft fixture 0 "a" "ordinal_a"
  b<-newDraft fixture 1 "a" "ordinal_b"
  mutate owner(execute "UPDATE admission_queue_clock SET last_ordinal='18446744073709551614'" [])
  _<-enqueue controller fixture 0 a "ordinal_max"
  scalarText owner "SELECT queue_ordinal FROM requests WHERE phase='queued'" >>=assertion "queue order reaches UInt64 maximum without signed truncation" . (=="18446744073709551615")
  nonce<-key owner "ordinal_over"
  refused<-enqueueRequest controller(proofs!!1)(draftId b)nonce(etag b)(body "enqueue")
  assertion "queue ordinal overflow never wraps or aliases history" (refused==Left StateConflict)
  number owner "SELECT count(*) FROM requests WHERE phase='queued'" >>=assertion "ordinal overflow rolls back queue acceptance" . (==1)
  forM_ ["-1","00","18446744073709551616"] $ \bad -> do
    invalid<-try @StoreFailure(mutate owner(execute "UPDATE requests SET queue_ordinal=? WHERE phase='draft'" [SQL.SQLText bad]))
    assertion "stored queue ordinals reject malformed bounded representations" (case invalid of Left StoreUnavailable->True;_->False)

invalidationRollbackChecks :: FilePath -> FilePath -> IO ()
invalidationRollbackChecks work native=withFixture work native "enqueue-event-failure" 1 [("a",[])] $ \fixture@(Fixture root _ owner _ proofs)->withAdmission owner $ \controller->do
  draft<-newDraft fixture 0 "a" "event_failure"
  oldSequence<-scalarText owner "SELECT sequence FROM service_metadata"
  oldCommands<-number owner "SELECT count(*) FROM commands"
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database ->SQL.exec database "UPDATE service_metadata SET sequence='18446744073709551615'"
  nonce<-key owner "event_enqueue"
  failed<-enqueueRequest controller(proofs!!0)(draftId draft)nonce(etag draft)(body "enqueue")
  assertion "invalidation exhaustion refuses enqueue acceptance" (failed==Left StorageUnavailable)
  number owner "SELECT count(*) FROM requests WHERE phase='queued'" >>=assertion "failed invalidation rolls back queue position" . (==0)
  scalarText owner "SELECT last_ordinal FROM admission_queue_clock" >>=assertion "failed invalidation rolls back queue ordinal allocation" . (=="0")
  number owner "SELECT count(*) FROM commands" >>=assertion "failed invalidation leaves no enqueue receipt" . (==oldCommands)
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database ->SQL.exec database("UPDATE service_metadata SET sequence='"<>oldSequence<>"'")
  recovered<-enqueueRequest controller(proofs!!0)(draftId draft)nonce(etag draft)(body "enqueue")>>=right
  assertion "same-key retry after proven rollback creates one valid enqueue" (receiptState recovered==EffectObserved)

commitDeadlineChecks :: FilePath -> FilePath -> IO ()
commitDeadlineChecks work native=withFixture work native "commit-deadline" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ _)->do
  time<-newTVarIO 0
  armed<-newTVarIO False
  entered<-newEmptyMVar
  release<-newEmptyMVar
  let clockRead=do
        stopHere<-atomically $ do value<-readTVar armed;writeTVar armed False;pure value
        when stopHere (putMVar entered() >> takeMVar release)
        atomically(readTVar time)
      clock'=MonotonicClock clockRead (\deadline->atomically(readTVar time>>=check.(>=deadline)))
  withAdmissionClock clock' owner $ \controller->do
    draft<-newDraft fixture 0 "a" "commit_deadline"
    _<-enqueue controller fixture 0 draft "commit_deadline"
    live<-admit controller
    review<-await(awaitReview live)>>=right
    let program guard revision = runTransaction owner $ do
          execute "UPDATE clients SET revision=? WHERE id='client_1'" [SQL.SQLText revision]
          enforceCommitDeadline guard
          pure((),[Invalidation "service.changed" "/v1/capabilities" revision])
    withReviewAcceptance live(\_ guard->program guard "deadline_valid")>>=right
    scalarText owner "SELECT revision FROM clients WHERE id='client_1'" >>=assertion "unexpired final transaction deadline permits legitimate commit" . (=="deadline_valid")
    refused<-bracket (async $ withReviewAcceptance live $ \_ guard->do
      atomically(writeTVar armed True)
      program guard "deadline_refused") cancel $ \pending->do
        await(takeMVar entered)
        active<-try @StoreFailure(storeIdentity owner)
        assertion "live deadline crosses while owning transaction is active" (case active of Left StoreBusy->True;_->False)
        atomically(writeTVar time(reviewDeadlineNanos review))
        putMVar release()
        wait pending
    assertion "expiry after protected entry refuses final guarded acceptance" (refused==Left StorageUnavailable)
    await(awaitAdmissionCleanup live)>>=right
    scalarText owner "SELECT revision FROM clients WHERE id='client_1'" >>=assertion "final in-transaction expiry rolls back bounded source-owned writes" . (=="deadline_valid")
    number owner "SELECT count(*) FROM invalidations WHERE revision='deadline_refused'" >>=assertion "final in-transaction expiry rolls back invalidations" . (==0)

activeRetryChecks :: FilePath -> FilePath -> IO ()
activeRetryChecks work native=withFixture work native "active-retry" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ _)->do
  time<-newTVarIO 0
  prepared<-newEmptyMVar
  leaving<-newEmptyMVar
  reply<-newEmptyMVar
  let clock'=MonotonicClock(atomically(readTVar time))(\deadline->atomically(readTVar time>>=check.(>=deadline)))
  scoped<-async $ withAdmissionClock clock' owner $ \controller->do
    draft<-newDraft fixture 0 "a" "active_retry"
    _<-enqueue controller fixture 0 draft "active_retry"
    live<-admit controller
    review<-await(awaitReview live)>>=right
    putMVar prepared review
    holdReply<-newEmptyMVar
    caller<-async $ retryAdmissionCleanup live >>= \outcome->putMVar reply outcome>>takeMVar holdReply
    let entered=do
          returned<-tryReadMVar reply
          state<-threadStatus(asyncThreadId caller)
          case (returned,state) of
            (Just _,_)->pure()
            (_,ThreadBlocked BlockedOnSTM)->pure()
            _->threadDelay 1000>>entered
    await entered
    void(timeout 2000000(readMVar reply))
    cancel caller
    cancelled<-waitCatch caller
    assertion "premature retry caller cancellation preserves original exception" (case cancelled of
      Left failure->case fromException failure of Just AsyncCancelled->True;_->False
      Right _->False)
    putMVar leaving()
  review<-await(takeMVar prepared)
  await(takeMVar leaving)
  ending<-timeout 20000000(waitCatch scoped)
  case ending of
    Nothing->do
      putStrLn "FAIL active retry prevented Admission scope shutdown with clock below expiry"
      number owner "SELECT count(*) FROM reservations WHERE state='held'" >>=assertion "negative schedule retains actual held reservation" . (==1)
      putStrLn "NEGATIVE TEARDOWN ONLY: advancing controlled expiry after recording shutdown failure"
      atomically(writeTVar time(reviewDeadlineNanos review))
      void(await(waitCatch scoped))
      error "active-retry shutdown regression"
    Just outcome->do
      either (error.show) pure outcome
      returned<-tryReadMVar reply
      assertion "retry refuses pending original cleanup before task join" (returned==Just(Left StateConflict))
      atomically(readTVar time)>>=assertion "successful scope shutdown did not advance review clock" . (==0)
      number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "scope shutdown signals and joins original prepared worker" . (==0)

-- The boundary mode requires the exact instrumented Commands slice.
interruptedAcceptanceChecks :: FilePath -> FilePath -> IO ()
interruptedAcceptanceChecks work native = do
  withFixture work native "interrupted-enqueue" 1 [("a",[])] $ \fixture@(Fixture _ _ owner _ proofs)->withAdmission owner $ \controller->do
    draft<-newDraft fixture 0 "a" "interrupted_enqueue"
    nonce<-key owner "interrupted_enqueue"
    Audit.withAcceptanceAudit $ \audit -> do
      caller<-async(enqueueRequest controller(proofs!!0)(draftId draft)nonce(etag draft)(body "enqueue"))
      (executing,command)<-Audit.waitAccepted audit
      original<-receiptBytes owner command
      number owner "SELECT count(*) FROM requests WHERE phase='queued'" >>=assertion "interruption rendezvous follows actual committed enqueue" . (==1)
      number owner "SELECT count(*) FROM reservations" >>=assertion "enqueue return gap has not launched or reserved a worker" . (==0)
      throwTo executing UserInterrupt
      assertInterrupted caller
      reply<-enqueueRequest controller(proofs!!0)(draftId draft)nonce(etag draft)(body "enqueue")>>=right
      assertion "interrupted enqueue exact retry returns immutable committed receipt" (encoded reply==original)
      number owner "SELECT count(*) FROM commands WHERE operation='enqueue'" >>=assertion "interrupted enqueue creates one durable command" . (==1)
      live<-admit controller
      review<-await(awaitReview live)>>=right
      assertion "interrupted enqueue reconciles original association into real preparation" (reviewRequest review==draftId draft)
      (reconciled,delivered,sameTicket,sameAttempt)<-Audit.auditSummary audit
      assertion "enqueue reconciliation retains original attempt and dispatch cell" (reconciled==1 && delivered==0 && sameTicket && sameAttempt)
  withFixture work native "interrupted-cleanup" 1 [("a",["shared"])] $ \fixture@(Fixture root _ owner _ proofs)->withAdmission owner $ \controller->do
    draft<-newDraft fixture 0 "a" "interrupted_cleanup"
    _<-enqueue controller fixture 0 draft "interrupted_cleanup"
    live<-admit controller
    void(await(awaitReview live)>>=right)
    bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database ->
      SQL.exec database "CREATE TRIGGER hold_interrupted_release BEFORE UPDATE OF state ON reservations WHEN NEW.state='released' BEGIN SELECT RAISE(ABORT,'controlled publication failure'); END"
    current<-viewNow fixture 0(draftId draft)
    nonce<-key owner "interrupted_withdraw"
    Audit.withAcceptanceAudit $ \audit -> do
      caller<-async(withdrawRequest controller(proofs!!0)(draftId draft)nonce(etag current)(body "withdraw"))
      (executing,command)<-Audit.waitAccepted audit
      original<-receiptBytes owner command
      number owner "SELECT count(*) FROM reservations WHERE state='cleanup-pending'" >>=assertion "interruption boundary has committed live cleanup intent" . (==1)
      number owner "SELECT count(*) FROM reservation_resources" >>=assertion "committed return gap retains original complete claims" . (==1)
      number owner "SELECT count(*) FROM commands WHERE operation='withdraw' AND attempted_at IS NOT NULL" >>=assertion "unpublished cleanup continuation has not dispatched" . (==0)
      throwTo executing UserInterrupt
      assertInterrupted caller
      cleanup<-await(awaitAdmissionCleanup live)
      assertion "interrupted cleanup reconciles original ticket but retains claims on SQL failure" (cleanup==Left StorageUnavailable)
      (reconciled,delivered,sameTicket,sameAttempt)<-Audit.auditSummary audit
      assertion "interrupted live cleanup uses original attempt and original ticket state" (reconciled==1 && delivered==1 && sameTicket && sameAttempt)
      number owner "SELECT count(*) FROM reservation_resources" >>=assertion "no premature release after interrupted cleanup publication" . (==1)
      reply<-withdrawRequest controller(proofs!!0)(draftId draft)nonce(etag current)(body "withdraw")>>=right
      assertion "interrupted cleanup exact retry keeps original accepted receipt" (encoded reply==original && receiptState reply==Accepted)
      bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database ->SQL.exec database "DROP TRIGGER hold_interrupted_release"
      retryAdmissionCleanup live>>=right
      finalReply<-withdrawRequest controller(proofs!!0)(draftId draft)nonce(etag current)(body "withdraw")>>=right
      assertion "joined cleanup does not rewrite immutable original receipt" (encoded finalReply==original)
      (_,finalDeliveries,finalSameTicket,finalSameAttempt)<-Audit.auditSummary audit
      assertion "interrupted cleanup and exact retries dispatch at most once" (finalDeliveries==1 && finalSameTicket && finalSameAttempt)
      number owner "SELECT count(*) FROM reservations WHERE state!='released'" >>=assertion "original native cleanup confirms final reservation release" . (==0)
      number owner "SELECT count(*) FROM commands WHERE operation='withdraw' AND state='effect-observed'" >>=assertion "original cleanup effect commits with release" . (==1)
  where
    receiptBytes owner command=runRead owner $ do
      rows<-query "SELECT receipt FROM commands WHERE id=?" [SQL.SQLText command]
      case rows of [[SQL.SQLBlob bytes]]->pure bytes;_->refuseTransaction StoreIntegrity
    assertInterrupted caller=do
      outcome<-await(waitCatch caller)
      assertion "original command thread interruption survives reconciliation and publication" (case outcome of
        Left failure->case fromException failure of Just UserInterrupt->True;_->False
        Right _->False)
