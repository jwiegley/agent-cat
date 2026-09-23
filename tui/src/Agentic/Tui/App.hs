{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Thin Brick adapter over the pure TUI model and machine snapshot reducer.
module Agentic.Tui.App
  ( runApp,
    runServiceApp,
    withTerminationHandlers,
  )
where

import Agentic.Runtime
  ( AttemptId (attemptOccurrence),
    CatalogueEntry (..),
    Control (..),
    ControlAckSnapshot (..),
    ControlCommand (..),
    ControlId (..),
    DispatchSnapshot (..),
    FrontendManifest (..),
    FrontendServer,
    LineageOperation (..),
    OccurrenceId,
    OccurrenceSnapshot (..),
    RecoveryControl (..),
    RecoveryOption (..),
    RecoverySnapshot (..),
    Envelope (..),
    RunId,
    RunOwnership (..),
    RunRecord (..),
    RunSnapshot (..),
    RunStatus (..),
    SteeringTiming (..),
    SnapshotError (snapshotErrorMessage),
    WorkflowDescriptor (..),
    WorkflowInputDescriptor (workflowInputName),
    initialRunSnapshot,
    readResultArtifactAt,
    stepRunSnapshot,
  )
import qualified Agentic.Manager.Client as Manager
import qualified Agentic.Tui.Service as Service
import Agentic.Tui.Client
import Agentic.Tui.Model
import Agentic.Tui.Person
import Agentic.Tui.Presentation
import Agentic.Tui.Process
import Agentic.Tui.RunModel
import Agentic.Tui.Root
import Agentic.Tui.Types
import Brick
import Brick.BChan (BChan, newBChan, writeBChan, writeBChanNonBlocking)
import qualified Brick.Widgets.Edit as Edit
import Control.Concurrent (forkIO, myThreadId, threadDelay, throwTo)
import Control.Concurrent.Async (Async, asyncWithUnmask, cancel)
import Control.Concurrent.MVar (MVar, modifyMVarMasked_, newMVar, readMVar, tryReadMVar)
import Control.Concurrent.STM
  ( STM,
    TBQueue,
    TVar,
    atomically,
    isEmptyTBQueue,
    newTBQueueIO,
    newTVarIO,
    readTBQueue,
    readTVar,
    writeTVar,
  )
import Control.Exception (AsyncException (UserInterrupt), SomeAsyncException, SomeException, bracket, displayException, finally, fromException, mask, mask_, onException, throwIO, try, uninterruptibleMask_)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Aeson (Value (..), encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.List (elemIndex, find)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime, utctDayTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Graphics.Vty as Vty
import qualified Graphics.Vty.Output as VtyOutput
import Graphics.Vty.Platform.Unix (mkVty)
import System.Environment (lookupEnv)
import System.FilePath (isAbsolute, (</>))
import System.IO (hClose, hPutStrLn, stderr)
import System.Posix.Files (ownerReadMode, ownerWriteMode, unionFileModes)
import System.Posix.IO (OpenFileFlags (cloexec, creat, exclusive, nofollow), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)
import System.Posix.Signals (Handler (Catch, Ignore), installHandler, sigINT, sigTERM)

-- | Coalesced display wakeups plus lossless one-shot operation results.
data AppEvent
  = FrameReady
  | InitialReady !(Either Text InitialData)
  | Tick !UTCTime
  | PreviewReady !Int !(Either Text LaunchPreview)
  | HelpReady !Int !(Either Text Text)
  | RunsReady !(Either Text [CatalogueEntry])
  | RoutingReady !Text !(Either Text RoutingSummary)
  | MachineReady !Int !LaunchPreview !(Either Text RunningMachine)
  | ChildStopped !Int !MachineExit
  | PersonPromptReady !MandatoryDecision !Int !(Either Text PersonPrompt)
  | FinalResultReady !RunId !(Either Text Value)
  | ServiceProfilesReady !Int !(Either Manager.ClientFailure [Service.Profile])
  | ServiceWorkflowsReady !Int !Service.Profile !(Either Manager.ClientFailure [Service.Workflow])
  | ServicePrepared !Int !(Either Manager.ClientFailure Manager.PendingCommand)
  | ServiceSent !Int !(Either Manager.ClientFailure Manager.ClientResponse)
  | ServiceRequestReady !Int !(Either Manager.ClientFailure ServiceObservation)

-- | Bounded frontend IO slots, each retaining at most one cancellable task.
data Work = InitialWork | PreviewWork | HelpWork | RunsWork | RoutingWork | MachineWork | PersonWork | ResultWork
  | ServiceReadWork | ServicePrepareWork | ServiceSendWork
  deriving (Eq, Ord)

-- | Disjoint original local and manager-client owners.
data Backend = LocalBackend !TuiConfig !PrivateRoot | ServiceBackend !Manager.Client

-- Each attempted mutation retains the original immutable pending command.
data MutationState
  = MutationIdle
  | MutationPreparing !Int !Service.Mutation
  | MutationSending !Int !Service.Mutation !Manager.PendingCommand
  | MutationAwaiting !Service.Mutation !Manager.PendingCommand !Manager.Reference
  | MutationUncertain !Service.Mutation !Manager.PendingCommand !(Maybe Manager.Reference) !Text

data ServiceObservation = ServiceObservation !Manager.Observed !Manager.DraftView
  !(Maybe (Manager.Observed,Manager.Preparation)) !(Maybe (Either Manager.ClientFailure Manager.CommandReceipt))

-- | Brick-only editor/process state around the pure model.
data AppState = AppState
  { stateModel :: !TuiModel,
    stateEditor :: !(Edit.Editor Text Name),
    stateFilterEditor :: !(Edit.Editor Text Name),
    statePersonEditor :: !(Edit.Editor Text Name),
    stateControlEditor :: !(Edit.Editor Text Name),
    stateSaveEditor :: !(Edit.Editor Text Name),
    stateChannel :: !(BChan AppEvent),
    stateEvents :: !(TBQueue Envelope),
    stateFramePending :: !(TVar Bool),
    stateRunning :: !(Maybe RunningMachine),
    statePendingExit :: !(Maybe MachineExit),
    stateMachineFailure :: !(Maybe Text),
    stateOwned :: !(IORef (Maybe RunningMachine)),
    stateWorkers :: !(MVar (Map.Map Work (Async ()))),
    stateRunView :: !RunView,
    statePaneFocus :: !PaneFocus,
    stateOutputFollow :: !Bool,
    stateConfirmDetails :: !Bool,
    stateKeyHelp :: !Bool,
    stateShowResult :: !Bool,
    stateRunDetails :: !Bool,
    stateFilterEditing :: !Bool,
    stateSaveResult :: !Bool,
    stateSaveError :: !(Maybe Text),
    stateNow :: !UTCTime,
    stateRunStartedAt :: !(Maybe UTCTime),
    stateRunPersona :: !(Maybe Text),
    stateRunRealization :: !(Maybe Text),
    stateRuntimeDirectory :: !(Maybe FilePath),
    stateViewingRecord :: !(Maybe RunRecord),
    stateRoutingRequest :: !(Maybe Text),
    stateRequestSerial :: !Int,
    stateMachineRequest :: !(Maybe Int),
    statePreviewRequest :: !(Maybe Int),
    stateHelpRequest :: !(Maybe Int),
    stateMandatoryDecisions :: ![MandatoryDecision],
    statePersonLoadGeneration :: !Int,
    statePersonLoading :: !(Maybe (MandatoryDecision, Int)),
    statePersonPrompt :: !(Maybe (MandatoryDecision, PersonPrompt)),
    statePersonSubmitted :: !Bool,
    statePersonControlId :: !(Maybe Text),
    statePersonError :: !(Maybe Text),
    stateCancelConfirm :: !Bool,
    stateSteerTiming :: !(Maybe SteeringTiming),
    stateControlError :: !(Maybe Text),
    stateFinalResult :: !(Maybe (Either Text Value)),
    stateFinalLoading :: !Bool,
    stateNoColor :: !Bool,
    stateTerminalSize :: !(Int, Int),
    stateServer :: !(Maybe FrontendServer),
    stateBackend :: !Backend,
    stateServiceReadTicket :: !(Maybe Int),
    stateServiceProfiles :: ![Service.Profile],
    stateServiceWorkflows :: ![Service.Workflow],
    stateServiceWorkflow :: !(Maybe Service.Workflow),
    stateServiceRequestId :: !(Maybe Text),
    stateServiceRequest :: !(Maybe (Manager.Observed,Manager.DraftView)),
    stateServicePreparation :: !(Maybe (Manager.Observed,Manager.Preparation)),
    stateServiceMutation :: !MutationState,
    stateServiceApproval :: !(Maybe (Service.Mutation,Manager.PendingCommand,Maybe Manager.Reference)),
    stateServiceApprovalStatus :: !(Maybe Text),
    stateServiceLastReceipt :: !(Maybe Manager.CommandReceipt),
    stateServiceResendConfirm :: !Bool,
    stateServiceUncertainExit :: !(IORef Bool)
  }

runApp :: TuiConfig -> PrivateRoot -> IO ()
runApp config root = runAppWith (LocalBackend config root)

runServiceApp :: Manager.Client -> IO ()
runServiceApp = runAppWith . ServiceBackend

runAppWith :: Backend -> IO ()
runAppWith backend = mask $ \restore -> do
  channel <- newBChan 64
  now <- getCurrentTime
  noColor <- maybe False (not . null) <$> lookupEnv "NO_COLOR"
  events <- newTBQueueIO 2048
  framePending <- newTVarIO False
  owned <- newIORef Nothing
  workers <- newMVar Map.empty
  uncertainExit <- newIORef False
  let buildVty = do
        value <- mkVty Vty.defaultConfig
        enableBracketedPaste value `onException` Vty.shutdown value
        pure value
  initialVty <- buildVty
  terminalSize <- VtyOutput.displayBounds (Vty.outputIface initialVty) `onException` Vty.shutdown initialVty
  ticker <- (asyncWithUnmask $ \unmask -> unmask . forever $ do
    threadDelay 1000000
    current <- getCurrentTime
    void (writeBChanNonBlocking channel (Tick current))) `onException` Vty.shutdown initialVty
  let loadingModel = (initialModel [] [] (Left "catalogue is loading"))
        { modelScreen = InitialLoading, modelStatus = case backend of
            LocalBackend {} -> "loading runner catalogue"
            ServiceBackend {} -> "loading manager profiles" }
      initialState =
        AppState
          { stateModel = loadingModel,
            stateEditor = blankEditor,
            stateFilterEditor = blankEditor,
            statePersonEditor = blankEditor,
            stateControlEditor = blankEditor,
            stateSaveEditor = blankEditor,
            stateChannel = channel,
            stateEvents = events,
            stateFramePending = framePending,
            stateRunning = Nothing,
            statePendingExit = Nothing,
            stateMachineFailure = Nothing,
            stateOwned = owned,
            stateWorkers = workers,
            stateRunView = emptyRunView,
            statePaneFocus = PrimaryPane,
            stateOutputFollow = True,
            stateConfirmDetails = False,
            stateKeyHelp = False,
            stateShowResult = False,
            stateRunDetails = False,
            stateFilterEditing = False,
            stateSaveResult = False,
            stateSaveError = Nothing,
            stateNow = now,
            stateRunStartedAt = Nothing,
            stateRunPersona = Nothing,
            stateRunRealization = Nothing,
            stateRuntimeDirectory = Nothing,
            stateViewingRecord = Nothing,
            stateRoutingRequest = Nothing,
            stateRequestSerial = 0,
            stateMachineRequest = Nothing,
            statePreviewRequest = Nothing,
            stateHelpRequest = Nothing,
            stateMandatoryDecisions = [],
            statePersonLoadGeneration = 0,
            statePersonLoading = Nothing,
            statePersonPrompt = Nothing,
            statePersonSubmitted = False,
            statePersonControlId = Nothing,
            statePersonError = Nothing,
            stateCancelConfirm = False,
            stateSteerTiming = Nothing,
            stateControlError = Nothing,
            stateFinalResult = Nothing,
            stateFinalLoading = False,
            stateNoColor = noColor,
            stateTerminalSize = terminalSize,
            stateServer = Nothing,
            stateBackend = backend,
            stateServiceReadTicket = Nothing,
            stateServiceProfiles = [],
            stateServiceWorkflows = [],
            stateServiceWorkflow = Nothing,
            stateServiceRequestId = Nothing,
            stateServiceRequest = Nothing,
            stateServicePreparation = Nothing,
            stateServiceMutation = MutationIdle,
            stateServiceApproval = Nothing,
            stateServiceApprovalStatus = Nothing,
            stateServiceLastReceipt = Nothing,
            stateServiceResendConfirm = False,
            stateServiceUncertainExit = uncertainExit
          }
      stopAll [] = pure ()
      stopAll (worker : rest) = cancel worker `finally` stopAll rest
      cleanup = do
        uninterruptibleMask_ (ignoreTerminationSignals >> Vty.shutdown initialVty) `finally`
          case backend of
            LocalBackend {} ->
              (uninterruptibleMask_ (cancel ticker >> (readMVar workers >>= mapM_ cancel))
                `finally` (readIORef owned >>= mapM_ terminateMachine))
                `finally` writeIORef owned Nothing
            ServiceBackend client -> mask_ $
              (Manager.closeClient client `finally`
                (readMVar workers >>= stopAll . (ticker :) . Map.elems)) `finally` do
                  unresolved <- readIORef uncertainExit
                  when unresolved (hPutStrLn stderr "Manager command outcome may be uncertain. The manager run was not cancelled.")
  restore (void (customMain initialVty buildVty (Just channel) app initialState)) `finally` cleanup

ignoreTerminationSignals :: IO ()
ignoreTerminationSignals = do
  void (installHandler sigINT Ignore Nothing)
  void (installHandler sigTERM Ignore Nothing)

-- Vty restores every enabled mode during shutdown, including exceptional exits.
enableBracketedPaste :: Vty.Vty -> IO ()
enableBracketedPaste vty = do
  let output = Vty.outputIface vty
  when (VtyOutput.supportsMode output VtyOutput.BracketedPaste) (VtyOutput.setMode output VtyOutput.BracketedPaste True)

-- The local action boundary cannot recover a local root from a service identity.
withLocalBackend :: (TuiConfig -> PrivateRoot -> EventM Name AppState ()) -> EventM Name AppState ()
withLocalBackend action = do
  state <- get
  case stateBackend state of
    LocalBackend config root -> action config root
    ServiceBackend {} -> put state {stateModel = (stateModel state) {modelStatus = "local action unavailable in service mode"}}

localReviewAllowed :: AppState -> LaunchPreview -> (Int,Int) -> Bool
localReviewAllowed state preview size = case stateBackend state of
  LocalBackend config _ -> launchReviewAllowed config preview size
  ServiceBackend {} -> False

-- One read slot owns the actual HTTP operation, not a detached wrapper task.
startServiceRead :: (Int -> IO AppEvent) -> EventM Name AppState ()
startServiceRead action = do
  state <- get
  case stateServiceReadTicket state of
    Just _ -> pure ()
    Nothing -> do
      let ticket = stateRequestSerial state + 1
      put state {stateRequestSerial = ticket, stateServiceReadTicket = Just ticket,
        stateModel = (stateModel state) {modelStatus = "loading manager catalogue"}}
      liftIO . startWorker state ServiceReadWork $ action ticket >>= writeBChan (stateChannel state)

startServiceProfiles :: Manager.Client -> EventM Name AppState ()
startServiceProfiles client = startServiceRead $ \ticket ->
  ServiceProfilesReady ticket <$> Service.loadProfiles client

startServiceWorkflows :: Manager.Client -> Service.Profile -> EventM Name AppState ()
startServiceWorkflows client profile = startServiceRead $ \ticket ->
  ServiceWorkflowsReady ticket profile <$> Service.loadWorkflows client profile

serviceIdle :: AppState -> Bool
serviceIdle state = case stateServiceMutation state of MutationIdle -> True; _ -> False

serviceSending :: AppState -> Bool
serviceSending state = case stateServiceMutation state of
  MutationPreparing {} -> True
  MutationSending {} -> True
  _ -> False

safeService :: IO (Either Manager.ClientFailure a) -> IO (Either Manager.ClientFailure a)
safeService action = do
  outcome <- try @SomeException action
  case outcome of
    Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
    Left _ -> pure (Left Manager.TransportUnavailable)
    Right result -> pure result

refreshServiceRequest :: Manager.Client -> EventM Name AppState ()
refreshServiceRequest client = do
  state <- get
  case (stateServiceWorkflow state,stateServiceRequestId state) of
    (Just workflow,Just ident) | not (serviceSending state) -> do
      let pending = case stateServiceMutation state of
            MutationAwaiting mutation _ location -> Just (mutation,location)
            MutationUncertain mutation _ (Just location) _ -> Just (mutation,location)
            _ -> case stateServiceApproval state of Just (mutation,_,Just location) -> Just (mutation,location); _ -> Nothing
      startServiceRead $ \ticket -> ServiceRequestReady ticket <$> safeService (runExceptT $ do
        -- Receipt visibility and request visibility are independently authorized.
        receipt <- liftIO (traverse (\(mutation,location) -> safeService (Service.observeReceipt client mutation location)) pending)
        (observed,request) <- ExceptT (Service.observeDraft client workflow ident)
        preparation <- if Manager.draftPhase request == "review" && isJust (Manager.draftPreparation request)
          then Just <$> ExceptT (Service.observePreparation client request) else pure Nothing
        pure (ServiceObservation observed request preparation receipt))
    _ -> pure ()

beginServiceMutation :: Manager.Client -> Service.Mutation -> Maybe Manager.Observed -> EventM Name AppState ()
beginServiceMutation client mutation observation = do
  state <- get
  when (serviceIdle state) $ do
    now <- liftIO getCurrentTime
    let ticket = stateRequestSerial state + 1
    put state {stateServiceReadTicket = Nothing, stateRequestSerial = ticket,
      stateServiceMutation = MutationPreparing ticket mutation, stateServiceResendConfirm = False, stateServiceLastReceipt = Nothing,
      stateModel = (stateModel state) {modelStatus = "preparing explicit " <> Service.mutationOperation mutation}}
    liftIO (cancelWorker state ServiceReadWork)
    liftIO . startWorker state ServicePrepareWork $
      safeService (Service.prepareMutation client now mutation observation) >>= writeBChan (stateChannel state) . ServicePrepared ticket

sendServicePending :: Manager.Client -> Int -> Service.Mutation -> Manager.PendingCommand -> EventM Name AppState ()
sendServicePending client ticket mutation pending = do
  state <- get
  put state {stateServiceMutation = MutationSending ticket mutation pending, stateServiceResendConfirm = False,
    stateModel = (stateModel state) {modelStatus = "sending one " <> Service.mutationOperation mutation <> " attempt"}}
  liftIO (writeIORef (stateServiceUncertainExit state) True)
  liftIO . startWorker state ServiceSendWork $
    safeService (Manager.sendCommand client pending) >>= writeBChan (stateChannel state) . ServiceSent ticket

uncertainService :: AppState -> Service.Mutation -> Manager.PendingCommand -> Maybe Manager.Reference -> Text -> EventM Name AppState ()
uncertainService state mutation pending location failure =
  put state {stateServiceMutation = MutationUncertain mutation pending location failure,
    stateServiceReadTicket = Nothing, stateServiceResendConfirm = False,
    stateModel = (stateModel state) {modelScreen = ServiceCommandScreen
      ("Outcome unresolved: " <> failure <> "\nOriginal " <> Service.mutationOperation mutation <> " attempt retained.\n"
        <> Service.mutationURI mutation <> "\ng refreshes observations. x requests an exact resend. q detaches."),
      modelStatus = "no automatic resend"}}

handleServiceSent :: Manager.Client -> Int -> Either Manager.ClientFailure Manager.ClientResponse -> EventM Name AppState ()
handleServiceSent client ticket result = do
  state <- get
  case stateServiceMutation state of
    MutationSending expected mutation pending | ticket == expected -> case result of
      Left failure -> uncertainService state mutation pending Nothing (T.pack (show failure))
      Right response -> case mutation of
        Service.Create workflow -> case Manager.decodeObservation (Manager.responseValue response) of
          Right request | Manager.responseStatus response == 201, Service.requestMatches workflow request,
            Manager.draftPhase request == "draft", Manager.draftRun request == Nothing,
            Manager.draftParent request == Nothing, Manager.draftLineage request == Nothing,
            fmap Manager.referenceURI (Manager.responseLocation response) == Just ("/v1/requests/" <> Manager.draftId request) -> do
              let descriptor = Service.workflowDisplay workflow
                  model = (stateModel state) {modelWorkflow = Just descriptor, modelInputs = Map.empty,
                    modelScreen = if null (workflowInputs descriptor) then ServiceRequestScreen request else InputScreen 0,
                    modelStatus = "request created; fetching its exact validator"}
              put state {stateServiceMutation = MutationIdle, stateServiceRequestId = Just (Manager.draftId request),
                stateServiceRequest = Nothing, stateServiceWorkflow = Just workflow, stateModel = model, stateEditor = blankEditor}
              liftIO (writeIORef (stateServiceUncertainExit state) False)
              refreshServiceRequest client
          _ -> uncertainService state mutation pending Nothing "invalid creation response"
        _ -> case (Manager.decodeObservation (Manager.responseValue response),Manager.responseLocation response) of
          (Right receipt,Just location) | Manager.responseStatus response == 202, Service.receiptMatches mutation receipt,
            Manager.referenceURI location == "/v1/commands/" <> Manager.receiptId receipt -> do
              put state {stateServiceMutation = MutationAwaiting mutation pending location, stateServiceLastReceipt = Just receipt,
                stateModel = (stateModel state) {modelStatus = "manager intent accepted; awaiting independent effect"}}
              refreshServiceRequest client
          _ -> uncertainService state mutation pending Nothing "invalid command response"
    _ -> pure ()

applyServiceObservation :: ServiceObservation -> EventM Name AppState ()
applyServiceObservation (ServiceObservation observed request preparation receiptResult) = do
  before <- get
  let receipt = case receiptResult of Just (Right received) -> Just received; _ -> stateServiceLastReceipt before
      receiptStatus = maybe "outcome unresolved" (Manager.stateName . Manager.receiptState) receipt
        <> case receiptResult of Just (Left _) -> " (receipt read unavailable)"; _ -> ""
      state = before {stateServiceReadTicket = Nothing, stateServiceRequest = Just (observed,request),
        stateServiceLastReceipt = receipt, stateServicePreparation = preparation,
        stateServiceApprovalStatus = case stateServiceApproval before of
          Nothing -> stateServiceApprovalStatus before
          Just (approval,_,_) -> case receipt of
            Just received | Service.receiptMatches approval received -> Just receiptStatus
            _ -> stateServiceApprovalStatus before}
      pending = case stateServiceMutation state of
        MutationAwaiting mutation command location -> Just (mutation,command,Just location)
        MutationUncertain mutation command location _ -> Just (mutation,command,location)
        _ -> Nothing
      confirmed kind = maybe False (\value -> Manager.stateName (Manager.receiptState value) == "effect-observed"
        && Service.receiptEffectKind value == Just kind
        && maybe False (\(mutation,_,_) -> Service.receiptMatches mutation value) pending) receipt
  put state
  case pending of
    Just (mutation@(Service.SaveLiteral _ name value index),command,location)
      | confirmed "input-changed" ->
          if Service.literalInputs request == Map.insert name value (modelInputs (stateModel state))
            && Manager.draftPhase request == "draft"
          then do
            let model = (stateModel state) {modelInputs = Map.insert name value (modelInputs (stateModel state)),
                  modelScreen = case modelWorkflow (stateModel state) of
                    Just descriptor | index + 1 < length (workflowInputs descriptor) -> InputScreen (index + 1)
                    _ -> ServiceRequestScreen request, modelStatus = "input effect observed"}
            put state {stateServiceMutation = MutationIdle, stateModel = model,
              stateEditor = Edit.editorText InputEditor Nothing (inputValue model)}
            liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
          else uncertainService state mutation command location "request no longer matches the submitted literals"
    Just (Service.Enqueue _,_,_) | confirmed "enqueued" -> do
      put state {stateServiceMutation = MutationIdle, stateModel = (stateModel state) {modelScreen = ServiceRequestScreen request}}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    Just (mutation@(Service.Approve approvedRequest _),command,location)
      | Manager.draftPhase request == "associated", isJust (Manager.draftRun request),
        Manager.draftId request == Manager.draftId approvedRequest,
        Service.literalInputs request == modelInputs (stateModel state) ->
          put state {stateServiceMutation = MutationIdle, stateServiceApproval = Just (mutation,command,location),
            stateServiceApprovalStatus = Just receiptStatus,
            stateModel = (stateModel state) {modelScreen = ServiceRequestScreen request,
              modelStatus = "run associated; approval receipt remains distinct from runtime outcome"}}
    Just (mutation,command,location) | Just received <- receipt, Manager.stateName (Manager.receiptState received) `elem` ["refused","unresolved"] ->
      uncertainService state mutation command location (Manager.stateName (Manager.receiptState received))
    _ -> pure ()
  current <- get
  when (serviceIdle current) $ case modelScreen (stateModel current) of
    InputScreen _ -> put current {stateModel = (stateModel current) {modelStatus = "request validator current; Ctrl-D sends the literal"}}
    _ -> case (stateServiceWorkflow current,preparation) of
      (Just workflow,Just (prepObserved,prep))
        | Service.reviewMatches workflow request prep, Service.literalInputs request == modelInputs (stateModel current),
          Service.reviewLive (stateNow current) prep -> do
            let screen = ServiceReviewScreen prep (Manager.observedETag prepObserved)
            put current {stateConfirmDetails = stateConfirmDetails current && modelScreen (stateModel current) == screen,
              stateModel = (stateModel current) {modelScreen = screen, modelStatus = "exact manager review; y explicitly approves"}}
      _ -> put current {stateConfirmDetails = False, stateModel = (stateModel current)
        {modelScreen = ServiceRequestScreen request, modelStatus = "manager request: " <> Manager.draftPhase request}}

handleServiceEvent :: Manager.Client -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleServiceEvent client event = do
  state <- get
  let failed problem = state {stateServiceReadTicket = Nothing, stateServiceRequest = Nothing, stateServicePreparation = Nothing,
        stateModel = (stateModel state) {modelScreen = ServiceCommandScreen ("Observation refused: " <> T.pack (show problem)),
          modelStatus = "previous command outcomes are unchanged"}}
  case event of
    AppEvent (ServiceProfilesReady ticket result) ->
      when (stateServiceReadTicket state == Just ticket) $ case result of
        Left problem -> put (failed problem)
        Right profiles -> put state {stateServiceReadTicket = Nothing, stateServiceProfiles = profiles,
          stateServiceWorkflows = [], stateModel = initialServiceModel profiles, statePaneFocus = PrimaryPane}
    AppEvent (ServiceWorkflowsReady ticket profile result) ->
      when (stateServiceReadTicket state == Just ticket) $ case result of
        Left problem -> put (failed problem)
        Right workflows -> put state {stateServiceReadTicket = Nothing, stateServiceWorkflows = workflows,
          stateModel = (initialModel (map Service.workflowDisplay workflows) [] (Left "manager owns routing"))
            {modelStatus = "manager catalogue: " <> Service.profileId profile}, statePaneFocus = PrimaryPane}
    AppEvent (ServicePrepared ticket result) -> case stateServiceMutation state of
      MutationPreparing expected mutation | ticket == expected -> case result of
        Left failure -> put state {stateServiceMutation = MutationIdle,
          stateModel = (stateModel state) {modelStatus = "preflight refused before send: " <> T.pack (show failure)}}
        Right pending -> sendServicePending client ticket mutation pending
      _ -> pure ()
    AppEvent (ServiceSent ticket result) -> handleServiceSent client ticket result
    AppEvent (ServiceRequestReady ticket result) ->
      when (stateServiceReadTicket state == Just ticket) $ either (put . failed) applyServiceObservation result
    AppEvent (Tick now) -> do
      put state {stateNow = now}
      refreshServiceRequest client
    VtyEvent (Vty.EvResize width height) -> put state {stateTerminalSize = (width,height)}
    VtyEvent (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) -> halt
    VtyEvent key | InputScreen index <- modelScreen (stateModel state) -> case key of
      Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] | serviceIdle state ->
        case (stateServiceRequest state,modelWorkflow (stateModel state)) of
          (Just (observed,request),Just descriptor) | Just input <- atMay (workflowInputs descriptor) index ->
            beginServiceMutation client (Service.SaveLiteral request (workflowInputName input)
              (T.intercalate "\n" (Edit.getEditContents (stateEditor state))) index) (Just observed)
          _ -> pure ()
      Vty.EvKey Vty.KEsc [] | serviceIdle state -> case stateServiceRequest state of
        Just (_,request) -> put state {stateModel = (stateModel state) {modelScreen = ServiceRequestScreen request}}
        _ -> pure ()
      _ | serviceIdle state -> handleEditorInput event
        | otherwise -> pure ()
    VtyEvent (Vty.EvKey key modifiers)
      | key == Vty.KChar 'q' && null modifiers -> halt
      | key == Vty.KChar '?' && null modifiers && not (stateServiceResendConfirm state) -> put state {stateKeyHelp = not (stateKeyHelp state)}
      | stateKeyHelp state -> when (key == Vty.KEsc) (put state {stateKeyHelp = False})
      | stateServiceResendConfirm state -> case key of
          Vty.KChar 'y' | null modifiers -> case stateServiceMutation state of
            MutationUncertain mutation pending _ _ -> do
              let ticket = stateRequestSerial state + 1
              put state {stateRequestSerial = ticket, stateServiceReadTicket = Nothing}
              liftIO (cancelWorker state ServiceReadWork)
              sendServicePending client ticket mutation pending
            _ -> pure ()
          Vty.KChar 'n' -> put state {stateServiceResendConfirm = False}
          Vty.KEsc -> put state {stateServiceResendConfirm = False}
          _ -> pure ()
      | serviceSending state -> pure ()
      | null modifiers -> case key of
          Vty.KEsc -> serviceBack state
          Vty.KUp -> serviceMove (-1) state
          Vty.KDown -> serviceMove 1 state
          Vty.KPageUp -> vScrollPage (viewportScroll (serviceViewport state)) Up
          Vty.KPageDown -> vScrollPage (viewportScroll (serviceViewport state)) Down
          Vty.KLeft -> put state {statePaneFocus = PrimaryPane}
          Vty.KRight -> put state {statePaneFocus = SecondaryPane}
          Vty.KEnter | serviceIdle state -> case modelScreen (stateModel state) of
            ServiceProfilesScreen {} -> case selectedServiceProfile (stateModel state) of
              Just profile | Service.profileReadiness profile == "ready", Service.profileRefusal profile == Nothing -> startServiceWorkflows client profile
              _ -> pure ()
            BrowserScreen -> case atMay (stateServiceWorkflows state) (modelWorkflowIndex (stateModel state)) of
              Just workflow -> do
                put state {stateServiceWorkflow = Just workflow, stateServiceRequestId = Nothing, stateServiceRequest = Nothing,
                  stateModel = (stateModel state) {modelInputs = Map.empty, modelWorkflow = Just (Service.workflowDisplay workflow)}}
                beginServiceMutation client (Service.Create workflow) Nothing
              Nothing -> pure ()
            ServiceRequestScreen request | Service.requestReady request, Manager.draftPhase request == "draft" ->
              beginServiceMutation client (Service.Enqueue request) (fst <$> stateServiceRequest state)
            _ -> pure ()
          Vty.KChar 'y' | serviceIdle state, not (stateConfirmDetails state), stateServiceReadTicket state == Nothing ->
            case (modelScreen (stateModel state),stateServiceWorkflow state,stateServiceRequest state,stateServicePreparation state) of
              (ServiceReviewScreen displayed tag,Just workflow,Just (_,request),Just (observed,preparation))
                | displayed == preparation, tag == Manager.observedETag observed,
                  Service.reviewMatches workflow request preparation, Service.literalInputs request == modelInputs (stateModel state),
                  serviceReviewAllowed displayed tag (stateTerminalSize state) -> beginServiceMutation client (Service.Approve request displayed) (Just observed)
              _ -> pure ()
          Vty.KChar 'd' | ServiceReviewScreen {} <- modelScreen (stateModel state) -> do
            put state {stateConfirmDetails = not (stateConfirmDetails state)}
            vScrollToBeginning (viewportScroll ConfirmDetailsViewport)
          Vty.KChar 'e' | serviceIdle state, ServiceRequestScreen request <- modelScreen (stateModel state), Manager.draftPhase request == "draft" ->
            case modelWorkflow (stateModel state) of
              Just descriptor | not (null (workflowInputs descriptor)) ->
                let model = (stateModel state) {modelScreen = InputScreen 0}
                in put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing (inputValue model)}
              _ -> pure ()
          Vty.KChar 'h' | modelScreen (stateModel state) == BrowserScreen ->
            case atMay (stateServiceWorkflows state) (modelWorkflowIndex (stateModel state)) of
              Just workflow -> put state {stateModel = (stateModel state) {modelScreen = HelpScreen (Service.workflowHelp workflow)}}
              Nothing -> pure ()
          Vty.KChar 'g' -> refreshServiceRequest client
          Vty.KChar 'x' | MutationUncertain {} <- stateServiceMutation state -> put state {stateServiceResendConfirm = True}
          Vty.KChar 'r' | ServiceProfilesScreen {} <- modelScreen (stateModel state) -> startServiceProfiles client
          _ -> pure ()
    _ -> pure ()
  where
    serviceBack state = case modelScreen (stateModel state) of
      ServiceProfilesScreen {} -> halt
      InitialLoading -> halt
      ServiceReviewScreen {} | stateConfirmDetails state -> put state {stateConfirmDetails = False}
      HelpScreen _ -> put state {stateModel = (stateModel state) {modelScreen = BrowserScreen}}
      BrowserScreen | serviceIdle state -> do
        put state {stateServiceReadTicket = Nothing, stateServiceWorkflows = [],
          stateModel = initialServiceModel (stateServiceProfiles state), statePaneFocus = PrimaryPane}
        liftIO (cancelWorker state ServiceReadWork)
      _ -> pure ()
    serviceMove delta state = case modelScreen (stateModel state) of
      HelpScreen _ -> vScrollBy (viewportScroll HelpViewport) delta
      FailureScreen _ -> vScrollBy (viewportScroll FailureViewport) delta
      ServiceRequestScreen _ -> vScrollBy (viewportScroll FailureViewport) delta
      ServiceReviewScreen {} | stateConfirmDetails state -> vScrollBy (viewportScroll ConfirmDetailsViewport) delta
      _ | statePaneFocus state == SecondaryPane -> vScrollBy (viewportScroll BrowserDetailViewport) delta
        | otherwise -> do
            put state {stateModel = moveSelection delta (stateModel state)}
            vScrollToBeginning (viewportScroll BrowserDetailViewport)
    serviceViewport state = case modelScreen (stateModel state) of
      HelpScreen _ -> HelpViewport
      FailureScreen _ -> FailureViewport
      ServiceRequestScreen _ -> FailureViewport
      ServiceReviewScreen {} -> ConfirmDetailsViewport
      _ | statePaneFocus state == SecondaryPane -> BrowserDetailViewport
        | otherwise -> BrowserListViewport

