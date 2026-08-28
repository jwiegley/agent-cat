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
    RuntimeEvent (..),
    Envelope (..),
    SequenceDecision (..),
    EventSink,
    nullEventSink,
    mkRunId,
    descriptorVersion,
    protocolVersion,
    storeVersion,
    maxFrameBytes,
    encodeEnvelope,
    decodeEnvelope,
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
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Object, Pair, Parser)
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
  | OccurrenceStarted !OccurrenceId !Text !Text !Text !Text
  | AttemptStarted !AttemptId !Text
  | AttemptOutput !AttemptId !Text
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
  | TraceOrdered ![OccurrenceId]
  | RunCompleted !Integer !Integer
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

descriptorVersion, protocolVersion, storeVersion :: Int
descriptorVersion = 1
protocolVersion = 1
storeVersion = 1

-- | Bound one NDJSON record before asking aeson to allocate for it.  Transport
-- output is split into smaller events by the writer.
maxFrameBytes :: Int
maxFrameBytes = 1024 * 1024

encodeEnvelope :: Envelope -> ByteString
encodeEnvelope = BL.toStrict . encode

decodeEnvelope :: ByteString -> Either Text Envelope
decodeEnvelope bytes
  | BS.length bytes > maxFrameBytes = Left "runtime protocol frame exceeds 1048576 bytes"
  | otherwise = case eitherDecodeStrict' bytes of
      Left why -> Left (T.pack why)
      Right envelope -> Right envelope

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
    if version /= protocolVersion
      then fail ("unsupported runtime protocol version " <> show (version :: Int))
      else do
        run <- parseRunId =<< o .: "runId"
        sequence' <- parseWord64 "sequence" =<< o .: "sequence"
        timestamp <- o .: "timestamp" >>= parseTimestamp
        event <- o .: "event"
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
    TraceOrdered occurrences ->
      object ["type" .= ("trace.ordered" :: Text), "occurrenceIds" .= map occurrenceText occurrences]
    RunCompleted fresh memo ->
      object ["type" .= ("run.completed" :: Text), "billFresh" .= integerText fresh, "billMemo" .= integerText memo]
    RunFailed failure why ->
      object ["type" .= ("run.failed" :: Text), "failure" .= failureText failure, "message" .= why]
    RunCancelled why ->
      object ["type" .= ("run.cancelled" :: Text), "message" .= why]

instance FromJSON RuntimeEvent where
  parseJSON = withObject "runtime event" parseRuntimeEvent

parseRuntimeEvent :: Object -> Parser RuntimeEvent
parseRuntimeEvent o = do
  eventType <- o .: "type" :: Parser Text
  case eventType of
    "run.started" -> RunStarted <$> o .: "workflow" <*> o .: "target"
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
    "control.ack" -> do
      control <- o .: "controlId" >>= parseControlId
      state <- o .: "state" >>= parseAcknowledgementState
      ControlAcknowledged control state <$> o .: "message"
    "trace.ordered" -> do
      ids <- o .: "occurrenceIds"
      occurrences <- traverse (fmap OccurrenceId . parseWord64 "occurrenceId") ids
      if length (nub occurrences) /= length occurrences
        then fail "trace occurrenceIds are duplicated"
        else pure (TraceOrdered occurrences)
    "run.completed" ->
      RunCompleted
        <$> (parseInteger "billFresh" =<< o .: "billFresh")
        <*> (parseInteger "billMemo" =<< o .: "billMemo")
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
