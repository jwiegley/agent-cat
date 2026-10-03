{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | One live coordinator and bounded indexes of its original owned associations.
module Agentic.Manager.Service
  ( Service, withService, withServiceRequest, serviceStore, serviceFault, wakeAdmission, drain, draining,
    enqueue, editInput, withdraw, approve, discard, submitExport, submitLineage, controlRun, controlDecision, readControl, withControl,
    withSnapshot, withSnapshotSource, withOverviewSource, Overview.Collection (..), withCollectionSource,
    withRun, withOutputs, withOutputsSource, withExportsSource, withExport, withLineageSource, download
  ) where

import qualified Agentic.Manager.Admission as A
import qualified Agentic.Manager.Approval as Approval
import qualified Agentic.Manager.Artifacts as Artifacts
import qualified Agentic.Manager.Drafts as Drafts
import Agentic.Manager.Authorization (CredentialProof, AuthorizedView, attachResponseLoan, withAuthorizedCatalogueContext)
import Agentic.Manager.Fault (FaultClass (CommandRefusal), classifyFault, recordFault)
import qualified Agentic.Manager.History as History
import qualified Agentic.Manager.Overview as Overview
import Agentic.Manager.Pages (Producer)
import Agentic.Manager.Commands (CommandRequest (..), submissionReceipt)
import Data.Aeson.Types (Pair)
import Agentic.Manager.Profile (ConfigurationLimits, publicId)
import Agentic.Manager.Protocol.Command
import qualified Agentic.Manager.Protocol.Preparation as P
import qualified Agentic.Manager.State as State
import qualified Agentic.Manager.Observation as Observation
import Agentic.Manager.Store (CoordinationStore, StoreFailure (..), refuseBusy, withStoreFileLoan, withStoreRequest)
import qualified Agentic.Manager.Store.Admission as SA
import Agentic.Manager.Worker (WorkerObservation (..))
import Agentic.Runtime (FrontendPrepared (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, asyncWithUnmask, link, poll, waitCatch, withAsync)
import Control.Concurrent.STM
import Control.Exception (SomeException, SomeAsyncException, fromException, mask, mask_, onException, throwIO, try, catch)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)

-- | The original preparation's current public handoff, never authority from an ID.
data Phase = Preparing | Reviewing !Approval.ReviewedPreparation
  | Following !Approval.ReviewedPreparation !A.AcceptedStart !State.RunAssociation
  | Retired !(Maybe State.RunAssociation)

-- | The fault is the fixed classification of 'Agentic.Manager.Fault'. No
-- exception text, credentials or private input is retained.
data Completion = Completion !(Maybe State.RunAssociation) !(Maybe FaultClass)
  !(Either CommandFailure ()) !(Maybe WorkerObservation)

data Owned = Working !A.LivePreparation !(TVar Phase) !(Async Completion)
  | Held !A.LivePreparation !Completion

-- | A Store lifetime with at most sixteen retained preparation/ingestion tasks,
-- and the legacy retention roots that its run resources list read-only.
data Service = Service
  { serviceStore :: !CoordinationStore, admission :: !A.Admission, legacyHistory :: ![History.LegacyHistory],
    stopping :: !(TVar Bool), owned :: !(TVar (Map.Map Text Owned)),
    faultCell :: !(TVar (Maybe FaultClass)), scheduler :: !(TMVar (Async ())) }

-- | One HTTP route of this service. The callback receives the same service
-- with the request store of 'withStoreRequest', so every Store action that an
-- owner runs through that store, every nested scope of the store and every
-- attempt of a repeated read share one admission deadline. The deadline
-- starts when this scope starts. A value that the route keeps after it ends,
-- such as a command attempt or a dispatch ticket, keeps a store without the
-- request scope.
withServiceRequest :: Service -> (Service -> IO a) -> IO a
withServiceRequest service action = withStoreRequest (serviceStore service) $ \request ->
  action service {serviceStore = request}

serviceFault :: Service -> IO (Maybe FaultClass)
serviceFault = readTVarIO . faultCell

-- | Tell the admission controller of this service that a released
-- reservation freed capacity, as the release of a terminal run does, so that
-- the scheduler polls admission again without another client command.
wakeAdmission :: Service -> IO ()
wakeAdmission = atomically . A.notifyAdmission . admission

-- | Begin the drain of this service and return at once. New admission work
-- refuses with @storage-unavailable@ for the rest of the lifetime, the
-- scheduler stops polling admission, each preparation whose start has not
-- committed stops and returns its request to the queue, and the owned runs
-- continue with their controls. Reads and event streams keep serving until
-- the service scope ends. See 'A.beginDrain'.
drain :: Service -> IO ()
drain = A.beginDrain . admission

-- | Whether this service no longer admits new work: a drain or a shutdown
-- has begun.
draining :: Service -> IO Bool
draining = atomically . A.admissionClosed . admission

-- | The service of one Store lifetime. The legacy bindings come from
-- 'History.bindLegacyHistory' and are never controllable.
withService :: CoordinationStore -> [History.LegacyHistory] -> (Service -> IO a) -> IO a
withService current legacy action = A.withAdmission current $ \controller -> mask $ \restore -> do
  service <- Service current controller legacy <$> newTVarIO False <*> newTVarIO Map.empty
    <*> newTVarIO Nothing <*> newEmptyTMVarIO
  withAsync (restore (schedule service)) $ \driver -> do
    atomically (putTMVar (scheduler service) driver)
    link driver
    result <- try @SomeException (restore (action service))
    ended <- try @SomeException (shutdownService service)
    case result of
      Left failure -> throwIO failure
      Right value -> either throwIO (const (pure value)) ended

-- The service scope stops its original Admission controller before joining the
-- ingestion tasks. An HTTP waiter never invokes this operation.
shutdownService :: Service -> IO ()
shutdownService service = mask_ $ do
  atomically (writeTVar (stopping service) True)
  driver <- atomically (readTMVar (scheduler service))
  driverResult <- waitCatch driver
  stopped <- try @SomeException (A.shutdownAdmission (admission service) A.CancelNow)
  jobs <- Map.elems <$> readTVarIO (owned service)
  results <- forM jobs $ \job -> case job of
    Held _ completion -> pure (Right completion)
    Working _ _ task -> waitCatch task
  either throwIO (need . A.shutdownCleanup) stopped
  either throwIO pure driverResult
  forM_ results $ \result -> do
    Completion _ _ cleanup observation <- either throwIO pure result
    need cleanup
    when (maybe False observedCleanupUnproven observation) (throwIO OwnershipUnavailable)

schedule :: Service -> IO ()
schedule service = loop False
  where
    loop pending = do
      released <- reap service
      closing <- readTVarIO (stopping service)
      unless closing $ do
        deferred <- if released || pending then fill service else pure False
        timer <- registerDelay 100000
        event <- atomically $
          (readTVar (stopping service) >>= check >> pure Nothing)
          `orElse` (A.awaitAdmissionWork (admission service) >> pure (Just True))
          `orElse` (readTVar timer >>= check >> pure (Just False))
        case event of
          Nothing -> pure ()
          Just changed -> loop (deferred || changed)

-- Each notification denotes new queue or released-reservation facts. A
-- closed Admission controller, as during a drain, is not polled, so a drain
-- records no fault. Only a
-- proven unentered configuration callback keeps that notification pending.
-- Opaque failures are recorded in the fault cell and the private log. They
-- are never retried by the timer or made cancellation.
--
-- With sixteen owned preparations the poll reserves nothing. It still brings
-- the blocking reasons of the queue up to date, so that a request queued
-- behind sixteen reservations names capacity.
fill :: Service -> IO Bool
fill service = do
  (closing, count) <- atomically $ (,) <$> ((||) <$> readTVar (stopping service) <*> A.admissionClosed (admission service))
    <*> (Map.size <$> readTVar (owned service))
  if closing then pure False else do
    outcome <- try @SomeException (A.refreshAdmission (count < 16) (admission service))
    case outcome of
      Left failure | Just asynchronous <- (fromException failure :: Maybe SomeAsyncException) -> throwIO asynchronous
      Left failure -> faulted (classifyFault failure)
      -- A drain that began during this poll closes the fence before the
      -- poll's transaction, and that refusal is not a fault.
      Right (Left failure) -> do
        drained <- atomically (A.admissionClosed (admission service))
        if drained then pure False else faulted (CommandRefusal failure)
      Right (Right A.AdmissionDeferred) -> pure True
      Right (Right A.AdmissionIdle) -> atomically (writeTVar (faultCell service) Nothing) >> pure False
      Right (Right (A.AdmissionReady live)) -> do
        atomically (writeTVar (faultCell service) Nothing)
        startLoan service live >> fill service
  where
    faulted problem = do
      recordFault "service admission-poll" problem
      atomically (writeTVar (faultCell service) (Just problem))
      pure False

startLoan :: Service -> A.LivePreparation -> IO ()
startLoan service live = mask_ $ do
  phase <- newTVarIO Preparing
  start <- newEmptyTMVarIO
  task <- asyncWithUnmask (\unmask -> atomically (readTMVar start) >> unmask (drive service live phase))
    `onException` A.requestPreparationStop live
  atomically $ do
    modifyTVar' (owned service) (Map.insert (A.reservationIdentity live) (Working live phase task))
    putTMVar start ()

drive :: Service -> A.LivePreparation -> TVar Phase -> IO Completion
drive service live phase = mask $ \restore -> do
  outcome <- try @SomeException $ restore $ do
    context <- A.awaitReview live >>= need
    reviewed <- Approval.publishReview (serviceStore service) live >>= need
    atomically (writeTVar phase (Reviewing reviewed))
    accepted <- A.awaitAcceptedStart live
    forM_ accepted $ \original -> do
      let public = Approval.reviewedView reviewed
          native = A.reviewNative context
          association = State.RunAssociation (A.acceptedStartRun original) (P.preparationProfile public)
            (preparedRootIdentity native) (preparedRunId native)
      atomically (writeTVar phase (Following reviewed original association))
      ingest original
  let problem = either (Just . classifyFault) (const Nothing) outcome
  association <- atomically $ do
    current <- readTVar phase
    let remembered = case current of Following _ _ value -> Just value; Retired value -> value; _ -> Nothing
    writeTVar phase (Retired remembered)
    pure remembered
  A.requestPreparationStop live
  cleanup <- A.awaitAdmissionCleanup live
  observation <- A.observeLivePreparation live
  -- The private record follows original-owner cleanup, so a slow log write
  -- cannot delay the stop request or the cleanup join.
  forM_ problem (recordFault ("service preparation " <> A.reservationIdentity live))
  pure (Completion association problem cleanup observation)

-- Only typed contention retries the exact original retained ingestion head.
ingest :: A.AcceptedStart -> IO ()
ingest original = do
  more <- State.ingestAcceptedStart original `catch` firstBusy
  when more (ingest original)
  where
    firstBusy failure = case failure of
      StoreBusy -> SA.newDeadline >>= sameHead
      _ -> throwIO failure
    sameHead deadline = do
      threadDelay 10000
      left <- try @SA.AdmissionFailure (SA.remainingMicros deadline)
      either (const (refuseBusy "service-ingestion-head" (Just deadline))) (const (pure ())) left
      State.ingestAcceptedStart original `catch` \failure -> case failure of
        StoreBusy -> sameHead deadline
        _ -> throwIO failure

reap :: Service -> IO Bool
reap service = do
  jobs <- Map.toList <$> readTVarIO (owned service)
  freed <- forM jobs $ \(ident,job) -> case job of
    Held _ _ -> pure False
    Working live _ task -> do
      finished <- poll task
      case finished of
        Nothing -> pure False
        Just _ -> do
          completion@(Completion _ problem cleanup observation) <- waitCatch task >>= either throwIO pure
          let retain = cleanup /= Right () || maybe False (\w -> observedQueuedFrames w > 0 || observedCleanupUnproven w) observation
          atomically $ do
            forM_ problem (writeTVar (faultCell service) . Just)
            modifyTVar' (owned service) $
              if retain then Map.insert ident (Held live completion) else Map.delete ident
          pure (not retain)
  pure (or freed)

phases :: Service -> IO [Phase]
phases service = atomically $ do
  jobs <- Map.elems <$> readTVar (owned service)
  mapM readTVar [phase | Working _ phase _ <- jobs]

reviewFor :: Service -> Text -> IO (Maybe Approval.ReviewedPreparation)
reviewFor service ident = do
  current <- phases service
  pure $ listToMaybe [reviewed | phase <- current,
    reviewed <- case phase of Reviewing value -> [value]; Following value _ _ -> [value]; _ -> [],
    P.preparationId (Approval.reviewedView reviewed) == ident]

startFor :: Service -> Text -> IO (Maybe A.AcceptedStart)
startFor service ident = do
  current <- phases service
  pure $ listToMaybe [original | Following _ original _ <- current, A.acceptedStartRun original == ident]

enqueue :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
enqueue service = A.enqueueRequest (admission service)

editInput :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
editInput service = A.editRequestInput (admission service)

withdraw :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
withdraw service = A.withdrawRequest (admission service)

approve :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
approve service proof ident key condition body = do
  original <- reviewFor service ident
  case original of
    Just reviewed -> Approval.approve reviewed proof key condition body
    Nothing -> Approval.replayApproval (serviceStore service) proof ident key condition body

-- | Discard the review of the original live preparation. Without it, only an
-- exact cached receipt replays.
discard :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
discard service proof ident key condition body = do
  original <- reviewFor service ident
  case original of
    Just reviewed -> Approval.discard reviewed proof key condition body
    Nothing -> Approval.replayDiscard (serviceStore service) proof ident key condition body

-- | Export the verified result of one run under a single-component name. The
-- run resolves under the scopes of the export operation, and the export owner
-- decodes the body strictly, checks the collection precondition, records the
-- acceptance and publishes once. An exact retry returns the original receipt
-- without another publication.
submitExport :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
submitExport service proof ident key condition body = do
  association <- State.resolveRun (serviceStore service) proof (requiredScopes Export) ident
  let request = CommandRequest Export (State.associationProfile association) "POST"
        ("/v1/runs/" <> State.associationRun association <> "/exports") key "application/json" condition body
  fmap submissionReceipt <$> Artifacts.submitExport (serviceStore service) proof association request

-- | Create a restart, resume or fork request of one parent run. The run
-- resolves under the scopes of the lineage operations, and the history owner
-- refuses a legacy observation entry. Otherwise the draft owner decodes the
-- body strictly, checks the parent revision precondition and eligibility, and
-- creates the child draft once. An exact retry returns the original receipt.
submitLineage :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
submitLineage service proof ident key condition body = do
  association <- State.resolveRun (serviceStore service) proof (requiredScopes Restart) ident
  History.createHistoryLineage (serviceStore service) proof (State.associationRun association) key condition body

controlRun :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
controlRun service proof ident key condition body = do
  association <- State.resolveRun (serviceStore service) proof [Control] ident
  original <- startFor service ident
  fmap (fmap submissionReceipt) $ case original of
    Just start -> State.dispatchRunControl start proof key condition body
    Nothing -> State.replayControl (serviceStore service) proof association Nothing key condition body

controlDecision :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
controlDecision service proof decision key condition body = do
  association <- State.resolveDecision (serviceStore service) proof [Control] decision
  original <- startFor service (State.associationRun association)
  fmap (fmap submissionReceipt) $ case original of
    Just start -> State.dispatchDecisionControl start proof decision key condition body
    Nothing -> State.replayControl (serviceStore service) proof association (Just decision) key condition body

readControl :: Service -> CredentialProof -> Text -> IO Value
readControl service proof ident = withControl service proof ident (\_ -> pure)

withControl :: Service -> CredentialProof -> Text -> (AuthorizedView -> Value -> IO a) -> IO a
withControl service proof ident respond = do
  association <- State.resolveRun (serviceStore service) proof [Observe] ident
  original <- startFor service ident
  case original of
    Just start -> State.withControlSurface (serviceStore service) start proof respond
    Nothing -> State.withClosedControlSurface (serviceStore service) proof association respond

withOverviewSource :: Service -> CredentialProof
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text,[Pair],[Value]) -> IO a) -> IO a
withOverviewSource service proof = Overview.withOverviewSource (serviceStore service) proof (Just (admission service))

