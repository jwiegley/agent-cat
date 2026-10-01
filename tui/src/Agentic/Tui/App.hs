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
    FrontendEdit (..),
    FrontendManifest (..),
    FrontendServer,
    LineageOperation (..),
    OccurrenceId,
    OccurrenceSnapshot (..),
    RecoveryControl (..),
    RecoveryOption (..),
    RecoverySnapshot (..),
    Envelope (..),
    RunId (runIdText),
    RunOwnership (..),
    RunRecord (..),
    RunSnapshot (..),
    RunStatus (..),
    SteeringTiming (..),
    SnapshotError (snapshotErrorMessage),
    WorkflowDescriptor (..),
    WorkflowInputDescriptor (workflowInputName),
    initialRunSnapshot,
    mkRunId,
    readResultArtifactAt,
    stepRunSnapshot,
  )
import qualified Agentic.Manager.Client as Manager
import qualified Agentic.Tui.Approval as Approval
import qualified Agentic.Tui.Service as Service
import qualified Agentic.Tui.ServiceLane as Lane
import Agentic.Tui.Client
import Agentic.Tui.Model
import Agentic.Tui.Person
import Agentic.Tui.Presentation
import Agentic.Tui.Process
import Agentic.Tui.RunModel
import Agentic.Tui.Root
import Agentic.Tui.Save (Saved, saveExact, saveRefusalText)
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
    modifyTVar',
    newTBQueueIO,
    newTVarIO,
    readTBQueue,
    readTVar,
    swapTVar,
    writeTVar,
  )
import Crypto.Random (getRandomBytes)
import Control.Exception (AsyncException (UserInterrupt), SomeAsyncException, SomeException, bracket, displayException, finally, fromException, mask, mask_, onException, throwIO, try, uninterruptibleMask_)
import Control.Monad (forM_, forever, mfilter, unless, void, when)
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
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime, utctDayTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Graphics.Vty as Vty
import qualified Graphics.Vty.Output as VtyOutput
import Graphics.Vty.Platform.Unix (mkVty)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
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
    -- | One result of a service worker, stamped with the generation of the
    -- session that started the worker. Only a result of the active session
    -- is handled.
  | ServiceResult !(Lane.Stamped ServiceEvent)
    -- | The connection with this ticket to another client profile.
  | EndpointConnected !Int !(Lane.CallOutcome (Manager.Client, Service.Endpoint))
    -- | The event worker of the session recorded invalidations or a new
    -- delivery state in the live sink. At most one wakeup is pending.
  | ServiceWakeup

-- | The results of the service workers of one session.
data ServiceEvent
  = ServiceProfilesReady !Int !(Lane.CallOutcome [Service.Profile])
    -- | The workflow catalogue of a profile, and the request of that profile
    -- that opens after the catalogue loads, when the overview asked for it.
    -- | The current profile and its workflow catalogue, and the request of
    -- that profile that opens after the catalogue loads, when the overview
    -- or a lineage request asked for it.
  | ServiceWorkflowsReady !Int !(Maybe Manager.DraftView) !(Lane.CallOutcome (Service.Profile, [Service.Workflow]))
  | ServicePrepared !Int !(Lane.CallOutcome Manager.PendingCommand)
  | ServiceSent !Int !(Lane.CallOutcome Manager.ClientResponse)
  | ServiceRequestReady !Int !(Lane.CallOutcome (Service.RequestRead Manager.Observed))
    -- | The overview read with this ticket, what started it, the fetch
    -- generation in which it started, and the event cursor and members of
    -- the overview.
  | ServiceOverviewReady !Int !OverviewOrigin !Manager.FetchGeneration !(Lane.CallOutcome (Text, [Service.OverviewMember]))
    -- | The read of the pending decision heads with this ticket, whether
    -- the explicit g key started it, and the heads in manager observation
    -- order.
  | ServiceDecisionsReady !Int !Bool !(Lane.CallOutcome [Service.DecisionView])
    -- | The read of the run list of @/v1/runs@ with this ticket, whether the
    -- explicit g key started it, and the runs in identifier order.
  | ServiceHistoryReady !Int !Bool !(Lane.CallOutcome [Service.RunItem])
    -- | The read of the detail of this run with this ticket, and whether an
    -- explicit key started it.
  | ServiceHistoryDetailReady !Int !Bool !Text !(Lane.CallOutcome Service.HistoryDetail)
    -- | The retrieval of the verified result of this run.
  | ServiceResultReady !Int !Text !(Lane.CallOutcome (Maybe Service.VerifiedResult))
    -- | The read of the progress of the accepted export in the command lane.
  | ServiceExportReady !Int !(Lane.CallOutcome Service.ExportProgress)
    -- | The read of the first page of the lineage collection of this run of
    -- this profile, which opens the lineage menu.
  | ServiceLineageMenuReady !Int !Text !Text !(Lane.CallOutcome (Manager.Observed, Service.LineageCollection))
    -- | The read of the progress of the accepted lineage request in the
    -- command lane.
  | ServiceLineageReady !Int !(Lane.CallOutcome Service.LineageProgress)

-- | What started an overview read: the bootstrap of the session, which
-- shows the profiles afterwards, the explicit g key, or live delivery.
data OverviewOrigin = BootstrapOverview | ExplicitOverview | LiveOverview
  deriving (Eq, Show)

-- | Bounded frontend IO slots, each retaining at most one cancellable task.
-- 'ServiceEventsWork' holds the event worker of the service session.
data Work = InitialWork | PreviewWork | HelpWork | RunsWork | RoutingWork | MachineWork | PersonWork | ResultWork
  | ServiceReadWork | ServicePrepareWork | ServiceSendWork | ServiceConnectWork | ServiceEventsWork
  deriving (Eq, Ord)

-- | What the event worker of the service session passes to Brick: the
-- bounded set of invalidated resources, the delivery state, and whether a
-- wakeup is pending. The worker never writes the Brick channel while a
-- wakeup is pending, so a full channel never drops an invalidation.
data LiveSink = LiveSink
  { sinkInvalidated :: !(TVar Lane.Invalidated),
    sinkDelivery :: !(TVar Lane.Delivery),
    sinkWakeup :: !(TVar Bool)
  }

-- | Disjoint original local and manager-client owners.
-- | The local runner backend, or the service backend: the active client
-- session and the client profiles. The identity of the active profile is the
-- one that the shell shows and that decides the credential scopes.
data Backend = LocalBackend !TuiConfig !PrivateRoot | ServiceBackend !Manager.Client !Lane.Endpoints

-- Each attempted mutation retains the original immutable pending command.
type MutationState = Lane.MutationState Manager.PendingCommand Manager.Reference

type Attempt = Lane.Attempt Manager.PendingCommand Manager.Reference

type ServiceLane = Lane.Lane Manager.PendingCommand Manager.Reference

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
    -- | Whether the path editor of a file capture is open over the input
    -- editor, its path editor, and the refusal of its latest read.
    stateCaptureFile :: !Bool,
    stateCaptureEditor :: !(Edit.Editor Text Name),
    stateCaptureError :: !(Maybe Text),
    -- | The profile and run of the open export name editor, its name editor,
    -- and the refusal of its latest Ctrl-D.
    stateExportRun :: !(Maybe (Text, Text)),
    stateExportEditor :: !(Edit.Editor Text Name),
    stateExportError :: !(Maybe Text),
    -- | The open lineage menu and the editor of its replacement answer.
    stateLineageMenu :: !(Maybe (Service.LineageMenu Manager.Observed)),
    stateLineageEditor :: !(Edit.Editor Text Name),
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
    -- | The read ticket, the one command lane, the internal-fault flag and the
    -- resend confirmation. Only the pure transitions in "Agentic.Tui.ServiceLane"
    -- and the explicit key and event handlers below change them.
    stateServiceLane :: !ServiceLane,
    stateServiceProfiles :: ![Service.Profile],
    stateServiceWorkflows :: ![Service.Workflow],
    stateServiceWorkflow :: !(Maybe Service.Workflow),
    -- | The selected identity: a request, or a run opened by its
    -- identifier. The run of a request selection is the run that the
    -- installed observation names ('serviceSelection').
    stateServiceSelected :: !(Maybe Service.Selection),
    -- | The last complete composite read of the selected request and its
    -- stale mark. Only 'Lane.requestStep' installs a read or marks it stale.
    stateServiceObservation :: !(Lane.Installed (Service.RequestRead Manager.Observed)),
    -- | The last complete manager overview and its stale mark. Only
    -- 'Lane.requestStep' installs an overview or marks it stale.
    stateServiceOverview :: !(Lane.Installed [Service.OverviewMember]),
    -- | The selected row of the manager overview view, by the kind and
    -- identity of the row.
    stateServiceOverviewFocus :: !(Lane.RowFocus (Manager.OverviewKind, Text)),
    -- | The last complete pending decision heads of @/v1/decisions@ in
    -- manager observation order and their stale mark. Only
    -- 'Lane.requestStep' installs them or marks them stale.
    stateServiceDecisions :: !(Lane.Installed [Service.DecisionView]),
    -- | The selected row of the manager decisions view, by the kind and
    -- identity of the row.
    stateServiceDecisionsFocus :: !(Lane.RowFocus (Manager.OverviewKind, Text)),
    -- | The last complete run list of @/v1/runs@ in identifier order and its
    -- stale mark. Only 'Lane.requestStep' installs it or marks it stale.
    stateServiceHistory :: !(Lane.Installed [Service.RunItem]),
    -- | The selected row of the History view, by the kind and identity of
    -- the row.
    stateServiceHistoryFocus :: !(Lane.RowFocus (Manager.OverviewKind, Text)),
    -- | The last complete detail of the run that the run detail shows and
    -- its stale mark. Only 'Lane.requestStep' installs it or marks it stale.
    stateServiceHistoryDetail :: !(Lane.Installed Service.HistoryDetail),
    -- | The text drafts by identity: the input editor text of each request
    -- and input, and the answer text of each decision. The editors show the
    -- draft of the displayed identity ('serviceDraftKey').
    stateServiceDrafts :: !Lane.Drafts,
    -- | The capture receipts of this session by capture identifier. Only a
    -- captured input with one of these receipts agrees with an exact review.
    stateServiceCaptures :: !(Map.Map Text Manager.CaptureReceipt),
    -- | The live sink of the event worker of the session.
    stateServiceSink :: !LiveSink,
    -- | The delivery state that the latest wakeup read from the live sink.
    stateServiceDelivery :: !Lane.Delivery,
    -- | Whether the manager answers the reads of the session, as
    -- 'Lane.readReachability' decides it from each completed read.
    stateServiceReach :: !Lane.Reachability,
    -- | The fetches of live delivery that wait for the read lane, and the
    -- one that holds the read ticket.
    stateServiceFetches :: !Lane.Fetches,
    -- | The time of the latest timer read of the selected request that
    -- started a read.
    stateServiceSafetyAt :: !(Maybe UTCTime),
    -- | The retry of a refused overview read of live delivery or of a
    -- resnapshot.
    stateServiceOverviewRetry :: !(Maybe Lane.OverviewRetry),
    stateServiceApproval :: !(Maybe (Service.Mutation,Manager.PendingCommand,Maybe Manager.Reference)),
    stateServiceApprovalStatus :: !(Maybe Text),
    stateServiceLastReceipt :: !(Maybe Manager.CommandReceipt),
    -- | The run and the outcome of the latest cancel, steer or recovery
    -- choice that completed, as 'Service.controlOutcome' reads it from the
    -- receipt of the command.
    stateServiceControlOutcome :: !(Maybe (Text, Text)),
    -- | The run and the outcome of its latest export: a definite refusal of
    -- the send, or the published export receipt with its verified bytes.
    stateServiceExport :: !(Maybe (Text, Service.ExportOutcome)),
    -- | The parent run and the outcome of its latest lineage request: a
    -- definite refusal of the send, or the child request that it created.
    stateServiceLineage :: !(Maybe (Text, Service.LineageOutcome)),
    -- | The sequence number of the latest approval-key press on the review.
    -- It counts approval-key presses only, not every key event.
    stateServiceKeySerial :: !Int,
    -- | The sequence number of the press that started the latest approval.
    stateServiceApprovalPress :: !(Maybe Int),
    -- | The notice of the latest approval-key press. Only the approval-key
    -- handler sets it, and 'Approval.retainNotice' alone ends or replaces it.
    stateServiceNotice :: !(Maybe Approval.KeyNotice),
    -- | The outcome of the latest mutation key that started nothing, and the
    -- number of such presses in the session. 'serviceKeyOutcome' sets it,
    -- and 'Lane.retainKeyOutcome' alone ends or replaces it.
    stateServiceKeyOutcome :: !(Maybe Lane.KeyOutcome),
    stateServiceOutcomeSerial :: !Int,
    -- | The open confirmation of a withdrawal or a discard. Only its
    -- confirming key starts the mutation.
    stateServiceConfirm :: !(Maybe Lane.Confirmation),
    stateServiceUncertainExit :: !(IORef Bool),
    -- | The active client session, which the shutdown closes.
    stateServiceSession :: !(IORef (Maybe Manager.Client)),
    -- | Whether the Endpoints view is open over the service screen.
    stateEndpointsView :: !Bool,
    stateServiceFaultExit :: !(IORef Bool),
    -- | The retrievals of the verified results of the session by run
    -- identifier: the exact verified bytes, or a retryable failure, for each
    -- run. Only 'Lane.retrievalStep' and 'Lane.retrievalObserved' change
    -- them.
    stateServiceResults :: !(Lane.Retrievals Service.VerifiedResult),
    -- | The result line of the latest successful save of the verified bytes
    -- of the named run.
    stateServiceSaved :: !(Maybe (Text, Text))
  }

runApp :: TuiConfig -> PrivateRoot -> IO ()
runApp config root = runAppWith (LocalBackend config root)

runServiceApp :: Manager.Client -> Lane.Endpoints -> IO ()
runServiceApp client endpoints = runAppWith (ServiceBackend client endpoints)

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
  faultExit <- newIORef False
  session <- newIORef (case backend of ServiceBackend client _ -> Just client; LocalBackend {} -> Nothing)
  sink <- LiveSink <$> newTVarIO Lane.noInvalidations <*> newTVarIO Lane.DeliveryIdle <*> newTVarIO False
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
            stateCaptureFile = False,
            stateCaptureEditor = blankEditor,
            stateCaptureError = Nothing,
            stateExportRun = Nothing,
            stateExportEditor = blankEditor,
            stateExportError = Nothing,
            stateLineageMenu = Nothing,
            stateLineageEditor = blankEditor,
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
            stateServiceLane = Lane.sessionLane,
            stateServiceProfiles = [],
            stateServiceWorkflows = [],
            stateServiceWorkflow = Nothing,
            stateServiceSelected = Nothing,
            stateServiceObservation = Lane.noObservation,
            stateServiceOverview = Lane.noObservation,
            stateServiceOverviewFocus = Lane.noFocus,
            stateServiceDecisions = Lane.noObservation,
            stateServiceDecisionsFocus = Lane.noFocus,
            stateServiceHistory = Lane.noObservation,
            stateServiceHistoryFocus = Lane.noFocus,
            stateServiceHistoryDetail = Lane.noObservation,
            stateServiceDrafts = Lane.noDrafts,
            stateServiceCaptures = Map.empty,
            stateServiceSink = sink,
            stateServiceDelivery = Lane.DeliveryIdle,
            stateServiceReach = Lane.Reachable,
            stateServiceFetches = Lane.noFetches,
            stateServiceSafetyAt = Nothing,
            stateServiceOverviewRetry = Nothing,
            stateServiceApproval = Nothing,
            stateServiceApprovalStatus = Nothing,
            stateServiceLastReceipt = Nothing,
            stateServiceControlOutcome = Nothing,
            stateServiceExport = Nothing,
            stateServiceLineage = Nothing,
            stateServiceKeySerial = 0,
            stateServiceApprovalPress = Nothing,
            stateServiceNotice = Nothing,
            stateServiceKeyOutcome = Nothing,
            stateServiceOutcomeSerial = 0,
            stateServiceConfirm = Nothing,
            stateServiceUncertainExit = uncertainExit,
            stateServiceSession = session,
            stateEndpointsView = False,
            stateServiceFaultExit = faultExit,
            stateServiceResults = Lane.noRetrievals,
            stateServiceSaved = Nothing
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
            ServiceBackend {} -> mask_ $
              ((readIORef session >>= mapM_ Manager.closeClient) `finally`
                (readMVar workers >>= stopAll . (ticker :) . Map.elems)) `finally` do
                  unresolved <- readIORef uncertainExit
                  faulted <- readIORef faultExit
                  mapM_ (hPutStrLn stderr . T.unpack) (Lane.shutdownNotices unresolved faulted)
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
-- No read starts while another holds the ticket. The status line names what
-- the started read reads.
startServiceRead :: Lane.ReadKind -> Text -> (Int -> IO ServiceEvent) -> EventM Name AppState ()
startServiceRead kind status = startServiceReadShown kind (Just status)

-- | 'startServiceRead', given the status line of the read, or 'Nothing' for
-- a read of live delivery, which keeps the status line.
startServiceReadShown :: Lane.ReadKind -> Maybe Text -> (Int -> IO ServiceEvent) -> EventM Name AppState ()
startServiceReadShown kind status action = do
  state <- get
  let ticket = stateRequestSerial state + 1
  case Lane.startRead ticket kind (stateServiceLane state) of
    Nothing -> pure ()
    Just lane -> do
      put state {stateServiceLane = lane, stateRequestSerial = ticket,
        stateModel = (stateModel state) {modelStatus = fromMaybe (modelStatus (stateModel state)) status}}
      liftIO . startServiceWorker state ServiceReadWork $ action ticket

startServiceProfiles :: Manager.Client -> EventM Name AppState ()
startServiceProfiles client = startServiceRead Lane.PageSetRead "loading manager catalogue" $ \ticket ->
  ServiceProfilesReady ticket <$> Lane.serviceCall (Service.loadProfiles client)

-- | Read the authorized manager overview through the single-flight lane,
-- given what starts the read. A read of live delivery keeps the status line.
startServiceOverview :: Manager.Client -> OverviewOrigin -> EventM Name AppState ()
startServiceOverview client origin = do
  generation <- Manager.refreshGeneration . serviceRefresh <$> get
  startServiceReadShown Lane.PageSetRead (if origin == LiveOverview then Nothing else Just "reading the manager overview") $ \ticket ->
    ServiceOverviewReady ticket origin generation <$> Lane.serviceCall
      ((>>= \overview -> (,) (Manager.overviewCursor overview) <$> traverse Service.decodeOverviewItem (Manager.overviewItems overview))
        <$> Manager.loadOverview client)

-- | Read the pending decision heads of @/v1/decisions@ through the
-- single-flight lane, given whether the explicit g key starts the read. A
-- read of live delivery keeps the status line.
startServiceDecisions :: Manager.Client -> Bool -> EventM Name AppState ()
startServiceDecisions client explicit =
  startServiceReadShown Lane.PageSetRead (if explicit then Just "reading the manager decisions" else Nothing) $ \ticket ->
    ServiceDecisionsReady ticket explicit <$> Lane.serviceCall (Service.loadDecisions client)

-- | Read the run list of @/v1/runs@ through the single-flight lane, every
-- window of it, given whether the explicit g key starts the read. A read of
-- live delivery keeps the status line.
startServiceHistory :: Manager.Client -> Bool -> EventM Name AppState ()
startServiceHistory client explicit =
  startServiceReadShown Lane.PageSetRead (if explicit then Just "reading the manager history" else Nothing) $ \ticket ->
    ServiceHistoryReady ticket explicit <$> Lane.serviceCall (Service.loadHistory client)

-- | Read the detail of this run of the installed run list through the
-- single-flight lane ('Service.observeHistoryDetail'), given whether an
-- explicit key starts the read. A read of live delivery keeps the status
-- line. A run that the installed run list does not name is not read.
startServiceHistoryDetail :: Manager.Client -> Bool -> Text -> EventM Name AppState ()
startServiceHistoryDetail client explicit run = do
  state <- get
  case find ((== run) . Service.runItemId) (fromMaybe [] (Lane.installedRead (stateServiceHistory state))) of
    Nothing -> put state {stateModel = (stateModel state) {modelStatus = "run detail not read: the installed history does not list run " <> run}}
    Just item ->
      startServiceReadShown (if Service.historyLegacy item then Lane.SingleResourceRead else Lane.PageSetRead)
        (if explicit then Just "reading the run detail" else Nothing) $ \ticket ->
          ServiceHistoryDetailReady ticket explicit run <$> Lane.serviceCall (Service.observeHistoryDetail client item)

