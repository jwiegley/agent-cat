{-# LANGUAGE OverloadedStrings #-}

-- | Identity-stable, bounded projection of a runtime snapshot.
module Agentic.Tui.RunModel
  ( RunView (..),
    MandatoryDecisionKind (..),
    MandatoryDecision (..),
    updateMandatoryDecisions,
    emptyRunView,
    reconcileRunView,
    moveOccurrenceSelection,
    selectedOccurrence,
    occurrenceRows,
    occurrenceRowsWithSelection,
    selectedOccurrenceLines,
    selectedOutputLines,
    pendingPersonOccurrences,
    activeAttemptForSelection,
    runStatusLabel,
    occurrenceStateLabel,
    runFailureLines,
  )
where

import Agentic.Runtime
  ( AttemptId (..),
    AttemptSnapshot (..),
    AttemptState (..),
    ControlAckSnapshot (..),
    DispatchSnapshot (..),
    Envelope (..),
    OccurrenceId (..),
    OccurrenceState (..),
    OccurrenceSnapshot (..),
    PublicTodoItem (..),
    PublicToolUpdate (..),
    PublicUsage (..),
    RecoveryChosen (..),
    RecoveryOption (..),
    RecoverySnapshot (..),
    RunId,
    RunSnapshot (..),
    RunStatus (..),
    RuntimeEvent (..),
    SeqNo,
    SteerSnapshot (..),
  )
import Control.Applicative ((<|>))
import Data.List (findIndex, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | Selection is attached to an occurrence identity, never its display index.
data RunView = RunView
  { runViewOccurrence :: !(Maybe OccurrenceId)
  }
  deriving (Eq, Show)

-- | The protocol operation required at one position in the mandatory FIFO.
data MandatoryDecisionKind = MandatoryPerson | MandatoryRecovery
  deriving (Eq, Show)

-- | One mandatory decision identified by its run, protocol sequence, and occurrence.
data MandatoryDecision = MandatoryDecision
  { mandatoryRunId :: !RunId,
    mandatorySequence :: !SeqNo,
    mandatoryOccurrence :: !OccurrenceId,
    mandatoryKind :: !MandatoryDecisionKind
  }
  deriving (Eq, Show)

updateMandatoryDecisions :: [MandatoryDecision] -> [Envelope] -> RunSnapshot -> [MandatoryDecision]
updateMandatoryDecisions queued envelopes snapshot = filter (stillPending snapshot) (foldl' step queued (sortOn envelopeSequence envelopes))
  where
    step current envelope = add envelope (removeResolved envelope current)
    add envelope current = case envelopeEvent envelope of
      OccurrencePersonAnswerPending occurrence _ -> append MandatoryPerson occurrence envelope current
      OccurrenceRecoveryPending occurrence _ _ _ -> append MandatoryRecovery occurrence envelope current
      _ -> current
    append kind occurrence envelope current
      | any (sameDecision kind occurrence (envelopeRunId envelope)) current = current
      | otherwise = current <> [MandatoryDecision (envelopeRunId envelope) (envelopeSequence envelope) occurrence kind]
    sameDecision kind occurrence runId decision = mandatoryKind decision == kind && mandatoryOccurrence decision == occurrence && mandatoryRunId decision == runId

removeResolved :: Envelope -> [MandatoryDecision] -> [MandatoryDecision]
removeResolved envelope = case envelopeEvent envelope of
  OccurrenceRetried occurrence _ -> without MandatoryRecovery occurrence
  OccurrenceRecoveryChosen occurrence _ _ _ -> without MandatoryRecovery occurrence
  OccurrenceCompleted occurrence _ _ -> withoutOccurrence occurrence
  OccurrenceFailed occurrence _ _ -> withoutOccurrence occurrence
  RunFailed {} -> const []
  RunCancelled {} -> const []
  RunCompleted {} -> const []
  RunCompletedV2 {} -> const []
  _ -> id
  where
    without kind occurrence = filter (\decision -> mandatoryKind decision /= kind || mandatoryOccurrence decision /= occurrence)
    withoutOccurrence occurrence = filter ((/= occurrence) . mandatoryOccurrence)

stillPending :: RunSnapshot -> MandatoryDecision -> Bool
stillPending snapshot decision
  | mandatoryRunId decision /= snapshotRunId snapshot = False
  | otherwise = case Map.lookup (mandatoryOccurrence decision) (snapshotOccurrences snapshot) of
      Nothing -> False
      Just occurrence -> case mandatoryKind decision of
        MandatoryPerson -> snapshotOccurrencePersonPending occurrence
        MandatoryRecovery -> maybe False (const True) (snapshotOccurrenceRecovery occurrence)

emptyRunView :: RunView
emptyRunView = RunView Nothing

reconcileRunView :: RunSnapshot -> RunView -> RunView
reconcileRunView snapshot view =
  let order = occurrenceOrder snapshot
      retained = runViewOccurrence view >>= \selected -> if selected `elem` order then Just selected else Nothing
      preferred = retained <|> firstActive order <|> firstOf order
   in RunView preferred
  where
    firstActive order =
      firstOf
        [ occurrenceId
          | occurrenceId <- order,
            Just occurrence <- [Map.lookup occurrenceId (snapshotOccurrences snapshot)],
            snapshotOccurrenceState occurrence `elem` [OccurrenceRunningState, OccurrenceRecoveringState]
        ]

moveOccurrenceSelection :: Int -> RunSnapshot -> RunView -> RunView
moveOccurrenceSelection delta snapshot view =
  let order = occurrenceOrder snapshot
      current = fromMaybe 0 (runViewOccurrence view >>= \selected -> findIndex (== selected) order)
      next
        | null order = Nothing
        | otherwise = Just (order !! max 0 (min (length order - 1) (current + delta)))
   in RunView next

selectedOccurrence :: RunSnapshot -> RunView -> Maybe OccurrenceSnapshot
selectedOccurrence snapshot view = runViewOccurrence view >>= (`Map.lookup` snapshotOccurrences snapshot)

occurrenceRows :: RunSnapshot -> RunView -> [Text]
occurrenceRows snapshot = map snd . occurrenceRowsWithSelection snapshot

occurrenceRowsWithSelection :: RunSnapshot -> RunView -> [(Bool, Text)]
occurrenceRowsWithSelection snapshot view =
  [ (selected, marker selected <> T.pack (show (occurrenceNumber occurrenceId + 1)) <> "  " <> occurrenceStateLabel (snapshotOccurrenceState occurrence) <> "\n  " <> snapshotOccurrenceAddressee occurrence)
    | occurrenceId <- occurrenceOrder snapshot,
      Just occurrence <- [Map.lookup occurrenceId (snapshotOccurrences snapshot)],
      let selected = Just occurrenceId == runViewOccurrence view
  ]
  where
    marker True = "> "
    marker False = "  "

selectedOccurrenceLines :: RunSnapshot -> RunView -> [Text]
selectedOccurrenceLines snapshot view = concatMap (T.splitOn "\n") (selectedOccurrenceBlocks snapshot view)

-- | Reading view of the selected answer or latest attempt. The full protocol
-- diagnostics remain in 'selectedOccurrenceLines'.
selectedOutputLines :: RunSnapshot -> RunView -> [Text]
selectedOutputLines snapshot view = concatMap (T.splitOn "\n") $ case selectedOccurrence snapshot view of
  Nothing -> ["Waiting for the first request…"]
  Just occurrence -> case snapshotOccurrenceAnswer occurrence of
    Just answer -> [answer]
    Nothing -> case reverse (sortOn (attemptNumber . snapshotAttemptId) (Map.elems (snapshotOccurrenceAttempts occurrence))) of
      [] -> [snapshotOccurrencePrompt occurrence, "", "Waiting for a response…"]
      attempt : _ ->
        (if T.null (snapshotAttemptOutput attempt) then ["Waiting for output…"] else tailTextLines 200 (32 * 1024) (snapshotAttemptOutput attempt))
          <> map ("message: " <>) (snapshotAttemptMessages attempt)
          <> ["tool " <> fromMaybe "pending" (publicToolStatus tool) <> "  " <> fromMaybe (publicToolId tool) (publicToolTitle tool) <> maybe "" (": " <>) (publicToolSummary tool) | tool <- Map.elems (snapshotAttemptTools attempt)]
          <> ["todo " <> publicTodoStatus item <> "  " <> publicTodoContent item | item <- snapshotAttemptTodos attempt]
          <> maybe [] (\failure -> ["", "Failed: " <> failure]) (snapshotAttemptFailure attempt)

selectedOccurrenceBlocks :: RunSnapshot -> RunView -> [Text]
selectedOccurrenceBlocks snapshot view = case selectedOccurrence snapshot view of
  Nothing -> ["No occurrence selected."]
  Just occurrence ->
    [ "occurrence " <> occurrenceText (snapshotOccurrenceId occurrence),
      "state " <> occurrenceStateLabel (snapshotOccurrenceState occurrence),
      "request " <> snapshotOccurrenceIntent occurrence <> "/" <> snapshotOccurrenceCode occurrence,
      "addressee " <> snapshotOccurrenceAddressee occurrence,
      "prompt " <> snapshotOccurrencePrompt occurrence
    ]
      <> maybe [] (\answer -> ["answer " <> answer]) (snapshotOccurrenceAnswer occurrence)
      <> maybe [] dispatchLines (snapshotOccurrenceDispatch occurrence)
      <> maybe [] recoveryLines (snapshotOccurrenceRecovery occurrence)
      <> concatMap attemptLines (sortOn (attemptNumber . snapshotAttemptId) (Map.elems (snapshotOccurrenceAttempts occurrence)))
      <> [ "control " <> snapshotControlId acknowledgement <> " " <> snapshotControlState acknowledgement <> ": " <> snapshotControlMessage acknowledgement
           | acknowledgement <- Map.elems (snapshotControlAcks snapshot),
             snapshotControlOccurrence acknowledgement == Just (snapshotOccurrenceId occurrence)
         ]
  where
    dispatchLines dispatch =
      [ "dispatch " <> T.intercalate ", " (dispatchTargets dispatch)
          <> maybe "" (\(_, target) -> " -> " <> target) (dispatchRedirect dispatch)
      ]
    recoveryLines recovery =
      ["recovery " <> snapshotRecoveryGap recovery <> ": " <> snapshotRecoveryMessage recovery]
        <> ["offered " <> recoveryChoice choice <> maybe "" (" -> " <>) (recoveryTarget choice) | choice <- snapshotRecoveryChoices recovery]
        <> maybe [] (\chosen -> ["chosen " <> chosenChoice chosen <> maybe "" (" -> " <>) (chosenTarget chosen)]) (snapshotRecoveryChosen recovery)
    attemptLines attempt =
      [ "attempt " <> attemptText (snapshotAttemptId attempt) <> " " <> attemptStateLabel (snapshotAttemptState attempt) <> " on " <> snapshotAttemptTarget attempt
      ]
        <> ["  " <> line | line <- tailTextLines 200 (32 * 1024) (snapshotAttemptOutput attempt)]
        <> ["  message: " <> message | message <- snapshotAttemptMessages attempt]
        <> map toolLine (Map.elems (snapshotAttemptTools attempt))
        <> map todoLine (snapshotAttemptTodos attempt)
        <> maybe [] (\usage -> ["  usage: " <> T.pack (show (publicUsageUsed usage)) <> "/" <> T.pack (show (publicUsageSize usage))]) (snapshotAttemptUsage attempt)
        <> ["  reasoning summary: " <> summary | summary <- snapshotAttemptReasoningSummaries attempt]
        <> ["  steer " <> steerTiming steer <> ": " <> steerText steer | steer <- takeLast 20 (snapshotAttemptSteers attempt)]
        <> maybe [] (\failure -> ["  failure " <> failure]) (snapshotAttemptFailure attempt)
    toolLine tool =
      "  tool "
        <> maybe "pending" id (publicToolStatus tool)
        <> " "
        <> maybe (publicToolId tool) id (publicToolTitle tool)
        <> maybe "" (" [" <>) (fmap (<> "]") (publicToolKind tool))
        <> maybe "" (": " <>) (publicToolSummary tool)
    todoLine item = "  todo " <> publicTodoStatus item <> "/" <> publicTodoPriority item <> ": " <> publicTodoContent item

pendingPersonOccurrences :: RunSnapshot -> [OccurrenceSnapshot]
pendingPersonOccurrences snapshot =
  [ occurrence
    | occurrenceId <- occurrenceOrder snapshot,
      Just occurrence <- [Map.lookup occurrenceId (snapshotOccurrences snapshot)],
      snapshotOccurrencePersonPending occurrence
  ]

activeAttemptForSelection :: RunSnapshot -> RunView -> Maybe AttemptId
activeAttemptForSelection snapshot view = do
  occurrence <- selectedOccurrence snapshot view
  case [snapshotAttemptId attempt | attempt <- Map.elems (snapshotOccurrenceAttempts occurrence), snapshotAttemptState attempt == AttemptRunning] of
    attempt : _ -> Just attempt
    [] -> Nothing

occurrenceOrder :: RunSnapshot -> [OccurrenceId]
occurrenceOrder snapshot
  | snapshotTraceRecorded snapshot = snapshotAuthoredOrder snapshot
  | otherwise = Map.keys (snapshotOccurrences snapshot)

occurrenceText :: OccurrenceId -> Text
occurrenceText = T.pack . show . occurrenceNumber

attemptText :: AttemptId -> Text
attemptText attempt = occurrenceText (attemptOccurrence attempt) <> "." <> T.pack (show (attemptNumber attempt))

occurrenceStateLabel :: OccurrenceState -> Text
occurrenceStateLabel OccurrenceRunningState = "Running"
occurrenceStateLabel OccurrenceRecoveringState = "Awaiting recovery"
occurrenceStateLabel OccurrenceReusedState = "Reused"
occurrenceStateLabel OccurrenceCompletedState = "Completed"
occurrenceStateLabel OccurrenceFailedState = "Failed"
occurrenceStateLabel OccurrenceCancelledState = "Cancelled"

attemptStateLabel :: AttemptState -> Text
attemptStateLabel AttemptRunning = "Running"
attemptStateLabel AttemptCompletedState = "Completed"
attemptStateLabel AttemptFailedState = "Failed"

runStatusLabel :: RunStatus -> Text
runStatusLabel RunStarting = "Starting"
runStatusLabel RunRunning = "Running"
runStatusLabel RunCancelling = "Cancelling"
runStatusLabel RunSucceeded = "Succeeded"
runStatusLabel RunFailedStatus = "Failed"
runStatusLabel RunCancelledStatus = "Cancelled"
runStatusLabel RunOrphaned = "Owner unavailable"

runFailureLines :: RunSnapshot -> [Text]
runFailureLines snapshot = case snapshotRunFailure snapshot of
  Just message -> ["Why it stopped", message, ""]
  Nothing -> []

firstOf :: [a] -> Maybe a
firstOf (value : _) = Just value
firstOf [] = Nothing

takeLast :: Int -> [a] -> [a]
takeLast count values = drop (max 0 (length values - count)) values

tailTextLines :: Int -> Int -> Text -> [Text]
tailTextLines maxLines maxCharacters = reverse . go maxCharacters . take maxLines . reverse . T.lines
  where
    go _ [] = []
    go remaining _ | remaining <= 0 = []
    go remaining (line : rest) =
      let suffix = T.takeEnd remaining line
       in suffix : go (remaining - T.length suffix) rest

