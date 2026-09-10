{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure screen, selection, input, and run-view state.
module Agentic.Tui.Model
  ( BrowserTab (..),
    Screen (..),
    TuiModel (..),
    initialModel,
    selectedWorkflow,
    visibleWorkflows,
    setWorkflowFilter,
    fuzzyMatch,
    selectedRun,
    moveSelection,
    cycleTab,
    beginWorkflow,
    submitInput,
    chooseTarget,
    previewFinished,
    launchStarted,
    snapshotUpdated,
    returnToBrowser,
    browserLines,
    snapshotLines,
    runRecordRealizations,
  )
where

import Agentic.Runtime
  ( AttemptSnapshot (..),
    CatalogueEntry (..),
    ControlAckSnapshot (..),
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
import Agentic.Tui.Types
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KeyMap
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as Vector

-- | One of the three top-level browser panes.
data BrowserTab = WorkflowsTab | RunsTab | RoutingTab
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Pure navigation stage. Editor widgets and process handles remain in App.
data Screen
  = BrowserScreen
  | InputScreen !Int
  | TargetScreen
  | PreviewLoading
  | HelpLoading
  | HelpScreen !Text
  | ConfirmScreen !LaunchPreview
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
moveSelection delta model = case modelTab model of
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
              modelStatus = "choose scripted or live execution"
            }
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
      modelStatus = "run event received"
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

browserLines :: TuiModel -> [Text]
browserLines model = case modelTab model of
  WorkflowsTab ->
    ( [ "filter /" <> modelWorkflowFilter model <> "/  " <> T.pack (show (length (visibleWorkflows model))) <> " of " <> T.pack (show (length (modelWorkflows model)))
      ]
        <> [ marker index (modelWorkflowIndex model)
               <> workflowName workflow
               <> "  ["
               <> workflowLevel workflow
               <> "; cost "
               <> foldRange workflow
               <> " over "
               <> T.pack (show (workflowPaths workflow))
               <> (if workflowPaths workflow == 1 then " path" else " paths")
               <> "; inputs "
               <> inputSummary workflow
               <> "; pins "
               <> if null (workflowPins workflow) then "none" else T.intercalate "," (workflowPins workflow)
               <> "]  "
               <> workflowBlurb workflow
             | (index, workflow) <- zip [0 ..] (visibleWorkflows model)
           ]
    )
  RunsTab ->
    [ marker index (modelRunIndex model) <> runLine entry
      | (index, entry) <- zip [0 ..] (modelRuns model)
    ]
  RoutingTab -> case modelRouting model of
    Left failure -> ["routing unavailable: " <> failure]
    Right routing ->
      [ "persona " <> fromMaybe "none" (routingSummaryPersona routing)
          <> maybe "" (\source -> " (" <> source <> ")") (routingSummaryPersonaSource routing)
      ]
        <> [ marker index (modelEngineIndex model)
               <> engineChoiceAlias engine
               <> "  "
               <> engineChoiceBackend engine
               <> "  "
               <> engineChoiceProvider engine
             | (index, engine) <- zip [0 ..] (routingSummaryEngines routing)
           ]
        <> concatMap routingProfileBrowserLines (routingSummaryProfiles routing)

snapshotLines :: RunSnapshot -> [Text]
snapshotLines snapshot =
  [ "run " <> runIdText (snapshotRunId snapshot) <> "  " <> T.pack (show (snapshotRunStatus snapshot)),
    "workflow " <> fromMaybe "starting" (snapshotWorkflow snapshot) <> "  target " <> fromMaybe "pending" (snapshotTarget snapshot)
  ]
    <> concatMap occurrenceLine (orderedOccurrences snapshot)
    <> ["control " <> snapshotControlId acknowledgement <> ": " <> snapshotControlState acknowledgement <> " — " <> snapshotControlMessage acknowledgement | acknowledgement <- Map.elems (snapshotControlAcks snapshot)]
  where
    occurrenceLine occurrence =
      [ "[" <> occurrenceIdText (snapshotOccurrenceId occurrence) <> "] "
          <> T.pack (show (snapshotOccurrenceState occurrence))
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

runLine :: CatalogueEntry -> Text
runLine entry = T.take 8192 (unboundedRunLine entry)

unboundedRunLine :: CatalogueEntry -> Text
unboundedRunLine = \case
  CatalogueCorrupt path why -> "corrupt " <> T.pack path <> " — " <> why
  CatalogueRun record ->
    let manifest = recordManifest record
        snapshot = recordSnapshot record
        status = maybe "not-started" (T.pack . show . snapshotRunStatus) snapshot
        lineage =
          fromMaybe "root" (frontendLineage manifest)
            <> maybe "" (\parent -> " from " <> runIdText parent) (frontendParentRunId manifest)
        persona = fromMaybe "none" (frontendPersona manifest)
        realizations = runRecordRealizations record
        bills = case snapshot of
          Nothing -> "pending"
          Just value -> maybe "?" (T.pack . show) (snapshotBillFresh value) <> "/" <> maybe "?" (T.pack . show) (snapshotBillMemo value)
        resultAvailable = case snapshot >>= snapshotResult of
          Just _ -> True
          Nothing -> False
     in runIdText (frontendRunId manifest)
          <> "  workflow "
          <> frontendWorkflow manifest
          <> "  target "
          <> frontendTargetKind manifest
          <> "  status "
          <> status
          <> "  lineage "
          <> lineage
          <> "  persona "
          <> persona
          <> "  realizations "
          <> realizations
          <> "  bills "
          <> bills
          <> "  result "
          <> (if resultAvailable then "available" else "none")
          <> "  owner "
          <> T.pack (show (recordOwnership record))

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
              <> ", inventory "
              <> routingInventorySource (routingRungInventory rung)
              <> maybe "" (", fingerprint " <>) (routingInventoryFingerprint (routingRungInventory rung))
              <> maybe "" (", fetched " <>) (routingInventoryFetchedAt (routingRungInventory rung))
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

inputSummary :: WorkflowDescriptor -> Text
inputSummary descriptor = case workflowInputs descriptor of
  [] -> "none"
  inputs -> T.intercalate "," [workflowInputName input <> ":" <> sourceText (workflowInputSource input) | input <- inputs]

sourceText :: WorkflowInputSource -> Text
sourceText DescriptorPrompt = "prompt"
sourceText DescriptorCommandTail = "arg"
sourceText DescriptorStdin = "stdin"

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
