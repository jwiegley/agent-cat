{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Thin Brick adapter over the pure TUI model and machine snapshot reducer.
module Agentic.Tui.App
  ( runApp,
    withTerminationHandlers,
  )
where

import Agentic.Runtime
  ( AttemptId (attemptOccurrence),
    AttemptSnapshot (..),
    CatalogueEntry (..),
    Control (..),
    ControlAckSnapshot (..),
    ControlCommand (..),
    ControlId (..),
    DescriptorCapabilities (..),
    DispatchSnapshot (..),
    FrontendManifest (..),
    LineageOperation (..),
    OccurrenceId (occurrenceNumber),
    OccurrenceSnapshot (..),
    RecoveryControl (..),
    RecoveryOption (..),
    RecoverySnapshot (..),
    Envelope (..),
    ResultRef (resultArtifactPreview),
    RunId (runIdText),
    RunOwnership (..),
    RunRecord (..),
    RunSnapshot (..),
    RunStatus (..),
    RuntimeEvent
      ( OccurrenceCompleted,
        OccurrenceFailed,
        OccurrencePersonAnswerPending,
        OccurrenceRecoveryChosen,
        OccurrenceRecoveryPending,
        OccurrenceRetried,
        RunCancelled,
        RunFailed
      ),
    SteeringTiming (..),
    SnapshotError (snapshotErrorMessage),
    WorkflowDescriptor (..),
    WorkflowInputDescriptor (..),
    WorkflowInputSource (..),
    initialRunSnapshot,
    readResultArtifactAt,
    stepRunSnapshot,
  )
import Agentic.Tui.Client
import Agentic.Tui.Highlight
import Agentic.Tui.Model
import Agentic.Tui.Person
import Agentic.Tui.Process
import Agentic.Tui.RunModel
import Agentic.Tui.Root
import Agentic.Tui.Types
import Brick
import Brick.BChan (BChan, newBChan, writeBChan, writeBChanNonBlocking)
import Brick.Widgets.Border (borderWithLabel, vBorder)
import Brick.Widgets.Center (center)
import qualified Brick.Widgets.Edit as Edit
import Control.Concurrent (forkIO, killThread, myThreadId, threadDelay, throwTo)
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
import Control.Exception (AsyncException (UserInterrupt), SomeAsyncException, SomeException, bracket, displayException, finally, fromException, mask, onException, throwIO, try, uninterruptibleMask_)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), encode)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.List (elemIndex, find)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import qualified Data.Vector as Vector
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Graphics.Vty as Vty
import Graphics.Vty.Platform.Unix (mkVty)
import System.FilePath (isAbsolute, (</>))
import System.IO (hClose)
import System.Posix.Files (ownerReadMode, ownerWriteMode, unionFileModes)
import System.Posix.IO (OpenFileFlags (cloexec, creat, exclusive, nofollow), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

-- | Brick resource identities.
data Name = MainViewport | OutputViewport | InputEditor
  deriving (Eq, Ord, Show)

-- | Coalesced display wakeups plus lossless one-shot operation results.
data AppEvent
  = FrameReady
  | Tick !UTCTime
  | PreviewReady !Int !(Either Text LaunchPreview)
  | HelpReady !Int !(Either Text Text)
  | RunsReady !(Either Text [CatalogueEntry])
  | RoutingReady !Text !(Either Text RoutingSummary)
  | ChildStopped !MachineExit
  | PersonPromptReady !OccurrenceId !(Either Text PersonPrompt)
  | FinalResultReady !RunId !(Either Text Value)

-- | Bounded frontend IO slots, each retaining at most one cancellable task.
data Work = PreviewWork | HelpWork | RunsWork | RoutingWork | PersonWork | ResultWork
  deriving (Eq, Ord)

-- | Brick-only editor/process state around the pure model.
data AppState = AppState
  { stateModel :: !TuiModel,
    stateEditor :: !(Edit.Editor Text Name),
    stateChannel :: !(BChan AppEvent),
    stateEvents :: !(TBQueue Envelope),
    stateFramePending :: !(TVar Bool),
    stateRunning :: !(Maybe RunningMachine),
    statePendingExit :: !(Maybe MachineExit),
    stateMachineFailure :: !(Maybe Text),
    stateOwned :: !(IORef (Maybe RunningMachine)),
    stateWorkers :: !(MVar (Map.Map Work (Async ()))),
    stateRunView :: !RunView,
    stateOutputFollow :: !Bool,
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
    statePreviewRequest :: !(Maybe Int),
    stateHelpRequest :: !(Maybe Int),
    statePersonQueue :: ![OccurrenceId],
    stateRecoveryQueue :: ![OccurrenceId],
    statePersonLoading :: !(Maybe OccurrenceId),
    statePersonPrompt :: !(Maybe PersonPrompt),
    statePersonSubmitted :: !Bool,
    statePersonControlId :: !(Maybe Text),
    statePersonError :: !(Maybe Text),
    stateCancelConfirm :: !Bool,
    stateSteerTiming :: !(Maybe SteeringTiming),
    stateControlError :: !(Maybe Text),
    stateFinalResult :: !(Maybe (Either Text Value)),
    stateFinalLoading :: !Bool,
    stateConfig :: !TuiConfig,
    stateRoot :: !PrivateRoot
  }

runApp :: TuiConfig -> PrivateRoot -> InitialData -> IO ()
runApp config root initial = do
  channel <- newBChan 64
  now <- getCurrentTime
  ticker <- forkIO . forever $ do
    threadDelay 1000000
    current <- getCurrentTime
    void (writeBChanNonBlocking channel (Tick current))
  events <- newTBQueueIO 2048
  framePending <- newTVarIO False
  owned <- newIORef Nothing
  workers <- newMVar Map.empty
  let initialState =
        AppState
          { stateModel = initialModel (initialWorkflows initial) (initialRuns initial) (initialRouting initial),
            stateEditor = Edit.editorText InputEditor Nothing "",
            stateChannel = channel,
            stateEvents = events,
            stateFramePending = framePending,
            stateRunning = Nothing,
            statePendingExit = Nothing,
            stateMachineFailure = Nothing,
            stateOwned = owned,
            stateWorkers = workers,
            stateRunView = emptyRunView,
            stateOutputFollow = True,
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
            statePreviewRequest = Nothing,
            stateHelpRequest = Nothing,
            statePersonQueue = [],
            stateRecoveryQueue = [],
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
            stateConfig = config,
            stateRoot = root
          }
      buildVty = mkVty Vty.defaultConfig
      -- A second signal must not abandon a worker that is still reaping its group.
      cleanup = do
        uninterruptibleMask_ (killThread ticker >> (readMVar workers >>= mapM_ cancel))
          `finally` (readIORef owned >>= mapM_ terminateMachine)
        writeIORef owned Nothing
  (do
      initialVty <- buildVty
      void (customMain initialVty buildVty (Just channel) app initialState)
    )
    `finally` cleanup

startWorker :: AppState -> Work -> IO () -> IO ()
startWorker state work action =
  modifyMVarMasked_ (stateWorkers state) $ \workers -> do
    mapM_ cancel (Map.lookup work workers)
    worker <- asyncWithUnmask (\unmask -> unmask action)
    pure (Map.insert work worker workers)

withTerminationHandlers :: IO a -> IO a
withTerminationHandlers action = do
  owner <- myThreadId
  let caught = Catch (throwTo owner UserInterrupt)
      withSignal sig = bracket (installHandler sig caught Nothing) (\previous -> void (installHandler sig previous Nothing)) . const
  withSignal sigINT (withSignal sigTERM action)

app :: App AppState AppEvent Name
app =
  App
    { appDraw = draw,
      appChooseCursor = showFirstCursor,
      appHandleEvent = handleEvent,
      appStartEvent = pure (),
      appAttrMap = const attributes
    }

attributes :: AttrMap
attributes =
  attrMap
    Vty.defAttr
    [ (attrName "selected", fg Vty.cyan `Vty.withStyle` Vty.bold),
      (attrName "title", fg Vty.brightBlue `Vty.withStyle` Vty.bold),
      (attrName "error", fg Vty.red),
      (attrName "status", fg Vty.yellow),
      (attrName "markdown-heading", fg Vty.brightBlue `Vty.withStyle` Vty.bold),
      (attrName "markdown-quote", fg Vty.brightBlack),
      (attrName "markdown-fence", fg Vty.brightMagenta),
      (attrName "diff-header", fg Vty.cyan),
      (attrName "diff-added", fg Vty.green),
      (attrName "diff-removed", fg Vty.red),
      (attrName "diff-hunk", fg Vty.magenta),
      (Edit.editAttr, fg Vty.white),
      (Edit.editFocusedAttr, fg Vty.brightWhite)
    ]

draw :: AppState -> [Widget Name]
draw state =
  [ vBox
      [ withAttr (attrName "title") (txt "agent-cat"),
        tabs (modelTab model),
        withAttr (attrName "status") (txtWrap (modelStatus model)),
        borderWithLabel (txt (screenTitle (modelScreen model))) (padAll 1 body),
        txt (footer state)
      ]
  ]
  where
    model = stateModel state
    body
      | stateCancelConfirm state = cancelConfirmationView
      | Just prompt <- statePersonPrompt state = personPromptView state prompt
      | Just (occurrence, recovery) <- queuedRecovery state = recoveryDecisionView occurrence recovery
      | Just timing <- stateSteerTiming state = steerView state timing
      | stateSaveResult state = saveResultView state
      | stateFilterEditing state = workflowFilterView state
      | otherwise = screenBody
    screenBody = case modelScreen model of
      BrowserScreen -> viewport MainViewport Vertical (vBox (map selectableLine (browserLines model)))
      InputScreen index -> inputView state index
      TargetScreen -> targetView model
      HelpLoading -> center (txt "Loading bounded runner help…")
      HelpScreen help -> viewport MainViewport Vertical (txt (boundedDisplay help))
      PreviewLoading -> center (txt "Building exact-input plan and routing preview…")
      ConfirmScreen preview -> confirmView (stateConfig state) preview
      LaunchingScreen _ -> center (txt "Waiting for the validated run.started event…")
      LiveScreen _ -> case modelSnapshot model of
        Nothing -> center (txt "Waiting for run.started…")
        Just snapshot -> liveView state snapshot
      FailureScreen failure -> withAttr (attrName "error") (txtWrap failure)
    selectableLine line
      | "> " `T.isPrefixOf` line = withAttr (attrName "selected") (txtWrap line)
      | otherwise = txtWrap line

cancelConfirmationView :: Widget Name
cancelConfirmationView =
  center
    ( borderWithLabel (txt "cancel owned run")
        (padAll 1 (vBox [txt "Cancel the machine child and its process group?", txt "", withAttr (attrName "selected") (txt "y cancel   n keep running")]))
    )

workflowFilterView :: AppState -> Widget Name
workflowFilterView state =
  vBox
    [ txt "Fuzzy workflow filter (subsequence match against name and description)",
      Edit.renderEditor (txt . T.unlines) True (stateEditor state),
      txt "Ctrl-D applies; Esc keeps the current filter."
    ]

saveResultView :: AppState -> Widget Name
saveResultView state =
  vBox
    [ txt "Copy the verified final JSON result to a new absolute path (existing files are refused).",
      Edit.renderEditor (txt . T.unlines) True (stateEditor state),
      maybe emptyWidget (withAttr (attrName "error") . txtWrap) (stateSaveError state),
      txt "Ctrl-D saves; Esc cancels."
    ]

queuedRecovery :: AppState -> Maybe (OccurrenceSnapshot, RecoverySnapshot)
queuedRecovery state = do
  _ <- stateRunning state
  occurrenceId <- case stateRecoveryQueue state of
    first : _ -> Just first
    [] -> Nothing
  snapshot <- modelSnapshot (stateModel state)
  occurrence <- Map.lookup occurrenceId (snapshotOccurrences snapshot)
  recovery <- snapshotOccurrenceRecovery occurrence
  pure (occurrence, recovery)

recoveryDecisionView :: OccurrenceSnapshot -> RecoverySnapshot -> Widget Name
recoveryDecisionView occurrence recovery =
  vBox
    [ txt ("Recovery required for occurrence " <> T.pack (show (occurrenceNumber (snapshotOccurrenceId occurrence)))),
      txtWrap (snapshotRecoveryGap recovery <> ": " <> snapshotRecoveryMessage recovery),
      txtWrap
        ( "Choose "
            <> T.intercalate
              ", "
              [ recoveryKey (recoveryChoice option) <> " " <> recoveryChoice option
                | option <- snapshotRecoveryChoices recovery
              ]
        ),
      txt "This FIFO decision cannot be bypassed by selecting a later occurrence.",
      txt "c requests whole-run cancellation."
    ]
  where
    recoveryKey "retry" = "r"
    recoveryKey "failover" = "f"
    recoveryKey "abandon" = "a"
    recoveryKey _ = "?"

steerView :: AppState -> SteeringTiming -> Widget Name
steerView state timing =
  vBox
    [ txt ("Steer selected active attempt (" <> steeringTimingText timing <> ")"),
      txt "The control is tied to the selected occurrence and physical attempt.",
      Edit.renderEditor (txt . T.unlines) True (stateEditor state),
      maybe emptyWidget (withAttr (attrName "error") . txtWrap) (stateControlError state),
      txt "Enter inserts a newline; Ctrl-D sends. Esc closes without sending."
    ]

personPromptView :: AppState -> PersonPrompt -> Widget Name
personPromptView state prompt =
  vBox
    [ txt ("Person answer required for occurrence " <> occurrenceNumberText (personPromptOccurrence prompt)),
      txt (personPromptIntent prompt <> "/" <> personPromptCode prompt),
      viewport MainViewport Vertical (txtWrap (boundedDisplay (personPromptText prompt))),
      txt "",
      if statePersonSubmitted state
        then withAttr (attrName "selected") (txt "Answer accepted locally; waiting for delivered acknowledgement…")
        else Edit.renderEditor (txt . T.unlines) True (stateEditor state),
      maybe emptyWidget (withAttr (attrName "error") . txtWrap) (statePersonError state),
      txt (personAnswerHelp (personPromptCode prompt))
    ]

liveView :: AppState -> RunSnapshot -> Widget Name
liveView state snapshot =
  vBox
    [ txtWrap
        ( "workflow "
            <> fromMaybe "starting" (snapshotWorkflow snapshot)
            <> "  persona "
            <> fromMaybe "none" (stateRunPersona state)
            <> "  realization "
            <> fromMaybe (liveAttemptTargets snapshot) (stateRunRealization state)
            <> "  run "
            <> runIdText (snapshotRunId snapshot)
            <> "  "
            <> T.pack (show (snapshotRunStatus snapshot))
            <> "  elapsed "
            <> elapsedText state
            <> billText snapshot
        ),
      hBox
        [ hLimit 52 (viewport MainViewport Vertical (vBox (map selectedLine (occurrenceRows snapshot (stateRunView state))))),
          vBorder,
          padLeft (Pad 1) (viewport OutputViewport Vertical (vBox (map styledLine (selectedOccurrenceLines snapshot (stateRunView state)))))
        ],
      txt (controlHint snapshot (stateRunView state)),
      maybe emptyWidget (withAttr (attrName "error") . txtWrap) (stateControlError state),
      finalResultView state snapshot
    ]
  where
    selectedLine line
      | "> " `T.isPrefixOf` line = withAttr (attrName "selected") (txtWrap line)
      | otherwise = txtWrap line

liveAttemptTargets :: RunSnapshot -> Text
liveAttemptTargets snapshot =
  case
      [ snapshotAttemptTarget attempt
        | occurrence <- Map.elems (snapshotOccurrences snapshot),
          attempt <- Map.elems (snapshotOccurrenceAttempts occurrence)
      ] of
    [] -> "pending"
    values -> T.intercalate ", " (deduplicate values)

elapsedText :: AppState -> Text
elapsedText state = case stateRunStartedAt state of
  Nothing -> "unknown"
  Just started ->
    let seconds = max 0 (floor (diffUTCTime (stateNow state) started) :: Integer)
        (hours, afterHours) = seconds `divMod` 3600
        (minutes, remainder) = afterHours `divMod` 60
     in if hours > 0
          then T.pack (show hours <> "h" <> show minutes <> "m" <> show remainder <> "s")
          else T.pack (show minutes <> "m" <> show remainder <> "s")

deduplicate :: (Eq a) => [a] -> [a]
deduplicate [] = []
deduplicate (value : rest) = value : deduplicate (filter (/= value) rest)

controlHint :: RunSnapshot -> RunView -> Text
controlHint snapshot view = case selectedOccurrence snapshot view of
  Nothing -> ""
  Just occurrence ->
    let steer = maybe "" (const "i steer-now  b steer-next  ") (activeAttemptForSelection snapshot view)
        recovery = case snapshotOccurrenceRecovery occurrence of
          Nothing -> ""
          Just pending ->
            T.unwords
              [ key <> " " <> recoveryChoice choice
                | choice <- snapshotRecoveryChoices pending,
                  let key = case recoveryChoice choice of
                        "retry" -> "r"
                        "failover" -> "f"
                        "abandon" -> "a"
                        _ -> "?"
              ]
        redirects = case snapshotOccurrenceDispatch occurrence of
          Just dispatch
            | dispatchOpen dispatch -> T.unwords [T.pack (show index) <> " " <> target | (index, target) <- zip [1 :: Int .. 9] (take 9 (dispatchTargets dispatch))]
          _ -> ""
     in T.strip (steer <> recovery <> "  " <> redirects)

finalResultView :: AppState -> RunSnapshot -> Widget Name
finalResultView state snapshot = case snapshotResult snapshot of
  Nothing -> emptyWidget
  Just reference ->
    borderWithLabel (txt "final result") $
      padAll 1 $ case stateFinalResult state of
        Nothing
          | stateFinalLoading state -> txt "Loading and verifying private result artifact…"
          | otherwise -> txtWrap (resultArtifactPreview reference)
        Just (Left failure) -> withAttr (attrName "error") (txtWrap failure)
        Just (Right value) -> txtWrap (boundedDisplay (TE.decodeUtf8 (BL.toStrict (encode value))))

billText :: RunSnapshot -> Text
billText snapshot = case (snapshotBillFresh snapshot, snapshotBillMemo snapshot) of
  (Nothing, Nothing) -> ""
  (fresh, memo) -> "  bill " <> maybe "?" (T.pack . show) fresh <> " fresh / " <> maybe "?" (T.pack . show) memo <> " memo"

boundedDisplay :: Text -> Text
boundedDisplay value
  | T.length value <= 262144 = value
  | otherwise = T.take 262144 value <> "\n[… display truncated; full value remains in the private run store …]"

personAnswerHelp :: Text -> Text
personAnswerHelp "text" = "Enter inserts a newline; Ctrl-D submits the exact text. c cancels the run."
personAnswerHelp "flag" = "Type yes/no or true/false, then Ctrl-D. c cancels the run."
personAnswerHelp "receipt" = "Leave the editor empty and press Ctrl-D to acknowledge. c cancels the run."
personAnswerHelp _ = "Enter a JSON value and press Ctrl-D. c cancels the run."

screenTitle :: Screen -> Text
screenTitle = \case
  BrowserScreen -> "browser"
  InputScreen _ -> "workflow input"
  TargetScreen -> "execution target"
  HelpLoading -> "workflow help"
  HelpScreen _ -> "workflow help"
  PreviewLoading -> "preview"
  ConfirmScreen _ -> "launch confirmation"
  LaunchingScreen _ -> "launching"
  LiveScreen _ -> "live run"
  FailureScreen _ -> "error"

tabs :: BrowserTab -> Widget Name
tabs selected =
  hBox
    [ tab WorkflowsTab "Workflows",
      txt "  ",
      tab RunsTab "Runs",
      txt "  ",
      tab RoutingTab "Routing"
    ]
  where
    tab value label
      | value == selected = withAttr (attrName "selected") (txt ("[" <> label <> "]"))
      | otherwise = txt label

inputView :: AppState -> Int -> Widget Name
inputView state index = case modelWorkflow model >>= (\descriptor -> atMay (workflowInputs descriptor) index) of
  Nothing -> withAttr (attrName "error") (txt "Input descriptor unavailable")
  Just input ->
    vBox
      [ txt ("Input " <> T.pack (show (index + 1)) <> ": " <> workflowInputName input <> " (" <> inputSourceText (workflowInputSource input) <> ")"),
        txt "Enter inserts a newline; Ctrl-D accepts this value.",
        Edit.renderEditor (txt . T.unlines) True (stateEditor state)
      ]
  where
    model = stateModel state

targetView :: TuiModel -> Widget Name
targetView model =
  vBox
    ( [txt "Press s for scripted execution, l for the selected live engine, or p for the next persona."]
        <> case modelRouting model of
          Left failure -> [txt ("Live routing unavailable: " <> failure)]
          Right routing ->
            [ txt ("Persona: " <> fromMaybe "none" (routingSummaryPersona routing)),
              txt ("Available personas: " <> T.intercalate ", " (routingSummaryPersonas routing)),
              txt ""
            ]
              <> [ if index == modelEngineIndex model then withAttr (attrName "selected") (txt line) else txt line
                   | (index, engine) <- zip [0 :: Int ..] (routingSummaryEngines routing),
                     let line = engineChoiceAlias engine <> "  " <> engineChoiceBackend engine
                 ]
    )

confirmView :: TuiConfig -> LaunchPreview -> Widget Name
confirmView config preview =
  let descriptor = previewDescriptor preview
      capabilities = workflowCapabilities descriptor
      target = case previewLineage preview of
        Just (operation, record) ->
          lineageText operation
            <> " from "
            <> runIdText (frontendRunId (recordManifest record))
            <> " using "
            <> frontendTargetKind (recordManifest record)
        Nothing -> case previewTarget preview of
          TargetScripted -> "scripted"
          TargetRestored kind _ -> "restored " <> kind
          TargetLive engine persona ->
            "live: "
              <> engineChoiceAlias engine
              <> " ("
              <> persona
              <> "); backend "
              <> engineChoiceBackend engine
              <> "; provider "
              <> engineChoiceProvider engine
      workingDirectory = maybe (tuiWorkingDir config) (frontendCwd . recordManifest . snd) (previewLineage preview)
      exactTargetArguments = case previewLineage preview of
        Just (_, record) -> Right (map T.unpack (frontendTargetArgs (recordManifest record)))
        Nothing -> targetArguments (previewTarget preview)
      renderedArguments = either ("invalid: " <>) (T.pack . show) exactTargetArguments
      exactEffectful = case previewPlan preview of
        Object plan -> case KeyMap.lookup "capabilities" plan of
          Just (Object capabilities') -> case KeyMap.lookup "effectful" capabilities' of
            Just (Bool value) -> value
            _ -> descriptorEffectful capabilities
          _ -> descriptorEffectful capabilities
        _ -> descriptorEffectful capabilities
   in vBox
        ( [ txt ("Workflow: " <> workflowName descriptor),
          txt ("Runner executable: " <> T.pack (tuiRunner config)),
          txtWrap ("Runner prefix arguments: " <> T.pack (show (tuiRunnerArgs config))),
          txtWrap ("Exact target arguments: " <> renderedArguments),
          txt ("Working directory: " <> T.pack workingDirectory),
          txt ("Target: " <> target),
          txt ("Effectful: " <> yesNo exactEffectful),
          txt ("Program SHA-256: " <> previewProgramHash preview),
          txt ("Private state root: " <> T.pack (tuiStateDir config))
        ]
          <> planConfirmationLines (previewPlan preview)
          <> routingConfirmationLines preview
          <> [ txt "",
          txt "Input bodies and secret values are intentionally omitted.",
          withAttr (attrName "selected") (txt "Press y to launch, n to return.")
          ]
        )

planConfirmationLines :: Value -> [Widget Name]
planConfirmationLines (Object plan) =
  [ txtWrap
      ( "Exact-input plan: "
          <> scalarField "level" plan
          <> "; size "
          <> scalarField "size" plan
          <> "; ask nodes "
          <> scalarField "askNodes" plan
          <> "; fold "
          <> scalarField "minFold" plan
          <> "–"
          <> scalarField "maxFold" plan
          <> " over "
          <> scalarField "paths" plan
          <> " paths"
      ),
    txtWrap ("Code sequence: " <> arrayField "codes" plan)
  ]
planConfirmationLines _ = [withAttr (attrName "error") (txt "Exact-input plan is not an object")]

scalarField :: KeyMap.Key -> KeyMap.KeyMap Value -> Text
scalarField name fields = case KeyMap.lookup name fields of
  Just (String value) -> value
  Just (Number value) -> T.pack (show value)
  Just Null -> "none"
  _ -> "?"

arrayField :: KeyMap.Key -> KeyMap.KeyMap Value -> Text
arrayField name fields = case KeyMap.lookup name fields of
  Just (Array values) ->
    let rendered = [value | String value <- Vector.toList values]
     in if null rendered then "none" else boundedDisplay (T.intercalate " → " rendered)
  _ -> "?"

routingConfirmationLines :: LaunchPreview -> [Widget Name]
routingConfirmationLines preview = case previewRouting preview of
  Nothing -> []
  Just routing ->
    map (txtWrap . ("Concrete realization: " <>)) realizations
      <> [txtWrap ("Routing warnings: " <> if null (routingSummaryWarnings routing) then "none" else T.intercalate "; " (routingSummaryWarnings routing))]
    where
      realizations = case concatMap routingProfileLines (routingSummaryProfiles routing) of
        [] -> ["unavailable"]
        values -> values

routingProfileLines :: RoutingProfileChoice -> [Text]
routingProfileLines profile =
  map (routingRungLine (routingProfileName profile)) (routingProfileRungs profile)

routingRungLine :: Text -> RoutingRungChoice -> Text
routingRungLine profileName rung =
  profileName
    <> ": "
    <> routingRungAxis rung
    <> " #"
    <> T.pack (show (routingRungNumber rung))
    <> " -> "
    <> routingRungModel rung
    <> maybe "" (" (" <>) (fmap (<> ")") (routingRungModelAlias rung))
    <> " on "
    <> routingRungRouter rung
    <> " ["
    <> routingRungBackend rung
    <> "; "
    <> routingRungProvider rung
    <> "; thinking "
    <> routingRungThinking rung
    <> "; inventory "
    <> routingInventoryProvenance (routingRungInventory rung)
    <> "]"

routingInventoryProvenance :: RoutingInventoryChoice -> Text
routingInventoryProvenance inventory =
  routingInventorySource inventory
    <> maybe "" ("; fingerprint " <>) (routingInventoryFingerprint inventory)
    <> maybe "" ("; fetched " <>) (routingInventoryFetchedAt inventory)

footer :: AppState -> Text
footer state
  | stateSaveResult state = "Ctrl-D save verified result  Esc cancel"
  | isJust (statePersonPrompt state) = "Ctrl-D submit person answer  c cancel"
  | not (null (stateRecoveryQueue state)) = "r retry  f failover  a abandon  c cancel (FIFO recovery)"
  | stateFilterEditing state = "Ctrl-D apply fuzzy filter  Esc cancel"
  | otherwise = footerScreen state (modelScreen (stateModel state))

footerScreen :: AppState -> Screen -> Text
footerScreen state = \case
  BrowserScreen
    | isJust (stateRunning state) -> "↑/↓ select  Tab pane  Enter open  Esc live run  c cancel owned run"
    | modelTab (stateModel state) == RunsTab -> "↑/↓ select  Enter inspect  r restart  m resume  f fork  q quit"
    | modelTab (stateModel state) == RoutingTab -> "↑/↓ select  p next persona  Tab pane  q quit"
    | otherwise -> "↑/↓ select  / filter  Enter launch  h help  Tab pane  q quit"
  InputScreen _ -> "Ctrl-D accept  Esc back"
  TargetScreen -> "s scripted  l live  p next persona  ↑/↓ engine  Esc back"
  HelpLoading -> "runner help subprocess is bounded to 30 seconds / 4 MiB"
  HelpScreen _ -> "↑/↓ scroll  Esc return to browser"
  PreviewLoading -> "preview subprocess is bounded to 30 seconds / 4 MiB"
  ConfirmScreen _ -> "y launch  n back"
  LaunchingScreen _ -> "Esc detach to browser  c cancel"
  LiveScreen _
    | isJust (stateRunning state) -> "j/k occurrence  ↑/↓ scroll  G follow tail  Esc detach  c cancel"
    | Just (Right _) <- stateFinalResult state -> "j/k occurrence  ↑/↓ scroll  G follow tail  s save/copy result  Esc return to runs"
    | otherwise -> "j/k occurrence  ↑/↓ scroll  G follow tail  Esc return to runs"
  FailureScreen _ -> "Esc return to browser"

handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent event = case event of
  AppEvent FrameReady -> handleFrame
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
      Left failure -> put state {stateModel = (stateModel state) {modelStatus = "run catalogue refresh failed: " <> failure}}
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
                { stateModel = model {modelRuns = records, modelRunIndex = selected},
                  stateViewingRecord = case contextRecord of
                    Just record -> Just record
                    Nothing -> stateViewingRecord state,
                  stateRunPersona = maybe (stateRunPersona state) (frontendPersona . recordManifest) contextRecord,
                  stateRunRealization = maybe (stateRunRealization state) (Just . runRecordRealizations) contextRecord
                }
  AppEvent (RoutingReady requested result) -> do
    state <- get
    when (stateRoutingRequest state == Just requested) $ case result of
      Left failure -> put state {stateRoutingRequest = Nothing, stateModel = (stateModel state) {modelStatus = "routing persona failed: " <> failure}}
      Right routing
        | routingSummaryPersona routing == Just requested ->
            put state {stateRoutingRequest = Nothing, stateModel = (stateModel state) {modelRouting = Right routing, modelEngineIndex = 0, modelStatus = "routing persona selected"}}
        | otherwise ->
            put state {stateRoutingRequest = Nothing, stateModel = (stateModel state) {modelStatus = "routing inspection returned another persona"}}
  AppEvent (ChildStopped outcome) -> do
    state <- get
    case outcome of
      MachineProtocolFailed failure -> do
        put state {stateMachineFailure = Just failure, stateModel = (stateModel state) {modelScreen = FailureScreen failure, modelStatus = "machine protocol failed"}}
        liftIO . void . forkIO $ mapM_ terminateMachine (stateRunning state)
      MachineExited _ _ -> do
        put state {statePendingExit = Just outcome}
        queueEmpty <- liftIO . atomically $ isEmptyTBQueue (stateEvents state)
        if queueEmpty
          then finalizePendingExit
          else liftIO (notifyFrame (stateChannel state) (stateFramePending state))
  AppEvent (PersonPromptReady occurrence result) -> do
    state <- get
    when (statePersonLoading state == Just occurrence) $ case result of
      Left failure -> do
        liftIO . void . forkIO $ mapM_ terminateMachine (stateRunning state)
        put
          state
            { stateModel = (stateModel state) {modelScreen = FailureScreen ("private person question is invalid: " <> failure)},
              stateMachineFailure = Just ("private person question is invalid: " <> failure),
              statePersonLoading = Nothing,
              statePersonError = Just failure
            }
      Right prompt ->
        put
          state
            { statePersonLoading = Nothing,
              statePersonPrompt = Just prompt,
              statePersonSubmitted = False,
              statePersonControlId = Nothing,
              statePersonError = Nothing,
              stateEditor = Edit.editorText InputEditor Nothing ""
            }
  AppEvent (FinalResultReady runId result) -> do
    state <- get
    when (maybe False ((== runId) . snapshotRunId) (modelSnapshot (stateModel state))) $
      put state {stateFinalLoading = False, stateFinalResult = Just result}
  VtyEvent key -> handleKey event key
  _ -> pure ()

finalizePendingExit :: EventM Name AppState ()
finalizePendingExit = do
  state <- get
  case statePendingExit state of
    Nothing -> pure ()
    Just outcome -> do
      liftIO (writeIORef (stateOwned state) Nothing)
      let model = stateModel state
          stoppedModel = case stateMachineFailure state of
            Just failure -> model {modelScreen = FailureScreen failure, modelStatus = "machine protocol failed"}
            Nothing -> case outcome of
              MachineExited status diagnostic
                | maybe False (terminalStatus . snapshotRunStatus) (modelSnapshot model) -> model {modelStatus = "machine child exited"}
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
            stateCancelConfirm = False,
            stateSteerTiming = Nothing,
            statePersonPrompt = if maybe False (terminalStatus . snapshotRunStatus) (modelSnapshot model) then Nothing else statePersonPrompt state
          }
      refreshRuns

handleKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleKey original key = do
  state <- get
  if stateSaveResult state
    then handleSaveResultKey original key
    else if stateFilterEditing state
      then handleFilterKey original key
      else if stateCancelConfirm state
        then handleCancelKey key
        else if isJust (stateRunning state) && not (null (stateRecoveryQueue state)) && not (isJust (statePersonPrompt state))
          then maybe (pure ()) (\occurrence -> handleRecoveryKey occurrence key) (listToMaybe (stateRecoveryQueue state))
          else case statePersonPrompt state of
      Just _ -> case key of
        Vty.EvKey (Vty.KChar 'c') [] -> requestCancellation
        Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl]
          | not (statePersonSubmitted state) -> submitPersonAnswer
        _
          | statePersonSubmitted state -> pure ()
          | otherwise -> handlePersonEditorInput original
      Nothing
        | Just _ <- stateSteerTiming state -> case key of
            Vty.EvKey Vty.KEsc [] -> put state {stateSteerTiming = Nothing, stateControlError = Nothing}
            Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> submitSteer
            _ -> handleControlEditorInput original
      Nothing -> case (modelScreen (stateModel state), key) of
        (BrowserScreen, Vty.EvKey (Vty.KChar 'q') [])
          | not (isJust (stateRunning state)) -> halt
        (BrowserScreen, Vty.EvKey Vty.KEsc []) -> handleEscape
        (BrowserScreen, Vty.EvKey Vty.KUp []) -> handleMove (-1)
        (BrowserScreen, Vty.EvKey Vty.KDown []) -> handleMove 1
        (BrowserScreen, Vty.EvKey (Vty.KChar '\t') []) -> cycleBrowserTab
        (BrowserScreen, Vty.EvKey (Vty.KChar 'p') []) -> cycleRoutingPersona
        (BrowserScreen, Vty.EvKey Vty.KEnter []) -> handleEnter
        (BrowserScreen, Vty.EvKey (Vty.KChar 'h') []) -> showSelectedHelp
        (BrowserScreen, Vty.EvKey (Vty.KChar '/') [])
          | modelTab (stateModel state) == WorkflowsTab -> openWorkflowFilter
        (BrowserScreen, Vty.EvKey (Vty.KChar 'r') []) -> beginLineage RestartRun
        (BrowserScreen, Vty.EvKey (Vty.KChar 'm') []) -> beginLineage ResumeRun
        (BrowserScreen, Vty.EvKey (Vty.KChar 'f') []) -> beginLineage ForkRun
        (BrowserScreen, Vty.EvKey (Vty.KChar 'c') []) -> requestCancellation
        (InputScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
        (InputScreen _, Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl]) -> submitEditor
        (InputScreen _, _) -> handleEditorInput original
        (TargetScreen, Vty.EvKey Vty.KEsc []) -> handleEscape
        (TargetScreen, Vty.EvKey Vty.KUp []) -> handleMove (-1)
        (TargetScreen, Vty.EvKey Vty.KDown []) -> handleMove 1
        (TargetScreen, Vty.EvKey (Vty.KChar 's') []) -> chooseScripted
        (TargetScreen, Vty.EvKey (Vty.KChar 'l') []) -> chooseLive
        (TargetScreen, Vty.EvKey (Vty.KChar 'p') []) -> cycleRoutingPersona
        (PreviewLoading, Vty.EvKey Vty.KEsc []) -> handleEscape
        (ConfirmScreen _, Vty.EvKey (Vty.KChar 'y') []) -> confirmLaunch
        (ConfirmScreen _, Vty.EvKey (Vty.KChar 'n') []) -> modify $ \value -> value {stateModel = (stateModel value) {modelScreen = TargetScreen}}
        (LaunchingScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
        (LaunchingScreen _, Vty.EvKey (Vty.KChar 'c') []) -> requestCancellation
        (LiveScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
        (LiveScreen _, Vty.EvKey Vty.KUp []) -> handleMove (-1)
        (LiveScreen _, Vty.EvKey Vty.KDown []) -> handleMove 1
        (LiveScreen _, Vty.EvKey (Vty.KChar 'G') []) -> followOutputTail
        (LiveScreen _, Vty.EvKey Vty.KEnd []) -> followOutputTail
        (LiveScreen _, Vty.EvKey (Vty.KChar 'j') []) -> moveOccurrence 1
        (LiveScreen _, Vty.EvKey (Vty.KChar 'k') []) -> moveOccurrence (-1)
        (LiveScreen _, Vty.EvKey (Vty.KChar 'i') []) -> openSteer InterruptNow
        (LiveScreen _, Vty.EvKey (Vty.KChar 'b') []) -> openSteer NextBoundary
        (LiveScreen _, Vty.EvKey (Vty.KChar 'r') []) -> sendRecovery RecoveryRetry
        (LiveScreen _, Vty.EvKey (Vty.KChar 'f') []) -> sendRecovery RecoveryFailOver
        (LiveScreen _, Vty.EvKey (Vty.KChar 'a') []) -> sendRecovery RecoveryAbandon
        (LiveScreen _, Vty.EvKey (Vty.KChar digit) [])
          | digit >= '1' && digit <= '9' -> redirectSelected (fromEnum digit - fromEnum '1')
        (LiveScreen _, Vty.EvKey (Vty.KChar 'c') []) -> requestCancellation
        (LiveScreen _, Vty.EvKey (Vty.KChar 's') [])
          | Just (Right _) <- stateFinalResult state -> openSaveResult
        (HelpLoading, Vty.EvKey Vty.KEsc []) -> handleEscape
        (HelpScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
        (HelpScreen _, Vty.EvKey Vty.KUp []) -> handleMove (-1)
        (HelpScreen _, Vty.EvKey Vty.KDown []) -> handleMove 1
        (FailureScreen _, Vty.EvKey Vty.KEsc []) -> handleEscape
        _ -> pure ()

handleRecoveryKey :: OccurrenceId -> Vty.Event -> EventM Name AppState ()
handleRecoveryKey occurrence key = case key of
  Vty.EvKey (Vty.KChar 'r') [] -> sendRecoveryFor occurrence RecoveryRetry
  Vty.EvKey (Vty.KChar 'f') [] -> sendRecoveryFor occurrence RecoveryFailOver
  Vty.EvKey (Vty.KChar 'a') [] -> sendRecoveryFor occurrence RecoveryAbandon
  Vty.EvKey (Vty.KChar 'c') [] -> requestCancellation
  _ -> pure ()

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
  put state {stateFilterEditing = True, stateEditor = Edit.editorText InputEditor (Just 1) query}

handleFilterKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleFilterKey original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateFilterEditing = False})
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> do
    state <- get
    let query = T.unwords (T.words (T.intercalate "\n" (Edit.getEditContents (stateEditor state))))
    put
      state
        { stateFilterEditing = False,
          stateModel = (setWorkflowFilter query (stateModel state)) {modelStatus = "workflow filter applied"}
        }
  _ -> do
    state <- get
    (editor, ()) <- nestEventM (stateEditor state) (Edit.handleEditorEvent original)
    let query = T.intercalate "\n" (Edit.getEditContents editor)
    if BS.length (TE.encodeUtf8 query) <= 256
      then put state {stateEditor = editor}
      else put state {stateModel = (stateModel state) {modelStatus = "workflow filter exceeds 256 UTF-8 bytes"}}

openSaveResult :: EventM Name AppState ()
openSaveResult =
  modify
    ( \state ->
        state
          { stateSaveResult = True,
            stateSaveError = Nothing,
            stateEditor = Edit.editorText InputEditor (Just 1) ""
          }
    )

handleSaveResultKey :: BrickEvent Name AppEvent -> Vty.Event -> EventM Name AppState ()
handleSaveResultKey original key = case key of
  Vty.EvKey Vty.KEsc [] -> modify (\state -> state {stateSaveResult = False, stateSaveError = Nothing})
  Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> saveFinalResult
  _ -> do
    state <- get
    (editor, ()) <- nestEventM (stateEditor state) (Edit.handleEditorEvent original)
    let path = T.intercalate "\n" (Edit.getEditContents editor)
    if BS.length (TE.encodeUtf8 path) <= 4096
      then put state {stateEditor = editor, stateSaveError = Nothing}
      else put state {stateSaveError = Just "result path exceeds 4096 UTF-8 bytes"}

saveFinalResult :: EventM Name AppState ()
saveFinalResult = do
  state <- get
  let pathText = T.intercalate "\n" (Edit.getEditContents (stateEditor state))
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
cycleRoutingPersona = do
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
            config = stateConfig state
        put state {stateRoutingRequest = Just next, stateModel = model {modelStatus = "loading routing persona " <> next}}
        liftIO . startWorker state RoutingWork $ loadRoutingSummary config (Just next) >>= writeBChan channel . RoutingReady next

cycleBrowserTab :: EventM Name AppState ()
cycleBrowserTab = do
  state <- get
  let model = cycleTab (stateModel state)
  put state {stateModel = model}
  when (modelTab model == RunsTab) refreshRuns

refreshRuns :: EventM Name AppState ()
refreshRuns = do
  state <- get
  let config = stateConfig state
      channel = stateChannel state
  liftIO . startWorker state RunsWork $ loadRunCatalogue config (stateRoot state) >>= writeBChan channel . RunsReady

handleMove :: Int -> EventM Name AppState ()
handleMove delta = do
  state <- get
  case modelScreen (stateModel state) of
    BrowserScreen -> modify $ \value -> value {stateModel = moveSelection delta (stateModel value)}
    TargetScreen -> modify $ \value -> value {stateModel = moveSelection delta (stateModel value)}
    LaunchingScreen _ -> pure ()
    LiveScreen _ -> do
      put state {stateOutputFollow = False}
      vScrollBy (viewportScroll OutputViewport) delta
    HelpScreen _ -> vScrollBy (viewportScroll MainViewport) delta
    _ -> pure ()

handleEnter :: EventM Name AppState ()
handleEnter = do
  state <- get
  case modelScreen (stateModel state) of
    BrowserScreen
      | Just running <- stateRunning state ->
          put state {stateModel = (stateModel state) {modelScreen = LiveScreen (runningRunId running), modelStatus = "reattached to owned run"}}
      | modelTab (stateModel state) == WorkflowsTab -> do
          let model = beginWorkflow (stateModel state)
          put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing ""}
      | modelTab (stateModel state) == RunsTab -> openSelectedRun
    _ -> pure ()