-- | Start the event worker of the session from the cursor of an installed
-- overview that started in the given fetch generation, when
-- 'Lane.overviewStartsStream' allows it: no stream runs, or a 410 refusal
-- ended the stream, and the overview is of the current generation.
startServiceEvents :: Manager.Client -> Manager.FetchGeneration -> Text -> EventM Name AppState ()
startServiceEvents client generation cursor = do
  state <- get
  when (Lane.overviewStartsStream generation (Manager.refreshGeneration (serviceRefresh state)) (stateServiceDelivery state)) $ do
    let sink = stateServiceSink state
    liftIO (atomically (writeTVar (sinkDelivery sink) Lane.DeliveryConnecting))
    put state {stateServiceDelivery = Lane.DeliveryConnecting}
    liftIO . startWorker state ServiceEventsWork $ serviceEventWorker (stateChannel state) sink client cursor

-- | The event worker of one session. It follows @/events@ from the cursor
-- with 'Manager.streamEvents' and records each invalidated resource and the
-- delivery state in the live sink, with one pending wakeup. The pure rules
-- of 'Lane.afterStream' and 'Lane.afterPoll' decide each next step. After
-- the manager ends the stream or a failure, the worker reconnects with the
-- identifier of the last complete event after the jittered backoff. After
-- 'Lane.streamFailureLimit' consecutive failures or a refusal of the
-- stream, for example 429 when the credential has no free SSE reader, it
-- polls with 'Manager.pollEventBatch' every second from that identifier and
-- connects the stream again when the jittered backoff has passed. A 410
-- refusal of the stream or of a poll ends the worker with
-- 'Lane.DeliveryResnapshot', and the frontend reads a new overview whose
-- cursor starts the next worker. A closed client ends the worker. An
-- internal fault stops delivery, and the timer refresh continues at every
-- tick.
serviceEventWorker :: BChan AppEvent -> LiveSink -> Manager.Client -> Text -> IO ()
serviceEventWorker channel sink client = stream . Lane.newFollow
  where
    wake = notifyOnce channel (sinkWakeup sink) ServiceWakeup
    -- Apply one pure delivery transition and wake the frontend when the
    -- state changed.
    transition change = do
      (result, changed) <- atomically $ do
        current <- readTVar (sinkDelivery sink)
        let (result, next) = change current
        writeTVar (sinkDelivery sink) next
        pure (result, current /= next)
      when changed wake
      pure result
    noteEvents events = atomically $ forM_ events $ \event ->
      modifyTVar' (sinkInvalidated sink) (Lane.noteInvalidation (Manager.invalidationResource (Manager.invalidationEventData event)))
    stream follow = do
      latest <- newIORef (Lane.followCursor follow)
      delivered <- newIORef False
      outcome <- Lane.serviceCall . Manager.streamEvents client (Lane.followCursor follow) $ \item -> do
        writeIORef delivered True
        case item of
          Manager.StreamHeartbeat -> transition (const ((), Lane.DeliveryLive))
          Manager.StreamInvalidation event -> do
            writeIORef latest (Manager.invalidationEventId event)
            noteEvents [event]
            atomically (writeTVar (sinkDelivery sink) Lane.DeliveryLive)
            wake
      worked <- readIORef delivered
      resume <- readIORef latest
      case outcome of
        Lane.InternalFault -> transition (const ((), Lane.DeliveryStopped "internal frontend fault"))
        Lane.Declared result -> do
          now <- getCurrentTime
          let end = Lane.StreamEnd worked (either (const resume) id result) (either Just (const Nothing) result)
          (follow', step) <- transition $ \delivery ->
            let (next, shown, chosen) = Lane.afterStream now end delivery follow in ((next, chosen), shown)
          case step of
            Lane.FollowClosed -> pure ()
            Lane.FollowResnapshot -> pure ()
            Lane.FollowStream seconds -> pause seconds >> stream follow'
            Lane.FollowPoll seconds -> do
              wait <- jittered seconds
              poll follow' (addUTCTime (fromIntegral wait / 1000000) now)
    -- Poll from the cursor until the stream is due again at the given time.
    poll follow due = do
      outcome <- Lane.serviceCall (Manager.pollEventBatch client (Lane.followCursor follow))
      case outcome of
        Lane.InternalFault -> transition (const ((), Lane.DeliveryStopped "internal frontend fault"))
        Lane.Declared result -> do
          -- The invalidations of a batch wake the frontend even when the
          -- delivery state stays the same.
          forM_ result $ \batch -> unless (null (Manager.batchEvents batch)) (noteEvents (Manager.batchEvents batch) >> wake)
          now <- getCurrentTime
          (follow', step) <- transition $ \delivery ->
            let batch = fmap (\value -> (Manager.batchCursor value, Manager.batchHasMore value)) result
                (next, shown, chosen) = Lane.afterPoll now batch delivery follow
             in ((next, chosen), shown)
          case step of
            Lane.PollClosed -> pure ()
            Lane.PollResnapshot -> pure ()
            Lane.PollNow -> poll follow' due
            Lane.PollLater -> do
              threadDelay (Lane.pollIntervalSeconds * 1000000)
              later <- getCurrentTime
              if later >= due then stream follow' else poll follow' due
    pause seconds = jittered seconds >>= threadDelay
    jittered seconds = do
      bytes <- getRandomBytes 2 :: IO BS.ByteString
      let fraction = fromIntegral (foldl (\total byte -> 256 * total + fromIntegral byte) (0 :: Int) (BS.unpack bytes)) / 65535
      pure (Manager.jitteredMicroseconds seconds fraction)

-- | The rows of the installed manager overview.
serviceOverviewRows :: AppState -> [Service.OverviewRow]
serviceOverviewRows = maybe [] Service.overviewRows . Lane.installedRead . stateServiceOverview

-- | The rows of the installed pending decision heads, in manager
-- observation order.
serviceDecisionRows :: AppState -> [Service.OverviewRow]
serviceDecisionRows = maybe [] Service.decisionRows . Lane.installedRead . stateServiceDecisions

-- | The rows of the installed run list, in identifier order.
serviceHistoryRows :: AppState -> [Service.OverviewRow]
serviceHistoryRows = maybe [] Service.historyRows . Lane.installedRead . stateServiceHistory

-- | Load the workflow catalogue of a profile, and then open the given
-- request when one is given.
-- | Read the current profile and its workflow catalogue
-- ('Service.loadProfileWorkflows'), so a profile revision that a manager
-- restart published binds the catalogue.
startServiceWorkflows :: Manager.Client -> Service.Profile -> Maybe Manager.DraftView -> EventM Name AppState ()
startServiceWorkflows client profile opening = startServiceRead Lane.PageSetRead "loading manager catalogue" $ \ticket ->
  ServiceWorkflowsReady ticket opening <$> Lane.serviceCall (Service.loadProfileWorkflows client (Service.profileId profile))

-- | Open the selected row of the manager overview with
-- 'Service.overviewOpen'. Only an idle command lane opens a row, so a
-- command in progress keeps the selection whose reads confirm it.
openOverviewRow :: Manager.Client -> EventM Name AppState ()
openOverviewRow client = do
  state <- get
  let rows = serviceOverviewRows state
      keys = map Service.overviewRowKey rows
      members = fromMaybe [] (Lane.installedRead (stateServiceOverview state))
      refused :: Text -> EventM Name AppState ()
      refused reason = put state {stateModel = (stateModel state) {modelStatus = "overview row not opened: " <> reason}}
  case atMay keys (Lane.focusedIndex keys (stateServiceOverviewFocus state)) of
    _ | not (serviceIdle state) -> refused "a manager command is in progress"
    Nothing -> refused "no overview row is selected"
    Just key -> case Service.overviewOpen members key of
      Service.OpenNothing reason -> refused reason
      Service.OpenRun run profile -> openServiceRun OverviewList run profile
      Service.OpenRequest request -> case find (`Service.requestMatches` request) (stateServiceWorkflows state) of
        Just workflow -> openServiceRequest workflow request
        Nothing -> case find ((== Manager.draftProfile request) . Service.profileId) (stateServiceProfiles state) of
          Just profile -> startServiceWorkflows client profile (Just request)
          Nothing -> refused "the manager catalogue lists no profile of this request"

-- | Open the run of the selected decision head of the manager decisions
-- with 'Service.decisionsOpen'. Only an idle command lane opens a row, as on
-- the overview. Esc on the live monitor of the run returns to the manager
-- decisions.
openDecisionRow :: EventM Name AppState ()
openDecisionRow = do
  state <- get
  let keys = map Service.overviewRowKey (serviceDecisionRows state)
      heads = fromMaybe [] (Lane.installedRead (stateServiceDecisions state))
      refused :: Text -> EventM Name AppState ()
      refused reason = put state {stateModel = (stateModel state) {modelStatus = "decision row not opened: " <> reason}}
  case atMay keys (Lane.focusedIndex keys (stateServiceDecisionsFocus state)) of
    _ | not (serviceIdle state) -> refused "a manager command is in progress"
    Nothing -> refused "no decision row is selected"
    Just key -> case Service.decisionsOpen heads key of
      Service.OpenRun run profile -> openServiceRun DecisionsList run profile
      Service.OpenRequest _ -> refused "a decision row opens only its run"
      Service.OpenNothing reason -> refused reason

-- | Open the read-only detail of the selected run of the History view. The
-- detail of the run that the run detail already shows keeps its
-- observation, and any other run starts with no observation. The detail is
-- read at once. Nothing is selected and nothing is sent, so the selection,
-- its reads and a command in progress stay.
openHistoryRow :: EventM Name AppState ()
openHistoryRow = do
  state <- get
  let keys = map Service.overviewRowKey (serviceHistoryRows state)
  case atMay keys (Lane.focusedIndex keys (stateServiceHistoryFocus state)) of
    Nothing -> put state {stateModel = (stateModel state) {modelStatus = "history row not opened: no run row is selected"}}
    Just (_, run) -> do
      let same = fmap Service.historyDetailRun (Lane.installedRead (stateServiceHistoryDetail state)) == Just run
      put state {stateServiceHistoryDetail = if same then stateServiceHistoryDetail state else Lane.noObservation,
        stateModel = (stateModel state) {modelScreen = ServiceHistoryRunScreen run, modelStatus = "manager run detail opened"}}
      vScrollToBeginning (viewportScroll FailureViewport)
      invalidateServiceFetches [Lane.HistoryFetch]

-- | Retrieve the verified result of the run that the run detail shows, for
-- the r key. Only an installed detail of a succeeded managed run with a
-- verified or referenced result starts 'Service.retrieveResult', and only
-- when 'Lane.retrievalDue' allows an explicit retrieval: retained bytes are
-- not retrieved again, and a failed retrieval is retried at once. Every r
-- has one visible outcome on the status line.
retrieveHistoryResult :: Manager.Client -> Text -> EventM Name AppState ()
retrieveHistoryResult client run = do
  state <- get
  let status :: Text -> EventM Name AppState ()
      status text = put state {stateModel = (stateModel state) {modelStatus = text}}
  case Lane.installedRead (stateServiceHistoryDetail state) of
    Just detail | Service.historyDetailRun detail == run -> case Service.historyRetrievable detail of
      Left reason -> status ("result not retrieved: " <> reason)
      Right observation
        | not (Lane.retrievalDue Lane.ExplicitRefresh run (stateServiceResults state)) ->
            status "verified result already retained; s saves it"
        | isJust (Lane.laneReadTicket (stateServiceLane state)) ->
            status "result retrieval not started: another manager read is in flight; press r again"
        | otherwise -> startServiceRead Lane.PageSetRead "retrieving the verified result" $ \ticket ->
            ServiceResultReady ticket run <$> Lane.serviceCall (Service.retrieveResult client observation)
    _ -> status "result not retrieved: the run detail is not observed"

-- | Select this request of this catalogue row and show it by its phase. The
-- request screen shows at once, and the next installed read shows the
-- review or the live monitor of its run. A newly selected request starts
-- with no observation. The drafts stay.
openServiceRequest :: Service.Workflow -> Manager.DraftView -> EventM Name AppState ()
openServiceRequest workflow request = do
  state <- get
  let same = stateServiceSelected state == Just (Service.RequestSelection (Manager.draftId request) Nothing)
      shown = if same then maybe request snd (serviceRequest state) else request
  put (if same then state else newServiceSelection state) {stateServiceSelected = Just (Service.RequestSelection (Manager.draftId request) Nothing),
    stateServiceWorkflow = Just workflow,
    stateModel = (stateModel state) {modelWorkflow = Just (Service.workflowDisplay workflow), modelInputs = Service.literalInputs shown,
      modelScreen = ServiceRequestScreen shown, modelServiceList = OverviewList, modelStatus = "manager request opened: " <> Manager.draftPhase shown}}
  invalidateServiceFetches [Lane.RequestFetch]

-- | Select this run by its identifier and show its live monitor, opened
-- from this service view. The run that the installed observation already
-- shows keeps its observation and its monitor position. Any other run starts
-- with no observation.
openServiceRun :: ServiceList -> Text -> Text -> EventM Name AppState ()
openServiceRun list run profile = do
  state <- get
  case mkRunId run of
    Left _ -> put state {stateModel = (stateModel state) {modelStatus = "overview row not opened: the run identifier is not valid"}}
    Right ident -> do
      let same = fmap (runIdText . Service.runIdentity) (serviceRun state) == Just run
          selected = if same then state else (newServiceSelection state) {stateServiceSelected = Just (Service.RunSelection run profile)}
      put selected {stateModel = (stateModel state) {modelScreen = LiveScreen ident, modelServiceList = list,
        modelSnapshot = if same then serviceRun state >>= Service.runSnapshot else Nothing, modelStatus = "manager run opened"}}
      invalidateServiceFetches [Lane.RequestFetch]

-- | The state before a new selection: no observation, approval notice or
-- monitor position of the earlier selection. The drafts, the overview and
-- the retained results stay.
newServiceSelection :: AppState -> AppState
newServiceSelection state = state {stateServiceObservation = Lane.noObservation, stateServiceWorkflow = Nothing,
  stateRunView = emptyRunView, stateOutputFollow = True, stateRunDetails = False, stateConfirmDetails = False,
  statePaneFocus = PrimaryPane}

-- | Esc on the live monitor or the request screen ('serviceLeave'): the
-- manager overview. The selection and its observation stay, so the reads
-- that confirm a command in progress continue, and nothing is sent.
leaveServiceSelection :: EventM Name AppState ()
leaveServiceSelection = modify $ \state -> case serviceLeave (stateModel state) of
  Just model -> state {stateModel = model, statePaneFocus = PrimaryPane, stateSteerTiming = Nothing}
  Nothing -> state

serviceMutation :: AppState -> MutationState
serviceMutation = Lane.laneMutation . stateServiceLane

-- | The installed request observation.
serviceRequest :: AppState -> Maybe (Manager.Observed,Manager.DraftView)
serviceRequest state = Lane.installedRead (stateServiceObservation state) >>= Service.readRequest

-- | The installed run observation.
serviceRun :: AppState -> Maybe Service.RunObservation
serviceRun state = Service.runReadSnapshot <$> (Lane.installedRead (stateServiceObservation state) >>= Service.readRun)

-- | The run components of the installed composite read.
serviceRunRead :: AppState -> Maybe (Service.RunRead Manager.Observed)
serviceRunRead state = Lane.installedRead (stateServiceObservation state) >>= Service.readRun

-- | The decision head that the manager presents in the installed composite
-- read, while the live monitor shows its run. Only 'Service.decisionHead'
-- derives it, from the installed observation alone. No local decision state
-- or running machine takes part.
serviceHead :: AppState -> Maybe Service.DecisionHead
serviceHead state = case (stateBackend state, modelScreen (stateModel state)) of
  (ServiceBackend {}, LiveScreen _) -> serviceRunRead state >>= Service.decisionHead
  _ -> Nothing

-- | The retained verified result bytes of the run that the screen shows:
-- the run of the run detail, or else the installed run.
serviceVerifiedResult :: AppState -> Maybe (Text, Service.VerifiedResult)
serviceVerifiedResult state = do
  run <- case modelScreen (stateModel state) of
    ServiceHistoryRunScreen shown -> Just shown
    _ -> runIdText . Service.runIdentity <$> serviceRun state
  (,) run <$> Lane.retrievedResult run (stateServiceResults state)

-- | The export line of this run: the outcome of its latest export.
-- | The outcome lines of the read-only detail of a run: its saved result,
-- its export and its lineage operation, in the order that the detail shows
-- them after the run lines.
historyOutcomeLines :: AppState -> Text -> [Text]
historyOutcomeLines state run =
  [line | Just (ident, line) <- [stateServiceSaved state], ident == run] <> serviceExportLines state run <> serviceLineageLines state run

serviceExportLines :: AppState -> Text -> [Text]
serviceExportLines state run = [line | Just (ident, outcome) <- [stateServiceExport state], ident == run, line <- Service.exportLines outcome]

-- | The lineage line of this run: the outcome of its latest lineage request.
serviceLineageLines :: AppState -> Text -> [Text]
serviceLineageLines state run = [line | Just (ident, outcome) <- [stateServiceLineage state], ident == run, line <- Service.lineageLines outcome]

-- | Whether s opens the save dialog: the live monitor shows no decision head
-- and no run details, or the run detail shows its run, and the verified
-- result bytes of that run are retained.
serviceSavable :: AppState -> Bool
serviceSavable state = case modelScreen (stateModel state) of
  LiveScreen _ -> not (stateRunDetails state) && serviceHead state == Nothing && isJust (serviceVerifiedResult state)
  ServiceHistoryRunScreen _ -> isJust (serviceVerifiedResult state)
  _ -> False

-- | Whether the command lane holds an answer to this decision. A retained
-- answer stays bound to its original decision when the head changes.
serviceAnswerPending :: AppState -> Service.DecisionView -> Bool
serviceAnswerPending state view = serviceAnswerHeld state (Service.decisionId view)

-- | Whether the command lane holds an answer to the decision with this
-- identifier.
serviceAnswerHeld :: AppState -> Text -> Bool
serviceAnswerHeld state ident = case serviceMutation state of
  Lane.MutationPreparing _ mutation -> answers mutation
  Lane.MutationSending _ attempt -> answers (Lane.attemptMutation attempt)
  Lane.MutationAwaiting mutation _ _ -> answers mutation
  Lane.MutationUncertain attempt _ -> answers (Lane.attemptMutation attempt)
  Lane.MutationIdle -> False
  where
    answers mutation = case mutation of
      Service.Answer decision _ -> Service.decisionId decision == ident
      _ -> False

-- | The run whose live monitor the service frontend shows.
serviceShownRun :: AppState -> Maybe Text
serviceShownRun state = case (stateBackend state, modelScreen (stateModel state)) of
  (ServiceBackend {}, LiveScreen run) -> Just (runIdText run)
  _ -> Nothing

-- | Keep the answer draft of the earlier question head when the head of the
-- shown run changed before this session sent an answer to it
-- ('Lane.keepDraft'). The line @Control:@ of the run then states
-- 'Lane.draftKeptText', unless it already states it after a 412 refusal.
-- Nothing is sent.
keepServiceDraft :: Maybe Lane.DraftKey -> AppState -> AppState
keepServiceDraft before state = case before of
  Just earlier@(Lane.AnswerDraft run decision)
    | serviceShownRun state == Just run, not (serviceAnswerHeld state decision),
      Just drafts <- Lane.keepDraft earlier (serviceDraftKey state) (stateServiceDrafts state) ->
        let stated = case stateServiceControlOutcome state of
              Just (ident, label) -> ident == run && Lane.draftKeptText `T.isSuffixOf` label
              Nothing -> False
         in state {stateServiceDrafts = drafts,
              stateServiceControlOutcome = if stated then stateServiceControlOutcome state else Just (run, Lane.draftKeptText),
              stateModel = (stateModel state) {modelStatus = Lane.draftKeptText}}
  _ -> state

-- | The installed preparation observation.
servicePreparation :: AppState -> Maybe (Manager.Observed,Manager.Preparation)
servicePreparation state = Lane.installedRead (stateServiceObservation state) >>= Service.readPreparation

-- | The selection: the selected request with the run that its installed
-- observation names, or the selected run.
serviceSelection :: AppState -> Maybe Service.Selection
serviceSelection state = case stateServiceSelected state of
  Just (Service.RequestSelection ident _) -> Just (Service.RequestSelection ident (serviceRequest state >>= Manager.draftRun . snd))
  other -> other

-- | The profile of the selection: the profile of the installed request, or
-- the profile that the overview row of a selected run names.
serviceProfile :: AppState -> Maybe Text
serviceProfile state = case stateServiceSelected state of
  Just (Service.RunSelection _ profile) -> Just profile
  _ -> Manager.draftProfile . snd <$> serviceRequest state

-- | The identity of the draft that an editor displays: the input of the
-- selected request on the input screen, or the question at the head of the
-- displayed run.
serviceDraftKey :: AppState -> Maybe Lane.DraftKey
serviceDraftKey state = case (modelScreen (stateModel state), serviceHead state) of
  (_, Just (Service.QuestionHead view _)) -> Just (Lane.AnswerDraft (Service.decisionRun view) (Service.decisionId view))
  (InputScreen index, _) | Just (Service.RequestSelection request _) <- stateServiceSelected state,
    Just input <- modelWorkflow (stateModel state) >>= (`atMay` index) . workflowInputs ->
      Just (Lane.InputDraft request (workflowInputName input))
  _ -> Nothing

-- | Keep the text of the displayed editor as the draft of its identity.
recordServiceDraft :: EventM Name AppState ()
recordServiceDraft = modify $ \state -> case serviceDraftKey state of
  Just key@(Lane.AnswerDraft {}) -> state {stateServiceDrafts = Lane.recordDraft key (editorContents (statePersonEditor state)) (stateServiceDrafts state)}
  Just key@(Lane.InputDraft {}) -> state {stateServiceDrafts = Lane.recordDraft key (editorContents (stateEditor state)) (stateServiceDrafts state)}
  Nothing -> state

-- | Show the draft of the displayed identity after the identity changed
-- from the given one with 'Lane.showDraft'. An answer without a draft shows
-- an empty editor, so the text of an earlier head never stays. An input
-- without a draft shows its accepted literal.
showServiceDraft :: Maybe Lane.DraftKey -> AppState -> AppState
showServiceDraft before state = case Lane.showDraft before after (stateServiceDrafts state) of
  (_, Nothing) -> state
  (drafts, Just text) ->
    let shown = state {stateServiceDrafts = drafts}
     in case after of
          Just (Lane.AnswerDraft {}) -> shown {statePersonEditor = Edit.editorText InputEditor Nothing (fromMaybe "" text)}
          Just (Lane.InputDraft {}) -> shown {stateEditor = Edit.editorText InputEditor Nothing (fromMaybe (inputValue (stateModel state)) text)}
          Nothing -> shown
  where after = serviceDraftKey state

editorContents :: Edit.Editor Text Name -> Text
editorContents = T.intercalate "\n" . Edit.getEditContents

serviceResendConfirm :: AppState -> Bool
serviceResendConfirm = Lane.laneResendConfirm . stateServiceLane

serviceFaulted :: AppState -> Bool
serviceFaulted = Lane.laneFault . stateServiceLane

-- | Whether the manager or the client refused the credential of the session.
serviceCredentialRefused :: AppState -> Bool
serviceCredentialRefused = isJust . Lane.laneCredentialRefused . stateServiceLane

-- | Change only the lane facts of the state.
onLane :: (ServiceLane -> ServiceLane) -> AppState -> AppState
onLane change state = state {stateServiceLane = change (stateServiceLane state)}

-- | Return the command lane to idle.
idleService :: AppState -> AppState
idleService = onLane (\lane -> lane {Lane.laneMutation = Lane.MutationIdle})

serviceIdle :: AppState -> Bool
serviceIdle state = case serviceMutation state of Lane.MutationIdle -> True; _ -> False

-- | Whether a new mutation may start. No mutation starts after an internal fault.
serviceMutable :: AppState -> Bool
serviceMutable = Lane.mutationAllowed . stateServiceLane

serviceSending :: AppState -> Bool
serviceSending state = case serviceMutation state of
  Lane.MutationPreparing {} -> True
  Lane.MutationSending {} -> True
  _ -> False

-- | Install the faulted lane that a pure lane transition produced and show the
-- fixed fault notice. Only the lane and the displayed text change, so installed
-- observations, approvals and receipts stay as they are.
faultService :: AppState -> ServiceLane -> EventM Name AppState ()
faultService state lane = do
  liftIO (writeIORef (stateServiceFaultExit state) True)
  put state {stateServiceLane = lane,
    stateModel = (stateModel state) {modelScreen = ServiceCommandScreen (Lane.faultScreen lane),
      modelStatus = Lane.internalFaultStatus}}

-- | The mutation and receipt location of the retained command whose
-- receipt the composite read reads.
servicePendingReceipt :: AppState -> Maybe (Service.Mutation, Manager.Reference)
servicePendingReceipt state = case serviceMutation state of
  Lane.MutationAwaiting mutation _ location -> Just (mutation,location)
  Lane.MutationUncertain (Lane.Attempt mutation _ (Just location)) _ -> Just (mutation,location)
  _ -> case stateServiceApproval state of Just (mutation,_,Just location) -> Just (mutation,location); _ -> Nothing

-- | The resources that the composite read of the selected request reads.
serviceCompositeResources :: AppState -> [Text]
serviceCompositeResources state = case serviceSelection state of
  Just selection -> Service.compositeResources selection (Lane.installedRead (stateServiceObservation state))
    (Manager.referenceURI . snd <$> servicePendingReceipt state)
  Nothing -> [Manager.referenceURI location | Just (_, location) <- [servicePendingReceipt state]]

-- | Apply invalidations of these reads to the refresh coordinator of the
-- session and to the waiting fetches.
invalidateServiceFetches :: [Lane.FetchKey] -> EventM Name AppState ()
invalidateServiceFetches keys = modify $ \state ->
  onEndpointsRefresh (\refresh -> Lane.invalidateFetches keys refresh (stateServiceFetches state)) state

-- | Change the refresh coordinator of the session and the fetches of live
-- delivery together.
onEndpointsRefresh :: (Manager.Refresh Lane.FetchKey -> (Manager.Refresh Lane.FetchKey, Lane.Fetches)) -> AppState -> AppState
onEndpointsRefresh change state = case stateBackend state of
  ServiceBackend client endpoints ->
    let (refresh, fetches) = change (Lane.endpointsRefresh endpoints)
     in state {stateBackend = ServiceBackend client endpoints {Lane.endpointsRefresh = refresh}, stateServiceFetches = fetches}
  LocalBackend {} -> state

-- | Take the invalidations and the delivery state from the live sink and
-- clear the pending wakeup. A 410 refusal of the stream is a resnapshot
-- ('Lane.resnapshotFetches'): the coordinator advances its generation, so
-- a fetch in flight installs nothing, and every read is fetched again. The
-- next installed overview starts the stream again. A credential refusal of
-- the stream records the refusal in the lane ('Lane.refuseCredential').
handleServiceWakeup :: EventM Name AppState ()
handleServiceWakeup = do
  state <- get
  let sink = stateServiceSink state
  (invalidated, delivery) <- liftIO . atomically $ do
    writeTVar (sinkWakeup sink) False
    (,) <$> swapTVar (sinkInvalidated sink) Lane.noInvalidations <*> readTVar (sinkDelivery sink)
  let resnapshot = delivery == Lane.DeliveryResnapshot && stateServiceDelivery state /= Lane.DeliveryResnapshot
      refused = delivery == Lane.DeliveryRefused && stateServiceDelivery state /= Lane.DeliveryRefused
  put ((if refused then onLane (Lane.refuseCredential (stateRequestSerial state)) else id) state) {stateServiceDelivery = delivery}
  if resnapshot
    then modify (onEndpointsRefresh (\refresh -> Lane.resnapshotFetches refresh (stateServiceFetches state)))
    else invalidateServiceFetches (Lane.invalidatedFetches (serviceCompositeResources state) invalidated)

-- | Start the next waiting fetch of live delivery when the read lane is
-- free. A fetch whose read lost the read ticket without a completion waits
-- again. Fetches follow the rule of automatic refresh: none starts during a
-- preparation or a send, after an internal fault, while the credential is
-- refused, or while a deferred key pauses refresh. The overview is fetched
-- while its view is shown, or for the cursor of a resnapshot. A fetch of the
-- composite read without a selected request reads nothing and completes at
-- once.
pumpServiceFetches :: Manager.Client -> EventM Name AppState ()
pumpServiceFetches client = do
  state <- get
  case stateBackend state of
    LocalBackend {} -> pure ()
    ServiceBackend {} -> do
      let lane = stateServiceLane state
          fetches = Lane.fetchAbandoned lane (stateServiceFetches state)
          allowed = not (serviceFaulted state || serviceCredentialRefused state || serviceSending state
            || Lane.refreshPaused (stateNow state) lane (stateServiceKeyOutcome state))
          startable key = allowed && case key of
            Lane.OverviewFetch -> modelScreen (stateModel state) == ServiceOverviewScreen || stateServiceDelivery state == Lane.DeliveryResnapshot
            Lane.RequestFetch -> True
            Lane.DecisionsFetch -> modelScreen (stateModel state) == ServiceDecisionsScreen
            Lane.HistoryFetch -> case modelScreen (stateModel state) of
              ServiceHistoryScreen -> True
              ServiceHistoryRunScreen _ -> True
              _ -> False
      case Lane.takeFetch startable lane fetches of
        Nothing -> put state {stateServiceFetches = fetches}
        Just (fetch, rest) -> do
          put state {stateServiceFetches = rest}
          case fst fetch of
            Lane.OverviewFetch -> startServiceOverview client LiveOverview
            Lane.RequestFetch -> refreshServiceRequest client Lane.AutomaticRefresh
            Lane.DecisionsFetch -> startServiceDecisions client False
            Lane.HistoryFetch -> case modelScreen (stateModel state) of
              ServiceHistoryRunScreen run -> startServiceHistoryDetail client False run
              _ -> startServiceHistory client False
          after <- get
          case Lane.laneReadTicket (stateServiceLane after) of
            Just ticket -> put after {stateServiceFetches = Lane.fetchStarted (Lane.ticketNumber ticket) fetch rest}
            Nothing -> do
              put (onEndpointsRefresh (\refresh -> Lane.fetchSkipped fetch refresh rest) after)
              pumpServiceFetches client

-- | Refresh the observation of the selection for this cause.
refreshServiceRequest :: Manager.Client -> Lane.RefreshCause -> EventM Name AppState ()
refreshServiceRequest client cause = do
  state <- get
  let pending = servicePendingReceipt state
      -- Receipt visibility and request visibility are independently authorized.
      -- A declared receipt failure stays in its slot. An internal fault faults the whole read.
      readReceipt = liftIO (traverse (\(mutation,location) -> (,) mutation <$> Lane.declaredCall (Service.observeReceipt client mutation location)) pending)
      -- Any declared refusal of a run component refuses the whole read, so
      -- no partial composite reaches the install.
      readComponents profile runId = do
        snapshot <- ExceptT (Service.observeSnapshot client runId)
        control <- ExceptT (Service.observeControl client runId)
        decision <- traverse (ExceptT . Service.observeDecision client profile runId) (Service.controlHead (snd control))
        pure (Service.RunRead snapshot control decision)
  case (servicePendingReceipt state, serviceSelection state) of
    -- The receipt of an accepted export is read with 'Service.observeExport'
    -- in place of the composite read, with or without a selection, until the
    -- export is published and its download verifies.
    (Just (mutation@Service.Export {}, location), _) | not (serviceSending state) ->
      startServiceRead Lane.SingleResourceRead "reading the export receipt" $ \ticket ->
        ServiceExportReady ticket <$> Lane.serviceCall (Service.observeExport client mutation location)
    -- The receipt of an accepted lineage request is read with
    -- 'Service.observeLineageCommand' in the same way, until its child
    -- request is created and read.
    (Just (mutation@Service.Lineage {}, location), _) | not (serviceSending state) ->
      startServiceRead Lane.SingleResourceRead "reading the lineage receipt" $ \ticket ->
        ServiceLineageReady ticket <$> Lane.serviceCall (Service.observeLineageCommand client mutation location)
    -- A succeeded run with a verified or referenced result is retrieved
    -- through the same single-flight read lane, in place of the composite
    -- read, when 'Lane.retrievalDue' holds: once per run until its verified
    -- bytes are retained. After a failed retrieval, an automatic refresh
    -- retries only after the next installed composite read, and g retries at
    -- once. 'Service.retrieveResult' downloads only for a snapshot that
    -- publishes the verified state.
    (_, Just _) | not (serviceSending state), Just run <- serviceRun state,
      Service.resultWanted run || Service.resultReferenced run,
      Lane.retrievalDue cause (runIdText (Service.runIdentity run)) (stateServiceResults state) ->
        startServiceRead Lane.PageSetRead "retrieving the verified result" $ \ticket ->
          ServiceResultReady ticket (runIdText (Service.runIdentity run)) <$> Lane.serviceCall (Service.retrieveResult client run)
    -- The run components are read only for the run that the installed
    -- request names, so the read kind is known before the read starts.
    (_, Just (Service.RequestSelection ident run)) | Just workflow <- stateServiceWorkflow state, not (serviceSending state) ->
      startServiceRead (maybe Lane.SingleResourceRead (const Lane.PageSetRead) run)
        (maybe "reading manager request" (const "reading manager request and run") run) $ \ticket ->
        ServiceRequestReady ticket <$> Lane.serviceCall (runExceptT $ do
          receipt <- readReceipt
          (observed,request) <- ExceptT (Service.observeDraft client workflow ident)
          preparation <- if Manager.draftPhase request == "review" && isJust (Manager.draftPreparation request)
            then Just <$> ExceptT (Service.observePreparation client request) else pure Nothing
          components <- traverse (readComponents (Manager.draftProfile request)) run
          pure (Service.RequestRead (Just (observed,request)) preparation receipt components))
    -- A run opened by its identifier reads its snapshot, its controls and
    -- the decision at their head, with no request.
    (_, Just (Service.RunSelection run profile)) | not (serviceSending state) ->
      startServiceRead Lane.PageSetRead "reading manager run" $ \ticket ->
        ServiceRequestReady ticket <$> Lane.serviceCall (runExceptT $ do
          receipt <- readReceipt
          components <- readComponents profile run
          pure (Service.RequestRead Nothing Nothing receipt (Just components)))
    _ -> pure ()

-- | Decide one key that asks for a new mutation with 'Lane.mutationKeyOutcome':
-- a scope that the credential lacks refuses first, then the lane decides with
-- 'Lane.mutationAdmission'. A start runs the given action. Every other outcome shows its fixed text as
-- a key outcome, and the key is not replayed later.
serviceMutationKey :: Text -> EventM Name AppState () -> EventM Name AppState ()
serviceMutationKey operation start = do
  state <- get
  case Lane.mutationKeyOutcome (serviceScopes state) operation (stateServiceLane state) of
    Nothing -> start
    Just (refusal,deferred) -> serviceKeyOutcome deferred refusal

-- | The credential scopes that the capabilities of the service session list.
-- The local backend has no manager credential.
serviceScopes :: AppState -> [Text]
serviceScopes state = case stateBackend state of
  ServiceBackend _ endpoints -> maybe [] Service.endpointScopes (Lane.activeIdentity endpoints)
  LocalBackend {} -> []

-- | Show the fixed text of a mutation key that started nothing as the next
-- numbered key outcome, given whether a page-set read deferred the key. A
-- deferral records the deferring read and the time of the outcome, which
-- bound the pause of automatic refresh.
serviceKeyOutcome :: Bool -> Text -> EventM Name AppState ()
serviceKeyOutcome deferred text = do
  now <- liftIO getCurrentTime
  modify $ \state ->
    let serial = stateServiceOutcomeSerial state + 1
        deferral = if deferred then Lane.deferral now (stateServiceLane state) else Nothing
     in state {stateServiceOutcomeSerial = serial, stateServiceKeyOutcome = Just (Lane.KeyOutcome serial text deferral)}

-- | Begin a mutation that 'Lane.mutationAdmission' started. Any
-- single-resource read ends and is cancelled, so it delivers nothing.
beginServiceMutation :: Manager.Client -> Service.Mutation -> Maybe Manager.Observed -> EventM Name AppState ()
beginServiceMutation client mutation observation = do
  state <- get
  when (Lane.mutationAdmission (stateServiceLane state) == Lane.KeyStart) $ do
    now <- liftIO getCurrentTime
    let ticket = stateRequestSerial state + 1
    put (onLane (Lane.beginMutation ticket mutation) state) {stateRequestSerial = ticket, stateServiceLastReceipt = Nothing,
      stateModel = (stateModel state) {modelStatus = "preparing explicit " <> Service.mutationOperation mutation}}
    liftIO (cancelWorker state ServiceReadWork)
    liftIO . startServiceWorker state ServicePrepareWork $
      ServicePrepared ticket <$> Lane.serviceCall (Service.prepareMutation client now mutation observation)

-- | Send one original attempt once. A resend passes the retained attempt unchanged.
sendServicePending :: Manager.Client -> Int -> Attempt -> EventM Name AppState ()
sendServicePending client ticket attempt = do
  state <- get
  put (onLane (\lane -> lane {Lane.laneMutation = Lane.MutationSending ticket attempt, Lane.laneResendConfirm = False}) state) {
    stateModel = (stateModel state) {modelStatus = "sending one " <> Service.mutationOperation (Lane.attemptMutation attempt) <> " attempt"}}
  liftIO (writeIORef (stateServiceUncertainExit state) True)
  liftIO . startServiceWorker state ServiceSendWork $
    ServiceSent ticket <$> Lane.serviceCall (Manager.sendCommand client (Lane.attemptPending attempt))

-- | Install a lane that holds an unresolved attempt and show its notice.
uncertainService :: AppState -> ServiceLane -> EventM Name AppState ()
uncertainService state lane =
  put state {stateServiceLane = lane,
    stateModel = (stateModel state) {modelScreen = maybe (modelScreen (stateModel state)) ServiceCommandScreen (Lane.unresolvedNotice lane),
      modelStatus = "no automatic resend"}}

-- | Leave this attempt unresolved for a declared reason.
settleService :: AppState -> Attempt -> Text -> EventM Name AppState ()
settleService state attempt reason =
  uncertainService state (Lane.settleUncertain attempt (Lane.DeclaredUncertainty reason) (stateServiceLane state))

handleServiceSent :: Manager.Client -> Int -> Lane.CallOutcome Manager.ClientResponse -> EventM Name AppState ()
handleServiceSent client ticket result = do
  state <- get
  case Lane.sendStep ticket result (stateServiceLane state) of
    (Lane.SendStale,_) -> pure ()
    (Lane.SendFaulted,lane) -> faultService state lane
    (Lane.SendUncertain,lane) -> uncertainService state lane
    -- A 412 refusal proves that the manager holds no command under the key,
    -- so the lane is idle and nothing is sent again. A refused answer keeps
    -- its draft, the line @Control:@ states that the decision changed, and
    -- the selection is read again. A refused export shows its refusal on
    -- the export line of its run.
    (Lane.SendRefused attempt failure,lane) -> do
      let operation = Service.mutationOperation (Lane.attemptMutation attempt)
          refusal = operation <> " refused: " <> Lane.refusalCode failure
          (label,outcome) = case Lane.attemptMutation attempt of
            Service.Answer decision _ ->
              let text = refusal <> "; " <> Lane.draftKeptText in (text, Just (Service.decisionRun decision, text))
            _ -> (refusal <> "; the resource changed and nothing was sent again", stateServiceControlOutcome state)
          exported = case Lane.attemptMutation attempt of
            Service.Export _ run name -> Just (run, Service.ExportRefused name (Lane.refusalCode failure))
            _ -> stateServiceExport state
          lineaged = case Lane.attemptMutation attempt of
            Service.Lineage _ run _ choice -> Just (run, Service.LineageRefused (Service.lineageChoiceName choice) (Lane.refusalCode failure))
            _ -> stateServiceLineage state
      put state {stateServiceLane = lane, stateServiceControlOutcome = outcome, stateServiceExport = exported, stateServiceLineage = lineaged,
        stateModel = (stateModel state) {modelStatus = label}}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
      refreshServiceRequest client Lane.AutomaticRefresh
    (Lane.SendDelivered attempt@(Lane.Attempt mutation pending _) response,_) -> case mutation of
        Service.Create workflow -> case Manager.decodeObservation (Manager.responseValue response) of
          Right request | Manager.responseStatus response == 201, Service.requestMatches workflow request,
            Manager.draftPhase request == "draft", Manager.draftRun request == Nothing,
            Manager.draftParent request == Nothing, Manager.draftLineage request == Nothing,
            fmap Manager.referenceURI (Manager.responseLocation response) == Just ("/v1/requests/" <> Manager.draftId request) -> do
              let descriptor = Service.workflowDisplay workflow
                  model = (stateModel state) {modelWorkflow = Just descriptor, modelInputs = Map.empty,
                    modelScreen = if null (workflowInputs descriptor) then ServiceRequestScreen request else InputScreen 0,
                    modelStatus = "request created; fetching its exact validator"}
              put (idleService state) {stateServiceSelected = Just (Service.RequestSelection (Manager.draftId request) Nothing),
                stateServiceObservation = Lane.noObservation, stateServiceWorkflow = Just workflow, stateModel = model, stateEditor = blankEditor}
              liftIO (writeIORef (stateServiceUncertainExit state) False)
              refreshServiceRequest client Lane.AutomaticRefresh
          _ -> uncertainService state (Lane.declaredSendUncertain attempt "invalid creation response" (stateServiceLane state))
        -- A capture answers with its capture receipt, which must name the
        -- exact bytes that were sent. The set-input that binds it starts
        -- from the next installed request read ('applyServiceObservation').
        Service.Capture {} -> case Manager.captureResponse response of
          Right (receipt,location) | Service.captureMatches mutation receipt -> do
            put (onLane (\lane -> lane {Lane.laneMutation = Lane.MutationAwaiting mutation pending location}) state) {
              stateServiceCaptures = Map.insert (Manager.captureId receipt) receipt (stateServiceCaptures state),
              stateModel = (stateModel state) {modelStatus = "capture stored; reading the request before its set-input"}}
            refreshServiceRequest client Lane.AutomaticRefresh
          _ -> uncertainService state (Lane.declaredSendUncertain attempt "invalid capture response" (stateServiceLane state))
        _ -> case (Manager.decodeObservation (Manager.responseValue response),Manager.responseLocation response) of
          (Right receipt,Just location) | Manager.responseStatus response == 202, Service.receiptMatches mutation receipt,
            Manager.referenceURI location == "/v1/commands/" <> Manager.receiptId receipt -> do
              put (onLane (\lane -> lane {Lane.laneMutation = Lane.MutationAwaiting mutation pending location}) state) {stateServiceLastReceipt = Just receipt,
                stateModel = (stateModel state) {modelStatus = "manager intent accepted; awaiting independent effect"}}
              refreshServiceRequest client Lane.AutomaticRefresh
          _ -> uncertainService state (Lane.declaredSendUncertain attempt "invalid command response" (stateServiceLane state))

-- | Apply one installed composite read. 'Lane.requestStep' has already
-- installed it. Only a receipt read in this read can confirm an effect or
-- settle an attempt. An unreadable receipt keeps the last receipt for display,
-- confirms nothing and offers no resend. 'serviceRunObserved' decides whether
-- a read with run components shows the run in the live monitor. The
-- occurrence selection, pane focus, output position and run details stay.
applyServiceObservation :: Manager.Client -> Service.RequestRead Manager.Observed -> EventM Name AppState ()
applyServiceObservation client (Service.RequestRead requestRead preparation receiptResult runComponents) = do
  before <- get
  let fresh = case receiptResult of Just (_,Right received) -> Just received; _ -> Nothing
      state = before {stateServiceLastReceipt = maybe (stateServiceLastReceipt before) Just fresh,
        stateServiceApprovalStatus = case stateServiceApproval before of
          Nothing -> stateServiceApprovalStatus before
          Just (approval,_,_) -> Just (Service.approvalStatus approval receiptResult (stateServiceApprovalStatus before))}
      pending = case serviceMutation state of
        Lane.MutationAwaiting mutation command location -> Just (mutation,command,Just location)
        Lane.MutationUncertain (Lane.Attempt mutation command location) _ -> Just (mutation,command,location)
        _ -> Nothing
      confirmed kind = maybe False (\value -> Manager.stateName (Manager.receiptState value) == "effect-observed"
        && Service.receiptEffectKind value == Just kind
        && maybe False (\(mutation,_,_) -> Service.receiptMatches mutation value) pending) fresh
      -- A completed command shows its screen only while a screen of the
      -- selection is shown, so it never replaces the overview or a browser.
      shownScreen current screen = if serviceShowsSelection (modelScreen (stateModel current)) then screen else modelScreen (stateModel current)
      requested = snd <$> requestRead
      -- An observed input change shows the next input, or the request after
      -- the last input, with these operator literals. Its draft ends.
      inputSaved :: Manager.DraftView -> Text -> Map.Map Text Text -> Int -> EventM Name AppState ()
      inputSaved request name literals index = do
        let model = (stateModel state) {modelInputs = literals,
              modelScreen = case modelWorkflow (stateModel state) of
                Just descriptor | index + 1 < length (workflowInputs descriptor) -> InputScreen (index + 1)
                _ -> ServiceRequestScreen request, modelStatus = "input effect observed"}
        put (idleService state) {stateModel = model,
          stateEditor = Edit.editorText InputEditor Nothing (inputValue model),
          stateServiceDrafts = Lane.dropDraft (Lane.InputDraft (Manager.draftId request) name) (stateServiceDrafts state)}
        liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
  put state
  case (pending, requested) of
    (Just (mutation@(Service.SaveLiteral _ name value index),command,location), Just request)
      | confirmed "input-changed" ->
          if Service.literalInputs request == Map.insert name value (modelInputs (stateModel state))
            && Manager.draftPhase request == "draft"
          then inputSaved request name (Map.insert name value (modelInputs (stateModel state))) index
          else settleService state (Lane.Attempt mutation command location) "request no longer matches the submitted literals"
    -- A stored capture continues with the set-input that binds it, once
    -- its own receipt reads back. That set-input is prepared from the
    -- request observation of this installed read, and it is a new command
    -- with its own key, not a resend.
    (Just (mutation@(Service.Capture _ name _ index),_,_), Just request)
      | Just (observed,_) <- requestRead, maybe False (Service.receiptMatches mutation) fresh,
        Just receipt <- Service.capturedReceipt mutation (stateServiceCaptures state) -> do
          put (idleService state)
          beginServiceMutation client (Service.SaveCapture request name receipt index) (Just observed)
    (Just (mutation@(Service.SaveCapture _ name receipt index),command,location), Just request)
      | confirmed "input-changed" ->
          let Manager.Readiness _ supplied _ _ = Manager.draftReadiness request
              literals = Map.delete name (modelInputs (stateModel state))
           in if Manager.CapturedValue name (Manager.captureId receipt) `elem` supplied
                && Service.literalInputs request == literals && Manager.draftPhase request == "draft"
              then inputSaved request name literals index
              else settleService state (Lane.Attempt mutation command location) "request no longer matches the submitted capture"
    -- The answer completes only on its own effect-observed receipt of kind
    -- answer-accepted, whose address 'Service.receiptMatches' binds to the
    -- answered occurrence and run. Its draft ends with it.
    (Just (Service.Answer decision _,_,_), _) | confirmed "answer-accepted" -> do
      put (idleService state) {statePersonEditor = blankEditor,
        stateServiceDrafts = Lane.dropDraft (Lane.AnswerDraft (Service.decisionRun decision) (Service.decisionId decision)) (stateServiceDrafts state),
        stateModel = (stateModel state) {modelStatus = "answer effect observed"}}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    -- The retry completes only on its own effect-observed receipt of the
    -- effect kind of its offer, whose address 'Service.receiptMatches' binds
    -- to the recovering occurrence and attempt of the run controls.
    (Just (Service.Retry _ _ offer _,_,_), _) | confirmed (Service.retryEffect offer) -> do
      put (idleService state) {stateModel = (stateModel state) {modelStatus = "retry effect observed"}}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    -- A cancel, a steer and a recovery choice complete on the outcome that
    -- 'Service.controlOutcome' reads from their own receipt: the accepting
    -- runtime acknowledgement of a cancel, the effect steered of a steer,
    -- and the effect recovery-chosen of a recovery choice. The live monitor
    -- shows that outcome for the run.
    (Just (mutation,_,_), _) | Just run <- Service.controlMutationRun mutation, Just received <- fresh,
      Just outcome <- Service.controlOutcome mutation received -> do
        put (idleService state) {stateServiceControlOutcome = Just (run, outcome),
          stateModel = (stateModel state) {modelStatus = Service.mutationOperation mutation <> " outcome observed: " <> outcome}}
        liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    -- A removal, a withdrawal and a discard complete on their own
    -- effect-observed receipt of their effect kind, which names the request.
    -- The request screen then shows the request of this read: its readiness
    -- without the removed input, the withdrawn phase, or the draft phase
    -- without a preparation. A removal also ends the draft of its input.
    (Just (Service.RemoveInput _ name _,_,_), Just request) | confirmed "input-changed" -> do
      put (idleService state) {stateModel = (stateModel state) {modelInputs = Map.delete name (modelInputs (stateModel state)),
          modelScreen = shownScreen state (ServiceRequestScreen request), modelStatus = "input removal observed"},
        stateServiceDrafts = Lane.dropDraft (Lane.InputDraft (Manager.draftId request) name) (stateServiceDrafts state)}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    (Just (Service.Withdraw _,_,_), Just request) | confirmed "withdrawn" -> do
      put (idleService state) {stateModel = (stateModel state) {modelScreen = shownScreen state (ServiceRequestScreen request),
        modelStatus = "withdrawal effect observed"}}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    (Just (Service.Discard {},_,_), Just request) | confirmed "discarded" -> do
      put (idleService state) {stateModel = (stateModel state) {modelScreen = shownScreen state (ServiceRequestScreen request),
        modelStatus = "discard effect observed; Enter prepares a new review"}}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    (Just (Service.Enqueue _,_,_), Just request) | confirmed "enqueued" -> do
      put (idleService state) {stateModel = (stateModel state) {modelScreen = shownScreen state (ServiceRequestScreen request)}}
      liftIO (writeIORef (stateServiceUncertainExit state) (isJust (stateServiceApproval state)))
    (Just (mutation@(Service.Approve approvedRequest _),command,location), Just request)
      | Manager.draftPhase request == "associated", isJust (Manager.draftRun request),
        Manager.draftId request == Manager.draftId approvedRequest,
        Service.literalInputs request == modelInputs (stateModel state) ->
          put (idleService state) {stateServiceApproval = Just (mutation,command,location),
            stateServiceApprovalStatus = Just (Service.approvalStatus mutation receiptResult Nothing),
            stateModel = (stateModel state) {modelScreen = shownScreen state (ServiceRequestScreen request),
              modelStatus = "run associated; approval receipt remains distinct from runtime outcome"}}
    -- A receipt that reports the command refused or unresolved leaves the
    -- retained attempt unresolved, with the reconciliation of its receipt
    -- state, for example after a manager restart. Only the explicit exact
    -- resend can send it again.
    (Just (mutation,command,location), _) | Just _ <- Service.receiptSettlement mutation receiptResult, Just received <- fresh ->
      let attempt = Lane.Attempt mutation command location
       in settleService state attempt (Lane.receiptReconciliation attempt (Manager.receiptState received))
    _ -> pure ()
  current <- get
  let run = (\components -> let observed = Service.runReadSnapshot components in (Service.runIdentity observed, Service.runSnapshot observed))
        <$> runComponents
  case serviceRunObserved (serviceIdle current) run (stateModel current) of
    Just model -> do
      put current {stateConfirmDetails = False, stateModel = model,
        stateRunView = maybe (stateRunView current) (`reconcileRunView` stateRunView current) (modelSnapshot model)}
      when (stateOutputFollow current) (vScrollToEnd (viewportScroll OutputViewport))
    -- The request and review screens follow the installed request only
    -- while a screen of the selection is shown.
    Nothing -> when (serviceIdle current && serviceShowsSelection (modelScreen (stateModel current))) $ case (modelScreen (stateModel current), requested) of
      (InputScreen _, _) -> put current {stateModel = (stateModel current) {modelStatus = "request validator current; Ctrl-D sends the literal"}}
      (_, Just request) -> case (stateServiceWorkflow current,preparation) of
        (Just workflow,Just (prepObserved,prep))
          | Service.reviewMatches (stateServiceCaptures current) workflow request prep, Service.literalInputs request == modelInputs (stateModel current),
            Service.reviewLive (stateNow current) prep -> do
              let screen = ServiceReviewScreen prep (Manager.observedETag prepObserved)
              put current {stateConfirmDetails = stateConfirmDetails current && modelScreen (stateModel current) == screen,
                stateModel = (stateModel current) {modelScreen = screen, modelStatus = "exact manager review observed"}}
        _ -> put current {stateConfirmDetails = False, stateModel = (stateModel current)
          {modelScreen = ServiceRequestScreen request, modelStatus = "manager request: " <> Manager.draftPhase request}}
      (_, Nothing) -> pure ()

-- | Handle one service event, start the next waiting fetch of live
-- delivery, show the draft of the displayed identity when that identity
-- changed, then apply the approval-notice and key-outcome lifetimes.
handleServiceEvent :: Manager.Client -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleServiceEvent client event = do
  before <- get
  handleServiceEventCore client event
  pumpServiceFetches client
  modify (showServiceDraft (serviceDraftKey before) . keepServiceDraft (serviceDraftKey before))
  after <- get
  let view current = (modelScreen (stateModel current), stateConfirmDetails current, stateKeyHelp current, serviceResendConfirm current, stateServiceConfirm current)
      noticeEvent = Approval.NoticeEvent
        { Approval.eventKeyPress = case event of VtyEvent Vty.EvKey {} -> True; _ -> False,
          Approval.eventViewBefore = view before,
          Approval.eventViewAfter = view after,
          Approval.eventReviewShown = case modelScreen (stateModel after) of ServiceReviewScreen {} -> True; _ -> False,
          Approval.eventUnsentApproval = Approval.unsentApproval (stateServiceApprovalPress after) (serviceMutation before) (serviceMutation after)
        }
  put after {stateServiceNotice = Approval.retainNotice noticeEvent (stateServiceNotice before) (stateServiceNotice after),
    stateServiceKeyOutcome = Lane.retainKeyOutcome (Approval.eventKeyPress noticeEvent) (view before) (view after)
      (stateServiceKeyOutcome before) (stateServiceKeyOutcome after)}

-- | Decide one approval-key press on the displayed review with
-- 'Approval.approvalDecision', show its notice, and start the approval only
-- when the decision approves. An approval start records its press, and it
-- ends and cancels any read in flight through 'beginServiceMutation'.
handleApprovalKey :: Manager.Client -> (Approval.ApprovalKey, Manager.Preparation, Text) -> EventM Name AppState ()
handleApprovalKey client (key,displayed,tag) = do
  state <- get
  let serial = stateServiceKeySerial state + 1
      decision = Approval.approvalDecision (serviceScopes state) key (serviceReviewView state) (stateServiceLane state) (serviceReviewCheck state displayed tag)
      pressed = state {stateServiceKeySerial = serial, stateServiceNotice = Just (Approval.decisionNotice serial decision)}
  case decision of
    Approval.Approve (request,observed) -> do
      put pressed {stateServiceApprovalPress = Just serial}
      beginServiceMutation client (Service.Approve request displayed) (Just observed)
    Approval.Refuse _ -> put pressed
    Approval.Unscoped _ -> put pressed

-- | The view of the review screen that the operator sees.
serviceReviewView :: AppState -> Approval.ReviewView
serviceReviewView state = Approval.reviewView (stateKeyHelp state) (stateConfirmDetails state)

-- | Check the displayed review against the installed observations, the
-- current time and the terminal size.
serviceReviewCheck :: AppState -> Manager.Preparation -> Text -> Approval.ReviewCheck (Manager.DraftView, Manager.Observed)
serviceReviewCheck state displayed tag =
  Approval.checkReview Manager.observedETag (stateNow state) (serviceReviewAllowed displayed tag (stateTerminalSize state))
    (stateServiceWorkflow state) (serviceRequest state) (servicePreparation state) (modelInputs (stateModel state))
    (stateServiceCaptures state) displayed tag

-- | Handle one worker result of the active session. The completion of the
-- read that holds the read ticket also decides whether the manager answers
-- ('Lane.readReachability') and whether it accepts the credential
-- ('Lane.credentialStep'). When a read reaches the manager again after it
-- was unreachable, every read of live delivery is invalidated, so each
-- retained observation is read again when its view is shown. A credential
-- refusal of any other result, a preparation and a send included, also
-- records the refusal ('Lane.refuseCredential').
handleServiceResult :: Manager.Client -> ServiceEvent -> EventM Name AppState ()
handleServiceResult client serviceEvent = do
  before <- get
  let owned = fmap Lane.ticketNumber (Lane.laneReadTicket (stateServiceLane before)) == Just (serviceEventTicket serviceEvent)
  handleServiceResultFetch client serviceEvent
  when (resultRefusesCredential serviceEvent) (modify (\current -> onLane (Lane.refuseCredential (stateRequestSerial current)) current))
  forM_ (if owned then serviceReadOutcome serviceEvent else Nothing) $ \outcome -> do
    now <- liftIO getCurrentTime
    current <- get
    let reach = Lane.readReachability now outcome (stateServiceReach current)
    put (onLane (Lane.credentialStep (stateRequestSerial current) (serviceEventTicket serviceEvent) outcome) current) {stateServiceReach = reach}
    when (stateServiceReach current /= Lane.Reachable && reach == Lane.Reachable) $
      invalidateServiceFetches [minBound .. maxBound]

-- | Whether a worker result is a declared credential refusal
-- ('Lane.credentialRefusal'): a read, a preparation or a send.
resultRefusesCredential :: ServiceEvent -> Bool
resultRefusesCredential serviceEvent = case serviceEvent of
  ServicePrepared _ result -> refused result
  ServiceSent _ result -> refused result
  _ -> case serviceReadOutcome serviceEvent of
    Just (Left failure) -> Lane.credentialRefusal failure
    _ -> False
  where
    refused :: Lane.CallOutcome a -> Bool
    refused result = case result of
      Lane.Declared (Left failure) -> Lane.credentialRefusal failure
      _ -> False

-- | The outcome of a completed read for 'Lane.readReachability': a declared
-- failure, or a delivered value. A preparation, a send and an internal fault
-- are not reads that decide it.
serviceReadOutcome :: ServiceEvent -> Maybe (Either Manager.ClientFailure ())
serviceReadOutcome serviceEvent = case serviceEvent of
  ServiceProfilesReady _ result -> declared result
  ServiceWorkflowsReady _ _ result -> declared result
  ServicePrepared {} -> Nothing
  ServiceSent {} -> Nothing
  ServiceRequestReady _ result -> declared result
  ServiceOverviewReady _ _ _ result -> declared result
  ServiceDecisionsReady _ _ result -> declared result
  ServiceHistoryReady _ _ result -> declared result
  ServiceHistoryDetailReady _ _ _ result -> declared result
  ServiceResultReady _ _ result -> declared result
  ServiceExportReady _ result -> declared result
  ServiceLineageMenuReady _ _ _ result -> declared result
  ServiceLineageReady _ result -> declared result
  where
    declared :: Lane.CallOutcome a -> Maybe (Either Manager.ClientFailure ())
    declared result = case result of
      Lane.Declared outcome -> Just (() <$ outcome)
      Lane.InternalFault -> Nothing

-- | Complete the fetch of live delivery that the result performs, if any,
-- and handle the result.
handleServiceResultFetch :: Manager.Client -> ServiceEvent -> EventM Name AppState ()
handleServiceResultFetch client serviceEvent = do
  before <- get
  -- The completion of a read that performs a fetch of live delivery
  -- completes that fetch first. A result that the coordinator discards only
  -- ends the read ticket.
  case Lane.fetchCompleted (serviceEventTicket serviceEvent) (serviceRefresh before) (stateServiceFetches before) of
    Nothing -> handleServiceResultCore client serviceEvent
    Just (install, refresh, fetches) -> do
      put (onEndpointsRefresh (const (refresh, fetches)) before)
      -- A fetch that a resnapshot discarded ends its read here: the read
      -- ticket is free for the fetch of the new generation, and nothing of
      -- the result is installed. The session generation is unchanged, so
      -- the result was admitted.
      if install
        then handleServiceResultCore client serviceEvent
        else modify (onLane (Lane.releaseRead (serviceEventTicket serviceEvent)))

-- | The ticket of a worker result.
serviceEventTicket :: ServiceEvent -> Int
serviceEventTicket serviceEvent = case serviceEvent of
  ServiceProfilesReady ticket _ -> ticket
  ServiceWorkflowsReady ticket _ _ -> ticket
  ServicePrepared ticket _ -> ticket
  ServiceSent ticket _ -> ticket
  ServiceRequestReady ticket _ -> ticket
  ServiceOverviewReady ticket _ _ _ -> ticket
  ServiceDecisionsReady ticket _ _ -> ticket
  ServiceHistoryReady ticket _ _ -> ticket
  ServiceHistoryDetailReady ticket _ _ _ -> ticket
  ServiceResultReady ticket _ _ -> ticket
  ServiceExportReady ticket _ -> ticket
  ServiceLineageMenuReady ticket _ _ _ -> ticket
  ServiceLineageReady ticket _ -> ticket

-- | The refresh coordinator of the session.
serviceRefresh :: AppState -> Manager.Refresh Lane.FetchKey
serviceRefresh state = case stateBackend state of
  ServiceBackend _ endpoints -> Lane.endpointsRefresh endpoints
  LocalBackend {} -> Manager.newRefresh

handleServiceResultCore :: Manager.Client -> ServiceEvent -> EventM Name AppState ()
handleServiceResultCore client serviceEvent = do
  state <- get
  -- A refused catalogue read has no earlier observation to keep.
  let failed lane problem = state {stateServiceLane = lane, stateModel = refuseCatalogueRead (T.pack (show problem)) (stateModel state)}
  case serviceEvent of
    ServiceProfilesReady ticket result -> case Lane.readStep ticket result (stateServiceLane state) of
      (Lane.ReadStale,_) -> pure ()
      (Lane.ReadFaulted,lane) -> faultService state lane
      (Lane.ReadRefused problem,lane) -> put (failed lane problem)
      -- The profiles show after the overview read of the bootstrap, so no
      -- profile key meets that read in flight.
      (Lane.ReadDelivered profiles,lane) -> do
        put state {stateServiceLane = lane, stateServiceProfiles = profiles, stateServiceWorkflows = []}
        startServiceOverview client BootstrapOverview
    -- Every overview read is fenced by the fetch generation in which it
    -- started ('Lane.overviewStep'), whatever its origin: a read of an
    -- earlier generation only ends its read ticket, so the waiting
    -- resnapshot fetch starts at the current generation. A refused overview
    -- read keeps the last complete overview and marks it stale with the
    -- refusal code. An installed overview starts the event worker from its
    -- cursor when no stream runs.
    ServiceOverviewReady ticket origin generation result ->
      let bootstrap = origin == BootstrapOverview
          shown current
            | bootstrap = current {stateModel = initialServiceModel (stateServiceProfiles current), statePaneFocus = PrimaryPane}
            | otherwise = current
          members = case result of
            Lane.Declared outcome -> Lane.Declared (snd <$> outcome)
            Lane.InternalFault -> Lane.InternalFault
          cursor = case result of
            Lane.Declared (Right (value, _)) -> Just value
            _ -> Nothing
      in case Lane.overviewStep generation (Manager.refreshGeneration (serviceRefresh state)) ticket members (stateServiceLane state) (stateServiceOverview state) of
        (Lane.RequestStale,lane,_) -> put state {stateServiceLane = lane}
        (Lane.RequestFaulted,lane,_) -> faultService state lane
        -- A refused read of live delivery or of a resnapshot is read again
        -- after the backoff. Such a read keeps the status line, and the
        -- overview line shows the refusal code.
        (Lane.RequestRefused problem,lane,installed) ->
          let live = origin == LiveOverview || stateServiceDelivery state == Lane.DeliveryResnapshot
              next = shown state {stateServiceLane = lane, stateServiceOverview = installed,
                stateServiceOverviewRetry = if live
                  then Just (Lane.overviewRefused (stateNow state) (stateServiceOverviewRetry state))
                  else stateServiceOverviewRetry state}
          in put (if origin == LiveOverview then next
            else next {stateModel = refuseRequestRead (Lane.refusalCode problem) (isJust (Lane.installedRead installed)) (stateModel next)})
        -- The focus keeps the identity of the selected row, so the same row
        -- stays selected wherever the new overview lists it.
        (Lane.RequestInstalled _,lane,installed) ->
          let next = shown state {stateServiceLane = lane, stateServiceOverview = installed, stateServiceOverviewRetry = Nothing}
          in do
            put next {stateModel = if origin == ExplicitOverview then (stateModel next) {modelStatus = "manager overview read"} else stateModel next}
            mapM_ (startServiceEvents client generation) cursor
    -- A refused read of the decision heads keeps the last complete heads
    -- and marks them stale with the refusal code. The focus keeps the
    -- identity of the selected row.
    ServiceDecisionsReady ticket explicit result ->
      case Lane.requestStep (const Service.ReadCurrent) ticket result (stateServiceLane state) (stateServiceDecisions state) of
        (Lane.RequestStale,lane,_) -> put state {stateServiceLane = lane}
        (Lane.RequestFaulted,lane,_) -> faultService state lane
        (Lane.RequestRefused problem,lane,installed) ->
          let next = state {stateServiceLane = lane, stateServiceDecisions = installed}
          in put (if explicit
            then next {stateModel = refuseRequestRead (Lane.refusalCode problem) (isJust (Lane.installedRead installed)) (stateModel next)}
            else next)
        (Lane.RequestInstalled _,lane,installed) ->
          let next = state {stateServiceLane = lane, stateServiceDecisions = installed}
          in put (if explicit then next {stateModel = (stateModel next) {modelStatus = "manager decisions read"}} else next)
    -- A refused read of the run list keeps the last complete run list and
    -- marks it stale with the refusal code. The focus keeps the identity of
    -- the selected row.
    ServiceHistoryReady ticket explicit result ->
      case Lane.requestStep (const Service.ReadCurrent) ticket result (stateServiceLane state) (stateServiceHistory state) of
        (Lane.RequestStale,lane,_) -> put state {stateServiceLane = lane}
        (Lane.RequestFaulted,lane,_) -> faultService state lane
        (Lane.RequestRefused problem,lane,installed) ->
          let next = state {stateServiceLane = lane, stateServiceHistory = installed}
          in put (if explicit
            then next {stateModel = refuseRequestRead (Lane.refusalCode problem) (isJust (Lane.installedRead installed)) (stateModel next)}
            else next)
        (Lane.RequestInstalled _,lane,installed) ->
          let next = state {stateServiceLane = lane, stateServiceHistory = installed}
          in put (if explicit then next {stateModel = (stateModel next) {modelStatus = "manager history read"}} else next)
    -- Only a detail of the run that the run detail shows installs. A refused
    -- read keeps the last complete detail and marks it stale.
    ServiceHistoryDetailReady ticket explicit run result ->
      let verdict detail = case modelScreen (stateModel state) of
            ServiceHistoryRunScreen shown | shown == run && Service.historyDetailRun detail == run -> Service.ReadCurrent
            _ -> Service.ReadForeign
          installedNow = case Lane.installedRead (stateServiceHistoryDetail state) of
            Just detail | Service.historyDetailRun detail /= run -> Lane.noObservation
            _ -> stateServiceHistoryDetail state
      in case Lane.requestStep verdict ticket result (stateServiceLane state) installedNow of
        (Lane.RequestStale,lane,_) -> put state {stateServiceLane = lane}
        (Lane.RequestFaulted,lane,_) -> faultService state lane
        (Lane.RequestRefused problem,lane,installed) ->
          let next = state {stateServiceLane = lane, stateServiceHistoryDetail = installed}
          in put (if explicit
            then next {stateModel = refuseRequestRead (Lane.refusalCode problem) (isJust (Lane.installedRead installed)) (stateModel next)}
            else next)
        (Lane.RequestInstalled _,lane,installed) ->
          let next = state {stateServiceLane = lane, stateServiceHistoryDetail = installed,
                stateServiceResults = Lane.retrievalObserved run (stateServiceResults state)}
          in put (if explicit then next {stateModel = (stateModel next) {modelStatus = "manager run detail read"}} else next)
    -- A catalogue that the overview loaded for a request opens that request
    -- when it lists the workflow revision of the request.
    -- The current profile replaces the earlier observation of that profile.
    ServiceWorkflowsReady ticket opening result -> case Lane.readStep ticket result (stateServiceLane state) of
      (Lane.ReadStale,_) -> pure ()
      (Lane.ReadFaulted,lane) -> faultService state lane
      (Lane.ReadRefused problem,lane) -> put (failed lane problem)
      (Lane.ReadDelivered (profile, workflows),lane) -> do
        put state {stateServiceLane = lane, stateServiceWorkflows = workflows,
          stateServiceProfiles = map (\listed -> if Service.profileId listed == Service.profileId profile then profile else listed)
            (stateServiceProfiles state),
          stateModel = (initialModel (map Service.workflowDisplay workflows) [] (Left "manager owns routing"))
            {modelStatus = "manager catalogue: " <> Service.profileId profile}, statePaneFocus = PrimaryPane}
        forM_ opening $ \request -> case find (`Service.requestMatches` request) workflows of
          Just workflow -> openServiceRequest workflow request
          Nothing -> modify $ \current -> current {stateModel = (stateModel current)
            {modelStatus = "overview row not opened: the catalogue of " <> Service.profileId profile <> " lists no workflow revision of this request"}}
    ServicePrepared ticket result -> case Lane.prepareStep ticket result (stateServiceLane state) of
      (Lane.PrepareStale,_) -> pure ()
      (Lane.PrepareFaulted,lane) -> faultService state lane
      (Lane.PrepareRefused failure,lane) -> put state {stateServiceLane = lane,
        stateModel = (stateModel state) {modelStatus = "preflight refused before send: " <> T.pack (show failure)}}
      (Lane.PrepareSend attempt,_) -> sendServicePending client ticket attempt
    ServiceSent ticket result -> handleServiceSent client ticket result
    -- A refused request read keeps the screen, the command lane and the last
    -- complete observation, and marks that observation stale.
    ServiceRequestReady ticket result ->
      let verdict = maybe (const Service.ReadForeign) (Service.readVerdict Service.observedBinding) (serviceSelection state)
      in case Lane.requestStep verdict ticket result (stateServiceLane state) (stateServiceObservation state) of
        (Lane.RequestStale,lane,_) -> put state {stateServiceLane = lane}
        (Lane.RequestFaulted,lane,_) -> faultService state lane
        (Lane.RequestRefused problem,lane,installed) -> put state {stateServiceLane = lane, stateServiceObservation = installed,
          stateModel = refuseRequestRead (Lane.refusalCode problem) (isJust (Lane.installedRead installed)) (stateModel state)}
        -- An installed composite read makes a failed retrieval of its run
        -- due again.
        (Lane.RequestInstalled observation,lane,installed) ->
          put state {stateServiceLane = lane, stateServiceObservation = installed,
            stateServiceResults = maybe id (Lane.retrievalObserved . runIdText . Service.runIdentity . Service.runReadSnapshot)
              (Service.readRun observation) (stateServiceResults state)} >> applyServiceObservation client observation
    -- Only retrieved verified bytes are retained for their run. A declared
    -- refusal and a retrieval without a verified result are retryable
    -- failures that the status line and the result lines show.
    ServiceResultReady ticket run result ->
      let retrieved :: ServiceLane -> Lane.Retrievals Service.VerifiedResult -> EventM Name AppState ()
          -- On the run detail of the run, r retries a failed retrieval.
          retrieved lane retrievals = put state {stateServiceLane = lane, stateServiceResults = retrievals,
                stateModel = (stateModel state) {modelStatus = case (Lane.retrievalOf run retrievals, modelScreen (stateModel state)) of
                  (Just (Lane.RetrievalFailed code _), ServiceHistoryRunScreen shown) | shown == run ->
                    "verified result not retrieved: " <> code <> "; r retries"
                  (Just retrieval, _) -> Lane.retrievalStatus retrieval
                  (Nothing, _) -> modelStatus (stateModel state)}}
      in case Lane.readStep ticket result (stateServiceLane state) of
        (Lane.ReadStale,_) -> pure ()
        (Lane.ReadFaulted,lane) -> faultService state lane
        (Lane.ReadRefused problem,lane) -> retrieved lane (Lane.retrievalStep run (Left problem) (stateServiceResults state))
        (Lane.ReadDelivered value,lane) -> retrieved lane (Lane.retrievalStep run (Right value) (stateServiceResults state))
    -- The progress of the accepted export. A pending receipt is the latest
    -- receipt, and a refused or unresolved receipt leaves the export
    -- unresolved without a resend. A published export whose download
    -- verified completes the command and shows its receipt and its bytes on
    -- the export line of its run. A declared refusal of the read keeps the
    -- command, and the next refresh reads its receipt again.
    ServiceExportReady ticket result -> case Lane.readStep ticket result (stateServiceLane state) of
      (Lane.ReadStale,_) -> pure ()
      (Lane.ReadFaulted,lane) -> faultService state lane
      (Lane.ReadRefused problem,lane) -> put state {stateServiceLane = lane,
        stateModel = (stateModel state) {modelStatus = "export receipt not read: " <> Lane.refusalCode problem <> "; the next refresh reads it again"}}
      (Lane.ReadDelivered progress,lane) -> do
        let current = state {stateServiceLane = lane}
            pending = case serviceMutation current of
              Lane.MutationAwaiting mutation command location -> Just (mutation, command, Just location)
              Lane.MutationUncertain (Lane.Attempt mutation command location) _ -> Just (mutation, command, location)
              _ -> Nothing
        case (pending, progress) of
          (Just (mutation@(Service.Export _ run _), _, _), Service.ExportPublished receipt export bytes)
            | Service.receiptMatches mutation receipt -> do
                put (idleService current) {stateServiceLastReceipt = Just receipt,
                  stateServiceExport = Just (run, Service.ExportVerified export bytes),
                  stateModel = (stateModel current) {modelStatus = "export published; its download verified"}}
                liftIO (writeIORef (stateServiceUncertainExit current) (isJust (stateServiceApproval current)))
          (Just (mutation@Service.Export {}, command, location), Service.ExportPending receipt)
            | Just reason <- Service.receiptSettlement mutation (Just (mutation, Right receipt)) ->
                settleService current {stateServiceLastReceipt = Just receipt} (Lane.Attempt mutation command location) reason
            | otherwise -> put current {stateServiceLastReceipt = Just receipt}
          _ -> put current
    -- The first page of the lineage collection opens the lineage menu while
    -- the screen still shows its run.
    ServiceLineageMenuReady ticket profile run result -> case Lane.readStep ticket result (stateServiceLane state) of
      (Lane.ReadStale,_) -> pure ()
      (Lane.ReadFaulted,lane) -> faultService state lane
      (Lane.ReadRefused problem,lane) -> put state {stateServiceLane = lane,
        stateModel = (stateModel state) {modelStatus = "lineage menu not opened: " <> Lane.refusalCode problem}}
      (Lane.ReadDelivered (observed, page),lane) -> do
        let current = state {stateServiceLane = lane}
        case serviceLineageSource current of
          Right (shownProfile, shown) | shownProfile == profile, runIdText (Service.runIdentity shown) == run ->
            put current {stateLineageMenu = Just (Service.lineageMenu profile observed page shown), stateLineageEditor = blankEditor,
              stateModel = (stateModel current) {modelStatus = "lineage menu of run " <> run}}
          _ -> put current {stateModel = (stateModel current) {modelStatus = "lineage menu not opened: the screen no longer shows run " <> run}}
    -- The progress of the accepted lineage request. A pending receipt is the
    -- latest receipt, and a refused or unresolved receipt leaves the request
    -- unresolved without a resend. A created child request completes the
    -- command, shows the outcome on the lineage line of the parent run, and
    -- opens the child request by its phase. A declared refusal of the read
    -- keeps the command, and the next refresh reads its receipt again.
    ServiceLineageReady ticket result -> case Lane.readStep ticket result (stateServiceLane state) of
      (Lane.ReadStale,_) -> pure ()
      (Lane.ReadFaulted,lane) -> faultService state lane
      (Lane.ReadRefused problem,lane) -> put state {stateServiceLane = lane,
        stateModel = (stateModel state) {modelStatus = "lineage receipt not read: " <> Lane.refusalCode problem <> "; the next refresh reads it again"}}
      (Lane.ReadDelivered progress,lane) -> do
        let current = state {stateServiceLane = lane}
            pending = case serviceMutation current of
              Lane.MutationAwaiting mutation command location -> Just (mutation, command, Just location)
              Lane.MutationUncertain (Lane.Attempt mutation command location) _ -> Just (mutation, command, location)
              _ -> Nothing
        case (pending, progress) of
          (Just (mutation@(Service.Lineage _ run _ choice), _, _), Service.LineageChild receipt child)
            | Service.receiptMatches mutation receipt -> do
                put (idleService current) {stateServiceLastReceipt = Just receipt,
                  stateServiceLineage = Just (run, Service.LineageCreated (Service.lineageChoiceName choice) (Manager.draftId child)),
                  stateModel = (stateModel current) {modelStatus = "lineage request created; opening request " <> Manager.draftId child}}
                liftIO (writeIORef (stateServiceUncertainExit current) (isJust (stateServiceApproval current)))
                openLineageChild client child
          (Just (mutation@Service.Lineage {}, command, location), Service.LineagePending receipt)
            | Just reason <- Service.receiptSettlement mutation (Just (mutation, Right receipt)) ->
                settleService current {stateServiceLastReceipt = Just receipt} (Lane.Attempt mutation command location) reason
            | otherwise -> put current {stateServiceLastReceipt = Just receipt}
          _ -> put current

-- | Open the child request that a lineage request created, by its phase,
-- with the catalogue row of its workflow. A catalogue that does not list the
-- row is loaded for the profile of the child first.
openLineageChild :: Manager.Client -> Manager.DraftView -> EventM Name AppState ()
openLineageChild client child = do
  state <- get
  case find (`Service.requestMatches` child) (stateServiceWorkflows state) of
    Just workflow -> openServiceRequest workflow child
    Nothing -> case find ((== Manager.draftProfile child) . Service.profileId) (stateServiceProfiles state) of
      Just profile -> startServiceWorkflows client profile (Just child)
      Nothing -> put state {stateModel = (stateModel state)
        {modelStatus = "child request not opened: the manager catalogue lists no profile of request " <> Manager.draftId child}}

handleServiceEventCore :: Manager.Client -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleServiceEventCore client event = do
  state <- get
  case event of
    -- A result of an earlier session changes nothing.
    AppEvent (ServiceResult stamped) -> case stateBackend state of
      ServiceBackend _ endpoints -> mapM_ (handleServiceResult client) (Lane.admitStamped endpoints stamped)
      LocalBackend {} -> pure ()
    AppEvent (EndpointConnected ticket outcome) -> handleEndpointConnected ticket outcome
    AppEvent ServiceWakeup -> handleServiceWakeup
    AppEvent (Tick now) -> do
      put state {stateNow = now}
      -- After an internal fault, and while the credential is refused,
      -- observations refresh only on an explicit g.
      -- After a deferred key, automatic refresh pauses until the deferring
      -- page-set read completes or for at most 'Lane.refreshPauseLimit'.
      -- While the stream is live, the timer read is a safety read at most
      -- every 'Lane.safetyReadInterval'.
      -- The safety read counts only when it started a read. A refused
      -- overview read of live delivery or of a resnapshot is read again
      -- when its backoff ends.
      unless (serviceFaulted state || serviceCredentialRefused state || Lane.refreshPaused now (stateServiceLane state) (stateServiceKeyOutcome state)
          || not (Lane.safetyReadDue (stateServiceDelivery state) (stateServiceSafetyAt state) now)) $ do
        refreshServiceRequest client Lane.AutomaticRefresh
        after <- get
        when (stateRequestSerial after /= stateRequestSerial state) $
          put after {stateServiceSafetyAt = Just now}
      when (not (serviceCredentialRefused state) && Lane.overviewRetryDue (stateServiceOverviewRetry state) now) $ do
        modify (\current -> current {stateServiceOverviewRetry = Lane.overviewRetryStarted <$> stateServiceOverviewRetry current})
        invalidateServiceFetches [Lane.OverviewFetch]
    VtyEvent (Vty.EvResize width height) -> put state {stateTerminalSize = (width,height)}
    VtyEvent (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) -> halt
    -- The Endpoints view takes every key while it is open.
    VtyEvent (Vty.EvKey key modifiers) | stateEndpointsView state -> handleEndpointsKey key modifiers
    -- A question head takes the text entry keys. Ctrl-D sends one answer for
    -- the displayed head. Text keys edit the answer, which is kept as the
    -- draft of the decision, so q does not detach here, and Ctrl-C detaches.
    -- Esc returns to the manager overview and sends nothing. No text key
    -- edits while an answer to this decision is in the command lane.
    VtyEvent key | Just (Service.QuestionHead view _) <- serviceHead state, not (stateKeyHelp state), not (serviceResendConfirm state),
        stateServiceConfirm state == Nothing -> case key of
      Vty.EvKey Vty.KEsc [] -> leaveServiceSelection
      Vty.EvKey Vty.KPageUp [] -> vScrollBy (viewportScroll PersonViewport) (-10)
      Vty.EvKey Vty.KPageDown [] -> vScrollBy (viewportScroll PersonViewport) 10
      Vty.EvKey Vty.KHome [] -> vScrollToBeginning (viewportScroll PersonViewport)
      Vty.EvKey Vty.KEnd [] -> vScrollToEnd (viewportScroll PersonViewport)
      -- Every Ctrl-D has one numbered visible outcome: a start, or a key
      -- outcome that names why nothing was sent, also while an answer to
      -- this decision is in flight ('Service.answerKey').
      Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> case (serviceRunRead state, serviceProfile state) of
        (Just components, Just profile) ->
          case Service.answerKey (serviceAnswerPending state view) (isJust (Lane.installedStale (stateServiceObservation state)))
                 profile components (editorContents (statePersonEditor state)) of
            Left failure -> serviceKeyOutcome False ("answer did not start: " <> failure)
            Right (mutation,observed) -> serviceMutationKey "answer" (beginServiceMutation client mutation (Just observed))
        _ -> serviceKeyOutcome False "answer did not start: the decision is not observed."
      _ | serviceAnswerPending state view -> pure ()
      _ -> handlePersonEditorInput event >> recordServiceDraft
    -- The steer editor below the live monitor takes the text entry keys, so
    -- q edits the text here, and Ctrl-C detaches.
    VtyEvent key | activeLayer state == SteerLayer -> handleServiceSteerKey client event key
    -- The save dialog of the verified result takes the text entry keys, so q
    -- edits the path here, and Ctrl-C detaches.
    VtyEvent key | activeLayer state == SaveLayer -> handleSaveResultKey event key
    -- The path editor of a file capture takes the text entry keys.
    VtyEvent key | activeLayer state == CaptureFileLayer -> handleCaptureFileKey client event key
    -- The export name editor takes the text entry keys.
    VtyEvent key | activeLayer state == ExportLayer -> handleServiceExportKey client event key
    -- The lineage menu takes every key while it is open.
    VtyEvent key | activeLayer state == LineageLayer -> handleServiceLineageKey client event key
    VtyEvent key | InputScreen index <- modelScreen (stateModel state) -> case key of
      -- Ctrl-T captures the exact editor text as raw UTF-8 bytes instead of
      -- sending it as a literal.
      Vty.EvKey (Vty.KChar 't') [Vty.MCtrl] -> captureServiceInput client (TE.encodeUtf8 (editorContents (stateEditor state)))
      -- Ctrl-R removes the supplied value of this input.
      Vty.EvKey (Vty.KChar 'r') [Vty.MCtrl] ->
        case (serviceRequest state,modelWorkflow (stateModel state)) of
          (Just (observed,request),Just descriptor) | Just input <- atMay (workflowInputs descriptor) index ->
            let name = workflowInputName input
                Manager.Readiness _ supplied _ _ = Manager.draftReadiness request
             in serviceMutationKey "remove-input" $
                  if name `elem` map Service.suppliedName supplied
                    then beginServiceMutation client (Service.RemoveInput request name index) (Just observed)
                    else serviceKeyOutcome False ("remove-input did not start: the request supplies no value for " <> name <> ".")
          _ -> serviceKeyOutcome False (Lane.unobservedText "remove-input")
      -- Ctrl-O opens the path editor of a file capture.
      Vty.EvKey (Vty.KChar 'o') [Vty.MCtrl] ->
        put state {stateCaptureFile = True, stateCaptureError = Nothing, stateCaptureEditor = Edit.editorText InputEditor (Just 1) ""}
      Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] ->
        case (serviceRequest state,modelWorkflow (stateModel state)) of
          (Just (observed,request),Just descriptor) | Just input <- atMay (workflowInputs descriptor) index ->
            serviceMutationKey "set-input" $ beginServiceMutation client (Service.SaveLiteral request (workflowInputName input)
              (T.intercalate "\n" (Edit.getEditContents (stateEditor state))) index) (Just observed)
          _ -> serviceKeyOutcome False (Lane.unobservedText "set-input")
      Vty.EvKey Vty.KEsc [] | serviceIdle state -> case serviceRequest state of
        Just (_,request) -> put state {stateModel = (stateModel state) {modelScreen = ServiceRequestScreen request}}
        _ -> pure ()
      _ | serviceIdle state -> handleEditorInput event >> recordServiceDraft
        | otherwise -> pure ()
    VtyEvent (Vty.EvKey key modifiers)
      | key == Vty.KChar 'q' && null modifiers -> halt
      -- An open confirmation of a withdrawal or a discard takes the keys.
      | Just confirmation <- stateServiceConfirm state -> handleServiceConfirm client confirmation key modifiers
      | key == Vty.KChar '?' && null modifiers && not (serviceResendConfirm state) -> put state {stateKeyHelp = not (stateKeyHelp state)}
      -- Under the key help, an approval key on the review still has one
      -- visible outcome, and only Esc closes the help.
      -- A mutation key under the key help is refused visibly.
      | stateKeyHelp state -> case Approval.reviewApprovalKey (modelScreen (stateModel state)) key modifiers of
          Just press -> handleApprovalKey client press
          Nothing -> case serviceNewMutationKey state key modifiers of
            Just (operation,_) -> serviceKeyOutcome False (Lane.keyHelpText operation)
            Nothing -> when (key == Vty.KEsc) (put state {stateKeyHelp = False})
      -- The confirmation of an exact resend has one visible outcome. A
      -- deferral keeps the confirmation open for another explicit y. A key
      -- that asks for a new mutation is decided as everywhere else.
      | serviceResendConfirm state -> case key of
          Vty.KChar 'y' | null modifiers -> case Lane.resendAdmission (stateServiceLane state) of
            Lane.ResendStart attempt -> do
              let ticket = stateRequestSerial state + 1
              put (onLane (\lane -> lane {Lane.laneReadTicket = Nothing}) state) {stateRequestSerial = ticket}
              liftIO (cancelWorker state ServiceReadWork)
              sendServicePending client ticket attempt
            Lane.ResendDeferred -> serviceKeyOutcome True Lane.resendDeferredText
            Lane.ResendUnoffered -> put (onLane (\lane -> lane {Lane.laneResendConfirm = False}) state)
              >> serviceKeyOutcome False Lane.resendUnofferedText
          Vty.KChar 'n' -> put (onLane (\lane -> lane {Lane.laneResendConfirm = False}) state)
          Vty.KEsc -> put (onLane (\lane -> lane {Lane.laneResendConfirm = False}) state)
          _ | Just (operation,start) <- serviceNewMutationKey state key modifiers -> serviceMutationKey operation start
          _ -> pure ()
      -- Every approval-key press on the review has exactly one visible
      -- outcome, whatever the command and read lanes hold.
      | Just press <- Approval.reviewApprovalKey (modelScreen (stateModel state)) key modifiers -> handleApprovalKey client press
      -- Every key that asks for a new mutation has exactly one visible
      -- outcome, including while a command is in progress.
      | Just (operation,start) <- serviceNewMutationKey state key modifiers -> serviceMutationKey operation start
      | serviceSending state -> pure ()
      -- h, O, D, H and Esc move among the workflow browser, the workflow
      -- help, the manager overview, the manager decisions, the History view
      -- and its run detail. Every other browser key keeps its behavior.
      -- Opening the manager decisions or the History view reads its list
      -- through live delivery.
      | Just model <- serviceBrowserKey (Service.workflowHelp <$> atMay (stateServiceWorkflows state) (modelWorkflowIndex (stateModel state)))
          key modifiers (stateModel state) -> do
          put state {stateModel = model, statePaneFocus = if any (`elem` [ServiceOverviewScreen, ServiceDecisionsScreen, ServiceHistoryScreen]) [modelScreen model, modelScreen (stateModel state)]
            then PrimaryPane else statePaneFocus state}
          when (modelScreen model == ServiceDecisionsScreen) (invalidateServiceFetches [Lane.DecisionsFetch])
          when (modelScreen model == ServiceHistoryScreen) (invalidateServiceFetches [Lane.HistoryFetch])
      | null modifiers -> case key of
          Vty.KEsc -> serviceBack state
          Vty.KUp -> serviceMove (-1) state
          Vty.KDown -> serviceMove 1 state
          Vty.KPageUp | liveMonitor state -> scrollFocusedOutput (-10)
                      | otherwise -> vScrollPage (viewportScroll (serviceViewport state)) Up
          Vty.KPageDown | liveMonitor state -> scrollFocusedOutput 10
                        | otherwise -> vScrollPage (viewportScroll (serviceViewport state)) Down
          -- On the live monitor End follows the output tail. Elsewhere, the
          -- run details included, Home and End scroll the same viewport as
          -- PgUp and PgDn.
          -- Home and End on the History view select the first or the last run.
          Vty.KHome | ServiceHistoryScreen <- modelScreen (stateModel state), statePaneFocus state == PrimaryPane ->
            serviceMove (negate (length (serviceHistoryRows state))) state
          Vty.KEnd | ServiceHistoryScreen <- modelScreen (stateModel state), statePaneFocus state == PrimaryPane ->
            serviceMove (length (serviceHistoryRows state)) state
          Vty.KHome | not (liveMonitor state) -> vScrollToBeginning (viewportScroll (serviceViewport state))
          Vty.KEnd | liveMonitor state -> followOutputTail
                   | otherwise -> vScrollToEnd (viewportScroll (serviceViewport state))
          Vty.KLeft -> put state {statePaneFocus = PrimaryPane}
          Vty.KRight -> put state {statePaneFocus = SecondaryPane}
          -- Enter on the manager overview opens the selected row.
          Vty.KEnter | ServiceOverviewScreen <- modelScreen (stateModel state) -> openOverviewRow client
          -- Enter on the manager decisions opens the run of the selected head.
          Vty.KEnter | ServiceDecisionsScreen <- modelScreen (stateModel state) -> openDecisionRow
          -- Enter on the History view opens the read-only detail of the selected run.
          Vty.KEnter | ServiceHistoryScreen <- modelScreen (stateModel state) -> openHistoryRow
          Vty.KEnter | serviceIdle state -> case modelScreen (stateModel state) of
            ServiceProfilesScreen {} -> case selectedServiceProfile (stateModel state) of
              Just profile | Service.profileReadiness profile == "ready", Service.profileRefusal profile == Nothing -> startServiceWorkflows client profile Nothing
              _ -> pure ()
            _ -> pure ()
          Vty.KChar 'd' | ServiceReviewScreen {} <- modelScreen (stateModel state) -> do
            put state {stateConfirmDetails = not (stateConfirmDetails state)}
            vScrollToBeginning (viewportScroll ConfirmDetailsViewport)
          -- In service mode the live monitor sends the run controls, the
          -- redirect digits included, only through 'serviceNewMutationKey'.
          -- Local result keys have no binding here.
          Vty.KChar 'd' | LiveScreen _ <- modelScreen (stateModel state) -> do
            put state {stateRunDetails = not (stateRunDetails state)}
            vScrollToBeginning (viewportScroll FailureViewport)
          Vty.KChar '\t' | liveMonitor state -> togglePaneFocus
          Vty.KChar 'j' | liveMonitor state -> moveOccurrence 1
          Vty.KChar 'k' | liveMonitor state -> moveOccurrence (-1)
          Vty.KChar 'G' | liveMonitor state -> followOutputTail
          Vty.KChar 's' | serviceSavable state -> openSaveResult
          Vty.KChar 'e' | serviceMutable state, ServiceRequestScreen request <- modelScreen (stateModel state), Manager.draftPhase request == "draft" ->
            case modelWorkflow (stateModel state) of
              Just descriptor | not (null (workflowInputs descriptor)) ->
                let model = (stateModel state) {modelScreen = InputScreen 0}
                in put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing (inputValue model)}
              _ -> pure ()
          -- g on the manager overview reads the overview again.
          Vty.KChar 'g' | modelScreen (stateModel state) == ServiceOverviewScreen -> case Lane.laneReadTicket (stateServiceLane state) of
            Nothing -> startServiceOverview client ExplicitOverview
            Just _ -> put state {stateModel = (stateModel state) {modelStatus = "overview read not started: another manager read is in flight; press g again"}}
          -- g on the manager decisions reads the decision heads again.
          Vty.KChar 'g' | modelScreen (stateModel state) == ServiceDecisionsScreen -> case Lane.laneReadTicket (stateServiceLane state) of
            Nothing -> startServiceDecisions client True
            Just _ -> put state {stateModel = (stateModel state) {modelStatus = "decisions read not started: another manager read is in flight; press g again"}}
          -- g on the History view reads the run list again, and on the run
          -- detail it reads the detail again.
          Vty.KChar 'g' | modelScreen (stateModel state) == ServiceHistoryScreen -> case Lane.laneReadTicket (stateServiceLane state) of
            Nothing -> startServiceHistory client True
            Just _ -> put state {stateModel = (stateModel state) {modelStatus = "history read not started: another manager read is in flight; press g again"}}
          Vty.KChar 'g' | ServiceHistoryRunScreen run <- modelScreen (stateModel state) -> case Lane.laneReadTicket (stateServiceLane state) of
            Nothing -> startServiceHistoryDetail client True run
            Just _ -> put state {stateModel = (stateModel state) {modelStatus = "run detail read not started: another manager read is in flight; press g again"}}
          -- r on the run detail retrieves the verified result of its run.
          Vty.KChar 'r' | ServiceHistoryRunScreen run <- modelScreen (stateModel state) -> retrieveHistoryResult client run
          -- l on the live monitor or on a run detail reads the lineage
          -- collection of the run and opens the lineage menu.
          Vty.KChar 'l' | LiveScreen _ <- modelScreen (stateModel state) -> openServiceLineage client
          Vty.KChar 'l' | ServiceHistoryRunScreen _ <- modelScreen (stateModel state) -> openServiceLineage client
          Vty.KChar 'g' -> refreshServiceRequest client Lane.ExplicitRefresh
          Vty.KChar 'x' | Lane.resendOffered (stateServiceLane state) -> put (onLane (\lane -> lane {Lane.laneResendConfirm = True}) state)
          Vty.KChar 'r' | ServiceProfilesScreen {} <- modelScreen (stateModel state) -> startServiceProfiles client
          -- E opens the Endpoints view from every service screen without
          -- text entry, the browser screens and the request screen included.
          -- Tab and the other browser keys keep their behavior.
          Vty.KChar 'E' -> openEndpoints
          _ -> pure ()
    _ -> pure ()
  where
    -- The key that asks for a new mutation on the current screen, with its
    -- operation and the action that starts it.
    serviceNewMutationKey state key modifiers = case (modelScreen (stateModel state), key, modifiers) of
      (BrowserScreen, Vty.KEnter, []) | Just workflow <- atMay (stateServiceWorkflows state) (modelWorkflowIndex (stateModel state)) ->
        Just ("create", do
          put state {stateServiceWorkflow = Just workflow, stateServiceSelected = Nothing, stateServiceObservation = Lane.noObservation,
            stateModel = (stateModel state) {modelInputs = Map.empty, modelWorkflow = Just (Service.workflowDisplay workflow)}}
          beginServiceMutation client (Service.Create workflow) Nothing)
      (ServiceRequestScreen request, Vty.KEnter, []) | Service.requestReady request, Manager.draftPhase request == "draft" ->
        Just ("enqueue", beginServiceMutation client (Service.Enqueue request) (fst <$> serviceRequest state))
      -- W on a draft or queued request and X on the review open a
      -- confirmation. Only its y starts the withdrawal or the discard.
      (ServiceRequestScreen request, Vty.KChar 'W', []) | Manager.draftPhase request `elem` ["draft","queued"] ->
        Just ("withdraw", modify (\current -> current {stateServiceConfirm = Just (Lane.ConfirmWithdraw (Manager.draftId request))}))
      (ServiceReviewScreen preparation _, Vty.KChar 'X', []) ->
        Just ("discard", modify (\current -> current {stateServiceConfirm = Just (Lane.ConfirmDiscard (Manager.preparationId preparation))}))
      -- r at a recovery head retries only through the offer that the
      -- installed control observation presents for that head.
      (LiveScreen _, Vty.KChar 'r', []) | Just (Service.RecoveryHead {}) <- serviceHead state ->
        Just ("retry", case (serviceRunRead state, serviceProfile state) of
          (Just components, Just profile)
            | isJust (Lane.installedStale (stateServiceObservation state)) ->
                serviceKeyOutcome False "retry did not start: the control observation is stale."
            | otherwise -> case Service.retryMutation profile components of
                Left failure -> serviceKeyOutcome False ("retry did not start: " <> failure)
                Right (mutation,observed) -> beginServiceMutation client mutation (Just observed)
          _ -> serviceKeyOutcome False "retry did not start: the decision is not observed.")
      -- f and a at a recovery head choose failover or abandon only through
      -- the choose-recovery offer that the installed control observation
      -- presents for that head, with the decision observation as If-Match.
      (LiveScreen _, Vty.KChar choiceKey, []) | choiceKey `elem` ['f','a'], Just (Service.RecoveryHead {}) <- serviceHead state ->
        let choice = if choiceKey == 'f' then "failover" else "abandon"
         in Just ("choose-recovery", runControl choice $ \profile components -> Service.chooseRecoveryMutation profile components choice)
      -- c opens the cancel confirmation only when the installed control
      -- observation allows a cancel of the displayed run. Only its y starts
      -- the cancel.
      (LiveScreen _, Vty.KChar 'c', []) -> Just ("cancel", case (serviceRunRead state, serviceProfile state) of
        (Just components, Just profile)
          | isJust (Lane.installedStale (stateServiceObservation state)) -> serviceKeyOutcome False "cancel did not start: the control observation is stale."
          | otherwise -> case Service.cancelMutation profile components of
              Left failure -> serviceKeyOutcome False ("cancel did not start: " <> failure <> ".")
              Right _ -> modify (\current -> current {stateServiceConfirm =
                Just (Lane.ConfirmCancel (runIdText (Service.runIdentity (Service.runReadSnapshot components))))})
        _ -> serviceKeyOutcome False "cancel did not start: the run controls are not observed.")
      -- i and b open the steer editor below the live monitor only when the
      -- installed control observation offers a steer with that timing.
      (LiveScreen _, Vty.KChar timingKey, []) | timingKey `elem` ['i','b'] ->
        let timing = if timingKey == 'i' then InterruptNow else NextBoundary
         in Just ("steer", case serviceRunRead state of
              Just (Service.RunRead _ (_,control) _)
                | isJust (Service.steerOffer control (serviceSelectedOccurrence state) (steeringTimingText timing)) ->
                    modify (\current -> current {stateSteerTiming = Just timing, stateControlError = Nothing, stateControlEditor = blankEditor})
                | otherwise -> serviceKeyOutcome False ("steer did not start: the manager offers no " <> steeringTimingText timing <> " steer for this run.")
              Nothing -> serviceKeyOutcome False "steer did not start: the run controls are not observed.")
      -- A digit key 1 to 9 redirects the occurrence that the redirect line
      -- of the live monitor names to the offered target of that digit,
      -- inside the dispatch window or for the attempt in flight. A digit
      -- without an offered target sends nothing and shows a fixed refusal.
      (LiveScreen _, Vty.KChar digit, []) | digit >= '1' && digit <= '9' ->
        Just ("redirect", case (serviceRunRead state, serviceProfile state) of
          (Just components, Just profile)
            | isJust (Lane.installedStale (stateServiceObservation state)) ->
                serviceKeyOutcome False "redirect did not start: the control observation is stale."
            | otherwise -> case Service.redirectMutation profile components (serviceSelectedOccurrence state) (fromEnum digit - fromEnum '1') of
                Left failure -> serviceKeyOutcome False ("redirect did not start: " <> failure <> ".")
                Right (mutation,observed) -> beginServiceMutation client mutation (Just observed)
          _ -> serviceKeyOutcome False "redirect did not start: the run controls are not observed.")
      -- e on the live monitor or on a run detail opens the export name
      -- editor for a run whose snapshot publishes a verified result. Only
      -- Ctrl-D in the editor starts the export.
      (LiveScreen _, Vty.KChar 'e', []) -> Just ("export", openServiceExport)
      (ServiceHistoryRunScreen _, Vty.KChar 'e', []) -> Just ("export", openServiceExport)
      _ -> Nothing
    -- Start a control of the displayed run from the installed composite
    -- read, or show why it did not start.
    runControl choice build = do
      current <- get
      case (serviceRunRead current, serviceProfile current) of
        (Just components, Just profile)
          | isJust (Lane.installedStale (stateServiceObservation current)) ->
              serviceKeyOutcome False (choice <> " did not start: the control observation is stale.")
          | otherwise -> case build profile components of
              Left failure -> serviceKeyOutcome False (choice <> " did not start: " <> failure <> ".")
              Right (mutation,observed) -> beginServiceMutation client mutation (Just observed)
        _ -> serviceKeyOutcome False (choice <> " did not start: the decision is not observed.")
    -- The live monitor without its run details open.
    liveMonitor state = case modelScreen (stateModel state) of
      LiveScreen _ -> not (stateRunDetails state)
      _ -> False
    serviceBack state = case modelScreen (stateModel state) of
      LiveScreen _ | stateRunDetails state -> put state {stateRunDetails = False}
      LiveScreen _ -> leaveServiceSelection
      ServiceRequestScreen _ | serviceIdle state -> leaveServiceSelection
      ServiceProfilesScreen {} -> halt
      InitialLoading -> halt
      ServiceReviewScreen {} | stateConfirmDetails state -> put state {stateConfirmDetails = False}
      BrowserScreen | serviceIdle state -> do
        put (onLane (\lane -> lane {Lane.laneReadTicket = Nothing}) state) {stateServiceWorkflows = [],
          stateModel = initialServiceModel (stateServiceProfiles state), statePaneFocus = PrimaryPane}
        liftIO (cancelWorker state ServiceReadWork)
      _ -> pure ()
    serviceMove delta state = case modelScreen (stateModel state) of
      HelpScreen _ -> vScrollBy (viewportScroll HelpViewport) delta
      FailureScreen _ -> vScrollBy (viewportScroll FailureViewport) delta
      ServiceRequestScreen _ -> vScrollBy (viewportScroll FailureViewport) delta
      ServiceOverviewScreen | statePaneFocus state == PrimaryPane -> do
        put state {stateServiceOverviewFocus = Lane.moveFocus delta (map Service.overviewRowKey (serviceOverviewRows state)) (stateServiceOverviewFocus state)}
        vScrollToBeginning (viewportScroll BrowserDetailViewport)
      ServiceDecisionsScreen | statePaneFocus state == PrimaryPane -> do
        put state {stateServiceDecisionsFocus = Lane.moveFocus delta (map Service.overviewRowKey (serviceDecisionRows state)) (stateServiceDecisionsFocus state)}
        vScrollToBeginning (viewportScroll BrowserDetailViewport)
      ServiceHistoryScreen | statePaneFocus state == PrimaryPane -> do
        put state {stateServiceHistoryFocus = Lane.moveFocus delta (map Service.overviewRowKey (serviceHistoryRows state)) (stateServiceHistoryFocus state)}
        vScrollToBeginning (viewportScroll BrowserDetailViewport)
      ServiceHistoryRunScreen _ -> vScrollBy (viewportScroll FailureViewport) delta
      ServiceReviewScreen {} | stateConfirmDetails state -> vScrollBy (viewportScroll ConfirmDetailsViewport) delta
      LiveScreen _
        | stateRunDetails state -> vScrollBy (viewportScroll FailureViewport) delta
        | statePaneFocus state == PrimaryPane -> moveOccurrence delta
        | otherwise -> do
            put state {stateOutputFollow = False}
            vScrollBy (viewportScroll OutputViewport) delta
      _ | statePaneFocus state == SecondaryPane -> vScrollBy (viewportScroll BrowserDetailViewport) delta
        | otherwise -> do
            put state {stateModel = moveSelection delta (stateModel state)}
            vScrollToBeginning (viewportScroll BrowserDetailViewport)
    serviceViewport state = case modelScreen (stateModel state) of
      HelpScreen _ -> HelpViewport
      FailureScreen _ -> FailureViewport
      ServiceRequestScreen _ -> FailureViewport
      ServiceHistoryRunScreen _ -> FailureViewport
      ServiceReviewScreen {} -> ConfirmDetailsViewport
      LiveScreen _ -> FailureViewport
      _ | statePaneFocus state == SecondaryPane -> BrowserDetailViewport
        | otherwise -> BrowserListViewport

