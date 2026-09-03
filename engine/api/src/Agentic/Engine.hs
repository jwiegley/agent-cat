{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Engine-neutral boundary between runtime policy and concrete transports.
module Agentic.Engine
  ( Engine (..),
    ConcurrentEngine,
    EngineConversation (..),
    EngineContext (..),
    EngineSteerer,
    EngineSteering (..),
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
  )
where

import Control.Concurrent.STM (TMVar, TVar, newTMVarIO, newTVarIO)
import Control.Exception (Exception (displayException))
import Data.Aeson (FromJSON (parseJSON), withText)
import Data.Text (Text)
import qualified Data.Text as T

-- | Capabilities required to report one physical attempt to the runtime.
data EngineContext = EngineContext
  { runEngineAttempt :: forall a. Maybe EngineSteerer -> Text -> ((Text -> IO ()) -> IO a) -> IO a
  }

data EngineSteering = InterruptNow | NextBoundary
  deriving (Eq, Ord, Show)

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
  deriving (Eq, Ord, Show)

intentName :: EngineIntent -> Text
intentName Consult = "consult"
intentName Observe = "observe"
intentName Effect = "effect"

data EngineAnswerKind = TextAnswer | VerdictAnswer | FlagAnswer | ReceiptAnswer | StructuredAnswer
  deriving (Eq, Ord, Show)

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

newtype ConcurrentEngine = ConcurrentEngine (EngineRequest -> Text -> IO EngineResult)

instance Engine ConcurrentEngine where
  startEngine (ConcurrentEngine ask) _ request = pure (EngineConversation (ask request))
  engineTurnLane _ = Nothing

-- | Construct an unordered engine whose logical start is a no-op.
concurrentEngine :: (EngineRequest -> Text -> IO EngineResult) -> ConcurrentEngine
concurrentEngine = ConcurrentEngine
