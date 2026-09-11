{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Runtime
  ( CatalogueEntry (..),
    AttemptSnapshot (..),
    LineageOperation (..),
    OccurrenceState (..),
    RecoverySnapshot (..),
    RecoveryOption (..),
    Envelope (..),
    ExactPlanSummary (..),
    FrontendInvocation (..),
    FrontendManifest (..),
    FrontendServer (..),
    OccurrenceId (..),
    OccurrenceSnapshot (..),
    PlanFold (..),
    RunId,
    RunOwnership (..),
    RunRecord (..),
    RunSnapshot (..),
    RunStatus (..),
    WorkflowDescriptor (..),
    decodeEnvelopeFor,
    decodeFrontendManifest,
    decodeWorkflowDescriptor,
    frontendCapabilities,
    initialRunSnapshot,
    mkRunId,
    stepRunSnapshot,
  )
import Agentic.Tui.Client (decodeFrontendCapabilities)
import Agentic.Tui.Highlight
import Agentic.Tui.Model
import Agentic.Tui.Person (personAnswerValue)
import Agentic.Tui.Presentation
import Agentic.Tui.Process (MachineExit (..), RunningMachine (runningDirectory), activateMachine, startMachine, terminateMachine)
import Agentic.Tui.Root (withPrivateRoot)
import Agentic.Tui.RunModel
import Agentic.Tui.Types
import Brick (attrMapLookup, attrName, renderWidget)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM (atomically, isEmptyTBQueue, newTBQueueIO)
import Control.Exception (finally)
import Control.Monad (foldM, forM_, void)
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Bits ((.&.))
import Data.List (findIndex)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as TL
import qualified Data.Vector as Vector
import qualified Graphics.Vty as Vty
import Graphics.Vty.PictureToSpans (displayOpsForPic)
import Graphics.Vty.Span (SpanOp (..))
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory, getTemporaryDirectory, removePathForcibly)
import System.Environment (getArgs, getExecutablePath, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.Timeout (timeout)
import Test.QuickCheck (Testable, isSuccess, maxSuccess, quickCheckWithResult, stdArgs)
import TuiRootRoleTests (tuiRootRoleTests)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "--activation-fixture" : _ -> do
      BS.hPut stdout "{not-json}\n"
      hFlush stdout
      threadDelay 60000000
    "--root-role-runner" : path : _ -> BS.writeFile path "unexpected runner launch" >> exitFailure
    _ -> runTests

runTests :: IO ()
runTests = do
  descriptorBytes <- BS.readFile "test/fixtures/runtime/descriptor-v3/valid.json"
  startedBytes <- firstLine <$> BS.readFile "test/fixtures/runtime/protocol-v1/success.ndjson"
  manifestBytes <- BS.readFile "test/fixtures/runtime/frontend-manifest/v2.json"
  personBytes <- BS.readFile "test/fixtures/runtime/protocol-v2/person-result.ndjson"
  descriptor <- requireRight "descriptor fixture" (decodeWorkflowDescriptor descriptorBytes)
  tuiRootRoleTests descriptor (previewFor descriptor Map.empty)
  manifest <- requireRight "frontend manifest fixture" (decodeFrontendManifest manifestBytes)
  envelope <- requireRight "protocol fixture" (decodeEnvelopeFor [1] startedBytes)
  runId <- requireRight "run id" (mkRunId "tui-model-test")
  started <- requireRight "started snapshot" (stepRunSnapshot (initialRunSnapshot runId) (rewriteRunId runId envelope))
  personEvents <- traverse (requireRight "person fixture" . decodeEnvelopeFor [2]) (filter (not . BS.null) (BS.split 10 personBytes))
  terminalSnapshot <-
    foldM
      (\snapshot event' -> requireRight "terminal catalogue snapshot" (stepRunSnapshot snapshot (rewriteRunId (frontendRunId manifest) event')))
      (initialRunSnapshot (frontendRunId manifest))
      personEvents
  routing <- requireRight "routing fixture" (decodeRoutingSummary routingFixture)
  let alternate = descriptor {workflowName = "other", workflowBlurb = "Unrelated task"}
      runRecord =
        RunRecord
          { recordDirectory = "/tmp/run-v2",
            recordManifest = manifest,
            recordOwnerLease = Nothing,
            recordOwnership = RunTerminal,
            recordPolicy = Just (object ["realizations" .= [object ["axis" .= ("deep" :: Text), "model" .= ("concrete-a" :: Text), "engine" .= ("engine-a" :: Text), "provider" .= ("fixture" :: Text)]]]),
            recordSnapshot = Just terminalSnapshot
          }
      initial = initialModel [descriptor, alternate] [CatalogueRun runRecord] (Right routing)
      filtered = setWorkflowFilter "rvw" initial
      collecting = beginWorkflow initial
      firstInput = submitInput "subject value" collecting
      allInputs = submitInput "line one\nline two" firstInput
      preview = previewFor descriptor (modelInputs allInputs)
      confirming = previewFinished (Right preview) (chooseTarget TargetScripted allInputs)
      draftSecond = storeInput "draft kept" firstInput
      backToFirst = previousStep draftSecond
      backFromTarget = previousStep allInputs
      backFromConfirmation = previousStep confirming
      launching = launchStarted runId (initialRunSnapshot runId) confirming
      live = snapshotUpdated started launching
      trustedConfig = TuiConfig "work" "/trusted/wrapper" ["--profile", "work"] "/tmp/project" "/tmp/state"
      storedServer = FrontendServer "wf" "/nix/store/actual-wf/bin/wf" (workflowRunnerVersion descriptor)
      storedInvocation = FrontendInvocation 1 "work" "/trusted/wrapper" ["--profile", "work"]
      invokedManifest = manifest
        { frontendVersion = 3,
          frontendRunnerId = frontendServerRunnerId storedServer,
          frontendRunnerExecutable = Just (frontendServerExecutable storedServer),
          frontendRunnerVersion = Just (frontendServerRunnerVersion storedServer),
          frontendInvocation = Just storedInvocation
        }
      capabilityDocument = toJSON (frontendCapabilities storedServer)
      encodedCapabilities = BL.toStrict (encode capabilityDocument <> "\n")
      rejectsCapabilities value = either (const True) (const False) (decodeFrontendCapabilities (BL.toStrict (encode value <> "\n")))
      rejectsInvocation config = either (const True) (const False) (validateStoredInvocation config invokedManifest)
  concurrent <- twoOccurrenceSnapshot
  tailed <- longOutputSnapshot
  (mixedEvents, mixedSnapshot) <- mixedDecisionSnapshot
  workflowGolden <- TIO.readFile "test/fixtures/tui/workflow-filter.golden"
  routingGolden <- TIO.readFile "test/fixtures/tui/routing-browser.golden"
  runGolden <- TIO.readFile "test/fixtures/tui/run-browser.golden"
  check "workflow browser starts selected" (selectedWorkflow initial == Just descriptor)
  check "fuzzy workflow filter is a case-folded subsequence over names and descriptions" (map workflowName (visibleWorkflows filtered) == ["review"])
  checkGolden "workflow browser golden" workflowGolden (T.unlines (browserLines filtered))
  checkGolden "routing browser golden" routingGolden (T.unlines (browserLines (cycleTab (cycleTab initial))))
  checkGolden "run browser golden" runGolden (T.unlines (browserLines (cycleTab initial)))
  check "descriptor inputs retain order" (modelScreen collecting == InputScreen 0)
  check "first input advances exactly once" (modelScreen firstInput == InputScreen 1)
  check "stdin input preserves multiline text" (Map.lookup "notes" (modelInputs allInputs) == Just "line one\nline two")
  check "moving to a previous input preserves the current draft" (modelScreen backToFirst == InputScreen 0 && Map.lookup "notes" (modelInputs backToFirst) == Just "draft kept" && inputValue backToFirst == "subject value")
  check "target back-navigation reopens the final accepted input" (modelScreen backFromTarget == InputScreen 1 && inputValue backFromTarget == "line one\nline two")
  check "confirmation refusal preserves inputs and target selection" (modelScreen backFromConfirmation == TargetScreen && modelInputs backFromConfirmation == modelInputs confirming && modelTarget backFromConfirmation == modelTarget confirming)
  check "all inputs lead to target selection" (modelScreen allInputs == TargetScreen)
  check "target selection cannot launch without preview" (modelScreen (chooseTarget TargetScripted allInputs) == PreviewLoading)
  check "successful preview requires confirmation" (modelScreen confirming == ConfirmScreen preview)
  check "routing readiness is decoded" (maybe False engineChoiceCredentialReady (listToMaybe (routingSummaryEngines routing)))
  check "routing launch uses only top-level arguments and fingerprint" $
    targetArguments (TargetRouting "work" (routingSummaryArguments routing) (routingSummaryFingerprint routing))
      == Right ["--routing", "--persona", "work", "--offline", "--expect-routing-fingerprint", T.unpack (routingSummaryFingerprint routing)]
  check "capability discovery retains server identity distinct from configured invocation" $
    decodeFrontendCapabilities encodedCapabilities == Right storedServer
      && rejectsCapabilities (case capabilityDocument of
           Object fields -> Object (KeyMap.insert "future" (Bool True) fields)
           _ -> error "native capability advertisement is not an object")
  check "configured invocation accepts only the exact trusted alias, executable, and prefix" $
    validateStoredInvocation trustedConfig invokedManifest == Right ()
      && frontendInvocationRunnerAlias storedInvocation /= frontendServerRunnerId storedServer
      && frontendInvocationExecutable storedInvocation /= T.pack (frontendServerExecutable storedServer)
      && rejectsInvocation trustedConfig {tuiRunnerAlias = "missing-alias"}
      && rejectsInvocation trustedConfig {tuiRunner = "/trusted/replaced-wrapper"}
      && rejectsInvocation trustedConfig {tuiRunnerArgs = ["work", "--profile"]}
      && validateStoredInvocation trustedConfig manifest == Right ()
  check "routing max-output and execution fingerprint are decoded"
    (case routingSummaryProfiles routing of
      profile : _ -> case routingProfileRungs profile of
        rung : _ -> routingRungMaxOutput rung == Nothing && routingRungExecutionFingerprint rung == Just "sha256:execution"
        [] -> False
      [] -> False)
  check "child launch waits outside the live monitor" (modelScreen launching == LaunchingScreen runId)
  check "first valid run.started enters the live monitor" (modelScreen live == LiveScreen runId)
  check "empty catalogues keep selection bounded" (modelWorkflowIndex (moveSelection 9 (initialModel [] [] (Left "none"))) == 0)
  let selectedBeforeOrder = reconcileRunView concurrent emptyRunView
      reordered = concurrent {snapshotTraceRecorded = True, snapshotAuthoredOrder = [OccurrenceId 1, OccurrenceId 0]}
      selectedAfterOrder = reconcileRunView reordered selectedBeforeOrder
  check "occurrence selection starts by stable identity" (runViewOccurrence selectedBeforeOrder == Just (OccurrenceId 0))
  check "authored reordering retains occurrence identity" (runViewOccurrence selectedAfterOrder == Just (OccurrenceId 0))
  let tailedLines = selectedOccurrenceLines tailed (reconcileRunView tailed emptyRunView)
  check "selected occurrence output tails a huge unterminated line" ("TAIL_SENTINEL" `T.isInfixOf` T.unlines tailedLines && not ("HEAD_SENTINEL" `T.isInfixOf` T.unlines tailedLines) && sum (map T.length tailedLines) < 40000)
  let pendingEvents = [mixedEvents !! 2, mixedEvents !! 6]
      decisions = updateMandatoryDecisions [] (reverse pendingEvents) mixedSnapshot
      personResolved = mixedSnapshot {snapshotOccurrences = Map.adjust (\occurrence -> occurrence {snapshotOccurrencePersonPending = False}) (OccurrenceId 0) (snapshotOccurrences mixedSnapshot)}
      recoveryResolved = personResolved {snapshotOccurrences = Map.adjust (\occurrence -> occurrence {snapshotOccurrenceRecovery = Nothing}) (OccurrenceId 1) (snapshotOccurrences personResolved)}
  check "mandatory person and recovery decisions follow protocol sequence across kinds"
    (map mandatoryKind decisions == [MandatoryPerson, MandatoryRecovery] && map mandatoryOccurrence decisions == [OccurrenceId 0, OccurrenceId 1] && map mandatorySequence decisions == map envelopeSequence pendingEvents)
  check "resolving the FIFO head reveals the next mandatory kind" (map mandatoryKind (updateMandatoryDecisions decisions [] personResolved) == [MandatoryRecovery])
  check "terminally resolved mandatory decisions leave no stale modal" (null (updateMandatoryDecisions decisions [] recoveryResolved))
  check "flag person answers are code-directed" (personAnswerValue "flag" "YES" == Right (Bool True))
  check "multiline text person answers remain exact" (personAnswerValue "text" "a\nb" == Right (String "a\nb"))
  check "invalid flag person answers refuse" (either (const True) (const False) (personAnswerValue "flag" "maybe"))
  check "plain renderer classifies ordinary output" (classifyLine "answer text" == PlainLine)
  check "status renderer classifies every progress channel" (all ((== StatusLine) . classifyLine) ["message: m", "tool completed t", "todo pending/high: t", "usage: 1/2", "reasoning summary: r"])
  check "diff renderer classifies headers, hunks, additions, and removals"
    (map classifyLine ["diff --git a/x b/x", "@@ -1 +1 @@", "+new", "-old"] == [DiffHeaderLine, DiffHunkLine, DiffAddedLine, DiffRemovedLine])
  check "markdown fallback styles bounded headings, quotations, and fences"
    (map classifyLine ["## Heading", "> quoted", "```haskell"] == [MarkdownHeadingLine, MarkdownQuoteLine, MarkdownFenceLine])
  checkProperty "fuzzy reflexivity" (\value -> fuzzyMatch (T.pack value) (T.pack value))
  checkProperty "fuzzy subsequence survives surrounding text" (\value -> fuzzyMatch (T.pack value) ("prefix " <> T.pack value <> " suffix"))
  checkRendering descriptor routing initial
  startupActivationProbe descriptor
  putStrLn "tui model/property/golden/render tests: all checks passed"

