{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure lifecycle projection of validated runtime envelopes.
module Agentic.Runtime.Snapshot
  ( SnapshotErrorClass (..),
    SnapshotError (..),
    RunStatus (..),
    AttemptState (..),
    AttemptSnapshot (..),
    SteerSnapshot (..),
    OccurrenceState (..),
    DispatchSnapshot (..),
    RecoveryChosen (..),
    RecoverySnapshot (..),
    OccurrenceSnapshot (..),
    ControlAckSnapshot (..),
    RunSnapshot (..),
    initialRunSnapshot,
    stepRunSnapshot,
    runSnapshotValue,
    controlAcknowledgementLimit,
  )
where

import Agentic.Runtime.Protocol
import Control.Monad (unless, when)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)

-- | Stable category for one refused snapshot transition.
data SnapshotErrorClass
  = SnapshotVersion
  | SnapshotRun
  | SnapshotSequence
  | SnapshotLifecycle
  deriving (Eq, Ord, Show)

-- | One fail-closed snapshot refusal with a stable class and human detail.
data SnapshotError = SnapshotError
  { snapshotErrorClass :: !SnapshotErrorClass,
    snapshotErrorMessage :: !Text
  }
  deriving (Eq, Show)

-- | Lifecycle of one supervised run.
data RunStatus
  = RunStarting
  | RunRunning
  | RunCancelling
  | RunSucceeded
  | RunFailedStatus
  | RunCancelledStatus
  | RunOrphaned
  deriving (Eq, Ord, Show)

-- | Lifecycle of one physical attempt.
data AttemptState = AttemptRunning | AttemptCompletedState | AttemptFailedState
  deriving (Eq, Ord, Show)

-- | One delivered steer recorded against its exact physical attempt.
data SteerSnapshot = SteerSnapshot
  { steerControlId :: !Text,
    steerTiming :: !Text,
    steerText :: !Text
  }
  deriving (Eq, Show)

-- | Bounded projection of one physical attempt.
data AttemptSnapshot = AttemptSnapshot
  { snapshotAttemptId :: !AttemptId,
    snapshotAttemptTarget :: !Text,
    snapshotAttemptState :: !AttemptState,
    snapshotAttemptSteerable :: !(Maybe Bool),
    snapshotAttemptOutput :: !Text,
    snapshotAttemptSteers :: ![SteerSnapshot],
    snapshotAttemptMessages :: ![Text],
    snapshotAttemptTools :: !(Map Text PublicToolUpdate),
    snapshotAttemptTodos :: ![PublicTodoItem],
    snapshotAttemptUsage :: !(Maybe PublicUsage),
    snapshotAttemptReasoningSummaries :: ![Text],
    snapshotAttemptFailure :: !(Maybe Text),
    snapshotAttemptFailureClass :: !(Maybe FailureClass)
  }
  deriving (Eq, Show)

-- | Lifecycle of one authored request occurrence.
data OccurrenceState
  = OccurrenceRunningState
  | OccurrenceRecoveringState
  | OccurrenceReusedState
  | OccurrenceCompletedState
  | OccurrenceFailedState
  | OccurrenceCancelledState
  deriving (Eq, Ord, Show)

-- | Scheduler targets offered before physical dispatch.
data DispatchSnapshot = DispatchSnapshot
  { dispatchTargets :: ![Text],
    dispatchOpen :: !Bool,
    dispatchRedirect :: !(Maybe (Text, Text))
  }
  deriving (Eq, Show)

