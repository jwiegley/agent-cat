{-# LANGUAGE OverloadedStrings #-}

-- | Public observations of one immutable Runtime prefix and its durable bindings.
-- Page identities and live execution authority are not part of this projection.
module Agentic.Manager.Observation
  ( SnapshotCut, SnapshotProjection (..), captureSnapshot, restoreSnapshot,
    withRunSnapshot, withRunSnapshotSource, runtimeSummary
  ) where

import Agentic.Manager.Authorization
import Agentic.Manager.History (verificationValue)
import Agentic.Manager.Profile (ConfigurationLimits)
import qualified Agentic.Manager.Protocol.Command as Command
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.State
  ( RunAssociation (..), ProjectionCut, captureProjectionCut, restoreProjectionCut,
    authorizeObservation, resolveRun, publicRecoveryOptionValue )
import Agentic.Manager.Store
import Agentic.Runtime
import Control.DeepSeq (NFData (rnf))
import Control.Exception (throwIO)
import Control.Monad (forM, forM_, unless, when, void)
import Data.Aeson (FromJSON, Value (..), object, (.=), fromJSON, Result (..))
import Data.Aeson.Types (Pair, parseEither)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL

-- | One atomic read cut, without response or worker authority.
data SnapshotCut = SnapshotCut !RunAssociation !ProjectionCut !Text !Text !Value
  !(Maybe (Text, BS.ByteString)) !(Map.Map Text (Text, Text, Maybe Text))
  !(Map.Map Text (Text, Text))

instance NFData SnapshotCut where
  rnf (SnapshotCut association cut revision supervision verification result decisions commands) =
    rnf (associationRun association, associationProfile association, associationRoot association,
      runIdText (associationNative association)) `seq`
    rnf (cut, revision, supervision, verification, result, decisions, commands)

-- | Complete public fields and occurrence items before bounded page construction.
data SnapshotProjection = SnapshotProjection
  { publicSnapshotRevision :: !Text,
    publicSnapshotFields :: ![Pair],
    publicSnapshotItems :: ![Value]
  }

captureSnapshot :: CredentialProof -> RunAssociation -> Transaction SnapshotCut
captureSnapshot proof association = do
  authorizeObservation proof association
  cut <- captureProjectionCut association
  rows <- query
    "SELECT r.revision,r.supervision,r.result_state,r.result_artifact_id,a.verification_failure,a.private_reference FROM runs r LEFT JOIN artifacts a ON a.id=r.result_artifact_id AND a.run_id=r.id WHERE r.id=?"
    [text (associationRun association)]
  (revision, supervision, verification, result) <- case rows of
    [[SQL.SQLText revision, SQL.SQLText supervision, state, artifact, failure, reference]] -> do
      verification <- either refuseTransaction pure (verificationValue artifact state failure)
      result <- case (artifact, reference) of
        (SQL.SQLNull, SQL.SQLNull) -> pure Nothing
        (SQL.SQLText ident, SQL.SQLBlob bytes) -> pure (Just (ident, bytes))
        _ -> refuseTransaction StoreIntegrity
      pure (revision, supervision, verification, result)
    _ -> refuseTransaction StoreIntegrity
  decisions <- (jsonColumn
    "SELECT json_group_array(json_array(d.occurrence_id,d.id,d.kind,CAST(a.private_reference AS TEXT))) FROM decisions d LEFT JOIN artifacts a ON a.id=d.question_artifact_id AND a.run_id=d.run_id WHERE d.run_id=? AND NOT EXISTS(SELECT 1 FROM decisions n WHERE n.run_id=d.run_id AND n.occurrence_id=d.occurrence_id AND (length(n.observed_sequence)>length(d.observed_sequence) OR (length(n.observed_sequence)=length(d.observed_sequence) AND n.observed_sequence>d.observed_sequence)))"
    [text (associationRun association)] :: Transaction [(Text, Text, Text, Maybe Text)])
  commands <- (jsonColumn
    "SELECT json_group_array(json_array(c.id,c.operation,i.native_command)) FROM control_intents i JOIN commands c ON c.id=i.command_id WHERE i.run_id=?"
    [text (associationRun association)] :: Transaction [(Text, Text, Text)])
  let decisionMap = Map.fromList [(occurrence, (ident, kind, reference)) | (occurrence, ident, kind, reference) <- decisions]
      commandMap = Map.fromList [(ident, (operation, native)) | (ident, operation, native) <- commands]
  unless (Map.size decisionMap == length decisions && Map.size commandMap == length commands)
    (refuseTransaction StoreIntegrity)
  pure (SnapshotCut association cut revision supervision verification result decisionMap commandMap)

jsonColumn :: FromJSON a => Text -> [SQL.SQLData] -> Transaction a
jsonColumn sql parameters = do
  rows <- query sql parameters
  case rows of
    [[SQL.SQLText bytes]] -> case decodeStrictValue (TE.encodeUtf8 bytes) of
      Right value -> case fromJSON value of
        Success parsed -> pure parsed
        Error _ -> refuseTransaction StoreIntegrity
      Left _ -> refuseTransaction StoreIntegrity
    _ -> refuseTransaction StoreIntegrity

withRunSnapshot :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> SnapshotProjection -> IO a) -> IO a
withRunSnapshot store proof ident respond =
  withRunSnapshotSource store proof ident $ \view _ materialize -> materialize >>= respond view