blankEditor :: Edit.Editor Text Name
blankEditor = Edit.editorText InputEditor Nothing ""

-- | One key while a confirmation of a withdrawal or a discard is open. y
-- closes it and decides the mutation once with 'serviceMutationKey'. The
-- mutation starts only for the resource that the key named, while that
-- resource is still displayed and installed, with the installed observation
-- as its precondition. n and Esc close the confirmation with a key outcome,
-- and every other key does nothing.
handleServiceConfirm :: Manager.Client -> Lane.Confirmation -> Vty.Key -> [Vty.Modifier] -> EventM Name AppState ()
handleServiceConfirm client confirmation key modifiers = case key of
  Vty.KChar 'y' | null modifiers -> do
    modify (\state -> state {stateServiceConfirm = Nothing})
    serviceMutationKey operation $ do
      state <- get
      case (confirmation, modelScreen (stateModel state), serviceRequest state, servicePreparation state) of
        (Lane.ConfirmWithdraw ident, ServiceRequestScreen shown, Just (observed,request), _)
          | Manager.draftId shown == ident, Manager.draftId request == ident, Manager.draftPhase request `elem` ["draft","queued"] ->
              beginServiceMutation client (Service.Withdraw request) (Just observed)
        (Lane.ConfirmDiscard ident, ServiceReviewScreen displayed _, Just (_,request), Just (observed,preparation))
          | Manager.preparationId displayed == ident, Manager.preparationId preparation == ident ->
              beginServiceMutation client (Service.Discard request preparation) (Just observed)
        -- The cancel starts from the control observation of the displayed
        -- run that is installed when y is pressed.
        (Lane.ConfirmCancel ident, LiveScreen shown, _, _)
          | runIdText shown == ident, Just components <- serviceRunRead state, Just profile <- serviceProfile state,
            Nothing <- Lane.installedStale (stateServiceObservation state),
            Right (mutation,observed) <- Service.cancelMutation profile components,
            Service.controlRun (snd (Service.runReadControl components)) == ident ->
              beginServiceMutation client mutation (Just observed)
        _ -> serviceKeyOutcome False (Lane.confirmChangedText operation)
  Vty.KChar 'n' | null modifiers -> closed
  Vty.KEsc -> closed
  _ -> pure ()
  where
    operation = Lane.confirmationOperation confirmation
    closed = modify (\state -> state {stateServiceConfirm = Nothing}) >> serviceKeyOutcome False (Lane.confirmCancelledText operation)