-- | One accepted recovery choice.
data RecoveryChosen = RecoveryChosen
  { chosenControlId :: !Text,
    chosenChoice :: !Text,
    chosenTarget :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | Recovery state retained across retries and failover.
data RecoverySnapshot = RecoverySnapshot
  { snapshotRecoveryGap :: !Text,
    snapshotRecoveryMessage :: !Text,
    snapshotRecoveryRetries :: ![Text],
    snapshotRecoveryChoices :: ![RecoveryOption],
    snapshotRecoveryChosen :: !(Maybe RecoveryChosen)
  }
  deriving (Eq, Show)

-- | Pure projection of one request occurrence and its attempts.
data OccurrenceSnapshot = OccurrenceSnapshot
  { snapshotOccurrenceId :: !OccurrenceId,
    snapshotOccurrenceState :: !OccurrenceState,
    snapshotOccurrenceCode :: !Text,
    snapshotOccurrenceIntent :: !Text,
    snapshotOccurrenceAddressee :: !Text,
    snapshotOccurrencePrompt :: !Text,
    snapshotOccurrenceAnswer :: !(Maybe Text),
    snapshotOccurrenceDispatch :: !(Maybe DispatchSnapshot),
    snapshotOccurrenceRecovery :: !(Maybe RecoverySnapshot),
    snapshotOccurrenceReuseKind :: !(Maybe Text),
    snapshotOccurrenceSource :: !(Maybe Text),
    snapshotOccurrenceFailureClass :: !(Maybe FailureClass),
    snapshotOccurrenceReplayable :: !Bool,
    snapshotOccurrencePersonQuestion :: !(Maybe QuestionRef),
    snapshotOccurrencePersonPending :: !Bool,
    snapshotOccurrenceAttempts :: !(Map AttemptId AttemptSnapshot)
  }
  deriving (Eq, Show)

-- | Latest acknowledgement for one idempotent control id.
data ControlAckSnapshot = ControlAckSnapshot
  { snapshotControlId :: !Text,
    snapshotControlState :: !Text,
    snapshotControlMessage :: !Text,
    snapshotControlCommand :: !(Maybe Text),
    snapshotControlOccurrence :: !(Maybe OccurrenceId),
    snapshotControlAttempt :: !(Maybe AttemptId)
  }
  deriving (Eq, Show)

-- | Reconstructible pure view of one machine run.
data RunSnapshot = RunSnapshot
  { snapshotRunId :: !RunId,
    snapshotRunStatus :: !RunStatus,
    snapshotLastEnvelope :: !(Maybe Envelope),
    snapshotWorkflow :: !(Maybe Text),
    snapshotTarget :: !(Maybe Text),
    snapshotPersonAnswering :: !(Maybe PersonAnswering),
    snapshotOccurrences :: !(Map OccurrenceId OccurrenceSnapshot),
    snapshotAuthoredOrder :: ![OccurrenceId],
    snapshotTraceRecorded :: !Bool,
    snapshotControlAcks :: !(Map Text ControlAckSnapshot),
    snapshotBillFresh :: !(Maybe Integer),
    snapshotBillMemo :: !(Maybe Integer),
    snapshotResult :: !(Maybe ResultRef),
    snapshotRunFailure :: !(Maybe Text),
    snapshotRunFailureClass :: !(Maybe FailureClass)
  }
  deriving (Eq, Show)

-- | Empty snapshot for a run id known by its supervisor.
initialRunSnapshot :: RunId -> RunSnapshot
initialRunSnapshot runId =
  RunSnapshot
    { snapshotRunId = runId,
      snapshotRunStatus = RunStarting,
      snapshotLastEnvelope = Nothing,
      snapshotWorkflow = Nothing,
      snapshotTarget = Nothing,
      snapshotPersonAnswering = Nothing,
      snapshotOccurrences = Map.empty,
      snapshotAuthoredOrder = [],
      snapshotTraceRecorded = False,
      snapshotControlAcks = Map.empty,
      snapshotBillFresh = Nothing,
      snapshotBillMemo = Nothing,
      snapshotResult = Nothing,
      snapshotRunFailure = Nothing,
      snapshotRunFailureClass = Nothing
    }

-- | Fold one validated envelope, refusing every invalid lifecycle transition.
stepRunSnapshot :: RunSnapshot -> Envelope -> Either SnapshotError RunSnapshot
stepRunSnapshot current envelope = do
  unless (envelopeVersion envelope `elem` supportedProtocolVersions) $
    refuse SnapshotVersion ("unsupported protocol version " <> tshow (envelopeVersion envelope))
  unless (envelopeRunId envelope == snapshotRunId current) $
    refuse SnapshotRun "runtime protocol run id changed within one snapshot"
  when (terminalStatus (snapshotRunStatus current)) $
    refuse SnapshotLifecycle ("post-terminal event " <> eventName (envelopeEvent envelope))
  case checkSequence (snapshotLastEnvelope current) envelope of
    Left why -> refuse SnapshotSequence why
    Right SequenceNext -> pure ()
  next <- applyEvent
    current
      { snapshotLastEnvelope = Just envelope
      }
    (envelopeEvent envelope)
  pure $ if terminalStatus (snapshotRunStatus next)
    then next {snapshotOccurrences = Map.map clearSteering (snapshotOccurrences next)}
    else next
  where
    clearSteering occurrence = occurrence {snapshotOccurrenceAttempts = Map.map
      (\attempt -> attempt {snapshotAttemptSteerable = False <$ snapshotAttemptSteerable attempt})
      (snapshotOccurrenceAttempts occurrence)}

applyEvent :: RunSnapshot -> RuntimeEvent -> Either SnapshotError RunSnapshot
applyEvent snapshot = \case
  RunStarted workflow target -> startRun snapshot workflow target Nothing
  RunStartedV2 workflow target personAnswering -> startRun snapshot workflow target (Just personAnswering)
  OccurrenceStarted occurrence code intent addressee prompt -> do
    unless (snapshotRunStatus snapshot == RunRunning) $
      lifecycle "occurrence started before run"
    when (Map.member occurrence (snapshotOccurrences snapshot)) $
      lifecycle ("duplicate occurrence " <> occurrenceText occurrence)
    when (Map.size (snapshotOccurrences snapshot) >= maxSnapshotOccurrences) $
      lifecycle "runtime snapshot exceeds 2048 occurrences"
    let occurrenceSnapshot =
          OccurrenceSnapshot
            { snapshotOccurrenceId = occurrence,
              snapshotOccurrenceState = OccurrenceRunningState,
              snapshotOccurrenceCode = code,
              snapshotOccurrenceIntent = intent,
              snapshotOccurrenceAddressee = addressee,
              snapshotOccurrencePrompt = prompt,
              snapshotOccurrenceAnswer = Nothing,
              snapshotOccurrenceDispatch = Nothing,
              snapshotOccurrenceRecovery = Nothing,
              snapshotOccurrenceReuseKind = Nothing,
              snapshotOccurrenceSource = Nothing,
              snapshotOccurrenceFailureClass = Nothing,
              snapshotOccurrenceReplayable = True,
              snapshotOccurrencePersonQuestion = Nothing,
              snapshotOccurrencePersonPending = False,
              snapshotOccurrenceAttempts = Map.empty
            }
    pure snapshot {snapshotOccurrences = Map.insert occurrence occurrenceSnapshot (snapshotOccurrences snapshot)}
  AttemptStarted attempt target ->
    modifyOccurrence snapshot (attemptOccurrence attempt) $ \occurrence -> do
      unless (snapshotOccurrenceState occurrence == OccurrenceRunningState) $
        lifecycle ("occurrence " <> occurrenceText (snapshotOccurrenceId occurrence) <> " cannot start an attempt")
      when (Map.member attempt (snapshotOccurrenceAttempts occurrence)) $
        lifecycle ("duplicate attempt " <> attemptText attempt)
      when (snapshotAttemptCount snapshot >= maxSnapshotAttempts) $
        lifecycle "runtime snapshot exceeds 512 attempts"
      let attemptSnapshot = AttemptSnapshot attempt target AttemptRunning Nothing "" [] [] Map.empty [] Nothing [] Nothing Nothing
          closeDispatch dispatch = dispatch {dispatchOpen = False}
      pure
        occurrence
          { snapshotOccurrenceDispatch = closeDispatch <$> snapshotOccurrenceDispatch occurrence,
            snapshotOccurrenceAttempts = Map.insert attempt attemptSnapshot (snapshotOccurrenceAttempts occurrence)
          }
  AttemptControlAvailability attempt steerable -> do
    unless (snapshotLastEnvelopeVersion snapshot == Just latestProtocolVersion) $
      lifecycle "control availability requires protocol version 3"
    modifyAttempt snapshot attempt $ \current -> do
      requireAttemptRunning current "control availability"
      pure current {snapshotAttemptSteerable = Just steerable}
  AttemptOutput attempt chunk ->
    modifyAttempt snapshot attempt $ \attemptSnapshot -> do
      requireAttemptRunning attemptSnapshot "output"
      pure attemptSnapshot {snapshotAttemptOutput = utf8Tail (snapshotAttemptOutput attemptSnapshot <> chunk)}
  AttemptProgress attempt progress ->
    modifyAttempt snapshot attempt $ \attemptSnapshot -> do
      requireAttemptRunning attemptSnapshot "progress"
      applyProgress attemptSnapshot progress
  AttemptSteered attempt control timing text -> do
    snapshot' <-
      modifyAttempt snapshot attempt $ \attemptSnapshot -> do
        requireAttemptRunning attemptSnapshot "steering"
        when (snapshotSteerCount snapshot >= maxSnapshotSteers) $
          lifecycle "runtime snapshot exceeds 256 steer records"
        pure
          attemptSnapshot
            { snapshotAttemptSteers = snapshotAttemptSteers attemptSnapshot <> [SteerSnapshot control timing text]
            }
    modifyOccurrence snapshot' (attemptOccurrence attempt) $ \occurrence ->
      pure occurrence {snapshotOccurrenceReplayable = False}
  AttemptCompleted attempt _source ->
    modifyAttempt snapshot attempt $ \attemptSnapshot -> do
      requireAttemptRunning attemptSnapshot "completion"
      pure attemptSnapshot {snapshotAttemptState = AttemptCompletedState,
        snapshotAttemptSteerable = False <$ snapshotAttemptSteerable attemptSnapshot}
  AttemptFailed attempt failure message ->
    modifyAttempt snapshot attempt $ \attemptSnapshot -> do
      requireAttemptRunning attemptSnapshot "failure"
      pure
        attemptSnapshot
          { snapshotAttemptState = AttemptFailedState,
            snapshotAttemptSteerable = False <$ snapshotAttemptSteerable attemptSnapshot,
            snapshotAttemptFailure = Just message,
            snapshotAttemptFailureClass = Just failure
          }
  OccurrenceReused occurrence answerGroup ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> do
      unless
        ( snapshotOccurrenceState occurrenceSnapshot == OccurrenceRunningState
            && Map.null (snapshotOccurrenceAttempts occurrenceSnapshot)
            && not (snapshotOccurrencePersonPending occurrenceSnapshot)
        ) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " cannot be reused")
      pure
        occurrenceSnapshot
          { snapshotOccurrenceState = OccurrenceReusedState,
            snapshotOccurrenceReuseKind = Just answerGroup,
            snapshotOccurrenceDispatch = (\dispatch -> dispatch {dispatchOpen = False}) <$> snapshotOccurrenceDispatch occurrenceSnapshot
          }
  OccurrenceRecoveryPending occurrence gap message choices ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> do
      unless (snapshotOccurrenceState occurrenceSnapshot == OccurrenceRunningState) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " cannot enter recovery")
      when (length choices > maxSnapshotOptions) $
        lifecycle "runtime snapshot recovery exceeds 64 choices"
      pure
        occurrenceSnapshot
          { snapshotOccurrenceState = OccurrenceRecoveringState,
            snapshotOccurrenceRecovery = Just (RecoverySnapshot gap message [] choices Nothing)
          }
  OccurrenceRetried occurrence control ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> case snapshotOccurrenceRecovery occurrenceSnapshot of
      Just recovery
        | snapshotOccurrenceState occurrenceSnapshot == OccurrenceRecoveringState,
          Just chosen <- snapshotRecoveryChosen recovery,
          chosenChoice chosen /= "abandon" -> do
            when (length (snapshotRecoveryRetries recovery) >= maxSnapshotHistory) $
              lifecycle "runtime snapshot recovery exceeds 64 retries"
            pure
              occurrenceSnapshot
                { snapshotOccurrenceState = OccurrenceRunningState,
                  snapshotOccurrenceRecovery =
                    Just recovery {snapshotRecoveryRetries = snapshotRecoveryRetries recovery <> [control]}
                }
      _ -> lifecycle ("occurrence " <> occurrenceText occurrence <> " was not waiting for retry/failover recovery")
  OccurrenceRecoveryChosen occurrence control choice target ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> case snapshotOccurrenceRecovery occurrenceSnapshot of
      Nothing -> lifecycle ("occurrence " <> occurrenceText occurrence <> " was not waiting for recovery choice")
      Just recovery -> do
        unless (snapshotOccurrenceState occurrenceSnapshot == OccurrenceRecoveringState) $
          lifecycle ("occurrence " <> occurrenceText occurrence <> " was not waiting for recovery choice")
        when (isJust (snapshotRecoveryChosen recovery)) $
          lifecycle ("occurrence " <> occurrenceText occurrence <> " already has a recovery choice")
        unless (any (matches choice target) (snapshotRecoveryChoices recovery)) $
          lifecycle ("recovery choice " <> choice <> " was not offered")
        pure
          occurrenceSnapshot
            { snapshotOccurrenceRecovery =
                Just recovery {snapshotRecoveryChosen = Just (RecoveryChosen control choice target)}
            }
  OccurrenceDispatchPending occurrence targets ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> do
      unless (snapshotOccurrenceState occurrenceSnapshot == OccurrenceRunningState && not (isJust (snapshotOccurrenceDispatch occurrenceSnapshot))) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " cannot open dispatch")
      when (length targets > maxSnapshotOptions) $
        lifecycle "runtime snapshot dispatch exceeds 64 targets"
      pure occurrenceSnapshot {snapshotOccurrenceDispatch = Just (DispatchSnapshot targets True Nothing)}
  OccurrenceRedirected occurrence control target ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> case snapshotOccurrenceDispatch occurrenceSnapshot of
      Just dispatch
        | dispatchOpen dispatch && target `elem` dispatchTargets dispatch ->
            pure
              occurrenceSnapshot
                { snapshotOccurrenceDispatch = Just dispatch {dispatchOpen = False, dispatchRedirect = Just (control, target)}
                }
      _ -> lifecycle ("redirect target " <> target <> " was not reserved in an open dispatch")
  OccurrencePersonAnswerPending occurrence reference ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> do
      unless
        ( snapshotOccurrenceState occurrenceSnapshot == OccurrenceRunningState
            && "person " `T.isPrefixOf` snapshotOccurrenceAddressee occurrenceSnapshot
            && Map.null (snapshotOccurrenceAttempts occurrenceSnapshot)
            && not (snapshotOccurrencePersonPending occurrenceSnapshot)
            && not (isJust (snapshotOccurrencePersonQuestion occurrenceSnapshot))
        ) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " cannot wait for a person answer")
      pure
        occurrenceSnapshot
          { snapshotOccurrencePersonQuestion = Just reference,
            snapshotOccurrencePersonPending = True
          }
  OccurrenceCompleted occurrence source answer ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> do
      unless (snapshotOccurrenceState occurrenceSnapshot `elem` [OccurrenceRunningState, OccurrenceReusedState]) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " cannot complete")
      when (snapshotOccurrencePersonPending occurrenceSnapshot) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " completed while waiting for a person answer")
      when (any ((== AttemptRunning) . snapshotAttemptState) (Map.elems (snapshotOccurrenceAttempts occurrenceSnapshot))) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " completed with an active attempt")
      pure
        occurrenceSnapshot
          { snapshotOccurrenceState =
              if snapshotOccurrenceState occurrenceSnapshot == OccurrenceReusedState
                then OccurrenceReusedState
                else OccurrenceCompletedState,
            snapshotOccurrenceSource = Just source,
            snapshotOccurrenceAnswer = Just answer
          }
  OccurrenceFailed occurrence failure message ->
    modifyOccurrence snapshot occurrence $ \occurrenceSnapshot -> do
      when (occurrenceTerminal (snapshotOccurrenceState occurrenceSnapshot)) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " failed after terminal state")
      when (any ((== AttemptRunning) . snapshotAttemptState) (Map.elems (snapshotOccurrenceAttempts occurrenceSnapshot))) $
        lifecycle ("occurrence " <> occurrenceText occurrence <> " failed with an active attempt")
      pure
        occurrenceSnapshot
          { snapshotOccurrenceState = OccurrenceFailedState,
            snapshotOccurrenceAnswer = Just message,
            snapshotOccurrenceFailureClass = Just failure
          }
  ControlAcknowledged control state message ->
    recordControlAck snapshot control state message Nothing Nothing Nothing
  ControlAcknowledgedV2 control state message command occurrence attempt ->
    recordControlAck snapshot control state message (Just command) occurrence attempt
  TraceOrdered occurrences -> do
    when (snapshotTraceRecorded snapshot) $ lifecycle "trace.ordered was emitted more than once"
    unless (all (`Map.member` snapshotOccurrences snapshot) occurrences) $
      lifecycle "trace.ordered occurrenceIds are invalid or unknown"
    unless (length occurrences == Map.size (snapshotOccurrences snapshot)) $
      lifecycle "trace.ordered omitted occurrences"
    unless (all occurrenceComplete (Map.elems (snapshotOccurrences snapshot))) $
      lifecycle "trace.ordered was emitted before all occurrences completed"
    pure snapshot {snapshotAuthoredOrder = occurrences, snapshotTraceRecorded = True}
  RunCompleted fresh memo -> completeRun snapshot fresh memo Nothing
  RunCompletedV2 fresh memo result -> completeRun snapshot fresh memo (Just result)
  RunFailed failure message -> do
    unless (snapshotRunStatus snapshot `elem` [RunRunning, RunCancelling]) $
      lifecycle "run failed before start"
    pure
      snapshot
        { snapshotRunStatus = RunFailedStatus,
          snapshotRunFailure = Just message,
          snapshotRunFailureClass = Just failure
        }
  RunCancelled message -> do
    unless (snapshotRunStatus snapshot `elem` [RunRunning, RunCancelling]) $
      lifecycle "run cancelled before start"
    pure
      snapshot
        { snapshotRunStatus = RunCancelledStatus,
          snapshotRunFailure = Just message,
          snapshotRunFailureClass = Just FailureCancelled
        }

startRun :: RunSnapshot -> Text -> Text -> Maybe PersonAnswering -> Either SnapshotError RunSnapshot
startRun snapshot workflow target personAnswering = do
  unless (snapshotRunStatus snapshot `elem` [RunStarting, RunCancelling]) $
    lifecycle "run.started is not first"
  pure
    snapshot
      { snapshotRunStatus = if snapshotRunStatus snapshot == RunCancelling then RunCancelling else RunRunning,
        snapshotWorkflow = Just workflow,
        snapshotTarget = Just target,
        snapshotPersonAnswering = personAnswering
      }

recordControlAck :: RunSnapshot -> Text -> Text -> Text -> Maybe Text -> Maybe OccurrenceId -> Maybe AttemptId -> Either SnapshotError RunSnapshot
recordControlAck snapshot control state message command occurrence attempt =
  let nextAck = ControlAckSnapshot control state message command occurrence attempt
   in case Map.lookup control (snapshotControlAcks snapshot) of
        Just prior | prior == nextAck -> pure snapshot
        prior -> do
          let hasCancellation = command==Just "cancelRun" || any ((==Just "cancelRun") . snapshotControlCommand) (Map.elems(snapshotControlAcks snapshot))
              limit = controlAcknowledgementLimit (maybe protocolVersion id (snapshotLastEnvelopeVersion snapshot)) hasCancellation
          when (Map.notMember control (snapshotControlAcks snapshot) && Map.size (snapshotControlAcks snapshot) >= limit) $
            lifecycle ("runtime snapshot exceeds " <> tshow limit <> " control acknowledgements")
          unless (snapshotRunStatus snapshot `elem` [RunRunning, RunCancelling]) $
            lifecycle "control acknowledged while run is not active"
          case prior of
            Just acknowledgement ->
              unless
                ( command == snapshotControlCommand acknowledgement
                    && occurrence == snapshotControlOccurrence acknowledgement
                    && attempt == snapshotControlAttempt acknowledgement
                )
                (lifecycle "control acknowledgement correlation mismatch: command or target identity changed")
            Nothing -> pure ()
          case prior of
            Just acknowledgement
              | terminalAck (snapshotControlState acknowledgement) || state `elem` ["accepted", "queued"] ->
                  lifecycle ("invalid acknowledgement transition " <> snapshotControlState acknowledgement <> " -> " <> state)
            _ -> pure ()
          when
            ( command == Just "answerPerson"
                && state `elem` ["delivered", "failed"]
                && maybe True ((/= "accepted") . snapshotControlState) prior
            ) $
            lifecycle "person answer terminal acknowledgement was not preceded by acceptance"
          snapshot' <-
            case (command, occurrence) of
              (Just "answerPerson", Just occurrenceId)
                | state `elem` ["accepted", "delivered", "failed"] ->
                    modifyOccurrence snapshot occurrenceId $ \occurrenceSnapshot -> do
                      unless (snapshotOccurrencePersonPending occurrenceSnapshot) $
                        lifecycle ("occurrence " <> occurrenceText occurrenceId <> " is not waiting for a person answer")
                      when (isJust attempt) $ lifecycle "person answer acknowledgement has an attempt id"
                      pure occurrenceSnapshot {snapshotOccurrencePersonPending = state /= "delivered"}
              (Just "answerPerson", Nothing) -> lifecycle "person answer acknowledgement has no occurrence id"
              _ -> pure snapshot
          pure
            snapshot'
              { snapshotControlAcks = Map.insert control nextAck (snapshotControlAcks snapshot')
              }

completeRun :: RunSnapshot -> Integer -> Integer -> Maybe ResultRef -> Either SnapshotError RunSnapshot
completeRun snapshot fresh memo result = do
  unless
    ( snapshotRunStatus snapshot == RunRunning
        && snapshotTraceRecorded snapshot
        && length (snapshotAuthoredOrder snapshot) == Map.size (snapshotOccurrences snapshot)
        && all occurrenceComplete (Map.elems (snapshotOccurrences snapshot))
    ) $
    lifecycle "run completed before authored trace/occurrences completed"
  when (maybe False (>= correlatedProtocolVersion) (snapshotLastEnvelopeVersion snapshot) && not (isJust result)) $
    lifecycle "protocol version 2 completed without a result reference"
  pure
    snapshot
      { snapshotRunStatus = RunSucceeded,
        snapshotBillFresh = Just fresh,
        snapshotBillMemo = Just memo,
        snapshotResult = result
      }

snapshotLastEnvelopeVersion :: RunSnapshot -> Maybe Int
snapshotLastEnvelopeVersion = fmap envelopeVersion . snapshotLastEnvelope

modifyOccurrence :: RunSnapshot -> OccurrenceId -> (OccurrenceSnapshot -> Either SnapshotError OccurrenceSnapshot) -> Either SnapshotError RunSnapshot
modifyOccurrence snapshot occurrence f = case Map.lookup occurrence (snapshotOccurrences snapshot) of
  Nothing -> lifecycle ("unknown occurrence " <> occurrenceText occurrence)
  Just known -> do
    updated <- f known
    pure snapshot {snapshotOccurrences = Map.insert occurrence updated (snapshotOccurrences snapshot)}

modifyAttempt :: RunSnapshot -> AttemptId -> (AttemptSnapshot -> Either SnapshotError AttemptSnapshot) -> Either SnapshotError RunSnapshot
modifyAttempt snapshot attempt f =
  modifyOccurrence snapshot (attemptOccurrence attempt) $ \occurrence -> case Map.lookup attempt (snapshotOccurrenceAttempts occurrence) of
    Nothing -> lifecycle ("unknown attempt " <> attemptText attempt)
    Just known -> do
      updated <- f known
      pure occurrence {snapshotOccurrenceAttempts = Map.insert attempt updated (snapshotOccurrenceAttempts occurrence)}

requireAttemptRunning :: AttemptSnapshot -> Text -> Either SnapshotError ()
requireAttemptRunning attempt operation =
  unless (snapshotAttemptState attempt == AttemptRunning) $
    lifecycle ("attempt " <> attemptText (snapshotAttemptId attempt) <> " cannot accept " <> operation)

matches :: Text -> Maybe Text -> RecoveryOption -> Bool
matches choice target option = recoveryChoice option == choice && recoveryTarget option == target

occurrenceComplete :: OccurrenceSnapshot -> Bool
occurrenceComplete occurrence = snapshotOccurrenceState occurrence `elem` [OccurrenceCompletedState, OccurrenceReusedState]

occurrenceTerminal :: OccurrenceState -> Bool
occurrenceTerminal state = state `elem` [OccurrenceCompletedState, OccurrenceReusedState, OccurrenceFailedState, OccurrenceCancelledState]

terminalStatus :: RunStatus -> Bool
terminalStatus status = status `elem` [RunSucceeded, RunFailedStatus, RunCancelledStatus, RunOrphaned]

terminalAck :: Text -> Bool
terminalAck state = state `notElem` ["accepted", "queued"]

lifecycle :: Text -> Either SnapshotError a
lifecycle = refuse SnapshotLifecycle

refuse :: SnapshotErrorClass -> Text -> Either SnapshotError a
refuse kind = Left . SnapshotError kind

utf8Tail :: Text -> Text
utf8Tail text
  | BS.length encoded <= outputTailBytes = text
  | otherwise = T.pack kept
  where
    encoded = TE.encodeUtf8 text
    (_, kept) = foldl keep (0, []) (reverse (T.unpack text))
    keep state@(bytes, chars) character
      | bytes + characterBytes character > outputTailBytes = state
      | otherwise = (bytes + characterBytes character, character : chars)
    characterBytes = BS.length . TE.encodeUtf8 . T.singleton

maxSnapshotOccurrences, maxSnapshotAttempts, maxSnapshotSteers, maxSnapshotControls, maxSnapshotOptions, maxSnapshotHistory :: Int
maxSnapshotOccurrences = 2048
maxSnapshotAttempts = 512
maxSnapshotSteers = 256
maxSnapshotControls = 256

-- | Observation v3 adds one cancellation-only slot without reducing ordinary IDs.
controlAcknowledgementLimit :: Int -> Bool -> Int
controlAcknowledgementLimit version hasCancellation = maxSnapshotControls +
  if version==latestProtocolVersion && hasCancellation then 1 else 0
maxSnapshotOptions = 64
maxSnapshotHistory = 64

snapshotAttemptCount :: RunSnapshot -> Int
snapshotAttemptCount = sum . map (Map.size . snapshotOccurrenceAttempts) . Map.elems . snapshotOccurrences

snapshotSteerCount :: RunSnapshot -> Int
snapshotSteerCount = sum . map occurrenceSteers . Map.elems . snapshotOccurrences
  where
    occurrenceSteers = sum . map (length . snapshotAttemptSteers) . Map.elems . snapshotOccurrenceAttempts

outputTailBytes :: Int
outputTailBytes = 64 * 1024

eventName :: RuntimeEvent -> Text
eventName = \case
  RunStarted {} -> "run.started"
  RunStartedV2 {} -> "run.started"
  OccurrenceStarted {} -> "occurrence.started"
  AttemptStarted {} -> "attempt.started"
  AttemptControlAvailability {} -> "attempt.control-availability"
  AttemptOutput {} -> "attempt.output"
  AttemptProgress {} -> "attempt.progress"
  AttemptSteered {} -> "attempt.steered"
  AttemptCompleted {} -> "attempt.completed"
  AttemptFailed {} -> "attempt.failed"
  OccurrenceReused {} -> "occurrence.reused"
  OccurrenceRecoveryPending {} -> "occurrence.recovery-pending"
  OccurrenceRetried {} -> "occurrence.retried"
  OccurrenceRecoveryChosen {} -> "occurrence.recovery-chosen"
  OccurrenceDispatchPending {} -> "occurrence.dispatch-pending"
  OccurrenceRedirected {} -> "occurrence.redirected"
  OccurrenceCompleted {} -> "occurrence.completed"
  OccurrenceFailed {} -> "occurrence.failed"
  OccurrencePersonAnswerPending {} -> "occurrence.person-answer-pending"
  ControlAcknowledged {} -> "control.ack"
  ControlAcknowledgedV2 {} -> "control.ack"
  TraceOrdered {} -> "trace.ordered"
  RunCompleted {} -> "run.completed"
  RunCompletedV2 {} -> "run.completed"
  RunFailed {} -> "run.failed"
  RunCancelled {} -> "run.cancelled"

runSnapshotValue :: RunSnapshot -> Value
runSnapshotValue snapshot =
  object $
    [ "runId" .= runIdText (snapshotRunId snapshot),
      "status" .= runStatusText (snapshotRunStatus snapshot),
      "lastSequence" .= fmap (word64Text . sequenceNumber . envelopeSequence) (snapshotLastEnvelope snapshot),
      "workflow" .= snapshotWorkflow snapshot,
      "target" .= snapshotTarget snapshot,
      "occurrences" .= map occurrenceValue (Map.elems (snapshotOccurrences snapshot)),
      "authoredOrder" .= map occurrenceText (snapshotAuthoredOrder snapshot),
      "traceRecorded" .= snapshotTraceRecorded snapshot,
      "controlAcks" .= map controlAckValue (Map.elems (snapshotControlAcks snapshot)),
      "billFresh" .= fmap tshow (snapshotBillFresh snapshot),
      "billMemo" .= fmap tshow (snapshotBillMemo snapshot),
      "failure" .= snapshotRunFailure snapshot,
      "failureClass" .= fmap failureTextValue (snapshotRunFailureClass snapshot)
    ]
      <> maybe [] (\mode -> ["personAnswering" .= personAnsweringValue mode]) (snapshotPersonAnswering snapshot)
      <> maybe [] (\result -> ["result" .= result]) (snapshotResult snapshot)

occurrenceValue :: OccurrenceSnapshot -> Value
occurrenceValue occurrence =
  object $
    [ "id" .= occurrenceText (snapshotOccurrenceId occurrence),
      "state" .= occurrenceStateText (snapshotOccurrenceState occurrence),
      "code" .= snapshotOccurrenceCode occurrence,
      "intent" .= snapshotOccurrenceIntent occurrence,
      "addressee" .= snapshotOccurrenceAddressee occurrence,
      "prompt" .= snapshotOccurrencePrompt occurrence,
      "answer" .= snapshotOccurrenceAnswer occurrence,
      "dispatch" .= fmap dispatchValue (snapshotOccurrenceDispatch occurrence),
      "recovery" .= fmap recoveryValue (snapshotOccurrenceRecovery occurrence),
      "reuseKind" .= snapshotOccurrenceReuseKind occurrence,
      "source" .= snapshotOccurrenceSource occurrence,
      "failureClass" .= fmap failureTextValue (snapshotOccurrenceFailureClass occurrence),
      "replayable" .= snapshotOccurrenceReplayable occurrence,
      "attempts" .= map attemptValueSnapshot (Map.elems (snapshotOccurrenceAttempts occurrence))
    ]
      <> maybe
        []
        (\reference -> ["personQuestion" .= reference, "personPending" .= snapshotOccurrencePersonPending occurrence])
        (snapshotOccurrencePersonQuestion occurrence)

attemptValueSnapshot :: AttemptSnapshot -> Value
attemptValueSnapshot attempt =
  object $
    [ "id" .= attemptText (snapshotAttemptId attempt),
      "target" .= snapshotAttemptTarget attempt,
      "state" .= attemptStateText (snapshotAttemptState attempt),
      "output" .= snapshotAttemptOutput attempt,
      "steers" .= map steerValue (snapshotAttemptSteers attempt),
      "failure" .= snapshotAttemptFailure attempt,
      "failureClass" .= fmap failureTextValue (snapshotAttemptFailureClass attempt)
    ]
      <> maybe [] (\support -> ["steerable" .= support]) (snapshotAttemptSteerable attempt)
      <> ["messages" .= snapshotAttemptMessages attempt | not (null (snapshotAttemptMessages attempt))]
      <> ["tools" .= Map.elems (snapshotAttemptTools attempt) | not (Map.null (snapshotAttemptTools attempt))]
      <> ["todos" .= snapshotAttemptTodos attempt | not (null (snapshotAttemptTodos attempt))]
      <> maybe [] (\usage -> ["usage" .= usage]) (snapshotAttemptUsage attempt)
      <> ["reasoningSummaries" .= snapshotAttemptReasoningSummaries attempt | not (null (snapshotAttemptReasoningSummaries attempt))]

steerValue :: SteerSnapshot -> Value
steerValue steer =
  object
    [ "controlId" .= steerControlId steer,
      "timing" .= steerTiming steer,
      "text" .= steerText steer
    ]

dispatchValue :: DispatchSnapshot -> Value
dispatchValue dispatch =
  object
    [ "targets" .= dispatchTargets dispatch,
      "open" .= dispatchOpen dispatch,
      "redirect" .= fmap (\(control, target) -> object ["controlId" .= control, "target" .= target]) (dispatchRedirect dispatch)
    ]

recoveryValue :: RecoverySnapshot -> Value
recoveryValue recovery =
  object
    [ "gap" .= snapshotRecoveryGap recovery,
      "message" .= snapshotRecoveryMessage recovery,
      "retries" .= snapshotRecoveryRetries recovery,
      "choices" .= snapshotRecoveryChoices recovery,
      "chosen" .= fmap recoveryChosenValue (snapshotRecoveryChosen recovery)
    ]

recoveryChosenValue :: RecoveryChosen -> Value
recoveryChosenValue chosen =
  object
    [ "controlId" .= chosenControlId chosen,
      "choice" .= chosenChoice chosen,
      "target" .= chosenTarget chosen
    ]

controlAckValue :: ControlAckSnapshot -> Value
controlAckValue acknowledgement =
  object $
    [ "controlId" .= snapshotControlId acknowledgement,
      "state" .= snapshotControlState acknowledgement,
      "message" .= snapshotControlMessage acknowledgement
    ]
      <> maybe [] (\command -> ["command" .= command]) (snapshotControlCommand acknowledgement)
      <> maybe [] (\occurrence -> ["occurrenceId" .= occurrenceText occurrence]) (snapshotControlOccurrence acknowledgement)
      <> maybe [] (\attempt -> ["attemptId" .= attemptText attempt]) (snapshotControlAttempt acknowledgement)

runStatusText :: RunStatus -> Text
runStatusText = \case
  RunStarting -> "starting"
  RunRunning -> "running"
  RunCancelling -> "cancelling"
  RunSucceeded -> "succeeded"
  RunFailedStatus -> "failed"
  RunCancelledStatus -> "cancelled"
  RunOrphaned -> "orphaned"

personAnsweringValue :: PersonAnswering -> Text
personAnsweringValue PersonAnswerEngine = "engine"
personAnsweringValue PersonAnswerLocalControl = "local-control"

occurrenceStateText :: OccurrenceState -> Text
occurrenceStateText = \case
  OccurrenceRunningState -> "running"
  OccurrenceRecoveringState -> "recovering"
  OccurrenceReusedState -> "reused"
  OccurrenceCompletedState -> "completed"
  OccurrenceFailedState -> "failed"
  OccurrenceCancelledState -> "cancelled"

attemptStateText :: AttemptState -> Text
attemptStateText = \case
  AttemptRunning -> "running"
  AttemptCompletedState -> "completed"
  AttemptFailedState -> "failed"

failureTextValue :: FailureClass -> Text
failureTextValue = \case
  FailureSetup -> "setup"
  FailureTransport -> "transport"
  FailureDecode -> "decode"
  FailureProtocol -> "protocol"
  FailureCancelled -> "cancelled"
  FailureRuntime -> "runtime"

occurrenceText :: OccurrenceId -> Text
occurrenceText = word64Text . occurrenceNumber

applyProgress :: AttemptSnapshot -> PublicProgress -> Either SnapshotError AttemptSnapshot
applyProgress attempt = \case
  ProgressMessage text ->
    pure attempt {snapshotAttemptMessages = appendBounded 64 (snapshotAttemptMessages attempt) text}
  ProgressReasoningSummary text ->
    pure attempt {snapshotAttemptReasoningSummaries = appendBounded 32 (snapshotAttemptReasoningSummaries attempt) text}
  ProgressTodos items ->
    pure attempt {snapshotAttemptTodos = items}
  ProgressUsage usage ->
    pure attempt {snapshotAttemptUsage = Just usage}
  ProgressTool update -> do
    let tools = snapshotAttemptTools attempt
        identifier = publicToolId update
        merged = maybe update (`mergeToolUpdate` update) (Map.lookup identifier tools)
    when (Map.notMember identifier tools && Map.size tools >= 128) $
      lifecycle "runtime snapshot exceeds 128 public tools in one attempt"
    pure attempt {snapshotAttemptTools = Map.insert identifier merged tools}

mergeToolUpdate :: PublicToolUpdate -> PublicToolUpdate -> PublicToolUpdate
mergeToolUpdate previous update =
  PublicToolUpdate
    { publicToolId = publicToolId update,
      publicToolTitle = publicToolTitle update `orPrevious` publicToolTitle previous,
      publicToolKind = publicToolKind update `orPrevious` publicToolKind previous,
      publicToolStatus = publicToolStatus update `orPrevious` publicToolStatus previous,
      publicToolSummary = publicToolSummary update `orPrevious` publicToolSummary previous
    }
  where
    Just value `orPrevious` _ = Just value
    Nothing `orPrevious` old = old

appendBounded :: Int -> [a] -> a -> [a]
appendBounded limit values value = drop (max 0 (length values + 1 - limit)) (values <> [value])

attemptText :: AttemptId -> Text
attemptText attempt = occurrenceText (attemptOccurrence attempt) <> ":" <> T.pack (show (attemptNumber attempt))

word64Text :: Word64 -> Text
word64Text = T.pack . show

tshow :: (Show a) => a -> Text
tshow = T.pack . show