withRunSnapshotSource :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO SnapshotProjection -> IO a) -> IO a
withRunSnapshotSource store proof ident action = do
  association <- resolveRun store proof [Command.Observe] ident
  withAuthorizedResponseLimits store proof (associationProfile association) [Command.Observe] $ \view limits ->
    action view limits $ do
      revalidateAuthorizedView view >>= either throwIO pure
      cut <- runRead store (captureSnapshot proof association)
      projected <- restoreSnapshot store cut
      revalidateAuthorizedView view >>= either throwIO pure
      pure projected

runtimeSummary :: Maybe RunSnapshot -> Either Command.CommandFailure Value
runtimeSummary Nothing = Right Null
runtimeSummary (Just snapshot) = case snapshotLastEnvelope snapshot of
  Nothing -> Right Null
  Just envelope
    | envelopeVersion envelope `elem` supportedProtocolVersions -> Right (object
        ["status" .= runStatusText (snapshotRunStatus snapshot),
         "lastSequence" .= sequenceText envelope, "protocolVersion" .= envelopeVersion envelope])
    | otherwise -> Left Command.UnsupportedVersion

-- | Replay only the captured immutable prefix outside SQL. The caller retains
-- its original reader and configuration loans through materialization and send.
restoreSnapshot :: CoordinationStore -> SnapshotCut -> IO SnapshotProjection
restoreSnapshot store (SnapshotCut association cut revision supervision verification resultBinding decisions commands) = do
  restored <- restoreProjectionCut store cut
  let snapshot = maybe (initialRunSnapshot (associationNative association)) checkpointSnapshot restored
  runtime <- either throwIO pure (runtimeSummary (checkpointSnapshot <$> restored))
  mapM_ (publicText 1024) (snapshotWorkflow snapshot)
  mapM_ (publicText 1024) (snapshotTarget snapshot)
  mapM_ publicNatural (snapshotBillFresh snapshot)
  mapM_ publicNatural (snapshotBillMemo snapshot)
  mapM_ (publicText 4096) (snapshotRunFailure snapshot)
  items <- mapM (publicOccurrence decisions) (Map.elems (snapshotOccurrences snapshot))
  acknowledgements <- mapM (publicAcknowledgement commands) (Map.elems (snapshotControlAcks snapshot))
  result <- case (snapshotResult snapshot, resultBinding) of
    (Nothing, Nothing) -> pure Null
    (Just reference, Just (ident, original)) -> do
      unless (original == Command.encoded reference) (throwIO StoreIntegrity)
      publicIdentifier ident
      void (either (const (throwIO StoreIntegrity)) pure (parseEither answerSchemaForObservationCode (resultArtifactCode reference)))
      publicCodeStrings (resultArtifactCode reference)
      pure (object
        ["artifactId" .= ident, "artifactVersion" .= resultArtifactVersion reference,
         "sha256" .= resultArtifactSha256 reference, "bytes" .= T.pack (show (resultArtifactBytes reference)),
         "code" .= resultArtifactCode reference, "preview" .= resultArtifactPreview reference])
    _ -> throwIO StoreIntegrity
  let fields =
        ["snapshotVersion" .= (1 :: Int), "runId" .= associationRun association,
         "runtime" .= runtime, "workflow" .= snapshotWorkflow snapshot,
         "targetLabel" .= snapshotTarget snapshot, "personAnswering" .= snapshotPersonAnswering snapshot,
         "authoredOrder" .= map occurrenceKey (snapshotAuthoredOrder snapshot),
         "traceRecorded" .= snapshotTraceRecorded snapshot, "controlAcks" .= acknowledgements,
         "billFresh" .= fmap (T.pack . show) (snapshotBillFresh snapshot),
         "billMemo" .= fmap (T.pack . show) (snapshotBillMemo snapshot), "result" .= result,
         "verification" .= verification, "failure" .= snapshotRunFailure snapshot,
         "failureClass" .= fmap failureTextValue (snapshotRunFailureClass snapshot),
         "supervision" .= supervision, "integrity" .= ("unknown" :: Text)]
      size = toInteger (BS.length (Command.encoded (object fields)))
        + sum [toInteger (BS.length (Command.encoded item)) + 1 | item <- items]
  when (size > 67108864) (throwIO Command.ViewTooLarge)
  pure (SnapshotProjection revision fields items)

publicOccurrence :: Map.Map Text (Text, Text, Maybe Text) -> OccurrenceSnapshot -> IO Value
publicOccurrence decisions occurrence = do
  let ident = occurrenceKey (snapshotOccurrenceId occurrence)
      decision = Map.lookup ident decisions
      code = snapshotOccurrenceCode occurrence
  unless (code `elem` ["text", "verdict", "flag", "ack", "structured"])
    (throwIO Command.ResourceUnavailable)
  publicText 1024 (snapshotOccurrenceIntent occurrence)
  publicText 4096 (snapshotOccurrenceAddressee occurrence)
  publicText 524288 (snapshotOccurrencePrompt occurrence)
  mapM_ (publicText 524288) (snapshotOccurrenceAnswer occurrence)
  mapM_ (publicText 1024) (snapshotOccurrenceReuseKind occurrence)
  mapM_ (publicText 4096) (snapshotOccurrenceSource occurrence)
  forM_ decision $ \(decisionId, _, _) -> publicIdentifier decisionId
  forM_ (snapshotOccurrencePersonQuestion occurrence) $ \reference -> case decision of
    Just (_, "question", Just original) | TE.encodeUtf8 original == Command.encoded reference -> pure ()
    _ -> throwIO StoreIntegrity
  dispatch <- traverse publicDispatch (snapshotOccurrenceDispatch occurrence)
  recovery <- traverse publicRecovery (snapshotOccurrenceRecovery occurrence)
  attempts <- mapM publicAttempt (Map.elems (snapshotOccurrenceAttempts occurrence))
  pure (object
    ["occurrenceId" .= ident, "state" .= occurrenceStateText (snapshotOccurrenceState occurrence),
     "code" .= code, "intent" .= snapshotOccurrenceIntent occurrence,
     "addressee" .= snapshotOccurrenceAddressee occurrence, "prompt" .= snapshotOccurrencePrompt occurrence,
     "answer" .= snapshotOccurrenceAnswer occurrence, "dispatch" .= dispatch, "recovery" .= recovery,
     "reuseKind" .= snapshotOccurrenceReuseKind occurrence, "source" .= snapshotOccurrenceSource occurrence,
     "failureClass" .= fmap failureTextValue (snapshotOccurrenceFailureClass occurrence),
     "replayable" .= snapshotOccurrenceReplayable occurrence,
     "decisionId" .= fmap (\(value, _, _) -> value) decision,
     "personPending" .= snapshotOccurrencePersonPending occurrence, "attempts" .= attempts])

publicAttempt :: AttemptSnapshot -> IO Value
publicAttempt attempt = do
  publicText 1024 (snapshotAttemptTarget attempt)
  publicText 65536 (snapshotAttemptOutput attempt)
  mapM_ (publicText 4096) (snapshotAttemptFailure attempt)
  forM_ (snapshotAttemptUsage attempt) $ \usage -> mapM_ publicNatural [publicUsageUsed usage, publicUsageSize usage]
  steers <- forM (snapshotAttemptSteers attempt) $ \steer -> do
    publicIdentifier (steerControlId steer)
    publicText 65536 (steerText steer)
    pure (object ["commandId" .= steerControlId steer, "timing" .= steerTiming steer, "text" .= steerText steer])
  let ident = snapshotAttemptId attempt
  pure (object
    ["address" .= object ["occurrenceId" .= occurrenceKey (attemptOccurrence ident), "attemptId" .= attemptKey ident],
     "targetLabel" .= snapshotAttemptTarget attempt, "state" .= attemptStateText (snapshotAttemptState attempt),
     "output" .= snapshotAttemptOutput attempt, "steers" .= steers,
     "messages" .= snapshotAttemptMessages attempt, "tools" .= Map.elems (snapshotAttemptTools attempt),
     "todos" .= snapshotAttemptTodos attempt, "usage" .= snapshotAttemptUsage attempt,
     "reasoningSummaries" .= snapshotAttemptReasoningSummaries attempt,
     "failure" .= snapshotAttemptFailure attempt, "failureClass" .= fmap failureTextValue (snapshotAttemptFailureClass attempt)])

publicDispatch :: DispatchSnapshot -> IO Value
publicDispatch dispatch = do
  mapM_ (publicText 1024) (dispatchTargets dispatch)
  redirect <- forM (dispatchRedirect dispatch) $ \(command, target) -> do
    publicIdentifier command
    publicText 1024 target
    pure (object ["commandId" .= command, "target" .= target])
  pure (object ["targets" .= dispatchTargets dispatch, "open" .= dispatchOpen dispatch, "redirect" .= redirect])

publicRecovery :: RecoverySnapshot -> IO Value
publicRecovery recovery = do
  publicText 4096 (snapshotRecoveryGap recovery)
  publicText 4096 (snapshotRecoveryMessage recovery)
  when (length (snapshotRecoveryChoices recovery) > 16) (throwIO Command.ViewTooLarge)
  mapM_ publicIdentifier (snapshotRecoveryRetries recovery)
  forM_ (snapshotRecoveryChoices recovery) $ mapM_ (publicText 1024) . recoveryTarget
  chosen <- forM (snapshotRecoveryChosen recovery) $ \choice -> do
    publicIdentifier (chosenControlId choice)
    mapM_ (publicText 1024) (chosenTarget choice)
    pure (object ["commandId" .= chosenControlId choice, "choice" .= chosenChoice choice, "target" .= chosenTarget choice])
  pure (object ["gap" .= snapshotRecoveryGap recovery, "message" .= snapshotRecoveryMessage recovery,
    "retries" .= snapshotRecoveryRetries recovery, "choices" .= map publicRecoveryOptionValue (snapshotRecoveryChoices recovery), "chosen" .= chosen])

publicAcknowledgement :: Map.Map Text (Text, Text) -> ControlAckSnapshot -> IO Value
publicAcknowledgement commands acknowledgement = do
  publicText 4096 (snapshotControlMessage acknowledgement)
  command <- case Map.lookup (snapshotControlId acknowledgement) commands of
    Just (operation, native) -> do
      unless (snapshotControlCommand acknowledgement == Just native) (throwIO StoreIntegrity)
      pure (Just operation)
    Nothing -> case snapshotControlCommand acknowledgement of
      Nothing -> pure Nothing
      Just "invalid" -> pure Nothing
      Just native -> case lookup native
          [("cancelRun", "cancel"), ("steerOccurrence", "steer"), ("retryOccurrence", "retry"),
           ("failoverOccurrence", "choose-recovery"), ("abandonOccurrence", "choose-recovery"),
           ("redirectOccurrence", "redirect"), ("answerPerson", "answer")] of
        Just operation -> pure (Just operation)
        Nothing -> throwIO StoreIntegrity
  let value = object
        ["commandId" .= snapshotControlId acknowledgement, "state" .= snapshotControlState acknowledgement,
         "message" .= snapshotControlMessage acknowledgement, "command" .= command,
         "occurrenceId" .= fmap occurrenceKey (snapshotControlOccurrence acknowledgement),
         "attemptId" .= fmap attemptKey (snapshotControlAttempt acknowledgement)]
  case fromJSON value :: Result Command.Acknowledgement of
    Success checked -> pure (Command.acknowledgementValue checked)
    Error _ -> throwIO Command.ResourceUnavailable

publicText :: Int -> Text -> IO ()
publicText limit value = when (T.length value > limit) (throwIO Command.ViewTooLarge)

publicIdentifier :: Text -> IO ()
publicIdentifier value = unless (Command.validId value) (throwIO Command.ResourceUnavailable)

publicNatural :: Integer -> IO ()
publicNatural value = do
  unless (value >= 0) (throwIO StoreIntegrity)
  publicText 4096 (T.pack (show value))

publicCodeStrings :: Value -> IO ()
publicCodeStrings (String value) = publicText 1024 value
publicCodeStrings (Object fields) = mapM_ publicCodeStrings (KM.elems fields)
publicCodeStrings (Array values) = mapM_ publicCodeStrings values
publicCodeStrings _ = pure ()

text :: Text -> SQL.SQLData
text = SQL.SQLText

occurrenceKey :: OccurrenceId -> Text
occurrenceKey = T.pack . show . occurrenceNumber

attemptKey :: AttemptId -> Text
attemptKey = T.pack . show . attemptNumber

sequenceText :: Envelope -> Text
sequenceText = T.pack . show . sequenceNumber . envelopeSequence