startupActivationProbe :: WorkflowDescriptor -> IO ()
startupActivationProbe descriptor = do
  temporary <- getTemporaryDirectory
  workingDirectory <- getCurrentDirectory
  runner <- getExecutablePath
  stamp <- getMonotonicTimeNSec
  let stateDirectory = temporary </> ("agent-cat-tui-activation-" <> show stamp)
      config = TuiConfig "work" runner ["--activation-fixture"] workingDirectory stateDirectory
      server = FrontendServer "wf" "/nix/store/actual-wf/bin/wf" (workflowRunnerVersion descriptor)
      inputs = Map.fromList [("subject", "fixture"), ("notes", "fixture")]
      preview = (previewFor descriptor inputs) {previewProgramHash = T.replicate 64 "a"}
      cleanup = removePathForcibly stateDirectory
  (withPrivateRoot stateDirectory $ \root -> do
      queue <- newTBQueueIO 16
      frame <- newEmptyMVar
      stopped <- newEmptyMVar
      launched <- startMachine server config root preview queue (void (tryPutMVar frame ())) (\outcome -> void (tryPutMVar stopped outcome))
      running <- requireRight "startup activation machine" launched
      manifestBytes <- BS.readFile (runningDirectory running </> "supervisor-manifest.json")
      manifest <- requireRight "startup capability server manifest" (decodeFrontendManifest manifestBytes)
      check "child manifest keeps capability server identity separate from alias and wrapper" $
        frontendRunnerId manifest == frontendServerRunnerId server
          && frontendRunnerExecutable manifest == Just (frontendServerExecutable server)
          && frontendRunnerVersion manifest == Just (frontendServerRunnerVersion server)
          && frontendRunnerId manifest /= tuiRunnerAlias config
          && frontendRunnerExecutable manifest /= Just (tuiRunner config)
      threadDelay 200000
      earlyFrame <- tryReadMVar frame
      earlyStop <- tryReadMVar stopped
      queueEmpty <- atomically (isEmptyTBQueue queue)
      check "machine callbacks remain gated until App adopts ownership" (earlyFrame == Nothing && earlyStop == Nothing && queueEmpty)
      activateMachine running
      outcome <- timeout 5000000 (takeMVar stopped)
      check "activation releases the immediate protocol failure" $ case outcome of
        Just (MachineProtocolFailed failure) -> "machine protocol decode failed" `T.isInfixOf` failure
        _ -> False
      terminateMachine running
    ) `finally` cleanup