appendPersonOccurrence :: [OccurrenceId] -> Envelope -> [OccurrenceId]
appendPersonOccurrence queued envelope = case envelopeEvent envelope of
  OccurrencePersonAnswerPending occurrence _
    | occurrence `elem` queued -> queued
    | otherwise -> queued <> [occurrence]
  _ -> queued

appendRecoveryOccurrence :: [OccurrenceId] -> Envelope -> [OccurrenceId]
appendRecoveryOccurrence queued envelope = case envelopeEvent envelope of
  OccurrenceRecoveryPending occurrence _ _ _
    | occurrence `elem` queued -> queued
    | otherwise -> queued <> [occurrence]
  OccurrenceRecoveryChosen occurrence _ _ _ -> filter (/= occurrence) queued
  OccurrenceRetried occurrence _ -> filter (/= occurrence) queued
  OccurrenceFailed occurrence _ _ -> filter (/= occurrence) queued
  OccurrenceCompleted occurrence _ _ -> filter (/= occurrence) queued
  RunFailed {} -> []
  RunCancelled {} -> []
  _ -> queued


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
              stateOutputFollow = True,
              stateRunStartedAt = Just startedAt,
              stateRunPersona = frontendPersona manifest,
              stateRunRealization = Just (runRecordRealizations record),
              stateSaveResult = False,
              stateSaveError = Nothing,
              statePersonQueue = [],
              stateRecoveryQueue = [],
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
beginLineage operation = do
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
                  liftIO . startWorker state PreviewWork $ buildLineagePreview (stateConfig state) (stateRoot state) descriptor record operation >>= writeBChan channel . PreviewReady request