-- | One frozen request, run or decision collection with this service's
-- original Admission, so that managed supervision reads as the detail
-- resources read it. The run collection also lists the legacy entries of the
-- bound retention roots of the observable profiles. Their handles are
-- retained before the source takes its loans, and each window decodes only
-- its own legacy entries.
withCollectionSource :: Service -> CredentialProof -> Overview.Collection
  -> (AuthorizedView -> ConfigurationLimits -> Producer -> IO a) -> IO a
withCollectionSource service proof collection respond = do
  legacy <- case collection of
    Overview.Runs -> History.retainLegacyHandles (serviceStore service) proof (legacyHistory service)
    _ -> pure []
  Overview.withCollectionSource (serviceStore service) proof (Just (admission service)) legacy collection respond

-- | One managed run, or one legacy entry of a bound retention root, in the
-- representation of its run collection item. A legacy read decodes only the
-- entry that its handle names.
withRun :: Service -> CredentialProof -> Text -> (AuthorizedView -> Value -> IO a) -> IO a
withRun service proof ident respond = do
  legacy <- History.legacyRun (serviceStore service) proof (legacyHistory service) ident
  withStoreFileLoan (serviceStore service) $ \files root ->
    withAuthorizedCatalogueContext (serviceStore service) proof [Observe] $ \view _ visible _ invocations -> do
      attachResponseLoan view files
      case legacy of
        Just entry -> do
          unless (History.legacyRunProfile entry `elem` map (publicId . fst) visible) (throwIO ResourceUnavailable)
          respond view (History.legacyRunValue entry)
        Nothing ->
          History.managedRunInView (serviceStore service) root proof view (Just (admission service)) invocations ident >>= respond view

