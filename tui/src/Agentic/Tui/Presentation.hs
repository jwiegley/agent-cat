{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Responsive, pure Brick presentation for the terminal frontend.
module Agentic.Tui.Presentation
  ( Name (..),
    PaneFocus (..),
    ActiveLayer (..),
    Presentation (..),
    staticPresentation,
    drawPresentation,
    presentationAttributes,
    confirmationDetails,
    launchReviewAllowed,
    wrapDisplayLines,
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
import Agentic.Tui.Highlight
import Agentic.Tui.Model
import Agentic.Tui.Person
import Agentic.Tui.RunModel
import Agentic.Tui.Types
import Brick
import Brick.Widgets.Border (borderWithLabel, hBorder, hBorderWithLabel, vBorder)
import Brick.Widgets.Center (hCenter)
import qualified Brick.Widgets.Edit as Edit
import Data.Aeson (Value (..), encode)
import qualified Data.ByteString.Lazy as BL
import Data.Char (isControl, isSpace)
import Data.List (intersperse)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Graphics.Vty as Vty

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
  = KeyHelpLayer
  | CancelLayer
  | PersonLayer
  | RecoveryLayer
  | SteerLayer
  | SaveLayer
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
    presentationConfig :: !TuiConfig,
    presentationPersonPrompt :: !(Maybe PersonPrompt),
    presentationPersonSubmitted :: !Bool,
    presentationPersonError :: !(Maybe Text),
    presentationRecovery :: !(Maybe (OccurrenceSnapshot, RecoverySnapshot)),
    presentationSteerTiming :: !(Maybe SteeringTiming),
    presentationControlError :: !(Maybe Text),
    presentationSaveError :: !(Maybe Text),
    presentationFinalResult :: !(Maybe (Either Text Value)),
    presentationFinalLoading :: !Bool,
    presentationShowResult :: !Bool,
    presentationElapsed :: !Text,
    presentationRunPersona :: !(Maybe Text),
    presentationRunRealization :: !(Maybe Text),
    presentationSpinner :: !Text
  }

-- | Minimal state for rendering static browser and launch-review fixtures.
staticPresentation :: TuiConfig -> TuiModel -> Presentation
staticPresentation config model =
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
      presentationConfig = config,
      presentationPersonPrompt = Nothing,
      presentationPersonSubmitted = False,
      presentationPersonError = Nothing,
      presentationRecovery = Nothing,
      presentationSteerTiming = Nothing,
      presentationControlError = Nothing,
      presentationSaveError = Nothing,
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
    headerRows = shellHeaderRows width height
    statusRows = shellStatusRows height
    footerRows = shellFooterRows height
    mainRows = shellMainRows width height
    headerWidgets = case headerRows of
      0 -> []
      1 -> [bar width (hBox [withAttr (attrName "title") (displayText "agent-cat"), displayText " / ", headerContext presentation])]
      _ | LiveScreen _ <- modelScreen (presentationModel presentation) ->
            [ bar width (padLeft (Pad 1) (headerContext presentation)),
              bar width (muted (displayText (oneLine width (" persona " <> fromMaybe "none" (presentationRunPersona presentation) <> " · target " <> fromMaybe "pending" (presentationRunRealization presentation)))))
            ]
        | otherwise -> [bar width (withAttr (attrName "title") (displayText (" agent-cat  /  " <> screenTitle (modelScreen (presentationModel presentation))))), bar width (padLeft (Pad 1) (headerContext presentation))]
    mainWidget = hLimit width (vLimit mainRows (padBottom Max (layerView presentation width height mainRows)))
    statusWidgets = [bar width (statusView presentation width) | statusRows == 1]
    footerWidgets = map (bar width . (\line -> if T.all isSpace line then muted hBorder else shortcutLine line)) footerLines
    footerLines = packedFooter width footerRows (footerItems presentation width height)

shellHeaderRows :: Int -> Int -> Int
shellHeaderRows width height
  | height <= 2 = 0
  | width >= 72 && height >= 16 = 2
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

shellMainRows :: Int -> Int -> Int
shellMainRows width height = max 0 (height - shellHeaderRows width height - shellStatusRows height - shellFooterRows height)

bar :: Int -> Widget n -> Widget n
bar width widget = hLimit width (padRight Max widget)


headerContext :: Presentation -> Widget Name
headerContext presentation = case modelScreen model of
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
layerView presentation width totalHeight mainHeight = case presentationLayer presentation of
  KeyHelpLayer -> keyHelpView presentation width mainHeight
  CancelLayer -> cancelView width mainHeight
  PersonLayer -> personView presentation width mainHeight
  RecoveryLayer -> recoveryView presentation width mainHeight
  SteerLayer -> steerView presentation width mainHeight
  SaveLayer -> saveResultView presentation width mainHeight
  FilterLayer -> workflowFilterView presentation width mainHeight
  ConfirmDetailsLayer -> confirmDetailsView presentation width mainHeight
  ConfirmLayer -> confirmSummaryView presentation width totalHeight mainHeight
  RunDetailsLayer -> pane "RUN DETAILS [focus]" (viewport FailureViewport Vertical (displayTextWrap (boundedDisplay (maybe "Run unavailable." (runDetailsText presentation) (modelSnapshot (presentationModel presentation))))))
  ScreenLayer -> screenView presentation width totalHeight mainHeight

screenView :: Presentation -> Int -> Int -> Int -> Widget Name
screenView presentation width totalHeight mainHeight = case modelScreen model of
  InitialLoading -> loadingView presentation "Loading workflows, stored runs, and offline routing..." "q cancels"
  BrowserScreen -> browserView presentation width totalHeight
  InputScreen index -> inputView presentation index width mainHeight
  TargetScreen -> targetView presentation width
  HelpLoading -> loadingView presentation "Loading bounded runner help..." "Esc cancels"
  HelpScreen help -> viewport HelpViewport Vertical (displayText (boundedDisplay help))
  PreviewLoading -> loadingView presentation "Building exact-input plan and routing preview..." "Esc cancels"
  ConfirmScreen _ -> confirmSummaryView presentation width totalHeight mainHeight
  ProcessLoading _ -> loadingView presentation "Preparing the private run and starting the machine..." "Esc cancels safely"
  LaunchingScreen _ -> loadingView presentation "Waiting for the validated run.started event..." "Esc detaches; c cancels"
  LiveScreen _ -> maybe (loadingView presentation "Waiting for run.started..." "Esc detaches; c cancels") (liveView presentation width totalHeight) (modelSnapshot model)
  FailureScreen failure -> viewport FailureViewport Vertical (withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure)))
  where
    model = presentationModel presentation

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
    listPane = pane (tabName (modelTab model) <> focusMark primaryFocused) $
      viewport BrowserListViewport Vertical $
        if null rows then displayTextWrap "No matches. Press / to change the search." else vBox rows
    rows = case modelTab model of
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
    detailBody = case modelTab model of
      WorkflowsTab -> maybe (displayText "Select a workflow.") workflowOverview (selectedWorkflow model)
      _ -> vBox (map detailLine (browserDetailLines model))
    selectedIndex = case modelTab model of
      WorkflowsTab -> modelWorkflowIndex model
      RunsTab -> modelRunIndex model
      RoutingTab -> modelEngineIndex model
    selectedRow index widget =
      let selected = index == selectedIndex
          styled = if selected then withAttr (attrName "selected") (padRight Max widget) else widget
       in if selected && primaryFocused then visible styled else styled