submitEditor :: EventM Name AppState ()
submitEditor = do
  state <- get
  case modelScreen (stateModel state) of
    InputScreen _ -> do
      let value = T.intercalate "\n" (Edit.getEditContents (stateEditor state))
          model = submitInput value (stateModel state)
      put state {stateModel = model, stateEditor = Edit.editorText InputEditor Nothing ""}
    _ -> pure ()

chooseScripted :: EventM Name AppState ()
chooseScripted = beginPreview TargetScripted

chooseLive :: EventM Name AppState ()
chooseLive = do
  state <- get
  let model = stateModel state
  case modelRouting model of
    Left failure -> put state {stateModel = model {modelScreen = FailureScreen failure}}
    Right routing -> case atMay (routingSummaryEngines routing) (modelEngineIndex model) of
      Nothing -> put state {stateModel = model {modelScreen = FailureScreen "no live routing engine is available"}}
      Just engine -> case routingSummaryPersona routing of
        Nothing -> put state {stateModel = model {modelScreen = FailureScreen "routing inspection selected no persona"}}
        Just persona -> beginPreview (TargetLive engine persona)

beginPreview :: TargetSelection -> EventM Name AppState ()
beginPreview target = do
  state <- get
  case modelWorkflow (stateModel state) of
    Nothing -> put state {stateModel = (stateModel state) {modelScreen = FailureScreen "no workflow selected"}}
    Just descriptor -> do
      let request = stateRequestSerial state + 1
          model = chooseTarget target (stateModel state)
          config = stateConfig state
          inputs = modelInputs model
          channel = stateChannel state
          routing = case target of
            TargetScripted -> Nothing
            TargetLive {} -> either (const Nothing) Just (modelRouting model)
            TargetRestored {} -> Nothing
      put state {stateModel = model, stateRequestSerial = request, statePreviewRequest = Just request}
      liftIO . startWorker state PreviewWork $ do
        result <- buildLaunchPreview config (stateRoot state) descriptor inputs target
        writeBChan channel (PreviewReady request (fmap (\preview -> preview {previewRouting = routing}) result))