blankEditor :: Edit.Editor Text Name
blankEditor = Edit.editorText InputEditor Nothing ""

startWorker :: AppState -> Work -> IO () -> IO ()
startWorker state work action =
  modifyMVarMasked_ (stateWorkers state) $ \workers -> do
    mapM_ cancel (Map.lookup work workers)
    worker <- asyncWithUnmask (\unmask -> unmask action)
    pure (Map.insert work worker workers)

cancelWorker :: AppState -> Work -> IO ()
cancelWorker state work =
  modifyMVarMasked_ (stateWorkers state) $ \workers -> do
    mapM_ cancel (Map.lookup work workers)
    pure (Map.delete work workers)

withTerminationHandlers :: IO a -> IO a
withTerminationHandlers action = do
  owner <- myThreadId
  stopping <- newIORef False
  let caught = Catch $ do
        first <- atomicModifyIORef' stopping (\already -> (True, not already))
        when first (throwTo owner UserInterrupt)
      withSignal sig = bracket (installHandler sig caught Nothing) (\previous -> void (installHandler sig previous Nothing)) . const
  withSignal sigINT (withSignal sigTERM action)

app :: App AppState AppEvent Name
app =
  App
    { appDraw = draw,
      appChooseCursor = showFirstCursor,
      appHandleEvent = handleEvent,
      appStartEvent = startInitialLoad,
      appAttrMap = presentationAttributes . stateNoColor
    }