checkRendering :: WorkflowDescriptor -> RoutingSummary -> TuiModel -> IO ()
checkRendering descriptor routing initial = do
  let engine = case routingSummaryEngines routing of
        value : _ -> value
        [] -> error "routing fixture has no engine"
      longEngine =
        engine
          { engineChoiceAlias = "claude-personal-界e\x0301",
            engineChoiceProvider = "fixture-provider-with-a-deliberately-long-name"
          }
      baseProfile = case routingSummaryProfiles routing of
        value : _ -> value
        [] -> error "routing fixture has no profile"
      irrelevant index =
        baseProfile
          { routingProfileName = "irrelevant-" <> T.pack (show index),
            routingProfileRungs =
              [ rung
                  { routingRungModel = "unused-model-" <> T.replicate 80 "界",
                    routingRungExecutionFingerprint = Just ("sha256:unused-" <> T.pack (show index))
                  }
                | rung <- routingProfileRungs baseProfile
              ]
          }
      overflowRouting =
        routing
          { routingSummaryEngines = [longEngine],
            routingSummaryProfiles = baseProfile : map irrelevant [1 :: Int .. 80],
            routingSummaryWarnings = ["long routing warning " <> T.replicate 100 "warning " | _ <- [1 :: Int .. 20]]
          }
      config = TuiConfig "fixture" "/runner" [] "/work" "/tmp/private-state"
      overflowConfig =
        config
          { tuiRunner = "/very/long/runner/" <> T.unpack (T.replicate 80 "segment/"),
            tuiRunnerArgs = ["--registry", T.unpack (T.replicate 200 "prefix-")],
            tuiWorkingDir = "/very/long/working/directory/" <> T.unpack (T.replicate 400 "cwd/")
          }
      exactDescriptor = descriptor {workflowDescriptorVersion = 2, workflowProtocolVersions = [1], workflowStoreVersions = [1], workflowPersonAnsweringModes = []}
      plan = ExactPlanSummary exactDescriptor (Just ["text", "receipt"]) [PlanFold (maybe 0 id (workflowMinFold descriptor)) (workflowPaths descriptor)]
      preview =
        LaunchPreview
          { previewDescriptor = descriptor,
            previewInputs = Map.fromList [("subject", "INPUT_SENTINEL_DO_NOT_RENDER")],
            previewTarget = TargetRouting "work" (routingSummaryArguments routing) (routingSummaryFingerprint routing),
            previewLineage = Nothing,
            previewRouting = Just routing,
            previewPlan = plan,
            previewProgramHash = T.replicate 64 "a"
          }
      overflowPreview = preview
        { previewTarget = TargetRouting "work" (routingSummaryArguments overflowRouting) (routingSummaryFingerprint overflowRouting),
          previewRouting = Just overflowRouting
        }
      confirmModel =
        initial
          { modelScreen = ConfirmScreen preview,
            modelWorkflow = Just descriptor,
            modelInputs = previewInputs preview,
            modelTarget = Just (previewTarget preview),
            modelStatus = "preview complete"
          }
      presentation = (staticPresentation config confirmModel) {presentationNoColor = True}
      sizes = [(140, 36), (80, 24), (40, 12), (24, 6), (1, 1)]
      frames = [(size, renderFrame size presentation) | size <- sizes]
  forM_ frames $ \((columns, rows), frame) ->
    check ("render stays within " <> show columns <> "x" <> show rows)
      (length (frameRows frame) <= rows && all ((<= columns) . renderedColumns) (frameRows frame))
  let allowedHeights = [rows | rows <- [1 .. 80], launchReviewAllowed config preview (80, rows)]
      narrowAllowedHeights = [rows | rows <- [1 .. 200], launchReviewAllowed config preview (24, rows)]
      minimumHeight = case allowedHeights of
        value : _ -> value
        [] -> error "standard launch review never fits"
      minimumFrame = renderFrame (80, minimumHeight) presentation
      frame80 = renderFrame (80, 24) presentation
      frame40 = renderFrame (40, 12) presentation
      frame24 = renderFrame (24, 6) presentation
      textMinimum = frameText minimumFrame
      text80 = frameText frame80
      text40 = frameText frame40
      text24 = frameText frame24
      requiredFacts = ["LIVE BACKEND: PROVIDER CHARGES MAY APPLY", "Workflow  review", "Persona   work", "Target    routing", "Routing   deep", "Requests  2", "Effects   effectful no", "Directory /work"]
  check "launch review has a content-derived height boundary" (minimumHeight > 1 && not (launchReviewAllowed config preview (80, minimumHeight - 1)))
  check "launch review width is derived from complete controls rather than a fixed breakpoint" (not (null narrowAllowedHeights) && not (launchReviewAllowed config preview (21, 200)))
  check "the first permitted frame contains every required fact and action" (all (`T.isInfixOf` textMinimum) (requiredFacts <> ["Enter/y LAUNCH", "n/Esc BACK"]))
  check "80x24 confirmation keeps every required fact and primary action visible" (all (`T.isInfixOf` text80) (requiredFacts <> ["Enter/y LAUNCH", "n/Esc BACK"]))
  let inventoryWarnings = ["model alias 'unused-" <> T.pack (show index) <> "' is static-unverified" | index <- [1 :: Int .. 12]]
      inventoryPreview = preview {previewRouting = Just (routing {routingSummaryWarnings = inventoryWarnings})}
      inventoryConfig = config {tuiWorkingDir = "/private/var/folders/ab/012345678901234567890123456789/T/workflow-demo/working-directory"}
      inventoryPresentation = staticPresentation inventoryConfig (confirmModel {modelScreen = ConfirmScreen inventoryPreview})
      inventoryFrame = renderFrame (80, 24) inventoryPresentation
      inventoryText = frameText inventoryFrame
      inventoryDetails = confirmationDetails inventoryConfig inventoryPreview
      warningDetails = T.unlines (takeWhile (/= "Launch") inventoryDetails)
  exportFrame "warnings" (80, 24) inventoryPresentation
  check ("persona-wide inventory warnings do not crowd a normal launch review\n" <> T.unpack inventoryText)
    (launchReviewAllowed inventoryConfig inventoryPreview (80, 24) && all (`T.isInfixOf` inventoryText) ["Warnings  12 reported; d DETAILS", "Enter/y LAUNCH", "n/Esc BACK"] && T.pack (tuiWorkingDir inventoryConfig) `T.isInfixOf` T.filter (`notElem` [' ', '\n', '│']) inventoryText)
  check "launch review summarizes warnings without repeating unrelated inventory rows"
    (not ("unused-" `T.isInfixOf` inventoryText) && "LAUNCH" `T.isInfixOf` renderedText (last (frameRows inventoryFrame)))
  check "every routing warning remains at the start of exact details"
    (all (`T.isInfixOf` warningDetails) inventoryWarnings)
  check "unsafe compact confirmation is blocked without a launch action" ("LAUNCH DISABLED" `T.isInfixOf` text40 && not ("Enter/y LAUNCH" `T.isInfixOf` text40))
  check "confirmation actions occupy the final visible row" (T.isInfixOf "LAUNCH" (renderedText (last (frameRows frame80))))
  check "status strip remains exactly one row through compact layouts" (all ((== 1) . length . filter (T.isInfixOf "preview complete") . map renderedText . frameRows) [frame80, frame40, frame24])
  let longStatusModel = confirmModel {modelStatus = "STATUS_SENTINEL\n" <> T.replicate 1000 "界e\x0301"}
      longStatusFrame = renderFrame (40, 12) ((staticPresentation config longStatusModel) {presentationNoColor = True})
  check "multiline untrusted status is normalized, cell-clipped, and confined to one row"
    (length (filter (T.isInfixOf "STATUS_SENTINEL") (map renderedText (frameRows longStatusFrame))) == 1 && all ((<= 40) . renderedColumns) (frameRows longStatusFrame))
  check "undersized confirmation disables launch and asks for resize" ("RESIZE" `T.isInfixOf` text24 && not ("Enter/y LAUNCH" `T.isInfixOf` text24))
  check "exact-plan pins select routing profiles by exact membership" (map routingProfileName (routingProfilesForPlan plan overflowRouting) == [routingProfileName baseProfile])
  check "input bodies and raw programs do not enter confirmation cells" (not ("INPUT_SENTINEL_DO_NOT_RENDER" `T.isInfixOf` text80))
  let overflowModel = confirmModel {modelScreen = ConfirmScreen overflowPreview}
      overflowPresentation = (staticPresentation overflowConfig overflowModel) {presentationNoColor = True}
      overflowSummary = frameText (renderFrame (140, 36) overflowPresentation)
      details = T.unlines (confirmationDetails overflowConfig overflowPreview)
      detailPresentation = overflowPresentation {presentationLayer = ConfirmDetailsLayer}
      detailFrames = [(size, renderFrame size detailPresentation) | size <- sizes]
  check "an incomplete proportional review is disabled even on a wide screen" ("LAUNCH DISABLED" `T.isInfixOf` overflowSummary && not ("Enter/y LAUNCH" `T.isInfixOf` overflowSummary))
  forM_ detailFrames $ \((columns, rows), frame) ->
    check ("exact-detail render stays within " <> show columns <> "x" <> show rows)
      (length (frameRows frame) <= rows && all ((<= columns) . renderedColumns) (frameRows frame))
  check "80x24 exact details retain their title and navigation actions" (all (`T.isInfixOf` frameText (renderFrame (80, 24) detailPresentation)) ["Launch details", "n/Esc BACK", "d SUMMARY"])
  check "exact details retain direct argv, exact folds, and fingerprints"
    (all (`T.isInfixOf` details) ["Runner executable", "[0] \"--registry\"", "Exact target arguments", "fold histogram", "routing launch fingerprint", "sha256:execution", "irrelevant-80", "full sanitized inspection JSON"])
  check "exact details omit input bodies and raw programs" (not ("INPUT_SENTINEL_DO_NOT_RENDER" `T.isInfixOf` details))
  let many = [descriptor {workflowName = "workflow-" <> T.pack (show index)} | index <- [0 :: Int .. 99]]
      selectedModel = initial {modelWorkflows = many, modelWorkflowIndex = 95, modelScreen = BrowserScreen}
      selectedPresentation = (staticPresentation config selectedModel) {presentationNoColor = True, presentationPaneFocus = PrimaryPane}
      selectedFrame = renderFrame (40, 12) selectedPresentation
      unicodeModel = initial {modelWorkflows = [descriptor {workflowName = "界e\x0301🙂-workflow"}], modelScreen = BrowserScreen}
      unicodeFrame = renderFrame (40, 12) ((staticPresentation config unicodeModel) {presentationNoColor = True})
      unsafeHelpFrame = renderFrame (80, 24) ((staticPresentation config (initial {modelScreen = HelpScreen "\ESC[31munsafe\rtext"})) {presentationNoColor = True})
      longFailureFrame = renderFrame (24, 6) ((staticPresentation config (initial {modelScreen = FailureScreen ("failure-" <> T.replicate 2000 "界")})) {presentationNoColor = True})
      noColorMap = presentationAttributes True
      selectedAttribute = attrMapLookup (attrName "selected") noColorMap
      expectedSelection = Vty.withStyle (Vty.withStyle Vty.defAttr Vty.reverseVideo) Vty.bold
  check "off-screen selection is made visible without wrapping rows" ("workflow-95" `T.isInfixOf` frameText selectedFrame)
  check "monochrome rendering retains textual focus and selection" (all (`T.isInfixOf` frameText selectedFrame) ["> workflow-95", "Workflows •"])
  check "NO_COLOR selection uses terminal defaults plus reverse and bold" (selectedAttribute == expectedSelection)
  check "rendered untrusted text replaces terminal controls" ("�[31munsafe�text" `T.isInfixOf` frameText unsafeHelpFrame && not (T.any (`elem` ['\ESC', '\r']) (frameText unsafeHelpFrame)))
  check "long unbroken wide-character errors remain within real cells" (all ((<= 24) . renderedColumns) (frameRows longFailureFrame))
  check "narrow Unicode layout retains header context and adjacent footer cells" (all (`T.isInfixOf` frameText unicodeFrame) ["[Workflows]", "界", "workflow", "Tab SECTION"] && all ((<= 40) . renderedColumns) (frameRows unicodeFrame))
  let resizeSizes = [(140, 36), (40, 12), (80, 24), (24, 6), (140, 36)]
      resizeFrames = map (`renderFrame` presentation) resizeSizes
  forM_ (zip resizeSizes resizeFrames) $ \((columns, rows), frame) ->
    check "every rapid-resize frame is evaluated, bounded, and retains review status"
      (length (frameRows frame) <= rows && all ((<= columns) . renderedColumns) (frameRows frame) && "preview complete" `T.isInfixOf` frameText frame)
  check "returning to the original size restores the rendered review" $ case resizeFrames of
    [first, _, _, _, final] -> frameText first == frameText final
    _ -> False
  forM_ [WorkflowsTab, RunsTab, RoutingTab] $ \tab -> do
    let statusModel = initial {modelScreen = BrowserScreen, modelTab = tab, modelStatus = "STATUS_SENTINEL"}
        statusFrame = renderFrame (80, 24) (staticPresentation config statusModel)
    check "browser context retains operation status" ("STATUS_SENTINEL" `T.isInfixOf` frameText statusFrame)
  let refreshFailure = "ERROR: run catalogue refresh failed: unreadable state"
      staleRuns = initial {modelScreen = BrowserScreen, modelTab = RunsTab, modelStatus = refreshFailure}
      staleFrame = renderFrame (80, 24) (staticPresentation config staleRuns)
  check "run browser displays a failed refresh instead of only stale counts" (refreshFailure `T.isInfixOf` frameText staleFrame)
  failedId <- requireRight "failed run id" (mkRunId "failed-before-first-request")
  let failure = "Configured model is unavailable. Select an offered model.\n" <> T.replicate 80 "diagnostic detail\n" <> "LAST_DIAGNOSTIC"
      failed = (initialRunSnapshot failedId) {snapshotWorkflow = Just "hello-world", snapshotRunStatus = RunFailedStatus, snapshotRunFailure = Just failure}
      failedModel = initial {modelScreen = LiveScreen failedId, modelSnapshot = Just failed}
      failedPresentation = (staticPresentation config failedModel) {presentationNoColor = True}
  forM_ [(80, 24), (40, 12), (140, 36)] $ \size -> do
    let text = frameText (renderFrame size failedPresentation)
    check "failure before the first request displays its reason without navigation"
      ("Configured model is unavailable" `T.isInfixOf` text && "d DETAILS" `T.isInfixOf` text && not ("RunFailedStatus" `T.isInfixOf` text) && not ("No occurrence selected" `T.isInfixOf` text))
  check "run diagnostics retain the complete recorded failure" (failure `T.isInfixOf` T.unlines (snapshotLines failed))
  case modelRuns initial of
    CatalogueRun record : _ -> do
      let manifest = recordManifest record
          restored = failed {snapshotRunId = frontendRunId manifest, snapshotWorkflow = Just (frontendWorkflow manifest)}
          browser = initial {modelTab = RunsTab, modelRuns = [CatalogueRun (record {recordSnapshot = Just restored})]}
          text = frameText (renderFrame (80, 24) (staticPresentation config browser))
      check "stored-run details begin with the recorded failure" ("Configured model is unavailable" `T.isInfixOf` text && not ("RunFailedStatus" `T.isInfixOf` text))
    _ -> error "missing catalogue fixture"
  let inputFrame = renderFrame (80, 24) (staticPresentation config (initial {modelScreen = InputScreen 0, modelWorkflow = Just descriptor}))
  check "a one-line input does not fill the screen with an empty box"
    (length (filter (T.isInfixOf "│" . renderedText) (frameRows inputFrame)) <= 6)
  forM_ [record | CatalogueRun record <- modelRuns initial] $ \record ->
    forM_ [RestartRun, ResumeRun, ForkRun] $ \operation ->
      forM_ ["acp", "deck", "routing", "scripted"] $ \kind -> do
        let parent = record {recordManifest = (recordManifest record) {frontendTargetKind = kind}}
            restored = preview {previewTarget = TargetRestored kind [], previewLineage = Just (operation, parent)}
            text = frameText (renderFrame (100, 36) (staticPresentation config (confirmModel {modelScreen = ConfirmScreen restored})))
        check "restored targets preserve their billing classification"
          (if kind == "scripted" then "Review scripted run" `T.isInfixOf` text else "Review live run" `T.isInfixOf` text && not ("no external backend" `T.isInfixOf` text))
  stream <- longOutputSnapshot
  let readable = stream {snapshotWorkflow = Just "review-quick", snapshotOccurrences = Map.map (\occurrence -> occurrence {snapshotOccurrenceAddressee = "model code-reviewer", snapshotOccurrenceAttempts = Map.map (\attempt -> attempt {snapshotAttemptOutput = "## Review findings\n\nThe retry loop discards the last error.\nPreserve that diagnostic before returning.\n\n```sh\n# keep literal\nretry remaining action\n```\n\n+ retain the failure\n- return an empty result"}) (snapshotOccurrenceAttempts occurrence)}) (snapshotOccurrences stream)}
      liveModel = initial {modelScreen = LiveScreen (snapshotRunId readable), modelSnapshot = Just readable}
      livePresentation = (staticPresentation config liveModel) {presentationRunView = reconcileRunView readable emptyRunView, presentationPaneFocus = SecondaryPane, presentationRunning = True, presentationElapsed = "0m12s"}
      message = "Authentication failed: OAuth session expired and could not be refreshed (JSON-RPC -32603)"
      recovery = RecoverySnapshot "transport-refusal" message [] [RecoveryOption "retry" Nothing, RecoveryOption "abandon" Nothing] Nothing
      recovering = case Map.lookup (OccurrenceId 0) (snapshotOccurrences readable) of
        Just value -> value {snapshotOccurrenceState = OccurrenceRecoveringState, snapshotOccurrenceRecovery = Just recovery}
        Nothing -> error "missing recovery fixture request"
      recoveryPresentation = livePresentation {presentationLayer = RecoveryLayer, presentationRecovery = Just (recovering, recovery), presentationModel = liveModel {modelSnapshot = Just (readable {snapshotOccurrences = Map.insert (OccurrenceId 0) recovering (snapshotOccurrences readable)})}}
      locked = engine {engineChoiceAlias = "locked-engine-with-a-long-name", engineChoiceCredentialReady = False}
      targetPresentation = staticPresentation config (initial {modelScreen = TargetScreen, modelRouting = Right (routing {routingSummaryEngines = [locked]})})
  forM_ [(40, 12), (80, 24), (140, 36)] $ \size@(columns, rows) -> do
    let browserFrame = renderFrame size (staticPresentation config initial)
        liveFrame = renderFrame size livePresentation
        recoveryFrame = renderFrame size recoveryPresentation
        targetFrame = renderFrame size targetPresentation
        footer = T.unlines (map renderedText (drop (rows - 2) (frameRows browserFrame)))
        workflowRows = map (T.strip . T.takeWhile (/= '│') . renderedText) (frameRows browserFrame)
        overview = frameText (renderFrame size ((staticPresentation config initial) {presentationPaneFocus = SecondaryPane}))
    check "workflow list uses consecutive name-only rows"
      (take 2 (dropWhile (/= "> review") workflowRows) == ["> review", "other"]
        && all (\workflow -> not (workflowBlurb workflow `T.isInfixOf` T.unlines workflowRows)) (visibleWorkflows initial))
    check "selected workflow summary remains in details" (workflowBlurb descriptor `T.isInfixOf` overview)
    check "compact browser keeps details and help reachable" (all (`T.isInfixOf` footer) ["Right DETAILS", "? KEYS"])
    check "reading view shows output without protocol preamble"
      ("Review findings" `T.isInfixOf` frameText liveFrame && not ("prompt " `T.isInfixOf` frameText liveFrame) && not ("attempt 0.0" `T.isInfixOf` frameText liveFrame))
    check "recovery keeps primary actions visible without protocol labels"
      (all (`T.isInfixOf` frameText recoveryFrame) ["Recovery required", "r RETRY", "a ABANDON"] && not ("transport-refusal" `T.isInfixOf` frameText recoveryFrame))
    check "routing engine readiness is visible on narrow terminals" ("NOT READY" `T.isInfixOf` frameText targetFrame)
    check "output projection preserves paragraph breaks" (take 2 (selectedOutputLines readable (presentationRunView livePresentation)) == ["## Review findings", ""])
    if columns < 72 then pure () else do
      check "fenced code preserves literal comment markers" ("# keep literal" `T.isInfixOf` frameText liveFrame)
      check "live output receives at least three quarters minus pane chrome"
        (any (\row -> findIndex (== '│') (T.unpack (renderedText row)) == Just (min 32 (columns `div` 4))) (frameRows liveFrame))
    forM_ [("browser", staticPresentation config initial), ("review", presentation), ("live", livePresentation), ("recovery", recoveryPresentation), ("target", targetPresentation)] $ \(label, sample) -> do
      let frame = renderFrame size sample
      check (label <> " uses bounded visible cells") (length (frameRows frame) == rows && all ((<= columns) . renderedColumns) (frameRows frame))
      exportFrame label size sample

-- Export the production renderer's spans, including attributes, for visual review.
exportFrame :: String -> (Int, Int) -> Presentation -> IO ()
exportFrame label size@(columns, rows) presentation = do
  destination <- lookupEnv "TUI_RENDER_DIR"
  forM_ destination $ \directory -> do
    createDirectoryIfMissing True directory
    let picture = renderWidget (Just (presentationAttributes (presentationNoColor presentation))) (drawPresentation presentation) size
        lines' = [T.concat (map spanHtml (Vector.toList spans)) | spans <- Vector.toList (displayOpsForPic picture size)]
        title = T.pack (label <> "-" <> show columns <> "x" <> show rows)
    TIO.writeFile (directory </> T.unpack title <> ".html")
      ("<!doctype html><meta charset=\"utf-8\"><title>" <> title <> "</title><style>body{background:#161b22;color:#e6edf3;padding:20px}pre{font:14px/1.4 Menlo,monospace;white-space:pre}</style><pre>" <> T.intercalate "\n" lines' <> "</pre>")
  where
    escape = T.replace "\"" "&quot;" . T.replace ">" "&gt;" . T.replace "<" "&lt;" . T.replace "&" "&amp;"
    spanHtml (TextSpan attribute _ _ text) =
      let styles = case Vty.attrStyle attribute of Vty.SetTo value -> value; _ -> 0
          has style = styles .&. style /= 0
          fore = color "#e6edf3" (Vty.attrForeColor attribute)
          back = color "#161b22" (Vty.attrBackColor attribute)
          (fg', bg') = if has Vty.reverseVideo then (back, fore) else (fore, back)
          css = "color:" <> fg' <> ";background:" <> bg' <> (if has Vty.bold then ";font-weight:bold" else "") <> (if has Vty.dim then ";opacity:.65" else "")
       in "<span style=\"" <> css <> "\">" <> escape (TL.toStrict text) <> "</span>"
    spanHtml (Skip count) = T.replicate count " "
    spanHtml (RowEnd count) = T.replicate count " "
    color _ (Vty.SetTo (Vty.ISOColor index)) =
      ["#161b22", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#e6edf3"] !! (fromIntegral index `mod` 8)
    color _ (Vty.SetTo (Vty.RGBColor r g b)) = "rgb(" <> T.intercalate "," (map (T.pack . show) [r,g,b]) <> ")"
    color fallback _ = fallback

data RenderedRow = RenderedRow
  { renderedText :: !Text,
    renderedColumns :: !Int
  }

data RenderFrame = RenderFrame
  { frameRows :: ![RenderedRow]
  }

frameText :: RenderFrame -> Text
frameText = T.unlines . map renderedText . frameRows

renderFrame :: (Int, Int) -> Presentation -> RenderFrame
renderFrame size presentation =
  RenderFrame
    { frameRows =
        [ RenderedRow
            { renderedText = T.concat (map spanText (Vector.toList spans)),
              renderedColumns = sum (map spanColumns (Vector.toList spans))
            }
          | spans <- Vector.toList (displayOpsForPic picture size)
        ]
    }
  where
    picture = renderWidget (Just (presentationAttributes (presentationNoColor presentation))) (drawPresentation presentation) size
    spanText (TextSpan _ _ _ value) = TL.toStrict value
    spanText (Skip columns) = T.replicate columns " "
    spanText (RowEnd columns) = T.replicate columns " "
    spanColumns (TextSpan _ columns _ _) = columns
    spanColumns (Skip columns) = columns
    spanColumns (RowEnd columns) = columns

routingFixture :: BS.ByteString
routingFixture =
  "{\"version\":2,\"persona\":{\"name\":\"work\",\"source\":\"command-line\"},\"launch\":{\"targetKind\":\"routing\",\"arguments\":[\"--routing\"],\"fingerprint\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"},\"availablePersonas\":[\"work\"],\"engines\":[{\"name\":\"engine-a\",\"backend\":\"deck:pane\",\"provider\":\"fixture\",\"credentialReady\":true,\"launch\":{\"targetKind\":\"deck\",\"arguments\":[\"--session\",\"pane\"],\"fingerprint\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"}}],\"profiles\":[{\"name\":\"deep\",\"rungs\":[{\"axis\":\"deep\",\"rung\":0,\"modelAlias\":\"model-a\",\"model\":\"concrete-a\",\"router\":\"engine-a\",\"backend\":\"deck:pane\",\"provider\":\"fixture\",\"thinking\":\"high\",\"maxOutput\":null,\"executionFingerprint\":\"sha256:execution\",\"inventory\":{\"source\":\"offline-cache\",\"fingerprint\":\"sha256:inventory\",\"fetchedAt\":\"2026-09-04T00:00:00Z\"}}]}],\"warnings\":[]}"