confirmLaunch :: EventM Name AppState ()
confirmLaunch = do
  state <- get
  case modelScreen (stateModel state) of
    ConfirmScreen preview -> do
      let channel = stateChannel state
          queue = stateEvents state
          notify = notifyFrame channel (stateFramePending state)
          stopped = writeBChan channel . ChildStopped
      started <- liftIO $ mask $ \_ -> do
        result <- startMachine (stateConfig state) (stateRoot state) preview queue notify stopped
        case result of
          Right running -> writeIORef (stateOwned state) (Just running)
          Left _ -> pure ()
        pure result
      case started of
        Left failure -> put state {stateModel = (stateModel state) {modelScreen = FailureScreen failure}}
        Right running -> do
          now <- liftIO getCurrentTime
          let snapshot = initialRunSnapshot (runningRunId running)
          put
            state
              { stateRunning = Just running,
                statePendingExit = Nothing,
                stateMachineFailure = Nothing,
                stateRunView = emptyRunView,
                stateOutputFollow = True,
                stateRunStartedAt = Just now,
                stateRunPersona = previewPersona preview,
                stateRunRealization = Just (previewRealizationSummary preview),
                stateSaveResult = False,
                stateSaveError = Nothing,
                stateRuntimeDirectory = Just (runningDirectory running </> "runtime"),
                stateViewingRecord = Nothing,
                statePersonQueue = [],
                stateRecoveryQueue = [],
                statePersonLoading = Nothing,
                statePersonPrompt = Nothing,
                statePersonSubmitted = False,
                statePersonControlId = Nothing,
                statePersonError = Nothing,
                stateSteerTiming = Nothing,
                stateControlError = Nothing,
                stateFinalResult = Nothing,
                stateFinalLoading = False,
                stateModel = launchStarted (runningRunId running) snapshot (stateModel state)
              }
    _ -> pure ()