startInitialLoad :: EventM Name AppState ()
startInitialLoad = do
  state <- get
  case stateBackend state of
    LocalBackend config root ->
      liftIO . startWorker state InitialWork $ loadInitialData config root >>= writeBChan (stateChannel state) . InitialReady
    ServiceBackend client -> startServiceProfiles client

draw :: AppState -> [Widget Name]
draw = drawPresentation . toPresentation

serviceMutationNotice :: AppState -> Maybe (Text,Text,Bool)
serviceMutationNotice state = case stateServiceMutation state of
  MutationIdle -> Nothing
  MutationPreparing _ mutation -> entry mutation False
  MutationSending _ mutation _ -> entry mutation False
  MutationAwaiting mutation _ _ -> entry mutation False
  MutationUncertain mutation _ _ _ -> entry mutation True
  where entry mutation uncertain = Just (Service.mutationOperation mutation,Service.mutationURI mutation,uncertain)

toPresentation :: AppState -> Presentation
toPresentation state =
  (emptyPresentation (stateModel state))
    { presentationConfig = case stateBackend state of LocalBackend config _ -> Just config; ServiceBackend {} -> Nothing,
      presentationService = case stateBackend state of ServiceBackend {} -> True; LocalBackend {} -> False,
      presentationServiceMutation = serviceMutationNotice state,
      presentationServiceResendConfirm = stateServiceResendConfirm state,
      presentationServiceApproval = stateServiceApprovalStatus state,
      presentationServiceReviewAvailable = serviceIdle state && stateServiceReadTicket state == Nothing
        && case (stateServiceWorkflow state,stateServiceRequest state,stateServicePreparation state) of
          (Just workflow,Just (_,request),Just (_,preparation)) -> Service.reviewLive (stateNow state) preparation
            && Service.reviewMatches workflow request preparation && Service.literalInputs request == modelInputs (stateModel state)
          _ -> False,
      presentationEditor = currentEditor state,
      presentationRunView = stateRunView state,
      presentationPaneFocus = statePaneFocus state,
      presentationOutputFollow = stateOutputFollow state,
      presentationLayer = activeLayer state,
      presentationExactDetails = stateConfirmDetails state,
      presentationRunning = isJust (stateRunning state),
      presentationNoColor = stateNoColor state,
      presentationPersonPrompt = snd <$> statePersonPrompt state,
      presentationPersonSubmitted = statePersonSubmitted state,
      presentationPersonError = statePersonError state,
      presentationRecovery = queuedRecovery state,
      presentationSteerTiming = stateSteerTiming state,
      presentationControlError = stateControlError state,
      presentationSaveError = stateSaveError state,
      presentationFinalResult = stateFinalResult state,
      presentationFinalLoading = stateFinalLoading state,
      presentationShowResult = stateShowResult state,
      presentationElapsed = elapsedText state,
      presentationRunPersona = stateRunPersona state,
      presentationRunRealization = stateRunRealization state,
      presentationSpinner = spinnerFrame (stateNow state)
    }