workflowOverview :: WorkflowDescriptor -> Widget Name
workflowOverview workflow = vBox
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
    shortcutLine "Enter CONFIGURE   h HELP",
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
    summaryLines = case preview of
      Nothing -> [("ERROR: launch preview unavailable", "error")]
      Just value
        | launchReviewAllowed (presentationConfig presentation) value (width, totalHeight) -> confirmationSummary (presentationConfig presentation) value
        | otherwise -> blockedConfirmationSummary (presentationConfig presentation) value width totalHeight
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
    details = maybe ["ERROR: launch preview unavailable"] (confirmationDetails (presentationConfig presentation)) (confirmPreview presentation)

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

saveResultView :: Presentation -> Int -> Int -> Widget Name
saveResultView presentation width mainHeight =
  dialog width mainHeight " Save verified result " $
    vBox
      [ maybe (displayTextWrap "Copy the verified final JSON result to a new absolute path. Existing files are refused.") (const emptyWidget) (presentationSaveError presentation),
        vLimit 3 (borderWithLabel (displayText " Path • ") (Edit.renderEditor (displayText . T.unlines) True (presentationEditor presentation))),
        case presentationSaveError presentation of
          Nothing -> displayText "Ctrl-D saves. Esc cancels."
          Just failure -> viewport FailureViewport Vertical (withAttr (attrName "error") (displayTextWrap ("ERROR: " <> failure)))
      ]

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
        [ muted (displayText ("Request " <> shown (occurrenceNumber (personPromptOccurrence prompt) + 1) <> " · " <> personPromptCode prompt)),
          vLimit promptHeight (viewport PersonViewport Vertical (displayTextWrap (boundedDisplay (personPromptText prompt)))),
          if presentationPersonSubmitted presentation
            then withAttr (attrName "selected") (displayText "Answer accepted locally; waiting for delivered acknowledgement...")
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
            <> shown (occurrenceNumber (snapshotOccurrenceId occurrence) + 1)
            <> " · "
            <> snapshotOccurrenceAddressee occurrence
        message = snapshotRecoveryMessage recovery
        contentWidth = confirmationInnerWidth width
        contentHeight = sum (map (length . wrapDisplayLines contentWidth) [request, message])
        actions = T.intercalate "   " [recoveryKeyText (recoveryChoice option) <> " " <> recoveryChoice option | option <- snapshotRecoveryChoices recovery]
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
  dialog width mainHeight " Keyboard shortcuts " (viewport KeyHelpViewport Vertical (vBox (map displayTextWrap (keyHelpLines presentation))))

keyHelpLines :: Presentation -> [Text]
keyHelpLines presentation = case modelScreen model of
  BrowserScreen ->
    [ "Up/Down       select",
      "Right/Left    focus details/list",
      "Tab           next Workflows/Runs/Routing section"
    ]
      <> browserKeys
      <> ownershipKeys
      <> ["? or Esc      close this help"]
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
  LiveScreen _ ->
    ["d full run details and error", "Tab focus pane", "Up/Down move or scroll", "j/k select occurrence", "G follow output"]
      <> [hint | hint <- [liveResultHint presentation, controlHintLine presentation, if presentationRunning presentation then "c cancel owned run" else ""], not (T.null hint)]
      <> ["Esc return to Runs", "? or Esc close this help"]
  FailureScreen _ -> ["Up/Down or PgUp/PgDn scroll", "Home/End first/last", "Esc return to browser", "? or Esc close this help"]
  InputScreen _ -> []
  where
    model = presentationModel presentation
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
    failureBanner = case snapshotRunFailure snapshot of
      Nothing -> []
      Just failure ->
        let rows = wrapDisplayLines width (T.takeWhile (/= '\n') (T.strip failure))
            limit = max 1 (min 6 (shellMainRows width totalHeight - if Map.null (snapshotOccurrences snapshot) then 4 else 6))
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
              Just dispatch | dispatchOpen dispatch -> shortcutLine ("Routes   " <> T.intercalate "   " [shown index <> " " <> target | (index, target) <- zip [1 :: Int ..9] (dispatchTargets dispatch)])
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
      Nothing -> []
      Just _ -> [withAttr (attrName "selected") (displayText (resultBanner presentation))]

outputTitle :: Presentation -> RunSnapshot -> Text
outputTitle presentation snapshot
  | presentationShowResult presentation = "Result"
  | otherwise = "Output" <> maybe "" (\occurrence -> " · Request " <> shown (occurrenceNumber (snapshotOccurrenceId occurrence) + 1)) (selectedOccurrence snapshot (presentationRunView presentation)) <> if presentationOutputFollow presentation then " · Follow" else " · Paused"

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
  Nothing -> "waiting for run.started"
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
      <> ["", "persona: " <> fromMaybe "none" (presentationRunPersona presentation), "realization: " <> fromMaybe "pending" (presentationRunRealization presentation)]
      <> concat ["" : selectedOccurrenceLines snapshot (RunView (Just occurrence)) | occurrence <- Map.keys (snapshotOccurrences snapshot)]
  )