checkProperty :: Testable property => String -> property -> IO ()
checkProperty label property = do
  result <- quickCheckWithResult stdArgs {maxSuccess = 200} property
  check label (isSuccess result)


twoOccurrenceSnapshot :: IO RunSnapshot
twoOccurrenceSnapshot = do
  let frames =
        [ "{\"protocolVersion\":1,\"runId\":\"run-two\",\"sequence\":\"0\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"run.started\",\"workflow\":\"w\",\"target\":\"scripted\"}}",
          "{\"protocolVersion\":1,\"runId\":\"run-two\",\"sequence\":\"1\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"occurrence.started\",\"occurrenceId\":\"0\",\"code\":\"text\",\"intent\":\"consult\",\"addressee\":\"model first\",\"prompt\":\"first\"}}",
          "{\"protocolVersion\":1,\"runId\":\"run-two\",\"sequence\":\"2\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"occurrence.started\",\"occurrenceId\":\"1\",\"code\":\"text\",\"intent\":\"consult\",\"addressee\":\"model second\",\"prompt\":\"second\"}}"
        ]
  runId <- requireRight "two-occurrence run id" (mkRunId "run-two")
  envelopes <- traverse (requireRight "two-occurrence event" . decodeEnvelopeFor [1]) frames
  foldM (\snapshot envelope -> requireRight "two-occurrence snapshot" (stepRunSnapshot snapshot envelope)) (initialRunSnapshot runId) envelopes

longOutputSnapshot :: IO RunSnapshot
longOutputSnapshot = do
  runId <- requireRight "long-output run id" (mkRunId "run-long-output")
  let event :: Int -> Value -> BS.ByteString
      event sequenceNumber body =
        BL.toStrict . encode $
          object
            [ "protocolVersion" .= (1 :: Int),
              "runId" .= ("run-long-output" :: Text),
              "sequence" .= T.pack (show sequenceNumber),
              "timestamp" .= ("2026-09-04T00:00:00Z" :: Text),
              "event" .= body
            ]
      frames =
        [ event 0 (object ["type" .= ("run.started" :: Text), "workflow" .= ("w" :: Text), "target" .= ("scripted" :: Text)]),
          event 1 (object ["type" .= ("occurrence.started" :: Text), "occurrenceId" .= ("0" :: Text), "code" .= ("text" :: Text), "intent" .= ("consult" :: Text), "addressee" .= ("model" :: Text), "prompt" .= ("prompt" :: Text)]),
          event 2 (object ["type" .= ("attempt.started" :: Text), "occurrenceId" .= ("0" :: Text), "attempt" .= ("0" :: Text), "target" .= ("model" :: Text)]),
          event 3 (object ["type" .= ("attempt.output" :: Text), "occurrenceId" .= ("0" :: Text), "attempt" .= ("0" :: Text), "stream" .= ("transport-text" :: Text), "chunk" .= ("HEAD_SENTINEL" <> T.replicate 50000 "x" <> "TAIL_SENTINEL")])
        ]
  envelopes <- traverse (requireRight "long-output event" . decodeEnvelopeFor [1]) frames
  foldM (\snapshot envelope -> requireRight "long-output snapshot" (stepRunSnapshot snapshot envelope)) (initialRunSnapshot runId) envelopes