currentEditor :: AppState -> Edit.Editor Text Name
currentEditor state = case activeLayer state of
  PersonLayer -> statePersonEditor state
  SteerLayer -> stateControlEditor state
  SaveLayer -> stateSaveEditor state
  FilterLayer -> stateFilterEditor state
  _ -> stateEditor state

activeLayer :: AppState -> ActiveLayer
activeLayer state
  | stateKeyHelp state = KeyHelpLayer
  | stateCancelConfirm state = CancelLayer
  | Just decision <- listToMaybe (stateMandatoryDecisions state), mandatoryKind decision == MandatoryPerson = PersonLayer
  | Just decision <- listToMaybe (stateMandatoryDecisions state), mandatoryKind decision == MandatoryRecovery = RecoveryLayer
  | isJust (stateSteerTiming state) = SteerLayer
  | stateSaveResult state = SaveLayer
  | stateFilterEditing state = FilterLayer
  | ConfirmScreen _ <- screen, stateConfirmDetails state = ConfirmDetailsLayer
  | ConfirmScreen _ <- screen = ConfirmLayer
  | LiveScreen _ <- screen, stateRunDetails state = RunDetailsLayer
  | otherwise = ScreenLayer
  where
    screen = modelScreen (stateModel state)

queuedRecovery :: AppState -> Maybe (OccurrenceSnapshot, RecoverySnapshot)
queuedRecovery state = do
  _ <- stateRunning state
  decision <- listToMaybe (stateMandatoryDecisions state)
  if mandatoryKind decision == MandatoryRecovery then pure () else Nothing
  snapshot <- modelSnapshot (stateModel state)
  occurrence <- Map.lookup (mandatoryOccurrence decision) (snapshotOccurrences snapshot)
  recovery <- snapshotOccurrenceRecovery occurrence
  pure (occurrence, recovery)

spinnerFrame :: UTCTime -> Text
spinnerFrame now = ["|", "/", "-", "\\"] !! (floor (utctDayTime now) `mod` 4)

elapsedText :: AppState -> Text
elapsedText state = case stateRunStartedAt state of
  Nothing -> "unknown"
  Just started ->
    let end = case modelSnapshot (stateModel state) of
          Just snapshot | terminalStatus (snapshotRunStatus snapshot) ->
            fromMaybe started (snapshotLastEnvelope snapshot >>= parseFrontendTime . envelopeTimestamp)
          _ -> stateNow state
        seconds = max 0 (floor (diffUTCTime end started) :: Integer)
        (hours, afterHours) = seconds `divMod` 3600
        (minutes, remainder) = afterHours `divMod` 60
     in if hours > 0
          then T.pack (show hours <> "h" <> show minutes <> "m" <> show remainder <> "s")
          else T.pack (show minutes <> "m" <> show remainder <> "s")

handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent event = do
  before <- get
  handleEventCore event
  after <- get
  resetEnteredViewport before after

handleEventCore :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEventCore event = do
  state <- get
  case stateBackend state of
    LocalBackend {} -> handleLocalEvent event
    ServiceBackend client -> handleServiceEvent client event

handleLocalEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleLocalEvent event = case event of
  AppEvent (ServiceProfilesReady _ _) -> pure ()
  AppEvent (ServiceWorkflowsReady _ _ _) -> pure ()
  AppEvent (ServicePrepared _ _) -> pure ()
  AppEvent (ServiceSent _ _) -> pure ()
  AppEvent (ServiceRequestReady _ _) -> pure ()
  AppEvent FrameReady -> handleFrame
  AppEvent (InitialReady result) -> do
    state <- get
    when (modelScreen (stateModel state) == InitialLoading) $ case result of
      Left failure -> put state {stateModel = (stateModel state) {modelScreen = FailureScreen failure, modelStatus = "runner discovery failed"}}
      Right initial -> put state
        { stateServer = Just (initialServer initial),
          stateModel = initialModel (initialWorkflows initial) (initialRuns initial) (initialRouting initial)
        }
  AppEvent (Tick now) -> modify (\state -> state {stateNow = now})
  AppEvent (PreviewReady request result) -> do
    state <- get
    when (modelScreen (stateModel state) == PreviewLoading && statePreviewRequest state == Just request) $
      put state {statePreviewRequest = Nothing, stateModel = previewFinished result (stateModel state)}
  AppEvent (HelpReady request result) -> do
    state <- get
    when (modelScreen (stateModel state) == HelpLoading && stateHelpRequest state == Just request) $ case result of
      Left failure -> put state {stateHelpRequest = Nothing, stateModel = (stateModel state) {modelScreen = FailureScreen failure, modelStatus = "workflow help failed"}}
      Right help -> put state {stateHelpRequest = Nothing, stateModel = (stateModel state) {modelScreen = HelpScreen help, modelStatus = "workflow help"}}
  AppEvent (RunsReady result) -> do
    state <- get
    case result of
      Left failure -> put state {stateModel = (stateModel state) {modelStatus = "ERROR: run catalogue refresh failed: " <> failure}}
      Right records ->
        let model = stateModel state
            selected = max 0 (min (length records - 1) (modelRunIndex model))
            currentRunId = snapshotRunId <$> modelSnapshot model
            currentRecord =
              find
                (\case
                    CatalogueRun record -> Just (frontendRunId (recordManifest record)) == currentRunId
                    CatalogueCorrupt {} -> False
                )
                records
            contextRecord = case currentRecord of
              Just (CatalogueRun record) -> Just record
              _ -> Nothing
         in put
              state
                { stateModel = model {modelRuns = records, modelRunIndex = selected, modelStatus = "run catalogue refreshed"},
                  stateViewingRecord = case contextRecord of
                    Just record -> Just record
                    Nothing -> stateViewingRecord state,
                  stateRunPersona = maybe (stateRunPersona state) (frontendPersona . recordManifest) contextRecord,
                  stateRunRealization = maybe (stateRunRealization state) (Just . runRecordRealizations) contextRecord
                }
  AppEvent (RoutingReady requested result) -> do
    state <- get
    when (stateRoutingRequest state == Just requested) $ case result of
      Left failure -> put state {stateRoutingRequest = Nothing, stateModel = (stateModel state) {modelRouting = Left failure, modelStatus = "routing persona failed: " <> failure}}
      Right routing
        | routingSummaryPersona routing == Just requested ->
            put state {stateRoutingRequest = Nothing, stateModel = (stateModel state) {modelRouting = Right routing, modelEngineIndex = 0, modelStatus = "routing persona selected"}}
        | otherwise ->
            put state {stateRoutingRequest = Nothing, stateModel = (stateModel state) {modelStatus = "routing inspection returned another persona"}}
  AppEvent (MachineReady request preview result) -> handleMachineReady request preview result
  AppEvent (ChildStopped request outcome) -> do
    state <- get
    when (stateMachineRequest state == Just request) $
      if isProcessLoading state
        then put state {statePendingExit = Just outcome, stateMachineFailure = protocolFailure outcome}
        else case outcome of
          MachineProtocolFailed failure -> do
            put state {statePendingExit = Just outcome, stateMachineFailure = Just failure}
            finalizePendingExit
          MachineExited _ _ -> do
            put state {statePendingExit = Just outcome}
            queueEmpty <- liftIO . atomically $ isEmptyTBQueue (stateEvents state)
            if queueEmpty
              then finalizePendingExit
              else liftIO (notifyFrame (stateChannel state) (stateFramePending state))
  AppEvent (PersonPromptReady decision generation result) -> do
    state <- get
    when (statePersonLoading state == Just (decision, generation) && listToMaybe (stateMandatoryDecisions state) == Just decision) $ case result of
      Left failure -> do
        let message = "private person question is invalid: " <> failure
        put
          state
            { statePendingExit = Just (MachineProtocolFailed message),
              stateMachineFailure = Just message,
              statePersonLoading = Nothing,
              statePersonError = Just failure
            }
        finalizePendingExit
      Right prompt -> do
        vScrollToBeginning (viewportScroll PersonViewport)
        put
          state
            { statePersonLoading = Nothing,
              statePersonPrompt = Just (decision, prompt),
              statePersonSubmitted = False,
              statePersonControlId = Nothing,
              statePersonError = Nothing,
              statePersonEditor = blankEditor
            }
  AppEvent (FinalResultReady runId result) -> do
    state <- get
    when (maybe False ((== runId) . snapshotRunId) (modelSnapshot (stateModel state))) $
      put state {stateFinalLoading = False, stateFinalResult = Just result}
  VtyEvent (Vty.EvResize width height) -> modify $ \state ->
    let model = stateModel state
        status = case modelScreen model of
          ConfirmScreen preview
            | localReviewAllowed state preview (width, height) -> "complete launch review is visible"
            | otherwise -> "launch disabled until the complete review fits"
          _ -> modelStatus model
     in state {stateTerminalSize = (width, height), stateModel = model {modelStatus = status}}
  VtyEvent key -> handleKey event key
  _ -> pure ()

resetEnteredViewport :: AppState -> AppState -> EventM Name AppState ()
resetEnteredViewport before after = do
  let oldScreen = modelScreen (stateModel before)
      newScreen = modelScreen (stateModel after)
      oldDecision = listToMaybe (stateMandatoryDecisions before)
      newDecision = listToMaybe (stateMandatoryDecisions after)
  when (newFailure oldScreen newScreen) (vScrollToBeginning (viewportScroll FailureViewport))
  when (newHelp oldScreen newScreen) (vScrollToBeginning (viewportScroll HelpViewport))
  when (oldDecision /= newDecision && maybe False ((== MandatoryRecovery) . mandatoryKind) newDecision) (vScrollToBeginning (viewportScroll RecoveryViewport))
  when (oldDecision /= newDecision && maybe False ((== MandatoryPerson) . mandatoryKind) newDecision) (vScrollToBeginning (viewportScroll PersonViewport))
  where
    newFailure (FailureScreen old) (FailureScreen new) = old /= new
    newFailure _ FailureScreen {} = True
    newFailure _ _ = False
    newHelp (HelpScreen old) (HelpScreen new) = old /= new
    newHelp _ HelpScreen {} = True
    newHelp _ _ = False

finalizePendingExit :: EventM Name AppState ()
finalizePendingExit = do
  state <- get
  case statePendingExit state of
    Nothing -> pure ()
    Just outcome -> do
      case outcome of
        MachineProtocolFailed _ -> liftIO (mapM_ terminateMachine (stateRunning state))
        MachineExited {} -> pure ()
      liftIO (cancelWorker state PersonWork >> writeIORef (stateOwned state) Nothing)
      let model = stateModel state
          stoppedModel = case stateMachineFailure state of
            Just failure -> model {modelScreen = FailureScreen failure, modelStatus = "machine protocol failed"}
            Nothing -> case outcome of
              MachineExited status diagnostic
                | maybe False (terminalStatus . snapshotRunStatus) (modelSnapshot model) -> model
                | otherwise ->
                    let detail = if T.null diagnostic then "" else "; " <> diagnostic
                     in model
                          { modelScreen = FailureScreen ("machine child exited before a terminal protocol event (" <> T.pack (show status) <> ")" <> detail),
                            modelStatus = "machine child failed"
                          }
              MachineProtocolFailed failure -> model {modelScreen = FailureScreen failure, modelStatus = "machine protocol failed"}
      put
        state
          { stateModel = stoppedModel,
            stateRunning = Nothing,
            statePendingExit = Nothing,
            stateMachineFailure = Nothing,
            stateMachineRequest = Nothing,
            stateCancelConfirm = False,
            stateSteerTiming = Nothing,
            stateMandatoryDecisions = [],
            statePersonLoading = Nothing,
            statePersonPrompt = Nothing
          }
      refreshRuns

handleKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleKey original key = do
  state <- get
  case activeLayer state of
    KeyHelpLayer -> handleKeyHelp key
    CancelLayer -> handleCancelKey key
    PersonLayer -> handlePersonKey original key
    RecoveryLayer -> maybe (pure ()) (\decision -> handleRecoveryKey (mandatoryOccurrence decision) key) (listToMaybe (stateMandatoryDecisions state))
    SteerLayer -> handleSteerKey original key
    SaveLayer -> handleSaveResultKey original key
    FilterLayer -> handleFilterKey original key
    ConfirmDetailsLayer -> handleConfirmDetailsKey key
    ConfirmLayer -> handleConfirmKey key
    RunDetailsLayer -> handleRunDetailsKey key
    ScreenLayer -> handleScreenKey original key

handleKeyHelp :: Vty.Event -> EventM Name AppState ()
handleKeyHelp key = case key of
  Vty.EvKey Vty.KEsc [] -> close
  Vty.EvKey (Vty.KChar '?') [] -> close
  Vty.EvKey Vty.KUp [] -> vScrollBy scroll (-1)
  Vty.EvKey Vty.KDown [] -> vScrollBy scroll 1
  Vty.EvKey Vty.KPageUp [] -> vScrollBy scroll (-10)
  Vty.EvKey Vty.KPageDown [] -> vScrollBy scroll 10
  Vty.EvKey Vty.KHome [] -> vScrollToBeginning scroll
  Vty.EvKey Vty.KEnd [] -> vScrollToEnd scroll
  _ -> pure ()
  where
    scroll = viewportScroll KeyHelpViewport
    close = modify (\state -> state {stateKeyHelp = False})

handleRunDetailsKey :: Vty.Event -> EventM Name AppState ()
handleRunDetailsKey key = case key of
  Vty.EvKey Vty.KEsc [] -> close
  Vty.EvKey (Vty.KChar 'd') [] -> close
  Vty.EvKey Vty.KUp [] -> vScrollBy scroll (-1)
  Vty.EvKey Vty.KDown [] -> vScrollBy scroll 1
  Vty.EvKey Vty.KPageUp [] -> vScrollBy scroll (-10)
  Vty.EvKey Vty.KPageDown [] -> vScrollBy scroll 10
  Vty.EvKey Vty.KHome [] -> vScrollToBeginning scroll
  Vty.EvKey Vty.KEnd [] -> vScrollToEnd scroll
  _ -> pure ()
  where
    scroll = viewportScroll FailureViewport
    close = modify (\state -> state {stateRunDetails = False})

handlePersonKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handlePersonKey original key = do
  state <- get
  case key of
    Vty.EvKey Vty.KEsc [] -> requestCancellation
    Vty.EvKey Vty.KPageUp [] -> vScrollBy promptScroll (-10)
    Vty.EvKey Vty.KPageDown [] -> vScrollBy promptScroll 10
    Vty.EvKey Vty.KHome [] -> vScrollToBeginning promptScroll
    Vty.EvKey Vty.KEnd [] -> vScrollToEnd promptScroll
    Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl]
      | isJust (statePersonPrompt state) && not (statePersonSubmitted state) -> submitPersonAnswer
    _
      | statePersonSubmitted state || not (isJust (statePersonPrompt state)) -> pure ()
      | otherwise -> handlePersonEditorInput original
  where
    promptScroll = viewportScroll PersonViewport

handleSteerKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleSteerKey original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateSteerTiming = Nothing, stateControlError = Nothing})
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> submitSteer
  _ -> handleControlEditorInput original

handleConfirmKey :: Vty.Event -> EventM Name AppState ()
handleConfirmKey key = case key of
  Vty.EvKey (Vty.KChar 'y') [] -> confirmLaunch
  Vty.EvKey Vty.KEnter [] -> confirmLaunch
  Vty.EvKey (Vty.KChar 'n') [] -> declinePreview
  Vty.EvKey Vty.KEsc [] -> declinePreview
  Vty.EvKey (Vty.KChar 'd') [] -> do
    modify (\state -> state {stateConfirmDetails = True})
    vScrollToBeginning (viewportScroll ConfirmDetailsViewport)
  Vty.EvKey (Vty.KChar '?') [] -> openKeyHelp
  _ -> pure ()

handleConfirmDetailsKey :: Vty.Event -> EventM Name AppState ()
handleConfirmDetailsKey key = case key of
  Vty.EvKey (Vty.KChar 'y') [] -> confirmLaunch
  Vty.EvKey Vty.KEnter [] -> confirmLaunch
  Vty.EvKey (Vty.KChar 'n') [] -> declinePreview
  Vty.EvKey Vty.KEsc [] -> summary
  Vty.EvKey (Vty.KChar 'd') [] -> summary
  Vty.EvKey Vty.KUp [] -> vScrollBy scroll (-1)
  Vty.EvKey Vty.KDown [] -> vScrollBy scroll 1
  Vty.EvKey Vty.KPageUp [] -> vScrollBy scroll (-10)
  Vty.EvKey Vty.KPageDown [] -> vScrollBy scroll 10
  Vty.EvKey Vty.KHome [] -> vScrollToBeginning scroll
  Vty.EvKey Vty.KEnd [] -> vScrollToEnd scroll
  Vty.EvKey (Vty.KChar '?') [] -> openKeyHelp
  _ -> pure ()
  where
    scroll = viewportScroll ConfirmDetailsViewport
    summary = modify (\state -> state {stateConfirmDetails = False})

handleScreenKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleScreenKey original key = do
  state <- get
  case (modelScreen (stateModel state), key) of
    (InputScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
    (InputScreen _, Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl]) -> submitEditor
    (InputScreen _, _) -> handleEditorInput original
    (_, Vty.EvKey (Vty.KChar '?') []) -> openKeyHelp
    (InitialLoading, Vty.EvKey (Vty.KChar 'q') []) -> halt
    (InitialLoading, Vty.EvKey Vty.KEsc []) -> halt
    (BrowserScreen, Vty.EvKey (Vty.KChar 'q') [])
      | not (isJust (stateRunning state)) -> halt
    (BrowserScreen, Vty.EvKey Vty.KEsc []) -> handleBrowserEscape
    (BrowserScreen, Vty.EvKey Vty.KLeft []) -> focusPrimary
    (BrowserScreen, Vty.EvKey Vty.KRight []) -> focusSecondary
    (BrowserScreen, Vty.EvKey Vty.KUp []) -> handleMove (-1)
    (BrowserScreen, Vty.EvKey Vty.KDown []) -> handleMove 1
    (BrowserScreen, Vty.EvKey (Vty.KChar '\t') []) -> cycleBrowserTab
    (BrowserScreen, Vty.EvKey (Vty.KChar 'p') [])
      | modelTab (stateModel state) == RoutingTab -> cycleRoutingPersona
    (BrowserScreen, Vty.EvKey Vty.KEnter []) -> handleEnter
    (BrowserScreen, Vty.EvKey (Vty.KChar 'h') [])
      | modelTab (stateModel state) == WorkflowsTab -> showSelectedHelp
    (BrowserScreen, Vty.EvKey (Vty.KChar '/') [])
      | modelTab (stateModel state) == WorkflowsTab -> openWorkflowFilter
    (BrowserScreen, Vty.EvKey (Vty.KChar 'r') [])
      | modelTab (stateModel state) == RunsTab -> beginLineage RestartRun
    (BrowserScreen, Vty.EvKey (Vty.KChar 'm') [])
      | modelTab (stateModel state) == RunsTab -> beginLineage ResumeRun
    (BrowserScreen, Vty.EvKey (Vty.KChar 'f') [])
      | modelTab (stateModel state) == RunsTab -> beginLineage ForkRun
    (BrowserScreen, Vty.EvKey (Vty.KChar 'c') [])
      | isJust (stateRunning state) -> requestCancellation
    (TargetScreen, Vty.EvKey Vty.KEsc []) -> handleEscape
    (TargetScreen, Vty.EvKey Vty.KUp []) -> vScrollBy (viewportScroll TargetViewport) (-1)
    (TargetScreen, Vty.EvKey Vty.KDown []) -> vScrollBy (viewportScroll TargetViewport) 1
    (TargetScreen, Vty.EvKey (Vty.KChar 's') []) -> chooseScripted
    (TargetScreen, Vty.EvKey (Vty.KChar 'l') []) -> chooseLive
    (TargetScreen, Vty.EvKey Vty.KEnter []) -> chooseLive
    (TargetScreen, Vty.EvKey (Vty.KChar 'p') []) -> cycleRoutingPersona
    (PreviewLoading, Vty.EvKey Vty.KEsc []) -> cancelPreview
    (ProcessLoading _, Vty.EvKey Vty.KEsc []) -> cancelProcessStart
    (LaunchingScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
    (LaunchingScreen _, Vty.EvKey (Vty.KChar 'c') []) -> requestCancellation
    (LiveScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
    (LiveScreen _, Vty.EvKey (Vty.KChar 'd') []) -> do
      put state {stateRunDetails = True}
      vScrollToBeginning (viewportScroll FailureViewport)
    (LiveScreen _, Vty.EvKey (Vty.KChar '\t') []) -> togglePaneFocus
    (LiveScreen _, Vty.EvKey Vty.KUp []) -> handleMove (-1)
    (LiveScreen _, Vty.EvKey Vty.KDown []) -> handleMove 1
    (LiveScreen _, Vty.EvKey Vty.KPageUp []) -> scrollFocusedOutput (-10)
    (LiveScreen _, Vty.EvKey Vty.KPageDown []) -> scrollFocusedOutput 10
    (LiveScreen _, Vty.EvKey (Vty.KChar 'G') []) -> followOutputTail
    (LiveScreen _, Vty.EvKey Vty.KEnd []) -> followOutputTail
    (LiveScreen _, Vty.EvKey (Vty.KChar 'j') []) -> moveOccurrence 1
    (LiveScreen _, Vty.EvKey (Vty.KChar 'k') []) -> moveOccurrence (-1)
    (LiveScreen _, Vty.EvKey (Vty.KChar 'i') []) -> openSteer InterruptNow
    (LiveScreen _, Vty.EvKey (Vty.KChar 'b') []) -> openSteer NextBoundary
    (LiveScreen _, Vty.EvKey (Vty.KChar digit) [])
      | digit >= '1' && digit <= '9' -> redirectSelected (fromEnum digit - fromEnum '1')
    (LiveScreen _, Vty.EvKey (Vty.KChar 'c') []) -> requestCancellation
    (LiveScreen _, Vty.EvKey (Vty.KChar 'r') []) -> showFinalResult
    (LiveScreen _, Vty.EvKey (Vty.KChar 's') [])
      | Just (Right _) <- stateFinalResult state -> openSaveResult
    (HelpLoading, Vty.EvKey Vty.KEsc []) -> cancelHelp
    (HelpScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
    (HelpScreen _, Vty.EvKey Vty.KUp []) -> vScrollBy (viewportScroll HelpViewport) (-1)
    (HelpScreen _, Vty.EvKey Vty.KDown []) -> vScrollBy (viewportScroll HelpViewport) 1
    (HelpScreen _, Vty.EvKey Vty.KPageUp []) -> vScrollBy (viewportScroll HelpViewport) (-10)
    (HelpScreen _, Vty.EvKey Vty.KPageDown []) -> vScrollBy (viewportScroll HelpViewport) 10
    (HelpScreen _, Vty.EvKey Vty.KHome []) -> vScrollToBeginning (viewportScroll HelpViewport)
    (HelpScreen _, Vty.EvKey Vty.KEnd []) -> vScrollToEnd (viewportScroll HelpViewport)
    (FailureScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
    (FailureScreen _, Vty.EvKey Vty.KUp []) -> vScrollBy (viewportScroll FailureViewport) (-1)
    (FailureScreen _, Vty.EvKey Vty.KDown []) -> vScrollBy (viewportScroll FailureViewport) 1
    (FailureScreen _, Vty.EvKey Vty.KPageUp []) -> vScrollBy (viewportScroll FailureViewport) (-10)
    (FailureScreen _, Vty.EvKey Vty.KPageDown []) -> vScrollBy (viewportScroll FailureViewport) 10
    (FailureScreen _, Vty.EvKey Vty.KHome []) -> vScrollToBeginning (viewportScroll FailureViewport)
    (FailureScreen _, Vty.EvKey Vty.KEnd []) -> vScrollToEnd (viewportScroll FailureViewport)
    _ -> pure ()

openKeyHelp :: EventM Name AppState ()
openKeyHelp = do
  modify (\state -> state {stateKeyHelp = True})
  vScrollToBeginning (viewportScroll KeyHelpViewport)

focusPrimary :: EventM Name AppState ()
focusPrimary = modify (\state -> state {statePaneFocus = PrimaryPane})

focusSecondary :: EventM Name AppState ()
focusSecondary = modify (\state -> state {statePaneFocus = SecondaryPane})

togglePaneFocus :: EventM Name AppState ()
togglePaneFocus = modify $ \state -> state {statePaneFocus = if statePaneFocus state == PrimaryPane then SecondaryPane else PrimaryPane}

handleBrowserEscape :: EventM Name AppState ()
handleBrowserEscape = do
  state <- get
  if statePaneFocus state == SecondaryPane
    then put state {statePaneFocus = PrimaryPane}
    else handleEscape

scrollFocusedOutput :: Int -> EventM Name AppState ()
scrollFocusedOutput amount = do
  state <- get
  when (statePaneFocus state == SecondaryPane) $ do
    put state {stateOutputFollow = False}
    vScrollBy (viewportScroll OutputViewport) amount

showFinalResult :: EventM Name AppState ()
showFinalResult = do
  state <- get
  case stateFinalResult state of
    Just _ -> do
      put state {stateShowResult = True, statePaneFocus = SecondaryPane, stateOutputFollow = False}
      vScrollToBeginning (viewportScroll OutputViewport)
    Nothing -> put state {stateControlError = Just "the verified final result is not available yet"}

declinePreview :: EventM Name AppState ()
declinePreview =
  modify (\state -> state {stateModel = previousStep (stateModel state), stateConfirmDetails = False, statePaneFocus = PrimaryPane})

cancelPreview :: EventM Name AppState ()
cancelPreview = do
  state <- get
  liftIO (cancelWorker state PreviewWork)
  put state {statePreviewRequest = Nothing, stateModel = previousStep (stateModel state)}

cancelHelp :: EventM Name AppState ()
cancelHelp = do
  state <- get
  liftIO (cancelWorker state HelpWork)
  put state {stateHelpRequest = Nothing, stateModel = previousStep (stateModel state)}

handleRecoveryKey :: OccurrenceId -> Vty.Event -> EventM Name AppState ()
handleRecoveryKey occurrence key = case key of
  Vty.EvKey (Vty.KChar 'r') [] -> sendRecoveryFor occurrence RecoveryRetry
  Vty.EvKey (Vty.KChar 'f') [] -> sendRecoveryFor occurrence RecoveryFailOver
  Vty.EvKey (Vty.KChar 'a') [] -> sendRecoveryFor occurrence RecoveryAbandon
  Vty.EvKey (Vty.KChar 'c') [] -> requestCancellation
  Vty.EvKey Vty.KUp [] -> vScrollBy scroll (-1)
  Vty.EvKey Vty.KDown [] -> vScrollBy scroll 1
  Vty.EvKey Vty.KPageUp [] -> vScrollBy scroll (-10)
  Vty.EvKey Vty.KPageDown [] -> vScrollBy scroll 10
  Vty.EvKey Vty.KHome [] -> vScrollToBeginning scroll
  Vty.EvKey Vty.KEnd [] -> vScrollToEnd scroll
  Vty.EvKey (Vty.KChar '?') [] -> openKeyHelp
  _ -> pure ()
  where
    scroll = viewportScroll RecoveryViewport

handleCancelKey :: Vty.Event -> EventM Name AppState ()
handleCancelKey key = do
  state <- get
  case key of
    Vty.EvKey (Vty.KChar 'y') [] -> confirmCancellation
    Vty.EvKey (Vty.KChar 'n') [] -> put state {stateCancelConfirm = False}
    Vty.EvKey Vty.KEsc [] -> put state {stateCancelConfirm = False}
    _ -> pure ()

openWorkflowFilter :: EventM Name AppState ()
openWorkflowFilter = do
  state <- get
  let query = modelWorkflowFilter (stateModel state)
  put state {stateFilterEditing = True, stateFilterEditor = Edit.editorText InputEditor (Just 1) query}

handleFilterKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleFilterKey original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateFilterEditing = False})
  Vty.EvKey Vty.KEnter [] -> applyFilter
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> applyFilter
  _ -> do
    state <- get
    (editor, ()) <- nestEventM (stateFilterEditor state) (Edit.handleEditorEvent original)
    let query = T.intercalate "\n" (Edit.getEditContents editor)
    if BS.length (TE.encodeUtf8 query) <= 256
      then put state {stateFilterEditor = editor}
      else put state {stateModel = (stateModel state) {modelStatus = "workflow filter exceeds 256 UTF-8 bytes"}}
  where
    applyFilter = do
      state <- get
      let query = T.unwords (T.words (T.intercalate "\n" (Edit.getEditContents (stateFilterEditor state))))
      put state {stateFilterEditing = False, stateModel = (setWorkflowFilter query (stateModel state)) {modelStatus = "workflow filter applied"}}

openSaveResult :: EventM Name AppState ()
openSaveResult = do
  vScrollToBeginning (viewportScroll FailureViewport)
  modify
    ( \state ->
        state
          { stateSaveResult = True,
            stateSaveError = Nothing,
            stateSaveEditor = Edit.editorText InputEditor (Just 1) ""
          }
    )

handleSaveResultKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleSaveResultKey original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateSaveResult = False, stateSaveError = Nothing})
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> saveFinalResult
  Vty.EvKey Vty.KPageUp [] -> vScrollBy (viewportScroll FailureViewport) (-10)
  Vty.EvKey Vty.KPageDown [] -> vScrollBy (viewportScroll FailureViewport) 10
  _ -> do
    state <- get
    (editor, ()) <- nestEventM (stateSaveEditor state) (Edit.handleEditorEvent original)
    let path = T.intercalate "\n" (Edit.getEditContents editor)
    if BS.length (TE.encodeUtf8 path) <= 4096
      then put state {stateSaveEditor = editor, stateSaveError = Nothing}
      else put state {stateSaveError = Just "result path exceeds 4096 UTF-8 bytes"}

