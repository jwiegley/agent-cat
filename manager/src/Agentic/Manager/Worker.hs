{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | One owned native frontend process, with private pipes and bounded ingestion.
module Agentic.Manager.Worker
  ( FrontendWorker, WorkerFailure (..), WorkerPhase (..), WorkerObservation (..),
    WorkerEvent, workerEventEnvelope, workerEventBytes,
    withFrontendWorker, withStartingFrontendWorker, withWorkerCommitDeadline, workerPrepared, startWorker, discardWorker, writeWorkerControl,
    consumeWorkerEvent, observeWorker, workerDiagnostics, waitWorker, closeWorker
  ) where

import Agentic.Manager.Protocol.Command (CommandFailure)
import Agentic.Manager.Drafts (verifyFrontendFiles)
import Agentic.Manager.Profile
  (Discovery, discoveryEntries, discoveryRevision, discoveryProfileRevision, discoverySelection,
   Selection, selectionContext, selectionInvocation, OperatorProfile (..))
import Agentic.Manager.Store
import Agentic.Manager.Worker.State
import Agentic.Runtime
  (ProcessGroup, terminateProcessGroup, closeGroupPipes, waitProcessGroup,
   groupInput, groupOutput, groupErrors, privateRootIdentity,
   ensurePrivateDirectoryAt, openPrivateSubroot, closePrivateRoot,
   FrontendSetupRequest (..), FrontendSetup (..), FrontendDecision (..),
   FrontendPrepared (..), FrontendCapabilities (..), WorkflowDescriptor (..),
   encodeFrontendSetupRequest, encodeFrontendDecision, decodeFrontendPrepared,
   maxFrontendReplyBytes, maxFrameBytes, latestProtocolVersion, readNdjsonFrame,
   Envelope (..), RuntimeEvent (..), SeqNo, checkSequence, decodeEnvelopeFor,
   Control, encodeControlFor, decodeControlFor)
import Control.Concurrent.Async (async, withAsync, waitCatch, race, concurrently_)
import Control.Concurrent.MVar (MVar, newMVar, tryTakeMVar, putMVar)
import Control.Concurrent.STM
  (STM, TVar, TMVar, TBQueue, throwSTM, atomically, newTVarIO, readTVar, writeTVar, modifyTVar',
   newEmptyTMVarIO, readTMVar, tryReadTMVar, tryPutTMVar, newTBQueueIO, writeTBQueue,
   peekTBQueue, readTBQueue, lengthTBQueue, check, orElse)
import Control.Exception
  (SomeException, IOException, bracket, mask, try, throwIO, fromException, onException,
   finally, uninterruptibleMask_)
import Control.Monad (unless, when, void)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (canonicalizePath)
import System.Exit (ExitCode (..))
import System.IO (Handle, hFlush, hSetBinaryMode)
import System.Process (CreateProcess (cwd, env, std_in, std_out, std_err), StdStream (CreatePipe), proc)
import System.Timeout (timeout)
import Data.Word (Word64)

-- | Non-consuming bounded transport observations. Exit is not workflow success.
data WorkerObservation = WorkerObservation
  { observedWorkerPhase :: !WorkerPhase,
    observedWorkerSequence :: !(Maybe SeqNo),
    observedQueuedFrames :: !Int,
    observedQueuedBytes :: !Int,
    observedDiagnosticBytes :: !Int,
    observedDiagnosticsTruncated :: !Bool,
    observedWorkerExit :: !(Maybe (Either WorkerFailure ExitCode)),
    observedCleanupUnproven :: !Bool
  } deriving (Eq, Show)

-- | An unchanged framed native envelope. Consuming it is not a durable receipt.
data WorkerEvent = WorkerEvent !BS.ByteString !Envelope
workerEventEnvelope :: WorkerEvent -> Envelope
workerEventEnvelope (WorkerEvent _ envelope) = envelope
workerEventBytes :: WorkerEvent -> BS.ByteString
workerEventBytes (WorkerEvent bytes _) = bytes

-- | Live ownership created only by this module. No constructor, Generic, Show or JSON.
data FrontendWorker = FrontendWorker
  { lifecycle :: !WorkerLifecycle,
    nativeProcess :: !(TVar (Maybe ProcessGroup)),
    prepared :: !(TMVar FrontendPrepared),
    inputPipe :: !(TVar (Maybe Handle)),
    eventQueue :: !(TBQueue WorkerEvent),
    queueBytes :: !(TVar Int),
    lastSequence :: !(TVar (Maybe SeqNo)),
    diagnostics :: !(TVar (BS.ByteString, Bool)),
    writer :: !(MVar ()),
    consumer :: !(MVar ()),
    authority :: !(TVar (STM Bool)),
    ownership :: !(TVar (Maybe StoreWorker))
  }

phase :: FrontendWorker -> TVar WorkerPhase
phase = lifecyclePhase . lifecycle
stopReason :: FrontendWorker -> TMVar StopReason
stopReason = lifecycleStop . lifecycle
finished :: FrontendWorker -> TMVar (Either WorkerFailure ExitCode)
finished = lifecycleFinished . lifecycle
released :: FrontendWorker -> TVar Bool
released = lifecycleReleased . lifecycle

-- | Loan final acceptance checks over this same native process and lifecycle.
withWorkerCommitDeadline :: FrontendWorker -> CoordinationStore -> IO Word64 -> Word64 -> (CommitDeadline -> IO a) -> IO a
withWorkerCommitDeadline worker store now expires action = do
  (owner,group) <- atomically $ do
    valid <- acceptingPreparation(lifecycle worker)
    unless valid(throwSTM WorkerClosed)
    owner <- readTVar(ownership worker) >>= maybe(throwSTM WorkerClosed)pure
    group <- readTVar(nativeProcess worker) >>= maybe(throwSTM WorkerClosed)pure
    pure(owner,group)
  withPreparedCommitDeadline store owner group (lifecycle worker) now expires action

-- | Own a native session independently of observers. This does not authorize approval.
withFrontendWorker :: CoordinationStore -> Text -> Text -> FrontendSetupRequest -> (FrontendWorker -> IO a) -> IO a
withFrontendWorker store profile revision setup action = withStartingFrontendWorker store profile revision setup $ \worker ->
  workerPrepared worker >> action worker

-- | Loan construction ownership immediately, without granting preparation or approval.
withStartingFrontendWorker :: CoordinationStore -> Text -> Text -> FrontendSetupRequest -> (FrontendWorker -> IO a) -> IO a
withStartingFrontendWorker store profile revision setup action = mask $ \restore -> do
  worker <- FrontendWorker <$> newWorkerLifecycle <*> newTVarIO Nothing <*> newEmptyTMVarIO <*> newTVarIO Nothing
    <*> newTBQueueIO 32 <*> newTVarIO 0 <*> newTVarIO Nothing <*> newTVarIO (BS.empty, False)
    <*> newMVar () <*> newMVar () <*> newTVarIO (pure False) <*> newTVarIO Nothing
  supervisor <- async $ do
    outcome <- try @SomeException $ withAsync (preparationDeadline worker) $ \_ ->
      withStoreWorker store (runOwned worker)
    let result = either (Left . classify) Right outcome
    atomically $ do
      writeTVar (inputPipe worker) Nothing
      closed <- readTVar (released worker)
      writeTVar (phase worker) (if closed then WorkerReleased else WorkerExited)
      void (tryPutTMVar (finished worker) result)
  preserveException
    (restore (action worker))
    (closeWorker worker `finally` void (waitCatch supervisor))
  where
    runOwned worker owner root live = do
      atomically (writeTVar (authority worker) live >> writeTVar (ownership worker) (Just owner))
      result <- race (atomically (readTMVar (stopReason worker))) (startup worker owner root)
      case result of
        Left StopRequested -> throwIO WorkerClosed
        Left (StopFailed failure) -> throwIO failure
        Right value -> pure value
    startup worker owner root = do
      bytes <- either (const (throwIO WorkerConfiguration)) pure (encodeFrontendSetupRequest setup)
      initial <- checkedSelection store profile revision setup
      files <- try @CommandFailure (try @IOException (verifyFrontendFiles store profile setup))
      case files of
        Right (Right ()) -> pure ()
        _ -> throwIO WorkerConfiguration
      capabilities <- probeStoreCapabilities store owner profile revision >>= either (const (throwIO WorkerCapabilityRejected)) pure
      ensurePrivateDirectoryAt root ["runs"]
      expectedRoot <- bracket (openPrivateSubroot root ["runs"]) closePrivateRoot (pure . T.pack . privateRootIdentity)
      bracketPreserving (launch worker owner initial) cleanupGroup $ \(group, selected) -> do
        input <- maybe (throwIO WorkerUnavailable) pure (groupInput group)
        output <- maybe (throwIO WorkerUnavailable) pure (groupOutput group)
        errors <- maybe (throwIO WorkerUnavailable) pure (groupErrors group)
        mapM_ (`hSetBinaryMode` True) [input,output,errors]
        atomically (writeTVar (inputPipe worker) (Just input))
        (concurrently_
          (drainErrors worker errors)
          (do
            writeFrame WorkerWriteFailed input bytes
            (reply, rest) <- readPrepared output
            validatePrepared selected capabilities expectedRoot setup reply
            unless (BS.null rest) (throwIO WorkerPhaseViolation)
            atomically $ do
              writeTVar (phase worker) WorkerPrepared
              void (tryPutTMVar (prepared worker) reply)
            readEvents worker output reply Nothing False)) `onException`
              (atomically $ do
                closed <- readTVar(released worker)
                unless closed(writeTVar(phase worker)WorkerExited))
        exit <- waitProcessGroup group
        unless (exit == ExitSuccess) (throwIO WorkerUnexpectedExit)
        pure exit
    launch worker owner initial = do
      result <- withStoreCatalogues store $ \_ _ catalogues -> do
        selected <- selectCurrent profile revision setup catalogues
        unless (discoveryRevision (snd selected) == discoveryRevision (snd initial)) (throwIO WorkerConfiguration)
        let policy = selectionContext (fst selected)
            command = (proc (operatorExecutable policy) (operatorPrefix policy <> ["frontend"]))
              {cwd = Just (operatorCwd policy), env = Just (operatorEnvironment policy),
               std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
        group <- createStoreWorkerGroup owner command
        atomically(writeTVar(nativeProcess worker)(Just group))
        pure (group, selected)
      either (const (throwIO WorkerConfiguration)) pure result

preparationDeadline :: FrontendWorker -> IO ()
preparationDeadline worker = do
  completed <- timeout 30000000 $ atomically $
    void (readTMVar (prepared worker)) `orElse` void (readTMVar (finished worker))
  case completed of
    Just () -> pure ()
    Nothing -> atomically (void (tryPutTMVar (stopReason worker) (StopFailed WorkerStartupTimeout)))

checkedSelection :: CoordinationStore -> Text -> Text -> FrontendSetupRequest -> IO (Selection, Discovery)
checkedSelection store profile revision setup = do
  result <- withStoreCatalogues store $ \_ _ catalogues -> selectCurrent profile revision setup catalogues
  either (const (throwIO WorkerConfiguration)) pure result

selectCurrent :: Text -> Text -> FrontendSetupRequest -> [(Text, Discovery)] -> IO (Selection, Discovery)
selectCurrent profile revision setup catalogues = do
  catalogue <- maybe (throwIO WorkerConfiguration) pure (lookup profile catalogues)
  unless (discoveryProfileRevision catalogue == revision) (throwIO WorkerConfiguration)
  let selected = discoverySelection catalogue
      policy = selectionContext selected
      (invocation, person) = case setup of
        RootSetup request -> (setupInvocation request, setupPerson request)
        DerivedSetup _ _ _ _ answering requested -> (requested, answering)
  unless (invocation == Just (selectionInvocation selected) && person == operatorPersonAnswering policy) (throwIO WorkerConfiguration)
  case setup of
    RootSetup request -> do
      unless (setupArguments request == operatorTargetArguments policy) (throwIO WorkerConfiguration)
      unless (any ((== setupWorkflow request) . workflowName . snd) (discoveryEntries catalogue)) (throwIO WorkerConfiguration)
    DerivedSetup {} -> pure ()
  pure (selected, catalogue)

validatePrepared :: (Selection, Discovery) -> FrontendCapabilities -> Text -> FrontendSetupRequest -> FrontendPrepared -> IO ()
validatePrepared (selected, catalogue) capabilities root setup reply = do
  working <- canonicalizePath (operatorCwd (selectionContext selected))
  let (invocation, answering) = case setup of
        RootSetup request -> (setupInvocation request, setupPerson request)
        DerivedSetup _ _ _ _ person requested -> (requested, person)
  unless (preparedInvocation reply == invocation && preparedPersonAnswering reply == answering
    && preparedRootIdentity reply == root && preparedCwd reply == working
    && preparedServer reply == capabilityServer capabilities) (throwIO WorkerWrongIdentity)
  either (const(throwIO WorkerWrongIdentity)) pure (operatorPreparedTarget (selectionContext selected) reply)
  case setup of
    RootSetup request -> unless (any (\(_, descriptor) -> descriptor == preparedDescriptor reply
      && workflowName descriptor == setupWorkflow request) (discoveryEntries catalogue)) (throwIO WorkerWrongIdentity)
    DerivedSetup {} -> pure ()

readPrepared :: Handle -> IO (FrontendPrepared, BS.ByteString)
readPrepared handle = do
  frame <- readNdjsonFrame (fromInteger maxFrontendReplyBytes - 1) "worker prepared" handle BS.empty
    >>= either (const (throwIO WorkerPreparedFraming)) pure
  case frame of
    Nothing -> throwIO WorkerPreparedFraming
    Just (bytes, rest) -> do
      validUtf8 WorkerPreparedDecode bytes
      reply <- either (const (throwIO WorkerPreparedDecode)) pure (decodeFrontendPrepared bytes)
      pure (reply, rest)

readEvents :: FrontendWorker -> Handle -> FrontendPrepared -> Maybe Envelope -> Bool -> IO ()
readEvents worker handle reply previous terminal = loop BS.empty previous terminal
  where
    loop buffered lastEnvelope ended = do
      result <- readNdjsonFrame maxFrameBytes "worker runtime" handle buffered >>= either (const (throwIO WorkerRuntimeFraming)) pure
      case result of
        Nothing -> do
          state <- atomically (readTVar (phase worker))
          unless (ended || (state == WorkerDiscardSent && lastEnvelope == Nothing)) (throwIO WorkerUnexpectedExit)
        Just (bytes, rest) -> do
          validUtf8 WorkerRuntimeDecode bytes
          envelope <- either (const (throwIO WorkerRuntimeDecode)) pure (decodeEnvelopeFor [latestProtocolVersion] bytes)
          unless (envelopeRunId envelope == preparedRunId reply) (throwIO WorkerWrongIdentity)
          _ <- either (const (throwIO WorkerSequenceViolation)) pure (checkSequence lastEnvelope envelope)
          state <- atomically (readTVar (phase worker))
          unless (state `elem` [WorkerStartSent,WorkerRunning] && not ended) (throwIO WorkerPhaseViolation)
          when (lastEnvelope == Nothing) $ case envelopeEvent envelope of
            RunStartedV2 {} -> pure ()
            _ -> throwIO WorkerPhaseViolation
          let framed = bytes <> "\n"
          atomically $ do
            count <- readTVar (queueBytes worker)
            check (count + BS.length framed <= 8388608)
            writeTBQueue (eventQueue worker) (WorkerEvent framed envelope)
            writeTVar (queueBytes worker) (count + BS.length framed)
            writeTVar (lastSequence worker) (Just (envelopeSequence envelope))
            writeTVar (phase worker) WorkerRunning
          loop rest (Just envelope) (terminalEvent (envelopeEvent envelope))
    terminalEvent event = case event of
      RunCompleted {} -> True
      RunCompletedV2 {} -> True
      RunFailed {} -> True
      RunCancelled {} -> True
      _ -> False

drainErrors :: FrontendWorker -> Handle -> IO ()
drainErrors worker handle = loop
  where
    loop = do
      bytes <- BS.hGetSome handle 32768
      unless (BS.null bytes) $ do
        atomically $ modifyTVar' (diagnostics worker) $ \(kept, truncated) ->
          let room = 65536 - BS.length kept
           in (kept <> BS.take room bytes, truncated || BS.length bytes > room)
        loop

workerPrepared :: FrontendWorker -> IO FrontendPrepared
workerPrepared = awaitPrepared

awaitPrepared :: FrontendWorker -> IO FrontendPrepared
awaitPrepared worker = atomically $ do
  closed <- readTVar (released worker)
  when closed (throwSTM WorkerClosed)
  failure <- tryReadTMVar (finished worker)
  case failure of
    Just (Left reason) -> throwSTM reason
    _ -> readTMVar (prepared worker)

startWorker :: FrontendWorker -> IO ()
startWorker worker = decision worker WorkerStartSent FrontendStart

discardWorker :: FrontendWorker -> IO ()
discardWorker worker = decision worker WorkerDiscardSent FrontendDiscard

decision :: FrontendWorker -> WorkerPhase -> (Text -> FrontendDecision) -> IO ()
decision worker next construct = serializedWrite worker $ do
  reply <- workerPrepared worker
  state <- atomically (readTVar (phase worker))
  unless (state == WorkerPrepared) (throwIO WorkerPhaseViolation)
  bytes <- either (const (throwIO WorkerConfiguration)) pure (encodeFrontendDecision (construct (preparedApprovalId reply)))
  send worker (Just next) bytes

writeWorkerControl :: FrontendWorker -> Control -> IO ()
writeWorkerControl worker control = serializedWrite worker $ do
  state <- atomically (readTVar (phase worker))
  unless (state `elem` [WorkerStartSent, WorkerRunning]) (throwIO WorkerPhaseViolation)
  bytes <- either (const (throwIO WorkerConfiguration)) pure (encodeControlFor latestProtocolVersion control)
  _ <- either (const (throwIO WorkerConfiguration)) pure (decodeControlFor latestProtocolVersion bytes)
  send worker Nothing bytes

serializedWrite :: FrontendWorker -> IO a -> IO a
serializedWrite worker action = mask $ \restore -> do
  atomically (ensureLive worker)
  token <- tryTakeMVar (writer worker)
  case token of
    Nothing -> throwIO WorkerWriterBusy
    Just () -> restore action `finally` putMVar (writer worker) ()

send :: FrontendWorker -> Maybe WorkerPhase -> BS.ByteString -> IO ()
send worker next bytes = mask $ \restore -> do
  pipe <- atomically $ do
    ensureLive worker
    input <- readTVar (inputPipe worker) >>= maybe (throwSTM WorkerClosed) pure
    mapM_ (writeTVar (phase worker)) next
    pure input
  outcome <- try @SomeException (restore (writeFrame WorkerWriteFailed pipe bytes))
  case outcome of
    Right () -> pure ()
    Left failure -> do
      atomically (void (tryPutTMVar (stopReason worker) (StopFailed (classify failure))))
      uninterruptibleMask_ (void (atomically (readTMVar (finished worker))))
      throwIO failure

writeFrame :: WorkerFailure -> Handle -> BS.ByteString -> IO ()
writeFrame failure pipe bytes = do
  outcome <- try @IOException (deadline WorkerWriteTimeout 5000000 (BS.hPut pipe (bytes <> "\n") >> hFlush pipe))
  either (const (throwIO failure)) pure outcome

-- | Exactly one ingestion callback may hold the queue head. Failure retains it.
-- Success acknowledges only this in-memory consumption, never a durable commit.
consumeWorkerEvent :: FrontendWorker -> (WorkerEvent -> IO ()) -> IO Bool
consumeWorkerEvent worker action = mask $ \restore -> do
  token <- tryTakeMVar (consumer worker)
  case token of
    Nothing -> throwIO WorkerConsumerBusy
    Just () -> (do
      next <- restore $ atomically $ do
        -- Physical release cannot erase buffered evidence. Only the original
        -- producer's completion proves no later frame can enter an empty queue.
        (Just <$> peekTBQueue (eventQueue worker)) `orElse` do
          result <- readTMVar (finished worker)
          either throwSTM (const (pure Nothing)) result
      case next of
        Nothing -> pure False
        Just event -> do
          restore (action event)
          atomically $ do
            removed <- readTBQueue (eventQueue worker)
            modifyTVar' (queueBytes worker) (subtract (BS.length (workerEventBytes removed)))
          pure True) `finally` putMVar (consumer worker) ()

observeWorker :: FrontendWorker -> IO WorkerObservation
observeWorker worker = do
  confirmed <- cleanupConfirmed worker
  atomically $ do
    state <- readTVar (phase worker)
    sequenceNo <- readTVar (lastSequence worker)
    count <- lengthTBQueue (eventQueue worker)
    bytes <- readTVar (queueBytes worker)
    (messages, truncated) <- readTVar (diagnostics worker)
    result <- tryReadTMVar (finished worker)
    pure (WorkerObservation state sequenceNo (fromIntegral count) bytes (BS.length messages) truncated result (case result of Just _ -> not confirmed; Nothing -> False))

workerDiagnostics :: FrontendWorker -> IO BS.ByteString
workerDiagnostics worker = fst <$> atomically (readTVar (diagnostics worker))

waitWorker :: FrontendWorker -> IO ExitCode
waitWorker worker = atomically (readTMVar (finished worker)) >>= either throwIO pure

closeWorker :: FrontendWorker -> IO ()
closeWorker worker = uninterruptibleMask_ $ do
  atomically $ do
    writeTVar (released worker) True
    writeTVar (phase worker) WorkerReleased
    void (tryPutTMVar (stopReason worker) StopRequested)
  void (atomically (readTMVar (finished worker)))
  confirmed <- cleanupConfirmed worker
  unless confirmed (throwIO WorkerCleanupUnproven)

cleanupConfirmed :: FrontendWorker -> IO Bool
cleanupConfirmed worker = atomically (readTVar (ownership worker)) >>= maybe (pure True) storeWorkerCleanupConfirmed

ensureLive :: FrontendWorker -> STM ()
ensureLive worker = do
  closed <- readTVar (released worker)
  live <- readTVar (authority worker) >>= id
  when (closed || not live) (throwSTM WorkerClosed)

cleanupGroup :: (ProcessGroup, a) -> IO ()
cleanupGroup (group, _) = terminateProcessGroup 5000000 group `finally` closeGroupPipes group

validUtf8 :: WorkerFailure -> BS.ByteString -> IO ()
validUtf8 failure bytes = either (const (throwIO failure)) (const (pure ())) (TE.decodeUtf8' bytes)

deadline :: WorkerFailure -> Int -> IO a -> IO a
deadline failure micros action = timeout micros action >>= maybe (throwIO failure) pure

classify :: SomeException -> WorkerFailure
classify failure = case fromException failure of
  Just value -> value
  Nothing -> case fromException failure of
    Just StoreClosed -> WorkerClosed
    Just StoreCleanupUnproven -> WorkerCleanupUnproven
    Just (_ :: StoreFailure) -> WorkerUnavailable
    Nothing -> WorkerUnexpectedExit

bracketPreserving :: IO a -> (a -> IO ()) -> (a -> IO b) -> IO b
bracketPreserving acquire release use = mask $ \restore -> do
  resource <- acquire
  preserveException (restore (use resource)) (release resource)

preserveException :: IO a -> IO () -> IO a
preserveException action cleanup = mask $ \restore -> do
  result <- try @SomeException (restore action)
  ended <- try @SomeException cleanup
  case result of
    Left failure -> throwIO failure
    Right value -> either throwIO (const (pure value)) ended