previewPersona :: LaunchPreview -> Maybe Text
previewPersona preview = case previewLineage preview of
  Just (_, record) -> frontendPersona (recordManifest record)
  Nothing -> case previewTarget preview of
    TargetLive _ persona -> Just persona
    _ -> Nothing

previewRealizationSummary :: LaunchPreview -> Text
previewRealizationSummary preview = case previewRouting preview of
  Nothing -> case previewTarget preview of
    TargetScripted -> "scripted"
    TargetRestored kind _ -> kind
    TargetLive engine _ -> engineChoiceAlias engine <> "/" <> engineChoiceProvider engine
  Just routing -> case concatMap routingProfileLines (routingSummaryProfiles routing) of
    [] -> "unavailable"
    values -> boundedDisplay (T.intercalate " | " values)

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
  (envelopes, more) <- liftIO . atomically $ do
    writeTVar (stateFramePending state) False
    values <- drain 512 (stateEvents state)
    pending <- not <$> isEmptyTBQueue (stateEvents state)
    pure (values, pending)
  let stepped = foldSnapshots (modelSnapshot (stateModel state)) envelopes
  case stepped of
    Left failure -> do
      put state {stateMachineFailure = Just failure, stateModel = (stateModel state) {modelScreen = FailureScreen failure, modelStatus = "machine protocol failed"}}
      liftIO . void . forkIO $ mapM_ terminateMachine (stateRunning state)
    Right Nothing -> pure ()
    Right (Just snapshot) -> do
      let baseView = reconcileRunView snapshot (stateRunView state)
          personQueue = foldl appendPersonOccurrence (statePersonQueue state) envelopes
          recoveryQueue = foldl appendRecoveryOccurrence (stateRecoveryQueue state) envelopes
          view = case recoveryQueue of
            first : _ -> RunView (Just first)
            [] -> baseView
          contextNeeded =
            isJust (snapshotWorkflow snapshot)
              && maybe True (not . isJust . snapshotWorkflow) (modelSnapshot (stateModel state))
      put
        state
          { stateModel = snapshotUpdated snapshot (stateModel state),
            stateRunView = view,
            statePersonQueue = personQueue,
            stateRecoveryQueue = recoveryQueue
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
ensureAuxiliaryLoads = do
  original <- get
  case modelSnapshot (stateModel original) of
    Nothing -> pure ()
    Just snapshot -> do
      let active = not (terminalStatus (snapshotRunStatus snapshot))
          allPending = if active then pendingPersonOccurrences snapshot else []
          queued =
            [ occurrence
              | occurrenceId <- statePersonQueue original,
                occurrence <- allPending,
                snapshotOccurrenceId occurrence == occurrenceId
            ]
          pending = queued <> [occurrence | occurrence <- allPending, snapshotOccurrenceId occurrence `notElem` map snapshotOccurrenceId queued]
          pendingIds = map snapshotOccurrenceId pending
          promptStillPending = maybe False ((`elem` pendingIds) . personPromptOccurrence) (statePersonPrompt original)
          loadingStillPending = maybe True (`elem` pendingIds) (statePersonLoading original)
          personAck = statePersonControlId original >>= (`Map.lookup` snapshotControlAcks snapshot)
          answerFailed = maybe False ((`elem` ["failed", "rejected-stale", "unsupported"]) . snapshotControlState) personAck
          answerError = if answerFailed then snapshotControlMessage <$> personAck else statePersonError original
          synchronized =
            original
              { statePersonQueue = pendingIds,
                statePersonPrompt = if promptStillPending then statePersonPrompt original else Nothing,
                statePersonLoading = if loadingStillPending then statePersonLoading original else Nothing,
                statePersonSubmitted = promptStillPending && statePersonSubmitted original && not answerFailed,
                statePersonControlId = if promptStillPending && not answerFailed then statePersonControlId original else Nothing,
                statePersonError = if promptStillPending then answerError else Nothing
              }
      put synchronized
      state <- get
      case (stateRunning state, stateRuntimeDirectory state, statePersonPrompt state, statePersonLoading state, pending) of
        (Just _, Just runtimeDirectory, Nothing, Nothing, occurrence : _) -> do
          let occurrenceId = snapshotOccurrenceId occurrence
              channel = stateChannel state
              runId = snapshotRunId snapshot
          put state {statePersonLoading = Just occurrenceId}
          liftIO . startWorker state PersonWork $ loadPersonPrompt (stateRoot state) runtimeDirectory runId occurrence >>= writeBChan channel . PersonPromptReady occurrenceId
        _ -> pure ()
      latest <- get
      case (snapshotResult snapshot, stateRuntimeDirectory latest, stateFinalResult latest, stateFinalLoading latest) of
        (Just reference, Just runtimeDirectory, Nothing, False) -> do
          let channel = stateChannel latest
              runId = snapshotRunId snapshot
          put latest {stateFinalLoading = True}
          liftIO . startWorker latest ResultWork $ do
            outcome <- try @SomeException $ do
              components <- privatePathComponents (stateRoot latest) runtimeDirectory
              withPrivateDirectoryAt (stateRoot latest) components $ \descriptor ->
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
    LaunchingScreen _ -> put (detachedState state)
    LiveScreen _ -> put (detachedState state)
    BrowserScreen
      | isJust (stateRunning state) ->
          put state {stateModel = (stateModel state) {modelScreen = maybe BrowserScreen (LiveScreen . runningRunId) (stateRunning state)}}
    _ -> put state {stateModel = returnToBrowser (stateModel state)}
  where
    detachedState current
      | isJust (stateRunning current) = current {stateModel = returnToBrowser (stateModel current)}
      | otherwise =
          current
            { stateModel = returnToBrowser (stateModel current),
              stateViewingRecord = Nothing,
              stateRuntimeDirectory = Nothing,
              statePersonQueue = [],
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
    (Just running, Just prompt) -> do
      let input = T.intercalate "\n" (Edit.getEditContents (stateEditor state))
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

styledLine :: Text -> Widget Name
styledLine line = case classifyLine line of
  PlainLine -> txtWrap line
  StatusLine -> withAttr (attrName "status") (txtWrap line)
  MarkdownHeadingLine -> withAttr (attrName "markdown-heading") (txtWrap line)
  MarkdownQuoteLine -> withAttr (attrName "markdown-quote") (txtWrap line)
  MarkdownFenceLine -> withAttr (attrName "markdown-fence") (txtWrap line)
  DiffHeaderLine -> withAttr (attrName "diff-header") (txtWrap line)
  DiffAddedLine -> withAttr (attrName "diff-added") (txtWrap line)
  DiffRemovedLine -> withAttr (attrName "diff-removed") (txtWrap line)
  DiffHunkLine -> withAttr (attrName "diff-hunk") (txtWrap line)

moveOccurrence :: Int -> EventM Name AppState ()
moveOccurrence delta = do
  state <- get
  case modelSnapshot (stateModel state) of
    Nothing -> pure ()
    Just snapshot -> do
      put state {stateRunView = moveOccurrenceSelection delta snapshot (stateRunView state), stateOutputFollow = True}
      vScrollBy (viewportScroll MainViewport) delta
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
      put state {stateSteerTiming = Just timing, stateControlError = Nothing, stateEditor = Edit.editorText InputEditor Nothing ""}
    _ -> put state {stateControlError = Just "the selected occurrence has no steerable active attempt"}

submitSteer :: EventM Name AppState ()
submitSteer = do
  state <- get
  let text = T.intercalate "\n" (Edit.getEditContents (stateEditor state))
  case (stateSteerTiming state, modelSnapshot (stateModel state)) of
    (Just timing, Just snapshot) -> case activeAttemptForSelection snapshot (stateRunView state) of
      Nothing -> put state {stateSteerTiming = Nothing, stateControlError = Just "the selected attempt is no longer active"}
      Just attempt
        | T.null (T.strip text) -> put state {stateControlError = Just "steering text is empty"}
        | otherwise -> sendSelectedControl "steer" (attemptOccurrence attempt) (Just attempt) (Steer timing text) True
    _ -> pure ()

sendRecovery :: RecoveryControl -> EventM Name AppState ()
sendRecovery recovery = do
  state <- get
  case modelSnapshot (stateModel state) >>= \snapshot -> selectedOccurrence snapshot (stateRunView state) of
    Nothing -> put state {stateControlError = Just "no occurrence is selected"}
    Just occurrence -> sendRecoveryFor (snapshotOccurrenceId occurrence) recovery

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

steeringTimingText :: SteeringTiming -> Text
steeringTimingText InterruptNow = "interrupt-now"
steeringTimingText NextBoundary = "next-boundary"

freshControlId :: Text -> IO ControlId
freshControlId purpose = do
  stamp <- getMonotonicTimeNSec
  pure (ControlId ("tui." <> purpose <> "." <> T.pack (show stamp)))

handleEditorInput :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEditorInput event = do
  state <- get
  case modelScreen (stateModel state) of
    InputScreen _ -> updateEditor event False
    _ -> pure ()

handlePersonEditorInput :: BrickEvent Name AppEvent -> EventM Name AppState ()
handlePersonEditorInput event = updateEditor event True

handleControlEditorInput :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleControlEditorInput event = do
  state <- get
  (editor, ()) <- nestEventM (stateEditor state) (Edit.handleEditorEvent event)
  let bytes = BS.length (TE.encodeUtf8 (T.intercalate "\n" (Edit.getEditContents editor)))
  if bytes <= 1024 * 1024
    then put state {stateEditor = editor, stateControlError = Nothing}
    else put state {stateControlError = Just "control text exceeds 1048576 UTF-8 bytes"}

updateEditor :: BrickEvent Name AppEvent -> Bool -> EventM Name AppState ()
updateEditor event personEditor = do
  state <- get
  (editor, ()) <- nestEventM (stateEditor state) (Edit.handleEditorEvent event)
  let bytes = BS.length (TE.encodeUtf8 (T.intercalate "\n" (Edit.getEditContents editor)))
  if bytes <= 1024 * 1024
    then put state {stateEditor = editor, statePersonError = if personEditor then Nothing else statePersonError state}
    else
      if personEditor
        then put state {statePersonError = Just "answer exceeds 1048576 UTF-8 bytes"}
        else put state {stateModel = (stateModel state) {modelStatus = "input exceeds 1048576 UTF-8 bytes"}}

terminalStatus :: RunStatus -> Bool
terminalStatus RunSucceeded = True
terminalStatus RunFailedStatus = True
terminalStatus RunCancelledStatus = True
terminalStatus RunStarting = False
terminalStatus RunRunning = False
terminalStatus RunCancelling = False
terminalStatus RunOrphaned = False

lineageText :: LineageOperation -> Text
lineageText RootRun = "root"
lineageText RestartRun = "restart"
lineageText ResumeRun = "resume"
lineageText ForkRun = "fork"

inputSourceText :: WorkflowInputSource -> Text
inputSourceText DescriptorPrompt = "prompt"
inputSourceText DescriptorCommandTail = "command tail"
inputSourceText DescriptorStdin = "standard input"

occurrenceNumberText :: OccurrenceId -> Text
occurrenceNumberText = T.pack . show . occurrenceNumber

yesNo :: Bool -> Text
yesNo True = "yes"
yesNo False = "no"

showSelectedHelp :: EventM Name AppState ()
showSelectedHelp = do
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
              config = stateConfig state
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