billText :: RunSnapshot -> Text
billText snapshot = case (snapshotBillFresh snapshot, snapshotBillMemo snapshot) of
  (Nothing, Nothing) -> ""
  (fresh, memo) -> " | bill " <> maybe "?" shown fresh <> " fresh / " <> maybe "?" shown memo <> " memo"

footerItems :: Presentation -> Int -> Int -> [Text]
footerItems presentation width height = case presentationLayer presentation of
  KeyHelpLayer -> ["Esc CLOSE", "Up/Down SCROLL", "PgUp/PgDn", "Home/End"]
  CancelLayer -> ["n/Esc KEEP RUNNING", "y CANCEL RUN"]
  PersonLayer
    | Nothing <- presentationPersonPrompt presentation -> ["Esc CANCEL RUN", "LOADING VERIFIED QUESTION"]
    | presentationPersonSubmitted presentation -> ["Esc CANCEL RUN", "WAITING FOR DELIVERY"]
    | otherwise -> ["Esc CANCEL RUN", "Ctrl-D SUBMIT", "Enter newline", "PgUp/PgDn prompt"]
  RecoveryLayer -> recoveryItems presentation <> ["c CANCEL RUN", "PgUp/PgDn scroll"]
  SteerLayer -> ["Esc CLOSE", "Ctrl-D SEND", "Enter newline"]
  SaveLayer -> ["Esc CANCEL", "Ctrl-D SAVE"] <> ["PgUp/PgDn ERROR" | Just _ <- [presentationSaveError presentation]]
  FilterLayer -> ["Enter APPLY", "Esc CANCEL"]
  ConfirmDetailsLayer -> confirmItems True
  ConfirmLayer -> confirmItems False
  RunDetailsLayer -> ["Esc/d CLOSE", "Up/Down SCROLL", "PgUp/PgDn", "Home/End"]
  ScreenLayer -> screenItems
  where
    compact = width < 72 || height < 16
    allowed = maybe False (\preview -> launchReviewAllowed (presentationConfig presentation) preview (width, height)) (confirmPreview presentation)
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
      BrowserScreen
        | presentationRunning presentation -> ["Esc REATTACH", "c CANCEL RUN", "Tab SECTION", "? KEYS", browserPaneHint]
        | compact -> ["Enter OPEN", browserPaneHint, "? KEYS", "Tab SECTION", "q QUIT"] <> case modelTab model of WorkflowsTab -> ["/ FILTER"]; RunsTab -> ["r/m/f LINEAGE"]; RoutingTab -> ["p PERSONA"]
        | modelTab model == RunsTab -> ["Enter INSPECT", "r RESTART", "m RESUME", "f FORK", "Tab SECTION", "? KEYS", "q QUIT"]
        | modelTab model == RoutingTab -> ["p PERSONA", "Tab SECTION", browserPaneHint, "? KEYS", "q QUIT"]
        | otherwise -> ["Enter CONFIGURE", "/ FILTER", "Tab SECTION", browserPaneHint, "? KEYS", "q QUIT"]
      InputScreen index -> [if index == 0 then "Esc CANCEL" else "Esc PREVIOUS", "Ctrl-D CONTINUE", "Enter newline"]
      TargetScreen -> ["Esc BACK", "s SCRIPTED", "l/Enter ROUTING", "Up/Down SCROLL", "p PERSONA", "? KEYS"]
      HelpLoading -> ["Esc CANCEL"]
      HelpScreen _ -> ["Esc BACK", "Up/Down SCROLL", "PgUp/PgDn", "Home/End", "? KEYS"]
      PreviewLoading -> ["Esc CANCEL"]
      ConfirmScreen _ -> confirmItems False
      ProcessLoading _ -> ["Esc CANCEL STARTUP"]
      LaunchingScreen _ -> ["Esc DETACH", "c CANCEL RUN", "? KEYS"]
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

recoveryKeyText :: Text -> Text
recoveryKeyText "retry" = "r"
recoveryKeyText "failover" = "f"
recoveryKeyText "abandon" = "a"
recoveryKeyText _ = "?"

screenTitle :: Screen -> Text
screenTitle = \case
  InitialLoading -> "loading"
  BrowserScreen -> "browser"
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
confirmationBodyRows width height = max 0 (shellMainRows width height - 2)

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