saveFinalResult :: EventM Name AppState ()
saveFinalResult = do
  state <- get
  let pathText = T.intercalate "\n" (Edit.getEditContents (stateSaveEditor state))
  case stateFinalResult state of
    Just (Right value) -> do
      result <- liftIO (try @SomeException (saveResultFile (T.unpack pathText) value))
      case result of
        Left failure | Just _ <- fromException @SomeAsyncException failure -> liftIO (throwIO failure)
        Left failure -> put state {stateSaveError = Just (T.pack (displayException failure))}
        Right () ->
          put
            state
              { stateSaveResult = False,
                stateSaveError = Nothing,
                stateModel = (stateModel state) {modelStatus = "saved verified final result to " <> pathText}
              }
    _ -> put state {stateSaveError = Just "verified final result is not available"}

saveResultFile :: FilePath -> Value -> IO ()
saveResultFile path value = do
  when (not (isAbsolute path) || any (`elem` ['\NUL', '\n', '\r']) path) $
    ioError (userError "result destination must be one absolute single-line path")
  descriptor <- openFd path WriteOnly privateOutputFlags
  handle <- fdToHandle descriptor `onException` closeFd descriptor
  (BS.hPut handle (BL.toStrict (encode value <> "\n"))) `finally` hClose handle

privateOutputFlags :: OpenFileFlags
privateOutputFlags =
  defaultFileFlags
    { creat = Just (ownerReadMode `unionFileModes` ownerWriteMode),
      exclusive = True,
      nofollow = True,
      cloexec = True
    }

cycleRoutingPersona :: EventM Name AppState ()
cycleRoutingPersona = withLocalBackend $ \config _ -> do
  state <- get
  let model = stateModel state
      allowedScreen = modelScreen model == TargetScreen || (modelScreen model == BrowserScreen && modelTab model == RoutingTab)
  when (allowedScreen && stateRoutingRequest state == Nothing) $ case modelRouting model of
    Left failure -> put state {stateModel = model {modelStatus = "routing unavailable: " <> failure}}
    Right routing -> case routingSummaryPersonas routing of
      [] -> put state {stateModel = model {modelStatus = "routing inspection offers no personas"}}
      personas -> do
        let current = routingSummaryPersona routing >>= (`elemIndex` personas)
            next = personas !! ((fromMaybe (-1) current + 1) `mod` length personas)
            channel = stateChannel state
        put state {stateRoutingRequest = Just next, stateModel = model {modelStatus = "loading routing persona " <> next}}
        liftIO . startWorker state RoutingWork $ loadRoutingSummary config (Just next) >>= writeBChan channel . RoutingReady next

cycleBrowserTab :: EventM Name AppState ()
cycleBrowserTab = do
  state <- get
  let model = cycleTab (stateModel state)
  put state {stateModel = model, statePaneFocus = PrimaryPane}
  vScrollToBeginning (viewportScroll BrowserDetailViewport)
  when (modelTab model == RunsTab) refreshRuns

refreshRuns :: EventM Name AppState ()
refreshRuns = withLocalBackend $ \config root -> do
  state <- get
  let channel = stateChannel state
  liftIO . startWorker state RunsWork $ loadRunCatalogue config root >>= writeBChan channel . RunsReady

handleMove :: Int -> EventM Name AppState ()
handleMove delta = do
  state <- get
  case modelScreen (stateModel state) of
    BrowserScreen
      | statePaneFocus state == SecondaryPane -> vScrollBy (viewportScroll BrowserDetailViewport) delta
      | otherwise -> do
          put state {stateModel = moveSelection delta (stateModel state)}
          vScrollToBeginning (viewportScroll BrowserDetailViewport)
    TargetScreen -> put state {stateModel = moveSelection delta (stateModel state)}
    LaunchingScreen _ -> pure ()
    LiveScreen _
      | statePaneFocus state == PrimaryPane -> moveOccurrence delta
      | otherwise -> do
          put state {stateOutputFollow = False}
          vScrollBy (viewportScroll OutputViewport) delta
    _ -> pure ()

handleEnter :: EventM Name AppState ()
handleEnter = do
  state <- get
  case modelScreen (stateModel state) of
    BrowserScreen
      | Just running <- stateRunning state ->
          put state {stateModel = (stateModel state) {modelScreen = LiveScreen (runningRunId running), modelStatus = "reattached to owned run"}, statePaneFocus = PrimaryPane}
      | modelTab (stateModel state) == WorkflowsTab -> do
          let model = beginWorkflow (stateModel state)
          put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing (inputValue model), statePaneFocus = PrimaryPane}
      | modelTab (stateModel state) == RunsTab -> openSelectedRun
    _ -> pure ()

openSelectedRun :: EventM Name AppState ()
openSelectedRun = do
  state <- get
  case selectedRun (stateModel state) of
    Nothing -> put state {stateModel = (stateModel state) {modelStatus = "no run selected"}}
    Just (CatalogueCorrupt path failure) ->
      put state {stateModel = (stateModel state) {modelScreen = FailureScreen (T.pack path <> ": " <> failure)}}
    Just (CatalogueRun record) -> case recordSnapshot record of
      Nothing -> put state {stateModel = (stateModel state) {modelScreen = FailureScreen "the selected run has no validated protocol events"}}
      Just snapshot -> do
        let manifest = recordManifest record
            startedAt = fromMaybe (stateNow state) (parseFrontendTime (frontendCreatedAt manifest))
            model =
              (stateModel state)
                { modelScreen = LiveScreen (snapshotRunId snapshot),
                  modelSnapshot = Just snapshot,
                  modelStatus = "reconstructed from private run store"
                }
        put
          state
            { stateModel = model,
              stateViewingRecord = Just record,
              stateRuntimeDirectory = Just (recordDirectory record </> frontendRuntimeStore manifest),
              stateRunView = reconcileRunView snapshot emptyRunView,
              statePaneFocus = PrimaryPane,
              stateOutputFollow = True,
              stateShowResult = False,
              stateRunDetails = False,
              stateRunStartedAt = Just startedAt,
              stateRunPersona = frontendPersona manifest,
              stateRunRealization = Just (runRecordRealizations record),
              stateSaveResult = False,
              stateSaveError = Nothing,
              stateMandatoryDecisions = [],
              statePersonLoading = Nothing,
              statePersonPrompt = Nothing,
              statePersonSubmitted = False,
              statePersonControlId = Nothing,
              statePersonError = Nothing,
              stateFinalResult = Nothing,
              stateFinalLoading = False
            }
        ensureAuxiliaryLoads