mixedDecisionSnapshot :: IO ([Envelope], RunSnapshot)
mixedDecisionSnapshot = do
  let frames =
        [ "{\"protocolVersion\":2,\"runId\":\"run-mixed\",\"sequence\":\"0\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"run.started\",\"workflow\":\"w\",\"target\":\"scripted\",\"personAnswering\":\"local-control\"}}",
          "{\"protocolVersion\":2,\"runId\":\"run-mixed\",\"sequence\":\"1\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"occurrence.started\",\"occurrenceId\":\"0\",\"code\":\"flag\",\"intent\":\"consult\",\"addressee\":\"person owner\",\"prompt\":\"approve?\"}}",
          "{\"protocolVersion\":2,\"runId\":\"run-mixed\",\"sequence\":\"2\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"occurrence.person-answer-pending\",\"occurrenceId\":\"0\",\"question\":{\"artifactVersion\":1,\"path\":\"person/questions/0.json\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"bytes\":\"100\"}}}",
          "{\"protocolVersion\":2,\"runId\":\"run-mixed\",\"sequence\":\"3\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"occurrence.started\",\"occurrenceId\":\"1\",\"code\":\"text\",\"intent\":\"consult\",\"addressee\":\"model worker\",\"prompt\":\"work\"}}",
          "{\"protocolVersion\":2,\"runId\":\"run-mixed\",\"sequence\":\"4\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"attempt.started\",\"occurrenceId\":\"1\",\"attempt\":\"0\",\"target\":\"primary\"}}",
          "{\"protocolVersion\":2,\"runId\":\"run-mixed\",\"sequence\":\"5\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"attempt.failed\",\"occurrenceId\":\"1\",\"attempt\":\"0\",\"failure\":\"transport\",\"message\":\"gap\"}}",
          "{\"protocolVersion\":2,\"runId\":\"run-mixed\",\"sequence\":\"6\",\"timestamp\":\"2026-09-04T00:00:00Z\",\"event\":{\"type\":\"occurrence.recovery-pending\",\"occurrenceId\":\"1\",\"gap\":\"transport\",\"message\":\"gap\",\"choices\":[{\"choice\":\"retry\"}]}}"
        ]
  runId <- requireRight "mixed-decision run id" (mkRunId "run-mixed")
  envelopes <- traverse (requireRight "mixed-decision event" . decodeEnvelopeFor [2]) frames
  snapshot <- foldM (\current envelope -> requireRight "mixed-decision snapshot" (stepRunSnapshot current envelope)) (initialRunSnapshot runId) envelopes
  pure (envelopes, snapshot)

