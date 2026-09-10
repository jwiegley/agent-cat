{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Runtime
  ( CatalogueEntry (..),
    Envelope (..),
    FrontendManifest (..),
    OccurrenceId (..),
    RunId,
    RunOwnership (..),
    RunRecord (..),
    RunSnapshot (..),
    WorkflowDescriptor (..),
    decodeEnvelopeFor,
    decodeFrontendManifest,
    decodeWorkflowDescriptor,
    initialRunSnapshot,
    mkRunId,
    stepRunSnapshot,
  )
import Agentic.Tui.Highlight
import Agentic.Tui.Model
import Agentic.Tui.Person (personAnswerValue)
import Agentic.Tui.RunModel
import Agentic.Tui.Types
import Control.Monad (foldM)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Test.QuickCheck (Testable, isSuccess, maxSuccess, quickCheckWithResult, stdArgs)
import System.Exit (exitFailure)

main :: IO ()
main = do
  descriptorBytes <- BS.readFile "test/fixtures/runtime/descriptor-v3/valid.json"
  startedBytes <- firstLine <$> BS.readFile "test/fixtures/runtime/protocol-v1/success.ndjson"
  manifestBytes <- BS.readFile "test/fixtures/runtime/frontend-manifest/v2.json"
  personBytes <- BS.readFile "test/fixtures/runtime/protocol-v2/person-result.ndjson"
  descriptor <- requireRight "descriptor fixture" (decodeWorkflowDescriptor descriptorBytes)
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
      launching = launchStarted runId (initialRunSnapshot runId) confirming
      live = snapshotUpdated started launching
  concurrent <- twoOccurrenceSnapshot
  workflowGolden <- TIO.readFile "test/fixtures/tui/workflow-filter.golden"
  routingGolden <- TIO.readFile "test/fixtures/tui/routing-browser.golden"
  runGolden <- TIO.readFile "test/fixtures/tui/run-browser.golden"
  check "workflow browser starts selected" (selectedWorkflow initial == Just descriptor)
  check "fuzzy workflow filter is a case-folded subsequence over names and descriptions" (map workflowName (visibleWorkflows filtered) == ["review"])
  check "workflow browser golden" (T.unlines (browserLines filtered) == workflowGolden)
  check "routing browser golden" (T.unlines (browserLines (cycleTab (cycleTab initial))) == routingGolden)
  check "run browser golden" (T.unlines (browserLines (cycleTab initial)) == runGolden)
  check "descriptor inputs retain order" (modelScreen collecting == InputScreen 0)
  check "first input advances exactly once" (modelScreen firstInput == InputScreen 1)
  check "stdin input preserves multiline text" (Map.lookup "notes" (modelInputs allInputs) == Just "line one\nline two")
  check "all inputs lead to target selection" (modelScreen allInputs == TargetScreen)
  check "target selection cannot launch without preview" (modelScreen (chooseTarget TargetScripted allInputs) == PreviewLoading)
  check "successful preview requires confirmation" (modelScreen confirming == ConfirmScreen preview)
  check "child launch waits outside the live monitor" (modelScreen launching == LaunchingScreen runId)
  check "first valid run.started enters the live monitor" (modelScreen live == LiveScreen runId)
  check "empty catalogues keep selection bounded" (modelWorkflowIndex (moveSelection 9 (initialModel [] [] (Left "none"))) == 0)
  let selectedBeforeOrder = reconcileRunView concurrent emptyRunView
      reordered = concurrent {snapshotTraceRecorded = True, snapshotAuthoredOrder = [OccurrenceId 1, OccurrenceId 0]}
      selectedAfterOrder = reconcileRunView reordered selectedBeforeOrder
  check "occurrence selection starts by stable identity" (runViewOccurrence selectedBeforeOrder == Just (OccurrenceId 0))
  check "authored reordering retains occurrence identity" (runViewOccurrence selectedAfterOrder == Just (OccurrenceId 0))
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
  putStrLn "tui model/property/golden tests: all checks passed"

routingFixture :: BS.ByteString
routingFixture =
  "{\"version\":2,\"persona\":{\"name\":\"work\",\"source\":\"command-line\"},\"launch\":{\"targetKind\":\"routing\",\"arguments\":[\"--routing\"],\"fingerprint\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"},\"availablePersonas\":[\"work\"],\"engines\":[{\"name\":\"engine-a\",\"backend\":\"deck:pane\",\"provider\":\"fixture\",\"launch\":{\"targetKind\":\"deck\",\"arguments\":[\"--session\",\"pane\"],\"fingerprint\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"}}],\"profiles\":[{\"name\":\"deep\",\"rungs\":[{\"axis\":\"deep\",\"rung\":0,\"modelAlias\":\"model-a\",\"model\":\"concrete-a\",\"router\":\"engine-a\",\"backend\":\"deck:pane\",\"provider\":\"fixture\",\"thinking\":\"high\",\"inventory\":{\"source\":\"offline-cache\",\"fingerprint\":\"sha256:inventory\",\"fetchedAt\":\"2026-09-04T00:00:00Z\"}}]}],\"warnings\":[]}"

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

previewFor :: WorkflowDescriptor -> Map.Map Text Text -> LaunchPreview
previewFor descriptor inputs =
  LaunchPreview descriptor inputs TargetScripted Nothing Nothing Null "0123456789abcdef"

rewriteRunId :: RunId -> Envelope -> Envelope
rewriteRunId runId envelope = envelope {envelopeRunId = runId}

firstLine :: BS.ByteString -> BS.ByteString
firstLine = fst . BS.break (== 10)

requireRight :: Show e => String -> Either e a -> IO a
requireRight label = either (\failure -> putStrLn (label <> ": " <> show failure) >> exitFailure) pure

check :: String -> Bool -> IO ()
check label condition =
  if condition
    then pure ()
    else putStrLn ("FAIL: " <> label) >> exitFailure
