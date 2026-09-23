{-# LANGUAGE OverloadedStrings #-}

-- | Pure screen, selection, input, and run-view state.
module Agentic.Tui.Model
  ( BrowserTab (..),
    Screen (..),
    TuiModel (..),
    initialModel,
    initialServiceModel,
    selectedServiceProfile,
    selectedWorkflow,
    visibleWorkflows,
    setWorkflowFilter,
    fuzzyMatch,
    selectedRun,
    moveSelection,
    cycleTab,
    beginWorkflow,
    submitInput,
    storeInput,
    previousStep,
    inputValue,
    chooseTarget,
    previewFinished,
    launchStarted,
    snapshotUpdated,
    returnToBrowser,
    browserRows,
    browserDetailLines,
    browserLines,
    snapshotLines,
    runRecordRealizations,
  )
where

import Agentic.Runtime
  ( AttemptSnapshot (..),
    CatalogueEntry (..),
    ControlAckSnapshot (..),
    DescriptorCapabilities (..),
    FrontendManifest (..),
    OccurrenceId (occurrenceNumber),
    OccurrenceSnapshot (..),
    RunId (runIdText),
    RunRecord (..),
    RunSnapshot (..),
    WorkflowDescriptor (..),
    WorkflowInputDescriptor (..),
    WorkflowInputSource (..),
  )
import Agentic.Tui.RunModel (occurrenceStateLabel, runFailureLines, runStatusLabel)
import Agentic.Tui.Types
import qualified Agentic.Tui.Service as Service
import qualified Agentic.Manager.Client as Manager
import Data.Aeson (Value (..), encode)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import qualified Data.Vector as Vector

-- | One of the three top-level browser panes.
data BrowserTab = WorkflowsTab | RunsTab | RoutingTab
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Pure navigation stage. Editor widgets and process handles remain in App.
data Screen
  = InitialLoading
  | BrowserScreen
  | ServiceProfilesScreen ![Service.Profile] !Int
  | ServiceRequestScreen !Manager.DraftView
  | ServiceReviewScreen !Manager.Preparation !Text
  | ServiceCommandScreen !Text
  | InputScreen !Int
  | TargetScreen
  | PreviewLoading
  | HelpLoading
  | HelpScreen !Text
  | ConfirmScreen !LaunchPreview
  | ProcessLoading !LaunchPreview
  | LaunchingScreen !RunId
  | LiveScreen !RunId
  | FailureScreen !Text
  deriving (Eq, Show)

-- | All behaviorally relevant frontend state.
data TuiModel = TuiModel
  { modelWorkflows :: ![WorkflowDescriptor],
    modelRuns :: ![CatalogueEntry],
    modelRouting :: !(Either Text RoutingSummary),
    modelTab :: !BrowserTab,
    modelWorkflowIndex :: !Int,
    modelWorkflowFilter :: !Text,
    modelRunIndex :: !Int,
    modelEngineIndex :: !Int,
    modelScreen :: !Screen,
    modelWorkflow :: !(Maybe WorkflowDescriptor),
    modelInputs :: !(Map Text Text),
    modelTarget :: !(Maybe TargetSelection),
    modelSnapshot :: !(Maybe RunSnapshot),
    modelStatus :: !Text
  }
  deriving (Eq, Show)

initialModel :: [WorkflowDescriptor] -> [CatalogueEntry] -> Either Text RoutingSummary -> TuiModel
initialModel workflows runs routing =
  TuiModel
    { modelWorkflows = workflows,
      modelRuns = runs,
      modelRouting = routing,
      modelTab = WorkflowsTab,
      modelWorkflowIndex = 0,
      modelWorkflowFilter = "",
      modelRunIndex = 0,
      modelEngineIndex = 0,
      modelScreen = BrowserScreen,
      modelWorkflow = Nothing,
      modelInputs = Map.empty,
      modelTarget = Nothing,
      modelSnapshot = Nothing,
      modelStatus = "ready"
    }

-- | An authenticated manager catalogue without local invocation or state paths.
initialServiceModel :: [Service.Profile] -> TuiModel
initialServiceModel profiles = (initialModel [] [] (Left "manager profile catalogue"))
  { modelScreen = ServiceProfilesScreen profiles 0, modelStatus = "select a manager profile" }

selectedServiceProfile :: TuiModel -> Maybe Service.Profile
selectedServiceProfile model = case modelScreen model of
  ServiceProfilesScreen profiles index -> atMay profiles index
  _ -> Nothing

selectedWorkflow :: TuiModel -> Maybe WorkflowDescriptor
selectedWorkflow model = atMay (visibleWorkflows model) (modelWorkflowIndex model)

visibleWorkflows :: TuiModel -> [WorkflowDescriptor]
visibleWorkflows model
  | T.null (T.strip (modelWorkflowFilter model)) = modelWorkflows model
  | otherwise =
      filter
        (\workflow -> fuzzyMatch (modelWorkflowFilter model) (workflowName workflow <> " " <> workflowBlurb workflow))
        (modelWorkflows model)

setWorkflowFilter :: Text -> TuiModel -> TuiModel
setWorkflowFilter query model = model {modelWorkflowFilter = query, modelWorkflowIndex = 0}

fuzzyMatch :: Text -> Text -> Bool
fuzzyMatch needle haystack = go (T.unpack (T.toCaseFold needle)) (T.unpack (T.toCaseFold haystack))
  where
    go [] _ = True
    go _ [] = False
    go wanted@(next : rest) (candidate : candidates)
      | next == candidate = go rest candidates
      | otherwise = go wanted candidates

selectedRun :: TuiModel -> Maybe CatalogueEntry
selectedRun model = atMay (modelRuns model) (modelRunIndex model)

moveSelection :: Int -> TuiModel -> TuiModel
moveSelection delta model
  | ServiceProfilesScreen profiles index <- modelScreen model = model
      { modelScreen = ServiceProfilesScreen profiles (boundedIndex (length profiles) (index + delta)) }
  | otherwise = case modelTab model of
      WorkflowsTab -> model {modelWorkflowIndex = boundedIndex (length (visibleWorkflows model)) (modelWorkflowIndex model + delta)}
      RunsTab -> model {modelRunIndex = boundedIndex (length (modelRuns model)) (modelRunIndex model + delta)}
      RoutingTab -> model {modelEngineIndex = boundedIndex (length (routingEngines model)) (modelEngineIndex model + delta)}

cycleTab :: TuiModel -> TuiModel
cycleTab model =
  model
    { modelTab = case modelTab model of
        WorkflowsTab -> RunsTab
        RunsTab -> RoutingTab
        RoutingTab -> WorkflowsTab
    }

beginWorkflow :: TuiModel -> TuiModel
beginWorkflow model = case selectedWorkflow model of
  Nothing -> model {modelStatus = "no workflow selected"}
  Just descriptor ->
    model
      { modelWorkflow = Just descriptor,
        modelInputs = Map.empty,
        modelTarget = Nothing,
        modelScreen = if null (workflowInputs descriptor) then TargetScreen else InputScreen 0,
        modelStatus = "collecting launch inputs"
      }

submitInput :: Text -> TuiModel -> TuiModel
submitInput value model = case (modelWorkflow model, modelScreen model) of
  (Just descriptor, InputScreen index) -> case atMay (workflowInputs descriptor) index of
    Nothing -> model {modelScreen = FailureScreen "input descriptor index is invalid"}
    Just input ->
      let values = Map.insert (workflowInputName input) value (modelInputs model)
          next = index + 1
       in model
            { modelInputs = values,
              modelScreen = if next < length (workflowInputs descriptor) then InputScreen next else TargetScreen,
              modelStatus = if next < length (workflowInputs descriptor) then "configure workflow input" else "choose scripted or live execution"
            }
  _ -> model

storeInput :: Text -> TuiModel -> TuiModel
storeInput value model = case (modelWorkflow model, modelScreen model) of
  (Just descriptor, InputScreen index) -> case atMay (workflowInputs descriptor) index of
    Just input -> model {modelInputs = Map.insert (workflowInputName input) value (modelInputs model)}
    Nothing -> model
  _ -> model

inputValue :: TuiModel -> Text
inputValue model = case (modelWorkflow model, modelScreen model) of
  (Just descriptor, InputScreen index) -> case atMay (workflowInputs descriptor) index of
    Just input -> Map.findWithDefault "" (workflowInputName input) (modelInputs model)
    Nothing -> ""
  _ -> ""

previousStep :: TuiModel -> TuiModel
previousStep model = case modelScreen model of
  InputScreen index
    | index > 0 -> model {modelScreen = InputScreen (index - 1), modelStatus = "configure workflow input"}
    | otherwise -> returnToBrowser model
  TargetScreen -> case modelWorkflow model of
    Just descriptor
      | not (null (workflowInputs descriptor)) -> model {modelScreen = InputScreen (length (workflowInputs descriptor) - 1), modelStatus = "configure workflow input"}
    _ -> returnToBrowser model
  PreviewLoading -> model {modelScreen = TargetScreen, modelStatus = "choose scripted or live execution"}
  ConfirmScreen preview ->
    case previewLineage preview of
      Just _ -> (returnToBrowser model) {modelTab = RunsTab}
      Nothing -> model {modelScreen = TargetScreen, modelStatus = "choose scripted or live execution"}
  ProcessLoading preview -> previousStep model {modelScreen = ConfirmScreen preview}
  HelpLoading -> returnToBrowser model
  HelpScreen _ -> returnToBrowser model
  FailureScreen _ -> returnToBrowser model
  _ -> model

chooseTarget :: TargetSelection -> TuiModel -> TuiModel
chooseTarget target model =
  model
    { modelTarget = Just target,
      modelScreen = PreviewLoading,
      modelStatus = "building exact-input preview"
    }

previewFinished :: Either Text LaunchPreview -> TuiModel -> TuiModel
previewFinished result model = case result of
  Left failure -> model {modelScreen = FailureScreen failure, modelStatus = "preview failed"}
  Right preview -> model {modelScreen = ConfirmScreen preview, modelStatus = "confirm launch"}

launchStarted :: RunId -> RunSnapshot -> TuiModel -> TuiModel
launchStarted runId snapshot model =
  model
    { modelScreen = LaunchingScreen runId,
      modelSnapshot = Just snapshot,
      modelStatus = "machine child starting"
    }

snapshotUpdated :: RunSnapshot -> TuiModel -> TuiModel
snapshotUpdated snapshot model =
  model
    { modelSnapshot = Just snapshot,
      modelScreen = case modelScreen model of
        LaunchingScreen _ -> LiveScreen (snapshotRunId snapshot)
        current -> current,
      modelStatus = runStatusLabel (snapshotRunStatus snapshot)
    }

returnToBrowser :: TuiModel -> TuiModel
returnToBrowser model =
  model
    { modelScreen = BrowserScreen,
      modelWorkflow = Nothing,
      modelInputs = Map.empty,
      modelTarget = Nothing,
      modelStatus = "ready"
    }

browserRows :: TuiModel -> [Text]
browserRows model | ServiceProfilesScreen profiles selected <- modelScreen model =
  [ marker index selected <> Service.profileId profile <> "  " <> Service.profileReadiness profile
  | (index,profile) <- zip [0..] profiles ]
browserRows model = case modelTab model of
  WorkflowsTab ->
    [ marker index (modelWorkflowIndex model)
        <> workflowName workflow
      | (index, workflow) <- zip [0 ..] (visibleWorkflows model)
    ]
  RunsTab ->
    [ marker index (modelRunIndex model) <> runRow entry
      | (index, entry) <- zip [0 ..] (modelRuns model)
    ]
  RoutingTab -> case modelRouting model of
    Left failure -> ["  ERROR: routing unavailable: " <> failure]
    Right routing ->
      [ marker index (modelEngineIndex model)
          <> engineChoiceAlias engine
          <> "  "
          <> engineChoiceBackend engine
          <> "/"
          <> engineChoiceProvider engine
          <> "  "
          <> readinessText engine
        | (index, engine) <- zip [0 ..] (routingSummaryEngines routing)
      ]

browserDetailLines :: TuiModel -> [Text]
browserDetailLines model | ServiceProfilesScreen _ _ <- modelScreen model =
  maybe ["No manager profile selected."] (\profile ->
    [ "Profile: " <> Service.profileId profile,
      "Revision: " <> Service.profileRevision profile,
      "Workspace: " <> Service.profileWorkspace profile,
      "Target: " <> Service.profileTarget profile,
      "Readiness: " <> Service.profileReadiness profile,
      "Refusal: " <> fromMaybe "none" (Service.profileRefusal profile) ]) (selectedServiceProfile model)
browserDetailLines model = case modelTab model of
  WorkflowsTab -> maybe ["No workflow selected."] workflowDetail (selectedWorkflow model)
  RunsTab -> maybe ["No run selected."] runDetail (selectedRun model)
  RoutingTab -> routingDetail (modelRouting model) (atMay (routingEngines model) (modelEngineIndex model))

browserLines :: TuiModel -> [Text]
browserLines model = browserRows model <> [""] <> browserDetailLines model

workflowDetail :: WorkflowDescriptor -> [Text]
workflowDetail workflow =
  [ workflowName workflow,
    workflowBlurb workflow,
    "",
    "Inputs"
  ]
    <> (if null (workflowInputs workflow) then ["  none"] else map inputLine (workflowInputs workflow))
    <> [ "",
         "Result",
         "  " <> (case workflowResultCode workflow of String code -> code; value -> jsonTextValue value),
         "",
         "Plan",
         "  level " <> workflowLevel workflow <> "; size " <> shown (workflowSize workflow) <> "; ask nodes " <> shown (workflowAskNodes workflow),
         "  " <> foldRange workflow <> " request occurrences; " <> plural (workflowPaths workflow) "path",
         "  pins: " <> commaOrNone (workflowPins workflow),
         "  run facts: " <> commaOrNone (workflowRunFacts workflow),
         "",
         "Capabilities",
         "  consult " <> shown (descriptorConsults capabilities) <> "; observe " <> shown (descriptorObserves capabilities) <> "; effect " <> shown (descriptorEffects capabilities),
         "  effectful: " <> yesNo (descriptorEffectful capabilities) <> "; tool execution: " <> yesNo (descriptorToolExecution capabilities),
         "",
         "Enter configures this workflow."
       ]
  where
    capabilities = workflowCapabilities workflow
    inputLine input = "  " <> workflowInputName input <> " (" <> sourceText (workflowInputSource input) <> ")"

runDetail :: CatalogueEntry -> [Text]
runDetail (CatalogueCorrupt path why) = ["ERROR: corrupt run", "  path: " <> T.pack path, "  diagnostic: " <> why]
runDetail (CatalogueRun record) =
  maybe [] runFailureLines snapshot <>
  [ runIdText (frontendRunId manifest),
    "",
    "Run",
    "  status: " <> maybe "Not started" (runStatusLabel . snapshotRunStatus) snapshot,
    "  ownership: " <> T.pack (show (recordOwnership record)),
    "  workflow: " <> frontendWorkflow manifest,
    "  target kind: " <> frontendTargetKind manifest,
    "  persona: " <> fromMaybe "none" (frontendPersona manifest),
    "  lineage: " <> fromMaybe "root" (frontendLineage manifest),
    "  parent: " <> maybe "none" runIdText (frontendParentRunId manifest),
    "  bills: " <> bills,
    "  result: " <> if maybe False (isJust . snapshotResult) snapshot then "available" else "none",
    "",
    "Realizations",
    "  " <> runRecordRealizations record,
    "",
    "Identity",
    "  program SHA-256: " <> frontendProgramHash manifest,
    "  policy digest: " <> fromMaybe "none" (frontendPolicyDigest manifest),
    "  working directory: " <> T.pack (frontendCwd manifest),
    "  store: " <> T.pack (recordDirectory record)
  ]
  where
    manifest = recordManifest record
    snapshot = recordSnapshot record
    bills = case snapshot of
      Nothing -> "pending"
      Just value -> maybe "?" shown (snapshotBillFresh value) <> " fresh / " <> maybe "?" shown (snapshotBillMemo value) <> " memo"

routingDetail :: Either Text RoutingSummary -> Maybe EngineChoice -> [Text]
routingDetail (Left failure) _ = ["ERROR: routing unavailable", failure]
routingDetail (Right routing) selected =
  [ "Persona",
    "  " <> fromMaybe "none" (routingSummaryPersona routing) <> maybe "" (\source -> " (" <> source <> ")") (routingSummaryPersonaSource routing),
    "  available: " <> commaOrNone (routingSummaryPersonas routing),
    "  launch fingerprint: " <> routingSummaryFingerprint routing,
    "",
    "Selected engine"
  ]
    <> maybe ["  none"] engineLines selected
    <> ["", "Profiles"]
    <> (if null (routingSummaryProfiles routing) then ["  none"] else concatMap routingProfileBrowserLines (routingSummaryProfiles routing))
    <> ["", "Warnings"]
    <> (if null (routingSummaryWarnings routing) then ["  none"] else map ("  WARNING: " <>) (routingSummaryWarnings routing))
  where
    engineLines engine =
      [ "  alias: " <> engineChoiceAlias engine,
        "  backend: " <> engineChoiceBackend engine <> "; provider: " <> engineChoiceProvider engine,
        "  credential: " <> readinessText engine
      ]

runRow :: CatalogueEntry -> Text
runRow (CatalogueCorrupt path _) = "corrupt  " <> T.pack path
runRow (CatalogueRun record) =
  frontendWorkflow manifest
    <> "  "
    <> maybe "Not started" (runStatusLabel . snapshotRunStatus) (recordSnapshot record)
    <> "  "
    <> runIdText (frontendRunId manifest)
  where
    manifest = recordManifest record

snapshotLines :: RunSnapshot -> [Text]
snapshotLines snapshot =
  runFailureLines snapshot <>
  [ "run " <> runIdText (snapshotRunId snapshot) <> "  " <> runStatusLabel (snapshotRunStatus snapshot),
    "workflow " <> fromMaybe "starting" (snapshotWorkflow snapshot) <> "  target " <> fromMaybe "pending" (snapshotTarget snapshot)
  ]
    <> concatMap occurrenceLine (orderedOccurrences snapshot)
    <> ["control " <> snapshotControlId acknowledgement <> ": " <> snapshotControlState acknowledgement <> " — " <> snapshotControlMessage acknowledgement | acknowledgement <- Map.elems (snapshotControlAcks snapshot)]
  where
    occurrenceLine occurrence =
      [ "[" <> occurrenceIdText (snapshotOccurrenceId occurrence) <> "] "
          <> occurrenceStateLabel (snapshotOccurrenceState occurrence)
          <> " "
          <> snapshotOccurrenceIntent occurrence
          <> "/"
          <> snapshotOccurrenceCode occurrence
          <> " -> "
          <> snapshotOccurrenceAddressee occurrence,
        "  prompt: " <> snapshotOccurrencePrompt occurrence
      ]
        <> maybe [] (\answer -> ["  answer: " <> answer]) (snapshotOccurrenceAnswer occurrence)

orderedOccurrences :: RunSnapshot -> [OccurrenceSnapshot]
orderedOccurrences snapshot =
  let authored = [occurrence | occurrenceId <- snapshotAuthoredOrder snapshot, occurrence <- maybeToList (Map.lookup occurrenceId (snapshotOccurrences snapshot))]
      remaining = [occurrence | (occurrenceId, occurrence) <- Map.toList (snapshotOccurrences snapshot), occurrenceId `notElem` snapshotAuthoredOrder snapshot]
   in authored <> remaining

routingProfileBrowserLines :: RoutingProfileChoice -> [Text]
routingProfileBrowserLines profile =
  map
    (T.take 8192)
    ( ("  profile " <> routingProfileName profile <> " chain:")
        : [ "    "
              <> T.pack (show (routingRungNumber rung))
              <> ". "
              <> routingRungAxis rung
              <> " -> "
              <> routingRungModel rung
              <> " on "
              <> routingRungRouter rung
              <> " ("
              <> routingRungProvider rung
              <> ", "
              <> routingRungBackend rung
              <> ", thinking "
              <> routingRungThinking rung
              <> ", max output "
              <> maybe "unconstrained" shown (routingRungMaxOutput rung)
              <> ", inventory "
              <> routingInventorySource (routingRungInventory rung)
              <> maybe "" (", fingerprint " <>) (routingInventoryFingerprint (routingRungInventory rung))
              <> maybe "" (", fetched " <>) (routingInventoryFetchedAt (routingRungInventory rung))
              <> maybe "" (", execution fingerprint " <>) (routingRungExecutionFingerprint rung)
              <> ")"
            | rung <- routingProfileRungs profile
          ]
    )

runRecordRealizations :: RunRecord -> Text
runRecordRealizations record = case policyRealizations (recordPolicy record) of
  [] -> maybe "pending" fallbackTargets (recordSnapshot record)
  values -> T.intercalate ", " values

policyRealizations :: Maybe Value -> [Text]
policyRealizations (Just (Object policy)) = case KeyMap.lookup "realizations" policy of
  Just (Array values) ->
    take 128 [T.take 1024 rendered | value <- Vector.toList values, Just rendered <- [policyRealization value]]
  _ -> []
policyRealizations _ = []

policyRealization :: Value -> Maybe Text
policyRealization (Object fields) = do
  axis <- jsonText "axis" fields
  model <- jsonText "model" fields
  let engine = case jsonText "engine" fields of
        Just value -> value
        Nothing -> fromMaybe "?" (jsonText "router" fields)
      provider = fromMaybe "?" (jsonText "provider" fields)
  pure (axis <> " -> " <> model <> " on " <> engine <> "/" <> provider)
policyRealization _ = Nothing

jsonText :: KeyMap.Key -> KeyMap.KeyMap Value -> Maybe Text
jsonText name fields = case KeyMap.lookup name fields of
  Just (String value) -> Just value
  _ -> Nothing

fallbackTargets :: RunSnapshot -> Text
fallbackTargets snapshot =
  case nub [snapshotAttemptTarget attempt | occurrence <- Map.elems (snapshotOccurrences snapshot), attempt <- Map.elems (snapshotOccurrenceAttempts occurrence)] of
    [] -> "pending"
    values -> T.intercalate ", " values

foldRange :: WorkflowDescriptor -> Text
foldRange descriptor = maybe "—" (T.pack . show) (workflowMinFold descriptor) <> ".." <> maybe "—" (T.pack . show) (workflowMaxFold descriptor)

sourceText :: WorkflowInputSource -> Text
sourceText DescriptorPrompt = "prompt"
sourceText DescriptorCommandTail = "command tail"
sourceText DescriptorStdin = "standard input"

shown :: Show a => a -> Text
shown = T.pack . show

plural :: Integer -> Text -> Text
plural count noun = shown count <> " " <> noun <> if count == 1 then "" else "s"

commaOrNone :: [Text] -> Text
commaOrNone [] = "none"
commaOrNone values = T.intercalate ", " values

jsonTextValue :: Value -> Text
jsonTextValue = TE.decodeUtf8 . BL.toStrict . encode

readinessText :: EngineChoice -> Text
readinessText engine = if engineChoiceCredentialReady engine then "READY (offline)" else "NOT READY"

yesNo :: Bool -> Text
yesNo True = "yes"
yesNo False = "no"

routingEngines :: TuiModel -> [EngineChoice]
routingEngines model = either (const []) routingSummaryEngines (modelRouting model)

marker :: Int -> Int -> Text
marker actual selected = if actual == selected then "> " else "  "

boundedIndex :: Int -> Int -> Int
boundedIndex size index
  | size <= 0 = 0
  | otherwise = max 0 (min (size - 1) index)

atMay :: [a] -> Int -> Maybe a
atMay values index
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing

occurrenceIdText :: OccurrenceId -> Text
occurrenceIdText = T.pack . show . occurrenceNumber

maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just value) = [value]