previewFor :: WorkflowDescriptor -> Map.Map Text Text -> LaunchPreview
previewFor descriptor inputs =
  LaunchPreview descriptor inputs TargetScripted Nothing Nothing plan "0123456789abcdef"
  where
    exact = descriptor {workflowDescriptorVersion = 2, workflowProtocolVersions = [1], workflowStoreVersions = [1], workflowPersonAnsweringModes = []}
    plan = ExactPlanSummary exact Nothing []

rewriteRunId :: RunId -> Envelope -> Envelope
rewriteRunId runId envelope = envelope {envelopeRunId = runId}

firstLine :: BS.ByteString -> BS.ByteString
firstLine = fst . BS.break (== 10)

requireRight :: Show e => String -> Either e a -> IO a
requireRight label = either (\failure -> putStrLn (label <> ": " <> show failure) >> exitFailure) pure

checkGolden :: String -> Text -> Text -> IO ()
checkGolden label expected actual = do
  if expected == actual
    then pure ()
    else do
      putStrLn ("FAIL: " <> label <> "\n--- expected\n" <> T.unpack expected <> "--- actual\n" <> T.unpack actual)
      exitFailure

check :: String -> Bool -> IO ()
check label condition =
  if condition
    then pure ()
    else putStrLn ("FAIL: " <> label) >> exitFailure
