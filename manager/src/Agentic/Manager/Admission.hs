{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Explicit oldest-eligible admission and retained native preparation ownership.
module Agentic.Manager.Admission
  ( Admission, LivePreparation, ReviewContext (..), MonotonicClock (..),
    withAdmission, withAdmissionClock, enqueueRequest, admitOldest,
    editRequestInput, withdrawRequest, awaitReview, withReviewAcceptance,
    retryAdmissionCleanup, awaitAdmissionCleanup, closeAdmission, reservationIdentity, observeLivePreparation,
    acceptControlCommand, deliverAcceptedControl, acceptedControlContext,
    AcceptedStart, acceptStartCommand, deliverAcceptedStart, stopAcceptedStart, observeAcceptedStart, acceptedStartRun, acceptedTimerRetired, invalidateLivePreparation, consumeAcceptedStart
  ) where

import Agentic.Manager.Admission.Policy
import Agentic.Manager.Authorization
import Agentic.Manager.Commands
import Agentic.Manager.Drafts
import Agentic.Manager.Profile
  (ConfigurationLimits (..), Discovery, discoverySelection, discoveryProfileRevision,
   discoveryRevision, discoveryEntries, selectionContext, Selection, OperatorProfile (..), publicId, publicRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Draft (DraftView (..))
import Agentic.Manager.Protocol.Preparation (ReviewInput)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Store
import Agentic.Manager.Worker
import Agentic.Runtime (FrontendPrepared (..), FrontendSetupRequest, RunId (..), Control (controlId), ControlId (..), decodeControlFor, encodeControlFor, correlatedProtocolVersion, controlAcknowledgementLimit)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, waitCatch, poll, race)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
  (STM, TVar, TMVar, atomically, newTVarIO, readTVar, writeTVar, modifyTVar',
   newEmptyTMVarIO, readTMVar, tryReadTMVar, putTMVar, tryPutTMVar, swapTMVar, check, throwSTM)
import Control.DeepSeq (NFData)
import Control.Exception (SomeException, mask, uninterruptibleMask_, finally, onException, try, throwIO, fromException)
import Control.Monad (forM, forM_, unless, when, void)
import Crypto.Random (getRandomBytes)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON, Value, eitherDecodeStrict', object, (.=))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.List
import qualified Database.SQLite3 as SQL
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)

-- | Environmental monotonic time and waiting, not persisted timer authority.
data MonotonicClock = MonotonicClock
  { monotonicNow :: IO Word64, monotonicUntil :: Word64 -> IO () }

realClock :: MonotonicClock
realClock = MonotonicClock getMonotonicTimeNSec waitUntil
  where
    waitUntil target = do
      now <- getMonotonicTimeNSec
      when (now < target) $ do
        threadDelay (fromIntegral (min 1000000 ((target-now+999) `div` 1000)))
        waitUntil target

-- | Current observed review facts, not the complete WM-014 public review or approval.
data ReviewContext = ReviewContext
  { reviewRequest :: !Text, reviewRequestRevision :: !Text, reviewProfileRevision :: !Text,
    reviewReservation :: !Text, reviewGeneration :: !Text, reviewDeadlineNanos :: !Word64,
    reviewNative :: !FrontendPrepared, reviewSelection :: !Selection, reviewInputSummaries :: ![ReviewInput], reviewSetup :: !FrontendSetupRequest }

-- | One scoped controller, associated with one actual Store lifetime.
data Admission = Admission
  { store :: !CoordinationStore, clock :: !MonotonicClock,
    gate :: !(MVar ()), closed :: !(TVar Bool), liveStore :: !(TVar (STM Bool)),
    queued :: !(TVar (Map.Map Text AcceptedEnqueue)), entries :: !(TVar (Map.Map Text Entry)),
    attempts :: !(TVar (Map.Map Text CommandAttempt)),
    operations :: !(TVar [TMVar (Maybe (Async ()))]), finished :: !(TMVar (Either CommandFailure ())) }

-- | A loan of the original live association. It exposes no native Worker constructor.
data LivePreparation = LivePreparation !Admission !Entry
reservationIdentity :: LivePreparation -> Text
reservationIdentity (LivePreparation _ entry) = entryReservation entry

data Entry = Entry
  { entryRequest :: !Text, entryReservation :: !Text, entryGeneration :: !Text,
    entryProfile :: !Text, entryPolicy :: !Text, entryPermit :: !AcceptedEnqueue,
    entryWorker :: !(TMVar FrontendWorker),
    entryReview :: !(TMVar (Either CommandFailure ReviewContext)), entryRetiredTimer :: !(TVar Bool),
    entryStop :: !(TMVar Stop), entryTask :: !(TMVar (Maybe (Async ()))),
    entryFinal :: !(TVar (Maybe Finalization)), entryDispatched :: !(TVar Bool), entryCleanupConfirmed :: !(TVar Bool), entryResult :: !(TMVar (Either CommandFailure ())), entryStart :: !(TVar (Maybe AcceptedStart)), entryControls :: !(TVar (Map.Map Text (Operation,DispatchTicket))), entryControlGate :: !(MVar ()) }

-- | One committed start association retaining its original one-shot ticket and Worker.
data AcceptedStart = AcceptedStart !Admission !Entry !DispatchTicket !Text
acceptedStartRun :: AcceptedStart -> Text
acceptedStartRun (AcceptedStart _ _ _ run) = run

data Stop = StopCommand !DispatchTicket !Text !Text | StopService !Text
-- Only this current in-memory operation may retry its own final publication.
data Finalization = Finalization !(Maybe DispatchTicket) !Text !Text

data QueueRow = QueueRow !Text !Text !Text !Text !Text !Text !Integer
  deriving (Generic, NFData)

withAdmission :: CoordinationStore -> (Admission -> IO a) -> IO a
withAdmission = withAdmissionClock realClock

withAdmissionClock :: MonotonicClock -> CoordinationStore -> (Admission -> IO a) -> IO a
withAdmissionClock timer owner action = mask $ \restore -> do
  controller <- Admission owner timer <$> newMVar () <*> newTVarIO False <*> newTVarIO (pure False)
    <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO [] <*> newEmptyTMVarIO
  ready <- newEmptyTMVarIO
  supervisor <- async $ do
    result <- try @SomeException $ withStoreAdmission owner $ \alive -> do
      atomically (writeTVar (liveStore controller) alive >> putTMVar ready ())
      atomically $ do
        ending <- readTVar (closed controller)
        current <- alive
        check (ending || not current)
      shutdown controller
    atomically $ do
      void(tryPutTMVar ready ())
      putTMVar (finished controller) (either (Left . classify) (const (Right ())) result)
  result <- try @SomeException (restore (atomically(readTMVar ready) >> ensureController controller >> action controller))
  ending <- try @SomeException $ uninterruptibleMask_ $ closeAdmission controller >> void(waitCatch supervisor)
  case result of Left failure -> throwIO failure; Right value -> either throwIO (const(pure value)) ending

closeAdmission :: Admission -> IO ()
closeAdmission controller = uninterruptibleMask_ $ do
  atomically(writeTVar(closed controller)True)
  atomically(readTMVar(finished controller)) >>= either throwIO pure

ensureController :: Admission -> IO ()
ensureController controller = atomically $ do
  stopping <- readTVar(closed controller)
  active <- readTVar(liveStore controller) >>= id
  unless (not stopping && active) (throwSTM StorageUnavailable)

