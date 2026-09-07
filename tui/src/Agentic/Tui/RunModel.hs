{-# LANGUAGE OverloadedStrings #-}

-- | Identity-stable, bounded projection of a runtime snapshot.
module Agentic.Tui.RunModel
  ( RunView (..),
    emptyRunView,
    reconcileRunView,
    moveOccurrenceSelection,
    selectedOccurrence,
    occurrenceRows,
    selectedOccurrenceLines,
    pendingPersonOccurrences,
    activeAttemptForSelection,
  )
where

import Agentic.Runtime
  ( AttemptId (..),
    AttemptSnapshot (..),
    AttemptState (AttemptRunning),
    ControlAckSnapshot (..),
    DispatchSnapshot (..),
    OccurrenceId (..),
    OccurrenceState (OccurrenceRecoveringState, OccurrenceRunningState),
    OccurrenceSnapshot (..),
    PublicTodoItem (..),
    PublicToolUpdate (..),
    PublicUsage (..),
    RecoveryChosen (..),
    RecoveryOption (..),
    RecoverySnapshot (..),
    RunSnapshot (..),
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
occurrenceRows snapshot view =
  [ marker occurrenceId
      <> "["
      <> occurrenceText occurrenceId
      <> "] "
      <> stateText (snapshotOccurrenceState occurrence)
      <> "  "
      <> snapshotOccurrenceIntent occurrence
      <> "/"
      <> snapshotOccurrenceCode occurrence
      <> "  "
      <> snapshotOccurrenceAddressee occurrence
    | occurrenceId <- occurrenceOrder snapshot,
      Just occurrence <- [Map.lookup occurrenceId (snapshotOccurrences snapshot)]
  ]
  where
    marker occurrenceId = if Just occurrenceId == runViewOccurrence view then "> " else "  "

selectedOccurrenceLines :: RunSnapshot -> RunView -> [Text]
selectedOccurrenceLines snapshot view = concatMap (T.splitOn "\n") (selectedOccurrenceBlocks snapshot view)

selectedOccurrenceBlocks :: RunSnapshot -> RunView -> [Text]
selectedOccurrenceBlocks snapshot view = case selectedOccurrence snapshot view of
  Nothing -> ["No occurrence selected."]
  Just occurrence ->
    [ "occurrence " <> occurrenceText (snapshotOccurrenceId occurrence),
      "state " <> stateText (snapshotOccurrenceState occurrence),
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
      [ "attempt " <> attemptText (snapshotAttemptId attempt) <> " " <> T.pack (show (snapshotAttemptState attempt)) <> " on " <> snapshotAttemptTarget attempt
      ]
        <> ["  " <> line | line <- takeLast 200 (T.lines (snapshotAttemptOutput attempt))]
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

stateText :: Show state => state -> Text
stateText = T.dropEnd 5 . T.pack . show

firstOf :: [a] -> Maybe a
firstOf (value : _) = Just value
firstOf [] = Nothing

takeLast :: Int -> [a] -> [a]
takeLast count values = drop (max 0 (length values - count)) values