-- | One key in the steer editor below the live monitor of a service run.
-- Esc closes the editor. Ctrl-D builds the steer from the installed control
-- observation, the selected occurrence, the timing of the editor and its
-- text, and decides it once with 'serviceMutationKey'. A started steer
-- closes the editor. A steer that the manager no longer offers, or an empty
-- text, keeps the editor open with a numbered key outcome. Every other key
-- edits the text.
handleServiceSteerKey :: Manager.Client -> BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleServiceSteerKey client original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateSteerTiming = Nothing, stateControlError = Nothing})
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> serviceMutationKey "steer" $ do
    state <- get
    let text = T.intercalate "\n" (Edit.getEditContents (stateControlEditor state))
    case (stateSteerTiming state, serviceRunRead state, serviceProfile state) of
      (Just timing, Just components, Just profile)
        | isJust (Lane.installedStale (stateServiceObservation state)) ->
            serviceKeyOutcome False "steer did not start: the control observation is stale."
        | otherwise -> case Service.steerMutation profile components (serviceSelectedOccurrence state) (steeringTimingText timing) text of
            Left failure -> serviceKeyOutcome False ("steer did not start: " <> failure <> ".")
            Right (mutation,observed) -> do
              put state {stateSteerTiming = Nothing, stateControlError = Nothing}
              beginServiceMutation client mutation (Just observed)
      _ -> serviceKeyOutcome False "steer did not start: the run controls are not observed."
  _ -> handleControlEditorInput original

-- | The occurrence that the live monitor selects in the installed run.
serviceSelectedOccurrence :: AppState -> Maybe OccurrenceId
serviceSelectedOccurrence state =
  snapshotOccurrenceId <$> (modelSnapshot (stateModel state) >>= \snapshot -> selectedOccurrence snapshot (stateRunView state))

-- | Change only the client profiles of the service backend.
onEndpoints :: (Lane.Endpoints -> Lane.Endpoints) -> AppState -> AppState
onEndpoints change state = case stateBackend state of
  ServiceBackend client endpoints -> state {stateBackend = ServiceBackend client (change endpoints)}
  LocalBackend {} -> state

-- | Open the Endpoints view with the active profile selected.
openEndpoints :: EventM Name AppState ()
openEndpoints = modify $ \state ->
  (onEndpoints (\endpoints -> endpoints {Lane.endpointsCursor = Lane.endpointsActive endpoints}) state)
    {stateEndpointsView = True, stateModel = (stateModel state) {modelStatus = "manager endpoints: Enter connects the selected profile"}}

-- | One key in the Endpoints view. Esc returns to the screen below, Up and
-- Down select a profile, and Enter connects the selected profile in a worker.
-- The active session continues until that connection succeeds.
handleEndpointsKey :: Vty.Key -> [Vty.Modifier] -> EventM Name AppState ()
handleEndpointsKey key modifiers = do
  state <- get
  case (key, modifiers, stateBackend state) of
    (Vty.KEsc, [], _) -> put state {stateEndpointsView = False}
    (Vty.KChar 'q', [], _) -> halt
    (Vty.KUp, [], _) -> put (onEndpoints (Lane.moveEndpoint (-1)) state)
    (Vty.KDown, [], _) -> put (onEndpoints (Lane.moveEndpoint 1) state)
    (Vty.KEnter, [], ServiceBackend client endpoints) -> do
      let ticket = stateRequestSerial state + 1
      case Lane.beginSwitch ticket endpoints of
        (Lane.SwitchRefused reason, _) -> put state {stateModel = (stateModel state) {modelStatus = reason}}
        (Lane.SwitchStart profile, next) -> do
          put state {stateBackend = ServiceBackend client next, stateRequestSerial = ticket,
            stateModel = (stateModel state) {modelStatus = "connecting endpoint " <> T.pack (show (Lane.endpointsCursor next + 1))}}
          liftIO . startWorker state ServiceConnectWork $
            Lane.serviceCall (Service.connectEndpoint profile) >>= writeBChan (stateChannel state) . EndpointConnected ticket
    _ -> pure ()

-- | Complete the connection with this ticket. A failure keeps the active
-- session and shows the fixed reason. A success cancels the read, send and
-- preparation workers of the earlier session, closes it and clears every
-- observation, selection, retained result and settled command. The command
-- that the earlier session leaves unresolved stays listed for its profile,
-- and the new session never sends it. The new session then loads the
-- manager profiles.
handleEndpointConnected :: Int -> Lane.CallOutcome (Manager.Client, Service.Endpoint) -> EventM Name AppState ()
handleEndpointConnected ticket outcome = do
  state <- get
  case stateBackend state of
    LocalBackend {} -> pure ()
    ServiceBackend earlier endpoints ->
      case Lane.switchStep ticket outcome (Lane.unresolvedCommands (stateServiceLane state)) endpoints of
        (Lane.SwitchStale session, _) -> liftIO (mapM_ Manager.closeClient session)
        (Lane.SwitchFailed reason, next) -> put state {stateBackend = ServiceBackend earlier next,
          stateModel = (stateModel state) {modelStatus = "endpoint switch failed: " <> reason <> "; the active endpoint is unchanged"}}
        (Lane.SwitchConnected client, next) -> do
          liftIO $ do
            mapM_ (cancelWorker state) [ServiceReadWork, ServicePrepareWork, ServiceSendWork, ServiceEventsWork]
            atomically $ do
              writeTVar (sinkInvalidated (stateServiceSink state)) Lane.noInvalidations
              writeTVar (sinkDelivery (stateServiceSink state)) Lane.DeliveryIdle
            Manager.closeClient earlier
            writeIORef (stateServiceSession state) (Just client)
            writeIORef (stateServiceUncertainExit state) (any (not . null . Lane.slotUnresolved) (Lane.endpointsSlots next))
          put (clearServiceSession state) {stateBackend = ServiceBackend client next}
          startServiceProfiles client
          modify $ \current -> current {stateModel = (stateModel current)
            {modelStatus = "endpoint " <> T.pack (show (Lane.endpointsActive next + 1)) <> " active; the earlier selection and observations are cleared"}}

-- | The state of a new service session: no read, command, observation,
-- selection, approval, receipt, retained result or saved result, and the
-- loading screen.
clearServiceSession :: AppState -> AppState
clearServiceSession state =
  state
    { stateServiceLane = Lane.sessionLane,
      stateServiceProfiles = [],
      stateServiceWorkflows = [],
      stateServiceWorkflow = Nothing,
      stateServiceSelected = Nothing,
      stateServiceObservation = Lane.noObservation,
      stateServiceOverview = Lane.noObservation,
      stateServiceOverviewFocus = Lane.noFocus,
      stateServiceDecisions = Lane.noObservation,
      stateServiceDecisionsFocus = Lane.noFocus,
      stateServiceHistory = Lane.noObservation,
      stateServiceHistoryFocus = Lane.noFocus,
      stateServiceHistoryDetail = Lane.noObservation,
      stateServiceDrafts = Lane.noDrafts,
      stateServiceCaptures = Map.empty,
      stateServiceDelivery = Lane.DeliveryIdle,
      stateServiceReach = Lane.Reachable,
      stateServiceFetches = Lane.noFetches,
      stateServiceSafetyAt = Nothing,
      stateServiceOverviewRetry = Nothing,
      stateServiceApproval = Nothing,
      stateServiceApprovalStatus = Nothing,
      stateServiceLastReceipt = Nothing,
      stateServiceControlOutcome = Nothing,
      stateServiceExport = Nothing,
      stateServiceLineage = Nothing,
      stateServiceApprovalPress = Nothing,
      stateServiceNotice = Nothing,
      stateServiceKeyOutcome = Nothing,
      stateServiceConfirm = Nothing,
      stateServiceResults = Lane.noRetrievals,
      stateServiceSaved = Nothing,
      stateConfirmDetails = False,
      stateRunDetails = False,
      stateKeyHelp = False,
      stateSaveResult = False,
      stateSaveError = Nothing,
      stateCaptureFile = False,
      stateCaptureEditor = blankEditor,
      stateCaptureError = Nothing,
      stateExportRun = Nothing,
      stateExportEditor = blankEditor,
      stateExportError = Nothing,
      stateLineageMenu = Nothing,
      stateLineageEditor = blankEditor,
      stateRunView = emptyRunView,
      statePaneFocus = PrimaryPane,
      stateOutputFollow = True,
      stateEditor = blankEditor,
      statePersonEditor = blankEditor,
      stateSaveEditor = blankEditor,
      stateModel = (initialModel [] [] (Left "catalogue is loading")) {modelScreen = InitialLoading, modelStatus = "loading manager profiles"}
    }

-- | Start a service worker whose result carries the generation of the
-- active session, so a result that arrives after a switch is not handled.
startServiceWorker :: AppState -> Work -> IO ServiceEvent -> IO ()
startServiceWorker state work action = case stateBackend state of
  ServiceBackend _ endpoints ->
    startWorker state work (action >>= writeBChan (stateChannel state) . ServiceResult . Lane.Stamped (Lane.endpointsGeneration endpoints))
  LocalBackend {} -> pure ()

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
    ServiceBackend client _ -> startServiceProfiles client

draw :: AppState -> [Widget Name]
draw = drawPresentation . toPresentation

toPresentation :: AppState -> Presentation
toPresentation state =
  (emptyPresentation (stateModel state))
    { presentationConfig = case stateBackend state of LocalBackend config _ -> Just config; ServiceBackend {} -> Nothing,
      presentationService = case stateBackend state of ServiceBackend {} -> True; LocalBackend {} -> False,
      presentationServiceEndpoint = case stateBackend state of ServiceBackend _ endpoints -> Lane.activeIdentity endpoints; LocalBackend {} -> Nothing,
      presentationServiceDelivery = stateServiceDelivery state,
      presentationServiceReach = stateServiceReach state,
      presentationServiceEndpoints = case stateBackend state of ServiceBackend _ endpoints -> Just endpoints; LocalBackend {} -> Nothing,
      presentationServiceMutation = Lane.mutationNotice (stateServiceLane state),
      presentationServiceResendConfirm = serviceResendConfirm state,
      presentationServiceConfirm = Lane.confirmationLines <$> stateServiceConfirm state,
      presentationServiceApproval = case stateServiceApproval state of
        Just (Service.Approve approved _,_,_) | fmap (Manager.draftId . snd) (serviceRequest state) /= Just (Manager.draftId approved) -> Nothing
        _ -> stateServiceApprovalStatus state,
      presentationServiceFault = serviceFaulted state,
      presentationServiceCredentialRefused = serviceCredentialRefused state,
      presentationServiceKeyOutcome = stateServiceKeyOutcome state,
      presentationServiceOverview = let installed = stateServiceOverview state in
        OverviewView (serviceOverviewRows state) (Lane.focusedIndex (map Service.overviewRowKey (serviceOverviewRows state)) (stateServiceOverviewFocus state))
          (Service.overviewStatus (shownStale installed) (Service.overviewRows <$> Lane.installedRead installed)),
      presentationServiceDecisions = let installed = stateServiceDecisions state in
        OverviewView (serviceDecisionRows state) (Lane.focusedIndex (map Service.overviewRowKey (serviceDecisionRows state)) (stateServiceDecisionsFocus state))
          (Service.decisionsStatus (shownStale installed) (Service.decisionRows <$> Lane.installedRead installed)),
      presentationServiceHistory = let installed = stateServiceHistory state in
        OverviewView (serviceHistoryRows state) (Lane.focusedIndex (map Service.overviewRowKey (serviceHistoryRows state)) (stateServiceHistoryFocus state))
          (Service.historyStatus (shownStale installed) (Lane.installedRead installed)),
      presentationServiceHistoryDetail = case modelScreen (stateModel state) of
        ServiceHistoryRunScreen run ->
          let installed = stateServiceHistoryDetail state
              detail = mfilter ((== run) . Service.historyDetailRun) (Lane.installedRead installed)
          in [case (shownStale installed, detail) of
                (Nothing, Nothing) -> "Run detail: reading run " <> run
                (Nothing, Just _) -> "Run detail: current"
                (Just code, Just _) -> "Run detail: stale (" <> code <> "); the last complete detail is retained"
                (Just code, Nothing) -> "Run detail: refused (" <> code <> "); no complete detail is installed"]
            <> maybe [] (\shown -> Service.historyDetailLines shown (Lane.retrievalShown run (stateServiceResults state))) detail
            <> historyOutcomeLines state run
        _ -> [],
      presentationServiceObservation = let installed = stateServiceObservation state in
        Service.observationLines (Lane.refreshPaused (stateNow state) (stateServiceLane state) (stateServiceKeyOutcome state))
          (shownStale installed) (isJust (Lane.installedRead installed)) (serviceRun state),
      presentationServiceRun = serviceRun state,
      presentationServiceRecoveryOffers = case (serviceHead state, serviceRunRead state) of
        (Just (Service.RecoveryHead view _ _), Just (Service.RunRead _ (_,control) _)) ->
          ["retry" | isJust (Service.retryOffer control view)]
            <> [choice | choice <- ["failover","abandon"], isJust (Service.recoveryOffer control view choice)]
        _ -> [],
      presentationServiceRunKeys = case (modelScreen (stateModel state), serviceRunRead state) of
        (LiveScreen _, Just (Service.RunRead _ (_,control) _)) ->
          ["c CANCEL" | Service.cancelOffered control]
            <> ["i/b STEER" | any (isJust . Service.steerOffer control Nothing) ["interrupt-now","next-boundary"]]
            <> ["1-9 REDIRECT" | isJust (Service.redirectOffer control Nothing)]
        _ -> [],
      presentationServiceControlLines = Service.controlLines (stateServiceControlOutcome state) (serviceRun state)
        <> case (modelScreen (stateModel state), serviceRunRead state) of
          (LiveScreen _, Just (Service.RunRead snapshot (_,control) _)) -> Service.redirectLines control snapshot (serviceSelectedOccurrence state)
          _ -> [],
      presentationServiceResultLines = case serviceRun state of
        Just run -> Service.resultLines run (Lane.retrievalShown (runIdText (Service.runIdentity run)) (stateServiceResults state))
          <> [line | Just (ident, line) <- [stateServiceSaved state], ident == runIdText (Service.runIdentity run)]
          <> serviceExportLines state (runIdText (Service.runIdentity run))
          <> serviceLineageLines state (runIdText (Service.runIdentity run))
        Nothing -> [],
      presentationServiceExportable = either (const False) (const True) (serviceExportSource state),
      presentationExportError = stateExportError state,
      presentationExportRun = snd <$> stateExportRun state,
      presentationServiceLineageOffered = either (const False) (const True) (serviceLineageSource state),
      presentationLineageRun = Service.lineageRun . Service.menuCollection <$> stateLineageMenu state,
      presentationLineageMode = Service.menuMode <$> stateLineageMenu state,
      presentationLineageEligible = maybe [] (Service.lineageEligible . Service.menuCollection) (stateLineageMenu state),
      presentationLineageLines = maybe [] Service.lineageMenuLines (stateLineageMenu state),
      presentationLineageError = stateLineageMenu state >>= Service.menuError,
      presentationServiceSavable = serviceSavable state,
      presentationServiceRequestLines = maybe [] (serviceRequestLines . snd) (serviceRequest state),
      presentationServiceApprovalOffered = case modelScreen (stateModel state) of
        ServiceReviewScreen displayed tag ->
          Approval.approvalOffered (serviceScopes state) (serviceReviewView state) (stateServiceLane state) (serviceReviewCheck state displayed tag)
        _ -> False,
      presentationServiceNotice = stateServiceNotice state,
      presentationEditor = currentEditor state,
      presentationRunView = stateRunView state,
      presentationPaneFocus = statePaneFocus state,
      presentationOutputFollow = stateOutputFollow state,
      presentationLayer = activeLayer state,
      presentationExactDetails = stateConfirmDetails state,
      presentationRunning = isJust (stateRunning state),
      presentationNoColor = stateNoColor state,
      presentationPersonPrompt = case serviceHead state of
        Just (Service.QuestionHead _ prompt) -> Just prompt
        _ -> snd <$> statePersonPrompt state,
      presentationPersonSubmitted = case serviceHead state of
        Just (Service.QuestionHead view _) -> serviceAnswerPending state view
        _ -> statePersonSubmitted state,
      presentationPersonError = statePersonError state,
      presentationRecovery = case serviceHead state of
        Just (Service.RecoveryHead _ occurrence recovery) -> Just (occurrence, recovery)
        _ -> queuedRecovery state,
      presentationSteerTiming = stateSteerTiming state,
      presentationControlError = stateControlError state,
      presentationSaveError = stateSaveError state,
      presentationCaptureError = stateCaptureError state,
      presentationFinalResult = stateFinalResult state,
      presentationFinalLoading = stateFinalLoading state,
      presentationShowResult = stateShowResult state,
      presentationElapsed = elapsedText state,
      presentationRunPersona = stateRunPersona state,
      presentationRunRealization = stateRunRealization state,
      presentationSpinner = spinnerFrame (stateNow state)
    }
  where
    -- While the manager is unreachable, every retained observation is shown
    -- as stale.
    shownStale :: Lane.Installed a -> Maybe Text
    shownStale = Lane.shownStale (stateServiceReach state) . Lane.installedStale

currentEditor :: AppState -> Edit.Editor Text Name
currentEditor state = case activeLayer state of
  PersonLayer -> statePersonEditor state
  SteerLayer -> stateControlEditor state
  SaveLayer -> stateSaveEditor state
  ExportLayer -> stateExportEditor state
  LineageLayer -> stateLineageEditor state
  CaptureFileLayer -> stateCaptureEditor state
  FilterLayer -> stateFilterEditor state
  _ -> stateEditor state

activeLayer :: AppState -> ActiveLayer
activeLayer state
  | stateEndpointsView state = EndpointsLayer
  | stateKeyHelp state = KeyHelpLayer
  | Just decision <- serviceHead state = case decision of
      Service.QuestionHead {} -> PersonLayer
      Service.RecoveryHead {} | stateRunDetails state -> RunDetailsLayer
                              | otherwise -> RecoveryLayer
  | stateCancelConfirm state = CancelLayer
  | Just decision <- listToMaybe (stateMandatoryDecisions state), mandatoryKind decision == MandatoryPerson = PersonLayer
  | Just decision <- listToMaybe (stateMandatoryDecisions state), mandatoryKind decision == MandatoryRecovery = RecoveryLayer
  | isJust (stateSteerTiming state) = SteerLayer
  | stateSaveResult state = SaveLayer
  | isJust (stateExportRun state) = ExportLayer
  | isJust (stateLineageMenu state) = LineageLayer
  | stateCaptureFile state = CaptureFileLayer
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
    ServiceBackend client _ -> handleServiceEvent client event

handleLocalEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleLocalEvent event = case event of
  AppEvent (ServiceResult _) -> pure ()
  AppEvent (EndpointConnected _ _) -> pure ()
  AppEvent ServiceWakeup -> pure ()
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
  -- A new save, export or lineage outcome on the read-only run detail
  -- scrolls the detail to its end, where those outcome lines are, so that
  -- the outcome of the key is visible also when the detail is taller than
  -- the main area, as it is at 80x24.
  case newScreen of
    ServiceHistoryRunScreen run
      | oldScreen == newScreen, historyOutcomeLines after run /= historyOutcomeLines before run, not (null (historyOutcomeLines after run)) ->
          vScrollToEnd (viewportScroll FailureViewport)
    _ -> pure ()
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
    EndpointsLayer -> pure ()
    KeyHelpLayer -> handleKeyHelp key
    CancelLayer -> handleCancelKey key
    PersonLayer -> handlePersonKey original key
    RecoveryLayer -> maybe (pure ()) (\decision -> handleRecoveryKey (mandatoryOccurrence decision) key) (listToMaybe (stateMandatoryDecisions state))
    SteerLayer -> handleSteerKey original key
    SaveLayer -> handleSaveResultKey original key
    -- Only service mode opens the path editor of a file capture and the
    -- export name editor.
    CaptureFileLayer -> pure ()
    ExportLayer -> pure ()
    LineageLayer -> pure ()
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

-- | Start the capture of these exact bytes for the input that the input
-- editor shows. The key has one lane outcome: a start or a key outcome.
captureServiceInput :: Manager.Client -> BS.ByteString -> EventM Name AppState ()
captureServiceInput client bytes = do
  state <- get
  case (serviceRequest state, modelWorkflow (stateModel state), modelScreen (stateModel state)) of
    (Just (observed,request), Just descriptor, InputScreen index) | Just input <- atMay (workflowInputs descriptor) index ->
      serviceMutationKey "capture" $ beginServiceMutation client (Service.Capture request (workflowInputName input) bytes index) (Just observed)
    _ -> serviceKeyOutcome False (Lane.unobservedText "capture")

-- | The path editor of a file capture. Ctrl-D reads the named local file
-- with 'Service.readCaptureFile' and captures its exact bytes. A refused
-- read keeps the editor open with its reason and sends nothing. Esc closes
-- the editor.
handleCaptureFileKey :: Manager.Client -> BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleCaptureFileKey client original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateCaptureFile = False, stateCaptureError = Nothing})
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> do
    state <- get
    let path = T.unpack (editorContents (stateCaptureEditor state))
    outcome <- liftIO (Service.readCaptureFile (Service.captureLimit client) path)
    case outcome of
      Left refusal -> put state {stateCaptureError = Just refusal}
      Right bytes -> do
        put state {stateCaptureFile = False, stateCaptureError = Nothing}
        captureServiceInput client bytes
  _ -> do
    state <- get
    (editor, ()) <- nestEventM (stateCaptureEditor state) (Edit.handleEditorEvent original)
    if BS.length (TE.encodeUtf8 (editorContents editor)) <= 4096
      then put state {stateCaptureEditor = editor, stateCaptureError = Nothing}
      else put state {stateCaptureError = Just "the file path exceeds 4096 UTF-8 bytes"}

-- | The profile and the run whose verified result @e@ exports from the
-- shown screen, or the reason why it exports nothing: the installed run of
-- the live monitor, or the managed run of the installed run detail with the
-- profile that the installed run list names. A legacy entry has no export
-- authority.
serviceExportSource :: AppState -> Either Text (Text, Service.RunObservation)
serviceExportSource state = case modelScreen (stateModel state) of
  LiveScreen _ -> case (serviceRun state, serviceProfile state) of
    (Just run, Just profile) -> (profile, run) <$ Service.exportSource run
    _ -> Left "the run is not observed"
  ServiceHistoryRunScreen shown ->
    case (Lane.installedRead (stateServiceHistoryDetail state), find ((== shown) . Service.runItemId) (fromMaybe [] (Lane.installedRead (stateServiceHistory state)))) of
      (Just (Service.ManagedDetail run), Just item) | runIdText (Service.runIdentity run) == shown ->
        (Service.runItemProfile item, run) <$ Service.exportSource run
      (Just (Service.LegacyDetail item), _) | Service.runItemId item == shown -> Left "a legacy entry has no export authority"
      _ -> Left "the run detail is not observed"
  _ -> Left "no run is shown"

-- | Open the export name editor for the run that the screen shows, or show
-- why @e@ exports nothing as a numbered key outcome.
openServiceExport :: EventM Name AppState ()
openServiceExport = do
  state <- get
  case serviceExportSource state of
    Left reason -> serviceKeyOutcome False ("export did not start: " <> reason <> ".")
    Right (profile, run) -> put state {stateExportRun = Just (profile, runIdText (Service.runIdentity run)), stateExportError = Nothing,
      stateExportEditor = Edit.editorText InputEditor (Just 1) "", stateModel = (stateModel state) {modelStatus = "export: type a new export name"}}

-- | The export name editor. Ctrl-D starts the export of the verified result
-- of its run under the typed name ('Service.exportMutation') through the
-- command lane. A refused name, or a screen that no longer shows that run,
-- keeps the editor open with its reason and sends nothing. Esc closes the
-- editor and sends nothing.
handleServiceExportKey :: Manager.Client -> BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleServiceExportKey client original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateExportRun = Nothing, stateExportError = Nothing})
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> serviceMutationKey "export" $ do
    state <- get
    case serviceExportSource state of
      Right (profile, run) | stateExportRun state == Just (profile, runIdText (Service.runIdentity run)) ->
        case Service.exportMutation profile run (editorContents (stateExportEditor state)) of
          Left reason -> put state {stateExportError = Just reason}
          Right mutation -> do
            put state {stateExportRun = Nothing, stateExportError = Nothing}
            beginServiceMutation client mutation Nothing
      Right _ -> put state {stateExportError = Just "the screen no longer shows the run of this export"}
      Left reason -> put state {stateExportError = Just reason}
  _ -> do
    state <- get
    (editor, ()) <- nestEventM (stateExportEditor state) (Edit.handleEditorEvent original)
    put state {stateExportEditor = editor, stateExportError = Nothing}

-- | The profile and the run whose lineage menu @l@ opens from the shown
-- screen, or the reason why it opens nothing: the installed run of the live
-- monitor, or the managed run of the installed run detail with the profile
-- that the installed run list names. A legacy entry has no lineage
-- authority.
serviceLineageSource :: AppState -> Either Text (Text, Service.RunObservation)
serviceLineageSource state = case modelScreen (stateModel state) of
  LiveScreen _ -> case (serviceRun state, serviceProfile state) of
    (Just run, Just profile) -> Right (profile, run)
    _ -> Left "the run is not observed"
  ServiceHistoryRunScreen shown ->
    case (Lane.installedRead (stateServiceHistoryDetail state), find ((== shown) . Service.runItemId) (fromMaybe [] (Lane.installedRead (stateServiceHistory state)))) of
      (Just (Service.ManagedDetail run), Just item) | runIdText (Service.runIdentity run) == shown -> Right (Service.runItemProfile item, run)
      (Just (Service.LegacyDetail item), _) | Service.runItemId item == shown -> Left "a legacy entry has no lineage authority"
      _ -> Left "the run detail is not observed"
  _ -> Left "no run is shown"

-- | Read the first page of the lineage collection of the run that the
-- screen shows, which opens the lineage menu ('ServiceLineageMenuReady'),
-- or show why @l@ opens nothing. The explicit key ends a read in flight, as
-- the confirmation of an exact resend does, and live delivery fetches that
-- read again.
openServiceLineage :: Manager.Client -> EventM Name AppState ()
openServiceLineage client = do
  state <- get
  case serviceLineageSource state of
    Left reason -> put state {stateModel = (stateModel state) {modelStatus = "lineage menu not opened: " <> reason}}
    Right (profile, run) -> do
      let ident = runIdText (Service.runIdentity run)
      put (onLane (\lane -> lane {Lane.laneReadTicket = Nothing}) state)
      liftIO (cancelWorker state ServiceReadWork)
      startServiceRead Lane.SingleResourceRead "reading the lineage collection" $ \ticket ->
        ServiceLineageMenuReady ticket profile ident <$> Lane.serviceCall (Service.observeLineageCollection client ident)

-- | The lineage menu. On the choice of the operation, r and s send a
-- restart or a resume, and f opens the fork edits. On the fork edits,
-- Up/Down select an occurrence, d drops its answer, k keeps it, Enter opens
-- the replacement answer editor, and Ctrl-D sends the fork with its edits.
-- In the replacement answer editor, Ctrl-D converts the text by the code of
-- the occurrence ('Service.forkSetReplacement'). An operation that the
-- lineage collection does not list as eligible is refused here, and nothing
-- is sent. Esc closes the editor, leaves the fork edits, or closes the menu.
handleServiceLineageKey :: Manager.Client -> BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleServiceLineageKey client original key = do
  state <- get
  case stateLineageMenu state of
    Nothing -> pure ()
    Just menu -> do
      let set :: Service.LineageMenu Manager.Observed -> EventM Name AppState ()
          set changed = put state {stateLineageMenu = Just changed}
          count = length (Service.menuTargets menu)
      case (Service.menuMode menu, key) of
        (Service.LineageChoosing, Vty.EvKey Vty.KEsc []) -> put state {stateLineageMenu = Nothing}
        (Service.LineageChoosing, Vty.EvKey (Vty.KChar 'r') []) -> sendLineage Service.RestartChoice
        (Service.LineageChoosing, Vty.EvKey (Vty.KChar 's') []) -> sendLineage Service.ResumeChoice
        (Service.LineageChoosing, Vty.EvKey (Vty.KChar 'f') []) ->
          case Service.lineageMutation Service.observedBinding menu (Service.lineageForkChoice menu) of
            Left reason -> set menu {Service.menuError = Just ("fork did not start: " <> reason)}
            Right _ -> set menu {Service.menuMode = Service.LineageForking, Service.menuError = Nothing}
        (Service.LineageForking, Vty.EvKey Vty.KEsc []) -> set menu {Service.menuMode = Service.LineageChoosing, Service.menuError = Nothing}
        (Service.LineageForking, Vty.EvKey Vty.KUp []) -> set menu {Service.menuFocus = max 0 (Service.menuFocus menu - 1)}
        (Service.LineageForking, Vty.EvKey Vty.KDown []) -> set menu {Service.menuFocus = max 0 (min (count - 1) (Service.menuFocus menu + 1))}
        (Service.LineageForking, Vty.EvKey (Vty.KChar 'd') []) -> set (Service.forkToggleDrop menu)
        (Service.LineageForking, Vty.EvKey (Vty.KChar 'k') []) -> set (Service.forkKeep menu)
        (Service.LineageForking, Vty.EvKey Vty.KEnter []) -> case Service.forkFocused menu of
          Nothing -> set menu {Service.menuError = Just "no occurrence is selected"}
          Just target ->
            let shown = case Map.lookup (Service.forkOccurrence target) (Service.menuEdits menu) of
                  Just (ReplaceAnswer _ (String text)) | Service.forkCode target == "text" -> text
                  Just (ReplaceAnswer _ value) -> TE.decodeUtf8 (BL.toStrict (encode value))
                  _ -> ""
             in put state {stateLineageMenu = Just menu {Service.menuMode = Service.LineageReplacing, Service.menuError = Nothing},
                  stateLineageEditor = Edit.editorText InputEditor Nothing shown}
        (Service.LineageForking, Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl]) -> sendLineage (Service.lineageForkChoice menu)
        (Service.LineageReplacing, Vty.EvKey Vty.KEsc []) -> set menu {Service.menuMode = Service.LineageForking, Service.menuError = Nothing}
        (Service.LineageReplacing, Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl]) ->
          set (Service.forkSetReplacement (editorContents (stateLineageEditor state)) menu)
        (Service.LineageReplacing, _) -> do
          (editor, ()) <- nestEventM (stateLineageEditor state) (Edit.handleEditorEvent original)
          put state {stateLineageEditor = editor, stateLineageMenu = Just menu {Service.menuError = Nothing}}
        _ -> pure ()
  where
    -- Send the lineage request of the menu for this operation through the
    -- command lane, with the observation of the lineage collection as its
    -- precondition. A refusal keeps the menu open with its reason.
    sendLineage choice = serviceMutationKey (Service.lineageChoiceName choice) $ do
      current <- get
      case stateLineageMenu current of
        Nothing -> pure ()
        Just menu -> case Service.lineageMutation Service.observedBinding menu choice of
          Left reason -> put current {stateLineageMenu = Just menu {Service.menuError = Just (Service.lineageChoiceName choice <> " did not start: " <> reason)}}
          Right (mutation, observed) -> do
            put current {stateLineageMenu = Nothing}
            beginServiceMutation client mutation (Just observed)

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
  case stateBackend state of
    ServiceBackend {} -> saveServiceResult pathText
    LocalBackend {} -> saveLocalResult pathText

-- | Publish the retained verified result bytes of the installed run exactly
-- through 'saveExact'. A refusal keeps the dialog open with its fixed
-- message, and the destination stays as it was.
saveServiceResult :: Text -> EventM Name AppState ()
saveServiceResult pathText = do
  state <- get
  case serviceVerifiedResult state of
    Nothing -> put state {stateSaveError = Just "the verified result is not available"}
    Just (run, result) -> do
      outcome <- liftIO (saveExact (T.unpack pathText) (Service.verifiedBytes result))
      case outcome of
        Left refusal -> put state {stateSaveError = Just (serviceSaveRefusal pathText refusal)}
        Right saved -> put state {stateSaveResult = False, stateSaveError = Nothing,
          stateServiceSaved = Just (run, serviceSavedLine pathText (BS.length (Service.verifiedBytes result)) saved)}

saveLocalResult :: Text -> EventM Name AppState ()
saveLocalResult pathText = do
  state <- get
  case stateFinalResult state of
    Just (Right value) -> do
      result <- liftIO (try @SomeException (saveResultFile (T.unpack pathText) value))
      case result of
        Left failure | Just _ <- fromException @SomeAsyncException failure -> liftIO (throwIO failure)
        Left failure -> put state {stateSaveError = Just (T.pack (displayException failure))}
        Right saved ->
          put
            state
              { stateSaveResult = False,
                stateSaveError = Nothing,
                stateModel = (stateModel state) {modelStatus = "saved verified final result to " <> pathText <> savedLeftoverNote saved}
              }
    _ -> put state {stateSaveError = Just "verified final result is not available"}

-- | Publish the verified final JSON result and a final LF exclusively
-- through 'saveExact'.
saveResultFile :: FilePath -> Value -> IO Saved
saveResultFile path value =
  saveExact path (BL.toStrict (encode value <> "\n")) >>= either (ioError . userError . T.unpack . saveRefusalText) pure

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
notifyFrame channel pending = notifyOnce channel pending FrameReady

-- | Write the event to the Brick channel unless one is pending. The handler
-- of the event clears the pending flag. A full channel takes the event in a
-- detached write, so the notification is never dropped.
notifyOnce :: BChan AppEvent -> TVar Bool -> AppEvent -> IO ()
notifyOnce channel pending event = do
  shouldNotify <- atomically $ do
    already <- readTVar pending
    if already then pure False else writeTVar pending True >> pure True
  when shouldNotify $ do
    written <- writeBChanNonBlocking channel event
    when (not written) (void (forkIO (writeBChan channel event)))

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