withSnapshot :: Service -> CredentialProof -> Text -> (AuthorizedView -> Observation.SnapshotProjection -> IO a) -> IO a
withSnapshot service = Observation.withRunSnapshot (serviceStore service)

withSnapshotSource :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO Observation.SnapshotProjection -> IO a) -> IO a
withSnapshotSource service = Observation.withRunSnapshotSource (serviceStore service)

withOutputs :: Service -> CredentialProof -> Text -> (AuthorizedView -> [Value] -> IO ()) -> IO ()
withOutputs service proof ident respond = do
  association <- State.resolveRun (serviceStore service) proof [Observe] ident
  Artifacts.withRunOutputs (serviceStore service) proof association respond

withOutputsSource :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO [Value] -> IO a) -> IO a
withOutputsSource service proof ident respond = do
  association <- State.resolveRun (serviceStore service) proof [Observe] ident
  Artifacts.withRunOutputsSource (serviceStore service) proof association respond

-- | The export receipts of one run and their collection revision. A run of
-- a profile that the credential cannot observe refuses as the other run
-- resources refuse.
withExportsSource :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text, [Value]) -> IO a) -> IO a
withExportsSource service proof ident respond = do
  association <- State.resolveRun (serviceStore service) proof [Observe] ident
  Artifacts.withRunExportsSource (serviceStore service) proof association respond

withExport :: Service -> CredentialProof -> Text -> (AuthorizedView -> Value -> IO a) -> IO a
withExport service = Artifacts.withExport (serviceStore service)

-- | The lineage-request collection of one parent run, with the same run
-- refusal as the other run resources.
withLineageSource :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO Drafts.LineageRequests -> IO a) -> IO a
withLineageSource service proof ident respond = do
  _ <- State.resolveRun (serviceStore service) proof [Observe] ident
  Drafts.withLineageRequestsSource (serviceStore service) proof ident respond

download :: Service -> CredentialProof -> Text -> (AuthorizedView -> Value -> BS.ByteString -> IO a) -> IO a
download service = Artifacts.withArtifactDownload (serviceStore service)

need :: Either CommandFailure a -> IO a
need = either throwIO pure

