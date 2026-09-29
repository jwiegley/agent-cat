{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Engine-neutral boundary between runtime policy and concrete transports.
module Agentic.Engine
  ( Engine (..),
    ConcurrentEngine,
    EngineConversation (..),
    EngineContext (..),
    EngineUpdateSink,
    EngineUpdate (..),
    EngineToolUpdate (..),
    EngineTodoItem (..),
    EngineUsage (..),
    EnginePermissionReport (..),
    EnginePermissionAnswer (..),
    EngineSteerer,
    EngineSteering (..),
    steeringName,
    EngineRequest (..),
    EngineIntent (..),
    intentName,
    EngineAnswerKind (..),
    answerKindName,
    EngineResult (..),
    EngineCompletion (..),
    EngineError (..),
    EngineFailureKind (..),
    ModelConfig (..),
    Thinking (..),
    thinkingName,
    TurnLane (..),
    newTurnLaneIO,
    concurrentEngine,

    -- * Versioned value codecs
    engineCodecVersion,
    encodeEngineRequest,
    decodeEngineRequest,
    encodeEngineResult,
    decodeEngineResult,
    encodeEngineSteering,
    decodeEngineSteering,
    encodeEnginePermissionReport,
    decodeEnginePermissionReport,
  )
where

import Control.Concurrent.STM (TMVar, TVar, newTMVarIO, newTVarIO)
import Control.Exception (Exception (displayException))
import Data.Aeson (FromJSON (parseJSON), Key, Value (..), object, withText, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR

-- | Optional public progress emitted during one physical attempt.
type EngineUpdateSink = EngineUpdate -> IO ()

-- | Typed stream facts from one engine turn; answer bytes remain explicit.
data EngineUpdate
  = EngineAnswerChunk !Text
  | EnginePublicMessage !Text
  | EngineToolProgress !EngineToolUpdate
  | EngineTodoSnapshot ![EngineTodoItem]
  | EngineUsageProgress !EngineUsage
  | EnginePublicReasoningSummary !Text
  | -- | A permission request that the adapter answered during this turn. It is
    -- not public progress.
    EnginePermission !EnginePermissionReport
  deriving (Eq, Show)

-- | One permission request from an agent, as its adapter answered it during
-- the active turn: the question under way, the tool call that the agent asked
-- for, and the answer.
data EnginePermissionReport = EnginePermissionReport
  { enginePermissionQuestion :: !Text,
    enginePermissionTool :: !Text,
    enginePermissionAnswer :: !EnginePermissionAnswer
  }
  deriving (Eq, Show)

-- | A grant names the option that the adapter selected. A refusal selects none.
data EnginePermissionAnswer
  = EnginePermissionGranted !Text
  | EnginePermissionRefused
  deriving (Eq, Show)

-- | One bounded patch to a transport tool call, keyed by its stable id.
data EngineToolUpdate = EngineToolUpdate
  { engineToolId :: !Text,
    engineToolTitle :: !(Maybe Text),
    engineToolKind :: !(Maybe Text),
    engineToolStatus :: !(Maybe Text),
    engineToolSummary :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | One entry in an authoritative public todo snapshot.
data EngineTodoItem = EngineTodoItem
  { engineTodoContent :: !Text,
    engineTodoPriority :: !Text,
    engineTodoStatus :: !Text
  }
  deriving (Eq, Show)

-- | Cumulative public context usage reported by a transport.
data EngineUsage = EngineUsage
  { engineUsageUsed :: !Integer,
    engineUsageSize :: !Integer
  }
  deriving (Eq, Show)

-- | Capabilities required to report one physical attempt to the runtime.
data EngineContext = EngineContext
  { runEngineAttempt :: forall a. Maybe EngineSteerer -> Text -> (EngineUpdateSink -> IO a) -> IO a
  }

data EngineSteering = InterruptNow | NextBoundary
  deriving (Eq, Ord, Show, Enum, Bounded)

steeringName :: EngineSteering -> Text
steeringName InterruptNow = "interrupt-now"
steeringName NextBoundary = "next-boundary"

type EngineSteerer = EngineSteering -> Text -> IO (Either Text ())

-- | Runtime-independent request data. The runtime alone translates a typed plan
-- request into this representation.
data EngineRequest = EngineRequest
  { engineTarget :: !Text,
    engineModelAxis :: !(Maybe Text),
    engineModeAxis :: !(Maybe Text),
    engineDraw :: !Integer,
    engineIntent :: !EngineIntent,
    engineAnswerKind :: !EngineAnswerKind,
    enginePrompt :: !Text,
    engineRequiresCompletedTurn :: !Bool
  }
  deriving (Eq, Show)

data EngineIntent = Consult | Observe | Effect
  deriving (Eq, Ord, Show, Enum, Bounded)

intentName :: EngineIntent -> Text
intentName Consult = "consult"
intentName Observe = "observe"
intentName Effect = "effect"

data EngineAnswerKind = TextAnswer | VerdictAnswer | FlagAnswer | ReceiptAnswer | StructuredAnswer
  deriving (Eq, Ord, Show, Enum, Bounded)

answerKindName :: EngineAnswerKind -> Text
answerKindName TextAnswer = "text"
answerKindName VerdictAnswer = "verdict"
answerKindName FlagAnswer = "flag"
answerKindName ReceiptAnswer = "ack"
answerKindName StructuredAnswer = "structured"

data EngineCompletion = Completed | Unverified | Incomplete !Text
  deriving (Eq, Show)

data EngineResult = EngineResult
  { engineAnswer :: !Text,
    engineNarration :: !Text,
    engineCompletion :: !EngineCompletion
  }
  deriving (Eq, Show)

data EngineFailureKind = TransportFailure | ProtocolFailure
  deriving (Eq, Ord, Show)

data EngineError = EngineError
  { engineFailureKind :: !EngineFailureKind,
    engineFailureEvidence :: !Text,
    engineFailureMessage :: !Text
  }
  deriving (Eq, Show)

instance Exception EngineError where
  displayException = T.unpack . engineFailureMessage

-- | Concrete model settings shared by current engines. The symbolic profile and
-- router that selected this value remain owned by CLI composition.
data ModelConfig = ModelConfig
  { modelName :: !Text,
    modelThinking :: !Thinking,
    modelMaxOutput :: !(Maybe Integer)
  }
  deriving (Eq, Show)

data Thinking
  = ThinkOff
  | ThinkMinimal
  | ThinkLow
  | ThinkMedium
  | ThinkHigh
  | ThinkXHigh
  | ThinkMax
  deriving (Eq, Ord, Show, Enum, Bounded)

thinkingName :: Thinking -> Text
thinkingName ThinkOff = "off"
thinkingName ThinkMinimal = "minimal"
thinkingName ThinkLow = "low"
thinkingName ThinkMedium = "medium"
thinkingName ThinkHigh = "high"
thinkingName ThinkXHigh = "xhigh"
thinkingName ThinkMax = "max"

instance FromJSON Thinking where
  parseJSON = withText "thinking level" $ \name ->
    case name of
      "off" -> pure ThinkOff
      "minimal" -> pure ThinkMinimal
      "low" -> pure ThinkLow
      "medium" -> pure ThinkMedium
      "high" -> pure ThinkHigh
      "xhigh" -> pure ThinkXHigh
      "max" -> pure ThinkMax
      _ -> fail ("unknown thinking level '" <> T.unpack name <> "'")

-- | Stateful engines use this runtime-reserved lane to keep turns in plan order.
newtype TurnLane = TurnLane (TVar (TMVar ()))
  deriving (Eq)

newTurnLaneIO :: IO TurnLane
newTurnLaneIO = do
  completed <- newTMVarIO ()
  TurnLane <$> newTVarIO completed

-- | One logical question. Starting it once may yield multiple turns when the
-- runtime re-asks an undecodable answer.
newtype EngineConversation = EngineConversation
  { runEngineTurn :: Text -> IO EngineResult
  }

class Engine engine where
  startEngine :: engine -> EngineContext -> EngineRequest -> IO EngineConversation
  engineTurnLane :: engine -> Maybe TurnLane
  -- | Exact secret values that must suppress any matching public presentation update.
  enginePublicRedactionValues :: engine -> [Text]
  enginePublicRedactionValues _ = []

newtype ConcurrentEngine = ConcurrentEngine (EngineRequest -> Text -> IO EngineResult)

instance Engine ConcurrentEngine where
  startEngine (ConcurrentEngine ask) _ request = pure (EngineConversation (ask request))
  engineTurnLane _ = Nothing

-- | Construct an unordered engine whose logical start is a no-op.
concurrentEngine :: (EngineRequest -> Text -> IO EngineResult) -> ConcurrentEngine
concurrentEngine = ConcurrentEngine

-- ---------------------------------------------------------------------------
-- Versioned value codecs
-- ---------------------------------------------------------------------------

-- | The version that every value codec below writes and the only version that
-- it reads. Each encoded value is a JSON object whose field @version@ holds it.
--
-- Each decoder refuses a value that is not an object, a missing field, a field
-- that the version does not define, a field of the wrong type and any other
-- version, so @decode (encode x) = Right x@ for every value. An 'Integer' is a
-- JSON string of canonical decimal digits, which keeps it exact at any size.
-- 'Text' is carried unchanged. Duplicate keys are the concern of the line
-- decoder that produced the 'Value'.
engineCodecVersion :: Integer
engineCodecVersion = 1

encodeEngineRequest :: EngineRequest -> Value
encodeEngineRequest request =
  versioned
    [ "target" .= engineTarget request,
      "modelAxis" .= engineModelAxis request,
      "modeAxis" .= engineModeAxis request,
      "draw" .= integerText (engineDraw request),
      "intent" .= intentName (engineIntent request),
      "answerKind" .= answerKindName (engineAnswerKind request),
      "prompt" .= enginePrompt request,
      "requiresCompletedTurn" .= engineRequiresCompletedTurn request
    ]

decodeEngineRequest :: Value -> Either Text EngineRequest
decodeEngineRequest value = do
  fields <- versionedFields "engine request" ["target", "modelAxis", "modeAxis", "draw", "intent", "answerKind", "prompt", "requiresCompletedTurn"] value
  EngineRequest
    <$> textField fields "target"
    <*> optionalTextField fields "modelAxis"
    <*> optionalTextField fields "modeAxis"
    <*> integerField fields "draw"
    <*> (textField fields "intent" >>= named "intent" intentName)
    <*> (textField fields "answerKind" >>= named "answer kind" answerKindName)
    <*> textField fields "prompt"
    <*> boolField fields "requiresCompletedTurn"

encodeEngineResult :: EngineResult -> Value
encodeEngineResult result =
  versioned
    [ "answer" .= engineAnswer result,
      "narration" .= engineNarration result,
      "completion" .= completionValue (engineCompletion result)
    ]
  where
    completionValue Completed = object ["state" .= ("completed" :: Text)]
    completionValue Unverified = object ["state" .= ("unverified" :: Text)]
    completionValue (Incomplete reason) = object ["state" .= ("incomplete" :: Text), "reason" .= reason]

decodeEngineResult :: Value -> Either Text EngineResult
decodeEngineResult value = do
  fields <- versionedFields "engine result" ["answer", "narration", "completion"] value
  EngineResult
    <$> textField fields "answer"
    <*> textField fields "narration"
    <*> (field fields "completion" >>= completion)
  where
    completion (Object fields) = case KeyMap.lookup "state" fields of
      Just (String "completed") -> Completed <$ exactFields "completion" ["state"] fields
      Just (String "unverified") -> Unverified <$ exactFields "completion" ["state"] fields
      Just (String "incomplete") -> exactFields "completion" ["state", "reason"] fields >> (Incomplete <$> textField fields "reason")
      Just (String other) -> Left ("completion has unknown state '" <> other <> "'")
      Just _ -> Left "completion field 'state' is not a string"
      Nothing -> Left "completion lacks field 'state'"
    completion _ = Left "engine result field 'completion' is not an object"

encodeEngineSteering :: EngineSteering -> Text -> Value
encodeEngineSteering timing text =
  versioned ["steering" .= steeringName timing, "text" .= text]

decodeEngineSteering :: Value -> Either Text (EngineSteering, Text)
decodeEngineSteering value = do
  fields <- versionedFields "engine steering" ["steering", "text"] value
  (,) <$> (textField fields "steering" >>= named "steering" steeringName) <*> textField fields "text"

encodeEnginePermissionReport :: EnginePermissionReport -> Value
encodeEnginePermissionReport report =
  versioned
    [ "question" .= enginePermissionQuestion report,
      "tool" .= enginePermissionTool report,
      "answer" .= answerValue (enginePermissionAnswer report)
    ]
  where
    answerValue (EnginePermissionGranted option) = object ["outcome" .= ("granted" :: Text), "option" .= option]
    answerValue EnginePermissionRefused = object ["outcome" .= ("refused" :: Text)]

decodeEnginePermissionReport :: Value -> Either Text EnginePermissionReport
decodeEnginePermissionReport value = do
  fields <- versionedFields "engine permission report" ["question", "tool", "answer"] value
  EnginePermissionReport
    <$> textField fields "question"
    <*> textField fields "tool"
    <*> (field fields "answer" >>= answer)
  where
    answer (Object fields) = case KeyMap.lookup "outcome" fields of
      Just (String "granted") -> exactFields "permission answer" ["outcome", "option"] fields >> (EnginePermissionGranted <$> textField fields "option")
      Just (String "refused") -> EnginePermissionRefused <$ exactFields "permission answer" ["outcome"] fields
      Just (String other) -> Left ("permission answer has unknown outcome '" <> other <> "'")
      Just _ -> Left "permission answer field 'outcome' is not a string"
      Nothing -> Left "permission answer lacks field 'outcome'"
    answer _ = Left "engine permission report field 'answer' is not an object"

type Fields = KeyMap.KeyMap Value

versioned :: [(Key, Value)] -> Value
versioned fields = object (("version" .= engineCodecVersion) : fields)

versionedFields :: Text -> [Key] -> Value -> Either Text Fields
versionedFields what keys (Object fields) = do
  _ <- exactFields what ("version" : keys) fields
  case KeyMap.lookup "version" fields of
    Just (Number version) | version == fromInteger engineCodecVersion -> pure fields
    _ -> Left (what <> " is not version " <> integerText engineCodecVersion)
versionedFields what _ _ = Left (what <> " is not an object")

exactFields :: Text -> [Key] -> Fields -> Either Text Fields
exactFields what keys fields =
  case (filter (`notElem` keys) (KeyMap.keys fields), filter (not . (`KeyMap.member` fields)) keys) of
    (unknown : _, _) -> Left (what <> " has unknown field '" <> Key.toText unknown <> "'")
    (_, missing : _) -> Left (what <> " lacks field '" <> Key.toText missing <> "'")
    ([], []) -> Right fields

field :: Fields -> Key -> Either Text Value
field fields key = maybe (Left ("lacks field '" <> Key.toText key <> "'")) Right (KeyMap.lookup key fields)

textField :: Fields -> Key -> Either Text Text
textField fields key =
  field fields key >>= \case
    String text -> Right text
    _ -> Left ("field '" <> Key.toText key <> "' is not a string")

optionalTextField :: Fields -> Key -> Either Text (Maybe Text)
optionalTextField fields key =
  field fields key >>= \case
    Null -> Right Nothing
    String text -> Right (Just text)
    _ -> Left ("field '" <> Key.toText key <> "' is neither a string nor null")

boolField :: Fields -> Key -> Either Text Bool
boolField fields key =
  field fields key >>= \case
    Bool flag -> Right flag
    _ -> Left ("field '" <> Key.toText key <> "' is not a Boolean")

-- | A canonical decimal string: no sign on zero, no leading zeros and no
-- surrounding text, so that the rendering of the parsed value is the input.
integerField :: Fields -> Key -> Either Text Integer
integerField fields key = do
  text <- textField fields key
  case TR.signed TR.decimal text of
    Right (number, "") | integerText number == text -> Right number
    _ -> Left ("field '" <> Key.toText key <> "' is not a canonical decimal integer")

integerText :: Integer -> Text
integerText = T.pack . show

named :: (Enum a, Bounded a) => Text -> (a -> Text) -> Text -> Either Text a
named what name text =
  case [value | value <- [minBound .. maxBound], name value == text] of
    [value] -> Right value
    _ -> Left ("unknown " <> what <> " '" <> text <> "'")
