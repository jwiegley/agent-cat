{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | One live coordinator and bounded indexes of its original owned associations.
module Agentic.Manager.Service
  ( Service, ServiceFault (..), withService, serviceStore, serviceFault,
    enqueue, editInput, withdraw, approve, controlRun, controlDecision, readControl, withControl,
    withSnapshot, withSnapshotSource, withOverviewSource, withRun, withOutputs, withOutputsSource, download
  ) where

import qualified Agentic.Manager.Admission as A
import qualified Agentic.Manager.Approval as Approval
import qualified Agentic.Manager.Artifacts as Artifacts
import Agentic.Manager.Authorization (CredentialProof, AuthorizedView, withAuthorizedCatalogueContext)
import qualified Agentic.Manager.History as History
import qualified Agentic.Manager.Overview as Overview
import Agentic.Manager.Commands (submissionReceipt)
import Data.Aeson.Types (Pair)
import Agentic.Manager.Profile (ConfigurationLimits)
import Agentic.Manager.Protocol.Command
import qualified Agentic.Manager.Protocol.Preparation as P
import qualified Agentic.Manager.State as State
import qualified Agentic.Manager.Observation as Observation
import Agentic.Manager.Store (CoordinationStore, StoreFailure (..), withStoreFiles)
import Agentic.Manager.Worker (WorkerFailure, WorkerObservation (..))
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
import GHC.Clock (getMonotonicTimeNSec)

-- | Fixed internal faults. No exception text, credentials or private input is retained.
data ServiceFault = CommandFault !CommandFailure | StoreFault !StoreFailure
  | WorkerFault !WorkerFailure | UnexpectedFault deriving (Eq, Show)

-- | The original preparation's current public handoff, never authority from an ID.
data Phase = Preparing | Reviewing !Approval.ReviewedPreparation
  | Following !Approval.ReviewedPreparation !A.AcceptedStart !State.RunAssociation
  | Retired !(Maybe State.RunAssociation)

data Completion = Completion !(Maybe State.RunAssociation) !(Maybe ServiceFault)
  !(Either CommandFailure ()) !(Maybe WorkerObservation)

data Owned = Working !A.LivePreparation !(TVar Phase) !(Async Completion)
  | Held !A.LivePreparation !Completion

-- | A Store lifetime with at most sixteen retained preparation/ingestion tasks.
data Service = Service
  { serviceStore :: !CoordinationStore, admission :: !A.Admission,
    stopping :: !(TVar Bool), owned :: !(TVar (Map.Map Text Owned)),
    faultCell :: !(TVar (Maybe ServiceFault)), scheduler :: !(TMVar (Async ())) }

serviceFault :: Service -> IO (Maybe ServiceFault)
serviceFault = readTVarIO . faultCell

withService :: CoordinationStore -> (Service -> IO a) -> IO a
withService current action = A.withAdmission current $ \controller -> mask $ \restore -> do
  service <- Service current controller <$> newTVarIO False <*> newTVarIO Map.empty
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

-- Each notification denotes new queue or released-reservation facts. Only a
-- proven unentered configuration callback keeps that notification pending.
-- Opaque failures are recorded, never retried by the timer or made cancellation.
fill :: Service -> IO Bool
fill service = do
  room <- atomically $ do
    closing <- readTVar (stopping service)
    count <- Map.size <$> readTVar (owned service)
    pure (not closing && count < 16)
  if not room then pure False else do
    outcome <- try @SomeException (A.pollAdmission (admission service))
    case outcome of
      Left failure | Just asynchronous <- (fromException failure :: Maybe SomeAsyncException) -> throwIO asynchronous
      Left failure -> atomically (writeTVar (faultCell service) (Just (fault failure))) >> pure False
      Right (Left failure) -> atomically (writeTVar (faultCell service) (Just (CommandFault failure))) >> pure False
      Right (Right A.AdmissionDeferred) -> pure True
      Right (Right A.AdmissionIdle) -> atomically (writeTVar (faultCell service) Nothing) >> pure False
      Right (Right (A.AdmissionReady live)) -> do
        atomically (writeTVar (faultCell service) Nothing)
        startLoan service live >> fill service

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
  association <- atomically $ do
    current <- readTVar phase
    let remembered = case current of Following _ _ value -> Just value; Retired value -> value; _ -> Nothing
    writeTVar phase (Retired remembered)
    pure remembered
  A.requestPreparationStop live
  cleanup <- A.awaitAdmissionCleanup live
  observation <- A.observeLivePreparation live
  pure (Completion association (either (Just . fault) (const Nothing) outcome) cleanup observation)

-- Only typed contention retries the exact original retained ingestion head.
ingest :: A.AcceptedStart -> IO ()
ingest original = do
  more <- State.ingestAcceptedStart original `catch` firstBusy
  when more (ingest original)
  where
    firstBusy failure = case failure of
      StoreBusy -> getMonotonicTimeNSec >>= \now -> sameHead (now + 5000000000)
      _ -> throwIO failure
    sameHead deadline = do
      threadDelay 10000
      now <- getMonotonicTimeNSec
      when (now >= deadline) (throwIO StoreBusy)
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
    Just start -> State.withControlSurface start proof respond
    Nothing -> State.withClosedControlSurface (serviceStore service) proof association respond

withOverviewSource :: Service -> CredentialProof
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text,[Pair],[Value]) -> IO a) -> IO a
withOverviewSource service proof = Overview.withOverviewSource (serviceStore service) proof (Just (admission service))

withRun :: Service -> CredentialProof -> Text -> (AuthorizedView -> Value -> IO a) -> IO a
withRun service proof ident respond = withStoreFiles (serviceStore service) $ \root ->
  withAuthorizedCatalogueContext (serviceStore service) proof [Observe] $ \view _ _ _ invocations ->
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

download :: Service -> CredentialProof -> Text -> (AuthorizedView -> Value -> BS.ByteString -> IO a) -> IO a
download service = Artifacts.withArtifactDownload (serviceStore service)

need :: Either CommandFailure a -> IO a
need = either throwIO pure

fault :: SomeException -> ServiceFault
fault exception
  | Just value <- fromException exception = CommandFault value
  | Just value <- fromException exception = StoreFault value
  | Just value <- fromException exception = WorkerFault value
  | otherwise = UnexpectedFault