beginLineage :: LineageOperation -> EventM Name AppState ()
beginLineage operation = withLocalBackend $ \config root -> do
  state <- get
  if isJust (stateRunning state)
    then put state {stateModel = (stateModel state) {modelStatus = "an owned run is already active; reattach or cancel it first"}}
    else
      if modelTab (stateModel state) /= RunsTab
        then pure ()
        else case selectedRun (stateModel state) of
          Nothing -> put state {stateModel = (stateModel state) {modelStatus = "no run selected"}}
          Just (CatalogueCorrupt path failure) ->
            put state {stateModel = (stateModel state) {modelScreen = FailureScreen (T.pack path <> ": " <> failure)}}
          Just (CatalogueRun record)
            | recordOwnership record == RunOwnedElsewhere ->
                put state {stateModel = (stateModel state) {modelScreen = FailureScreen "the selected nonterminal run has another live owner"}}
            | otherwise -> case find ((== frontendWorkflow (recordManifest record)) . workflowName) (modelWorkflows (stateModel state)) of
                Nothing -> put state {stateModel = (stateModel state) {modelScreen = FailureScreen "the selected run workflow is absent from this runner catalogue"}}
                Just descriptor -> do
                  let request = stateRequestSerial state + 1
                      model =
                        (stateModel state)
                          { modelScreen = PreviewLoading,
                            modelWorkflow = Just descriptor,
                            modelStatus = "validating exact-input lineage launch"
                          }
                      channel = stateChannel state
                  put state {stateModel = model, stateRequestSerial = request, statePreviewRequest = Just request}
                  liftIO . startWorker state PreviewWork $ buildLineagePreview config root descriptor record operation >>= writeBChan channel . PreviewReady request

submitEditor :: EventM Name AppState ()
submitEditor = do
  state <- get
  case modelScreen (stateModel state) of
    InputScreen _ -> do
      let value = T.intercalate "\n" (Edit.getEditContents (stateEditor state))
          model = submitInput value (stateModel state)
      put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing (inputValue model)}
    _ -> pure ()

chooseScripted :: EventM Name AppState ()
chooseScripted = beginPreview TargetScripted

chooseLive :: EventM Name AppState ()
chooseLive = do
  state <- get
  let model = stateModel state
  case modelRouting model of
    Left failure -> put state {stateModel = model {modelScreen = FailureScreen failure}}
    Right routing
      | any (not . engineChoiceCredentialReady) (routingSummaryEngines routing) ->
          put state {stateModel = model {modelStatus = "routing engine is NOT READY"}}
      | otherwise -> case routingSummaryPersona routing of
          Nothing -> put state {stateModel = model {modelScreen = FailureScreen "routing inspection selected no persona"}}
          Just persona ->
            beginPreview
              ( TargetRouting
                  persona
                  (routingSummaryArguments routing)
                  (routingSummaryFingerprint routing)
              )

beginPreview :: TargetSelection -> EventM Name AppState ()
beginPreview target = withLocalBackend $ \config root -> do
  state <- get
  case modelWorkflow (stateModel state) of
    Nothing -> put state {stateModel = (stateModel state) {modelScreen = FailureScreen "no workflow selected"}}
    Just descriptor -> do
      let request = stateRequestSerial state + 1
          model = chooseTarget target (stateModel state)
          inputs = modelInputs model
          channel = stateChannel state
          routing = case target of
            TargetScripted -> Nothing
            TargetRouting {} -> either (const Nothing) Just (modelRouting model)
            TargetRestored {} -> Nothing
      put state {stateModel = model, stateRequestSerial = request, statePreviewRequest = Just request}
      liftIO . startWorker state PreviewWork $ do
        result <- buildLaunchPreview config root descriptor inputs target
        writeBChan channel (PreviewReady request (fmap (\preview -> preview {previewRouting = routing}) result))

confirmLaunch :: EventM Name AppState ()
confirmLaunch = withLocalBackend $ \config root -> do
  state <- get
  case modelScreen (stateModel state) of
    ConfirmScreen preview
      | not (launchReviewAllowed config preview (stateTerminalSize state)) ->
          put state {stateModel = (stateModel state) {modelStatus = "launch disabled until the complete review fits"}}
      | otherwise -> do
          let request = stateRequestSerial state + 1
              channel = stateChannel state
              queue = stateEvents state
              notify = notifyFrame channel (stateFramePending state)
              stopped = writeBChan channel . ChildStopped request
              starting =
                state
                  { stateModel = (stateModel state) {modelScreen = ProcessLoading preview, modelStatus = "starting validated machine child"},
                    stateRequestSerial = request,
                    stateMachineRequest = Just request,
                    stateConfirmDetails = False
                  }
          put starting
          liftIO . startWorker starting MachineWork $ do
            result <- case stateServer state of
              Nothing -> pure (Left "capability server identity is unavailable")
              Just server -> mask $ \_ -> do
                launched <- startMachine server config root preview queue notify stopped
                case launched of
                  Right running -> writeIORef (stateOwned state) (Just running)
                  Left _ -> pure ()
                pure launched
            writeBChan channel (MachineReady request preview result)
    _ -> pure ()

handleMachineReady :: Int -> LaunchPreview -> Either Text RunningMachine -> EventM Name AppState ()
handleMachineReady request preview result = do
  state <- get
  when (stateMachineRequest state == Just request && isProcessLoading state) $ case result of
    Left failure -> do
      liftIO (discardQueuedFrames state)
      put
        state
          { stateMachineRequest = Nothing,
            stateModel = (stateModel state) {modelScreen = FailureScreen failure, modelStatus = "machine startup failed"}
          }
    Right running -> do
      now <- liftIO getCurrentTime
      put (adoptRunning state preview running now)
      liftIO (activateMachine running >> notifyFrame (stateChannel state) (stateFramePending state))

adoptRunning :: AppState -> LaunchPreview -> RunningMachine -> UTCTime -> AppState
adoptRunning state preview running now =
  state
    { stateRunning = Just running,
      stateRunView = emptyRunView,
      statePaneFocus = PrimaryPane,
      stateOutputFollow = True,
      stateShowResult = False,
      stateRunDetails = False,
      stateRunStartedAt = Just now,
      stateRunPersona = previewPersona preview,
      stateRunRealization = Just (previewRealizationSummary preview),
      stateSaveResult = False,
      stateSaveError = Nothing,
      stateRuntimeDirectory = Just (runningDirectory running </> "runtime"),
      stateViewingRecord = Nothing,
      stateMandatoryDecisions = [],
      statePersonLoading = Nothing,
      statePersonPrompt = Nothing,
      statePersonSubmitted = False,
      statePersonControlId = Nothing,
      statePersonError = Nothing,
      stateSteerTiming = Nothing,
      stateControlError = Nothing,
      stateFinalResult = Nothing,
      stateFinalLoading = False,
      stateModel = launchStarted (runningRunId running) (initialRunSnapshot (runningRunId running)) (stateModel state)
    }

cancelProcessStart :: EventM Name AppState ()
cancelProcessStart = do
  state <- get
  liftIO (cancelWorker state MachineWork)
  owned <- liftIO (readIORef (stateOwned state))
  case (modelScreen (stateModel state), owned) of
    (ProcessLoading preview, Just running) -> do
      now <- liftIO getCurrentTime
      put ((adoptRunning state preview running now) {stateCancelConfirm = True})
      liftIO (activateMachine running >> notifyFrame (stateChannel state) (stateFramePending state))
    (ProcessLoading _, Nothing) -> do
      liftIO (discardQueuedFrames state)
      put
        state
          { stateMachineRequest = Nothing,
            stateModel = previousStep (stateModel state),
            stateConfirmDetails = False
          }
    _ -> pure ()

discardQueuedFrames :: AppState -> IO ()
discardQueuedFrames state = atomically $ do
  writeTVar (stateFramePending state) False
  let drain = do
        empty <- isEmptyTBQueue (stateEvents state)
        if empty then pure () else readTBQueue (stateEvents state) >> drain
  drain

isProcessLoading :: AppState -> Bool
isProcessLoading state = case modelScreen (stateModel state) of
  ProcessLoading _ -> True
  _ -> False

protocolFailure :: MachineExit -> Maybe Text
protocolFailure (MachineProtocolFailed failure) = Just failure
protocolFailure MachineExited {} = Nothing

previewPersona :: LaunchPreview -> Maybe Text
previewPersona preview = case previewLineage preview of
  Just (_, record) -> frontendPersona (recordManifest record)
  Nothing -> case previewTarget preview of
    TargetRouting persona _ _ -> Just persona
    _ -> Nothing

previewRealizationSummary :: LaunchPreview -> Text
previewRealizationSummary preview = case previewTarget preview of
  TargetScripted -> "scripted"
  TargetRestored kind _ -> kind
  TargetRouting persona _ _ -> case previewRouting preview of
    Nothing -> "routing/" <> persona
    Just routing -> case routingProfilesForPlan (previewPlan preview) routing of
      [] -> "routing/" <> persona
      profiles -> T.take 4096 (T.intercalate " | " (map profileSummary profiles))
  where
    profileSummary profile = routingProfileName profile <> ": " <> T.intercalate " -> " (map routingRungModel (routingProfileRungs profile))

parseFrontendTime :: Text -> Maybe UTCTime
parseFrontendTime = parseTimeM True defaultTimeLocale "%FT%T%QZ" . T.unpack


notifyFrame :: BChan AppEvent -> TVar Bool -> IO ()
notifyFrame channel pending = do
  shouldNotify <- atomically $ do
    already <- readTVar pending
    if already then pure False else writeTVar pending True >> pure True
  when shouldNotify $ do
    written <- writeBChanNonBlocking channel FrameReady
    when (not written) (void (forkIO (writeBChan channel FrameReady)))

handleFrame :: EventM Name AppState ()
handleFrame = do
  state <- get
  if isProcessLoading state
    then liftIO . atomically $ writeTVar (stateFramePending state) False
    else consumeFrame state

consumeFrame :: AppState -> EventM Name AppState ()
consumeFrame state = do
  (envelopes, more) <- liftIO . atomically $ do
    writeTVar (stateFramePending state) False
    values <- drain 512 (stateEvents state)
    pending <- not <$> isEmptyTBQueue (stateEvents state)
    pure (values, pending)
  let stepped = foldSnapshots (modelSnapshot (stateModel state)) envelopes
  case stepped of
    Left failure -> do
      let outcome = MachineProtocolFailed failure
      liftIO (discardQueuedFrames state)
      put state {statePendingExit = Just outcome, stateMachineFailure = Just failure}
      finalizePendingExit
    Right Nothing -> pure ()
    Right (Just snapshot) -> do
      let view = reconcileRunView snapshot (stateRunView state)
          decisions = updateMandatoryDecisions (stateMandatoryDecisions state) envelopes snapshot
          contextNeeded =
            isJust (snapshotWorkflow snapshot)
              && maybe True (not . isJust . snapshotWorkflow) (modelSnapshot (stateModel state))
      put
        state
          { stateModel = snapshotUpdated snapshot (stateModel state),
            stateRunView = view,
            stateMandatoryDecisions = decisions
          }
      when contextNeeded refreshRuns
      when (stateOutputFollow state) (vScrollToEnd (viewportScroll OutputViewport))
      when (terminalStatus (snapshotRunStatus snapshot)) $
        liftIO . void . forkIO $ do
          threadDelay 500000
          mapM_ terminateMachine (stateRunning state)
      ensureAuxiliaryLoads
  if more
    then liftIO (notifyFrame (stateChannel state) (stateFramePending state))
    else finalizePendingExit
  where
    drain :: Int -> TBQueue Envelope -> STM [Envelope]
    drain 0 _ = pure []
    drain count queue = do
      empty <- isEmptyTBQueue queue
      if empty then pure [] else do
        value <- readTBQueue queue
        (value :) <$> drain (count - 1) queue

