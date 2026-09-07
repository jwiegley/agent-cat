{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Versioned operational events for machine-supervised agent-cat runs.
--
-- These values describe realization only.  Run, occurrence, and attempt IDs do
-- not enter 'Agentic.Plan.Q', 'Agentic.Plan.Request', or the denotation.
module Agentic.Runtime.Protocol
  ( RunId (..),
    OccurrenceId (..),
    AttemptId (..),
    SeqNo (..),
    FailureClass (..),
    RecoveryOption (..),
    PersonAnswering (..),
    QuestionRef (..),
    ResultRef (..),
    PublicProgress (..),
    PublicToolUpdate (..),
    PublicTodoItem (..),
    PublicUsage (..),
    RuntimeEvent (..),
    Envelope (..),
    SequenceDecision (..),
    EventSink,
    nullEventSink,
    mkRunId,
    protocolVersion,
    latestProtocolVersion,
    storeVersion,
    latestStoreVersion,
    maxFrameBytes,
    maxArtifactBytes,
    encodeEnvelope,
    encodeEnvelopeFor,
    decodeEnvelope,
    decodeEnvelopeFor,
    checkSequence,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value,
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    withText,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Object, Pair, Parser, parseEither)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum, isDigit)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Time.Clock (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Word (Word32, Word64)

newtype RunId = RunId {runIdText :: Text}
  deriving (Eq, Ord, Show)

newtype OccurrenceId = OccurrenceId {occurrenceNumber :: Word64}
  deriving (Eq, Ord, Show)

data AttemptId = AttemptId
  { attemptOccurrence :: !OccurrenceId,
    attemptNumber :: !Word32
  }
  deriving (Eq, Ord, Show)

newtype SeqNo = SeqNo {sequenceNumber :: Word64}
  deriving (Eq, Ord, Show)

data FailureClass
  = FailureSetup
  | FailureTransport
  | FailureDecode
  | FailureProtocol
  | FailureCancelled
  | FailureRuntime
  deriving (Eq, Ord, Show)

data RecoveryOption = RecoveryOption
  { recoveryChoice :: !Text,
    recoveryTarget :: !(Maybe Text)
  }
  deriving (Eq, Show)

instance ToJSON RecoveryOption where
  toJSON option = object (["choice" .= recoveryChoice option] <> maybe [] (\target -> ["target" .= target]) (recoveryTarget option))

instance FromJSON RecoveryOption where
  parseJSON = withObject "recovery option" $ \o -> do
    choice <- o .: "choice" >>= parseRecoveryChoice
    target <- o .:? "target"
    if choice /= "failover" && target /= Nothing
      then fail "only failover recovery may name a target"
      else pure (RecoveryOption choice target)

-- | Who realizes person-addressed questions in one machine run.
data PersonAnswering = PersonAnswerEngine | PersonAnswerLocalControl
  deriving (Eq, Ord, Show)

instance ToJSON PersonAnswering where
  toJSON = toJSON . personAnsweringText

instance FromJSON PersonAnswering where
  parseJSON = withText "person answering mode" parsePersonAnswering

-- | Private full-question artifact made visible by a bounded reference.
data QuestionRef = QuestionRef
  { questionArtifactVersion :: !Int,
    questionArtifactPath :: !Text,
    questionArtifactSha256 :: !Text,
    questionArtifactBytes :: !Integer
  }
  deriving (Eq, Show)

-- | Private final-result artifact installed before successful completion.
data ResultRef = ResultRef
  { resultArtifactVersion :: !Int,
    resultArtifactPath :: !Text,
    resultArtifactSha256 :: !Text,
    resultArtifactBytes :: !Integer,
    resultArtifactCode :: !Value,
    resultArtifactPreview :: !Text
  }
  deriving (Eq, Show)

instance ToJSON QuestionRef where
  toJSON reference =
    object
      [ "artifactVersion" .= questionArtifactVersion reference,
        "path" .= questionArtifactPath reference,
        "sha256" .= questionArtifactSha256 reference,
        "bytes" .= integerText (questionArtifactBytes reference)
      ]

instance FromJSON QuestionRef where
  parseJSON = withObject "question artifact reference" $ \o -> do
    reference <-
      QuestionRef
        <$> o .: "artifactVersion"
        <*> o .: "path"
        <*> o .: "sha256"
        <*> (parseInteger "question artifact bytes" =<< o .: "bytes")
    validateQuestionRef reference

instance ToJSON ResultRef where
  toJSON reference =
    object
      [ "artifactVersion" .= resultArtifactVersion reference,
        "path" .= resultArtifactPath reference,
        "sha256" .= resultArtifactSha256 reference,
        "bytes" .= integerText (resultArtifactBytes reference),
        "code" .= resultArtifactCode reference,
        "preview" .= resultArtifactPreview reference
      ]

instance FromJSON ResultRef where
  parseJSON = withObject "result artifact reference" $ \o -> do
    reference <-
      ResultRef
        <$> o .: "artifactVersion"
        <*> o .: "path"
        <*> o .: "sha256"
        <*> (parseInteger "result artifact bytes" =<< o .: "bytes")
        <*> o .: "code"
        <*> o .: "preview"
    validateResultRef reference

-- | Public presentation data emitted by an engine outside its answer bytes.
data PublicProgress
  = ProgressMessage !Text
  | ProgressTool !PublicToolUpdate
  | ProgressTodos ![PublicTodoItem]
  | ProgressUsage !PublicUsage
  | ProgressReasoningSummary !Text
  deriving (Eq, Show)

-- | One bounded tool-state patch keyed by the transport's stable call id.
data PublicToolUpdate = PublicToolUpdate
  { publicToolId :: !Text,
    publicToolTitle :: !(Maybe Text),
    publicToolKind :: !(Maybe Text),
    publicToolStatus :: !(Maybe Text),
    publicToolSummary :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | One entry in an authoritative public todo snapshot.
data PublicTodoItem = PublicTodoItem
  { publicTodoContent :: !Text,
    publicTodoPriority :: !Text,
    publicTodoStatus :: !Text
  }
  deriving (Eq, Show)

-- | Cumulative public context-window usage.
data PublicUsage = PublicUsage
  { publicUsageUsed :: !Integer,
    publicUsageSize :: !Integer
  }
  deriving (Eq, Show)

instance ToJSON PublicProgress where
  toJSON = \case
    ProgressMessage text -> object ["kind" .= ("message" :: Text), "text" .= text]
    ProgressTool tool -> object ["kind" .= ("tool" :: Text), "tool" .= tool]
    ProgressTodos todos -> object ["kind" .= ("todos" :: Text), "items" .= todos]
    ProgressUsage usage -> object ["kind" .= ("usage" :: Text), "usage" .= usage]
    ProgressReasoningSummary text -> object ["kind" .= ("reasoning-summary" :: Text), "text" .= text]

instance FromJSON PublicProgress where
  parseJSON = withObject "public progress" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "message" -> ProgressMessage <$> (o .: "text" >>= boundedProgressText "message" 4096)
      "tool" -> ProgressTool <$> o .: "tool"
      "todos" -> do
        items <- o .: "items"
        if length items > 128 then fail "public todo snapshot exceeds 128 entries" else pure (ProgressTodos items)
      "usage" -> ProgressUsage <$> o .: "usage"
      "reasoning-summary" -> ProgressReasoningSummary <$> (o .: "text" >>= boundedProgressText "reasoning summary" 4096)
      _ -> fail ("unknown public progress kind " <> T.unpack kind)

instance ToJSON PublicToolUpdate where
  toJSON tool =
    object
      ( ["id" .= publicToolId tool]
          <> maybe [] (\value -> ["title" .= value]) (publicToolTitle tool)
          <> maybe [] (\value -> ["toolKind" .= value]) (publicToolKind tool)
          <> maybe [] (\value -> ["status" .= value]) (publicToolStatus tool)
          <> maybe [] (\value -> ["summary" .= value]) (publicToolSummary tool)
      )

instance FromJSON PublicToolUpdate where
  parseJSON = withObject "public tool update" $ \o -> do
    identifier <- o .: "id" >>= boundedProgressId "tool id"
    title <- traverse (boundedProgressText "tool title" 1024) =<< o .:? "title"
    kind <- traverse (boundedProgressText "tool kind" 128) =<< o .:? "toolKind"
    status <- traverse parseToolStatus =<< o .:? "status"
    summary <- traverse (boundedProgressText "tool summary" 4096) =<< o .:? "summary"
    pure (PublicToolUpdate identifier title kind status summary)

instance ToJSON PublicTodoItem where
  toJSON item = object ["content" .= publicTodoContent item, "priority" .= publicTodoPriority item, "status" .= publicTodoStatus item]

instance FromJSON PublicTodoItem where
  parseJSON = withObject "public todo item" $ \o ->
    PublicTodoItem
      <$> (o .: "content" >>= boundedProgressText "todo content" 1024)
      <*> (o .: "priority" >>= parseTodoPriority)
      <*> (o .: "status" >>= parseTodoStatus)

instance ToJSON PublicUsage where
  toJSON usage = object ["used" .= integerText (publicUsageUsed usage), "size" .= integerText (publicUsageSize usage)]

instance FromJSON PublicUsage where
  parseJSON = withObject "public usage" $ \o -> do
    used <- parseNatural "usage used" =<< o .: "used"
    size <- parseNatural "usage size" =<< o .: "size"
    if size <= 0 || used > size then fail "public usage is outside its context window" else pure (PublicUsage used size)

boundedProgressText :: String -> Int -> Text -> Parser Text
boundedProgressText label limit value
  | T.null value = fail (label <> " is empty")
  | T.length value > limit = fail (label <> " exceeds " <> show limit <> " characters")
  | otherwise = pure value

boundedProgressId :: String -> Text -> Parser Text
boundedProgressId label value
  | T.null value || T.length value > 128 = fail (label <> " is empty or too long")
  | T.all (\character -> isAlphaNum character || character `elem` ("._:-" :: String)) value = pure value
  | otherwise = fail (label <> " contains an invalid character")

parseToolStatus :: Text -> Parser Text
parseToolStatus value
  | value `elem` ["pending", "in_progress", "completed", "failed", "cancelled"] = pure value
  | otherwise = fail ("unknown public tool status " <> T.unpack value)

parseTodoPriority :: Text -> Parser Text
parseTodoPriority value
  | value `elem` ["high", "medium", "low"] = pure value
  | otherwise = fail ("unknown public todo priority " <> T.unpack value)

parseTodoStatus :: Text -> Parser Text
parseTodoStatus value
  | value `elem` ["pending", "in_progress", "completed"] = pure value
  | otherwise = fail ("unknown public todo status " <> T.unpack value)

parseRecoveryChoice :: Text -> Parser Text
parseRecoveryChoice choice
  | choice `elem` ["retry", "failover", "abandon"] = pure choice
  | otherwise = fail ("unknown recovery choice " <> T.unpack choice)

parseSteeringTiming :: Text -> Parser Text
parseSteeringTiming timing
  | timing `elem` ["interrupt-now", "next-boundary"] = pure timing
  | otherwise = fail ("unknown steering timing " <> T.unpack timing)

parseAcknowledgementState :: Text -> Parser Text
parseAcknowledgementState state
  | state `elem` ["accepted", "queued", "delivered", "rejected-stale", "unsupported", "failed"] = pure state
  | otherwise = fail ("unknown control acknowledgement state " <> T.unpack state)

parseControlId :: Text -> Parser Text
parseControlId control
  | T.null control = fail "runtime control id is empty"
  | T.length control > 128 = fail "runtime control id exceeds 128 characters"
  | T.all (\c -> isAlphaNum c || c `elem` ("._-" :: String)) control = pure control
  | otherwise = fail "runtime control id contains an invalid character"

-- | Facts emitted by the existing interpreter and its transports.
--
-- Sequence order is chronology.  'TraceOrdered' supplies authored order after
-- the interpreter has collected its tickets.
data RuntimeEvent
  = RunStarted !Text !Text
  | RunStartedV2 !Text !Text !PersonAnswering
  | OccurrenceStarted !OccurrenceId !Text !Text !Text !Text
  | AttemptStarted !AttemptId !Text
  | AttemptOutput !AttemptId !Text
  | AttemptProgress !AttemptId !PublicProgress
  | AttemptSteered !AttemptId !Text !Text !Text
  | AttemptCompleted !AttemptId !Text
  | AttemptFailed !AttemptId !FailureClass !Text
  | OccurrenceReused !OccurrenceId !Text
  | OccurrenceRecoveryPending !OccurrenceId !Text !Text ![RecoveryOption]
  | OccurrenceRetried !OccurrenceId !Text
  | OccurrenceRecoveryChosen !OccurrenceId !Text !Text !(Maybe Text)
  | OccurrenceDispatchPending !OccurrenceId ![Text]
  | OccurrenceRedirected !OccurrenceId !Text !Text
  | OccurrenceCompleted !OccurrenceId !Text !Text
  | OccurrenceFailed !OccurrenceId !FailureClass !Text
  | ControlAcknowledged !Text !Text !Text
  | ControlAcknowledgedV2 !Text !Text !Text !Text !(Maybe OccurrenceId) !(Maybe AttemptId)
  | OccurrencePersonAnswerPending !OccurrenceId !QuestionRef
  | TraceOrdered ![OccurrenceId]
  | RunCompleted !Integer !Integer
  | RunCompletedV2 !Integer !Integer !ResultRef
  | RunFailed !FailureClass !Text
  | RunCancelled !Text
  deriving (Eq, Show)

data Envelope = Envelope
  { envelopeVersion :: !Int,
    envelopeRunId :: !RunId,
    envelopeSequence :: !SeqNo,
    envelopeTimestamp :: !Text,
    envelopeEvent :: !RuntimeEvent
  }
  deriving (Eq, Show)

data SequenceDecision = SequenceNext
  deriving (Eq, Show)

type EventSink = RuntimeEvent -> IO ()

nullEventSink :: EventSink
nullEventSink _ = pure ()

protocolVersion, latestProtocolVersion, storeVersion, latestStoreVersion :: Int
protocolVersion = 1
latestProtocolVersion = 2
storeVersion = 1
latestStoreVersion = 2

-- | Bound one NDJSON record before asking aeson to allocate for it.  Transport
-- output is split into smaller events by the writer.
maxFrameBytes :: Int
maxFrameBytes = 1024 * 1024

maxArtifactBytes :: Integer
maxArtifactBytes = 64 * 1024 * 1024

encodeEnvelope :: Envelope -> ByteString
encodeEnvelope = BL.toStrict . encode

encodeEnvelopeFor :: Int -> Envelope -> Either Text ByteString
encodeEnvelopeFor version envelope
  | version `notElem` [protocolVersion, latestProtocolVersion] = Left ("unsupported runtime protocol version " <> T.pack (show version))
  | envelopeVersion envelope /= version = Left "runtime envelope version does not match selected protocol"
  | not (eventSupported version (envelopeEvent envelope)) = Left "runtime event is not available in selected protocol"
  | Left failure <- validateRuntimeEventFor version (envelopeEvent envelope) = Left ("runtime event is invalid: " <> failure)
  | BS.length bytes > maxFrameBytes = Left "runtime protocol event exceeds 1048576 bytes"
  | otherwise = Right bytes
  where
    bytes = encodeEnvelope envelope

validateRuntimeEventFor :: Int -> RuntimeEvent -> Either Text ()
validateRuntimeEventFor version event@AttemptProgress {} =
  case parseEither (parseRuntimeEventFor version) (toJSON event) of
    Left failure -> Left (T.pack failure)
    Right parsed
      | parsed == event -> Right ()
      | otherwise -> Left "runtime event changed during validation"
validateRuntimeEventFor _ _ = Right ()

decodeEnvelope :: ByteString -> Either Text Envelope
decodeEnvelope = decodeEnvelopeFor [protocolVersion]

decodeEnvelopeFor :: [Int] -> ByteString -> Either Text Envelope
decodeEnvelopeFor accepted bytes
  | BS.length bytes > maxFrameBytes = Left "runtime protocol frame exceeds 1048576 bytes"
  | otherwise = do
      value <- either (Left . T.pack) Right (eitherDecodeStrict' bytes :: Either String Value)
      version <-
        either (Left . T.pack) Right $
          parseEither (withObject "runtime envelope" (\o -> o .: "protocolVersion")) value
      if version `notElem` accepted
        then Left ("unsupported runtime protocol version " <> T.pack (show (version :: Int)))
        else either (Left . T.pack) Right (parseEither parseJSON value)

-- | Check one append against the previously accepted envelope.  Duplicates,
-- gaps, regressions, cross-run records, and conflicting records are corruption.
checkSequence :: Maybe Envelope -> Envelope -> Either Text SequenceDecision
checkSequence Nothing next
  | envelopeSequence next == SeqNo 0 = Right SequenceNext
  | otherwise = Left "runtime protocol first sequence is not 0"
checkSequence (Just previous) next
  | envelopeVersion previous /= envelopeVersion next = Left "runtime protocol version changed within one run"
  | envelopeRunId previous /= envelopeRunId next = Left "runtime protocol run id changed within one stream"
  | envelopeSequence next == envelopeSequence previous,
    next == previous = Left "runtime protocol duplicate sequence is refused"
  | envelopeSequence next == envelopeSequence previous = Left "runtime protocol sequence has a conflicting duplicate"
  | envelopeSequence previous == SeqNo maxBound = Left "runtime protocol sequence counter is exhausted"
  | envelopeSequence next < envelopeSequence previous = Left "runtime protocol sequence regressed"
  | envelopeSequence next == succSeq (envelopeSequence previous) = Right SequenceNext
  | otherwise = Left "runtime protocol sequence has a gap"
  where
    succSeq (SeqNo n) = SeqNo (n + 1)

instance ToJSON Envelope where
  toJSON envelope =
    object
      [ "protocolVersion" .= envelopeVersion envelope,
        "runId" .= runIdText (envelopeRunId envelope),
        "sequence" .= word64Text (sequenceNumber (envelopeSequence envelope)),
        "timestamp" .= envelopeTimestamp envelope,
        "event" .= envelopeEvent envelope
      ]

instance FromJSON Envelope where
  parseJSON = withObject "runtime envelope" $ \o -> do
    version <- o .: "protocolVersion"
    if version `notElem` [protocolVersion, latestProtocolVersion]
      then fail ("unsupported runtime protocol version " <> show (version :: Int))
      else do
        run <- parseRunId =<< o .: "runId"
        sequence' <- parseWord64 "sequence" =<< o .: "sequence"
        timestamp <- o .: "timestamp" >>= parseTimestamp
        eventValue <- o .: "event"
        event <- parseRuntimeEventFor version eventValue
        pure (Envelope version run (SeqNo sequence') timestamp event)

parseTimestamp :: Text -> Parser Text
parseTimestamp timestamp
  | not (canonicalTimestamp timestamp) = fail "runtime timestamp is not canonical UTC ISO-8601"
  | otherwise = case parseTimeM True defaultTimeLocale "%FT%T%QZ" (T.unpack timestamp) :: Maybe UTCTime of
      Just _ -> pure timestamp
      Nothing -> fail "runtime timestamp is not canonical UTC ISO-8601"

canonicalTimestamp :: Text -> Bool
canonicalTimestamp timestamp =
  T.length timestamp >= 20
    && T.all isDigit (T.take 4 timestamp)
    && T.index timestamp 4 == '-'
    && T.all isDigit (T.take 2 (T.drop 5 timestamp))
    && T.index timestamp 7 == '-'
    && T.all isDigit (T.take 2 (T.drop 8 timestamp))
    && T.index timestamp 10 == 'T'
    && T.all isDigit (T.take 2 (T.drop 11 timestamp))
    && T.index timestamp 13 == ':'
    && T.all isDigit (T.take 2 (T.drop 14 timestamp))
    && T.index timestamp 16 == ':'
    && T.all isDigit (T.take 2 (T.drop 17 timestamp))
    && case T.drop 19 timestamp of
      "Z" -> True
      suffix -> T.length suffix >= 3 && T.head suffix == '.' && T.last suffix == 'Z' && T.all isDigit (T.init (T.tail suffix))

instance ToJSON RuntimeEvent where
  toJSON = \case
    RunStarted workflow target ->
      object ["type" .= ("run.started" :: Text), "workflow" .= workflow, "target" .= target]
    RunStartedV2 workflow target personAnswering ->
      object
        [ "type" .= ("run.started" :: Text),
          "workflow" .= workflow,
          "target" .= target,
          "personAnswering" .= personAnsweringText personAnswering
        ]
    OccurrenceStarted occurrence code intent addressee prompt ->
      object
        [ "type" .= ("occurrence.started" :: Text),
          "occurrenceId" .= occurrenceText occurrence,
          "code" .= code,
          "intent" .= intent,
          "addressee" .= addressee,
          "prompt" .= prompt
        ]
    AttemptStarted attempt target ->
      attemptObject "attempt.started" attempt ["target" .= target]
    AttemptOutput attempt chunk ->
      attemptObject "attempt.output" attempt ["stream" .= ("transport-text" :: Text), "chunk" .= chunk]
    AttemptProgress attempt progress ->
      attemptObject "attempt.progress" attempt ["progress" .= progress]
    AttemptSteered attempt control timing text ->
      attemptObject
        "attempt.steered"
        attempt
        ["controlId" .= control, "timing" .= timing, "text" .= text]
    AttemptCompleted attempt source ->
      attemptObject "attempt.completed" attempt ["source" .= source]
    AttemptFailed attempt failure why ->
      attemptObject "attempt.failed" attempt ["failure" .= failureText failure, "message" .= why]
    OccurrenceReused occurrence answerGroup ->
      occurrenceObject "occurrence.reused" occurrence ["answerGroup" .= answerGroup]
    OccurrenceRecoveryPending occurrence gap why choices ->
      occurrenceObject "occurrence.recovery-pending" occurrence ["gap" .= gap, "message" .= why, "choices" .= choices]
    OccurrenceRetried occurrence control ->
      occurrenceObject "occurrence.retried" occurrence ["controlId" .= control]
    OccurrenceRecoveryChosen occurrence control choice target ->
      occurrenceObject "occurrence.recovery-chosen" occurrence (["controlId" .= control, "choice" .= choice] <> maybe [] (\selected -> ["target" .= selected]) target)
    OccurrenceDispatchPending occurrence targets ->
      occurrenceObject "occurrence.dispatch-pending" occurrence ["targets" .= targets]
    OccurrenceRedirected occurrence control target ->
      occurrenceObject "occurrence.redirected" occurrence ["controlId" .= control, "target" .= target]
    OccurrenceCompleted occurrence source answer ->
      occurrenceObject "occurrence.completed" occurrence ["source" .= source, "answer" .= answer]
    OccurrenceFailed occurrence failure why ->
      occurrenceObject "occurrence.failed" occurrence ["failure" .= failureText failure, "message" .= why]
    ControlAcknowledged control state message ->
      object
        [ "type" .= ("control.ack" :: Text),
          "controlId" .= control,
          "state" .= state,
          "message" .= message
        ]
    ControlAcknowledgedV2 control state message command occurrence attempt ->
      object
        [ "type" .= ("control.ack" :: Text),
          "controlId" .= control,
          "state" .= state,
          "message" .= message,
          "command" .= command,
          "occurrenceId" .= fmap occurrenceText occurrence,
          "attemptId" .= fmap attemptValue attempt
        ]
    OccurrencePersonAnswerPending occurrence reference ->
      occurrenceObject "occurrence.person-answer-pending" occurrence ["question" .= reference]
    TraceOrdered occurrences ->
      object ["type" .= ("trace.ordered" :: Text), "occurrenceIds" .= map occurrenceText occurrences]
    RunCompleted fresh memo ->
      object ["type" .= ("run.completed" :: Text), "billFresh" .= integerText fresh, "billMemo" .= integerText memo]
    RunCompletedV2 fresh memo result ->
      object ["type" .= ("run.completed" :: Text), "billFresh" .= integerText fresh, "billMemo" .= integerText memo, "result" .= result]
    RunFailed failure why ->
      object ["type" .= ("run.failed" :: Text), "failure" .= failureText failure, "message" .= why]
    RunCancelled why ->
      object ["type" .= ("run.cancelled" :: Text), "message" .= why]

instance FromJSON RuntimeEvent where
  parseJSON = parseRuntimeEventFor protocolVersion

parseRuntimeEventFor :: Int -> Value -> Parser RuntimeEvent
parseRuntimeEventFor version = withObject "runtime event" $ \o -> do
  eventType <- o .: "type" :: Parser Text
  case eventType of
    "run.started"
      | version == protocolVersion -> RunStarted <$> o .: "workflow" <*> o .: "target"
      | otherwise -> RunStartedV2 <$> o .: "workflow" <*> o .: "target" <*> (o .: "personAnswering" >>= parsePersonAnswering)
    "occurrence.started" ->
      OccurrenceStarted
        <$> occurrenceFrom o
        <*> o .: "code"
        <*> o .: "intent"
        <*> o .: "addressee"
        <*> o .: "prompt"
    "attempt.started" -> AttemptStarted <$> attemptFrom o <*> o .: "target"
    "attempt.output" -> do
      stream <- o .: "stream" :: Parser Text
      if stream /= "transport-text"
        then fail ("unknown attempt output stream " <> T.unpack stream)
        else AttemptOutput <$> attemptFrom o <*> o .: "chunk"
    "attempt.progress"
      | version == latestProtocolVersion -> AttemptProgress <$> attemptFrom o <*> o .: "progress"
      | otherwise -> fail "attempt progress is unavailable in protocol version 1"
    "attempt.steered" -> do
      attempt <- attemptFrom o
      control <- o .: "controlId" >>= parseControlId
      timing <- o .: "timing" >>= parseSteeringTiming
      AttemptSteered attempt control timing <$> o .: "text"
    "attempt.completed" -> AttemptCompleted <$> attemptFrom o <*> o .: "source"
    "attempt.failed" -> AttemptFailed <$> attemptFrom o <*> failureFrom o <*> o .: "message"
    "occurrence.reused" -> OccurrenceReused <$> occurrenceFrom o <*> o .: "answerGroup"
    "occurrence.recovery-pending" -> do
      occurrence <- occurrenceFrom o
      gap <- o .: "gap"
      message <- o .: "message"
      choices <- o .: "choices"
      if null choices || length (nub (map recoveryChoice choices)) /= length choices
        then fail "recovery choices are empty or duplicated"
        else pure (OccurrenceRecoveryPending occurrence gap message choices)
    "occurrence.retried" -> OccurrenceRetried <$> occurrenceFrom o <*> (o .: "controlId" >>= parseControlId)
    "occurrence.recovery-chosen" -> do
      occurrence <- occurrenceFrom o
      control <- o .: "controlId" >>= parseControlId
      choice <- o .: "choice" >>= parseRecoveryChoice
      target <- o .:? "target"
      if choice /= "failover" && target /= Nothing
        then fail "only failover recovery may name a target"
        else pure (OccurrenceRecoveryChosen occurrence control choice target)
    "occurrence.dispatch-pending" -> do
      occurrence <- occurrenceFrom o
      targets <- o .: "targets"
      if null targets || length (nub targets) /= length targets
        then fail "dispatch targets are empty or duplicated"
        else pure (OccurrenceDispatchPending occurrence targets)
    "occurrence.redirected" -> OccurrenceRedirected <$> occurrenceFrom o <*> (o .: "controlId" >>= parseControlId) <*> o .: "target"
    "occurrence.completed" -> OccurrenceCompleted <$> occurrenceFrom o <*> o .: "source" <*> o .: "answer"
    "occurrence.failed" -> OccurrenceFailed <$> occurrenceFrom o <*> failureFrom o <*> o .: "message"
    "occurrence.person-answer-pending"
      | version == latestProtocolVersion -> OccurrencePersonAnswerPending <$> occurrenceFrom o <*> o .: "question"
      | otherwise -> fail "person answer event is unavailable in protocol version 1"
    "control.ack" -> do
      control <- o .: "controlId" >>= parseControlId
      state <- o .: "state" >>= parseAcknowledgementState
      message <- o .: "message"
      if version == protocolVersion
        then pure (ControlAcknowledged control state message)
        else
          ControlAcknowledgedV2 control state message
            <$> (o .: "command" >>= parseControlCommandName)
            <*> (traverse (fmap OccurrenceId . parseWord64 "occurrenceId") =<< o .:? "occurrenceId")
            <*> (traverse parseAttemptValue =<< o .:? "attemptId")
    "trace.ordered" -> do
      ids <- o .: "occurrenceIds"
      occurrences <- traverse (fmap OccurrenceId . parseWord64 "occurrenceId") ids
      if length (nub occurrences) /= length occurrences
        then fail "trace occurrenceIds are duplicated"
        else pure (TraceOrdered occurrences)
    "run.completed"
      | version == protocolVersion ->
          RunCompleted
            <$> (parseInteger "billFresh" =<< o .: "billFresh")
            <*> (parseInteger "billMemo" =<< o .: "billMemo")
      | otherwise ->
          RunCompletedV2
            <$> (parseInteger "billFresh" =<< o .: "billFresh")
            <*> (parseInteger "billMemo" =<< o .: "billMemo")
            <*> o .: "result"
    "run.failed" -> RunFailed <$> failureFrom o <*> o .: "message"
    "run.cancelled" -> RunCancelled <$> o .: "message"
    _ -> fail ("unknown runtime event type " <> T.unpack eventType)

occurrenceFrom :: Object -> Parser OccurrenceId
occurrenceFrom o = OccurrenceId <$> (parseWord64 "occurrenceId" =<< o .: "occurrenceId")

attemptFrom :: Object -> Parser AttemptId
attemptFrom o =
  AttemptId
    <$> occurrenceFrom o
    <*> (parseWord32 "attempt" =<< o .: "attempt")

parseAttemptValue :: Value -> Parser AttemptId
parseAttemptValue = withObject "runtime attempt id" $ \o ->
  AttemptId
    <$> (OccurrenceId <$> (parseWord64 "attempt occurrenceId" =<< o .: "occurrenceId"))
    <*> (parseWord32 "attemptNumber" =<< o .: "attemptNumber")

failureFrom :: Object -> Parser FailureClass
failureFrom o = do
  word <- o .: "failure"
  maybe (fail ("unknown runtime failure class " <> T.unpack word)) pure (failureOfText word)

attemptObject :: Text -> AttemptId -> [Pair] -> Value
attemptObject eventType attempt fields =
  object
    ( [ "type" .= eventType,
        "occurrenceId" .= occurrenceText (attemptOccurrence attempt),
        "attempt" .= word32Text (attemptNumber attempt)
      ]
        <> fields
    )

attemptValue :: AttemptId -> Value
attemptValue attempt =
  object
    [ "occurrenceId" .= occurrenceText (attemptOccurrence attempt),
      "attemptNumber" .= word32Text (attemptNumber attempt)
    ]

occurrenceObject :: Text -> OccurrenceId -> [Pair] -> Value
occurrenceObject eventType occurrence fields =
  object (["type" .= eventType, "occurrenceId" .= occurrenceText occurrence] <> fields)

word64Text :: Word64 -> Text
word64Text = T.pack . show

word32Text :: Word32 -> Text
word32Text = T.pack . show

integerText :: Integer -> Text
integerText = T.pack . show

occurrenceText :: OccurrenceId -> Text
occurrenceText = word64Text . occurrenceNumber

mkRunId :: Text -> Either Text RunId
mkRunId t
  | T.null t = Left "runtime protocol run id is empty"
  | T.length t > 128 = Left "runtime protocol run id exceeds 128 characters"
  | T.all allowed t = Right (RunId t)
  | otherwise = Left "runtime protocol run id contains an invalid character"
  where
    allowed c = isAlphaNum c || c `elem` ("._-" :: String)

parseRunId :: Text -> Parser RunId
parseRunId = either (fail . T.unpack) pure . mkRunId

parseWord64 :: String -> Text -> Parser Word64
parseWord64 label t = do
  n <- parseNatural label t
  if n <= toInteger (maxBound :: Word64)
    then pure (fromInteger n)
    else fail ("runtime protocol " <> label <> " exceeds Word64")

parseWord32 :: String -> Text -> Parser Word32
parseWord32 label t = do
  n <- parseNatural label t
  if n <= toInteger (maxBound :: Word32)
    then pure (fromInteger n)
    else fail ("runtime protocol " <> label <> " exceeds Word32")

parseInteger :: String -> Text -> Parser Integer
parseInteger = parseNatural

parseNatural :: String -> Text -> Parser Integer
parseNatural label t = case TR.decimal t of
  Right (n, rest) | T.null rest -> pure n
  _ -> fail ("runtime protocol " <> label <> " is not an unsigned decimal string")

parsePersonAnswering :: Text -> Parser PersonAnswering
parsePersonAnswering "engine" = pure PersonAnswerEngine
parsePersonAnswering "local-control" = pure PersonAnswerLocalControl
parsePersonAnswering other = fail ("unknown person answering mode " <> T.unpack other)

personAnsweringText :: PersonAnswering -> Text
personAnsweringText PersonAnswerEngine = "engine"
personAnsweringText PersonAnswerLocalControl = "local-control"

parseControlCommandName :: Text -> Parser Text
parseControlCommandName command
  | command `elem` ["cancelRun", "steerOccurrence", "retryOccurrence", "failoverOccurrence", "abandonOccurrence", "redirectOccurrence", "answerPerson", "invalid"] = pure command
  | otherwise = fail ("unknown runtime control command " <> T.unpack command)

validateQuestionRef :: QuestionRef -> Parser QuestionRef
validateQuestionRef reference = do
  unlessP (questionArtifactVersion reference == 1) "unsupported question artifact version"
  unlessP (validQuestionPath (questionArtifactPath reference)) "invalid question artifact path"
  validateDigest (questionArtifactSha256 reference)
  validateArtifactBytes (questionArtifactBytes reference)
  pure reference

validateResultRef :: ResultRef -> Parser ResultRef
validateResultRef reference = do
  unlessP (resultArtifactVersion reference == 1) "unsupported result artifact version"
  unlessP (resultArtifactPath reference == "result.json") "invalid result artifact path"
  validateDigest (resultArtifactSha256 reference)
  validateArtifactBytes (resultArtifactBytes reference)
  unlessP (T.length (resultArtifactPreview reference) <= 500 && not (T.any (`elem` ['\n', '\r']) (resultArtifactPreview reference))) "invalid result artifact preview"
  pure reference

validQuestionPath :: Text -> Bool
validQuestionPath path =
  case T.stripPrefix "person/questions/" path >>= T.stripSuffix ".json" of
    Just occurrence -> not (T.null occurrence) && T.all isDigit occurrence
    Nothing -> False

validateDigest :: Text -> Parser ()
validateDigest digest =
  unlessP (T.length digest == 64 && T.all (\c -> isDigit c || c `elem` ['a' .. 'f']) digest) "invalid artifact SHA-256"

validateArtifactBytes :: Integer -> Parser ()
validateArtifactBytes bytes =
  unlessP (bytes > 0 && bytes <= maxArtifactBytes) "artifact byte count is outside the supported bound"

unlessP :: Bool -> String -> Parser ()
unlessP condition message = if condition then pure () else fail message

eventSupported :: Int -> RuntimeEvent -> Bool
eventSupported version event
  | version == protocolVersion = case event of
      RunStartedV2 {} -> False
      ControlAcknowledgedV2 {} -> False
      OccurrencePersonAnswerPending {} -> False
      AttemptProgress {} -> False
      RunCompletedV2 {} -> False
      _ -> True
  | version == latestProtocolVersion = case event of
      RunStarted {} -> False
      ControlAcknowledged {} -> False
      RunCompleted {} -> False
      _ -> True
  | otherwise = False

failureText :: FailureClass -> Text
failureText = \case
  FailureSetup -> "setup"
  FailureTransport -> "transport"
  FailureDecode -> "decode"
  FailureProtocol -> "protocol"
  FailureCancelled -> "cancelled"
  FailureRuntime -> "runtime"

failureOfText :: Text -> Maybe FailureClass
failureOfText = \case
  "setup" -> Just FailureSetup
  "transport" -> Just FailureTransport
  "decode" -> Just FailureDecode
  "protocol" -> Just FailureProtocol
  "cancelled" -> Just FailureCancelled
  "runtime" -> Just FailureRuntime
  _ -> Nothing