-- A cancelled caller abandons only its wait, not the retained acceptance/cleanup job.
operation :: Admission -> IO a -> IO (Either CommandFailure a)
operation controller action = do
  outcome <- try @CommandFailure $ mask $ \restore -> do
    ensureController controller
    slot <- newEmptyTMVarIO
    start <- newEmptyTMVarIO
    result <- newEmptyTMVarIO
    atomically $ do
      stopping <- readTVar(closed controller)
      active <- readTVar(liveStore controller) >>= id
      unless (not stopping && active) (throwSTM StorageUnavailable)
      current <- readTVar(operations controller)
      when(length current>=16)(throwSTM StorageUnavailable)
      writeTVar(operations controller)(slot:current)
    worker <- (async $ (do
      atomically(readTMVar start)
      value <- try @SomeException action
      atomically(putTMVar result value)) `finally`
        atomically(modifyTVar'(operations controller)(filter (/=slot)))) `onException`
        atomically(putTMVar slot Nothing >> modifyTVar'(operations controller)(filter (/=slot)))
    atomically(putTMVar slot (Just worker) >> putTMVar start ())
    restore(atomically(readTMVar result)) >>= either (\failure -> case fromException failure :: Maybe StoreFailure of
      Just _ -> throwIO StorageUnavailable
      Nothing -> throwIO failure) pure
  pure outcome

locked :: Admission -> IO a -> IO a
locked controller action = withMVar(gate controller)(const action)

-- | Explicit queue intent, retaining a live accepted-operation association after commit.
enqueueRequest :: Admission -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either CommandFailure CommandReceipt)
enqueueRequest controller proof requestId key precondition body = operation controller $ do
  requireBody "enqueue" body
  metadata <- dbRead controller (requestState proof requestId [Submit])
  let view=requestView metadata
      request=CommandRequest Enqueue (draftProfile view) "POST" (requestURI requestId) key "application/json" precondition body
  replay <- commandPreflight (store controller) proof request (\_ _ _ exists -> pure(exists,[])) >>= need
  if replay then submissionReceipt <$> (submitConfiguredCommand (store controller) proof request (\_ _ _ -> Left StateConflict) >>= need)
  else do
    snapshot <- assembleDraftSnapshot (store controller) proof requestId >>= need
    revision <- fresh "request_revision_"
    generation <- storeProcessGeneration <$> storeIdentity(store controller)
    locked controller $ do
      ensureController controller
      currentQueue <- dbRead controller $ do
        rows <- query "SELECT id FROM requests WHERE phase='queued' LIMIT 101" []
        pure [ident | [SQL.SQLText ident] <- rows]
      held <- Map.keys <$> readTVarIO(entries controller)
      atomically(modifyTVar'(queued controller)(Map.restrictKeys `flip` Set.fromList(currentQueue<>held)))
      let builder commandId _ catalogues = do
            unless(currentPolicy catalogues (draftProfile view) (draftProfileRevision view) (draftWorkflow view) (draftDescriptorRevision view))(Left StaleRevision)
            Right $ Mutation (assemblyProfileRevision snapshot) (currentVersion proof requestId) $ do
              current <- requestState proof requestId [Submit]
              editable current
              unless (draftPhase(requestView current)=="draft" && draftRevision(requestView current)==assemblyRevision snapshot)(refuseTransaction StateConflict)
              count <- query "SELECT count(*) FROM requests WHERE phase='queued'" []
              unless(count==[[SQL.SQLInteger 0]] || case count of [[SQL.SQLInteger n]]->n<100;_->False)(refuseTransaction StateConflict)
              ordinal <- nextOrdinal
              pure $ Right $ Intent (noReferences{referenceRequest=Just requestId}) False $ do
                execute "UPDATE requests SET phase='queued',admission='waiting',input_revision=coalesce(input_revision,?),queue_ordinal=?,queue_origin_revision=?,queue_generation=?,enqueue_command=?,revision=?,blocking_reasons=? WHERE id=?"
                  [text(assemblyRevision snapshot),text ordinal,text revision,text generation,text commandId,text revision,SQL.SQLBlob(encoded([]::[Text])),text requestId]
                effect <- effectValueFor "enqueued" requestId
                pure([requestEvent requestId revision],Just effect)
      accepted <- submitRetained controller proof requestId "enqueue" request builder >>= need
      case submissionEnqueue accepted of
        Just permit -> atomically(modifyTVar'(queued controller)(Map.insert requestId permit))
        Nothing -> unless(submissionReplayed accepted)(throwIO StorageUnavailable)
      pure(submissionReceipt accepted)

-- | Atomically choose and reserve before any file wait or native preparation.
admitOldest :: Admission -> IO (Either CommandFailure (Maybe LivePreparation))
admitOldest controller = operation controller $ locked controller $ do
  ensureController controller
  pruneCompleted controller
  tracked <- readTVarIO(entries controller)
  permits <- atomically(readTVar(queued controller))
  reservation <- fresh "reservation_"
  revision <- fresh "request_revision_"
  generation <- storeProcessGeneration <$> storeIdentity(store controller)
  selected <- configured controller $ \limits catalogues -> runTransaction (store controller) $ do
    rows <- queueRows
    valid <- currentAcceptedEnqueues(Map.elems permits)
    occupancy <- heldRows
    ready <- structuralReadiness [ident | QueueRow ident _ _ _ _ _ _ <- rows]
    let candidate (QueueRow ident _ profile policy workflow descriptor ordinal) = Candidate ident ordinal
          (Set.member ident valid && currentPolicy catalogues profile policy workflow descriptor)
          (maybe False id(lookup ident ready)) (resourcesFor catalogues profile)
        candidates=map candidate rows
        foreignOwner=any (\(_,_,owner)->owner/=generation) occupancy
        held=[heldLease | (_,heldLease,_)<-occupancy]
        choice=if foreignOwner then Nothing else oldestEligible (limitExecutionReservations limits) held candidates
    events <- forM rows $ \row@(QueueRow ident _ _ _ _ _ _) -> do
      let facts=candidate row
          reasons :: [Text]
          reasons=if foreignOwner || not(candidateEnabled facts) then ["quarantined"] else
            if not(candidateReady facts) then ["missing-inputs"] else
            if length held>=limitExecutionReservations limits then ["capacity"] else
            if any (\(Held _ keys)->not(Set.disjoint keys(candidateResources facts))) held then ["profile-busy"] else []
      previous<-query "SELECT blocking_reasons FROM requests WHERE id=?" [text ident]
      if previous==[[SQL.SQLBlob(encoded reasons)]] then pure [] else do
        let changed=revision
        unless(T.length changed<=128)(refuseTransaction StorageUnavailable)
        execute "UPDATE requests SET blocking_reasons=?,revision=? WHERE id=?" [SQL.SQLBlob(encoded reasons),text changed,text ident]
        pure [requestEvent ident changed]
    case choice of
      Nothing -> pure(Nothing,concat events)
      Just(facts,slot) -> do
        when(Map.size tracked>=16 || Map.member(candidateRequest facts)tracked)(refuseTransaction StateConflict)
        permit <- maybe(refuseTransaction StateConflict)pure(Map.lookup(candidateRequest facts)permits)
        _ <- checkAcceptedEnqueue permit
        row <- maybe(refuseTransaction StateConflict)pure(findQueue(candidateRequest facts)rows)
        let QueueRow ident _ profile policy _ _ ordinal=row
        execute "INSERT INTO reservations (id,request_id,slot,process_generation,state,request_revision,profile_revision,queue_ordinal) VALUES (?,?,?,?,'held',?,?,?)"
          [text reservation,text ident,SQL.SQLInteger(fromIntegral slot),text generation,text revision,text policy,text(T.pack(show ordinal))]
        forM_ (groupsOf 64(Set.toList(candidateResources facts))) $ \keys -> execute
          ("INSERT INTO reservation_resources(kind,resource_key,reservation_id) VALUES "<>T.intercalate ","(replicate(length keys)"(?,?,?)"))
          (concat[resourceValues key<>[text reservation]|key<-keys])
        execute "UPDATE requests SET phase='preparing',admission='reserved',revision=?,blocking_reasons=? WHERE id=?"
          [text revision,SQL.SQLBlob(encoded([]::[Text])),text ident]
        pure(Just(ident,profile,policy),concat events<>[requestEvent ident revision])
  case selected of
    Nothing -> pure Nothing
    Just(ident,profile,policy) -> do
      permit <- maybe(throwIO StateConflict)pure(Map.lookup ident permits)
      entry <- Entry ident reservation generation profile policy permit <$> newEmptyTMVarIO <*> newEmptyTMVarIO <*> newTVarIO False <*> newEmptyTMVarIO <*> newEmptyTMVarIO <*> newTVarIO Nothing <*> newTVarIO False <*> newTVarIO False <*> newEmptyTMVarIO <*> newTVarIO Nothing <*> newTVarIO Map.empty <*> newMVar ()
      atomically $ modifyTVar'(entries controller)(Map.insert ident entry)
      start <- newEmptyTMVarIO
      task <- async (atomically(readTMVar start) >> runEntry controller entry) `onException`
        atomically(putTMVar(entryTask entry)Nothing >> putTMVar(entryResult entry)(Left StorageUnavailable) >> putTMVar(entryReview entry)(Left StorageUnavailable))
      atomically(putTMVar(entryTask entry)(Just task) >> putTMVar start ())
      pure(Just(LivePreparation controller entry))

observeLivePreparation :: LivePreparation -> IO (Maybe WorkerObservation)
observeLivePreparation (LivePreparation _ entry) = atomically(tryReadTMVar(entryWorker entry)) >>= traverse observeWorker

awaitReview :: LivePreparation -> IO (Either CommandFailure ReviewContext)
awaitReview (LivePreparation _ entry)=atomically(readTMVar(entryReview entry))

-- The callback is a short local acceptance transaction, not process or network IO.
withReviewAcceptance :: LivePreparation -> (ReviewContext -> CommitDeadline -> IO a) -> IO (Either CommandFailure a)
withReviewAcceptance (LivePreparation controller entry) action = operation controller $ locked controller $ do
  ensureController controller
  current <- currentReview controller entry
  worker <- atomically(readTMVar(entryWorker entry))
  result <- try @SomeException $ withWorkerCommitDeadline worker (store controller) (monotonicNow(clock controller)) (reviewDeadlineNanos current) (action current)
  committed <- try @SomeException(dbRead controller (startCommitted entry))
  case committed of Right True -> atomically(writeTVar(entryRetiredTimer entry)True); _->pure()
  either throwIO pure result

currentReview :: Admission -> Entry -> IO ReviewContext
currentReview controller entry = do
  value <- atomically(tryReadTMVar(entryReview entry)) >>= maybe(throwIO StateConflict)need
  worker <- atomically(readTMVar(entryWorker entry))
  observation <- observeWorker worker
  unless(observedWorkerPhase observation==WorkerPrepared && not(isJust(observedWorkerExit observation)))(throwIO StateConflict)
  now <- monotonicNow(clock controller)
  unless(now<reviewDeadlineNanos value)(throwIO StateConflict)
  revision <- configured controller $ \_ catalogues -> dbRead controller $ do
    _ <- checkAcceptedEnqueue(entryPermit entry)
    validateEntry entry ["review"] ["held"]
    rows <- query "SELECT revision,workflow_id,descriptor_revision FROM requests WHERE id=?" [text(entryRequest entry)]
    case rows of
      [[SQL.SQLText current,SQL.SQLText workflow,SQL.SQLText descriptor]] -> do
        unless(currentPolicy catalogues (entryProfile entry) (entryPolicy entry) workflow descriptor)(refuseTransaction StaleRevision)
        pure current
      _ -> refuseTransaction StateConflict
  pure value {reviewRequestRevision=revision}

runEntry :: Admission -> Entry -> IO ()
runEntry controller entry = do
  constructing <- newTVarIO False
  result <- try @SomeException $ do
    assembled <- assembleAcceptedDraft (store controller) (entryPermit entry) >>= need
    stoppedBeforeLaunch <- atomically(tryReadTMVar(entryStop entry))
    when(isJust stoppedBeforeLaunch)(throwIO WorkerClosed)
    atomically(writeTVar constructing True)
    withStartingFrontendWorker (store controller) (entryProfile entry) (entryPolicy entry) (assemblySetup assembled) $ \worker -> mask $ \restore -> do
      atomically(putTMVar(entryWorker entry)worker)
      outcome <- restore $ race (atomically(readTMVar(entryStop entry))) (workerPrepared worker)
      case outcome of
        Left stopping -> finishEntry controller entry worker stopping
        Right native -> do
          now <- monotonicNow(clock controller)
          published <- locked controller $ do
            pending <- atomically(tryReadTMVar(entryStop entry))
            case pending of
              Just _ -> pure Nothing
              Nothing -> do
                revision <- fresh "request_revision_"
                let deadline=now+600000000000
                dbChange controller $ do
                  validateEntry entry ["preparing"] ["held"]
                  execute "INSERT INTO admission_observations VALUES (?,?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'),strftime('%Y-%m-%dT%H:%M:%fZ','now','+600 seconds'),'prepared',NULL)"
                    [text(entryReservation entry),text(runIdText(preparedRunId native)),text(preparedRootIdentity native)]
                  execute "UPDATE requests SET phase='review',revision=? WHERE id=?" [text revision,text(entryRequest entry)]
                  execute "UPDATE reservations SET request_revision=? WHERE id=?" [text revision,text(entryReservation entry)]
                  pure((),[requestEvent(entryRequest entry)revision])
                let review=ReviewContext(entryRequest entry)revision(entryPolicy entry)(entryReservation entry)(entryGeneration entry)deadline native (assemblySelection assembled) (assemblyInputSummaries assembled) (assemblySetup assembled)
                atomically(putTMVar(entryReview entry)(Right review))
                pure(Just deadline)
          stopping <- case published of
            Nothing -> atomically(readTMVar(entryStop entry))
            Just deadline -> do
              outcome' <- race (waitWorker worker) (reviewWait controller entry deadline)
              pure(either(const(StopService "worker-lost"))id outcome')
          restore(finishEntry controller entry worker stopping)
  mapM_ (discardControlPayload . snd) . Map.elems =<< readTVarIO(entryControls entry)
  case result of
    Right () -> atomically $ do
      void(tryPutTMVar(entryReview entry)(Left StateConflict))
      void(tryPutTMVar(entryResult entry)(Right ()))
    Left failure -> do
      let reason=classify failure
      atomically(void(tryPutTMVar(entryReview entry)(Left reason)))
      worker <- atomically(tryReadTMVar(entryWorker entry))
      began <- readTVarIO constructing
      final <- tryCommand $ do
        when (began && not(isJust worker)) (throwIO OwnershipUnavailable)
        selected <- try @SomeException (selectFinalization controller entry "worker-lost")
        cleanup <- try @SomeException $ do
          tried <- readTVarIO(entryDispatched entry)
          case selected of
            Right(Finalization(Just ticket)_ _) | not tried -> dispatchCleanup entry ticket (mapM_ closeWorker worker)
            _ -> mapM_ closeWorker worker
        case cleanup of
          Left failed -> throwIO failed
          Right () -> atomically(writeTVar(entryCleanupConfirmed entry)True)
        either throwIO (const(finalizeKnown controller entry)) selected
      atomically(void(tryPutTMVar(entryResult entry)final))

-- Select after acquiring the gate, so an accepted mutation cannot be overtaken
-- by a cleanup continuation that read its pending state before the commit.
selectFinalization :: Admission -> Entry -> Text -> IO Finalization
selectFinalization controller entry fallback = locked controller $ do
  pending <- readTVarIO(entryFinal entry)
  case pending of
    Just final -> pure final
    Nothing -> do
      attempt <- Map.lookup(entryRequest entry) <$> readTVarIO(attempts controller)
      recovered <- case attempt of
        Nothing -> pure Nothing
        Just known -> do
          result <- reconcileCommandAttemptWithAdmission WaitWithinBudget known
          case result of
            Right (Just accepted) | Just _ <- submissionTicket accepted -> do
              let kind=case receiptOperation(submissionReceipt accepted) of
                    Approve->"approve"; Withdraw->"withdraw"
                    op | op `elem` [Cancel,Steer,Retry,ChooseRecovery,Redirect,Answer] -> "control"
                    _->"edit"
              publishRetainedWithAdmission WaitWithinBudget controller (entryRequest entry) kind accepted
              atomically(modifyTVar'(attempts controller)(Map.delete(entryRequest entry)))
              readTVarIO(entryFinal entry)
            Right Nothing -> atomically(modifyTVar'(attempts controller)(Map.delete(entryRequest entry))) >> pure Nothing
            _ -> pure Nothing
      case recovered of
        Just final -> pure final
        Nothing -> do
          stopping <- atomically(tryReadTMVar(entryStop entry))
          started<-dbTerminalRead controller(startCommitted entry)
          let kind=if started then "closed" else case stopping of Just(StopService reason)->reason;_->fallback
          revision <- markServiceCleanup controller entry kind
          let final=Finalization Nothing kind revision
          atomically(writeTVar(entryFinal entry)(Just final))
          pure final

reviewWait :: Admission -> Entry -> Word64 -> IO Stop
reviewWait controller entry deadline = do
  outcome <- race (atomically(readTMVar(entryStop entry))) (monotonicUntil(clock controller)deadline)
  case outcome of
    Left stopping -> pure stopping
    Right () -> do
      retired <- locked controller $ do
        already <- readTVarIO(entryRetiredTimer entry)
        started <- if already then pure True else dbTerminalRead controller(startCommitted entry)
        if started then atomically(writeTVar(entryRetiredTimer entry)True) >> pure True else do
          now <- monotonicNow(clock controller)
          unless(now>=deadline)(throwIO StateConflict)
          revision <- markServiceCleanup controller entry "expired"
          atomically(writeTVar(entryFinal entry)(Just(Finalization Nothing "expired" revision)))
          pure False
      if retired then atomically(readTMVar(entryStop entry)) else pure(StopService "expired")

finishEntry :: Admission -> Entry -> FrontendWorker -> Stop -> IO ()
finishEntry controller entry worker stopping = do
  started<-dbTerminalRead controller(startCommitted entry)
  let effective=case stopping of StopService _ | started -> StopService "closed";_->stopping
  case effective of
    StopCommand ticket kind revision -> do
      atomically(writeTVar(entryFinal entry)(Just(Finalization(Just ticket)kind revision)))
      dispatchCleanup entry ticket (discardAndClose worker)
    StopService kind -> do
      pending <- readTVarIO(entryFinal entry)
      case pending of
        Nothing -> do
          revision <- locked controller (markServiceCleanup controller entry kind)
          atomically(writeTVar(entryFinal entry)(Just(Finalization Nothing kind revision)))
        Just _ -> pure()
      discardAndClose worker
  atomically(writeTVar(entryCleanupConfirmed entry)True)
  finalizeKnown controller entry

dispatchCleanup :: Entry -> DispatchTicket -> IO () -> IO ()
dispatchCleanup entry ticket action = do
  atomically(writeTVar(entryDispatched entry)True)
  reserveDispatchWithAdmission WaitWithinBudget ticket >>= need
  attemptDispatchWithAdmission WaitWithinBudget ticket action >>= need

discardAndClose :: FrontendWorker -> IO ()
discardAndClose worker = do
  observation <- observeWorker worker
  case observedWorkerPhase observation of
    WorkerPrepared -> do
      result <- try @WorkerFailure(discardWorker worker)
      case result of Left WorkerClosed -> pure();Left failure->throwIO failure;Right()->pure()
    _ -> pure()
  closeWorker worker

markServiceCleanup :: Admission -> Entry -> Text -> IO Text
markServiceCleanup controller entry reason = markServiceCleanupWithReason WaitWithinBudget controller entry reason Nothing

markServiceCleanupWithReason :: StoreAdmission -> Admission -> Entry -> Text -> Maybe Text -> IO Text
markServiceCleanupWithReason admission controller entry reason publicReason = do
  revision <- fresh "request_revision_"
  runRevision <- fresh "run_revision_"
  runTransactionWithAdmission admission (store controller) $ do
    validateOwner entry (if reason=="closed" then ["preparing","review","start-pending","associated"] else ["preparing","review"]) ["held"]
    started <- startCommitted entry
    when (started && reason/="closed") (refuseTransaction StateConflict)
    execute "UPDATE reservations SET state='cleanup-pending',pending_kind=?,request_revision=? WHERE id=?" [text reason,text revision,text(entryReservation entry)]
    execute "UPDATE admission_observations SET state='invalidated',reason=? WHERE reservation_id=?" [text reason,text(entryReservation entry)]
    changes <- invalidatePreparations entry (maybe (if reason=="expired" then "expired" else "worker-lost") id publicReason) revision
    execute "UPDATE requests SET revision=? WHERE id=?" [text revision,text(entryRequest entry)]
    runChanges <- changeRunSupervision entry "owned" "cleanup-pending" runRevision
    pure((),requestEvent(entryRequest entry)revision:changes<>runChanges)
  pure revision

finalizeKnown :: Admission -> Entry -> IO ()
finalizeKnown controller entry = locked controller $ do
  confirmed <- readTVarIO(entryCleanupConfirmed entry)
  unless confirmed (throwIO OwnershipUnavailable)
  pending <- readTVarIO(entryFinal entry) >>= maybe(throwIO StateConflict)pure
  let Finalization ticket kind revision=pending
      finalPhase=if kind=="withdraw" then "withdrawn" else "draft"
  next <- fresh "request_revision_"
  runRevision <- fresh "run_revision_"
  let publish = do
        rows <- query "SELECT r.revision,r.phase,v.request_revision,v.process_generation,v.pending_command,v.pending_kind FROM requests r JOIN reservations v ON v.request_id=r.id WHERE r.id=? AND v.id=? AND v.state='cleanup-pending'"
          [text(entryRequest entry),text(entryReservation entry)]
        let command=maybe SQL.SQLNull (text.dispatchCommandId) ticket
        case rows of
          [[SQL.SQLText actual,SQL.SQLText phaseName,SQL.SQLText bound,SQL.SQLText generation,storedCommand,SQL.SQLText storedKind]] -> do
            -- First Runtime evidence may associate after cleanup-pending committed.
            -- Only that exact post-start revision may supersede the retained fence.
            associated <- if kind=="closed" && phaseName=="associated" && command==SQL.SQLNull then do
              intents <- query "SELECT run_id FROM start_intents WHERE request_id=? AND reservation_id=? AND process_generation=?"
                [text(entryRequest entry),text(entryReservation entry),text(entryGeneration entry)]
              pure (case intents of [[SQL.SQLText run]] -> actual=="associated_"<>run; _ -> False)
              else pure False
            unless((actual==revision || associated) && bound==actual && generation==entryGeneration entry && storedCommand==command && storedKind==kind && phaseName `elem` (if kind=="closed" then ["preparing","review","start-pending","associated"] else ["preparing","review"]))(refuseTransaction StateConflict)
          _->refuseTransaction StateConflict
        execute "DELETE FROM reservation_resources WHERE reservation_id=?" [text(entryReservation entry)]
        execute "UPDATE reservations SET state='released',slot=NULL,request_revision=? WHERE id=?" [text next,text(entryReservation entry)]
        execute "UPDATE requests SET phase=CASE WHEN phase IN ('start-pending','associated') THEN phase ELSE ? END,admission='released',revision=?,queue_ordinal=NULL,queue_origin_revision=NULL,queue_generation=NULL,blocking_reasons=? WHERE id=?"
          [text finalPhase,text next,SQL.SQLBlob(encoded([]::[Text])),text(entryRequest entry)]
        runChanges <- changeRunSupervision entry "cleanup-pending" "lost" runRevision
        pure (requestEvent(entryRequest entry)next:runChanges)
  case ticket of
    Nothing -> dbTerminalChange controller $ do events<-publish;pure((),events)
    Just actual -> do
      effect <- need (decodeEffect(if kind=="edit" then "input-changed" else "withdrawn")(entryRequest entry))
      void(recordEffectWithAdmission WaitWithinBudget actual effect publish >>= need)
  atomically $ do
    modifyTVar'(queued controller)(Map.delete(entryRequest entry))

changeRunSupervision :: Entry -> Text -> Text -> Text -> Transaction [Invalidation]
changeRunSupervision entry previous next revision = do
  rows <- query "SELECT id FROM runs WHERE request_id=? AND supervision=?" [text(entryRequest entry),text previous]
  events <- mapM (\row -> case row of
    [SQL.SQLText ident] -> pure [Invalidation "run.changed" ("/v1/runs/"<>ident) revision,
      Invalidation "run.changed" ("/v1/runs/"<>ident<>"/control") revision]
    _ -> refuseTransaction StorageUnavailable) rows
  execute "UPDATE runs SET supervision=?,revision=?,control_revision=? WHERE request_id=? AND supervision=?"
    [text next,text revision,text revision,text(entryRequest entry),text previous]
  pure (concat events)

awaitAdmissionCleanup :: LivePreparation -> IO (Either CommandFailure ())
awaitAdmissionCleanup (LivePreparation _ entry)=atomically(readTMVar(entryResult entry))

retryAdmissionCleanup :: LivePreparation -> IO (Either CommandFailure ())
retryAdmissionCleanup (LivePreparation controller entry) = operation controller $ do
  completed <- atomically(tryReadTMVar(entryResult entry))
  unless (isJust completed) (throwIO StateConflict)
  atomically(readTMVar(entryTask entry)) >>= mapM_ (void . waitCatch)
  final <- selectFinalization controller entry "worker-lost"
  worker <- atomically(tryReadTMVar(entryWorker entry))
  let confirm = case worker of
        Just actual -> closeWorker actual >> atomically(writeTVar(entryCleanupConfirmed entry)True)
        Nothing -> readTVarIO(entryCleanupConfirmed entry) >>= \confirmed -> unless confirmed(throwIO OwnershipUnavailable)
  tried <- readTVarIO(entryDispatched entry)
  case final of
    Finalization(Just ticket)_ _ | not tried -> dispatchCleanup entry ticket confirm
    _ -> confirm
  finalizeKnown controller entry
  atomically(void(swapTMVar(entryResult entry)(Right())))

editRequestInput :: Admission -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either CommandFailure CommandReceipt)
editRequestInput controller proof requestId key precondition body = operation controller $ do
  bound <- Map.lookup requestId <$> readTVarIO(entries controller)
  result <- changeDraftInputGuarded (store controller) proof requestId key precondition body (transition bound) submit
  submissionReceipt <$> need result
  where
    transition bound command limits current revision = do
      let view=requestView current
      if draftPhase view `elem` ["draft","queued"] then do
        editable current
        when(draftPhase view=="queued")(checkDraftCapacity limits(requestOwner current))
        pure(InputTransition "draft" "not-queued" False [])
      else do
        entry <- maybe(refuseTransaction OwnershipUnavailable)pure bound
        validateOwner entry ["preparing","review"] ["held"]
        checkDraftCapacity limits(requestOwner current)
        changes <- invalidateCommand entry command "edit" revision
        pure(InputTransition(draftPhase view) "reserved" True changes)
    submit request builder = locked controller $ do
      ensureController controller
      result <- submitRetained controller proof requestId "edit" request builder
      pure result

withdrawRequest :: Admission -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either CommandFailure CommandReceipt)
withdrawRequest controller proof requestId key precondition body = operation controller $ do
  requireBody "withdraw" body
  metadata <- dbRead controller(requestState proof requestId [Submit])
  currentPolicyRevision <- profileRevisionNow controller(draftProfile(requestView metadata))
  revision <- fresh "request_revision_"
  let request=CommandRequest Withdraw (draftProfile(requestView metadata)) "POST" (requestURI requestId) key "application/json" precondition body
  locked controller $ do
    ensureController controller
    bound <- Map.lookup requestId <$> readTVarIO(entries controller)
    let builder command _limits _catalogues = Right $ Mutation currentPolicyRevision (currentVersion proof requestId) $ do
          current <- requestState proof requestId [Submit]
          if draftPhase(requestView current) `elem` ["draft","queued"] then do
            editable current
            pure $ Right $ Intent (noReferences{referenceRequest=Just requestId}) False $ do
              execute "UPDATE requests SET phase='withdrawn',admission='released',revision=?,queue_ordinal=NULL,queue_origin_revision=NULL,queue_generation=NULL WHERE id=?" [text revision,text requestId]
              effect<-effectValueFor "withdrawn" requestId
              pure([requestEvent requestId revision],Just effect)
          else do
            entry <- maybe(refuseTransaction OwnershipUnavailable)pure bound
            validateOwner entry ["preparing","review"] ["held"]
            pure $ Right $ Intent (noReferences{referenceRequest=Just requestId}) True $ do
              changes <- invalidateCommand entry command "withdraw" revision
              execute "UPDATE requests SET revision=?,queue_ordinal=NULL,queue_origin_revision=NULL,queue_generation=NULL WHERE id=?" [text revision,text requestId]
              pure(requestEvent requestId revision:changes,Nothing)
    result <- submitRetained controller proof requestId "withdraw" request builder
    submissionReceipt <$> need result

submitRetained :: Admission -> CredentialProof -> Text -> Text -> CommandRequest
  -> (Text -> ConfigurationLimits -> [(Text,Discovery)] -> Either CommandFailure Mutation)
  -> IO (Either CommandFailure Submission)
submitRetained controller proof requestId kind request = submitRetainedGuarded controller proof requestId kind request Nothing Nothing

submitRetainedGuarded :: Admission -> CredentialProof -> Text -> Text -> CommandRequest -> Maybe CommitDeadline
  -> Maybe (Text -> Either CommandFailure BS.ByteString)
  -> (Text -> ConfigurationLimits -> [(Text,Discovery)] -> Either CommandFailure Mutation)
  -> IO (Either CommandFailure Submission)
submitRetainedGuarded controller proof requestId kind request deadlineGuard controlEncoder builder = mask $ \restore -> do
  pending <- readTVarIO(attempts controller)
  case Map.lookup requestId pending of
    Nothing -> freshAttempt restore pending
    Just previous -> do
      reconciled <- reconcileCommandAttempt previous
      case reconciled of
        Right Nothing -> do
          forget
          freshAttempt restore (Map.delete requestId pending)
        _ -> do
          replay <- submitConfiguredCommand (store controller) proof request (\_ _ _ -> Left StateConflict)
          case (replay,reconciled) of
            (Right accepted,Right(Just current))
              | receiptId(submissionReceipt current)==receiptId(submissionReceipt accepted) -> publish current
            _ -> pure()
          pure replay
  where
    forget = atomically(modifyTVar'(attempts controller)(Map.delete requestId))
    publish accepted = publishRetained controller requestId kind accepted >> forget
    freshAttempt restore pending = do
      when(Map.size pending>=16)(throwIO StateConflict)
      attempt <- maybe (newCommandAttempt (store controller) proof request)
        (newControlCommandAttempt (store controller) proof request) controlEncoder
      atomically(modifyTVar'(attempts controller)(Map.insert requestId attempt))
      result <- try @SomeException(restore(maybe(submitCommandAttempt attempt builder)(\guard->submitCommandAttemptWithDeadline guard attempt builder)deadlineGuard))
      resolved <- case result of
        Right(Right accepted) -> pure(Right(Just accepted))
        Right(Left failure) | failure/=StorageUnavailable -> pure(Right Nothing)
        _ -> reconcileCommandAttempt attempt
      case resolved of
        Right(Just accepted) -> publish accepted
        Right Nothing -> forget
        Left _ -> do
          current <- Map.lookup requestId <$> readTVarIO(entries controller)
          forM_ current $ \entry -> atomically(void(tryPutTMVar(entryStop entry)(StopService "closed")))
      case result of
        Left failure -> throwIO failure
        Right original -> pure $ case resolved of Right(Just accepted)->Right accepted;_->original

publishRetained :: Admission -> Text -> Text -> Submission -> IO ()
publishRetained = publishRetainedWithAdmission FailFast

publishRetainedWithAdmission :: StoreAdmission -> Admission -> Text -> Text -> Submission -> IO ()
publishRetainedWithAdmission admission controller requestId kind accepted =
  if kind=="approve" then retainStartWithAdmission admission controller requestId accepted else if kind=="enqueue" then case submissionEnqueue accepted of
    Just permit -> atomically(modifyTVar'(queued controller)(Map.insert requestId permit))
    Nothing -> pure()
  else if kind=="control" then unless (submissionReplayed accepted) $ do
    entry <- Map.lookup requestId <$> readTVarIO(entries controller) >>= maybe(throwIO OwnershipUnavailable)pure
    ticket <- maybe(throwIO OwnershipUnavailable)pure(submissionTicket accepted)
    atomically(modifyTVar' (entryControls entry) (Map.insert (dispatchCommandId ticket) (receiptOperation(submissionReceipt accepted),ticket)))
  else retainMutationWithAdmission admission controller requestId kind (Right accepted)

retainStartWithAdmission :: StoreAdmission -> Admission -> Text -> Submission -> IO ()
retainStartWithAdmission admission controller requestId accepted = unless(submissionReplayed accepted) $ do
  entry <- Map.lookup requestId <$> readTVarIO(entries controller) >>= maybe(throwIO OwnershipUnavailable)pure
  ticket <- maybe(throwIO OwnershipUnavailable)pure(submissionTicket accepted)
  native <- atomically(readTMVar(entryReview entry)) >>= need
  run <- runReadWithAdmission admission (store controller) $ do
    rows<-query "SELECT s.run_id,s.preparation_id FROM start_intents s JOIN runs r ON r.id=s.run_id JOIN preparations p ON p.id=s.preparation_id WHERE s.command_id=? AND s.request_id=? AND s.reservation_id=? AND s.process_generation=? AND r.native_run_id=? AND r.root_identity=? AND p.native_run_id=r.native_run_id AND p.root_identity=r.root_identity AND p.state='consumed'"
      (map text [dispatchCommandId ticket,requestId,entryReservation entry,entryGeneration entry,runIdText(preparedRunId(reviewNative native)),preparedRootIdentity(reviewNative native)])
    case rows of
      [[SQL.SQLText run,SQL.SQLText preparation]] -> do
        unless(submissionReferences accepted==CommandReferences(Just requestId)(Just run)(Just preparation)Nothing)(refuseTransaction OwnershipUnavailable)
        pure run
      _->refuseTransaction OwnershipUnavailable
  old<-readTVarIO(entryStart entry)
  case old of
    Just(AcceptedStart _ _ existing _) -> unless(dispatchCommandId existing==dispatchCommandId ticket)(throwIO OwnershipUnavailable)
    Nothing -> atomically(writeTVar(entryStart entry)(Just(AcceptedStart controller entry ticket run)))

-- | Accept only through the original live association, without performing native IO.
acceptStartCommand :: LivePreparation -> CredentialProof -> CommandRequest
  -> (ReviewContext -> Text -> ConfigurationLimits -> [(Text,Discovery)] -> Either CommandFailure Mutation)
  -> IO (Either CommandFailure (Submission,Maybe AcceptedStart))
acceptStartCommand (LivePreparation controller entry) proof request builder = operation controller $ locked controller $ do
  ensureController controller
  unless(commandOperation request==Approve)(throwIO InvalidRequest)
  replay<-commandPreflight(store controller)proof request(\_ _ _ exists->pure(exists,[])) >>= need
  accepted<-if replay then submitRetained controller proof (entryRequest entry) "approve" request (\_ _ _->Left StateConflict) >>= need else do
    current<-currentReview controller entry
    worker<-atomically(readTMVar(entryWorker entry))
    withWorkerCommitDeadline worker (store controller) (monotonicNow(clock controller)) (reviewDeadlineNanos current) $ \guard->
      submitRetainedGuarded controller proof (entryRequest entry) "approve" request (Just guard) Nothing (builder current) >>= need
  retained<-readTVarIO(entryStart entry)
  let same=case retained of Just value@(AcceptedStart _ _ ticket _) | dispatchCommandId ticket==receiptId(submissionReceipt accepted)->Just value;_->Nothing
  pure(accepted,same)

-- | Invalidate an unapproved original live association, then join its actual cleanup.
invalidateLivePreparation :: LivePreparation -> Text -> IO (Either CommandFailure ())
invalidateLivePreparation (LivePreparation controller entry) reason = operation controller $ do
  unless(reason `elem` ["profile-changed","authority-changed","discarded"])(throwIO InvalidRequest)
  locked controller $ do
    ensureController controller
    started<-dbRead controller(startCommitted entry)
    when started(throwIO StateConflict)
    revision<-markServiceCleanupWithReason FailFast controller entry "closed" (Just reason)
    atomically $ do
      writeTVar(entryFinal entry)(Just(Finalization Nothing "closed" revision))
      void(tryPutTMVar(entryStop entry)(StopService "closed"))
  atomically(readTMVar(entryResult entry)) >>= need

deliverAcceptedStart :: AcceptedStart -> IO (Either CommandFailure ())
deliverAcceptedStart (AcceptedStart controller entry ticket run) = operation controller $ do
  worker<-locked controller $ do
    ensureController controller
    dbRead controller $ do
      validateOwner entry ["start-pending","associated"] ["held"]
      rows<-query "SELECT count(*) FROM start_intents WHERE command_id=? AND run_id=? AND reservation_id=? AND process_generation=?"
        (map text [dispatchCommandId ticket,run,entryReservation entry,entryGeneration entry])
      unless(rows==[[SQL.SQLInteger 1]])(refuseTransaction OwnershipUnavailable)
    stopped<-atomically(tryReadTMVar(entryStop entry))
    when(isJust stopped)(throwIO StateConflict)
    atomically(readTMVar(entryWorker entry))
  reserveDispatch ticket >>= need
  attemptDispatch ticket (startWorker worker) >>= need

-- | Observation context from the original association. It cannot create a ticket.
acceptedControlContext :: AcceptedStart -> IO (CoordinationStore, Text, Text, FrontendPrepared)
acceptedControlContext (AcceptedStart controller entry _ _) = do
  context <- atomically(readTMVar(entryReview entry)) >>= need
  pure(store controller,entryProfile entry,entryPolicy entry,reviewNative context)

-- Both internal control entrypoints use the same retained command attempt path.
acceptControlCommand :: AcceptedStart -> CredentialProof -> CommandRequest
  -> Transaction (Maybe (Text,Text,Text))
  -> IO (Text -> Either CommandFailure BS.ByteString,
         Text -> ConfigurationLimits -> [(Text,Discovery)] -> Either CommandFailure Mutation)
  -> IO (Either CommandFailure Submission)
acceptControlCommand (AcceptedStart controller entry _ run) proof request version prepare = operation controller $
  withMVar (entryControlGate entry) $ \_ -> do
    ensureController controller
    unless(commandOperation request `elem` [Cancel,Steer,Retry,ChooseRecovery,Redirect,Answer]
      && commandProfile request==entryProfile entry)(throwIO InvalidRequest)
    replay <- commandPreflightVersion (store controller) proof request version >>= need
    if replay then locked controller $ submitConfiguredCommand (store controller) proof request (\_ _ _->Left StateConflict) >>= need
    else do
      checkLive
      available <- capacityAvailable
      unless available(throwIO SizeLimit)
      -- Never hold global admission or configuration locks during restoration.
      (encoder,builder) <- prepare
      locked controller $ do
        checkLive
        capacity <- capacityAvailable
        let checked candidate limits catalogues = do
              mutation <- builder candidate limits catalogues
              pure mutation {mutationValidate = do
                validateOwner entry ["start-pending","associated"] ["held"]
                rows <- query "SELECT id FROM runs WHERE id=? AND request_id=? AND supervision='owned'"
                  [text run,text(entryRequest entry)]
                unless(rows==[[text run]])(refuseTransaction OwnershipUnavailable)
                result <- mutationValidate mutation
                pure $ case result of Right _ | not capacity -> Left SizeLimit; _ -> result}
        submitRetainedGuarded controller proof (entryRequest entry) "control" request Nothing (Just encoder) checked >>= need
  where
    checkLive = do
      ensureController controller
      stopped <- atomically(tryReadTMVar(entryStop entry))
      when(isJust stopped)(throwIO OwnershipUnavailable)
      worker <- atomically(readTMVar(entryWorker entry))
      observed <- observeWorker worker
      unless(observedWorkerPhase observed `elem` [WorkerStartSent,WorkerRunning]
        && not(isJust(observedWorkerExit observed)))(throwIO OwnershipUnavailable)
    capacityAvailable = do
      retained <- readTVarIO(entryControls entry)
      worker <- atomically(readTMVar(entryWorker entry))
      protocol <- workerProtocolVersion worker
      let cancellation=commandOperation request==Cancel || any ((==Cancel) . fst) (Map.elems retained)
      pure(Map.size retained<controlAcknowledgementLimit protocol cancellation)

-- | Explicit one-shot dispatch through the original ticket, Worker and pipe.
-- Only the original ticket supplies bytes. Stored bindings cannot recreate them.
deliverAcceptedControl :: AcceptedStart -> Text -> IO (Either CommandFailure ())
deliverAcceptedControl (AcceptedStart controller entry _ run) command = operation controller $ do
  (ticket,worker) <- locked controller $ do
    ensureController controller
    (_,ticket) <- Map.lookup command <$> readTVarIO(entryControls entry) >>= maybe(throwIO OwnershipUnavailable)pure
    dbRead controller $ do
      rows <- query "SELECT command_id FROM control_intents WHERE command_id=? AND run_id=?" [text command,text run]
      unless(rows==[[text command]])(refuseTransaction OwnershipUnavailable)
    worker <- atomically(readTMVar(entryWorker entry))
    pure(ticket,worker)
  reserveDispatch ticket >>= need
  attemptControlDispatch ticket (\bytes -> do
    control <- either (const(throwIO InvalidRequest)) pure (decodeControlFor correlatedProtocolVersion bytes)
    encodedControl <- either (const(throwIO InvalidRequest)) pure (encodeControlFor correlatedProtocolVersion control)
    unless(controlId control==ControlId command && encodedControl==bytes)(throwIO InvalidRequest)
    dbRead controller $ do
      rows <- query "SELECT native_sha256,native_bytes FROM control_intents WHERE command_id=? AND run_id=?" [text command,text run]
      unless(rows==[[text(T.pack(show(hash bytes::Digest SHA256))),SQL.SQLInteger(fromIntegral(BS.length bytes))]])(refuseTransaction OwnershipUnavailable)
    writeWorkerControl worker control) >>= need

-- | Internal owner stop, not a public control receipt or fabricated cancellation event.
stopAcceptedStart :: AcceptedStart -> IO (Either CommandFailure ())
stopAcceptedStart (AcceptedStart controller entry _ _) = operation controller $ do
  atomically(void(tryPutTMVar(entryStop entry)(StopService "closed")))
  atomically(readTMVar(entryResult entry)) >>= need

-- | A non-authoritative observation that the original timer checked committed intent.
acceptedTimerRetired :: AcceptedStart -> IO Bool
acceptedTimerRetired (AcceptedStart _ entry _ _) = readTVarIO(entryRetiredTimer entry)

-- | Loan only the original accepted association and its retained ingestion head.
-- This grants no new start/control ticket, including during uncertain delivery.
consumeAcceptedStart :: AcceptedStart -> (CoordinationStore -> Text -> FrontendPrepared -> WorkerEvent -> IO ()) -> IO Bool
consumeAcceptedStart (AcceptedStart controller entry _ _) action = do
  context <- atomically (readTMVar (entryReview entry)) >>= need
  worker <- atomically (readTMVar (entryWorker entry))
  consumeWorkerEvent worker (action (store controller) (entryProfile entry) (reviewNative context))

observeAcceptedStart :: AcceptedStart -> IO WorkerObservation
observeAcceptedStart (AcceptedStart _ entry _ _) = atomically(readTMVar(entryWorker entry)) >>= observeWorker

retainMutationWithAdmission :: StoreAdmission -> Admission -> Text -> Text -> Either CommandFailure Submission -> IO ()
retainMutationWithAdmission admission controller requestId kind outcome = case outcome of
  Right accepted | not(submissionReplayed accepted) -> do
    current <- Map.lookup requestId <$> readTVarIO(entries controller)
    case (current,submissionTicket accepted) of
      (Just entry,Just ticket) -> do
        revision <- runReadWithAdmission admission (store controller) $ do
          rows<-query "SELECT request_revision FROM reservations WHERE id=? AND pending_command=?" [text(entryReservation entry),text(dispatchCommandId ticket)]
          case rows of [[SQL.SQLText value]]->pure value;_->refuseTransaction StateConflict
        atomically $ do
          writeTVar(entryFinal entry)(Just(Finalization(Just ticket)kind revision))
          void(tryPutTMVar(entryStop entry)(StopCommand ticket kind revision))
      (_,Nothing) -> atomically(modifyTVar'(queued controller)(Map.delete requestId))
      _ -> throwIO OwnershipUnavailable
  _ -> pure()

invalidateCommand :: Entry -> Text -> Text -> Text -> Transaction [Invalidation]
invalidateCommand entry command kind revision = do
  execute "UPDATE reservations SET state='cleanup-pending',pending_command=?,pending_kind=?,request_revision=? WHERE id=?"
    [text command,text kind,text revision,text(entryReservation entry)]
  execute "UPDATE admission_observations SET state='invalidated',reason=? WHERE reservation_id=?"
    [text(if kind=="edit" then "input-changed" else "withdrawn"),text(entryReservation entry)]
  invalidatePreparations entry (if kind=="edit" then "input-changed" else "discarded") revision

invalidatePreparations :: Entry -> Text -> Text -> Transaction [Invalidation]
invalidatePreparations entry reason revision = do
  rows <- query "SELECT id FROM preparations WHERE reservation_id=? AND process_generation=? AND state='live'" [text(entryReservation entry),text(entryGeneration entry)]
  execute "UPDATE preparations SET state='invalidated',reason=?,revision=? WHERE reservation_id=? AND process_generation=? AND state='live'"
    [text reason,text revision,text(entryReservation entry),text(entryGeneration entry)]
  pure [Invalidation "preparation.changed" ("/v1/preparations/"<>ident) revision | [SQL.SQLText ident] <- rows]

validateEntry :: Entry -> [Text] -> [Text] -> Transaction ()
validateEntry entry phases states = do
  validateOwner entry phases states
  rows <- query "SELECT count(*) FROM requests r JOIN reservations v ON v.request_id=r.id WHERE r.id=? AND v.id=? AND r.revision=v.request_revision" [text(entryRequest entry),text(entryReservation entry)]
  unless(rows==[[SQL.SQLInteger 1]])(refuseTransaction StateConflict)

validateOwner :: Entry -> [Text] -> [Text] -> Transaction ()
validateOwner entry phases states = do
  generation <- transactionGeneration
  rows<-query "SELECT r.phase,v.state,r.profile_revision,v.profile_revision FROM requests r JOIN reservations v ON v.request_id=r.id WHERE r.id=? AND v.id=? AND v.process_generation=?"
    [text(entryRequest entry),text(entryReservation entry),text(entryGeneration entry)]
  unless(generation==entryGeneration entry)(refuseTransaction OwnershipUnavailable)
  case rows of
    [[SQL.SQLText phaseName,SQL.SQLText state,SQL.SQLText profile,SQL.SQLText captured]] ->
      unless(phaseName `elem` phases && state `elem` states && profile==entryPolicy entry && captured==entryPolicy entry)(refuseTransaction StateConflict)
    _->refuseTransaction OwnershipUnavailable

startCommitted :: Entry -> Transaction Bool
startCommitted entry = do
  rows<-query "SELECT count(*) FROM requests r JOIN preparations p ON p.request_id=r.id JOIN commands c ON c.preparation_id=p.id JOIN admission_observations o ON o.reservation_id=p.reservation_id WHERE r.id=? AND p.reservation_id=? AND p.process_generation=? AND r.phase IN ('start-pending','associated') AND p.state='consumed' AND p.native_run_id=o.native_run_id AND p.root_identity=o.root_identity AND c.request_id=r.id AND c.operation='approve'"
    [text(entryRequest entry),text(entryReservation entry),text(entryGeneration entry)]
  pure(rows==[[SQL.SQLInteger 1]])

pruneCompleted :: Admission -> IO ()
pruneCompleted controller = do
  current <- readTVarIO(entries controller)
  forM_ (Map.toList current) $ \(ident,entry) -> do
    task <- atomically(tryReadTMVar(entryTask entry))
    done <- case task of Just(Just worker) -> isJust <$> poll worker; _ -> pure False
    outcome <- atomically(tryReadTMVar(entryResult entry))
    when(done && outcome==Just(Right())) $
      atomically(modifyTVar'(entries controller)(Map.delete ident))

shutdown :: Admission -> IO ()
shutdown controller = do
  atomically(writeTVar(closed controller)True)
  jobs<-readTVarIO(operations controller)
  forM_ jobs $ \slot->atomically(readTMVar slot)>>=mapM_ (void . waitCatch)
  current<-Map.elems <$> readTVarIO(entries controller)
  forM_ current $ \entry->atomically(void(tryPutTMVar(entryStop entry)(StopService "closed")))
  forM_ current $ \entry->atomically(readTMVar(entryTask entry))>>=mapM_ (void . waitCatch)
  mapM_ discardControlAttempt . Map.elems =<< readTVarIO(attempts controller)
  atomically(writeTVar(attempts controller)Map.empty)
  outcomes<-mapM (atomically.readTMVar.entryResult) current
  unless(all (either(const False)(const True)) outcomes)(throwIO StorageUnavailable)

queueRows :: Transaction [QueueRow]
queueRows = do
  rows<-query "SELECT id,revision,profile_id,profile_revision,workflow_id,descriptor_revision,queue_ordinal FROM requests WHERE phase='queued' ORDER BY length(queue_ordinal),queue_ordinal LIMIT 101" []
  unless(length rows<=100)(refuseTransaction StateConflict)
  forM rows $ \row->case row of
    [SQL.SQLText a,SQL.SQLText b,SQL.SQLText c,SQL.SQLText d,SQL.SQLText e,SQL.SQLText f,SQL.SQLText g]->QueueRow a b c d e f <$> decimal g
    _->refuseTransaction StorageUnavailable
heldRows :: Transaction [(Text,Held,Text)]
heldRows = do
  rows<-query "SELECT v.id,v.slot,v.process_generation,(SELECT json_group_array(json_array(kind,resource_key)) FROM reservation_resources WHERE reservation_id=v.id) FROM reservations v WHERE v.state!='released'" []
  forM rows $ \row->case row of
    [SQL.SQLText ident,SQL.SQLInteger slot,SQL.SQLText generation,SQL.SQLText keys]->do
      values<-decodeT(TE.encodeUtf8 keys)::Transaction [[Text]]
      resources<-forM values $ \value->case value of ["operator",name]->pure(OperatorResource name);["unclassified",""]->pure UnclassifiedResource;_->refuseTransaction StorageUnavailable
      pure(ident,Held(fromIntegral slot)(Set.fromList resources),generation)
    _->refuseTransaction StorageUnavailable
currentPolicy :: [(Text,Discovery)] -> Text -> Text -> Text -> Text -> Bool
currentPolicy catalogues profile revision workflow descriptor = case lookup profile catalogues of
  Just value->discoveryProfileRevision value==revision && discoveryRevision value==descriptor && isJust(lookup workflow(discoveryEntries value))
  Nothing->False
resourcesFor :: [(Text,Discovery)] -> Text -> Set.Set Resource
resourcesFor catalogues profile = maybe (Set.singleton UnclassifiedResource) (effectiveResources.operatorResourceKeys.selectionContext.discoverySelection) (lookup profile catalogues)
findQueue :: Text -> [QueueRow] -> Maybe QueueRow
findQueue ident = Data.List.find(\(QueueRow current _ _ _ _ _ _)->ident==current)
resourceValues :: Resource -> [SQL.SQLData]
resourceValues UnclassifiedResource=[text"unclassified",text""]
resourceValues (OperatorResource value)=[text"operator",text value]
nextOrdinal :: Transaction Text
nextOrdinal = do
  rows<-query "SELECT last_ordinal FROM admission_queue_clock WHERE singleton=1" []
  current<-case rows of [[SQL.SQLText value]]->decimal value;_->refuseTransaction StorageUnavailable
  unless(current<18446744073709551615)(refuseTransaction StateConflict)
  let next=T.pack(show(current+1))
  execute "UPDATE admission_queue_clock SET last_ordinal=? WHERE singleton=1" [text next]
  pure next

-- Each original terminal-owner Store action keeps its own existing allowance.
dbTerminalRead :: NFData a => Admission -> Transaction a -> IO a
dbTerminalRead controller = runReadWithAdmission WaitWithinBudget (store controller)

dbTerminalChange :: NFData a => Admission -> Transaction (a,[Invalidation]) -> IO a
dbTerminalChange controller = runTransactionWithAdmission WaitWithinBudget (store controller)

dbRead :: NFData a => Admission -> Transaction a -> IO a
dbRead controller action = runRead(store controller)action

dbChange :: NFData a => Admission -> Transaction (a,[Invalidation]) -> IO a
dbChange controller action = runTransaction(store controller)action
configured :: Admission -> (ConfigurationLimits -> [(Text,Discovery)] -> IO a) -> IO a
configured controller action = withStoreCatalogues(store controller)(\limits _ catalogues->action limits catalogues) >>= either(const(throwIO StorageUnavailable))pure
profileRevisionNow :: Admission -> Text -> IO Text
profileRevisionNow controller ident = withStoreConfiguration(store controller)(\_ profiles->case [publicRevision p|p<-profiles,publicId p==ident]of [value]->pure value;_->throwIO Forbidden) >>= either(const(throwIO StorageUnavailable))pure
requireBody :: Text -> BS.ByteString -> IO ()
requireBody name bytes = do
  unless(BS.length bytes<=2097152)(throwIO SizeLimit)
  value<-either(const(throwIO InvalidRequest))pure(decodeStrictValue bytes)
  unless(value==object["operation" .= name])(throwIO InvalidRequest)
effectValueFor :: Text -> Text -> Transaction Effect
effectValueFor kind ident = either refuseTransaction pure (decodeEffect kind ident)
decodeEffect :: Text -> Text -> Either CommandFailure Effect
decodeEffect kind ident = either(const(Left InvalidRequest))Right(eitherDecodeStrict'(encoded(object["kind" .= kind,"runtimeSequence" .= (Nothing::Maybe Text),"address" .= (Nothing::Maybe Value),"resource" .= requestURI ident])))
need :: Either CommandFailure a -> IO a
need=either throwIO pure
tryCommand :: IO a -> IO (Either CommandFailure a)
tryCommand action=do result<-try @SomeException action;pure(either(Left . classify)Right result)
classify :: SomeException -> CommandFailure
classify failure=maybe StorageUnavailable id(fromException failure)
text :: Text -> SQL.SQLData
text=SQL.SQLText
requestURI :: Text -> Text
requestURI ident="/v1/requests/"<>ident
requestEvent :: Text -> Text -> Invalidation
requestEvent ident revision=Invalidation "request.changed" (requestURI ident) revision
fresh :: Text -> IO Text
fresh prefix=do value<-getRandomBytes 24::IO BS.ByteString;pure(prefix<>TE.decodeUtf8(convertToBase Base16 value))
decimal :: Text -> Transaction Integer
decimal value=case reads(T.unpack value)of [(number,"")]|number>=0 && number<=18446744073709551615 && T.pack(show number)==value->pure number;_->refuseTransaction StorageUnavailable
readTVarIO :: TVar a -> IO a
readTVarIO=atomically.readTVar
decodeT :: FromJSON a => BS.ByteString -> Transaction a
decodeT=either(const(refuseTransaction StorageUnavailable))pure.eitherDecodeStrict'
groupsOf :: Int -> [a] -> [[a]]
groupsOf _ []=[]
groupsOf size values=let (prefix,rest)=splitAt size values in prefix:groupsOf size rest