ensureAuxiliaryLoads :: EventM Name AppState ()
ensureAuxiliaryLoads = withLocalBackend $ \_ root -> do
  original <- get
  case modelSnapshot (stateModel original) of
    Nothing -> pure ()
    Just snapshot -> do
      let headDecision = listToMaybe (stateMandatoryDecisions original)
          headPerson = case headDecision of
            Just decision | mandatoryKind decision == MandatoryPerson -> Just decision
            _ -> Nothing
          promptStillPending = maybe False (\(decision, _) -> Just decision == headPerson) (statePersonPrompt original)
          loadingStillPending = maybe False (\(decision, _) -> Just decision == headPerson) (statePersonLoading original)
          personAck = statePersonControlId original >>= (`Map.lookup` snapshotControlAcks snapshot)
          answerFailed = maybe False ((`elem` ["failed", "rejected-stale", "unsupported"]) . snapshotControlState) personAck
          answerError = if answerFailed then snapshotControlMessage <$> personAck else statePersonError original
          synchronized =
            original
              { statePersonPrompt = if promptStillPending then statePersonPrompt original else Nothing,
                statePersonLoading = if loadingStillPending then statePersonLoading original else Nothing,
                statePersonSubmitted = promptStillPending && statePersonSubmitted original && not answerFailed,
                statePersonControlId = if promptStillPending && not answerFailed then statePersonControlId original else Nothing,
                statePersonError = if promptStillPending then answerError else Nothing,
                statePersonEditor = if promptStillPending then statePersonEditor original else blankEditor
              }
      put synchronized
      state <- get
      case (stateRunning state, stateRuntimeDirectory state, statePersonPrompt state, statePersonLoading state, headPerson) of
        (Just _, Just runtimeDirectory, Nothing, Nothing, Just decision) ->
          case Map.lookup (mandatoryOccurrence decision) (snapshotOccurrences snapshot) of
            Nothing -> pure ()
            Just occurrence -> do
              let generation = statePersonLoadGeneration state + 1
                  channel = stateChannel state
                  runId = snapshotRunId snapshot
              put state {statePersonLoadGeneration = generation, statePersonLoading = Just (decision, generation)}
              liftIO . startWorker state PersonWork $ loadPersonPrompt root runtimeDirectory runId occurrence >>= writeBChan channel . PersonPromptReady decision generation
        _ -> pure ()
      latest <- get
      case (snapshotResult snapshot, stateRuntimeDirectory latest, stateFinalResult latest, stateFinalLoading latest) of
        (Just reference, Just runtimeDirectory, Nothing, False) -> do
          let channel = stateChannel latest
              runId = snapshotRunId snapshot
          put latest {stateFinalLoading = True}
          liftIO . startWorker latest ResultWork $ do
            outcome <- try @SomeException $ do
              components <- privatePathComponents root runtimeDirectory
              withPrivateDirectoryAt root components $ \descriptor ->
                readResultArtifactAt runtimeDirectory descriptor runId reference
            case outcome of
              Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
              _ -> writeBChan channel (FinalResultReady runId (either (Left . T.pack . displayException) Right outcome))
        _ -> pure ()

foldSnapshots :: Maybe RunSnapshot -> [Envelope] -> Either Text (Maybe RunSnapshot)
foldSnapshots initial envelopes = foldl step (Right initial) envelopes
  where
    step result envelope = do
      current <- result
      let snapshot = fromMaybe (initialRunSnapshot (envelopeRunId envelope)) current
      either (Left . snapshotErrorMessage) (Right . Just) (stepRunSnapshot snapshot envelope)

handleEscape :: EventM Name AppState ()
handleEscape = do
  state <- get
  case modelScreen (stateModel state) of
    InputScreen _ -> do
      let value = T.intercalate "\n" (Edit.getEditContents (stateEditor state))
          model = previousStep (storeInput value (stateModel state))
      put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing (inputValue model)}
    TargetScreen -> do
      let model = previousStep (stateModel state)
      put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing (inputValue model)}
    LaunchingScreen _ -> put (detachedState state)
    LiveScreen _ -> put (detachedState state)
    BrowserScreen
      | isJust (stateRunning state) ->
          put state {stateModel = (stateModel state) {modelScreen = maybe BrowserScreen (LiveScreen . runningRunId) (stateRunning state)}, statePaneFocus = PrimaryPane}
    _ -> put state {stateModel = previousStep (stateModel state), statePaneFocus = PrimaryPane}
  where
    detachedState current
      | isJust (stateRunning current) = current {stateModel = (returnToBrowser (stateModel current)) {modelTab = RunsTab}, statePaneFocus = PrimaryPane}
      | otherwise =
          current
            { stateModel = (returnToBrowser (stateModel current)) {modelTab = RunsTab},
              statePaneFocus = PrimaryPane,
              stateShowResult = False,
              stateViewingRecord = Nothing,
              stateRuntimeDirectory = Nothing,
              stateMandatoryDecisions = [],
              statePersonLoading = Nothing,
              statePersonPrompt = Nothing,
              statePersonControlId = Nothing,
              stateFinalResult = Nothing,
              stateFinalLoading = False
            }

requestCancellation :: EventM Name AppState ()
requestCancellation = do
  state <- get
  when (isJust (stateRunning state)) (put state {stateCancelConfirm = True})

confirmCancellation :: EventM Name AppState ()
confirmCancellation = do
  state <- get
  case stateRunning state of
    Nothing -> put state {stateCancelConfirm = False}
    Just running -> do
      identifier <- liftIO (freshControlId "cancel")
      sent <- liftIO (sendMachineControl running (Control identifier Nothing Nothing CancelRun))
      case sent of
        Left failure -> do
          liftIO . void . forkIO $ terminateMachine running
          put state {stateCancelConfirm = False, stateModel = (stateModel state) {modelScreen = FailureScreen failure}}
        Right () -> do
          liftIO . void . forkIO $ do
            threadDelay 5000000
            exited <- tryReadMVar (runningExit running)
            when (not (isJust exited)) (terminateMachine running)
          put state {stateCancelConfirm = False, stateModel = (stateModel state) {modelStatus = "cancellation requested"}}

submitPersonAnswer :: EventM Name AppState ()
submitPersonAnswer = do
  state <- get
  case (stateRunning state, statePersonPrompt state) of
    (Just running, Just (_, prompt)) -> do
      let input = T.intercalate "\n" (Edit.getEditContents (statePersonEditor state))
      case personAnswerValue (personPromptCode prompt) input of
        Left failure -> put state {statePersonError = Just failure}
        Right answer -> do
          identifier <- liftIO (freshControlId "answer")
          let occurrence = personPromptOccurrence prompt
              control = Control identifier (Just occurrence) Nothing (AnswerPerson answer)
          sent <- liftIO (sendMachineControl running control)
          case sent of
            Left failure -> put state {statePersonError = Just failure}
            Right () -> put state {statePersonSubmitted = True, statePersonControlId = Just (controlIdText identifier), statePersonError = Nothing}
    _ -> pure ()

moveOccurrence :: Int -> EventM Name AppState ()
moveOccurrence delta = do
  state <- get
  case modelSnapshot (stateModel state) of
    Nothing -> pure ()
    Just snapshot -> do
      put state {stateRunView = moveOccurrenceSelection delta snapshot (stateRunView state), stateOutputFollow = True, stateShowResult = False}
      vScrollBy (viewportScroll OccurrenceViewport) delta
      vScrollToEnd (viewportScroll OutputViewport)

followOutputTail :: EventM Name AppState ()
followOutputTail = do
  modify (\state -> state {stateOutputFollow = True})
  vScrollToEnd (viewportScroll OutputViewport)

openSteer :: SteeringTiming -> EventM Name AppState ()
openSteer timing = do
  state <- get
  case (stateRunning state, modelSnapshot (stateModel state) >>= \snapshot -> activeAttemptForSelection snapshot (stateRunView state)) of
    (Just _, Just _) ->
      put state {stateSteerTiming = Just timing, stateControlError = Nothing, stateControlEditor = blankEditor}
    _ -> put state {stateControlError = Just "the selected occurrence has no steerable active attempt"}

submitSteer :: EventM Name AppState ()
submitSteer = do
  state <- get
  let text = T.intercalate "\n" (Edit.getEditContents (stateControlEditor state))
  case (stateSteerTiming state, modelSnapshot (stateModel state)) of
    (Just timing, Just snapshot) -> case activeAttemptForSelection snapshot (stateRunView state) of
      Nothing -> put state {stateSteerTiming = Nothing, stateControlError = Just "the selected attempt is no longer active"}
      Just attempt
        | T.null (T.strip text) -> put state {stateControlError = Just "steering text is empty"}
        | otherwise -> sendSelectedControl "steer" (attemptOccurrence attempt) (Just attempt) (Steer timing text) True
    _ -> pure ()

sendRecoveryFor :: OccurrenceId -> RecoveryControl -> EventM Name AppState ()
sendRecoveryFor occurrenceId recovery = do
  state <- get
  case modelSnapshot (stateModel state) >>= \snapshot -> Map.lookup occurrenceId (snapshotOccurrences snapshot) of
    Nothing -> put state {stateControlError = Just "the FIFO recovery occurrence is no longer present"}
    Just occurrence -> case snapshotOccurrenceRecovery occurrence of
      Just pending
        | recoveryName recovery `elem` map recoveryChoice (snapshotRecoveryChoices pending) ->
            sendSelectedControl (recoveryName recovery) occurrenceId Nothing (ChooseRecovery recovery) False
      _ -> put state {stateControlError = Just ("the FIFO recovery occurrence was not offered " <> recoveryName recovery)}

redirectSelected :: Int -> EventM Name AppState ()
redirectSelected index = do
  state <- get
  case modelSnapshot (stateModel state) >>= \snapshot -> selectedOccurrence snapshot (stateRunView state) of
    Nothing -> put state {stateControlError = Just "no occurrence is selected"}
    Just occurrence -> case snapshotOccurrenceDispatch occurrence of
      Just dispatch
        | dispatchOpen dispatch -> case atMay (dispatchTargets dispatch) index of
            Just target -> sendSelectedControl "redirect" (snapshotOccurrenceId occurrence) Nothing (RedirectOccurrence target) False
            Nothing -> put state {stateControlError = Just "that redirect target is not available"}
      _ -> put state {stateControlError = Just "the selected occurrence is not waiting for dispatch"}

sendSelectedControl :: Text -> OccurrenceId -> Maybe AttemptId -> ControlCommand -> Bool -> EventM Name AppState ()
sendSelectedControl purpose occurrence attempt command closeEditor = do
  state <- get
  case stateRunning state of
    Nothing -> put state {stateControlError = Just "this reconstructed run is read-only"}
    Just running -> do
      identifier <- liftIO (freshControlId purpose)
      sent <- liftIO (sendMachineControl running (Control identifier (Just occurrence) attempt command))
      case sent of
        Left failure -> put state {stateControlError = Just failure}
        Right () ->
          put
            state
              { stateSteerTiming = if closeEditor then Nothing else stateSteerTiming state,
                stateControlError = Nothing,
                stateModel = (stateModel state) {modelStatus = purpose <> " control sent"}
              }

recoveryName :: RecoveryControl -> Text
recoveryName RecoveryRetry = "retry"
recoveryName RecoveryFailOver = "failover"
recoveryName RecoveryAbandon = "abandon"

freshControlId :: Text -> IO ControlId
freshControlId purpose = do
  stamp <- getMonotonicTimeNSec
  pure (ControlId ("tui." <> purpose <> "." <> T.pack (show stamp)))

handleEditorInput :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEditorInput event = do
  state <- get
  case modelScreen (stateModel state) of
    InputScreen _ -> do
      (editor, ()) <- nestEventM (stateEditor state) (Edit.handleEditorEvent event)
      if editorBytes editor <= 1024 * 1024
        then put state {stateEditor = editor}
        else put state {stateModel = (stateModel state) {modelStatus = "input exceeds 1048576 UTF-8 bytes"}}
    _ -> pure ()

handlePersonEditorInput :: BrickEvent Name AppEvent -> EventM Name AppState ()
handlePersonEditorInput event = do
  state <- get
  (editor, ()) <- nestEventM (statePersonEditor state) (Edit.handleEditorEvent event)
  if editorBytes editor <= 1024 * 1024
    then put state {statePersonEditor = editor, statePersonError = Nothing}
    else put state {statePersonError = Just "answer exceeds 1048576 UTF-8 bytes"}

handleControlEditorInput :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleControlEditorInput event = do
  state <- get
  (editor, ()) <- nestEventM (stateControlEditor state) (Edit.handleEditorEvent event)
  if editorBytes editor <= 1024 * 1024
    then put state {stateControlEditor = editor, stateControlError = Nothing}
    else put state {stateControlError = Just "control text exceeds 1048576 UTF-8 bytes"}

editorBytes :: Edit.Editor Text Name -> Int
editorBytes = BS.length . TE.encodeUtf8 . T.intercalate "\n" . Edit.getEditContents

terminalStatus :: RunStatus -> Bool
terminalStatus RunSucceeded = True
terminalStatus RunFailedStatus = True
terminalStatus RunCancelledStatus = True
terminalStatus RunStarting = False
terminalStatus RunRunning = False
terminalStatus RunCancelling = False
terminalStatus RunOrphaned = False

showSelectedHelp :: EventM Name AppState ()
showSelectedHelp = withLocalBackend $ \config _ -> do
  state <- get
  let model = stateModel state
  if isJust (stateRunning state)
    then put state {stateModel = model {modelStatus = "an owned run is active; reattach or cancel it first"}}
    else
      when (modelTab model == WorkflowsTab) $ case selectedWorkflow model of
        Nothing -> put state {stateModel = model {modelStatus = "no workflow selected"}}
        Just descriptor -> do
          let request = stateRequestSerial state + 1
              channel = stateChannel state
          put
            state
              { stateModel = model {modelScreen = HelpLoading, modelStatus = "loading workflow help"},
                stateRequestSerial = request,
                stateHelpRequest = Just request
              }
          liftIO . startWorker state HelpWork $ loadWorkflowHelp config (workflowName descriptor) >>= writeBChan channel . HelpReady request

atMay :: [a] -> Int -> Maybe a
atMay values index
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing
