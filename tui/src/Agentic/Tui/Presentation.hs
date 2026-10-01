{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Responsive, pure Brick presentation for the terminal frontend.
module Agentic.Tui.Presentation
  ( Name (..),
    PaneFocus (..),
    ActiveLayer (..),
    Presentation (..),
    OverviewView (..),
    staticPresentation,
    emptyPresentation,
    drawPresentation,
    presentationAttributes,
    confirmationDetails,
    launchReviewAllowed,
    serviceReviewAllowed,
    serviceReviewRows,
    endpointLine,
    endpointsLines,
    serviceRequestLines,
    serviceSaveRefusal,
    serviceSavedLine,
    savedLeftoverNote,
    wrapDisplayLines,
    steeringTimingText,
  )
where

import Agentic.Runtime
  ( CatalogueEntry (..),
    AttemptSnapshot (..),
    OccurrenceState (..),
    DescriptorCapabilities (..),
    ExactPlanSummary (..),
    DispatchSnapshot (..),
    FrontendManifest (..),
    LineageOperation (..),
    OccurrenceId (occurrenceNumber),
    OccurrenceSnapshot (..),
    PlanFold (..),
    RecoveryOption (..),
    RecoverySnapshot (..),
    RunId (runIdText),
    RunRecord (..),
    RunSnapshot (..),
    SteeringTiming (..),
    WorkflowDescriptor (..),
    WorkflowInputDescriptor (..),
    WorkflowInputSource (..),
  )
import Agentic.Tui.Approval (KeyNotice (..), noticeLine, noticeTexts)
import Agentic.Tui.Highlight
import Agentic.Tui.Model
import Agentic.Tui.Person
import Agentic.Tui.RunModel
import Agentic.Tui.Save (SaveRefusal (..), Saved (..))
import Agentic.Tui.Types
import qualified Agentic.Tui.Service as Service
import Agentic.Tui.ServiceLane (Delivery (..), EndpointSlot (..), EndpointState (..), Endpoints (..), KeyOutcome, Reachability (..), deliveryText, internalFaultStatus, keyOutcomeLine,
  reachabilityText)
import qualified Agentic.Manager.Client as Manager
import Brick
import Brick.Widgets.Border (borderWithLabel, hBorder, hBorderWithLabel, vBorder)
import Brick.Widgets.Center (hCenter)
import qualified Brick.Widgets.Edit as Edit
import Data.Aeson (Value (..), encode, toJSON)
import qualified Data.ByteString.Lazy as BL
import Data.Char (isControl, isSpace)
import Data.List (intersperse)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Graphics.Vty as Vty
import System.IO.Error (ioeGetErrorType, isAlreadyExistsError)

-- | Brick identities are distinct for every independently scrolling surface.
data Name
  = BrowserListViewport
  | BrowserDetailViewport
  | HelpViewport
  | TargetViewport
  | ConfirmDetailsViewport
  | OccurrenceViewport
  | OutputViewport
  | PersonViewport
  | RecoveryViewport
  | FailureViewport
  | KeyHelpViewport
  | InputEditor
  deriving (Eq, Ord, Show)

-- | The keyboard focus shared by list/detail and occurrence/output layouts.
data PaneFocus = PrimaryPane | SecondaryPane
  deriving (Eq, Show)

-- | The one visible and input-active layer.
data ActiveLayer
  = -- | The Endpoints view of the service frontend.
    EndpointsLayer
  | KeyHelpLayer
  | CancelLayer
  | PersonLayer
  | RecoveryLayer
  | SteerLayer
  | SaveLayer
    -- | The export name editor of the service frontend.
  | ExportLayer
    -- | The lineage menu of the service frontend.
  | LineageLayer
    -- | The path editor of a file capture over the service input editor.
  | CaptureFileLayer
  | FilterLayer
  | ConfirmDetailsLayer
  | ConfirmLayer
  | RunDetailsLayer
  | ScreenLayer
  deriving (Eq, Show)

-- | Display-only state projected from the process-owning application state.
data Presentation = Presentation
  { presentationModel :: !TuiModel,
    presentationEditor :: !(Edit.Editor Text Name),
    presentationRunView :: !RunView,
    presentationPaneFocus :: !PaneFocus,
    presentationOutputFollow :: !Bool,
    presentationLayer :: !ActiveLayer,
    presentationExactDetails :: !Bool,
    presentationRunning :: !Bool,
    presentationNoColor :: !Bool,
    presentationService :: !Bool,
    -- | The endpoint identity of the service session. The service shell shows
    -- it in its own header row when the terminal has room for that row.
    presentationServiceEndpoint :: !(Maybe Service.Endpoint),
    -- | The delivery state of the event stream of the service session, which
    -- the header row of the screen context shows above the identity row.
    presentationServiceDelivery :: !Delivery,
    -- | Whether the manager answers the reads of the service session. While
    -- it does not, the header row shows @manager unreachable since T@ in
    -- place of the delivery state.
    presentationServiceReach :: !Reachability,
    -- | The client profiles of the service frontend, their connection
    -- states and identities, which the Endpoints view lists.
    presentationServiceEndpoints :: !(Maybe Endpoints),
    -- | Operation, URI, and whether an explicit exact resend is offered.
    presentationServiceMutation :: !(Maybe (Text,Text,Bool)),
    presentationServiceResendConfirm :: !Bool,
    -- | The title and lines of the open confirmation of a withdrawal or a
    -- discard, which the dialog over the screen shows.
    presentationServiceConfirm :: !(Maybe (Text, [Text])),
    presentationServiceApproval :: !(Maybe Text),
    -- | Whether y would approve the exact summary review now, as
    -- 'Agentic.Tui.Approval.approvalOffered' decides. The approval hint is
    -- shown exactly when this holds.
    presentationServiceApprovalOffered :: !Bool,
    -- | The notice of the latest approval-key press, shown in both review
    -- views and in the key help while the review is on the screen.
    presentationServiceNotice :: !(Maybe KeyNotice),
    -- | An internal frontend fault occurred. No mutation starts, no exact
    -- resend is offered, and only read-only actions remain.
    presentationServiceFault :: !Bool,
    -- | The lines that describe the installed request observation, its stale
    -- mark and the published runtime status.
    presentationServiceObservation :: ![Text],
    -- | The lines that name the installed request, its phase and its run.
    -- The live monitor shows them in service mode.
    presentationServiceRequestLines :: ![Text],
    -- | The installed run observation in service mode. The live monitor takes
    -- the published workflow and target label from it, also when the runtime
    -- is absent.
    presentationServiceRun :: !(Maybe Service.RunObservation),
    -- | The recovery choices (@retry@, @failover@, @abandon@) that the
    -- installed control observation offers for the recovery at the head, as
    -- 'Agentic.Tui.Service.retryOffer' and
    -- 'Agentic.Tui.Service.recoveryOffer' decide.
    presentationServiceRecoveryOffers :: ![Text],
    -- | The run keys that the installed control observation offers on the
    -- live monitor: @c CANCEL@, @i/b STEER@ and @1-9 REDIRECT@.
    presentationServiceRunKeys :: ![Text],
    -- | The control line of the installed run, as
    -- 'Agentic.Tui.Service.controlLines' produces it, and on the live
    -- monitor the redirect line, as 'Agentic.Tui.Service.redirectLines'
    -- produces it.
    presentationServiceControlLines :: ![Text],
    -- | The terminal status and verified result lines of the installed run,
    -- as 'Agentic.Tui.Service.resultLines' produces them.
    presentationServiceResultLines :: ![Text],
    -- | Whether s opens the save dialog for the retained verified result
    -- bytes of the installed run.
    presentationServiceSavable :: !Bool,
    -- | Whether e opens the export name editor for the run that the screen
    -- shows.
    presentationServiceExportable :: !Bool,
    -- | The run of the open export name editor, and the refusal of its
    -- latest Ctrl-D.
    presentationExportRun :: !(Maybe Text),
    presentationExportError :: !(Maybe Text),
    -- | Whether l opens the lineage menu for the run that the screen shows.
    presentationServiceLineageOffered :: !Bool,
    -- | The open lineage menu: its parent run, the part that has the keys,
    -- its eligible operations, its display lines and the refusal of its
    -- latest key.
    presentationLineageRun :: !(Maybe Text),
    presentationLineageMode :: !(Maybe Service.LineageMode),
    presentationLineageEligible :: ![Text],
    presentationLineageLines :: ![Text],
    presentationLineageError :: !(Maybe Text),
    -- | The outcome of the latest mutation key that started nothing. The
    -- status line shows it until the next key press or view change.
    presentationServiceKeyOutcome :: !(Maybe KeyOutcome),
    -- | The rows of the installed manager overview, the selected row and the
    -- overview status line, which the manager overview view shows.
    presentationServiceOverview :: !OverviewView,
    -- | The rows of the installed pending decision heads in manager
    -- observation order, the selected row and the decisions status line,
    -- which the manager decisions view shows.
    presentationServiceDecisions :: !OverviewView,
    -- | The rows of the installed run list of @/v1/runs@ in identifier
    -- order, the selected row and the history status line, which the
    -- History view shows.
    presentationServiceHistory :: !OverviewView,
    -- | The lines of the installed detail of the run that the run detail
    -- shows, as 'Agentic.Tui.Service.historyDetailLines' produces them,
    -- with the status line of the detail read and the saved line.
    presentationServiceHistoryDetail :: ![Text],
    presentationConfig :: !(Maybe TuiConfig),
    presentationPersonPrompt :: !(Maybe PersonPrompt),
    presentationPersonSubmitted :: !Bool,
    presentationPersonError :: !(Maybe Text),
    presentationRecovery :: !(Maybe (OccurrenceSnapshot, RecoverySnapshot)),
    presentationSteerTiming :: !(Maybe SteeringTiming),
    presentationControlError :: !(Maybe Text),
    presentationSaveError :: !(Maybe Text),
    -- | The refusal of the latest read of the path editor of a file capture.
    presentationCaptureError :: !(Maybe Text),
    presentationFinalResult :: !(Maybe (Either Text Value)),
    presentationFinalLoading :: !Bool,
    presentationShowResult :: !Bool,
    presentationElapsed :: !Text,
    presentationRunPersona :: !(Maybe Text),
    presentationRunRealization :: !(Maybe Text),
    presentationSpinner :: !Text
  }

-- | The display state of the manager overview view, of the manager
-- decisions view and of the History view.
data OverviewView = OverviewView
  { overviewViewRows :: ![Service.OverviewRow], overviewViewCursor :: !Int, overviewViewStatus :: !Text }

-- | Minimal state for rendering static browser and launch-review fixtures.
staticPresentation :: TuiConfig -> TuiModel -> Presentation
staticPresentation config model = (emptyPresentation model) {presentationConfig = Just config}

-- | Presentation defaults without a local executable or private-root configuration.
emptyPresentation :: TuiModel -> Presentation
emptyPresentation model =
  Presentation
    { presentationModel = model,
      presentationEditor = Edit.editorText InputEditor Nothing "",
      presentationRunView = emptyRunView,
      presentationPaneFocus = PrimaryPane,
      presentationOutputFollow = True,
      presentationLayer = case modelScreen model of
        ConfirmScreen _ -> ConfirmLayer
        _ -> ScreenLayer,
      presentationExactDetails = False,
      presentationRunning = False,
      presentationNoColor = False,
      presentationService = False,
      presentationServiceEndpoint = Nothing,
      presentationServiceDelivery = DeliveryIdle,
      presentationServiceReach = Reachable,
      presentationServiceEndpoints = Nothing,
      presentationServiceMutation = Nothing,
      presentationServiceResendConfirm = False,
      presentationServiceConfirm = Nothing,
      presentationServiceApproval = Nothing,
      presentationServiceApprovalOffered = False,
      presentationServiceNotice = Nothing,
      presentationServiceFault = False,
      presentationServiceObservation = [],
      presentationServiceRequestLines = [],
      presentationServiceRun = Nothing,
      presentationServiceRecoveryOffers = [],
      presentationServiceRunKeys = [],
      presentationServiceControlLines = [],
      presentationServiceResultLines = [],
      presentationServiceSavable = False,
      presentationServiceExportable = False,
      presentationExportRun = Nothing,
      presentationExportError = Nothing,
      presentationServiceLineageOffered = False,
      presentationLineageRun = Nothing,
      presentationLineageMode = Nothing,
      presentationLineageEligible = [],
      presentationLineageLines = [],
      presentationLineageError = Nothing,
      presentationServiceKeyOutcome = Nothing,
      presentationServiceOverview = OverviewView [] 0 (Service.overviewStatus Nothing Nothing),
      presentationServiceDecisions = OverviewView [] 0 (Service.decisionsStatus Nothing Nothing),
      presentationServiceHistory = OverviewView [] 0 (Service.historyStatus Nothing Nothing),
      presentationServiceHistoryDetail = [],
      presentationConfig = Nothing,
      presentationPersonPrompt = Nothing,
      presentationPersonSubmitted = False,
      presentationPersonError = Nothing,
      presentationRecovery = Nothing,
      presentationSteerTiming = Nothing,
      presentationControlError = Nothing,
      presentationSaveError = Nothing,
      presentationCaptureError = Nothing,
      presentationFinalResult = Nothing,
      presentationFinalLoading = False,
      presentationShowResult = False,
      presentationElapsed = "unknown",
      presentationRunPersona = Nothing,
      presentationRunRealization = Nothing,
      presentationSpinner = "|"
    }

-- | Draw one complete fixed-shell frame.
drawPresentation :: Presentation -> [Widget Name]
drawPresentation presentation = [responsive (layout presentation)]

responsive :: (Int -> Int -> Widget n) -> Widget n
responsive build = Widget Greedy Greedy $ do
  context <- getContext
  render (build (availWidth context) (availHeight context))

layout :: Presentation -> Int -> Int -> Widget Name
layout presentation width height
  | height <= 0 || width <= 0 = emptyWidget
  | otherwise =
      vBox
        ( headerWidgets
            <> [mainWidget | mainRows > 0]
            <> statusWidgets
            <> footerWidgets
        )
  where
    identity = isJust (presentationServiceEndpoint presentation)
    headerRows = shellHeaderRows identity width height
    statusRows = shellStatusRows height
    footerRows = shellFooterRows height
    mainRows = shellMainRows identity width height
    identityRows = [bar width (muted (displayText (oneLine width (" " <> endpointLine endpoint)))) | Just endpoint <- [presentationServiceEndpoint presentation]]
    -- The header row of the screen context. Above the identity row it also
    -- shows the delivery state of the event stream at its right end, or the
    -- time since when the manager is unreachable. The unreachable state is
    -- shown complete, and the screen context gives way to it.
    unreachable = reachabilityText (presentationServiceReach presentation)
    contextWidth = case unreachable of
      Just text | identity -> max 0 (width - T.length text - 2)
      _ -> width
    contextRow = bar width (hBox ([hLimit contextWidth (padLeft (Pad 1) (headerContext presentation))]
      <> [padLeft Max (muted (displayText (fromMaybe (deliveryText (presentationServiceDelivery presentation)) unreachable <> " "))) | identity]))
    headerWidgets = case headerRows of
      0 -> []
      1 -> [bar width (hBox [withAttr (attrName "title") (displayText "agent-cat"), displayText " / ", headerContext presentation])]
      _ | LiveScreen _ <- modelScreen (presentationModel presentation) ->
            [ contextRow,
              bar width (muted (displayText (oneLine width (liveSubtitle presentation))))
            ] <> identityRows
        | otherwise -> [bar width (withAttr (attrName "title") (displayText (" agent-cat  /  " <> screenTitle (modelScreen (presentationModel presentation))))), contextRow]
            <> identityRows
    mainWidget = hLimit width (vLimit mainRows (padBottom Max (layerView presentation width height mainRows)))
    statusWidgets = [bar width (statusView presentation width) | statusRows == 1]
    footerWidgets = map (bar width . (\line -> if T.all isSpace line then muted hBorder else shortcutLine line)) footerLines
    footerLines = packedFooter width footerRows (footerItems presentation width height)

-- | The second header row of the live monitor. The manager publishes a
-- target label but no persona or realization, so service mode shows only the
-- target label of the installed run observation. The label does not depend on
-- the runtime, and only a null label reads as not reported.
liveSubtitle :: Presentation -> Text
liveSubtitle presentation
  | presentationService presentation =
      " target " <> fromMaybe "not reported" (presentationServiceRun presentation >>= Service.runTarget)
  | otherwise =
      " persona " <> fromMaybe "none" (presentationRunPersona presentation) <> " · target " <> fromMaybe "pending" (presentationRunRealization presentation)

-- | The header rows, given whether the shell shows an endpoint identity row.
-- That row appears only where the two-row header fits.
shellHeaderRows :: Bool -> Int -> Int -> Int
shellHeaderRows identity width height
  | height <= 2 = 0
  | width >= 72 && height >= 16 = if identity then 3 else 2
  | otherwise = 1

shellStatusRows :: Int -> Int
shellStatusRows height
  | height >= 3 = 1
  | otherwise = 0

shellFooterRows :: Int -> Int
shellFooterRows height
  | height <= 1 = 1
  | height >= 8 = 2
  | otherwise = 1

shellMainRows :: Bool -> Int -> Int -> Int
shellMainRows identity width height = max 0 (height - shellHeaderRows identity width height - shellStatusRows height - shellFooterRows height)

-- | The endpoint identity row of the service shell: the endpoint host and
-- port, the leading characters of the authority epoch, the credential scopes
-- and the stream identifier. The stream identifier comes last, so a narrow
-- terminal shows its leading characters.
endpointLine :: Service.Endpoint -> Text
endpointLine endpoint =
  "manager " <> host <> ":" <> shown (Service.endpointPort endpoint)
    <> " · " <> authority
    <> " · scopes " <> (if null scopes then "none" else T.unwords scopes)
    <> " · " <> Service.endpointStream endpoint
  where
    named = Service.endpointHost endpoint
    host = if T.any (== ':') named then "[" <> named <> "]" else named
    epoch = Service.endpointAuthority endpoint
    authority = if T.length epoch > 18 then T.take 18 epoch <> "…" else epoch
    scopes = Service.endpointScopes endpoint

-- | The lines of the Endpoints view: for each client profile its number,
-- connection state and path, the identity of its latest session, and each
-- command that a switch left unresolved for it. The selected profile is
-- marked with @>@.
endpointsLines :: Endpoints -> [Text]
endpointsLines endpoints = concat (zipWith entry [0 :: Int ..] (endpointsSlots endpoints))
  where
    entry index slot =
      [ (if index == endpointsCursor endpoints then "> " else "  ") <> shown (index + 1) <> ". " <> state (slotState slot) <> "  " <> T.pack (slotProfile slot),
        "     " <> maybe "identity not observed" endpointLine (slotIdentity slot) ]
        <> [ "     unresolved " <> command <> " (not sent through another endpoint)" | command <- slotUnresolved slot ]
    state current = case current of
      EndpointActive -> "active"
      EndpointIdle -> "not connected"
      EndpointConnecting _ -> "connecting"
      EndpointFailed reason -> "failed: " <> reason

bar :: Int -> Widget n -> Widget n
bar width widget = hLimit width (padRight Max widget)


headerContext :: Presentation -> Widget Name
headerContext presentation = case modelScreen model of
  BrowserScreen | presentationService presentation -> displayText "Manager workflows"
  ServiceOverviewScreen -> displayText "Manager overview"
  ServiceDecisionsScreen -> displayText "Manager decisions"
  ServiceHistoryScreen -> displayText "Manager history"
  ServiceHistoryRunScreen _ -> displayText "Manager run detail"
  BrowserScreen -> tabs (modelTab model)
  LiveScreen _ -> hBox [withAttr (attrName "title") (displayText (liveContext presentation))]
  LaunchingScreen _ -> displayText "Starting runner…"
  screen -> maybe (displayText (screenTitle screen)) (displayText . ("workflow " <>) . workflowName) (modelWorkflow model)
  where
    model = presentationModel presentation

statusView :: Presentation -> Int -> Widget Name
statusView presentation width = withAttr attribute (displayText (oneLine width message))
  where
    model = presentationModel presentation
    (attribute, message)
      | Just outcome <- presentationServiceKeyOutcome presentation = (attrName "warning", keyOutcomeLine outcome)
      | presentationServiceFault presentation = (attrName "error", internalFaultStatus)
      | Just failure <- presentationControlError presentation = (attrName "error", "ERROR: " <> failure)
      | RecoveryLayer <- presentationLayer presentation = (attrName "warning", "Recovery required")
      | FilterLayer <- presentationLayer presentation = (attrName "status", browserStatus (setWorkflowFilter (T.unwords (T.words (T.intercalate "\n" (Edit.getEditContents (presentationEditor presentation))))) model))
      | BrowserScreen <- modelScreen model = (attrName "status", modelStatus model <> " | " <> browserStatus model)
      | otherwise = (attrName "status", modelStatus model)

browserStatus :: TuiModel -> Text
browserStatus model = case modelTab model of
  WorkflowsTab ->
    "filter /"
      <> modelWorkflowFilter model
      <> "/  "
      <> shown (length (visibleWorkflows model))
      <> " of "
      <> shown (length (modelWorkflows model))
  RunsTab -> shown (length (modelRuns model)) <> " stored runs"
  RoutingTab -> case modelRouting model of
    Left failure -> "ERROR: " <> failure
    Right routing -> "persona " <> fromMaybe "none" (routingSummaryPersona routing) <> maybe "" (\source -> " (" <> source <> ")") (routingSummaryPersonaSource routing)

layerView :: Presentation -> Int -> Int -> Int -> Widget Name
layerView presentation width _ mainHeight
  | presentationServiceResendConfirm presentation, Just (operation,uri,_) <- presentationServiceMutation presentation =
      dialog width mainHeight " Confirm exact resend " (vBox (map displayTextWrap
        [ "Resend the retained " <> operation <> " attempt?", uri,
          "The original body, idempotency key and If-Match stay unchanged.",
          "Its previous outcome may be uncertain. No fresh attempt is created.", "y RESEND EXACT ATTEMPT   n BACK" ]))
  | Just (title, rows) <- presentationServiceConfirm presentation =
      dialog width mainHeight title (vBox (map displayTextWrap rows))
layerView presentation width totalHeight mainHeight = case presentationLayer presentation of
  EndpointsLayer -> pane "Manager endpoints [focus]" (vBox (map displayTextWrap (maybe [] endpointsLines (presentationServiceEndpoints presentation))))
  KeyHelpLayer -> keyHelpView presentation width mainHeight
  CancelLayer -> cancelView width mainHeight
  PersonLayer -> headView personView
  RecoveryLayer -> headView recoveryView
  SteerLayer -> steerView presentation width mainHeight
  SaveLayer -> saveResultView presentation width mainHeight
  ExportLayer -> exportNameView presentation width mainHeight
  LineageLayer -> lineageView presentation width mainHeight
  CaptureFileLayer -> captureFileView presentation width mainHeight
  FilterLayer -> workflowFilterView presentation width mainHeight
  ConfirmDetailsLayer -> confirmDetailsView presentation width mainHeight
  ConfirmLayer -> confirmSummaryView presentation width totalHeight mainHeight
  RunDetailsLayer -> pane "RUN DETAILS [focus]" (viewport FailureViewport Vertical (displayTextWrap (boundedDisplay (maybe (if presentationService presentation then "Runtime not yet observed." else "Run unavailable.") (runDetailsText presentation) (modelSnapshot (presentationModel presentation))))))
  ScreenLayer -> screenView presentation width totalHeight mainHeight
  where
    -- In service mode the service lines stay above the decision head, so the
    -- runtime and the approval receipt remain visible beside the question.
    headView view
      | presentationService presentation =
          let lines' = serviceLiveLines presentation
              rows = sum (map (length . wrapDisplayLines width) lines')
           in vBox (map displayTextWrap lines' <> [view presentation width (max 1 (mainHeight - rows))])
      | otherwise = view presentation width mainHeight

screenView :: Presentation -> Int -> Int -> Int -> Widget Name
screenView presentation width totalHeight mainHeight = case modelScreen model of
  InitialLoading | presentationService presentation -> loadingView presentation "Loading manager profiles..." "q detaches"
  InitialLoading -> loadingView presentation "Loading workflows, stored runs, and offline routing..." "q cancels"
  BrowserScreen -> browserView presentation width totalHeight
  ServiceProfilesScreen _ _ -> browserView presentation width totalHeight
  ServiceOverviewScreen -> serviceRowsView "Overview" "Select an overview row." (presentationServiceOverview presentation) presentation width totalHeight
  ServiceDecisionsScreen -> serviceRowsView "Decisions" "Select a decision row." (presentationServiceDecisions presentation) presentation width totalHeight
  ServiceHistoryScreen -> serviceRowsView "History" "Select a run row." (presentationServiceHistory presentation) presentation width totalHeight
  ServiceHistoryRunScreen _ -> pane "Run detail [read-only]" (viewport FailureViewport Vertical (vBox (map displayTextWrap (presentationServiceHistoryDetail presentation))))
  ServiceRequestScreen request -> serviceRequestView presentation request
  ServiceReviewScreen preparation tag -> serviceReviewView presentation preparation tag width totalHeight mainHeight
  ServiceCommandScreen message -> pane "Manager command" (viewport FailureViewport Vertical (displayTextWrap message))
  InputScreen index -> inputView presentation index width mainHeight
  TargetScreen -> targetView presentation width
  HelpLoading -> loadingView presentation "Loading bounded runner help..." "Esc cancels"
  HelpScreen help -> viewport HelpViewport Vertical (displayText (boundedDisplay help))
  PreviewLoading -> loadingView presentation "Building exact-input plan and routing preview..." "Esc cancels"
  ConfirmScreen _ -> confirmSummaryView presentation width totalHeight mainHeight
  ProcessLoading _ -> loadingView presentation "Preparing the private run and starting the machine..." "Esc cancels safely"
  LaunchingScreen _ -> loadingView presentation "Waiting for the validated run.started event..." "Esc detaches; c cancels"
  LiveScreen _
    | presentationService presentation ->
        vBox (map displayTextWrap (serviceLiveLines presentation) <> [maybe (loadingView presentation "Runtime not yet observed. The manager has published no runtime status for this run." "q detaches; the manager run continues")
          (liveView presentation width totalHeight) (modelSnapshot model)])
    | otherwise -> maybe (loadingView presentation "Waiting for run.started..." "Esc detaches; c cancels") (liveView presentation width totalHeight) (modelSnapshot model)
  FailureScreen failure -> viewport FailureViewport Vertical (withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure)))
  where
    model = presentationModel presentation

-- | The lines above the live monitor in service mode: the request and its
-- run, the installed observation with its stale mark and published runtime,
-- the approval receipt status, which stays separate from the runtime, the
-- outcome of the latest control of the run, the redirect line, and the
-- result lines.
serviceLiveLines :: Presentation -> [Text]
serviceLiveLines presentation =
  presentationServiceRequestLines presentation
    <> presentationServiceObservation presentation
    <> ["Approval receipt: " <> fromMaybe "none" (presentationServiceApproval presentation)]
    <> presentationServiceControlLines presentation
    <> presentationServiceResultLines presentation

-- | The lines that name a request, its phase and its run. The run has its own
-- line, so a long request id never splits the run id across screen rows.
serviceRequestLines :: Manager.DraftView -> [Text]
serviceRequestLines request =
  [ "Request: " <> Manager.draftId request <> "   Phase: " <> Manager.draftPhase request,
    "Run: " <> fromMaybe "none" (Manager.draftRun request) ]

serviceRequestView :: Presentation -> Manager.DraftView -> Widget Name
serviceRequestView presentation request = pane "Manager request" $ viewport FailureViewport Vertical $ vBox $ map displayTextWrap $
  [ "Request: " <> Manager.draftId request, "Profile: " <> Manager.draftProfile request,
    "Phase: " <> Manager.draftPhase request, "Admission: " <> Manager.draftAdmission request,
    "Position: " <> maybe "none" shown (Manager.draftPosition request),
    "Blocking reasons: " <> T.intercalate ", " (Manager.draftReasons request),
    "Missing inputs: " <> (if null missing then "none" else T.intercalate ", " missing),
    "Run: " <> fromMaybe "none" (Manager.draftRun request) ]
  <> [ "Lineage: " <> operation <> " of run " <> parent <> "; the inputs come from the parent run"
     | Just parent <- [Manager.draftParent request], Just operation <- [Manager.draftLineage request] ]
  <> presentationServiceObservation presentation
  <> [ "Approval receipt: " <> fromMaybe "none" (presentationServiceApproval presentation),
    "Runtime completion and result verification are not inferred from this request.", "", "Retained operator literals:" ]
  <> concat [[name, value] | (name,value) <- Map.toList (modelInputs (presentationModel presentation))]
  <> (if null captured then [] else "" : "Captured inputs:" : captured)
  where
    Manager.Readiness _ supplied missing _ = Manager.draftReadiness request
    captured = [name <> ": capture " <> ident | Manager.CapturedValue name ident <- supplied]

serviceReviewRows :: Manager.Preparation -> Text -> [Text]
serviceReviewRows preparation tag =
  [ "Explicit approval starts execution through the manager.",
    "Request: " <> Manager.preparationRequest preparation,
    "Preparation: " <> Manager.preparationId preparation,
    "Profile: " <> Manager.preparationProfile preparation,
    "Expires: " <> Manager.preparationExpiresAt preparation,
    "If-Match: " <> tag ] <> lineageRows <> Service.approvalSelectors preparation
      <> ["d shows the complete exact review.", "Only y approves. Enter does not approve."]
  where
    -- A lineage review names its parent run, its operation and its fork
    -- edits. A replacement shows the SHA-256 of its answer, as the review
    -- states it.
    lineageRows = case Manager.reviewLineage (Manager.preparationReview preparation) of
      Nothing -> []
      Just lineage ->
        [ "Lineage: " <> Manager.reviewLineageOperation lineage <> " of run " <> Manager.reviewLineageParent lineage,
          "Lineage edits: " <> case Manager.reviewLineageEdits lineage of
            [] -> "none"
            edits -> T.intercalate ", " (map editText edits) ]
    editText edit = case edit of
      Manager.ReviewDrop occurrence -> "drop occurrence " <> occurrence
      Manager.ReviewReplace occurrence digest -> "replace occurrence " <> occurrence <> " (answer SHA-256 " <> digest <> ")"

-- | Whether the complete summary review fits in the service shell, whose
-- header includes the endpoint identity row where it fits. The rows of the
-- longest approval-key notice are always reserved, so a notice never clips the
-- review.
serviceReviewAllowed :: Manager.Preparation -> Text -> (Int,Int) -> Bool
serviceReviewAllowed preparation tag (width,height) = width >= 40 &&
  length (concatMap (wrapDisplayLines innerWidth) (serviceReviewRows preparation tag)) + serviceNoticeRows innerWidth
    <= max 0 (shellMainRows True width height - 2)
  where innerWidth = max 1 (min 84 width - 4)

-- | The rows that the longest approval-key notice needs at this inner width,
-- with the widest possible key number.
serviceNoticeRows :: Int -> Int
serviceNoticeRows innerWidth =
  maximum (0 : [length (wrapDisplayLines innerWidth (noticeLine (KeyNotice maxBound text))) | text <- noticeTexts])

-- | The lines of the approval-key notice in a dialog of this width. Each
-- view places them first, so a clipped review cannot hide them.
serviceNoticeWidgets :: Presentation -> Int -> [Widget Name]
serviceNoticeWidgets presentation width =
  [ withAttr (attrName "warning") (displayText line)
  | Just current <- [presentationServiceNotice presentation],
    line <- wrapDisplayLines (max 1 (min 84 width - 4)) (noticeLine current)
  ]

serviceReviewView :: Presentation -> Manager.Preparation -> Text -> Int -> Int -> Int -> Widget Name
serviceReviewView presentation preparation tag width _ mainHeight
  | presentationExactDetails presentation = dialog width mainHeight " Exact manager review " $
      vBox (notice <> [viewport ConfirmDetailsViewport Vertical $ vBox $ map displayTextWrap details])
  | otherwise = dialog width mainHeight " Approve exact manager review " $
      vBox (notice <> map displayText (concatMap (wrapDisplayLines innerWidth) (serviceReviewRows preparation tag)))
  where
    innerWidth = max 1 (min 84 width - 4)
    notice = serviceNoticeWidgets presentation width
    review = Manager.preparationReview preparation
    details = Service.approvalSelectors preparation <>
      [ "Program SHA-256: " <> Manager.reviewProgramHash review,
        "Person answering: " <> Manager.reviewPerson review,
        "Workflow: " <> Manager.reviewWorkflow review,
        "Profile: " <> Manager.reviewProfile review,
        "Workspace: " <> Manager.reviewWorkspaceLabel review,
        "Target: " <> Manager.reviewTargetLabel review,
        "Policy:", jsonTextValue (Manager.policyValue (Manager.reviewPolicy review)),
        "Exact native input identities:", jsonTextValue (toJSON (Manager.reviewInputs review)),
        "Exact plan:", Manager.reviewPlan review,
        "Run facts:", jsonTextValue (toJSON (Manager.reviewRunFacts review)),
        "Pins:", jsonTextValue (toJSON (Manager.reviewPins review)),
        "Warnings:", jsonTextValue (toJSON (Manager.reviewWarnings review)),
        "Result code:", jsonTextValue (Manager.reviewResultCode review) ]
      <> maybe [] (\lineage ->
        [ "Lineage: " <> Manager.reviewLineageOperation lineage <> " of run " <> Manager.reviewLineageParent lineage,
          "Lineage edits:", jsonTextValue (toJSON (Manager.reviewLineageEdits lineage)) ]) (Manager.reviewLineage review)

-- | The manager overview, the manager decisions or the History view, given the title of the
-- list pane, the text of an empty detail pane and the display state: the
-- status line, the list of rows and the detail lines of the selected row. A
-- wide terminal shows the list beside the details. A narrow terminal shows
-- the focused pane only.
serviceRowsView :: Text -> Text -> OverviewView -> Presentation -> Int -> Int -> Widget Name
serviceRowsView title unselected overview presentation width totalHeight = vBox [displayTextWrap (overviewViewStatus overview), body]
  where
    rows = overviewViewRows overview
    cursor = overviewViewCursor overview
    wide = width >= 72 && totalHeight >= 16
    listWidth = min 38 (max 26 (width `div` 3))
    primaryFocused = presentationPaneFocus presentation == PrimaryPane
    body
      | wide = hBox [hLimit listWidth listPane, muted vBorder, detailPane]
      | primaryFocused = listPane
      | otherwise = detailPane
    listPane = pane (title <> focusMark primaryFocused) $ viewport BrowserListViewport Vertical $
      if null rows then displayTextWrap "No rows are visible." else vBox (zipWith entry [0 ..] rows)
    entry index row =
      let selected = index == cursor
          line = displayText ((if selected then "> " else "  ") <> Service.overviewRowLabel row)
          styled = if selected then withAttr (attrName "selected") (padRight Max line) else line
       in if selected && primaryFocused then visible styled else styled
    detailPane = pane ("Details" <> focusMark (not primaryFocused)) $ viewport BrowserDetailViewport Vertical $
      maybe (displayText unselected) (vBox . map displayTextWrap . Service.overviewRowDetails) (atMay rows cursor)

loadingView :: Presentation -> Text -> Text -> Widget Name
loadingView presentation message action = padLeftRight 2 (vBox [displayText "", withAttr (attrName "title") (displayTextWrap (presentationSpinner presentation <> "  " <> message)), muted (displayText action)])

browserView :: Presentation -> Int -> Int -> Widget Name
browserView presentation width totalHeight
  | wide = hBox [hLimit listWidth listPane, muted vBorder, detailPane]
  | presentationPaneFocus presentation == SecondaryPane = detailPane
  | otherwise = listPane
  where
    model = presentationModel presentation
    wide = width >= 72 && totalHeight >= 16
    listWidth = min 38 (max 26 (width `div` 3))
    primaryFocused = presentationPaneFocus presentation == PrimaryPane
    listTitle = case modelScreen model of ServiceProfilesScreen _ _ -> "Manager profiles"; _ -> tabName (modelTab model)
    listPane = pane (listTitle <> focusMark primaryFocused) $
      viewport BrowserListViewport Vertical $
        if null rows then displayTextWrap emptyMessage else vBox rows
    emptyMessage = case modelScreen model of
      ServiceProfilesScreen _ _ -> "No manager profiles are authorized."
      _ -> "No matches. Press / to change the search."
    rows
      | ServiceProfilesScreen _ _ <- modelScreen model =
          zipWith (\index line -> selectedRow index (displayTextWrap line)) [0..] (browserRows model)
      | otherwise = case modelTab model of
          WorkflowsTab -> [selectedRow index (displayText (marker index <> workflowName workflow)) | (index, workflow) <- zip [0 ..] (visibleWorkflows model)]
          RunsTab -> [selectedRow index (runCard index entry) | (index, entry) <- zip [0 ..] (modelRuns model)]
          RoutingTab -> zipWith (\index line -> selectedRow index (displayTextWrap line)) [0 ..] (browserRows model)
    listContentWidth = (if wide then listWidth else width) - 2
    runCard index (CatalogueRun record) =
      let manifest = recordManifest record
       in vBox [displayText (marker index <> frontendWorkflow manifest), muted (displayText ("  " <> maybe "Not started" (runStatusLabel . snapshotRunStatus) (recordSnapshot record))), muted (displayText (oneLine listContentWidth ("  " <> runIdText (frontendRunId manifest))))]
    runCard index (CatalogueCorrupt _ _) = displayText (marker index <> "Unreadable run")
    marker index = if index == selectedIndex then "> " else "  "
    detailPane = pane ("Details" <> focusMark (not primaryFocused)) (viewport BrowserDetailViewport Vertical detailBody)
    detailBody
      | ServiceProfilesScreen _ _ <- modelScreen model = vBox (map detailLine (browserDetailLines model))
      | otherwise = case modelTab model of
          WorkflowsTab -> maybe (displayText "Select a workflow.") (workflowOverview (presentationService presentation)) (selectedWorkflow model)
          _ -> vBox (map detailLine (browserDetailLines model))
    selectedIndex
      | ServiceProfilesScreen _ index <- modelScreen model = index
      | otherwise = case modelTab model of
          WorkflowsTab -> modelWorkflowIndex model
          RunsTab -> modelRunIndex model
          RoutingTab -> modelEngineIndex model
    selectedRow index widget =
      let selected = index == selectedIndex
          styled = if selected then withAttr (attrName "selected") (padRight Max widget) else widget
       in if selected && primaryFocused then visible styled else styled

workflowOverview :: Bool -> WorkflowDescriptor -> Widget Name
workflowOverview service workflow = vBox
  [ withAttr (attrName "title") (displayTextWrap (workflowName workflow)),
    displayText "",
    displayTextWrap (workflowBlurb workflow),
    displayText "",
    detailLine "Inputs",
    displayTextWrap (case workflowInputs workflow of [] -> "No input required."; inputs -> T.intercalate ", " (map workflowInputName inputs)),
    displayText "",
    detailLine "Produces",
    displayTextWrap (case workflowResultCode workflow of String code -> code; value -> jsonTextValue value),
    displayText "",
    detailLine "Execution",
    displayTextWrap (shown (descriptorConsults capabilities) <> " consultations · " <> shown (descriptorObserves capabilities) <> " observations · " <> shown (descriptorEffects capabilities) <> " effects"),
    withAttr (attrName (if descriptorEffectful capabilities || descriptorToolExecution capabilities then "warning" else "muted"))
      (displayTextWrap ("Effects: " <> yesNo (descriptorEffectful capabilities) <> " · Tool execution: " <> yesNo (descriptorToolExecution capabilities))),
    displayText "",
    shortcutLine (if service then "Enter NEW REQUEST   h HELP" else "Enter CONFIGURE   h HELP"),
    displayText "",
    muted (displayTextWrap ("Profiles: " <> commaOrNone (workflowPins workflow)))
  ]
  where capabilities = workflowCapabilities workflow

detailLine :: Text -> Widget Name
detailLine line
  | T.null line = displayText ""
  | not (T.isPrefixOf " " line) = withAttr (attrName "title") (displayTextWrap line)
  | otherwise = displayTextWrap (T.stripStart line)

pane :: Text -> Widget Name -> Widget Name
pane title body = vBox [withAttr (attrName attribute) (hBorderWithLabel (displayText (" " <> label <> " "))), padLeftRight 1 body]
  where
    focused = " [focus]" `T.isSuffixOf` title
    attribute = if focused then "title" else "muted"
    label = T.dropWhileEnd isSpace (fromMaybe title (T.stripSuffix " [focus]" title)) <> if focused then " •" else ""

focusMark :: Bool -> Text
focusMark True = " [focus]"
focusMark False = ""

tabName :: BrowserTab -> Text
tabName WorkflowsTab = "Workflows"
tabName RunsTab = "Runs"
tabName RoutingTab = "Routing"

tabs :: BrowserTab -> Widget Name
tabs selected = hBox [tab WorkflowsTab "Workflows", displayText "   ", tab RunsTab "Runs", displayText "   ", tab RoutingTab "Routing"]
  where
    tab value label
      | value == selected = withAttr (attrName "title") (displayText ("[" <> label <> "]"))
      | otherwise = muted (displayText label)

muted :: Widget n -> Widget n
muted = withAttr (attrName "muted")

inputView :: Presentation -> Int -> Int -> Int -> Widget Name
inputView presentation index width mainHeight = case modelWorkflow model of
  Nothing -> unavailable
  Just descriptor -> case atMay (workflowInputs descriptor) index of
    Nothing -> unavailable
    Just input -> hCenter $ hLimit (min 76 width) $ padLeftRight 1 $ vBox
      [ muted (displayText "Configure  →  Target  →  Review"),
        displayText "",
        withAttr (attrName "title") (displayText (workflowInputName input <> "  (" <> shown (index + 1) <> " of " <> shown (length (workflowInputs descriptor)) <> ")")),
        vLimit editorRows (borderWithLabel (withAttr (attrName "title") (displayText " Input • ")) (padLeftRight 1 (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation))))
      ]
  where
    model = presentationModel presentation
    editorRows = max 1 (min (mainHeight - 3) (min 10 (2 + length (Edit.getEditContents (presentationEditor presentation)))))
    unavailable = withAttr (attrName "error") (displayText "ERROR: input descriptor unavailable")

targetView :: Presentation -> Int -> Widget Name
targetView presentation width = hCenter $ hLimit (min 84 width) $
  pane "Execution target [focus]" (viewport TargetViewport Vertical (vBox (headerLines <> routingLines)))
  where
    model = presentationModel presentation
    readinessHeader = case modelRouting model of
      Left _ -> withAttr (attrName "error") (displayText "ROUTING UNAVAILABLE")
      Right routing ->
        let ready = all engineChoiceCredentialReady (routingSummaryEngines routing)
         in withAttr (attrName (if ready then "success" else "warning"))
              (displayText (if ready then "ROUTING READY (offline)" else "ROUTING NOT READY"))
    headerLines =
      [ readinessHeader,
        muted (displayTextWrap "Routing requires full pin coverage. You will review the exact plan before launch."),
        displayText ""
      ]
    routingLines = case modelRouting model of
      Left failure -> [withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure))]
      Right routing ->
        [ displayTextWrap ("Persona: " <> fromMaybe "none" (routingSummaryPersona routing) <> maybe "" (\source -> " (" <> source <> ")") (routingSummaryPersonaSource routing)),
          withAttr (attrName "warning") (displayTextWrap "Live providers may charge for requests."),
          displayText ""
        ]
          <> map engineLine (routingSummaryEngines routing)
          <> [displayText "", muted hBorder, shortcutLine "s SCRIPTED", muted (displayTextWrap "Deterministic replies; no external backend is contacted.")]
    engineLine engine =
      vBox
        [ displayTextWrap (engineChoiceAlias engine),
          withAttr (attrName (if engineChoiceCredentialReady engine then "success" else "warning")) (displayText ("  " <> readinessText engine)),
          muted (displayTextWrap ("  " <> engineChoiceBackend engine <> " / " <> engineChoiceProvider engine))
        ]

confirmSummaryView :: Presentation -> Int -> Int -> Int -> Widget Name
confirmSummaryView presentation width totalHeight mainHeight =
  dialog width mainHeight title (vBox (map renderLine summaryLines))
  where
    preview = confirmPreview presentation
    live = maybe False previewIsLive preview
    title = if live then " Review live run " else " Review scripted run "
    summaryLines = case (presentationConfig presentation,preview) of
      (Just config,Just value)
        | launchReviewAllowed config value (width, totalHeight) -> confirmationSummary config value
        | otherwise -> blockedConfirmationSummary config value width totalHeight
      _ -> [("ERROR: local launch preview unavailable", "error")]
    renderLine (line, attribute)
      | T.null attribute =
        let (label, value) = T.breakOn " " line
         in Widget Greedy Fixed $ do
              context <- getContext
              render (vBox (zipWith (\index row -> if index == (0 :: Int) then hBox [muted (displayText label), displayText (T.drop (T.length label) row)] else displayText row) [0 ..] (wrapDisplayLines (availWidth context) (label <> value))))
      | otherwise = withAttr (attrName (T.unpack attribute)) (displayTextWrap line)

confirmationSummary :: TuiConfig -> LaunchPreview -> [(Text, Text)]
confirmationSummary config preview =
  [ (billingText preview, billingAttribute preview),
    ("Workflow  " <> workflowName descriptor <> lineageCompact preview, ""),
    ("Persona   " <> personaText preview, ""),
    ("Target    " <> targetSummary preview, ""),
    ("Routing   " <> relevantRoutingCompact preview, ""),
    ("Requests  " <> planRange preview <> " occurrences / " <> shown (workflowPaths descriptor) <> " paths", ""),
    ("Effects   effectful " <> yesNo (descriptorEffectful capabilities) <> "; tool execution " <> yesNo (descriptorToolExecution capabilities), ""),
    ("Directory " <> T.pack (previewWorkingDirectory config preview), "")
  ]
    <> warningLines preview
  where
    descriptor = exactPlanDescriptor (previewPlan preview)
    capabilities = workflowCapabilities descriptor

warningLines :: LaunchPreview -> [(Text, Text)]
warningLines preview = case previewRouting preview of
  Nothing -> [("Warnings  none", "")]
  Just routing -> case routingSummaryWarnings routing of
    [] -> [("Warnings  none", "")]
    warnings -> [("Warnings  " <> shown (length warnings) <> " reported; d DETAILS", "warning")]

blockedConfirmationSummary :: TuiConfig -> LaunchPreview -> Int -> Int -> [(Text, Text)]
blockedConfirmationSummary config preview width height =
  [ ("LAUNCH DISABLED: COMPLETE REVIEW DOES NOT FIT", "warning"),
    (billingCompactText preview, billingAttribute preview),
    ("Workflow  " <> workflowName (exactPlanDescriptor (previewPlan preview)), ""),
    ("Need " <> shown required <> " review rows; " <> shown available <> " available.", "error"),
    ("Resize, or press d for exact details. n/Esc goes back.", "")
  ]
  where
    required = confirmationRequiredRows config preview width
    available = confirmationBodyRows width height

confirmDetailsView :: Presentation -> Int -> Int -> Widget Name
confirmDetailsView presentation width mainHeight =
  dialog width mainHeight " Launch details " $
    viewport ConfirmDetailsViewport Vertical (vBox (map detailLine details))
  where
    details = case (presentationConfig presentation,confirmPreview presentation) of
      (Just config,Just preview) -> confirmationDetails config preview
      _ -> ["ERROR: local launch preview unavailable"]

confirmationDetails :: TuiConfig -> LaunchPreview -> [Text]
confirmationDetails config preview =
  warningDetails
    <> [ "Launch",
         "  workflow: " <> workflowName descriptor,
         "  lineage: " <> lineageDetails preview,
         "  target: " <> targetFull preview,
         "  persona: " <> personaText preview,
         "  working directory: " <> T.pack workingDirectory,
         "  private state root: " <> T.pack (tuiStateDir config),
         "  plan-program SHA-256: " <> previewProgramHash preview,
         "  routing launch fingerprint: " <> launchFingerprint preview,
         "",
         "Runner executable",
         "  " <> T.pack (tuiRunner config),
         "",
         "Runner prefix arguments"
       ]
    <> indexedArguments (map T.pack (tuiRunnerArgs config))
    <> ["", "Exact target arguments (direct argv; no shell)"]
    <> either (\failure -> ["  ERROR: " <> failure]) (indexedArguments . map T.pack) exactArguments
    <> [ "",
         "Exact-input plan",
         "  descriptor version: " <> shown (workflowDescriptorVersion descriptor),
         "  runner version: " <> workflowRunnerVersion descriptor,
         "  protocol versions: " <> commaOrNone (map shown (workflowProtocolVersions descriptor)),
         "  store versions: " <> commaOrNone (map shown (workflowStoreVersions descriptor)),
         "  level: " <> workflowLevel descriptor,
         "  result: " <> jsonTextValue (workflowResultCode descriptor),
         "  size: " <> shown (workflowSize descriptor),
         "  ask nodes: " <> shown (workflowAskNodes descriptor),
         "  request occurrences: " <> planRange preview,
         "  paths: " <> shown (workflowPaths descriptor),
         "  fold histogram: " <> foldHistogram plan,
         "  code sequence: " <> maybe "none (branching)" commaOrNone (exactPlanCodes plan),
         "  pins: " <> commaOrNone (workflowPins descriptor),
         "  run facts: " <> commaOrNone (workflowRunFacts descriptor),
         "  inputs: " <> inputDetails descriptor,
         "  consult: " <> shown (descriptorConsults capabilities),
         "  observe: " <> shown (descriptorObserves capabilities),
         "  effect: " <> shown (descriptorEffects capabilities),
         "  effectful: " <> yesNo (descriptorEffectful capabilities),
         "  tool execution: " <> yesNo (descriptorToolExecution capabilities),
         "",
         "Routing summary"
       ]
    <> routingDetails preview
    <> [ "",
         "Privacy",
         "  Input bodies and the raw plan program are retained for launch but are not rendered."
       ]
  where
    plan = previewPlan preview
    descriptor = exactPlanDescriptor plan
    capabilities = workflowCapabilities descriptor
    workingDirectory = previewWorkingDirectory config preview
    exactArguments = previewTargetArguments preview
    warningDetails = case maybe [] routingSummaryWarnings (previewRouting preview) of
      [] -> []
      warnings -> ["Routing warnings"] <> map ("  WARNING: " <>) warnings <> [""]

indexedArguments :: [Text] -> [Text]
indexedArguments [] = ["  none"]
indexedArguments arguments = ["  [" <> shown index <> "] " <> jsonQuoted argument | (index, argument) <- zip [0 :: Int ..] arguments]

routingDetails :: LaunchPreview -> [Text]
routingDetails preview = case previewRouting preview of
  Nothing -> ["  none (scripted or restored target)"]
  Just routing ->
    [ "  persona: " <> fromMaybe "none" (routingSummaryPersona routing),
      "  persona source: " <> fromMaybe "none" (routingSummaryPersonaSource routing),
      "  profiles matching exact-plan pins: " <> commaOrNone [routingProfileName profile | profile <- relevantProfiles preview],
      "  all persona profiles:"
    ]
      <> concatMap (map ("    " <>) . routingProfileLines) (routingSummaryProfiles routing)
      <> ["  full sanitized inspection JSON:", "    " <> jsonTextValue (routingSummaryRaw routing)]

routingProfileLines :: RoutingProfileChoice -> [Text]
routingProfileLines profile =
  (routingProfileName profile <> " chain:") : map (routingRungLine (routingProfileName profile)) (routingProfileRungs profile)

routingRungLine :: Text -> RoutingRungChoice -> Text
routingRungLine profileName rung =
  profileName
    <> " rung "
    <> shown (routingRungNumber rung)
    <> ": "
    <> routingRungAxis rung
    <> " -> "
    <> routingRungModel rung
    <> maybe "" (\alias -> " (alias " <> alias <> ")") (routingRungModelAlias rung)
    <> " on "
    <> routingRungRouter rung
    <> " / "
    <> routingRungProvider rung
    <> " / "
    <> routingRungBackend rung
    <> "; thinking "
    <> routingRungThinking rung
    <> "; max output "
    <> maybe "unconstrained" shown (routingRungMaxOutput rung)
    <> "; inventory "
    <> routingInventoryProvenance (routingRungInventory rung)
    <> maybe "" ("; execution fingerprint " <>) (routingRungExecutionFingerprint rung)

routingInventoryProvenance :: RoutingInventoryChoice -> Text
routingInventoryProvenance inventory =
  routingInventorySource inventory
    <> maybe "" ("; fingerprint " <>) (routingInventoryFingerprint inventory)
    <> maybe "" ("; fetched " <>) (routingInventoryFetchedAt inventory)

workflowFilterView :: Presentation -> Int -> Int -> Widget Name
workflowFilterView presentation width mainHeight = vBox
  [ hBox [withAttr (attrName "title") (displayText " / "), Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation)],
    browserView filtered width (mainHeight + 5)
  ]
  where
    query = T.unwords (T.words (T.intercalate "\n" (Edit.getEditContents (presentationEditor presentation))))
    filtered = presentation {presentationModel = setWorkflowFilter query (presentationModel presentation), presentationPaneFocus = PrimaryPane}

-- | The path editor of a file capture. The frontend reads the named local
-- file and sends only its bytes.
captureFileView :: Presentation -> Int -> Int -> Widget Name
captureFileView presentation width mainHeight =
  dialog width mainHeight " Capture a local file " $
    vBox
      [ displayTextWrap "Capture the exact bytes of a local UTF-8 file as this input. The manager receives the bytes, not the path.",
        vLimit 3 (borderWithLabel (displayText " Path • ") (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation))),
        case presentationCaptureError presentation of
          Nothing -> displayText "Ctrl-D captures. Esc cancels."
          Just failure -> withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure))
      ]

-- | The export name editor over the live monitor or the run detail.
exportNameView :: Presentation -> Int -> Int -> Widget Name
exportNameView presentation width mainHeight =
  dialog width mainHeight " Export verified result " $
    vBox
      [ displayTextWrap ("Export the verified result of run " <> fromMaybe "" (presentationExportRun presentation)
          <> " under a new name. The manager publishes the export once."),
        vLimit 3 (borderWithLabel (displayText " Name • ") (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation))),
        case presentationExportError presentation of
          Nothing -> displayText "Ctrl-D exports. Esc cancels."
          Just failure -> withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure))
      ]

-- | The lineage menu over the live monitor or the run detail: the choice of
-- the operation, the fork edits of each occurrence, or the replacement
-- answer editor of the selected occurrence.
lineageView :: Presentation -> Int -> Int -> Widget Name
lineageView presentation width mainHeight =
  dialog width mainHeight (" Lineage of run " <> fromMaybe "" (presentationLineageRun presentation) <> " ") $
    vBox $
      map displayTextWrap (presentationLineageLines presentation)
        <> [ vLimit 6 (borderWithLabel (displayText " Replacement answer • ") (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation)))
           | presentationLineageMode presentation == Just Service.LineageReplacing ]
        <> [ withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure)) | Just failure <- [presentationLineageError presentation] ]

saveResultView :: Presentation -> Int -> Int -> Widget Name
saveResultView presentation width mainHeight =
  dialog width mainHeight " Save verified result " $
    vBox
      [ maybe (displayTextWrap intro) (const emptyWidget) (presentationSaveError presentation),
        vLimit 3 (borderWithLabel (displayText " Path • ") (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation))),
        case presentationSaveError presentation of
          Nothing -> displayText "Ctrl-D saves. Esc cancels."
          Just failure -> viewport FailureViewport Vertical (withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure)))
      ]
  where
    intro
      | presentationService presentation = "Copy the verified result bytes to a new absolute path. Existing entries are refused."
      | otherwise = "Copy the verified final JSON result to a new absolute path. Existing files are refused."

-- | The fixed message of a refused service save, with the path. The path is
-- shown on one line through 'safeDisplay'.
serviceSaveRefusal :: Text -> SaveRefusal -> Text
serviceSaveRefusal path refusal = case refusal of
  InvalidDestination -> "Save refused: the destination must be one absolute single-line file path. Path: " <> shownPath path
  SaveIOFailure failure
    | isAlreadyExistsError failure -> "Save refused: an entry already exists at the destination. Nothing was written. Path: " <> shownPath path
    | otherwise -> "Save failed: nothing was written (" <> T.pack (show (ioeGetErrorType failure)) <> "). Path: " <> shownPath path

-- | The result line after a service save of this many verified bytes. A
-- private file that remains after the link is named.
serviceSavedLine :: Text -> Int -> Saved -> Text
serviceSavedLine path size saved = "Saved the verified " <> shown size <> " bytes to " <> shownPath path <> savedLeftoverNote saved

-- | The note that names a private file that remains after a save, if any.
savedLeftoverNote :: Saved -> Text
savedLeftoverNote saved = case saved of
  Saved -> ""
  SavedLeftover private -> "; the temporary file " <> shownPath (T.pack private) <> " was not removed"

shownPath :: Text -> Text
shownPath = T.replace "\n" "\xfffd" . safeDisplay

cancelView :: Int -> Int -> Widget Name
cancelView width mainHeight =
  dialog width (min mainHeight 5) " Cancel run? " $
    vBox
      [ displayText "Cancel the machine child and its process group?",
        displayText "",
        withAttr (attrName "selected") (displayText "y CANCEL RUN   n keep running")
      ]

personView :: Presentation -> Int -> Int -> Widget Name
personView presentation width mainHeight = case presentationPersonPrompt presentation of
  Nothing ->
    dialog width (min mainHeight 4) " Your answer " $
      displayTextWrap (presentationSpinner presentation <> "  Loading verified question…")
  Just prompt ->
    dialog width mainHeight " Your answer " $
      vBox
        [ muted (displayText ("Request " <> shown (toInteger (occurrenceNumber (personPromptOccurrence prompt)) + 1) <> " · " <> personPromptCode prompt)),
          vLimit promptHeight (viewport PersonViewport Vertical (displayTextWrap (boundedDisplay (personPromptText prompt)))),
          if presentationPersonSubmitted presentation
            then withAttr (attrName "selected") (displayText (if presentationService presentation
              then "Answer sent to the manager; waiting for its observed effect..."
              else "Answer accepted locally; waiting for delivered acknowledgement..."))
            else vLimit (max 3 (min 8 (mainHeight - promptHeight - 4))) (borderWithLabel (displayText " Answer • ") (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation))),
          maybe emptyWidget (withAttr (attrName "error") . displayTextWrap . ("ERROR: " <>)) (presentationPersonError presentation)
        ]
    where
      promptHeight = max 1 (mainHeight `div` 3)

recoveryView :: Presentation -> Int -> Int -> Widget Name
recoveryView presentation width mainHeight = case presentationRecovery presentation of
  Nothing -> withAttr (attrName "error") (displayText "ERROR: recovery decision unavailable")
  Just (occurrence, recovery) ->
    let request =
          "Request "
            <> shown (toInteger (occurrenceNumber (snapshotOccurrenceId occurrence)) + 1)
            <> " · "
            <> snapshotOccurrenceAddressee occurrence
        message = snapshotRecoveryMessage recovery
        contentWidth = confirmationInnerWidth width
        contentHeight = sum (map (length . wrapDisplayLines contentWidth) [request, message])
        choices = snapshotRecoveryChoices recovery
        -- Service mode offers the key of a choice only when the control
        -- observation offers that choice. Other published choices are
        -- shown as not offered.
        offered = presentationServiceRecoveryOffers presentation
        unoffered = [recoveryChoice option | option <- choices, recoveryChoice option `notElem` offered]
        actions
          | presentationService presentation, not (null offered) =
              T.intercalate "   " ([recoveryKeyText choice <> " " <> T.toUpper choice | choice <- offered]
                <> ["Not offered: " <> T.intercalate ", " unoffered | not (null unoffered)])
          | presentationService presentation = "Choices (not offered by the manager): " <> T.intercalate ", " (map recoveryChoice choices)
          | otherwise = T.intercalate "   " [recoveryKeyText (recoveryChoice option) <> " " <> recoveryChoice option | option <- choices]
     in dialog width (min mainHeight (contentHeight + 4)) " Recovery required " $
          vBox
            [ viewport RecoveryViewport Vertical $ vBox
                [ muted (displayTextWrap request),
                  withAttr (attrName "error") (displayTextWrap message)
                ],
              muted hBorder,
              shortcutLine actions
            ]

steerView :: Presentation -> Int -> Int -> Widget Name
steerView presentation width mainHeight = case presentationSteerTiming presentation of
  Nothing -> withAttr (attrName "error") (displayText "ERROR: steering mode unavailable")
  Just timing ->
    let editorRows = min 7 (2 + length (Edit.getEditContents (presentationEditor presentation)))
     in vBox
          [ vLimit (max 1 (mainHeight - editorRows - 2)) (maybe emptyWidget (liveView presentation width (mainHeight + 5)) (modelSnapshot (presentationModel presentation))),
            pane ("Steer · " <> steeringTimingText timing <> " [focus]")
              (vLimit editorRows (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation))),
            maybe emptyWidget (withAttr (attrName "error") . displayTextWrap) (presentationControlError presentation)
          ]

keyHelpView :: Presentation -> Int -> Int -> Widget Name
keyHelpView presentation width mainHeight =
  dialog width mainHeight " Keyboard shortcuts " $
    vBox (serviceNoticeWidgets presentation width <> [viewport KeyHelpViewport Vertical (vBox (map displayTextWrap (keyHelpLines presentation)))])

keyHelpLines :: Presentation -> [Text]
keyHelpLines presentation = case modelScreen model of
  BrowserScreen | presentationService presentation ->
    ["Up/Down select"] <> ["Enter creates a manager request" | not faulted]
      <> ["Right/Left focus details/list", "h workflow help", "O manager overview", "D manager decisions", "H manager history", "Esc profiles",
        "E manager endpoints", "q detach",
        "? or Esc close this help"]
  ServiceOverviewScreen -> ["Up/Down select", "Enter opens the selected request or run", "Right/Left focus details/list", "g reads the overview again", "Esc workflows",
    "E manager endpoints", "q detach", "? or Esc close this help"]
  ServiceDecisionsScreen -> ["Up/Down select", "Enter opens the run at the selected decision head", "Right/Left focus details/list",
    "g reads the decision heads again", "Esc workflows", "E manager endpoints", "q detach", "? or Esc close this help"]
  ServiceHistoryScreen -> ["Up/Down select", "Home/End first or last run", "Enter opens the read-only detail of the selected run",
    "Right/Left focus details/list", "g reads the run list again", "Esc workflows", "E manager endpoints", "q detach", "? or Esc close this help"]
  ServiceHistoryRunScreen _ -> ["r retrieves the verified result of a succeeded run", "s saves the retrieved result to a new absolute path",
    "e exports the verified result of a succeeded run under a new name",
    "l opens the lineage menu: restart, resume or fork of the run",
    "g reads the run detail again", "Up/Down scroll", "Esc returns to the history", "E manager endpoints", "q detach", "? or Esc close this help"]
  BrowserScreen ->
    [ "Up/Down       select",
      "Right/Left    focus details/list",
      "Tab           next Workflows/Runs/Routing section"
    ]
      <> browserKeys
      <> ownershipKeys
      <> ["? or Esc      close this help"]
  ServiceProfilesScreen _ _ -> ["Up/Down select profile", "Right/Left focus details/list", "Enter select ready profile", "r refresh profiles", "E manager endpoints", "q detach", "? or Esc close this help"]
  ServiceRequestScreen _ -> ["Enter requests review when the draft is ready" | not faulted] <> ["e edits draft inputs" | not faulted]
    <> ["W withdraws a draft or queued request after a confirmation" | not faulted]
    <> ["g refreshes observations", "Esc returns to the manager overview", "E manager endpoints", "q detaches without cancelling the manager run"]
  ServiceReviewScreen {} -> ["y approves the exact visible selectors" | not faulted]
    <> ["X discards the review after a confirmation" | not faulted]
    <> ["Enter does not approve", "d toggles complete review details", "Up/Down scroll details", "q detaches"]
  ServiceCommandScreen _ -> ["g refreshes observations without sending a mutation"]
    <> ["x requests confirmation of an exact resend" | Just (_,_,True) <- [presentationServiceMutation presentation]] <> ["q detaches"]
  InitialLoading -> ["q or Esc      cancel discovery and quit", "? or Esc      close this help"]
  TargetScreen -> ["Up/Down scroll", "p persona", "s scripted review", "l or Enter routing review", "Esc previous", "? or Esc close this help"]
  HelpLoading -> ["Esc cancel bounded help load", "? or Esc close this help"]
  HelpScreen _ -> ["Up/Down or PgUp/PgDn scroll", "Esc return to browser", "? or Esc close this help"]
  PreviewLoading -> ["Esc cancel bounded preview", "? or Esc close this help"]
  ConfirmScreen _
    | presentationExactDetails presentation -> ["Up/Down or PgUp/PgDn scroll", "Home/End first/last", "Enter or y launch", "n return to target", "d return to summary", "? or Esc close this help"]
    | otherwise -> ["Enter or y launch", "n return to target", "d exact details", "? or Esc close this help"]
  ProcessLoading _ -> ["Esc cancel startup safely", "? or Esc close this help"]
  LaunchingScreen _ -> ["Esc detach", "c cancel owned run", "? or Esc close this help"]
  LiveScreen _
    | presentationService presentation ->
        ["d full run details and error", "Tab focus pane", "Up/Down move or scroll", "j/k select occurrence", "G follow output",
         "g refreshes observations"] <> ["r retries the recovery that the manager offers" | "retry" `elem` presentationServiceRecoveryOffers presentation]
          <> ["f fails over the recovery that the manager offers" | "failover" `elem` presentationServiceRecoveryOffers presentation]
          <> ["a abandons the recovery that the manager offers" | "abandon" `elem` presentationServiceRecoveryOffers presentation]
          <> ["c cancels the run after a confirmation" | "c CANCEL" `elem` presentationServiceRunKeys presentation]
          <> ["i or b opens the steer editor for interrupt-now or next-boundary" | "i/b STEER" `elem` presentationServiceRunKeys presentation]
          <> ["1 to 9 redirect the occurrence of the redirect line to that offered target" | "1-9 REDIRECT" `elem` presentationServiceRunKeys presentation]
          <> ["s saves the verified result bytes to a new file" | presentationServiceSavable presentation]
          <> ["e exports the verified result under a new name" | presentationServiceExportable presentation]
          <> ["l opens the lineage menu: restart, resume or fork of the run" | presentationServiceLineageOffered presentation]
          <> ["Esc returns to the manager overview; the manager run continues", "q detaches; the manager run continues", "? or Esc close this help"]
  LiveScreen _ ->
    ["d full run details and error", "Tab focus pane", "Up/Down move or scroll", "j/k select occurrence", "G follow output"]
      <> [hint | hint <- [liveResultHint presentation, controlHintLine presentation, if presentationRunning presentation then "c cancel owned run" else ""], not (T.null hint)]
      <> ["Esc return to Runs", "? or Esc close this help"]
  FailureScreen _ -> ["Up/Down or PgUp/PgDn scroll", "Home/End first/last", "Esc return to browser", "? or Esc close this help"]
  InputScreen _ -> []
  where
    model = presentationModel presentation
    faulted = presentationServiceFault presentation
    browserKeys
      | presentationRunning presentation = []
      | otherwise = case modelTab model of
          WorkflowsTab -> ["Enter         configure workflow", "/             filter workflows", "h             workflow help"]
          RunsTab -> ["Enter         inspect run", "r/m/f         restart, resume, or fork"]
          RoutingTab -> ["p             next routing persona"]
    ownershipKeys
      | presentationRunning presentation = ["Enter or Esc  reattach owned run", "c             cancel owned run"]
      | otherwise = ["q             quit"]

liveView :: Presentation -> Int -> Int -> RunSnapshot -> Widget Name
liveView presentation width totalHeight snapshot = vBox (failureBanner <> banner <> body)
  where
    body
      | Map.null (snapshotOccurrences snapshot) && not (null failureBanner) = [displayText "No workflow requests started."]
      | otherwise = [panes]
    -- In service mode the service lines stand above the live monitor, so the
    -- banner limit counts their screen rows.
    serviceRows
      | presentationService presentation = sum (map (length . wrapDisplayLines width) (serviceLiveLines presentation))
      | otherwise = 0
    failureBanner = case snapshotRunFailure snapshot of
      Nothing -> []
      Just failure ->
        let rows = wrapDisplayLines width (T.takeWhile (/= '\n') (T.strip failure))
            limit = max 1 (min 6 (shellMainRows (isJust (presentationServiceEndpoint presentation)) width totalHeight - serviceRows - if Map.null (snapshotOccurrences snapshot) then 4 else 6))
         in [ withAttr (attrName "error") (displayText ("Run " <> T.toLower (runStatusLabel (snapshotRunStatus snapshot)))),
              vBox (map displayText (take limit rows))
            ]
              <> [displayText "... d DETAILS for the complete error" | length rows > limit]
              <> [displayText ""]
    wide = width >= 72 && totalHeight >= 16
    primaryFocused = presentationPaneFocus presentation == PrimaryPane
    occurrencePane = pane ("Requests" <> focusMark primaryFocused) (viewport OccurrenceViewport Vertical (vBox (map occurrenceRow (occurrenceRowsWithSelection snapshot (presentationRunView presentation)))))
    outputPane = pane (outputTitle presentation snapshot <> focusMark (not primaryFocused)) $
      vBox [maybe emptyWidget requestContext (selectedOccurrence snapshot (presentationRunView presentation)), viewport OutputViewport Vertical (vBox outputWidgets)]
    requestContext occurrence
      | presentationShowResult presentation = emptyWidget
      | otherwise = vBox
          [ muted (displayTextWrap (snapshotOccurrenceAddressee occurrence)),
            maybe emptyWidget (\(_, attempt) -> muted (displayTextWrap (occurrenceStateLabel (snapshotOccurrenceState occurrence) <> " on " <> snapshotAttemptTarget attempt))) (Map.lookupMax (snapshotOccurrenceAttempts occurrence)),
            case snapshotOccurrenceDispatch occurrence of
              Just dispatch | dispatchOpen dispatch, not (presentationService presentation) -> shortcutLine ("Routes   " <> T.intercalate "   " [shown index <> " " <> target | (index, target) <- zip [1 :: Int ..9] (dispatchTargets dispatch)])
              _ -> emptyWidget,
            displayText ""
          ]
    listWidth = min 32 (max 18 (width `div` 4))
    panes
      | wide = hBox [hLimit listWidth occurrencePane, muted vBorder, outputPane]
      | primaryFocused = occurrencePane
      | otherwise = outputPane
    occurrenceRow (selected, line) =
      let widget = vBox (map (displayText . oneLine ((if wide then listWidth else width) - 2)) (T.lines line))
       in if selected then visible (withAttr (attrName "selected") (padRight Max widget)) else muted widget
    outputWidgets
      | presentationShowResult presentation = readingWidgets (finalResultLines presentation)
      | otherwise = readingWidgets (selectedOutputLines snapshot (presentationRunView presentation))
    banner = case snapshotResult snapshot of
      Just _ | not (presentationService presentation) -> [withAttr (attrName "selected") (displayText (resultBanner presentation))]
      _ -> []

outputTitle :: Presentation -> RunSnapshot -> Text
outputTitle presentation snapshot
  | presentationShowResult presentation = "Result"
  | otherwise = "Output" <> maybe "" (\occurrence -> " · Request " <> shown (toInteger (occurrenceNumber (snapshotOccurrenceId occurrence)) + 1)) (selectedOccurrence snapshot (presentationRunView presentation)) <> if presentationOutputFollow presentation then " · Follow" else " · Paused"

resultBanner :: Presentation -> Text
resultBanner presentation
  | presentationFinalLoading presentation = "RESULT AVAILABLE - verifying private artifact"
  | Just (Left _) <- presentationFinalResult presentation = "RESULT AVAILABLE - verification failed"
  | otherwise = "RESULT AVAILABLE - r displays it; s saves a verified copy"

finalResultLines :: Presentation -> [Text]
finalResultLines presentation = case presentationFinalResult presentation of
  Nothing
    | presentationFinalLoading presentation -> ["Loading and verifying private result artifact..."]
    | otherwise -> ["The result reference is available; verification has not started."]
  Just (Left failure) -> ["ERROR: " <> failure]
  Just (Right (String value)) -> T.lines (boundedDisplay value)
  Just (Right value) -> T.lines (boundedDisplay (TE.decodeUtf8 (BL.toStrict (encode value))))

liveContext :: Presentation -> Text
liveContext presentation = case modelSnapshot model of
  Nothing | presentationService presentation ->
              maybe "" (<> " | ") (presentationServiceRun presentation >>= Service.runWorkflow) <> "runtime not yet observed"
          | otherwise -> "waiting for run.started"
  Just snapshot ->
    fromMaybe "starting" (snapshotWorkflow snapshot)
      <> " | "
      <> (if presentationLayer presentation == PersonLayer then "Waiting for your answer" else if any ((== OccurrenceRecoveringState) . snapshotOccurrenceState) (Map.elems (snapshotOccurrences snapshot)) then "Recovery required" else runStatusLabel (snapshotRunStatus snapshot))
      <> " elapsed " <> presentationElapsed presentation
      <> billText snapshot
  where
    model = presentationModel presentation

runDetailsText :: Presentation -> RunSnapshot -> Text
runDetailsText presentation snapshot = T.unlines
  ( snapshotLines snapshot
      <> (if presentationService presentation then []
            else ["", "persona: " <> fromMaybe "none" (presentationRunPersona presentation), "realization: " <> fromMaybe "pending" (presentationRunRealization presentation)])
      <> concat ["" : selectedOccurrenceLines snapshot (RunView (Just occurrence)) | occurrence <- Map.keys (snapshotOccurrences snapshot)]
  )

billText :: RunSnapshot -> Text
billText snapshot = case (snapshotBillFresh snapshot, snapshotBillMemo snapshot) of
  (Nothing, Nothing) -> ""
  (fresh, memo) -> " | bill " <> maybe "?" shown fresh <> " fresh / " <> maybe "?" shown memo <> " memo"

footerItems :: Presentation -> Int -> Int -> [Text]
footerItems presentation width height
  | Just _ <- presentationServiceConfirm presentation = ["y CONFIRM", "n/Esc BACK", "q DETACH"]
  | otherwise = case presentationLayer presentation of
  EndpointsLayer -> ["Up/Down SELECT", "Enter CONNECT", "Esc BACK", "q DETACH"]
  KeyHelpLayer -> ["Esc CLOSE", "Up/Down SCROLL", "PgUp/PgDn", "Home/End"]
  CancelLayer -> ["n/Esc KEEP RUNNING", "y CANCEL RUN"]
  PersonLayer
    | presentationService presentation, presentationPersonSubmitted presentation -> ["WAITING FOR THE MANAGER EFFECT", "Ctrl-C DETACH"]
    | presentationService presentation -> ["Ctrl-D SEND ANSWER", "Enter newline", "PgUp/PgDn prompt", serviceBackLabel presentation, "Ctrl-C DETACH"]
    | Nothing <- presentationPersonPrompt presentation -> ["Esc CANCEL RUN", "LOADING VERIFIED QUESTION"]
    | presentationPersonSubmitted presentation -> ["Esc CANCEL RUN", "WAITING FOR DELIVERY"]
    | otherwise -> ["Esc CANCEL RUN", "Ctrl-D SUBMIT", "Enter newline", "PgUp/PgDn prompt"]
  RecoveryLayer
    | presentationService presentation, offered@(_ : _) <- presentationServiceRecoveryOffers presentation ->
        [recoveryKeyText choice <> " " <> T.toUpper choice | choice <- offered] <> presentationServiceRunKeys presentation
          <> ["d DETAILS", "g REFRESH", serviceBackLabel presentation, "? KEYS", "q DETACH"]
    | presentationService presentation -> ["NO RECOVERY OFFERED"] <> presentationServiceRunKeys presentation
        <> ["d DETAILS", "g REFRESH", serviceBackLabel presentation, "? KEYS", "q DETACH"]
    | otherwise -> recoveryItems presentation <> ["c CANCEL RUN", "PgUp/PgDn scroll"]
  SteerLayer -> ["Esc CLOSE", "Ctrl-D SEND", "Enter newline"]
  SaveLayer -> ["Esc CANCEL", "Ctrl-D SAVE"] <> ["PgUp/PgDn ERROR" | Just _ <- [presentationSaveError presentation]]
  ExportLayer -> ["Esc CANCEL", "Ctrl-D EXPORT"]
  LineageLayer -> case presentationLineageMode presentation of
    Just Service.LineageForking -> ["Esc BACK", "Up/Down SELECT", "d DROP", "Enter REPLACE", "k KEEP", "Ctrl-D SEND FORK"]
    Just Service.LineageReplacing -> ["Esc CANCEL", "Ctrl-D SET ANSWER"]
    _ -> ["Esc CLOSE"] <> [key <> " " <> T.toUpper name | (key, name) <- [("r","restart"),("s","resume"),("f","fork")],
      name `elem` presentationLineageEligible presentation]
  CaptureFileLayer -> ["Esc CANCEL", "Ctrl-D CAPTURE FILE"]
  FilterLayer -> ["Enter APPLY", "Esc CANCEL"]
  ConfirmDetailsLayer -> confirmItems True
  ConfirmLayer -> confirmItems False
  RunDetailsLayer -> ["Esc/d CLOSE", "Up/Down SCROLL", "PgUp/PgDn", "Home/End"]
  ScreenLayer -> screenItems
  where
    compact = width < 72 || height < 16
    allowed = case (presentationConfig presentation,confirmPreview presentation) of
      (Just config,Just preview) -> launchReviewAllowed config preview (width, height)
      _ -> False
    recoveryItems current = case presentationRecovery current of
      Nothing -> []
      Just (_, recovery) -> [recoveryKeyText (recoveryChoice option) <> " " <> T.toUpper (recoveryChoice option) | option <- snapshotRecoveryChoices recovery]
    confirmItems showingDetails
      | allowed = ["Enter/y LAUNCH", "n/Esc BACK", "d " <> detailsLabel, "? KEYS"]
      | width < 32 = ["n BACK d " <> detailsLabel <> " RESIZE"]
      | otherwise = ["RESIZE TO REVIEW", "n/Esc BACK", "d " <> detailsLabel, "? KEYS"]
      where
        detailsLabel = if showingDetails then "SUMMARY" else "DETAILS"
    model = presentationModel presentation
    screenItems = case modelScreen model of
      InitialLoading -> ["q/Esc QUIT"]
      ServiceProfilesScreen _ _ -> ["Enter SELECT", "r REFRESH", browserPaneHint, "? KEYS", "q DETACH", "E ENDPOINTS"]
      ServiceOverviewScreen -> ["Enter OPEN", "g REFRESH", "Esc WORKFLOWS", browserPaneHint, "? KEYS", "q DETACH", "E ENDPOINTS"]
      ServiceDecisionsScreen -> ["Enter OPEN RUN", "g REFRESH", "Esc WORKFLOWS", browserPaneHint, "? KEYS", "q DETACH", "E ENDPOINTS"]
      ServiceHistoryScreen -> ["Enter OPEN RUN", "g REFRESH", "Home/End", "Esc WORKFLOWS", browserPaneHint, "? KEYS", "q DETACH", "E ENDPOINTS"]
      ServiceHistoryRunScreen _ -> ["r RETRIEVE RESULT"] <> saveItem <> exportItem <> lineageItem <> ["g REFRESH", "Esc HISTORY", "? KEYS", "q DETACH", "E ENDPOINTS"]
      ServiceRequestScreen request ->
        ["g REFRESH", "q DETACH"] <> [serviceBackLabel presentation | presentationServiceMutation presentation == Nothing]
          <> (if Manager.draftPhase request == "draft" && presentationServiceMutation presentation == Nothing
                && not (presentationServiceFault presentation)
              then ["e EDIT INPUTS"] <> ["Enter REQUEST REVIEW" | Service.requestReady request] else [])
          <> ["W WITHDRAW" | Manager.draftPhase request `elem` ["draft","queued"], presentationServiceMutation presentation == Nothing,
                not (presentationServiceFault presentation)]
      ServiceReviewScreen preparation tag -> ["d EXACT DETAILS", "q DETACH"] <>
        ["y APPROVE EXACT REVIEW" | presentationServiceApprovalOffered presentation]
        <> ["X DISCARD" | presentationServiceMutation presentation == Nothing, not (presentationServiceFault presentation)]
        <> ["RESIZE TO REVIEW" | not (serviceReviewAllowed preparation tag (width,height))]
      ServiceCommandScreen _ -> ["g REFRESH", "q DETACH"] <>
        ["x EXACT RESEND" | Just (_,_,True) <- [presentationServiceMutation presentation]]
      BrowserScreen
        | presentationService presentation -> ["h HELP", "O OVERVIEW", "D DECISIONS", "H HISTORY", "Esc PROFILES", browserPaneHint, "? KEYS", "q DETACH"]
            <> ["Enter NEW REQUEST" | presentationServiceMutation presentation == Nothing, not (presentationServiceFault presentation)]
            <> ["E ENDPOINTS"]
        | presentationRunning presentation -> ["Esc REATTACH", "c CANCEL RUN", "Tab SECTION", "? KEYS", browserPaneHint]
        | compact -> ["Enter OPEN", browserPaneHint, "? KEYS", "Tab SECTION", "q QUIT"] <> case modelTab model of WorkflowsTab -> ["/ FILTER"]; RunsTab -> ["r/m/f LINEAGE"]; RoutingTab -> ["p PERSONA"]
        | modelTab model == RunsTab -> ["Enter INSPECT", "r RESTART", "m RESUME", "f FORK", "Tab SECTION", "? KEYS", "q QUIT"]
        | modelTab model == RoutingTab -> ["p PERSONA", "Tab SECTION", browserPaneHint, "? KEYS", "q QUIT"]
        | otherwise -> ["Enter CONFIGURE", "/ FILTER", "Tab SECTION", browserPaneHint, "? KEYS", "q QUIT"]
      InputScreen index -> [if index == 0 then "Esc CANCEL" else "Esc PREVIOUS", "Ctrl-D CONTINUE", "Enter newline"]
        <> (if presentationService presentation then ["Ctrl-T CAPTURE TEXT", "Ctrl-O CAPTURE FILE", "Ctrl-R REMOVE INPUT"] else [])
      TargetScreen -> ["Esc BACK", "s SCRIPTED", "l/Enter ROUTING", "Up/Down SCROLL", "p PERSONA", "? KEYS"]
      HelpLoading -> ["Esc CANCEL"]
      HelpScreen _ -> ["Esc BACK", "Up/Down SCROLL", "PgUp/PgDn", "Home/End", "? KEYS"]
      PreviewLoading -> ["Esc CANCEL"]
      ConfirmScreen _ -> confirmItems False
      ProcessLoading _ -> ["Esc CANCEL STARTUP"]
      LaunchingScreen _ -> ["Esc DETACH", "c CANCEL RUN", "? KEYS"]
      LiveScreen _ | presentationService presentation, compact -> ["q DETACH", serviceBackLabel presentation] <> presentationServiceRunKeys presentation
                       <> ["Tab PANE", "d DETAILS", "? KEYS"] <> saveItem
                   | presentationService presentation -> ["q DETACH", serviceBackLabel presentation] <> presentationServiceRunKeys presentation
                       <> saveItem <> exportItem <> lineageItem <> ["g REFRESH", "d DETAILS", compactNavigation, "? KEYS"]
      LiveScreen _ | compact ->
        ["Esc " <> if presentationRunning presentation then "DETACH" else "RUNS", "Tab PANE", "d DETAILS", "? KEYS"]
          <> ["c CANCEL" | presentationRunning presentation]
          <> ["r RESULT  s SAVE" | Just (Right _) <- [presentationFinalResult presentation]]
      LiveScreen _ ->
        ["Esc " <> if presentationRunning presentation then "DETACH" else "RUNS"]
          <> ["c CANCEL RUN" | presentationRunning presentation]
          <> filter (not . T.null) [liveResultHint presentation, compactControlHint presentation]
          <> ["d DETAILS", compactNavigation, "? KEYS"]
      FailureScreen _ -> ["Esc BACK", "Up/Down SCROLL", "PgUp/PgDn", "Home/End", "? KEYS"]
    saveItem = ["s SAVE RESULT" | presentationServiceSavable presentation]
    exportItem = ["e EXPORT" | presentationServiceExportable presentation]
    lineageItem = ["l LINEAGE" | presentationServiceLineageOffered presentation]
    browserPaneHint = case presentationPaneFocus presentation of
      PrimaryPane -> "Right DETAILS"
      SecondaryPane -> "Left LIST"
    compactNavigation
      | compact = "Tab PANE / G FOLLOW"
      | otherwise = "Tab PANE / Up/Down MOVE-SCROLL / G FOLLOW"

compactControlHint :: Presentation -> Text
compactControlHint presentation = case modelSnapshot (presentationModel presentation) of
  Nothing -> ""
  Just snapshot -> case selectedOccurrence snapshot (presentationRunView presentation) of
    Nothing -> ""
    Just occurrence -> T.unwords (filter (not . T.null) [steer snapshot, redirect occurrence])
  where
    steer snapshot = maybe "" (const "i/b steer") (activeAttemptForSelection snapshot (presentationRunView presentation))
    redirect occurrence = case snapshotOccurrenceDispatch occurrence of
      Just dispatch | dispatchOpen dispatch -> "1-9 route"
      _ -> ""

liveResultHint :: Presentation -> Text
liveResultHint presentation = case presentationFinalResult presentation of
  Just (Right _) -> "r result   s save verified copy"
  Just (Left _) -> "r result verification error"
  Nothing -> ""

controlHintLine :: Presentation -> Text
controlHintLine presentation = case modelSnapshot model of
  Nothing -> ""
  Just snapshot -> case selectedOccurrence snapshot (presentationRunView presentation) of
    Nothing -> ""
    Just occurrence ->
      T.unwords
        ( filter
            (not . T.null)
            [ maybe "" (const "i steer now   b next boundary") (activeAttemptForSelection snapshot (presentationRunView presentation)),
              recoveryHints occurrence,
              redirectHints occurrence
            ]
        )
  where
    model = presentationModel presentation
    recoveryHints occurrence = case snapshotOccurrenceRecovery occurrence of
      Nothing -> ""
      Just pending -> T.unwords [recoveryKeyText (recoveryChoice choice) <> " " <> recoveryChoice choice | choice <- snapshotRecoveryChoices pending]
    redirectHints occurrence = case snapshotOccurrenceDispatch occurrence of
      Just dispatch
        | dispatchOpen dispatch -> T.unwords [shown index <> " " <> target | (index, target) <- zip [1 :: Int .. 9] (take 9 (dispatchTargets dispatch))]
      _ -> ""

-- | The footer label of Esc on the live monitor and the request screen of
-- the service frontend: the service list view that Esc returns to.
serviceBackLabel :: Presentation -> Text
serviceBackLabel presentation = case modelServiceList (presentationModel presentation) of
  OverviewList -> "Esc OVERVIEW"
  DecisionsList -> "Esc DECISIONS"

recoveryKeyText :: Text -> Text
recoveryKeyText "retry" = "r"
recoveryKeyText "failover" = "f"
recoveryKeyText "abandon" = "a"
recoveryKeyText _ = "?"

screenTitle :: Screen -> Text
screenTitle = \case
  InitialLoading -> "loading"
  BrowserScreen -> "browser"
  ServiceProfilesScreen _ _ -> "manager profiles"
  ServiceOverviewScreen -> "manager overview"
  ServiceDecisionsScreen -> "manager decisions"
  ServiceHistoryScreen -> "manager history"
  ServiceHistoryRunScreen _ -> "manager run detail"
  ServiceRequestScreen _ -> "manager request"
  ServiceReviewScreen {} -> "exact manager review"
  ServiceCommandScreen _ -> "manager command"
  InputScreen _ -> "configure"
  TargetScreen -> "configure / target"
  HelpLoading -> "workflow help"
  HelpScreen _ -> "workflow help"
  PreviewLoading -> "review / loading"
  ConfirmScreen _ -> "launch confirmation"
  ProcessLoading _ -> "launch / starting"
  LaunchingScreen _ -> "launching"
  LiveScreen _ -> "live"
  FailureScreen _ -> "error"

dialog :: Int -> Int -> Text -> Widget Name -> Widget Name
dialog width height title body =
  hCenter $
    hLimit (max 1 (min 84 width)) $
      vLimit (max 1 height) $
        borderWithLabel (withAttr (attrName "title") (displayText title)) (padLeftRight 1 body)

confirmPreview :: Presentation -> Maybe LaunchPreview
confirmPreview presentation = case modelScreen (presentationModel presentation) of
  ConfirmScreen preview -> Just preview
  ProcessLoading preview -> Just preview
  _ -> Nothing

launchReviewAllowed :: TuiConfig -> LaunchPreview -> (Int, Int) -> Bool
launchReviewAllowed config preview (width, height) =
  confirmationActionsFit width height
    && confirmationRequiredRows config preview width <= confirmationBodyRows width height

confirmationActionsFit :: Int -> Int -> Bool
confirmationActionsFit width height =
  width > 0
    && all ((<= width) . displayWidth) actions
    && length (packFooterRows width actions) <= shellFooterRows height
  where
    actions = ["Enter/y LAUNCH", "n/Esc BACK", "d DETAILS"]

confirmationRequiredRows :: TuiConfig -> LaunchPreview -> Int -> Int
confirmationRequiredRows config preview width =
  sum [length (wrapDisplayLines (confirmationInnerWidth width) line) | (line, _) <- confirmationSummary config preview]

confirmationBodyRows :: Int -> Int -> Int
confirmationBodyRows width height = max 0 (shellMainRows False width height - 2)

confirmationInnerWidth :: Int -> Int
confirmationInnerWidth width = max 1 (min 84 width - 4)

previewIsLive :: LaunchPreview -> Bool
previewIsLive preview = case previewTarget preview of
  TargetScripted -> False
  TargetRestored kind _ -> kind /= "scripted"
  TargetRouting {} -> True

billingText :: LaunchPreview -> Text
billingText preview
  | previewIsLive preview = "LIVE BACKEND: PROVIDER CHARGES MAY APPLY"
  | otherwise = "SCRIPTED: no external backend is contacted"

billingCompactText :: LaunchPreview -> Text
billingCompactText preview
  | previewIsLive preview = "LIVE BACKEND: CHARGES MAY APPLY"
  | otherwise = "SCRIPTED: no external backend"

billingAttribute :: LaunchPreview -> Text
billingAttribute preview = if previewIsLive preview then "warning" else "selected"

targetSummary :: LaunchPreview -> Text
targetSummary = targetFull

targetFull :: LaunchPreview -> Text
targetFull preview = case previewLineage preview of
  Just (_, record) -> frontendTargetKind (recordManifest record) <> " restored from " <> runIdText (frontendRunId (recordManifest record))
  Nothing -> case previewTarget preview of
    TargetScripted -> "scripted"
    TargetRestored kind _ -> kind <> " (restored)"
    TargetRouting _ _ _ -> "routing (full pin coverage required)"

personaText :: LaunchPreview -> Text
personaText preview = case previewLineage preview of
  Just (_, record) -> fromMaybe "none" (frontendPersona (recordManifest record))
  Nothing -> case previewTarget preview of
    TargetRouting persona _ _ -> persona <> source
      where
        source = case previewRouting preview >>= routingSummaryPersonaSource of
          Nothing -> ""
          Just value -> " (" <> value <> ")"
    _ -> "none"

lineageCompact :: LaunchPreview -> Text
lineageCompact preview = case previewLineage preview of
  Nothing -> ""
  Just (operation, record) -> " / " <> lineageText operation <> " from " <> runIdText (frontendRunId (recordManifest record))

lineageDetails :: LaunchPreview -> Text
lineageDetails preview = case previewLineage preview of
  Nothing -> "root"
  Just (operation, record) -> lineageText operation <> " from " <> runIdText (frontendRunId (recordManifest record))

lineageText :: LineageOperation -> Text
lineageText RootRun = "root"
lineageText RestartRun = "restart"
lineageText ResumeRun = "resume"
lineageText ForkRun = "fork"

previewWorkingDirectory :: TuiConfig -> LaunchPreview -> FilePath
previewWorkingDirectory config preview = maybe (tuiWorkingDir config) (frontendCwd . recordManifest . snd) (previewLineage preview)

previewTargetArguments :: LaunchPreview -> Either Text [String]
previewTargetArguments preview = case previewLineage preview of
  Just (_, record) -> Right (map T.unpack (frontendTargetArgs (recordManifest record)))
  Nothing -> targetArguments (previewTarget preview)

launchFingerprint :: LaunchPreview -> Text
launchFingerprint preview = case previewTarget preview of
  TargetRouting _ _ fingerprint -> fingerprint
  _ -> "none"

relevantProfiles :: LaunchPreview -> [RoutingProfileChoice]
relevantProfiles preview = case previewRouting preview of
  Nothing -> []
  Just routing -> routingProfilesForPlan (previewPlan preview) routing

relevantRoutingCompact :: LaunchPreview -> Text
relevantRoutingCompact preview = case previewTarget preview of
  TargetScripted -> "not used for scripted execution"
  TargetRestored {} -> "retained by restored target arguments"
  TargetRouting {}
    | null pins -> "no declared pins"
    | null profiles -> commaOrNone pins <> " (no matching inspected profile)"
    | otherwise -> T.intercalate "; " (map profileChain profiles)
  where
    pins = workflowPins (exactPlanDescriptor (previewPlan preview))
    profiles = relevantProfiles preview
    profileChain profile = routingProfileName profile <> " -> " <> T.intercalate " -> " (map routingRungModel (routingProfileRungs profile))

planRange :: LaunchPreview -> Text
planRange preview = bound (workflowMinFold descriptor) <> ".." <> bound (workflowMaxFold descriptor)
  where
    descriptor = exactPlanDescriptor (previewPlan preview)
    bound = maybe "none" shown

foldHistogram :: ExactPlanSummary -> Text
foldHistogram plan = case exactPlanFold plan of
  [] -> "none"
  folds -> T.intercalate ", " [shown (planFoldConsults fold) <> " consults x " <> shown (planFoldPaths fold) <> " paths" | fold <- folds]

inputDetails :: WorkflowDescriptor -> Text
inputDetails descriptor = case workflowInputs descriptor of
  [] -> "none"
  values -> T.intercalate ", " [workflowInputName input <> " (" <> inputSourceText (workflowInputSource input) <> ")" | input <- values]

inputSourceText :: WorkflowInputSource -> Text
inputSourceText DescriptorPrompt = "prompt"
inputSourceText DescriptorCommandTail = "command tail"
inputSourceText DescriptorStdin = "standard input"

readinessText :: EngineChoice -> Text
readinessText engine = if engineChoiceCredentialReady engine then "READY (offline)" else "NOT READY"

displayText :: Text -> Widget name
displayText value = txt (if T.null value then " " else safeDisplay value)

displayTextWrap :: Text -> Widget name
displayTextWrap value = Widget Greedy Fixed $ do
  context <- getContext
  render (vBox (map (padRight Max . displayText) (wrapDisplayLines (availWidth context) value)))

safeDisplay :: Text -> Text
safeDisplay = T.map $ \character ->
  if character == '\n' || not (isControl character)
    then character
    else '\xfffd'

wrapDisplayLines :: Int -> Text -> [Text]
wrapDisplayLines width value
  | width <= 0 = []
  | otherwise = concatMap (wrapLine width . displayClusters) (T.splitOn "\n" (safeDisplay value))

wrapLine :: Int -> [(Text, Int)] -> [Text]
wrapLine _ [] = [""]
wrapLine width clusters = go clusters
  where
    go [] = []
    go remaining =
      let (fitting, rest) = takeClusters width remaining
       in case rest of
            [] -> [clusterText fitting]
            _ -> case lastWordBreak fitting of
              Nothing -> clusterText fitting : go rest
              Just index ->
                let before = take index fitting
                    after = dropWhile clusterSpace (drop index fitting <> rest)
                 in clusterText before : go after

displayClusters :: Text -> [(Text, Int)]
displayClusters = reverse . T.foldl' add []
  where
    add [] character = [(T.singleton character, characterWidth character)]
    add current@((text, width) : rest) character
      | attachToPrevious text width character = (text <> T.singleton character, width + characterWidth character) : rest
      | otherwise = (T.singleton character, characterWidth character) : current
    attachToPrevious text width character =
      characterWidth character == 0
        || width == 0
        || T.isSuffixOf "\x200d" text
        || emojiModifier character
        || regionalPair text character
    regionalPair text character = T.length text == 1 && maybe False isRegionalIndicator (fst <$> T.uncons text) && isRegionalIndicator character

characterWidth :: Char -> Int
characterWidth = max 0 . Vty.safeWcwidth

emojiModifier :: Char -> Bool
emojiModifier character = character >= '\x1f3fb' && character <= '\x1f3ff'

isRegionalIndicator :: Char -> Bool
isRegionalIndicator character = character >= '\x1f1e6' && character <= '\x1f1ff'

takeClusters :: Int -> [(Text, Int)] -> ([(Text, Int)], [(Text, Int)])
takeClusters limit = go 0 []
  where
    go _ taken [] = (reverse taken, [])
    go _ [] (cluster : rest)
      | snd cluster > limit = ([("�", 1)], rest)
    go used taken remaining@(cluster : rest)
      | used + snd cluster <= limit = go (used + snd cluster) (cluster : taken) rest
      | otherwise = (reverse taken, remaining)

lastWordBreak :: [(Text, Int)] -> Maybe Int
lastWordBreak clusters = case [index | index <- [1 .. length clusters - 1], clusterSpace (clusters !! index), any (not . clusterSpace) (take index clusters)] of
  [] -> Nothing
  values -> Just (last values)

clusterSpace :: (Text, Int) -> Bool
clusterSpace = T.all isSpace . fst

clusterText :: [(Text, Int)] -> Text
clusterText = T.stripEnd . T.concat . map fst

shortcutLine :: Text -> Widget Name
shortcutLine = hBox . intersperse (displayText "   ") . map shortcut . T.splitOn "   "
  where
    shortcut item = let (key, label) = T.breakOn " " item
                     in hBox [withAttr (attrName "key") (displayText key), if T.null label then emptyWidget else muted (displayText label)]

displayWidth :: Text -> Int
displayWidth = sum . map snd . displayClusters . safeDisplay

oneLine :: Int -> Text -> Text
oneLine width = ellipsize width . T.intercalate " / " . T.splitOn "\n" . safeDisplay

ellipsize :: Int -> Text -> Text
ellipsize width value
  | width <= 0 = ""
  | displayWidth value <= width = value
  | width == 1 = clusterText (fst (takeClusters 1 (displayClusters value)))
  | otherwise = clusterText (fst (takeClusters (width - 1) (displayClusters value))) <> "…"

packedFooter :: Int -> Int -> [Text] -> [Text]
packedFooter width rows items
  | width <= 0 || rows <= 0 = []
  | otherwise = replicate (rows - length visibleRows) " " <> visibleRows
  where
    visibleRows = take rows (packFooterRows width (map (ellipsize width) items))

packFooterRows :: Int -> [Text] -> [Text]
packFooterRows width = pack []
  where
    separator = "   "
    pack [] [] = []
    pack current [] = [T.intercalate separator (reverse current)]
    pack current (item : rest)
      | null current = pack [item] rest
      | displayWidth (T.intercalate separator (reverse (item : current))) <= width = pack (item : current) rest
      | otherwise = T.intercalate separator (reverse current) : pack [item] rest

boundedDisplay :: Text -> Text
boundedDisplay value
  | T.length value <= 262144 = value
  | otherwise = T.take 262144 value <> "\n[... display truncated; full value remains in the private run store ...]"

jsonQuoted :: Text -> Text
jsonQuoted = TE.decodeUtf8 . BL.toStrict . encode

jsonTextValue :: Value -> Text
jsonTextValue = TE.decodeUtf8 . BL.toStrict . encode

commaOrNone :: [Text] -> Text
commaOrNone [] = "none"
commaOrNone values = T.intercalate ", " values

yesNo :: Bool -> Text
yesNo True = "yes"
yesNo False = "no"

shown :: Show a => a -> Text
shown = T.pack . show


steeringTimingText :: SteeringTiming -> Text
steeringTimingText InterruptNow = "interrupt-now"
steeringTimingText NextBoundary = "next-boundary"

readingWidgets :: [Text] -> [Widget Name]
readingWidgets = go Nothing
  where
    go _ [] = []
    go (Just fence) (line : rest)
      | T.strip line == fence = muted hBorder : go Nothing rest
      | otherwise = displayTextWrap line : go (Just fence) rest
    go Nothing (line : rest)
      | "    " `T.isPrefixOf` line = displayTextWrap line : go Nothing rest
      | MarkdownFenceLine <- classifyLine line, Just (marker, _) <- T.uncons (T.stripStart line) =
          let (fence, language) = T.span (== marker) (T.stripStart line)
           in muted (hBorderWithLabel (displayText (" " <> language <> " "))) : go (Just fence) rest
      | otherwise = styledLine line : go Nothing rest

styledLine :: Text -> Widget Name
styledLine line = case classifyLine line of
  PlainLine -> displayTextWrap line
  StatusLine -> withAttr (attrName "status") (displayTextWrap line)
  MarkdownHeadingLine -> withAttr (attrName "markdown-heading") (displayTextWrap (T.stripStart (T.dropWhile (== '#') line)))
  MarkdownQuoteLine -> withAttr (attrName "markdown-quote") (displayTextWrap ("│ " <> T.stripStart (T.drop 1 (T.stripStart line))))
  MarkdownFenceLine -> muted (hBorderWithLabel (displayText (" " <> T.drop 3 (T.stripStart line) <> " ")))
  DiffHeaderLine -> withAttr (attrName "diff-header") (displayTextWrap line)
  DiffAddedLine -> withAttr (attrName "diff-added") (displayTextWrap line)
  DiffRemovedLine -> withAttr (attrName "diff-removed") (displayTextWrap line)
  DiffHunkLine -> withAttr (attrName "diff-hunk") (displayTextWrap line)

presentationAttributes :: Bool -> AttrMap
presentationAttributes noColor =
  attrMap
    Vty.defAttr
    [ (attrName "selected", styled Vty.reverseVideo Vty.bold),
      (attrName "title", semantic Vty.cyan Vty.bold),
      (attrName "muted", plainStyle Vty.dim),
      (attrName "key", semantic Vty.cyan Vty.bold),
      (attrName "success", semantic Vty.green Vty.bold),
      (attrName "error", semantic Vty.red Vty.bold),
      (attrName "warning", semantic Vty.yellow Vty.bold),
      (attrName "status", Vty.defAttr),
      (attrName "markdown-heading", semantic Vty.cyan Vty.bold),
      (attrName "markdown-quote", plainStyle Vty.underline),
      (attrName "markdown-fence", semantic Vty.magenta Vty.bold),
      (attrName "diff-header", semantic Vty.cyan Vty.bold),
      (attrName "diff-added", semanticPlain Vty.green),
      (attrName "diff-removed", semanticPlain Vty.red),
      (attrName "diff-hunk", semanticPlain Vty.magenta),
      (Edit.editAttr, Vty.defAttr),
      (Edit.editFocusedAttr, Vty.defAttr)
    ]
  where
    semantic color emphasis
      | noColor = plainStyle emphasis
      | otherwise = Vty.withStyle (fg color) emphasis
    semanticPlain color
      | noColor = Vty.defAttr
      | otherwise = fg color
    plainStyle = Vty.withStyle Vty.defAttr
    styled first second = Vty.withStyle (plainStyle first) second

atMay :: [a] -> Int -> Maybe a
atMay values index
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing
